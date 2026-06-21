# Standalone demo: graphical interpretation of eigenvalues / eigenvectors.
#
# The blue circle is the unit circle.  The red curve is its image under a
# linear transformation A.  A general vector on the unit circle (black dot,
# top) is mapped by A to a vector on the ellipse (black dot, upper right);
# the arrow shows the action of A on that single vector.
#
# Run with the bundled examples environment:
#   julia --project=examples/ examples/eigen_demo.jl [out.png]
#
# This is a standalone scratch demo; not part of the package.

using CairoMakie
using LinearAlgebra
using TeXLayout
using LaTeXStrings

set_default_font_family!(:luciole)

# Transformation matrix — symmetric so the eigenvectors are
# orthogonal and the ellipse axes line up with them.
#   eigenvalues 2 (along [1, 1]) and 1/2 (along [1, -1])
A = [
    1.25 0.75;
    0.75 1.25
]

# Eigen-decomposition: λs are the eigenvalues, columns of V the (unit)
# eigenvectors.  Computed from A so this all updates if you change the matrix.
λs, V = eigen(A)

# Unit circle.
θ = range(0, 2π; length = 400)
circle = [cos.(θ)'; sin.(θ)']          # 2 × N
ellipse = A * circle                    # image under A

# A general sample vector and its image (the arrow in the figure).
v = [0.0, 1.0]
Av = A * v

fig = Figure(; size = (840, 680), backgroundcolor = :white)
ax = Axis(fig[1, 1]; aspect = DataAspect(), backgroundcolor = :white)
TeXLayout.set_default_layout_options!(align = :left, display_align = :center)

# Clean page: hide the default decorations, keep only a light frame.
hidedecorations!(ax)
hidespines!(ax)

lim = 2.4
limits!(ax, -lim, lim + 2, -lim - 0.1, lim)

# Dashed coordinate axes through the origin.
axcol = (:gray40, 0.9)
lines!(ax, [-lim, lim], [0, 0]; color = axcol, linestyle = :dash, linewidth = 1.5)
lines!(ax, [0, 0], [-lim, lim]; color = axcol, linestyle = :dash, linewidth = 1.5)

# Unit circle (blue) and its image (red).
lines!(ax, circle[1, :], circle[2, :]; color = RGBf(0.16, 0.32, 0.66), linewidth = 4)
lines!(ax, ellipse[1, :], ellipse[2, :]; color = RGBf(0.83, 0.18, 0.18), linewidth = 4)

# Eigenvectors: for each, draw the unit eigenvector (lands on the blue circle)
# and its image A·v = λ·v (lands on the red ellipse).  Along an eigen-direction
# the transformation is a pure scaling by λ, so both arrows are collinear and
# the ellipse meets the circle's radial line stretched by exactly λ.
eigcols = [RGBf(0.12, 0.55, 0.27), RGBf(0.55, 0.28, 0.62)]   # one colour per eigenvector
(λs[1] ≈ 0.5 && λs[2] ≈ 2.0) || error("eigenvalues changed to $λs; update the λ labels in the figure")
for i in 1:length(λs)
    vi = V[:, i]
    vi = vi ./ hypot(vi...)             # unit eigenvector
    λ = λs[i]
    col = eigcols[mod1(i, length(eigcols))]

    # Eigen-axis: a thin guide line through the origin along the eigenvector.
    lines!(
        ax, [-λ * vi[1], λ * vi[1]], [-λ * vi[2], λ * vi[2]];
        color = (col, 0.35), linewidth = 1.5
    )

    # Image arrow (origin → λ·v) drawn first so the unit arrow sits on top.
    arrows2d!(
        ax, [0.0], [0.0], [λ * vi[1]], [λ * vi[2]];
        color = col, tipwidth = 13, tiplength = 15, shaftwidth = 3.0
    )
    if i == 1
        text!(
            ax, λ * vi[1], λ * vi[2];
            text = L"\lambda_1 = \tfrac{1}{2}", color = col, align = (:right, :bottom), fontsize = 20, offset = (-4, 0)
        )
    elseif i == 2
        text!(
            ax, λ * vi[1], λ * vi[2];
            text = L"\lambda_2 = 2", color = col, align = (:left, :center), fontsize = 20, offset = (6, 0)
        )
    end
end

# Sample vector and its image: dots + arrow between them.
scatter!(ax, [v[1], Av[1]], [v[2], Av[2]]; color = :black, markersize = 16)
arrows2d!(
    ax, [v[1]], [v[2]], [Av[1] - v[1]], [Av[2] - v[2]],
    color = :black, tipwidth = 8, tiplength = 18, minshaftlength = 0, shaftwidth = 2.5
)
text!(
    ax, (v[1] + Av[1]) / 2, (v[2] + Av[2]) / 2;
    text = L"\begin{bmatrix}x\prime\\y\prime\end{bmatrix} = \begin{bmatrix}\frac{5}{4}&\frac{3}{4}\\\frac{3}{4}&\frac{5}{4}\end{bmatrix}\begin{bmatrix}x\\y\end{bmatrix}",
    color = :black, align = (:right, :bottom), fontsize = 20, offset = (0, 0)
)

text!(
    ax, 1.0, 0.0; offset = (20, -20), fontsize = 16, align = (:left, :top),
    text = latexstring(
        raw"The matrix $A$ can be decomposed as" *
            raw"$$ A = V\thickspace\Lambda\thickspace V^{\thinspace -1},$$" *
            raw"where $V$ is the matrix of \textbf{eigenvectors}" *
            "\\\\" *
            raw"and $\Lambda$ is the diagonal matrix of \textbf{eigenvalues}"
    )
)
text!(
    ax, 0.0, -1.0; offset = (20, -20), fontsize = 16, align = (:left, :top),
    text = latexstring(
        raw"Environments like \emph{align} are also supported:" *
            raw"\begin{align}" *  # Lorenz equations
            raw"\frac{\mathrm{d}x}{\mathrm{d}t} &= \sigma(y-x)\\ " *
            raw"\frac{\mathrm{d}y}{\mathrm{d}t} &= x(\rho-z)-y\\ " *
            raw"\frac{\mathrm{d}z}{\mathrm{d}t} &= xy-\beta z" *
            raw"\end{align}" *
            raw"As are things like $\underbrace{x^2 + y^2 - 2xy\cos(\mathbf{\theta})}_\text{underbraces}$ (and bold greek).")
)

out = isempty(ARGS) ? joinpath(@__DIR__, "eigen_demo.png") : ARGS[1]
save(out, fig)
println("wrote ", out)
