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
- Re-evaluate the fixed `_MATRIX_ROWGAP` only after explicit row spacing exists;
  compare any proposed default change against TeX, KaTeX, and all snapshot
  fonts.

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

## Makie integration

- Pursue an upstream MathTeXEngine extension point or a dedicated Makie recipe
  so TeXLayout no longer needs the confined `generate_tex_elements` type-piracy
  method.
- If Makie exposes per-render layout options, replace the current session-wide
  default bridge for document width and alignment.

## Regression tooling

- Keep every visual renderer capable of consuming both name-based `Glyph` and
  exact-path `GlyphID` elements; add renderer-contract tests when shared drawing
  helpers are introduced.
- Consider separating stress generation, manifest management, and comparison
  into small library components if the suite gains more backends or output
  formats.
