# Makie Integration

TeXLayout ships a Julia package extension (`MathTeXEngineExt`) that integrates with
Makie transparently — no changes to Makie or MathTeXEngine are required.

## How it works

When `TeXLayout`, `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings` are all
present in the same Julia session — which happens automatically when `CairoMakie` or
`GLMakie` is loaded — Julia activates `MathTeXEngineExt`.  The extension adds a
more-specific method:

```
MathTeXEngine.generate_tex_elements(::LaTeXString, ...)
```

Makie's internal `texelems_and_glyph_collection` always passes a `LaTeXString`, so
normal Julia method dispatch selects the TeXLayout method over MathTeXEngine's
built-in fallback.  No monkey-patching, no `__precompile__(false)`, and no changes to
any upstream package are needed.

For repeated rendering with the same font family, the extension reuses a cached
runtime bundle derived from the active `FontFamily`: loaded FreeType faces for each
font-slot fallback path, the derived MathTeXEngine font family, and glyph-index
lookups keyed by `(font path, glyph name)`.  The underlying TeXLayout pipeline also
reuses parsed MATH tables.  In steady-state Makie workloads this avoids reparsing
the OpenType font data on every formula.

## Inline math vs. mixed text and math

The extension inspects each `LaTeXString` and routes it one of two ways:

- **A single inline-math span** — a string that starts and ends with a single `$`
  and contains no other `$` (the usual `L"…"` form, e.g. `L"x^2"` → `"$x^2$"`) — is
  laid out as one formula in **`Display`** style, exactly as MathTeXEngine would.
  This is the common case for axis labels, legend entries, and annotations.
- **Anything else** is routed through [`layout_document`](@ref): surrounding prose,
  several `$…$` spans, `\(…\)` inline math, and `$$…$$` / `\[…\]` display math.  This
  lets a single `text!` call render mixed text-and-math content.

```julia
using TeXLayout, CairoMakie, LaTeXStrings

fig = Figure()
Label(fig[1, 1], L"x^2 + \frac{1}{2}"; fontsize = 40)                       # → math
Label(fig[2, 1], latexstring("Energy \$E=mc^2\$ is famous."); fontsize = 30) # → document
Label(fig[3, 1], latexstring("\$\$\\int_0^1 x^2\\,dx = \\tfrac13\$\$"); fontsize = 30) # → display
save("mixed.png", fig)
```

!!! note
    Because `L"…"` wraps its argument in `$…$`, a plain `L"x^2"` is a single inline
    span and takes the math path.  To force the document path (e.g. for prose with
    embedded math) construct the string so it is *not* a single `$…$` span — for
    instance with surrounding text, or via `latexstring(...)`.

### Document-layer options through Makie

Makie's call site (`generate_tex_elements(::LaTeXString)`) has a fixed signature, so
per-render [`LayoutOptions`](@ref) cannot be passed for the document path.  Instead,
set them session-wide with [`set_default_layout_options!`](@ref) — the extension
reads [`default_layout_options`](@ref) on every document-path render, just as it
reads [`default_font_family`](@ref) for the font:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

# Centre text and equations within a fixed 40 em column for all Makie renders.
set_default_layout_options!(width = 40.0, align = :center, display_align = :center)

Label(fig[1, 1], latexstring("A line of text and a display:\n\$\$x^2 + y^2 = r^2\$\$"))
```

The keyword form merges over the current default, so you can change just one field
(e.g. `set_default_layout_options!(align = :center)`).  A single inline-math
`L"…"` string still takes the Display-style math path, but math-internal
`\text{…}` / `\mbox{…}` fragments in that formula use the default shaper.  To opt
into HarfBuzz shaping for document text and math-internal text, load `HarfBuzz_jll`
and set:

```julia
using TeXLayout, HarfBuzz_jll
set_default_layout_options!(shaper = HarfBuzzShaper())
```

This opt-in is required for OpenType-substitution-based styles such as genuine
small capitals. The following renders lowercase letters through Termes's `smcp`
feature while leaving the initial capital at full cap height:

```julia
using TeXLayout, HarfBuzz_jll

set_default_font_family!(:termes)
set_default_layout_options!(shaper = HarfBuzzShaper())

using CairoMakie

fig = Figure()
ax = Axis(
    fig[1, 1],
    title = L"\text{\textsc{This text should be in small caps}}",
    xlabel = "X-axis",
    ylabel = "Y-axis",
)
lines!(ax, 1:10, rand(10))
display(fig)
```

`MetricShaper` deliberately does not synthesize small caps by scaling uppercase
glyphs; attempting to use `\textsc` with it raises an error explaining how to
select `HarfBuzzShaper`.

## Quick start

Load `TeXLayout` before (or alongside) `CairoMakie`; the extension activates
automatically.

```julia
using TeXLayout   # activates MathTeXEngineExt automatically when Makie is loaded
using CairoMakie, LaTeXStrings

fig = Figure()
ax  = Axis(fig[1,1])
text!(ax, 0.5, 0.5;
      text      = L"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
      fontsize   = 32,
      align      = (:center, :center))
save("output.png", fig)
```

## Changing the math font

Call [`set_default_font_family!`](@ref) before any rendering call.  The extension
always uses the current session-wide default, so changing it here changes what Makie
renders.

```julia
using TeXLayout
set_default_font_family!(:stix_two)

using CairoMakie, LaTeXStrings
# All L"…" strings are now rendered with STIX Two Math.
```

Any of the eight bundled families (`:new_cm`, `:pagella`, `:termes`, `:schola`,
`:bonum`, `:luciole`, `:stix_two`, `:fira_math`) or a custom [`FontFamily`](@ref)
built from file paths can be passed to `set_default_font_family!`.  See
[Font Families](02-fonts.md) for details.

## Matching text and math fonts

By default, Makie renders non-LaTeX axis labels, tick marks, and legends using its
own bundled fonts.  The TeXLayout document path uses the companion text slots in the
active `FontFamily` for commands such as `\textbf` and `\textit`; to make ordinary
Makie text match that same family, pass those companion fonts to Makie via
`set_theme!`:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

ff = default_font_family()   # New Computer Modern Math (default)

set_theme!(fonts = (;
    regular    = ff.regular,
    bold       = ff.bold,
    italic     = ff.italic,
    bolditalic = ff.bolditalic,
))

fig = Figure(size = (800, 500))
ax  = Axis(fig[1, 1]; xlabel = L"x", ylabel = L"f(x)")
x   = LinRange(0, 2π, 400)
lines!(ax, x, sin.(x); label = L"\sin(x)")
axislegend(ax)
save("output.png", fig)
```

!!! note
    If `ff.regular` is `nothing` (a math-only font family such as a custom `.otf`
    without companion text fonts), omit the affected slots from the `set_theme!` call
    or replace them with a system font of your choice.

For all eight bundled families, companion text fonts are included in the artifact and
all four slots are populated.

## The `font_family` argument

`MathTeXEngine.generate_tex_elements` accepts a `font_family` keyword argument for
API compatibility.  The extension currently **ignores** this argument and always uses
`TeXLayout.default_font_family()`.  To change the font used by Makie, call
`set_default_font_family!` before rendering; the extension picks up the new default
automatically.

## Type piracy note

The extension adds a method to `MathTeXEngine.generate_tex_elements` for the argument
type `LaTeXStrings.LaTeXString`.  TeXLayout owns neither the function nor the argument
type — this is a form of **type piracy**.

The approach is pragmatic and deliberately confined to the extension module.  It does
not overwrite any existing method; it only adds a more-specific one, so the original
MathTeXEngine behaviour is still available if TeXLayout is not loaded.  Alternative
integration strategies (a dedicated Makie recipe, or an upstream extension point in
MathTeXEngine) will be explored in future work.
