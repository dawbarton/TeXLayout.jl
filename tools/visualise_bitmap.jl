# Render a LaTeX expression to a PGM greyscale bitmap using FreeType glyph
# rasterisation, providing a pixel-accurate sanity check of the layout engine.
#
# Each Glyph LayoutBox is rendered at its scaled pixel size; HRule elements are
# filled directly.  A light-grey baseline and math-axis reference line are drawn
# beneath the glyphs.  The result is written as a binary PGM (P5) file.
#
# Usage:  julia tools/visualise_bitmap.jl [expression] [output.pgm]
# Defaults: expression = "\\frac{a}{b}", output = "output.png"

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using TeXLayout
using FreeTypeAbstraction

const BASE_PX  = 100   # pixels per em at Text scale (box.scale = 1.0)
const MARGIN   = 20    # canvas border in pixels

const FONT_PATH = joinpath(@__DIR__, "..", "..", "external",
    "MathTeXEngine.jl", "assets", "fonts", "NewComputerModern",
    "NewCMMath-Regular.otf")

# ── Canvas helpers ─────────────────────────────────────────────────────────────

# Bounding box of all layout boxes in em units (y upward).
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
    # Ensure baseline is visible
    by1 = min(by1, -0.15); by2 = max(by2, 0.15)
    return (bx1, bx2, by1, by2)
end

# Composite a grey level (0 = black) onto a white canvas with alpha blending.
@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    a   = Int(alpha)
    canvas[ry, cx] = UInt8(old * (255 - a) ÷ 255)
end

# Fill a rectangle on the canvas with value `val` (0 = black).
function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8=0x00)
    r1c = clamp(r1, 1, size(canvas, 1))
    r2c = clamp(r2, 1, size(canvas, 1))
    c1c = clamp(c1, 1, size(canvas, 2))
    c2c = clamp(c2, 1, size(canvas, 2))
    canvas[r1c:r2c, c1c:c2c] .= val
end

# Draw a horizontal line (1-pixel thick) with value `val`.
function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    c1c = clamp(c1, 1, size(canvas, 2))
    c2c = clamp(c2, 1, size(canvas, 2))
    canvas[r, c1c:c2c] .= val
end

# ── Image output ─────────────────────────────────────────────────────────────
# Writes the canvas as PGM or PNG (detected from the file extension).
# PNG uses ImageMagick's `convert` via a pipe; no extra Julia packages needed.
function write_image(path, canvas::Matrix{UInt8})
    H, W = size(canvas)
    if endswith(path, ".png")
        open(`convert pgm:- png:$path`, "w") do io
            write(io, "P5\n$W $H\n255\n")
            for row in 1:H
                write(io, view(canvas, row, :))
            end
        end
    else
        open(path, "w") do io
            write(io, "P5\n$W $H\n255\n")
            for row in 1:H
                write(io, view(canvas, row, :))
            end
        end
    end
end

# ── Main ───────────────────────────────────────────────────────────────────────
function main()
    expr  = length(ARGS) >= 1 ? ARGS[1] : "\\frac{a}{b}"
    outf  = length(ARGS) >= 2 ? ARGS[2] : "output.png"
    style = TeXLayout.Display

    isfile(FONT_PATH) || error("Font not found: $FONT_PATH")
    family = FontFamily(FONT_PATH)
    mt     = load_math_table(FONT_PATH)
    boxes  = layout(parse_latex(expr), family, style)

    if isempty(boxes)
        @warn "No layout boxes produced for expression: $expr"
        return
    end

    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm)
    # Add padding
    pad_em = 0.1
    bx1 -= pad_em; bx2 += pad_em; by1 -= pad_em; by2 += pad_em

    W = 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX)
    H = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)

    # Canvas is row-major: canvas[screen_y, screen_x], white background
    canvas = fill(0xff, H, W)

    # Convert em coords to canvas pixels (y flipped: math y↑, canvas y↓)
    em_to_px_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_to_px_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    # Reference lines (light grey = 0xcc)
    hline!(canvas, em_to_px_y(0.0), 1, W, 0xcc)                          # baseline
    hline!(canvas, em_to_px_y(mt.constants.axis_height / upm), 1, W, 0xcc)  # math axis

    # Load FreeType face for rendering
    face = FTFont(FONT_PATH)

    for box in boxes
        el = box.element

        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            # Pen position on canvas (baseline of this box)
            pen_cx = em_to_px_x(box.x)
            pen_cy = em_to_px_y(box.y)

            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, pixel_size)
            catch e
                @warn "renderface failed for $(el.glyph_name): $e"
                continue
            end

            # ext.horizontal_bearing = (horiBearingX, horiBearingY) in pixels
            bx_px = round(Int, ext.horizontal_bearing[1])  # left bearing
            by_px = round(Int, ext.horizontal_bearing[2])  # top bearing (pixels above baseline)

            # Top-left of bitmap on canvas
            bmp_top  = pen_cy - by_px
            bmp_left = pen_cx + bx_px

            # bmp is indexed as bmp[col, row] (x first, then y)
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end

        elseif el isa HRule
            # HRule positions in em: x ∈ [box.x, box.x+el.width], y ∈ [box.y, box.y+el.thickness]
            c1 = em_to_px_x(box.x)
            c2 = em_to_px_x(box.x + el.width)
            r1 = em_to_px_y(box.y + el.thickness)
            r2 = em_to_px_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)
        elseif el isa VRule
            # VRule positions in em: x ∈ [box.x, box.x+el.thickness], y ∈ [box.y, box.y+el.height]
            c1 = em_to_px_x(box.x)
            c2 = em_to_px_x(box.x + el.thickness)
            r1 = em_to_px_y(box.y + el.height)
            r2 = em_to_px_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)
        end
        # Space elements have no visual representation in the bitmap
    end

    write_image(outf, canvas)
    println("Written $outf  ($(W)×$(H) px, $(length(boxes)) boxes)")
end

main()
