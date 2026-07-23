# Render a stress-test sheet for TeXLayout.jl using CairoMakie.
#
# Produces PNG, PDF, or SVG output.  Requires CairoMakie and LaTeXStrings.
# The MathTeXEngineExt extension is activated automatically once TeXLayout,
# CairoMakie, and LaTeXStrings are all in scope.
#
# Layout uses the same per-expression em_bbox measurements as the FreeType
# renderer, so the horizontal arrangement is equivalent.  Positions are in
# pixel units (1 data unit = 1 px) with fontsize = BASE_PX so that 1 em =
# BASE_PX pixels.  Makie y increases upward; screen y increases downward.
#
# Usage:
#   julia tools/stress_test_makie.jl                          # :new_cm → png
#   julia tools/stress_test_makie.jl :pagella                 # Pagella → png
#   julia tools/stress_test_makie.jl :stix_two pdf            # PDF
#   julia tools/stress_test_makie.jl /path/Math.otf svg       # SVG

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using TeXLayout: FontFamily, Glyph, HRule, Space, VRule, layout, parse_latex
using FreeTypeAbstraction
using CairoMakie
using LaTeXStrings

const BASE_PX = 90    # pixels per em for math content
const MARGIN = 14     # canvas border in pixels
const EXPR_GAP = 30   # horizontal gap between side-by-side expressions (px)
const ROW_GAP = 8     # vertical gap between strips (px)
const SEC_H = 22      # section-header strip height (px)
const TITLE_H = 30    # title-bar strip height (px)
const SEC_PX = 13     # font size for section-header text
const TITLE_PX = 16   # font size for title text

# ── Bounding box ───────────────────────────────────────────────────────────────

# Compute bounding box in em units, matching Makie's height_insensitive_boundingbox_with_advance.
#
# Makie gives every glyph a fixed-height bounding box of [font_descender, font_ascender]
# (or the glyph's actual ink extent if that is more extreme).  Using just the ink extents
# (as a naive implementation would) causes row heights to be underestimated and formulae
# to be shifted well above the section header above them.  font_ascender and font_descender
# must be in em units (as returned by FreeTypeAbstraction.ascender/descender).
function em_bbox(boxes, upm, font_ascender::Float64, font_descender::Float64; pad = 0.1)
    bx1 = bx2 = by1 = by2 = 0.0
    has_glyph = false
    for box in boxes
        el = box.element
        if el isa Glyph
            has_glyph = true
            s = box.scale / upm
            bx1 = min(bx1, box.x + el.x_min * s)
            bx2 = max(bx2, box.x + el.x_max * s)
            # Per-glyph vertical extent: clamp to font-level bounds so we match what
            # Makie's GlyphExtent will report for this glyph.
            y_min_em = min(font_descender, Float64(el.y_min) / upm) * box.scale
            y_max_em = max(font_ascender, Float64(el.y_max) / upm) * box.scale
            by1 = min(by1, box.y + y_min_em)
            by2 = max(by2, box.y + y_max_em)
        elseif el isa HRule
            bx1 = min(bx1, box.x); bx2 = max(bx2, box.x + el.width)
            by1 = min(by1, box.y); by2 = max(by2, box.y + el.thickness)
        elseif el isa VRule
            bx1 = min(bx1, box.x); bx2 = max(bx2, box.x + el.thickness)
            by1 = min(by1, box.y); by2 = max(by2, box.y + el.height)
        elseif el isa Space
            bx1 = min(bx1, box.x, box.x + el.width)
            bx2 = max(bx2, box.x, box.x + el.width)
        end
    end
    # Fallback for formulas with no glyphs (rules only): use font-level bounds.
    if !has_glyph
        by1 = min(by1, font_descender)
        by2 = max(by2, font_ascender)
    end
    return (bx1 - pad, bx2 + pad, by1 - pad, by2 + pad)
end

# ── Stress-test content ────────────────────────────────────────────────────────

include("stress_test_content.jl")

# ── CairoMakie renderer ────────────────────────────────────────────────────────

function run_stress_test_makie(
        family::FontFamily, outpath::String,
        mt, font_name::String,
    )
    set_default_font_family!(family)
    upm = mt.upm
    face_math = FTFont(family.math)
    font_ascender = Float64(FreeTypeAbstraction.ascender(face_math))
    font_descender = Float64(FreeTypeAbstraction.descender(face_math))

    # ── Layout pass: compute per-row geometry ─────────────────────────────────
    # For each section, compute expression bboxes, pen x positions (pixels),
    # and row height; accumulate the maximum row width.
    #
    # Bounding boxes use font-level vertical extents (matching Makie's
    # height_insensitive_boundingbox_with_advance) so that row heights and
    # rendering positions are consistent with what Makie will actually draw.

    struct_rows = []    # (sec_title, items_data, pens_px, above_px, below_px, row_h_px)
    max_row_w = 0

    for (sec_title, items) in STRESS_SECTIONS
        above_px = 0   # max extent above baseline in this row (pixels)
        below_px = 0   # max extent below baseline (pixels)
        items_data = []

        for (style, expr) in items
            fa_default = max(font_ascender, 0.35)
            fd_default = min(font_descender, -0.15)
            bounds, renderable = try
                boxes = layout(parse_latex(expr), family, style)
                bounds = isempty(boxes) ?
                    (0.0, 1.0, fd_default, fa_default) :
                    em_bbox(boxes, upm, font_ascender, font_descender; pad = 0.05)
                (bounds, any(box -> !(box.element isa Space), boxes))
            catch
                ((0.0, 1.0, fd_default, fa_default), false)
            end
            bx1, bx2, by1, by2 = bounds
            above_px = max(above_px, round(Int, by2 * BASE_PX))
            below_px = max(below_px, round(Int, -by1 * BASE_PX))
            push!(items_data, (style, expr, bx1, bx2, by1, by2, renderable))
        end

        # Leftmost ink of expression 0 is placed at MARGIN pixels;
        # subsequent expressions follow with EXPR_GAP between ink regions.
        x_ink_left = MARGIN
        pens_px = Int[]
        for (_, _, bx1, bx2, _, _, _) in items_data
            push!(pens_px, x_ink_left - round(Int, bx1 * BASE_PX))
            x_ink_left += round(Int, (bx2 - bx1) * BASE_PX) + EXPR_GAP
        end

        row_w = x_ink_left - EXPR_GAP + MARGIN
        max_row_w = max(max_row_w, row_w)
        row_h_px = above_px + below_px + 2 * MARGIN

        push!(
            struct_rows,
            (sec_title, items_data, pens_px, above_px, below_px, row_h_px),
        )
    end

    # ── Total figure dimensions (pixels) ─────────────────────────────────────
    W = max(700, max_row_w)
    H = TITLE_H + ROW_GAP
    for (_, _, _, _, _, row_h_px) in struct_rows
        H += SEC_H + row_h_px + ROW_GAP
    end
    H += 4  # bottom bar

    # ── Figure setup ──────────────────────────────────────────────────────────
    fig = CairoMakie.Figure(size = (W, H), backgroundcolor = :white)
    ax = CairoMakie.Axis(
        fig[1, 1]; aspect = CairoMakie.DataAspect(), backgroundcolor = :white,
    )
    CairoMakie.hidespines!(ax)
    CairoMakie.hidedecorations!(ax)
    CairoMakie.xlims!(ax, 0, W)
    CairoMakie.ylims!(ax, 0, H)
    CairoMakie.resize!(fig.scene, W, H)

    # Helpers: rectangle as Point2f polygon; Makie y from screen y.
    _rect(x, y_screen_top, w, h) = CairoMakie.Point2f[
        CairoMakie.Point2f(x, H - y_screen_top - h),
        CairoMakie.Point2f(x + w, H - y_screen_top - h),
        CairoMakie.Point2f(x + w, H - y_screen_top),
        CairoMakie.Point2f(x, H - y_screen_top),
    ]
    my(y_screen) = H - y_screen  # screen y (top=0) → Makie y (bottom=0)

    # ── Draw title bar ────────────────────────────────────────────────────────
    title_str = "TeXLayout.jl  STRESS TEST  —  $(uppercase(font_name))"
    CairoMakie.poly!(ax, _rect(0, 0, W, TITLE_H); color = CairoMakie.RGBf(0.1, 0.1, 0.1))
    CairoMakie.text!(
        ax, MARGIN, my(TITLE_H ÷ 2);
        text = title_str,
        fontsize = TITLE_PX, color = :white,
        align = (:left, :center),
        space = :data, markerspace = :data,
    )
    y_screen = TITLE_H + ROW_GAP   # running screen y (increases downward)

    # ── Draw sections ─────────────────────────────────────────────────────────
    for (sec_title, items_data, pens_px, above_px, below_px, row_h_px) in struct_rows
        # Section header strip
        CairoMakie.poly!(
            ax, _rect(0, y_screen, W, SEC_H);
            color = CairoMakie.RGBf(0.27, 0.27, 0.27),
        )
        CairoMakie.text!(
            ax, MARGIN, my(y_screen + SEC_H ÷ 2);
            text = sec_title,
            fontsize = SEC_PX, color = :white,
            align = (:left, :center),
            space = :data, markerspace = :data,
        )
        y_screen += SEC_H

        # Expression row — intended baseline is `above_px` below the row top plus MARGIN.
        #
        # Makie's text! with align=(:left,:bottom) places the formula's bounding-box
        # bottom at the given y coordinate.  The bounding-box bottom is `below_px_i`
        # pixels below the mathematical baseline.  To put the baseline at the intended
        # screen y, we lower the anchor by `below_px_i` for each expression.

        for ((style, expr, _, _, by1_i, _, renderable), pen_x) in zip(items_data, pens_px)
            renderable || continue
            below_px_i = round(Int, -by1_i * BASE_PX)
            y_anchor = my(y_screen + MARGIN + above_px + below_px_i)
            try
                CairoMakie.text!(
                    ax, pen_x, y_anchor;
                    text = LaTeXStrings.LaTeXString("\$" * expr * "\$"),
                    fontsize = BASE_PX,
                    align = (:left, :bottom),
                    space = :data, markerspace = :data,
                )
            catch e
                @warn "Makie render failed for $(repr(expr)): $e"
            end
        end

        y_screen += row_h_px + ROW_GAP
    end

    # Bottom bar
    CairoMakie.poly!(ax, _rect(0, y_screen, W, 4); color = CairoMakie.RGBf(0.1, 0.1, 0.1))

    CairoMakie.save(outpath, fig; pt_per_unit = 1)
    return println("Written $outpath  ($(W)×$(H) px)")
end

# ── Font helpers ───────────────────────────────────────────────────────────────

function _resolve_font(spec)::FontFamily
    spec isa FontFamily && return spec
    s = string(spec)
    startswith(s, ":") && return font_family(Symbol(s[2:end]))
    isfile(s) && return FontFamily(s)
    return font_family(Symbol(s))
end

function _default_output(font_name::String, format::Symbol)::String
    slug = lowercase(replace(font_name, r"[^a-zA-Z0-9]+" => "_"))
    slug = strip(slug, '_')
    return "stress_test_$(slug).$(format)"
end

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _format = Symbol(length(ARGS) >= 2 ? ARGS[2] : "png")
    _output = length(ARGS) >= 3 ? ARGS[3] : nothing

    _format in (:png, :pdf, :svg) ||
        error("Unknown format $(repr(_format)). Choose: png, pdf, svg")

    family = _resolve_font(_font_spec)
    mt = TeXLayout.load_math_table(family.math)
    face_math = FTFont(family.math)
    font_name = FreeTypeAbstraction.family_name(face_math)
    outpath = _output !== nothing ? String(_output) :
        _default_output(font_name, _format)

    run_stress_test_makie(family, outpath, mt, font_name)
end
