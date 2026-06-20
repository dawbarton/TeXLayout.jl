# Tests for the LaTeX parser / AST builder (src/parser.jl).
#
# Tests check the shape of the AST, not rendering details.
# The convenience form `parse_latex(string)` is used throughout.

@testset "Parser" begin

    @testset "Single character" begin
        tree = parse_latex("x")
        @test tree.kind === NodeKind.Sequence
        @test length(tree.children) == 1
        @test tree.children[1].kind === NodeKind.Char
        @test tree.children[1].value == "x"
    end

    @testset "Superscript: x^2" begin
        tree = parse_latex("x^2")
        @test tree.kind === NodeKind.Sequence
        sup = tree.children[1]
        @test sup.kind === NodeKind.Superscript
        @test length(sup.children) == 2   # [base, exponent]
        @test sup.children[1].kind === NodeKind.Char
        @test sup.children[1].value == "x"
        @test sup.children[2].kind === NodeKind.Char
        @test sup.children[2].value == "2"
    end

    @testset "Subscript: x_i" begin
        tree = parse_latex("x_i")
        sub = tree.children[1]
        @test sub.kind === NodeKind.Subscript
        @test sub.children[1].value == "x"
        @test sub.children[2].value == "i"
    end

    @testset "Both sub and sup: x_i^2" begin
        tree = parse_latex("x_i^2")
        dec = tree.children[1]
        @test dec.kind === NodeKind.Decorated
        # children are always [base, subscript, superscript] regardless of source order
        @test length(dec.children) == 3
        @test dec.children[1].value == "x"  # base
        @test dec.children[2].value == "i"  # subscript
        @test dec.children[3].value == "2"  # superscript
    end

    @testset "Fraction: \\frac{a}{b}" begin
        tree = parse_latex("\\frac{a}{b}")
        frac = tree.children[1]
        @test frac.kind === NodeKind.Frac
        @test length(frac.children) == 2   # [numerator, denominator]
        # Numerator and denominator are single-element sequences or chars
        num = frac.children[1]
        den = frac.children[2]
        # _parse_argument! unwraps single-element braced groups, so {a} → NodeKind.Char("a").
        @test num.kind === NodeKind.Char && num.value == "a"
        @test den.kind === NodeKind.Char && den.value == "b"
    end

    @testset "Square root: \\sqrt{x}" begin
        tree = parse_latex("\\sqrt{x}")
        sqrt_node = tree.children[1]
        @test sqrt_node.kind === NodeKind.Sqrt
        # children[1] is the body; no optional degree argument
        @test length(sqrt_node.children) >= 1
    end

    @testset "Sqrt with degree: \\sqrt[3]{x}" begin
        tree = parse_latex("\\sqrt[3]{x}")
        sqrt_node = tree.children[1]
        @test sqrt_node.kind === NodeKind.Sqrt
        # Degree and body both present
        @test length(sqrt_node.children) == 2
    end

    @testset "Explicit group: {ab}" begin
        tree = parse_latex("{ab}")
        grp = tree.children[1]
        @test grp.kind === NodeKind.Group
        @test length(grp.children) == 2
    end

    @testset "Command atom: \\alpha" begin
        tree = parse_latex("\\alpha")
        cmd = tree.children[1]
        @test cmd.kind === NodeKind.Command
        @test cmd.value == "\\alpha"
    end

    @testset "Nested: \\frac{x^2}{y_i}" begin
        tree = parse_latex("\\frac{x^2}{y_i}")
        frac = tree.children[1]
        @test frac.kind === NodeKind.Frac
        num = frac.children[1]
        # Numerator should contain a superscript
        num_inner = num.kind === NodeKind.Sequence ? num.children[1] : num
        @test num_inner.kind === NodeKind.Superscript
    end

    @testset "Multi-character sequence: abc" begin
        tree = parse_latex("abc")
        @test tree.kind === NodeKind.Sequence
        @test length(tree.children) == 3
        @test all(c.kind === NodeKind.Char for c in tree.children)
    end

    @testset "Named operator: \\sin" begin
        tree = parse_latex("\\sin")
        op = tree.children[1]
        @test op.kind === NodeKind.Operator
        @test op.value == "sin"
    end

    @testset "\\operatorname{myop}" begin
        tree = parse_latex("\\operatorname{myop}")
        op = tree.children[1]
        @test op.kind === NodeKind.Operator
        @test op.value == "myop"
    end

    @testset "Braced superscript: x^{10}" begin
        tree = parse_latex("x^{10}")
        sup = tree.children[1]
        @test sup.kind === NodeKind.Superscript
        exp = sup.children[2]
        # Exponent is either a group or sequence containing chars '1' and '0'
        @test exp.kind === NodeKind.Group || exp.kind === NodeKind.Sequence
        chars = exp.kind === NodeKind.Group ? exp.children : exp.children
        @test length(chars) == 2
        @test chars[1].value == "1"
        @test chars[2].value == "0"
    end

    @testset "Thin space: \\," begin
        tree = parse_latex("a\\,b")
        @test length(tree.children) == 3
        sp = tree.children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 3 / 18
    end

    @testset "Medium space: \\:" begin
        sp = parse_latex("a\\:b").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 4 / 18
    end

    @testset "Thick space: \\;" begin
        sp = parse_latex("a\\;b").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 5 / 18
    end

    @testset "Negative thin space: \\!" begin
        sp = parse_latex("a\\!b").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ -3 / 18
    end

    @testset "Aliases: \\quad, \\qquad, \\enspace" begin
        @test parse_latex("a\\quad b").children[2].width ≈ 1.0
        @test parse_latex("a\\qquad b").children[2].width ≈ 2.0
        @test parse_latex("a\\enspace b").children[2].width ≈ 0.5
    end

    @testset "Aliases: \\thinspace, \\medspace, \\thickspace" begin
        @test parse_latex("a\\thinspace b").children[2].width ≈ 3 / 18
        @test parse_latex("a\\medspace b").children[2].width ≈ 4 / 18
        @test parse_latex("a\\thickspace b").children[2].width ≈ 5 / 18
    end

    @testset "Kern: \\kern1em (unbraced)" begin
        sp = parse_latex("a\\kern1emb").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 1.0
    end

    @testset "Kern: \\kern{0.5em} (braced)" begin
        sp = parse_latex("a\\kern{0.5em}b").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 0.5
    end

    @testset "Kern: \\kern{-0.25em} (negative)" begin
        sp = parse_latex("a\\kern{-0.25em}b").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ -0.25
    end

    @testset "Mkern: \\mkern18mu gives 1em" begin
        sp = parse_latex("a\\mkern18mub").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 1.0
    end

    @testset "Hskip: \\hskip2em gives 2em" begin
        sp = parse_latex("a\\hskip2emb").children[2]
        @test sp.kind === NodeKind.Space
        @test sp.width ≈ 2.0
    end

    @testset "\\left(…\\right) stores glyph names in value" begin
        node = parse_latex("\\left( x \\right)")
        delim = node.children[1]
        @test delim.kind === NodeKind.Delimited
        parts = split(delim.value, "\x00", limit = 2)
        @test parts[1] == "parenleft"
        @test parts[2] == "parenright"
        # \right is consumed — only x remains as an inner child
        @test all(c.kind !== NodeKind.Command || c.value != "\\right" for c in delim.children)
        @test any(c -> c.kind === NodeKind.Char && c.value == "x", delim.children)
    end

    @testset "\\left.…\\right) null left delimiter" begin
        node = parse_latex("\\left. x \\right)")
        delim = node.children[1]
        @test delim.kind === NodeKind.Delimited
        parts = split(delim.value, "\x00", limit = 2)
        @test parts[1] == ""          # null delimiter maps to empty string
        @test parts[2] == "parenright"
    end

    @testset "\\left\\{…\\right\\} brace delimiters" begin
        node = parse_latex("\\left\\{ x \\right\\}")
        delim = node.children[1]
        @test delim.kind === NodeKind.Delimited
        parts = split(delim.value, "\x00", limit = 2)
        @test parts[1] == "braceleft"
        @test parts[2] == "braceright"
    end

    # ── Font switching ──────────────────────────────────────────────────────────

    @testset "\\mathbf{x}: NodeKind.FontSwitch with variant mathbf" begin
        tree = parse_latex("\\mathbf{x}")
        fs = tree.children[1]
        @test fs.kind === NodeKind.FontSwitch
        @test fs.value == "mathbf"
        @test length(fs.children) == 1
        @test fs.children[1].kind === NodeKind.Char
        @test fs.children[1].value == "x"
    end

    @testset "\\mathit, \\mathrm, \\mathbb, \\mathcal, \\mathfrak produce NodeKind.FontSwitch" begin
        for (cmd, variant) in (
                ("\\mathit", "mathit"), ("\\mathrm", "mathrm"),
                ("\\mathbb", "mathbb"), ("\\mathcal", "mathcal"),
                ("\\mathfrak", "mathfrak"), ("\\mathsf", "mathsf"),
                ("\\mathtt", "mathtt"),
            )
            node = parse_latex("$(cmd){A}").children[1]
            @test node.kind === NodeKind.FontSwitch
            @test node.value == variant
        end
    end

    @testset "Aliases: \\Bbb, \\bold, \\frak produce NodeKind.FontSwitch" begin
        @test parse_latex("\\Bbb{A}").children[1].value == "mathbb"
        @test parse_latex("\\bold{x}").children[1].value == "mathbf"
        @test parse_latex("\\frak{A}").children[1].value == "mathfrak"
        for alias in ("\\Bbb", "\\bold", "\\frak")
            @test parse_latex("$(alias){x}").children[1].kind === NodeKind.FontSwitch
        end
    end

    @testset "\\boldsymbol and \\bm are aliases for boldsymbol" begin
        @test parse_latex("\\boldsymbol{x}").children[1].value == "boldsymbol"
        @test parse_latex("\\bm{x}").children[1].value == "boldsymbol"
    end

    @testset "\\mathbf{x_i}: font switch wraps a subscript" begin
        # \mathbf{x_i} → NodeKind.FontSwitch("mathbf", [NodeKind.Subscript([NodeKind.Char("x"), NodeKind.Char("i")])])
        tree = parse_latex("\\mathbf{x_i}")
        fs = tree.children[1]
        @test fs.kind === NodeKind.FontSwitch
        body = fs.children[1]
        @test body.kind === NodeKind.Subscript
        @test body.children[1].kind === NodeKind.Char
        @test body.children[1].value == "x"
        @test body.children[2].kind === NodeKind.Char
        @test body.children[2].value == "i"
    end

    @testset "\\mathbf{abc}: multi-character body is a sequence/group" begin
        tree = parse_latex("\\mathbf{abc}")
        fs = tree.children[1]
        @test fs.kind === NodeKind.FontSwitch
        @test fs.value == "mathbf"
        # {abc} is parsed as a group containing three NodeKind.Char children.
        body = fs.children[1]
        @test body.kind === NodeKind.Group || body.kind === NodeKind.Sequence
        @test length(body.children) == 3
        @test all(c.kind === NodeKind.Char for c in body.children)
    end

    @testset "\\widehat{x}: produces NodeKind.Accent with value \\widehat" begin
        tree = parse_latex("\\widehat{x}")
        acc = tree.children[1]
        @test acc.kind === NodeKind.Accent
        @test acc.value == "\\widehat"
        @test length(acc.children) == 1
        @test acc.children[1].kind === NodeKind.Char
    end

    @testset "\\widetilde{x}: produces NodeKind.Accent with value \\widetilde" begin
        tree = parse_latex("\\widetilde{x}")
        acc = tree.children[1]
        @test acc.kind === NodeKind.Accent
        @test acc.value == "\\widetilde"
        @test length(acc.children) == 1
        @test acc.children[1].kind === NodeKind.Char
    end

    @testset "\\widehat{xyz}: wide accent over multi-char base" begin
        tree = parse_latex("\\widehat{xyz}")
        acc = tree.children[1]
        @test acc.kind === NodeKind.Accent
        @test acc.value == "\\widehat"
        # {xyz} becomes a group or sequence with three NodeKind.Char children.
        body = acc.children[1]
        @test body.kind === NodeKind.Group || body.kind === NodeKind.Sequence
        @test length(body.children) == 3
    end

    @testset "\\overbrace{x}: produces NodeKind.HorizBrace with command in value" begin
        tree = parse_latex("\\overbrace{x}")
        brace = tree.children[1]
        @test brace.kind === NodeKind.HorizBrace
        @test brace.value == "\\overbrace"
        @test length(brace.children) == 1
        @test brace.children[1].kind === NodeKind.Char
        @test brace.children[1].value == "x"
    end

    @testset "\\underbrace{x}: produces NodeKind.HorizBrace" begin
        tree = parse_latex("\\underbrace{x}")
        brace = tree.children[1]
        @test brace.kind === NodeKind.HorizBrace
        @test brace.value == "\\underbrace"
        @test length(brace.children) == 1
    end

    @testset "\\overbracket / \\underbracket / \\overparen / \\underparen" begin
        for cmd in ("\\overbracket", "\\underbracket", "\\overparen", "\\underparen")
            tree = parse_latex("$(cmd){x}")
            brace = tree.children[1]
            @test brace.kind === NodeKind.HorizBrace
            @test brace.value == cmd
        end
    end

    @testset "\\overbrace{x}^{n}: NodeKind.Superscript with NodeKind.HorizBrace base" begin
        tree = parse_latex("\\overbrace{x}^{n}")
        sup = tree.children[1]
        @test sup.kind === NodeKind.Superscript
        @test sup.children[1].kind === NodeKind.HorizBrace
        @test sup.children[2].kind === NodeKind.Char
        @test sup.children[2].value == "n"
    end

    @testset "\\underbrace{x}_{n}: NodeKind.Subscript with NodeKind.HorizBrace base" begin
        tree = parse_latex("\\underbrace{x}_{n}")
        sub = tree.children[1]
        @test sub.kind === NodeKind.Subscript
        @test sub.children[1].kind === NodeKind.HorizBrace
        @test sub.children[2].kind === NodeKind.Char
        @test sub.children[2].value == "n"
    end

    @testset "\\overbrace{x}^{n}_{m}: NodeKind.Decorated with NodeKind.HorizBrace base" begin
        tree = parse_latex("\\overbrace{x}^{n}_{m}")
        dec = tree.children[1]
        @test dec.kind === NodeKind.Decorated
        @test dec.children[1].kind === NodeKind.HorizBrace   # base
        # children[2] = sub, children[3] = sup
        @test dec.children[2].kind === NodeKind.Char   # m (sub)
        @test dec.children[3].kind === NodeKind.Char   # n (sup)
    end

    # ── Matrix environments ───────────────────────────────────────────────────

    @testset "\\begin{pmatrix} 2x2: NodeKind.Matrix with correct shape" begin
        tree = parse_latex(raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}")
        @test length(tree.children) == 1
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        @test mat.value == "pmatrix\x002\x00cc"
        @test length(mat.children) == 4
        # Each child is a group; check cell content
        @test mat.children[1].kind === NodeKind.Group
        @test mat.children[1].children[1].value == "a"
        @test mat.children[2].children[1].value == "b"
        @test mat.children[3].children[1].value == "c"
        @test mat.children[4].children[1].value == "d"
    end

    @testset "\\begin{matrix} 1x1: single cell, no delimiters" begin
        tree = parse_latex(raw"\begin{matrix} x \end{matrix}")
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        @test mat.value == "matrix\x001\x00c"
        @test length(mat.children) == 1
        @test mat.children[1].children[1].value == "x"
    end

    @testset "\\begin{cases}: 2x2 with braceleft delimiter" begin
        tree = parse_latex(raw"\begin{cases} f & x > 0 \\ 0 & \text{otherwise}\end{cases}")
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        @test mat.value == "cases\x002\x00ll"
        @test length(mat.children) == 4
    end

    @testset "Unclosed matrix environment: lenient parse" begin
        tree = parse_latex(raw"\begin{pmatrix} a & b")
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        @test mat.value == "pmatrix\x001\x00cc"
        @test length(mat.children) == 2
    end

    @testset "Unknown environment: falls through to NodeKind.Command" begin
        tree = parse_latex(raw"\begin{myenv} x \end{myenv}")
        @test tree.children[1].kind === NodeKind.Command
        @test tree.children[1].value == "\\begin{myenv}"
    end

    @testset "Mismatched row lengths: short rows padded" begin
        # Row 1 has 3 cells, row 2 has 1: should produce a 2x3 matrix with 6 cells.
        tree = parse_latex(raw"\begin{matrix} a & b & c \\ x \end{matrix}")
        mat = tree.children[1]
        @test mat.value == "matrix\x002\x00ccc"
        @test length(mat.children) == 6
        # Last two cells of row 2 should be empty groups
        @test isempty(mat.children[5].children)
        @test isempty(mat.children[6].children)
    end

    @testset "\\begin{array}{lcr}: explicit colspec stored verbatim" begin
        tree = parse_latex(raw"\begin{array}{lcr} a & b & c \\ d & e & f \end{array}")
        @test length(tree.children) == 1
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        # value encodes env, nrow, and the raw colspec
        parts = split(mat.value, "\x00"; limit = 3)
        @test parts[1] == "array"
        @test parts[2] == "2"
        @test parts[3] == "lcr"
        @test length(mat.children) == 6
        @test mat.children[1].children[1].value == "a"
        @test mat.children[2].children[1].value == "b"
        @test mat.children[3].children[1].value == "c"
    end

    @testset "\\begin{array}{|l|c|r|}: vertical rules in colspec" begin
        tree = parse_latex(raw"\begin{array}{|l|c|r|} x & y & z \end{array}")
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        parts = split(mat.value, "\x00"; limit = 3)
        @test parts[1] == "array"
        @test parts[3] == "|l|c|r|"
        @test length(mat.children) == 3
    end

    @testset "\\begin{array}{ll}: cases-style two-column left-aligned" begin
        tree = parse_latex(raw"\begin{array}{ll} f(x) & x > 0 \\ 0 & \text{else}\end{array}")
        mat = tree.children[1]
        @test mat.kind === NodeKind.Matrix
        parts = split(mat.value, "\x00"; limit = 3)
        @test parts[3] == "ll"
        @test length(mat.children) == 4
    end

    # ── Style overrides ────────────────────────────────────────────────────────

    @testset "\\dfrac wraps NodeKind.Frac in NodeKind.StyleOverride(Display)" begin
        tree = parse_latex(raw"\dfrac{a}{b}")
        node = tree.children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Display"
        @test length(node.children) == 1
        @test node.children[1].kind === NodeKind.Frac
    end

    @testset "\\tfrac wraps NodeKind.Frac in NodeKind.StyleOverride(Text)" begin
        tree = parse_latex(raw"\tfrac{x}{y}")
        node = tree.children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Text"
        @test node.children[1].kind === NodeKind.Frac
    end

    @testset "\\binom produces NodeKind.Genfrac with paren delimiters" begin
        tree = parse_latex(raw"\binom{n}{k}")
        node = tree.children[1]
        @test node.kind === NodeKind.Genfrac
        # value encodes PS glyph names "parenleft\x00parenright"
        @test contains(node.value, "\x00")
        parts = split(node.value, "\x00")
        @test parts[1] == "parenleft"
        @test parts[2] == "parenright"
        @test length(node.children) == 2
    end

    @testset "\\dbinom wraps NodeKind.Genfrac in NodeKind.StyleOverride(Display)" begin
        tree = parse_latex(raw"\dbinom{a}{b}")
        node = tree.children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Display"
        @test length(node.children) == 1
        @test node.children[1].kind === NodeKind.Genfrac
    end

    @testset "\\tbinom wraps NodeKind.Genfrac in NodeKind.StyleOverride(Text)" begin
        tree = parse_latex(raw"\tbinom{x}{y}")
        node = tree.children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Text"
        @test node.children[1].kind === NodeKind.Genfrac
    end

    @testset "\\bigl( produces NodeKind.BigDelim with correct fields" begin
        tree = parse_latex(raw"\bigl( x \bigr)")
        # First child is \bigl(, last child is \bigr)
        ldelim = tree.children[1]
        rdelim = tree.children[end]
        @test ldelim.kind === NodeKind.BigDelim
        @test rdelim.kind === NodeKind.BigDelim
        # value format: "ps_name\x00size\x00class"
        lparts = split(ldelim.value, "\x00")
        @test lparts[1] == "parenleft"
        @test lparts[2] == "1"
        @test lparts[3] == "o"   # open
        rparts = split(rdelim.value, "\x00")
        @test rparts[1] == "parenright"
        @test rparts[3] == "c"   # close
        @test isempty(ldelim.children)
    end

    @testset "\\Bigr] has size 2 and close class" begin
        node = parse_latex(raw"\Bigr]").children[1]
        @test node.kind === NodeKind.BigDelim
        parts = split(node.value, "\x00")
        @test parts[1] == "bracketright"
        @test parts[2] == "2"
        @test parts[3] == "c"
    end

    @testset "\\bigm| has rel class" begin
        node = parse_latex(raw"\bigm|").children[1]
        @test node.kind === NodeKind.BigDelim
        @test split(node.value, "\x00")[3] == "r"
    end

    @testset "\\Bigg. has null delimiter (empty ps_name)" begin
        node = parse_latex(raw"\Bigg.").children[1]
        @test node.kind === NodeKind.BigDelim
        parts = split(node.value, "\x00")
        @test parts[1] == ""   # null delimiter
        @test parts[2] == "4"
        @test parts[3] == "d"  # ord
    end

    @testset "\\bigl\\langle produces angleleft" begin
        node = parse_latex(raw"\bigl\langle").children[1]
        @test node.kind === NodeKind.BigDelim
        @test split(node.value, "\x00")[1] == "angleleft"
    end

    @testset "\\bigl\\uparrow uses arrow delimiter" begin
        node = parse_latex(raw"\bigl\uparrow").children[1]
        @test node.kind === NodeKind.BigDelim
        @test split(node.value, "\x00")[1] == "uparrow"
    end

    @testset "\\displaystyle consumes rest of group" begin
        tree = parse_latex(raw"{\displaystyle a + b}")
        grp = tree.children[1]
        @test grp.kind === NodeKind.Group
        node = grp.children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Display"
        # children[1] is a NodeKind.Sequence wrapping [a, +, b]
        @test node.children[1].kind === NodeKind.Sequence
        @test length(node.children[1].children) == 3
    end

    @testset "\\scriptstyle has correct style name" begin
        tree = parse_latex(raw"{\scriptstyle x}")
        node = tree.children[1].children[1]
        @test node.kind === NodeKind.StyleOverride
        @test node.value == "Script"
    end

    # ── Sizing commands ────────────────────────────────────────────────────────

    @testset "\\large produces NodeKind.Sizing with multiplier > 1" begin
        tree = parse_latex(raw"{\large x}")
        node = tree.children[1].children[1]
        @test node.kind === NodeKind.Sizing
        @test parse(Float64, node.value) > 1.0
    end

    @testset "\\tiny produces NodeKind.Sizing with multiplier < 1" begin
        tree = parse_latex(raw"{\tiny x}")
        node = tree.children[1].children[1]
        @test node.kind === NodeKind.Sizing
        @test parse(Float64, node.value) < 1.0
    end

    @testset "\\normalsize produces multiplier 1.0" begin
        tree = parse_latex(raw"{\normalsize x}")
        node = tree.children[1].children[1]
        @test node.kind === NodeKind.Sizing
        @test parse(Float64, node.value) ≈ 1.0
    end

    # ── Extensible arrows ──────────────────────────────────────────────────────

    @testset "\\xrightarrow{f} produces NodeKind.XArrow with above label" begin
        tree = parse_latex(raw"\xrightarrow{f}")
        node = tree.children[1]
        @test node.kind === NodeKind.XArrow
        @test node.value == "\\xrightarrow"
        @test length(node.children) == 1   # above only
    end

    @testset "\\xrightarrow[g]{f} has both labels" begin
        tree = parse_latex(raw"\xrightarrow[g]{f}")
        node = tree.children[1]
        @test node.kind === NodeKind.XArrow
        @test length(node.children) == 2   # [above, below]
        @test node.children[1].kind === NodeKind.Char   # above = 'f'
        @test node.children[1].value == "f"
        # below is wrapped in NodeKind.Group
        @test node.children[2].kind === NodeKind.Group
    end

    @testset "\\xleftarrow is also NodeKind.XArrow" begin
        tree = parse_latex(raw"\xleftarrow{n}")
        node = tree.children[1]
        @test node.kind === NodeKind.XArrow
        @test node.value == "\\xleftarrow"
    end

end
