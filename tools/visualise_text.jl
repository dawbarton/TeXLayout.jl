# Render a mixed text/math string to a PNG greyscale bitmap using FreeType.
# Calls layout_document so styled text, line breaks, inline math, and display
# environments are all handled.
#
# Usage:  julia tools/visualise_text.jl [input] [output.png] [:font_sym|/path]
# Defaults: a short worked example, output.png, :new_cm

using Pkg
Pkg.activate(@__DIR__; io = devnull)
using TeXLayout
using TeXLayout: layout_document

include("common.jl")

const BASE_PX = 100   # pixels per em at scale = 1.0
const MARGIN = 20    # canvas border in pixels

const _WORKED_EXAMPLE =
    "\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"

function main()
    expr = length(ARGS) >= 1 ? ARGS[1] : _WORKED_EXAMPLE
    outf = length(ARGS) >= 2 ? ARGS[2] : "output.png"
    family = resolve_font(length(ARGS) >= 3 ? ARGS[3] : ":new_cm")

    boxes = layout_document(expr; family = family).boxes
    if isempty(boxes)
        @warn "No layout boxes produced"
        return
    end

    upm = Float64(TeXLayout.load_math_table(family.math).upm)
    bx1, bx2, by1, by2 = em_bbox(boxes, upm; advance = true, pad = 0.15)
    W = 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX)
    H = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)
    canvas = fill(0xff, H, W)
    col(x) = MARGIN + round(Int, (x - bx1) * BASE_PX)
    row(y) = MARGIN + round(Int, (by2 - y) * BASE_PX)

    hline!(canvas, row(0.0), 1, W, 0xcc)   # first-line baseline
    draw_boxes!(canvas, boxes, family, BASE_PX, col, row)

    write_gray_png(outf, canvas)
    return println("Written $outf  ($(W)×$(H) px, $(length(boxes)) boxes)")
end

main()
