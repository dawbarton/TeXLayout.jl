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
include("render_support.jl")

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
export TeXLayoutHandler

"""
    TeXLayoutHandler(; family = nothing, options = nothing)

Handler for Makie's `text_handler` interface. On Makie 0.25 and later, pass an
instance as `text_handler = TeXLayoutHandler()` on a text plot or in a theme to
lay out `LaTeXString` values with TeXLayout. Other text values fall through to
Makie's built-in layout through normal dispatch.

By default the handler reads [`default_font_family`](@ref) and
[`default_layout_options`](@ref) when it lays out each block. Pass a `family` or
`options` value to pin either setting for this handler.
"""
struct TeXLayoutHandler
    family::Union{Nothing, FontFamily}
    options::Union{Nothing, LayoutOptions}
end

function TeXLayoutHandler(;
        family::Union{Nothing, FontFamily} = nothing,
        options::Union{Nothing, LayoutOptions} = nothing,
    )
    return TeXLayoutHandler(family, options)
end

end
