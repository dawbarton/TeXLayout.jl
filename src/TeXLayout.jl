# TeXLayout.jl — OpenType-aware LaTeX math typesetter for Makie.
#
# A Julia-idiomatic implementation of KaTeX-quality math layout, designed as
# a drop-in replacement for MathTeXEngine.jl.  Key improvements over
# MathTeXEngine: full TeX style cascade (D/T/S/SS with cramped variants),
# OpenType MATH table metrics (not FreeType approximations), and correct
# inter-atom spacing (mord/mbin/mrel classes).
#
# Pipeline:  tokenize → parse → layout → Vector{LayoutBox}
#            └─ Makie: LayoutBox → GlyphCollection

module TeXLayout

include("math_table.jl")
include("enums.jl")
include("text_styles.jl")
include("fonts.jl")
include("style.jl")
include("lexer.jl")
include("payloads.jl")
include("ast.jl")
include("tables/parser_tables.jl")
include("parser.jl")
include("tables/layout_atoms.jl")
include("tables/layout_spacing.jl")
include("tables/layout_symbols.jl")
include("layout.jl")
include("layout/extensible.jl")
include("layout/scripts.jl")
include("layout/constructs.jl")
include("layout/matrix.jl")
include("boxes.jl")
include("shaping.jl")
include("document.jl")
include("compose.jl")

# Public API — configuration surface for typical Makie users.
#
# Internal types (NodeKind, TokenKind, MathTable, GlyphMetrics,
# style helpers, glyph-metric functions) are accessible as TeXLayout.Xxx but
# are not exported so they do not pollute the caller's namespace.
#
# TexStyle enum *values* (Display, Text, Script, …) are deliberately not
# exported to avoid conflicts with Base.Text and Base.Display; access them
# as TeXLayout.Display etc.

# Advanced layout, AST, font-structure, element, and shaper-interface names
# remain available through qualified `TeXLayout.Xxx` access.
export font_family, default_font_family, set_default_font_family!
export default_layout_options, set_default_layout_options!
export HarfBuzzShaper

end
