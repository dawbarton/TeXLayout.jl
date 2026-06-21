# TeXLayout.jl — Architecture and Developer Guide

This file documents key architectural decisions, invariants, and caveats for
agents and human developers working on this codebase.

## Purpose

TeXLayout.jl is a Julia-idiomatic OpenType-aware LaTeX math typesetter.  It is intended
as a drop-in replacement for MathTeXEngine.jl in Makie.jl.  The design reference is
[KaTeX](https://katex.org/); the implementation is not a direct port but follows the same
algorithmic structure where it is sound.

## File structure

```
TeXLayout.jl/
├── src/
│   ├── TeXLayout.jl        # Module entry point; exports and include order
│   ├── math_table.jl       # OpenType MATH table parser + per-font MathTable cache
│   ├── enums.jl            # Internal namespaced enums (EnumX): FontSlot, LayoutMode, Alignment, NodeKind, TokenKind
│   ├── fonts.jl            # FontFamily, GlyphMetrics, artifact-backed font lookup, font cache
│   ├── style.jl            # TexStyle enum (D/T/S/SS × cramped), style transition helpers
│   ├── lexer.jl            # Tokeniser: LaTeX string → Vector{Token}
│   ├── payloads.jl         # Structured encoders/decoders for data stored in Node.value
│   ├── ast.jl              # Node AST type and AST helper constructors
│   ├── parser.jl           # Recursive-descent parser implementation
│   ├── tables/             # Parser/layout lookup tables kept out of implementation files
│   │   ├── parser_tables.jl
│   │   ├── layout_atoms.jl
│   │   ├── layout_spacing.jl
│   │   └── layout_symbols.jl
│   ├── layout.jl           # Core layout types, shared helpers, recursive dispatch, public layout API
│   ├── layout/             # Feature-specific layout helpers
│   │   ├── constructs.jl
│   │   ├── extensible.jl
│   │   ├── matrix.jl
│   │   └── scripts.jl
│   ├── boxes.jl            # Internal measured box tree + shape pass for composition
│   ├── shaping.jl          # TextShaper interface, MetricShaper, per-span glyph shaping
│   ├── document.jl         # Document AST (Block/Line/Run/TextSpan/TextAttrs) + parse_document
│   └── compose.jl          # TeXBox, hconcat, vstack, LayoutOptions, layout_document
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
│   ├── test_katex.jl       # KaTeX-derived test suite (smoke, malformed, nested)
│   ├── test_text.jl        # Text/document layout tests
│   └── test_snapshots.jl   # Layout-equivalence hashes for math and document layout
├── benchmark/
│   ├── Project.toml
│   ├── README.md
│   └── runbenchmarks.jl    # BenchmarkTools harness with baseline comparison support
├── tools/
│   ├── visualise_bitmap.jl        # Rasterise one expression to PNG via FreeType
│   ├── visualise_metrics.jl       # MathTeXEngine-style glyph metric overlay visualiser
│   ├── visualise_metrics_makie.jl # CairoMakie text! + metric overlay visualiser
│   ├── stress_test_content.jl     # Shared test expression definitions (library, not executable)
│   ├── stress_test_freetype.jl    # Render stress-test sheet via FreeType (no Makie required)
│   ├── stress_test_makie.jl       # Render stress-test sheet via CairoMakie
│   ├── stress_test_text.jl        # Render mixed text/math document stress-test sheet
│   ├── stress_test_latex.jl       # Generate .tex stress-test source for xelatex comparison
│   ├── stress_test_suite.jl       # Unified per-case stress PNG generator/packer/comparator
│   ├── stress_test_all.jl         # Compatibility wrapper for stress_test_suite.jl
│   ├── visualise_text.jl          # Render a mixed text/math string to PNG via FreeType
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
├── AGENTS.md               # This architecture/developer guide
├── CLAUDE.md               # Symlink to AGENTS.md for compatibility
├── katex_rules.md          # Rule-by-rule implementation notes against KaTeX/TeX
├── notes.md                # Cross-session engineering notes
├── justfile                # Common developer/test/stress-suite command shortcuts
├── Project.toml
└── README.md
```

### Rendering tools

All tools in `tools/` share a single `Project.toml` / `Manifest.toml` and activate automatically via `julia --project=tools/ tools/<script>.jl`.  Most PNG outputs are written directly from Julia; some single-expression visualisers may still require ImageMagick (`magick` / `convert`) on `PATH`.

| Script | Purpose | Key invocation |
|--------|---------|----------------|
| `visualise_bitmap.jl` | Pixel-accurate FreeType render of a single expression — first sanity check after changing the layout engine. | `julia tools/visualise_bitmap.jl "expr" out.png` |
| `visualise_metrics.jl` | Metric overlay: coloured left-bearing / advance-gap / above-baseline / descender regions, plus baseline and axis guides. | `julia tools/visualise_metrics.jl "expr" [out.png] [:font_symbol\|/path/to/math.otf]` |
| `visualise_metrics_makie.jl` | CairoMakie companion to the above: draws via `text!` and overlays TeXLayout metric guides in data space. | `julia tools/visualise_metrics_makie.jl "expr" [out.png\|out.svg\|out.pdf] [:font\|/path]` |
| `stress_test_freetype.jl` | Visual full-sheet math stress render via FreeType — no CairoMakie or LaTeXStrings required. | `julia tools/stress_test_freetype.jl [out.png] [:font_symbol]` |
| `stress_test_makie.jl` | Visual full-sheet math stress render via CairoMakie. | `julia tools/stress_test_makie.jl [out.png\|out.pdf] [:font_symbol]` |
| `stress_test_text.jl` | Visual full-sheet mixed text/math document stress render via `layout_document`; source text appears beside the rendered output. | `julia tools/stress_test_text.jl [:font_symbol] [out.png]` |
| `stress_test_suite.jl` | Unified stress suite: generate per-case PNGs for all bundled fonts, optionally include CairoMakie integration checks, pack a reference tarball, and compare current output against a local or downloaded reference. | `julia tools/stress_test_suite.jl all` |
| `stress_test_all.jl` | Compatibility wrapper for the unified suite. Old font-list invocations still work, and explicit suite commands pass through. | `julia tools/stress_test_all.jl [all\|generate\|pack\|compare]` |
| `prepare_font_artifacts.jl` | Download fonts from CTAN/GitHub, build artifact tarballs, and draft `Artifacts.toml` stanzas.  Run when adding fonts or publishing a release. | `julia tools/prepare_font_artifacts.jl [output_dir]` |

The root `justfile` provides shortcuts for the common paths:

```
just test
just stress-generate
just stress-generate-makie
just stress-pack
just stress-compare
just stress-all
```

### Stress references

`tools/stress_test_suite.jl` is the canonical image regression tool.  It generates a directory tree of stable, per-expression PNGs grouped by font, suite, and source category:

```
stress_outputs/current/<font>/<suite>/<section>/<case>.png
```

The built-in suites are `math_freetype`, `text_freetype`, and the optional `makie_cairo` suite enabled with `--include-makie`.  `makie_cairo` is intentionally opt-in because it loads CairoMakie, but it should be used before changing Makie extension behaviour.

Reference archives are named `stress_test_reference.tar` and are created with Julia's `Tar` stdlib:

```
julia tools/stress_test_suite.jl generate --out stress_outputs/current
julia tools/stress_test_suite.jl pack --input stress_outputs/current --out stress_test_reference.tar
julia tools/stress_test_suite.jl compare --current stress_outputs/current --reference stress_test_reference.tar
```

The `all` command runs generate, downloads or reads a reference, and compares in one step.  A reference can be a local path or URL; the default remote is the `v0.1.0-stress` release asset `stress_test_reference.tar`.

Full-sheet outputs remain useful for quick visual inspection and are written under each font's `sheets/` directory, but they are deliberately excluded from reference tarballs and comparisons.  Adding new stress cases is backwards-compatible: images present only in the current output are reported as `NEW` and do not fail comparison unless `--fail-on-new` is passed.  Missing, changed, or unreadable reference images still fail.

### Formatting

Format Julia code with Runic.jl.  The simplest path is the `runic` Bash command
from the repository root; Runic is also installed in the global Julia
environment `@runic`.  Any touched Julia source or test files should be left in
Runic format before finishing a change.

## Pipeline

```
String  ──tokenize──►  Vector{Token}  ──parse_latex──►  Node (AST)  ──layout(node, family, style)──►  Vector{LayoutBox}
```

Each stage is stateless and pure apart from memoization caches: `fonts.jl`
caches loaded FreeType faces and `hmtx` data by path, `math_table.jl` caches
parsed `MathTable` values by math-font path, and `ext/MathTeXEngineExt.jl`
caches the Makie-facing runtime bundle by effective `FontFamily`.

## Key types

### `Node` / `NodeKind` (`ast.jl`, `enums.jl`)
- `NodeKind` is an internal `EnumX.@enumx` namespace; use values as
  `NodeKind.Char`, `NodeKind.Sequence`, etc.  The namespace is intentionally not
  exported yet.  It can be made public later without breaking callers, but making
  an exported internal API private later would be breaking.
- Immutable struct: `kind::NodeKind.T`, `value::String`,
  `children::Vector{Node}`, `width::Float64`.  The `width` field is only
  meaningful for `NodeKind.Space` nodes (em units; 1 mu = 1/18 em); all other
  kinds leave it at `0.0`.  See the `EnumX.@enumx NodeKind` block in
  `enums.jl` for the full kind list.
- **Non-obvious encodings** — several kinds pack structured data into `value`
  using `\x00` as a field separator:
  - `NodeKind.Decorated` — children are always `[base, sub, sup]` regardless of
    source order.  (`NodeKind.Superscript`/`NodeKind.Subscript` have children
    `[base, script]` when only one script is present.)
  - `NodeKind.Delimited` — `value = "left_ps\x00right_ps"` (PostScript glyph
    names; empty string = null delimiter, no glyph rendered).
  - `NodeKind.Genfrac` — same `"left_ps\x00right_ps"` convention; children =
    `[numerator, denominator]`.
  - `NodeKind.BigDelim` — `value = "ps_name\x00<size>\x00<class>"` where size
    ∈ `'1'`–`'4'` (1.2 / 1.8 / 2.4 / 3.0 em) and class ∈ `'o'` / `'c'` /
    `'r'` / `'d'` (open/close/rel/ord atom class).
  - `NodeKind.Matrix` — `value = "env\x00nrow\x00colspec"`; children are a flat
    row-major list of `NodeKind.Group` cells.  For `\begin{array}` the colspec
    string is taken verbatim (e.g. `"|l|c|r|"`); for shorthand environments it
    is derived automatically.  `||` produces two rules separated by
    `_MATRIX_DOUBLERULESEP`.
  - `NodeKind.StyleOverride` — for `\displaystyle` / `\textstyle` / etc. the
    body `NodeKind.Sequence` consumes the **rest of the current group**; for
    `\dfrac`/`\tfrac` the body is the single `NodeKind.Frac` node.  Both reset
    style *and* scale absolutely, so `\dfrac` inside a subscript renders at full
    display size.
  - `NodeKind.Operator` — `value` is the bare operator name (e.g. `"sin"`).
    Operators in `_LIMITS_OPERATORS` automatically use limits placement in
    Display style.

### `Token` / `TokenKind` (`lexer.jl`, `enums.jl`)
- `TokenKind` is also an internal `EnumX.@enumx` namespace.  Use values as
  `TokenKind.Char`, `TokenKind.Command`, `TokenKind.EOF`, etc.; do not introduce
  new flat `TK*` bindings.
- The lexer always appends exactly one `TokenKind.EOF` sentinel.  Parser loops
  must check for that sentinel before calling sub-parsers.

### Glyph lookup (`fonts.jl`)
Three functions with different portability:
- `glyph_metrics(family, name)` — PS glyph name in the math font.  **Avoid for
  letters and symbols** — naming conventions diverge across fonts (AGL in
  NewCMMath/Pagella/STIXTwo, `uni`-style in FiraMath, font-specific in Luciole).
- `glyph_metrics_by_codepoint(family, cp)` — Unicode codepoint; the portable
  path for all math symbols and letters.  Returns `nothing` on miss.
- `glyph_metrics_upright(family, ch)` — upright (roman) form; uses the `regular`
  font slot if present, else falls back to the math font's codepoint map.  Used
  by `NodeKind.Operator` and `\text{}`/`\mbox{}` rendering.

Fonts are cached in `_FONT_CACHE` by path; safe to call repeatedly.

### `LayoutBox` / `TeXElement` (`layout.jl`)
- `LayoutBox`: `element::TeXElement`, `x::Float64`, `y::Float64`, `scale::Float64`.
  Positions are in em units (design units / UPM × scale); x right, y up, origin at
  formula baseline.
- Element subtypes: `Glyph` (PS name + metrics), `HRule` (width + thickness in em),
  `VRule` (height + thickness in em), `Space` (width in em).
- `Glyph.font_slot` — tells the renderer which font file to use for glyph-index
  resolution.  Math-mode glyphs carry `FontSlot.Math`; document text glyphs may
  carry `FontSlot.Regular`, `FontSlot.Bold`, `FontSlot.Italic`, or
  `FontSlot.BoldItalic`, each falling back through the configured `FontFamily`
  slots when the requested companion font is absent.
- `_LayoutCtx` carries: `family`, `mc` (all MATH constants), `upm`,
  `vert_constructions` / `horiz_constructions` (extensible glyph tables),
  `top_accent_attachments`, `italic_corrections`, `min_connector_overlap`,
  `mode` (`LayoutMode.Math` or `LayoutMode.Text`), `font_variant` (`:default`
  or a `\mathXX` symbol).

## Architectural invariants

1. **The `TokenKind.EOF` sentinel is never consumed.** Every loop in the parser
   checks for `TokenKind.EOF` before calling sub-parsers.  `_parse_primary!`
   returns a zero-advance `NodeKind.Space` node on `TokenKind.EOF` without
   advancing `pos`.

2. **The parser never throws on ill-formed input.** Malformed expressions (double scripts,
   unclosed braces, missing `\right`) produce degraded but structurally valid ASTs.

3. **All metric constants come from the MATH table.** This includes axis height, script
   shifts, fraction shifts, radical gaps, and rule thicknesses.  Adding support for a new
   construct requires identifying the correct MATH table fields (see the OpenType spec
   or KaTeX's `fontMetricsData.js`).

4. **`NodeKind.Operator` uses codepoint lookup, not PS-name lookup.** The
   codepoint path reliably returns the *upright* roman form in OpenType math
   fonts.  (In NewCMMath, PS names like `"x"` also happen to map to the upright
   form, but this is font-dependent — using codepoints is the portable approach
   for upright text.)

5. **Large operator glyphs are resolved by codepoint, not command name.** PS glyph names
   in OpenType math fonts diverge from LaTeX command names (`\sum` → `"summation"`,
   `\prod` → `"product"`, `\int` → `"integral"`, etc.).
   `_DISPLAY_OP_CODEPOINTS` in `src/tables/layout_symbols.jl` maps bare command
   names to Unicode codepoints; `glyph_name_by_codepoint` then obtains the
   correct PS name.  The display-size variant is selected from `vert_constructions`
   using the `display_operator_min_height` MATH constant.

6. **All math symbol glyphs should be resolved by Unicode codepoint, not PostScript name.**
   PS glyph naming conventions differ across fonts: NewCMMath/Pagella/STIXTwo use standard
   AGL names (`"parenleft"`, `"ltimes"`, `"alpha"`), while FiraMath uses uni-style names
   (`"uni0028"`, `"uni22C9"`, `"uni03B1"`) and Luciole uses its own convention (`"lparen"`,
   `"muppi"`, etc.).  Resolving by codepoint via `glyph_metrics_by_codepoint` is the only
   path that is portable across all fonts.  `_SYMBOL_CODEPOINTS` in
   `src/tables/layout_symbols.jl` is the authoritative map from bare command
   name → Unicode codepoint for all ordinary symbols.
   Additionally, `glyph_metrics(family, "x")` returns the *upright* roman form in NewCMMath
   (the glyph named "x" is the regular-weight slot), whereas the cmap at U+0078 correctly
   yields the math-italic form — so codepoint resolution is also more correct for letters.
   The only necessary use of PS names is in `_construction_key`, which translates canonical
   AGL names to the font's own names when looking up `vert_constructions`/`horiz_constructions`
   (those dicts are keyed by the font's MATH table PS names and cannot be changed).

7. **Math layout uses range emission.** `_layout_node!` appends new boxes to the
   shared `Vector{LayoutBox}`.  Construct helpers that need child measurements
   record the just-emitted `(start, stop)` ranges, scan those ranges for extents,
   and translate those same ranges in place with `_translate_range!`.  They must
   not mutate boxes outside the ranges they emitted.  Append order is not
   semantic; geometry, metrics, font slots, and rule/space dimensions are.

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
- **`\bigplus` has no Unicode codepoint** — it is in `_CMD_ATOM_CLASS` (`:op`)
  in `src/tables/layout_atoms.jl` but not in `_SYMBOL_CODEPOINTS`, so it
  produces blank space on all fonts.  It is not a standard LaTeX/AMS symbol and
  has no single Unicode codepoint; per-font investigation would be needed to
  support it.
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
- **`align` column-spacing approximation** — `\begin{align}` reuses the matrix column
  machinery and its column-separation model.  Cells after `&` do insert the
  ordinary atom needed for TeX-style spacing before leading relations such as
  `=`, but the environment is not a full amsmath alignment template.
- **`\textsf` / `\texttt` mapped to `:regular` slot** — no dedicated sans-serif or
  monospace font is wired to those slot names in v1; they render identically to `\textrm`.
- **HarfBuzz shaper not yet implemented** — the `TextShaper` interface and extension seam
  are in place (`ext/HarfBuzzExt.jl` is documented in `text-spec.md` but not yet built).
  Users opt in with `shaper = HarfBuzzShaper()` once the extension is available.
- **Makie extension ignores caller-specified font family** — the overridden
  `generate_tex_elements` accepts a `font_family` argument (for API compatibility
  with MathTeXEngine) but always uses `TeXLayout.default_font_family()` regardless.
  Users can change the font used by Makie by calling `TeXLayout.set_default_font_family!`
  before rendering; the extension will pick up the new default automatically.

## Changelog

`CHANGELOG.md` follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Every user-visible change — new features, bug fixes, removals, and breaking changes — must be
recorded in the `[Unreleased]` section at the time it is made, grouped under the appropriate
heading (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`).  When a version
is released, the `[Unreleased]` section is retitled with the version number and date, and a
fresh `[Unreleased]` section is opened above it.

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.

`test/test_snapshots.jl` is the layout-equivalence guard.  It hashes normalized
layout output for representative math and document cases: glyph names, font
slots, glyph metrics, rules, positions, scales, and document extents.  Box
records are sorted before hashing so append order changes from range-emission
refactors do not count as layout changes.  If a snapshot hash changes, either
the geometry/metrics changed or the normalization changed.  Do not update a
hash casually; inspect the rendered/serialized difference and document whether
the change is an intentional bug fix or feature change.

## Benchmarks

The benchmark harness lives in `benchmark/runbenchmarks.jl`.

Use a quick smoke run while refactoring:

```
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/runbenchmarks.jl --seconds=0.05 --samples=2 --output=/tmp/texlayout-bench-smoke.toml
```

For performance-sensitive changes, compare against a baseline with the default
longer settings:

```
julia --project=benchmark benchmark/runbenchmarks.jl --update-baseline
julia --project=benchmark benchmark/runbenchmarks.jl --baseline=benchmark/baseline.toml
```

The default regression thresholds are `--time-threshold=1.15` and
`--allocation-threshold=1.20`; both are configurable.  Treat sub-microsecond
timing deltas as noise unless a targeted longer run confirms them.  Allocation
or memory increases are usually more actionable than nanosecond-scale timing
movement.

## Note taking

Take notes incrementally during a session at natural breakpoints (end of a discussion phase, after a plan is agreed, after a significant result). Do not wait until the end of the session. Add notes to the end of `notes.md` in the project root using the section heading:

```
## <ISO datetime> <descriptive title>
```

followed by bullet points covering key ideas, decisions, results, and open questions. Include references to external sources where relevant. Keep notes concise and high-signal; this is cross-session context, not a transcript. Ensure the correct ISO datetime is used by calling `date -Iminutes` with Bash.
