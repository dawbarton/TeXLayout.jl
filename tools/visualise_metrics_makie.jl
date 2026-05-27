# Render a MathTeXEngine-style metric visualisation using CairoMakie.
#
# The expression is drawn via a normal Makie `text!` call on a `LaTeXString`.
# The overlays are computed from the same MathTeXEngine TeXChar/HLine/VLine
# stream that Makie uses internally, so the guides track the rendered glyphs
# rather than an approximate parallel reconstruction.
#   - yellow: origin-to-left-ink gap
#   - green: right-ink-to-advance gap
#   - red:    ink above the baseline
#   - blue:   descender below the baseline
# plus baseline / math-axis guides and per-glyph origin / advance markers.
#
# Usage:
#   julia tools/visualise_metrics_makie.jl "expr" [output.png|output.svg|output.pdf] [:font_symbol|/path/to/font.otf]

using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const EXAMPLES_ENV = joinpath(REPO_ROOT, "examples")

Pkg.activate(EXAMPLES_ENV; io = devnull)
pushfirst!(LOAD_PATH, REPO_ROOT)

using CairoMakie
using LaTeXStrings: LaTeXString
import MathTeXEngine
using TeXLayout

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
    elements = MathTeXEngine.generate_tex_elements(latex)
    isempty(elements) && @warn "No layout boxes produced for expression: $expr"

    rotation = Makie.to_rotation(0.0f0)
    _, _, tex_offset = Makie.texelems_and_glyph_collection(
        latex,
        Vec2f(BASE_PX),
        (:left, :baseline),
        rotation,
        RGBAf(0, 0, 0, 1),
        RGBAf(0, 0, 0, 0),
        0.0f0,
        -1.0f0,
    )

    shift_x = -tex_offset[1]
    shift_y = -tex_offset[2]

    xmin = xmax = shift_x
    ymin = ymax = shift_y

    for (elem, pos, scale) in elements
        x0 = pos[1] * BASE_PX - tex_offset[1]
        y0 = pos[2] * BASE_PX - tex_offset[2]

        if elem isa MathTeXEngine.TeXChar
            s = scale * BASE_PX
            left = MathTeXEngine.leftinkbound(elem) * s
            right = MathTeXEngine.rightinkbound(elem) * s
            top = MathTeXEngine.topinkbound(elem) * s
            bottom = MathTeXEngine.bottominkbound(elem) * s
            adv = MathTeXEngine.hadvance(elem) * s
            xmin = min(xmin, x0 + left, x0 + adv)
            xmax = max(xmax, x0 + right, x0 + adv)
            ymin = min(ymin, y0 + bottom)
            ymax = max(ymax, y0 + top)
        elseif elem isa MathTeXEngine.HLine
            half_t = elem.thickness * scale * BASE_PX / 2
            xmin = min(xmin, x0)
            xmax = max(xmax, x0 + elem.width * scale * BASE_PX)
            ymin = min(ymin, y0 - half_t)
            ymax = max(ymax, y0 + half_t)
        elseif elem isa MathTeXEngine.VLine
            half_t = elem.thickness * scale * BASE_PX / 2
            xmin = min(xmin, x0 - half_t)
            xmax = max(xmax, x0 + half_t)
            ymin = min(ymin, y0)
            ymax = max(ymax, y0 + elem.height * scale * BASE_PX)
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

    for (elem, pos, scale) in elements
        if elem isa MathTeXEngine.TeXChar
            s = scale * BASE_PX
            x0 = pos[1] * BASE_PX - tex_offset[1]
            y0 = pos[2] * BASE_PX - tex_offset[2]
            left = MathTeXEngine.leftinkbound(elem) * s
            right = MathTeXEngine.rightinkbound(elem) * s
            top = MathTeXEngine.topinkbound(elem) * s
            bottom = MathTeXEngine.bottominkbound(elem) * s
            adv = MathTeXEngine.hadvance(elem) * s
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
            "$(length(elements)) boxes)"
    )
end

main()
