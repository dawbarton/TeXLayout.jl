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
            raw"M = \frac{1}{2}\begin{matrix} 1 & -1" *
                raw" \\ -1 & 1 \end{matrix}",
            raw"\left(\begin{smallmatrix} a & b" *
                raw" \\ c & d \end{smallmatrix}\right)" *
                raw" + \left(\begin{smallmatrix} e & f" *
                raw" \\ g & h \end{smallmatrix}\right)",
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
