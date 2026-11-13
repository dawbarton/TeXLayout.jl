# TeXLayout.jl: guide for agents and developers

This file holds what every change needs: where things are, the invariants that
must hold, and the working rules.  How TeXLayout works (pipeline, data
structures, algorithms, adapters) is in the design documentation; read the page
for the area you are changing before you change it.

## Purpose

TeXLayout.jl is an OpenType-aware LaTeX math typesetter in Julia, intended as a
drop-in replacement for MathTeXEngine.jl in Makie.  Its design reference is
[KaTeX](https://katex.org/), followed where it is sound rather than ported; its
geometry reference is LuaLaTeX with unicode-math and the same font files.

## Where things are

- `src/`: the pipeline `tokenize` → `parse_latex` → `layout` →
  `Vector{LayoutBox}` (`lexer.jl`, `parser.jl`, `ast.jl`, `payloads.jl`,
  `layout.jl`, `src/layout/`), fonts and the MATH table (`fonts.jl`,
  `math_table.jl`), the text and document layer (`shaping.jl`, `document.jl`,
  `boxes.jl`, `compose.jl`), lookup tables (`src/tables/`), and what the
  renderer adapters share (`render_support.jl`).
- `ext/`: `MakieExt.jl` (the Makie 0.25 text handler), `MathTeXEngineExt.jl`
  (Makie 0.24), and `HarfBuzzExt.jl` (`HarfBuzzShaper`).
- `test/`: one file per area, listed in `runtests.jl`; shared helpers in
  `helpers.jl`.
- `tools/`: visualisers, the stress suite, and `compare_tex.jl`, with shared
  helpers in `tools/common.jl`; run as `julia --project=tools tools/<script>.jl`.
- `docs/src/91-design/`: the design documentation.
  - `01-overview.md`: pipeline, source map, caches, thread safety, invariants.
  - `02-parsing.md`: lexer, parser, AST, and node payloads.
  - `03-layout.md`: layout context, output types, spacing, styles, and every
    construct.
  - `04-fonts.md`: font families, glyph lookup, and the MATH table.
  - `05-text.md`: documents, whitespace, shaping, and composition.
  - `06-renderers.md`: the Makie and MathTeXEngine adapters and their contracts.
  - `07-contributing.md`: adding commands and fonts, tests, stress references,
    tools, comparing against TeX, and benchmarks.
- `katex_rules.md`: the TeX rule behind each construct, the MATH constants it
  reads, and deviations from KaTeX.
- `future.md`: the single list of known limitations and planned work.
- `notes.md`: cross-session engineering notes (see Note taking below).
- `external/`: read-only source references (KaTeX, Makie, MathTeXEngine), not
  part of the package.

## Invariants

These hold everywhere; `01-overview.md` explains each.

1. **The `TokenKind.EOF` sentinel is never consumed.**  Every parser loop checks
   for it before calling a sub-parser.
2. **The parser never throws** on ill-formed input, and layout accepts any tree
   it produces.
3. **Metric constants come from the MATH table**, never hard-coded; the only
   fixed lengths are TeX's and LaTeX's own (`src/tables/`).
4. **Glyphs are found by Unicode codepoint**, not PostScript name; names differ
   between fonts.  Names are used only where the font keys data by name (MATH
   constructions, italic corrections, accent attachments, `ssty` alternates).
5. **Math layout emits by range.**  A helper measures and moves only the box
   ranges it has just emitted (`_translate_range!`); append order is not paint
   order.
6. **Structured AST data lives in `Node.payload`** (typed payloads in
   `payloads.jl`); never pack fields into `Node.value`.
7. **Caches are locked and FreeType calls hold the face's `FTFont.lock`.**  Use
   `_load_glyph_metrics` and `_char_index` rather than calling FreeType directly.
8. **Exports stay minimal.**  `NodeKind`, `TokenKind`, and the other enums are
   internal; a name can be made public later, but not withdrawn.

## Working rules

- **Format** every touched Julia file with Runic: `runic --inplace <files>`
  (also in the global `@runic` environment).  CI checks it.
- **Changelog.**  Record every user-visible change (feature, fix, removal, or
  breaking change) in the `[Unreleased]` section of `CHANGELOG.md` when you make
  it, under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`
  ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)).  At a release the
  section is retitled with the version and date, and a new `[Unreleased]` opened.
- **Tests.**  Run `julia --project=. -e 'using Pkg; Pkg.test()'`; pass
  `test_args = ["layout_scripts"]` (any substring of file names) to run part of
  it.  `julia --project=. test/runtests.jl` runs without the weak dependencies
  and must still pass with the extension tests skipped.
- **Snapshots.**  Never update a hash in `test/test_snapshots.jl` without
  inspecting the layout difference and saying whether it is an intended fix or
  feature.
- **Stress images.**  After any change to layout or rendering, generate the
  stress suite and compare it against the reference
  (`tools/stress_test_suite.jl`, see `07-contributing.md`), and look at every
  changed or new image.  Add `--include-makie` before changing the Makie
  adapters.
- **Makie 0.25.**  After any change to the handler, check the experimental
  `makie-0-25` CI job; it is `continue-on-error`, so it does not fail CI.
- **Claims that a result matches TeX** need `tools/compare_tex.jl` against
  LuaLaTeX, at `--size=10` when scripts are involved; the caveats are in
  `07-contributing.md`.
- **Performance-sensitive changes** are compared against a baseline with
  `benchmark/runbenchmarks.jl`.
- **One home per fact.**  When a change alters something the design
  documentation describes, update that page; limitations go in `future.md` and
  TeX rules in `katex_rules.md`, not here.

## Note taking

Take notes incrementally during a session at natural breakpoints (end of a discussion phase, after a plan is agreed, after a significant result). Do not wait until the end of the session. Add notes to the end of `notes.md` in the project root using the section heading:

```
## <ISO datetime> <descriptive title>
```

followed by bullet points covering key ideas, decisions, results, and open questions. Include references to external sources where relevant. Keep notes concise and high-signal; this is cross-session context, not a transcript. Ensure the correct ISO datetime is used by calling `date -Iminutes` with Bash.
