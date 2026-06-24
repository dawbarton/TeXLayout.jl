# Future Work

These notes record small layout features to implement later.

## Possible bugs to evaluate

- Does `\frac` display at the right size in displayed equations?

## Revisit stress test code

- It's a bit of a mess in terms of the high-level logic around generation/comparison/etc.

## HarfBuzz shaping follow-ups

- Add optional controls for HarfBuzz features, language, script, and direction if
  users need them beyond the current `hb_buffer_guess_segment_properties` path.
- Evaluate paragraph-level bidirectional text support.  HarfBuzz shapes runs but
  does not perform full bidi paragraph reordering.
- Broaden fallback tests for mixed-script text and combining-mark clusters.  The
  current implementation segments by grapheme clusters and shapes adjacent clusters
  that choose the same fallback font together.
- Consider whether visual/debug tools other than the text stress renderer should
  render `GlyphID` elements directly.

## `\strut` / phantom-style height support

- Implement `\strut` as an invisible zero-width box with TeX-like height and
  depth, so users can force a row or expression to reserve normal vertical
  space without drawing anything.
- Consider adding related primitives at the same time:
  - `\vphantom{...}` for invisible height/depth copied from an argument.
  - `\hphantom{...}` for invisible width copied from an argument.
  - `\phantom{...}` for invisible width/height/depth copied from an argument.
- Parser work: add AST representation for invisible measured boxes rather than
  treating them as glyphs or spaces.
- Layout work: measure the argument normally, emit no visible boxes, but return
  the measured advance/ascent/descent contribution.

## Matrix row spacing arguments

- The parser currently recognizes optional row-spacing syntax after a matrix row
  break, e.g. `\\[0.2em]`, but only skips the bracketed dimension.
- Preserve that parsed dimension in `NodeKind.Matrix` payload data or a child-row
  metadata structure.
- Apply the extra spacing in `src/layout/matrix.jl` when computing row baselines:
  the additional amount should increase the gap below the row where it appears.
- Add tests for positive, zero, and malformed row-spacing arguments.

## Matrix default row spacing

- Revisit `_MATRIX_ROWGAP` in `src/layout/matrix.jl`. The current fixed
  `3 / 18` em gap can make small two-row vectors such as
  `\begin{bmatrix}x\\y\end{bmatrix}` look cramped.
- Compare against KaTeX, TeX/LaTeX, and OpenType MATH expectations before
  changing the default. If changed, update layout snapshots intentionally.
- Prefer explicit row-spacing support first, so demos and users can opt in
  without changing global matrix layout behavior.

## Dedicated sans-serif and monospace text slots

- `\textsf{...}` and `\texttt{...}` currently reset to the regular text slot,
  so they render identically to `\textrm{...}`.
- Extend `FontFamily` with optional sans-serif and monospace slots, likely with
  regular/bold/italic/bold-italic variants for each family if the API can stay
  manageable.
- Update text attribute parsing so `\textsf` selects a sans-serif family and
  `\texttt` selects a monospace family while preserving nested bold/italic state.
- Update slot fallback rules so missing sans-serif or monospace fonts degrade
  predictably to the current regular-slot behavior.
- Update the Makie extension runtime cache and `MathTeXEngine.FontFamily`
  conversion so those additional text faces render correctly through CairoMakie.
- Add tests showing `\textsf`, `\texttt`, nested `\textbf`, nested `\textit`, and
  fallback behavior produce the intended font slots.

## Leading and trailing whitespace conventions

- Done. Document text mode trims leading/trailing whitespace at line/paragraph
  and block boundaries (deferred-space model in `src/document.jl`); `%` line
  comments are honoured by the lexer.
- Done. Math mode ignores leading/trailing/repeated ordinary whitespace and a
  space after `^`/`_` or before a command argument (`x^ 2`, `\frac 1 2`).  `~`,
  `\ `, `\space`, and `\nobreakspace` produce a normal interword space (1/3 em)
  in both math mode and `\text{…}`.  `\text{…}` collapses whitespace runs and
  keeps internal spaces, matching document `{…}` groups and LaTeX.
