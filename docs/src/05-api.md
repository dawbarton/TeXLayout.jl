# API Reference

TeXLayout exports only the configuration surface normally needed by Makie users.
Advanced layout and renderer APIs remain available through qualified
`TeXLayout.Xxx` access or explicit imports.

## Exported configuration API

```@docs
default_layout_options
set_default_layout_options!
HarfBuzzShaper
TeXLayoutHandler
font_family
default_font_family
set_default_font_family!
```

## Qualified advanced API

These names are intentionally not exported:

```@docs
TeXLayout.generate_tex_elements
TeXLayout.parse_latex
TeXLayout.layout
TeXLayout.layout_document
TeXLayout.TeXBox
TeXLayout.LayoutOptions
TeXLayout.TextShaper
TeXLayout.MetricShaper
TeXLayout.FontFamily
TeXLayout.TexStyle
TeXLayout.LayoutBox
TeXLayout.TeXElement
TeXLayout.Glyph
TeXLayout.GlyphID
TeXLayout.HRule
TeXLayout.VRule
TeXLayout.Space
```
