# MathTeXEngineExt — add a MathTeXEngine.generate_tex_elements(::LaTeXString) method
# that uses TeXLayout's OpenType-aware typesetter instead of MathTeXEngine's own
# layout engine.
#
# Loaded automatically when TeXLayout, MathTeXEngine, GeometryBasics, and
# LaTeXStrings are all in the same Julia session (e.g. when CairoMakie or
# GLMakie is loaded — both packages always bring the full set as transitive deps).
#
# The ::LaTeXString specialisation is a new method (not an overwrite of an
# existing one), so the extension can be fully precompiled.  Makie's
# texelems_and_glyph_collection passes a LaTeXString directly, so our more
# specific method is always chosen over MathTeXEngine's fallback.
#
# We produce real MathTeXEngine.TeXChar / HLine / VLine instances so that
# Makie's texelems_and_glyph_collection can consume them without modification.

module MathTeXEngineExt

import MathTeXEngine
import TeXLayout
using FreeTypeAbstraction: FreeTypeAbstraction
using GeometryBasics: Point2f
using LaTeXStrings: LaTeXString

# ── Helpers ───────────────────────────────────────────────────────────────────

# Strip surrounding $ delimiters that LaTeXStrings add automatically.
# L"x^2" stores "$x^2$" internally; TeXLayout's parser expects no delimiters.
function _strip_math_delimiters(s::AbstractString)
    str = String(s)
    length(str) >= 2 && str[1] == '$' && str[end] == '$' && return str[2:end-1]
    return str
end

# Resolve a PostScript glyph name to a FreeType glyph index.
# Strategy: PS name lookup → single-char codepoint → uniXXXX encoding.
function _glyph_index(font, name::String)::Culong
    isempty(name) && return Culong(0)

    # Primary: PS name lookup (covers standard names like "parenleft", "alpha").
    gid = FreeTypeAbstraction.glyph_index(font, name)
    gid > 0 && return Culong(gid)

    # Single-character name: try as a Unicode codepoint.
    chars = collect(name)
    if length(chars) == 1
        gid = FreeTypeAbstraction.glyph_index(font, chars[1])
        gid > 0 && return Culong(gid)
    end

    # "uni{HHHH}" or "uni{HHHHHH}" encoding used by some math fonts.
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
    if m !== nothing
        gid = FreeTypeAbstraction.glyph_index(font, Char(parse(UInt32, m.captures[1], base=16)))
        gid > 0 && return Culong(gid)
    end

    return Culong(0)
end

# Best-effort Unicode character for a PostScript glyph name.
# Used as TeXChar.represented_char; mainly matters for word-wrap in Makie
# (spaces/newlines), which does not apply inside math mode.
function _represented_char(name::String)::Char
    isempty(name) && return '?'
    chars = collect(name)
    length(chars) == 1 && return chars[1]
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
    m !== nothing && return Char(parse(UInt32, m.captures[1], base=16))
    return '?'
end

# Build an MTE FontFamily whose slots all point to TeXLayout's chosen fonts.
# This ensures that GlyphExtent computation (ascender/descender) uses the same
# font data as TeXLayout's layout engine.
function _mte_font_family(tl_family::TeXLayout.FontFamily)
    math_path = tl_family.math
    reg_path  = something(tl_family.regular, math_path)
    it_path   = something(tl_family.italic, reg_path)
    bd_path   = something(tl_family.bold, reg_path)
    bdit_path = something(tl_family.bolditalic, it_path)
    MathTeXEngine.FontFamily(Dict(
        :regular    => reg_path,
        :italic     => it_path,
        :bold       => bd_path,
        :bolditalic => bdit_path,
        :math       => math_path,
    ))
end

# Convert a single LayoutBox to an MTE (element, position, scale) tuple, or
# nothing if the box cannot be represented (e.g. missing glyph, bare Space).
# `math_font` and `reg_font` are loaded FreeType face handles; the Glyph's
# `font_slot` field selects which one to use for glyph-index resolution.
function _box_to_mte(box, math_font, reg_font, mte_ff)
    pos   = Point2f(box.x, box.y)
    scale = Float64(box.scale)
    el    = box.element

    if el isa TeXLayout.Glyph
        chosen = el.font_slot === :regular ? reg_font : math_font
        gid = _glyph_index(chosen, el.glyph_name)
        gid == 0 && return nothing
        tc = MathTeXEngine.TeXChar(
            gid, chosen, mte_ff, false, _represented_char(el.glyph_name))
        return (tc, pos, scale)
    elseif el isa TeXLayout.HRule
        return (MathTeXEngine.HLine(Float32(el.width), Float32(el.thickness)), pos, scale)
    elseif el isa TeXLayout.VRule
        return (MathTeXEngine.VLine(Float32(el.height), Float32(el.thickness)), pos, scale)
    end
    # TeXLayout.Space boxes have no visible rendering; skip them.
    return nothing
end

# ── Main override ─────────────────────────────────────────────────────────────

"""
    MathTeXEngine.generate_tex_elements(str::LaTeXString[, font_family])

Specialisation of MathTeXEngine's `generate_tex_elements` for `LaTeXString`
inputs.  Uses TeXLayout's OpenType-aware typesetter instead of MathTeXEngine's
own layout engine.

This is a new method (not an overwrite), so the extension is fully precompiled.
Makie always passes a `LaTeXString` at this call site, so this method takes
priority via normal dispatch specificity.

The `font_family` argument is accepted for API compatibility but is currently
ignored; TeXLayout's `default_font_family()` is used instead.
"""
function MathTeXEngine.generate_tex_elements(str::LaTeXString, _mte_family=MathTeXEngine.FontFamily())
    tl_family = TeXLayout.default_font_family()

    input = _strip_math_delimiters(str)
    node  = TeXLayout.parse_latex(input)
    boxes = TeXLayout.layout(node, tl_family, TeXLayout.Display)

    math_font, _ = TeXLayout._load_font(tl_family.math)
    reg_path      = something(tl_family.regular, tl_family.math)
    reg_font, _   = TeXLayout._load_font(reg_path)
    mte_ff        = _mte_font_family(tl_family)

    result = Tuple[]
    for box in boxes
        t = _box_to_mte(box, math_font, reg_font, mte_ff)
        t !== nothing && push!(result, t)
    end
    return result
end

end # module MathTeXEngineExt
