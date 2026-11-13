# Layout tests: single characters, literal commands, operator names, italic
# correction, inter-atom spacing and explicit spaces (TeX rules 5, 6, and 20),
# and style and size overrides.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: core" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    @testset "Single character layout" begin
        boxes = layout(parse_latex("x"), family, Text)
        @test length(boxes) >= 1
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].x ≈ 0.0      # first glyph starts at origin
        @test glyphs[1].y ≈ 0.0      # baseline
        @test glyphs[1].scale ≈ 1.0  # Text style
    end

    @testset "Literal commands emit portable glyphs" begin
        math_cases = (
            raw"\#" => "numbersign",
            raw"\$" => "dollar",
            raw"\%" => "percent",
            raw"\&" => "ampersand",
            raw"\_" => "underscore",
            raw"\{" => "braceleft",
            raw"\}" => "braceright",
            raw"\lbrace" => "braceleft",
            raw"\rbrace" => "braceright",
            raw"\|" => "dblverticalbar",
        )
        for (source, expected_name) in math_cases
            glyph = only(find_glyphs(layout(parse_latex(source), family, Text)))
            @test glyph.element.glyph_name == expected_name
        end

        text_cases = (
            raw"\textdollar" => "dollar",
            raw"\textunderscore" => "underscore",
            raw"\textbraceleft" => "braceleft",
            raw"\textbraceright" => "braceright",
            raw"\textasciitilde" => "asciitilde",
            raw"\textbackslash" => "backslash",
            raw"\textasciicircum" => "asciicircum",
            raw"\textbar" => "bar",
            raw"\textbardbl" => "dblverticalbar",
        )
        for (source, expected_name) in text_cases
            expression = "\\text{" * source * "}"
            glyph = only(find_glyphs(layout(parse_latex(expression), family, Text)))
            @test glyph.element.glyph_name == expected_name
        end
    end

    @testset "\\lbrace and \\rbrace remain valid delimiter aliases" begin
        boxes = layout(
            parse_latex(raw"\left\lbrace x \right\rbrace"),
            family,
            Text,
        )
        names = [box.element.glyph_name for box in find_glyphs(boxes)]
        @test any(contains("braceleft"), names)
        @test any(contains("braceright"), names)
    end

    @testset "\\vert-family delimiters render after \\left/\\right" begin
        for source in (raw"\left\vert x \right\vert", raw"\left\lVert x \right\rVert")
            # x plus one glyph per delimiter (previously null delimiters: x only).
            @test length(find_glyphs(layout(parse_latex(source), family, Text))) >= 3
        end
    end

    @testset "\\sinh, \\cosh, \\tanh, \\coth, \\lg render their operator names" begin
        for name in ("sinh", "cosh", "tanh", "coth", "lg")
            boxes = layout(parse_latex("\\" * name * " x"), family, Text)
            @test length(find_glyphs(boxes)) == length(name) + 1
        end
    end

    @testset "Italic correction after math characters (TeX, XeTeX, LuaTeX)" begin
        # tex.web make_ord: a math character with no subscript is followed by a
        # kern of its italic correction; with a subscript the kern is omitted, the
        # subscript sits at the advance, and a superscript sits the italic
        # correction further right.  XeTeX and LuaTeX keep this for OpenType math
        # fonts, using the MATH table's italic corrections.
        advance(g) = g.element.advance_width / FONT_UPM * g.scale
        ic(g) = get(mt.italic_corrections, g.element.glyph_name, 0) / FONT_UPM * g.scale
        glyphs_of(source) = sort(find_glyphs(layout(parse_latex(source), family, Text)); by = g -> g.x)
        f = first(glyphs_of("f"))
        @test ic(f) > 0.0   # the test relies on a slanted f with an italic correction

        g = glyphs_of("f(x)")   # f, (, x, )
        @test g[2].x ≈ advance(f) + ic(f)
        g = glyphs_of("f^2")
        @test g[2].x ≈ advance(f) + ic(f)
        g = glyphs_of("f_i")
        @test g[2].x ≈ advance(f)
        g = glyphs_of("f_i^2")
        sub = only(filter(b -> b.y < 0.0, g)); sup = only(filter(b -> b.y > 0.0, g))
        @test sub.x ≈ advance(f)
        @test sup.x ≈ advance(f) + ic(f)
        # A one-character group behaves as the character (TeX simplifies {f}).
        @test glyphs_of("{f}_i")[2].x ≈ advance(f)
        # A longer group ends with its last character's correction.
        g = glyphs_of("{ff}_i")
        @test g[3].x ≈ 2 * (advance(f) + ic(f))
        # Upright text and operator names get no correction.
        @test glyphs_of(raw"\text{f}(")[2].x ≈ advance(glyphs_of(raw"\text{f}")[1])
        # Large operators keep TeX's operator rule: subscript at the advance
        # less the correction, superscript at the advance.
        int = first(glyphs_of(raw"\int"))
        g = glyphs_of(raw"\int_0^1")
        sub = only(filter(b -> b.y < int.y, g[2:end])); sup = only(filter(b -> b.y > 0.0, g[2:end]))
        @test sub.x ≈ advance(int) - ic(int)
        @test sup.x ≈ advance(int)
        # Inline math in a document measures to its full advance, so a trailing
        # correction (a kern in TeX, not a box) still separates it from text.
        width_of(source) = layout_document("\$" * source * "\$"; family).width
        @test width_of("f") ≈ advance(f) + ic(f)
        # Scripts end at the further script plus SpaceAfterScript; the
        # correction taken back for the subscript is not added again.
        sas = mt.constants.space_after_script / FONT_UPM
        for source in ("f_i", "f^2", "f_i^2", raw"\int_0", raw"\int^1", raw"\int_0^1")
            g = glyphs_of(source)
            @test width_of(source) ≈ maximum(b.x + advance(b) for b in g[2:end]) + sas
        end
    end

    @testset "Horizontal advance: boxes are left-to-right" begin
        boxes = layout(parse_latex("ab"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        @test glyphs[2].x > glyphs[1].x
    end

    @testset "Operator: \\sin x produces four glyphs" begin
        # \sin → NodeKind.Operator("sin"): three upright glyphs; x → one italic glyph.
        boxes = layout(parse_latex("\\sin x"), family, Display)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 4
        # Operator glyphs are left of the argument glyph.
        op_xs = [glyphs[i].x for i in 1:3]
        arg_x = glyphs[4].x
        @test all(x -> x < arg_x, op_xs)
    end

    @testset "\\operatorname renders correct character count" begin
        boxes = layout(parse_latex("\\operatorname{ker}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
    end

    # ── Inter-atom spacing ──────────────────────────────────────────────────────

    @testset "Inter-atom: ord+bin+ord (a+b) inserts two medium spaces" begin
        boxes = layout(parse_latex("a+b"), family, Text)
        spaces = find_spaces(boxes)
        # Expected: medium space before '+' (ord→bin) and after '+' (bin→ord).
        @test length(spaces) == 2
        medium = (4 / 18) * size_scale(Text, mt.constants)
        @test all(s -> isapprox(s.element.width, medium; atol = 1.0e-6), spaces)
    end

    @testset "Inter-atom: ord+rel+ord (a=b) inserts two thick spaces" begin
        boxes = layout(parse_latex("a=b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 2
        thick = (5 / 18) * size_scale(Text, mt.constants)
        @test all(s -> isapprox(s.element.width, thick; atol = 1.0e-6), spaces)
    end

    @testset "Inter-atom: punct→ord (a,b) inserts thin space after comma" begin
        boxes = layout(parse_latex("a,b"), family, Text)
        spaces = find_spaces(boxes)
        # punct→ord yields thin; there is no space before the comma.
        @test length(spaces) == 1
        thin = (3 / 18) * size_scale(Text, mt.constants)
        @test spaces[1].element.width ≈ thin atol = 1.0e-6
    end

    @testset "Inter-atom: op→ord (\\sin x) inserts thin space" begin
        boxes = layout(parse_latex("\\sin x"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        thin = (3 / 18) * size_scale(Text, mt.constants)
        @test spaces[1].element.width ≈ thin atol = 1.0e-6
    end

    @testset "Inter-atom: Script style suppresses medium/thick spacing" begin
        # In Script style the tight-spacing table applies: ord+bin+ord → no space.
        boxes = layout(parse_latex("a+b"), family, Script)
        spaces = find_spaces(boxes)
        @test length(spaces) == 0
    end

    @testset "Inter-atom: explicit space between ordinary atoms adds no auto-space" begin
        # 'a \quad b': ord-ord spacing is zero, so the \quad is the only Space.
        boxes = layout(parse_latex("a\\quad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
    end

    @testset "Inter-atom: explicit spaces are transparent (a\\,=b keeps thick spaces)" begin
        thin = (3 / 18) * size_scale(Text, mt.constants)
        thick = (5 / 18) * size_scale(Text, mt.constants)
        medium = (4 / 18) * size_scale(Text, mt.constants)
        widths(s) = sort([b.element.width for b in find_spaces(layout(parse_latex(s), family, Text))])
        @test widths(raw"a\,=b") ≈ sort([thin, thick, thick])
        # The binary operator is spaced on both sides, not only after the space.
        @test widths(raw"a\;+b") ≈ sort([thick, medium, medium])
        # A leading binary operator stays an ordinary atom after a space.
        @test widths(raw"\,+b") ≈ [thin]
    end

    @testset "Inter-atom: explicit spaces are transparent to automatic spacing" begin
        # TeX's mlist_to_hlist skips glue and kern nodes when tracking the
        # previous atom type (r_type), and KaTeX's traverseNonSpaceNodes ignores
        # explicit spaces, so automatic spacing still applies across them.
        advance(g) = g.element.advance_width / FONT_UPM * g.scale
        function gaps(source, style)
            glyphs = sort(find_glyphs(layout(parse_latex(source), family, style)); by = g -> g.x)
            return [glyphs[i + 1].x - (glyphs[i].x + advance(glyphs[i])) for i in 1:(length(glyphs) - 1)]
        end
        thin, medium, thick = 3 / 18, 4 / 18, 5 / 18
        # a, thin, medium, +, medium, b: the + stays binary.
        @test gaps(raw"a\,+b", Text) ≈ [thin + medium, medium]
        @test gaps(raw"x \quad = y", Text) ≈ [1.0 + thick, thick]
        @test gaps(raw"a~=b", Text) ≈ [TeXLayout._NORMAL_SPACE_EM + thick, thick]
        # Ordinary atoms: only the explicit space, after f's italic correction.
        ic_f = mt.italic_corrections[TeXLayout.glyph_name_by_codepoint(family, UInt32(0x0001D453))] / FONT_UPM   # 𝑓
        @test gaps(raw"f\,d", Text) ≈ [ic_f + thin]
        # op-op is a thin space, so \int\!\!\int nets one negative thin space.
        @test only(gaps(raw"\int\!\!\int", Text)) ≈ -thin
        # In script styles bin spacing is absent; only the explicit space remains.
        s = mt.constants.script_percent_scale_down / 100
        @test gaps(raw"x_{a\,+b}", Text)[2:end] ≈ [thin * s, 0.0]
        # A leading binary atom is still ordinary (Rule 5), even after a space.
        @test gaps(raw"\,+b", Text) ≈ [0.0]
    end

    @testset "\\quad produces a Space element of width 1 em" begin
        boxes = layout(parse_latex("a\\quad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        # Text-style scale is 1.0; Space width should be 1.0 em.
        @test spaces[1].element.width ≈ 1.0 * size_scale(Text, mt.constants)
    end

    @testset "\\qquad produces a Space element of width 2 em" begin
        boxes = layout(parse_latex("a\\qquad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ 2.0 * size_scale(Text, mt.constants)
    end

    @testset "\\, produces thin space (3/18 em)" begin
        boxes = layout(parse_latex("a\\,b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ (3 / 18) * size_scale(Text, mt.constants)
    end

    @testset "\\! produces negative space" begin
        boxes = layout(parse_latex("a\\!b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width < 0.0
    end

    @testset "\\kern{1em} produces Space of width 1 em" begin
        boxes = layout(parse_latex("a\\kern{1em}b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ 1.0 * size_scale(Text, mt.constants)
    end

    # ── Binary atom reclassification (Rules 5 & 6) ────────────────────────────

    @testset "Rule 5: leading mbin demoted → no space inserted" begin
        # '+x': the '+' is at the start of a list, so it is mbin → mord.
        # No medium space should appear before 'x'.
        boxes_leading = layout(parse_latex("+x"), family, Text)
        spaces_leading = find_spaces(boxes_leading)
        # Compare with 'a+x' where '+' is a genuine binary: should have spaces.
        boxes_binary = layout(parse_latex("a+x"), family, Text)
        spaces_binary = find_spaces(boxes_binary)
        @test length(spaces_leading) < length(spaces_binary)
    end

    @testset "Rule 5: mbin after mopen demoted → no space" begin
        # '(+x)': the '+' immediately follows an open atom → demoted to mord.
        boxes = layout(parse_latex("\\left( +x \\right)"), family, Text)
        spaces = find_spaces(boxes)
        # 'a+x' in the same context produces medium spaces; '(+x)' should not.
        boxes_mid = layout(parse_latex("\\left( a+x \\right)"), family, Text)
        spaces_mid = find_spaces(boxes_mid)
        @test length(spaces) < length(spaces_mid)
    end

    @testset "Rule 6: mbin before mrel demoted → no space before relation" begin
        # 'a+=b': the '+' precedes '=', so it is demoted to mord.
        # A mbin before mrel should produce no medium space after mbin.
        boxes_demoted = layout(parse_latex("a+=b"), family, Text)
        spaces_demoted = find_spaces(boxes_demoted)
        # 'a+b' in the same style has a medium space after '+'.
        boxes_binary = layout(parse_latex("a+b"), family, Text)
        spaces_binary = find_spaces(boxes_binary)
        # 'a+=b' should have fewer or equal number of medium spaces.
        @test length(spaces_demoted) <= length(spaces_binary)
    end

    @testset "Rule 5: mbin after mbin demoted (double binary)" begin
        # 'a++b': the second '+' follows a mbin and is demoted.
        # The result should have fewer spaces than 'a + b + c'.
        boxes_double = layout(parse_latex("a++b"), family, Text)
        boxes_normal = layout(parse_latex("a+c+b"), family, Text)
        spaces_double = find_spaces(boxes_double)
        spaces_normal = find_spaces(boxes_normal)
        @test length(spaces_double) < length(spaces_normal)
    end

    @testset "Spacing advances cursor left-to-right" begin
        # With a quad between a and b, b's x-position must be further right
        # than without spacing.
        boxes_spaced = layout(parse_latex("a\\quad b"), family, Text)
        boxes_plain = layout(parse_latex("ab"), family, Text)
        glyphs_spaced = find_glyphs(boxes_spaced)
        glyphs_plain = find_glyphs(boxes_plain)
        b_x_spaced = glyphs_spaced[2].x
        b_x_plain = glyphs_plain[2].x
        @test b_x_spaced > b_x_plain
    end

    # ── Style overrides ────────────────────────────────────────────────────────

    @testset "\\dfrac inside subscript renders at full scale" begin
        # With plain \frac inside a subscript, the fraction is at script scale.
        # With \dfrac the override forces Display style → scale = 1.0.
        boxes_frac = layout(parse_latex(raw"x_{\frac{a}{b}}"), family, Text)
        boxes_dfrac = layout(parse_latex(raw"x_{\dfrac{a}{b}}"), family, Text)

        # Find all HRule elements (fraction bars); pick the one with largest width
        # (the fraction bar rather than any overline).
        rule_frac = maximum(b.scale for b in find_hrules(boxes_frac); init = 0.0)
        rule_dfrac = maximum(b.scale for b in find_hrules(boxes_dfrac); init = 0.0)
        @test rule_dfrac > rule_frac   # Display forces larger scale
    end

    @testset "\\displaystyle inside group overrides style" begin
        # In a subscript without override the fraction bar is at sub scale.
        # \displaystyle inside the sub forces Display.
        boxes_default = layout(parse_latex(raw"x_{\frac{a}{b}}"), family, Text)
        boxes_override = layout(parse_latex(raw"x_{\displaystyle \frac{a}{b}}"), family, Text)

        rule_default = maximum(b.scale for b in find_hrules(boxes_default); init = 0.0)
        rule_override = maximum(b.scale for b in find_hrules(boxes_override); init = 0.0)
        @test rule_override > rule_default
    end

    @testset "\\textstyle inside display does not enlarge the fraction" begin
        boxes_display = layout(parse_latex(raw"\frac{a}{b}"), family, Display)
        boxes_textstyle = layout(parse_latex(raw"{\textstyle \frac{a}{b}}"), family, Display)
        # In Display the numerator style is Text (scale=1); in Text style it is Script (scale<1).
        # So \textstyle inside display should produce a smaller numerator glyph y-position.
        top_display = maximum(
            b.y + (b.element isa Glyph ? b.element.y_max / mt.upm * b.scale : 0.0)
                for b in layout(parse_latex(raw"\frac{a}{b}"), family, Display)
        )
        top_textstyle = maximum(
            b.y + (b.element isa Glyph ? b.element.y_max / mt.upm * b.scale : 0.0)
                for b in layout(parse_latex(raw"{\textstyle \frac{a}{b}}"), family, Display)
        )
        @test top_textstyle <= top_display + 1.0e-6
    end

    # ── Sizing commands ────────────────────────────────────────────────────────

    @testset "\\large produces larger glyphs than \\normalsize" begin
        boxes_normal = layout(parse_latex(raw"{\normalsize x}"), family, Text)
        boxes_large = layout(parse_latex(raw"{\large x}"), family, Text)
        scale_normal = find_glyphs(boxes_normal)[1].scale
        scale_large = find_glyphs(boxes_large)[1].scale
        @test scale_large > scale_normal
    end

    @testset "\\tiny produces smaller glyphs than \\normalsize" begin
        boxes_normal = layout(parse_latex(raw"{\normalsize x}"), family, Text)
        boxes_tiny = layout(parse_latex(raw"{\tiny x}"), family, Text)
        scale_normal = find_glyphs(boxes_normal)[1].scale
        scale_tiny = find_glyphs(boxes_tiny)[1].scale
        @test scale_tiny < scale_normal
    end

    @testset "\\large scale is 1.2× base in Text style" begin
        boxes = layout(parse_latex(raw"{\large x}"), family, Text)
        g = find_glyphs(boxes)[1]
        @test g.scale ≈ 1.2 * 1.0   # Text scale=1.0, large multiplier=1.2
    end
end
