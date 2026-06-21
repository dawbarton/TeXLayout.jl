# Render a stress-test sheet for TeXLayout.jl using FreeType rasterisation.
#
# Produces a greyscale PNG image with no external dependencies beyond
# FreeTypeAbstraction and PNGFiles (no CairoMakie, no LaTeXStrings required).
#
# Usage:
#   julia tools/stress_test_freetype.jl                        # :new_cm → png
#   julia tools/stress_test_freetype.jl :pagella               # Pagella
#   julia tools/stress_test_freetype.jl :stix_two out.png      # custom path
#   julia tools/stress_test_freetype.jl /path/Math.otf         # custom font

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using FreeTypeAbstraction
using PNGFiles
using Colors: Gray, RGB, N0f8

const BASE_PX = 90    # pixels per em for math content
const MARGIN = 14     # canvas border in pixels
const EXPR_GAP = 30   # horizontal gap between side-by-side expressions (px)
const ROW_GAP = 8     # vertical gap between strips (px)
const TITLE_SCALE = 0.6   # title text size as a fraction of BASE_PX
const SEC_SCALE = 0.5     # section-header text size as a fraction of BASE_PX
const TITLE_H = max(26, round(Int, BASE_PX * 0.8))   # title-bar strip height (px)
const SEC_H = max(20, round(Int, BASE_PX * 0.7))     # section-header strip height (px)

# ── Canvas helpers ─────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    return canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

@inline function composite_white!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    return canvas[ry, cx] = UInt8(old + (255 - old) * Int(alpha) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8 = 0x00)
    r1 = clamp(r1, 1, size(canvas, 1)); r2 = clamp(r2, 1, size(canvas, 1))
    c1 = clamp(c1, 1, size(canvas, 2)); c2 = clamp(c2, 1, size(canvas, 2))
    return r1 > r2 || c1 > c2 || (canvas[r1:r2, c1:c2] .= val)
end

function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    return canvas[r, clamp(c1, 1, size(canvas, 2)):clamp(c2, 1, size(canvas, 2))] .= val
end

# ── Bounding box ───────────────────────────────────────────────────────────────

function em_bbox(boxes, upm; pad = 0.1)
    bx1 = bx2 = by1 = by2 = 0.0
    for box in boxes
        el = box.element
        if el isa Glyph
            s = box.scale / upm
            bx1 = min(bx1, box.x + el.x_min * s)
            bx2 = max(bx2, box.x + el.x_max * s)
            by1 = min(by1, box.y + el.y_min * s)
            by2 = max(by2, box.y + el.y_max * s)
        elseif el isa HRule
            bx1 = min(bx1, box.x); bx2 = max(bx2, box.x + el.width)
            by1 = min(by1, box.y); by2 = max(by2, box.y + el.thickness)
        elseif el isa VRule
            bx1 = min(bx1, box.x); bx2 = max(bx2, box.x + el.thickness)
            by1 = min(by1, box.y); by2 = max(by2, box.y + el.height)
        elseif el isa Space
            bx1 = min(bx1, box.x, box.x + el.width)
            bx2 = max(bx2, box.x, box.x + el.width)
        end
    end
    by1 = min(by1, -0.15); by2 = max(by2, 0.35)
    return (bx1 - pad, bx2 + pad, by1 - pad, by2 + pad)
end

# ── Render one LaTeX expression to a greyscale canvas ─────────────────────────

function render_expr(
        expr::String, family, mt, face_math,
        face_regular = nothing,
        style = TeXLayout.Display,
    )::Matrix{UInt8}
    local boxes
    try
        boxes = layout(parse_latex(expr), family, style)
    catch e
        @warn "layout failed for $expr: $e"
        return fill(0xff, 60, 100)
    end
    isempty(boxes) && return fill(0xff, 60, 60)
    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm)

    W = max(60, 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX))
    H = max(50, 2MARGIN + round(Int, (by2 - by1) * BASE_PX))
    canvas = fill(0xff, H, W)
    em_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    hline!(canvas, em_y(0.0), 1, W, 0xd8)
    hline!(canvas, em_y(mt.constants.axis_height / upm), 1, W, 0xec)

    face_cache = Dict{String, FTFont}(family.math => face_math)
    face_regular !== nothing && (face_cache[TeXLayout._font_path_for_slot(family, TeXLayout.FontSlot.Regular)] = face_regular)
    function face_for(slot)
        path = TeXLayout._font_path_for_slot(family, slot)
        return get!(face_cache, path) do
            FTFont(path)
        end
    end

    for box in boxes
        el = box.element
        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_x(box.x); pen_cy = em_y(box.y)
            face = face_for(el.font_slot)
            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, pixel_size)
            catch
                continue
            end
            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top = pen_cy - by_px
            bmp_left = pen_cx + bx_px
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]; alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end
        elseif el isa HRule
            fill_rect!(
                canvas,
                em_y(box.y + el.thickness), em_x(box.x),
                em_y(box.y), em_x(box.x + el.width),
            )
        elseif el isa VRule
            fill_rect!(
                canvas,
                em_y(box.y + el.height), em_x(box.x),
                em_y(box.y), em_x(box.x + el.thickness),
            )
        end
    end
    return canvas
end

# ── Text rendering for headers ─────────────────────────────────────────────────

function render_text!(
        canvas, face, text::String, x0::Int, scale::Float64,
        fg::Symbol = :black,
    )
    px = max(1, round(Int, scale * BASE_PX))
    H = size(canvas, 1)
    # Common baseline for all glyphs, placing the cap-height band roughly centred
    # within the strip (≈cap height is 0.7·px, so half is ≈px÷3).
    baseline = H ÷ 2 + px ÷ 3
    x = x0
    for ch in text
        local bmp, ext
        try
            bmp, ext = renderface(face, ch, px)
        catch
            x += px ÷ 2; continue
        end
        bx_px = round(Int, ext.horizontal_bearing[1])
        by_px = round(Int, ext.horizontal_bearing[2])
        top = baseline - by_px
        left = x + bx_px
        for row in axes(bmp, 2), col in axes(bmp, 1)
            alpha = bmp[col, row]; alpha == 0x00 && continue
            r = top + row - 1; c = left + col - 1
            fg === :white ? composite_white!(canvas, r, c, alpha) :
                composite!(canvas, r, c, alpha)
        end
        x += round(Int, ext.advance[1])
        x > size(canvas, 2) - MARGIN && break
    end
    return
end

# ── Header strips ──────────────────────────────────────────────────────────────

function render_title_bar(face, text::String, W::Int)::Matrix{UInt8}
    strip = fill(UInt8(0x1a), TITLE_H, W)
    render_text!(strip, face, text, MARGIN, TITLE_SCALE, :white)
    return strip
end

function render_section_header(face, text::String, W::Int)::Matrix{UInt8}
    band = fill(UInt8(0x55), 3, W)
    strip = fill(UInt8(0x44), SEC_H, W)
    render_text!(strip, face, text, MARGIN, SEC_SCALE, :white)
    return vcat(band, strip)
end

# ── Composition helpers ────────────────────────────────────────────────────────

function hcat_canvases(cs::Vector{Matrix{UInt8}}, gap::Int = EXPR_GAP)::Matrix{UInt8}
    isempty(cs) && return fill(0xff, 40, 40)
    H = maximum(size(c, 1) for c in cs)
    W = sum(size(c, 2) for c in cs) + gap * (length(cs) - 1)
    out = fill(0xff, H, W)
    x = 1
    for c in cs
        h, w = size(c)
        r = (H - h) ÷ 2
        out[(r + 1):(r + h), x:(x + w - 1)] .= c
        x += w + gap
    end
    return out
end

function pad_to_width(c::Matrix{UInt8}, W::Int)::Matrix{UInt8}
    h, w = size(c)
    w >= W && return c
    out = fill(0xff, h, W)
    out[:, (MARGIN + 1):min(W, MARGIN + w)] .= c[:, 1:min(w, W - MARGIN)]
    return out
end

function vstack(rows::Vector{Matrix{UInt8}}, gap::Int = ROW_GAP)::Matrix{UInt8}
    isempty(rows) && return fill(0xff, 40, 40)
    W = maximum(size(r, 2) for r in rows)
    parts = Matrix{UInt8}[]
    for (i, r) in enumerate(rows)
        push!(parts, pad_to_width(r, W))
        i < length(rows) && push!(parts, fill(0xff, gap, W))
    end
    return vcat(parts...)
end

# ── Stress-test content ────────────────────────────────────────────────────────

include("stress_test_content.jl")

# ── PNG output ────────────────────────────────────────────────────────────────

function write_png(path::String, canvas::Matrix{UInt8})
    H, W = size(canvas)
    PNGFiles.save(path, reinterpret(Gray{N0f8}, canvas))
    return println("Written $path  ($(W)×$(H) px)")
end

# ── Build the full sheet canvas ────────────────────────────────────────────────

function _build_sheet(
        family::FontFamily,
        mt,
        face_math::FTFont,
        face_regular,
        font_name::String,
    )::Matrix{UInt8}
    section_strips = Matrix{UInt8}[]

    for (_, items) in STRESS_SECTIONS
        canvases = Matrix{UInt8}[]
        for (style, expr) in items
            push!(
                canvases,
                render_expr(expr, family, mt, face_math, face_regular, style),
            )
        end
        push!(section_strips, hcat_canvases(canvases))
    end

    W = max(700, maximum(size(s, 2) for s in section_strips) + 2MARGIN)
    title_str = "TeXLayout.jl  STRESS TEST  —  $(uppercase(font_name))"
    all_rows = Matrix{UInt8}[render_title_bar(face_math, title_str, W)]

    for (i, (sec_title, _)) in enumerate(STRESS_SECTIONS)
        push!(all_rows, render_section_header(face_math, sec_title, W))
        strip = pad_to_width(section_strips[i], W)
        h, w = size(strip)
        padded = fill(0xff, h, W)
        padded[:, (MARGIN + 1):min(W, MARGIN + w)] .= strip[:, 1:min(w, W - MARGIN)]
        push!(all_rows, padded)
    end

    push!(all_rows, fill(UInt8(0x1a), 4, W))
    return vstack(all_rows, 0)
end

# ── Font helpers ───────────────────────────────────────────────────────────────

function _resolve_font(spec)::FontFamily
    spec isa FontFamily && return spec
    s = string(spec)
    startswith(s, ":") && return font_family(Symbol(s[2:end]))
    isfile(s) && return FontFamily(s)
    return font_family(Symbol(s))
end

function _default_output(font_name::String)::String
    slug = lowercase(replace(font_name, r"[^a-zA-Z0-9]+" => "_"))
    slug = strip(slug, '_')
    return "stress_test_$(slug).png"
end

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _output = length(ARGS) >= 2 ? ARGS[2] : nothing

    family = _resolve_font(_font_spec)
    mt = TeXLayout.load_math_table(family.math)
    face_math = FTFont(family.math)
    face_regular = family.regular !== nothing ? FTFont(family.regular) : nothing
    font_name = FreeTypeAbstraction.family_name(face_math)
    outpath = _output !== nothing ? String(_output) : _default_output(font_name)

    canvas = _build_sheet(family, mt, face_math, face_regular, font_name)
    write_png(outpath, canvas)
end
