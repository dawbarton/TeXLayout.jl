# Render a LaTeX expression to a PNG greyscale bitmap using FreeType glyph
# rasterisation, providing a pixel-accurate sanity check of the layout engine.
#
# Each glyph is rendered at its scaled pixel size from the face the renderer
# adapters would use; rules are filled directly.  Light-grey baseline and
# math-axis reference lines are drawn beneath the glyphs.
#
# Usage:  julia tools/visualise_bitmap.jl [expression] [output.png] [:font_sym|/path]
# Defaults: expression = "\\frac{a}{b}", output = "output.png", font = :new_cm

using Pkg
Pkg.activate(@__DIR__; io = devnull)
using TeXLayout
using TeXLayout: layout, parse_latex

include("common.jl")

const BASE_PX = 100   # pixels per em at Text scale (box.scale = 1.0)
const MARGIN = 20    # canvas border in pixels

function main()
    expr = length(ARGS) >= 1 ? ARGS[1] : "\\frac{a}{b}"
    outf = length(ARGS) >= 2 ? ARGS[2] : "output.png"
    family = resolve_font(length(ARGS) >= 3 ? ARGS[3] : ":new_cm")

    mt = TeXLayout.load_math_table(family.math)
    boxes = layout(parse_latex(expr), family, TeXLayout.Display)
    if isempty(boxes)
        @warn "No layout boxes produced for expression: $expr"
        return
    end

    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm; pad = 0.1)
    W = 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX)
    H = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)
    canvas = fill(0xff, H, W)
    col(x) = MARGIN + round(Int, (x - bx1) * BASE_PX)
    row(y) = MARGIN + round(Int, (by2 - y) * BASE_PX)

    hline!(canvas, row(0.0), 1, W, 0xcc)
    hline!(canvas, row(mt.constants.axis_height / upm), 1, W, 0xcc)
    draw_boxes!(canvas, boxes, family, BASE_PX, col, row)

    write_gray_png(outf, canvas)
    return println("Written $outf  ($(W)×$(H) px, $(length(boxes)) boxes)")
end

main()
