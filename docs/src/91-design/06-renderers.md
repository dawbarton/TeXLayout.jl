# Renderer adapters

Two package extensions connect TeXLayout to Makie:

- `ext/MakieExt.jl` (Makie and LaTeXStrings) implements Makie 0.25's public text
  handler, `Makie.layout_text(handler, source, attributes) -> Makie.TextLayout`.
  It defines the method only when Makie has `TextAttributes`, `TextLayout`, and
  `layout_text`, so the same weak dependency still loads with Makie 0.24.
- `ext/MathTeXEngineExt.jl` (MathTeXEngine, GeometryBasics, and LaTeXStrings) is
  the automatic path for Makie 0.24.

What they share lives in `src/render_support.jl`, which depends on no weak
dependency.

## Routing

`_inline_math_tokens` decides how a `LaTeXString` is laid out.  A string that
starts and ends with a single `$` and contains exactly two unescaped math shifts
at brace depth zero (the usual `L"…"`) is one formula: the delimiters are
stripped, and it is parsed with `parse_latex` and laid out in Display style.  An
escaped `\$` does not count, and a `$` inside braces (`\text{if $x>0$}`) belongs to
its group.  Every other string (surrounding text, several `$…$` spans, `\(…\)`,
`$$…$$`, `\[…\]`) goes through `layout_document`.

## Glyph resolution

`_glyph_runtime(family)` returns a cached `GlyphRuntime`: the loaded face for each
font in the family, each slot's fallback chain, and memoised name-to-index
lookups.  `_resolve_glyph(runtime, slot, name)` walks the slot's chain for the
first face that has the glyph, trying the PostScript name, then a one-character
name as a codepoint, then a `uniXXXX` name; it returns `nothing` when no font has
it, and the adapter draws nothing.  A `GlyphID` is drawn from its own font file
(`_runtime_font`).  The FreeType tools resolve glyphs the same way
(`tools/common.jl`), so what they draw is what a renderer draws.

## The Makie 0.25 handler

`TeXLayoutHandler(; family, options)` claims only `LaTeXString`; Makie sends every
other source to its own layout.  A handler can pin a `FontFamily` and
`LayoutOptions`, or read the session defaults at each call.  Users select it per
plot (`text_handler = TeXLayoutHandler()`) or in a theme.

The handler converts TeXLayout's output to a `Makie.TextLayout`:

1. Route the string (above).  For documents, Makie's `lineheight` multiplies the
   options' `line_height`, `word_wrap_width` sets the document width, and the
   resolved justification maps to `LayoutOptions.align`.
2. Convert each element.  Glyphs become a native font, glyph index, extent,
   origin, and scale; `HRule` and `VRule` become one `LineSegments` plot spec with
   its own bounding box; a `Space` has no glyph and counts only through the block
   width.
3. Return the layout with the block box scaled by font size.  The reported
   baseline is the last line's, as in Makie's own layouts.  Makie applies
   `align`, `rotation`, and `offset` afterwards and owns validation, placement,
   and batching.

### Geometry contract

`HRule.y` and `VRule.x` are rectangle edges (bottom and left), but Makie line
specs and MathTeXEngine's `HLine` and `VLine` are positioned at the line's
centre.  The adapters shift each rule by half its thickness and report the full
visual bounds of each spec.

### Metric contract

Makie builds every glyph's bounding box from `(0, descender)` to
`(hadvance, ascender)` (`height_insensitive_boundingbox_with_advance`) and
expects these to be the font's line metrics, not the glyph's ink, so that a
label's height does not depend on its characters.  `_glyph_extent` therefore
pads each glyph's ink to `max(ink_top, font_ascender)` and
`min(ink_bottom, font_descender)`, as `MathTeXEngine.TeXChar` does, and
`_block_bbox` pads `TeXBox.ascent` and `descent` the same way.  With bare ink
bounds, `align = (:*, :center)` would put `L"x"` and `L"M"` on different
baselines, and axis tick-label space would depend on whether a label has a
descender.

### Limits of the mapping

TeXLayout has no soft line breaking, so `word_wrap_width` sets the box width
without wrapping, and fractional justification snaps to left, centre, or right.
Layout is not cached: Makie's display-only fast path applies only when
`text_handler === nothing`, so a colour change runs `layout_text` again.  Makie
removed the overloadable `bakes_display_attributes` hook in
[#5717](https://github.com/MakieOrg/Makie.jl/pull/5717) because a handler that
opted out would leave its plot specs' colours stale; TeXLayout's rule specs do
carry the colour.

## The Makie 0.24 adapter

`MathTeXEngineExt` adds a method
`MathTeXEngine.generate_tex_elements(::LaTeXString)` that converts TeXLayout's
output to MathTeXEngine's `TeXChar`, `HLine`, and `VLine` elements, with its own
cache of derived MathTeXEngine families.  This is type piracy, kept confined to
one method.  Once `MakieExt` reports that the public handler exists, the method
`invoke`s MathTeXEngine's original generic implementation instead, so Makie 0.25
is unchanged until a user selects `TeXLayoutHandler`.
