
# !!!!!!! WORK IN PROGRESS !!!!!!!

# Singular Value Decomposition — Geometry Visualiser
#
# Visualises the decomposition A = U Σ Vᵀ for the 2×2 matrix
#
#   A = [2  1]
#       [1  3]
#
# Four geometry panels show the sequential geometric action of each factor:
#
#   Panel 1  —  unit circle + right singular vectors v₁, v₂
#   Panel 2  —  after Vᵀ  : rotation that aligns v₁, v₂ with coordinate axes
#   Panel 3  —  after Σ   : axis-aligned scaling by σ₁, σ₂  →  ellipse
#   Panel 4  —  after U   : second rotation into the final orientation = A·x
#
# An equations strip at the bottom carries the matrix forms with actual
# computed values, exercising bmatrix environments, Greek letters, subscripts,
# bold vectors, and nested fractions via TeXLayout.jl.
#
# Setup (first run only):
#   julia --project=examples -e 'using Pkg; Pkg.instantiate()'
#
# Usage:
#   julia --project=examples examples/svd_geometry.jl [output_dir]
#
# Outputs (written to output_dir; default: examples/):
#   svd_geometry.png   (2× pixel density)
#   svd_geometry.svg
#   svd_geometry.pdf

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using CairoMakie
using LaTeXStrings
using LinearAlgebra
using Printf

using TeXLayout   # activates MathTeXEngineExt — LaTeXStrings → TeXLayout renderer

# ── SVD computation ────────────────────────────────────────────────────────────

# A = [2 1; 1 3] is symmetric positive-definite.
# Singular values = eigenvalues = (5 ± √5)/2.
# Since A is symmetric, U = V (up to column signs).
const A_MAT = [2.0 1.0; 1.0 3.0]
const _SVDF = svd(A_MAT)
const U_MAT = _SVDF.U    # left singular vectors  — columns are u₁, u₂
const S_VEC = _SVDF.S    # singular values, descending: [σ₁, σ₂]
const Vt_MAT = _SVDF.Vt   # Vᵀ
const V_MAT = _SVDF.V    # right singular vectors — columns are v₁, v₂

const u1 = U_MAT[:, 1];  const u2 = U_MAT[:, 2]
const v1 = V_MAT[:, 1];  const v2 = V_MAT[:, 2]
const σ1 = S_VEC[1];      const σ2 = S_VEC[2]

# ── Colour palette ─────────────────────────────────────────────────────────────

const C_CIRC = RGBf(0.18, 0.46, 0.71)    # unit circle / ellipse
const C_GRAY = RGBf(0.45, 0.45, 0.45)    # neutral basis / coordinate vectors
const C_V1 = RGBf(0.55, 0.12, 0.65)    # v₁ / σ₁-axis  (purple)
const C_V2 = RGBf(0.1, 0.52, 0.48)    # v₂ / σ₂-axis  (teal)
const C_U1 = RGBf(0.82, 0.15, 0.07)    # u₁             (red)
const C_U2 = RGBf(0.82, 0.44, 0.08)    # u₂             (amber)
const C_GRID = RGBAf(0.78, 0.78, 0.78, 0.45)

# ── Geometry helpers ───────────────────────────────────────────────────────────

function circle_pts(n = 300)
    θ = LinRange(0, 2π, n)
    return cos.(θ), sin.(θ)
end

function ellipse_pts(a, b, n = 300)
    θ = LinRange(0, 2π, n)
    return a .* cos.(θ), b .* sin.(θ)
end

# Apply 2×2 matrix M to a curve given as two coordinate vectors xs, ys.
function apply_mat(M, xs, ys)
    p = M * vcat(xs', ys')
    return vec(p[1, :]), vec(p[2, :])
end

# ── Drawing primitives ─────────────────────────────────────────────────────────

function draw_grid!(ax, xl, yl)
    for xi in ceil(Int, xl[1]):floor(Int, xl[2])
        vlines!(ax, xi; color = C_GRID, linewidth = 0.7)
    end
    for yi in ceil(Int, yl[1]):floor(Int, yl[2])
        hlines!(ax, yi; color = C_GRID, linewidth = 0.7)
    end
    vlines!(ax, 0; color = (:black, 0.35), linewidth = 0.9)
    return hlines!(ax, 0; color = (:black, 0.35), linewidth = 0.9)
end

function vec_arrow!(ax, ox, oy, dx, dy, col; lw = 2.8, as = 15)
    return arrows2d!(
        ax, [ox], [oy], [dx], [dy];
        color = col, shaftwidth = lw,
        tipwidth = 0.85 * as, tiplength = 1.05 * as,
    )
end

function vlabel!(ax, x, y, s, col; fs = 21, ha = :left, va = :bottom)
    return text!(ax, x, y; text = s, color = col, fontsize = fs, align = (ha, va))
end

# Format a scalar for embedding in LaTeX: 3 decimal places, trailing zeros trimmed.
function fmt(x)
    abs(x) < 5.0e-4 && return "0"
    s = @sprintf("%.3f", x)
    s = replace(s, r"(\.\d*?)0+$" => s"\1")
    s = replace(s, r"\.$" => "")
    return s
end

# Build a LaTeX \begin{bmatrix}…\end{bmatrix} snippet for a 2×2 matrix.
function bmat2x2(M)
    r1 = "$(fmt(M[1, 1])) & $(fmt(M[1, 2]))"
    r2 = "$(fmt(M[2, 1])) & $(fmt(M[2, 2]))"
    return "\\begin{bmatrix} $r1 \\\\ $r2 \\end{bmatrix}"
end

# ── Panel 1: original geometry ────────────────────────────────────────────────
#
# Shows the unit circle (the set of all inputs with ||x|| = 1) together with the
# standard basis e₁, e₂ and the right singular vectors v₁, v₂.  The singular
# vectors are the principal input directions of A: they will be scaled by σ₁, σ₂
# and rotated to u₁, u₂ in the output.

function draw_panel1!(ax)
    xl = (-1.78, 1.78)
    yl = (-1.78, 1.78)
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Unit circle
    lines!(ax, circle_pts()...; color = C_CIRC, linewidth = 2.5)

    # Standard basis (thin, gray)
    vec_arrow!(ax, 0, 0, 1, 0, C_GRAY; lw = 1.8, as = 11)
    vec_arrow!(ax, 0, 0, 0, 1, C_GRAY; lw = 1.8, as = 11)
    vlabel!(ax, 1.09, -0.04, L"\mathbf{e}_1", C_GRAY; fs = 18, va = :top)
    vlabel!(ax, -0.07, 1.1, L"\mathbf{e}_2", C_GRAY; fs = 18, ha = :right)

    # Faint dotted lines along the right singular vector directions
    for (v, c) in ((v1, C_V1), (v2, C_V2))
        lines!(
            ax, [-1.6 * v[1], 1.6 * v[1]], [-1.6 * v[2], 1.6 * v[2]];
            color = (c, 0.22), linewidth = 1.0, linestyle = :dot,
        )
    end

    # Right singular vectors (thick, coloured)
    vec_arrow!(ax, 0, 0, v1[1], v1[2], C_V1; lw = 3.2, as = 17)
    vec_arrow!(ax, 0, 0, v2[1], v2[2], C_V2; lw = 3.2, as = 17)

    oy1 = v1[2] >= 0 ? 0.11 : -0.27
    oy2 = v2[2] >= 0 ? 0.11 : -0.27
    vlabel!(ax, v1[1] + 0.09, v1[2] + oy1, L"\mathbf{v}_1", C_V1; fs = 23)
    return vlabel!(ax, v2[1] + 0.09, v2[2] + oy2, L"\mathbf{v}_2", C_V2; fs = 23)
end

# ── Panel 2: after Vᵀ ────────────────────────────────────────────────────────
#
# Vᵀ is orthogonal, so the unit circle is preserved in shape.
# The key effect: Vᵀ v₁ = e₁ and Vᵀ v₂ = e₂ — the principal input directions are
# now aligned with the coordinate axes.  The original basis vectors e₁, e₂ are
# shown rotated to Vᵀ e₁, Vᵀ e₂ (gray, dashed) to emphasise the rotation.

function draw_panel2!(ax)
    xl = (-1.78, 1.78)
    yl = (-1.78, 1.78)
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Unit circle (orthogonal transform preserves it)
    lines!(ax, circle_pts()...; color = C_CIRC, linewidth = 2.5)

    # Images of the original standard basis under Vᵀ: shown faint/smaller
    Vte1 = Vt_MAT * [1.0, 0.0]
    Vte2 = Vt_MAT * [0.0, 1.0]
    vec_arrow!(ax, 0, 0, Vte1[1], Vte1[2], C_GRAY; lw = 1.8, as = 11)
    vec_arrow!(ax, 0, 0, Vte2[1], Vte2[2], C_GRAY; lw = 1.8, as = 11)
    oy_e1 = Vte1[2] >= 0 ? 0.1 : -0.22
    oy_e2 = Vte2[2] >= 0 ? 0.1 : -0.22
    vlabel!(ax, Vte1[1] + 0.07, Vte1[2] + oy_e1, L"V^\top\mathbf{e}_1", C_GRAY; fs = 15)
    vlabel!(ax, Vte2[1] + 0.07, Vte2[2] + oy_e2, L"V^\top\mathbf{e}_2", C_GRAY; fs = 15)

    # Vᵀ v₁ = e₁ and Vᵀ v₂ = e₂: principal axes aligned with coordinate axes
    vec_arrow!(ax, 0, 0, 1, 0, C_V1; lw = 3.2, as = 17)
    vec_arrow!(ax, 0, 0, 0, 1, C_V2; lw = 3.2, as = 17)
    vlabel!(ax, 1.09, -0.04, L"V^\top\mathbf{v}_1", C_V1; fs = 16, va = :top)
    return vlabel!(ax, -0.07, 1.1, L"V^\top\mathbf{v}_2", C_V2; fs = 16, ha = :right)
end

# ── Panel 3: after Σ ──────────────────────────────────────────────────────────
#
# Σ = diag(σ₁, σ₂) independently stretches the two coordinate directions.
# The unit circle is deformed into an axis-aligned ellipse with semiaxes σ₁ and σ₂.
# This is the purely geometric content of the singular values.

function draw_panel3!(ax)
    pad = 0.68
    xl = (-(σ1 + pad), σ1 + pad)
    yl = (-(σ1 + pad), σ1 + pad)   # square domain; ellipse fills horizontally
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Axis-aligned ellipse: semiaxis σ₁ along x, σ₂ along y
    lines!(ax, ellipse_pts(σ1, σ2)...; color = C_CIRC, linewidth = 2.5)

    # Semiaxis arrows
    vec_arrow!(ax, 0, 0, σ1, 0, C_V1; lw = 3.2, as = 17)
    vec_arrow!(ax, 0, 0, 0, σ2, C_V2; lw = 3.2, as = 17)

    # Midpoint labels for σ₁ and σ₂
    vlabel!(ax, σ1 / 2, 0.24, L"\sigma_1", C_V1; fs = 25, ha = :center)
    vlabel!(ax, 0.25, σ2 / 2, L"\sigma_2", C_V2; fs = 25)

    # Dashed tick marks at the ellipse endpoints
    lines!(ax, [σ1, σ1], [0.0, -0.28]; color = (C_V1, 0.6), linewidth = 1.2, linestyle = :dash)
    lines!(ax, [0.0, -0.28], [σ2, σ2]; color = (C_V2, 0.6), linewidth = 1.2, linestyle = :dash)

    # Numerical values at the endpoints.  Use ha = :right so the text grows
    # leftward from the tick position and never overflows the panel edge.
    vlabel!(
        ax, σ1 + 0.05, -0.45,
        latexstring("\\sigma_1 \\approx $(fmt(σ1))"),
        C_V1; fs = 16, ha = :right, va = :top,
    )
    return vlabel!(
        ax, -0.45, σ2,
        latexstring("\\sigma_2 \\approx $(fmt(σ2))"),
        C_V2; fs = 16, ha = :right, va = :center,
    )
end

# ── Panel 4: after U — final transformation ───────────────────────────────────
#
# U rotates the axis-aligned ellipse from Panel 3 into its final orientation.
# The left singular vectors u₁, u₂ lie along the semiaxes of the output ellipse:
#   σ₁ u₁  is the far endpoint of the major semiaxis,
#   σ₂ u₂  is the far endpoint of the minor semiaxis.
# The final ellipse is identical to the image of the unit circle under A.

function draw_panel4!(ax)
    pad = 0.68
    xl = (-(σ1 + pad), σ1 + pad)
    yl = (-(σ1 + pad), σ1 + pad)
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Final ellipse = image of unit circle under A = U Σ Vᵀ
    lines!(ax, apply_mat(A_MAT, circle_pts()...)...; color = C_CIRC, linewidth = 2.5)

    # Scaled left singular vectors (semiaxis endpoints)
    σ1u1 = σ1 .* u1
    σ2u2 = σ2 .* u2
    vec_arrow!(ax, 0, 0, σ1u1[1], σ1u1[2], C_U1; lw = 3.2, as = 17)
    vec_arrow!(ax, 0, 0, σ2u2[1], σ2u2[2], C_U2; lw = 3.2, as = 17)

    # Unit left singular vectors (smaller arrows to show direction)
    vec_arrow!(ax, 0, 0, u1[1], u1[2], C_U1; lw = 2.0, as = 12)
    vec_arrow!(ax, 0, 0, u2[1], u2[2], C_U2; lw = 2.0, as = 12)

    # Label placement strategy: σᵢuᵢ label at the arrow TIP (+ perpendicular),
    # uᵢ label at the arrow MIDPOINT (- perpendicular).  Placing them at different
    # distances from the origin prevents overlap even when σᵢ is close to 1.
    perp1 = [-u1[2], u1[1]] .* 0.42    # left-normal to u1
    perp2 = [-u2[2], u2[1]] .* 0.42    # left-normal to u2
    mid1 = 0.5 .* σ1u1
    mid2 = 0.5 .* σ2u2

    vlabel!(
        ax, σ1u1[1] + perp1[1], σ1u1[2] + perp1[2],
        L"\sigma_1\mathbf{u}_1", C_U1; fs = 19, ha = :left, va = :center,
    )
    vlabel!(
        ax, mid1[1] - perp1[1], mid1[2] - perp1[2],
        L"\mathbf{u}_1", C_U1; fs = 18, ha = :right, va = :center,
    )
    vlabel!(
        ax, σ2u2[1] + perp2[1], σ2u2[2] + perp2[2],
        L"\sigma_2\mathbf{u}_2", C_U2; fs = 19, ha = :left, va = :center,
    )
    return vlabel!(
        ax, mid2[1] - perp2[1], mid2[2] - perp2[2],
        L"\mathbf{u}_2", C_U2; fs = 18, ha = :right, va = :center,
    )
end

# ── Arrow panels between geometry panels ──────────────────────────────────────
#
# Each narrow column between geometry panels holds a horizontal arrow labelled
# with the matrix being applied.  Labels are rendered by TeXLayout.

function draw_arrow_panel!(ax, lbl)
    hidedecorations!(ax)
    hidespines!(ax)
    xlims!(ax, 0, 1)
    ylims!(ax, 0, 1)
    arrows2d!(
        ax, [0.1], [0.5], [0.8], [0.0];
        color = :black, shaftwidth = 2.5, tipwidth = 13, tiplength = 16,
    )
    # Matrix label above the arrow shaft
    return text!(ax, 0.5, 0.7; text = lbl, fontsize = 27, color = :black, align = (:center, :bottom))
    # Subscript reminder below the shaft
end

# ── Equations panel ───────────────────────────────────────────────────────────
#
# Carries the complete mathematical spine of the figure:
#   • main decomposition A = U Σ Vᵀ  (large, centred)
#   • matrix A, U, Σ, Vᵀ with actual computed values
#   • key singular-vector relations
#   • exact closed forms for the singular values
#
# This panel is deliberately notation-dense to stress-test TeXLayout:
# bmatrix environments, Greek letters (Σ, σ, Vᵀ), bold vectors,
# subscripted indices, and \tfrac nested inside text.

function draw_equations_panel!(ax)
    hidedecorations!(ax)
    hidespines!(ax)
    xlims!(ax, 0, 1)
    ylims!(ax, 0, 1)

    # Top and bottom dividers
    hlines!(ax, 0.96; color = (:slategray, 0.3), linewidth = 0.8)
    hlines!(ax, 0.44; color = (:slategray, 0.18), linewidth = 0.6)

    # ── Main decomposition (centred, large) ────────────────────────────────
    # Exercises: \Sigma, V^\top, multi-letter roman names
    text!(
        ax, 0.5, 0.92;
        text = L"A \;=\; U\,\Sigma\,V^\top",
        fontsize = 38, color = :black, align = (:center, :top),
    )

    # ── Matrix A (literal) ─────────────────────────────────────────────────
    # Exercises: \begin{bmatrix} with integer entries
    text!(
        ax, 0.04, 0.73;
        text = L"A = \begin{bmatrix} 2 & 1 \\ 1 & 3 \end{bmatrix}",
        fontsize = 21, color = :black, align = (:left, :top),
    )

    # ── U with computed numerical values ──────────────────────────────────
    # Exercises: \begin{bmatrix} with decimal entries, negative signs
    text!(
        ax, 0.24, 0.73;
        text = latexstring("U = $(bmat2x2(U_MAT))"),
        fontsize = 21, color = :black, align = (:left, :top),
    )

    # ── Σ diagonal matrix with σ₁, σ₂ ────────────────────────────────────
    # Exercises: \Sigma, nested subscripts, zero off-diagonal
    text!(
        ax, 0.52, 0.73;
        text = latexstring(
            "\\Sigma = \\begin{bmatrix} $(fmt(σ1)) & 0 \\\\ 0 & $(fmt(σ2)) \\end{bmatrix}",
        ),
        fontsize = 21, color = :black, align = (:left, :top),
    )

    # ── Vᵀ with computed numerical values ─────────────────────────────────
    # Exercises: V^\top, bmatrix with float entries
    text!(
        ax, 0.74, 0.73;
        text = latexstring("V^\\top = $(bmat2x2(Vt_MAT))"),
        fontsize = 21, color = :black, align = (:left, :top),
    )

    # ── Key singular-vector relations ──────────────────────────────────────
    # Exercises: A, \mathbf{v}_i, \sigma_i, \mathbf{u}_i; A^\top
    text!(
        ax, 0.25, 0.38;
        text = L"A\,\mathbf{v}_i = \sigma_i\,\mathbf{u}_i",
        fontsize = 27, color = :black, align = (:center, :top),
    )
    text!(
        ax, 0.75, 0.38;
        text = L"A^\top\mathbf{u}_i = \sigma_i\,\mathbf{v}_i",
        fontsize = 27, color = :black, align = (:center, :top),
    )

    # ── Exact closed forms for singular values ─────────────────────────────
    # Exercises: \tfrac, \sqrt, \approx, coloured text
    text!(
        ax, 0.25, 0.16;
        text = latexstring(
            "\\sigma_1 = \\tfrac{5+\\sqrt{5}}{2} \\approx $(fmt(σ1))",
        ),
        fontsize = 19, color = C_V1, align = (:center, :top),
    )
    text!(
        ax, 0.75, 0.16;
        text = latexstring(
            "\\sigma_2 = \\tfrac{5-\\sqrt{5}}{2} \\approx $(fmt(σ2))",
        ),
        fontsize = 19, color = C_V2, align = (:center, :top),
    )

    # ── Colour legend for vectors ──────────────────────────────────────────
    # Exercises: \mathbf with subscripts; mixed font sizes in a row
    return text!(
        ax, 0.5, 0.04;
        text = L"\mathbf{v}_1,\,\mathbf{u}_1 \leftrightarrow \sigma_1 \quad\quad \mathbf{v}_2,\,\mathbf{u}_2 \leftrightarrow \sigma_2",
        fontsize = 14, color = (:black, 0.55), align = (:center, :bottom),
    )
end

# ── Figure assembly ────────────────────────────────────────────────────────────

function build_figure()
    fig = Figure(;
        size = (1900, 950),
        backgroundcolor = :white,
        figure_padding = (16, 16, 16, 16),
    )

    # ── Title row ──────────────────────────────────────────────────────────
    # Exercises: \Sigma, \times, \text{}, mixed math/text
    ax_title = Axis(fig[0, 1:7])
    hidedecorations!(ax_title)
    hidespines!(ax_title)
    xlims!(ax_title, 0, 1)
    ylims!(ax_title, 0, 1)
    text!(
        ax_title, 0.5, 0.5;
        text = L"A = U\Sigma V^\top\!:\ \text{Geometry of the Singular Value Decomposition for a }2{\times}2\text{ Matrix}",
        fontsize = 23, color = :black, align = (:center, :center),
    )

    # ── Common axis keyword arguments ──────────────────────────────────────
    # Exercises (axis labels): L"x_1", L"x_2", L"\Sigma V^\top\mathbf{x}", …
    common_kw = (;
        xlabel = L"x_1",
        ylabel = L"x_2",
        xlabelsize = 18,
        ylabelsize = 18,
        xticklabelsize = 13,
        yticklabelsize = 13,
        titlesize = 20,
    )

    # ── Geometry axes (cols 1, 3, 5, 7) ───────────────────────────────────
    # aspect = DataAspect() ensures equal physical x/y scale so that circles
    # render as circles and ellipses have correct proportions.
    ax1 = Axis(
        fig[1, 1];
        title = L"\mathbf{x}\ \text{— input (unit circle)}",
        aspect = DataAspect(),
        common_kw...,
    )
    ax2 = Axis(
        fig[1, 3];
        title = L"V^\top\!\mathbf{x}\ \text{— rotation}",
        aspect = DataAspect(),
        common_kw...,
    )
    ax3 = Axis(
        fig[1, 5];
        title = L"\Sigma V^\top\!\mathbf{x}\ \text{— anisotropic scaling}",
        aspect = DataAspect(),
        common_kw...,
    )
    ax4 = Axis(
        fig[1, 7];
        title = L"U\Sigma V^\top\!\mathbf{x} = A\mathbf{x}\ \text{— rotation}",
        aspect = DataAspect(),
        common_kw...,
    )

    # ── Arrow axes (cols 2, 4, 6) ──────────────────────────────────────────
    ax_a1 = Axis(fig[1, 2])
    ax_a2 = Axis(fig[1, 4])
    ax_a3 = Axis(fig[1, 6])

    colsize!(fig.layout, 2, Fixed(84))
    colsize!(fig.layout, 4, Fixed(84))
    colsize!(fig.layout, 6, Fixed(84))

    # ── Equations axis (row 2, full width) ────────────────────────────────
    ax_eq = Axis(fig[2, 1:7])

    # Row heights
    rowsize!(fig.layout, 0, Fixed(52))
    rowsize!(fig.layout, 2, Fixed(240))

    # Gaps (rowgap index i = gap between the i-th and (i+1)-th row)
    rowgap!(fig.layout, 1, 4)   # between title row (0) and geometry row (1)
    rowgap!(fig.layout, 2, 6)   # between geometry row (1) and equations row (2)
    for c in 1:6
        colgap!(fig.layout, c, 5)
    end

    # ── Populate all panels ────────────────────────────────────────────────
    draw_panel1!(ax1)
    draw_panel2!(ax2)
    draw_panel3!(ax3)
    draw_panel4!(ax4)

    draw_arrow_panel!(ax_a1, L"V^\top")
    draw_arrow_panel!(ax_a2, L"\Sigma")
    draw_arrow_panel!(ax_a3, L"U")

    draw_equations_panel!(ax_eq)

    return fig
end

# ── Main ───────────────────────────────────────────────────────────────────────

function main()
    outdir = length(ARGS) >= 1 ? ARGS[1] : @__DIR__
    isdir(outdir) || mkpath(outdir)

    println("Building figure…")
    fig = build_figure()

    png_path = joinpath(outdir, "svd_geometry.png")
    svg_path = joinpath(outdir, "svd_geometry.svg")
    pdf_path = joinpath(outdir, "svd_geometry.pdf")

    println("Saving PNG…")
    save(png_path, fig; px_per_unit = 2)
    println("Saving SVG…")
    save(svg_path, fig)
    println("Saving PDF…")
    save(pdf_path, fig)

    println("Done.")
    println("  PNG: $png_path")
    println("  SVG: $svg_path")
    return println("  PDF: $pdf_path")
end

main()
