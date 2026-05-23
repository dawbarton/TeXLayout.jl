# Render a grid of LaTeX expressions to a single PNG to sanity-check inter-atom
# spacing.  Each row shows one expression; a thin red baseline and blue math-axis
# reference line are drawn behind the glyphs.
#
# Usage:  julia tools/visualise_spacing.jl [output.png]
# Default output: spacing_test.png

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using Formatic
using FreeTypeAbstraction

const FONT_PATH = joinpath(@__DIR__, "..", "..", "external",
    "MathTeXEngine.jl", "assets", "fonts", "NewComputerModern",
    "NewCMMath-Regular.otf")

const BASE_PX  = 80     # pixels per em for a Text-style (scale=1) glyph
const MARGIN   = 12     # border around each row, in pixels
const ROW_GAP  = 4      # extra pixels between rows
const LABEL_W  = 0      # no labels — expressions are self-explanatory

# Expressions to render (label, latex, style)
const EXPRS = [
    ("a b",             "ab",                         Formatic.Text),
    ("a + b",           "a+b",                        Formatic.Text),
    ("a - b",           "a-b",                        Formatic.Text),
    ("a = b",           "a=b",                        Formatic.Text),
    ("a < b",           "a<b",                        Formatic.Text),
    ("a , b",           "a,b",                        Formatic.Text),
    ("\\sin x",         "\\sin x",                    Formatic.Text),
    ("\\sin^2 x",       "\\sin^2 x",                  Formatic.Text),
    ("a + b (script)",  "a+b",                        Formatic.Script),
    ("a \\quad b",      "a\\quad b",                  Formatic.Text),
    ("x^2 + y^2",       "x^2+y^2",                    Formatic.Text),
    ("\\frac{a+b}{c}",  "\\frac{a+b}{c}",             Formatic.Display),
    ("\\left(a+b\\right)", "\\left(a+b\\right)",      Formatic.Text),
]

# ── Canvas helpers ─────────────────────────────────────────────────────────────

function em_bbox(boxes, upm)
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
            bx1 = min(bx1, box.x)
            bx2 = max(bx2, box.x + el.width)
            by1 = min(by1, box.y)
            by2 = max(by2, box.y + el.thickness)
        elseif el isa Space
            bx1 = min(bx1, box.x, box.x + el.width)
            bx2 = max(bx2, box.x, box.x + el.width)
        end
    end
    by1 = min(by1, -0.2); by2 = max(by2, 0.2)
    return (bx1, bx2, by1, by2)
end

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8=0x00)
    r1 = clamp(r1, 1, size(canvas,1)); r2 = clamp(r2, 1, size(canvas,1))
    c1 = clamp(c1, 1, size(canvas,2)); c2 = clamp(c2, 1, size(canvas,2))
    r1 <= r2 && c1 <= c2 && (canvas[r1:r2, c1:c2] .= val)
end

# Draw a 1-px horizontal line in-bounds.
function hline!(canvas, row, c1, c2, val::UInt8)
    row = clamp(row, 1, size(canvas,1))
    c1  = clamp(c1,  1, size(canvas,2))
    c2  = clamp(c2,  1, size(canvas,2))
    c1 <= c2 && (canvas[row, c1:c2] .= val)
end

# ── Render one row ─────────────────────────────────────────────────────────────

function render_row!(canvas, row_top, boxes, face, upm, axis_height_em)
    isempty(boxes) && return

    bx1, bx2, by1, by2 = em_bbox(boxes, upm)
    pad = 0.05
    bx1 -= pad; bx2 += pad; by1 -= pad; by2 += pad

    W = size(canvas, 2)
    H_row = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)
    em_to_px_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_to_px_y(ey) = row_top + MARGIN + round(Int, (by2 - ey) * BASE_PX)

    # Reference lines
    hline!(canvas, em_to_px_y(0.0),              1, W, 0xcc)   # baseline (light grey)
    hline!(canvas, em_to_px_y(axis_height_em),   1, W, 0xcc)   # math axis

    for box in boxes
        el = box.element
        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_to_px_x(box.x)
            pen_cy = em_to_px_y(box.y)
            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, pixel_size)
            catch e
                @warn "renderface failed for $(el.glyph_name): $e"
                continue
            end
            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top  = pen_cy - by_px
            bmp_left = pen_cx + bx_px
            for row in axes(bmp,2), col in axes(bmp,1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, bmp_top+row-1, bmp_left+col-1, alpha)
            end
        elseif el isa HRule
            c1 = em_to_px_x(box.x)
            c2 = em_to_px_x(box.x + el.width)
            r1 = em_to_px_y(box.y + el.thickness)
            r2 = em_to_px_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)
        elseif el isa Space && el.width > 0.0
            # Draw space as a very-light-grey band so it is visible in the test image.
            c1 = em_to_px_x(box.x)
            c2 = em_to_px_x(box.x + el.width)
            fill_rect!(canvas, row_top+1, c1, row_top+H_row-2, max(c1+1, c2), 0xe8)
        end
    end

    return H_row
end

# ── Main ───────────────────────────────────────────────────────────────────────

function main()
    outf  = length(ARGS) >= 1 ? ARGS[1] : "spacing_test.png"

    isfile(FONT_PATH) || error("Font not found: $FONT_PATH")
    family = FontFamily(FONT_PATH)
    mt     = load_math_table(FONT_PATH)
    face   = FTFont(FONT_PATH)

    axis_em = mt.constants.axis_height / mt.upm

    # Pre-compute row boxes and heights.
    all_boxes  = Vector{Vector}()
    row_heights = Int[]
    for (_, expr, style) in EXPRS
        boxes = layout(parse_latex(expr), family, style)
        push!(all_boxes, boxes)
        if isempty(boxes)
            push!(row_heights, 2MARGIN + round(Int, 0.4 * BASE_PX))
        else
            _, _, by1, by2 = em_bbox(boxes, mt.upm)
            pad = 0.05
            by1 -= pad; by2 += pad
            push!(row_heights, 2MARGIN + round(Int, (by2-by1)*BASE_PX))
        end
    end

    # Separator between rows.
    sep_h = ROW_GAP

    # Canvas dimensions — width fixed so all rows are the same width.
    max_bx2 = maximum(begin
        isempty(b) ? 0.5 :
            maximum(box.x + (box.element isa Glyph ? box.element.x_max/mt.upm*box.scale : 0.0)
                    for box in b)
        end for b in all_boxes)
    W = 2MARGIN + round(Int, (max_bx2 + 0.1) * BASE_PX) + 200
    H = sum(row_heights) + sep_h * (length(EXPRS) - 1)

    canvas = fill(0xff, H, W)

    row_top = 0
    for (i, (label, expr, style)) in enumerate(EXPRS)
        h = render_row!(canvas, row_top, all_boxes[i], face, mt.upm, axis_em)
        # Draw a thin separator between rows.
        if i < length(EXPRS)
            hline!(canvas, row_top + h, 1, W, 0xaa)
        end
        row_top += h + sep_h
    end

    # Write PNG via ImageMagick.
    open(`convert pgm:- png:$outf`, "w") do io
        H2, W2 = size(canvas)
        write(io, "P5\n$W2 $H2\n255\n")
        for row in 1:H2
            write(io, view(canvas, row, :))
        end
    end
    println("Written $outf  ($(W)×$(H) px, $(length(EXPRS)) expressions)")
end

main()
