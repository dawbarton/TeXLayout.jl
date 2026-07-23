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

const _MTEElement = Union{MathTeXEngine.TeXChar, MathTeXEngine.HLine, MathTeXEngine.VLine}
const _MTEElementTuple = Tuple{_MTEElement, Point2f, Float64}
const _RuntimeKey = NTuple{13, Union{String, Nothing}}
const _REPRESENTED_CHAR_BY_GLYPH_NAME = Dict(
    "space" => ' ',
    "hyphen" => '-',
    "minus" => '-',
    "period" => '.',
    "comma" => ',',
    "colon" => ':',
    "semicolon" => ';',
    "plus" => '+',
    "equal" => '=',
    "parenleft" => '(',
    "parenright" => ')',
    "bracketleft" => '[',
    "bracketright" => ']',
    "braceleft" => '{',
    "braceright" => '}',
    "slash" => '/',
    "backslash" => '\\',
    "Lambda" => 'Λ',
)

mutable struct _RuntimeBundle
    fonts::Dict{String, FreeTypeAbstraction.FTFont}
    mte_family::MathTeXEngine.FontFamily
    slot_paths::Dict{TeXLayout.FontSlot.T, Vector{String}}
    glyph_indices::Dict{Tuple{String, String}, Culong}
end

const _RUNTIME_CACHE = Dict{_RuntimeKey, _RuntimeBundle}()

# Strip surrounding $ delimiters that LaTeXStrings add automatically.
# L"x^2" stores "$x^2$" internally; TeXLayout's parser expects no delimiters.
function _strip_math_delimiters(s::AbstractString)
    str = String(s)
    length(str) >= 2 && str[1] == '$' && str[end] == '$' && return str[2:(end - 1)]
    return str
end

# True when the whole string is a single inline-math span: it starts and ends with
# a single `$` and contains no other `$`.  This is the canonical `L"…"` form (e.g.
# "$x^2$").  Anything else — surrounding text, `$$…$$`/`\[…\]` display math, or
# several `$…$` spans — is routed through the document layer instead.
function _is_inline_math(s::AbstractString)::Bool
    length(s) >= 2 || return false
    (first(s) == '$' && last(s) == '$') || return false
    return count(==('$'), s) == 2
end

# Return the single character encoded by `name`, or `nothing` if the string is
# empty or contains multiple characters.
@inline function _single_char(name::String)::Union{Char, Nothing}
    isempty(name) && return nothing
    i = firstindex(name)
    ch = name[i]
    next_i = nextind(name, i)
    return next_i > lastindex(name) ? ch : nothing
end

# Resolve a PostScript glyph name to a FreeType glyph index.
# Strategy: PS name lookup → single-char codepoint → uniXXXX encoding.
function _glyph_index_uncached(font, name::String)::Culong
    isempty(name) && return Culong(0)

    # Primary: PS name lookup (covers standard names like "parenleft", "alpha").
    gid = FreeTypeAbstraction.glyph_index(font, name)
    gid > 0 && return Culong(gid)

    # Single-character name: try as a Unicode codepoint.
    ch = _single_char(name)
    if ch !== nothing
        gid = FreeTypeAbstraction.glyph_index(font, ch)
        gid > 0 && return Culong(gid)
    end

    # "uni{HHHH}" or "uni{HHHHHH}" encoding used by some math fonts.
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
    if m !== nothing
        gid = FreeTypeAbstraction.glyph_index(font, Char(parse(UInt32, m.captures[1], base = 16)))
        gid > 0 && return Culong(gid)
    end

    return Culong(0)
end

@inline function _glyph_index(
        cache::Dict{Tuple{String, String}, Culong}, font, path::String, name::String
    )::Culong
    return get!(cache, (path, name)) do
        _glyph_index_uncached(font, name)
    end
end

# Best-effort Unicode character for a PostScript glyph name.
# Used as TeXChar.represented_char; mainly matters for word-wrap in Makie
# (spaces/newlines), which does not apply inside math mode.
function _represented_char(name::String)::Char
    isempty(name) && return '?'
    mapped = get(_REPRESENTED_CHAR_BY_GLYPH_NAME, name, nothing)
    mapped !== nothing && return mapped
    ch = _single_char(name)
    ch !== nothing && return ch
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
    m !== nothing && return Char(parse(UInt32, m.captures[1], base = 16))
    return '?'
end

# Build an MTE FontFamily whose slots all point to TeXLayout's chosen fonts.
# This ensures that GlyphExtent computation (ascender/descender) uses the same
# font data as TeXLayout's layout engine.
function _mte_font_family(tl_family::TeXLayout.FontFamily)
    math_path = tl_family.math
    reg_path = something(tl_family.regular, math_path)
    it_path = something(tl_family.italic, reg_path)
    bd_path = something(tl_family.bold, reg_path)
    bdit_path = something(tl_family.bolditalic, it_path)
    return MathTeXEngine.FontFamily(
        Dict(
            :regular => reg_path,
            :italic => it_path,
            :bold => bd_path,
            :bolditalic => bdit_path,
            :math => math_path,
        )
    )
end

@inline _runtime_key(tl_family::TeXLayout.FontFamily) =
    TeXLayout._font_family_key(tl_family)

function _runtime_bundle(tl_family::TeXLayout.FontFamily)::_RuntimeBundle
    return get!(_RUNTIME_CACHE, _runtime_key(tl_family)) do
        slot_paths = Dict(
            TeXLayout.FontSlot.Math => TeXLayout._slot_fallback(tl_family, TeXLayout.FontSlot.Math),
            TeXLayout.FontSlot.Regular => TeXLayout._slot_fallback(tl_family, TeXLayout.FontSlot.Regular),
            TeXLayout.FontSlot.Bold => TeXLayout._slot_fallback(tl_family, TeXLayout.FontSlot.Bold),
            TeXLayout.FontSlot.Italic => TeXLayout._slot_fallback(tl_family, TeXLayout.FontSlot.Italic),
            TeXLayout.FontSlot.BoldItalic => TeXLayout._slot_fallback(tl_family, TeXLayout.FontSlot.BoldItalic),
        )
        paths = unique!(reduce(vcat, values(slot_paths)))
        fonts = Dict{String, FreeTypeAbstraction.FTFont}()
        for path in paths
            fonts[path], _ = TeXLayout._load_font(path)
        end
        _RuntimeBundle(
            fonts,
            _mte_font_family(tl_family),
            slot_paths,
            Dict{Tuple{String, String}, Culong}(),
        )
    end
end

function _glyph_index_for_slot(
        runtime::_RuntimeBundle, slot::TeXLayout.FontSlot.T, name::String
    )::Union{Tuple{Culong, FreeTypeAbstraction.FTFont}, Nothing}
    for path in runtime.slot_paths[slot]
        font = runtime.fonts[path]
        gid = _glyph_index(runtime.glyph_indices, font, path, name)
        gid > 0 && return (gid, font)
    end
    return nothing
end

function _font_for_path(runtime::_RuntimeBundle, path::String)::FreeTypeAbstraction.FTFont
    return get!(runtime.fonts, path) do
        font, _ = TeXLayout._load_font(path)
        font
    end
end

# Convert a single LayoutBox to an MTE (element, position, scale) tuple, or
# nothing if the box cannot be represented (e.g. missing glyph, bare Space).
# `math_font` and `reg_font` are loaded FreeType face handles; the Glyph's
# `font_slot` field selects the fallback chain to use for glyph-index resolution.
# TeXLayout rules are rectangle-anchored (`HRule.y` / `VRule.x` are the bottom /
# left edges).  MathTeXEngine's `HLine` / `VLine` instead use centered line
# positions, so the adapter must shift by half the rule thickness.
function _box_to_mte(
        box::TeXLayout.LayoutBox, runtime::_RuntimeBundle
    )::Union{_MTEElementTuple, Nothing}
    pos = Point2f(box.x, box.y)
    scale = Float64(box.scale)
    el = box.element

    if el isa TeXLayout.Glyph
        resolved = _glyph_index_for_slot(runtime, el.font_slot, el.glyph_name)
        resolved === nothing && return nothing
        gid, font = resolved
        tc = MathTeXEngine.TeXChar(
            gid, font, runtime.mte_family, false,
            _represented_char(el.glyph_name)
        )
        return (tc, pos, scale)
    elseif el isa TeXLayout.GlyphID
        font = _font_for_path(runtime, el.font_path)
        tc = MathTeXEngine.TeXChar(
            Culong(el.glyph_id), font, runtime.mte_family, false,
            el.represented_char,
        )
        return (tc, pos, scale)
    elseif el isa TeXLayout.HRule
        rule_pos = Point2f(box.x, box.y + el.thickness / 2)
        return (
            MathTeXEngine.HLine(Float32(el.width), Float32(el.thickness)),
            rule_pos,
            scale,
        )
    elseif el isa TeXLayout.VRule
        rule_pos = Point2f(box.x + el.thickness / 2, box.y)
        return (
            MathTeXEngine.VLine(Float32(el.height), Float32(el.thickness)),
            rule_pos,
            scale,
        )
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

Routing depends on the string's shape:

  - A single inline-math span (`"\$…\$"`, the usual `L"…"` form) is laid out as one
    formula in `Display` style — MathTeXEngine's traditional behaviour.
  - Anything else — surrounding text, `\$\$…\$\$` / `\\[…\\]` display math, or several
    `\$…\$` spans — is routed through [`TeXLayout.layout_document`](@ref), so mixed
    text-and-math `LaTeXString`s render through the document layer.

The `font_family` argument is accepted for API compatibility but is currently
ignored; TeXLayout's `default_font_family()` is used instead.
"""
function MathTeXEngine.generate_tex_elements(str::LaTeXString, _mte_family = MathTeXEngine.FontFamily())
    tl_family = TeXLayout.default_font_family()
    runtime = _runtime_bundle(tl_family)
    opts = TeXLayout.default_layout_options()

    boxes = if _is_inline_math(str)
        node = TeXLayout.parse_latex(_strip_math_delimiters(str))
        TeXLayout.layout(node, tl_family, TeXLayout.Display; shaper = opts.shaper)
    else
        # Width/alignment cannot be passed through Makie's fixed call site, so the
        # document path uses the session-wide default options
        # (set via TeXLayout.set_default_layout_options!).
        TeXLayout.layout_document(String(str), opts; family = tl_family).boxes
    end

    result = Vector{_MTEElementTuple}()
    sizehint!(result, length(boxes))
    for box in boxes
        t = _box_to_mte(box, runtime)
        t !== nothing && push!(result, t)
    end
    return result
end

end # module MathTeXEngineExt
