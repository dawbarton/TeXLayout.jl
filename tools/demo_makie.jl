# Demo: TeXLayout.jl as a drop-in replacement for MathTeXEngine in CairoMakie.
#
# Run from the TeXLayout.jl directory with an environment that has
# CairoMakie and MathTeXEngine available:
#
#   julia --project -e 'using Pkg; Pkg.add(["CairoMakie", "LaTeXStrings"])' 2>/dev/null
#   julia --project tools/demo_makie.jl

using TeXLayout        # triggers MathTeXEngineExt when MathTeXEngine is loaded
using MathTeXEngine
using LaTeXStrings
using CairoMakie

println("TeXLayout v$(pkgversion(TeXLayout)) — MathTeXEngineExt demo")
println("Extension loaded: MathTeXEngineExt ∈ keys(Base.loaded_modules)")

# ── Smoke test: generate_tex_elements returns MTE-compatible tuples ───────────
elems     = MathTeXEngine.generate_tex_elements(L"\frac{x^2 + 1}{2}")
tex_chars = filter(t -> t[1] isa MathTeXEngine.TeXChar, elems)
hlines    = filter(t -> t[1] isa MathTeXEngine.HLine, elems)
println("\\frac{x^2+1}{2}: $(length(tex_chars)) chars, $(length(hlines)) rules")
@assert length(tex_chars) > 0 "Expected at least one TeXChar"
@assert length(hlines)    > 0 "Expected at least one HLine (fraction bar)"

# ── Render a figure with several LaTeX formulae ───────────────────────────────
fig = Figure(size=(800, 600), backgroundcolor=:white)
ax  = Axis(fig[1,1]; title="TeXLayout.jl — Makie integration")
CairoMakie.hidespines!(ax)
CairoMakie.hidedecorations!(ax)

formulas = [
    (0.5, 0.85, L"\frac{x^2 + 1}{2\pi}"),
    (0.5, 0.65, L"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}"),
    (0.5, 0.45, L"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"),
    (0.5, 0.25, L"\sqrt{a^2 + b^2}"),
    (0.5, 0.08, L"\alpha + \beta = \gamma"),
]

for (x, y, formula) in formulas
    text!(ax, x, y; text=formula, fontsize=28, align=(:center, :center))
end

xlims!(ax, 0, 1)
ylims!(ax, 0, 1)

outpath = joinpath(@__DIR__, "demo_makie_output.png")
save(outpath, fig)
println("Saved: $outpath")
