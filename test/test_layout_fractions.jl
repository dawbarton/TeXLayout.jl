# Layout tests: fractions (TeX rule 15), radicals (rule 11), and binomials.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: fractions and radicals" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    @testset "Fraction rule is at axis height" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        hrules = find_hrules(boxes)
        @test length(hrules) >= 1
        rule = hrules[1]
        axis_em = mt.constants.axis_height / FONT_UPM
        half_thickness = rule.element.thickness / 2
        # Rule centre (bottom edge + half thickness) must sit exactly on the axis height.
        @test (rule.y + half_thickness) ≈ axis_em atol = 1.0e-6
    end

    @testset "Fraction rule thickness" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        hrules = find_hrules(boxes)
        @test length(hrules) >= 1
        expected_thickness = mt.constants.fraction_rule_thickness / FONT_UPM
        @test hrules[1].element.thickness ≈ expected_thickness atol = 1.0e-6
    end

    @testset "Fraction: numerator above axis, denominator below" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        ys = sort([b.y for b in glyphs]; rev = true)  # highest first
        axis_em = mt.constants.axis_height / FONT_UPM
        @test ys[1] > axis_em   # numerator above axis
        @test ys[2] < axis_em   # denominator below axis
    end

    @testset "Display style: numerator shift uses display variant" begin
        # In Display style, FractionNumeratorDisplayStyleShiftUp should be used,
        # which is larger than FractionNumeratorShiftUp.
        boxes_display = layout(parse_latex("\\frac{a}{b}"), family, Display)
        boxes_text = layout(parse_latex("\\frac{a}{b}"), family, Text)
        num_y_display = maximum(b.y for b in find_glyphs(boxes_display))
        num_y_text = maximum(b.y for b in find_glyphs(boxes_text))
        # Display numerator uses FractionNumeratorDisplayStyleShiftUp (677) vs
        # FractionNumeratorShiftUp (394), so it must be strictly higher.
        @test num_y_display > num_y_text
    end

    @testset "Sqrt: radical bar above radicand" begin
        boxes = layout(parse_latex("\\sqrt{x}"), family, Text)
        hrules = find_hrules(boxes)
        glyphs = find_glyphs(boxes)
        @test length(hrules) >= 1
        @test length(glyphs) >= 2  # at least one radical glyph + one body glyph
        # The radical glyph(s) are placed to the left of (or at the same x as)
        # the body; exclude them by keeping only glyphs at x > the minimum x.
        rad_x = minimum(b.x for b in glyphs)
        body_glyphs = filter(b -> b.x > rad_x, glyphs)
        @test !isempty(body_glyphs)
        radicand_y = maximum(
            b.y + b.element.y_max / FONT_UPM * b.scale
                for b in body_glyphs
        )
        rule = hrules[1]
        rule_y = rule.y
        @test rule_y >= radicand_y - 1.0e-6

        radical_glyphs = filter(b -> b.x == rad_x, glyphs)
        radical_advance = maximum(
            b.element.advance_width / FONT_UPM * b.scale
                for b in radical_glyphs
        )
        body_x = minimum(b.x for b in body_glyphs)
        @test body_x - rad_x ≈ radical_advance atol = 1.0e-6
        @test body_x - rule.x ≈ rule.element.thickness / 2 atol = 1.0e-6
    end

    @testset "Sqrt with degree places root index" begin
        boxes = layout(parse_latex("\\sqrt[3]{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        # The degree is set in ScriptScript style, so it uses the ssty=1 alternate.
        degree = only(filter(b -> b.element.glyph_name == "three.sts", glyphs))
        radical = only(filter(b -> startswith(b.element.glyph_name, "radical"), glyphs))
        body = only(filter(b -> b.element.glyph_name == "u1D465", glyphs))

        @test degree.scale ≈ mt.constants.script_script_percent_scale_down / 100 atol = 1.0e-6
        @test radical.x < degree.x < body.x
        @test body.x - radical.x ≈ radical.element.advance_width / FONT_UPM * radical.scale atol = 1.0e-6

        # RadicalDegreeBottomRaisePercent is a proportion of the sign's height
        # (ascender + descender), measured from the bottom of the sign; as in
        # LuaTeX's make_radical, it sets the degree's baseline.
        radical_top = radical.y + radical.element.y_max / FONT_UPM * radical.scale
        radical_bottom = radical.y + radical.element.y_min / FONT_UPM * radical.scale
        expected = radical_bottom + mt.constants.radical_degree_bottom_raise_percent / 100 *
            (radical_top - radical_bottom)
        @test degree.y ≈ expected atol = 1.0e-6
    end

    @testset "Sqrt degree matches LuaTeX's \\Uroot" begin
        # LuaLaTeX + unicode-math + NewCMMath at 10 pt: the degree's baseline is
        # 3.605 pt up in Text style and 4.095 pt in Display style (measured from
        # the height of \sqrt[\rule{1pt}{60pt}]{x}).  A degree with a descender
        # hangs below that baseline rather than raising it.
        for (style, expected) in ((Text, 0.3605), (Display, 0.4095))
            for (src, degree_ps) in (("\\sqrt[3]{x}", "three.sts"), ("\\sqrt[p]{x}", "u1D45D.sts"))
                degree = only(
                    filter(
                        b -> b.element.glyph_name == degree_ps,
                        find_glyphs(layout(parse_latex(src), family, style))
                    )
                )
                @test degree.y ≈ expected atol = 1.0e-4
            end
        end
        # The negative after-degree kern never pulls the sign left of where it
        # sits without a degree.  A narrow degree leaves the sign in place; the
        # ssty-wide 3 overflows the kern and pushes it right (LuaTeX: \sqrt{x}
        # is 14.05 pt wide and \sqrt[3]{x} 14.675 pt).
        sign_x(src) = only(b.x for b in find_glyphs(layout(parse_latex(src), family, Text)) if startswith(b.element.glyph_name, "radical"))
        @test sign_x(raw"\sqrt[.]{x}") ≈ sign_x(raw"\sqrt{x}") atol = 1.0e-9
        @test sign_x(raw"\sqrt[3]{x}") - sign_x(raw"\sqrt{x}") ≈ 0.0625 atol = 1.0e-4
    end

    @testset "Sqrt degree is measured from the bottom of a deep radical sign" begin
        percent = mt.constants.radical_degree_bottom_raise_percent / 100
        for (source, style) in ((raw"\sqrt[3]{\frac{a}{b}}", Display), (raw"\sqrt[n]{y}", Text))
            glyphs = find_glyphs(layout(parse_latex(source), family, style))
            degree = argmin(b -> b.scale, glyphs)   # the ScriptScript-size index
            radical = only(filter(b -> startswith(b.element.glyph_name, "radical"), glyphs))
            radical_top = radical.y + radical.element.y_max / FONT_UPM * radical.scale
            radical_bottom = radical.y + radical.element.y_min / FONT_UPM * radical.scale
            @test radical_bottom < 0.0
            @test degree.y ≈ radical_bottom + percent * (radical_top - radical_bottom) atol = 1.0e-6
            # The index sits within the sign's height rather than above it.
            @test degree.y + degree.element.y_max / FONT_UPM * degree.scale < radical_top
        end
    end

    @testset "Nested sqrt: radicand starts at radical advance width" begin
        boxes = layout(
            parse_latex("\\sqrt{1 + \\sqrt{1 + \\sqrt{1 + \\sqrt{1 + x}}}}"),
            family,
            Text,
        )
        hrules = find_hrules(boxes)
        radical_glyphs = filter(b -> startswith(b.element.glyph_name, "radical"), find_glyphs(boxes))
        @test length(radical_glyphs) == 4
        @test length(hrules) >= length(radical_glyphs)

        for radical in radical_glyphs
            radical_top = radical.y + radical.element.y_max / FONT_UPM * radical.scale
            match = findfirst(hrules) do rule
                rule_top = rule.y + rule.element.thickness
                isapprox(rule_top, radical_top; atol = 1.0e-6)
            end
            @test match !== nothing
            rule = hrules[match]
            body_x = rule.x + rule.element.thickness / 2
            expected = radical.element.advance_width / FONT_UPM * radical.scale
            @test body_x - radical.x ≈ expected atol = 1.0e-6
        end
    end

    @testset "Nested sqrt: repeated plus glyphs stay on one baseline" begin
        boxes = layout(
            parse_latex("\\sqrt{1 + \\sqrt{1 + \\sqrt{1 + \\sqrt{1 + x}}}}"),
            family,
            Text,
        )
        pluses = filter(b -> b.element.glyph_name == "plus", find_glyphs(boxes))
        @test length(pluses) == 4
        reference_y = pluses[1].y
        @test all(isapprox(p.y, reference_y; atol = 1.0e-6) for p in pluses)
    end

    # ── Binomial coefficients ──────────────────────────────────────────────────

    @testset "\\binom{a}{b} produces more glyphs than \\frac{a}{b}" begin
        # \binom adds two delimiter glyphs (parenleft + parenright) that \frac lacks.
        boxes_frac = layout(parse_latex(raw"\frac{a}{b}"), family, Display)
        boxes_binom = layout(parse_latex(raw"\binom{a}{b}"), family, Display)
        @test length(find_glyphs(boxes_binom)) == length(find_glyphs(boxes_frac)) + 2
    end

    @testset "Fractions and undelimited arrays are Ord atoms" begin
        # LaTeX's \frac and \binom are `{…\over…}`, an Ord; matrix, array,
        # aligned, and smallmatrix are a \vcenter, an Ord; \left…\right and the
        # delimited environments are Inner.  The gap between two atoms is
        # measured as the marker's origin minus the first atom's width;
        # LuaLaTeX puts no space in the Ord pairs and a thin space (1/6 em)
        # in the Inner ones.
        marker_x(src) = only(b.x for b in find_glyphs(layout(parse_latex(src * "1"), family, Text)) if b.element.glyph_name == "one")
        advance(src) = TeXLayout.measure(layout(parse_latex(src), family, Text), Float64(FONT_UPM)).width
        for (atom, gap) in (
                (raw"\frac{a}{2}", 0.0), (raw"\binom{a}{2}", 0.0), (raw"\dfrac{a}{2}", 0.0),
                (raw"\begin{matrix} a \end{matrix}", 0.0), (raw"\begin{array}{c} a \end{array}", 0.0),
                (raw"\begin{smallmatrix} a \end{smallmatrix}", 0.0),
                (raw"\left(a\right)", 1 / 6), (raw"\begin{pmatrix} a \end{pmatrix}", 1 / 6),
            )
            @test marker_x(atom) - advance(atom) ≈ gap atol = 1.0e-9
        end
        # LuaLaTeX widths at 10 pt: a\frac{1}{2} 11.673 pt, \frac{1}{2}( 10.273 pt.
        @test advance(raw"a\frac{1}{2}") ≈ 1.1673 atol = 1.0e-4
        @test advance(raw"\frac{1}{2}\begin{pmatrix} a \end{pmatrix}") ≈ 2.177962 atol = 1.0e-4
    end

    @testset "Null delimiters are \\nulldelimiterspace wide" begin
        # TeX flanks \frac with null delimiters of \nulldelimiterspace (1.2 pt at
        # 10 pt), unscaled in script styles: XeLaTeX sets \scriptstyle\frac{a}{a}
        # exactly 2.4 pt wider than \scriptscriptstyle a.
        nds = TeXLayout._NULL_DELIMITER_SPACE
        @test nds == 0.12
        for style in (Display, Text, Script)
            frac = layout(parse_latex(raw"\frac{a}{a}"), family, style)
            numer = layout(parse_latex("a"), family, frac_num_style(style))
            rule = only(find_hrules(frac))
            @test rule.x ≈ nds
            @test TeXLayout.measure(frac, Float64(FONT_UPM)).width ≈
                TeXLayout.measure(numer, Float64(FONT_UPM)).width + 2nds atol = 1.0e-9
        end
        # \left. and the missing delimiter of cases give the same space.
        left_dot = layout(parse_latex(raw"\left. x \right|"), family, Text)
        x = only(b for b in find_glyphs(left_dot) if b.element.glyph_name == "u1D465")
        @test x.x ≈ nds
        cases = layout(parse_latex(raw"\begin{cases} x \end{cases}"), family, Text)
        @test any(b -> b.element isa Space && b.element.width == nds, cases)
    end

    @testset "\\binom{a}{b}: numerator above denominator" begin
        boxes = layout(parse_latex(raw"\binom{a}{b}"), family, Display)
        glyphs = find_glyphs(boxes)
        # The 'a' (numerator) and 'b' (denominator) glyphs should be present.
        # The numerator glyph should have a strictly higher y than the denominator.
        @test length(glyphs) >= 4   # left paren + a + b + right paren
        ys = sort(unique(round(g.y; digits = 6) for g in glyphs))
        @test length(ys) >= 2   # at least two distinct y-levels
        @test maximum(g.y for g in glyphs) > minimum(g.y for g in glyphs)
    end

    @testset "\\binom: TeX Rule 15c with the MATH Stack* constants" begin
        # A rule-less fraction uses num1/denom1 (Display) or num3/denom2 and one
        # mutual clearance, 7θ or 3θ, between numerator and denominator, adding
        # half of any shortfall to each shift (tex.web, make_fraction).  The
        # OpenType equivalents are the Stack* constants (LuaTeX make_fraction).
        c = mt.constants
        ink_top(g) = g.y + g.element.y_max / FONT_UPM * g.scale
        ink_bottom(g) = g.y + g.element.y_min / FONT_UPM * g.scale
        for (style, up, down, gap) in (
                (Display, c.stack_top_display_style_shift_up, c.stack_bottom_display_style_shift_down, c.stack_display_style_gap_min),
                (Text, c.stack_top_shift_up, c.stack_bottom_shift_down, c.stack_gap_min),
            )
            up, down, gap = up / FONT_UPM, down / FONT_UPM, gap / FONT_UPM
            # Vertical shift of an operand inside the binomial: match its glyphs
            # against the same operand laid out alone in its own style.
            function operand_shift(boxes, source, operand_style)
                alone = find_glyphs(layout(parse_latex(source), family, operand_style))
                return only(
                        unique(
                            round(b.y - a.y; digits = 9) for a in alone for b in boxes
                            if b.element == a.element && b.scale ≈ a.scale
                        )
                    ), alone
            end

            # Shallow operands: the standard shifts apply (no shortfall in New CM).
            boxes = find_glyphs(layout(parse_latex(raw"\binom{n}{k}"), family, style))
            num_shift, _ = operand_shift(boxes, "n", frac_num_style(style))
            den_shift, _ = operand_shift(boxes, "k", frac_den_style(style))
            @test num_shift ≈ up atol = 1.0e-9
            @test -den_shift ≈ down atol = 1.0e-9

            # Deep operands force the mutual clamp: both shifts grow by the same
            # amount, and the clearance becomes exactly the gap minimum.
            num_src, den_src = raw"\frac{a}{\frac{b}{c}}", raw"\frac{\frac{d}{e}}{f}"
            boxes = find_glyphs(layout(parse_latex("\\binom{" * num_src * "}{" * den_src * "}"), family, style))
            num_shift, num_alone = operand_shift(boxes, num_src, frac_num_style(style))
            den_shift, den_alone = operand_shift(boxes, den_src, frac_den_style(style))
            Δnum, Δden = num_shift - up, -den_shift - down
            @test Δnum > 0.0
            @test Δnum ≈ Δden atol = 1.0e-9
            num_depth = -minimum(ink_bottom, num_alone)
            den_height = maximum(ink_top, den_alone)
            @test (num_shift - num_depth) - (den_height + den_shift) ≈ gap atol = 1.0e-9
        end
    end

    @testset "\\binom delimiters have TeX's fixed delim1/delim2 sizes" begin
        # Rule 15e: the delimiters of a generalized fraction are sized from
        # delim1 (Display style, 2.39 em in Computer Modern) or delim2 (1.01 em),
        # not from the content.  The smallest variant at least that tall is used.
        variants = mt.vert_constructions["parenleft"].variants
        expected(size_em) = first(v.glyph_name for v in variants if v.advance >= size_em * FONT_UPM)
        paren(source, style) = only(
            filter(g -> startswith(g.element.glyph_name, "parenleft"), find_glyphs(layout(parse_latex(source), family, style)))
        )
        for source in (raw"\binom{n}{k}", raw"\binom{\frac{a}{b}}{\frac{c}{d}}", raw"\binom{1}{2}")
            @test paren(source, Display).element.glyph_name == expected(2.39)
            @test paren(source, Text).element.glyph_name == expected(1.01)
        end
        # In a superscript, delim2 at script size: the same variant, scaled.
        p = paren(raw"x^{\binom{n}{k}}", Text)
        @test p.element.glyph_name == expected(1.01)
        @test p.scale ≈ mt.constants.script_percent_scale_down / 100
    end

    @testset "\\binom{a}{b} contains no HRule (no fraction bar)" begin
        boxes = layout(parse_latex(raw"\binom{a}{b}"), family, Display)
        @test isempty(find_hrules(boxes))
    end

    @testset "\\dbinom forces Display scale vs \\binom in Text style" begin
        # In Text style \binom uses Text-style shifts (smaller); \dbinom forces Display.
        boxes_binom = layout(parse_latex(raw"\binom{a}{b}"), family, Text)
        boxes_dbinom = layout(parse_latex(raw"\dbinom{a}{b}"), family, Text)
        # Display style makes the whole thing taller.
        top_binom = maximum(
            b.y + (b.element isa Glyph ? b.element.y_max / mt.upm * b.scale : 0.0)
                for b in boxes_binom
        )
        top_dbinom = maximum(
            b.y + (b.element isa Glyph ? b.element.y_max / mt.upm * b.scale : 0.0)
                for b in boxes_dbinom
        )
        @test top_dbinom > top_binom
    end

    @testset "\\binom with complex arguments does not crash" begin
        boxes = layout(parse_latex(raw"\binom{\frac{x}{y}}{z}"), family, Display)
        @test !isempty(boxes)
    end
end
