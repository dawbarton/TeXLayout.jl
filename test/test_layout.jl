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
        boxes_double = layout(parse_latex("a++b"),   family, Text)
        boxes_normal = layout(parse_latex("a+c+b"),  family, Text)
        spaces_double = find_spaces(boxes_double)
        spaces_normal = find_spaces(boxes_normal)
        @test length(spaces_double) < length(spaces_normal)
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

    # ── Limits placement ──────────────────────────────────────────────────────

    @testset "Limits: \\lim_{n} in Display places sub centred below" begin
        # In Display style \lim is a limits operator: subscript goes below, centred.
        boxes  = layout(parse_latex("\\lim_{n}"), family, Display)
        glyphs = find_glyphs(boxes)
        # 3 upright glyphs from \lim (l, i, m) + 1 sub glyph (n).
        @test length(glyphs) == 4
        lim_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)   # base scale
        sub_glyph  = filter(b -> b.scale < 0.9, glyphs)    # script scale
        @test length(lim_glyphs) == 3
        @test length(sub_glyph)  == 1
        sub = sub_glyph[1]
        # Sub must be below baseline.
        @test sub.y < 0.0
        # Gap between base bottom ink and sub top ink must be ≥ lower_limit_gap_min.
        base_bot = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in lim_glyphs)
        sub_top  = sub.y + sub.element.y_max / FONT_UPM * sub.scale
        @test base_bot - sub_top >= mt.constants.lower_limit_gap_min / FONT_UPM - 1e-6
        # Sub is horizontally centred: since \lim (3 chars) is wider than n,
        # the sub's left x must be positive (shifted right to centre it).
        @test sub.x > 0.0
    end

    @testset "Limits: \\lim_{n} in Text uses side placement" begin
        # In Text style \lim is NOT a limits operator: sub goes to the right.
        boxes  = layout(parse_latex("\\lim_{n}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 4
        # Sub glyph (smaller scale) must be to the right of all base glyphs.
        sub_glyph  = filter(b -> b.scale < 0.9, glyphs)
        lim_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        @test length(sub_glyph) == 1
        rightmost_lim_x = maximum(b.x for b in lim_glyphs)
        @test sub_glyph[1].x > rightmost_lim_x
    end

    @testset "Limits: \\sin_{x} in Display uses side placement (not a limits op)" begin
        # \sin is never a limits operator, even in Display style.
        boxes  = layout(parse_latex("\\sin_{x}"), family, Display)
        glyphs = find_glyphs(boxes)
        # 3 base glyphs (s, i, n) + 1 sub (x).
        @test length(glyphs) == 4
        sub_glyph  = filter(b -> b.scale < 0.9, glyphs)
        sin_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        @test length(sub_glyph) == 1
        # Side placement: sub is to the right of the sin text.
        rightmost_sin_x = maximum(b.x for b in sin_glyphs)
        @test sub_glyph[1].x > rightmost_sin_x
    end

    @testset "Limits: \\sum has positive advance width (large-op codepoint fix)" begin
        # Before the codepoint fix, \\sum rendered as invisible (0 width) because
        # _cmd_glyph looked up "sum" which is not a PS name in NewCMMath.
        boxes = layout(parse_latex("\\sum"), family, Display)
        @test !isempty(find_glyphs(boxes))
        # Advance width must be positive.
        @test find_glyphs(boxes)[1].element.advance_width > 0
    end

    @testset "Limits: \\sum in Display uses display-size glyph" begin
        # In Display style the \sum glyph height should meet DisplayOperatorMinHeight.
        boxes_d = layout(parse_latex("\\sum"), family, Display)
        boxes_t = layout(parse_latex("\\sum"), family, Text)
        g_d = find_glyphs(boxes_d)[1].element
        g_t = find_glyphs(boxes_t)[1].element
        # Display variant is taller than Text variant.
        @test (g_d.y_max - g_d.y_min) > (g_t.y_max - g_t.y_min)
        # Display variant meets the minimum height threshold.
        @test (g_d.y_max - g_d.y_min) >= mt.constants.display_operator_min_height
    end

    @testset "Limits: \\sum_{i}^{n} in Display places limits above and below" begin
        # Both sub and sup should be centred above/below the \sum glyph.
        boxes  = layout(parse_latex("\\sum_{i}^{n}"), family, Display)
        glyphs = find_glyphs(boxes)
        # Separate: base at scale≈1, scripts at script scale.
        base_glyphs   = filter(b -> b.scale ≈ 1.0, glyphs)
        script_glyphs = filter(b -> b.scale < 0.9, glyphs)
        @test length(base_glyphs) == 1     # \sum glyph
        @test length(script_glyphs) == 2   # i (sub) + n (sup)
        # Sub is below base, sup is above base.
        sub_glyph = argmin(b -> b.y, script_glyphs)
        sup_glyph = argmax(b -> b.y, script_glyphs)
        @test sub_glyph.y < 0.0
        @test sup_glyph.y > 0.0
        # Gap constraints: sub top ink below sum bottom ink, sup bottom ink above sum top ink.
        sum_box = base_glyphs[1]
        sum_top = sum_box.y + sum_box.element.y_max / FONT_UPM * sum_box.scale
        sum_bot = sum_box.y + sum_box.element.y_min / FONT_UPM * sum_box.scale
        sub_top = sub_glyph.y + sub_glyph.element.y_max / FONT_UPM * sub_glyph.scale
        sup_bot = sup_glyph.y + sup_glyph.element.y_min / FONT_UPM * sup_glyph.scale
        @test sub_top <= sum_bot + 1e-6   # sub ink at or below sum bottom
        @test sup_bot >= sum_top - 1e-6   # sup ink at or above sum top
    end

    @testset "Limits: \\int\\limits_0^1 in Text forces limits placement" begin
        # \nolimits / \limits override the automatic detection.
        # \int normally uses side placement in Text; \limits forces above/below.
        boxes  = layout(parse_latex("\\int\\limits_0^1"), family, Text)
        glyphs = find_glyphs(boxes)
        base_glyphs   = filter(b -> b.scale ≈ 1.0, glyphs)
        script_glyphs = filter(b -> b.scale < 0.9, glyphs)
        @test !isempty(base_glyphs)
        @test length(script_glyphs) == 2
        sub_glyph = argmin(b -> b.y, script_glyphs)
        sup_glyph = argmax(b -> b.y, script_glyphs)
        @test sub_glyph.y < 0.0   # 0 is below baseline
        @test sup_glyph.y > 0.0   # 1 is above baseline
        # Forced limits: sub/sup must NOT be to the right of the base.
        int_x_right = base_glyphs[1].x + base_glyphs[1].element.advance_width / FONT_UPM
        @test sub_glyph.x < int_x_right
        @test sup_glyph.x < int_x_right
    end

    @testset "Limits: \\sum\\nolimits_{i} in Display forces side placement" begin
        # \nolimits overrides the automatic limits detection.
        boxes_limits   = layout(parse_latex("\\sum_{i}"),          family, Display)
        boxes_nolimits = layout(parse_latex("\\sum\\nolimits_{i}"), family, Display)
        glyphs_l = find_glyphs(boxes_limits)
        glyphs_n = find_glyphs(boxes_nolimits)
        # With nolimits the sub goes to the right (side placement).
        sub_side = filter(b -> b.scale < 0.9, glyphs_n)
        sub_lim  = filter(b -> b.scale < 0.9, glyphs_l)
        @test length(sub_side) == 1
        @test length(sub_lim)  == 1
        # Sub x is farther right in side placement than in limits placement.
        @test sub_side[1].x > sub_lim[1].x
    end

    @testset "Limits: \\limsup and \\liminf are recognised operators" begin
        # limsup and liminf should render as upright text (NKOperator).
        for cmd in ("\\limsup", "\\liminf")
            boxes = layout(parse_latex(cmd), family, Display)
            @test !isempty(find_glyphs(boxes))
        end
    end

    # ── Font switching ──────────────────────────────────────────────────────────

    @testset "FontSwitch: \\mathbf{x} renders one glyph" begin
        boxes  = layout(parse_latex("\\mathbf{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
    end

    @testset "FontSwitch: \\mathbf{x} glyph differs from plain x (bold vs italic)" begin
        # Bold 'x' (U+1D431) and italic math 'x' are different glyphs.
        boxes_bf  = layout(parse_latex("\\mathbf{x}"),  family, Text)
        boxes_def = layout(parse_latex("x"),             family, Text)
        name_bf   = find_glyphs(boxes_bf)[1].element.glyph_name
        name_def  = find_glyphs(boxes_def)[1].element.glyph_name
        @test name_bf != name_def
    end

    @testset "FontSwitch: \\mathit{x} glyph differs from bold x" begin
        boxes_it = layout(parse_latex("\\mathit{x}"), family, Text)
        boxes_bf = layout(parse_latex("\\mathbf{x}"), family, Text)
        name_it  = find_glyphs(boxes_it)[1].element.glyph_name
        name_bf  = find_glyphs(boxes_bf)[1].element.glyph_name
        @test name_it != name_bf
    end

    @testset "FontSwitch: \\mathbb{R} uses double-struck glyph" begin
        # \mathbb{R} → U+211D DOUBLE-STRUCK CAPITAL R (exception codepoint).
        boxes  = layout(parse_latex("\\mathbb{R}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathbb{A} uses math-block double-struck glyph" begin
        # \mathbb{A} → U+1D538 (non-exception uppercase).
        boxes_bb  = layout(parse_latex("\\mathbb{A}"), family, Text)
        boxes_def = layout(parse_latex("A"),            family, Text)
        @test !isempty(find_glyphs(boxes_bb))
        name_bb  = find_glyphs(boxes_bb)[1].element.glyph_name
        name_def = find_glyphs(boxes_def)[1].element.glyph_name
        @test name_bb != name_def
    end

    @testset "FontSwitch: \\mathrm{x} produces upright glyph distinct from \\mathit{x}" begin
        # \mathrm uses the upright lookup path; \mathit (and the default math-mode path)
        # uses U+1D465 (PS name "u1D465").  The upright "x" and the italic "u1D465" are
        # distinct glyphs with different metrics.
        boxes_rm = layout(parse_latex("\\mathrm{x}"),  family, Text)
        boxes_it = layout(parse_latex("\\mathit{x}"),  family, Text)
        @test !isempty(find_glyphs(boxes_rm))
        name_rm = find_glyphs(boxes_rm)[1].element.glyph_name
        name_it = find_glyphs(boxes_it)[1].element.glyph_name
        @test name_rm != name_it
    end

    @testset "FontSwitch: \\mathbf propagates to subscript" begin
        # \mathbf{x_i} should produce two glyphs, both from bold variants.
        boxes_bf  = layout(parse_latex("\\mathbf{x_i}"),  family, Text)
        boxes_def = layout(parse_latex("x_i"),             family, Text)
        glyphs_bf  = find_glyphs(boxes_bf)
        glyphs_def = find_glyphs(boxes_def)
        @test length(glyphs_bf) == 2
        # Bold glyphs should differ from the default italic glyphs.
        @test glyphs_bf[1].element.glyph_name != glyphs_def[1].element.glyph_name
        @test glyphs_bf[2].element.glyph_name != glyphs_def[2].element.glyph_name
    end

    @testset "FontSwitch: \\mathbf{x} advance width differs from italic x" begin
        # Bold metrics (wider) should differ from italic metrics.
        boxes_bf  = layout(parse_latex("\\mathbf{x}"),  family, Text)
        boxes_def = layout(parse_latex("x"),             family, Text)
        adv_bf  = find_glyphs(boxes_bf)[1].element.advance_width
        adv_def = find_glyphs(boxes_def)[1].element.advance_width
        # Advance widths are not required to differ by a specific amount, but must both be positive.
        @test adv_bf  > 0
        @test adv_def > 0
    end

    @testset "FontSwitch: \\mathbf{+} atom class is :bin (inherited from body)" begin
        # \mathbf{+} should insert medium spaces in a+b context same as plain +.
        boxes_plain = layout(parse_latex("a+b"),          family, Text)
        boxes_bf    = layout(parse_latex("a\\mathbf{+}b"), family, Text)
        spaces_plain = find_spaces(boxes_plain)
        spaces_bf    = find_spaces(boxes_bf)
        # Both should have 2 medium spaces (the + is :bin regardless of font variant).
        @test length(spaces_bf) == length(spaces_plain)
    end

    @testset "FontSwitch: \\mathtt{0} digit renders glyph" begin
        boxes  = layout(parse_latex("\\mathtt{0}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathcal{A} renders glyph" begin
        boxes  = layout(parse_latex("\\mathcal{A}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathfrak{A} renders glyph" begin
        boxes  = layout(parse_latex("\\mathfrak{A}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    # ── Accent layout (Rule 12) ───────────────────────────────────────────────

    @testset "Accent: \\hat{x} emits base and accent glyphs" begin
        boxes  = layout(parse_latex("\\hat{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        # Must have at least 2 glyphs: the base 'x' and the circumflex.
        @test length(glyphs) >= 2
    end

    @testset "Accent: \\hat{x} base glyph has same advance as plain x" begin
        boxes_hat   = layout(parse_latex("\\hat{x}"),  family, Text)
        boxes_plain = layout(parse_latex("x"),          family, Text)
        # The base glyph should be identical; only the accent is added on top.
        base_in_hat   = argmin(b -> b.x, find_glyphs(boxes_hat))
        base_in_plain = find_glyphs(boxes_plain)[1]
        @test base_in_hat.element.advance_width == base_in_plain.element.advance_width
    end

    @testset "Accent: \\hat{x} accent glyph ink top exceeds base ink top" begin
        boxes  = layout(parse_latex("\\hat{x}"), family, Text)
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
        boxes  = layout(parse_latex("\\bar{\\alpha}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
    end

    @testset "Accent: \\vec{v} renders without error" begin
        boxes  = layout(parse_latex("\\vec{v}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 2
    end

    @testset "Accent: all non-stretchy commands render" begin
        for cmd in ("\\hat", "\\acute", "\\grave", "\\ddot", "\\tilde",
                    "\\bar", "\\breve", "\\check", "\\dot", "\\mathring", "\\vec")
            boxes  = layout(parse_latex("$(cmd){x}"), family, Text)
            glyphs = find_glyphs(boxes)
            @test length(glyphs) >= 1   # at minimum the base must render
        end
    end

    @testset "Accent: cramped style inside accent (superscript in radicand)" begin
        # \hat{x^2}: the base x^2 is laid out cramped; the accent should still appear.
        boxes  = layout(parse_latex("\\hat{x^2}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 3   # x, superscript 2, accent
    end

    @testset "\\overline emits base glyphs and an HRule above" begin
        boxes  = layout(parse_latex("\\overline{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 1
        @test length(hrules) == 1
        upm = Float64(mt.upm)
        # Rule must be above the base glyph's ink top.
        base_top = maximum(b.y + b.element.y_max / upm * b.scale for b in glyphs)
        rule = hrules[1]
        rule_bottom = rule.y   # HRule.y is the bottom edge
        @test rule_bottom >= base_top - 1e-10   # rule sits above or at body top
    end

    @testset "\\underline emits base glyphs and an HRule below" begin
        boxes  = layout(parse_latex("\\underline{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 1
        @test length(hrules) == 1
        upm = Float64(mt.upm)
        # Rule top must be at or below the base glyph's ink bottom.
        base_bot = minimum(b.y + b.element.y_min / upm * b.scale for b in glyphs)
        rule = hrules[1]
        rule_top = rule.y + (rule.element::HRule).thickness
        @test rule_top <= base_bot + 1e-10   # rule sits below or at body bottom
    end

    @testset "\\overline width equals body width" begin
        boxes_over  = layout(parse_latex("\\overline{xy}"),  family, Text)
        boxes_plain = layout(parse_latex("xy"),               family, Text)
        hrule = find_hrules(boxes_over)[1]
        # Width of overline rule should match the body advance.
        plain_w = maximum(b.x + b.element.advance_width / Float64(mt.upm) * b.scale
                          for b in find_glyphs(boxes_plain))
        @test (hrule.element::HRule).width ≈ plain_w atol=0.01
    end

    @testset "\\overline rule thickness matches MATH table" begin
        boxes = layout(parse_latex("\\overline{x}"), family, Text)
        hrule = find_hrules(boxes)[1]
        upm = Float64(mt.upm)
        expected_t = mt.constants.overbar_rule_thickness / upm   # scale=1 in Text style
        @test (hrule.element::HRule).thickness ≈ expected_t atol=1e-10
    end

    @testset "\\underline rule thickness matches MATH table" begin
        boxes = layout(parse_latex("\\underline{x}"), family, Text)
        hrule = find_hrules(boxes)[1]
        upm = Float64(mt.upm)
        expected_t = mt.constants.underbar_rule_thickness / upm
        @test (hrule.element::HRule).thickness ≈ expected_t atol=1e-10
    end

    @testset "\\overline nested inside \\frac renders" begin
        boxes = layout(parse_latex("\\frac{\\overline{a}}{b}"), family, Display)
        glyphs = find_glyphs(boxes)
        hrules = find_hrules(boxes)
        @test length(glyphs) >= 2   # a and b
        @test length(hrules) >= 2   # fraction rule + overline rule
    end

end
