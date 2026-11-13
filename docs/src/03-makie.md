# Makie Integration

TeXLayout works with Makie 0.24, the current release, through an automatic
adapter. Makie 0.25, still in development, adds a public text-layout protocol,
which TeXLayout implements with [`TeXLayoutHandler`](@ref), so integration no
longer requires intercepting MathTeXEngine methods. CI tests the handler
against Makie's development branch; most of this page describes it.

## Makie 0.24

Makie 0.24 has no `text_handler` attribute. On that release the
`MathTeXEngineExt` package extension, loaded when TeXLayout, MathTeXEngine,
GeometryBasics, and LaTeXStrings are all in the session (CairoMakie and GLMakie
bring the last three), replaces MathTeXEngine's layout of every `LaTeXString`
with TeXLayout's. No other code changes are needed:

```julia
using TeXLayout, CairoMakie, LaTeXStrings
set_default_font_family!(:stix_two)   # optional; read at layout time

fig = Figure()
Axis(fig[1, 1]; xlabel = L"x", ylabel = L"\int_0^x f(t)\,dt")
save("output.png", fig)
```

Font family and layout options come from [`default_font_family`](@ref) and
[`default_layout_options`](@ref); strings are routed between formula and
document layout as described below. Once Makie 0.25's handler interface is
present, this adapter delegates to MathTeXEngine's original implementation, so
merely loading TeXLayout does not change Makie's default LaTeX renderer.

## Quick start (Makie 0.25)

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
[`FontFamily`](@ref TeXLayout.FontFamily). TeXLayout's core caches continue to reuse font metrics and
parsed OpenType MATH tables.

## Inline math vs. mixed text and math

The handler, like the Makie 0.24 adapter, routes each `LaTeXString` in one of
two ways:

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
resolved-justification attributes. Makie's `lineheight` is a multiplier, so it
scales the handler's `line_height` (TeXLayout's baselineskip, 1.2 em by default)
rather than replacing it. Makie's justification always sets the text alignment,
so a pinned `options.align` has no effect through the handler. TeXLayout does not
yet perform soft line breaking, so `word_wrap_width` controls the document box
width but does not wrap a paragraph. Arbitrary fractional justification is mapped
to the nearest of TeXLayout's left, centre, and right alignments.

With `align = (:left, :baseline)` a multi-line block is anchored on the baseline
of its last line, as Makie's own text layout is.

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
and Cursor artifacts provide sans-serif and monospace companions. On Makie
0.24, leave out `text_handler`.
