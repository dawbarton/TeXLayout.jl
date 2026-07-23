# Render a MathTeXEngine-style metric visualisation for one TeXLayout expression.
#
# The output overlays the rendered glyphs/rules with coloured metric regions:
#   - yellow: origin-to-left-ink gap
#   - green: right-ink-to-advance gap
#   - red:    ink above the baseline
#   - blue:   descender below the baseline
# along with baseline and math-axis guides.
#
# Usage:
#   julia tools/visualise_metrics.jl "expr" [output.png] [:font_symbol|/path/to/font.otf]
#
# Examples:
#   julia tools/visualise_metrics.jl "\\frac{a}{b}" metrics.png
#   julia tools/visualise_metrics.jl "\\sum_{n=1}^\\infty n^{-2}" metrics.png :stix_two

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using FreeTypeAbstraction
using TeXLayout
using TeXLayout:
    FontFamily, Glyph, HRule, LayoutBox, Space, VRule, layout, parse_latex
using PNGFiles
using Colors: RGB, N0f8

@inline rgb(r, g, b) = (UInt8(r), UInt8(g), UInt8(b))

const BASE_PX = 110
const MARGIN = 28
const PAD_EM = 0.16

const WHITE = rgb(0xff, 0xff, 0xff)
const BLACK = rgb(0x00, 0x00, 0x00)
const BASELINE = rgb(0xb8, 0xb8, 0xb8)
const AXIS = rgb(0xff, 0x99, 0x99)
const YELLOW = rgb(0xff, 0xe6, 0x00)
const GREEN = rgb(0x44, 0xcc, 0x44)
const RED = rgb(0xff, 0x55, 0x55)
const BLUE = rgb(0x55, 0x88, 0xff)
const OUTLINE = rgb(0x1f, 0x4f, 0xa3)

const OVERLAY_ALPHA = Dict(
    :left_gap => 0.55,
    :right_gap => 0.28,
    :above_baseline => 0.38,
    :descender => 0.3,
    :outline => 1.0,
    :guide => 1.0,
)

function usage(io::IO = stderr)
    println(
        io,
        "Usage: julia tools/visualise_metrics.jl \"expr\" [output.png] " *
            "[:font_symbol|/path/to/font.otf]"
    )
    return nothing
end

function parse_font(spec::AbstractString)
    startswith(spec, ":") && return font_family(Symbol(spec[2:end]))
    isfile(spec) || error("Font path not found: $spec")
    return FontFamily(spec)
end

function load_family()
    length(ARGS) >= 3 && return parse_font(ARGS[3])
    return default_font_family()
end

function em_bbox(boxes::Vector{LayoutBox}, upm::Real)
    upm_f = Float64(upm)
    bx1 = bx2 = by1 = by2 = 0.0
    for box in boxes
        el = box.element
        if el isa Glyph
            s = box.scale / upm_f
            bx1 = min(bx1, box.x + el.x_min * s, box.x + el.advance_width * s)
            bx2 = max(bx2, box.x + el.x_max * s, box.x + el.advance_width * s)
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
        elseif el isa Space
            bx1 = min(bx1, box.x, box.x + el.width)
            bx2 = max(bx2, box.x, box.x + el.width)
        end
    end
    by1 = min(by1, -0.2)
    by2 = max(by2, 0.2)
    return (bx1 - PAD_EM, bx2 + PAD_EM, by1 - PAD_EM, by2 + PAD_EM)
end

@inline function clamp_index(i::Int, lo::Int, hi::Int)
    return i < lo ? lo : (i > hi ? hi : i)
end

@inline function blend_pixel!(
        canvas::Array{UInt8, 3}, row::Int, col::Int,
        color::NTuple{3, UInt8}, alpha::Float64
    )
    1 <= row <= size(canvas, 1) && 1 <= col <= size(canvas, 2) || return nothing
    a = clamp(alpha, 0.0, 1.0)
    ia = 1.0 - a
    @inbounds for ch in 1:3
        canvas[row, col, ch] = UInt8(round(Int, canvas[row, col, ch] * ia + color[ch] * a))
    end
    return nothing
end

function fill_rect!(
        canvas::Array{UInt8, 3},
        r1::Int, c1::Int, r2::Int, c2::Int,
        color::NTuple{3, UInt8}, alpha::Float64
    )
    rr1 = clamp_index(min(r1, r2), 1, size(canvas, 1))
    rr2 = clamp_index(max(r1, r2), 1, size(canvas, 1))
    cc1 = clamp_index(min(c1, c2), 1, size(canvas, 2))
    cc2 = clamp_index(max(c1, c2), 1, size(canvas, 2))
    for row in rr1:rr2, col in cc1:cc2
        blend_pixel!(canvas, row, col, color, alpha)
    end
    return nothing
end

function rect_outline!(
        canvas::Array{UInt8, 3},
        r1::Int, c1::Int, r2::Int, c2::Int,
        color::NTuple{3, UInt8}
    )
    rr1 = clamp_index(min(r1, r2), 1, size(canvas, 1))
    rr2 = clamp_index(max(r1, r2), 1, size(canvas, 1))
    cc1 = clamp_index(min(c1, c2), 1, size(canvas, 2))
    cc2 = clamp_index(max(c1, c2), 1, size(canvas, 2))
    for col in cc1:cc2
        blend_pixel!(canvas, rr1, col, color, OVERLAY_ALPHA[:outline])
        blend_pixel!(canvas, rr2, col, color, OVERLAY_ALPHA[:outline])
    end
    for row in rr1:rr2
        blend_pixel!(canvas, row, cc1, color, OVERLAY_ALPHA[:outline])
        blend_pixel!(canvas, row, cc2, color, OVERLAY_ALPHA[:outline])
    end
    return nothing
end

function hline!(
        canvas::Array{UInt8, 3}, row::Int, c1::Int, c2::Int,
        color::NTuple{3, UInt8}
    )
    rr = clamp_index(row, 1, size(canvas, 1))
    cc1 = clamp_index(min(c1, c2), 1, size(canvas, 2))
    cc2 = clamp_index(max(c1, c2), 1, size(canvas, 2))
    for col in cc1:cc2
        blend_pixel!(canvas, rr, col, color, OVERLAY_ALPHA[:guide])
    end
    return nothing
end

function vline!(
        canvas::Array{UInt8, 3}, col::Int, r1::Int, r2::Int,
        color::NTuple{3, UInt8}
    )
    cc = clamp_index(col, 1, size(canvas, 2))
    rr1 = clamp_index(min(r1, r2), 1, size(canvas, 1))
    rr2 = clamp_index(max(r1, r2), 1, size(canvas, 1))
    for row in rr1:rr2
        blend_pixel!(canvas, row, cc, color, OVERLAY_ALPHA[:guide])
    end
    return nothing
end

@inline function composite_black!(canvas::Array{UInt8, 3}, row::Int, col::Int, alpha::UInt8)
    1 <= row <= size(canvas, 1) && 1 <= col <= size(canvas, 2) || return nothing
    a = Int(alpha)
    @inbounds for ch in 1:3
        canvas[row, col, ch] = UInt8(Int(canvas[row, col, ch]) * (255 - a) ÷ 255)
    end
    return nothing
end

function write_image(path::AbstractString, canvas::Array{UInt8, 3})
    H, W, _ = size(canvas)
    perm = permutedims(canvas, (3, 1, 2))  # 3×H×W: channels innermost for reinterpret
    return PNGFiles.save(path, reinterpret(reshape, RGB{N0f8}, perm))
end

function main()
    any(arg -> arg in ("-h", "--help"), ARGS) && return usage(stdout)

    expr = length(ARGS) >= 1 ? ARGS[1] : raw"\frac{a}{b}"
    outf = length(ARGS) >= 2 ? ARGS[2] : "visualise_metrics.png"
    family = load_family()

    mt = TeXLayout.load_math_table(family.math)
    boxes = layout(parse_latex(expr), family, TeXLayout.Display)
    isempty(boxes) && @warn "No layout boxes produced for expression: $expr"

    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm)

    W = max(1, 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX))
    H = max(1, 2MARGIN + round(Int, (by2 - by1) * BASE_PX))
    canvas = fill(UInt8(0xff), H, W, 3)

    em_to_px_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_to_px_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    baseline_row = em_to_px_y(0.0)
    axis_row = em_to_px_y(mt.constants.axis_height / upm)
    hline!(canvas, baseline_row, 1, W, BASELINE)
    hline!(canvas, axis_row, 1, W, AXIS)

    face_cache = Dict{String, FTFont}()
    function face_for(slot)
        path = TeXLayout._font_path_for_slot(family, slot)
        return get!(face_cache, path) do
            FTFont(path)
        end
    end

    for box in boxes
        el = box.element
        if el isa Glyph
            s = box.scale / upm
            x0 = box.x
            y0 = box.y
            left = el.x_min * s
            right = el.x_max * s
            top = el.y_max * s
            bottom = el.y_min * s
            adv = el.advance_width * s

            ink_left = em_to_px_x(x0 + left)
            ink_right = em_to_px_x(x0 + right)
            ink_top = em_to_px_y(y0 + top)
            ink_bottom = em_to_px_y(y0 + bottom)
            origin_col = em_to_px_x(x0)
            advance_col = em_to_px_x(x0 + adv)

            fill_rect!(
                canvas,
                ink_bottom, origin_col, ink_top, ink_left,
                YELLOW, OVERLAY_ALPHA[:left_gap]
            )
            fill_rect!(
                canvas,
                ink_bottom, ink_right, ink_top, advance_col,
                GREEN, OVERLAY_ALPHA[:right_gap]
            )
            fill_rect!(
                canvas,
                em_to_px_y(y0), ink_left, ink_top, ink_right,
                RED, OVERLAY_ALPHA[:above_baseline]
            )
            fill_rect!(
                canvas,
                ink_bottom, ink_left, em_to_px_y(y0), ink_right,
                BLUE, OVERLAY_ALPHA[:descender]
            )

            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            face = face_for(el.font_slot)

            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, pixel_size)
            catch err
                @warn "renderface failed for $(el.glyph_name): $err"
                continue
            end

            pen_col = em_to_px_x(box.x)
            pen_row = em_to_px_y(box.y)
            bmp_left = pen_col + round(Int, ext.horizontal_bearing[1])
            bmp_top = pen_row - round(Int, ext.horizontal_bearing[2])

            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite_black!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end

            rect_outline!(canvas, ink_top, ink_left, ink_bottom, ink_right, OUTLINE)
            vline!(canvas, origin_col, ink_top, ink_bottom, OUTLINE)
            vline!(canvas, advance_col, ink_top, ink_bottom, GREEN)

        elseif el isa HRule
            fill_rect!(
                canvas,
                em_to_px_y(box.y + el.thickness),
                em_to_px_x(box.x),
                em_to_px_y(box.y),
                em_to_px_x(box.x + el.width),
                BLACK,
                1.0,
            )
        elseif el isa VRule
            fill_rect!(
                canvas,
                em_to_px_y(box.y + el.height),
                em_to_px_x(box.x),
                em_to_px_y(box.y),
                em_to_px_x(box.x + el.thickness),
                BLACK,
                1.0,
            )
        end
    end

    write_image(outf, canvas)
    return println("Written $outf  ($(W)x$(H) px, $(length(boxes)) boxes)")
end

main()
