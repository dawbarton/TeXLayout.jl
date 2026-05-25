# Render a stress-test demo sheet for TeXLayout.jl.
#
# Unlike the general demo_sheet.jl, every expression here is chosen to exercise
# a specific hard or edge case in the layout engine: deep nesting, extreme
# delimiter sizing, extensible glyph assembly, every large-operator variant,
# script-size cascade, italic correction, all font variants, and so on.
# Failures (blank glyphs, wrong sizes, clipped bounding boxes) are easy to spot.
#
# Usage:
#   julia tools/stress_test_sheet.jl                           # :new_cm, stress_test_new_cm.png
#   julia tools/stress_test_sheet.jl :pagella                  # Pagella
#   julia tools/stress_test_sheet.jl :stix_two out.png         # STIX Two, named output
#   julia tools/stress_test_sheet.jl /path/to/Math.otf out.png # custom font path

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using TeXLayout
using FreeTypeAbstraction

const BASE_PX  = 90    # pixels per em for math content
const MARGIN   = 14    # canvas border in pixels
const EXPR_GAP = 30    # horizontal gap between side-by-side expressions (px)
const ROW_GAP  = 8     # vertical gap between strips (px)
const SEC_H    = 22    # section-header strip height (px)
const TITLE_H  = 30    # title-bar strip height (px)
const SEC_PX   = 13    # FreeType pixel size for section-header text
const TITLE_PX = 16    # FreeType pixel size for title text

# ── Canvas helpers ────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    canvas[ry, cx] = UInt8(old * (255 - Int(alpha)) ÷ 255)
end

@inline function composite_white!(canvas, ry, cx, alpha::UInt8)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    canvas[ry, cx] = UInt8(old + (255 - old) * Int(alpha) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8=0x00)
    r1 = clamp(r1, 1, size(canvas, 1)); r2 = clamp(r2, 1, size(canvas, 1))
    c1 = clamp(c1, 1, size(canvas, 2)); c2 = clamp(c2, 1, size(canvas, 2))
    r1 > r2 || c1 > c2 || (canvas[r1:r2, c1:c2] .= val)
end

function hline!(canvas, row, c1, c2, val::UInt8)
    r = clamp(row, 1, size(canvas, 1))
    canvas[r, clamp(c1,1,size(canvas,2)):clamp(c2,1,size(canvas,2))] .= val
end

# ── Bounding box ──────────────────────────────────────────────────────────────

function em_bbox(boxes, upm; pad=0.10)
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

# ── Render one LaTeX expression to a canvas ───────────────────────────────────

function render_expr(expr::String, family, mt, face_math,
                     style=TeXLayout.Display)::Matrix{UInt8}
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
            local bmp, ext
            try
                bmp, ext = renderface(face_math, el.glyph_name, pixel_size)
            catch
                continue
            end
            bx_px = round(Int, ext.horizontal_bearing[1])
            by_px = round(Int, ext.horizontal_bearing[2])
            bmp_top  = pen_cy - by_px
            bmp_left = pen_cx + bx_px
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]; alpha == 0x00 && continue
                composite!(canvas, bmp_top + row - 1, bmp_left + col - 1, alpha)
            end
        elseif el isa HRule
            fill_rect!(canvas,
                em_y(box.y + el.thickness), em_x(box.x),
                em_y(box.y),               em_x(box.x + el.width))
        elseif el isa VRule
            fill_rect!(canvas,
                em_y(box.y + el.height), em_x(box.x),
                em_y(box.y),             em_x(box.x + el.thickness))
        end
    end
    return canvas
end

# ── Text rendering for headers ────────────────────────────────────────────────

function render_text!(canvas, face, text::String, x0::Int, px::Int,
                      fg::Symbol=:black)
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
        top  = H ÷ 2 - by_px ÷ 2 + 2
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
end

# ── Header strips ─────────────────────────────────────────────────────────────

function render_title_bar(face, text::String, W::Int)::Matrix{UInt8}
    strip = fill(UInt8(0x1a), TITLE_H, W)
    render_text!(strip, face, text, MARGIN, TITLE_PX, :white)
    return strip
end

function render_section_header(face, text::String, W::Int)::Matrix{UInt8}
    band  = fill(UInt8(0x55), 3, W)
    strip = fill(UInt8(0x44), SEC_H, W)
    render_text!(strip, face, text, MARGIN, SEC_PX, :white)
    return vcat(band, strip)
end

# ── Composition helpers ───────────────────────────────────────────────────────

function hcat_canvases(cs::Vector{Matrix{UInt8}}, gap::Int=EXPR_GAP)::Matrix{UInt8}
    isempty(cs) && return fill(0xff, 40, 40)
    H = maximum(size(c, 1) for c in cs)
    W = sum(size(c, 2) for c in cs) + gap * (length(cs) - 1)
    out = fill(0xff, H, W)
    x = 1
    for c in cs
        h, w = size(c)
        r = (H - h) ÷ 2
        out[r+1:r+h, x:x+w-1] .= c
        x += w + gap
    end
    return out
end

function pad_to_width(c::Matrix{UInt8}, W::Int)::Matrix{UInt8}
    h, w = size(c)
    w >= W && return c
    out = fill(0xff, h, W)
    out[:, MARGIN+1:min(W, MARGIN+w)] .= c[:, 1:min(w, W-MARGIN)]
    return out
end

function vstack(rows::Vector{Matrix{UInt8}}, gap::Int=ROW_GAP)::Matrix{UInt8}
    isempty(rows) && return fill(0xff, 40, 40)
    W = maximum(size(r, 2) for r in rows)
    parts = Matrix{UInt8}[]
    for (i, r) in enumerate(rows)
        push!(parts, pad_to_width(r, W))
        i < length(rows) && push!(parts, fill(0xff, gap, W))
    end
    return vcat(parts...)
end

# ── Stress-test content ───────────────────────────────────────────────────────
#
# Each section is (title => [(style, latex_expr), ...]).
# :D = Display (default for most expressions), :T = Text (used to show style
# differences or for symbol galleries where Display is unnecessarily large).

const D = TeXLayout.Display
const T = TeXLayout.Text

# Helper: default all entries to Display style.
_D(exprs) = [(D, e) for e in exprs]
_T(exprs) = [(T, e) for e in exprs]

const STRESS_SECTIONS = [

    # ─────────────────────────────────────────────────────────────────────────
    # Deep nesting: tests recursive layout, style-size cascade in Script/
    # ScriptScript, and correct bounding-box accumulation.
    # ─────────────────────────────────────────────────────────────────────────
    "1. DEEP NESTING — CONTINUED FRACTIONS" => _D([
        raw"\frac{1}{1 + \frac{1}{1 + \frac{1}{1 + \frac{1}{2}}}}",
        raw"\frac{\frac{a+b}{c-d}}{\frac{e+f}{g-h} + \frac{i}{j+k}}",
        raw"\frac{1}{\sqrt{1 + \frac{x^2}{1 + \frac{x^4}{1 + x^6}}}}",
    ]),

    "2. DEEP NESTING — RADICALS & SCRIPTS" => _D([
        raw"\sqrt{1 + \sqrt{1 + \sqrt{1 + \sqrt{1 + x}}}}",
        raw"x^{a^{b^{c^d}}} + y_{m_{n_{p_q}}}",
        raw"\left(\frac{p}{q}\right)^{\!\left(\frac{r}{s}\right)^{\!2}}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Classic identities: real mathematical content exercising many features.
    # ─────────────────────────────────────────────────────────────────────────
    "3. CLASSIC IDENTITIES" => _D([
        raw"e^{i\pi} + 1 = 0",
        raw"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}",
        raw"\left(\sum_{k=1}^{n} k\right)^{\!2} = \sum_{k=1}^{n} k^3",
        raw"\prod_{n=1}^{\infty}\!\left(1 - \frac{x^2}{n^2\pi^2}\right) = \frac{\sin x}{x}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Integrals: tests italic correction on \int, multiple integral glyphs,
    # and complex limit expressions below/above large operators.
    # ─────────────────────────────────────────────────────────────────────────
    "4. INTEGRALS & GREEN'S THEOREM" => _D([
        raw"\int_{-\infty}^{\infty} e^{-x^2/2}\,dx = \sqrt{2\pi}",
        raw"\frac{d}{dx}\!\left(\int_a^x f(t)\,dt\right) = f(x)",
        raw"\iint_D \!\left(\frac{\partial Q}{\partial x} - \frac{\partial P}{\partial y}\right)dx\,dy = \oint_{\partial D} P\,dx + Q\,dy",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # All large-operator glyphs: one strip per operator family so that missing
    # or wrongly-sized glyphs are immediately visible.
    # ─────────────────────────────────────────────────────────────────────────
    "5. LARGE OPERATORS — SIGMA / PI / INTEGRAL FAMILY" => _D([
        raw"\sum_{k=0}^{n} \frac{(-1)^k}{2k+1}",
        raw"\prod_{p\,\text{prime}} \frac{p^s}{p^s - 1}",
        raw"\coprod_{\alpha \in I} X_\alpha",
        raw"\int_0^1 f\,dx \quad \iint_D f\,dx\,dy \quad \iiint_V f\,dV",
        raw"\oint_C \mathbf{F}\cdot d\mathbf{r}",
    ]),

    "6. LARGE OPERATORS — SET / LATTICE FAMILY" => _D([
        raw"\bigcup_{n=1}^{\infty} A_n \quad \bigcap_{n=1}^{\infty} B_n",
        raw"\bigsqcup_{k \geq 0} C_k \quad \bigsqcap_{k \geq 0} D_k",
        raw"\bigvee_{i \in I} P_i \quad \bigwedge_{i \in I} Q_i",
        raw"\bigoplus_{k=1}^n V_k \quad \bigotimes_{k=1}^n W_k \quad \bigodot_{k} Z_k \quad \biguplus_{k} U_k",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Physics: realistic formulas that combine nabla, bold vectors, fractions,
    # partial derivatives, and large operators.
    # ─────────────────────────────────────────────────────────────────────────
    "7. PHYSICS EQUATIONS" => _D([
        raw"\hat{H}\psi = -\frac{\hbar^2}{2m}\nabla^2\psi + V(\mathbf{r})\psi = E\psi",
        raw"\nabla \times \mathbf{B} = \mu_0\mathbf{J} + \mu_0\varepsilon_0\frac{\partial \mathbf{E}}{\partial t}",
        raw"\dot{\mathbf{q}} = \frac{\partial \mathcal{H}}{\partial \mathbf{p}}, \quad \dot{\mathbf{p}} = -\frac{\partial \mathcal{H}}{\partial \mathbf{q}}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Tall auto-sized delimiters: exercises vert_constructions lookup and the
    # "smallest variant tall enough to cover inner content" selection.
    # ─────────────────────────────────────────────────────────────────────────
    "8. TALL AUTO-SIZED DELIMITERS" => _D([
        raw"\left(\frac{\dfrac{a}{b} + \dfrac{c}{d}}{\dfrac{e}{f}}\right)^{\!3}",
        raw"\left\|\frac{\partial^2 f}{\partial x^2}\right\|_2 + \left\lfloor\frac{\lceil x\rceil}{2}\right\rfloor",
        raw"\left\langle \frac{a}{b} \,\middle|\, \frac{c}{d} \right\rangle",
        raw"\left[\begin{matrix} \frac{1}{2} & -\frac{1}{2} \\ \frac{1}{2} & \frac{1}{2} \end{matrix}\right]",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Greek alphabet in Display and Text style.
    # ─────────────────────────────────────────────────────────────────────────
    "9. GREEK ALPHABET — LOWERCASE (display)" => _D([
        raw"\alpha\;\beta\;\gamma\;\delta\;\varepsilon\;\zeta\;\eta\;\theta\;\iota\;\kappa\;\lambda\;\mu",
        raw"\nu\;\xi\;\pi\;\varpi\;\rho\;\varrho\;\sigma\;\varsigma\;\tau\;\upsilon\;\varphi\;\chi\;\psi\;\omega",
        raw"\epsilon\;\vartheta\;\varkappa\;\phi",
    ]),

    "10. GREEK ALPHABET — UPPERCASE + MISC" => _D([
        raw"\Gamma\;\Delta\;\Theta\;\Lambda\;\Xi\;\Pi\;\Sigma\;\Upsilon\;\Phi\;\Psi\;\Omega",
        raw"\hbar\;\ell\;\partial\;\nabla\;\infty\;\forall\;\exists\;\emptyset\;\aleph\;\beth\;\gimel",
        raw"\Re\;\Im\;\wp\;\imath\;\jmath",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # All font variants: check that correct Unicode math-variant codepoints are
    # selected for Latin, Greek, and digits in each variant.
    # ─────────────────────────────────────────────────────────────────────────
    "11. FONT VARIANTS — LATIN & GREEK" => _D([
        raw"\mathbf{AaBbXx} \quad \mathit{AaBbXx}",
        raw"\mathrm{AaBbXx} \quad \mathsf{AaBbXx} \quad \mathtt{AaBbXx}",
        raw"\mathbb{RCZQN} \quad \mathcal{FLHKP} \quad \mathfrak{fgAB}",
        raw"\boldsymbol{\alpha\beta\gamma\Gamma\Delta\Omega} \quad \mathbf{x}^{\mathbf{T}}\mathbf{A}\mathbf{x}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # All accent commands: tests MathTopAccentAttachment alignment.
    # ─────────────────────────────────────────────────────────────────────────
    "12. ACCENTS — NON-EXTENSIBLE" => _D([
        raw"\hat{f} \quad \bar{x} \quad \vec{v} \quad \dot{q} \quad \ddot{y}",
        raw"\tilde{a} \quad \breve{u} \quad \check{c} \quad \acute{e} \quad \grave{e} \quad \mathring{A}",
        raw"\hat{\mathbf{n}} + \vec{\mathbf{F}} \times \bar{\mathbf{B}}",
    ]),

    "13. ACCENTS — EXTENSIBLE (widehat / widetilde)" => _D([
        raw"\widehat{x} + \widehat{xy} + \widehat{xyz} + \widehat{xyzw}",
        raw"\widetilde{a} + \widetilde{ab} + \widetilde{abc} + \widetilde{abcd}",
        raw"\widehat{f \cdot g} = \hat{f} * \hat{g}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Horizontal braces / brackets / parens: tests horiz_constructions lookup
    # and extensible assembly; also tests limits-style note placement.
    # ─────────────────────────────────────────────────────────────────────────
    "14. HORIZONTAL BRACES" => _D([
        raw"\overbrace{a_1 + a_2 + \cdots + a_{n-1} + a_n}^{n \text{ terms}}",
        raw"\underbrace{f(x_1)\cdot f(x_2)\cdots f(x_n)}_{n \text{ factors}} \leq M^n",
        raw"\overbracket{p_1 + p_2 + \cdots + p_k}^{\text{sum}} \quad \underbracket{q_1 \cdot q_2 \cdots q_m}_{\text{product}}",
        raw"\overparen{\alpha + \beta} + \underparen{\gamma + \delta}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Matrix environments: tests two-pass grid layout, vertical rules,
    # per-column alignment, and delimiter sizing around tall cells.
    # ─────────────────────────────────────────────────────────────────────────
    "15. MATRICES — ENVIRONMENT GALLERY" => _D([
        raw"\begin{pmatrix} \frac{\partial^2 f}{\partial x^2} & \frac{\partial^2 f}{\partial x\partial y} \\ \frac{\partial^2 f}{\partial y\partial x} & \frac{\partial^2 f}{\partial y^2} \end{pmatrix}",
        raw"\det\begin{pmatrix} 1-\lambda & 1 & 0 \\ 0 & 1-\lambda & 1 \\ 0 & 0 & 1-\lambda \end{pmatrix} = (1-\lambda)^3",
        raw"\begin{Bmatrix} a & b \\ c & d \end{Bmatrix} \quad \begin{Vmatrix} p & q \\ r & s \end{Vmatrix}",
    ]),

    "16. MATRICES — ARRAY COLSPEC & CASES" => _D([
        raw"\begin{array}{|r|c|l|} \alpha & \beta & \gamma \\ \frac{1}{2} & \sqrt{3} & \pi^2 \end{array}",
        raw"\begin{cases} x^2 & \text{if } x \ge 0 \\ -x^2 & \text{if } x < 0 \end{cases}",
        raw"\begin{array}{||c||} \frac{a+b}{c} \\ d \end{array}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Limits override: tests \limits and \nolimits modifiers.
    # ─────────────────────────────────────────────────────────────────────────
    "17. LIMITS OVERRIDE (\\limits / \\nolimits)" => _D([
        raw"\int\limits_0^{\infty} e^{-st}f(t)\,dt = \mathcal{L}\{f\}(s)",
        raw"\sum\nolimits_{k=0}^{n} x^k = \frac{x^{n+1}-1}{x-1}",
        raw"\int_{h\to 0}\frac{f(x+h)-f(x)}{h} \quad \text{vs.} \quad \int\limits_{h\to 0}\frac{f(x+h)-f(x)}{h}",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Named operators: every operator in _OPERATOR_NAMES at least once.
    # ─────────────────────────────────────────────────────────────────────────
    "18. NAMED OPERATORS" => _D([
        raw"\sin^2\theta + \cos^2\theta = 1, \quad \tan\theta = \frac{\sin\theta}{\cos\theta}",
        raw"\log(ab) = \log a + \log b, \quad \ln e^x = x, \quad \exp(i\pi) = -1",
        raw"\lim_{x\to 0^+} x\ln x = 0, \quad \limsup_{n\to\infty} a_n, \quad \liminf_{n\to\infty} b_n",
        raw"\sup_{x\in A} f(x), \quad \inf_{x\in A} f(x), \quad \max_{k} a_k, \quad \min_{k} b_k",
        raw"\det A = \sum_{\sigma} \text{sgn}(\sigma)\prod_{i}a_{i\sigma(i)}, \quad \ker T \cap \text{Im}\,S",
        raw"\gcd(a,b)\cdot\operatorname{lcm}(a,b) = ab, \quad \deg p = n, \quad \dim V = n",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Inter-atom spacing: exercises the TeX atom-class spacing table for
    # all combinations of ord/bin/rel/op/open/close/punct/inner atoms.
    # ─────────────────────────────────────────────────────────────────────────
    "19. INTER-ATOM SPACING" => _D([
        raw"a + b - c \times d \div e = f",
        raw"A \cup B \cap C \setminus D \oplus E",
        raw"x \leq y \geq z, \quad p \Rightarrow q \iff r",
        raw"\{a,b,c\} \subset \langle d,e \rangle \subseteq \mathbb{R}^n",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Italic-correction stress: \int is the canonical case where the italic
    # correction should shift subscripts left to avoid overlap with the base.
    # ─────────────────────────────────────────────────────────────────────────
    "20. ITALIC CORRECTION ON SLANTED BASES" => _D([
        raw"\int_a^b f(x)\,dx \ne \int_0^1 g(t)\,dt",
        raw"\int\!\!\int_D f\,dA \quad \iint_D f\,dA",
        raw"\oint_C f\,dz = 2\pi i \sum_k \operatorname{Res}(f, z_k)",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Miscellaneous symbols: punctuation, ellipses, misc ord atoms.
    # ─────────────────────────────────────────────────────────────────────────
    "21. SYMBOL GALLERY — ARROWS & LOGIC" => _D([
        raw"A \to B \leftarrow C, \quad f\colon X \mapsto Y",
        raw"\forall \varepsilon > 0\; \exists \delta > 0\colon |x - a| < \delta \implies |f(x) - L| < \varepsilon",
        raw"P \Leftrightarrow Q, \quad \neg P \Rightarrow R, \quad A \vdash B",
    ]),

    "22. SYMBOL GALLERY — MISC ORDINALS" => _D([
        raw"\prime \quad \partial \quad \nabla \quad \angle \quad \triangle \quad \square \quad \lozenge \quad \bigstar",
        raw"\flat \quad \natural \quad \sharp \quad \checkmark \quad \maltese \quad \degree \quad \yen \quad \pounds",
        raw"\top \quad \bot \quad \aleph \quad \beth \quad \gimel \quad \daleth \quad \hbar \quad \ell",
    ]),

    # ─────────────────────────────────────────────────────────────────────────
    # Kitchen-sink: long, complex expressions that combine nearly every feature.
    # ─────────────────────────────────────────────────────────────────────────
    "23. KITCHEN SINK — FOURIER & LAPLACE" => _D([
        raw"\hat{f}(\xi) = \int_{-\infty}^{\infty} f(x)\,e^{-2\pi i x\xi}\,dx",
        raw"\mathcal{L}\{f * g\}(s) = \mathcal{L}\{f\}(s)\cdot\mathcal{L}\{g\}(s)",
        raw"\sum_{n=-\infty}^{\infty} c_n\,e^{in\theta} \xrightarrow{\;L^2\;} f(\theta)",
    ]),

    "24. KITCHEN SINK — TAYLOR & POWER SERIES" => _D([
        raw"\sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n = f(x)",
        raw"e^x = \sum_{n=0}^{\infty}\frac{x^n}{n!}, \quad \sin x = \sum_{n=0}^{\infty}\frac{(-1)^n x^{2n+1}}{(2n+1)!}",
        raw"\frac{1}{1-x} = \sum_{n=0}^{\infty} x^n \quad (|x| < 1)",
    ]),
]

# ── PNG output ────────────────────────────────────────────────────────────────

function write_png(path, canvas::Matrix{UInt8})
    H, W = size(canvas)
    tmp = tempname() * ".pgm"
    try
        open(tmp, "w") do io
            write(io, "P5\n$W $H\n255\n")
            for row in 1:H
                write(io, view(canvas, row, :))
            end
        end
        run(`magick $tmp png:$path`)
    finally
        isfile(tmp) && rm(tmp)
    end
    println("Written $path  ($(W)×$(H) px)")
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    out_default = let s = lstrip(font_spec, ':')
        isempty(s) || startswith(font_spec, '/') ? "stress_test.png" :
            "stress_test_$(replace(s, '/' => '_')).png"
    end
    outf = length(ARGS) >= 2 ? ARGS[2] : out_default

    family = if startswith(font_spec, ':')
        font_family(Symbol(font_spec[2:end]))
    else
        font_family(font_spec)
    end

    math_path = family.math
    mt        = TeXLayout.load_math_table(math_path)
    face_math = FTFont(math_path)
    font_name = FreeTypeAbstraction.family_name(face_math)

    section_strips = Matrix{UInt8}[]

    for (sec_title, items) in STRESS_SECTIONS
        canvases = Matrix{UInt8}[]
        for (style, expr) in items
            c = render_expr(expr, family, mt, face_math, style)
            push!(canvases, c)
        end
        push!(section_strips, hcat_canvases(canvases))
    end

    W = max(700, maximum(size(s, 2) for s in section_strips) + 2MARGIN)

    title_str = "TeXLayout.jl  STRESS TEST  —  $(uppercase(font_name))"
    all_rows = Matrix{UInt8}[render_title_bar(face_math, title_str, W)]

    for (i, (sec_title, _)) in enumerate(STRESS_SECTIONS)
        push!(all_rows, render_section_header(face_math, sec_title, W))
        expr_canvas = pad_to_width(section_strips[i], W)
        h, w = size(expr_canvas)
        padded = fill(0xff, h, W)
        padded[:, MARGIN+1:min(W, MARGIN+w)] .= expr_canvas[:, 1:min(w, W-MARGIN)]
        push!(all_rows, padded)
    end

    push!(all_rows, fill(UInt8(0x1a), 4, W))

    sheet = vstack(all_rows, 0)
    write_png(outf, sheet)
end

main()
