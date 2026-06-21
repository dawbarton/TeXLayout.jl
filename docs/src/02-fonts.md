# Font Families

## Overview

A `FontFamily` bundles file paths for up to five font roles:

| Field | Required | Purpose |
|:------|:---------|:--------|
| `math` | **Yes** | OpenType math font (must contain a MATH table) |
| `regular` | No | Upright text font — used for `\text{}`/`\mbox{}` content and named operator letters |
| `italic` | No | Italic text font |
| `bold` | No | Bold text font |
| `bolditalic` | No | Bold-italic text font |

Only `math` is mandatory.  If `regular` is omitted, upright glyphs fall back to the
math font's own codepoint map, which yields upright roman forms in well-constructed
OpenType math fonts such as New Computer Modern.  The document text layer uses
`italic`, `bold`, and `bolditalic` for commands such as `\textit` and `\textbf`.
Math-mode font switching commands like `\mathbf` still map to Unicode math-variant
codepoints rather than these companion files.

Fonts are cached by file path; calling `font_family` repeatedly with the same arguments
is cheap.

## Bundled families

Eight font families are available out of the box.  All are downloaded lazily via Julia
Artifacts on first use and cached in Julia's depot.

| Symbol | Font | Style |
|:-------|:-----|:------|
| `:new_cm` | New Computer Modern Math | CM / serif (default) |
| `:pagella` | TeX Gyre Pagella Math | Palatino |
| `:termes` | TeX Gyre Termes Math | Times New Roman |
| `:schola` | TeX Gyre Schola Math | New Century Schoolbook |
| `:bonum` | TeX Gyre Bonum Math | ITC Bookman |
| `:luciole` | Luciole Math | Humanist sans (designed for low vision) |
| `:stix_two` | STIX Two Math v2.0.2 | Times |
| `:fira_math` | Fira Math + Fira Sans v0.3.4 | Geometric sans |

Artifacts are downloaded from Julia's artifact registry on first use and cached in
Julia's depot at `~/.julia/artifacts/` (or wherever `JULIA_DEPOT_PATH` points).

## Selecting a font

```julia
using TeXLayout

# Return a FontFamily for a single call.
family = font_family(:pagella)
boxes  = generate_tex_elements(raw"\Gamma(n+1) = n!", family)

# Override the session-wide default (affects all subsequent calls, including
# the Makie integration extension).
set_default_font_family!(:stix_two)

# Retrieve the current session-wide default.
family = default_font_family()
```

`set_default_font_family!` also accepts a `FontFamily` directly, which is useful when
you have constructed a family from custom paths (see below).

## Using a custom font

Supply the path to any OpenType math font:

```julia
family = font_family("/path/to/MyMath.otf")
```

To also provide a companion regular font for `\text{}`/`\mbox{}` and upright operator
letters, use the keyword arguments:

```julia
family = font_family("/path/to/MyMath.otf";
                     regular    = "/path/to/MyText-Regular.otf",
                     bold       = "/path/to/MyText-Bold.otf",
                     italic     = "/path/to/MyText-Italic.otf",
                     bolditalic = "/path/to/MyText-BoldItalic.otf")
```

**Requirements for the math font:**
- Must be a valid OpenType (`.otf`) or TrueType (`.ttf`) font.
- Must contain an OpenType `MATH` table.  If the table is absent, `font_family` will
  throw an error when the font is first used.
- Glyph lookup is performed by Unicode codepoint (via the `cmap` table) and by
  PostScript name (via the `post` table).  Both tables must be present for full
  functionality.

## Matching Makie text fonts

By default, Makie renders axis labels, tick labels, and legends using its own bundled
fonts, which may not match the math font selected for LaTeX strings.  To achieve a
consistent appearance, pass the same font files to both TeXLayout and Makie via
`set_theme!`:

```julia
using TeXLayout, CairoMakie, LaTeXStrings

# Choose the math font family once.
set_default_font_family!(:stix_two)
ff = default_font_family()

# Apply the companion text fonts to all Makie elements.
set_theme!(fonts = (;
    regular    = ff.regular,
    bold       = ff.bold,
    italic     = ff.italic,
    bolditalic = ff.bolditalic,
))

fig = Figure(size = (800, 400))
ax  = Axis(fig[1, 1];
           xlabel = L"x",
           ylabel = L"f(x) = e^{-x^2/2}")
x = LinRange(-3, 3, 400)
lines!(ax, x, exp.(-x .^ 2 ./ 2))
save("output.png", fig)
```

If a slot is `nothing` (e.g. `ff.regular === nothing` for a custom math-only family),
omit it from the `set_theme!` call or fall back to a font of your choice.

For the bundled TeX Gyre and New Computer Modern families, companion text fonts are
included in the artifact and all four slots are populated.  For `:fira_math`, the
companion text font is Fira Sans.  For `:luciole`, the companion text font is the
Luciole text font.

## Licences

All bundled font families are redistributed under open licences.  Each downloaded
artifact tarball includes the relevant licence file.

| Symbol | Font | Licence |
|:-------|:-----|:--------|
| `:new_cm` | [New Computer Modern](https://ctan.org/pkg/newcomputermodern) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:pagella` | [TeX Gyre Pagella Math](https://ctan.org/pkg/tex-gyre-math-pagella) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:termes` | [TeX Gyre Termes Math](https://ctan.org/pkg/tex-gyre-math-termes) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:schola` | [TeX Gyre Schola Math](https://ctan.org/pkg/tex-gyre-math-schola) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:bonum` | [TeX Gyre Bonum Math](https://ctan.org/pkg/tex-gyre-math-bonum) | [GUST Font Licence](https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt) (LPPL 1.3c) |
| `:luciole` | [Luciole](https://luciole-vision.com/) | Math: [SIL OFL 1.1](https://openfontlicense.org); text: [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `:stix_two` | [STIX Two Math](https://github.com/stipub/stixfonts) v2.0.2 | [SIL OFL 1.1](https://openfontlicense.org) |
| `:fira_math` | [Fira Math](https://github.com/firamath/firamath) v0.3.4 + [Fira Sans](https://github.com/mozilla/Fira) | [SIL OFL 1.1](https://openfontlicense.org) |
