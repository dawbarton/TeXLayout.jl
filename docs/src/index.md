# TeXLayout.jl

TeXLayout.jl is a Julia-idiomatic, OpenType-aware LaTeX math typesetter designed as a
drop-in replacement for [MathTeXEngine.jl](https://github.com/Kolaru/MathTeXEngine.jl)
in [Makie.jl](https://github.com/MakieOrg/Makie.jl).  It converts LaTeX math strings
into a flat list of positioned glyph elements via a `tokenize → parse → layout` pipeline.
Every metric constant — axis height, script shifts, fraction gaps, radical clearance —
is read directly from the font's OpenType MATH table; nothing is hard-coded.

## Key features

- Full TeX style cascade (Display / Text / Script / ScriptScript, each with a cramped
  variant) driven entirely from the font's OpenType MATH table — no hard-coded fallbacks.
- Auto-sized delimiters, fractions, radicals, and accents; sub/superscripts with italic
  correction applied to slanted bases (e.g. `\int`).
- Named math operators (`\sin`, `\cos`, `\lim`, `\operatorname{…}`, and 30+ others)
  rendered upright using the companion regular font or the math font's codepoint map.
- Inter-atom spacing following the TeX atom-class table
  (ord / bin / rel / op / open / close / punct / inner).
- Font switching: `\mathbf`, `\mathrm`, `\mathbb`, `\mathcal`, `\mathfrak`, `\mathtt`,
  `\mathit`, `\mathsf`, `\boldsymbol`, and their aliases.
- Array and matrix environments: `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`,
  `Vmatrix`, `smallmatrix`, `cases`, and `\begin{array}{colspec}` with per-column
  `l`/`c`/`r` alignment and single/double (`||`) vertical rules.
- Mixed text-and-math document layout via `layout_document`: styled text, inline
  `$…$` math, display-math environments (`align`, `aligned`, `split`, `gather`,
  `gathered`, `equation`, and their starred forms), line breaks (`\\`), and
  paragraph breaks, returned as a measured `TeXBox`.
- Pluggable text shaping: `MetricShaper` by default, with optional
  `HarfBuzzShaper` support when `HarfBuzz_jll` is loaded.
- Eight bundled font families downloaded lazily via Julia Artifacts on first use.
- Lenient parser: never throws on ill-formed input; unknown commands produce inert nodes
  that are silently skipped by the layout engine.

## Getting started

The canonical three-liner lays out a formula with the default font (New Computer Modern):

```julia
using TeXLayout
boxes = TeXLayout.generate_tex_elements(raw"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}")
# boxes is a Vector{LayoutBox}
```

Each `LayoutBox` carries a `TeXElement` (a `Glyph`, `GlyphID`, `HRule`, `VRule`, or `Space`), a
2-D position in em units relative to the formula baseline (`x` right, `y` up), and a
`scale` factor.  See [Getting Started](01-getting-started.md) for a full walkthrough.

## Makie integration

When `TeXLayout` and `MathTeXEngine` are both loaded in the same Julia session, a
package extension (`MathTeXEngineExt`) activates automatically and replaces
MathTeXEngine's layout engine with TeXLayout's OpenType-aware pipeline.  No further
code changes are needed — LaTeX strings passed to `text!` in CairoMakie or GLMakie are
rendered via TeXLayout transparently.

```julia
using TeXLayout          # activates MathTeXEngineExt automatically
using CairoMakie, LaTeXStrings

fig = Figure()
ax  = Axis(fig[1, 1])
text!(ax, 0.5, 0.5;
      text      = L"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
      fontsize  = 32,
      align     = (:center, :center))
save("output.png", fig)
```

See [Makie integration](03-makie.md) for font-matching tips and known limitations.

## Pages

- [Getting Started](01-getting-started.md) — installation, basic usage, coordinate system, and custom renderers.
- [Font Families](02-fonts.md) — bundled families, custom fonts, Makie font matching, and licences.
- [Makie Integration](03-makie.md) — activating the extension, changing fonts, matching Makie text.
- [LaTeX Command Reference](04-commands.md) — supported commands, operators, accents, environments, and spacing.
- [API Reference](05-api.md) — the small exported configuration surface and
  qualified advanced APIs.
- [Developer Docs](91-developer.md) — architecture, invariants, and contributing guide.

## Acknowledgements

TeXLayout.jl builds on the following prior work:

- **[KaTeX](https://katex.org/)** (MIT licence) — primary reference for algorithm
  design, TeX style cascade rules, operator lists, italic-correction handling, and test
  cases.  Several test expressions in `test/test_katex.jl` are derived from KaTeX's
  `ss_data.yaml`, `katex-spec.ts`, and `errors-spec.ts`.
- **[MathTeXEngine.jl](https://github.com/Kolaru/MathTeXEngine.jl)** (MIT licence) — an
  earlier Julia implementation of LaTeX rendering for Makie; informed the overall
  architecture and the `LayoutBox` interface consumed by Makie's glyph collection.
- **[The TeXbook](https://www.amazon.co.uk/TeXbook-Donald-Knuth/dp/0201134489)** by
  Donald E. Knuth — the authoritative reference for TeX's box-and-glue model, style
  cascade, and atom spacing table.
- **[OpenType MATH specification](https://docs.microsoft.com/en-us/typography/opentype/spec/math)**
  — source of truth for all metric constants (axis height, script shifts, fraction
  parameters, radical gaps, etc.).
