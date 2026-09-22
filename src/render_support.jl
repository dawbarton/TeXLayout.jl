# Shared support for the renderer adapters in `ext/`.
#
# `MakieExt` and `MathTeXEngineExt` both have to answer the same two questions
# before they can convert a `LaTeXString` into their host's representation:
#
#   1. Is the string one inline-math span, or mixed text and math?
#   2. Which FreeType face and glyph index does a `Glyph` name resolve to?
#
# Neither answer is host-specific, so both live here rather than being restated
# per extension.  Nothing in this file depends on a weak dependency.

# ── LaTeXString routing ───────────────────────────────────────────────────────

# Strip surrounding $ delimiters that LaTeXStrings add automatically.
# L"x^2" stores "$x^2$" internally; TeXLayout's parser expects no delimiters.
# Indices come from `nextind`/`prevind` so a multibyte first or last character
# (`$α$`) does not raise a `StringIndexError`.
function _strip_math_delimiters(s::AbstractString)::String
    str = String(s)
    if length(str) >= 2 && first(str) == '$' && last(str) == '$'
        inner_start = nextind(str, firstindex(str))
        inner_stop = prevind(str, lastindex(str))
        return inner_start > inner_stop ? "" : str[inner_start:inner_stop]
    end
    return str
end

# Return already-tokenized inline math when the whole string is one `$…$` span,
# or `nothing` when it must use document routing.  Reusing TeXLayout's lexer
# keeps escaped-dollar and comment semantics in one place: `\$` is a command,
# while an unescaped `$` inside the outer delimiters is a MathShift token.
function _inline_math_tokens(s::AbstractString)::Union{Vector{Token}, Nothing}
    length(s) >= 2 || return nothing
    (first(s) == '$' && last(s) == '$') || return nothing
    tokens = tokenize(_strip_math_delimiters(s))
    any(token -> token.kind === TokenKind.MathShift, tokens) && return nothing
    return tokens
end

# True when the whole string is a single inline-math span.  This is the
# canonical `L"…"` form (e.g. "$x^2$").  Anything else — surrounding text,
# `$$…$$`/`\[…\]` display math, or several `$…$` spans — is routed through the
# document layer instead.
_is_inline_math(s::AbstractString)::Bool = _inline_math_tokens(s) !== nothing

# ── Glyph resolution runtime ──────────────────────────────────────────────────

"""
Per-`FontFamily` state a renderer adapter needs on every frame: the loaded
FreeType face for each font path reachable from the family, the slot fallback
chains, and memoized glyph-name → glyph-index lookups.

Built once per family by [`_glyph_runtime`](@ref) and reused, so repeated
renders neither reopen font files nor repeat name lookups.
"""
struct GlyphRuntime
    fonts::Dict{String, FreeTypeAbstraction.FTFont}
    slot_paths::Dict{FontSlot.T, Vector{String}}
    glyph_indices::Dict{Tuple{String, String}, UInt64}
end

const _GLYPH_RUNTIME_CACHE = Dict{FontFamilyKey, GlyphRuntime}()

const _RUNTIME_SLOTS = (
    FontSlot.Math, FontSlot.Regular, FontSlot.Bold,
    FontSlot.Italic, FontSlot.BoldItalic,
)

"""
    _glyph_runtime(family) -> GlyphRuntime

Return the cached [`GlyphRuntime`](@ref) for `family`, building it on first use.
"""
function _glyph_runtime(family::FontFamily)::GlyphRuntime
    return get!(_GLYPH_RUNTIME_CACHE, _font_family_key(family)) do
        slot_paths = Dict{FontSlot.T, Vector{String}}(
            slot => _slot_fallback(family, slot) for slot in _RUNTIME_SLOTS
        )
        fonts = Dict{String, FreeTypeAbstraction.FTFont}()
        for path in unique!(reduce(vcat, values(slot_paths)))
            fonts[path], _ = _load_font(path)
        end
        return GlyphRuntime(fonts, slot_paths, Dict{Tuple{String, String}, UInt64}())
    end
end

"""
    _runtime_font(runtime, path) -> FTFont

Loaded face for `path`, adding it to `runtime` if it is outside the family's
slot fallback chains (a shaped `GlyphID` may name any font file).
"""
function _runtime_font(runtime::GlyphRuntime, path::String)::FreeTypeAbstraction.FTFont
    return get!(runtime.fonts, path) do
        font, _ = _load_font(path)
        font
    end
end

# Return the single character encoded by `name`, or `nothing` if the string is
# empty or contains multiple characters.
@inline function _single_char(name::String)::Union{Char, Nothing}
    isempty(name) && return nothing
    i = firstindex(name)
    return nextind(name, i) > lastindex(name) ? name[i] : nothing
end

const _UNI_GLYPH_NAME = r"^uni([0-9A-Fa-f]{4,6})$"

# The codepoint a `uniXXXX`-style glyph name encodes, or `nothing`.
function _uni_glyph_codepoint(name::String)::Union{Char, Nothing}
    m = match(_UNI_GLYPH_NAME, name)
    return m === nothing ? nothing : Char(parse(UInt32, only(m.captures), base = 16))
end

# Resolve a PostScript glyph name to a FreeType glyph index, or 0 on failure.
# Strategy: PS name lookup → single-char codepoint → uniXXXX encoding.
function _glyph_index_uncached(font::FreeTypeAbstraction.FTFont, name::String)::UInt64
    isempty(name) && return UInt64(0)

    # Primary: PS name lookup (covers standard names like "parenleft", "alpha").
    gid = UInt64(FreeTypeAbstraction.glyph_index(font, name))
    gid > 0 && return gid

    # Single-character name: try as a Unicode codepoint.
    ch = _single_char(name)
    if ch !== nothing
        gid = UInt64(FreeTypeAbstraction.glyph_index(font, ch))
        gid > 0 && return gid
    end

    # "uni{HHHH}" or "uni{HHHHHH}" encoding used by some math fonts.
    ch = _uni_glyph_codepoint(name)
    if ch !== nothing
        gid = UInt64(FreeTypeAbstraction.glyph_index(font, ch))
        gid > 0 && return gid
    end

    return UInt64(0)
end

"""
    _glyph_index(runtime, path, name) -> UInt64

Memoized glyph index for `name` in the face at `path`; 0 when the face has no
such glyph.
"""
function _glyph_index(runtime::GlyphRuntime, path::String, name::String)::UInt64
    return get!(runtime.glyph_indices, (path, name)) do
        _glyph_index_uncached(_runtime_font(runtime, path), name)
    end
end

"""
    _resolve_glyph(runtime, slot, name) -> Union{Tuple{UInt64, FTFont, String}, Nothing}

Walk `slot`'s fallback chain for the first face containing `name`, returning its
glyph index, face, and font path.  `nothing` means no configured font has the
glyph, in which case the adapter has nothing to draw.
"""
function _resolve_glyph(
        runtime::GlyphRuntime, slot::FontSlot.T, name::String
    )::Union{Tuple{UInt64, FreeTypeAbstraction.FTFont, String}, Nothing}
    for path in runtime.slot_paths[slot]
        gid = _glyph_index(runtime, path, name)
        gid > 0 && return (gid, runtime.fonts[path], path)
    end
    return nothing
end
