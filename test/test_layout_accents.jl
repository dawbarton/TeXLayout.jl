# Layout tests: accents (TeX rule 12), wide accents, `\overline` and
# `\underline`, and horizontal braces.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: accents and braces" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    # ── Accent layout (Rule 12) ───────────────────────────────────────────────

    @testset "Accent: \\hat{x} emits base and accent glyphs" begin
        boxes = layout(parse_latex("\\hat{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        # Must have at least 2 glyphs: the base 'x' and the circumflex.
        @test length(glyphs) >= 2
    end

    @testset "Accent: \\hat{x} base glyph has same advance as plain x" begin
        boxes_hat = layout(parse_latex("\\hat{x}"), family, Text)
        boxes_plain = layout(parse_latex("x"), family, Text)
        # The base glyph should be identical; only the accent is added on top.
        base_in_hat = argmin(b -> b.x, find_glyphs(boxes_hat))
        base_in_plain = find_glyphs(boxes_plain)[1]
        @test base_in_hat.element.advance_width == base_in_plain.element.advance_width
    end

    @testset "Accent: \\hat{x} accent glyph ink top exceeds base ink top" begin
        boxes = layout(parse_latex("\\hat{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
        upm = Float64(mt.upm)
        # Ink top of each box = b.y + element.y_max / upm * b.scale.
        ink_tops = [b.y + b.element.y_max / upm * b.scale for b in glyphs]
        # The base glyph is at the lower ink top; the accent must be higher.
        @test maximum(ink_tops) > minimum(ink_tops)
        # Base glyph must sit at y = 0 (formula baseline).
        base_box = argmin(b -> b.y, glyphs)
        @test base_box.y ≈ 0.0
    end

    @testset "Accent: \\bar{\\alpha} renders without error" begin
        boxes = layout(parse_latex("\\bar{\\alpha}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
    end

    @testset "Accent: \\vec{v} renders without error" begin
        boxes = layout(parse_latex("\\vec{v}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
    end

    @testset "Accent: all non-stretchy commands render" begin
        for cmd in (
                "\\hat", "\\acute", "\\grave", "\\ddot", "\\tilde",
                "\\bar", "\\breve", "\\check", "\\dot", "\\mathring", "\\vec",
            )
            boxes = layout(parse_latex("$(cmd){x}"), family, Text)
            glyphs = find_glyphs(boxes)
            @test length(glyphs) >= 1   # at minimum the base must render
        end
    end

    @testset "Accent: Rule 12 attaches scripts to the accented character" begin
        # Script positions on an accented single character match the bare
        # character: the accent neither lowers a subscript nor raises a superscript.
        script_ys(expr) = sort([b.y for b in find_glyphs(layout(parse_latex(expr), family, Display)) if b.scale < 0.99])
        @test script_ys(raw"\hat{y}_{t+1}") ≈ script_ys(raw"y_{t+1}")
        @test script_ys(raw"\tilde{A}^2") ≈ script_ys(raw"A^2")
        @test script_ys(raw"\vec{v}_i^2") ≈ script_ys(raw"v_i^2")
        @test script_ys(raw"\widehat{x}^2") ≈ script_ys(raw"x^2")
        # A multi-character accented base is still a compound box (Rule 18a).
        @test script_ys(raw"\widehat{xy}^2") != script_ys(raw"{xy}^2")
    end

    @testset "Wide accent: \\widehat{x} emits base and accent" begin
        boxes = layout(parse_latex("\\widehat{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2   # base glyph + at least one accent glyph
    end

    @testset "Wide accent: \\widetilde{x} emits base and accent" begin
        boxes = layout(parse_latex("\\widetilde{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
    end

    @testset "Wide accent: \\widehat{xyz} emits accent above multi-char base" begin
        boxes = layout(parse_latex("\\widehat{xyz}"), family, Text)
        glyphs = find_glyphs(boxes)
        # Three base characters plus at least one accent part.
        @test length(glyphs) >= 4
        upm = Float64(mt.upm)
        # The accent's ink top must exceed the base's ink top.
        # Base glyphs are the first three pushed; accent glyph(s) follow.
        base_top = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs[1:3])
        accent_top = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs[4:end])
        @test accent_top > base_top
    end

    @testset "Wide accent: \\widehat base glyphs have same advance as plain xyz" begin
        boxes_wide = layout(parse_latex("\\widehat{xyz}"), family, Text)
        boxes_plain = layout(parse_latex("xyz"), family, Text)
        upm = Float64(mt.upm)
        # The base glyphs (first three) should be laid out identically to plain xyz.
        # The accent glyph may overhang the base on both sides — that is expected.
        base_glyphs = find_glyphs(boxes_wide)[1:3]
        plain_glyphs = find_glyphs(boxes_plain)
        adv_base = maximum(b.x + b.element.advance_width / upm * b.scale for b in base_glyphs)
        adv_plain = maximum(b.x + b.element.advance_width / upm * b.scale for b in plain_glyphs)
        @test adv_base ≈ adv_plain atol = 1.0e-10
    end

    @testset "Accent: cramped style inside accent (superscript in radicand)" begin
        # \hat{x^2}: the base x^2 is laid out cramped; the accent should still appear.
        boxes = layout(parse_latex("\\hat{x^2}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 3   # x, superscript 2, accent
    end

    @testset "\\overline emits base glyphs and an HRule above" begin
        boxes = layout(parse_latex("\\overline{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 1
        @test length(hrules) == 1
        upm = Float64(mt.upm)
        # Rule must be above the base glyph's ink top.
        base_top = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs)
        rule = hrules[1]
        rule_bottom = rule.y   # HRule.y is the bottom edge
        @test rule_bottom >= base_top - 1.0e-10   # rule sits above or at body top
    end

    @testset "\\underline emits base glyphs and an HRule below" begin
        boxes = layout(parse_latex("\\underline{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 1
        @test length(hrules) == 1
        upm = Float64(mt.upm)
        # Rule top must be at or below the base glyph's ink bottom.
        base_bot = minimum(b.y + b.element.y_min / upm * b.scale for b in glyphs)
        rule = hrules[1]
        rule_top = rule.y + (rule.element::HRule).thickness
        @test rule_top <= base_bot + 1.0e-10   # rule sits below or at body bottom
    end

    @testset "\\overline width equals body width" begin
        boxes_over = layout(parse_latex("\\overline{xy}"), family, Text)
        boxes_plain = layout(parse_latex("xy"), family, Text)
        hrule = find_hrules(boxes_over)[1]
        # Width of overline rule should match the body advance, including the
        # italic kern after the last character.
        plain_w = TeXLayout.measure(boxes_plain, Float64(mt.upm)).width
        @test (hrule.element::HRule).width ≈ plain_w atol = 0.01
    end

    @testset "\\overline rule thickness matches MATH table" begin
        boxes = layout(parse_latex("\\overline{x}"), family, Text)
        hrule = find_hrules(boxes)[1]
        upm = Float64(mt.upm)
        expected_t = mt.constants.overbar_rule_thickness / upm   # scale=1 in Text style
        @test (hrule.element::HRule).thickness ≈ expected_t atol = 1.0e-10
    end

    @testset "\\underline rule thickness matches MATH table" begin
        boxes = layout(parse_latex("\\underline{x}"), family, Text)
        hrule = find_hrules(boxes)[1]
        upm = Float64(mt.upm)
        expected_t = mt.constants.underbar_rule_thickness / upm
        @test (hrule.element::HRule).thickness ≈ expected_t atol = 1.0e-10
    end

    @testset "\\overline nested inside \\frac renders" begin
        boxes = layout(parse_latex("\\frac{\\overline{a}}{b}"), family, Display)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 2   # a and b
        @test length(hrules) >= 2   # fraction rule + overline rule
    end

    # ── Horizontal braces (\\overbrace / \\underbrace family) ───────────────────

    @testset "HorizBrace: all six commands render at least two glyphs" begin
        for cmd in (
                "\\overbrace", "\\underbrace", "\\overbracket",
                "\\underbracket", "\\overparen", "\\underparen",
            )
            boxes = layout(parse_latex("$(cmd){x}"), family, Text)
            glyphs = find_glyphs(boxes)
            @test length(glyphs) >= 2
        end
    end

    @testset "HorizBrace: notes keep the enclosing size factor" begin
        # The note is a script of the brace: under \large it is as large as an
        # ordinary superscript there, and inside a script it shrinks once more.
        script_scale(src, ps) = only(b.scale for b in find_glyphs(layout(parse_latex(src), family, Text)) if startswith(b.element.glyph_name, ps))
        for (brace, plain) in (
                ("{\\large \\overbrace{x}^{n}}", "{\\large x^{n}}"),
                ("{\\large \\underbrace{x}_{n}}", "{\\large x_{n}}"),
                ("{\\large \\overbrace{x}^{m}_{n}}", "{\\large x_{n}}"),
                ("a_{\\overbrace{x}^{n}}", "a_{x^{n}}"),
            )
            @test script_scale(brace, "u1D45B") ≈ script_scale(plain, "u1D45B")
        end
    end

    @testset "HorizBrace: \\overbrace brace ink extends above body ink" begin
        # Overbrace glyph (uni23DE) sits entirely above the baseline; its presence
        # must push the overall ink top higher than the plain body glyph alone.
        boxes_brace = layout(parse_latex("\\overbrace{x}"), family, Text)
        boxes_plain = layout(parse_latex("x"), family, Text)
        glyphs_brace = find_glyphs(boxes_brace)
        glyphs_plain = find_glyphs(boxes_plain)
        upm = Float64(mt.upm)
        @test length(glyphs_brace) >= 2
        top_brace = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs_brace)
        top_plain = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs_plain)
        @test top_brace > top_plain
    end

    @testset "HorizBrace: \\underbrace brace ink extends below body ink" begin
        # Underbrace glyph (uni23DF) sits entirely below the baseline; its presence
        # must push the overall ink bottom lower than the plain body glyph alone.
        boxes_brace = layout(parse_latex("\\underbrace{x}"), family, Text)
        boxes_plain = layout(parse_latex("x"), family, Text)
        glyphs_brace = find_glyphs(boxes_brace)
        glyphs_plain = find_glyphs(boxes_plain)
        upm = Float64(mt.upm)
        @test length(glyphs_brace) >= 2
        bot_brace = minimum(b.y + b.element.y_min / upm * b.scale for b in glyphs_brace)
        bot_plain = minimum(b.y + b.element.y_min / upm * b.scale for b in glyphs_plain)
        @test bot_brace < bot_plain
    end

    @testset "HorizBrace: note scales with surrounding \\large sizing" begin
        # The note is the smallest glyph; it must inherit the 1.2× sizing factor
        # like the body and brace rather than resetting to the bare script scale.
        note_scale(source) = minimum(b.scale for b in find_glyphs(layout(parse_latex(source), family, Text)))
        # The last case also has a secondary (opposite-side) script.
        for brace in (raw"\underbrace{x}_{n}", raw"\overbrace{x}^{n}", raw"\underbrace{x}_{n}^{m}")
            @test note_scale(raw"\large" * brace) ≈ 1.2 * note_scale(brace)
        end
    end

    @testset "HorizBrace: \\overbrace{xyz} renders multi-char body with brace above" begin
        boxes = layout(parse_latex("\\overbrace{xyz}"), family, Text)
        glyphs = find_glyphs(boxes)
        upm = Float64(mt.upm)
        # Three body characters (x, y, z) plus at least one brace glyph.
        @test length(glyphs) >= 4
        # Brace must still reach above the multi-char body.
        top_brace = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs)
        boxes_plain = layout(parse_latex("xyz"), family, Text)
        top_plain = maximum(
            b.y + b.element.y_max / upm * b.scale
                for b in find_glyphs(boxes_plain)
        )
        @test top_brace > top_plain
    end

    @testset "HorizBrace: \\overbrace{x}^{n} note glyph appears above brace" begin
        # The note 'n' is placed at script style (scale ≈ 0.7); its ink bottom
        # must be at or above the top ink edge of the brace stack.
        boxes = layout(parse_latex("\\overbrace{x}^{n}"), family, Text)
        glyphs = find_glyphs(boxes)
        upm = Float64(mt.upm)
        @test length(glyphs) >= 3   # body + brace + note
        script_scale = mt.constants.script_percent_scale_down / 100.0
        note = filter(b -> b.scale ≈ script_scale, glyphs)
        @test length(note) == 1
        # All base-scale glyphs (body + brace); note must sit above their maximum ink top.
        base = filter(b -> b.scale ≈ 1.0, glyphs)
        base_top = maximum(b.y + b.element.y_max / upm * b.scale for b in base)
        note_bot = note[1].y + note[1].element.y_min / upm * note[1].scale
        @test note_bot >= base_top - 1.0e-10
    end

    @testset "HorizBrace: \\underbrace{x}_{n} note glyph appears below brace" begin
        # The note 'n' is placed at script style; its ink top must be at or below
        # the bottom ink edge of the brace stack.
        boxes = layout(parse_latex("\\underbrace{x}_{n}"), family, Text)
        glyphs = find_glyphs(boxes)
        upm = Float64(mt.upm)
        @test length(glyphs) >= 3   # body + brace + note
        script_scale = mt.constants.script_percent_scale_down / 100.0
        note = filter(b -> b.scale ≈ script_scale, glyphs)
        @test length(note) == 1
        base = filter(b -> b.scale ≈ 1.0, glyphs)
        base_bot = minimum(b.y + b.element.y_min / upm * b.scale for b in base)
        note_top = note[1].y + note[1].element.y_max / upm * note[1].scale
        @test note_top <= base_bot + 1.0e-10
    end
end
