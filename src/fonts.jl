# Font loading and glyph metrics.
#
# `FontFamily` bundles a set of OTF/TTF paths for the roles a complete font
# family must fill (regular, italic, bold, bold-italic, and math).  Advance
# widths and left side bearings are read directly from the binary hmtx table
# (matching the font designer's nominal values); ink bounding boxes are
# obtained via FreeTypeAbstraction.

using FreeTypeAbstraction
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
