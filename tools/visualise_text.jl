# Render a mixed text/math string to a PNG greyscale bitmap using FreeType.
# Calls layout_document so styled text, line breaks, inline math, and display
# environments are all handled.
#
# Usage:  julia tools/visualise_text.jl [input] [output.png] [:font_sym|/path]
# Defaults: the worked example from text-spec.md, output.png, :new_cm

using Pkg
Pkg.activate(@__DIR__; io = devnull)
using TeXLayout
using FreeTypeAbstraction
using PNGFiles
using Colors: Gray, N0f8

const BASE_PX = 100   # pixels per em at scale = 1.0
const MARGIN = 20    # canvas border in pixels

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
        elseif el isa VRule
            bx1 = min(bx1, box.x)
            bx2 = max(bx2, box.x + el.thickness)
            by1 = min(by1, box.y)
            by2 = max(by2, box.y + el.height)
        end
    end
    by1 = min(by1, -0.15); by2 = max(by2, 0.15)
    return (bx1, bx2, by1, by2)
end

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    a = Int(alpha)
    return canvas[ry, cx] = UInt8(old * (255 - a) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8 = 0x00)
    r1c = clamp(r1, 1, size(canvas, 1)); r2c = clamp(r2, 1, size(canvas, 1))
    c1c = clamp(c1, 1, size(canvas, 2)); c2c = clamp(c2, 1, size(canvas, 2))
    return canvas[r1c:r2c, c1c:c2c] .= val
end

function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    return canvas[r, clamp(c1, 1, size(canvas, 2)):clamp(c2, 1, size(canvas, 2))] .= val
end

write_image(path, canvas) = PNGFiles.save(path, reinterpret(Gray{N0f8}, canvas))

# ── Main ───────────────────────────────────────────────────────────────────────

const _WORKED_EXAMPLE =
    "\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"

function _parse_font(spec)
    startswith(spec, ":") && return font_family(Symbol(spec[2:end]))
    isfile(spec) && return FontFamily(spec)
    return font_family(Symbol(spec))
end

function main()
    expr = length(ARGS) >= 1 ? ARGS[1] : _WORKED_EXAMPLE
    outf = length(ARGS) >= 2 ? ARGS[2] : "output.png"
    font_spec = length(ARGS) >= 3 ? ARGS[3] : ":new_cm"

    family = _parse_font(font_spec)
    result = layout_document(expr; family = family)
    boxes = result.boxes

    if isempty(boxes)
        @warn "No layout boxes produced"
        return
    end

    upm = Float64(TeXLayout.load_math_table(family.math).upm)

    # Font faces keyed by path — one FTFont per unique font file.
    face_cache = Dict{String, FTFont}()
    slot_path = Dict(
        :math => family.math,
        :regular => something(family.regular, family.math),
        :italic => something(family.italic, family.regular, family.math),
        :bold => something(family.bold, family.regular, family.math),
        :bolditalic => something(
            family.bolditalic, family.bold, family.italic,
            family.regular, family.math
        ),
    )
    function face_for(slot)
        key = get(slot_path, TeXLayout._font_slot_symbol(slot), family.math)
        return get!(face_cache, key) do
            FTFont(key)
        end
    end

    bx1, bx2, by1, by2 = em_bbox(boxes, upm)
    pad_em = 0.15
    bx1 -= pad_em; bx2 += pad_em; by1 -= pad_em; by2 += pad_em

    W = 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX)
    H = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)

    canvas = fill(0xff, H, W)

    em_to_px_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_to_px_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    # Light grey guideline at y = 0 (first-line baseline).
    hline!(canvas, em_to_px_y(0.0), 1, W, 0xcc)

    for box in boxes
        el = box.element

        if el isa Glyph
            face = face_for(el.font_slot)
            px_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_to_px_x(box.x)
            pen_cy = em_to_px_y(box.y)

            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, px_size)
            catch e
                @warn "renderface failed for $(el.glyph_name): $e"
                continue
            end

            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top = pen_cy - by_px
            bmp_left = pen_cx + bx_px

            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end

        elseif el isa HRule
            c1 = em_to_px_x(box.x);              c2 = em_to_px_x(box.x + el.width)
            r1 = em_to_px_y(box.y + el.thickness); r2 = em_to_px_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)

        elseif el isa VRule
            c1 = em_to_px_x(box.x);              c2 = em_to_px_x(box.x + el.thickness)
            r1 = em_to_px_y(box.y + el.height);  r2 = em_to_px_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)
        end
    end

    write_image(outf, canvas)
    return println("Written $outf  ($(W)×$(H) px, $(length(boxes)) boxes)")
end

main()
