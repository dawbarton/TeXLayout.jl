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
        radicand_y = maximum(b.y + b.element.y_max / FONT_UPM * b.scale
                             for b in glyphs)
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

end
