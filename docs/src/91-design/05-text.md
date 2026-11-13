# Text and documents

The math pipeline sets one formula.  A second layer handles text with inline and
display math, over several lines.  Its entry point is `layout_document`, which
returns a measured `TeXBox`:

```julia
struct TeXBox
    boxes::Vector{LayoutBox}   # every line, positioned
    width::Float64             # em
    ascent::Float64            # em above the first baseline
    descent::Float64           # em below the last baseline
end
```

## Document AST (`src/document.jl`)

`parse_document(input)` reads text by default and enters math with `$…$`,
`\(…\)`, `$$…$$`, `\[…\]`, or a top-level display environment.  It returns a
`Document`, a `Vector{Block}`:

| Type | Role |
|:-----|:-----|
| `TextAttrs` | the resolved style of a span: text `family`, weight and shape `slot`, `size`, and `TextFeatures` |
| `TextFeatures` | backend-independent features; currently `small_caps` |
| `TextSpan` | a run of characters with one `TextAttrs` |
| `TextRun`, `MathRun` | a stretch of a line: shaped text, or a math `Node` with its style |
| `Line` | the runs between `\\` breaks |
| `ParagraphBlock`, `DisplayBlock`, `ParagraphBreakBlock` | a paragraph of lines, a display, or a blank-line break |

Text commands change independent axes of `TextAttrs`: family (`\textrm`,
`\textsf`, `\texttt`), weight (`\textbf`), shape (`\textit`), and features
(`\textsc`).  `\emph` toggles italic relative to its surroundings, and
`\textnormal` is the only full reset.  `\text` and `\mbox` open a group that
inherits the current style.  The same transitions, in `src/text_styles.jl`,
serve `\text{…}` inside math.  `align`, `aligned`, `gather`, `gathered`, `split`,
and `equation` at the top level become `DisplayBlock`s.

### Whitespace

Document text follows LaTeX.  A single newline is one space, a continuation
line's indentation collapses, a blank line starts a paragraph, and leading and
trailing whitespace at line and block boundaries is dropped.  `_DocBuilder`
implements this with a deferred space (`pending_space`, `at_line_start`).  Spaces
inside `{…}` and around inline math are significant.  `%` comments are handled
in the lexer (see [Parsing](02-parsing.md)).

`~` is a significant non-breaking space (`pending_nbsp`): one interword space,
merged with adjacent ordinary whitespace, and, unlike ordinary whitespace, never
dropped at a line or paragraph boundary.  There is no soft line breaking yet, so
its non-breaking property cannot be observed.

## Shaping (`src/shaping.jl`)

A `TextShaper` turns a `TextSpan` into positioned glyphs:
`shape_span(shaper, span, family, scale)` returns a `TeXBox` in em, baseline at
y = 0 and first glyph at x = 0, whose width is the total advance.  Every shaper
emits `GlyphID` elements naming the exact font file that the text-font fallback
chose, and must apply the span's `TextFeatures` faithfully or reject them.

- `MetricShaper` (the default) places one glyph per character with advances from
  `hmtx`, without substitution or kerning.  It throws on a span with features
  rather than fake small capitals from scaled capitals.  It must stay testable
  without HarfBuzz.
- `HarfBuzzShaper` (`ext/HarfBuzzExt.jl`, loaded with HarfBuzz_jll) shapes with
  HarfBuzz and maps `small_caps` to the OpenType `smcp` feature.  It does not
  reorder bidirectional paragraphs, expose language, script, or feature settings,
  or shape math glyphs and operators.

Document text always goes through `LayoutOptions.shaper`.  Math `\text{…}` and
`\mbox{…}` use the shaper only when one other than `MetricShaper` is passed to
`layout` or `generate_tex_elements`, or when a text style needs it; otherwise they
keep the upright-glyph path.

## Composition (`src/boxes.jl`, `src/compose.jl`)

Composition measures with a small internal box tree, `ShapedBox` (laid-out boxes
with their extents), `HBox`, and `VBox`, and flattens it with `shape(box)` into
the `Vector{LayoutBox}` renderers consume.  On top of it:

- `hlayout_math` and `hlayout_run` lay out one math node or one run as a `TeXBox`.
  Inline math takes the larger of the layout's advance and its measured width,
  so space after a final script counts.
- `hconcat` joins runs on a shared baseline.
- `vstack` stacks lines and displays with `line_height`, `lineskip`, and the
  display and paragraph skips.
- `LayoutOptions` holds those settings (`align`, `width`, `line_height`,
  `lineskip`, `display_align`, `abovedisplayskip`, `belowdisplayskip`, `parskip`,
  `shaper`); `layout_document` builds one from keywords over the session default
  (`default_layout_options`).

The internal box tree is the first step towards a box-and-glue representation
for all layout; math layout still emits flat ranges.  Line breaking, when it
comes, is the natural point to finish that migration.
