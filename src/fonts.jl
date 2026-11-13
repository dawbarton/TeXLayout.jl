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

# Thread safety.  Base.Dict is not safe for concurrent use (even a read during
# another task's insertion can fail), so every module-level cache has a lock and
# its values are built under it.  An FT_Face may only be used by one thread at
# a time, and FT_Load_Glyph writes the face's shared glyph slot, so every
# FreeType call on a cached face holds that face's own lock: FreeTypeAbstraction
# documents `FTFont.lock` as the lock for any FT operation on the face, and takes
# it in its own functions such as `glyph_index`.
const _FONT_CACHE_LOCK = ReentrantLock()

# Glyph-slot metrics (design units) for glyph `gid`, loaded under the face lock.
function _load_glyph_metrics(face::FreeTypeAbstraction.FTFont, gid::Integer)
    return @lock face.lock begin
        _FT.FT_Load_Glyph(face, UInt32(gid), _FT.FT_LOAD_NO_SCALE)
        unsafe_load(face.glyph).metrics
    end
end

_char_index(face::FreeTypeAbstraction.FTFont, cp::Integer)::Int =
    Int(@lock face.lock _FT.FT_Get_Char_Index(face, UInt32(cp)))

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
    return @lock _FONT_CACHE_LOCK get!(_FONT_CACHE, path) do
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
    return @lock _NAMED_METRICS_CACHE_LOCK get!(_NAMED_METRICS_CACHE, (family.math, glyph_name)) do
        _named_metrics(family.math, glyph_name)
    end
end

# Metrics by glyph name, memoised per (font path, name): FreeType's name lookup
# and glyph load are slow enough to double layout time when every script glyph
# is swapped for its `ssty` alternate by name.  Locked like every module-level
# cache (see the thread-safety note above).
const _NAMED_METRICS_CACHE = Dict{Tuple{String, String}, Union{GlyphMetrics, Nothing}}()
const _NAMED_METRICS_CACHE_LOCK = ReentrantLock()

function _named_metrics(path::String, glyph_name::String)::Union{GlyphMetrics, Nothing}
    face, hmtx = _load_font(path)
    gid = Int(FreeTypeAbstraction.glyph_index(face, glyph_name))
    gid == 0 && return nothing

    adv, lsb = hmtx[gid + 1]   # hmtx is 1-indexed; GID is 0-based

    m = _load_glyph_metrics(face, gid)
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
    gid = _char_index(face, UInt32(ch))
    gid == 0 && return nothing

    adv, lsb = hmtx[gid + 1]
    m = _load_glyph_metrics(face, gid)
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
    gid = _char_index(face, cp)
    gid == 0 && return nothing
    adv, lsb = hmtx[gid + 1]
    m = _load_glyph_metrics(face, gid)
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
const _UPM_CACHE_LOCK = ReentrantLock()

"""Units-per-em of the font at `path` (cached)."""
function _font_upm(path::String)::Float64
    return Float64(
        @lock _UPM_CACHE_LOCK get!(_UPM_CACHE, path) do
            _parse_upm(read(path))
        end
    )
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
    gid = _char_index(face, cp)
    gid == 0 && return ""
    buf = zeros(UInt8, 128)
    ret = @lock face.lock _FT.FT_Get_Glyph_Name(face, UInt32(gid), buf, UInt32(length(buf)))
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
