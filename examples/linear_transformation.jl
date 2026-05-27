# Pedagogic Linear Transformation Visualiser
#
# Demonstrates the geometric meaning of eigendecomposition for a 2×2 symmetric
# positive-definite matrix:
#
#   A = [2  1]
#       [1  3]
#
# Layout: two geometry panels separated by a centre column that acts as the
# mathematical spine of the figure.  All LaTeX notation is rendered by
# TeXLayout.jl via the MathTeXEngine extension.
#
# Setup (first run only):
#   julia --project=examples -e 'using Pkg; Pkg.instantiate()'
#
# Usage:
#   julia --project=examples examples/linear_transformation.jl [output_dir]
#
# Outputs (default output_dir: examples/):
#   linear_transformation.png  (2× pixel density)
#   linear_transformation.svg
#   linear_transformation.pdf

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using CairoMakie
using LaTeXStrings
using LinearAlgebra

using TeXLayout   # activates MathTeXEngineExt — LaTeXStrings → TeXLayout renderer

# ── Matrix and eigendecomposition ─────────────────────────────────────────────

# Characteristic polynomial: λ² − 5λ + 5 = 0  →  λ = (5 ± √5)/2
const A_MAT = [2.0 1.0; 1.0 3.0]
const X_VEC = [1.2, 0.8]   # arbitrary demonstration vector

const _F = eigen(Symmetric(A_MAT))
const Λ_ALL = _F.values    # ascending: λ₁ < λ₂
const Q_MAT = _F.vectors   # columns: orthonormal eigenvectors
const V1 = Q_MAT[:, 1]
const V2 = Q_MAT[:, 2]
const Λ1 = Λ_ALL[1]
const Λ2 = Λ_ALL[2]
const AX = A_MAT * X_VEC

# ── Colour palette ─────────────────────────────────────────────────────────────

const C_BLUE = RGBf(0.18, 0.46, 0.71)    # unit circle / image ellipse
const C_AMBER = RGBf(0.85, 0.48, 0.08)   # unit square / image parallelogram
const C_GREEN = RGBf(0.18, 0.54, 0.18)   # vector x / Ax
const C_GRAY = RGBf(0.42, 0.42, 0.42)    # basis vectors e₁, e₂
const C_PURPLE = RGBf(0.6, 0.14, 0.7)    # eigenvector v₁ / λ₁
const C_TEAL = RGBf(0.1, 0.58, 0.56)     # eigenvector v₂ / λ₂
const C_GRID = RGBAf(0.8, 0.8, 0.8, 0.5)

# ── Geometry helpers ───────────────────────────────────────────────────────────

function unit_circle_pts(n = 300)
    θ = LinRange(0, 2π, n)
    return cos.(θ), sin.(θ)
end

function unit_square_pts()
    return [0.0, 1.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 1.0, 0.0]
end

function transform(xs, ys)
    pts = A_MAT * vcat(xs', ys')
    return vec(pts[1, :]), vec(pts[2, :])
end

# ── Drawing primitives ─────────────────────────────────────────────────────────

function draw_grid!(ax, xl, yl)
    for xi in ceil(Int, xl[1]):floor(Int, xl[2])
        vlines!(ax, xi; color = C_GRID, linewidth = 0.8)
    end
    for yi in ceil(Int, yl[1]):floor(Int, yl[2])
        hlines!(ax, yi; color = C_GRID, linewidth = 0.8)
    end
    vlines!(ax, 0; color = (:black, 0.5), linewidth = 1.0)
    return hlines!(ax, 0; color = (:black, 0.5), linewidth = 1.0)
end

function vec_arrow!(ax, ox, oy, dx, dy, col; lw = 3.0, as = 16)
    return arrows2d!(
        ax, [ox], [oy], [dx], [dy];
        color = col, shaftwidth = lw,
        tipwidth = 0.9 * as, tiplength = 1.1 * as,
    )
end

function vlabel!(ax, x, y, s, col; fs = 22, ha = :left, va = :bottom)
    return text!(ax, x, y; text = s, color = col, fontsize = fs, align = (ha, va))
end

# ── Original Space panel ───────────────────────────────────────────────────────

function draw_original!(ax)
    xl = (-2.2, 2.2)
    yl = (-1.9, 2.8)
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Unit circle
    lines!(ax, unit_circle_pts()...; color = C_BLUE, linewidth = 2.5)

    # Unit square (dashed)
    lines!(ax, unit_square_pts()...; color = C_AMBER, linewidth = 2.5, linestyle = :dash)

    # Basis vectors e₁, e₂
    vec_arrow!(ax, 0, 0, 1, 0, C_GRAY)
    vec_arrow!(ax, 0, 0, 0, 1, C_GRAY)
    vlabel!(ax, 1.09, -0.06, L"\mathbf{e}_1", C_GRAY; fs = 23, va = :top)
    vlabel!(ax, -0.08, 1.11, L"\mathbf{e}_2", C_GRAY; fs = 23, ha = :right)

    # Vector x
    vec_arrow!(ax, 0, 0, X_VEC[1], X_VEC[2], C_GREEN)
    vlabel!(ax, X_VEC[1] + 0.1, X_VEC[2] + 0.1, L"\mathbf{x}", C_GREEN; fs = 28, ha = :left, va = :bottom)

    # Eigenlines (faint dotted)
    for (v, c) in ((V1, C_PURPLE), (V2, C_TEAL))
        lines!(
            ax, [-1.8 * v[1], 1.8 * v[1]], [-1.8 * v[2], 1.8 * v[2]];
            color = (c, 0.25), linewidth = 1.1, linestyle = :dot
        )
    end

    # Eigenvectors
    vec_arrow!(ax, 0, 0, V1[1], V1[2], C_PURPLE; lw = 3.5, as = 17)
    vec_arrow!(ax, 0, 0, V2[1], V2[2], C_TEAL; lw = 3.5, as = 17)

    oy1 = V1[2] >= 0 ? 0.14 : -0.26
    # Offset v₂ above the unit-square top edge
    oy2 = V2[2] >= 0 ? 0.2 : -0.26
    vlabel!(ax, V1[1] + 0.1, V1[2] + oy1, L"\mathbf{v}_1", C_PURPLE; fs = 22)
    return vlabel!(ax, V2[1] + 0.11, V2[2] + oy2, L"\mathbf{v}_2", C_TEAL; fs = 22)
end

# ── Transformed Space panel ────────────────────────────────────────────────────

function draw_transformed!(ax)
    xl = (-2.0, 6.2)
    yl = (-2.5, 7.0)
    xlims!(ax, xl...)
    ylims!(ax, yl...)
    draw_grid!(ax, xl, yl)

    # Transformed circle → ellipse
    lines!(ax, transform(unit_circle_pts()...)...; color = C_BLUE, linewidth = 2.5)

    # Transformed square → parallelogram
    lines!(
        ax, transform(unit_square_pts()...)...;
        color = C_AMBER, linewidth = 2.5, linestyle = :dash
    )

    # Transformed basis vectors
    Ae1 = A_MAT * [1.0, 0.0]
    Ae2 = A_MAT * [0.0, 1.0]
    vec_arrow!(ax, 0, 0, Ae1[1], Ae1[2], C_GRAY)
    vec_arrow!(ax, 0, 0, Ae2[1], Ae2[2], C_GRAY)
    vlabel!(
        ax, Ae1[1] + 0.2, Ae1[2] - 0.24,
        L"A\mathbf{e}_1", C_GRAY; fs = 23, va = :top
    )
    vlabel!(
        ax, Ae2[1] - 0.32, Ae2[2] + 0.24,
        L"A\mathbf{e}_2", C_GRAY; fs = 23
    )

    # Transformed vector Ax
    vec_arrow!(ax, 0, 0, AX[1], AX[2], C_GREEN)
    vlabel!(ax, AX[1] + 0.16, AX[2] + 0.16, L"A\mathbf{x}", C_GREEN; fs = 28)

    # Eigenlines (faint dotted)
    for (v, c) in ((V1, C_PURPLE), (V2, C_TEAL))
        lines!(
            ax, [-2.5 * v[1], 5.5 * v[1]], [-2.5 * v[2], 5.5 * v[2]];
            color = (c, 0.25), linewidth = 1.1, linestyle = :dot
        )
    end

    # Unit eigenvectors (thin — same direction before scaling)
    vec_arrow!(ax, 0, 0, V1[1], V1[2], C_PURPLE; lw = 1.8, as = 10)
    vec_arrow!(ax, 0, 0, V2[1], V2[2], C_TEAL; lw = 1.8, as = 10)

    # Scaled eigenvectors λᵢvᵢ = Avᵢ
    lv1 = Λ1 * V1
    lv2 = Λ2 * V2
    vec_arrow!(ax, 0, 0, lv1[1], lv1[2], C_PURPLE; lw = 3.5, as = 17)
    vec_arrow!(ax, 0, 0, lv2[1], lv2[2], C_TEAL; lw = 3.5, as = 17)

    oy1 = lv1[2] >= 0 ? 0.22 : -0.35
    oy2 = lv2[2] >= 0 ? 0.22 : -0.35
    vlabel!(
        ax, lv1[1] + 0.16, lv1[2] + oy1,
        L"\lambda_1\mathbf{v}_1", C_PURPLE; fs = 22
    )
    return vlabel!(
        ax, lv2[1] + 0.16, lv2[2] + oy2,
        L"\lambda_2\mathbf{v}_2", C_TEAL; fs = 22
    )
end

# ── Centre panel: transformation arrow + mathematical spine ───────────────────
#
# This column sits between the two geometry panels and serves as the unified
# mathematical commentary for the figure.  Using the same white background as
# the panels avoids the disjoint-section feel of a separate caption strip.

function draw_centre_panel!(ax)
    hidedecorations!(ax)
    hidespines!(ax)
    xlims!(ax, 0, 1)
    ylims!(ax, 0, 1)

    # ── Transformation arrow ───────────────────────────────────────────────
    arrows2d!(
        ax, [0.08], [0.935], [0.84], [0.0];
        color = :black, shaftwidth = 2.2, tipwidth = 11, tiplength = 14,
    )
    # "A" above the arrow shaft, "x ↦ Ax" below
    text!(
        ax, 0.5, 0.975;
        text = L"A",
        fontsize = 30, color = :black, align = (:center, :bottom)
    )
    text!(
        ax, 0.5, 0.896;
        text = L"\mathbf{x} \mapsto A\mathbf{x}",
        fontsize = 16, color = (:black, 0.6), align = (:center, :top)
    )

    # Faint divider beneath the arrow group
    hlines!(ax, 0.855; color = (:slategray, 0.28), linewidth = 0.8)

    # ── Matrix definition ──────────────────────────────────────────────────
    # Exercises: \begin{bmatrix}, integer entries
    text!(
        ax, 0.5, 0.835;
        text = L"A = \begin{bmatrix} 2 & 1 \\ 1 & 3 \end{bmatrix}",
        fontsize = 27, color = :black, align = (:center, :top)
    )

    # ── Eigendecomposition ─────────────────────────────────────────────────
    # Exercises: Q^{-1}, \Lambda
    text!(
        ax, 0.5, 0.6;
        text = L"A = Q\Lambda Q^{-1}",
        fontsize = 31, color = :black, align = (:center, :top)
    )

    # ── Core eigenvalue relation ───────────────────────────────────────────
    # Exercises: \mathbf, subscripts, \lambda
    text!(
        ax, 0.5, 0.485;
        text = L"A\mathbf{v}_i = \lambda_i\mathbf{v}_i",
        fontsize = 28, color = :black, align = (:center, :top)
    )

    # ── Eigenvector matrix Q ───────────────────────────────────────────────
    # Exercises: \mathbf column vectors inside bmatrix
    text!(
        ax, 0.5, 0.365;
        text = L"Q = \begin{bmatrix} \mathbf{v}_1 & \mathbf{v}_2 \end{bmatrix}",
        fontsize = 22, color = :black, align = (:center, :top)
    )

    # ── Eigenvalue matrix Λ ────────────────────────────────────────────────
    # Exercises: nested subscripts inside bmatrix
    text!(
        ax, 0.5, 0.225;
        text = L"\Lambda = \begin{bmatrix} \lambda_1 & 0 \\ 0 & \lambda_2 \end{bmatrix}",
        fontsize = 22, color = :black, align = (:center, :top)
    )

    # ── Eigenbasis expansion ───────────────────────────────────────────────
    # Exercises: c_1, c_2 scalar coefficients, bold vectors, +
    return text!(
        ax, 0.5, 0.06;
        text = L"\mathbf{x} = c_1\mathbf{v}_1 + c_2\mathbf{v}_2",
        fontsize = 21, color = (:black, 0.82), align = (:center, :top)
    )
end

# ── Figure assembly ────────────────────────────────────────────────────────────

function build_figure()
    fig = Figure(;
        size = (1580, 860),
        backgroundcolor = :white,
        figure_padding = (14, 14, 14, 14),
    )

    # ── Title row (row 0) ──────────────────────────────────────────────────
    # Use a hidden Axis with text! so the LaTeXString goes through TeXLayout.
    ax_title = Axis(fig[0, 1:3])
    hidedecorations!(ax_title)
    hidespines!(ax_title)
    xlims!(ax_title, 0, 1)
    ylims!(ax_title, 0, 1)
    text!(
        ax_title, 0.5, 0.5;
        text = L"A = Q\Lambda Q^{-1}: \text{ Eigendecomposition of a } 2{\times}2 \text{ Matrix}",
        fontsize = 22, color = :black, align = (:center, :center),
    )

    # ── Left panel: Original Space ─────────────────────────────────────────
    ax_orig = Axis(
        fig[1, 1];
        title = L"\text{Original Space: } \mathbf{x}",
        xlabel = L"x_1", ylabel = L"x_2",
        titlesize = 28, xlabelsize = 22, ylabelsize = 22,
        xticklabelsize = 16, yticklabelsize = 16,
    )

    # ── Centre column: mathematical spine ─────────────────────────────────
    ax_centre = Axis(fig[1, 2])
    colsize!(fig.layout, 2, Fixed(360))

    # ── Right panel: Transformed Space ────────────────────────────────────
    ax_trans = Axis(
        fig[1, 3];
        title = L"\text{Transformed Space: } A\mathbf{x}",
        xlabel = L"x_1", ylabel = L"x_2",
        titlesize = 28, xlabelsize = 22, ylabelsize = 22,
        xticklabelsize = 16, yticklabelsize = 16,
    )

    # ── Proportions ────────────────────────────────────────────────────────
    rowsize!(fig.layout, 0, Fixed(42))
    rowgap!(fig.layout, 1, 4)
    colgap!(fig.layout, 1, 4)
    colgap!(fig.layout, 2, 4)

    # ── Populate ───────────────────────────────────────────────────────────
    draw_original!(ax_orig)
    draw_transformed!(ax_trans)
    draw_centre_panel!(ax_centre)

    return fig
end

# ── Optional colour-coded legend ───────────────────────────────────────────────
#
# draw_legend!(ax) can replace draw_centre_panel! if a visual legend is
# preferred over the equation spine.  It exercises additional TeXLayout
# features: \text{}, \to, \mathbf, inline-label alignment.
#
#   ax_centre = Axis(fig[1, 2])
#   colsize!(fig.layout, 2, Fixed(360))
#   draw_legend!(ax_centre)

function draw_legend!(ax)
    hidedecorations!(ax)
    hidespines!(ax)
    xlims!(ax, 0, 1)
    ylims!(ax, 0, 1)
    items = [
        (C_BLUE, :solid, L"\text{unit circle} \to \text{ellipse}"),
        (C_AMBER, :dash, L"\text{unit square} \to \text{parallelogram}"),
        (C_GRAY, :solid, L"\text{basis vectors } \mathbf{e}_i \to A\mathbf{e}_i"),
        (C_GREEN, :solid, L"\text{vector } \mathbf{x} \to A\mathbf{x}"),
        (C_PURPLE, :solid, L"\text{eigenvector } \mathbf{v}_1 \text{ (scaled by } \lambda_1 \text{)}"),
        (C_TEAL, :solid, L"\text{eigenvector } \mathbf{v}_2 \text{ (scaled by } \lambda_2 \text{)}"),
    ]
    n = length(items)
    for (i, (col, ls, label)) in enumerate(items)
        y = 1.0 - i / (n + 1)
        lines!(ax, [0.03, 0.12], [y, y]; color = col, linewidth = 2.5, linestyle = ls)
        text!(
            ax, 0.15, y; text = label,
            fontsize = 15, color = :black, align = (:left, :center)
        )
    end
    return
end

# ── Main ───────────────────────────────────────────────────────────────────────

function main()
    outdir = length(ARGS) >= 1 ? ARGS[1] : @__DIR__
    isdir(outdir) || mkpath(outdir)

    println("Building figure…")
    fig = build_figure()

    png_path = joinpath(outdir, "linear_transformation.png")
    svg_path = joinpath(outdir, "linear_transformation.svg")
    pdf_path = joinpath(outdir, "linear_transformation.pdf")

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
