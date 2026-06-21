# API Reference

This page documents every symbol exported by TeXLayout.jl.  Docstrings are pulled
directly from the source; follow the cross-references for related types and functions.

## Top-level entry point

`generate_tex_elements` is the single function most users need.  It runs the complete
tokenise → parse → layout pipeline and returns a flat list of positioned elements
ready for a renderer.

```@docs
generate_tex_elements
```

## Pipeline functions

For advanced use — choosing a non-default style, inspecting the intermediate AST, or
driving the layout stage with a pre-parsed node — the two pipeline stages are exported
individually.

### Parsing

```@docs
parse_latex
```

### Layout

```@docs
layout
```

## Document layout

`layout_document` handles mixed text/math input and returns a measured `TeXBox`.
Use `LayoutOptions` or keyword arguments to control line spacing, display spacing,
paragraph spacing (`parskip`), alignment, width, and text shaping.

```@docs
layout_document
TeXBox
LayoutOptions
TextShaper
MetricShaper
```

## Font API

These functions control which fonts are used for glyph lookup and metric resolution.

### `FontFamily` type

```@docs
FontFamily
```

### Constructors

```@docs
font_family
```

### Default family

```@docs
default_font_family
set_default_font_family!
```

## Style

`TexStyle` encodes the eight TeX math styles (Display, Text, Script, ScriptScript,
and their cramped counterparts).  The enum values themselves are *not* exported to
avoid conflicts with `Base.Display` and `Base.Text`; access them as
`TeXLayout.Display`, `TeXLayout.Text`, etc.

```@docs
TexStyle
```

## Output types

The layout engine returns a `Vector{LayoutBox}`.  Each box wraps one `TeXElement`
together with its position and scale.

### Container

```@docs
LayoutBox
```

### Element union

`TeXElement` is the abstract base type for all renderable primitives.  Dispatch on
the four concrete subtypes below to handle each kind of element.

```@docs
TeXElement
```

### Concrete element types

```@docs
Glyph
HRule
VRule
Space
```
