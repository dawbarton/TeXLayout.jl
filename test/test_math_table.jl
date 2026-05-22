# Tests for the OpenType MATH table parser (src/math_table.jl).
#
# All expected values are ground-truth fixtures extracted from
# NewCMMath-Regular.otf via fonttools/ttx (see test/fixtures/newcm_math.jl).
# The fixture file is included once from runtests.jl.

@testset "MathTable parser" begin

    @test isfile(FIXTURE_FONT_PATH)

    mt = load_math_table(FIXTURE_FONT_PATH)

    @test mt isa MathTable
    @test mt.upm == FONT_UPM

    @testset "MathConstants — all 56 fields" begin
        c = mt.constants
        # Scale percentages
        @test c.script_percent_scale_down             == MATH_CONSTANTS[:ScriptPercentScaleDown]
        @test c.script_script_percent_scale_down      == MATH_CONSTANTS[:ScriptScriptPercentScaleDown]
        # Minimum heights
        @test c.delimited_sub_formula_min_height      == MATH_CONSTANTS[:DelimitedSubFormulaMinHeight]
        @test c.display_operator_min_height           == MATH_CONSTANTS[:DisplayOperatorMinHeight]
        # Vertical positions
        @test c.math_leading                          == MATH_CONSTANTS[:MathLeading]
        @test c.axis_height                           == MATH_CONSTANTS[:AxisHeight]
        @test c.accent_base_height                    == MATH_CONSTANTS[:AccentBaseHeight]
        @test c.flattened_accent_base_height          == MATH_CONSTANTS[:FlattenedAccentBaseHeight]
        # Subscript/superscript
        @test c.subscript_shift_down                  == MATH_CONSTANTS[:SubscriptShiftDown]
        @test c.subscript_top_max                     == MATH_CONSTANTS[:SubscriptTopMax]
        @test c.subscript_baseline_drop_min           == MATH_CONSTANTS[:SubscriptBaselineDropMin]
        @test c.superscript_shift_up                  == MATH_CONSTANTS[:SuperscriptShiftUp]
        @test c.superscript_shift_up_cramped          == MATH_CONSTANTS[:SuperscriptShiftUpCramped]
        @test c.superscript_bottom_min                == MATH_CONSTANTS[:SuperscriptBottomMin]
        @test c.superscript_baseline_drop_max         == MATH_CONSTANTS[:SuperscriptBaselineDropMax]
        @test c.sub_superscript_gap_min               == MATH_CONSTANTS[:SubSuperscriptGapMin]
        @test c.superscript_bottom_max_with_subscript == MATH_CONSTANTS[:SuperscriptBottomMaxWithSubscript]
        @test c.space_after_script                    == MATH_CONSTANTS[:SpaceAfterScript]
        # Limits
        @test c.upper_limit_gap_min                   == MATH_CONSTANTS[:UpperLimitGapMin]
        @test c.upper_limit_baseline_rise_min         == MATH_CONSTANTS[:UpperLimitBaselineRiseMin]
        @test c.lower_limit_gap_min                   == MATH_CONSTANTS[:LowerLimitGapMin]
        @test c.lower_limit_baseline_drop_min         == MATH_CONSTANTS[:LowerLimitBaselineDropMin]
        # Stacks
        @test c.stack_top_shift_up                          == MATH_CONSTANTS[:StackTopShiftUp]
        @test c.stack_top_display_style_shift_up            == MATH_CONSTANTS[:StackTopDisplayStyleShiftUp]
        @test c.stack_bottom_shift_down                     == MATH_CONSTANTS[:StackBottomShiftDown]
        @test c.stack_bottom_display_style_shift_down       == MATH_CONSTANTS[:StackBottomDisplayStyleShiftDown]
        @test c.stack_gap_min                               == MATH_CONSTANTS[:StackGapMin]
        @test c.stack_display_style_gap_min                 == MATH_CONSTANTS[:StackDisplayStyleGapMin]
        # Stretch stacks
        @test c.stretch_stack_top_shift_up    == MATH_CONSTANTS[:StretchStackTopShiftUp]
        @test c.stretch_stack_bottom_shift_down == MATH_CONSTANTS[:StretchStackBottomShiftDown]
        @test c.stretch_stack_gap_above_min   == MATH_CONSTANTS[:StretchStackGapAboveMin]
        @test c.stretch_stack_gap_below_min   == MATH_CONSTANTS[:StretchStackGapBelowMin]
        # Fractions
        @test c.fraction_numerator_shift_up                  == MATH_CONSTANTS[:FractionNumeratorShiftUp]
        @test c.fraction_numerator_display_style_shift_up    == MATH_CONSTANTS[:FractionNumeratorDisplayStyleShiftUp]
        @test c.fraction_denominator_shift_down              == MATH_CONSTANTS[:FractionDenominatorShiftDown]
        @test c.fraction_denominator_display_style_shift_down == MATH_CONSTANTS[:FractionDenominatorDisplayStyleShiftDown]
        @test c.fraction_numerator_gap_min                   == MATH_CONSTANTS[:FractionNumeratorGapMin]
        @test c.fraction_num_display_style_gap_min           == MATH_CONSTANTS[:FractionNumDisplayStyleGapMin]
        @test c.fraction_rule_thickness                      == MATH_CONSTANTS[:FractionRuleThickness]
        @test c.fraction_denominator_gap_min                 == MATH_CONSTANTS[:FractionDenominatorGapMin]
        @test c.fraction_denom_display_style_gap_min         == MATH_CONSTANTS[:FractionDenomDisplayStyleGapMin]
        # Skewed fractions
        @test c.skewed_fraction_horizontal_gap == MATH_CONSTANTS[:SkewedFractionHorizontalGap]
        @test c.skewed_fraction_vertical_gap   == MATH_CONSTANTS[:SkewedFractionVerticalGap]
        # Over/underbar
        @test c.overbar_vertical_gap      == MATH_CONSTANTS[:OverbarVerticalGap]
        @test c.overbar_rule_thickness    == MATH_CONSTANTS[:OverbarRuleThickness]
        @test c.overbar_extra_ascender    == MATH_CONSTANTS[:OverbarExtraAscender]
        @test c.underbar_vertical_gap     == MATH_CONSTANTS[:UnderbarVerticalGap]
        @test c.underbar_rule_thickness   == MATH_CONSTANTS[:UnderbarRuleThickness]
        @test c.underbar_extra_descender  == MATH_CONSTANTS[:UnderbarExtraDescender]
        # Radical
        @test c.radical_vertical_gap                == MATH_CONSTANTS[:RadicalVerticalGap]
        @test c.radical_display_style_vertical_gap  == MATH_CONSTANTS[:RadicalDisplayStyleVerticalGap]
        @test c.radical_rule_thickness              == MATH_CONSTANTS[:RadicalRuleThickness]
        @test c.radical_extra_ascender              == MATH_CONSTANTS[:RadicalExtraAscender]
        @test c.radical_kern_before_degree          == MATH_CONSTANTS[:RadicalKernBeforeDegree]
        @test c.radical_kern_after_degree           == MATH_CONSTANTS[:RadicalKernAfterDegree]  # negative
        @test c.radical_degree_bottom_raise_percent == MATH_CONSTANTS[:RadicalDegreeBottomRaisePercent]
    end

    @testset "Italic corrections" begin
        ic = mt.italic_corrections
        for (name, expected) in ITALIC_CORRECTIONS
            @test get(ic, name, nothing) == expected
        end
    end

    @testset "Top-accent attachments" begin
        ta = mt.top_accent_attachments
        for (name, expected) in TOP_ACCENT_ATTACHMENTS
            @test get(ta, name, nothing) == expected
        end
    end

    @testset "MathVariants — MinConnectorOverlap" begin
        @test mt.min_connector_overlap == MIN_CONNECTOR_OVERLAP
    end

    @testset "MathVariants — parenleft vert variants" begin
        vc = mt.vert_constructions
        @test haskey(vc, "parenleft")
        con = vc["parenleft"]
        @test length(con.variants) == length(PARENLEFT_VERT_VARIANTS)
        for (got, exp) in zip(con.variants, PARENLEFT_VERT_VARIANTS)
            @test got.glyph_name == exp.glyph
            @test got.advance    == exp.advance
        end
    end

    @testset "MathVariants — parenleft assembly" begin
        con = mt.vert_constructions["parenleft"]
        asm = con.assembly
        @test asm !== nothing
        @test asm.italic_correction == PARENLEFT_ASSEMBLY_ITALIC_CORRECTION
        @test length(asm.parts) == length(PARENLEFT_ASSEMBLY_PARTS)
        for (got, exp) in zip(asm.parts, PARENLEFT_ASSEMBLY_PARTS)
            @test got.glyph_name       == exp.glyph
            @test got.full_advance     == exp.full_advance
            @test got.start_connector  == exp.start_connector
            @test got.end_connector    == exp.end_connector
            @test got.is_extender      == exp.extender
        end
    end

    @testset "MathVariants — braceleft assembly (5-part)" begin
        con = mt.vert_constructions["braceleft"]
        asm = con.assembly
        @test asm !== nothing
        @test length(asm.parts) == length(BRACELEFT_ASSEMBLY_PARTS)
        for (got, exp) in zip(asm.parts, BRACELEFT_ASSEMBLY_PARTS)
            @test got.glyph_name   == exp.glyph
            @test got.full_advance == exp.full_advance
            @test got.is_extender  == exp.extender
        end
    end

end
