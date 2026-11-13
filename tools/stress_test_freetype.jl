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
using TeXLayout: FontFamily, layout, parse_latex

include("common.jl")

const BASE_PX = 90    # pixels per em for math content
const MARGIN = 14     # canvas border in pixels
const EXPR_GAP = 30   # horizontal gap between side-by-side expressions (px)
const ROW_GAP = 8     # vertical gap between strips (px)
const TITLE_SCALE = 0.6   # title text size as a fraction of BASE_PX
const SEC_SCALE = 0.5     # section-header text size as a fraction of BASE_PX
const TITLE_H = max(26, round(Int, BASE_PX * 0.8))   # title-bar strip height (px)
const SEC_H = max(20, round(Int, BASE_PX * 0.7))     # section-header strip height (px)

# ── Bounding box ───────────────────────────────────────────────────────────────

# Every case keeps at least 0.35 em above the baseline, so short expressions
# share a common cap band.
sheet_bbox(boxes, upm; pad = 0.1) = em_bbox(boxes, upm; ymax = 0.35, pad)

# ── Render one LaTeX expression to a greyscale canvas ─────────────────────────

function render_expr(
        expr::String, family::FontFamily, mt, style = TeXLayout.Display,
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
    bx1, bx2, by1, by2 = sheet_bbox(boxes, upm)

    W = max(60, 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX))
    H = max(50, 2MARGIN + round(Int, (by2 - by1) * BASE_PX))
    canvas = fill(0xff, H, W)
    em_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    hline!(canvas, em_y(0.0), 1, W, 0xd8)
    hline!(canvas, em_y(mt.constants.axis_height / upm), 1, W, 0xec)

    draw_boxes!(canvas, boxes, family, BASE_PX, em_x, em_y)
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
        blit!(canvas, bmp, ext, x, baseline; ink = fg === :white ? 0xff : 0x00)
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
    write_gray_png(path, canvas)
    return println("Written $path  ($(W)×$(H) px)")
end

# ── Build the full sheet canvas ────────────────────────────────────────────────

function _build_sheet(family::FontFamily, mt, font_name::String)::Matrix{UInt8}
    section_strips = Matrix{UInt8}[]

    for (_, items) in STRESS_SECTIONS
        canvases = Matrix{UInt8}[]
        for (style, expr) in items
            push!(canvases, render_expr(expr, family, mt, style))
        end
        push!(section_strips, hcat_canvases(canvases))
    end

    face_math = FTFont(family.math)   # sets the title and section headers
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

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _output = length(ARGS) >= 2 ? ARGS[2] : nothing

    family = resolve_font(_font_spec)
    mt = TeXLayout.load_math_table(family.math)
    font_name = FreeTypeAbstraction.family_name(FTFont(family.math))
    outpath = _output !== nothing ? String(_output) : "stress_test_$(font_slug(font_name)).png"

    write_png(outpath, _build_sheet(family, mt, font_name))
end
