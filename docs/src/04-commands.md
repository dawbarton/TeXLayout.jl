# LaTeX Command Reference

This page lists every LaTeX command recognised by TeXLayout's parser and layout engine.
Commands are grouped by mathematical role.  All commands are valid inside math mode
(i.e. after `generate_tex_elements` is called, or inside an `L"…"` string when using
the Makie integration).

## Ordinary symbols

### Greek lowercase

`\alpha`, `\beta`, `\gamma`, `\delta`, `\epsilon`, `\varepsilon`, `\zeta`, `\eta`,
`\theta`, `\vartheta`, `\iota`, `\kappa`, `\lambda`, `\mu`, `\nu`, `\xi`, `\pi`,
`\varpi`, `\rho`, `\varrho`, `\sigma`, `\varsigma`, `\tau`, `\upsilon`, `\phi`,
`\varphi`, `\chi`, `\psi`, `\omega`

### Greek uppercase

`\Gamma`, `\Delta`, `\Theta`, `\Lambda`, `\Xi`, `\Pi`, `\Sigma`, `\Upsilon`, `\Phi`,
`\Psi`, `\Omega`

### Miscellaneous

`\infty`, `\partial`, `\nabla`, `\forall`, `\exists`, `\nexists`, `\emptyset`,
`\varnothing`, `\angle`, `\measuredangle`, `\sphericalangle`, `\ell`, `\imath`,
`\jmath`, `\hbar`, `\hslash`, `\Re`, `\Im`, `\wp`, `\aleph`, `\beth`, `\gimel`,
`\daleth`, `\prime`, `\backprime`, `\complement`, `\surd`, `\top`, `\bot`, `\flat`,
`\natural`, `\sharp`, `\triangle`, `\triangledown`, `\square`, `\blacksquare`,
`\lozenge`, `\blacklozenge`, `\bigstar`, `\eth`, `\vdots`, `\checkmark`

## Binary operators

`\pm`, `\mp`, `\times`, `\div`, `\cdot`, `\ast`, `\star`, `\circ`, `\bullet`,
`\cap`, `\cup`, `\sqcap`, `\sqcup`, `\wedge` (alias `\land`), `\vee` (alias `\lor`),
`\setminus`, `\smallsetminus`, `\oplus`, `\ominus`, `\otimes`, `\oslash`, `\odot`,
`\ltimes`, `\rtimes`, `\wr`, `\amalg`, `\dagger`, `\ddagger`, `\triangleleft`,
`\triangleright`, `\dotplus`, `\intercal`, `\divideontimes`, `\boxplus`, `\boxminus`,
`\boxtimes`, `\boxdot`, `\barwedge`, `\curlywedge`, `\curlyvee`, `\doublebarwedge`,
`\leftthreetimes`, `\rightthreetimes`

## Relations

`\leq` (alias `\le`), `\geq` (alias `\ge`), `\neq` (alias `\ne`), `\equiv`,
`\approx`, `\sim`, `\simeq`, `\cong`, `\propto`, `\perp`, `\parallel`, `\mid`,
`\nmid`, `\subset`, `\supset`, `\subseteq`, `\supseteq`, `\sqsubseteq`,
`\sqsupseteq`, `\in`, `\notin`, `\ni`, `\prec`, `\succ`, `\preceq`, `\succeq`,
`\ll`, `\gg`, `\to`, `\leftarrow`, `\rightarrow`, `\Leftarrow`, `\Rightarrow`,
`\leftrightarrow`, `\Leftrightarrow`, `\iff`, `\implies`, `\mapsto`, `\longmapsto`,
`\hookleftarrow`, `\hookrightarrow`, `\uparrow`, `\downarrow`, `\vdash`, `\dashv`,
`\models`, `\smile`, `\frown`

AMS extensions include: `\leqslant`, `\geqslant`, `\approxeq`, `\lesssim`,
`\gtrsim`, `\lessgtr`, `\gtrless`, `\lesseqgtr`, `\gtreqless`, `\eqslantless`,
`\eqslantgtr`, `\preccurlyeq`, `\succcurlyeq`, `\curlyeqprec`, `\curlyeqsucc`,
`\precsim`, `\succsim`, `\subseteqq`, `\supseteqq`, `\Subset`, `\Supset`,
`\trianglelefteq`, `\trianglerighteq`, `\blacktriangleleft`, `\blacktriangleright`,
`\vartriangleleft`, `\vartriangleright`, and many more.

## Large operators

In Display style, large operators are automatically enlarged using the font's
`display_operator_min_height` constant from the OpenType MATH table.  For `\sum`,
`\prod`, `\coprod`, `\bigcap`, `\bigcup`, and all `\bigXxx` variants, limits
placement (sub/superscript stacked above/below the operator) is used automatically
in Display style; inline (beside-base) placement is used in Text style.  Use
`\limits` or `\nolimits` to override this decision.

`\sum`, `\prod`, `\coprod`, `\int`, `\iint`, `\iiint`, `\iiiint`, `\oint`,
`\oiint`, `\oiiint`, `\bigcap`, `\bigcup`, `\bigsqcup`, `\bigsqcap`, `\bigwedge`,
`\bigvee`, `\bigoplus`, `\bigotimes`, `\bigodot`, `\biguplus`

## Named operators

Rendered upright using the companion regular font (or the math font's own codepoint
mapping where no regular font is configured).  In Display style, the operators
`\lim`, `\limsup`, `\liminf`, `\sup`, `\inf`, `\max`, `\min`, `\det`, `\gcd`, and
`\Pr` automatically use limits placement.

`\sin`, `\cos`, `\tan`, `\cot`, `\sec`, `\csc`, `\arcsin`, `\arccos`, `\arctan`,
`\ln`, `\log`, `\exp`, `\lim`, `\limsup`, `\liminf`, `\sup`, `\inf`, `\max`,
`\min`, `\det`, `\dim`, `\ker`, `\deg`, `\gcd`, `\hom`, `\Pr`, `\arg`

For an operator name that is not in the list above, use `\operatorname{name}`.

## Delimiters

### Auto-sized pairs

Wrap content in `\left`…`\right` to have the delimiter height chosen automatically
to cover the enclosed expression.  The size is selected from the font's
`vert_constructions` table (pre-built size variants and extensible assemblies).

| Left | Right |
|:-----|:------|
| `\left(` | `\right)` |
| `\left[` | `\right]` |
| `\left\{` | `\right\}` |
| `\left\|` or `\left\vert` | `\right\|` or `\right\vert` |
| `\left\|` or `\left\Vert` | `\right\|` or `\right\Vert` |
| `\left/` | `\right/` |
| `\left\backslash` | `\right\backslash` |
| `\left\langle` | `\right\rangle` |
| `\left\lfloor` | `\right\rfloor` |
| `\left\lceil` | `\right\rceil` |
| `\left.` | `\right.` (null delimiter — no glyph rendered) |

All delimiters are centred on the math axis.

### Inner delimiter

`\middle` (followed by a delimiter token) inserts a delimiter auto-sized to the same
height as the enclosing `\left`/`\right` pair.  Multiple `\middle` delimiters per
group are supported.

## Fractions

| Command | Behaviour |
|:--------|:----------|
| `\frac{num}{den}` | Standard fraction in the current style |
| `\dfrac{num}{den}` | Forces Display style for the fraction (even inside a subscript) |
| `\tfrac{num}{den}` | Forces Text style for the fraction |

The fraction rule thickness and shift distances are read from the OpenType MATH table.

## Radicals

| Command | Behaviour |
|:--------|:----------|
| `\sqrt{body}` | Square root |
| `\sqrt[degree]{body}` | Root with explicit degree |

The radical glyph is selected from the font's `vert_constructions` table, then
extended with an assembly if the body is taller than the largest pre-built variant.
The overbar is top-anchored to the radical glyph.

## Sub- and superscripts

Standard TeX notation: `x^{sup}`, `x_{sub}`, `x_{sub}^{sup}`.  The source order of
`_` and `^` does not matter.

Italic correction is applied to subscripts on slanted single-glyph bases such as
`\int`, matching KaTeX behaviour.  For large operators with automatic limits
placement, use `\limits` to force stacked placement or `\nolimits` to force
beside-base placement regardless of the current style.

## Accents

### Non-stretchy

`\hat`, `\acute`, `\grave`, `\ddot`, `\tilde`, `\bar`, `\breve`, `\check`, `\dot`,
`\mathring`, `\vec`

The accent is horizontally aligned to the base glyph using the font's
`MathTopAccentAttachment` table.

### Stretchy (horizontally extensible)

`\widehat`, `\widetilde`

The glyph variant is selected from `horiz_constructions`; the accent is centred over
the base.

### Overline and underline rules

`\overline{…}`, `\underline{…}` — draws a rule above or below the body; gap and
rule thickness are read from the OpenType MATH table.

## Horizontal extensibles

The following commands stretch horizontally to cover their body and accept an
optional sub/superscript note placed above or below (limits style):

`\overbrace`, `\underbrace`, `\overbracket`, `\underbracket`, `\overparen`,
`\underparen`

Example: `\overbrace{a + b + c}^{n \text{ terms}}`

## Extensible arrows

All extensible-arrow commands stretch the arrow horizontally to span the label.
The optional `[below-label]` argument is placed below the arrow.

```
\xrightarrow[below]{above}
```

Available commands:

`\xrightarrow`, `\xleftarrow`, `\xLeftarrow`, `\xRightarrow`, `\xleftrightarrow`,
`\xLeftrightarrow`, `\xhookleftarrow`, `\xhookrightarrow`, `\xmapsto`,
`\xrightharpoondown`, `\xrightharpoonup`, `\xleftharpoondown`, `\xleftharpoonup`,
`\xrightleftharpoons`, `\xleftrightharpoons`, `\xtwoheadrightarrow`,
`\xtwoheadleftarrow`, `\xlongequal`

## Matrices and arrays

All environments use `\begin{env}…\end{env}` syntax.  Cells are separated by `&`;
rows are terminated by `\\`.

| Environment | Delimiters | Column alignment |
|:------------|:-----------|:-----------------|
| `matrix` | none | centred |
| `pmatrix` | `( )` | centred |
| `bmatrix` | `[ ]` | centred |
| `Bmatrix` | `\{ \}` | centred |
| `vmatrix` | `\| \|` | centred |
| `Vmatrix` | `‖ ‖` | centred |
| `smallmatrix` | none | centred (0.9× scale) |
| `cases` | `\{` left only | left-aligned |
| `array` | none | per `{colspec}` |

The `array` environment takes a mandatory column-spec argument:

```latex
\begin{array}{lcr|c||r}
  a & b & c & d & e \\
  f & g & h & i & j
\end{array}
```

Each letter in the spec is `l` (left-aligned), `c` (centred), or `r` (right-aligned).
`|` inserts a single vertical rule between columns; `||` inserts a double rule.

### Alignment and display-math environments

The amsmath alignment and display environments are also recognised.  They parse
like the matrix family — cells separated by `&`, rows terminated by `\\` — and in a
[document](#Document-text-mode) they become free-standing, centred display blocks.

| Environment | Layout |
|:------------|:-------|
| `align`, `aligned` | Columns alternate right/left around each `&` alignment point, with no gap inside a pair |
| `split` | Like `aligned` — a single alignment point |
| `gather`, `gathered` | Each row centred; no `&` alignment |
| `equation` | A single centred row |

Unlike `matrix` / `array` / `cases`, whose cells are set in **Text** style, the cells
of these environments are set in **Display** style, so fractions, scripts, and large
operators keep their full display size — matching amsmath.  At each `&` the engine
also inserts the empty ordinary atom TeX uses for relation spacing, so a leading
relation such as `=` is spaced correctly.

```latex
\begin{align}
  (a+b)^2 &= a^2 + 2ab + b^2 \\
          &= a^2 + b^2 + 2ab
\end{align}
```

Starred forms (`align*`, `gather*`, `equation*`, …) are accepted as aliases of their
unstarred environments; equation numbering is not rendered, so the star has no visual
effect.

`multline` is **not** yet supported: it needs per-row alignment (first line flush
left, last flush right) measured against a target line width rather than the shared
column grid used here.

## Text mode

`\text{…}`, `\mbox{…}` — switch to upright (regular-font) text rendering for the
enclosed content.  With the default `MetricShaper`, spaces are preserved as explicit
`Space` elements using the font's word-space advance.  The entire text fragment is
classified as an ordinary atom for inter-atom spacing purposes.

When `HarfBuzz_jll` is loaded and `HarfBuzzShaper()` is passed as the active shaper,
text fragments are shaped as text runs and may emit `GlyphID` elements instead of
one name-based `Glyph` per character.

## Font switching

Apply to a braced argument; the variant propagates into sub/superscripts.

| Command | Variant |
|:--------|:--------|
| `\mathbf{…}` | Bold |
| `\mathit{…}` | Italic |
| `\mathrm{…}` | Roman (upright math) |
| `\mathbb{…}` | Blackboard bold |
| `\mathcal{…}` | Calligraphic / script |
| `\mathfrak{…}` | Fraktur |
| `\mathsf{…}` | Sans-serif |
| `\mathtt{…}` | Typewriter / monospace |
| `\boldsymbol{…}` or `\bm{…}` | Bold (symbols) |
| `\mathscr{…}` | Script |

Aliases: `\Bbb` = `\mathbb`, `\bold` = `\mathbf`, `\frak` = `\mathfrak`.

Font switching maps Latin and Greek characters to their Unicode Mathematical
Alphanumeric Symbols codepoints (U+1D400–U+1D7FF).  Math-mode font switching does
not use the `bold`, `italic`, or `bolditalic` `FontFamily` text slots; those slots
are used by the document text layer for commands such as `\textbf`, `\textit`, and
nested bold-italic text.

## Style overrides

`\displaystyle`, `\textstyle`, `\scriptstyle`, `\scriptscriptstyle` — force a
specific TeX style for the rest of the current group.  `\dfrac` and `\tfrac` force
Display or Text style respectively for the fraction only.

Style overrides also reset the scale factor to match the target style
(`size_scale(new_style, mc)`), so `\dfrac` inside a subscript renders at full display
size, matching KaTeX behaviour.

## Font sizing

The following commands multiply the current scale by a fixed factor and apply to the
rest of the current group.  The style (D/T/S/SS) is unchanged.

| Command | Multiplier |
|:--------|:----------:|
| `\tiny` | 0.5× |
| `\scriptsize` | 0.7× |
| `\footnotesize` | 0.8× |
| `\small` | 0.9× |
| `\normalsize` | 1.0× |
| `\large` | 1.2× |
| `\Large` | 1.44× |
| `\LARGE` | 1.728× |
| `\huge` | 2.074× |
| `\Huge` | 2.488× |

## Spacing

Inter-atom spacing between mathematical object classes (Ord, Bin, Rel, Op, Open,
Close, Punct, Inner) is inserted automatically according to the standard TeX table.
The following commands insert explicit horizontal space:

| Command | Width |
|:--------|:------|
| `\,` or `\thinspace` | 3/18 em (thin space) |
| `\:` or `\medspace` | 4/18 em (medium space) |
| `\;` or `\thickspace` | 5/18 em (thick space) |
| `\!` or `\negthinspace` | −3/18 em |
| `\negmedspace` | −4/18 em |
| `\negthickspace` | −5/18 em |
| `\enspace` | 0.5 em |
| `\quad` | 1 em |
| `\qquad` | 2 em |
| `~`, `\ ` (control space), `\space`, `\nobreakspace` | 6/18 em (normal interword space) |
| `\kern{dim}` | explicit dimension (em or mu units) |
| `\mkern{dim}` | explicit math kern (mu units) |
| `\hskip{dim}` | same as `\kern` |
| `\mskip{dim}` | same as `\mkern` |

1 mu = 1/18 em.  Negative spaces are fully supported.  Ordinary whitespace
(spaces, tabs, newlines) is insignificant in math mode, including after `^`/`_` or
a command name (`x^ 2` and `\frac 1 2` bind the following token).  A `%` starts a
comment that runs to the end of the line.

## Document text mode

The commands above apply to **math** input.  `layout_document` additionally accepts
mixed text-and-math input, where the top-level mode is *text* and math is entered
explicitly.  The following constructs are recognised only in this document context:

| Construct | Effect |
|:----------|:-------|
| `\textbf{…}` | Bold text |
| `\textit{…}` | Italic text |
| `\emph{…}` | Emphasis — toggles italic relative to the surrounding text |
| `\textrm{…}`, `\textnormal{…}` | Upright (regular) text |
| `\textsf{…}` | Sans-serif (falls back to the regular slot in v1) |
| `\texttt{…}` | Monospace (falls back to the regular slot in v1) |
| `\text{…}`, `\mbox{…}` | Grouping scope that inherits the current text attributes |
| `$…$`, `\(…\)` | Inline math, laid out in `Text` style on the current line |
| `$$…$$`, `\[…\]` | Free-standing centred display-math block |
| `\begin{align}…\end{align}` (and `aligned`, `split`, `gather`, `gathered`, `equation`, plus starred forms) | Free-standing centred display-math block |
| `\\` | Explicit line break |
| blank line | Paragraph break with `parskip` vertical space |

Styling nests correctly: `\textbf` inside `\textit` produces bold-italic, and `\emph`
flips italic on or off depending on the surrounding state.

Whitespace follows LaTeX: runs collapse to a single inter-word space, a blank line
starts a new paragraph, and leading/trailing whitespace at a line or block boundary
is trimmed.  `~` is a non-breaking space that is never trimmed, and `%` starts a
line comment (a line ending in `%` joins the next line with no space).

See [`layout_document`](05-api.md) and the [Getting Started](01-getting-started.md#Mixed-text-and-math)
walkthrough for usage and the available `LayoutOptions`.

## Known limitations

A small set of negated and variant relations currently produce **blank space** because
they have no single Unicode codepoint in standard OpenType math fonts:

`\nleqslant`, `\ngeqslant`, `\nleqq`, `\ngeqq`, `\lvertneqq`, `\gvertneqq`,
`\varsubsetneq`, `\varsupsetneq`, `\npreceq`, `\nsucceq`

These symbols are defined in Unicode as a base character combined with U+0338
(COMBINING SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR-1), but OpenType math
fonts do not consistently encode them as single glyphs.  Correct support would
require two-glyph overlay rendering, similar to how TeX builds `\not\leq`.

`\bigplus` also has no Unicode codepoint and currently produces blank space on all
fonts.

Matrix vertical spacing helpers are still limited.  `\strut`,
`\phantom`/`\vphantom`/`\hphantom`, and effective row-spacing arguments such as
`\\[0.2em]` are not yet implemented in layout.  The parser recognises and skips
bracketed row-spacing arguments in matrix bodies, but the extra spacing is not
applied.

Soft line-breaking within a paragraph is not yet implemented, so the non-breaking
property of `~` has no visible effect on wrapping in document mode (it still renders
as a single, untrimmed space).
