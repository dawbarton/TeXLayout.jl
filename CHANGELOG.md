# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v0.3.0] - 2026-07-23

### Added
- Genuine sans-serif and monospace document text through `\textsf{…}` and
  `\texttt{…}`, backed by shared TeX Gyre Heros and Cursor artifacts for bundled
  serif families. Family, weight, shape, and OpenType features now compose as
  independent text-style axes.
- Feature-aware HarfBuzz fallback: semantic small caps require a physical font
  with the OpenType `smcp` feature and never silently synthesize or ignore it.
- Sans-serif, monospace, nested-feature, and Makie cases in the text and Cairo
  stress suites.

### Changed
- `MetricShaper` text now emits exact-path `GlyphID` elements, matching the
  renderer contract already used by `HarfBuzzShaper`.
- The exported namespace is limited to Makie-facing font/layout configuration
  functions and `HarfBuzzShaper`. Advanced layout, AST, element, and shaper
  interfaces remain available through qualified `TeXLayout.Xxx` access.
- `\textrm`, `\textsf`, and `\texttt` now preserve surrounding weight, shape,
  and semantic features; `\textnormal` remains the explicit full reset.

### Fixed
- Stress-reference URLs now download outside the extraction directory, allowing
  remote reference archives to be compared on Julia versions that require an
  empty extraction target.
- Cairo stress cases now restore the process-wide font and layout defaults,
  preventing HarfBuzz settings from leaking into later FreeType cases.
- Full stress generation now loads the Makie sheet renderer once, avoiding
  world-age failures and repeated constant redefinitions under
  `--include-makie`.

## [v0.2.3] - 2026-07-23

### Added
- `\textsc{…}` support in document text and inside math `\text{…}` / `\mbox{…}`
  fragments. Small caps are represented as semantic text attributes and shaped
  with the font's genuine OpenType `smcp` substitutions through
  `HarfBuzzShaper`; synthetic scaled capitals are deliberately not used.
- Shared nested text-style parsing for math-internal text fragments, using the
  same attribute semantics as document text.

## [v0.2.2] - 2026-06-24

### Added
- `split` and `gathered` math environments, laid out like `aligned` and `gather`
  respectively.
- Starred display environments (`align*`, `gather*`, `equation*`, …) are now
  accepted as aliases of their unstarred forms (equation numbering is not
  rendered, so the star has no visual effect).
- LaTeX-style `%` line comments are now recognised by the lexer in both math and
  document text modes. A `%` discards the rest of the line; a line ending in `%`
  also drops the following line break and the next line's leading indent (the
  usual whitespace-suppression idiom), while a comment immediately before a blank
  line still leaves the paragraph break intact. Escaped `\%` is unaffected.

### Changed
- Document text mode now trims whitespace at line and block boundaries to match
  LaTeX conventions: leading whitespace at the start of a paragraph or line and
  trailing whitespace before a display block or line break are dropped, instead
  of surviving as stray spaces on the adjacent text span. Single newlines still
  collapse to one inter-word space, indentation on continuation lines still
  collapses, blank lines still start a new paragraph, and spaces inside `{…}`
  groups and around inline math remain significant.
- `~`, `\ ` (control space), `\space`, and `\nobreakspace` now produce a normal
  interword space (1/3 em, matching TeX's `fontdimen2`) in math mode and inside
  `\text{…}`. Previously they were dropped, producing no space at all.
- In document text mode `~` is now a significant non-breaking space: it renders
  as a single inter-word space and is no longer dropped when it falls at the
  start or end of a line or paragraph (it still collapses with adjacent ordinary
  whitespace into one space). Soft line-breaking is not yet implemented, so the
  non-breaking property has no visible effect on wrapping today.

### Fixed
- A space immediately after `^` or `_` (e.g. `x^ 2`) and inside a command
  argument (e.g. `\frac 1 2`) is now ignored, so the following token becomes the
  script/argument. Previously the space was captured as an empty script and the
  intended argument was typeset separately on the baseline.
- Fractions, scripts, and large operators inside display alignment environments
  (`align`, `aligned`, `gather`, `gathered`, `split`, `equation`) now render at
  full display size. Previously these cells were typeset in Text style — like
  `matrix`/`array` cells — which incorrectly shrank fractions to script size.
  Genuine array environments (`matrix`, `array`, `cases`, `smallmatrix`) continue
  to use Text style, matching standard LaTeX.

## [v0.2.1] - 2026-06-22

### Added
- `GlyphID` render primitive for glyphs that are already resolved to an exact
  font path and glyph ID, used by shaped text and supported by the Makie adapter.
- Optional `HarfBuzzShaper` extension backed by `HarfBuzz_jll`; users can opt in
  with `shaper = HarfBuzzShaper()` for `layout_document`, `layout`, or
  `generate_tex_elements` after loading `HarfBuzz_jll`.
- HarfBuzz coverage in unit tests and a small HarfBuzz section in the text stress
  renderer, while leaving `MetricShaper` as the default stress-test workload.

### Changed
- Math `\text{…}` / `\mbox{…}` fragments can now use the active text shaper when
  a non-default shaper is passed; the default `MetricShaper` path preserves the
  legacy per-character/`Space` output.
- The MathTeXEngine/Makie extension now renders `GlyphID` values directly by glyph
  ID and exact font path instead of resolving through glyph names.

## [v0.2.0] - 2026-06-22

### Added
- `layout_document(input; family, align, line_height, lineskip, width, display_align,
  abovedisplayskip, belowdisplayskip, parskip, shaper)` — top-level text/paragraph layout entry
  point producing a `TeXBox` (flat `Vector{LayoutBox}` + measured extents)
- Text mode with significant spaces and literal characters; styled text via `\textbf`,
  `\textit`, `\textrm`, `\textnormal`, `\emph`, `\textsf`, `\texttt`, `\text`, `\mbox`
  with correct bold/italic nesting and `\emph` toggle
- Explicit line breaks (`\\`) and configurable `\baselineskip` / `\lineskip` spacing
- Inline math (`$…$`, `\(…\)`) embedded in text lines; display-math blocks
  (`$$…$$`, `\[…\]`, `\begin{align}`, `\begin{aligned}`, `\begin{gather}`,
  `\begin{equation}`) as free-standing vertical items
- `TeXBox`, `LayoutOptions`, `TextShaper`, `MetricShaper` exported types
- Pluggable text shaper interface (`TextShaper` abstract type, `MetricShaper` default);
  extension seam in place for a future HarfBuzz shaper via `ext/HarfBuzzExt.jl`
- `parse_document` (internal) — Document AST parser producing `ParagraphBlock` /
  `DisplayBlock` from mixed text/math input
- `hconcat` / `vstack` composition primitives (internal)
- `tools/visualise_text.jl` — render a mixed text/math string to PNG via FreeType
- `tools/stress_test_text.jl` — render a mixed text/math document stress sheet
  with literal source inputs beside `layout_document` output.
- Layout-equivalence snapshot tests for representative math and document cases.
- BenchmarkTools harness with configurable runtime/allocation regression thresholds.
- Unified stress-test suite (`tools/stress_test_suite.jl`) that renders per-case
  math, text, and optional CairoMakie PNGs for all bundled font artifacts,
  packages references as `stress_test_reference.tar`, and compares current output
  against local or downloaded references.
- Root `justfile` helpers for common test, stress generation, packaging, and
  comparison commands.
- Makie integration now renders mixed text-and-math `LaTeXString`s: the
  `MathTeXEngineExt` extension lays out a single inline-math span (`"$…$"`, the
  usual `L"…"` form) as one Display-style formula as before, but routes any other
  string (surrounding text, several `$…$` spans, `\(…\)`, or `$$…$$` / `\[…\]`
  display math) through `layout_document`.
- `default_layout_options()` / `set_default_layout_options!` — session-wide default
  `LayoutOptions` (mirroring `default_font_family`). `layout_document` merges
  per-call keyword arguments over these defaults, and the Makie extension reads them
  on the document path, giving width/alignment control where Makie's fixed call site
  cannot accept per-render options. `layout_document(input, opts::LayoutOptions;
  family)` is also available to pass an explicit options value.

### Changed
- Refactored internal parser and layout organization: AST/token kinds now use
  namespaced `EnumX.@enumx` enums, parser/layout lookup tables live under
  `src/tables/`, and feature-specific layout helpers live under `src/layout/`.
- Script and limits layout now measure emitted sub-ranges in place instead of
  allocating temporary `LayoutBox` buffers before copying them into the result.
- Compound math constructs now measure emitted sub-ranges in place for fractions,
  radicals, delimiters, arrows, accents, and over/under rules; snapshot tests now
  canonicalize box records so append order is not treated as layout semantics.
- Horizontal brace layout now measures body and note sub-ranges in place instead
  of allocating temporary `LayoutBox` buffers.
- Matrix and array layout now records emitted cell ranges and translates them in
  place, removing per-cell scratch `LayoutBox` buffers from the math layout path.
- Math-list child layout now computes binary-operator reclassification without a
  per-call atom-class vector on normal `Vector{Node}` paths.
- Developer documentation now describes the unified per-case stress-test suite,
  `stress_test_reference.tar` workflow, visual-only full sheets, optional
  CairoMakie stress cases, and root `justfile` helpers.
- Developer documentation now reflects the math flat-layout range-emission
  refactor, including in-place sub-range translation and order-insensitive
  snapshot normalization.
- Document composition now uses an internal measured box-tree layer behind the
  existing `TeXBox`, `hconcat`, and `vstack` compatibility surface.
- Internal renderer/debug tooling now resolves `Glyph.font_slot` paths through a
  shared `_font_path_for_slot` helper, keeping text-slot fallback behaviour
  consistent across tools and documentation examples.
- Internal box-tree constructors now validate finite non-negative dimensions,
  copy caller-owned vectors, and reject malformed `VBox` child/offset arrays at
  construction time.
- Renamed the agent/developer guide to `AGENTS.md`; `CLAUDE.md` is retained as a
  compatibility symlink.

### Fixed
- Makie rendering of mixed text/math `LaTeXString`s now resolves document text
  glyphs through the correct regular/bold/italic/bold-italic font slot fallback
  instead of always using the regular face, so `\textbf` and nested text styles
  render with the intended text font. The adapter also preserves represented
  characters for standard glyph names such as `space` and `Lambda`, improving
  Makie's text measurement and wrapping for mixed text/math labels.
- `\sqrt[n]{x}` now lays out the root index using the OpenType MATH radical
  degree kern and bottom-raise constants instead of silently ignoring the
  parsed degree.
- `align` / `aligned` cells after `&` now include the ordinary atom needed for
  TeX-style relation spacing before a leading relation such as `=`.
- `align` / `aligned` no longer insert inter-column `\arraycolsep` within an
  `r`/`l` pair, so the gap before a leading relation comes solely from the
  relation atom (matching plain math) instead of being doubled up; the grid also
  carries no outer column margin.
- Blank lines in document input now create paragraph breaks with configurable
  `parskip` vertical spacing.
- `layout_document` now applies display skips as explicit extra vertical space
  instead of synthetic empty baselines, so a display-only document starts at the
  first real display baseline.
- `\textsf` and `\texttt` in document text now use the v1 regular-slot fallback
  instead of inheriting surrounding bold/italic state.
- FreeType visualisation tools now compare `Glyph.font_slot` against `FontSlot`
  enum values instead of stale symbol values when choosing text fonts.
- `tools/stress_test_all.jl` now delegates to the unified per-case stress-test
  suite while preserving the old font-name argument form.
- `tools/stress_test_freetype.jl` section/title headers now resolve characters by
  codepoint (cmap) instead of by PostScript glyph name, so headings render on
  fonts with non-AGL glyph names (e.g. FiraMath, Luciole) instead of `.notdef`
  boxes. Header glyphs are also now placed on a common baseline instead of being
  individually vertically centred.
- `tools/visualise_metrics_makie.jl` now imports `Makie` via `CairoMakie.Makie`
  so it loads without `Makie` being a direct dependency of the tools project.
- Document input now recognises `$$…$$` and `\[…\]` as display-math blocks and
  `\(…\)` as inline math. Previously `$$…$$` was mis-parsed as two empty inline
  toggles with the body leaking into text, and `\[…\]` / `\(…\)` were dropped.
- `^`, `_`, and `&` in document text mode now render as literal characters instead
  of being silently dropped (so `x^2` outside math no longer becomes `x2`).

## [v0.1.1] - 2026-06-19

### Added
- `\binom`, `\dbinom`, `\tbinom` via `NKGenfrac` with auto-sized parenthesis delimiters and
  TeX Rule 15c no-rule gap clamping
- Manual delimiter sizing via `\bigl`/`\bigr`/`\Bigl`/`\Bigr`/`\biggl`/`\biggr`/`\Biggl`/`\Biggr`
  and `\bigm`/`\big` families (`NKBigDelim`; 4 size tiers; 16 commands + null delimiter support)

### Changed
- Tools overhaul: unified project environment, callable stress-test module, PPM image comparison

### Fixed
- Raw-string backslash parsing bug; added TEX fallback command definitions
- Section-header overlap in `stress_test_makie.jl`
- Glyph assembly (`\left`/`\right`/`\middle` extensible delimiters) now sizes to
  `required_du` instead of using minimum overlaps (maximum height): fixes STIX Two
  `\middle|` visibly exceeding `\langle`/`\rangle` height because the bar has only
  one pre-built variant and the assembly was rounding up to the next extender multiple
- Greek lowercase letters remapped to the math-italic Unicode block in default math mode

## [0.1.0] - 2026-05-28

Initial public release.

### Added
- Core typesetting pipeline: LaTeX string → token stream → AST → `Vector{LayoutBox}`
  (em-unit coordinate system, origin at formula baseline)
- OpenType MATH table parser (`math_table.jl`) with per-font caching; all metric constants
  (axis height, script shifts, fraction gaps, rule thicknesses, …) read directly from the font
- `FontFamily` type with artifact-backed font lookup; 8 bundled families: NewCMMath, Pagella,
  Termes, Schola, Bonum, Luciole, STIX Two, FiraMath
- `default_font_family()` / `set_default_font_family!()` API for session-wide font selection
- Fractions (`\frac`, `\dfrac`, `\tfrac`) with TeX Rule 15d/15e gap clamping
- Square roots (`\sqrt`, `\sqrt[n]`) using pre-built MATH variants and extensible assembly
- Sub/superscripts with italic correction for slanted single-glyph bases (e.g. `\int`),
  matching KaTeX `supsub.ts` behaviour
- Limits placement for large operators in Display style; `\limits`/`\nolimits` overrides
- Named math operators (`\sin`, `\cos`, `\lim`, `\limsup`, …; 27 operators)
- Large operators (`\sum`, `\prod`, `\int`, …) with display-size variant selected via
  `display_operator_min_height` from the MATH table
- Inter-atom spacing following the full TeX atom-class table
  (ord/bin/rel/op/open/close/punct/inner)
- Auto-sized delimiters via `\left`/`\right` with extensible glyph assembly centred on the
  math axis; `\middle` auto-sized to match the enclosing `\left`/`\right` pair
- Font switching (`\mathbf`, `\mathrm`, `\mathbb`, `\mathit`, `\mathcal`, `\mathfrak`,
  `\mathsf`, `\mathtt`, `\boldsymbol`) via Unicode math-variant codepoints
- Style switches (`\displaystyle`, `\textstyle`, `\scriptstyle`, `\scriptscriptstyle`)
- Font sizing commands (`\tiny` through `\Huge`; 10 levels)
- Non-stretchy accents (`\hat`, `\bar`, `\vec`, `\tilde`, `\dot`, `\ddot`, `\breve`,
  `\check`, `\acute`, `\grave`, `\mathring`; 11 commands) with `MathTopAccentAttachment`
  centering
- `\overline` and `\underline` (TeX Rules 9 & 10; gap and thickness from MATH table)
- Extensible horizontal accents (`\widehat`, `\widetilde`) with variant selection and
  extensible assembly from `horiz_constructions`
- Horizontal braces (`\overbrace`, `\underbrace`, `\overbracket`, `\underbracket`,
  `\overparen`, `\underparen`) with limits-style note placement
- Extensible arrows (`\xrightarrow`, `\xleftarrow`, and 16 further commands); arrow
  stretched to cover labels with 0.111 em clearance
- `\text{}` / `\mbox{}` for upright text fragments within math, with space preservation
- Explicit horizontal spacing (`\,`, `\:`, `\;`, `\!`, `\quad`, `\qquad`, `\kern`,
  `\mkern`, `\hskip`, `\mskip`; negative spaces supported)
- Array/matrix environments: `matrix`, `pmatrix`, `bmatrix`, `vmatrix`, `Vmatrix`,
  `smallmatrix`, `cases`, and `\begin{array}{colspec}` with per-column l/c/r alignment
  and single/double (`||`) vertical rules
- Makie integration via `MathTeXEngineExt.jl` package extension — drop-in replacement for
  MathTeXEngine.jl when `TeXLayout`, `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings`
  are all loaded
- Rendering and visualisation tools: `visualise_bitmap.jl`, `visualise_svg.jl`,
  `visualise_spacing.jl`, `visualise_metrics.jl`, `visualise_metrics_makie.jl`,
  `demo_sheet.jl`, `stress_test_sheet.jl`, `png_diff.jl`, and others
- CI workflow with Runic formatting enforcement and Dependabot for GitHub Actions and
  Julia packages

[Unreleased]: https://github.com/dawbarton/TeXLayout.jl/compare/v0.3.0...HEAD
[v0.3.0]: https://github.com/dawbarton/TeXLayout.jl/compare/v0.2.3...v0.3.0
[v0.2.3]: https://github.com/dawbarton/TeXLayout.jl/compare/v0.2.2...v0.2.3
[0.1.0]: https://github.com/dawbarton/TeXLayout.jl/commit/ec8d72d5d8da6eac7f0532438064ab9fd5ae5568
