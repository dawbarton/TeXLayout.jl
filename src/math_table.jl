# OpenType MATH table parser.
#
# Reads the binary MATH table from an OTF/TTF font file and exposes all three
# sub-tables: MathConstants, MathGlyphInfo (italic corrections, top-accent
# attachments, extended shapes), and MathVariants (size variants + assemblies).
# None of this is accessible via FreeType; we parse the raw table ourselves.
#
# Binary layout follows the OpenType 1.9 specification:
#   https://docs.microsoft.com/en-us/typography/opentype/spec/math
#
# All file offsets in the spec are 0-based.  Internally we use 1-based Julia
# array positions: a spec offset N maps to Julia position (table_start + N).

# ── MathConstants ─────────────────────────────────────────────────────────────

"""All 56 design-unit parameters from the OpenType MATH MathConstants sub-table.

Field names follow Julia snake_case; the corresponding OpenType CamelCase names
are given in comments. Values are in font design units (divide by UPM for em-fractions).
"""
struct MathConstants
    # Percentage scale factors (stored as integer percent, not a MathValueRecord)
    script_percent_scale_down::Int              # ScriptPercentScaleDown
    script_script_percent_scale_down::Int       # ScriptScriptPercentScaleDown
    # Minimum heights
    delimited_sub_formula_min_height::Int       # DelimitedSubFormulaMinHeight
    display_operator_min_height::Int            # DisplayOperatorMinHeight
    # Vertical positions
    math_leading::Int                           # MathLeading
    axis_height::Int                            # AxisHeight
    accent_base_height::Int                     # AccentBaseHeight
    flattened_accent_base_height::Int           # FlattenedAccentBaseHeight
    # Subscript/superscript
    subscript_shift_down::Int                   # SubscriptShiftDown
    subscript_top_max::Int                      # SubscriptTopMax
    subscript_baseline_drop_min::Int            # SubscriptBaselineDropMin
    superscript_shift_up::Int                   # SuperscriptShiftUp
    superscript_shift_up_cramped::Int           # SuperscriptShiftUpCramped
    superscript_bottom_min::Int                 # SuperscriptBottomMin
    superscript_baseline_drop_max::Int          # SuperscriptBaselineDropMax
    sub_superscript_gap_min::Int                # SubSuperscriptGapMin
    superscript_bottom_max_with_subscript::Int  # SuperscriptBottomMaxWithSubscript
    space_after_script::Int                     # SpaceAfterScript
    # Limits
    upper_limit_gap_min::Int                    # UpperLimitGapMin
    upper_limit_baseline_rise_min::Int          # UpperLimitBaselineRiseMin
    lower_limit_gap_min::Int                    # LowerLimitGapMin
    lower_limit_baseline_drop_min::Int          # LowerLimitBaselineDropMin
    # Stacks
    stack_top_shift_up::Int                     # StackTopShiftUp
    stack_top_display_style_shift_up::Int       # StackTopDisplayStyleShiftUp
    stack_bottom_shift_down::Int                # StackBottomShiftDown
    stack_bottom_display_style_shift_down::Int  # StackBottomDisplayStyleShiftDown
    stack_gap_min::Int                          # StackGapMin
    stack_display_style_gap_min::Int            # StackDisplayStyleGapMin
    # Stretch stacks
    stretch_stack_top_shift_up::Int             # StretchStackTopShiftUp
    stretch_stack_bottom_shift_down::Int        # StretchStackBottomShiftDown
    stretch_stack_gap_above_min::Int            # StretchStackGapAboveMin
    stretch_stack_gap_below_min::Int            # StretchStackGapBelowMin
    # Fractions
    fraction_numerator_shift_up::Int               # FractionNumeratorShiftUp
    fraction_numerator_display_style_shift_up::Int # FractionNumeratorDisplayStyleShiftUp
    fraction_denominator_shift_down::Int           # FractionDenominatorShiftDown
    fraction_denominator_display_style_shift_down::Int # FractionDenominatorDisplayStyleShiftDown
    fraction_numerator_gap_min::Int                # FractionNumeratorGapMin
    fraction_num_display_style_gap_min::Int        # FractionNumDisplayStyleGapMin
    fraction_rule_thickness::Int                   # FractionRuleThickness
    fraction_denominator_gap_min::Int              # FractionDenominatorGapMin
    fraction_denom_display_style_gap_min::Int      # FractionDenomDisplayStyleGapMin
    # Skewed fractions
    skewed_fraction_horizontal_gap::Int         # SkewedFractionHorizontalGap
    skewed_fraction_vertical_gap::Int           # SkewedFractionVerticalGap
    # Over/underbar
    overbar_vertical_gap::Int                   # OverbarVerticalGap
    overbar_rule_thickness::Int                 # OverbarRuleThickness
    overbar_extra_ascender::Int                 # OverbarExtraAscender
    underbar_vertical_gap::Int                  # UnderbarVerticalGap
    underbar_rule_thickness::Int                # UnderbarRuleThickness
    underbar_extra_descender::Int               # UnderbarExtraDescender
    # Radical
    radical_vertical_gap::Int                   # RadicalVerticalGap
    radical_display_style_vertical_gap::Int     # RadicalDisplayStyleVerticalGap
    radical_rule_thickness::Int                 # RadicalRuleThickness
    radical_extra_ascender::Int                 # RadicalExtraAscender
    radical_kern_before_degree::Int             # RadicalKernBeforeDegree
    radical_kern_after_degree::Int              # RadicalKernAfterDegree
    radical_degree_bottom_raise_percent::Int    # RadicalDegreeBottomRaisePercent
end

# ── MathVariants ──────────────────────────────────────────────────────────────

"""One pre-built larger variant of a glyph."""
struct GlyphVariant
    glyph_name::String
    advance::Int   # advance in the direction of extension (design units)
end

"""One part of an extensible glyph assembly."""
struct GlyphAssemblyPart
    glyph_name::String
    full_advance::Int       # full advance of the part (design units)
    start_connector::Int    # overlap allowed at the start (design units)
    end_connector::Int      # overlap allowed at the end (design units)
    is_extender::Bool       # if true, this part may be repeated
end

"""Extensible glyph assembly: a list of parts that can be stacked."""
struct GlyphAssembly
    italic_correction::Int
    parts::Vector{GlyphAssemblyPart}
end

"""All construction data for one stretchable glyph."""
struct GlyphConstruction
    variants::Vector{GlyphVariant}           # pre-built size variants (may be empty)
    assembly::Union{GlyphAssembly, Nothing}   # extensible assembly (may be nothing)
end

# ── Full MATH table ────────────────────────────────────────────────────────────

"""Complete data from the OpenType MATH table of a single font."""
struct MathTable
    upm::Int                                          # units per em
    constants::MathConstants
    italic_corrections::Dict{String, Int}              # glyph name → design units
    top_accent_attachments::Dict{String, Int}          # glyph name → x position (design units)
    extended_shapes::Set{String}                      # glyph names with extended-shape flag
    min_connector_overlap::Int                        # MathVariants.MinConnectorOverlap
    vert_constructions::Dict{String, GlyphConstruction}
    horiz_constructions::Dict{String, GlyphConstruction}
end

# ══════════════════════════════════════════════════════════════════════════════
# Parser implementation
# ══════════════════════════════════════════════════════════════════════════════

# ── Low-level big-endian readers ──────────────────────────────────────────────
# p is always a 1-based Julia array index.

@inline _u16(d::Vector{UInt8}, p::Int) = (UInt16(d[p]) << 8) | UInt16(d[p + 1])

@inline _i16(d::Vector{UInt8}, p::Int) = reinterpret(Int16, _u16(d, p))

@inline function _u32(d::Vector{UInt8}, p::Int)
    return (UInt32(d[p]) << 24) | (UInt32(d[p + 1]) << 16) |
        (UInt32(d[p + 2]) << 8) | UInt32(d[p + 3])
end

# ── sfnt table directory ──────────────────────────────────────────────────────

# Returns (1-based start position, byte length) of the named 4-char table tag.
function _find_table(data::Vector{UInt8}, tag::String)::Tuple{Int, Int}
    n = Int(_u16(data, 5))   # numTables at sfnt offset 4
    for i in 0:(n - 1)
        r = 13 + 16 * i        # 1-based start of i-th TableRecord
        String(data[r:(r + 3)]) == tag || continue
        return Int(_u32(data, r + 8)) + 1, Int(_u32(data, r + 12))
    end
    error("Font table '$tag' not found")
end

# ── UPM from head table ───────────────────────────────────────────────────────

function _parse_upm(data::Vector{UInt8})::Int
    hs, _ = _find_table(data, "head")
    return Int(_u16(data, hs + 18))   # unitsPerEm at head offset 18
end

# Like _find_table but returns nothing if the tag is absent rather than erroring.
function _find_table_opt(data::Vector{UInt8}, tag::String)::Union{Tuple{Int, Int}, Nothing}
    n = Int(_u16(data, 5))
    for i in 0:(n - 1)
        r = 13 + 16 * i
        String(data[r:(r + 3)]) == tag || continue
        return Int(_u32(data, r + 8)) + 1, Int(_u32(data, r + 12))
    end
    return nothing
end

# ── CFF glyph names (post v3.0 fonts store names in the CFF charset) ──────────

# The 391 predefined CFF standard strings (SIDs 0–390).
# Source: Adobe Technical Note #5176, Appendix A; verified against fontTools.
const _CFF_STD_STRINGS = [
    ".notdef", "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand",
    "quoteright", "parenleft", "parenright", "asterisk", "plus", "comma", "hyphen", "period",
    "slash", "zero", "one", "two", "three", "four", "five", "six",
    "seven", "eight", "nine", "colon", "semicolon", "less", "equal", "greater",
    "question", "at", "A", "B", "C", "D", "E", "F",
    "G", "H", "I", "J", "K", "L", "M", "N",
    "O", "P", "Q", "R", "S", "T", "U", "V",
    "W", "X", "Y", "Z", "bracketleft", "backslash", "bracketright", "asciicircum",
    "underscore", "quoteleft", "a", "b", "c", "d", "e", "f",
    "g", "h", "i", "j", "k", "l", "m", "n",
    "o", "p", "q", "r", "s", "t", "u", "v",
    "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde",
    "exclamdown", "cent", "sterling", "fraction", "yen", "florin", "section", "currency",
    "quotesingle", "quotedblleft", "guillemotleft", "guilsinglleft", "guilsinglright", "fi", "fl", "endash",
    "dagger", "daggerdbl", "periodcentered", "paragraph", "bullet", "quotesinglbase", "quotedblbase", "quotedblright",
    "guillemotright", "ellipsis", "perthousand", "questiondown", "grave", "acute", "circumflex", "tilde",
    "macron", "breve", "dotaccent", "dieresis", "ring", "cedilla", "hungarumlaut", "ogonek",
    "caron", "emdash", "AE", "ordfeminine", "Lslash", "Oslash", "OE", "ordmasculine",
    "ae", "dotlessi", "lslash", "oslash", "oe", "germandbls", "onesuperior", "logicalnot",
    "mu", "trademark", "Eth", "onehalf", "plusminus", "Thorn", "onequarter", "divide",
    "brokenbar", "degree", "thorn", "threequarters", "twosuperior", "registered", "minus", "eth",
    "multiply", "threesuperior", "copyright", "Aacute", "Acircumflex", "Adieresis", "Agrave", "Aring",
    "Atilde", "Ccedilla", "Eacute", "Ecircumflex", "Edieresis", "Egrave", "Iacute", "Icircumflex",
    "Idieresis", "Igrave", "Ntilde", "Oacute", "Ocircumflex", "Odieresis", "Ograve", "Otilde",
    "Scaron", "Uacute", "Ucircumflex", "Udieresis", "Ugrave", "Yacute", "Ydieresis", "Zcaron",
    "aacute", "acircumflex", "adieresis", "agrave", "aring", "atilde", "ccedilla", "eacute",
    "ecircumflex", "edieresis", "egrave", "iacute", "icircumflex", "idieresis", "igrave", "ntilde",
    "oacute", "ocircumflex", "odieresis", "ograve", "otilde", "scaron", "uacute", "ucircumflex",
    "udieresis", "ugrave", "yacute", "ydieresis", "zcaron", "exclamsmall", "Hungarumlautsmall", "dollaroldstyle",
    "dollarsuperior", "ampersandsmall", "Acutesmall", "parenleftsuperior", "parenrightsuperior", "twodotenleader", "onedotenleader", "zerooldstyle",
    "oneoldstyle", "twooldstyle", "threeoldstyle", "fouroldstyle", "fiveoldstyle", "sixoldstyle", "sevenoldstyle", "eightoldstyle",
    "nineoldstyle", "commasuperior", "threequartersemdash", "periodsuperior", "questionsmall", "asuperior", "bsuperior", "centsuperior",
    "dsuperior", "esuperior", "isuperior", "lsuperior", "msuperior", "nsuperior", "osuperior", "rsuperior",
    "ssuperior", "tsuperior", "ff", "ffi", "ffl", "parenleftinferior", "parenrightinferior", "Circumflexsmall",
    "hyphensuperior", "Gravesmall", "Asmall", "Bsmall", "Csmall", "Dsmall", "Esmall", "Fsmall",
    "Gsmall", "Hsmall", "Ismall", "Jsmall", "Ksmall", "Lsmall", "Msmall", "Nsmall",
    "Osmall", "Psmall", "Qsmall", "Rsmall", "Ssmall", "Tsmall", "Usmall", "Vsmall",
    "Wsmall", "Xsmall", "Ysmall", "Zsmall", "colonmonetary", "onefitted", "rupiah", "Tildesmall",
    "exclamdownsmall", "centoldstyle", "Lslashsmall", "Scaronsmall", "Zcaronsmall", "Dieresissmall", "Brevesmall", "Caronsmall",
    "Dotaccentsmall", "Macronsmall", "figuredash", "hypheninferior", "Ogoneksmall", "Ringsmall", "Cedillasmall", "questiondownsmall",
    "oneeighth", "threeeighths", "fiveeighths", "seveneighths", "onethird", "twothirds", "zerosuperior", "foursuperior",
    "fivesuperior", "sixsuperior", "sevensuperior", "eightsuperior", "ninesuperior", "zeroinferior", "oneinferior", "twoinferior",
    "threeinferior", "fourinferior", "fiveinferior", "sixinferior", "seveninferior", "eightinferior", "nineinferior", "centinferior",
    "dollarinferior", "periodinferior", "commainferior", "Agravesmall", "Aacutesmall", "Acircumflexsmall", "Atildesmall", "Adieresissmall",
    "Aringsmall", "AEsmall", "Ccedillasmall", "Egravesmall", "Eacutesmall", "Ecircumflexsmall", "Edieresissmall", "Igravesmall",
    "Iacutesmall", "Icircumflexsmall", "Idieresissmall", "Ethsmall", "Ntildesmall", "Ogravesmall", "Oacutesmall", "Ocircumflexsmall",
    "Otildesmall", "Odieresissmall", "OEsmall", "Oslashsmall", "Ugravesmall", "Uacutesmall", "Ucircumflexsmall", "Udieresissmall",
    "Yacutesmall", "Thornsmall", "Ydieresissmall", "001.000", "001.001", "001.002", "001.003", "Black",
    "Bold", "Book", "Light", "Medium", "Regular", "Roman", "Semibold",
]

# Returns the 1-based Julia position of the first byte AFTER the CFF INDEX at p.
function _cff_skip_index(data::Vector{UInt8}, p::Int)::Int
    count = Int(_u16(data, p))
    count == 0 && return p + 2
    off_size = Int(data[p + 2])
    last_off_pos = p + 3 + off_size * count    # position of the last offset entry
    last_off = 0
    for j in 0:(off_size - 1)
        last_off = (last_off << 8) | Int(data[last_off_pos + j])
    end
    data_start = p + 3 + off_size * (count + 1)
    return data_start + last_off - 1           # first byte past the INDEX
end

# Parse all entries in a CFF INDEX as raw byte vectors.
# Returns (next_position, entries).
function _cff_read_index(data::Vector{UInt8}, p::Int)::Tuple{Int, Vector{Vector{UInt8}}}
    count = Int(_u16(data, p))
    if count == 0
        return p + 2, Vector{Vector{UInt8}}()
    end
    off_size = Int(data[p + 2])
    data_start = p + 3 + off_size * (count + 1)

    read_off(i::Int) = let q = p + 3 + off_size * i  # 0-indexed i
        v = 0
        for j in 0:(off_size - 1)
            v = (v << 8) | Int(data[q + j])
        end
        v
    end

    entries = Vector{Vector{UInt8}}(undef, count)
    for i in 1:count
        o1 = read_off(i - 1)
        o2 = read_off(i)
        # CFF offsets are 1-based within the data section
        entries[i] = data[(data_start + o1 - 1):(data_start + o2 - 2)]
    end
    return data_start + read_off(count) - 1, entries
end

# Scan CFF Top DICT bytes for operator 15 (charset offset).
# Returns the offset relative to the CFF table start (0 = ISOAdobe built-in).
function _cff_top_dict_charset_offset(dict_bytes::Vector{UInt8})::Int
    i = 1
    operands = Int[]
    while i <= length(dict_bytes)
        b = Int(dict_bytes[i])
        if b == 28                     # int16
            v = (Int(dict_bytes[i + 1]) << 8) | Int(dict_bytes[i + 2])
            v >= 0x8000 && (v -= 0x00010000)
            push!(operands, v);  i += 3
        elseif b == 29                 # int32
            v = (Int(dict_bytes[i + 1]) << 24) | (Int(dict_bytes[i + 2]) << 16) |
                (Int(dict_bytes[i + 3]) << 8) | Int(dict_bytes[i + 4])
            # 0x100000000 is UInt64; subtract as Int to avoid UInt64 promotion.
            v >= 0x80000000 && (v -= Int(0x0000000100000000))
            push!(operands, v);  i += 5
        elseif b == 30                 # real — skip to 0xF end nibble
            i += 1
            while i <= length(dict_bytes)
                byte = dict_bytes[i];  i += 1
                ((byte & 0xF0) == 0xF0 || (byte & 0x0F) == 0x0F) && break
            end
        elseif 32 <= b <= 246
            push!(operands, b - 139);  i += 1
        elseif 247 <= b <= 250
            push!(operands, (b - 247) * 256 + Int(dict_bytes[i + 1]) + 108);  i += 2
        elseif 251 <= b <= 254
            push!(operands, -(b - 251) * 256 - Int(dict_bytes[i + 1]) - 108);  i += 2
        elseif b == 12                 # two-byte escape operator
            empty!(operands);  i += 2
        else                           # single-byte operator
            if b == 15 && !isempty(operands)
                return last(operands)
            end
            empty!(operands);  i += 1
        end
    end
    return 0
end

# Parse glyph names from the CFF table for post-table version 3.0 fonts.
function _parse_cff_glyph_names(data::Vector{UInt8}, cff_start::Int)::Vector{String}
    maxp_start, _ = _find_table(data, "maxp")
    num_glyphs = Int(_u16(data, maxp_start + 4))

    # CFF header: major(1) minor(1) hdrSize(1) offSize(1)
    hdr_size = Int(data[cff_start + 2])

    # Navigate: Name INDEX → Top DICT INDEX → String INDEX
    name_idx_start = cff_start + hdr_size
    top_dict_start = _cff_skip_index(data, name_idx_start)
    top_dict_end, top_dict_entries = _cff_read_index(data, top_dict_start)
    string_idx_start = top_dict_end

    charset_off = isempty(top_dict_entries) ? 0 :
        _cff_top_dict_charset_offset(top_dict_entries[1])

    # Build String INDEX lookup: SID 391+ → custom glyph names
    _, string_raw = _cff_read_index(data, string_idx_start)
    string_entries = [String(e) for e in string_raw]

    function sid_to_name(sid::Int)::String
        sid < 391 && return _CFF_STD_STRINGS[sid + 1]
        idx = sid - 391 + 1
        return idx <= length(string_entries) ? string_entries[idx] : ".notdef"
    end

    names = Vector{String}(undef, num_glyphs)
    names[1] = ".notdef"   # GID 0 is always .notdef

    if charset_off <= 2
        # Built-in charset (0=ISOAdobe, 1=Expert, 2=ExpertSubset): SID ≈ GID
        for gid in 1:(num_glyphs - 1)
            names[gid + 1] = sid_to_name(gid)
        end
    else
        cs = cff_start + charset_off
        fmt = Int(data[cs])
        if fmt == 0
            # Flat array: uint16 SID per GID 1..num_glyphs-1
            for gid in 1:(num_glyphs - 1)
                sid = Int(_u16(data, cs + 1 + 2 * (gid - 1)))
                names[gid + 1] = sid_to_name(sid)
            end
        elseif fmt == 1
            # Ranges with uint8 numLeft
            gid = 1;  p = cs + 1
            while gid < num_glyphs
                sid = Int(_u16(data, p))
                n_left = Int(data[p + 2])
                for k in 0:n_left
                    gid >= num_glyphs && break
                    names[gid + 1] = sid_to_name(sid + k);  gid += 1
                end
                p += 3
            end
        else  # fmt == 2: ranges with uint16 numLeft
            gid = 1;  p = cs + 1
            while gid < num_glyphs
                sid = Int(_u16(data, p))
                n_left = Int(_u16(data, p + 2))
                for k in 0:n_left
                    gid >= num_glyphs && break
                    names[gid + 1] = sid_to_name(sid + k);  gid += 1
                end
                p += 4
            end
        end
    end

    return names
end

# ── Glyph names from post table ───────────────────────────────────────────────

# Macintosh standard glyph order (258 names, indices 0–257).
# Used to decode post-table version 2.0 glyphNameIndex values < 258.
const _MAC_NAMES = [
    ".notdef", ".null", "nonmarkingreturn", "space", "exclam", "quotedbl",
    "numbersign", "dollar", "percent", "ampersand", "quotesingle", "parenleft",
    "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash",
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "bracketleft", "backslash", "bracketright", "asciicircum", "underscore",
    "grave",
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "braceleft", "bar", "braceright", "asciitilde",
    "Adieresis", "Aring", "Ccedilla", "Eacute", "Ntilde", "Odieresis",
    "Udieresis", "aacute", "agrave", "acircumflex", "adieresis", "atilde",
    "aring", "ccedilla", "eacute", "egrave", "ecircumflex", "edieresis",
    "iacute", "igrave", "icircumflex", "idieresis", "ntilde", "oacute",
    "ograve", "ocircumflex", "odieresis", "otilde", "uacute", "ugrave",
    "ucircumflex", "udieresis", "dagger", "degree", "cent", "sterling",
    "section", "bullet", "paragraph", "germandbls", "registered", "copyright",
    "trademark", "acute", "dieresis", "notequal", "AE", "Oslash", "infinity",
    "plusminus", "lessequal", "greaterequal", "yen", "mu", "partialdiff",
    "summation", "product", "pi", "integral", "ordfeminine", "ordmasculine",
    "Omega", "ae", "oslash", "questiondown", "exclamdown", "logicalnot",
    "radical", "florin", "approxequal", "Delta", "guillemotleft",
    "guillemotright", "ellipsis", "nonbreakingspace", "Agrave", "Atilde",
    "Otilde", "OE", "oe", "endash", "emdash", "quotedblleft", "quotedblright",
    "quoteleft", "quoteright", "divide", "lozenge", "ydieresis", "Ydieresis",
    "fraction", "currency", "guilsinglleft", "guilsinglright", "fi", "fl",
    "daggerdbl", "periodcentered", "quotesinglbase", "quotedblbase",
    "perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis",
    "Egrave", "Iacute", "Icircumflex", "Idieresis", "Igrave", "Oacute",
    "Ocircumflex", "apple", "Ograve", "Uacute", "Ucircumflex", "Ugrave",
    "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent",
    "ring", "cedilla", "hungarumlaut", "ogonek", "caron", "Lslash", "lslash",
    "Scaron", "scaron", "Zcaron", "zcaron", "brokenbar", "Eth", "eth",
    "Yacute", "yacute", "Thorn", "thorn", "minus", "multiply", "onesuperior",
    "twosuperior", "threesuperior", "onehalf", "onequarter", "threequarters",
    "franc", "Gbreve", "gbreve", "Idotaccent", "Scedilla", "scedilla",
    "Cacute", "cacute", "Ccaron", "ccaron", "dcroat",
]

# Returns a Vector{String} indexed 1-based by (glyph_id + 1).
function _parse_glyph_names(data::Vector{UInt8})::Vector{String}
    ps, tlen = _find_table(data, "post")
    version = _u32(data, ps)

    if version == 0x00010000   # 1.0 — glyphs are exactly the 258 Mac standard names
        return copy(_MAC_NAMES)

    elseif version == 0x00020000  # 2.0 — custom names via glyphNameIndex + Pascal strings
        # post header is 32 bytes; numGlyphs follows immediately
        n = Int(_u16(data, ps + 32))
        indices = [Int(_u16(data, ps + 34 + 2 * (i - 1))) for i in 1:n]

        # Determine how many custom Pascal strings we must read
        n_custom = 0
        for idx in indices
            idx >= 258 && (n_custom = max(n_custom, idx - 258 + 1))
        end

        custom = String[]
        p = ps + 34 + 2 * n          # first Pascal string
        post_end = ps + tlen - 1
        while length(custom) < n_custom && p <= post_end
            len = Int(data[p]);  p += 1
            push!(custom, len > 0 ? String(data[p:(p + len - 1)]) : "")
            p += len
        end

        names = Vector{String}(undef, n)
        for (i, idx) in enumerate(indices)
            names[i] = if idx < 258
                _MAC_NAMES[idx + 1]
            elseif idx - 258 < length(custom)
                custom[idx - 258 + 1]
            else
                ".notdef"
            end
        end
        return names

    else
        # v3.0 has no names in the post table; names are in the CFF charset instead
        cff = _find_table_opt(data, "CFF ")
        cff === nothing && return String[]
        return _parse_cff_glyph_names(data, cff[1])
    end
end

# ── OpenType coverage table ───────────────────────────────────────────────────

# Returns glyph IDs (0-based, in coverage-index order) from a coverage table.
function _read_coverage(data::Vector{UInt8}, p::Int)::Vector{Int}
    fmt = Int(_u16(data, p))
    if fmt == 1
        n = Int(_u16(data, p + 2))
        return [Int(_u16(data, p + 4 + 2 * (i - 1))) for i in 1:n]
    elseif fmt == 2
        n_ranges = Int(_u16(data, p + 2))
        glyphs = Int[]
        for i in 0:(n_ranges - 1)
            rp = p + 4 + 6 * i
            g_start = Int(_u16(data, rp))
            g_end = Int(_u16(data, rp + 2))
            append!(glyphs, g_start:g_end)
        end
        return glyphs
    else
        error("Unknown coverage format $fmt")
    end
end

# ── MathConstants ─────────────────────────────────────────────────────────────

function _parse_math_constants(data::Vector{UInt8}, p::Int)::MathConstants
    # Fields 1–4: plain int16 / uint16 (NOT MathValueRecord)
    script_percent = Int(_i16(data, p));     p += 2
    script_script_percent = Int(_i16(data, p));     p += 2
    delim_min_h = Int(_u16(data, p));     p += 2
    display_op_min_h = Int(_u16(data, p));     p += 2

    # Fields 5–55: MathValueRecord = int16 value + Offset16 device table.
    # We read only the signed value and skip the device-table offset (2 bytes).
    function mv()::Int
        v = Int(_i16(data, p)); p += 4
        return v
    end

    math_leading = mv()
    axis_height = mv()
    accent_base_height = mv()
    flattened_accent_base_height = mv()
    subscript_shift_down = mv()
    subscript_top_max = mv()
    subscript_baseline_drop_min = mv()
    superscript_shift_up = mv()
    superscript_shift_up_cramped = mv()
    superscript_bottom_min = mv()
    superscript_baseline_drop_max = mv()
    sub_superscript_gap_min = mv()
    superscript_bottom_max_with_subscript = mv()
    space_after_script = mv()
    upper_limit_gap_min = mv()
    upper_limit_baseline_rise_min = mv()
    lower_limit_gap_min = mv()
    lower_limit_baseline_drop_min = mv()
    stack_top_shift_up = mv()
    stack_top_display_style_shift_up = mv()
    stack_bottom_shift_down = mv()
    stack_bottom_display_style_shift_down = mv()
    stack_gap_min = mv()
    stack_display_style_gap_min = mv()
    stretch_stack_top_shift_up = mv()
    stretch_stack_bottom_shift_down = mv()
    stretch_stack_gap_above_min = mv()
    stretch_stack_gap_below_min = mv()
    fraction_numerator_shift_up = mv()
    fraction_numerator_display_style_shift_up = mv()
    fraction_denominator_shift_down = mv()
    fraction_denominator_display_style_shift_down = mv()
    fraction_numerator_gap_min = mv()
    fraction_num_display_style_gap_min = mv()
    fraction_rule_thickness = mv()
    fraction_denominator_gap_min = mv()
    fraction_denom_display_style_gap_min = mv()
    skewed_fraction_horizontal_gap = mv()
    skewed_fraction_vertical_gap = mv()
    overbar_vertical_gap = mv()
    overbar_rule_thickness = mv()
    overbar_extra_ascender = mv()
    underbar_vertical_gap = mv()
    underbar_rule_thickness = mv()
    underbar_extra_descender = mv()
    radical_vertical_gap = mv()
    radical_display_style_vertical_gap = mv()
    radical_rule_thickness = mv()
    radical_extra_ascender = mv()
    radical_kern_before_degree = mv()
    radical_kern_after_degree = mv()

    # Field 56: plain int16 (NOT MathValueRecord)
    radical_degree_bottom_raise_percent = Int(_i16(data, p))

    return MathConstants(
        script_percent, script_script_percent,
        delim_min_h, display_op_min_h,
        math_leading, axis_height, accent_base_height, flattened_accent_base_height,
        subscript_shift_down, subscript_top_max, subscript_baseline_drop_min,
        superscript_shift_up, superscript_shift_up_cramped, superscript_bottom_min,
        superscript_baseline_drop_max, sub_superscript_gap_min,
        superscript_bottom_max_with_subscript, space_after_script,
        upper_limit_gap_min, upper_limit_baseline_rise_min,
        lower_limit_gap_min, lower_limit_baseline_drop_min,
        stack_top_shift_up, stack_top_display_style_shift_up,
        stack_bottom_shift_down, stack_bottom_display_style_shift_down,
        stack_gap_min, stack_display_style_gap_min,
        stretch_stack_top_shift_up, stretch_stack_bottom_shift_down,
        stretch_stack_gap_above_min, stretch_stack_gap_below_min,
        fraction_numerator_shift_up, fraction_numerator_display_style_shift_up,
        fraction_denominator_shift_down, fraction_denominator_display_style_shift_down,
        fraction_numerator_gap_min, fraction_num_display_style_gap_min,
        fraction_rule_thickness, fraction_denominator_gap_min,
        fraction_denom_display_style_gap_min,
        skewed_fraction_horizontal_gap, skewed_fraction_vertical_gap,
        overbar_vertical_gap, overbar_rule_thickness, overbar_extra_ascender,
        underbar_vertical_gap, underbar_rule_thickness, underbar_extra_descender,
        radical_vertical_gap, radical_display_style_vertical_gap,
        radical_rule_thickness, radical_extra_ascender,
        radical_kern_before_degree, radical_kern_after_degree,
        radical_degree_bottom_raise_percent,
    )
end

# ── MathGlyphInfo ─────────────────────────────────────────────────────────────

# Parses italic corrections and top-accent attachments from a MathItalicsCorrection-
# or MathTopAccentAttachment-style sub-table (they share the same layout).
function _parse_math_value_coverage(
        data::Vector{UInt8}, subtable_start::Int,
        glyph_names::Vector{String}
    )::Dict{String, Int}
    cov_off = Int(_u16(data, subtable_start))
    count = Int(_u16(data, subtable_start + 2))
    glyphs = _read_coverage(data, subtable_start + cov_off)
    result = Dict{String, Int}()
    for i in 1:min(count, length(glyphs))
        gid = glyphs[i] + 1   # 0-based glyph ID → 1-based index into glyph_names
        gid <= length(glyph_names) || continue
        name = glyph_names[gid]
        isempty(name) && continue
        value = Int(_i16(data, subtable_start + 4 + 4 * (i - 1)))
        result[name] = value
    end
    return result
end

function _parse_math_glyph_info(
        data::Vector{UInt8}, info_start::Int,
        glyph_names::Vector{String}
    )
    italic_off = Int(_u16(data, info_start))
    accent_off = Int(_u16(data, info_start + 2))
    ext_off = Int(_u16(data, info_start + 4))

    italic_corrections = italic_off != 0 ?
        _parse_math_value_coverage(data, info_start + italic_off, glyph_names) :
        Dict{String, Int}()

    top_accent_attachments = accent_off != 0 ?
        _parse_math_value_coverage(data, info_start + accent_off, glyph_names) :
        Dict{String, Int}()

    extended_shapes = Set{String}()
    if ext_off != 0
        for gid in _read_coverage(data, info_start + ext_off)
            gid1 = gid + 1
            gid1 <= length(glyph_names) && !isempty(glyph_names[gid1]) &&
                push!(extended_shapes, glyph_names[gid1])
        end
    end

    return italic_corrections, top_accent_attachments, extended_shapes
end

# ── MathVariants ──────────────────────────────────────────────────────────────

function _parse_glyph_construction(
        data::Vector{UInt8}, con_start::Int,
        glyph_names::Vector{String}
    )::GlyphConstruction
    asm_off = Int(_u16(data, con_start))
    variant_count = Int(_u16(data, con_start + 2))

    variants = GlyphVariant[]
    for i in 0:(variant_count - 1)
        vp = con_start + 4 + 4 * i
        gid = Int(_u16(data, vp)) + 1
        adv = Int(_u16(data, vp + 2))
        gid <= length(glyph_names) || continue
        push!(variants, GlyphVariant(glyph_names[gid], adv))
    end

    assembly = nothing
    if asm_off != 0
        ap = con_start + asm_off
        ital_corr = Int(_i16(data, ap))      # MathValueRecord: int16 + skip 2
        part_count = Int(_u16(data, ap + 4))
        parts = GlyphAssemblyPart[]
        for i in 0:(part_count - 1)
            pp = ap + 6 + 10 * i
            gid = Int(_u16(data, pp)) + 1
            start_con = Int(_u16(data, pp + 2))
            end_con = Int(_u16(data, pp + 4))
            full_adv = Int(_u16(data, pp + 6))
            flags = Int(_u16(data, pp + 8))
            is_extender = (flags & 0x01) != 0
            gid <= length(glyph_names) || continue
            push!(
                parts, GlyphAssemblyPart(
                    glyph_names[gid], full_adv,
                    start_con, end_con, is_extender
                )
            )
        end
        assembly = GlyphAssembly(ital_corr, parts)
    end

    return GlyphConstruction(variants, assembly)
end

function _parse_math_variants(
        data::Vector{UInt8}, var_start::Int,
        glyph_names::Vector{String}
    )
    min_overlap = Int(_u16(data, var_start))
    vert_cov_off = Int(_u16(data, var_start + 2))
    horiz_cov_off = Int(_u16(data, var_start + 4))
    vert_count = Int(_u16(data, var_start + 6))
    horiz_count = Int(_u16(data, var_start + 8))

    function build_constructions(cov_off, count, con_offsets_start)
        result = Dict{String, GlyphConstruction}()
        cov_off == 0 && return result
        glyphs = _read_coverage(data, var_start + cov_off)
        for i in 1:count
            con_off = Int(_u16(data, con_offsets_start + 2 * (i - 1)))
            con = _parse_glyph_construction(data, var_start + con_off, glyph_names)
            i <= length(glyphs) || continue
            gid = glyphs[i] + 1
            gid <= length(glyph_names) || continue
            name = glyph_names[gid]
            isempty(name) || (result[name] = con)
        end
        return result
    end

    # Vert construction offsets start at byte 10 of MathVariants; horiz follow after
    vert_con_offsets_start = var_start + 10
    horiz_con_offsets_start = var_start + 10 + 2 * vert_count

    vert_constructions = build_constructions(
        vert_cov_off, vert_count,
        vert_con_offsets_start
    )
    horiz_constructions = build_constructions(
        horiz_cov_off, horiz_count,
        horiz_con_offsets_start
    )

    return min_overlap, vert_constructions, horiz_constructions
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    load_math_table(font_path) -> MathTable

Parse the MATH table from an OpenType font file.
"""
function load_math_table(font_path::AbstractString)::MathTable
    data = read(font_path)
    upm = _parse_upm(data)
    glyph_names = _parse_glyph_names(data)

    math_start, _ = _find_table(data, "MATH")
    # MATH header: uint16 major + uint16 minor + three Offset16 sub-table pointers
    mc_off = Int(_u16(data, math_start + 4))
    info_off = Int(_u16(data, math_start + 6))
    var_off = Int(_u16(data, math_start + 8))

    constants = _parse_math_constants(data, math_start + mc_off)

    italic_corrections, top_accent_attachments, extended_shapes =
        _parse_math_glyph_info(data, math_start + info_off, glyph_names)

    min_overlap, vert_constructions, horiz_constructions =
        _parse_math_variants(data, math_start + var_off, glyph_names)

    return MathTable(
        upm, constants, italic_corrections, top_accent_attachments,
        extended_shapes, min_overlap, vert_constructions, horiz_constructions
    )
end
