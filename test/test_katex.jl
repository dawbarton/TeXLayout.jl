# KaTeX-derived test suite for TeXLayout.jl.
#
# Three testsets, drawn from three KaTeX test files:
#   1. Screenshotter smoke tests — selected expressions from ss_data.yaml; each
#      must parse without crashing and yield at least one LayoutBox in Display
#      style.  Expressions whose entire content maps to unrecognised glyph names
#      (and therefore produce zero boxes with the current font) are annotated
#      broken=true.
#   2. Malformed-input — expressions from errors-spec.ts; TeXLayout.jl is
#      deliberately lenient and never throws on ill-formed input, but certain
#      malformed inputs currently trigger a BoundsError (parser advances past the
#      sentinel EOF token).  Those are annotated broken=true.
#   3. Nested and combined structures — AST invariants from katex-spec.ts; all
#      should pass with the current parser.

@testset "KaTeX screenshotter smoke tests" begin

    family = FontFamily(FIXTURE_FONT_PATH)

    # Parse and lay out in Display style; return the LayoutBox vector.
    smoke(expr) = layout(parse_latex(expr), family, Display)

    @testset "BasicTest" begin
        @test (parse_latex("a"); true)
        @test !isempty(smoke("a"))
    end

    @testset "Baseline" begin
        expr = "a+b-c\\cdot d/e"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "Exponents" begin
        expr = "a^{a^a_a}_{a^a_a}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "PrimeSpacing" begin
        expr = "f'+f_2'+f^{f'}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "PrimeSuper" begin
        expr = "x'^2+x'''^2"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "LeftRight" begin
        expr = "\\left( x^2 \\right)"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "Sqrt" begin
        expr = "\\sqrt{\\sqrt{\\sqrt{x}}}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "SqrtRoot" begin
        expr = "1+\\sqrt[3]{2}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "DisplayMode" begin
        # \sum and \infty may not resolve to glyphs, but i, 0, 1 will.
        expr = "\\sum_{i=0}^\\infty \\frac{1}{i}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "NestedFractions" begin
        expr = "\\frac{\\frac{a}{b}}{\\frac{c}{d}}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "NestedSuperscripts" begin
        expr = "x^{x^{x^{x^x}}}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "NullDelimiterInteraction" begin
        expr = "a + \\left. b \\right)"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "GreekLetters" begin
        # KaTeX: \alpha\beta\gamma\omega renders four Greek glyphs.
        # TeXLayout: each becomes NodeKind.Command; NewCMMath-Regular does contain PS
        # glyph names "alpha", "beta", "gamma", "omega" so this passes.
        expr = "\\alpha\\beta\\gamma\\omega"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "Functions" begin
        # KaTeX: renders \sin etc. as upright multi-letter operators.
        # TeXLayout: each becomes NodeKind.Operator; characters are looked up via
        # the upright (codepoint) path and render as roman letters.
        expr = "\\sin\\cos\\tan\\ln\\log"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "Kern" begin
        # ss_data.yaml: Kern — kern with em, ex (unsupported), and negative em.
        # \kern1ex produces zero-width space (unsupported unit); the rest produce
        # Space elements.  The expression contains several ordinary chars so the
        # result is non-empty.
        expr = "\\frac{a\\kern{1em}b}{c}a\\kern{1em}b\\kern{1ex}c\\kern{-0.25em}d"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "NegativeSpaceBetweenRel" begin
        # ss_data.yaml: NegativeSpaceBetweenRel — A =\!= B
        expr = "A =\\!= B"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "pmatrix 2×2" begin
        expr = raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "bmatrix identity" begin
        expr = raw"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "cases environment" begin
        expr = raw"\begin{cases} x & x > 0 \\ 0 & \text{otherwise} \end{cases}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "matrix (no delimiters)" begin
        expr = raw"\begin{matrix} \alpha & \beta \\ \gamma & \delta \end{matrix}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "pmatrix nested in frac" begin
        expr = raw"\frac{1}{\begin{pmatrix}a\\b\end{pmatrix}}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "BinomTest" begin
        # ss_data.yaml: \dbinom{a}{b}\tbinom{a}{b}^{\binom{a}{b}+17}{\scriptscriptstyle \binom a b}
        expr = raw"\dbinom{a}{b}\tbinom{a}{b}^{\binom{a}{b}+17}{\scriptscriptstyle \binom a b}"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "NullDelimiterInteraction" begin
        # ss_data.yaml: a \bigl. + 2 \quad \left. + a \right)
        expr = raw"a \bigl. + 2 \quad \left. + a \right)"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

    @testset "DelimiterSizing" begin
        # ss_data.yaml: first line of the multi-line entry.
        # Arrow delimiters fall back to the base glyph when no vert_construction exists;
        # brackets, braces, and rfloor use pre-built variants.
        expr = raw"\bigl\uparrow\Bigl\downarrow\biggl\updownarrow\Biggl\Uparrow\Biggr\Downarrow\biggr\langle\Bigr\}\bigr\rfloor"
        @test (parse_latex(expr); true)
        @test !isempty(smoke(expr))
    end

end

@testset "KaTeX malformed-input" begin

    # Returns true if parse_latex completes without throwing, false otherwise.
    # Used for tests where a crash is the current (broken) behaviour.
    no_crash(expr) = try
        parse_latex(expr); true
    catch
        false
    end

    @testset "superscript inside closing brace" begin
        # KaTeX error: "Expected group after '^'".
        # TeXLayout: silently produces NodeKind.Superscript with NodeKind.Char("}") as exponent.
        @test no_crash("{1^}")
    end

    @testset "subscript at end of input" begin
        # KaTeX error: "Expected group after '_'".
        # TeXLayout: silently produces NodeKind.Subscript with an empty NodeKind.Space argument.
        @test no_crash("1_")
    end

    @testset "superscript at end of input" begin
        # KaTeX error: "Expected group after '^'".
        # TeXLayout: silently produces NodeKind.Superscript with an empty NodeKind.Space argument.
        @test no_crash("1^")
    end

    @testset "double superscript" begin
        # KaTeX error: "Double superscript".
        # TeXLayout: silently ignores the second '^'; the third character is
        # emitted as a bare NodeKind.Char in the outer sequence.
        @test no_crash("1^2^3")
    end

    @testset "double subscript" begin
        # KaTeX error: "Double subscript".
        # TeXLayout: silently ignores the second '_'.
        @test no_crash("1_2_3")
    end

    @testset "unclosed sqrt brace" begin
        # KaTeX error: "Expected '}'".
        # TeXLayout: treats EOF as the closing brace — no crash.
        @test no_crash("\\sqrt{2")
    end

    @testset "unclosed sqrt optional argument" begin
        # KaTeX error: "Expected ']'".
        # TeXLayout: silently uses an empty NodeKind.Space as the body — no crash.
        @test no_crash("\\sqrt[3")
    end

    @testset "missing right delimiter" begin
        # KaTeX error: "Missing \\right".
        # TeXLayout: \right and its delimiter are consumed as NodeKind.Command and NodeKind.Char
        # children of the NodeKind.Delimited node — no crash.
        @test no_crash("\\left(1+2)")
    end

end

@testset "KaTeX nested and combined structures" begin

    @testset "sub/sup order independence" begin
        # x^2_3 and x_3^2 must both produce a NodeKind.Decorated node with the same
        # sub and sup content regardless of the order ^ and _ appear in source.
        n1 = parse_latex("x^2_3")
        n2 = parse_latex("x_3^2")
        d1 = n1.children[1]   # NodeKind.Decorated from top-level NodeKind.Sequence
        d2 = n2.children[1]
        @test d1.kind === NodeKind.Decorated
        @test d2.kind === NodeKind.Decorated
        # children: [base, sub_node, sup_node]
        @test d1.children[2].value == d2.children[2].value   # subscript "3"
        @test d1.children[3].value == d2.children[3].value   # superscript "2"
    end

    @testset "nested superscripts" begin
        # x^{y^z}: the exponent argument is itself a NodeKind.Superscript.
        node = parse_latex("x^{y^z}")
        outer = node.children[1]
        @test outer.kind === NodeKind.Superscript
        inner = outer.children[2]
        @test inner.kind === NodeKind.Superscript
        @test inner.children[1].value == "y"
        @test inner.children[2].value == "z"
    end

    @testset "sqrt containing frac" begin
        # \sqrt{\frac{a}{b}}: the body of the radical is a NodeKind.Frac node.
        node = parse_latex("\\sqrt{\\frac{a}{b}}")
        sqrt_node = node.children[1]
        @test sqrt_node.kind === NodeKind.Sqrt
        frac_node = sqrt_node.children[1]
        @test frac_node.kind === NodeKind.Frac
        @test frac_node.children[1].value == "a"
        @test frac_node.children[2].value == "b"
    end

    @testset "left-right produces NodeKind.Delimited" begin
        # \left( x \right): top-level child is NodeKind.Delimited.  The value field
        # encodes the delimiter glyph names; inner children contain only the
        # interior content (no \right command node).
        node = parse_latex("\\left( x \\right)")
        delim = node.children[1]
        @test delim.kind === NodeKind.Delimited
        @test any(c -> c.kind === NodeKind.Char && c.value == "x", delim.children)
        parts = split(delim.value, "\x00", limit = 2)
        @test parts[1] == "parenleft"
        @test parts[2] == "parenright"
    end

end
