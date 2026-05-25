# Demo: unified text and math fonts in a Makie figure.
#
# TeXLayout's default font family is New Computer Modern.  This script
# loads the same font files and passes them to Makie's set_theme! so that
# axis labels, tick labels, and titles share the same typeface as the
# OpenType math rendering.
#
#   julia --project=.scratch tools/demo_unified_fonts.jl

using TeXLayout, CairoMakie, LaTeXStrings

# Load the font family used by TeXLayout's Makie extension (default = :new_cm).
ff = default_font_family()

# Teach Makie to use the same text fonts.  The :bolditalic key matches
# Makie's theme convention (FontFamily.bold_italic → theme :bolditalic).
set_theme!(fonts = (;
    regular     = ff.regular,
    bold        = ff.bold,
    italic      = ff.italic,
    bolditalic  = ff.bold_italic,
))

# ── Build figure ──────────────────────────────────────────────────────────────

fig = Figure(size = (800, 500), backgroundcolor = :white)

ax = Axis(fig[1, 1];
    title  = "New Computer Modern — text and math in the same typeface",
    xlabel = L"x",
    ylabel = L"f(x)",
)

x = LinRange(0, 2π, 400)

lines!(ax, x, sin.(x);            label = L"\sin(x)")
lines!(ax, x, cos.(x);            label = L"\cos(x)")
lines!(ax, x, exp.(-x/4).*sin.(3x); label = L"e^{-x/4}\sin(3x)")

axislegend(ax; position = :rt)

outpath = joinpath(@__DIR__, "demo_unified_fonts_output.png")
save(outpath, fig)
println("Saved: $outpath")
