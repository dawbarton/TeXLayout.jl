# Future Work

This is the focused engineering backlog for work that is not part of v0.3.0.
Current limitations are also summarized in the user and developer documentation;
this file records the intended implementation direction.

## Paragraph shaping and line breaking

- Add width-aware soft line breaking for document paragraphs. Preserve the
  non-breaking behavior of `~` once lines can wrap.
- Evaluate a paragraph-level bidirectional algorithm. HarfBuzz shapes runs but
  does not reorder a bidirectional paragraph.
- Expose HarfBuzz language, script, direction, and optional feature controls
  only through backend-independent layout options; keep semantic features such
  as small capitals in `TextFeatures`.
- Extend fallback coverage for mixed-script runs and combining-mark clusters.

## Vertical metrics and matrix spacing

- Implement `\strut` as an invisible, zero-width box with TeX-like height and
  depth.
- Add `\phantom`, `\vphantom`, and `\hphantom` using the same invisible measured
  box representation.
- Preserve optional matrix row-spacing dimensions such as `\\[0.2em]` in the
  parsed matrix representation and apply them when computing row baselines.
- Matrix-family environments, `array`, `cases`, and `smallmatrix` follow
  LaTeX + amsmath (`_MATRIX_SPACING`; widths agree with LuaLaTeX to 0.001 pt).
  Remaining differences: a one-column `cases` omits the trailing `\quad` that
  amsmath's `l@{\quad}l` template leaves after the first column; array entries
  inside a script shrink with it, where TeX sets them at full Text size
  (`x_{\begin{matrix}a\\b\end{matrix}}`, measured in LuaLaTeX); `\hline` and `@{…}` are
  ignored.
- The display alignments (`align`, `gather`, `split`, …) keep ink-tight rows
  with `_MATRIX_ROWGAP` and 5 mu column margins.  amsmath sets them with
  `\strut@` rows, `\jot`, and its own column spacing; measure them in LuaLaTeX
  before changing, and compare against the snapshot fonts.
- Re-evaluate the fixed `_MATRIX_ROWGAP` only after explicit row spacing exists;
  compare any proposed default change against TeX, KaTeX, and all snapshot
  fonts.
- `\overbrace` and `\underbrace` are Op atoms in the LaTeX kernel
  (`\mathop{…}\limits`, fontmath.ltx) and Inner here; unicode-math redeclares
  them as `\mathover`/`\mathunder` characters, class unverified.  Widths next
  to an Ord agree in LuaLaTeX (thin space either way), but a following binary
  operator or opening delimiter would be spaced differently.
  Changing the class touches limit placement, so check `\overbrace{x}^{n}`
  and `\overbrace{a}+b` against LuaLaTeX first.
- LuaTeX adds a delimiter variant's italic correction after a `\left`
  delimiter (NewCM's `bmatrix` is 0.09 pt wider there); XeTeX does not, and
  neither does TeXLayout.
- Size `\binom` and `\genfrac` delimiters from fixed sizes, as TeX does with
  `delim1` / `delim2` (OpenType has no such constant; check what LuaTeX uses),
  instead of fitting them to the content.

- Add an invisible element with height and depth (a strut) to the box model.
  Layout is ink-based, so `RadicalExtraAscender` (space TeX keeps above a
  radical's rule) cannot be represented and is ignored: `\frac{1}{\sqrt{x}}`
  sets the fraction bar 0.04 em (NewCM) to 0.14 em (Termes) closer to the
  radical than TeX does.  The same element would let `\left…\right` see the
  row struts of a matrix among other content (a lone matrix already passes
  its delimiters to the matrix layout).

## Extensible glyph assemblies

- Vertical arrow and double-arrow assemblies are broken in some fonts: Luciole
  `\left\uparrow` shows two arrowheads and its `\downarrow` a detached bar;
  STIX Two and Luciole `\Downarrow` show a seam, and `\Downarrow` comes out
  taller than `\Uparrow` for the same content.
- Radical assemblies still use minimum part overlaps
  (`_layout_radical_assembly!`), so they can overshoot the required height by up
  to one extender; horizontal and delimiter assemblies now share
  `_assembly_overlaps`.
- `\bigm\{` and `\bigm|` come out at different heights (about 1.9 em and
  1.1 em in Bonum); check the `\big` size tiers against each font's variants.
- Fira Math's overbracket assembly has a visible step in its top rule.

## Sizing

- Make `\tiny` … `\Huge` absolute, as in LaTeX, rather than multiplying the
  enclosing size: `{\Large … {\small x}}` sets x at 1.44 × 0.9 instead of 0.9.

## Display environments

- Implement `multline` through a width-aware display layout path: first row
  flush left, final row flush right, intermediate rows centered.
- Replace the current `align` grid approximation with a complete amsmath-style
  alignment template if exact multi-pair spacing becomes necessary.

## Symbols and math variants

- Compose multi-codepoint negated and variant relations from a base glyph plus
  an overlay or variation selector instead of treating a combining sequence as
  one codepoint.
- Investigate per-font support for `\bigplus`, which has no standard Unicode
  codepoint.
- Define fallback behavior for math font switches applied to characters outside
  the Unicode Mathematical Alphanumeric Symbols block.
- Add a fallback font for symbols a math font lacks.  Fira Math has no
  `\setminus`, `\vdash`, `\triangle`, `\top`, `\bot`, or big set and lattice
  operators (⋃ ⋂ ⨁ ⨂ ⨀ ⨄ ⨆ ⨅ ⋁ ⋀), which render as blank space; its `\mathcal`
  and `\mathscr` fall back to upright sans, and `\widehat`/`\widetilde` do not
  stretch.
- An unknown command that is dropped still counts as an atom for spacing:
  `\unknown + x` gives the leading `+` binary spacing.
- `ssty` script alternates are applied to characters, symbols, and large
  operators but not to delimiters or accents set in a script.  STIX Two and
  Luciole have script delimiters (`parenleft.ssty`, `lparen.st`); substituting
  them needs the vertical-construction lookup to follow the alternate's name.
  Measure `x_{(a)}` and `x^{\hat{a}}` in LuaLaTeX first.  Conversely, the text
  alphabets (`\mathrm`, `\mathit`, …) are text fonts in unicode-math and get
  no `ssty` there, but take the math font's alternates here.
- Extensible arrows without a single-codepoint tail piece (`\xmapsto`, the hook
  arrows, the stacked harpoons) stay at natural width in fonts lacking a
  horizontal construction (Fira Math).  They could be built from a vertical
  rule or by overlapping two copies of the arrow glyph with clipping.

## Makie integration

- Pursue an upstream MathTeXEngine extension point or a dedicated Makie recipe
  so TeXLayout no longer needs the confined `generate_tex_elements` type-piracy
  method.
- If Makie exposes per-render layout options, replace the current session-wide
  default bridge for document width and alignment.
- Once Makie 0.25 is released, run the `TeXLayoutHandler` tests in CI against
  it; until then they are checked by hand against Makie's `ff/breaking-0.25`
  branch.

## Regression tooling

- Keep every visual renderer capable of consuming both name-based `Glyph` and
  exact-path `GlyphID` elements; add renderer-contract tests when shared drawing
  helpers are introduced.
- Consider separating stress generation, manifest management, and comparison
  into small library components if the suite gains more backends or output
  formats.
