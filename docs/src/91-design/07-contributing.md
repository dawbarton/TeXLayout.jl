# Extending and testing

## Adding a command

**A symbol** (such as `\hbar` or a new Unicode math symbol) needs two table
entries and no parser change, since an unknown command already parses as a
`NodeKind.Command` leaf:

```julia
# src/tables/layout_symbols.jl, in _SYMBOL_CODEPOINTS
"hbar" => 0x210F,    # ℏ PLANCK CONSTANT OVER TWO PI

# src/tables/layout_atoms.jl, in _CMD_ATOM_CLASS (omit for :ord)
"hbar" => :ord,
```

Add a test in the matching `test/test_layout_*.jl` file.  A symbol without a
single Unicode codepoint (a base character plus U+0338, say) cannot go in
`_SYMBOL_CODEPOINTS`; see
[`future.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/future.md).

**A construct** (a new environment, extensible, or command with arguments):

1. Add a `NodeKind` value in `src/enums.jl` if no existing kind fits, and a
   payload type in `src/payloads.jl` if it needs structured data.
2. Parse it in `_parse_command!` (or a sub-parser) in `src/parser.jl`, with its
   command table in `src/tables/parser_tables.jl`.
3. Lay it out in a `_layout_xxx!` helper in the matching file under
   `src/layout/`, and add a branch to `_layout_node!` and, if its class is not
   Ord, to `_atom_class`.  Both fall back silently (no glyphs, class Ord), so a
   missing branch shows up only in tests.
4. Test the AST in `test/test_parser.jl`, the geometry in a `test/test_layout_*`
   file, and a KaTeX analogue, if there is one, in `test/test_katex.jl`.  Add
   stress cases to `tools/stress_test_content.jl`, and check the result against
   LuaLaTeX (below).
5. Record the rule in
   [`katex_rules.md`](https://github.com/dawbarton/TeXLayout.jl/blob/main/katex_rules.md).

## Adding a font family

1. Collect the math font, which must have a MATH table, and any companion text
   faces.
2. Run `julia tools/prepare_font_artifacts.jl <output_dir>`, which builds the
   tarball and prints a draft `Artifacts.toml` stanza.  Check its `git-tree-sha1`
   and `sha256` against the tarball and add it to `Artifacts.toml`.
3. In `src/fonts.jl`, add an `@artifact_str` accessor and an entry in
   `_ARTIFACT_LOADERS`.
4. Add the family to the font table in `docs/src/02-fonts.md`, and to
   `ALL_FONTS` in `tools/stress_test_suite.jl`.
5. Run the tests and the stress suite with it: glyph names, missing constants,
   and missing symbols vary between fonts.

## Tests

```
julia --project=. -e 'using Pkg; Pkg.test()'                                  # everything
julia --project=. -e 'using Pkg; Pkg.test(test_args = ["layout_scripts"])'    # files whose names contain an argument
julia --project=. test/runtests.jl text_white                                 # without the weak dependencies
```

`Pkg.test()` includes HarfBuzz_jll and Makie from `[extras]`, so the HarfBuzz
and Makie extension tests run.  Running `test/runtests.jl` directly loads neither
and must still pass with those tests skipped; use it to check that the core
`MetricShaper` path stands alone.

| File | Covers |
|:-----|:-------|
| `test_math_table.jl`, `test_metrics.jl` | MATH table parsing and glyph metrics against the fixture constants |
| `test_style.jl`, `test_lexer.jl`, `test_parser.jl` | Style transitions, tokens, and AST structure, including ill-formed input |
| `test_layout_core.jl` | Characters, operator names, italic correction, inter-atom spacing, explicit spaces, style and size switches |
| `test_layout_scripts.jl` | Scripts and `ssty` alternates |
| `test_layout_fractions.jl` | Fractions, radicals, and binomials |
| `test_layout_delimiters.jl` | `\left…\right`, assemblies, and `\big` |
| `test_layout_operators.jl` | Large operators, limits, `\bmod` and friends, `\mathchoice` |
| `test_layout_alphabets.jl` | Math alphabets, font slots, Greek, and `\text{…}` |
| `test_layout_accents.jl` | Accents, `\overline`, and horizontal braces |
| `test_layout_matrices.jl` | Matrices, arrays, and alignments against LaTeX + amsmath |
| `test_layout_extensibles.jl` | Extensible arrows and horizontal assemblies |
| `test_katex.jl` | KaTeX-derived cases, malformed input, deep nesting |
| `test_text_*.jl` | Shaping, the document parser, composition, and whitespace |
| `test_makie_extension.jl` | The Makie adapters |
| `test_snapshots.jl` | Layout-equivalence hashes |
| `test_threads.jl` | Concurrent layout in a four-thread child process |

The fixture font is `NewCMMath-Regular.otf`, with ground-truth constants from
fonttools in `test/fixtures/newcm_math.jl`.  Shared helpers (`find_glyphs`,
`find_spaces`, …) are in `test/helpers.jl`.  KaTeX-derived tests cite the KaTeX
file and line they come from.

`test_makie_extension.jl` follows the installed Makie: with 0.25 it drives
`TeXLayoutHandler` through real `text!` calls and `Makie.layout_text`, and with
0.24 it checks the legacy adapter.  Protocol assertions use `Makie.layout_text`
rather than `Text` compute-graph node names, which changed when
[MakieOrg/Makie.jl#5717](https://github.com/MakieOrg/Makie.jl/pull/5717) merged.
Until Makie 0.25 is released the main CI matrix runs 0.24, and the experimental,
`continue-on-error` `makie-0-25` job develops Makie's `ff/breaking-0.25` branch
into a scratch environment and runs the suite there.

`test_snapshots.jl` guards against unintended layout changes.  It hashes
normalised layout output (glyph names, font slots, metrics, rules, positions,
scales, and document extents), with the box records sorted so that append order
does not count.  A changed hash means changed geometry or changed normalisation:
inspect the difference, and say whether it is an intended fix or feature, before
updating the hash.

## Stress references

`tools/stress_test_suite.jl` is the image regression tool.  It writes one PNG
per case under `stress_outputs/current/<font>/<suite>/<section>/<case>.png` for
the suites `math_freetype`, `text_freetype`, and, with `--include-makie`,
`makie_cairo` (slower, as it loads CairoMakie; use it before changing the Makie
adapters).

```
julia --project=tools tools/stress_test_suite.jl generate --out stress_outputs/current
julia --project=tools tools/stress_test_suite.jl pack --input stress_outputs/current --out stress_test_reference.tar
julia --project=tools tools/stress_test_suite.jl compare --current stress_outputs/current --reference stress_test_reference.tar
```

`all` generates, fetches a reference (a local path or URL; by default the
`stress_test_reference.tar` asset of the `v0.4.0-stress` release), and compares.
Whole-font sheets under each font's `sheets/` folder are for looking at and are
not compared.  New cases are reported as `NEW` and do not fail the comparison
unless `--fail-on-new` is given; missing, changed, or unreadable images do.

## Tools

The tools share one environment (`tools/Project.toml`), so run them as
`julia --project=tools tools/<script>.jl`.  The FreeType renderers draw through
`tools/common.jl`, which resolves glyphs as the renderer adapters do.

| Script | Purpose |
|:-------|:--------|
| `visualise_bitmap.jl` | FreeType render of one expression: the first check after changing layout |
| `visualise_metrics.jl` | Metric overlay: left bearing, advance gap, ink above and below the baseline, baseline and axis |
| `visualise_metrics_makie.jl` | The same overlay drawn with CairoMakie `text!` |
| `visualise_text.jl` | FreeType render of a mixed text and math string |
| `compare_tex.jl` | TeXLayout's boxes over LuaLaTeX or XeLaTeX output with the same fonts |
| `stress_test_freetype.jl`, `stress_test_text.jl`, `stress_test_makie.jl` | Whole-font math, document, and CairoMakie sheets |
| `stress_test_latex.jl` | A `.tex` version of the math sheet (no OpenType math font, so not for geometry) |
| `stress_test_suite.jl` | The per-case image regression suite |
| `stress_test_content.jl` | The math stress cases (a library, not a script) |
| `prepare_font_artifacts.jl` | Build font artifacts and draft `Artifacts.toml` stanzas |

The root `justfile` has shortcuts (`just` lists them): `test`;
`stress-generate`, with the variants `-no-sheets`, `-makie`, and `-font <name>`;
`stress-reference-generate`, which packs a fresh reference;
`stress-reference-compare`, which downloads the release reference if needed and
compares against it; `compare-tex <args>`; and `stress-clean`.

## Comparing against TeX

`tools/compare_tex.jl` checks geometry against a TeX engine.  It typesets each
expression with unicode-math and the bundled font files, then draws TeXLayout's
boxes into the same PDF glyph by glyph: cyan is TeX, magenta TeXLayout, and dark
where they agree.  Prefixes select Text (`T:`) or Script (`S:`) style, and
`B:{num}{den}` compares a binomial without its delimiters with `{num \atop den}`,
isolating the vertical shifts.

- **LuaLaTeX is the reference.**  It implements OpenType MATH directly:
  `SpaceAfterScript` after scripts, the Stack constants for rule-less fractions,
  and radical degrees measured from the bottom of the sign.  Where LuaTeX and
  XeTeX differ, follow LuaTeX and record the difference in `katex_rules.md`.  The
  one recorded exception: LuaTeX adds a `\left` delimiter variant's italic
  correction to its width and XeTeX does not; TeXLayout follows XeTeX.
- **Compare at 10 pt when scripts are involved.**  TeXLayout always uses `ssty`
  alternates, as unicode-math does at normal sizes, but unicode-math did not
  apply them at 24.88 pt or 60 pt in our measurements.  The tool's default is
  24 pt, so pass `--size=10` for scripts, primes, radical degrees, and
  `smallmatrix`.
- **XeLaTeX differs in known ways.**  It puts `\scriptspace` (0.5 pt in LaTeX)
  after scripts, which the tool replaces with the font's `SpaceAfterScript`; it
  keeps the Fraction shifts for rule-less fractions except `num3`; and
  unicode-math raises radical degrees by p × (height − depth) of the radical box.
- **Display mode is not display style.**  `$\displaystyle …$` is still inline
  mode, so amsmath's `\if@display` (used by `\pmod` and friends) is false; the
  tool sets `\@displaytrue` for Display-style cases.
- **Known residual differences**, not caused by the change under test: TeXLayout
  has no OpenType math kerning (`MathKernInfo`) between a base and its scripts;
  unicode-math's `\mathbf` uses the bold text font, where TeXLayout uses the
  Unicode math alphabet; and LaTeX adds an italic correction after `\textit{…}`.
- **Hand measurements.**  For a number the overlay cannot give (a box's height or
  depth, an array's struts), typeset `\setbox0\hbox{$…$}` and
  `\typeout{\the\wd0\space\the\ht0\space\the\dp0}` at 10 pt (10 pt = 1 em) with
  amsmath and unicode-math, loading the bundled font by path as the tool does:
  `\setmathfont{<file>.otf}[Path=<artifact dir>/]`.  Given a bare file name,
  TinyTeX may silently fall back to Latin Modern Math, so check the log for "not
  loadable" before trusting a number.

`compare_tex.jl` needs `lualatex` or `xelatex` with unicode-math, fontspec,
mathtools, extarrows, TikZ, and the `standalone` class, and ImageMagick for the
PNGs.

## Formatting

Format Julia code with [Runic](https://github.com/fredrikekre/Runic.jl): run
`runic --inplace <files>` from the repository root (Runic is also installed in
the global `@runic` environment).  CI checks the format.

## Benchmarks

`benchmark/runbenchmarks.jl` times tokenizing, parsing, layout, and document
layout for a fixed set of cases.  A quick smoke run while refactoring:

```
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/runbenchmarks.jl --seconds=0.05 --samples=2 --output=/tmp/texlayout-bench-smoke.toml
```

For a performance-sensitive change, compare against a baseline with the default,
longer settings:

```
julia --project=benchmark benchmark/runbenchmarks.jl --update-baseline
julia --project=benchmark benchmark/runbenchmarks.jl --baseline=benchmark/baseline.toml
```

The thresholds are `--time-threshold=1.15` and `--allocation-threshold=1.20`.
Treat sub-microsecond differences as noise unless a longer run confirms them, and
on a busy machine interleave the baseline and candidate runs; changes in
allocations or memory are usually more telling than timings.
