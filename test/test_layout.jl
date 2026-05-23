# Tests for the layout engine (src/layout.jl).
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants, not exact pixel positions (which depend on font size and renderer).
# All positions are in em units (divide by UPM for design-unit equivalents).
#
# Fixture values are used to check that rule thicknesses and shift amounts are
# consistent with the font's MATH table.  The fixture file is included once from
# runtests.jl.

# Helper: find all LayoutBoxes whose element matches a predicate.
find_elements(boxes, pred) = filter(b -> pred(b.element), boxes)
find_glyphs(boxes) = find_elements(boxes, e -> e isa Glyph)
find_hrules(boxes) = find_elements(boxes, e -> e isa HRule)

@testset "Layout engine" begin

    family = FontFamily(FIXTURE_FONT_PATH)
    mt     = load_math_table(FIXTURE_FONT_PATH)

    @testset "Single character layout" begin
        boxes = layout(parse_latex("x"), family, Text)
        @test length(boxes) >= 1
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].x ≈ 0.0      # first glyph starts at origin
        @test glyphs[1].y ≈ 0.0      # baseline
        @test glyphs[1].scale ≈ 1.0  # Text style
    end

    @testset "Superscript is above baseline" begin
        # In x^2, the '2' must have a positive y offset.
        boxes = layout(parse_latex("x^2"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        base_y = glyphs[1].y
        sup_y  = glyphs[2].y
        @test sup_y > base_y
        # The superscript shift is at least SuperscriptShiftUp/UPM (in em).
        min_shift = mt.constants.superscript_shift_up / FONT_UPM
        @test sup_y >= min_shift - 1e-6
    end

    @testset "Subscript is below baseline" begin
        boxes = layout(parse_latex("x_i"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        sub_y = glyphs[2].y
        @test sub_y < 0.0   # below baseline
    end

    @testset "NKDecorated: both sub and sup positioned correctly" begin
        # x_i^2 should produce three glyphs: base at y=0, sup above baseline, sub below.
        boxes = layout(parse_latex("x_i^2"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
        # Base (x) is at the formula baseline.
        base_y = glyphs[1].y
        @test base_y ≈ 0.0
        # Superscript is above; subscript is below.
        ys = [b.y for b in glyphs]
        @test maximum(ys) > 0.0   # sup above baseline
        @test minimum(ys) < 0.0   # sub below baseline
        # Both scripts are at the same horizontal origin (x + base_advance).
        script_xs = sort([glyphs[2].x, glyphs[3].x])
        @test script_xs[1] ≈ script_xs[2]  atol=1e-6
    end

    @testset "Fraction rule is at axis height" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        hrules = find_hrules(boxes)
        @test length(hrules) >= 1
        rule = hrules[1]
        axis_em = mt.constants.axis_height / FONT_UPM
        half_thickness = rule.element.thickness / 2
        # Rule centre (bottom edge + half thickness) must sit exactly on the axis height.
        @test (rule.y + half_thickness) ≈ axis_em  atol=1e-6
    end

    @testset "Fraction rule thickness" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        hrules = find_hrules(boxes)
        @test length(hrules) >= 1
        expected_thickness = mt.constants.fraction_rule_thickness / FONT_UPM
        @test hrules[1].element.thickness ≈ expected_thickness  atol=1e-6
    end

    @testset "Fraction: numerator above axis, denominator below" begin
        boxes = layout(parse_latex("\\frac{a}{b}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        ys = sort([b.y for b in glyphs], rev=true)  # highest first
        axis_em = mt.constants.axis_height / FONT_UPM
        @test ys[1] > axis_em   # numerator above axis
        @test ys[2] < axis_em   # denominator below axis
    end

    @testset "Superscript scale in Text style" begin
        boxes = layout(parse_latex("x^2"), family, Text)
        glyphs = find_glyphs(boxes)
        base_scale = glyphs[1].scale
        sup_scale  = glyphs[2].scale
        expected = mt.constants.script_percent_scale_down / 100.0
        @test sup_scale ≈ base_scale * expected  atol=1e-6
    end

    @testset "Display style: numerator shift uses display variant" begin
        # In Display style, FractionNumeratorDisplayStyleShiftUp should be used,
        # which is larger than FractionNumeratorShiftUp.
        boxes_display = layout(parse_latex("\\frac{a}{b}"), family, Display)
        boxes_text    = layout(parse_latex("\\frac{a}{b}"), family, Text)
        num_y_display = maximum(b.y for b in find_glyphs(boxes_display))
        num_y_text    = maximum(b.y for b in find_glyphs(boxes_text))
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
        radicand_y = maximum(b.y + b.element.y_max / FONT_UPM * b.scale
                             for b in body_glyphs)
        rule_y = hrules[1].y
        @test rule_y >= radicand_y - 1e-6
    end

    @testset "Horizontal advance: boxes are left-to-right" begin
        boxes = layout(parse_latex("ab"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        @test glyphs[2].x > glyphs[1].x
    end

    @testset "Operator: \\sin x produces four glyphs" begin
        # \sin → NKOperator("sin"): three upright glyphs; x → one italic glyph.
        boxes  = layout(parse_latex("\\sin x"), family, Display)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 4
        # Operator glyphs are left of the argument glyph.
        op_xs  = [glyphs[i].x for i in 1:3]
        arg_x  = glyphs[4].x
        @test all(x -> x < arg_x, op_xs)
    end

    @testset "\\operatorname renders correct character count" begin
        boxes  = layout(parse_latex("\\operatorname{ker}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
    end

    find_spaces(boxes) = find_elements(boxes, e -> e isa Space)

    # ── Inter-atom spacing ──────────────────────────────────────────────────────

    @testset "Inter-atom: ord+bin+ord (a+b) inserts two medium spaces" begin
        boxes  = layout(parse_latex("a+b"), family, Text)
        spaces = find_spaces(boxes)
        # Expected: medium space before '+' (ord→bin) and after '+' (bin→ord).
        @test length(spaces) == 2
        medium = (4/18) * size_scale(Text, mt.constants)
        @test all(s -> isapprox(s.element.width, medium, atol=1e-6), spaces)
    end

    @testset "Inter-atom: ord+rel+ord (a=b) inserts two thick spaces" begin
        boxes  = layout(parse_latex("a=b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 2
        thick = (5/18) * size_scale(Text, mt.constants)
        @test all(s -> isapprox(s.element.width, thick, atol=1e-6), spaces)
    end

    @testset "Inter-atom: punct→ord (a,b) inserts thin space after comma" begin
        boxes  = layout(parse_latex("a,b"), family, Text)
        spaces = find_spaces(boxes)
        # punct→ord yields thin; there is no space before the comma.
        @test length(spaces) == 1
        thin = (3/18) * size_scale(Text, mt.constants)
        @test spaces[1].element.width ≈ thin  atol=1e-6
    end

    @testset "Inter-atom: op→ord (\\sin x) inserts thin space" begin
        boxes  = layout(parse_latex("\\sin x"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        thin = (3/18) * size_scale(Text, mt.constants)
        @test spaces[1].element.width ≈ thin  atol=1e-6
    end

    @testset "Inter-atom: Script style suppresses medium/thick spacing" begin
        # In Script style the tight-spacing table applies: ord+bin+ord → no space.
        boxes  = layout(parse_latex("a+b"), family, Script)
        spaces = find_spaces(boxes)
        @test length(spaces) == 0
    end

    @testset "Inter-atom: explicit space resets context, no double gap" begin
        # 'a \quad b': the \quad is neutral; spacing context is reset after it,
        # so 'b' gets no additional auto-space.  Exactly 1 Space element (the \quad).
        boxes  = layout(parse_latex("a\\quad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
    end

    @testset "\\quad produces a Space element of width 1 em" begin
        boxes  = layout(parse_latex("a\\quad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        # Text-style scale is 1.0; Space width should be 1.0 em.
        @test spaces[1].element.width ≈ 1.0 * size_scale(Text, mt.constants)
    end

    @testset "\\qquad produces a Space element of width 2 em" begin
        boxes  = layout(parse_latex("a\\qquad b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ 2.0 * size_scale(Text, mt.constants)
    end

    @testset "\\, produces thin space (3/18 em)" begin
        boxes  = layout(parse_latex("a\\,b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ (3/18) * size_scale(Text, mt.constants)
    end

    @testset "\\! produces negative space" begin
        boxes  = layout(parse_latex("a\\!b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width < 0.0
    end

    @testset "\\kern{1em} produces Space of width 1 em" begin
        boxes  = layout(parse_latex("a\\kern{1em}b"), family, Text)
        spaces = find_spaces(boxes)
        @test length(spaces) == 1
        @test spaces[1].element.width ≈ 1.0 * size_scale(Text, mt.constants)
    end

    @testset "Spacing advances cursor left-to-right" begin
        # With a quad between a and b, b's x-position must be further right
        # than without spacing.
        boxes_spaced = layout(parse_latex("a\\quad b"), family, Text)
        boxes_plain  = layout(parse_latex("ab"), family, Text)
        glyphs_spaced = find_glyphs(boxes_spaced)
        glyphs_plain  = find_glyphs(boxes_plain)
        b_x_spaced = glyphs_spaced[2].x
        b_x_plain  = glyphs_plain[2].x
        @test b_x_spaced > b_x_plain
    end

    @testset "\\left(x\\right): three glyphs, left delim at x=0" begin
        # \left( x \right) should produce: parenleft, x, parenright (3 glyphs).
        boxes  = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
        # Left delimiter is placed at x=0 (the formula origin).
        @test glyphs[1].x ≈ 0.0
        # Glyphs are ordered left to right.
        @test glyphs[1].x < glyphs[2].x < glyphs[3].x
    end

    @testset "\\left( x \\right): delimiters centred on math axis" begin
        # Delimiter ink centre (y_min+y_max)/2 should equal the math axis height.
        boxes  = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs = find_glyphs(boxes)
        axis_em = mt.constants.axis_height / FONT_UPM
        for i in [1, 3]   # left and right delimiter glyphs
            g = glyphs[i].element
            glyph_center = (g.y_min + g.y_max) / (2.0 * FONT_UPM) * glyphs[i].scale
            delim_center = glyphs[i].y + glyph_center
            @test delim_center ≈ axis_em  atol=1e-6
        end
    end

    @testset "\\left( \\frac{a}{b} \\right): delimiter larger than plain parens" begin
        # Fractions are taller than a single character, so \left( should scale up.
        boxes_frac  = layout(parse_latex("\\left( \\frac{a}{b} \\right)"), family, Text)
        boxes_plain = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs_frac  = find_glyphs(boxes_frac)
        glyphs_plain = find_glyphs(boxes_plain)
        # The glyph height (y_max - y_min) of the left delimiter in the frac case
        # must be strictly greater than in the plain case.
        height(b) = b.element.y_max - b.element.y_min
        @test height(glyphs_frac[1]) > height(glyphs_plain[1])
    end

    @testset "\\left. (null delimiter) places no glyph on the left" begin
        # Null delimiter "." produces no rendered glyph on the left.
        boxes_null  = layout(parse_latex("\\left. x \\right)"), family, Text)
        boxes_paren = layout(parse_latex("\\left( x \\right)"), family, Text)
        # null version has one fewer glyph (no left delimiter)
        @test length(find_glyphs(boxes_null)) == length(find_glyphs(boxes_paren)) - 1
    end

    @testset "Assembly: 4-level nested fraction triggers extensible assembly" begin
        # \\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right) in Display
        # style produces required_du > 2991 (the largest parenleft pre-built variant),
        # so the glyph assembly (bottom cap + extender + top cap) is used for each
        # delimiter.  With 5 content chars and 3-part assemblies on each side the total
        # glyph count must exceed the 7 glyphs produced when single-glyph variants are used.
        expr  = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        # Minimum: 5 letters + 3 (left assembly) + 3 (right assembly) = 11 glyphs.
        @test length(glyphs) >= 11
    end

    @testset "Assembly: delimiter height exceeds largest pre-built variant" begin
        # The assembly delimiter must be taller than any pre-built variant.
        # Largest parenleft variant advance = 2991 design units in NewCMMath.
        largest_variant_du = 2991
        expr   = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes  = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        # Assembly parts are placed with y_min=0; their y_max = full_advance.
        # The outermost glyph in the assembly is the top cap (uni239B, full_adv=1495).
        # Assembly top = axis + total_height/2 > largest_variant_du/2 / upm.
        top_em  = maximum(b.y + b.element.y_max / FONT_UPM * b.scale for b in glyphs)
        bot_em  = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in glyphs)
        span_du = (top_em - bot_em) * FONT_UPM   # convert em → du (at scale=1)
        @test span_du > largest_variant_du
    end

    @testset "Assembly: delimiter centred on math axis" begin
        # The assembly's ink centre must lie on the math axis (±1 du tolerance).
        expr   = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes  = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        axis_em = mt.constants.axis_height / FONT_UPM
        # Isolate the left-delimiter glyphs (all at x=0 with the same advance width).
        left_x = glyphs[1].x
        left_glyphs = filter(b -> b.x ≈ left_x, glyphs)
        top_em  = maximum(b.y + b.element.y_max / FONT_UPM * b.scale for b in left_glyphs)
        bot_em  = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in left_glyphs)
        center  = (top_em + bot_em) / 2
        @test center ≈ axis_em  atol=1e-3
    end

end
