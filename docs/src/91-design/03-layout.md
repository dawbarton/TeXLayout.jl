# Math layout

Layout turns an AST into a flat list of positioned elements.  It is a recursive
walk: `_layout_node!` in `src/layout.jl` dispatches on `NodeKind` to a
`_layout_xxx!` helper, which appends `LayoutBox` values to one shared vector and
returns the node's horizontal advance.  The helpers live by topic in
`src/layout/scripts.jl`, `constructs.jl`, `extensible.jl`, and `matrix.jl`, and
the lookup tables they use in `src/tables/`.  The TeXbook rule behind each
construct, with the MATH constants it reads, is in
[`katex_rules.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/katex_rules.md).

## Output

```julia
abstract type TeXElement end

struct Glyph <: TeXElement        # found by name in a font slot
    glyph_name::String
    font_slot::FontSlot.T
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int
end

struct GlyphID <: TeXElement      # an exact glyph of an exact font file
    glyph_id::UInt32
    font_path::String
    font_slot::FontSlot.T
    represented_char::Char
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int
end

struct HRule <: TeXElement; width::Float64; thickness::Float64; end   # em
struct VRule <: TeXElement; height::Float64; thickness::Float64; end  # em
struct Space <: TeXElement; width::Float64; end                       # em

struct LayoutBox
    element::TeXElement
    x::Float64       # em, right of the formula origin
    y::Float64       # em, above the baseline
    scale::Float64   # size relative to the base font size
end
```

Glyph metrics are in the font's design units; `du * scale / upm` gives em.
`font_slot` names the font a `Glyph` comes from: `FontSlot.Math` for math glyphs,
or `Regular`, `Bold`, `Italic`, or `BoldItalic` for text, each falling back
through the family's other slots and finally the math font.  A renderer resolves
a `Glyph` through that whole chain (`GlyphRuntime`, see
[Renderer adapters](06-renderers.md)).  A `GlyphID` needs no resolution: it comes
from a shaper, and its glyph may be a ligature or substitution with no Unicode
scalar or name of its own.

`HRule.y` is the rule's bottom edge and `VRule.x` its left edge; the adapters
convert to the line centres their hosts expect.

### Coordinates

The origin is the formula's left end on its baseline; x runs right and y up, both
in em.  `scale` is 1 at the top level, about 0.7 in a script, and about 0.5 in a
second-level script; the exact values come from the font (`size_scale`).  To draw
at a font size of `fs` pixels, multiply x and y by `fs`.

## The layout context

Every recursive call receives the same immutable `_LayoutCtx`:

```julia
struct _LayoutCtx
    family::FontFamily
    mt::MathTable          # the math font's MATH table
    upm::Float64
    mode::LayoutMode.T     # Math, or Text inside \text{…}
    font_variant::Symbol   # :default, or the alphabet of an enclosing \mathbf, \mathbb, …
    text_shaper::TextShaper
end
```

`_LayoutCtx(family, shaper)` builds a math-mode context, and `_with(ctx; mode,
font_variant)` is the only copy helper.  `_with_variant` (for `FontSwitch`),
`_with_text_mode` (for `\text{…}`: upright glyphs, no math spacing, and no math
alphabet, as in LaTeX), and `_with_math_mode` (for `$…$` inside `\text{…}`) are
written with it.  The changed context flows into every nested call, so
`\mathbf{x_i}` sets both letters in bold.

## Range emission

A construct that must measure a child before placing it (scripts, fractions,
radicals, delimiters, accents, braces, matrices) lays the child out at a
temporary origin straight into the output vector, records the `(start, stop)`
range it emitted, measures that range (`_boxes_top`, `_boxes_bottom`), and then
moves it into place with `_translate_range!`.  A helper may only move ranges it
has just emitted.  Some constructs emit their children before their own rules or
delimiters, so append order is not paint order.

## Glyphs

Characters and symbols are found by codepoint (see the
[invariants](01-overview.md#Invariants)): `_char_glyph` for letters, digits, and
punctuation, after `_MATH_CHAR_REMAP` (hyphen to minus, `*` to `∗`); `_cmd_glyph` for commands,
through `_SYMBOL_CODEPOINTS`; `_upright_glyph` for operator names and text, from
the regular font when there is one; and `_variant_glyph` for math alphabets.
Large operators use `_DISPLAY_OP_CODEPOINTS` and take their display size from the
font's vertical variants (`display_operator_min_height`).

A math character is followed by its MATH-table italic correction, emitted as a
`Space` kern (`_push_math_char!`), as in TeX's `make_ord`; between letters of a
text alphabet (`\mathit`, `\mathrm`, …) `_drop_italic_kern!` removes it again.
In Script and ScriptScript styles, characters, symbols, and large operators
switch to the font's `ssty` alternates (`_script_glyph`), as unicode-math does.

## Atoms and spacing

`_atom_class` gives each node one of TeX's classes (`:ord`, `:op`, `:bin`, `:rel`,
`:open`, `:close`, `:punct`, `:inner`): characters from `_CHAR_ATOM_CLASS`,
commands from `_CMD_ATOM_CLASS` (both in `src/tables/layout_atoms.jl`), and other
kinds by rule.  A scripted node takes its base's class, a font switch its body's,
and an explicit `Space` is transparent.  Fractions, `\binom`, and undelimited
matrices are Ord, as `\frac` wraps its fraction in braces; `\left…\right`,
delimited matrices, and horizontal braces are Inner.

`_layout_children!` inserts the space between adjacent atoms from `_SPACINGS`
(Display and Text styles) or `_TIGHT_SPACINGS` (Script and ScriptScript), in
`src/tables/layout_spacing.jl`.  A `:bin` becomes `:ord` at the start of a list,
after `:bin`, `:op`, `:rel`, `:open`, or `:punct`, and before `:rel`, `:close`, or
`:punct` (TeX rules 5 and 6; `_BIN_LEFT_CANCEL` and `_BIN_RIGHT_CANCEL`).

## Styles and sizes (`src/style.jl`)

`TexStyle` is TeX's eight styles, numbered so that each cramped style is the even
number after its uncramped one, which makes the transitions tuple look-ups:

| Function | Gives | Used for |
|:---------|:------|:---------|
| `sup_style(s)` | `Script` or `ScriptScript`, cramped if `s` is | superscripts |
| `sub_style(s)` | `CrampedScript` or `CrampedScriptScript` | subscripts |
| `frac_num_style(s)` | one level down, cramped if `s` is | numerators |
| `frac_den_style(s)` | one level down, cramped | denominators |
| `cramp_style(s)` | the cramped form of `s` | radicands, accented bases |

The transitions follow Appendix G of the TeXbook, checked against KaTeX's
`Style.ts`.  `size_scale(s, mc)` is 1 in Display and Text and the font's
`script_percent_scale_down` and `script_script_percent_scale_down` in the script
styles; no scale is hard-coded.  A size switch (`\large`) multiplies the scale,
and `_scale_for_child` carries it through style changes:

```
child_scale = parent_scale × size_scale(child_style) / size_scale(parent_style)
```

## Constructs

**Scripts** (`src/layout/scripts.jl`).  `_layout_superscript!`,
`_layout_subscript!`, and `_layout_decorated!` follow TeX rule 18 with the
MATH constants `superscript_shift_up` (and its cramped form),
`superscript_bottom_min`, `superscript_baseline_drop_max`,
`subscript_shift_down`, `subscript_top_max`, `subscript_baseline_drop_min`,
`sub_superscript_gap_min`, and `superscript_bottom_max_with_subscript`.  A
subscript on a character or a large operator moves left by the base's italic
correction (`_subscript_italic_correction_em`); the superscript does not.  The
scripted atom is followed by `space_after_script`, and `hlayout_math` counts
that space at the end of inline math even though no box carries it.

**Limits.**  `_use_limits(base, style)` puts scripts above and below the base,
centred, for a large operator or an operator in `_LIMITS_OPERATORS` in Display
style, for any base under `\limits`, and for one under `\displaylimits` or
`\operatorname*` in Display style; `\nolimits` always puts them beside it.  The
gaps come from `upper_limit_gap_min`, `upper_limit_baseline_rise_min`,
`lower_limit_gap_min`, and `lower_limit_baseline_drop_min`.

**Fractions** (`_layout_frac!`, rule 15).  Numerator and denominator are set in
their styles, shifted from the axis by the `fraction_numerator_*` and
`fraction_denominator_*` constants (display forms in Display style) and pushed
apart to the minimum gaps, centred over the wider of the two, with a rule of
`fraction_rule_thickness` on the axis.  `\binom` (`_layout_genfrac!`) has no rule
and uses the `stack_*` constants, with delimiters of TeX's fixed `delim1` and
`delim2` sizes.

**Radicals** (`_layout_sqrt!`, `_layout_radical!`).  The radical sign is the
smallest vertical variant that covers the radicand plus `radical_vertical_gap`
(or its display form) and `radical_rule_thickness`, or an assembly when none is
tall enough; the rule sits on its top.  A degree is kerned by
`radical_kern_before_degree` and `radical_kern_after_degree` and raised by
`radical_degree_bottom_raise_percent` of the sign's height, measured from the
bottom of the sign, as LuaTeX does.

**Delimiters.**  `_layout_delimited!` sets the inner list, then `_layout_delim!`
picks for each side the smallest vertical variant that meets TeX's rule 19 size
(`_DELIMITER_FACTOR` and `_DELIMITER_SHORTFALL`), or an assembly, centred on the
axis.  `\middle` delimiters take the size of their pair.  A null delimiter
(`\left.`) is `_NULL_DELIMITER_SPACE` wide.  `\big` and its relatives
(`_layout_big_delim!`) take a fixed height from `_BIG_DELIM_HEIGHTS`.

**Extensible assemblies** (`src/layout/extensible.jl`).  `_layout_assembly!`
builds tall delimiters, wide accents, horizontal braces, and extensible arrows
from the font's assembly parts: the fewest extender repetitions that reach the
target, with the overlap at each joint shared evenly between
`min_connector_overlap` and the shorter connector (`_assembly_overlaps`).
Radicals have their own assembly (`_layout_radical_assembly!`).  Arrows that
the font has no construction for are built from pieces (`_XARROW_FILL_PIECES`).

**Accents** (rule 12).  The accent is placed over the base's top-accent
attachment point and raised by the base's height above `accent_base_height`
(TeX's δ), so it sits on an x-height base and rides higher over ascenders; the
base is set cramped, and scripts attach to the accented character.  Wide accents stretch
through the horizontal constructions.  `\overline` and `\underline` add a rule at
the `overbar_*` and `underbar_*` gaps.

**Font switches.**  Inside `\mathbf` and the other alphabets, `_variant_glyph`
maps each character with `_math_variant_codepoint` (`src/tables/math_alphabets.jl`)
to the Mathematical Alphanumeric Symbols block, or to the Letterlike Symbols that
Unicode encodes earlier (ℂ, ℌ, ℎ, …).  Math alphabets stay in the math font: the
text slots of a `FontFamily` are used by documents and `\text{…}`, not by
`\mathbf`.

## Matrices and alignments (`src/layout/matrix.jl`)

Matrix-like environments share one grid layout, spaced as LaTeX with amsmath
does it (`_MATRIX_SPACING` in `src/tables/layout_spacing.jl`): column separation
(`\arraycolsep` and its amsmath forms), `\arraystretch` struts in every row,
`\doublerulesep` for `||`, and for `smallmatrix` script-style entries with its own
baseline skip.  Widths, heights, and depths agree with LuaLaTeX to 0.001 pt in the
cases measured.  Delimited environments (`pmatrix`, `cases`, …) size their
delimiters against the whole box by rule 19.

`\\[len]` row spacing follows LaTeX: in an `array` a positive length deepens the
row to at least the strut depth plus the length; elsewhere it adds space.  Lengths
use TeX units at 10 pt = 1 em; register lengths such as `\jot` count as zero.

The display alignments `align`, `aligned`, `split`, `gather`, and `gathered` use
the same grid with amsmath's `aligned` and `gathered` spacing: a `\strut@` in
every row, `\openup\jot` between rows, and `\minalignsep` between column pairs.
A cell after `&` starts with an empty ordinary atom, so a leading `=` gets
relation spacing.  Their cells are set in Display style (`_DISPLAY_MATH_ENVS`);
`matrix`, `array`, and `cases` stay in Text style, and `smallmatrix` in script
style, as in TeX.  There is no display width, so `align` does not spread its
column pairs across the line, and nothing is numbered.  `equation` is a plain
display, the same as `\[…\]`.  A starred name is an alias of the unstarred one
(`_canonical_env_name`).

`multline` is not implemented: it has no alignment points and needs a
width-aware path.  See
[`future.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/future.md) for
this and the other gaps (`\hline`, `@{…}`, `\\*`, `[t]` and `[b]`, `\strut`, and
the phantoms).
