# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `\binom`, `\dbinom`, `\tbinom` via `NKGenfrac` with auto-sized parenthesis delimiters and
  TeX Rule 15c no-rule gap clamping
- Manual delimiter sizing via `\bigl`/`\bigr`/`\Bigl`/`\Bigr`/`\biggl`/`\biggr`/`\Biggl`/`\Biggr`
  and `\bigm`/`\big` families (`NKBigDelim`; 4 size tiers; 16 commands + null delimiter support)

### Changed
- Greek lowercase letters remapped to the math-italic Unicode block in default math mode
- Tools overhaul: unified project environment, callable stress-test module, PPM image comparison

### Fixed
- Raw-string backslash parsing bug; added TEX fallback command definitions
- Section-header overlap in `stress_test_makie.jl`

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

[Unreleased]: https://github.com/dawbarton/TeXLayout.jl/compare/ec8d72d5d8da6eac7f0532438064ab9fd5ae5568...HEAD
[0.1.0]: https://github.com/dawbarton/TeXLayout.jl/commit/ec8d72d5d8da6eac7f0532438064ab9fd5ae5568
