# MathTeXEngineExt — legacy Makie integration for releases without the public
# `Makie.layout_text` protocol (Makie 0.24 and earlier). It adds a
# MathTeXEngine.generate_tex_elements(::LaTeXString) method that uses TeXLayout's
# OpenType-aware typesetter instead of MathTeXEngine's own layout engine. On
# Makie 0.25 that method steps aside and users select `TeXLayoutHandler` through
# `MakieExt` instead; see the `generate_tex_elements` docstring below.
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
# Source routing and glyph resolution are shared with MakieExt; they live in
# TeXLayout's `src/render_support.jl`.

module MathTeXEngineExt

import MathTeXEngine
import TeXLayout
using GeometryBasics: Point2f
using LaTeXStrings: LaTeXString

# ── Helpers ───────────────────────────────────────────────────────────────────

const _MTEElement = Union{MathTeXEngine.TeXChar, MathTeXEngine.HLine, MathTeXEngine.VLine}
const _MTEElementTuple = Tuple{_MTEElement, Point2f, Float64}
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

# Best-effort Unicode character for a PostScript glyph name.
# Used as TeXChar.represented_char; mainly matters for word-wrap in Makie
# (spaces/newlines), which does not apply inside math mode.
function _represented_char(name::String)::Char
    isempty(name) && return '?'
    mapped = get(_REPRESENTED_CHAR_BY_GLYPH_NAME, name, nothing)
    mapped !== nothing && return mapped
    ch = TeXLayout._single_char(name)
    ch !== nothing && return ch
    ch = TeXLayout._uni_glyph_codepoint(name)
    return ch === nothing ? '?' : ch
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

# Glyph resolution and face caching are shared with `MakieExt` (see
# `src/render_support.jl`); only the derived MathTeXEngine font family is
# specific to this adapter, so it gets its own small cache on the same key.
const _MTE_FAMILY_CACHE = Dict{TeXLayout.FontFamilyKey, MathTeXEngine.FontFamily}()

# Named to stay clear of `generate_tex_elements`'s `_mte_family` argument, which
# would otherwise shadow it at the one call site that matters.
function _cached_mte_font_family(tl_family::TeXLayout.FontFamily)::MathTeXEngine.FontFamily
    return get!(_MTE_FAMILY_CACHE, TeXLayout._font_family_key(tl_family)) do
        _mte_font_family(tl_family)
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
        box::TeXLayout.LayoutBox,
        runtime::TeXLayout.GlyphRuntime,
        mte_family::MathTeXEngine.FontFamily,
    )::Union{_MTEElementTuple, Nothing}
    pos = Point2f(box.x, box.y)
    scale = Float64(box.scale)
    el = box.element

    if el isa TeXLayout.Glyph
        resolved = TeXLayout._resolve_glyph(runtime, el.font_slot, el.glyph_name)
        resolved === nothing && return nothing
        gid, font, _ = resolved
        tc = MathTeXEngine.TeXChar(
            Culong(gid), font, mte_family, false,
            _represented_char(el.glyph_name)
        )
        return (tc, pos, scale)
    elseif el isa TeXLayout.GlyphID
        font = TeXLayout._runtime_font(runtime, el.font_path)
        tc = MathTeXEngine.TeXChar(
            Culong(el.glyph_id), font, mte_family, false,
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
own layout engine on legacy Makie versions. When Makie 0.25's public
`layout_text` interface is active, this compatibility method delegates to
MathTeXEngine's original implementation and TeXLayout is selected explicitly
with [`TeXLayout.TeXLayoutHandler`](@ref).

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
    # Makie 0.25 has a first-class text-handler interface. Once that extension
    # is active, leave MathTeXEngine's own public API alone and let users select
    # TeXLayout explicitly with `text_handler = TeXLayoutHandler()`. The invoke
    # targets MathTeXEngine's untyped fallback, bypassing this legacy
    # LaTeXString specialization.
    makie_ext = Base.get_extension(TeXLayout, :MakieExt)
    if makie_ext !== nothing && makie_ext._HAS_LAYOUT_TEXT_INTERFACE
        return invoke(
            MathTeXEngine.generate_tex_elements,
            Tuple{Any, Any},
            str,
            _mte_family,
        )
    end

    tl_family = TeXLayout.default_font_family()
    runtime = TeXLayout._glyph_runtime(tl_family)
    mte_family = _cached_mte_font_family(tl_family)
    opts = TeXLayout.default_layout_options()
    inline_tokens = TeXLayout._inline_math_tokens(str)

    boxes = if inline_tokens !== nothing
        node = TeXLayout.parse_latex(inline_tokens)
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
        t = _box_to_mte(box, runtime, mte_family)
        t !== nothing && push!(result, t)
    end
    return result
end

end # module MathTeXEngineExt
