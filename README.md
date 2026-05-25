# TeXLayout.jl

A Julia-idiomatic OpenType-aware LaTeX math typesetter, designed for use
with [Makie.jl](https://github.com/MakieOrg/Makie.jl).

## Overview

TeXLayout.jl converts LaTeX math strings into a flat list of positioned glyph elements
that a renderer (e.g. CairoMakie or GLMakie) can consume directly.  The pipeline is:

```
tokenize → parse_latex → layout → Vector{LayoutBox}
```

Each `LayoutBox` carries a `TeXElement` (glyph, rule, or space), a 2-D position in em
units relative to the formula baseline, and a scale factor.

## Key features

- Full TeX style cascade (Display / Text / Script / ScriptScript, each with a cramped
  variant), driven entirely by the font's OpenType MATH table — no hard-coded constants.
- Correct sub/superscript placement, fractions, radicals, and auto-sized delimiters.
  Italic correction applied to subscripts on slanted bases (e.g. `\int`) to track the stroke.
- Named math operators (`\sin`, `\cos`, `\lim`, `\operatorname{…}`, and 25 others)
  rendered upright using the companion regular font or the math font's codepoint mapping.
- Inter-atom spacing (TeX atom-class table: ord/bin/rel/op/open/close/punct/inner).
- `\text{…}` and `\mbox{…}`: upright (regular-font) glyphs with word spacing;
  classified as ordinary atoms for correct inter-atom spacing at the boundary
  with adjacent math.
- Accents (`\hat`, `\bar`, `\vec`, `\widehat`, `\widetilde`, `\overline`, `\underbrace`, …).
- Font switching (`\mathbf`, `\mathrm`, `\mathbb`, `\mathcal`, `\mathfrak`, `\mathtt`, …).
- Array and matrix environments: `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`,
  `Vmatrix`, `smallmatrix`, `cases`, and `\begin{array}{colspec}` with per-column
  `l`/`c`/`r` alignment and single/double vertical rules (`|` / `||`).
- Eight bundled font families, downloaded lazily via Julia Artifacts on first use.
- Lenient parser: never throws on ill-formed input; unknown commands produce inert
  `NKCommand` leaf nodes that are silently skipped by the layout engine.

## Makie integration

When both `TeXLayout` and `MathTeXEngine` are loaded in the same Julia session,
TeXLayout automatically activates a package extension (`MathTeXEngineExt`) that
replaces MathTeXEngine's layout engine with TeXLayout's.  No other code changes
are required — LaTeX strings passed to `text!` in CairoMakie or GLMakie are
rendered using TeXLayout's OpenType-aware pipeline.

```julia
using TeXLayout       # activates MathTeXEngineExt automatically
using CairoMakie, LaTeXStrings

fig = Figure()
ax  = Axis(fig[1,1])
text!(ax, 0.5, 0.5; text=L"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
      fontsize=32, align=(:center, :center))
save("output.png", fig)
```

To use a different font for all math rendering (including via Makie), call
`set_default_font_family!` before loading CairoMakie or GLMakie:

```julia
using TeXLayout
set_default_font_family!(:stix_two)   # or any other bundled symbol / FontFamily

using CairoMakie, LaTeXStrings
# All L"…" strings are now rendered with STIX Two Math.
```

For a consistent appearance, set Makie's text fonts to the same files that
TeXLayout uses for math.  `default_font_family()` returns the font paths for
the active font family, so passing those paths to `set_theme!` makes axis
labels, tick labels, and titles share the same typeface as the math rendering:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

ff = default_font_family()   # whichever family is currently active

set_theme!(fonts = (;
    regular    = ff.regular,
    bold       = ff.bold,
    italic     = ff.italic,
    bolditalic = ff.bolditalic,
))

fig = Figure(size = (800, 500))
ax  = Axis(fig[1, 1]; xlabel = L"x", ylabel = L"f(x)")
x   = LinRange(0, 2π, 400)
lines!(ax, x, sin.(x); label = L"\sin(x)")
lines!(ax, x, exp.(-x/4).*sin.(3x); label = L"e^{-x/4}\sin(3x)")
axislegend(ax)
save("output.png", fig)
```

> **Note:** The extension works by adding a specialised
> `MathTeXEngine.generate_tex_elements(::LaTeXString)` method from within a
> package that owns neither the function nor the argument type — a form of
> [type piracy](https://docs.julialang.org/en/v1/manual/style-guide/#Avoid-type-piracy).
> This is pragmatic but not ideal.  Alternative integration strategies that avoid
> type piracy (e.g. a dedicated Makie recipe or a proper upstream extension point)
> will be investigated in future.

## Usage

```julia
using TeXLayout

# Lay out a formula with the default font (New Computer Modern Math).
boxes = generate_tex_elements(raw"\frac{1}{\sqrt{2}}")

# boxes is a Vector{LayoutBox}; each box carries:
#   .element  — a Glyph, HRule, VRule, or Space value
#   .x, .y    — baseline-relative position in em units
#   .scale    — font-size multiplier (1.0 for Display/Text, 0.7 for Script, …)
```

### Choosing a font family

Eight bundled font families are available, downloaded lazily via Julia Artifacts
on first use.  Pass a `FontFamily` as the second argument to `generate_tex_elements`,
or call `set_default_font_family!` once at start-up to change the default used by
all subsequent calls (including the Makie extension):

```julia
# Select by symbol — font files are downloaded automatically on first use.
#   :new_cm    — New Computer Modern (default)
#   :pagella   — TeX Gyre Pagella (Palatino style)
#   :termes    — TeX Gyre Termes Math (Times style)
#   :schola    — TeX Gyre Schola Math (New Century Schoolbook style)
#   :bonum     — TeX Gyre Bonum Math (Bookman style)
#   :luciole   — Luciole Math (designed for low vision)
#   :stix_two  — STIX Two Math (Times style)
#   :fira_math — Fira Math + Fira Sans (sans-serif)

# Change the session-wide default (affects Makie integration too):
set_default_font_family!(:stix_two)

# Or pass a FontFamily explicitly for a single call:
family = font_family(:pagella)
boxes  = generate_tex_elements(raw"\int_0^\infty e^{-x}\,dx", family)

# Supply your own OpenType math font:
family = font_family("/path/to/MyMath.otf"; regular="/path/to/MyText.otf")
```

### Lower-level pipeline

`generate_tex_elements` is a convenience wrapper.  The individual pipeline stages
are also exported for advanced use:

```julia
using TeXLayout

node  = parse_latex(raw"\sum_{k=0}^{n} k^2")  # → Node (AST)
boxes = layout(node, default_font_family(), TeXLayout.Display)  # → Vector{LayoutBox}
```

## API reference

The public API is intentionally small.  All other names (lexer tokens, parser node
kinds, style helpers, MATH-table types, glyph-metric functions) are accessible as
`TeXLayout.Xxx` or via explicit `using TeXLayout: name` imports but are not
exported.

| Name | Kind | Description |
|:-----|:-----|:------------|
| `FontFamily` | type | Holds file paths for the math, regular, italic, bold, and bold-italic font roles |
| `font_family` | function | Construct a `FontFamily` from a symbol (`:new_cm`, `:stix_two`, …) or an OTF path |
| `default_font_family` | function | Return the current session-wide default `FontFamily` |
| `set_default_font_family!` | function | Override the session-wide default; accepts a `Symbol` or a `FontFamily` |
| `TexStyle` | enum type | The eight TeX style levels (`TeXLayout.Display`, `TeXLayout.Text`, …) |
| `parse_latex` | function | Tokenise and parse a LaTeX math string into a `Node` AST |
| `layout` | function | Lay out a `Node` into a `Vector{LayoutBox}` given a `FontFamily` and `TexStyle` |
| `generate_tex_elements` | function | Convenience: `parse_latex` + `layout` in one call |
| `LayoutBox` | struct | A positioned element: `.element`, `.x`, `.y`, `.scale` |
| `TeXElement` | union type | Union of `Glyph`, `HRule`, `VRule`, `Space` |
| `Glyph` | struct | A single rendered glyph, identified by PostScript name and font role |
| `HRule` | struct | A horizontal rule (fraction bar, radical bar, …) |
| `VRule` | struct | A vertical rule (array column separator) |
| `Space` | struct | Explicit horizontal white space |

## Status

Early development (v0.1).  The following features are not yet implemented:

- Type-piracy-free Makie integration (current approach is functional but uses a specialised method on types owned by other packages; see note above).

## Acknowledgements

TeXLayout.jl draws heavily on the following prior work:

- **[KaTeX](https://katex.org/)** (MIT licence) — the primary reference for algorithm
  design, TeX style cascade rules, operator lists, and test cases.  The screenshotter
  expressions in `test/test_katex.jl` are derived from KaTeX's `ss_data.yaml`,
  `katex-spec.ts`, and `errors-spec.ts`.
- **[MathTeXEngine.jl](https://github.com/Kolaru/MathTeXEngine.jl)** (MIT licence) — an
  earlier Julia implementation of LaTeX rendering for Makie; informed the overall
  architecture and the `LayoutBox` interface consumed by Makie's glyph collection.
- **[The TeXbook](https://www.amazon.co.uk/TeXbook-Donald-Knuth/dp/0201134489)** by
  Donald E. Knuth — the authoritative reference for TeX's box-and-glue model, style
  cascade, and atom spacing rules.
- **OpenType MATH specification** (part of the
  [OpenType spec](https://docs.microsoft.com/en-us/typography/opentype/spec/math)) — the
  source of truth for all metric constants (axis height, script shifts, fraction
  parameters, radical gaps, etc.).

### Bundled fonts

All eight font families are redistributed under their respective open licences.  Each tarball includes the relevant licence file.

| Symbol | Font | Authors | Licence |
|:-------|:-----|:--------|:--------|
| `:new_cm` | [New Computer Modern](https://ctan.org/pkg/newcomputermodern) | Antonis Tsolomitis (University of the Aegean) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:pagella` | [TeX Gyre Pagella Math](https://ctan.org/pkg/tex-gyre-math-pagella) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:luciole` | [Luciole](https://luciole-vision.com/) | Daniel Flipo and [typographies.fr](https://typographies.fr/), in collaboration with [Centre de Ressources Handicap Visuel](https://crhv.fr/) de Lyon; with support from DIPHE/Université Lumière Lyon 2, GUTenberg, Swiss Ceres Foundation, PEP69 | Math font: [SIL OFL 1.1](https://openfontlicense.org); text fonts: [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `:stix_two` | [STIX Two Math](https://github.com/stipub/stixfonts) v2.0.2 | The STIX Fonts Project Authors; STIX Fonts™ is a trademark of the [Institute of Electrical and Electronics Engineers](https://www.ieee.org/) | [SIL OFL 1.1](https://openfontlicense.org) (Reserved Font Name "TM Math") |
| `:fira_math` | [Fira Math](https://github.com/firamath/firamath) v0.3.4 + [Fira Sans](https://github.com/mozilla/Fira) | Fira Math: Xiangdong Zeng; Fira Sans: Mozilla and Telefonica S.A. | [SIL OFL 1.1](https://openfontlicense.org) |
| `:schola` | [TeX Gyre Schola Math](https://ctan.org/pkg/tex-gyre-math-schola) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:termes` | [TeX Gyre Termes Math](https://ctan.org/pkg/tex-gyre-math-termes) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:bonum` | [TeX Gyre Bonum Math](https://ctan.org/pkg/tex-gyre-math-bonum) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
