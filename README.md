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
- Accents (`\hat`, `\bar`, `\vec`, `\widehat`, `\widetilde`, `\overline`, `\underbrace`, …).
- Font switching (`\mathbf`, `\mathrm`, `\mathbb`, `\mathcal`, `\mathfrak`, `\mathtt`, …).
- Array and matrix environments: `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`,
  `Vmatrix`, `smallmatrix`, `cases`, and `\begin{array}{colspec}` with per-column
  `l`/`c`/`r` alignment and single/double vertical rules (`|` / `||`).
- Five bundled font families, downloaded lazily via Julia Artifacts on first use (three further TeX Gyre families pending artifact publication).
- Lenient parser: never throws on ill-formed input; unknown commands produce inert
  `NKCommand` leaf nodes that are silently skipped by the layout engine.

## Usage

```julia
using TeXLayout

# Use the default font family (New Computer Modern Math, downloaded automatically).
family = default_font_family()

# Or select one of the five bundled families by symbol:
#   :new_cm    — New Computer Modern (default)
#   :pagella   — TeX Gyre Pagella (Palatino style)
#   :luciole   — Luciole Math (designed for low vision)
#   :stix_two  — STIX Two Math (Times style)
#   :fira_math — Fira Math + Fira Sans (sans-serif)
family = font_family(:stix_two)

# Or supply your own font files:
family = font_family("/path/to/MyMath.otf"; regular="/path/to/MyText.otf")

# Lay out a formula:
boxes = generate_tex_elements(raw"\frac{1}{\sqrt{2}}", family)

# boxes is a Vector{LayoutBox}; each box carries:
#   .element  — Glyph, HRule, VRule, or Space
#   .x, .y    — baseline-relative position in em units
#   .scale    — font-size multiplier (1.0 for Display/Text, 0.7 for Script, …)
```

## Status

Early development (v0.1).  The following features are not yet implemented:

- `\text{…}` inter-atom spacing (text-mode fragments are not yet classified by atom class).

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

The five currently published font families (plus three pending; see `tools/prepare_font_artifacts.jl`) are redistributed under their respective open licences.  Each tarball includes the relevant licence file.

| Symbol | Font | Authors | Licence |
|:-------|:-----|:--------|:--------|
| `:new_cm` | [New Computer Modern](https://ctan.org/pkg/newcomputermodern) | Antonis Tsolomitis (University of the Aegean) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:pagella` | [TeX Gyre Pagella Math](https://ctan.org/pkg/tex-gyre-math-pagella) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:luciole` | [Luciole](https://luciole-vision.com/) | Daniel Flipo and [typographies.fr](https://typographies.fr/), in collaboration with [Centre de Ressources Handicap Visuel](https://crhv.fr/) de Lyon; with support from DIPHE/Université Lumière Lyon 2, GUTenberg, Swiss Ceres Foundation, PEP69 | Math font: [SIL OFL 1.1](https://openfontlicense.org); text fonts: [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `:stix_two` | [STIX Two Math](https://github.com/stipub/stixfonts) v2.0.2 | The STIX Fonts Project Authors; STIX Fonts™ is a trademark of the [Institute of Electrical and Electronics Engineers](https://www.ieee.org/) | [SIL OFL 1.1](https://openfontlicense.org) (Reserved Font Name "TM Math") |
| `:fira_math` | [Fira Math](https://github.com/firamath/firamath) v0.3.4 + [Fira Sans](https://github.com/mozilla/Fira) | Fira Math: Xiangdong Zeng; Fira Sans: Mozilla and Telefonica S.A. | [SIL OFL 1.1](https://openfontlicense.org) |
| `:schola` *(pending)* | [TeX Gyre Schola Math](https://ctan.org/pkg/tex-gyre-math-schola) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:termes` *(pending)* | [TeX Gyre Termes Math](https://ctan.org/pkg/tex-gyre-math-termes) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:bonum` *(pending)* | [TeX Gyre Bonum Math](https://ctan.org/pkg/tex-gyre-math-bonum) | Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk (GUST e-foundry) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
