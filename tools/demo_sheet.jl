# Render a comprehensive single-page PNG "demo sheet" showcasing the layout
# capabilities of TeXLayout.jl for one font family.  Expressions are arranged
# as vertically-stacked horizontal strips; each strip shows a section label
# above one or more side-by-side rendered expressions.  Faint baseline and
# math-axis reference lines are drawn through each expression.
#
# Usage:
#   julia tools/demo_sheet.jl                           # :new_cm, output = demo_new_cm.png
#   julia tools/demo_sheet.jl :pagella                  # Pagella, output = demo_pagella.png
#   julia tools/demo_sheet.jl :stix_two out.png         # STIX Two, named output
#   julia tools/demo_sheet.jl /path/to/Math.otf out.png # custom font path

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io = devnull)
using TeXLayout
using FreeTypeAbstraction

const BASE_PX = 100   # pixels per em for math content
const MARGIN = 14    # canvas border in pixels
const EXPR_GAP = 34    # horizontal gap between side-by-side expressions (px)
const ROW_GAP = 10    # vertical gap between strips (px)
const SEC_H = 22    # section-header strip height (px)
const TITLE_H = 30    # title-bar strip height (px)
const SEC_PX = 13    # FreeType pixel size for section-header text
const TITLE_PX = 16    # FreeType pixel size for title text

# ── Canvas helpers ────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    return canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

# Composite a white foreground glyph (white-on-dark, used for headers).
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

# ── Bounding box in em units ──────────────────────────────────────────────────

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

# ── Render one LaTeX expression to a canvas ───────────────────────────────────

function render_expr(
        expr::String, family, mt, face_math,
        face_regular = nothing,
        style = TeXLayout.Display
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

    # Faint reference lines: baseline (slightly darker) and math axis (lighter).
    hline!(canvas, em_y(0.0), 1, W, 0xd8)
    hline!(canvas, em_y(mt.constants.axis_height / upm), 1, W, 0xec)

    for box in boxes
        el = box.element
        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_x(box.x); pen_cy = em_y(box.y)
            face = (el.font_slot === :regular && face_regular !== nothing) ?
                face_regular : face_math
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
                em_y(box.y), em_x(box.x + el.width)
            )
        elseif el isa VRule
            fill_rect!(
                canvas,
                em_y(box.y + el.height), em_x(box.x),
                em_y(box.y), em_x(box.x + el.thickness)
            )
        end
    end
    return canvas
end

# ── Text rendering for headers ────────────────────────────────────────────────

# Render ASCII text onto a pre-filled canvas using the given FreeType face and
# pixel size.  `fg` controls the glyph colour: :black renders dark-on-light,
# :white renders light-on-dark (for header strips).
function render_text!(
        canvas, face, text::String, x0::Int, px::Int,
        fg::Symbol = :black
    )
    H = size(canvas, 1)
    x = x0
    for ch in text
        local bmp, ext
        try
            bmp, ext = renderface(face, string(ch), px)
        catch
            x += px ÷ 2; continue
        end
        bx_px = round(Int, ext.horizontal_bearing[1])
        by_px = round(Int, ext.horizontal_bearing[2])
        top = H ÷ 2 - by_px ÷ 2 + 2
        left = x + bx_px
        for row in axes(bmp, 2), col in axes(bmp, 1)
            alpha = bmp[col, row]; alpha == 0x00 && continue
            r = top + row - 1; c = left + col - 1
            if fg === :white
                composite_white!(canvas, r, c, alpha)
            else
                composite!(canvas, r, c, alpha)
            end
        end
        x += round(Int, ext.advance[1] / 64)
        x > size(canvas, 2) - MARGIN && break
    end
    return
end

# ── Header strips ─────────────────────────────────────────────────────────────

function render_title_bar(face, text::String, W::Int)::Matrix{UInt8}
    strip = fill(UInt8(0x1a), TITLE_H, W)
    render_text!(strip, face, text, MARGIN, TITLE_PX, :white)
    return strip
end

function render_section_header(face, text::String, W::Int)::Matrix{UInt8}
    # Narrow dark band above, then the section label strip.
    band = fill(UInt8(0x55), 3, W)
    strip = fill(UInt8(0x44), SEC_H, W)
    render_text!(strip, face, text, MARGIN, SEC_PX, :white)
    return vcat(band, strip)
end

# ── Composition helpers ───────────────────────────────────────────────────────

# Place canvases side by side, vertically centred, separated by `gap` pixels.
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

# Pad canvas to width W, left-aligned with MARGIN offset.
function pad_to_width(c::Matrix{UInt8}, W::Int)::Matrix{UInt8}
    h, w = size(c)
    w >= W && return c
    out = fill(0xff, h, W)
    out[:, (MARGIN + 1):min(W, MARGIN + w)] .= c[:, 1:min(w, W - MARGIN)]
    return out
end

# Stack rows of canvases vertically with `gap` pixels of white space between them.
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

# ── Demo content ──────────────────────────────────────────────────────────────

# Each section is a title string paired with a list of LaTeX expressions.
# Expressions within a section are rendered side by side.
const DEMO_SECTIONS = [
    "FRACTIONS & ROOTS" => [
        raw"\frac{1}{\sqrt{2\pi}}\,e^{-x^2/2}",
        raw"\sqrt[3]{x^2+y^2}",
        raw"\frac{\displaystyle\frac{a}{b}}{\displaystyle\frac{c}{d}}",
    ],
    "SCRIPTS & LARGE OPERATORS" => [
        raw"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}",
        raw"\lim_{x \to 0} \frac{\sin x}{x} = 1",
        raw"\prod_{p\,\mathrm{prime}} \frac{1}{1-p^{-s}}",
    ],
    "INTEGRALS" => [
        raw"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
        raw"\oint_C \frac{f(z)}{z-z_0}\,dz = 2\pi i\,f(z_0)",
    ],
    "DELIMITERS" => [
        raw"\left(\frac{a}{b}\right)^{\!\!2}",
        raw"\left\|\,\mathbf{x} - \mathbf{y}\,\right\|^2",
        raw"\left\lfloor \frac{n}{2} \right\rfloor + \left\lceil \frac{n}{2} \right\rceil",
    ],
    "ACCENTS & EXTENSIBLES" => [
        raw"\hat{x} + \vec{v} + \bar{y} + \dot{q}",
        raw"\widehat{xyz} + \widetilde{xyz}",
        raw"\overbrace{a_1+a_2+\cdots+a_n}^{n\text{ terms}}",
    ],
    "FONT VARIANTS" => [
        raw"\mathbb{R}^n \supset \mathcal{H}",
        raw"\mathbf{A}\mathbf{x} = \mathbf{b}",
        raw"\mathfrak{g} \oplus \mathfrak{h}",
    ],
    "MATRICES" => [
        raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}",
        raw"\begin{vmatrix} 1 & 2 \\ 3 & 4 \end{vmatrix} = -2",
        raw"\begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}",
    ],
    "ARRAY (colspec)" => [
        raw"\begin{array}{|c|lr|} \alpha & \beta & \gamma \\ \delta & \varepsilon & \zeta \end{array}",
        raw"\begin{array}{||c||} \dfrac{a}{b} \\ c \end{array}",
    ],
]

# ── Output ────────────────────────────────────────────────────────────────────

function write_png(path, canvas::Matrix{UInt8})
    H, W = size(canvas)
    open(`convert pgm:- png:$path`, "w") do io
        write(io, "P5\n$W $H\n255\n")
        for row in 1:H
            write(io, view(canvas, row, :))
        end
    end
    return println("Written $path  ($(W)×$(H) px)")
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    # Parse arguments: optional font spec and optional output path.
    font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    out_default = let s = lstrip(font_spec, ':')
        isempty(s) || startswith(font_spec, '/') ? "demo_sheet.png" :
            "demo_$(replace(s, '/' => '_')).png"
    end
    outf = length(ARGS) >= 2 ? ARGS[2] : out_default

    # Load family.
    family = if startswith(font_spec, ':')
        sym = Symbol(font_spec[2:end])
        font_family(sym)
    else
        font_family(font_spec)
    end

    math_path = family.math
    mt = TeXLayout.load_math_table(math_path)
    face_math = FTFont(math_path)
    face_regular = family.regular !== nothing ? FTFont(family.regular) : nothing
    font_name = FreeTypeAbstraction.family_name(face_math)

    # Collect all per-section expression canvases.
    section_strips = Matrix{UInt8}[]

    for (sec_title, exprs) in DEMO_SECTIONS
        canvases = Matrix{UInt8}[]
        for expr in exprs
            c = render_expr(expr, family, mt, face_math, face_regular)
            push!(canvases, c)
        end
        row = hcat_canvases(canvases)
        push!(section_strips, row)
    end

    # Determine the overall width.
    W = max(600, maximum(size(s, 2) for s in section_strips) + 2MARGIN)

    # Build the complete sheet.
    title_str = "TeXLayout.jl  —  $(uppercase(font_name))"
    all_rows = Matrix{UInt8}[render_title_bar(face_math, title_str, W)]

    for (i, (sec_title, _)) in enumerate(DEMO_SECTIONS)
        push!(all_rows, render_section_header(face_math, sec_title, W))
        expr_canvas = pad_to_width(section_strips[i], W)
        h, w = size(expr_canvas)
        padded = fill(0xff, h, W)
        padded[:, (MARGIN + 1):min(W, MARGIN + w)] .= expr_canvas[:, 1:min(w, W - MARGIN)]
        push!(all_rows, padded)
    end

    # Bottom border
    push!(all_rows, fill(UInt8(0x1a), 4, W))

    sheet = vstack(all_rows, 0)
    return write_png(outf, sheet)
end

main()
