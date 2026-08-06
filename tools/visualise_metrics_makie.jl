# Render a TeXLayout metric visualisation using CairoMakie.
#
# The expression is drawn via a normal Makie `text!` call on a `LaTeXString`.
# The overlays are computed from the same TeXLayout boxes returned through
# Makie's text-handler interface, so the guides track the rendered glyphs.
#   - yellow: origin-to-left-ink gap
#   - green: right-ink-to-advance gap
#   - red:    ink above the baseline
#   - blue:   descender below the baseline
# plus baseline / math-axis guides and per-glyph origin / advance markers.
#
# Usage:
#   julia tools/visualise_metrics_makie.jl "expr" \
#         [output.png|output.svg|output.pdf] [:font_symbol|/path/to/font.otf]

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using CairoMakie
import CairoMakie.Makie
using LaTeXStrings: LaTeXString
using TeXLayout
using TeXLayout: FontFamily, generate_tex_elements

const BASE_PX = 110
const MARGIN = 28
const PAD_EM = 0.16

const BASELINE = RGBf(0.72, 0.72, 0.72)
const AXIS = RGBf(1.0, 0.6, 0.6)
const YELLOW = RGBAf(1.0, 0.9, 0.0, 0.55)
const GREEN = RGBAf(0.27, 0.8, 0.27, 0.28)
const RED = RGBAf(1.0, 0.33, 0.33, 0.38)
const BLUE = RGBAf(0.33, 0.53, 1.0, 0.3)
const OUTLINE = RGBf(0.12, 0.31, 0.64)
function usage(io::IO = stderr)
    println(
        io,
        "Usage: julia tools/visualise_metrics_makie.jl \"expr\" " *
            "[output.png|output.svg|output.pdf] [:font_symbol|/path/to/font.otf]"
    )
    return nothing
end

function parse_font(spec::AbstractString)
    startswith(spec, ":") && return font_family(Symbol(spec[2:end]))
    isfile(spec) || error("Font path not found: $spec")
    return TeXLayout.FontFamily(spec)
end

function load_family()
    length(ARGS) >= 3 && return parse_font(ARGS[3])
    return default_font_family()
end

function wrap_latex(expr::AbstractString)
    str = String(expr)
    length(str) >= 2 && first(str) == '$' && last(str) == '$' && return LaTeXString(str)
    return LaTeXString("\$" * str * "\$")
end

include("makie_handler.jl")

function glyph_upm(element, family)
    path = element isa TeXLayout.GlyphID ?
        element.font_path :
        TeXLayout._font_path_for_slot(family, element.font_slot)
    return TeXLayout._font_upm(path)
end

@inline rect_points(x1, y1, x2, y2) = CairoMakie.Point2f[
    (x1, y1), (x2, y1), (x2, y2), (x1, y2),
]

function fill_rect!(ax, x1, y1, x2, y2, color)
    xlo, xhi = minmax(x1, x2)
    ylo, yhi = minmax(y1, y2)
    xlo == xhi || ylo == yhi || poly!(ax, rect_points(xlo, ylo, xhi, yhi); color)
    return nothing
end

function rect_outline!(ax, x1, y1, x2, y2; color = OUTLINE, linewidth = 1.2)
    xlo, xhi = minmax(x1, x2)
    ylo, yhi = minmax(y1, y2)
    lines!(
        ax,
        [xlo, xhi, xhi, xlo, xlo],
        [ylo, ylo, yhi, yhi, ylo];
        color,
        linewidth,
    )
    return nothing
end

function hline!(ax, y, x1, x2; color, linewidth = 1.2)
    lines!(ax, [x1, x2], [y, y]; color, linewidth)
    return nothing
end

function vline!(ax, x, y1, y2; color, linewidth = 1.2)
    lines!(ax, [x, x], [y1, y2]; color, linewidth)
    return nothing
end

function main()
    any(arg -> arg in ("-h", "--help"), ARGS) && return usage(stdout)

    expr = length(ARGS) >= 1 ? ARGS[1] : raw"\frac{a}{b}"
    outf = length(ARGS) >= 2 ? ARGS[2] : "visualise_metrics_makie.png"
    family = load_family()

    set_default_font_family!(family)
    latex = wrap_latex(expr)

    mt = TeXLayout.load_math_table(family.math)
    boxes = generate_tex_elements(expr, family)
    isempty(boxes) && @warn "No layout boxes produced for expression: $expr"
    handler_kwargs = makie_handler_kwargs()

    tex_offset = if isempty(handler_kwargs)
        rotation = Makie.to_rotation(0.0f0)
        _, _, offset = Makie.texelems_and_glyph_collection(
            latex,
            Vec2f(BASE_PX),
            (:left, :baseline),
            rotation,
            RGBAf(0, 0, 0, 1),
            RGBAf(0, 0, 0, 0),
            0.0f0,
            -1.0f0,
        )
        offset
    else
        Vec2f(0)
    end

    xmin = xmax = -tex_offset[1]
    ymin = ymax = -tex_offset[2]

    for box in boxes
        elem = box.element
        x0 = box.x * BASE_PX - tex_offset[1]
        y0 = box.y * BASE_PX - tex_offset[2]

        if elem isa TeXLayout.Glyph || elem isa TeXLayout.GlyphID
            s = box.scale * BASE_PX / glyph_upm(elem, family)
            left = elem.x_min * s
            right = elem.x_max * s
            top = elem.y_max * s
            bottom = elem.y_min * s
            adv = elem.advance_width * s
            xmin = min(xmin, x0 + left, x0 + adv)
            xmax = max(xmax, x0 + right, x0 + adv)
            ymin = min(ymin, y0 + bottom)
            ymax = max(ymax, y0 + top)
        elseif elem isa TeXLayout.HRule
            half_t = elem.thickness * BASE_PX / 2
            rule_y = (box.y + elem.thickness / 2) * BASE_PX - tex_offset[2]
            xmin = min(xmin, x0)
            xmax = max(xmax, x0 + elem.width * BASE_PX)
            ymin = min(ymin, rule_y - half_t)
            ymax = max(ymax, rule_y + half_t)
        elseif elem isa TeXLayout.VRule
            half_t = elem.thickness * BASE_PX / 2
            rule_x = (box.x + elem.thickness / 2) * BASE_PX - tex_offset[1]
            xmin = min(xmin, rule_x - half_t)
            xmax = max(xmax, rule_x + half_t)
            ymin = min(ymin, y0)
            ymax = max(ymax, y0 + elem.height * BASE_PX)
        end
    end

    fig = Figure(size = (200, 200), backgroundcolor = :white)
    ax = Axis(fig[1, 1]; aspect = DataAspect(), backgroundcolor = :white)
    CairoMakie.hidespines!(ax)
    CairoMakie.hidedecorations!(ax)

    xlo = xmin - MARGIN
    xhi = xmax + MARGIN
    ylo = ymin - MARGIN
    yhi = ymax + MARGIN

    resize!(fig.scene, round(Int, xhi - xlo), round(Int, yhi - ylo))
    xlims!(ax, xlo, xhi)
    ylims!(ax, ylo, yhi)

    text!(
        ax, 0, 0;
        text = latex,
        handler_kwargs...,
        fontsize = BASE_PX,
        align = (:left, :baseline),
        space = :data,
        markerspace = :data,
    )

    hline!(ax, 0.0, xlo, xhi; color = BASELINE)
    hline!(
        ax,
        mt.constants.axis_height / Float64(mt.upm) * BASE_PX,
        xlo,
        xhi;
        color = AXIS,
    )

    for box in boxes
        elem = box.element
        if elem isa TeXLayout.Glyph || elem isa TeXLayout.GlyphID
            s = box.scale * BASE_PX / glyph_upm(elem, family)
            x0 = box.x * BASE_PX - tex_offset[1]
            y0 = box.y * BASE_PX - tex_offset[2]
            left = elem.x_min * s
            right = elem.x_max * s
            top = elem.y_max * s
            bottom = elem.y_min * s
            adv = elem.advance_width * s
            fill_rect!(ax, x0, y0 + bottom, x0 + left, y0 + top, YELLOW)
            fill_rect!(ax, x0 + right, y0 + bottom, x0 + adv, y0 + top, GREEN)
            fill_rect!(ax, x0 + left, y0, x0 + right, y0 + top, RED)
            fill_rect!(ax, x0 + left, y0 + bottom, x0 + right, y0, BLUE)

            rect_outline!(ax, x0 + left, y0 + bottom, x0 + right, y0 + top)
            vline!(ax, x0, y0 + bottom, y0 + top; color = OUTLINE)
            vline!(ax, x0 + adv, y0 + bottom, y0 + top; color = GREEN)
        end
    end

    save(outf, fig)
    return println(
        "Written $outf  ($(round(Int, xhi - xlo))x$(round(Int, yhi - ylo)) px, " *
            "$(length(boxes)) boxes)"
    )
end

main()
