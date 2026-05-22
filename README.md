# Formatic.jl

A Julia-idiomatic OpenType-aware LaTeX math typesetter, designed for use
with [Makie.jl](https://github.com/MakieOrg/Makie.jl).

## Overview

Formatic.jl converts LaTeX math strings into a flat list of positioned glyph elements
that a renderer (e.g. CairoMakie or GLMakie) can consume directly.  The pipeline is:

```
tokenize → parse_latex → layout → Vector{LayoutBox}
```

Each `LayoutBox` carries a `TeXElement` (glyph, rule, or space), a 2-D position in em
units relative to the formula baseline, and a scale factor.

## Key features

- Full TeX style cascade (Display / Text / Script / ScriptScript, each with a cramped
  variant), driven entirely by the font's OpenType MATH table — no hard-coded constants.
- Correct sub/superscript placement, fractions, radicals, and delimiters.
- Named math operators (`\sin`, `\cos`, `\lim`, `\operatorname{…}`, and 25 others)
  rendered upright using the companion regular font or the math font's codepoint mapping.
- Lenient parser: never throws on ill-formed input; unknown commands produce inert
  `NKCommand` leaf nodes that are silently skipped by the layout engine.

## Acknowledgements

Formatic.jl draws heavily on the following prior work:

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
- **[NewComputerModern](https://ctan.org/pkg/newcomputermodern)** font family — used as
  the fixture font in the test suite; provides a complete OpenType MATH table against
  which all metric constants are validated.

## Usage

```julia
using Formatic, CairoMakie

family = FontFamily("/path/to/NewCMMath-Regular.otf")
boxes  = generate_tex_elements("\\frac{1}{\\sqrt{2}}", family)

# boxes is a Vector{LayoutBox}; each box carries:
#   .element  — Glyph, HRule, VRule, or Space
#   .x, .y    — baseline-relative position in em units
#   .scale    — font-size multiplier (1.0 for Display/Text, 0.7 for Script, …)
```

## Status

Early development (v0.1).  The following features are not yet implemented:

- Limits placement (`\lim_{n\to\infty}` in Display mode places the subscript beside the
  operator rather than below it).
- Inter-atom spacing (thin/medium spaces between operator classes).
- Delimiter auto-sizing (`\left`/`\right` produce correctly-sized delimiters but do not
  yet scale them to the enclosed content).
- Accent commands (`\hat`, `\vec`, `\overline`, `\underbrace`, …) — stubbed in the AST.
- Font-switching (`\mathbf`, `\mathrm`, `\mathbb`, …).
- Array and matrix environments (`\begin{array}`, `pmatrix`, `cases`, …).
- `default_font_family()` for zero-argument `generate_tex_elements` calls.
