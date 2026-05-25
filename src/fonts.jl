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
    bolditalic::Union{String,Nothing}
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
    glyph_metrics(family, glyph_name) -> Union{GlyphMetrics, Nothing}

Return horizontal metrics for the named glyph in the math font, or `nothing`
if the glyph is absent.  `glyph_name` is the PostScript name (e.g. `"f"`,
`"parenleft"`, `"alpha"`).
"""
function glyph_metrics(family::FontFamily, glyph_name::String)::Union{GlyphMetrics,Nothing}
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
    glyph_metrics_by_codepoint(family, codepoint) -> Union{GlyphMetrics, Nothing}

Return metrics for the glyph mapped from a Unicode codepoint in the math font,
or `nothing` if the codepoint has no glyph.
"""
function glyph_metrics_by_codepoint(family::FontFamily, cp::UInt32)::Union{GlyphMetrics,Nothing}
    face, hmtx = _load_font(family.math)
    gid = Int(_FT.FT_Get_Char_Index(face, cp))
    gid == 0 && return nothing

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

    # ── \mathbf: bold upright Latin, digits, and Greek ─────────────────────────
    # Unicode Mathematical Bold block: Latin UC 1D400–1D419, LC 1D41A–1D433,
    # digits 1D7CE–1D7D7; Greek UC 1D6A8–1D6C0, LC 1D6C2–1D6DA.
    # The Greek UC gap at 0x03A2 (no such letter) aligns with the ϴ-symbol slot
    # 1D6B9 in the math block, so a single offset covers Α–Ρ and Σ–Ω uniformly.
    if variant === :mathbf
        'A' <= ch <= 'Z' && return 0x1D400 + (cp - UInt32('A'))  # 𝐀–𝐙
        'a' <= ch <= 'z' && return 0x1D41A + (cp - UInt32('a'))  # 𝐚–𝐳
        '0' <= ch <= '9' && return 0x1D7CE + (cp - UInt32('0'))  # 𝟎–𝟗
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x1D6A8 + (cp - UInt32('Α'))             # 𝚨–𝛀
        end
        'α' <= ch <= 'ω' &&
            return 0x1D6C2 + (cp - UInt32('α'))             # 𝛂–𝛚
        ch === '∇' && return 0x1D6C1  # bold ∇
        ch === '∂' && return 0x1D6DB  # bold ∂
        ch === 'ϵ' && return 0x1D6DC  # bold ϵ (varepsilon)
        ch === 'ϑ' && return 0x1D6DD  # bold ϑ (vartheta)
        ch === 'ϰ' && return 0x1D6DE  # bold ϰ (varkappa)
        ch === 'ϕ' && return 0x1D6DF  # bold ϕ (varphi)
        ch === 'ϱ' && return 0x1D6E0  # bold ϱ (varrho)
        ch === 'ϖ' && return 0x1D6E1  # bold ϖ (varpi)
        return nothing

    # ── \boldsymbol: bold italic Latin and Greek ──────────────────────────────
    # Unlike \mathbf, bold italic uses separate Latin slots (1D468 UC, 1D482 LC)
    # and a separate Greek block (UC 1D71C–1D734, LC 1D736–1D74E).
    elseif variant === :boldsymbol
        'A' <= ch <= 'Z' && return 0x1D468 + (cp - UInt32('A'))  # 𝑨–𝒁
        'a' <= ch <= 'z' && return 0x1D482 + (cp - UInt32('a'))  # 𝒂–𝒛
        '0' <= ch <= '9' && return 0x1D7CE + (cp - UInt32('0'))  # 𝟎–𝟗 (bold only; no bold-italic digit block)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x1D71C + (cp - UInt32('Α'))             # 𝜜–𝜴
        end
        'α' <= ch <= 'ω' &&
            return 0x1D736 + (cp - UInt32('α'))             # 𝜶–𝝎
        ch === '∇' && return 0x1D735  # bold italic ∇
        ch === '∂' && return 0x1D74F  # bold italic ∂
        ch === 'ϵ' && return 0x1D750  # bold italic ϵ
        ch === 'ϑ' && return 0x1D751  # bold italic ϑ
        ch === 'ϰ' && return 0x1D752  # bold italic ϰ
        ch === 'ϕ' && return 0x1D753  # bold italic ϕ
        ch === 'ϱ' && return 0x1D754  # bold italic ϱ
        ch === 'ϖ' && return 0x1D755  # bold italic ϖ
        return nothing

    # ── \mathit / \mathnormal: italic Latin and Greek ─────────────────────────
    # Greek italic: UC 1D6E2–1D6FA, LC 1D6FC–1D714 (default math style for Greek).
    elseif variant === :mathit || variant === :mathnormal
        'A' <= ch <= 'Z' && return 0x1D434 + (cp - UInt32('A'))  # 𝐴–𝑍
        'a' <= ch <= 'z' && return get(_MATHIT_LC_EXCEPTIONS, ch,
                                       0x1D44E + (cp - UInt32('a')))  # 𝑎–𝑧 (ℎ exception)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x1D6E2 + (cp - UInt32('Α'))             # 𝛢–𝛺
        end
        'α' <= ch <= 'ω' &&
            return 0x1D6FC + (cp - UInt32('α'))             # 𝛼–𝜔
        ch === '∇' && return 0x1D6FB  # italic ∇
        ch === '∂' && return 0x1D715  # italic ∂
        ch === 'ϵ' && return 0x1D716  # italic ϵ
        ch === 'ϑ' && return 0x1D717  # italic ϑ
        ch === 'ϰ' && return 0x1D718  # italic ϰ
        ch === 'ϕ' && return 0x1D719  # italic ϕ
        ch === 'ϱ' && return 0x1D71A  # italic ϱ
        ch === 'ϖ' && return 0x1D71B  # italic ϖ
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
    :schola    => "Schola",
    :termes    => "Termes",
    :bonum     => "Bonum",
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
_artifact_dir_schola()    = @artifact_str("Schola")
_artifact_dir_termes()    = @artifact_str("Termes")
_artifact_dir_bonum()     = @artifact_str("Bonum")
const _ARTIFACT_LOADERS = Dict{Symbol, Function}(
    :new_cm    => _artifact_dir_new_cm,
    :pagella   => _artifact_dir_pagella,
    :luciole   => _artifact_dir_luciole,
    :stix_two  => _artifact_dir_stix_two,
    :fira_math => _artifact_dir_fira_math,
    :schola    => _artifact_dir_schola,
    :termes    => _artifact_dir_termes,
    :bonum     => _artifact_dir_bonum,
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

# Process-global default.  Stores a Symbol (defers artifact download) or a
# FontFamily constructed from user-supplied paths.  Library code must never
# mutate this; only end-user scripts and notebooks should call
# set_default_font_family!.
const _DEFAULT_FONT_FAMILY = Ref{Union{Symbol,FontFamily}}(:new_cm)

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
function set_default_font_family!(f::Union{Symbol,FontFamily})
    _DEFAULT_FONT_FAMILY[] = f
end

"""
    default_font_family() -> FontFamily

Return the current default `FontFamily`.  Initially New Computer Modern Math;
override with `set_default_font_family!`.  The artifact is downloaded lazily on
first call if the default is still a `Symbol`.
"""
function default_font_family()::FontFamily
    v = _DEFAULT_FONT_FAMILY[]
    v isa Symbol ? font_family(v) : v
end
