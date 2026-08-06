# Makie Integration

Makie 0.25 exposes a public text-layout protocol. TeXLayout implements it with
[`TeXLayoutHandler`](@ref), so integration no longer requires intercepting
MathTeXEngine methods.

## Quick start

Select the handler on one text plot:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

fig = Figure()
ax = Axis(fig[1, 1])
text!(
    ax, 0.5, 0.5;
    text = L"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
    text_handler = TeXLayoutHandler(),
    fontsize = 32,
    align = (:center, :center),
)
save("output.png", fig)
```

Or set it in a theme so axis labels, titles, tick labels, legends, and explicit
text plots all use the same handler:

```julia
with_theme(text_handler = TeXLayoutHandler()) do
    fig = Figure()
    Axis(fig[1, 1]; xlabel = L"x", ylabel = L"f(x)")
    fig
end
```

`TeXLayoutHandler` only claims `LaTeXString` inputs. Plain strings and Makie rich
text fall through to Makie's built-in layout, so one plot can mix handled and
unhandled blocks.

## How it works

Makie calls:

```julia
Makie.layout_text(handler, source, attributes) -> Makie.TextLayout
```

The TeXLayout package extension returns glyph IDs, exact FreeType faces,
origins, extents, scales, a baseline-relative block bounding box, and plot specs
for horizontal and vertical rules. Makie validates and batches those arrays and
applies alignment, rotation, and offset downstream. Moving or rotating a label
therefore does not rerun TeXLayout.

The adapter caches FreeType handles and glyph-name lookups per effective
[`FontFamily`](@ref). TeXLayout's core caches continue to reuse font metrics and
parsed OpenType MATH tables.

## Inline math vs. mixed text and math

The handler routes each `LaTeXString` in one of two ways:

- A string that consists of one `$…$` span (the usual `L"…"` value) is laid out
  in `Display` style. Escaped dollar literals do not change this route.
- Surrounding prose, multiple math spans, `\(…\)`, `$$…$$`, and `\[…\]` use
  [`TeXLayout.layout_document`](@ref).

```julia
with_theme(text_handler = TeXLayoutHandler()) do
    fig = Figure()
    Label(fig[1, 1], L"x^2 + \frac{1}{2}")                         # → math
    Label(fig[2, 1], latexstring("Energy \$E=mc^2\$ is famous."))  # → document
    fig
end
```

Because `L"…"` adds `$…$`, construct a `LaTeXString` with surrounding prose to
force document routing.

!!! note
    `text_handler` is an attribute of the `text` plot, not of a `Block`. `Label`,
    `Axis`, and `Legend` reject it as a keyword argument, so select the handler
    through a theme (`with_theme` or `set_theme!`) whenever the text belongs to a
    block rather than to a `text!` call of your own.

## Font families and layout options

With no arguments, a handler reads [`default_font_family`](@ref) and
[`default_layout_options`](@ref) each time it lays out a block. Pin either value
when different themes or figures need independent configuration:

```julia
handler = TeXLayoutHandler(
    family = font_family(:stix_two),
    options = TeXLayout.LayoutOptions(display_align = :left),
)
```

The document path also receives Makie's line-height, wrapping-width, and
resolved-justification attributes. TeXLayout does not yet perform soft line
breaking, so `word_wrap_width` controls the document box width but does not wrap
a paragraph. Arbitrary fractional justification is mapped to the nearest of
TeXLayout's left, centre, and right alignments.

To use HarfBuzz for document text and math-internal `\text{…}` fragments, load
`HarfBuzz_jll` and configure the handler or session default:

```julia
using HarfBuzz_jll
set_default_layout_options!(shaper = HarfBuzzShaper())
handler = TeXLayoutHandler()
```

This is required for genuine OpenType small capitals through `\textsc`.

## Matching ordinary Makie text

Makie still lays out non-LaTeX strings itself. Set its font theme from the same
TeXLayout family for a consistent figure:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

family = font_family(:termes)
handler = TeXLayoutHandler(family = family)

set_theme!(
    fonts = (;
        regular = family.regular,
        bold = family.bold,
        italic = family.italic,
        bolditalic = family.bolditalic,
    ),
    text_handler = handler,
)
```

All eight bundled families populate the four primary text faces. Shared Heros
and Cursor artifacts provide sans-serif and monospace companions.

## Makie 0.24 compatibility

Makie 0.24 has no `text_handler` attribute. On that release TeXLayout retains
the legacy automatic `MathTeXEngineExt` adapter, selected when TeXLayout,
MathTeXEngine, GeometryBasics, and LaTeXStrings are loaded together.

Once Makie 0.25's handler interface is present, the legacy specialization
delegates to MathTeXEngine's original implementation. Merely loading TeXLayout
therefore does not change Makie's default LaTeX renderer; the user explicitly
selects `TeXLayoutHandler` instead.
