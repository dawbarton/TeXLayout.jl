# Visualise TeXLayout.jl layout output as an SVG bounding-box diagram.
#
# Each LayoutBox is drawn as a coloured rectangle showing its ink extent:
#   - Glyph:  light-blue fill, PS glyph name label
#   - HRule:  dark-grey fill
#   - Space:  dashed purple outline (red if negative width)
# Reference lines show the formula baseline (blue) and math axis (red).
#
# Usage:  julia tools/visualise_svg.jl [expression] [output.svg]
# Defaults: expression = "\\frac{a}{b}", output = "output.svg"

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using TeXLayout

const PXEM   = 150    # SVG user units per em
const MARGIN = 60     # border around the content (SVG user units)
const PAD    = 0.15   # extra padding in em added to each side of the bounding box

const FONT_PATH = joinpath(@__DIR__, "..", "..", "external",
    "MathTeXEngine.jl", "assets", "fonts", "NewComputerModern",
    "NewCMMath-Regular.otf")

# ── Coordinate transforms ──────────────────────────────────────────────────────
# em_bbox: (bx1, bx2, by1, by2) — bounding box in em units (y up)
# SVG origin is top-left; y increases downward.
make_transforms(bx1, by2) = (
    cx = ex -> MARGIN + (ex - bx1) * PXEM,
    cy = ey -> MARGIN + (by2 - ey) * PXEM,
)

# ── Bounding box computation ───────────────────────────────────────────────────
function ink_bbox(boxes, upm)
    bx1 = bx2 = by1 = by2 = 0.0   # always include the origin
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
    # Ensure a minimum visible height around the baseline
    by1 = min(by1, -0.15); by2 = max(by2, 0.15)
    return (bx1 - PAD, bx2 + PAD, by1 - PAD, by2 + PAD)
end

# ── SVG helpers ────────────────────────────────────────────────────────────────
svg_rect(io, x, y, w, h; fill, stroke="none", sw=1, dash="") = println(io,
    """<rect x="$(round(x,digits=2))" y="$(round(y,digits=2))" """ *
    """width="$(round(w,digits=2))" height="$(round(h,digits=2))" """ *
    """fill="$fill" stroke="$stroke" stroke-width="$sw" """ *
    (isempty(dash) ? "" : """stroke-dasharray="$dash" """) * "/>")

svg_line(io, x1, y1, x2, y2; stroke, sw=1, dash="") = println(io,
    """<line x1="$(round(x1,digits=2))" y1="$(round(y1,digits=2))" """ *
    """x2="$(round(x2,digits=2))" y2="$(round(y2,digits=2))" """ *
    """stroke="$stroke" stroke-width="$sw" """ *
    (isempty(dash) ? "" : """stroke-dasharray="$dash" """) * "/>")

svg_text(io, x, y, s; size=10, fill="#333") = println(io,
    """<text x="$(round(x,digits=2))" y="$(round(y,digits=2))" """ *
    """text-anchor="middle" dominant-baseline="middle" """ *
    """font-size="$size" font-family="monospace" fill="$fill">$s</text>""")

# ── Main ───────────────────────────────────────────────────────────────────────
function main()
    expr  = length(ARGS) >= 1 ? ARGS[1] : "\\frac{a}{b}"
    outf  = length(ARGS) >= 2 ? ARGS[2] : "output.svg"
    style = TeXLayout.Display

    isfile(FONT_PATH) || error("Font not found: $FONT_PATH")
    family = FontFamily(FONT_PATH)
    mt     = load_math_table(FONT_PATH)
    boxes  = layout(parse_latex(expr), family, style)

    if isempty(boxes)
        @warn "No layout boxes produced for expression: $expr"
    end

    bx1, bx2, by1, by2 = ink_bbox(boxes, mt.upm)
    cx, cy = make_transforms(bx1, by2)

    W = round(Int, 2MARGIN + (bx2 - bx1) * PXEM)
    H = round(Int, 2MARGIN + (by2 - by1) * PXEM)
    axis_em = mt.constants.axis_height / mt.upm

    open(outf, "w") do io
        println(io, """<?xml version="1.0" encoding="UTF-8"?>""")
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" """ *
                    """viewBox="0 0 $W $H">""")
        svg_rect(io, 0, 0, W, H; fill="white")

        # Reference lines span the full canvas width
        svg_line(io, 0, cy(axis_em), W, cy(axis_em);
                 stroke="#cc0000", sw=1, dash="6,4")
        svg_line(io, 0, cy(0.0),    W, cy(0.0);
                 stroke="#0055cc", sw=1, dash="4,4")

        upm = mt.upm
        for box in boxes
            el = box.element
            if el isa Glyph
                s  = box.scale / upm
                x1 = cx(box.x + el.x_min * s)
                y1 = cy(box.y + el.y_max * s)
                x2 = cx(box.x + el.x_max * s)
                y2 = cy(box.y + el.y_min * s)
                w  = max(x2 - x1, 1.0); h = max(y2 - y1, 1.0)
                svg_rect(io, x1, y1, w, h;
                         fill="#cce0ff", stroke="#3366cc", sw=1)
                # Label: glyph name centred inside the box (clip via font size)
                fs = clamp(round(Int, min(w / max(1, length(el.glyph_name)) * 1.6, h * 0.5)), 6, 12)
                svg_text(io, x1 + w/2, y1 + h/2, el.glyph_name; size=fs)

            elseif el isa HRule
                x1 = cx(box.x)
                y1 = cy(box.y + el.thickness)
                w  = max((bx2 - bx1) * PXEM * el.width / (bx2 - bx1), 1.0)
                # Recompute width properly in SVG units
                w  = max(cx(box.x + el.width) - x1, 1.0)
                h  = max(cy(box.y) - y1, 1.0)
                svg_rect(io, x1, y1, w, h; fill="#222222")

            elseif el isa Space
                neg = el.width < 0.0
                xl  = cx(min(box.x, box.x + el.width))
                xr  = cx(max(box.x, box.x + el.width))
                yt  = cy(box.y + 0.08); yb = cy(box.y - 0.08)
                w   = max(xr - xl, 1.0); h = yb - yt
                col = neg ? "#cc0000" : "#9900cc"
                svg_rect(io, xl, yt, w, h;
                         fill="none", stroke=col, sw=1.5, dash="5,3")
            end
        end

        # Legend
        lx = W - MARGIN + 5
        ly = MARGIN
        svg_line(io, lx, ly,      lx + 18, ly;      stroke="#cc0000", sw=1, dash="6,4")
        svg_text(io, lx + 35, ly, "axis"; size=9, fill="#cc0000")
        ly += 14
        svg_line(io, lx, ly,      lx + 18, ly;      stroke="#0055cc", sw=1, dash="4,4")
        svg_text(io, lx + 40, ly, "baseline"; size=9, fill="#0055cc")

        println(io, "</svg>")
    end
    println("Written $outf  ($(W)×$(H) px, $(length(boxes)) boxes)")
end

main()
