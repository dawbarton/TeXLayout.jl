# Font loading and glyph metrics.
#
# `FontFamily` bundles a math font, a primary set of text faces, and optional
# sans-serif and monospace text-face sets. Advance
# widths and left side bearings are read directly from the binary hmtx table
# (matching the font designer's nominal values); ink bounding boxes are
# obtained via FreeTypeAbstraction.
#
# `font_family(::Symbol)` provides lazy-download access to bundled font
# families via Julia
# Artifacts.  `font_family(path; ...)` constructs a family from user paths.

using FreeTypeAbstraction
using LazyArtifacts
const _FT = FreeTypeAbstraction.FreeType

"""Four weight/shape faces belonging to one text font family."""
struct TextFontSet
    regular::Union{String, Nothing}
    italic::Union{String, Nothing}
    bold::Union{String, Nothing}
    bolditalic::Union{String, Nothing}
end

TextFontSet() = TextFontSet(nothing, nothing, nothing, nothing)

function TextFontSet(
        regular::Union{AbstractString, Nothing},
        italic::Union{AbstractString, Nothing} = nothing,
        bold::Union{AbstractString, Nothing} = nothing,
        bolditalic::Union{AbstractString, Nothing} = nothing,
    )
    return TextFontSet(
        regular === nothing ? nothing : String(regular),
        italic === nothing ? nothing : String(italic),
        bold === nothing ? nothing : String(bold),
        bolditalic === nothing ? nothing : String(bolditalic),
    )
end

"""
A set of OTF/TTF font paths covering math and text typesetting.

The `math` slot is mandatory. The primary text slots, `sans`, and `monospace`
may be omitted. Missing text faces follow documented fallback rules ending at
the math font.
"""
struct FontFamily
    math::String
    regular::Union{String, Nothing}
    italic::Union{String, Nothing}
    bold::Union{String, Nothing}
    bolditalic::Union{String, Nothing}
    sans::Union{TextFontSet, Nothing}
    monospace::Union{TextFontSet, Nothing}
end

FontFamily(math::String) =
    FontFamily(math, nothing, nothing, nothing, nothing, nothing, nothing)

FontFamily(
    math::String,
    regular::Union{String, Nothing},
    italic::Union{String, Nothing},
    bold::Union{String, Nothing},
    bolditalic::Union{String, Nothing},
) = FontFamily(math, regular, italic, bold, bolditalic, nothing, nothing)

"""
Basic horizontal metrics for a single glyph (design units, same UPM as the
font's `head` table).
"""
struct GlyphMetrics
    advance_width::Int
    left_side_bearing::Int
    # Ink bounding box relative to the glyph origin (positive y is up).
    x_min::Int
    y_min::Int
    x_max::Int
    y_max::Int
end

# ── Font cache ────────────────────────────────────────────────────────────────

# Per-path cache: FTFont handle + hmtx table (Vector of (advance, lsb) by GID).
const _FONT_CACHE = Dict{String, Tuple{FreeTypeAbstraction.FTFont, Vector{Tuple{Int, Int}}}}()

# Parse the hmtx table from raw font bytes.
# Returns a 1-indexed vector where index GID+1 gives (advance_width, lsb).
function _parse_hmtx_table(data::Vector{UInt8})::Vector{Tuple{Int, Int}}
    maxp_start, _ = _find_table(data, "maxp")
    num_glyphs = Int(_u16(data, maxp_start + 4))

    hhea_start, _ = _find_table(data, "hhea")
    n_hm = Int(_u16(data, hhea_start + 34))   # numberOfHMetrics

    hmtx_start, _ = _find_table(data, "hmtx")

    result = Vector{Tuple{Int, Int}}(undef, num_glyphs)
    last_adv = 0
    for i in 0:(n_hm - 1)
        adv = Int(_u16(data, hmtx_start + 4 * i))
        lsb_u = Int(_u16(data, hmtx_start + 4 * i + 2))
        lsb = lsb_u >= 0x8000 ? lsb_u - 0x00010000 : lsb_u
        result[i + 1] = (adv, lsb)
        last_adv = adv
    end
    # Remaining glyphs inherit the last advance width.
    for i in n_hm:(num_glyphs - 1)
        off = n_hm * 4 + (i - n_hm) * 2
        lsb_u = Int(_u16(data, hmtx_start + off))
        lsb = lsb_u >= 0x8000 ? lsb_u - 0x00010000 : lsb_u
        result[i + 1] = (last_adv, lsb)
    end
    return result
end

function _load_font(path::String)
    return get!(_FONT_CACHE, path) do
        face = FreeTypeAbstraction.FTFont(path)
        hmtx = _parse_hmtx_table(read(path))
        (face, hmtx)
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    glyph_metrics(family, glyph_name) -> Union{GlyphMetrics, Nothing}

Return horizontal metrics for the named glyph in the math font, or `nothing`
if the glyph is absent.  `glyph_name` is the PostScript name (e.g. `"f"`,
`"parenleft"`, `"alpha"`).
"""
function glyph_metrics(family::FontFamily, glyph_name::String)::Union{GlyphMetrics, Nothing}
    face, hmtx = _load_font(family.math)
    gid = Int(FreeTypeAbstraction.glyph_index(face, glyph_name))
    gid == 0 && return nothing

    adv, lsb = hmtx[gid + 1]   # hmtx is 1-indexed; GID is 0-based

    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    x_min = Int(m.horiBearingX)
    y_max = Int(m.horiBearingY)
    x_max = Int(m.horiBearingX) + Int(m.width)
    y_min = Int(m.horiBearingY) - Int(m.height)

    return GlyphMetrics(adv, lsb, x_min, y_min, x_max, y_max)
end

"""
    glyph_metrics_upright(family, ch) -> Union{GlyphMetrics, Nothing}

Return metrics for character `ch` rendered in an upright (roman) font.

Uses the `regular` font slot when present; otherwise falls back to the math
font's codepoint mapping, which yields upright letter forms in OpenType math
fonts such as NewCMMath (unlike the PS-name lookup, which returns italic forms).
Returns `nothing` if the glyph is absent from the chosen font.
"""
function glyph_metrics_upright(family::FontFamily, ch::Char)::Union{GlyphMetrics, Nothing}
    font_path = family.regular !== nothing ? family.regular : family.math
    face, hmtx = _load_font(font_path)
    gid = Int(_FT.FT_Get_Char_Index(face, UInt32(ch)))
    gid == 0 && return nothing

    adv, lsb = hmtx[gid + 1]
    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    return GlyphMetrics(
        adv, lsb,
        Int(m.horiBearingX),
        Int(m.horiBearingY) - Int(m.height),
        Int(m.horiBearingX) + Int(m.width),
        Int(m.horiBearingY)
    )
end

# Glyph ID and metrics for codepoint `cp` in font `path`, or `nothing`.
# Text shapers use this to resolve renderer-facing glyph identity once.
function _codepoint_glyph(
        path::String, cp::UInt32
    )::Union{Tuple{UInt32, GlyphMetrics}, Nothing}
    face, hmtx = _load_font(path)
    gid = Int(_FT.FT_Get_Char_Index(face, cp))
    gid == 0 && return nothing
    adv, lsb = hmtx[gid + 1]
    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    return (
        UInt32(gid),
        GlyphMetrics(
            adv, lsb,
            Int(m.horiBearingX),
            Int(m.horiBearingY) - Int(m.height),
            Int(m.horiBearingX) + Int(m.width),
            Int(m.horiBearingY),
        ),
    )
end

# Metrics for the glyph at Unicode codepoint `cp` in font `path`, or `nothing`.
function _codepoint_metrics(path::String, cp::UInt32)::Union{GlyphMetrics, Nothing}
    result = _codepoint_glyph(path, cp)
    return result === nothing ? nothing : result[2]
end

"""
    glyph_metrics_by_codepoint(family, codepoint) -> Union{GlyphMetrics, Nothing}

Return metrics for the glyph mapped from a Unicode codepoint in the math font,
or `nothing` if the codepoint has no glyph.
"""
function glyph_metrics_by_codepoint(family::FontFamily, cp::UInt32)::Union{GlyphMetrics, Nothing}
    return _codepoint_metrics(family.math, cp)
end

# Priority-ordered list of non-nothing font paths for a given style slot.
# Falls back: requested slot → regular → math, de-duplicated.
function _slot_fallback(family::FontFamily, slot::FontSlot.T)::Vector{String}
    raw = if slot === FontSlot.BoldItalic
        [family.bolditalic, family.bold, family.italic, family.regular, family.math]
    elseif slot === FontSlot.Math
        [family.math]
    elseif slot === FontSlot.Bold
        [family.bold, family.regular, family.math]
    elseif slot === FontSlot.Italic
        [family.italic, family.regular, family.math]
    else  # FontSlot.Regular
        [family.regular, family.math]
    end
    seen = Set{String}()
    result = String[]
    for p in raw
        (p === nothing || p ∈ seen) && continue
        push!(seen, p)
        push!(result, p)
    end
    return result
end

"""First configured font path for `slot`, following TeXLayout's slot fallback rules."""
_font_path_for_slot(family::FontFamily, slot::FontSlot.T)::String = first(_slot_fallback(family, slot))

_roman_font_set(family::FontFamily) =
    TextFontSet(family.regular, family.italic, family.bold, family.bolditalic)

function _font_set(family::FontFamily, text_family::TextFamily.T)
    text_family === TextFamily.Roman && return _roman_font_set(family)
    text_family === TextFamily.Sans && return family.sans
    return family.monospace
end

function _face_fallback(set::TextFontSet, slot::FontSlot.T)
    slot === FontSlot.Math && return Union{String, Nothing}[]
    return if slot === FontSlot.BoldItalic
        [set.bolditalic, set.bold, set.italic, set.regular]
    elseif slot === FontSlot.Bold
        [set.bold, set.regular]
    elseif slot === FontSlot.Italic
        [set.italic, set.regular]
    else
        [set.regular]
    end
end

"""
Priority-ordered physical font paths for one resolved text-family/face request.

The requested family is exhausted before the primary Roman family is tried;
the math font is the final fallback. Paths are de-duplicated.
"""
function _text_font_fallback(
        family::FontFamily,
        text_family::TextFamily.T,
        slot::FontSlot.T,
    )::Vector{String}
    raw = Union{String, Nothing}[]
    requested = _font_set(family, text_family)
    requested === nothing || append!(raw, _face_fallback(requested, slot))
    if text_family !== TextFamily.Roman
        append!(raw, _face_fallback(_roman_font_set(family), slot))
    end
    push!(raw, family.math)

    seen = Set{String}()
    result = String[]
    for path in raw
        (path === nothing || path ∈ seen) && continue
        push!(seen, path)
        push!(result, path)
    end
    return result
end

function _text_glyph(
        family::FontFamily,
        ch::Char,
        text_family::TextFamily.T,
        slot::FontSlot.T,
    )::Union{Tuple{UInt32, GlyphMetrics, String}, Nothing}
    for path in _text_font_fallback(family, text_family, slot)
        result = _codepoint_glyph(path, UInt32(ch))
        result === nothing && continue
        gid, metrics = result
        return (gid, metrics, path)
    end
    return nothing
end

"""
Cache key identifying a `FontFamily` by its font paths alone.

`_font_family_key` is the only place that fixes the tuple's arity; anything
caching per family (the renderer adapters in `ext/`, say) should key on this
type rather than restating the arity.
"""
const FontFamilyKey = NTuple{13, Union{String, Nothing}}

function _font_family_key(family::FontFamily)::FontFamilyKey
    path_fields(set) = set === nothing ?
        (nothing, nothing, nothing, nothing) :
        (set.regular, set.italic, set.bold, set.bolditalic)
    return (
        family.math,
        family.regular,
        family.italic,
        family.bold,
        family.bolditalic,
        path_fields(family.sans)...,
        path_fields(family.monospace)...,
    )
end

"""
    glyph_metrics_slot(family, ch, slot) -> Union{Tuple{GlyphMetrics,String}, Nothing}

Return `(metrics, font_path)` for character `ch` in the requested style slot,
trying the slot's font first then falling back through regular → math. Returns
`nothing` if the character is absent from all fallback fonts.
"""
function glyph_metrics_slot(
        family::FontFamily, ch::Char, slot::FontSlot.T
    )::Union{Tuple{GlyphMetrics, String}, Nothing}
    for path in _slot_fallback(family, slot)
        m = _codepoint_metrics(path, UInt32(ch))
        m !== nothing && return (m, path)
    end
    return nothing
end

# Per-path UPM cache — avoids re-reading the file on every shape_span call.
const _UPM_CACHE = Dict{String, Int}()

"""Units-per-em of the font at `path` (cached)."""
function _font_upm(path::String)::Float64
    return Float64(
        get!(_UPM_CACHE, path) do
            _parse_upm(read(path))
        end
    )
end

# ── Unicode math-variant codepoint mapping ────────────────────────────────────

# Exception tables for variants whose Unicode math codepoints are not contiguous
# with the main Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF).
# Sources: Unicode 15 Table 2.8 and the Mathematical Alphanumeric Symbols chart.

# \mathbb exceptions: letters that have dedicated BMP codepoints in addition to
# (or instead of) their Mathematical Double-Struck equivalents.
const _MATHBB_EXCEPTIONS = Dict{Char, UInt32}(
    'C' => 0x2102,  # ℂ  DOUBLE-STRUCK CAPITAL C
    'H' => 0x210D,  # ℍ  DOUBLE-STRUCK CAPITAL H
    'N' => 0x2115,  # ℕ  DOUBLE-STRUCK CAPITAL N
    'P' => 0x2119,  # ℙ  DOUBLE-STRUCK CAPITAL P
    'Q' => 0x211A,  # ℚ  DOUBLE-STRUCK CAPITAL Q
    'R' => 0x211D,  # ℝ  DOUBLE-STRUCK CAPITAL R
    'Z' => 0x2124,  # ℤ  DOUBLE-STRUCK CAPITAL Z
)

# \mathcal exceptions: uppercase letters with BMP Letterlike Symbols codepoints.
const _MATHCAL_UC_EXCEPTIONS = Dict{Char, UInt32}(
    'B' => 0x212C,  # ℬ  SCRIPT CAPITAL B
    'E' => 0x2130,  # ℰ  SCRIPT CAPITAL E
    'F' => 0x2131,  # ℱ  SCRIPT CAPITAL F
    'H' => 0x210B,  # ℋ  SCRIPT CAPITAL H
    'I' => 0x2110,  # ℐ  SCRIPT CAPITAL I
    'L' => 0x2112,  # ℒ  SCRIPT CAPITAL L
    'M' => 0x2133,  # ℳ  SCRIPT CAPITAL M
    'R' => 0x211B,  # ℛ  SCRIPT CAPITAL R
)

# \mathcal lowercase exceptions.
const _MATHCAL_LC_EXCEPTIONS = Dict{Char, UInt32}(
    'e' => 0x212F,  # ℯ  SCRIPT SMALL E
    'g' => 0x210A,  # ℊ  SCRIPT SMALL G
    'o' => 0x2134,  # ℴ  SCRIPT SMALL O
)

# \mathfrak uppercase exceptions: letters with BMP Letterlike Symbols codepoints.
const _MATHFRAK_UC_EXCEPTIONS = Dict{Char, UInt32}(
    'C' => 0x212D,  # ℭ  FRAKTUR CAPITAL C
    'H' => 0x210C,  # ℌ  FRAKTUR CAPITAL H
    'I' => 0x2111,  # ℑ  FRAKTUR CAPITAL I (BLACK-LETTER)
    'R' => 0x211C,  # ℜ  FRAKTUR CAPITAL R (BLACK-LETTER)
    'Z' => 0x2128,  # ℨ  FRAKTUR CAPITAL Z
)

# \mathit lowercase exceptions.
const _MATHIT_LC_EXCEPTIONS = Dict{Char, UInt32}(
    'h' => 0x210E,  # ℎ  PLANCK CONSTANT (italic h)
)

"""
    _math_variant_codepoint(variant, ch) -> Union{UInt32, Nothing}

Return the Unicode codepoint for character `ch` in the requested math font
variant, or `nothing` if no variant codepoint exists for that character.

Uses the Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF) for
continuous ranges, and dedicated BMP Letterlike Symbols for exceptions.
"""
function _math_variant_codepoint(variant::Symbol, ch::Char)::Union{UInt32, Nothing}
    cp = UInt32(ch)

    # ── \mathbf: bold upright Latin, digits, and Greek ─────────────────────────
    # Unicode Mathematical Bold block: Latin UC 1D400–1D419, LC 1D41A–1D433,
    # digits 1D7CE–1D7D7; Greek UC 1D6A8–1D6C0, LC 1D6C2–1D6DA.
    # The Greek UC gap at 0x03A2 (no such letter) aligns with the ϴ-symbol slot
    # 1D6B9 in the math block, so a single offset covers Α–Ρ and Σ–Ω uniformly.
    if variant === :mathbf
        'A' <= ch <= 'Z' && return 0x0001D400 + (cp - UInt32('A'))  # 𝐀–𝐙
        'a' <= ch <= 'z' && return 0x0001D41A + (cp - UInt32('a'))  # 𝐚–𝐳
        '0' <= ch <= '9' && return 0x0001D7CE + (cp - UInt32('0'))  # 𝟎–𝟗
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D6A8 + (cp - UInt32('Α'))             # 𝚨–𝛀
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D6C2 + (cp - UInt32('α'))             # 𝛂–𝛚
        ch === '∇' && return 0x0001D6C1  # bold ∇
        ch === '∂' && return 0x0001D6DB  # bold ∂
        ch === 'ϵ' && return 0x0001D6DC  # bold ϵ (varepsilon)
        ch === 'ϑ' && return 0x0001D6DD  # bold ϑ (vartheta)
        ch === 'ϰ' && return 0x0001D6DE  # bold ϰ (varkappa)
        ch === 'ϕ' && return 0x0001D6DF  # bold ϕ (varphi)
        ch === 'ϱ' && return 0x0001D6E0  # bold ϱ (varrho)
        ch === 'ϖ' && return 0x0001D6E1  # bold ϖ (varpi)
        return nothing

        # ── \boldsymbol: bold italic Latin and Greek ──────────────────────────────
        # Unlike \mathbf, bold italic uses separate Latin slots (1D468 UC, 1D482 LC)
        # and a separate Greek block (UC 1D71C–1D734, LC 1D736–1D74E).
    elseif variant === :boldsymbol
        'A' <= ch <= 'Z' && return 0x0001D468 + (cp - UInt32('A'))  # 𝑨–𝒁
        'a' <= ch <= 'z' && return 0x0001D482 + (cp - UInt32('a'))  # 𝒂–𝒛
        '0' <= ch <= '9' && return 0x0001D7CE + (cp - UInt32('0'))  # 𝟎–𝟗 (bold only; no bold-italic digit block)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D71C + (cp - UInt32('Α'))             # 𝜜–𝜴
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D736 + (cp - UInt32('α'))             # 𝜶–𝝎
        ch === '∇' && return 0x0001D735  # bold italic ∇
        ch === '∂' && return 0x0001D74F  # bold italic ∂
        ch === 'ϵ' && return 0x0001D750  # bold italic ϵ
        ch === 'ϑ' && return 0x0001D751  # bold italic ϑ
        ch === 'ϰ' && return 0x0001D752  # bold italic ϰ
        ch === 'ϕ' && return 0x0001D753  # bold italic ϕ
        ch === 'ϱ' && return 0x0001D754  # bold italic ϱ
        ch === 'ϖ' && return 0x0001D755  # bold italic ϖ
        return nothing

        # ── \mathit / \mathnormal: italic Latin and Greek ─────────────────────────
        # Greek italic: UC 1D6E2–1D6FA, LC 1D6FC–1D714 (default math style for Greek).
    elseif variant === :mathit || variant === :mathnormal
        'A' <= ch <= 'Z' && return 0x0001D434 + (cp - UInt32('A'))  # 𝐴–𝑍
        'a' <= ch <= 'z' && return get(
            _MATHIT_LC_EXCEPTIONS, ch,
            0x0001D44E + (cp - UInt32('a'))
        )  # 𝑎–𝑧 (ℎ exception)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D6E2 + (cp - UInt32('Α'))             # 𝛢–𝛺
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D6FC + (cp - UInt32('α'))             # 𝛼–𝜔
        ch === '∇' && return 0x0001D6FB  # italic ∇
        ch === '∂' && return 0x0001D715  # italic ∂
        ch === 'ϵ' && return 0x0001D716  # italic ϵ
        ch === 'ϑ' && return 0x0001D717  # italic ϑ
        ch === 'ϰ' && return 0x0001D718  # italic ϰ
        ch === 'ϕ' && return 0x0001D719  # italic ϕ
        ch === 'ϱ' && return 0x0001D71A  # italic ϱ
        ch === 'ϖ' && return 0x0001D71B  # italic ϖ
        return nothing

        # ── \mathrm: upright via regular font or math-font codepoint ──────────────
    elseif variant === :mathrm
        # ASCII letters map directly; the layout engine will use _upright_glyph.
        # Return nothing here to signal "use upright lookup, not variant codepoint".
        return nothing

        # ── \mathbb: double-struck ─────────────────────────────────────────────────
    elseif variant === :mathbb
        haskey(_MATHBB_EXCEPTIONS, ch) && return _MATHBB_EXCEPTIONS[ch]
        'A' <= ch <= 'Z' && return 0x0001D538 + (cp - UInt32('A'))  # 𝔸–𝕑
        'a' <= ch <= 'z' && return 0x0001D552 + (cp - UInt32('a'))  # 𝕒–𝕫
        '0' <= ch <= '9' && return 0x0001D7D8 + (cp - UInt32('0'))  # 𝟘–𝟡
        return nothing

        # ── \mathcal / \mathscr: script ───────────────────────────────────────────
    elseif variant === :mathcal || variant === :mathscr
        'A' <= ch <= 'Z' && return get(
            _MATHCAL_UC_EXCEPTIONS, ch,
            0x0001D49C + (cp - UInt32('A'))
        )  # 𝒜–𝒵
        'a' <= ch <= 'z' && return get(
            _MATHCAL_LC_EXCEPTIONS, ch,
            0x0001D4B6 + (cp - UInt32('a'))
        )  # 𝒶–𝓏
        return nothing

        # ── \mathfrak: fraktur ────────────────────────────────────────────────────
    elseif variant === :mathfrak
        'A' <= ch <= 'Z' && return get(
            _MATHFRAK_UC_EXCEPTIONS, ch,
            0x0001D504 + (cp - UInt32('A'))
        )  # 𝔄–𝔷
        'a' <= ch <= 'z' && return 0x0001D51E + (cp - UInt32('a'))       # 𝔞–𝔷
        return nothing

        # ── \mathsf: sans-serif upright ───────────────────────────────────────────
    elseif variant === :mathsf
        'A' <= ch <= 'Z' && return 0x0001D5A0 + (cp - UInt32('A'))  # 𝖠–𝖹
        'a' <= ch <= 'z' && return 0x0001D5BA + (cp - UInt32('a'))  # 𝖺–𝗓
        '0' <= ch <= '9' && return 0x0001D7E2 + (cp - UInt32('0'))  # 𝟢–𝟫
        return nothing

        # ── \mathtt: monospace ────────────────────────────────────────────────────
    elseif variant === :mathtt
        'A' <= ch <= 'Z' && return 0x0001D670 + (cp - UInt32('A'))  # 𝙰–𝚉
        'a' <= ch <= 'z' && return 0x0001D68A + (cp - UInt32('a'))  # 𝚊–𝚣
        '0' <= ch <= '9' && return 0x0001D7F6 + (cp - UInt32('0'))  # 𝟶–𝟿
        return nothing

        # ── \mathsfit: sans-serif italic ─────────────────────────────────────────
    elseif variant === :mathsfit
        'A' <= ch <= 'Z' && return 0x0001D608 + (cp - UInt32('A'))  # 𝘈–𝘡
        'a' <= ch <= 'z' && return 0x0001D622 + (cp - UInt32('a'))  # 𝘢–𝘻
        return nothing

    else
        return nothing
    end
end

"""
    glyph_name_by_codepoint(family, codepoint) -> String

Return the PostScript glyph name for the glyph mapped from a Unicode codepoint
in the math font.  Returns an empty string if the codepoint has no glyph or the
font carries no glyph-name table.
"""
function glyph_name_by_codepoint(family::FontFamily, cp::UInt32)::String
    return glyph_name_by_codepoint(family.math, cp)
end

# Low-level overload: look up the PS glyph name for a codepoint in any font
# file by path.  Used by _upright_glyph to query the regular font directly.
function glyph_name_by_codepoint(font_path::String, cp::UInt32)::String
    face, _ = _load_font(font_path)
    gid = Int(_FT.FT_Get_Char_Index(face, cp))
    gid == 0 && return ""
    buf = zeros(UInt8, 128)
    ret = _FT.FT_Get_Glyph_Name(face, UInt32(gid), buf, UInt32(length(buf)))
    ret != 0 && return ""
    i = findfirst(==(0x00), buf)
    return i === nothing ? "" : String(buf[1:(i - 1)])
end

# ── Named font families via Artifacts ────────────────────────────────────────

# Find one conventional face file in an artifact directory.
function _artifact_face(dir::AbstractString, base::String)
    for ext in (".otf", ".ttf")
        path = joinpath(dir, base * ext)
        isfile(path) && return path
    end
    return nothing
end

function _text_set_from_artifact(dir::AbstractString)::TextFontSet
    return TextFontSet(
        _artifact_face(dir, "regular"),
        _artifact_face(dir, "italic"),
        _artifact_face(dir, "bold"),
        _artifact_face(dir, "bolditalic"),
    )
end

# Build a FontFamily from its primary artifact and optional shared companion
# artifacts. Luciole uses TTF text faces; all other bundled faces are OTF.
function _family_from_artifact(
        dir::AbstractString;
        sans_dir::Union{AbstractString, Nothing} = nothing,
        monospace_dir::Union{AbstractString, Nothing} = nothing,
        primary_is_sans::Bool = false,
    )::FontFamily
    math = joinpath(dir, "math.otf")
    isfile(math) || error("artifact at $dir is missing math.otf")
    primary = _text_set_from_artifact(dir)
    sans = if primary_is_sans
        primary
    elseif sans_dir === nothing
        nothing
    else
        _text_set_from_artifact(sans_dir)
    end
    monospace = monospace_dir === nothing ? nothing : _text_set_from_artifact(monospace_dir)
    return FontFamily(
        math,
        primary.regular,
        primary.italic,
        primary.bold,
        primary.bolditalic,
        sans,
        monospace,
    )
end

# One small function per artifact name so that the @artifact_str macro receives
# a string literal (required — the macro cannot accept a variable).
_artifact_dir_new_cm() = @artifact_str("NewCMMath")
_artifact_dir_pagella() = @artifact_str("Pagella")
_artifact_dir_luciole() = @artifact_str("Luciole")
_artifact_dir_stix_two() = @artifact_str("STIXTwo")
_artifact_dir_fira_math() = @artifact_str("FiraMath")
_artifact_dir_schola() = @artifact_str("Schola")
_artifact_dir_termes() = @artifact_str("Termes")
_artifact_dir_bonum() = @artifact_str("Bonum")
_artifact_dir_heros() = @artifact_str("Heros")
_artifact_dir_cursor() = @artifact_str("Cursor")
const _ARTIFACT_LOADERS = Dict{Symbol, Function}(
    :new_cm => _artifact_dir_new_cm,
    :pagella => _artifact_dir_pagella,
    :luciole => _artifact_dir_luciole,
    :stix_two => _artifact_dir_stix_two,
    :fira_math => _artifact_dir_fira_math,
    :schola => _artifact_dir_schola,
    :termes => _artifact_dir_termes,
    :bonum => _artifact_dir_bonum,
)

"""
    font_family(name::Symbol) -> FontFamily

Load a named built-in font family.  The artifact tarball is downloaded lazily
on first use and cached in Julia's artifact store.

| Symbol       | Font                          | Style              |
|:-------------|:------------------------------|:-------------------|
| `:new_cm`    | New Computer Modern Math      | CM / serif         |
| `:pagella`   | TeX Gyre Pagella Math         | Palatino           |
| `:luciole`   | Luciole Math                  | Humanist sans      |
| `:stix_two`  | STIX Two Math v2.0.2          | Times              |
| `:fira_math` | Fira Math + Fira Sans v0.3.4  | Geometric sans     |
| `:schola`    | TeX Gyre Schola Math          | Century Schoolbook |
| `:termes`    | TeX Gyre Termes Math          | Times New Roman    |
| `:bonum`     | TeX Gyre Bonum Math           | ITC Bookman        |
"""
function font_family(name::Symbol)::FontFamily
    loader = get(_ARTIFACT_LOADERS, name, nothing)
    loader === nothing &&
        error("unknown font family :$name — choose from: $(join(sort(string.(keys(_ARTIFACT_LOADERS))), ", "))")
    primary_is_sans = name === :fira_math || name === :luciole
    sans_dir = primary_is_sans ? nothing : _artifact_dir_heros()
    return _family_from_artifact(
        loader();
        sans_dir,
        monospace_dir = _artifact_dir_cursor(),
        primary_is_sans,
    )
end

"""
    font_family(math_path; regular, bold, italic, bolditalic, sans, monospace)
        -> FontFamily

Construct a `FontFamily` from user-supplied file paths.  Only `math_path` is
required; text faces default to `nothing` (math-only mode). `sans` and
`monospace` accept unexported `TeXLayout.TextFontSet` values.
"""
function font_family(
        math_path::AbstractString;
        regular::Union{AbstractString, Nothing} = nothing,
        bold::Union{AbstractString, Nothing} = nothing,
        italic::Union{AbstractString, Nothing} = nothing,
        bolditalic::Union{AbstractString, Nothing} = nothing,
        sans::Union{TextFontSet, Nothing} = nothing,
        monospace::Union{TextFontSet, Nothing} = nothing,
    )::FontFamily
    function checked_path(path, role)
        path === nothing && return nothing
        isfile(path) || error("$role font not found: $path")
        return abspath(normpath(path))
    end

    function checked_set(set, role)
        set === nothing && return nothing
        return TextFontSet(
            checked_path(set.regular, "$role regular"),
            checked_path(set.italic, "$role italic"),
            checked_path(set.bold, "$role bold"),
            checked_path(set.bolditalic, "$role bold-italic"),
        )
    end

    return FontFamily(
        checked_path(math_path, "math"),
        checked_path(regular, "regular"),
        checked_path(italic, "italic"),
        checked_path(bold, "bold"),
        checked_path(bolditalic, "bold-italic"),
        checked_set(sans, "sans-serif"),
        checked_set(monospace, "monospace"),
    )
end

# Process-global default.  Stores a Symbol (defers artifact download) or a
# FontFamily constructed from user-supplied paths.  Library code must never
# mutate this; only end-user scripts and notebooks should call
# set_default_font_family!.
const _DEFAULT_FONT_FAMILY = Ref{Union{Symbol, FontFamily}}(:new_cm)

"""
    set_default_font_family!(family)

Set the font family returned by `default_font_family()`.  Accepts a `Symbol`
(e.g. `:pagella`) or a `FontFamily` constructed from file paths.  The change
takes effect immediately and affects all subsequent calls, including the Makie
extension.  No artifact download is triggered until `default_font_family()` is
called.

Library code should never call this function; it is intended for end-user
scripts and interactive sessions only.
"""
function set_default_font_family!(f::Union{Symbol, FontFamily})
    return _DEFAULT_FONT_FAMILY[] = f
end

"""
    default_font_family() -> FontFamily

Return the current default `FontFamily`.  Initially New Computer Modern Math;
override with `set_default_font_family!`.  The artifact is downloaded lazily on
first call if the default is still a `Symbol`.
"""
function default_font_family()::FontFamily
    v = _DEFAULT_FONT_FAMILY[]
    return v isa Symbol ? font_family(v) : v
end
