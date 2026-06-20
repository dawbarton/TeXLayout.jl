# Getting Started

## Installation

TeXLayout.jl is registered in the Julia General registry.  Install it from the Julia
REPL package mode (press `]`):

```
] add TeXLayout
```

Font artifacts are **not** bundled inside the package; they are downloaded lazily from
Julia's artifact registry the first time a particular font family is requested.  A
network connection is required on that first use; subsequent uses are served from Julia's
local depot cache.

## Basic usage

The top-level entry point is `generate_tex_elements`, which runs the full pipeline and
returns a `Vector{LayoutBox}`:

```julia
using TeXLayout

boxes = generate_tex_elements(raw"\frac{1}{\sqrt{2\pi}} e^{-x^2/2}")
```

### What is a `LayoutBox`?

Each element of `boxes` is a `LayoutBox` with four fields:

| Field | Type | Description |
|:------|:-----|:------------|
| `.element` | `TeXElement` | The graphical primitive to render |
| `.x` | `Float64` | Horizontal position in em units (baseline origin, right is positive) |
| `.y` | `Float64` | Vertical position in em units (baseline origin, up is positive) |
| `.scale` | `Float64` | Font-size multiplier relative to the requested display size |

`TeXElement` is a union of four concrete types:

| Type | Key fields | Description |
|:-----|:-----------|:------------|
| `Glyph` | `.glyph_name`, `.font_slot`, `.advance`, `.left_side_bearing`, `.x_min`, `.y_min`, `.x_max`, `.y_max` | A single rendered glyph |
| `HRule` | `.width`, `.thickness` | A horizontal rule (fraction bar, radical overline, …) |
| `VRule` | `.height`, `.thickness` | A vertical rule (array column separator) |
| `Space` | `.width` | Explicit horizontal white space |

All metric fields in `Glyph`, `HRule`, `VRule`, and `Space` are in **em units** (already
scaled by `.scale`).

### Inspecting the result

```julia
for box in boxes
    el = box.element
    if el isa Glyph
        println("Glyph '$(el.glyph_name)'  font=$(el.font_slot)  ",
                "x=$(round(box.x, digits=4))  y=$(round(box.y, digits=4))  ",
                "scale=$(box.scale)")
    elseif el isa HRule
        println("HRule  width=$(round(el.width, digits=4))  ",
                "thickness=$(round(el.thickness, digits=4))")
    elseif el isa VRule
        println("VRule  height=$(round(el.height, digits=4))")
    elseif el isa Space
        println("Space  width=$(round(el.width, digits=4))")
    end
end
```

## Choosing a style

`generate_tex_elements` defaults to `TeXLayout.Display` style (full-size operators with
limits placed above/below).  To lay out inline math at `Text` style, or to access the
individual pipeline stages, use `parse_latex` and `layout` directly:

```julia
using TeXLayout

node  = parse_latex(raw"\sum_{k=0}^n k^2")          # tokenise + parse → Node AST
boxes = layout(node, default_font_family(), TeXLayout.Display)  # → Vector{LayoutBox}
```

The eight `TexStyle` values are accessed as `TeXLayout.XYZ` (they are not exported, to
avoid name conflicts with `Base.Display` and `Base.Text`):

| Value | Description |
|:------|:------------|
| `TeXLayout.Display` | Full-size; large operators with limits above/below |
| `TeXLayout.Text` | Inline size; large operators with limits beside |
| `TeXLayout.Script` | Superscript / subscript size (≈ 70 % by default) |
| `TeXLayout.ScriptScript` | Second-level script size (≈ 50 % by default) |
| `TeXLayout.CrampedDisplay` | Like `Display` but sub/sup shifted less (used inside radicals) |
| `TeXLayout.CrampedText` | Like `Text` but cramped |
| `TeXLayout.CrampedScript` | Like `Script` but cramped |
| `TeXLayout.CrampedScriptScript` | Like `ScriptScript` but cramped |

The exact `Script` and `ScriptScript` scale factors are read from the font's MATH table
(`script_percent_scale_down` and `script_script_percent_scale_down`), so they vary
slightly between font families.

## Choosing a font

The default font is New Computer Modern Math (`:new_cm`).  See [Font Families](02-fonts.md)
for the full list and licence details.  Two quick patterns:

```julia
# Change the session-wide default — affects all subsequent calls, including
# the Makie integration extension.
set_default_font_family!(:stix_two)

# Use a specific family for one call only.
family = font_family(:pagella)
boxes  = generate_tex_elements(raw"\alpha + \beta", family)
```

## Coordinates and units

- The **origin** (`x = 0`, `y = 0`) is the **formula baseline** — the line on which
  ordinary lowercase letters sit.
- **`x`** increases to the right; **`y`** increases upward.
- All positions and dimensions are in **em units**.  One em equals the requested
  font size (in whatever unit your renderer uses — pixels, points, etc.).
- The `.scale` field is a dimensionless multiplier.  At the top level it is `1.0`;
  inside a `\sum` subscript it is approximately `0.7`; inside nested scripts it is
  approximately `0.5`.  These values come from the font's MATH table and may differ
  slightly across font families.

To convert em units to pixels, multiply by the font size in pixels:

```julia
fontsize_px = 32.0   # render at 32 px em

for box in boxes
    x_px = box.x * fontsize_px
    y_px = box.y * fontsize_px
    # ... render box.element at (x_px, y_px)
end
```

## Rendering the output

`LayoutBox` is deliberately renderer-agnostic — it carries no dependency on any
particular graphics library.

**Makie users:** just load `TeXLayout` before `CairoMakie` or `GLMakie`; the
`MathTeXEngineExt` extension takes over automatically.  See [Makie Integration](03-makie.md).

**Custom renderers:** iterate over `boxes` and dispatch on the element type:

```julia
fontsize_px = 32.0

for box in boxes
    el  = box.element
    x   = box.x * fontsize_px
    y   = box.y * fontsize_px

    if el isa Glyph
        # Resolve the physical font file.
        font_path = TeXLayout._font_path_for_slot(family, el.font_slot)
        # Render the glyph named `el.glyph_name` from `font_path`
        # at pixel position (x, baseline_y - y) at size (box.scale * fontsize_px).
        render_glyph(el.glyph_name, font_path, x, y, box.scale * fontsize_px)

    elseif el isa HRule
        # Draw a filled rectangle of width `el.width * fontsize_px`
        # and height `el.thickness * fontsize_px`, bottom-left at (x, y).
        draw_hrule(x, y, el.width * fontsize_px, el.thickness * fontsize_px)

    elseif el isa VRule
        draw_vrule(x, y, el.height * fontsize_px, el.thickness * fontsize_px)

    elseif el isa Space
        # Nothing to draw; advance x by el.width * fontsize_px.
    end
end
```

`el.font_slot` identifies the math or companion text slot used for glyph-index
resolution.  Internal helper `TeXLayout._font_path_for_slot` applies the same
fallback order as TeXLayout's own render/debug tools.
