# Font loading and glyph metrics.
#
# `FontFamily` bundles a set of OTF/TTF paths for the roles a complete font
# family must fill (regular, italic, bold, bold-italic, and math).  Advance
# widths and left side bearings are read directly from the binary hmtx table
# (matching the font designer's nominal values); ink bounding boxes are
# obtained via FreeTypeAbstraction.
#
# `font_family(::Symbol)` provides lazy-download access to the five bundled
# font families (NewCMMath, Pagella, Luciole, STIXTwo, FiraMath) via Julia
# Artifacts.  `font_family(path; ...)` constructs a family from user paths.

using FreeTypeAbstraction
using LazyArtifacts
const _FT = FreeTypeAbstraction.FreeType

"""
A set of OTF/TTF font file paths covering all roles needed for math typesetting.

The `math` slot is mandatory; text slots may be omitted if only math mode is needed.
"""
struct FontFamily
    math::String
    regular::Union{String,Nothing}
    italic::Union{String,Nothing}
    bold::Union{String,Nothing}
    bold_italic::Union{String,Nothing}
end

FontFamily(math::String) = FontFamily(math, nothing, nothing, nothing, nothing)

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
const _FONT_CACHE = Dict{String, Tuple{FreeTypeAbstraction.FTFont, Vector{Tuple{Int,Int}}}}()

# Parse the hmtx table from raw font bytes.
# Returns a 1-indexed vector where index GID+1 gives (advance_width, lsb).
function _parse_hmtx_table(data::Vector{UInt8})::Vector{Tuple{Int,Int}}
    maxp_start, _ = _find_table(data, "maxp")
    num_glyphs    = Int(_u16(data, maxp_start + 4))

    hhea_start, _ = _find_table(data, "hhea")
    n_hm          = Int(_u16(data, hhea_start + 34))   # numberOfHMetrics

    hmtx_start, _ = _find_table(data, "hmtx")

    result = Vector{Tuple{Int,Int}}(undef, num_glyphs)
    last_adv = 0
    for i in 0:(n_hm - 1)
        adv      = Int(_u16(data, hmtx_start + 4*i))
        lsb_u    = Int(_u16(data, hmtx_start + 4*i + 2))
        lsb      = lsb_u >= 0x8000 ? lsb_u - 0x10000 : lsb_u
        result[i + 1] = (adv, lsb)
        last_adv = adv
    end
    # Remaining glyphs inherit the last advance width.
    for i in n_hm:(num_glyphs - 1)
        off   = n_hm * 4 + (i - n_hm) * 2
        lsb_u = Int(_u16(data, hmtx_start + off))
        lsb   = lsb_u >= 0x8000 ? lsb_u - 0x10000 : lsb_u
        result[i + 1] = (last_adv, lsb)
    end
    return result
end

function _load_font(path::String)
    get!(_FONT_CACHE, path) do
        face = FreeTypeAbstraction.FTFont(path)
        hmtx = _parse_hmtx_table(read(path))
        (face, hmtx)
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    glyph_metrics(family, glyph_name) -> GlyphMetrics

Return horizontal metrics for the named glyph in the math font.
`glyph_name` is the PostScript name (e.g. `"f"`, `"parenleft"`, `"alpha"`).
"""
function glyph_metrics(family::FontFamily, glyph_name::String)::GlyphMetrics
    face, hmtx = _load_font(family.math)
    gid = Int(FreeTypeAbstraction.glyph_index(face, glyph_name))
    gid == 0 && error("glyph not found in font: $glyph_name")

    adv, lsb = hmtx[gid + 1]   # hmtx is 1-indexed; GID is 0-based

    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    x_min = Int(m.horiBearingX)
    y_max = Int(m.horiBearingY)
    x_max = Int(m.horiBearingX) + Int(m.width)
    y_min = Int(m.horiBearingY) - Int(m.height)

    GlyphMetrics(adv, lsb, x_min, y_min, x_max, y_max)
end

"""
    glyph_metrics_upright(family, ch) -> Union{GlyphMetrics, Nothing}

Return metrics for character `ch` rendered in an upright (roman) font.

Uses the `regular` font slot when present; otherwise falls back to the math
font's codepoint mapping, which yields upright letter forms in OpenType math
fonts such as NewCMMath (unlike the PS-name lookup, which returns italic forms).
Returns `nothing` if the glyph is absent from the chosen font.
"""
function glyph_metrics_upright(family::FontFamily, ch::Char)::Union{GlyphMetrics,Nothing}
    font_path = family.regular !== nothing ? family.regular : family.math
    face, hmtx = _load_font(font_path)
    gid = Int(_FT.FT_Get_Char_Index(face, UInt32(ch)))
    gid == 0 && return nothing

    adv, lsb = hmtx[gid + 1]
    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    GlyphMetrics(adv, lsb,
                 Int(m.horiBearingX),
                 Int(m.horiBearingY) - Int(m.height),
                 Int(m.horiBearingX) + Int(m.width),
                 Int(m.horiBearingY))
end

"""
    glyph_metrics_by_codepoint(family, codepoint) -> GlyphMetrics

Return metrics for the glyph mapped from a Unicode codepoint in the math font.
"""
function glyph_metrics_by_codepoint(family::FontFamily, cp::UInt32)::GlyphMetrics
    face, hmtx = _load_font(family.math)
    gid = Int(_FT.FT_Get_Char_Index(face, cp))
    gid == 0 && error("no glyph for codepoint U+$(string(cp, base=16, pad=4))")

    adv, lsb = hmtx[gid + 1]

    _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
    m = unsafe_load(face.glyph).metrics
    x_min = Int(m.horiBearingX)
    y_max = Int(m.horiBearingY)
    x_max = Int(m.horiBearingX) + Int(m.width)
    y_min = Int(m.horiBearingY) - Int(m.height)

    GlyphMetrics(adv, lsb, x_min, y_min, x_max, y_max)
end

# ── Unicode math-variant codepoint mapping ────────────────────────────────────

# Exception tables for variants whose Unicode math codepoints are not contiguous
# with the main Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF).
# Sources: Unicode 15 Table 2.8 and the Mathematical Alphanumeric Symbols chart.

# \mathbb exceptions: letters that have dedicated BMP codepoints in addition to
# (or instead of) their Mathematical Double-Struck equivalents.
const _MATHBB_EXCEPTIONS = Dict{Char,UInt32}(
    'C' => 0x2102,  # ℂ  DOUBLE-STRUCK CAPITAL C
    'H' => 0x210D,  # ℍ  DOUBLE-STRUCK CAPITAL H
    'N' => 0x2115,  # ℕ  DOUBLE-STRUCK CAPITAL N
    'P' => 0x2119,  # ℙ  DOUBLE-STRUCK CAPITAL P
    'Q' => 0x211A,  # ℚ  DOUBLE-STRUCK CAPITAL Q
    'R' => 0x211D,  # ℝ  DOUBLE-STRUCK CAPITAL R
    'Z' => 0x2124,  # ℤ  DOUBLE-STRUCK CAPITAL Z
)

# \mathcal exceptions: uppercase letters with BMP Letterlike Symbols codepoints.
const _MATHCAL_UC_EXCEPTIONS = Dict{Char,UInt32}(
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
const _MATHCAL_LC_EXCEPTIONS = Dict{Char,UInt32}(
    'e' => 0x212F,  # ℯ  SCRIPT SMALL E
    'g' => 0x210A,  # ℊ  SCRIPT SMALL G
    'o' => 0x2134,  # ℴ  SCRIPT SMALL O
)

# \mathfrak uppercase exceptions: letters with BMP Letterlike Symbols codepoints.
const _MATHFRAK_UC_EXCEPTIONS = Dict{Char,UInt32}(
    'C' => 0x212D,  # ℭ  FRAKTUR CAPITAL C
    'H' => 0x210C,  # ℌ  FRAKTUR CAPITAL H
    'I' => 0x2111,  # ℑ  FRAKTUR CAPITAL I (BLACK-LETTER)
    'R' => 0x211C,  # ℜ  FRAKTUR CAPITAL R (BLACK-LETTER)
    'Z' => 0x2128,  # ℨ  FRAKTUR CAPITAL Z
)

# \mathit lowercase exceptions.
const _MATHIT_LC_EXCEPTIONS = Dict{Char,UInt32}(
    'h' => 0x210E,  # ℎ  PLANCK CONSTANT (italic h)
)

"""
    _math_variant_codepoint(variant, ch) -> Union{UInt32, Nothing}

Return the Unicode codepoint for character `ch` in the requested math font
variant, or `nothing` if no variant codepoint exists for that character.

Uses the Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF) for
continuous ranges, and dedicated BMP Letterlike Symbols for exceptions.
"""
function _math_variant_codepoint(variant::Symbol, ch::Char)::Union{UInt32,Nothing}
    cp = UInt32(ch)

    # ── \mathbf: bold upright Latin and digits ─────────────────────────────────
    if variant === :mathbf || variant === :boldsymbol
        'A' <= ch <= 'Z' && return 0x1D400 + (cp - UInt32('A'))  # 𝐀–𝐙
        'a' <= ch <= 'z' && return 0x1D41A + (cp - UInt32('a'))  # 𝐚–𝐳
        '0' <= ch <= '9' && return 0x1D7CE + (cp - UInt32('0'))  # 𝟎–𝟗
        return nothing

    # ── \mathit: italic Latin ──────────────────────────────────────────────────
    elseif variant === :mathit || variant === :mathnormal
        'A' <= ch <= 'Z' && return 0x1D434 + (cp - UInt32('A'))  # 𝐴–𝑍
        'a' <= ch <= 'z' && return get(_MATHIT_LC_EXCEPTIONS, ch,
                                       0x1D44E + (cp - UInt32('a')))  # 𝑎–𝑧 (ℎ exception)
        return nothing

    # ── \mathrm: upright via regular font or math-font codepoint ──────────────
    elseif variant === :mathrm
        # ASCII letters map directly; the layout engine will use _upright_glyph.
        # Return nothing here to signal "use upright lookup, not variant codepoint".
        return nothing

    # ── \mathbb: double-struck ─────────────────────────────────────────────────
    elseif variant === :mathbb
        haskey(_MATHBB_EXCEPTIONS, ch) && return _MATHBB_EXCEPTIONS[ch]
        'A' <= ch <= 'Z' && return 0x1D538 + (cp - UInt32('A'))  # 𝔸–𝕑
        'a' <= ch <= 'z' && return 0x1D552 + (cp - UInt32('a'))  # 𝕒–𝕫
        '0' <= ch <= '9' && return 0x1D7D8 + (cp - UInt32('0'))  # 𝟘–𝟡
        return nothing

    # ── \mathcal / \mathscr: script ───────────────────────────────────────────
    elseif variant === :mathcal || variant === :mathscr
        'A' <= ch <= 'Z' && return get(_MATHCAL_UC_EXCEPTIONS, ch,
                                       0x1D49C + (cp - UInt32('A')))  # 𝒜–𝒵
        'a' <= ch <= 'z' && return get(_MATHCAL_LC_EXCEPTIONS, ch,
                                       0x1D4B6 + (cp - UInt32('a')))  # 𝒶–𝓏
        return nothing

    # ── \mathfrak: fraktur ────────────────────────────────────────────────────
    elseif variant === :mathfrak
        'A' <= ch <= 'Z' && return get(_MATHFRAK_UC_EXCEPTIONS, ch,
                                       0x1D504 + (cp - UInt32('A')))  # 𝔄–𝔷
        'a' <= ch <= 'z' && return 0x1D51E + (cp - UInt32('a'))       # 𝔞–𝔷
        return nothing

    # ── \mathsf: sans-serif upright ───────────────────────────────────────────
    elseif variant === :mathsf
        'A' <= ch <= 'Z' && return 0x1D5A0 + (cp - UInt32('A'))  # 𝖠–𝖹
        'a' <= ch <= 'z' && return 0x1D5BA + (cp - UInt32('a'))  # 𝖺–𝗓
        '0' <= ch <= '9' && return 0x1D7E2 + (cp - UInt32('0'))  # 𝟢–𝟫
        return nothing

    # ── \mathtt: monospace ────────────────────────────────────────────────────
    elseif variant === :mathtt
        'A' <= ch <= 'Z' && return 0x1D670 + (cp - UInt32('A'))  # 𝙰–𝚉
        'a' <= ch <= 'z' && return 0x1D68A + (cp - UInt32('a'))  # 𝚊–𝚣
        '0' <= ch <= '9' && return 0x1D7F6 + (cp - UInt32('0'))  # 𝟶–𝟿
        return nothing

    # ── \mathsfit: sans-serif italic ─────────────────────────────────────────
    elseif variant === :mathsfit
        'A' <= ch <= 'Z' && return 0x1D608 + (cp - UInt32('A'))  # 𝘈–𝘡
        'a' <= ch <= 'z' && return 0x1D622 + (cp - UInt32('a'))  # 𝘢–𝘻
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
    face, _ = _load_font(family.math)
    gid = Int(_FT.FT_Get_Char_Index(face, cp))
    gid == 0 && return ""
    buf = zeros(UInt8, 128)
    ret = _FT.FT_Get_Glyph_Name(face, UInt32(gid), buf, UInt32(length(buf)))
    ret != 0 && return ""
    i = findfirst(==(0x00), buf)
    return i === nothing ? "" : String(buf[1:i-1])
end

# ── Named font families via Artifacts ────────────────────────────────────────

# Maps user-facing Symbol names to artifact names in Artifacts.toml.
const _NAMED_ARTIFACTS = Dict{Symbol,String}(
    :new_cm    => "NewCMMath",
    :pagella   => "Pagella",
    :luciole   => "Luciole",
    :stix_two  => "STIXTwo",
    :fira_math => "FiraMath",
)

# Build a FontFamily from an artifact directory.  Tries .otf first, then .ttf
# for the text slots (Luciole ships TTF text fonts).
function _family_from_artifact(dir::AbstractString)::FontFamily
    math = joinpath(dir, "math.otf")
    isfile(math) || error("artifact at $dir is missing math.otf")

    function find_slot(base)
        for ext in (".otf", ".ttf")
            p = joinpath(dir, base * ext)
            isfile(p) && return p
        end
        return nothing
    end

    FontFamily(math,
               find_slot("regular"),
               find_slot("italic"),
               find_slot("bold"),
               find_slot("bolditalic"))
end

# One small function per artifact name so that the @artifact_str macro receives
# a string literal (required — the macro cannot accept a variable).
_artifact_dir_new_cm()    = @artifact_str("NewCMMath")
_artifact_dir_pagella()   = @artifact_str("Pagella")
_artifact_dir_luciole()   = @artifact_str("Luciole")
_artifact_dir_stix_two()  = @artifact_str("STIXTwo")
_artifact_dir_fira_math() = @artifact_str("FiraMath")

const _ARTIFACT_LOADERS = Dict{Symbol, Function}(
    :new_cm    => _artifact_dir_new_cm,
    :pagella   => _artifact_dir_pagella,
    :luciole   => _artifact_dir_luciole,
    :stix_two  => _artifact_dir_stix_two,
    :fira_math => _artifact_dir_fira_math,
)

"""
    font_family(name::Symbol) -> FontFamily

Load a named built-in font family.  The artifact tarball is downloaded lazily
on first use and cached in Julia's artifact store.

| Symbol       | Font                          | Style         |
|:-------------|:------------------------------|:--------------|
| `:new_cm`    | New Computer Modern Math      | CM / serif    |
| `:pagella`   | TeX Gyre Pagella Math         | Palatino      |
| `:luciole`   | Luciole Math                  | Humanist sans |
| `:stix_two`  | STIX Two Math v2.0.2          | Times         |
| `:fira_math` | Fira Math + Fira Sans v0.3.4  | Geometric sans|
"""
function font_family(name::Symbol)::FontFamily
    loader = get(_ARTIFACT_LOADERS, name, nothing)
    loader === nothing &&
        error("unknown font family :$name — choose from: $(join(sort(string.(keys(_ARTIFACT_LOADERS))), ", "))")
    _family_from_artifact(loader())
end

"""
    font_family(math_path; regular, bold, italic, bolditalic) -> FontFamily

Construct a `FontFamily` from user-supplied file paths.  Only `math_path` is
required; text slots default to `nothing` (math-only mode).
"""
function font_family(math_path::AbstractString;
                     regular::Union{AbstractString,Nothing}    = nothing,
                     bold::Union{AbstractString,Nothing}        = nothing,
                     italic::Union{AbstractString,Nothing}      = nothing,
                     bolditalic::Union{AbstractString,Nothing}  = nothing)::FontFamily
    isfile(math_path) || error("math font not found: $math_path")
    FontFamily(math_path, regular, italic, bold, bolditalic)
end

"""
    default_font_family() -> FontFamily

Return the default `FontFamily` (New Computer Modern Math).  Downloads the
artifact on first call if not already cached.
"""
function default_font_family()::FontFamily
    font_family(:new_cm)
end
