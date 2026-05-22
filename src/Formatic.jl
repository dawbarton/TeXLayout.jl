# Formatic.jl — OpenType-aware LaTeX math typesetter for Makie.
#
# A Julia-idiomatic implementation of KaTeX-quality math layout, designed as
# a drop-in replacement for MathTeXEngine.jl.  Key improvements over
# MathTeXEngine: full TeX style cascade (D/T/S/SS with cramped variants),
# OpenType MATH table metrics (not FreeType approximations), and correct
# inter-atom spacing (mord/mbin/mrel classes).
#
# Pipeline:  tokenize → parse → layout → Vector{LayoutBox}
#            └─ Makie: LayoutBox → GlyphCollection

module Formatic

include("math_table.jl")
include("fonts.jl")
include("style.jl")
include("lexer.jl")
include("parser.jl")
include("layout.jl")

# MathConstants deliberately not exported (conflicts with Base.MathConstants module).
export MathTable, GlyphConstruction, GlyphAssembly, GlyphAssemblyPart,
       GlyphVariant, load_math_table
export FontFamily, GlyphMetrics, glyph_metrics, glyph_metrics_by_codepoint, glyph_metrics_upright
# TexStyle enum values deliberately not exported at top level to avoid
# conflicts with Base.Text and Base.Display.  Access as Formatic.Display etc.
export TexStyle,
       sup_style, sub_style, frac_num_style, frac_den_style, cramp_style,
       is_cramped, is_display, is_script, is_script_script, size_scale
export TokenKind, TKChar, TKCommand, TKSup, TKSub, TKLBrace, TKRBrace,
       TKMathShift, TKAmpersand, TKSpace, TKEOF, Token, tokenize
export NodeKind, NKChar, NKSequence, NKGroup, NKSuperscript, NKSubscript,
       NKDecorated, NKFrac, NKSqrt, NKDelimited, NKAccent, NKCommand,
       NKSpace, NKText, NKOperator, Node, parse_latex
export TeXElement, Glyph, HRule, VRule, Space, LayoutBox, layout,
       generate_tex_elements

end
