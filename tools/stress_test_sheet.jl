# Render a stress-test demo sheet for TeXLayout.jl.
#
# Every expression exercises a specific hard or edge case: deep nesting,
# extreme delimiter sizing, extensible glyph assembly, every large-operator
# variant, script-size cascade, italic correction, all font variants, etc.
# Failures (blank glyphs, wrong sizes, clipped bounding boxes) are easy to spot.
#
# Public API (usable when this file is included by another script):
#
#   run_stress_test(font_spec, format, output = nothing) -> String
#
#   font_spec  — FontFamily | :new_cm | ":pagella" | "/path/to/Math.otf"
#   format     — :ppm (FreeType, no external deps)
#              | :png | :pdf | :svg  (CairoMakie; load it first)
#              | :tex  (LaTeX source file)
#   output     — output path; default: stress_test_<fontname>.<ext>
#   Returns      the path written
#
# Usage as script:
#   julia tools/stress_test_sheet.jl                          # :new_cm, ppm
#   julia tools/stress_test_sheet.jl :pagella png             # Pagella, PNG
#   julia tools/stress_test_sheet.jl :stix_two ppm out.ppm   # custom name
#   julia tools/stress_test_sheet.jl /path/Math.otf svg      # custom font

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using FreeTypeAbstraction

const BASE_PX = 90    # pixels per em for math content
const MARGIN = 14     # canvas border in pixels
const EXPR_GAP = 30   # horizontal gap between side-by-side expressions (px)
const ROW_GAP = 8     # vertical gap between strips (px)
const SEC_H = 22      # section-header strip height (px)
const TITLE_H = 30    # title-bar strip height (px)
const SEC_PX = 13     # FreeType pixel size for section-header text
const TITLE_PX = 16   # FreeType pixel size for title text

# ── Canvas helpers ─────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    return canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

@inline function composite_white!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    return canvas[ry, cx] = UInt8(old + (255 - old) * Int(alpha) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8 = 0x00)
    r1 = clamp(r1, 1, size(canvas, 1)); r2 = clamp(r2, 1, size(canvas, 1))
    c1 = clamp(c1, 1, size(canvas, 2)); c2 = clamp(c2, 1, size(canvas, 2))
    return r1 > r2 || c1 > c2 || (canvas[r1:r2, c1:c2] .= val)
end

function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    return canvas[r, clamp(c1, 1, size(canvas, 2)):clamp(c2, 1, size(canvas, 2))] .= val
end

# ── Bounding box ───────────────────────────────────────────────────────────────

function em_bbox(boxes, upm; pad = 0.1)
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
    by1 = min(by1, -0.15); by2 = max(by2, 0.35)
    return (bx1 - pad, bx2 + pad, by1 - pad, by2 + pad)
end

# ── Render one LaTeX expression to a greyscale canvas ─────────────────────────

function render_expr(
        expr::String, family, mt, face_math,
        face_regular = nothing,
        style = TeXLayout.Display,
    )::Matrix{UInt8}
    local boxes
    try
        boxes = layout(parse_latex(expr), family, style)
    catch e
        @warn "layout failed for $expr: $e"
        return fill(0xff, 60, 100)
    end
    isempty(boxes) && return fill(0xff, 60, 60)
    upm = mt.upm
    bx1, bx2, by1, by2 = em_bbox(boxes, upm)

    W = max(60, 2MARGIN + round(Int, (bx2 - bx1) * BASE_PX))
    H = max(50, 2MARGIN + round(Int, (by2 - by1) * BASE_PX))
    canvas = fill(0xff, H, W)
    em_x(ex) = MARGIN + round(Int, (ex - bx1) * BASE_PX)
    em_y(ey) = MARGIN + round(Int, (by2 - ey) * BASE_PX)

    hline!(canvas, em_y(0.0), 1, W, 0xd8)
    hline!(canvas, em_y(mt.constants.axis_height / upm), 1, W, 0xec)

    for box in boxes
        el = box.element
        if el isa Glyph
            pixel_size = max(1, round(Int, box.scale * BASE_PX))
            pen_cx = em_x(box.x); pen_cy = em_y(box.y)
            face = (el.font_slot === :regular && face_regular !== nothing) ?
                face_regular : face_math
            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, pixel_size)
            catch
                continue
            end
            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top = pen_cy - by_px
            bmp_left = pen_cx + bx_px
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]; alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end
        elseif el isa HRule
            fill_rect!(
                canvas,
                em_y(box.y + el.thickness), em_x(box.x),
                em_y(box.y), em_x(box.x + el.width),
            )
        elseif el isa VRule
            fill_rect!(
                canvas,
                em_y(box.y + el.height), em_x(box.x),
                em_y(box.y), em_x(box.x + el.thickness),
            )
        end
    end
    return canvas
end

# ── Text rendering for headers (FreeType) ─────────────────────────────────────

function render_text!(
        canvas, face, text::String, x0::Int, px::Int,
        fg::Symbol = :black,
    )
    H = size(canvas, 1)
    x = x0
    for ch in text
        local bmp, ext
        try
            bmp, ext = renderface(face, string(ch), px)
        catch
            x += px ÷ 2; continue
        end
        bx_px = round(Int, ext.horizontal_bearing[1])
        by_px = round(Int, ext.horizontal_bearing[2])
        top = H ÷ 2 - by_px ÷ 2 + 2
        left = x + bx_px
        for row in axes(bmp, 2), col in axes(bmp, 1)
            alpha = bmp[col, row]; alpha == 0x00 && continue
            r = top + row - 1; c = left + col - 1
            fg === :white ? composite_white!(canvas, r, c, alpha) :
                composite!(canvas, r, c, alpha)
        end
        x += round(Int, ext.advance[1] / 64)
        x > size(canvas, 2) - MARGIN && break
    end
    return
end

# ── Header strips ──────────────────────────────────────────────────────────────

function render_title_bar(face, text::String, W::Int)::Matrix{UInt8}
    strip = fill(UInt8(0x1a), TITLE_H, W)
    render_text!(strip, face, text, MARGIN, TITLE_PX, :white)
    return strip
end

function render_section_header(face, text::String, W::Int)::Matrix{UInt8}
    band = fill(UInt8(0x55), 3, W)
    strip = fill(UInt8(0x44), SEC_H, W)
    render_text!(strip, face, text, MARGIN, SEC_PX, :white)
    return vcat(band, strip)
end

# ── Composition helpers ────────────────────────────────────────────────────────

function hcat_canvases(cs::Vector{Matrix{UInt8}}, gap::Int = EXPR_GAP)::Matrix{UInt8}
    isempty(cs) && return fill(0xff, 40, 40)
    H = maximum(size(c, 1) for c in cs)
    W = sum(size(c, 2) for c in cs) + gap * (length(cs) - 1)
    out = fill(0xff, H, W)
    x = 1
    for c in cs
        h, w = size(c)
        r = (H - h) ÷ 2
        out[(r + 1):(r + h), x:(x + w - 1)] .= c
        x += w + gap
    end
    return out
end

function pad_to_width(c::Matrix{UInt8}, W::Int)::Matrix{UInt8}
    h, w = size(c)
    w >= W && return c
    out = fill(0xff, h, W)
    out[:, (MARGIN + 1):min(W, MARGIN + w)] .= c[:, 1:min(w, W - MARGIN)]
    return out
end

function vstack(rows::Vector{Matrix{UInt8}}, gap::Int = ROW_GAP)::Matrix{UInt8}
    isempty(rows) && return fill(0xff, 40, 40)
    W = maximum(size(r, 2) for r in rows)
    parts = Matrix{UInt8}[]
    for (i, r) in enumerate(rows)
        push!(parts, pad_to_width(r, W))
        i < length(rows) && push!(parts, fill(0xff, gap, W))
    end
    return vcat(parts...)
end

# ── Stress-test content ────────────────────────────────────────────────────────
#
# Each section is (title => [(style, latex_expr), ...]).
# All items currently use Display style.

const D = TeXLayout.Display
const T = TeXLayout.Text

_D(exprs) = [(D, e) for e in exprs]
_T(exprs) = [(T, e) for e in exprs]

const STRESS_SECTIONS = [

    # ─────────────────────────────────────────────────────────────────────────
    # Deep nesting: tests recursive layout, style-size cascade in Script/
    # ScriptScript, and correct bounding-box accumulation.
    # ─────────────────────────────────────────────────────────────────────────
    "1. DEEP NESTING — CONTINUED FRACTIONS" => _D(
        [
            raw"\frac{1}{1 + \frac{1}{1 + \frac{1}{1 + \frac{1}{2}}}}",
            raw"\frac{\frac{a+b}{c-d}}{\frac{e+f}{g-h} + \frac{i}{j+k}}",
            raw"\frac{1}{\sqrt{1 + \frac{x^2}{1 + \frac{x^4}{1 + x^6}}}}",
        ]
    ),

    "2. DEEP NESTING — RADICALS & SCRIPTS" => _D(
        [
            raw"\sqrt{1 + \sqrt{1 + \sqrt{1 + \sqrt{1 + x}}}}",
            raw"x^{a^{b^{c^d}}} + y_{m_{n_{p_q}}}",
            raw"\left(\frac{p}{q}\right)^{\!\left(\frac{r}{s}\right)^{\!2}}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Classic identities: real mathematical content exercising many features.
    # ─────────────────────────────────────────────────────────────────────────
    "3. CLASSIC IDENTITIES" => _D(
        [
            raw"e^{i\pi} + 1 = 0",
            raw"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}",
            raw"\left(\sum_{k=1}^{n} k\right)^{\!2} = \sum_{k=1}^{n} k^3",
            raw"\prod_{n=1}^{\infty}\!\left(1 - \frac{x^2}{n^2\pi^2}\right)" *
                raw" = \frac{\sin x}{x}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Integrals: tests italic correction on \int, multiple integral glyphs,
    # and complex limit expressions below/above large operators.
    # ─────────────────────────────────────────────────────────────────────────
    "4. INTEGRALS & GREEN'S THEOREM" => _D(
        [
            raw"\int_{-\infty}^{\infty} e^{-x^2/2}\,dx = \sqrt{2\pi}",
            raw"\frac{d}{dx}\!\left(\int_a^x f(t)\,dt\right) = f(x)",
            raw"\iint_D \!\left(\frac{\partial Q}{\partial x}" *
                raw" - \frac{\partial P}{\partial y}\right)dx\,dy" *
                raw" = \oint_{\partial D} P\,dx + Q\,dy",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # All large-operator glyphs: one strip per operator family.
    # ─────────────────────────────────────────────────────────────────────────
    "5. LARGE OPERATORS — SIGMA / PI / INTEGRAL FAMILY" => _D(
        [
            raw"\sum_{k=0}^{n} \frac{(-1)^k}{2k+1}",
            raw"\prod_{p\,\text{prime}} \frac{p^s}{p^s - 1}",
            raw"\coprod_{\alpha \in I} X_\alpha",
            raw"\int_0^1 f\,dx \quad \iint_D f\,dx\,dy \quad \iiint_V f\,dV",
            raw"\oint_C \mathbf{F}\cdot d\mathbf{r}",
        ]
    ),

    "6. LARGE OPERATORS — SET / LATTICE FAMILY" => _D(
        [
            raw"\bigcup_{n=1}^{\infty} A_n \quad \bigcap_{n=1}^{\infty} B_n",
            raw"\bigsqcup_{k \geq 0} C_k \quad \bigsqcap_{k \geq 0} D_k",
            raw"\bigvee_{i \in I} P_i \quad \bigwedge_{i \in I} Q_i",
            raw"\bigoplus_{k=1}^n V_k \quad \bigotimes_{k=1}^n W_k" *
                raw" \quad \bigodot_{k} Z_k \quad \biguplus_{k} U_k",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Physics: realistic formulas combining nabla, bold vectors, fractions,
    # partial derivatives, and large operators.
    # ─────────────────────────────────────────────────────────────────────────
    "7. PHYSICS EQUATIONS" => _D(
        [
            raw"\hat{H}\psi = -\frac{\hbar^2}{2m}\nabla^2\psi" *
                raw" + V(\mathbf{r})\psi = E\psi",
            raw"\nabla \times \mathbf{B} = \mu_0\mathbf{J}" *
                raw" + \mu_0\varepsilon_0\frac{\partial \mathbf{E}}{\partial t}",
            raw"\dot{\mathbf{q}} = \frac{\partial \mathcal{H}}{\partial \mathbf{p}}" *
                raw", \quad \dot{\mathbf{p}}" *
                raw" = -\frac{\partial \mathcal{H}}{\partial \mathbf{q}}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Tall auto-sized delimiters: exercises vert_constructions lookup and the
    # "smallest variant tall enough to cover inner content" selection.
    # ─────────────────────────────────────────────────────────────────────────
    "8. TALL AUTO-SIZED DELIMITERS" => _D(
        [
            raw"\left(\frac{\dfrac{a}{b} + \dfrac{c}{d}}{\dfrac{e}{f}}\right)^{\!3}",
            raw"\left\|\frac{\partial^2 f}{\partial x^2}\right\|_2" *
                raw" + \left\lfloor\frac{\lceil x\rceil}{2}\right\rfloor",
            raw"\left\langle \frac{a}{b} \,\middle|\, \frac{c}{d} \right\rangle",
            raw"\left[\begin{matrix} \frac{1}{2} & -\frac{1}{2}" *
                raw" \\ \frac{1}{2} & \frac{1}{2} \end{matrix}\right]",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Greek alphabet in Display style.
    # ─────────────────────────────────────────────────────────────────────────
    "9. GREEK ALPHABET — LOWERCASE (display)" => _D(
        [
            raw"\alpha\;\beta\;\gamma\;\delta\;\varepsilon\;\zeta\;\eta" *
                raw"\;\theta\;\iota\;\kappa\;\lambda\;\mu",
            raw"\nu\;\xi\;\pi\;\varpi\;\rho\;\varrho\;\sigma\;\varsigma" *
                raw"\;\tau\;\upsilon\;\varphi\;\chi\;\psi\;\omega",
            raw"\epsilon\;\vartheta\;\varkappa\;\phi",
        ]
    ),

    "10. GREEK ALPHABET — UPPERCASE + MISC" => _D(
        [
            raw"\Gamma\;\Delta\;\Theta\;\Lambda\;\Xi\;\Pi\;\Sigma" *
                raw"\;\Upsilon\;\Phi\;\Psi\;\Omega",
            raw"\hbar\;\ell\;\partial\;\nabla\;\infty\;\forall\;\exists" *
                raw"\;\emptyset\;\aleph\;\beth\;\gimel",
            raw"\Re\;\Im\;\wp\;\imath\;\jmath",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # All font variants: check correct Unicode math-variant codepoints.
    # ─────────────────────────────────────────────────────────────────────────
    "11. FONT VARIANTS — LATIN & GREEK" => _D(
        [
            raw"\mathbf{AaBbXx} \quad \mathit{AaBbXx}",
            raw"\mathrm{AaBbXx} \quad \mathsf{AaBbXx} \quad \mathtt{AaBbXx}",
            raw"\mathbb{RCZQN} \quad \mathcal{FLHKP} \quad \mathfrak{fgAB}",
            raw"\boldsymbol{\alpha\beta\gamma\Gamma\Delta\Omega}" *
                raw" \quad \mathbf{x}^{\mathbf{T}}\mathbf{A}\mathbf{x}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # All accent commands: tests MathTopAccentAttachment alignment.
    # ─────────────────────────────────────────────────────────────────────────
    "12. ACCENTS — NON-EXTENSIBLE" => _D(
        [
            raw"\hat{f} \quad \bar{x} \quad \vec{v} \quad \dot{q} \quad \ddot{y}",
            raw"\tilde{a} \quad \breve{u} \quad \check{c}" *
                raw" \quad \acute{e} \quad \grave{e} \quad \mathring{A}",
            raw"\hat{\mathbf{n}} + \vec{\mathbf{F}} \times \bar{\mathbf{B}}",
        ]
    ),

    "13. ACCENTS — EXTENSIBLE (widehat / widetilde)" => _D(
        [
            raw"\widehat{x} + \widehat{xy} + \widehat{xyz} + \widehat{xyzw}",
            raw"\widetilde{a} + \widetilde{ab} + \widetilde{abc}" *
                raw" + \widetilde{abcd}",
            raw"\widehat{f \cdot g} = \hat{f} * \hat{g}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Horizontal braces / brackets / parens: tests horiz_constructions lookup
    # and extensible assembly; also tests limits-style note placement.
    # ─────────────────────────────────────────────────────────────────────────
    "14. HORIZONTAL BRACES" => _D(
        [
            raw"\overbrace{a_1 + a_2 + \cdots + a_{n-1} + a_n}^{n \text{ terms}}",
            raw"\underbrace{f(x_1)\cdot f(x_2)\cdots f(x_n)}_{n \text{ factors}}" *
                raw" \leq M^n",
            raw"\overbracket{p_1 + p_2 + \cdots + p_k}^{\text{sum}}" *
                raw" \quad \underbracket{q_1 \cdot q_2 \cdots q_m}_{\text{product}}",
            raw"\overparen{\alpha + \beta} + \underparen{\gamma + \delta}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Matrix environments: tests two-pass grid layout, vertical rules,
    # per-column alignment, and delimiter sizing around tall cells.
    # ─────────────────────────────────────────────────────────────────────────
    "15. MATRICES — ENVIRONMENT GALLERY" => _D(
        [
            raw"\begin{pmatrix} \frac{\partial^2 f}{\partial x^2}" *
                raw" & \frac{\partial^2 f}{\partial x\partial y}" *
                raw" \\ \frac{\partial^2 f}{\partial y\partial x}" *
                raw" & \frac{\partial^2 f}{\partial y^2} \end{pmatrix}",
            raw"\det\begin{pmatrix} 1-\lambda & 1 & 0" *
                raw" \\ 0 & 1-\lambda & 1 \\ 0 & 0 & 1-\lambda \end{pmatrix}" *
                raw" = (1-\lambda)^3",
            raw"\begin{Bmatrix} a & b \\ c & d \end{Bmatrix}" *
                raw" \quad \begin{Vmatrix} p & q \\ r & s \end{Vmatrix}",
        ]
    ),

    "16. MATRICES — ARRAY COLSPEC & CASES" => _D(
        [
            raw"\begin{array}{|r|c|l|} \alpha & \beta & \gamma" *
                raw" \\ \frac{1}{2} & \sqrt{3} & \pi^2 \end{array}",
            raw"\begin{cases} x^2 & \text{if } x \ge 0" *
                raw" \\ -x^2 & \text{if } x < 0 \end{cases}",
            raw"\begin{array}{||c||} \frac{a+b}{c} \\ d \end{array}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Limits override: tests \limits and \nolimits modifiers.
    # ─────────────────────────────────────────────────────────────────────────
    "17. LIMITS OVERRIDE (\\limits / \\nolimits)" => _D(
        [
            raw"\int\limits_0^{\infty} e^{-st}f(t)\,dt = \mathcal{L}\{f\}(s)",
            raw"\sum\nolimits_{k=0}^{n} x^k = \frac{x^{n+1}-1}{x-1}",
            raw"\int_{h\to 0}\frac{f(x+h)-f(x)}{h} \quad \text{vs.} \quad" *
                raw" \int\limits_{h\to 0}\frac{f(x+h)-f(x)}{h}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Named operators: every operator in _OPERATOR_NAMES at least once.
    # ─────────────────────────────────────────────────────────────────────────
    "18(a). NAMED OPERATORS" => _D(
        [
            raw"\sin^2\theta + \cos^2\theta = 1," *
                raw" \quad \tan\theta = \frac{\sin\theta}{\cos\theta}",
            raw"\log(ab) = \log a + \log b," *
                raw" \quad \ln e^x = x, \quad \exp(i\pi) = -1",
            raw"\lim_{x\to 0^+} x\ln x = 0, \quad \limsup_{n\to\infty} a_n," *
                raw" \quad \liminf_{n\to\infty} b_n",
        ]
    ),

    "18(b). NAMED OPERATORS" => _D(
        [
            raw"\sup_{x\in A} f(x), \quad \inf_{x\in A} f(x)," *
                raw" \quad \max_{k} a_k, \quad \min_{k} b_k",
            raw"\det A = \sum_{\sigma} \text{sgn}(\sigma)\prod_{i}" *
                raw"a_{i\sigma(i)}, \quad \ker T \cap \text{Im}\,S",
            raw"\gcd(a,b)\cdot\operatorname{lcm}(a,b) = ab," *
                raw" \quad \deg p = n, \quad \dim V = n",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Inter-atom spacing: exercises the TeX atom-class spacing table.
    # ─────────────────────────────────────────────────────────────────────────
    "19. INTER-ATOM SPACING" => _D(
        [
            raw"a + b - c \times d \div e = f",
            raw"A \cup B \cap C \setminus D \oplus E",
            raw"x \leq y \geq z, \quad p \Rightarrow q \iff r",
            raw"\{a,b,c\} \subset \langle d,e \rangle \subseteq \mathbb{R}^n",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Italic-correction stress.
    # ─────────────────────────────────────────────────────────────────────────
    "20. ITALIC CORRECTION ON SLANTED BASES" => _D(
        [
            raw"\int_a^b f(x)\,dx \ne \int_0^1 g(t)\,dt",
            raw"\int\!\!\int_D f\,dA \quad \iint_D f\,dA",
            raw"\oint_C f\,dz = 2\pi i \sum_k \operatorname{Res}(f, z_k)",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Miscellaneous symbols.
    # ─────────────────────────────────────────────────────────────────────────
    "21. SYMBOL GALLERY — ARROWS & LOGIC" => _D(
        [
            raw"A \to B \leftarrow C, \quad f\colon X \mapsto Y",
            raw"\forall \varepsilon > 0\; \exists \delta > 0\colon" *
                raw" |x - a| < \delta \implies |f(x) - L| < \varepsilon",
            raw"P \Leftrightarrow Q, \quad \neg P \Rightarrow R, \quad A \vdash B",
        ]
    ),

    "22. SYMBOL GALLERY — MISC ORDINALS" => _D(
        [
            raw"\prime \quad \partial \quad \nabla \quad \angle \quad" *
                raw" \triangle \quad \square \quad \lozenge \quad \bigstar",
            raw"\flat \quad \natural \quad \sharp \quad \checkmark" *
                raw" \quad \maltese \quad \degree \quad \yen \quad \pounds",
            raw"\top \quad \bot \quad \aleph \quad \beth \quad \gimel" *
                raw" \quad \daleth \quad \hbar \quad \ell",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Kitchen-sink: long, complex expressions combining nearly every feature.
    # ─────────────────────────────────────────────────────────────────────────
    "23. KITCHEN SINK — FOURIER & LAPLACE" => _D(
        [
            raw"\hat{f}(\xi) = \int_{-\infty}^{\infty}" *
                raw" f(x)\,e^{-2\pi i x\xi}\,dx",
            raw"\mathcal{L}\{f * g\}(s)" *
                raw" = \mathcal{L}\{f\}(s)\cdot\mathcal{L}\{g\}(s)",
            raw"\sum_{n=-\infty}^{\infty} c_n\,e^{in\theta}" *
                raw" \xrightarrow{\;L^2\;} f(\theta)",
        ]
    ),

    "24. KITCHEN SINK — TAYLOR & POWER SERIES" => _D(
        [
            raw"\sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n = f(x)",
            raw"e^x = \sum_{n=0}^{\infty}\frac{x^n}{n!}," *
                raw" \quad \sin x = \sum_{n=0}^{\infty}" *
                raw"\frac{(-1)^n x^{2n+1}}{(2n+1)!}",
            raw"\frac{1}{1-x} = \sum_{n=0}^{\infty} x^n \quad (|x| < 1)",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Font size commands: tests \tiny / \scriptsize / … / \Huge scaling.
    # ─────────────────────────────────────────────────────────────────────────
    "25. FONT SIZE COMMANDS — SIZE LADDER" => _D(
        [
            raw"{\tiny \frac{1}{2}}{\scriptsize \frac{1}{2}}" *
                raw"{\footnotesize \frac{1}{2}}{\small \frac{1}{2}}" *
                raw"{\normalsize \frac{1}{2}}{\large \frac{1}{2}}" *
                raw"{\Large \frac{1}{2}}{\LARGE \frac{1}{2}}" *
                raw"{\huge \frac{1}{2}}{\Huge \frac{1}{2}}",
            raw"{\tiny x^2_n}\;{\small x^2_n}\;{\normalsize x^2_n}" *
                raw"\;{\large x^2_n}\;{\Large x^2_n}\;{\LARGE x^2_n}" *
                raw"\;{\Huge x^2_n}",
        ]
    ),

    "26. FONT SIZE COMMANDS — MIXED SIZES IN ONE EXPRESSION" => _D(
        [
            raw"{\Large f}(x) = {\large a}x^2 + {\normalsize b}x + {\small c}",
            raw"{\tiny e^{i\pi}+1=0} \;\longleftrightarrow\;" *
                raw" {\Huge e^{i\pi}+1=0}",
            raw"{\large \sum_{n=1}^{\infty} \frac{1}{n^2}}" *
                raw" = {\Large \frac{\pi^2}{6}}",
            raw"{\LARGE \int_0^{\infty}} e^{-x^2}\,dx" *
                raw" = {\Large \frac{\sqrt{\pi}}{2}}",
        ]
    ),

    "27. FONT SIZE COMMANDS — SIZING WITHIN SUB-EXPRESSIONS" => _D(
        [
            raw"\frac{{\Large a + b}}{{\small c - d}}" *
                raw" + {\normalsize \sqrt{{\large x} + {\small y}}}",
            raw"\left({\large \frac{p}{q}}\right)^{\!{\small 2}}" *
                raw" + \left({\small \frac{r}{s}}\right)^{\!{\large 3}}",
            raw"{\LARGE \mathbf{A}}{\large \mathbf{x}}" *
                raw" = {\LARGE \mathbf{b}}," *
                raw" \quad {\small \mathbf{A} \in \mathbb{R}^{m \times n}}",
            raw"{\Large \sum_{k=0}^{n} {\small \frac{(-1)^k}{2k+1}}}" *
                raw" \xrightarrow{n\to\infty} {\Large \frac{\pi}{4}}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Overline / underline: tests _layout_overunder! (Rules 9 & 10).
    # Rule 9: \overline renders body in cramped style; HRule above with gap
    # from OverbarVerticalGap.  Rule 10: \underline uses UnderbarVerticalGap.
    # ─────────────────────────────────────────────────────────────────────────
    "28. OVERLINE & UNDERLINE" => _D(
        [
            raw"\overline{x + y} + \underline{z - w}",
            raw"\overline{\frac{a}{b}} \ne \underline{\frac{c}{d}}",
            raw"\overline{\mathbf{A}} = (\overline{A_{ij}})_{m \times n}",
            raw"\overline{\overline{x}} \quad \underline{\underline{y}}" *
                raw" \quad \overline{x^2 + \underline{2xy} + y^2}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Absolute style overrides: tests \displaystyle, \textstyle, \scriptstyle,
    # \scriptscriptstyle as explicit NKStyleOverride nodes (distinct from the
    # implicit style changes already exercised by fractions/scripts).
    # ─────────────────────────────────────────────────────────────────────────
    "29. ABSOLUTE STYLE OVERRIDES" => _D(
        [
            raw"{\displaystyle\frac{1}{n}} + {\textstyle\frac{1}{n}}" *
                raw" + {\scriptstyle\frac{1}{n}} + {\scriptscriptstyle\frac{1}{n}}",
            raw"\sum_{k=1}^n {\textstyle\frac{k}{n^2}}" *
                raw" = \frac{{\displaystyle\sum_{k=1}^n k}}{n^2}",
            raw"{\displaystyle\int_0^\infty e^{-x}\,dx}" *
                raw" \ne {\scriptscriptstyle\int_0^\infty e^{-x}\,dx}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # All 18 extensible arrow commands: tests _layout_xarrow! with every
    # codepoint in _XARROW_CODEPOINTS, covering both single-label (above only)
    # and double-label (above + below) forms.
    # ─────────────────────────────────────────────────────────────────────────
    "30. EXTENSIBLE ARROWS — FULL FAMILY" => _D(
        [
            raw"\xleftarrow{f} \quad \xrightarrow{g} \quad" *
                raw" \xleftrightarrow{h}",
            raw"\xLeftarrow{\alpha} \quad \xRightarrow{\beta} \quad" *
                raw" \xLeftrightarrow{\gamma}",
            raw"\xhookleftarrow{} \quad \xhookrightarrow{a} \quad" *
                raw" \xmapsto{T}",
            raw"\xleftharpoonup{} \quad \xrightharpoonup{}" *
                raw" \quad \xleftharpoondown{} \quad \xrightharpoondown{}",
            raw"\xrightleftharpoons{K_{\!\text{eq}}}" *
                raw" \quad \xleftrightharpoons{\Delta G}",
            raw"\xtwoheadleftarrow{} \quad \xtwoheadrightarrow{\text{onto}}" *
                raw" \quad \xlongequal{?}",
            raw"\xrightarrow[n\to\infty]{} \quad \xleftarrow[k<0]{f(k)}" *
                raw" \quad \xRightarrow[\text{by IVT}]{\exists c}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Radical degrees and assembly: \sqrt[n] with degree > 2; nested radicals
    # with non-trivial degree expressions; targets the degree-rendering and
    # radical-bar extension code paths.
    # ─────────────────────────────────────────────────────────────────────────
    "31. RADICAL DEGREES & ASSEMBLY" => _D(
        [
            raw"\sqrt[3]{x} + \sqrt[4]{y^2} + \sqrt[5]{z^3}" *
                raw" + \sqrt[n]{\frac{a+b}{c}}",
            raw"\sqrt[3]{\sqrt[3]{x}} = \sqrt[9]{x}",
            raw"\sqrt[\upsilon]{e^{2\pi i}} = 1 \quad" *
                raw" \sqrt[\alpha+\beta]{\frac{p}{q}}",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Delimiter edge cases: brace pair with \left/\right; null delimiter (.);
    # arrow delimiters; middle-size delimiters \bigm / \Bigm for rel/ord classes.
    # ─────────────────────────────────────────────────────────────────────────
    "32. DELIMITER EDGE CASES" => _D(
        [
            raw"\left\{ x \in \mathbb{R} \mid x^2 \le 1 \right\}",
            raw"\left. \frac{\partial f}{\partial x} \right|_{x=0}" *
                raw" + \left. g(t) \right|_{t=T}",
            raw"\left\uparrow \frac{a}{b} \right\downarrow \quad" *
                raw" \left\Uparrow x \right\Downarrow",
            raw"a \bigm| b \quad p \bigm\| q \quad x \Bigm\{" *
                raw" y \Bigm\} z",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Quad-integral and surface-integral large operators: \iiiint, \oiint,
    # \oiiint — not yet covered by any earlier section.
    # ─────────────────────────────────────────────────────────────────────────
    "33. ADDITIONAL LARGE OPERATORS" => _D(
        [
            raw"\iiiint_V f\,dV \quad \oiint_{\partial V}" *
                raw" \mathbf{F}\cdot d\mathbf{S} \quad" *
                raw" \oiiint_W G\,dW",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Extended font variants: \mathscr and \bm (alias for \boldsymbol)
    # — distinct code paths from the \mathfrak/\mathcal/\boldsymbol coverage
    # already present in section 11.
    # ─────────────────────────────────────────────────────────────────────────
    "34. FONT VARIANTS — EXTENDED (mathscr / bm)" => _D(
        [
            raw"\mathscr{ABCDEFGH}",
            raw"\bm{\alpha} + \bm{x}^T \bm{A} \bm{x}" *
                raw" = \boldsymbol{\lambda}\|\bm{x}\|^2",
            raw"\mathscr{F}\{f\}(s) = \int_{-\infty}^\infty" *
                raw" f(t)\,e^{-2\pi ist}\,dt",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Spacing commands: \kern (positive, negative, fractional em), \qquad
    # (explicit large spacing), and \colon (punctuation spacing vs `:` char).
    # ─────────────────────────────────────────────────────────────────────────
    "35. SPACING COMMANDS" => _D(
        [
            raw"A \kern{2em} B \kern{-1em} C \kern{0.5em} D",
            raw"a \qquad b \qquad c \qquad d",
            raw"f\colon X \to Y, \quad g\colon Y \to Z," *
                raw" \quad h = g \circ f",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Matrix edge cases: \begin{matrix} (no delimiters) and \begin{smallmatrix}
    # (0.9× scale factor, intended for inline use).
    # ─────────────────────────────────────────────────────────────────────────
    "36. MATRIX EDGE CASES" => _D(
        [
            raw"\begin{matrix} a & b \\ c & d \end{matrix}",
            raw"M = \frac{1}{2}\begin{matrix} 1 & -1 \\" *
                raw" -1 & 1 \end{matrix}",
            raw"\left(\begin{smallmatrix} a & b \\" *
                raw" c & d \end{smallmatrix}\right)" *
                raw" + \left(\begin{smallmatrix} e & f \\" *
                raw" g & h \end{smallmatrix}\right)",
        ]
    ),

    # ─────────────────────────────────────────────────────────────────────────
    # Binomial coefficients: \binom (display style, NKGenfrac with paren
    # delimiters and no fraction bar), \dbinom (forced display), \tbinom
    # (forced text).  Tests Rule 15c gap clamping, delimiter sizing around
    # the num/den pair, and style-override wrapping for \dbinom/\tbinom.
    # ─────────────────────────────────────────────────────────────────────────
    "37. BINOMIAL COEFFICIENTS" => _D(
        [
            raw"\binom{n}{k} = \frac{n!}{k!(n-k)!}",
            raw"\binom{n}{0} + \binom{n}{1} + \cdots + \binom{n}{n} = 2^n",
            raw"\dbinom{n}{k} \quad \tbinom{n}{k}" *
                raw" \quad \binom{n}{k} + \binom{n}{k+1} = \binom{n+1}{k+1}",
            raw"\dbinom{a}{b}\tbinom{a}{b}^{\binom{a}{b}+17}" *
                raw"{\scriptscriptstyle \binom{a}{b}}",
        ]
    ),
]

# ── PPM output (pure Julia, no external dependencies) ─────────────────────────

function write_ppm(path::String, canvas::Matrix{UInt8})
    H, W = size(canvas)
    open(path, "w") do io
        write(io, "P5\n$W $H\n255\n")
        for row in 1:H
            write(io, view(canvas, row, :))
        end
    end
    return println("Written $path  ($(W)×$(H) px)")
end

# ── Build the full stress-test canvas (FreeType rendering) ────────────────────

function _build_sheet(
        family::FontFamily,
        mt,
        face_math::FTFont,
        face_regular,
        font_name::String,
    )::Matrix{UInt8}
    section_strips = Matrix{UInt8}[]

    for (_, items) in STRESS_SECTIONS
        canvases = Matrix{UInt8}[]
        for (style, expr) in items
            push!(
                canvases,
                render_expr(expr, family, mt, face_math, face_regular, style)
            )
        end
        push!(section_strips, hcat_canvases(canvases))
    end

    W = max(700, maximum(size(s, 2) for s in section_strips) + 2MARGIN)
    title_str = "TeXLayout.jl  STRESS TEST  —  $(uppercase(font_name))"
    all_rows = Matrix{UInt8}[render_title_bar(face_math, title_str, W)]

    for (i, (sec_title, _)) in enumerate(STRESS_SECTIONS)
        push!(all_rows, render_section_header(face_math, sec_title, W))
        strip = pad_to_width(section_strips[i], W)
        h, w = size(strip)
        padded = fill(0xff, h, W)
        padded[:, (MARGIN + 1):min(W, MARGIN + w)] .= strip[:, 1:min(w, W - MARGIN)]
        push!(all_rows, padded)
    end

    push!(all_rows, fill(UInt8(0x1a), 4, W))
    return vstack(all_rows, 0)
end

# ── TEX output ────────────────────────────────────────────────────────────────

# Escape text for use in a LaTeX context (e.g. section titles).
function _latex_escape(s::String)
    s = replace(s, "\\" => "\\textbackslash{}")
    s = replace(s, "&" => "\\&")
    s = replace(s, "%" => "\\%")
    s = replace(s, "\$" => "\\\$")
    s = replace(s, "#" => "\\#")
    s = replace(s, "_" => "\\_")
    return s
end

"""
    run_stress_test_tex(outpath, font_name)

Write a LaTeX source file that approximately reproduces the stress-test sheet.
Compile with `pdflatex` or `xelatex` (the latter handles Unicode section titles
without extra packages).
"""
function run_stress_test_tex(outpath::String, font_name::String)
    open(outpath, "w") do io
        println(io, "% TeXLayout.jl stress-test (approximate LaTeX equivalent)")
        println(io, "% Compile with: xelatex $(basename(outpath))")
        println(io, "% Required packages beyond standard LaTeX:")
        println(io, "%   stmaryrd  (\\bigsqcap, \\bigsqcup extensions)")
        println(io, "%   mathtools (\\overbracket, \\underbracket)")
        println(io, "%   esint     (\\iiiint, \\oiint, \\oiiint)")
        println(io, "%   mathrsfs  (\\mathscr)")
        println(io, "% Note: \\overparen, \\underparen, \\kern{...} are TeXLayout-")
        println(io, "% specific; approximated below.  Font-size commands inside")
        println(io, "% math (sections 25-27) have no standard LaTeX equivalent.")
        println(io, "\\documentclass[12pt,a4paper]{article}")
        println(io, "\\usepackage{amsmath,amssymb,mathtools,bm}")
        println(io, "\\usepackage{stmaryrd}")
        println(io, "\\usepackage{esint}")
        println(io, "\\usepackage{mathrsfs}")
        println(io, "\\usepackage[margin=1.5cm]{geometry}")
        println(io, "\\setlength{\\parindent}{0pt}")
        println(io, "\\setlength{\\parskip}{3pt}")
        println(io, "\\pagestyle{empty}")
        println(io)
        println(io, "% Fallback definitions for TeXLayout-specific commands:")
        println(io, "\\providecommand{\\overparen}[1]{\\overset{\\frown}{#1}}")
        println(io, "\\providecommand{\\underparen}[1]{\\underset{\\smile}{#1}}")
        println(io, "\\providecommand{\\degree}{^{\\circ}}")
        println(io, "% Non-standard xarrow variants: approximate with standard ones.")
        println(io, "\\providecommand{\\xtwoheadrightarrow}[1]{\\xrightarrow{#1}}")
        println(io, "\\providecommand{\\xtwoheadleftarrow}[1]{\\xleftarrow{#1}}")
        println(io, "\\providecommand{\\xlongequal}[1]{\\xrightarrow{\\;#1\\;}}")
        println(io, "% \\oiiint not in esint; approximate with \\oiint.")
        println(io, "\\providecommand{\\oiiint}{\\oiint}")
        println(io)
        println(io, "\\begin{document}")
        println(io)
        println(io, "\\begin{center}")
        println(io, "  {\\Large\\bfseries TeXLayout.jl Stress Test}\\\\[2pt]")
        println(io, "  {\\large\\itshape $(font_name)}")
        println(io, "\\end{center}")
        println(io, "\\medskip\\hrule\\medskip")
        println(io)

        for (sec_title, items) in STRESS_SECTIONS
            escaped = _latex_escape(sec_title)
            println(io, "\\subsection*{$escaped}")

            # All items are Display style; group in one \[...\] block.
            display_exprs = [expr for (_, expr) in items]
            if !isempty(display_exprs)
                println(io, "\\[")
                for (k, expr) in enumerate(display_exprs)
                    sep = k < length(display_exprs) ? " \\qquad" : ""
                    # \kern{dim} is TeXLayout syntax; LaTeX \kern takes a bare
                    # dimension.  Replace with \hspace which accepts braces.
                    tex_expr = replace(expr, "\\kern{" => "\\hspace{")
                    println(io, "  $tex_expr$sep")
                end
                println(io, "\\]")
            end
            println(io)
        end

        println(io, "\\end{document}")
    end
    return println("Written $outpath")
end

# ── CairoMakie output ─────────────────────────────────────────────────────────
#
# CairoMakie and LaTeXStrings must be loaded in the calling environment before
# invoking this function.  The MathTeXEngineExt is activated automatically once
# TeXLayout, CairoMakie, and LaTeXStrings are all in scope.
#
# Layout uses the same per-expression em_bbox measurements as the PPM renderer,
# so the horizontal arrangement is equivalent.  Positions are in pixel units
# (1 data unit = 1 px) with fontsize = BASE_PX so that 1 em = BASE_PX pixels.
# Makie y increases upward; screen y (used for layout) increases downward.

function run_stress_test_makie(
        family::FontFamily, outpath::String,
        mt, font_name::String,
    )
    CM = CairoMakie
    LS = LaTeXStrings

    set_default_font_family!(family)
    upm = mt.upm

    # ── Layout pass: compute per-row geometry ─────────────────────────────────
    # For each section, compute the expression bboxes, pen x positions (pixels),
    # and row height; accumulate the maximum row width.

    struct_rows = []    # (sec_title, items_data, pens_px, above_px, below_px, row_h_px)
    max_row_w = 0

    for (sec_title, items) in STRESS_SECTIONS
        above_px = 0   # max ink above baseline in this row (pixels)
        below_px = 0   # max ink below baseline (pixels)
        items_data = []

        for (style, expr) in items
            bx1, bx2, by1, by2 = try
                boxes = layout(parse_latex(expr), family, style)
                isempty(boxes) ? (0.0, 1.0, -0.2, 0.8) :
                    em_bbox(boxes, upm; pad = 0.05)
            catch
                (0.0, 1.0, -0.2, 0.8)
            end
            above_px = max(above_px, round(Int, by2 * BASE_PX))
            below_px = max(below_px, round(Int, -by1 * BASE_PX))
            push!(items_data, (style, expr, bx1, bx2, by1, by2))
        end

        # Compute pen x (pixels) for each expression.
        # Leftmost ink of expression 0 is placed at MARGIN pixels;
        # subsequent expressions follow with EXPR_GAP between ink regions.
        x_ink_left = MARGIN
        pens_px = Int[]
        for (_, _, bx1, bx2, _, _) in items_data
            push!(pens_px, x_ink_left - round(Int, bx1 * BASE_PX))
            x_ink_left += round(Int, (bx2 - bx1) * BASE_PX) + EXPR_GAP
        end

        row_w = x_ink_left - EXPR_GAP + MARGIN
        max_row_w = max(max_row_w, row_w)
        row_h_px = above_px + below_px + 2 * MARGIN

        push!(
            struct_rows,
            (sec_title, items_data, pens_px, above_px, below_px, row_h_px)
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
    fig = CM.Figure(size = (W, H), backgroundcolor = :white)
    ax = CM.Axis(fig[1, 1]; aspect = CM.DataAspect(), backgroundcolor = :white)
    CM.hidespines!(ax)
    CM.hidedecorations!(ax)
    CM.xlims!(ax, 0, W)
    CM.ylims!(ax, 0, H)
    CM.resize!(fig.scene, W, H)

    # Helpers: rectangle as Point2f polygon; Makie y from screen y.
    _rect(x, y_screen_top, w, h) = CM.Point2f[
        CM.Point2f(x, H - y_screen_top - h),
        CM.Point2f(x + w, H - y_screen_top - h),
        CM.Point2f(x + w, H - y_screen_top),
        CM.Point2f(x, H - y_screen_top),
    ]
    my(y_screen) = H - y_screen  # convert screen y (top=0) to Makie y (bottom=0)

    # ── Draw title bar ────────────────────────────────────────────────────────
    title_str = "TeXLayout.jl  STRESS TEST  —  $(uppercase(font_name))"
    CM.poly!(ax, _rect(0, 0, W, TITLE_H); color = CM.RGBf(0.1, 0.1, 0.1))
    CM.text!(
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
        CM.poly!(
            ax, _rect(0, y_screen, W, SEC_H);
            color = CM.RGBf(0.27, 0.27, 0.27)
        )
        CM.text!(
            ax, MARGIN, my(y_screen + SEC_H ÷ 2);
            text = sec_title,
            fontsize = SEC_PX, color = :white,
            align = (:left, :center),
            space = :data, markerspace = :data,
        )
        y_screen += SEC_H

        # Expression row — baseline is `above_px` below the row top plus MARGIN
        y_baseline = my(y_screen + MARGIN + above_px)

        for ((style, expr, _, _, _, _), pen_x) in zip(items_data, pens_px)
            try
                CM.text!(
                    ax, pen_x, y_baseline;
                    text = LS.LaTeXString("\$" * expr * "\$"),
                    fontsize = BASE_PX,
                    align = (:left, :baseline),
                    space = :data, markerspace = :data,
                )
            catch e
                @warn "Makie render failed for $(repr(expr)): $e"
            end
        end

        y_screen += row_h_px + ROW_GAP
    end

    # Bottom bar
    CM.poly!(ax, _rect(0, y_screen, W, 4); color = CM.RGBf(0.1, 0.1, 0.1))

    CM.save(outpath, fig; pt_per_unit = 1)
    return println("Written $outpath  ($(W)×$(H) px)")
end

# ── Font resolution helpers ────────────────────────────────────────────────────

function _resolve_font(spec)::FontFamily
    spec isa FontFamily && return spec
    s = string(spec)
    startswith(s, ":") && return font_family(Symbol(s[2:end]))
    isfile(s) && return FontFamily(s)
    # bare symbol name without leading colon
    return font_family(Symbol(s))
end

function _default_output(font_name::String, format::Symbol)::String
    slug = lowercase(replace(font_name, r"[^a-zA-Z0-9]+" => "_"))
    slug = strip(slug, '_')
    ext = format === :ppm ? "ppm" : String(format)
    return "stress_test_$(slug).$(ext)"
end

# ── Public API ─────────────────────────────────────────────────────────────────

"""
    run_stress_test(font_spec, format, output = nothing) -> String

Render the TeXLayout.jl stress-test sheet.

`font_spec` may be a `FontFamily`, a `Symbol` (e.g. `:new_cm`), a colon-prefixed
string (`":pagella"`), or a path to an OTF file.

`format` may be:
  - `:ppm`  — greyscale PGM bitmap via FreeType (no external dependencies)
  - `:png`, `:pdf`, `:svg`  — via CairoMakie (must be loaded before calling)
  - `:tex`  — LaTeX source file; compile with `xelatex`

Returns the path to the written file.
"""
function run_stress_test(
        font_spec, format::Symbol, output = nothing,
    )::String
    format in (:ppm, :png, :pdf, :svg, :tex) ||
        error(
        "Unknown format $(repr(format)). " *
            "Choose :ppm, :png, :pdf, :svg, or :tex."
    )

    family = _resolve_font(font_spec)
    mt = TeXLayout.load_math_table(family.math)
    face_math = FTFont(family.math)
    face_regular = family.regular !== nothing ? FTFont(family.regular) : nothing
    font_name = FreeTypeAbstraction.family_name(face_math)
    outpath = output !== nothing ? String(output) :
        _default_output(font_name, format)

    if format === :ppm
        canvas = _build_sheet(family, mt, face_math, face_regular, font_name)
        write_ppm(outpath, canvas)
    elseif format in (:png, :pdf, :svg)
        isdefined(Main, :CairoMakie) ||
            error("Load CairoMakie before requesting $(format) output.")
        run_stress_test_makie(family, outpath, mt, font_name)
    else  # :tex
        run_stress_test_tex(outpath, font_name)
    end
    return outpath
end

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _format = Symbol(length(ARGS) >= 2 ? ARGS[2] : "ppm")
    _output = length(ARGS) >= 3 ? ARGS[3] : nothing

    if _format in (:png, :pdf, :svg)
        using CairoMakie
        using LaTeXStrings
    end

    run_stress_test(_font_spec, _format, _output)
end
