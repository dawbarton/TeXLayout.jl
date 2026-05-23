# Render demonstration panels for newly implemented Formatic.jl features.
#
# Generates three PNG files (one per feature group) in the directory given
# as the first argument (default: current directory):
#   accents.png         — Rule 12: \hat, \bar, \vec, \tilde, \dot, \ddot, \acute, \grave
#   overunder.png       — Rules 9 & 10: \overline and \underline
#   binary_reclass.png  — Rules 5 & 6: mbin → mord reclassification
#
# Each PNG is a column of rendered expressions at 120 px/em with captions
# drawn using the system monospace font (via FreeType) and light reference
# lines for the baseline and math axis.
#
# Usage:  julia tools/demo_features.jl [output_dir]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using Formatic
using FreeTypeAbstraction

const BASE_PX   = 120   # pixels per em for math content
const MARGIN    = 16    # outer border in pixels
const ROW_GAP   = 14    # vertical gap between rows in pixels
const CAP_H     = 18    # caption row height in pixels
const CAP_PX    = 14    # FreeType pixel size for caption glyphs

const FONT_PATH = joinpath(@__DIR__, "..", "..", "external",
    "MathTeXEngine.jl", "assets", "fonts", "NewComputerModern",
    "NewCMMath-Regular.otf")

# ── Canvas helpers ─────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8=0x00)
    r1c = clamp(r1, 1, size(canvas, 1))
    r2c = clamp(r2, 1, size(canvas, 1))
    c1c = clamp(c1, 1, size(canvas, 2))
    c2c = clamp(c2, 1, size(canvas, 2))
    canvas[r1c:r2c, c1c:c2c] .= val
end

function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    canvas[r, clamp(c1,1,size(canvas,2)):clamp(c2,1,size(canvas,2))] .= val
end

# ── Bounding box computation ───────────────────────────────────────────────────
function em_bbox(boxes, upm; pad=0.12)
    bx1 = bx2 = by1 = by2 = 0.0
    for box in boxes
        el = box.element
        if el isa Glyph
            s = box.scale / upm
            bx1 = min(bx1, box.x + el.x_min * s)
            bx2 = max(bx2, box.x + el.x_max * s)
            by1 = min(by1, box.y + el.y_min * s)
            by2 = max(by2, box.y + el.y_max * s)
        elseif el isa HRule
            bx1 = min(bx1, box.x)
            bx2 = max(bx2, box.x + el.width)
            by1 = min(by1, box.y)
            by2 = max(by2, box.y + el.thickness)
        end
    end
    by1 = min(by1, -0.15); by2 = max(by2, 0.35)
    bx1 -= pad; bx2 += pad; by1 -= pad; by2 += pad
    return (bx1, bx2, by1, by2)
end

# ── Render one expression into a fresh canvas ─────────────────────────────────
function render_expr(expr::String, family, mt, face_math, style=Formatic.Display)
    boxes = layout(parse_latex(expr), family, style)
    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm)

    W = 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX)
    H = 2MARGIN + round(Int, (by2 - by1) * BASE_PX)
    W = max(W, 40); H = max(H, 40)

    canvas = fill(0xff, H, W)
    em_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    # Faint reference lines
    hline!(canvas, em_y(0.0), 1, W, 0xe0)
    hline!(canvas, em_y(mt.constants.axis_height / upm), 1, W, 0xe8)

    for box in boxes
        el = box.element
        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_x(box.x)
            pen_cy = em_y(box.y)
            local bmp, ext
            try
                bmp, ext = renderface(face_math, el.glyph_name, pixel_size)
            catch e
                @warn "renderface failed for $(el.glyph_name): $e"
                continue
            end
            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top  = pen_cy - by_px
            bmp_left = pen_cx + bx_px
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end
        elseif el isa HRule
            c1 = em_x(box.x); c2 = em_x(box.x + el.width)
            r1 = em_y(box.y + el.thickness); r2 = em_y(box.y)
            fill_rect!(canvas, r1, c1, r2, c2, 0x00)
        end
    end
    return canvas
end

# ── Caption rendering using FreeType ──────────────────────────────────────────
function render_caption(face, text::String, W::Int)
    canvas = fill(0xff, CAP_H, W)
    x = MARGIN
    for ch in text
        local bmp, ext
        try
            bmp, ext = renderface(face, string(ch), CAP_PX)
        catch
            x += CAP_PX ÷ 2
            continue
        end
        bx_px = round(Int, ext.horizontal_bearing[1])
        by_px = round(Int, ext.horizontal_bearing[2])
        top  = CAP_H ÷ 2 - by_px ÷ 2
        left = x + bx_px
        for row in axes(bmp, 2), col in axes(bmp, 1)
            alpha = bmp[col, row]
            alpha == 0x00 && continue
            composite!(canvas, top + row, left + col - 1, alpha)
        end
        adv = round(Int, ext.advance[1] / 64)
        x += adv
        x > W - MARGIN && break
    end
    return canvas
end

# ── Stack rows into a panel ────────────────────────────────────────────────────
function make_panel(rows::Vector{Matrix{UInt8}})
    isempty(rows) && return fill(0xff, 40, 40)
    W = maximum(size(r, 2) for r in rows)
    # Pad each row to the same width
    padded = map(rows) do r
        h, w = size(r)
        w == W && return r
        out = fill(0xff, h, W)
        out[:, 1:w] = r
        out
    end
    # Insert ROW_GAP pixels of white space between rows
    gap = fill(0xff, ROW_GAP, W)
    parts = Matrix{UInt8}[]
    for (i, r) in enumerate(padded)
        push!(parts, r)
        i < length(padded) && push!(parts, gap)
    end
    return vcat(parts...)
end

# ── Write PNG via ImageMagick ──────────────────────────────────────────────────
function write_png(path, canvas::Matrix{UInt8})
    H, W = size(canvas)
    open(`convert pgm:- png:$path`, "w") do io
        write(io, "P5\n$W $H\n255\n")
        for row in 1:H
            write(io, view(canvas, row, :))
        end
    end
    println("Written $path  ($(W)×$(H) px)")
end

# ── Main ───────────────────────────────────────────────────────────────────────
function main()
    outdir = length(ARGS) >= 1 ? ARGS[1] : "."
    mkpath(outdir)

    isfile(FONT_PATH) || error("Font not found: $FONT_PATH")
    family    = FontFamily(FONT_PATH)
    mt        = load_math_table(FONT_PATH)
    face_math = FTFont(FONT_PATH)

    # ── Panel 1: Accents (Rule 12) ─────────────────────────────────────────────
    accent_rows = Pair{String,String}[
        "\\hat{x}"           => "\\hat{x}",
        "\\bar{a}"           => "\\bar{a}",
        "\\vec{v}"           => "\\vec{v}",
        "\\tilde{n}"         => "\\tilde{n}",
        "\\dot{x}"           => "\\dot{x}",
        "\\ddot{x}"          => "\\ddot{x}",
        "\\acute{e}"         => "\\acute{e}",
        "\\grave{e}"         => "\\grave{e}",
        "\\hat{A}"           => "\\hat{A}  (tall base)",
        "\\hat{\\frac{a}{b}}"=> "\\hat{\\frac{a}{b}}  (fraction base — centering fallback)",
        "\\widehat{x}"       => "\\widehat{x}  (wide accent, single char)",
        "\\widehat{xyz}"     => "\\widehat{xyz}  (wide accent, 3 chars — extensible)",
        "\\widetilde{x+y}"   => "\\widetilde{x+y}  (wide tilde over expression)",
    ]

    rows = Matrix{UInt8}[]
    W_cap = 0
    for (expr, cap) in accent_rows
        c = render_expr(expr, family, mt, face_math)
        W_cap = max(W_cap, size(c, 2))
        push!(rows, c)
    end
    W_cap = max(W_cap, 400)
    # Interleave captions
    rows2 = Matrix{UInt8}[]
    for (i, (_, cap)) in enumerate(accent_rows)
        push!(rows2, render_caption(face_math, cap, W_cap))
        push!(rows2, rows[i])
    end
    write_png(joinpath(outdir, "accents.png"), make_panel(rows2))

    # ── Panel 2: \overline / \underline (Rules 9 & 10) ────────────────────────
    ou_rows = Pair{String,String}[
        "\\overline{abc}"               => "\\overline{abc}",
        "\\underline{abc}"              => "\\underline{abc}",
        "\\overline{x+y+z}"             => "\\overline{x+y+z}",
        "\\underline{x+y+z}"            => "\\underline{x+y+z}",
        "\\overline{\\frac{a}{b}}"      => "\\overline{\\frac{a}{b}}  (fraction body)",
        "\\underline{\\frac{a}{b}}"     => "\\underline{\\frac{a}{b}}",
        "\\overline{\\overline{x}}"     => "\\overline{\\overline{x}}  (nested)",
        "\\frac{\\overline{a}}{\\underline{b}}" => "\\frac{\\overline{a}}{\\underline{b}}",
    ]

    rows = Matrix{UInt8}[]
    W_cap = 0
    for (expr, cap) in ou_rows
        c = render_expr(expr, family, mt, face_math)
        W_cap = max(W_cap, size(c, 2))
        push!(rows, c)
    end
    W_cap = max(W_cap, 480)
    rows2 = Matrix{UInt8}[]
    for (i, (_, cap)) in enumerate(ou_rows)
        push!(rows2, render_caption(face_math, cap, W_cap))
        push!(rows2, rows[i])
    end
    write_png(joinpath(outdir, "overunder.png"), make_panel(rows2))

    # ── Panel 3: Binary reclassification (Rules 5 & 6) ────────────────────────
    # Each entry: (expr, caption, note)
    bin_rows = Pair{String,String}[
        "+x"                 => "+x  (Rule 5: leading + demoted to ord, no space before x)",
        "a+x"                => "a+x  (normal: + is bin, medium space either side)",
        "\\left(+x\\right)"  => "\\left( +x \\right)  (Rule 5: + after open, demoted)",
        "\\left(a+x\\right)" => "\\left( a+x \\right)  (normal: + is bin)",
        "a+{=}b"             => "a + {=} b  (control: both + and = are full class)",
        "a+=b"               => "a+=b  (Rule 6: + before rel = demoted, no space before =)",
        "a++b"               => "a++b  (Rule 5: second + demoted after first +)",
        "a+b+c"              => "a+b+c  (normal: all + are bin with medium spaces)",
    ]

    rows = Matrix{UInt8}[]
    W_cap = 0
    for (expr, cap) in bin_rows
        c = render_expr(expr, family, mt, face_math)
        W_cap = max(W_cap, size(c, 2))
        push!(rows, c)
    end
    W_cap = max(W_cap, 580)
    rows2 = Matrix{UInt8}[]
    for (i, (_, cap)) in enumerate(bin_rows)
        push!(rows2, render_caption(face_math, cap, W_cap))
        push!(rows2, rows[i])
    end
    write_png(joinpath(outdir, "binary_reclass.png"), make_panel(rows2))
end

main()
