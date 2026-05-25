# Demo: matrix environments rendered via TeXLayout + CairoMakie.
#
#   julia --project=.scratch tools/demo_matrix.jl

using TeXLayout, MathTeXEngine, LaTeXStrings, CairoMakie

fig = Figure(size=(800, 700), backgroundcolor=:white)
ax  = Axis(fig[1,1]; title="TeXLayout.jl — matrix environments")
CairoMakie.hidespines!(ax)
CairoMakie.hidedecorations!(ax)

formulas = [
    (0.5, 0.88, L"R(\theta) = \begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix}"),
    (0.5, 0.64, L"A^{-1} = \frac{1}{\det A} \begin{bmatrix} d & -b \\ -c & a \end{bmatrix}"),
    (0.5, 0.42, L"|x| = \begin{cases} x & x \geq 0 \\ -x & x < 0 \end{cases}"),
    (0.5, 0.18, L"\begin{pmatrix} \lambda_1 & 0 \\ 0 & \lambda_2 \end{pmatrix} \mathbf{v} = A\mathbf{v}"),
]

for (x, y, formula) in formulas
    text!(ax, x, y; text=formula, fontsize=26, align=(:center, :center))
end

xlims!(ax, 0, 1); ylims!(ax, 0, 1)

outpath = joinpath(@__DIR__, "demo_matrix_output.png")
save(outpath, fig)
println("Saved: $outpath")
