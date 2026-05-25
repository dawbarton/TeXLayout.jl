# Tests for the TeX style cascade (src/style.jl).
#
# All transition tables are taken from KaTeX/src/Style.ts and cross-checked
# against TeXbook Appendix G rules 14–17.  The size-scale tests use fixture
# values from NewCMMath-Regular.otf.  The fixture file is included once from
# runtests.jl.

@testset "TeX style cascade" begin

    @testset "Enum membership" begin
        all_styles = (
            Display, CrampedDisplay, Text, CrampedText,
            Script, CrampedScript, ScriptScript, CrampedScriptScript,
        )
        @test length(all_styles) == 8
        @test all(s isa TexStyle for s in all_styles)
    end

    @testset "is_cramped" begin
        @test !is_cramped(Display)
        @test  is_cramped(CrampedDisplay)
        @test !is_cramped(Text)
        @test  is_cramped(CrampedText)
        @test !is_cramped(Script)
        @test  is_cramped(CrampedScript)
        @test !is_cramped(ScriptScript)
        @test  is_cramped(CrampedScriptScript)
    end

    @testset "is_display" begin
        @test  is_display(Display)
        @test  is_display(CrampedDisplay)
        @test !is_display(Text)
        @test !is_display(Script)
        @test !is_display(ScriptScript)
    end

    @testset "is_script" begin
        @test !is_script(Display)
        @test !is_script(Text)
        @test  is_script(Script)
        @test  is_script(CrampedScript)
        @test !is_script(ScriptScript)
    end

    @testset "is_script_script" begin
        @test !is_script_script(Script)
        @test  is_script_script(ScriptScript)
        @test  is_script_script(CrampedScriptScript)
    end

    @testset "sup_style" begin
        @test sup_style(Display) === Script
        @test sup_style(CrampedDisplay) === CrampedScript
        @test sup_style(Text) === Script
        @test sup_style(CrampedText) === CrampedScript
        @test sup_style(Script) === ScriptScript
        @test sup_style(CrampedScript) === CrampedScriptScript
        @test sup_style(ScriptScript) === ScriptScript       # does not go smaller
        @test sup_style(CrampedScriptScript) === CrampedScriptScript
    end

    @testset "sub_style" begin
        @test sub_style(Display) === CrampedScript
        @test sub_style(CrampedDisplay) === CrampedScript
        @test sub_style(Text) === CrampedScript
        @test sub_style(CrampedText) === CrampedScript
        @test sub_style(Script) === CrampedScriptScript
        @test sub_style(CrampedScript) === CrampedScriptScript
        @test sub_style(ScriptScript) === CrampedScriptScript
        @test sub_style(CrampedScriptScript) === CrampedScriptScript
    end

    @testset "frac_num_style" begin
        @test frac_num_style(Display) === Text           # D → T (display numerator)
        @test frac_num_style(CrampedDisplay) === CrampedText
        @test frac_num_style(Text) === Script
        @test frac_num_style(CrampedText) === CrampedScript
        @test frac_num_style(Script) === ScriptScript
        @test frac_num_style(CrampedScript) === CrampedScriptScript
        @test frac_num_style(ScriptScript) === ScriptScript
        @test frac_num_style(CrampedScriptScript) === CrampedScriptScript
    end

    @testset "frac_den_style" begin
        @test frac_den_style(Display) === CrampedText    # D → Tc (display denominator)
        @test frac_den_style(CrampedDisplay) === CrampedText
        @test frac_den_style(Text) === CrampedScript
        @test frac_den_style(CrampedText) === CrampedScript
        @test frac_den_style(Script) === CrampedScriptScript
        @test frac_den_style(CrampedScript) === CrampedScriptScript
        @test frac_den_style(ScriptScript) === CrampedScriptScript
        @test frac_den_style(CrampedScriptScript) === CrampedScriptScript
    end

    @testset "cramp_style" begin
        @test cramp_style(Display) === CrampedDisplay
        @test cramp_style(CrampedDisplay) === CrampedDisplay    # idempotent
        @test cramp_style(Text) === CrampedText
        @test cramp_style(CrampedText) === CrampedText
        @test cramp_style(Script) === CrampedScript
        @test cramp_style(CrampedScript) === CrampedScript
        @test cramp_style(ScriptScript) === CrampedScriptScript
        @test cramp_style(CrampedScriptScript) === CrampedScriptScript
    end

    @testset "size_scale (NewCMMath-Regular)" begin
        # Build a MathConstants with only the two scale fields populated.
        # Using zeros for unused fields; we only read the scale percentages.
        mc_zeros = ntuple(_ -> 0, fieldcount(MathConstants))
        mc = MathConstants(
            MATH_CONSTANTS[:ScriptPercentScaleDown],       # field 1
            MATH_CONSTANTS[:ScriptScriptPercentScaleDown], # field 2
            mc_zeros[3:end]...,
        )
        @test size_scale(Display, mc) == 1.0
        @test size_scale(CrampedDisplay, mc) == 1.0
        @test size_scale(Text, mc) == 1.0
        @test size_scale(CrampedText, mc) == 1.0
        @test size_scale(Script, mc) ≈ 0.7
        @test size_scale(CrampedScript, mc) ≈ 0.7
        @test size_scale(ScriptScript, mc) ≈ 0.5
        @test size_scale(CrampedScriptScript, mc) ≈ 0.5
    end

end
