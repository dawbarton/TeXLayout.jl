# Formatic.jl — Architecture and Developer Guide

This file documents key architectural decisions, invariants, and caveats for
Claude (and human developers) working on this codebase.

---

## Purpose

Formatic.jl is a Julia-idiomatic OpenType-aware LaTeX math typesetter.  It is intended
as a drop-in replacement for MathTeXEngine.jl in Makie.jl.  The design reference is
[KaTeX](https://katex.org/); the implementation is not a direct port but follows the same
algorithmic structure where it is sound.

---

## File structure

```
Formatic.jl/
├── src/
│   ├── Formatic.jl        # Module entry point; all exports declared here
│   ├── math_table.jl      # OpenType MATH table parser (binary → MathConstants struct)
│   ├── fonts.jl           # FontFamily, GlyphMetrics, font-cache, glyph lookup
│   ├── style.jl           # TexStyle enum (D/T/S/SS × cramped), style transition functions
│   ├── lexer.jl           # Tokeniser: LaTeX string → Vector{Token}
│   ├── parser.jl          # Recursive-descent parser: tokens → Node AST
│   └── layout.jl          # Layout engine: Node + style → Vector{LayoutBox}
├── test/
│   ├── runtests.jl        # Top-level testset; includes all test files
│   ├── fixtures/
│   │   └── newcm_math.jl  # Ground-truth constants extracted from NewCMMath-Regular.otf
│   ├── test_math_table.jl # Tests for MATH table parsing
│   ├── test_metrics.jl    # Tests for glyph metric lookups
│   ├── test_style.jl      # Tests for style cascade transitions
│   ├── test_lexer.jl      # Tests for the tokeniser
│   ├── test_parser.jl     # Tests for AST structure
│   ├── test_layout.jl     # Tests for layout engine invariants
│   └── test_katex.jl      # KaTeX-derived test suite (smoke, malformed, nested)
├── tools/
│   ├── visualise_bitmap.jl  # Render one expression to PNG via FreeType (usage: julia tools/visualise_bitmap.jl "expr" out.png)
│   ├── visualise_svg.jl     # Render bounding-box diagram to SVG (glyph boxes + reference lines; good for debugging metrics)
│   ├── visualise_spacing.jl # Grid of expressions showing inter-atom spacing
│   └── demo_features.jl     # Generate accents.png / overunder.png / binary_reclass.png feature panels
├── external/              # Source references (read-only; not part of the package)
│   ├── KaTeX/             # Original KaTeX JS implementation
│   ├── Makie.jl/          # Makie ecosystem packages
│   └── MathTeXEngine.jl/  # Previous Julia math typesetter
├── Project.toml
└── README.md
```

### Rendering tools

All tools in `tools/` activate the package's own project environment and require no extra setup beyond the registered dependencies.  `FreeTypeAbstraction` must be present (it is listed in `Project.toml`).  PNG output uses `convert` from ImageMagick, which must be available on `PATH`.

| Script | Purpose | Key options |
|--------|---------|-------------|
| `visualise_bitmap.jl` | Pixel-accurate render of a single expression using FreeType glyph rasterisation.  Useful as a quick sanity check after changing the layout engine. | `julia tools/visualise_bitmap.jl "expr" out.png` |
| `visualise_svg.jl` | Bounding-box diagram: each `LayoutBox` drawn as a coloured rectangle with glyph-name label, baseline and math-axis reference lines.  Best for debugging metric or positioning bugs. | `julia tools/visualise_svg.jl "expr" out.svg` |
| `visualise_spacing.jl` | Multi-row grid of spacing test expressions with inter-atom gaps highlighted. | `julia tools/visualise_spacing.jl` |
| `demo_features.jl` | Renders panels for accents, `\overline`/`\underline`, and binary reclassification (one PNG per feature) into a specified output directory. | `julia tools/demo_features.jl /path/to/output/` |

---

## Pipeline

```
String  ──tokenize──►  Vector{Token}
                              │
                        parse_latex
                              │
                              ▼
                           Node (AST)
                              │
                    layout(node, family, style)
                              │
                              ▼
                     Vector{LayoutBox}
```

Each stage is stateless and pure (no global mutation beyond the font cache).

---

## Key types

### `Token` / `TokenKind` (`lexer.jl`)
- Kinds: `TKChar`, `TKCommand`, `TKSup` (`^`), `TKSub` (`_`), `TKLBrace`, `TKRBrace`,
  `TKMathShift`, `TKAmpersand`, `TKSpace`, `TKEOF`.
- The lexer always appends a single `TKEOF` sentinel at position `ncodeunits(s)+1`.
  **The parser must never advance past this sentinel** — the `_parse_primary!` function
  returns `Node(NKSpace, "")` without advancing when it sees `TKEOF`.

### `Node` / `NodeKind` (`parser.jl`)
- Immutable struct: `kind::NodeKind`, `value::String`, `children::Vector{Node}`.
- Leaf nodes (chars, spaces, commands, operators) have empty `children`; interior nodes
  have empty or placeholder `value`.
- Key node kinds:
  - `NKChar` — single character; `value` is the one-character string.
  - `NKCommand` — unrecognised command; `value` is the full token including `\`.
  - `NKSpace` — explicit horizontal space; `value` is a decimal string giving the
    width in em units (may be negative for `\!` and similar).  Commands `\,` `\:` `\;`
    `\!` `\quad` `\qquad` `\kern` `\mkern` `\hskip` `\mskip` and their aliases all
    produce this node.  1 mu = 1/18 em.
  - `NKOperator` — named math operator (e.g. `\sin`); `value` is the bare name (`"sin"`).
    Rendered upright using `glyph_metrics_upright`.  In Display style, operators in
    `_LIMITS_OPERATORS` (`lim`, `limsup`, `liminf`, `sup`, `inf`, `max`, `min`, `det`,
    `gcd`, `Pr`) automatically use limits placement.
  - `NKDecorated` — children are `[base, sub, sup]` (always in that order regardless of
    source order).
  - `NKFrac` — children `[numerator, denominator]`.
  - `NKSqrt` — children `[body]` or `[degree, body]`.
  - `NKDelimited` — children are the interior sequence (no `\right` node); `value` encodes
    the PostScript glyph names of the left and right delimiters separated by `\x00`
    (e.g. `"parenleft\x00parenright"`).  An empty substring means a null delimiter (no glyph
    rendered).  The layout engine looks up `vert_constructions` from the MATH table to pick
    the smallest variant tall enough to cover the inner content, centred on the math axis.
  - `NKLimitsOverride` — produced by `\limits` or `\nolimits`; wraps the preceding base
    node as its sole child; `value` is `"limits"` or `"nolimits"`.  The layout engine
    checks this before dispatching the script placement algorithm.

### `TexStyle` (`style.jl`)
Eight styles: `Display`, `CrampedDisplay`, `Text`, `CrampedText`, `Script`,
`CrampedScript`, `ScriptScript`, `CrampedScriptScript`.  Use `sup_style`,
`sub_style`, `frac_num_style`, `frac_den_style`, `cramp_style` to transition.
`size_scale` returns the font-size multiplier for a style (1.0 / 0.7 / 0.5 by default,
driven by `MathConstants.script_percent_scale_down` and
`MathConstants.script_script_percent_scale_down`).

### `FontFamily` / `GlyphMetrics` (`fonts.jl`)
- `FontFamily` holds font paths: `math` (mandatory), `regular`, `italic`, `bold`,
  `bold_italic` (all optional).
- **Three glyph lookup functions:**
  - `glyph_metrics(family, name)` — PS glyph name in the math font (returns italic math
    glyphs for single letters such as `"x"`, `"alpha"`).
  - `glyph_metrics_by_codepoint(family, cp)` — Unicode codepoint in the math font (throws
    on miss).
  - `glyph_metrics_upright(family, ch)` — upright character; uses `regular` font if
    present, otherwise falls back to math font codepoint mapping which yields upright
    forms in OpenType math fonts like NewCMMath (returns `nothing` on miss).
- Fonts are cached by path in `_FONT_CACHE`; safe to call repeatedly.

### `LayoutBox` / `TeXElement` (`layout.jl`)
- `LayoutBox`: `element::TeXElement`, `x::Float64`, `y::Float64`, `scale::Float64`.
  Positions are in em units (design units / UPM × scale); x right, y up, origin at
  formula baseline.
- Element subtypes: `Glyph` (name + cached metrics), `HRule` (width + thickness),
  `VRule`, `Space`.
- `_LayoutCtx` carries `family`, `mc` (MathConstants), `upm`, `vert_constructions`, and
  `min_connector_overlap` (all from the MATH table) so the `NKDelimited` branch can look
  up delimiter variants and construct extensible assemblies.

### `MathConstants` (`math_table.jl`)
Parsed directly from the font's OpenType MATH table.  All constants are in design units;
divide by `upm` (from `_LayoutCtx.upm`) to get em values.  No hard-coded fallbacks are
used anywhere — if the font lacks a MATH table, `load_math_table` throws.

---

## Architectural invariants

1. **The TKEOF sentinel is never consumed.** Every loop in the parser checks for TKEOF
   before calling sub-parsers.  `_parse_primary!` returns a zero-advance `NKSpace` node
   on TKEOF without advancing `pos`.

2. **The parser never throws on ill-formed input.** Malformed expressions (double scripts,
   unclosed braces, missing `\right`) produce degraded but structurally valid ASTs.

3. **All metric constants come from the MATH table.** This includes axis height, script
   shifts, fraction shifts, radical gaps, and rule thicknesses.  Adding support for a new
   construct requires identifying the correct MATH table fields (see the OpenType spec
   or KaTeX's `fontMetricsData.js`).

4. **`NKOperator` uses codepoint lookup, not PS-name lookup.** For letters a–z and A–Z,
   the PS-name path in NewCMMath (and most OpenType math fonts) returns the *italic*
   variant; the codepoint path returns the *upright* variant.  This is intentional.

5. **Large operator glyphs are resolved by codepoint, not command name.** PS glyph names
   in OpenType math fonts diverge from LaTeX command names (`\sum` → `"summation"`,
   `\prod` → `"product"`, `\int` → `"integral"`, etc.).  `_DISPLAY_OP_CODEPOINTS` in
   `layout.jl` maps bare command names to Unicode codepoints; `glyph_name_by_codepoint`
   then obtains the correct PS name.  The display-size variant is selected from
   `vert_constructions` using the `display_operator_min_height` MATH constant.

6. **Layout is purely additive.** `_layout_node!` only pushes to `boxes`; it never
   removes or modifies existing entries.  Temporary `LayoutBox` vectors (used for
   centering fractions and limits) are merged in with adjusted coordinates.

---

## Implemented features

A summary of major features and their status.

| Feature | Status | Notes |
|---------|--------|-------|
| Fractions (`\frac`) | ✓ | TeX Rule 15d/15e gap clamping; fraction rule from MATH table |
| Square roots (`\sqrt`, `\sqrt[n]`) | ✓ | Pre-built variants + extensible assembly; top-anchored |
| Delimiters (`\left`/`\right`) | ✓ | Auto-sized from `vert_constructions`; centred on math axis |
| Sub/superscripts | ✓ | Standard beside-base placement using MATH shift constants |
| Named operators (`\sin`, `\cos`, `\lim`, …) | ✓ | Upright glyphs; 30+ operators including `\limsup`, `\liminf` |
| Large operators (`\sum`, `\prod`, `\int`, …) | ✓ | Display-size variant selected via `display_operator_min_height` |
| Limits placement | ✓ | Sub/sup centred below/above in Display style; 4 MATH constants used |
| `\limits` / `\nolimits` override | ✓ | Parsed as `NKLimitsOverride`; respected in all script branches |
| Explicit spacing (`\,` `\;` `\quad` `\kern` …) | ✓ | Width in em; negative spaces supported |
| Inter-atom spacing | ✓ | TeX atom-class table (ord/bin/rel/op/open/close/punct/inner) |
| Accents (`\hat`, `\bar`, `\vec`, …) | ✓ | Rule 12; `MathTopAccentAttachment` alignment; 11 non-stretchy commands |
| `\overline`, `\underline` | ✓ | Rules 9 & 10; gap and thickness from MATH table |
| Horizontal extensibles (`\widehat`, `\widetilde`) | ✓ | Variant selection + extensible assembly from `horiz_constructions`; centred over base |
| Font switching (`\mathbf`, `\mathrm`, …) | ✓ | Unicode math-variant codepoints; upright fallback for `\mathrm`; propagates into sub/superscripts |
| Horizontal braces (`\overbrace`, `\underbrace`, …) | ✓ | `NKHorizBrace`; variant selection from `horiz_constructions`; limits-style note placement; 6 commands |
| Array/matrix environments | ✓ | `NKMatrix`; 8 named environments (matrix, pmatrix, bmatrix, Bmatrix, vmatrix, Vmatrix, smallmatrix, cases); two-pass grid layout centred on math axis |
| `default_font_family()` | ✓ | Returns `:new_cm` (NewCMMath) via Julia Artifacts; lazy download |

## Known limitations / future work
- **Font switching (text slots)** — `\mathbf` etc. use Unicode math-variant codepoints
  from the math font.  The `bold`, `italic`, `bold_italic` slots in `FontFamily` are not
  yet used; adding them would give better coverage for characters outside the math block
  (e.g., Greek bold letters) and is deferred to steps 5–6.
- **`default_font_family()`** — now implemented; returns NewCMMath via the Julia
  Artifacts system.  The five font tarballs in `shared/font_archives/` must be
  uploaded to a GitHub Release and the URLs in `Artifacts.toml` updated before
  the package is usable by other users.
- **Inter-atom spacing for `\text{}`** — text-mode fragments are not yet classified for
  atom-class spacing purposes.

---

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.
