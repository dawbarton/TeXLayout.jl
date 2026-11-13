# Design overview

These pages describe how TeXLayout is built: its pipeline, data structures,
layout algorithms, and the rules that keep them correct.  They are written for
contributors and for anyone embedding TeXLayout below the configuration API.
Two documents in the repository complement them:

- [`katex_rules.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/katex_rules.md)
  is the per-construct reference: the TeXbook rule each construct follows, the
  OpenType MATH constants it reads, and where TeXLayout deviates from KaTeX.
- [`future.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/future.md)
  is the single list of known limitations and planned work.

TeXLayout is an OpenType-aware LaTeX math typesetter intended as a drop-in
replacement for MathTeXEngine.jl in Makie.  Its design reference is
[KaTeX](https://katex.org/): the implementation is not a port, but it follows
KaTeX's algorithmic structure where that is sound.  Geometry is checked against
LuaLaTeX with unicode-math and the same font files (see
[Extending and testing](07-contributing.md)).

## Pipeline

A formula passes through three stages:

```
String ──tokenize──► Vector{Token} ──parse_latex──► Node (AST) ──layout──► Vector{LayoutBox}
```

Mixed text and math go through a second layer on top.  `parse_document` builds a
document of paragraphs, lines, and runs; `layout_document` lays out each run (text
through a `TextShaper`, math through the pipeline above) and stacks the lines into
a measured `TeXBox`.  The renderer adapters in `ext/` convert either result into
Makie's or MathTeXEngine's representation.

```julia
boxes = TeXLayout.generate_tex_elements(raw"\frac{a}{b}", family)   # the whole pipeline

tokens = TeXLayout.tokenize(raw"\frac{a}{b}")                       # stage by stage
node = TeXLayout.parse_latex(tokens)
boxes = TeXLayout.layout(node, family, TeXLayout.Display)

box = TeXLayout.layout_document(raw"Energy $E = mc^2$."; family)    # text and math
```

Each stage is a pure function apart from memoisation caches, so a parsed AST can
be laid out in several fonts or styles, and each stage can be tested on its own.

## Source map

| File | Role |
|:-----|:-----|
| `src/TeXLayout.jl` | Module entry: include order, exports, and `TeXLayoutHandler` |
| `src/math_table.jl` | OpenType MATH table parser, glyph names from CFF or `post`, GSUB `ssty` alternates; cached per font |
| `src/enums.jl` | Internal EnumX namespaces: `FontSlot`, `TextFamily`, `LayoutMode`, `Alignment`, `NodeKind`, `TokenKind` |
| `src/text_styles.jl` | `TextAttrs`, `TextFeatures`, and the text-style commands shared by math `\text{…}` and documents |
| `src/fonts.jl` | `FontFamily`, `GlyphMetrics`, glyph lookup, slot fallback, bundled families as artifacts; font caches |
| `src/shaping.jl` | The `TextShaper` interface and the metric-only `MetricShaper` |
| `src/style.jl` | The eight TeX styles and their transitions |
| `src/lexer.jl` | String to tokens |
| `src/payloads.jl` | Typed payloads carried by some AST nodes |
| `src/ast.jl` | `Node`, its constructors, and payload accessors |
| `src/parser.jl` | Recursive-descent parser: tokens to AST |
| `src/tables/` | Lookup tables kept out of the code: parser commands and environments, atom classes, spacing, symbols, math alphabets |
| `src/layout.jl` | Output types, layout context, atom classes and spacing, glyph helpers, the `_layout_node!` dispatch, and `layout` |
| `src/layout/` | Layout of scripts, compound constructs, extensible glyphs, and matrices |
| `src/boxes.jl` | Internal measured box tree used by composition |
| `src/document.jl` | Document AST and parser for mixed text and math |
| `src/compose.jl` | `TeXBox`, `LayoutOptions`, `hconcat`, `vstack`, and `layout_document` |
| `src/render_support.jl` | What both renderer adapters share: `LaTeXString` routing and `GlyphRuntime` |
| `ext/MakieExt.jl` | Makie 0.25 text handler (`Makie.layout_text`) |
| `ext/MathTeXEngineExt.jl` | Makie 0.24 adapter through MathTeXEngine |
| `ext/HarfBuzzExt.jl` | `HarfBuzzShaper` |
| `test/` | Test suite, one file per area; see [Extending and testing](07-contributing.md) |
| `tools/` | Visualisers, stress suite, and TeX comparison; see [Extending and testing](07-contributing.md) |
| `benchmark/` | BenchmarkTools harness with baseline comparison |
| `external/` | Read-only source references (KaTeX, Makie, MathTeXEngine); not part of the package |

## Caches and thread safety

Font data is expensive to rebuild, so it is memoised by path:

- `_load_font(path)` keeps the FreeType face and the parsed `hmtx` table
  (`_FONT_CACHE`), and `_font_upm` the units per em (`_UPM_CACHE`).
- `glyph_metrics(family, name)` results are memoised per math font and glyph name
  (`_NAMED_METRICS_CACHE`), because FreeType's name lookup otherwise dominates
  layout time.
- `load_math_table(path)` keeps the parsed `MathTable` (`_MATH_TABLE_CACHE`).
- `_glyph_runtime(family)` keeps one `GlyphRuntime` per family for the renderer
  adapters (`_GLYPH_RUNTIME_CACHE`), and `MathTeXEngineExt` its derived
  MathTeXEngine family.

These caches and the cached FreeType faces are shared between threads.
`Base.Dict` is not safe for concurrent use, so each cache is guarded by its own
`ReentrantLock`, and its values are built under that lock.  An `FT_Face` may be
used by only one thread at a time, and `FT_Load_Glyph` writes the face's shared
glyph slot, so every FreeType call on a cached face holds that face's
`FTFont.lock` (FreeTypeAbstraction's convention, which its own `glyph_index`
follows).  `_load_glyph_metrics` and `_char_index` do this; call them rather than
FreeType directly.  Without these locks, concurrent layout crashed inside
FreeType even with warm caches.  `test/test_threads.jl` lays out concurrently in
a four-thread child process.

## Invariants

1. **The `TokenKind.EOF` sentinel is never consumed.**  The lexer always appends
   one, every parser loop checks for it before calling a sub-parser, and
   `_parse_primary!` returns a zero-width `NodeKind.Space` at EOF without
   advancing.
2. **The parser never throws on ill-formed input.**  Double scripts, unclosed
   braces, or a missing `\right` give a degraded but well-formed AST, and layout
   accepts any tree the parser produces.
3. **All metric constants come from the MATH table.**  Axis height, script and
   fraction shifts, radical gaps, and rule thicknesses are read from the font.
   The fixed constants in `src/tables/` are TeX's and LaTeX's own
   dimensions (`\arraycolsep`, `\jot`, `\nulldelimiterspace`, …) and KaTeX's
   sizes for `\big` delimiters and extensible arrows, which no font carries.
4. **Glyphs are found by Unicode codepoint, not PostScript name.**  Names differ
   between fonts (AGL names in New Computer Modern, Pagella, and STIX Two,
   `uniXXXX` names in Fira Math, Luciole's own scheme), and `glyph_metrics(family,
   "x")` even returns the upright x in New Computer Modern.  Names are used only
   where the font itself keys data by name: the MATH table's constructions
   (through `_construction_key`), italic corrections, accent attachments, and
   `ssty` alternates.
5. **Math layout emits by range.**  `_layout_node!` appends to one shared
   `Vector{LayoutBox}`.  A construct that needs a child's extent records the
   `(start, stop)` range it just emitted, measures it, and moves it with
   `_translate_range!`; it never touches boxes outside its own ranges.  Append
   order is not paint order, so tests compare geometry, not order.
6. **Structured AST data lives in `Node.payload`.**  Delimiter pairs, `\big`
   delimiters, and matrix shapes are typed payloads (see
   [Parsing](02-parsing.md)); never encode fields into `Node.value`.

## API boundary

TeXLayout exports only the configuration surface a Makie user needs
(`font_family`, the default-family and default-options functions,
`HarfBuzzShaper`, and `TeXLayoutHandler`).  Everything else, including
`parse_latex`, `layout`, `layout_document`, and the element types, is reached as
`TeXLayout.Xxx`.  `NodeKind`, `TokenKind`, and the other enums are internal on
purpose: an internal name can be made public later without breaking anyone, but
a public one cannot be withdrawn.
