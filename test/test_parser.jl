# Tests for the LaTeX parser / AST builder (src/parser.jl).
#
# Tests check the shape of the AST, not rendering details.
# The convenience form `parse_latex(string)` is used throughout.

@testset "Parser" begin

    @testset "Single character" begin
        tree = parse_latex("x")
        @test tree.kind === NKSequence
        @test length(tree.children) == 1
        @test tree.children[1].kind  === NKChar
        @test tree.children[1].value == "x"
    end

    @testset "Superscript: x^2" begin
        tree = parse_latex("x^2")
        @test tree.kind === NKSequence
        sup = tree.children[1]
        @test sup.kind === NKSuperscript
        @test length(sup.children) == 2   # [base, exponent]
        @test sup.children[1].kind  === NKChar
        @test sup.children[1].value == "x"
        @test sup.children[2].kind  === NKChar
        @test sup.children[2].value == "2"
    end

    @testset "Subscript: x_i" begin
        tree = parse_latex("x_i")
        sub = tree.children[1]
        @test sub.kind === NKSubscript
        @test sub.children[1].value == "x"
        @test sub.children[2].value == "i"
    end

    @testset "Both sub and sup: x_i^2" begin
        tree = parse_latex("x_i^2")
        dec = tree.children[1]
        @test dec.kind === NKDecorated
        # children are always [base, subscript, superscript] regardless of source order
        @test length(dec.children) == 3
        @test dec.children[1].value == "x"  # base
        @test dec.children[2].value == "i"  # subscript
        @test dec.children[3].value == "2"  # superscript
    end

    @testset "Fraction: \\frac{a}{b}" begin
        tree = parse_latex("\\frac{a}{b}")
        frac = tree.children[1]
        @test frac.kind === NKFrac
        @test length(frac.children) == 2   # [numerator, denominator]
        # Numerator and denominator are single-element sequences or chars
        num = frac.children[1]
        den = frac.children[2]
        # _parse_argument! unwraps single-element braced groups, so {a} → NKChar("a").
        @test num.kind === NKChar && num.value == "a"
        @test den.kind === NKChar && den.value == "b"
    end

    @testset "Square root: \\sqrt{x}" begin
        tree = parse_latex("\\sqrt{x}")
        sqrt_node = tree.children[1]
        @test sqrt_node.kind === NKSqrt
        # children[1] is the body; no optional degree argument
        @test length(sqrt_node.children) >= 1
    end

    @testset "Sqrt with degree: \\sqrt[3]{x}" begin
        tree = parse_latex("\\sqrt[3]{x}")
        sqrt_node = tree.children[1]
        @test sqrt_node.kind === NKSqrt
        # Degree and body both present
        @test length(sqrt_node.children) == 2
    end

    @testset "Explicit group: {ab}" begin
        tree = parse_latex("{ab}")
        grp = tree.children[1]
        @test grp.kind === NKGroup
        @test length(grp.children) == 2
    end

    @testset "Command atom: \\alpha" begin
        tree = parse_latex("\\alpha")
        cmd = tree.children[1]
        @test cmd.kind === NKCommand
        @test cmd.value == "\\alpha"
    end

    @testset "Nested: \\frac{x^2}{y_i}" begin
        tree = parse_latex("\\frac{x^2}{y_i}")
        frac = tree.children[1]
        @test frac.kind === NKFrac
        num = frac.children[1]
        # Numerator should contain a superscript
        num_inner = num.kind === NKSequence ? num.children[1] : num
        @test num_inner.kind === NKSuperscript
    end

    @testset "Multi-character sequence: abc" begin
        tree = parse_latex("abc")
        @test tree.kind === NKSequence
        @test length(tree.children) == 3
        @test all(c.kind === NKChar for c in tree.children)
    end

    @testset "Named operator: \\sin" begin
        tree = parse_latex("\\sin")
        op = tree.children[1]
        @test op.kind  === NKOperator
        @test op.value == "sin"
    end

    @testset "\\operatorname{myop}" begin
        tree = parse_latex("\\operatorname{myop}")
        op = tree.children[1]
        @test op.kind  === NKOperator
        @test op.value == "myop"
    end

    @testset "Braced superscript: x^{10}" begin
        tree = parse_latex("x^{10}")
        sup = tree.children[1]
        @test sup.kind === NKSuperscript
        exp = sup.children[2]
        # Exponent is either a group or sequence containing chars '1' and '0'
        @test exp.kind === NKGroup || exp.kind === NKSequence
        chars = exp.kind === NKGroup ? exp.children : exp.children
        @test length(chars) == 2
        @test chars[1].value == "1"
        @test chars[2].value == "0"
    end

    @testset "Thin space: \\," begin
        tree = parse_latex("a\\,b")
        @test length(tree.children) == 3
        sp = tree.children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 3/18
    end

    @testset "Medium space: \\:" begin
        sp = parse_latex("a\\:b").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 4/18
    end

    @testset "Thick space: \\;" begin
        sp = parse_latex("a\\;b").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 5/18
    end

    @testset "Negative thin space: \\!" begin
        sp = parse_latex("a\\!b").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ -3/18
    end

    @testset "Aliases: \\quad, \\qquad, \\enspace" begin
        @test parse(Float64, parse_latex("a\\quad b").children[2].value) ≈ 1.0
        @test parse(Float64, parse_latex("a\\qquad b").children[2].value) ≈ 2.0
        @test parse(Float64, parse_latex("a\\enspace b").children[2].value) ≈ 0.5
    end

    @testset "Aliases: \\thinspace, \\medspace, \\thickspace" begin
        @test parse(Float64, parse_latex("a\\thinspace b").children[2].value) ≈ 3/18
        @test parse(Float64, parse_latex("a\\medspace b").children[2].value) ≈ 4/18
        @test parse(Float64, parse_latex("a\\thickspace b").children[2].value) ≈ 5/18
    end

    @testset "Kern: \\kern1em (unbraced)" begin
        sp = parse_latex("a\\kern1emb").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 1.0
    end

    @testset "Kern: \\kern{0.5em} (braced)" begin
        sp = parse_latex("a\\kern{0.5em}b").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 0.5
    end

    @testset "Kern: \\kern{-0.25em} (negative)" begin
        sp = parse_latex("a\\kern{-0.25em}b").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ -0.25
    end

    @testset "Mkern: \\mkern18mu gives 1em" begin
        sp = parse_latex("a\\mkern18mub").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 1.0
    end

    @testset "Hskip: \\hskip2em gives 2em" begin
        sp = parse_latex("a\\hskip2emb").children[2]
        @test sp.kind === NKSpace
        @test parse(Float64, sp.value) ≈ 2.0
    end

    @testset "\\left(…\\right) stores glyph names in value" begin
        node  = parse_latex("\\left( x \\right)")
        delim = node.children[1]
        @test delim.kind === NKDelimited
        parts = split(delim.value, "\x00", limit=2)
        @test parts[1] == "parenleft"
        @test parts[2] == "parenright"
        # \right is consumed — only x remains as an inner child
        @test all(c.kind !== NKCommand || c.value != "\\right" for c in delim.children)
        @test any(c -> c.kind === NKChar && c.value == "x", delim.children)
    end

    @testset "\\left.…\\right) null left delimiter" begin
        node  = parse_latex("\\left. x \\right)")
        delim = node.children[1]
        @test delim.kind === NKDelimited
        parts = split(delim.value, "\x00", limit=2)
        @test parts[1] == ""          # null delimiter maps to empty string
        @test parts[2] == "parenright"
    end

    @testset "\\left\\{…\\right\\} brace delimiters" begin
        node  = parse_latex("\\left\\{ x \\right\\}")
        delim = node.children[1]
        @test delim.kind === NKDelimited
        parts = split(delim.value, "\x00", limit=2)
        @test parts[1] == "braceleft"
        @test parts[2] == "braceright"
    end

    # ── Font switching ──────────────────────────────────────────────────────────

    @testset "\\mathbf{x}: NKFontSwitch with variant mathbf" begin
        tree = parse_latex("\\mathbf{x}")
        fs = tree.children[1]
        @test fs.kind  === NKFontSwitch
        @test fs.value == "mathbf"
        @test length(fs.children) == 1
        @test fs.children[1].kind  === NKChar
        @test fs.children[1].value == "x"
    end

    @testset "\\mathit, \\mathrm, \\mathbb, \\mathcal, \\mathfrak produce NKFontSwitch" begin
        for (cmd, variant) in (("\\mathit",  "mathit"),  ("\\mathrm",  "mathrm"),
                                ("\\mathbb",  "mathbb"),  ("\\mathcal",  "mathcal"),
                                ("\\mathfrak","mathfrak"), ("\\mathsf",  "mathsf"),
                                ("\\mathtt",  "mathtt"))
            node = parse_latex("$(cmd){A}").children[1]
            @test node.kind  === NKFontSwitch
            @test node.value == variant
        end
    end

    @testset "Aliases: \\Bbb, \\bold, \\frak produce NKFontSwitch" begin
        @test parse_latex("\\Bbb{A}").children[1].value  == "mathbb"
        @test parse_latex("\\bold{x}").children[1].value == "mathbf"
        @test parse_latex("\\frak{A}").children[1].value == "mathfrak"
        for alias in ("\\Bbb", "\\bold", "\\frak")
            @test parse_latex("$(alias){x}").children[1].kind === NKFontSwitch
        end
    end

    @testset "\\boldsymbol and \\bm are aliases for boldsymbol" begin
        @test parse_latex("\\boldsymbol{x}").children[1].value == "boldsymbol"
        @test parse_latex("\\bm{x}").children[1].value         == "boldsymbol"
    end

    @testset "\\mathbf{x_i}: font switch wraps a subscript" begin
        # \mathbf{x_i} → NKFontSwitch("mathbf", [NKSubscript([NKChar("x"), NKChar("i")])])
        tree = parse_latex("\\mathbf{x_i}")
        fs = tree.children[1]
        @test fs.kind === NKFontSwitch
        body = fs.children[1]
        @test body.kind === NKSubscript
        @test body.children[1].kind  === NKChar
        @test body.children[1].value == "x"
        @test body.children[2].kind  === NKChar
        @test body.children[2].value == "i"
    end

    @testset "\\mathbf{abc}: multi-character body is a sequence/group" begin
        tree = parse_latex("\\mathbf{abc}")
        fs = tree.children[1]
        @test fs.kind === NKFontSwitch
        @test fs.value == "mathbf"
        # {abc} is parsed as a group containing three NKChar children.
        body = fs.children[1]
        @test body.kind === NKGroup || body.kind === NKSequence
        @test length(body.children) == 3
        @test all(c.kind === NKChar for c in body.children)
    end

    @testset "\\widehat{x}: produces NKAccent with value \\widehat" begin
        tree = parse_latex("\\widehat{x}")
        acc  = tree.children[1]
        @test acc.kind  === NKAccent
        @test acc.value == "\\widehat"
        @test length(acc.children) == 1
        @test acc.children[1].kind === NKChar
    end

    @testset "\\widetilde{x}: produces NKAccent with value \\widetilde" begin
        tree = parse_latex("\\widetilde{x}")
        acc  = tree.children[1]
        @test acc.kind  === NKAccent
        @test acc.value == "\\widetilde"
        @test length(acc.children) == 1
        @test acc.children[1].kind === NKChar
    end

    @testset "\\widehat{xyz}: wide accent over multi-char base" begin
        tree = parse_latex("\\widehat{xyz}")
        acc  = tree.children[1]
        @test acc.kind  === NKAccent
        @test acc.value == "\\widehat"
        # {xyz} becomes a group or sequence with three NKChar children.
        body = acc.children[1]
        @test body.kind === NKGroup || body.kind === NKSequence
        @test length(body.children) == 3
    end

end
