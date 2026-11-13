# Fonts and the MATH table

## Font families (`src/fonts.jl`)

```julia
struct FontFamily
    math::String                          # an OpenType font with a MATH table
    regular::Union{String, Nothing}       # the roman text faces
    italic::Union{String, Nothing}
    bold::Union{String, Nothing}
    bolditalic::Union{String, Nothing}
    sans::Union{TextFontSet, Nothing}     # optional \textsf faces
    monospace::Union{TextFontSet, Nothing} # optional \texttt faces
end
```

Only `math` is required.  `font_family(:new_cm)` and the other bundled names load
a family from its artifact (`_ARTIFACT_LOADERS`); `font_family(path; regular, …)`
builds one from files.  `_font_family_key` identifies a family by its paths, and
anything cached per family (`GlyphRuntime`, the MathTeXEngine adapter's family)
keys on it.

Missing faces fall back in a fixed order.  For glyphs found by name
(`_slot_fallback`): bold italic tries bold, italic, regular, and then the math
font; bold and italic try regular and then the math font; the math slot is the
math font alone.  For shaped text (`_text_font_fallback`), the requested family
(roman, sans, or monospace) is exhausted first, then the roman faces, and the
math font last.  `_font_path_for_slot` is the first path of a slot's chain; a
renderer that needs the glyph itself walks the whole chain (`_resolve_glyph`,
see [Renderer adapters](06-renderers.md)).

## Glyph metrics

```julia
struct GlyphMetrics
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int   # ink box; y up
end
```

Values are design units.  Advances and side bearings come from the font's binary
`hmtx` table, the designer's nominal values, rather than FreeType's scaled
metrics; ink boxes come from FreeType with `FT_LOAD_NO_SCALE`.

| Function | Looks up | Use |
|:---------|:---------|:----|
| `glyph_metrics_by_codepoint(family, cp)` | a codepoint in the math font's `cmap` | all symbols and letters; portable across fonts |
| `glyph_metrics_upright(family, ch)` | a character in the regular font, else the math font | operator names and text |
| `glyph_metrics(family, name)` | a PostScript name in the math font | names that come from the font itself: MATH-table variants and parts, `ssty` alternates, `glyph_name_by_codepoint` |
| `glyph_metrics_slot(family, ch, slot)` | a character through a slot's fallback chain; also returns the path | text glyphs |

Do not look letters or symbols up by name: names differ between fonts (AGL names
in New Computer Modern, Pagella, and STIX Two, `uniXXXX` in Fira Math, Luciole's
own scheme), and in New Computer Modern the glyph named `"x"` is the upright x,
while U+0078 in the `cmap` is the math italic.  `_construction_key` translates the
canonical names layout uses internally to a font's own names for the
construction tables.

## The MATH table (`src/math_table.jl`)

`load_math_table(path)` reads the font, finds the `MATH` table, parses it, and
caches the result:

```julia
struct MathTable
    upm::Int
    constants::MathConstants                             # the 56 MathConstants values
    italic_corrections::Dict{String, Int}                # glyph name → design units
    top_accent_attachments::Dict{String, Int}            # glyph name → x position
    extended_shapes::Set{String}
    min_connector_overlap::Int
    vert_constructions::Dict{String, GlyphConstruction}  # tall delimiters, radicals, operators
    horiz_constructions::Dict{String, GlyphConstruction} # wide accents, braces, arrows
    script_alternates::Dict{String, Tuple{String, String}} # GSUB ssty: (Script, ScriptScript)
end

struct GlyphConstruction
    variants::Vector{GlyphVariant}           # ready-made sizes, smallest first
    assembly::Union{GlyphAssembly, Nothing}  # parts for any larger size
end
```

`MathConstants` holds the table's constants as design-unit integers (the two
scale-down percentages are percentages), named as in the OpenType specification
in snake case: `axis_height`, `superscript_shift_up`, `fraction_rule_thickness`,
and so on.  `GlyphVariant` is a glyph name with its advance in the stretch
direction; a `GlyphAssembly` lists its parts (glyph, full advance, start and end
connector lengths, and whether it is an extender) and the assembly's italic
correction.

Everything is keyed by the font's own glyph names, which come from the CFF
charset (`_parse_cff_glyph_names`: charset formats 0, 1, and 2, with the 391
standard strings and the font's String INDEX) or from a format 2.0 `post` table
(`_parse_glyph_names`).

`script_alternates` comes from the GSUB `ssty` feature
(`_parse_script_alternates`): the first alternate is used in Script style and the
second, when the font has one, in ScriptScript.  Script letters, digits, primes,
and radical degrees are therefore slightly larger and wider than scaled base
glyphs, as the designers intended and as XeTeX and LuaTeX with unicode-math set
them.
