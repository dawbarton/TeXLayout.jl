# Future Work

This is the single list of TeXLayout's known limitations and the planned work
on them.  The design documentation (`docs/src/91-design/`) describes what is
implemented; this file records what is not, and the intended direction.

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
- Every array-like environment follows LaTeX + amsmath (`_MATRIX_SPACING`,
  `\\[len]` included; LuaLaTeX agrees to 0.001 pt).  Remaining differences:
  array entries inside a script shrink with it, where TeX sets them at full
  Text size (`x_{\begin{matrix}a\\b\end{matrix}}`, measured in LuaLaTeX);
  `\hline`, `@{…}`, `\\*`, and register lengths in `\\[…]` (`\jot`) are
  ignored; `align` and `gather` are set as `aligned` and `gathered`, without
  `align`'s spreading of column pairs across the display width or equation
  numbers; `\begin{array}[t]` / `[b]` positions are ignored (always centred).
- `\overbrace` and `\underbrace` are Op atoms in the LaTeX kernel
  (`\mathop{…}\limits`, fontmath.ltx) and Inner here; unicode-math redeclares
  them as `\mathover`/`\mathunder` characters, class unverified.  Widths next
  to an Ord agree in LuaLaTeX (thin space either way), but a following binary
  operator or opening delimiter would be spaced differently.
  Changing the class touches limit placement, so check `\overbrace{x}^{n}`
  and `\overbrace{a}+b` against LuaLaTeX first.  A script on the brace's far
  side (`^{m}` in `\underbrace{x+y}_{n}^{m}`) is set here as an ordinary
  superscript; as a `\limits` Op, TeX would centre it above the nucleus.
  The brace itself is also chosen differently: `\overbrace{a+b}` is 0.05 to
  0.21 em wider here than in LuaLaTeX (all eight bundled fonts) and up to
  0.08 em taller.
- LuaTeX adds a delimiter variant's italic correction after a `\left`
  delimiter (NewCM's `bmatrix` is 0.09 pt wider there); XeTeX does not, and
  neither does TeXLayout.

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
  The tiers themselves are KaTeX's by choice (`katex_rules.md`).
- Delimiter variants are compared by their MATH advance; LuaTeX appears to
  compare the glyph's height plus depth, 1 du less in the bundled fonts.  At an
  exact edge the choice differs: Schola's `\tbinom` (`delim2`, 1.01 em) gets
  `parenleft.v1` (1011 du advance, 1010 du ink) here and `.v2` in LuaLaTeX.
  (New Computer Modern's display `\binom` also differs, from the recorded
  choice of 2.39 em over luaotfload's 2.40; see `katex_rules.md`, 15e.)
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
- Once Makie 0.25 is released, run the `TeXLayoutHandler` tests in the main CI
  matrix; until then they run in the experimental, `continue-on-error`
  `makie-0-25` job against Makie's `ff/breaking-0.25` branch.  That job uploads
  no coverage, so codecov does not see `ext/MakieExt.jl`.  v0.4.0 already
  declares `Makie = "0.24, 0.25"`: if the released 0.25 breaks the handler,
  release a fix as 0.4.1 and ask General to cap 0.4.0's Makie compat at 0.24.
  The README and `docs/src/03-makie.md` then drop "in development" and can
  lead with the handler.
- Makie's `word_wrap_width` sets the document width without wrapping (there is
  no soft line breaking yet), and fractional justification snaps to left,
  centre, or right, the three `LayoutOptions.align` values.
- A colour change re-runs `layout_text`, because Makie's display-only fast path
  is limited to `text_handler === nothing`.  A handler-local cache keyed on
  source, family, and options would recover most of the cost if it ever
  measures as a problem.

## Regression tooling

- The FreeType tools draw through `tools/common.jl`, which resolves glyphs as
  `GlyphRuntime` does.  Add a renderer-contract test that checks every visual
  renderer consumes both name-based `Glyph` and exact-path `GlyphID` elements
  and resolves them the same way.
- Consider separating stress generation, manifest management, and comparison
  into small library components if the suite gains more backends or output
  formats.
