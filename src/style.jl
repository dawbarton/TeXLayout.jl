# TeX style cascade — the 8-style system from Appendix G of The TeXbook.
#
# Styles control which size of a formula is used for sub-expressions.
# Each style has a cramped variant (for subscripts and denominators) where
# superscripts are lowered to avoid protruding above the base.

"""
The 8 TeX math styles.

Integer values (1–8) match the ordering in KaTeX's Style.ts and allow
efficient lookup tables.  Cramped styles are odd-indexed successors.
"""
@enum TexStyle::Int8 begin
    Display = 1
    CrampedDisplay = 2
    Text = 3
    CrampedText = 4
    Script = 5
    CrampedScript = 6
    ScriptScript = 7
    CrampedScriptScript = 8
end

"""Return `true` if the style is a cramped variant."""
is_cramped(s::TexStyle) = Int8(s) % 2 == 0

"""Return `true` for Display or CrampedDisplay."""
is_display(s::TexStyle) = s === Display || s === CrampedDisplay

"""Return `true` for Script or CrampedScript."""
is_script(s::TexStyle) = s === Script || s === CrampedScript

"""Return `true` for ScriptScript or CrampedScriptScript."""
is_script_script(s::TexStyle) = s === ScriptScript || s === CrampedScriptScript

# ── Style transitions ──────────────────────────────────────────────────────────
# Source: KaTeX/src/Style.ts, cross-checked with TeXbook Appendix G rules 14–17.

const _SUP_STYLE = (
    Script, CrampedScript, Script, CrampedScript,
    ScriptScript, CrampedScriptScript, ScriptScript, CrampedScriptScript,
)

const _SUB_STYLE = (
    CrampedScript, CrampedScript, CrampedScript, CrampedScript,
    CrampedScriptScript, CrampedScriptScript,
    CrampedScriptScript, CrampedScriptScript,
)

const _FRAC_NUM_STYLE = (
    Text, CrampedText, Script, CrampedScript,
    ScriptScript, CrampedScriptScript, ScriptScript, CrampedScriptScript,
)

const _FRAC_DEN_STYLE = (
    CrampedText, CrampedText, CrampedScript, CrampedScript,
    CrampedScriptScript, CrampedScriptScript,
    CrampedScriptScript, CrampedScriptScript,
)

const _CRAMP_STYLE = (
    CrampedDisplay, CrampedDisplay, CrampedText, CrampedText,
    CrampedScript, CrampedScript, CrampedScriptScript, CrampedScriptScript,
)

"""Style used for a superscript in the current style."""
sup_style(s::TexStyle) = _SUP_STYLE[Int8(s)]

"""Style used for a subscript in the current style."""
sub_style(s::TexStyle) = _SUB_STYLE[Int8(s)]

"""Style used for the numerator of a fraction in the current style."""
frac_num_style(s::TexStyle) = _FRAC_NUM_STYLE[Int8(s)]

"""Style used for the denominator of a fraction in the current style."""
frac_den_style(s::TexStyle) = _FRAC_DEN_STYLE[Int8(s)]

"""Cramped variant of the current style."""
cramp_style(s::TexStyle) = _CRAMP_STYLE[Int8(s)]

"""
    size_scale(s, math_constants) -> Float64

Return the size multiplier for style `s` relative to the base (Text) style.
Scale factors come from the font's MATH table: `ScriptPercentScaleDown` and
`ScriptScriptPercentScaleDown`.
"""
function size_scale(s::TexStyle, mc::MathConstants)::Float64
    return if is_script_script(s)
        mc.script_script_percent_scale_down / 100.0
    elseif is_script(s)
        mc.script_percent_scale_down / 100.0
    else
        1.0
    end
end
