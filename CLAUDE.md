# TeXLayout.jl — Architecture and Developer Guide

This file documents key architectural decisions, invariants, and caveats for
Claude (and human developers) working on this codebase.

---

## Purpose

TeXLayout.jl is a Julia-idiomatic OpenType-aware LaTeX math typesetter.  It is intended
as a drop-in replacement for MathTeXEngine.jl in Makie.jl.  The design reference is
[KaTeX](https://katex.org/); the implementation is not a direct port but follows the same
algorithmic structure where it is sound.

---

## File structure

```
TeXLayout.jl/
├── src/
│   ├── TeXLayout.jl        # Module entry point; exports and include order
│   ├── math_table.jl       # OpenType MATH table parser + per-font MathTable cache
│   ├── fonts.jl            # FontFamily, GlyphMetrics, artifact-backed font lookup, font cache
│   ├── style.jl            # TexStyle enum (D/T/S/SS × cramped), style transition helpers
│   ├── lexer.jl            # Tokeniser: LaTeX string → Vector{Token}
│   ├── parser.jl           # Recursive-descent parser: tokens → Node AST
│   └── layout.jl           # Layout engine: Node + style → Vector{LayoutBox}
├── ext/
│   └── MathTeXEngineExt.jl # Makie/MathTeXEngine extension + cached runtime conversion bundle
├── test/
│   ├── runtests.jl         # Top-level testset; includes all test files
│   ├── fixtures/
│   │   └── newcm_math.jl   # Ground-truth constants extracted from NewCMMath-Regular.otf
│   ├── test_math_table.jl  # Tests for MATH table parsing and cache behaviour
│   ├── test_metrics.jl     # Tests for glyph metric lookups
│   ├── test_style.jl       # Tests for style cascade transitions
│   ├── test_lexer.jl       # Tests for the tokeniser
│   ├── test_parser.jl      # Tests for AST structure
│   ├── test_layout.jl      # Tests for layout engine invariants and feature coverage
│   └── test_katex.jl       # KaTeX-derived test suite (smoke, malformed, nested)
├── tools/
│   ├── visualise_bitmap.jl        # Rasterise one expression to PNG via FreeType
│   ├── visualise_metrics.jl       # MathTeXEngine-style glyph metric overlay visualiser
│   ├── visualise_metrics_makie.jl # CairoMakie text! + metric overlay visualiser
│   ├── stress_test_content.jl     # Shared test expression definitions (library, not executable)
│   ├── stress_test_freetype.jl    # Render stress-test sheet via FreeType (no Makie required)
│   ├── stress_test_makie.jl       # Render stress-test sheet via CairoMakie
│   ├── stress_test_latex.jl       # Generate .tex stress-test source for xelatex comparison
│   ├── stress_test_all.jl         # Batch-render all font families and compare with reference images
│   └── prepare_font_artifacts.jl  # Build artifact tarballs + draft Artifacts.toml stanzas
├── docs/
│   ├── make.jl             # Documenter.jl build script
│   ├── Project.toml
│   └── src/                # Markdown source pages
├── external/               # Source references (read-only; not part of the package)
│   ├── KaTeX/
│   ├── Makie.jl/
│   └── MathTeXEngine.jl/
├── artifacts/              # Bundled font payloads and extracted font files
├── Artifacts.toml          # Artifact definitions for bundled fonts
├── CHANGELOG.md            # Keep a Changelog format; update [Unreleased] with every change
├── CLAUDE.md               # This architecture/developer guide
├── katex_rules.md          # Rule-by-rule implementation notes against KaTeX/TeX
├── notes.md                # Cross-session engineering notes
├── Project.toml
└── README.md
```

### Rendering tools

All tools in `tools/` share a single `Project.toml` / `Manifest.toml` and activate automatically via `julia --project=tools/ tools/<script>.jl`.  PNG output uses ImageMagick (`magick` / `convert`), which must be available on `PATH`.

| Script | Purpose | Key invocation |
|--------|---------|----------------|
| `visualise_bitmap.jl` | Pixel-accurate FreeType render of a single expression — first sanity check after changing the layout engine. | `julia tools/visualise_bitmap.jl "expr" out.png` |
| `visualise_metrics.jl` | Metric overlay: coloured left-bearing / advance-gap / above-baseline / descender regions, plus baseline and axis guides. | `julia tools/visualise_metrics.jl "expr" [out.png] [:font_symbol\|/path/to/math.otf]` |
| `visualise_metrics_makie.jl` | CairoMakie companion to the above: draws via `text!` and overlays TeXLayout metric guides in data space. | `julia tools/visualise_metrics_makie.jl "expr" [out.png\|out.svg\|out.pdf] [:font\|/path]` |
| `stress_test_freetype.jl` | Full stress-test sheet rendered via FreeType — no CairoMakie or LaTeXStrings required. | `julia tools/stress_test_freetype.jl [out.png] [:font_symbol]` |
| `stress_test_makie.jl` | Full stress-test sheet rendered via CairoMakie. | `julia tools/stress_test_makie.jl [out.png\|out.pdf] [:font_symbol]` |
| `stress_test_all.jl` | Batch-render all 8 bundled families and diff against reference images from the `v0.1.0-stress` release. | `julia tools/stress_test_all.jl` |
| `prepare_font_artifacts.jl` | Download fonts from CTAN/GitHub, build artifact tarballs, and draft `Artifacts.toml` stanzas.  Run when adding fonts or publishing a release. | `julia tools/prepare_font_artifacts.jl [output_dir]` |

### Formatting

Format Julia code with Runic.jl.  The simplest path is the `runic` Bash command
from the repository root; Runic is also installed in the global Julia
environment `@runic`.  Any touched Julia source or test files should be left in
Runic format before finishing a change.

---

## Pipeline

```
String  ──tokenize──►  Vector{Token}
                              │
                        parse_latex
                              │
                              ▼
                           Node (AST)
                              │
                    layout(node, family, style)
                              │
                              ▼
                     Vector{LayoutBox}
```

Each stage is stateless and pure apart from memoization caches: `fonts.jl`
caches loaded FreeType faces and `hmtx` data by path, `math_table.jl` caches
parsed `MathTable` values by math-font path, and `ext/MathTeXEngineExt.jl`
caches the Makie-facing runtime bundle by effective `FontFamily`.

---

## Key types

### `Node` / `NodeKind` (`parser.jl`)
- Immutable struct: `kind::NodeKind`, `value::String`, `children::Vector{Node}`,
  `width::Float64`.  The `width` field is only meaningful for `NKSpace` nodes
  (em units; 1 mu = 1/18 em); all other kinds leave it at `0.0`.  See the
  `@enum NodeKind` block in `parser.jl` for the full kind list.
- **Non-obvious encodings** — several kinds pack structured data into `value`
  using `\x00` as a field separator:
  - `NKDecorated` — children are always `[base, sub, sup]` regardless of source
    order.  (`NKSuperscript`/`NKSubscript` have children `[base, script]` when
    only one script is present.)
  - `NKDelimited` — `value = "left_ps\x00right_ps"` (PostScript glyph names;
    empty string = null delimiter, no glyph rendered).
  - `NKGenfrac` — same `"left_ps\x00right_ps"` convention; children =
    `[numerator, denominator]`.
  - `NKBigDelim` — `value = "ps_name\x00<size>\x00<class>"` where size ∈
    `'1'`–`'4'` (1.2 / 1.8 / 2.4 / 3.0 em) and class ∈ `'o'` / `'c'` / `'r'` /
    `'d'` (open/close/rel/ord atom class).
  - `NKMatrix` — `value = "env\x00nrow\x00colspec"`; children are a flat
    row-major list of `NKGroup` cells.  For `\begin{array}` the colspec string
    is taken verbatim (e.g. `"|l|c|r|"`); for shorthand environments it is
    derived automatically.  `||` produces two rules separated by
    `_MATRIX_DOUBLERULESEP`.
  - `NKStyleOverride` — for `\displaystyle` / `\textstyle` / etc. the body
    `NKSequence` consumes the **rest of the current group**; for `\dfrac`/`\tfrac`
    the body is the single `NKFrac` node.  Both reset style *and* scale
    absolutely, so `\dfrac` inside a subscript renders at full display size.
  - `NKOperator` — `value` is the bare operator name (e.g. `"sin"`).  Operators
    in `_LIMITS_OPERATORS` automatically use limits placement in Display style.

### Glyph lookup (`fonts.jl`)
Three functions with different portability:
- `glyph_metrics(family, name)` — PS glyph name in the math font.  **Avoid for
  letters and symbols** — naming conventions diverge across fonts (AGL in
  NewCMMath/Pagella/STIXTwo, `uni`-style in FiraMath, font-specific in Luciole).
- `glyph_metrics_by_codepoint(family, cp)` — Unicode codepoint; the portable
  path for all math symbols and letters.  Returns `nothing` on miss.
- `glyph_metrics_upright(family, ch)` — upright (roman) form; uses the `regular`
  font slot if present, else falls back to the math font's codepoint map.  Used
  by `NKOperator` and `\text{}`/`\mbox{}` rendering.

Fonts are cached in `_FONT_CACHE` by path; safe to call repeatedly.

### `LayoutBox` / `TeXElement` (`layout.jl`)
- `LayoutBox`: `element::TeXElement`, `x::Float64`, `y::Float64`, `scale::Float64`.
  Positions are in em units (design units / UPM × scale); x right, y up, origin at
  formula baseline.
- Element subtypes: `Glyph` (PS name + metrics), `HRule` (width + thickness in em),
  `VRule` (height + thickness in em), `Space` (width in em).
- `Glyph.font_slot` — `:math` or `:regular`.  Tells the renderer which font file to
  use for glyph-index resolution (`:regular` falls back to `:math` when no companion
  regular font is configured).  All math-mode glyphs carry `:math`; glyphs from
  `\text{}`/`\mbox{}` carry `:regular`.
- `_LayoutCtx` carries: `family`, `mc` (all MATH constants), `upm`,
  `vert_constructions` / `horiz_constructions` (extensible glyph tables),
  `top_accent_attachments`, `italic_corrections`, `min_connector_overlap`,
  `mode` (`:math` or `:text`), `font_variant` (`:default` or a `\mathXX` symbol).

---

## Architectural invariants

1. **The TKEOF sentinel is never consumed.** Every loop in the parser checks for TKEOF
   before calling sub-parsers.  `_parse_primary!` returns a zero-advance `NKSpace` node
   on TKEOF without advancing `pos`.

2. **The parser never throws on ill-formed input.** Malformed expressions (double scripts,
   unclosed braces, missing `\right`) produce degraded but structurally valid ASTs.

3. **All metric constants come from the MATH table.** This includes axis height, script
   shifts, fraction shifts, radical gaps, and rule thicknesses.  Adding support for a new
   construct requires identifying the correct MATH table fields (see the OpenType spec
   or KaTeX's `fontMetricsData.js`).

4. **`NKOperator` uses codepoint lookup, not PS-name lookup.** The codepoint path reliably
   returns the *upright* roman form in OpenType math fonts.  (In NewCMMath, PS names like
   `"x"` also happen to map to the upright form, but this is font-dependent — using
   codepoints is the portable approach for upright text.)

5. **Large operator glyphs are resolved by codepoint, not command name.** PS glyph names
   in OpenType math fonts diverge from LaTeX command names (`\sum` → `"summation"`,
   `\prod` → `"product"`, `\int` → `"integral"`, etc.).  `_DISPLAY_OP_CODEPOINTS` in
   `layout.jl` maps bare command names to Unicode codepoints; `glyph_name_by_codepoint`
   then obtains the correct PS name.  The display-size variant is selected from
   `vert_constructions` using the `display_operator_min_height` MATH constant.

6. **All math symbol glyphs should be resolved by Unicode codepoint, not PostScript name.** (See also invariant 7 on layout purity.)
   PS glyph naming conventions differ across fonts: NewCMMath/Pagella/STIXTwo use standard
   AGL names (`"parenleft"`, `"ltimes"`, `"alpha"`), while FiraMath uses uni-style names
   (`"uni0028"`, `"uni22C9"`, `"uni03B1"`) and Luciole uses its own convention (`"lparen"`,
   `"muppi"`, etc.).  Resolving by codepoint via `glyph_metrics_by_codepoint` is the only
   path that is portable across all fonts.  `_SYMBOL_CODEPOINTS` in `layout.jl` is the
   authoritative map from bare command name → Unicode codepoint for all ordinary symbols.
   Additionally, `glyph_metrics(family, "x")` returns the *upright* roman form in NewCMMath
   (the glyph named "x" is the regular-weight slot), whereas the cmap at U+0078 correctly
   yields the math-italic form — so codepoint resolution is also more correct for letters.
   The only necessary use of PS names is in `_construction_key`, which translates canonical
   AGL names to the font's own names when looking up `vert_constructions`/`horiz_constructions`
   (those dicts are keyed by the font's MATH table PS names and cannot be changed).

7. **Layout is purely additive.** `_layout_node!` only pushes to `boxes`; it never
   removes or modifies existing entries.  Temporary `LayoutBox` vectors (used for
   centering fractions and limits) are merged in with adjusted coordinates.

---

## Feature index

`katex_rules.md` is the authoritative per-feature reference: it records the KaTeX/TeX
rule number, the OpenType MATH table field names used, implementation notes, and any
deviations from KaTeX behaviour.  Features without a KaTeX rule number (font switching,
array environments, text mode, etc.) are in the "Feature implementation index" section
at the end of that file.

## Known limitations / future work
- **Multi-codepoint Unicode symbols** — a subset of negated and variant relations
  (`\nleqslant`, `\ngeqslant`, `\nleqq`, `\ngeqq`, `\lvertneqq`, `\gvertneqq`,
  `\varsubsetneq`, `\varsupsetneq`, `\npreceq`, `\nsucceq`, and similar) lack single
  Unicode codepoints.  Unicode defines them as a base character + U+0338 (COMBINING
  SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR-1), but OpenType math fonts do not
  consistently encode them as single glyphs at any codepoint.  These commands currently
  produce blank space.  Correct support would require two-glyph overlay (base + combining
  stroke at x offset) — analogous to how TeX builds `\not\leq` — or per-font codepoint
  investigation.  Do not add combining-sequence "codepoints" to `_SYMBOL_CODEPOINTS`; they
  will not work with `glyph_metrics_by_codepoint`.
- **`\bigplus` has no Unicode codepoint** — it is in `_CMD_ATOM_CLASS` (`:op`) but not in
  `_SYMBOL_CODEPOINTS`, so it produces blank space on all fonts.  It is not a standard
  LaTeX/AMS symbol and has no single Unicode codepoint; per-font investigation would be
  needed to support it.
- **Font switching (text slots)** — `\mathbf`, `\boldsymbol`, `\mathit` etc. map Latin,
  Greek, and common symbols (∇, ∂, variant letters) to their Unicode math-variant
  codepoints.  The `bold`, `italic`, `bolditalic` slots in `FontFamily` are not yet used;
  adding them would cover characters outside the Unicode math block.
- **Makie integration** — implemented via `ext/MathTeXEngineExt.jl` (a Julia package
  extension).  When `TeXLayout`, `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings`
  are all loaded, the extension adds a specialised
  `MathTeXEngine.generate_tex_elements(::LaTeXString)` method that uses TeXLayout's
  OpenType layout engine.  Makie's `texelems_and_glyph_collection` always passes a
  `LaTeXString`, so dispatch picks our method over MathTeXEngine's fallback.  The
  extension is fully precompiled (no `__precompile__(false)` needed) because adding
  a method with a more specific argument type is a new method, not an overwrite.
  The extension also maintains a per-font runtime cache so repeated Makie renders
  reuse the loaded math/regular faces, the derived `MathTeXEngine.FontFamily`, and
  glyph-name → glyph-index lookup tables.
  **Geometry contract:** `TeXLayout.HRule` / `VRule` store rectangle edges
  (`HRule.y` = bottom edge, `VRule.x` = left edge), while
  `MathTeXEngine.HLine` / `VLine` use line-centre positions.  The adapter in
  `_box_to_mte` is responsible for converting between these conventions by
  shifting rule positions by half the thickness.
  **This is type piracy**: TeXLayout owns neither the function (`MathTeXEngine.generate_tex_elements`)
  nor the argument type (`LaTeXStrings.LaTeXString`).  It is pragmatic and confined
  to the extension, but alternative integration strategies (e.g. a dedicated Makie
  recipe or a proper upstream extension point in MathTeXEngine) will be investigated
  in future.
- **Makie extension ignores caller-specified font family** — the overridden
  `generate_tex_elements` accepts a `font_family` argument (for API compatibility
  with MathTeXEngine) but always uses `TeXLayout.default_font_family()` regardless.
  Users can change the font used by Makie by calling `TeXLayout.set_default_font_family!`
  before rendering; the extension will pick up the new default automatically.

---

## Changelog

`CHANGELOG.md` follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Every user-visible change — new features, bug fixes, removals, and breaking changes — must be
recorded in the `[Unreleased]` section at the time it is made, grouped under the appropriate
heading (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`).  When a version
is released, the `[Unreleased]` section is retitled with the version number and date, and a
fresh `[Unreleased]` section is opened above it.

---

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.
