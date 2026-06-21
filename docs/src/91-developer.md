# Developer Documentation

This guide is aimed at contributors and advanced users who want to extend, embed, or
deeply understand TeXLayout.jl.  It covers the full pipeline architecture, every
intermediate data structure, the layout algorithms, and practical recipes for adding
new commands and font families.

---

## Architecture overview

TeXLayout processes a LaTeX string in three sequential, stateless stages:

```
String
  │
  ▼  tokenize
Vector{Token}
  │
  ▼  parse_latex
Node  (AST)
  │
  ▼  layout
Vector{LayoutBox}
```

Each stage is a **pure function** apart from internal memoization caches.  In
particular, `fonts.jl` caches loaded FreeType faces and horizontal metrics by path,
and `math_table.jl` caches parsed `MathTable` values by math-font path.  This keeps
the pipeline logically clean while avoiding repeated font I/O and MATH-table parsing
on hot paths such as repeated Makie rendering.  A parsed AST can still be reused
across multiple font choices or style levels without re-parsing, and each stage can
be tested and debugged in isolation.

Mixed text-and-math input is handled by a second layer built on top of this math
pipeline — see the **Document and text layer** section below for `parse_document`,
the shaping interface, and `layout_document`.

The public entry points are:

```julia
# Run the full pipeline in one call.
boxes = generate_tex_elements(raw"\frac{a}{b}", family)

# Run stages individually.
tokens = TeXLayout.tokenize(raw"\frac{a}{b}")   # tokenize is internal (not exported)
node   = parse_latex(tokens)          # or parse_latex(raw"\frac{a}{b}")
boxes  = layout(node, family, TeXLayout.Display)
```

---

## Stage 1: Lexer (`src/lexer.jl`)

The lexer converts a raw LaTeX string into a flat, position-tagged stream of tokens.
It performs no macro expansion and no semantic analysis; that is entirely the parser's
responsibility.

### Token kinds

`TokenKind` is an internal `EnumX.@enumx` namespace with the following values:

| Value | Description |
|:------|:------------|
| `TokenKind.Char` | Ordinary character: letter, digit, punctuation, or any other non-special Unicode scalar |
| `TokenKind.Command` | A backslash command: `\alpha`, `\\`, `\{`, `\,`, etc. |
| `TokenKind.Sup` | Superscript operator `^` |
| `TokenKind.Sub` | Subscript operator `_` |
| `TokenKind.LBrace` | Opening brace `{` |
| `TokenKind.RBrace` | Closing brace `}` |
| `TokenKind.MathShift` | Dollar sign `$` |
| `TokenKind.Ampersand` | Column separator `&` (used in array/matrix environments) |
| `TokenKind.Space` | A whitespace run or an explicit space character (`~`) |
| `TokenKind.EOF` | End-of-input sentinel, always present as the last token |

### Token struct

```julia
struct Token
    kind::TokenKind.T
    value::String   # raw source text of the token
    pos::Int        # 1-based byte offset in the source string
end
```

The `pos` field preserves the original source position for each token.  It is not
currently used by the parser for error messages, but is available for future tooling
(e.g. syntax highlighting or hover information in an editor extension).

### Lexer rules

The lexer scans the input string from left to right using UTF-8 codepoint iteration
(`nextind`/`prevind`):

- **Multi-letter commands** — when a `\` is followed by a letter (`isletter`), the
  lexer greedily consumes subsequent letters.  Example: `\alpha` → one `TokenKind.Command`
  token with value `"\\alpha"`.
- **Single non-letter commands** — when a `\` is followed by any non-letter character,
  exactly that one character is consumed.  Example: `\{` → `TokenKind.Command("\\{")`;
  `\\` → `TokenKind.Command("\\\\")`.
- **Bare backslash at end of input** — treated as `TokenKind.Char("\\")` rather than the start
  of a command.
- **Whitespace runs** — any sequence of characters satisfying `isspace` is emitted
  as a single `TokenKind.Space` token whose `value` preserves the raw run.  The math
  parser ignores `TokenKind.Space` tokens; the document parser collapses ordinary
  whitespace to one text space and treats blank lines as paragraph breaks.
- **Tilde** — `~` is immediately emitted as `TokenKind.Space("~")`.  In LaTeX, `~` is a
  non-breaking inter-word space; in math mode it is effectively ignored like any other
  space.
- **Other characters** — every other codepoint (including multi-byte UTF-8) is emitted
  as a single `TokenKind.Char` carrying the one-character string.

### TokenKind.EOF sentinel invariant

The lexer **always** appends a single `TokenKind.EOF` sentinel at byte position
`ncodeunits(input) + 1`, even for the empty string.  The parser is designed to never
advance past this sentinel: `_parse_primary!` returns a zero-advance `NodeKind.Space` node
when it sees `TokenKind.EOF` without consuming it, and every loop in the parser checks for
`TokenKind.EOF` before calling sub-parsers.  Violating this invariant would cause out-of-bounds
access into the token vector.

---

## Stage 2: Parser (`src/parser.jl`)

The parser converts the token stream into a typed abstract syntax tree (AST).  It is
a hand-written recursive-descent parser with one-token lookahead.

### Node struct

```julia
struct Node
    kind::NodeKind.T
    value::String           # source text for leaf nodes; command name for interior nodes
    children::Vector{Node}
    width::Float64          # em units; meaningful only for NodeKind.Space; 0.0 otherwise
end
```

`Node` is immutable.  Convenience constructors allow building nodes without specifying
all fields:

```julia
Node(kind, value)                 # leaf: no children, width = 0.0
Node(kind, children)              # interior: empty value, width = 0.0
Node(kind, value, children)       # interior with value: width = 0.0
space_node(w)                     # NodeKind.Space with given width in em
```

### Node kinds

`NodeKind` is an internal `EnumX.@enumx` namespace with the following values:

| Kind | Children | `value` | Notes |
|:-----|:---------|:--------|:------|
| `NodeKind.Char` | — | single character string | letter, digit, punctuation |
| `NodeKind.Sequence` | ordered sequence | — | implicit group; top-level wrapper; also used by style-switch body |
| `NodeKind.Group` | ordered sequence | — | explicit `{…}` braced group; also used for matrix cells |
| `NodeKind.Superscript` | `[base, sup]` | — | `^` when `_` is absent on the same base |
| `NodeKind.Subscript` | `[base, sub]` | — | `_` when `^` is absent on the same base |
| `NodeKind.Decorated` | `[base, sub, sup]` | — | both `_` and `^` on the same base, in that fixed child order |
| `NodeKind.Frac` | `[num, den]` | — | `\frac{num}{den}` |
| `NodeKind.Sqrt` | `[body]` or `[degree, body]` | — | `\sqrt{body}` or `\sqrt[degree]{body}` |
| `NodeKind.Delimited` | interior sequence | `"left_ps\x00right_ps"` | `\left…\right` pair; `\x00` separates PS glyph names |
| `NodeKind.Accent` | `[base]` | command string e.g. `"\\hat"` | non-stretchy accent commands |
| `NodeKind.OverUnder` | `[body]` | `"overline"` or `"underline"` | `\overline`/`\underline` |
| `NodeKind.Command` | — | full token including `\` | unrecognised command or atom-producing symbol |
| `NodeKind.Space` | — | `""` | explicit horizontal space; width carried in `.width` field (em) |
| `NodeKind.Text` | `[body NodeKind.Sequence]` | — | `\text{…}` / `\mbox{…}`; text-mode fragment |
| `NodeKind.Operator` | — | bare operator name e.g. `"sin"` | `\sin`, `\operatorname{…}` |
| `NodeKind.LimitsOverride` | `[base]` | `"limits"` or `"nolimits"` | `\limits` / `\nolimits` override |
| `NodeKind.FontSwitch` | `[body]` | variant name e.g. `"mathbf"` | `\mathbf{…}`, `\mathbb{…}`, … |
| `NodeKind.HorizBrace` | `[body]` | bare command name e.g. `"overbrace"` | `\overbrace`, `\underbrace`, … |
| `NodeKind.Matrix` | flat row-major list of `NodeKind.Group` cells | `"env\x00nrow\x00colspec"` | `\begin{env}…\end{env}` |
| `NodeKind.Middle` | — | PS glyph name | `\middle<delim>`; auto-sized inner delimiter |
| `NodeKind.StyleOverride` | `[body]` | style name e.g. `"Display"` | `\dfrac`, `\tfrac`, `\displaystyle`, … |
| `NodeKind.Sizing` | `[body NodeKind.Sequence]` | Float64 multiplier as string | `\large`, `\tiny`, … |
| `NodeKind.XArrow` | `[above]` or `[above, below]` | command string | `\xrightarrow`, `\xleftarrow`, … |

A few notes on specific kinds:

**`NodeKind.Decorated` child ordering** — children are always `[base, sub, sup]` regardless of
the order in which `_` and `^` appeared in the source.  The layout engine always reads
`children[1]` as the base, `children[2]` as the subscript, and `children[3]` as the
superscript.

**`NodeKind.Space` width encoding** — the `.width` field carries the em value directly (may be
negative for `\!`, `\negmedspace`, etc.).  Explicit kern commands such as `\kern 5pt`,
`\mkern 3mu`, and `\hskip 1em` are also parsed into `NodeKind.Space` nodes with the computed em
value.  1 mu = 1/18 em.

**`NodeKind.Delimited` value encoding** — the PostScript glyph names of the left and right
delimiters are joined by a `\x00` byte.  An empty substring means a null delimiter
(nothing rendered), corresponding to `\left.` or `\right.` in the source.

**`NodeKind.Matrix` value encoding** — the `value` field packs three fields separated by
`\x00`: the environment name (e.g. `"pmatrix"`), the row count as a decimal string, and
the column specification string.  For `\begin{array}{colspec}` the colspec is the
verbatim content of the mandatory argument; for shorthand environments (e.g. `pmatrix`,
`bmatrix`) it is a derived string of `'c'`/`'l'` characters.

### Parser structure

The parser is implemented as a small mutable struct holding the token vector and a
current-position index:

```julia
mutable struct _Parser
    tokens::Vector{Token}
    pos::Int
end
```

The helper `_current(p)` peeks at the current token without consuming it;
`_advance!(p)` moves to the next token.

The top-level entry point is:

```julia
node = parse_latex(input)   # accepts String or Vector{Token}
```

which returns a single `Node(NodeKind.Sequence, children)` wrapping the entire expression.

The key internal functions and their roles are:

- **`_parse_sequence_children!`** — called at the top level and after `{`; parses
  atoms until it sees `}` or `TokenKind.EOF`, returning a `Vector{Node}`.
- **`_parse_atom!`** — parses one primary expression, then optionally attaches `_` and
  `^` tokens to produce `NodeKind.Subscript`, `NodeKind.Superscript`, or `NodeKind.Decorated`.  Also handles
  `\limits`/`\nolimits` by wrapping the preceding base in a `NodeKind.LimitsOverride` node.
- **`_parse_primary!`** — dispatches on the current token kind:
  - `TokenKind.Char` → `NodeKind.Char`
  - `TokenKind.Command` → `_parse_command!`
  - `TokenKind.LBrace` → consumes `{`, calls `_parse_sequence_children!`, expects `}`
  - `TokenKind.Sup`, `TokenKind.Sub`, `TokenKind.MathShift`, `TokenKind.Ampersand` → `NodeKind.Char` (treated literally when
    not consumed by `_parse_atom!` in the scripting role)
  - `TokenKind.EOF` → returns `NodeKind.Space` with zero width without advancing
- **`_parse_command!`** — a large dispatch table for all recognised commands, including
  `\frac`, `\sqrt`, `\left`/`\right`, `\begin`/`\end`, all math operators, all font
  switches, all spacing commands, all sizing commands, and all extensible-arrow commands.
  Unknown commands fall through to a `NodeKind.Command` leaf.
- **`_parse_argument!`** — reads one argument: if the next token is `{`, reads a braced
  group; otherwise reads a single primary.
- **`_parse_kern_dimension!`** — reads a dimension after `\kern`, `\mkern`, `\hskip`,
  or `\mskip`.  Handles numeric literals with optional decimal point, followed by a unit
  keyword (`pt`, `em`, `ex`, `mu`, `cm`, `mm`, `sp`, `bp`, `dd`, `pc`); converts to em.

### Parser resilience

The parser **never throws** on ill-formed input.  Examples of how degraded input is
handled:

| Ill-formed input | Behaviour |
|:----------------|:----------|
| `x^2^3` | The second `^` is treated as a fresh atom (the superscript is already attached); produces `(x^2)^3` effectively |
| `x_i_j` | Same: second `_` is a fresh atom |
| `{unclosed` | Parsed to `TokenKind.EOF`; treated as if `}` were present |
| `\left( x` (missing `\right`) | `\left` consumes to `TokenKind.EOF` |
| `\frac{a}` (missing second arg) | Second argument parsed as the empty group `{}` |
| `\unknown` | Produces `NodeKind.Command("\\unknown")`; layout engine emits no glyph |

This design means the layout engine always receives a structurally valid tree, even for
partially typed or otherwise broken expressions.

---

## Stage 3: Layout engine (`src/layout.jl`, `src/layout/*.jl`)

The layout engine converts the AST into a flat list of positioned renderable elements.
It is a recursive tree walk: `_layout_node!` in `src/layout.jl` performs the core
dispatch and appends `LayoutBox` values into a shared accumulator vector.  Feature
helpers that need child extents record the sub-range they just emitted, scan that
range, and translate it in place with `_translate_range!`; append order is therefore
an implementation detail rather than a rendering contract.  Feature helpers that used
to live in the same file are split into `src/layout/extensible.jl`,
`src/layout/scripts.jl`, `src/layout/constructs.jl`, and `src/layout/matrix.jl`.

### Font and MATH-table caching

Layout depends on font-derived data that is expensive to reconstruct repeatedly, so
TeXLayout memoizes it:

- **Font cache (`src/fonts.jl`)** — `_load_font(path)` reuses loaded FreeType faces and
  parsed `hmtx` data keyed by font path.
- **MATH table cache (`src/math_table.jl`)** — `load_math_table(path)` caches the parsed
  `MathTable` object keyed by the math-font path.  Repeated layout calls with the same
  font therefore reuse the already-parsed OpenType MATH table instead of reparsing the
  binary table on every call.

This cache layer matters in practice because AST parsing is usually cheap, while
font loading and MATH-table decoding can dominate steady-state rendering workloads if
they are not memoized.

### Layout context

All recursive calls share an immutable `_LayoutCtx` value:

```julia
struct _LayoutCtx
    family::FontFamily
    mc::MathConstants
    upm::Float64
    vert_constructions::Dict{String, GlyphConstruction}
    horiz_constructions::Dict{String, GlyphConstruction}
    top_accent_attachments::Dict{String, Int}
    italic_corrections::Dict{String, Int}
    min_connector_overlap::Int
    mode::LayoutMode.T    # LayoutMode.Math | LayoutMode.Text
    font_variant::Symbol  # :default | :mathbf | :mathit | :mathrm | :mathbb | …
end
```

Because `_LayoutCtx` is a plain struct (not a `mutable struct`), child contexts are
created cheaply by constructing a new value with one field changed.  Two helpers do
this:

- **`_with_variant(ctx, variant)`** — returns a copy with `font_variant` set; used by
  `_layout_font_switch!` so that the entire subtree of a `\mathbf{…}` node is rendered
  in the bold variant.
- **`_with_text_mode(ctx)`** — returns a copy with `mode = LayoutMode.Text`; used by
  `_layout_text!` so that `\text{…}` content uses upright glyph lookup and suppresses
  math-mode inter-atom spacing and italic remapping.

The `mode` and `font_variant` fields propagate through every recursive call: once a
`\mathbf{…}` or `\text{…}` scope is entered, the changed context is passed to all
nested `_layout_node!` calls.

### Output types

```julia
abstract type TeXElement end

struct Glyph <: TeXElement
    glyph_name::String
    font_slot::FontSlot.T
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int
end

struct HRule <: TeXElement
    width::Float64      # em units
    thickness::Float64  # em units
end

struct VRule <: TeXElement
    height::Float64     # em units
    thickness::Float64  # em units
end

struct Space <: TeXElement
    width::Float64      # em units
end

struct LayoutBox
    element::TeXElement
    x::Float64
    y::Float64
    scale::Float64
end
```

The `Glyph` metric fields (`advance_width`, `left_side_bearing`, and the bounding-box
fields) are in **design units** — the raw integer values from the font's hmtx and glyph
tables, with no scaling applied.  To convert to em units, use `du * scale / upm`.  The
`x`, `y` positions in `LayoutBox` are already in em units (origin at the formula
baseline; x right, y up).

`font_slot` tells the renderer which physical font file to open for glyph-index
resolution:
- `FontSlot.Math` → `family.math` (used for math-mode glyphs).
- `FontSlot.Regular`, `FontSlot.Bold`, `FontSlot.Italic`, and
  `FontSlot.BoldItalic` → the corresponding text companion font, falling back
  through regular/math when a companion slot is absent.

Renderer/debug code should use internal helper `_font_path_for_slot(family, slot)`
when resolving a `Glyph.font_slot` to a physical font path, so fallback behaviour
stays consistent across tools.

### Range emission and measurement

Math layout is flat and range-based.  Constructs such as scripts, fractions,
radicals, delimiters, accents, horizontal braces, and matrices lay out children at a
temporary origin directly into the final `Vector{LayoutBox}`.  They record the emitted
`(start, stop)` range, measure ink extents with `_boxes_top`, `_boxes_bottom`, or
`_boxes_vextent`, then apply the final placement by rewriting that same range through
`_translate_range!`.

This removes the older pattern of allocating temporary `LayoutBox[]` buffers,
measuring them, and copying shifted boxes into the output.  The important invariant is
that helpers may only translate ranges they just emitted; they should not mutate boxes
from earlier siblings or callers.  Because some constructs now emit children before
rules or delimiters for simpler measurement, consumers and tests must not rely on
append order as paint order.  Compare geometry and element identity instead.

### Coordinate system

- **Origin**: the formula baseline, at `(x, y) = (0, 0)`.
- **x** increases to the right, in em units.
- **y** increases upward, in em units.
- **scale**: dimensionless multiplier relative to the caller's base font size.
  At the top level it is `1.0`; inside a subscript it is approximately `0.7`; inside a
  double-nested script it is approximately `0.5`.  The exact values come from the font's
  MATH table (see [`src/style.jl`](#style-cascade-srcstyle.jl)).

To convert em coordinates to screen/output pixels, multiply by the desired font size:

```julia
fontsize_px = 32.0
for box in boxes
    x_px = box.x * fontsize_px
    y_px = box.y * fontsize_px
    # … render box.element at (x_px, baseline_y_px - y_px)
end
```

### Glyph resolution

Three lookup functions in `src/fonts.jl` cover all glyph access patterns:

| Function | When to use |
|:---------|:------------|
| `glyph_metrics(family, ps_name)` | You have a PostScript glyph name (e.g. `"parenleft"`, `"alpha"`); used in delimiter and construction key lookup |
| `glyph_metrics_by_codepoint(family, cp)` | **Preferred for symbols**: portable across all fonts; used for all entries in `_SYMBOL_CODEPOINTS`, large operators, and math-variant glyphs |
| `glyph_metrics_upright(family, ch)` | Upright (roman) form of a character; uses `regular` font when present, else the math font's cmap; used for `NodeKind.Operator` and `\text{…}` content |

**Why codepoints are preferred over PS names**: PostScript glyph naming conventions
diverge across fonts.  NewCMMath and Pagella use standard AGL names (`"alpha"`,
`"ltimes"`), while FiraMath uses `uni`-style names (`"uni03B1"`, `"uni22C9"`), and
Luciole uses its own convention.  Resolving by Unicode codepoint via the font's `cmap`
table is the only approach that is portable across all bundled font families.

Note also that in NewCMMath, calling `glyph_metrics(family, "x")` returns the *upright
roman* form (the slot named `"x"` in that font), whereas `glyph_metrics_by_codepoint`
at U+0078 correctly returns the *math-italic* form.  Using codepoints is therefore also
more semantically correct for math-mode letters.

The only place where PS names are unavoidable is `_construction_key`, which translates
canonical AGL names (used as keys in the layout engine's internal tables) to the font's
own MATH-table PS names when looking up `vert_constructions`/`horiz_constructions`.

### Inter-atom spacing

TeX defines seven atom classes for math-mode elements: `:ord` (ordinary), `:bin`
(binary operator), `:rel` (relation), `:op` (large operator), `:open` (opening
delimiter), `:close` (closing delimiter), `:punct` (punctuation), and `:inner`.

The atom class of each `Node` is determined by `_atom_class`, which checks:
1. `_CHAR_ATOM_CLASS` in `src/tables/layout_atoms.jl` for `NodeKind.Char` nodes (single-character lookup).
2. `_CMD_ATOM_CLASS` in `src/tables/layout_atoms.jl` for `NodeKind.Command` and `NodeKind.Operator` nodes (command-name lookup).
3. Structural rules for other node kinds (e.g. `NodeKind.Frac` → `:inner`).

`_layout_children!` accumulates inter-atom gaps using two spacing tables:

- `_SPACINGS` in `src/tables/layout_spacing.jl` — used in `Display` and `Text` styles; includes thin (3/18 em), medium
  (4/18 em), and thick (5/18 em) gaps for all class pairs that require spacing.
- `_TIGHT_SPACINGS` in `src/tables/layout_spacing.jl` — used in `Script` and `ScriptScript` styles; only thin spaces
  survive (only a few `:op`-adjacent pairs).

**Binary operator reclassification** (matching TeX Rule 14): a node with class `:bin`
is demoted to `:ord` when it appears:
- at the start of a sequence,
- at the end of a sequence,
- immediately after a `:bin` or `:rel` atom, or
- immediately before a `:rel` atom.

This is implemented via the `_BIN_LEFT_CANCEL` and `_BIN_RIGHT_CANCEL` sets checked
in `_layout_children!`.

### Script placement

Sub/superscript placement is the most detail-heavy part of the engine.  Three functions
handle the three cases:

- **`_layout_superscript!`** — base with `^` only (`NodeKind.Superscript`).
- **`_layout_subscript!`** — base with `_` only (`NodeKind.Subscript`).
- **`_layout_decorated!`** — base with both `_` and `^` (`NodeKind.Decorated`).

All three use the following MATH table constants (all in design units):

| Constant | Role |
|:---------|:-----|
| `subscript_shift_down` | Nominal downward shift of the subscript baseline |
| `subscript_top_max` | Subscript top must not exceed this height above the formula baseline |
| `subscript_baseline_drop_min` | Minimum drop of subscript baseline below the base top |
| `superscript_shift_up` | Nominal upward shift of the superscript baseline (uncramped) |
| `superscript_shift_up_cramped` | Same, in cramped styles (reduced to avoid protruding above accent) |
| `superscript_bottom_min` | Superscript bottom must not fall below this height above the baseline |
| `superscript_baseline_drop_max` | Maximum drop of superscript baseline below the base top |
| `sub_superscript_gap_min` | Minimum gap between superscript bottom and subscript top |
| `superscript_bottom_max_with_subscript` | When both are present: superscript bottom clipped to this value |

**Italic correction** — for slanted single-glyph bases (e.g. `\int`), the subscript
is shifted left by the glyph's italic correction value from the MATH table.  The helper
`_base_italic_correction_em(boxes, ctx, scale)` returns the italic correction of the
first `Glyph` in a box list, converted to em units.  This matches KaTeX's `supsub.ts`
behaviour exactly: the full IC shift is applied to the subscript, and no IC shift is
applied to the superscript (which is already displaced by the base's advance).

### Fraction layout

`_layout_frac!` implements TeX Rules 15d/15e:

1. Lay out numerator (in `frac_num_style`) and denominator (in `frac_den_style`)
   independently.
2. Determine the fraction rule position: the math axis height (`axis_height / upm` em).
3. Raise the numerator baseline by `fraction_numerator_shift_up` (or
   `fraction_numerator_display_style_shift_up` in Display style), clamped so that the
   gap between the numerator bottom and the rule top is at least
   `fraction_numerator_gap_min` (or `fraction_num_display_style_gap_min`).
4. Lower the denominator baseline by `fraction_denominator_shift_down` (or
   `fraction_denominator_display_style_shift_down`), clamped so that the gap between
   the rule bottom and the denominator top is at least `fraction_denominator_gap_min`
   (or `fraction_denom_display_style_gap_min`).
5. Emit the fraction rule as an `HRule` centred on the math axis, with thickness
   `fraction_rule_thickness / upm` em.
6. Translate numerator and denominator ranges so they are horizontally centred over
   the widest of the numerator, rule, and denominator, then emit the fraction rule.

### Radical layout

`_layout_radical!` and `_layout_radical_assembly!` implement `\sqrt` and `\sqrt[n]`:

1. Compute the required internal height: body height + `radical_vertical_gap` (or
   `radical_display_style_vertical_gap` in Display style) + `radical_rule_thickness`.
2. Scan the pre-built glyph variants in `vert_constructions` (ascending order); pick
   the smallest that meets the required height.
3. If no variant is tall enough, call `_layout_radical_assembly!` to build an
   extensible assembly (glyphs stacked with controlled overlap).
4. The radical glyph is **top-anchored**: its top is aligned with the top of the
   body plus the required gap, adding `radical_extra_ascender` above the rule for
   visual clearance.
5. The horizontal rule over the body is emitted as an `HRule` at the top of the body.
6. For `\sqrt[n]` (degree variant), the degree box is placed at
   `radical_kern_before_degree` spacing to the left of the radical glyph, and raised
   so that its bottom sits at `radical_degree_bottom_raise_percent` percent of the
   radical height above the baseline; `radical_kern_after_degree` is then added before
   the body.

### Delimiter layout

`_layout_delim!` selects a delimiter glyph for one side of a `\left`/`\right` pair:

1. Compute the required height (total height of the inner content, centred on the math
   axis).
2. Scan pre-built glyph variants in `vert_constructions`; take the smallest that covers
   the required height.
3. If none is tall enough and the construction has an assembly, call `_layout_assembly!`
   to build an extensible glyph.
4. The chosen glyph is centred vertically on the math axis.

`_layout_delimited!` (for `NodeKind.Delimited`) lays out the inner content first, computes the
bounding height, then calls `_layout_delim!` for the left and right glyphs.

`NodeKind.Middle` is handled inside `_layout_delimited!` by passing the parent's
`delim_height` down through the recursion so that `\middle` delimiters match the
enclosing `\left`/`\right` pair's height.  Multiple `\middle` delimiters per group are
supported.

### Extensible glyph assembly

`_layout_assembly!` implements the generalised OpenType assembly algorithm, used for
both vertical (tall delimiters, radicals) and horizontal (wide accents, horizontal
braces, extensible arrows) constructions:

1. Compute the target extent (height for vertical; width for horizontal).
2. Determine the minimum number of extender repetitions `n` using `_min_extender_reps`,
   which finds the smallest `n` such that the assembled glyph meets the target with
   maximum overlap.
3. Distribute overlap evenly among adjacent part boundaries, clamped so that each
   overlap is between `min_connector_overlap` (from the MATH table) and the minimum of
   the two adjacent connector lengths.
4. Lay out parts bottom-to-top (vertical) or left-to-right (horizontal), emitting one
   `Glyph` box per part occurrence (extenders are repeated `n` times each).

### Limits placement

`_use_limits(base, style)` returns `true` when limits placement (sub/sup centred
above/below the operator) should be used instead of the default beside-base placement.
The three cases are:

1. The base is a large operator (`NodeKind.Command` with a key in `_DISPLAY_OP_CODEPOINTS`
   from `src/tables/layout_symbols.jl` or in `_LIMITS_OP_COMMANDS`) and the current style is Display.
2. The base is a named operator (`NodeKind.Operator`) whose name is in `_LIMITS_OPERATORS`
   (`lim`, `limsup`, `liminf`, `sup`, `inf`, `max`, `min`, `det`, `gcd`, `Pr`) and the
   current style is Display.
3. A `NodeKind.LimitsOverride("limits")` node wraps the base (explicit `\limits`), regardless
   of style.

A `NodeKind.LimitsOverride("nolimits")` node forces beside-base placement regardless of style
and operator type.

In limits mode, the above-script and below-script are each horizontally centred over the
base, using these four MATH constants:

| Constant | Role |
|:---------|:-----|
| `upper_limit_gap_min` | Minimum gap between base top and above-script bottom |
| `upper_limit_baseline_rise_min` | Minimum rise of above-script baseline above base top |
| `lower_limit_gap_min` | Minimum gap between below-script top and base bottom |
| `lower_limit_baseline_drop_min` | Minimum drop of below-script baseline below base bottom |

### Font switching and math variants

`NodeKind.FontSwitch` is emitted by commands such as `\mathbf`, `\mathit`, `\mathrm`,
`\mathbb`, `\mathcal`, `\mathfrak`, `\mathsf`, `\mathtt`, and `\boldsymbol`.
`_layout_font_switch!` calls `_with_variant(ctx, variant)` and recursively lays out the
body subtree with the new context.

When `ctx.font_variant` is not `:default`, `_variant_glyph(ctx, variant, ch)` maps
the character `ch` to its Unicode math-variant codepoint via
`_math_variant_codepoint(variant, ch)` (defined in `src/fonts.jl`).  This function
handles:

- The main Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF): Latin and Greek
  letters across bold, italic, bold-italic, script, bold-script, Fraktur, bold-Fraktur,
  double-struck, sans-serif, sans-serif bold, sans-serif italic, sans-serif bold-italic,
  and monospace.
- BMP exception codepoints for specific characters (e.g. ℂ U+2102 for `\mathbb{C}`,
  ℌ U+210C for `\mathfrak{H}`, ∂ U+2202 for bold `\partial`).

Math-mode font switching operates within the Unicode math block.  The `bold`,
`italic`, and `bolditalic` `FontFamily` slots are used by the document text layer
for `\textbf`, `\textit`, and nested bold-italic text, but not yet by math-mode
font switching.

---

## Document and text layer (`src/document.jl`, `src/shaping.jl`, `src/boxes.jl`, `src/compose.jl`)

The math pipeline above lays out a single formula.  A second layer, sitting on top
of it, handles mixed text-and-math input and multi-line composition.  Its public
entry point is `layout_document`, which returns a `TeXBox`:

```julia
struct TeXBox
    boxes::Vector{LayoutBox}   # flat, positioned across all lines
    width::Float64             # em
    ascent::Float64            # em above the first baseline
    descent::Float64           # em below the last baseline
end
```

### Document AST (`src/document.jl`)

`parse_document(input)` parses a mixed string into a `Document` (`Vector{Block}`),
where text is the default mode and math is entered with `$…$` or a top-level display
environment:

| Type | Role |
|:-----|:-----|
| `TextAttrs` | Resolved text styling for a span: `font_slot::FontSlot.T` and `size` |
| `TextSpan` | A maximal run of characters sharing one `TextAttrs` |
| `Run` (`TextRun` / `MathRun`) | A horizontal run within a line: shaped text, or a math `Node` with its `TexStyle` |
| `Line` | A sequence of `Run`s separated by `\\` |
| `Block` (`ParagraphBlock` / `DisplayBlock` / `ParagraphBreakBlock`) | A paragraph of lines, a free-standing display-math block, or a blank-line break |

Text font-switch commands (`\textbf`, `\textit`, `\emph`, `\textrm`, `\textnormal`,
`\textsf`, `\texttt`) update the current `TextAttrs`; `\emph` toggles italic relative
to the surrounding state.  `\text` / `\mbox` open a grouping scope that inherits the
current attributes.  The display environments `align`, `aligned`, `gather`, and
`equation` (in `_DISPLAY_ENVS`) become `DisplayBlock`s when they appear at the top
level without `$…$`.

Currently `\textbf`, `\textit`, and nested bold-italic text select the corresponding
`FontFamily` text slots.  `\textsf` and `\texttt` are parsed as text-style scopes but
fall back to the regular text slot until dedicated sans-serif and monospace slots are
added.

### Shaping (`src/shaping.jl`)

`TextShaper` is the abstract interface for turning a `TextSpan` into positioned
glyphs; `shape_span(shaper, span, family, scale)` is the entry point.  The default
`MetricShaper` does metric-only shaping (one glyph per character, advances from the
font's `hmtx` table) with no contextual substitution or kerning.  This is the seam a
future `HarfBuzzShaper` (in an `ext/HarfBuzzExt.jl` extension) would plug into.

### Internal box tree (`src/boxes.jl`)

Composition uses a small measured box tree — `ShapedBox` (a leaf wrapping laid-out
`LayoutBox`es with extents), `HBox` (horizontal), and `VBox` (vertical) — all
subtypes of the internal `Box`.  `shape(box)` flattens the tree into the final
`Vector{LayoutBox}`.  This keeps measurement (width/ascent/descent) separate from
the flat output the renderer consumes.

### Composition (`src/compose.jl`)

`compose.jl` ties the layers together:

- `hlayout_math` / `hlayout_run` lay out a math node or a text/math run into a `TeXBox`.
- `hconcat` joins runs horizontally on a shared baseline; `vstack` / `_vstack_with_skips`
  stack lines and display blocks with `line_height`, `lineskip`, and display skips.
- `LayoutOptions` collects the keyword-configurable parameters (`align`, `width`,
  `line_height`, `lineskip`, `display_align`, `abovedisplayskip`, `belowdisplayskip`,
  `parskip`, `shaper`); `layout_document` builds it from keyword arguments, walks the
  `Document`, and returns the composed `TeXBox`.

---

## Font system (`src/fonts.jl`)

### `FontFamily`

```julia
struct FontFamily
    math::String
    regular::Union{String, Nothing}
    italic::Union{String, Nothing}
    bold::Union{String, Nothing}
    bolditalic::Union{String, Nothing}
end
```

Only `math` is mandatory.  The remaining slots may be `nothing`; when absent, any
operation that would use them falls back to the math font.

```julia
# From a registered artifact symbol.
family = font_family(:new_cm)

# From a file path with optional companion fonts.
family = font_family("/path/to/MyMath.otf";
                     regular    = "/path/to/MyText-Regular.otf",
                     bold       = "/path/to/MyText-Bold.otf",
                     italic     = "/path/to/MyText-Italic.otf",
                     bolditalic = "/path/to/MyText-BoldItalic.otf")
```

### `GlyphMetrics`

```julia
struct GlyphMetrics
    advance_width::Int
    left_side_bearing::Int
    x_min::Int
    y_min::Int
    x_max::Int
    y_max::Int
end
```

All values are in design units (divide by `upm` to get em values).  The bounding box
follows the OpenType convention: `y_max` is the ascent (positive = above baseline),
`y_min` is the descent (negative = below baseline).

### Font cache

`_FONT_CACHE` is a process-global `Dict{String, Tuple{FTFont, Vector{Tuple{Int,Int}}}}`.
It maps each font file path to a pair of (FreeType face handle, parsed hmtx table).
Calling `_load_font(path)` is idempotent and cheap after the first call.

Advance widths and left side bearings are read **from the raw binary hmtx table**, not
from FreeType's scaled metrics, to match the font designer's nominal design-unit values
exactly.  Ink bounding boxes are obtained via `FT_Load_Glyph` with `FT_LOAD_NO_SCALE`.

---

## OpenType MATH table (`src/math_table.jl`)

### Parsed structures

`load_math_table(font_path)` reads the font, locates the `MATH` table, parses all
sub-tables, and returns a `MathTable`:

```julia
struct MathTable
    upm::Int
    constants::MathConstants
    italic_corrections::Dict{String, Int}
    top_accent_attachments::Dict{String, Int}
    extended_shapes::Set{String}
    min_connector_overlap::Int
    vert_constructions::Dict{String, GlyphConstruction}
    horiz_constructions::Dict{String, GlyphConstruction}
end
```

`MathConstants` contains all 58 integer constants from the OpenType MATH table
`MathConstants` sub-table, covering script scaling percentages, axis height, accent
base height, sub/superscript shift parameters, fraction and radical parameters, and
over/underbar gap constants.  All values are in design units; divide by `upm` for em
values.

The stretchable-glyph structures form a small hierarchy:

```julia
struct GlyphVariant
    glyph_name::String
    advance::Int           # advance in the extension direction (design units)
end

struct GlyphAssemblyPart
    glyph_name::String
    full_advance::Int
    start_connector::Int
    end_connector::Int
    is_extender::Bool
end

struct GlyphAssembly
    italic_correction::Int
    parts::Vector{GlyphAssemblyPart}
end

struct GlyphConstruction
    variants::Vector{GlyphVariant}           # pre-built size variants
    assembly::Union{GlyphAssembly, Nothing}  # extensible assembly
end
```

Both `vert_constructions` and `horiz_constructions` are `Dict{String, GlyphConstruction}`
keyed by the font's own PostScript glyph names.

### PS glyph name resolution

Both outline formats supported by mainstream math fonts are handled:

- **CFF / Type 2** — `_parse_cff_glyph_names` parses the CFF `charset` field from the
  CFF Top DICT.  Both SID-based charsets and charset format 0/1/2 are supported.  SIDs
  in the range 0–390 are resolved from the 391-entry CFF standard string table
  (`_CFF_STD_STRINGS`); higher SIDs are resolved from the font's own String INDEX.
- **TrueType** — `_parse_glyph_names` reads the `post` table.  Only format 2.0 is
  implemented (the common case): it maps each GID to a Mac name index or an offset into
  the string pool.

---

## Style cascade (`src/style.jl`)

### `TexStyle` enum

```julia
@enum TexStyle::Int8 begin
    Display = 1
    CrampedDisplay = 2
    Text = 3
    CrampedText = 4
    Script = 5
    CrampedScript = 6
    ScriptScript = 7
    CrampedScriptScript = 8
end
```

The integer values 1–8 are chosen deliberately: cramped styles are even, uncramped
styles are odd, and each cramped/uncramped pair occupies two consecutive values.  This
allows the transition functions to be implemented as static tuples indexed by
`Int8(s)`, giving O(1) lookups.

### Style transitions

| Function | Produces | Used by |
|:---------|:---------|:--------|
| `sup_style(s)` | `Script` or `CrampedScript` | Superscript of the current atom |
| `sub_style(s)` | `CrampedScript` or `CrampedScriptScript` | Subscript of the current atom |
| `frac_num_style(s)` | `Text` / `Script` / `ScriptScript` (uncramped) | Fraction numerator |
| `frac_den_style(s)` | `CrampedText` / `CrampedScript` / `CrampedScriptScript` | Fraction denominator |
| `cramp_style(s)` | The cramped variant of `s` | Base of an accented expression |

These transitions follow TeXbook Appendix G Rules 14–17, cross-checked against KaTeX's
`Style.ts`.

**Scale factors** are computed by `size_scale(s, mc)` using values from the font's MATH
table:

- `Display` and `Text` → `1.0`
- `Script` and `CrampedScript` → `mc.script_percent_scale_down / 100.0` (typically ≈ 0.70)
- `ScriptScript` and `CrampedScriptScript` → `mc.script_script_percent_scale_down / 100.0`
  (typically ≈ 0.50)

No hard-coded scale values are used anywhere in the engine.

When a `\large`, `\tiny`, or other `NodeKind.Sizing` node is in effect, the scale is
multiplied by the sizing factor at each child call via `_scale_for_child`:

```
child_scale = parent_scale × (size_scale(child_style) / size_scale(parent_style))
```

This formula correctly propagates an inherited sizing factor through style transitions
(e.g. a `\large` subscript inside a `\sum` renders at the script scale multiplied by
the `\large` factor).

---

## Makie extension (`ext/MathTeXEngineExt.jl`)

### Activation

The extension is loaded automatically by Julia's package extension mechanism when all
of `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings` are present in the current
session.  No user action is required beyond loading those packages.

### Dispatch strategy

The extension adds a method:

```julia
MathTeXEngine.generate_tex_elements(str::LaTeXString, ...) -> ...
```

MathTeXEngine's existing method accepts `::AbstractString`, which is less specific than
`::LaTeXString`.  Makie always passes a `LaTeXString` to `generate_tex_elements`, so
Julia's standard method dispatch selects the TeXLayout method automatically.

### Conversion pipeline

The extension converts TeXLayout output to MathTeXEngine's expected tuple format:

1. Inspect the `LaTeXString`.
   - A string that starts and ends with a single `$` and contains no other `$` is
     treated as one inline-math formula.  The extension strips the delimiters, calls
     `TeXLayout.parse_latex`, and lays the result out in `Display` style with
     `TeXLayout.default_font_family()`.
   - Every other string is treated as document input and routed through
     `TeXLayout.layout_document` with `TeXLayout.default_font_family()` and
     `TeXLayout.default_layout_options()`.
2. Convert each `LayoutBox` element to an MTE tuple `(element, Point2f, scale)`:
   - `Glyph` → `MathTeXEngine.TeXChar`; glyph indices are resolved through the
     glyph's `FontSlot` fallback paths and cached by `(font path, glyph name)`.
   - `HRule` → `MathTeXEngine.HLine` with the corresponding width and thickness.
   - `VRule` → `MathTeXEngine.VLine` with the corresponding height and thickness.
   - `Space` → skipped (carries no renderable geometry).

### Type piracy note

This is an instance of **type piracy**: TeXLayout owns neither
`MathTeXEngine.generate_tex_elements` nor `LaTeXStrings.LaTeXString`.  The approach is
pragmatic — it adds a more-specific method rather than overwriting an existing one,
which is the least disruptive form of piracy — and is confined entirely to the
extension module.  A future alternative would be a dedicated Makie recipe or an
upstream extension point in MathTeXEngine.  The Makie integration section of the README
describes the current status.

**Note**: the extension always uses `TeXLayout.default_font_family()`, ignoring any
`font_family` argument passed by Makie.  Users can change the effective font by calling
`TeXLayout.set_default_font_family!(:stix_two)` (or any other family) before rendering;
the extension picks up the change on the next render call.

---

## Adding a new LaTeX command

### Simple symbol

A simple symbol (like `\hbar`, `\checkmark`, or any new Unicode math symbol) needs
changes in two files:

1. **`src/tables/layout_symbols.jl`** — add an entry to `_SYMBOL_CODEPOINTS`:

   ```julia
   # in _SYMBOL_CODEPOINTS
   "hbar" => 0x210F,    # ℏ  PLANCK CONSTANT OVER TWO PI
   ```

   Also add an entry to `_CMD_ATOM_CLASS` in `src/tables/layout_atoms.jl` with
   the appropriate atom class (`:ord`, `:bin`, `:rel`, etc.):

   ```julia
   # in _CMD_ATOM_CLASS
   "hbar" => :ord,
   ```

2. **`src/parser.jl`** — no change is needed for simple symbols.  The parser already
   emits a `NodeKind.Command` leaf for any unrecognised command, and the layout engine looks up
   `_SYMBOL_CODEPOINTS` to find the glyph.  The only reason to touch the parser is if
   the command needs special argument handling (e.g. it takes a mandatory argument).

3. **`test/test_layout.jl`** — add a smoke test:

   ```julia
   @test length(layout(parse_latex(raw"\hbar"), family, Display)) > 0
   ```

### Structural construct

A new structural element (a new environment, a new kind of extensible, etc.) requires
changes in both files and potentially a new `NodeKind`:

1. **`src/parser.jl`**:
   - Add a new value to the `NodeKind` `EnumX.@enumx` in `src/enums.jl`.
   - Add a parsing branch in `_parse_command!` (or a dedicated sub-parser function) that
     consumes the necessary tokens and builds the new node.

2. **Layout files**:
   - Add a new `_layout_xxx!` function in the most relevant feature file under
     `src/layout/`, or in `src/layout.jl` only when it is genuinely core layout
     dispatch/shared behavior.
   - Add a dispatch branch in `_layout_node!` calling `_layout_xxx!` for the new kind.
   - Add any necessary entries to `src/tables/layout_atoms.jl` for atom-class inference.

3. **Tests**:
   - Add unit tests for the parser output in `test/test_parser.jl`.
   - Add layout invariant tests in `test/test_layout.jl`.
   - Add end-to-end smoke tests in `test/test_katex.jl` if the feature has a KaTeX
     analogue.

---

## Adding a new font family

1. **Obtain the fonts** — collect the math OTF and, if available, the companion text
   OTF/TTF files (regular, bold, italic, bold-italic).  The math font must contain a
   valid OpenType MATH table.

2. **Build the artifact** — run the preparation script:

   ```
   julia tools/prepare_font_artifacts.jl /path/to/output_dir
   ```

   This downloads or copies the fonts, creates a tarball, computes its SHA-256 and
   tree-SHA-256, and prints a draft `Artifacts.toml` stanza.  Verify the stanza and
   add it to `Artifacts.toml` at the package root.

3. **Register the artifact** — add the new stanza from the previous step into
   `Artifacts.toml`.  Confirm the `git-tree-sha1` and `sha256` values match the actual
   tarball.

4. **Add the loader in `src/fonts.jl`**:

   ```julia
   # Add an artifact accessor:
   _artifact_dir_myfont() = @artifact_str("myfont")

   # Add an entry in _ARTIFACT_LOADERS:
   const _ARTIFACT_LOADERS = Dict{Symbol, Function}(
       # … existing entries …
       :myfont => () -> _family_from_artifact(_artifact_dir_myfont()),
   )
   ```

5. **Update documentation** — add a row to the font table in `docs/src/02-fonts.md`
   with the symbol name, display name, style description, and licence.

6. **Test** — run the test suite with the new family to check for any
   font-specific issues (unusual PS glyph names, missing MATH constants, etc.):

   ```julia
   julia --project=. -e '
       using TeXLayout, Test
       family = font_family(:myfont)
       node   = parse_latex(raw"\frac{\alpha + \beta}{\sqrt{x^2 + y^2}}")
       boxes  = layout(node, family, TeXLayout.Display)
       @test length(boxes) > 0
   '
   ```

---

## Test suite

Run the full suite with:

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

The fixture font is `NewCMMath-Regular.otf`; ground-truth MATH table constants are in
`test/fixtures/newcm_math.jl` as a plain Julia file of assignments.  This fixture is
used by `test/test_math_table.jl` to validate the parser against known values.

| File | What it covers |
|:-----|:---------------|
| `test/test_math_table.jl` | Binary MATH table parsing against all ground-truth constants from `newcm_math.jl` |
| `test/test_metrics.jl` | Glyph metric lookups: PS-name, codepoint, and upright paths; cache behaviour |
| `test/test_style.jl` | All eight style transitions and `size_scale` correctness |
| `test/test_lexer.jl` | Tokeniser: multi-letter commands, single-char commands, whitespace run preservation, TokenKind.EOF sentinel |
| `test/test_parser.jl` | AST structure for a representative set of expressions; resilience under ill-formed input |
| `test/test_layout.jl` | Layout engine invariants: non-empty box lists, relative positions, fraction/radical geometry |
| `test/test_katex.jl` | KaTeX-derived smoke tests (well-formed), malformed-input tests, and deeply nested expressions |
| `test/test_snapshots.jl` | Layout-equivalence hashes for representative math and document cases |

`test/test_snapshots.jl` is the guard for unintended layout changes.  It hashes
normalized layout output: glyph names, font slots, glyph metrics, rules, positions,
scales, and document extents.  Box records are sorted before hashing, so changes in
append order from range-emission refactors do not count as layout changes.  If a
snapshot changes, inspect the serialized or rendered difference before updating the
expected hash, and document whether the change is an intentional bug fix or feature
change.

## Benchmarks

The benchmark harness lives in `benchmark/runbenchmarks.jl`.  Run a quick smoke check
while refactoring with:

```
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/runbenchmarks.jl --seconds=0.05 --samples=2 --output=/tmp/texlayout-bench-smoke.toml
```

For performance-sensitive changes, compare against a baseline:

```
julia --project=benchmark benchmark/runbenchmarks.jl --update-baseline
julia --project=benchmark benchmark/runbenchmarks.jl --baseline=benchmark/baseline.toml
```

The default regression thresholds are `--time-threshold=1.15` and
`--allocation-threshold=1.20`; both are configurable.  Treat sub-microsecond timing
deltas as noise unless a targeted longer run confirms them.  Allocation or memory
increases are usually more actionable than nanosecond-scale timing movement.

---

## Known limitations and future work

- **Multi-codepoint symbols** — commands such as `\nleqslant`, `\ngeqslant`, `\nleqq`,
  `\ngeqq`, `\lvertneqq`, `\gvertneqq`, `\varsubsetneq`, `\varsupsetneq`, `\npreceq`,
  and `\nsucceq` have no single Unicode codepoints.  Unicode encodes them as a base
  character plus U+0338 (COMBINING SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR-1),
  but OpenType math fonts do not consistently place them at any single codepoint.
  Correct support requires two-glyph overlay (analogous to `\not\leq`).  Do **not** add
  combining-sequence codepoints to `_SYMBOL_CODEPOINTS` in
  `src/tables/layout_symbols.jl`; they will not work with `glyph_metrics_by_codepoint`.

- **`\bigplus`** — no standard Unicode codepoint; listed in `_CMD_ATOM_CLASS` in
  `src/tables/layout_atoms.jl` (as `:op`) but absent from `_SYMBOL_CODEPOINTS` in
  `src/tables/layout_symbols.jl`, so it renders as blank space on all fonts.

- **Font-switching outside the Unicode math block** — `\mathbf`, `\boldsymbol`, and
  related commands cover the Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF)
  and a set of BMP exceptions.  Characters outside both ranges (e.g. accented Latin
  letters in a `\mathbf` argument) fall back to the default glyph.  The document
  text layer uses the `bold`, `italic`, and `bolditalic` `FontFamily` slots, but
  math-mode font switching does not yet use those slots to cover these cases.

- **Dedicated sans-serif and monospace text slots** — `\textsf` and `\texttt` are
  parsed by the document text layer but currently fall back to the regular text slot.
  Extending `FontFamily` with sans-serif and monospace slots would let these render
  distinct faces and would require matching Makie runtime-cache support.

- **Matrix vertical spacing helpers** — `\strut`, `\phantom`/`\vphantom`/`\hphantom`,
  and applied row-spacing arguments such as `\\[0.2em]` are not implemented.  The
  parser currently recognises and skips bracketed matrix row-spacing arguments; layout
  does not apply them.

- **Whitespace conventions** — leading, trailing, and repeated whitespace handling in
  math and document text modes needs a compatibility review against LaTeX before any
  behavior changes.

- **Makie type piracy** — the `MathTeXEngineExt` extension adds a method to a function
  and argument type that TeXLayout does not own.  Alternative integration strategies
  (a dedicated Makie recipe, or an upstream extension point in MathTeXEngine) are under
  consideration.

- **Makie font-family argument ignored** — `generate_tex_elements(str, font_family)` in
  the extension always uses `default_font_family()`.  Call
  `set_default_font_family!(family)` to change the font used by Makie.

- **Makie document options are session-wide** — Makie's fixed call site cannot pass
  document `LayoutOptions` per render.  The extension reads `default_layout_options()`
  for document-path renders; call `set_default_layout_options!` to change width,
  alignment, and display alignment globally for the session.
