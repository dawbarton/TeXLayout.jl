# TeXLayout.jl — Architecture and Developer Guide

This file documents key architectural decisions, invariants, and caveats for
Claude (and human developers) working on this codebase.

---

## Purpose

TeXLayout.jl is a Julia-idiomatic OpenType-aware LaTeX math typesetter.  It is intended
as a drop-in replacement for MathTeXEngine.jl in Makie.jl.  The design reference is
[KaTeX](https://katex.org/); the implementation is not a direct port but follows the same
algorithmic structure where it is sound.

---

## File structure

```
TeXLayout.jl/
├── src/
│   ├── TeXLayout.jl        # Module entry point; all exports declared here
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
│   ├── visualise_bitmap.jl       # Render one expression to PNG via FreeType (usage: julia tools/visualise_bitmap.jl "expr" out.png)
│   ├── visualise_svg.jl          # Render bounding-box diagram to SVG (glyph boxes + reference lines; good for debugging metrics)
│   ├── visualise_spacing.jl      # Grid of expressions showing inter-atom spacing
│   ├── demo_features.jl          # Generate accents.png / overunder.png / binary_reclass.png feature panels
│   ├── demo_sheet.jl             # Comprehensive single-page PNG demo for a font family (julia tools/demo_sheet.jl [:symbol|/path] [out.png])
│   └── prepare_font_artifacts.jl # Build artifact tarballs + draft Artifacts.toml for all 8 font families
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
| `demo_sheet.jl` | Comprehensive single-page PNG demo sheet showing all major layout features for a given font family. | `julia tools/demo_sheet.jl [:symbol\|/path/to/math.otf] [out.png]` |
| `prepare_font_artifacts.jl` | Downloads fonts from CTAN/GitHub, builds Julia artifact tarballs and draft `Artifacts.toml` stanzas for all 8 font families.  Run once when adding new fonts or publishing a release. | `julia tools/prepare_font_artifacts.jl [output_dir]` |

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
  - `NKFontSwitch` — produced by `\mathbf{…}`, `\mathit{…}`, `\mathrm{…}`, `\mathbb{…}`,
    `\mathcal{…}`, `\mathfrak{…}`, `\mathsf{…}`, `\mathtt{…}`, `\boldsymbol{…}`, and
    aliases.  `value` is the variant name (e.g. `"mathbf"`); `children[1]` is the body
    sequence.  The layout engine recurses with `ctx.font_variant` set to the variant.
  - `NKHorizBrace` — produced by `\overbrace`, `\underbrace`, `\overbracket`,
    `\underbracket`, `\overgroup`, `\undergroup`.  `value` is the bare command name;
    `children[1]` is the body.  The layout engine selects the widest-fitting variant
    (or extensible assembly) from `horiz_constructions`, then applies limits-style
    note placement for any sub/superscript on the brace node.
  - `NKLimitsOverride` — produced by `\limits` or `\nolimits`; wraps the preceding base
    node as its sole child; `value` is `"limits"` or `"nolimits"`.  The layout engine
    checks this before dispatching the script placement algorithm.
  - `NKMatrix` — produced by `\begin{env}…\end{env}`; `value` encodes
    `"env\x00nrow\x00colspec"` where `colspec` is either the verbatim column-spec
    string from `\begin{array}{…}` (e.g. `"|l|c|r|"`) or a derived string of
    `'c'`/`'l'` characters for shorthand environments.  Children are a flat row-major
    list of `NKGroup` cells (one per cell, padded to a rectangular grid).  The layout
    engine calls `_parse_colspec` to recover per-column alignments and vertical-rule
    counts; `\begin{array}` is the only environment in `_COLSPEC_ENVS` (reads a
    mandatory `{colspec}` argument); all others derive the colspec automatically.
    `||` in a colspec produces two adjacent rules separated by `_MATRIX_DOUBLERULESEP`.

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
- **Constructors:** `font_family(::Symbol)` looks up a named artifact (`:new_cm`,
  `:pagella`, `:termes`, `:schola`, `:bonum`, `:luciole`, `:stix_two`, `:fira_math`);
  `font_family(math_path; regular,
  bold, italic, bolditalic)` accepts file paths directly; `default_font_family()` is an
  alias for `font_family(:new_cm)`.
- **Three glyph lookup functions:**
  - `glyph_metrics(family, name)` — metrics for a PostScript glyph name in the math font
    (e.g. `"parenleft"`, `"alpha"`).  The form of single-letter names depends on the font;
    in NewCMMath, `"x"` maps to the *upright* roman form, not italic — use
    `glyph_metrics_by_codepoint` with a Unicode math-variant codepoint for italic letters.
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
- Element subtypes: `Glyph` (PS name + advance/bearing/bbox metrics in design units),
  `HRule` (width + thickness in em), `VRule` (height + thickness in em), `Space` (width
  in em).
- `_LayoutCtx` carries: `family` (`FontFamily`), `mc` (`MathConstants`), `upm`
  (design units per em), `vert_constructions` and `horiz_constructions` (extensible glyph
  tables from the MATH table), `top_accent_attachments` (PS name → x offset for accent
  alignment), `italic_corrections` (PS glyph name → design units; from the MATH table;
  used to shift subscripts on slanted bases such as `\int`), `min_connector_overlap`
  (minimum overlap between assembly parts), `mode` (`:math` or `:text`), and
  `font_variant` (`:default` or a `\mathXX` variant symbol).
- **`_base_italic_correction_em(boxes, ctx, scale)`** — helper that returns the italic
  correction of the first `Glyph` element in a box list, converted to em units (design
  units × scale / upm).  Returns 0.0 if no glyph is found or the glyph has no IC entry.
  Used by all script placement branches to implement the italic correction rules.

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

4. **`NKOperator` uses codepoint lookup, not PS-name lookup.** The codepoint path reliably
   returns the *upright* roman form in OpenType math fonts.  (In NewCMMath, PS names like
   `"x"` also happen to map to the upright form, but this is font-dependent — using
   codepoints is the portable approach for upright text.)

5. **Large operator glyphs are resolved by codepoint, not command name.** PS glyph names
   in OpenType math fonts diverge from LaTeX command names (`\sum` → `"summation"`,
   `\prod` → `"product"`, `\int` → `"integral"`, etc.).  `_DISPLAY_OP_CODEPOINTS` in
   `layout.jl` maps bare command names to Unicode codepoints; `glyph_name_by_codepoint`
   then obtains the correct PS name.  The display-size variant is selected from
   `vert_constructions` using the `display_operator_min_height` MATH constant.

6. **All math symbol glyphs should be resolved by Unicode codepoint, not PostScript name.**
   PS glyph naming conventions differ across fonts: NewCMMath/Pagella/STIXTwo use standard
   AGL names (`"parenleft"`, `"ltimes"`, `"alpha"`), while FiraMath uses uni-style names
   (`"uni0028"`, `"uni22C9"`, `"uni03B1"`) and Luciole uses its own convention (`"lparen"`,
   `"muppi"`, etc.).  Resolving by codepoint via `glyph_metrics_by_codepoint` is the only
   path that is portable across all fonts.  `_SYMBOL_CODEPOINTS` in `layout.jl` is the
   authoritative map from bare command name → Unicode codepoint for all ordinary symbols.
   Additionally, `glyph_metrics(family, "x")` returns the *upright* roman form in NewCMMath
   (the glyph named "x" is the regular-weight slot), whereas the cmap at U+0078 correctly
   yields the math-italic form — so codepoint resolution is also more correct for letters.
   The only necessary use of PS names is in `_construction_key`, which translates canonical
   AGL names to the font's own names when looking up `vert_constructions`/`horiz_constructions`
   (those dicts are keyed by the font's MATH table PS names and cannot be changed).

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
| Sub/superscripts | ✓ | Standard beside-base placement using MATH shift constants; italic correction applied to subscripts on slanted single-glyph bases (e.g. `\int`) — full IC shift left, matching KaTeX `supsub.ts` |
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
| Array/matrix environments | ✓ | `NKMatrix`; 8 named environments + `\begin{array}{colspec}`; per-column l/c/r alignment; single and double (`||`) vertical rules from colspec; two-pass grid layout centred on math axis |
| `default_font_family()` | ✓ | Returns `:new_cm` (NewCMMath) via Julia Artifacts; lazy download |

## Known limitations / future work
- **Multi-codepoint Unicode symbols** — a subset of negated and variant relations
  (`\nleqslant`, `\ngeqslant`, `\nleqq`, `\ngeqq`, `\lvertneqq`, `\gvertneqq`,
  `\varsubsetneq`, `\varsupsetneq`, `\npreceq`, `\nsucceq`, and similar) lack single
  Unicode codepoints.  Unicode defines them as a base character + U+0338 (COMBINING
  SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR-1), but OpenType math fonts do not
  consistently encode them as single glyphs at any codepoint.  These commands currently
  produce blank space.  Correct support would require two-glyph overlay (base + combining
  stroke at x offset) — analogous to how TeX builds `\not\leq` — or per-font codepoint
  investigation.  Do not add combining-sequence "codepoints" to `_SYMBOL_CODEPOINTS`; they
  will not work with `glyph_metrics_by_codepoint`.
- **`\bigplus` has no Unicode codepoint** — it is in `_CMD_ATOM_CLASS` (`:op`) but not in
  `_SYMBOL_CODEPOINTS`, so it produces blank space on all fonts.  It is not a standard
  LaTeX/AMS symbol and has no single Unicode codepoint; per-font investigation would be
  needed to support it.
- **Font switching (text slots)** — `\mathbf`, `\boldsymbol`, `\mathit` etc. map Latin,
  Greek, and common symbols (∇, ∂, variant letters) to their Unicode math-variant
  codepoints.  The `bold`, `italic`, `bold_italic` slots in `FontFamily` are not yet used;
  adding them would cover characters outside the Unicode math block.
- **Inter-atom spacing for `\text{}`** — text-mode fragments are not yet classified for
  atom-class spacing purposes.
- **Makie integration** — implemented via `ext/MathTeXEngineExt.jl` (a Julia package
  extension).  When `TeXLayout`, `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings`
  are all loaded, the extension adds a specialised
  `MathTeXEngine.generate_tex_elements(::LaTeXString)` method that uses TeXLayout's
  OpenType layout engine.  Makie's `texelems_and_glyph_collection` always passes a
  `LaTeXString`, so dispatch picks our method over MathTeXEngine's fallback.  The
  extension is fully precompiled (no `__precompile__(false)` needed) because adding
  a method with a more specific argument type is a new method, not an overwrite.
  **This is type piracy**: TeXLayout owns neither the function (`MathTeXEngine.generate_tex_elements`)
  nor the argument type (`LaTeXStrings.LaTeXString`).  It is pragmatic and confined
  to the extension, but alternative integration strategies (e.g. a dedicated Makie
  recipe or a proper upstream extension point in MathTeXEngine) will be investigated
  in future.
- **Makie extension ignores caller-specified font family** — the overridden
  `generate_tex_elements` accepts a `font_family` argument (for API compatibility
  with MathTeXEngine) but always uses `TeXLayout.default_font_family()` (`:new_cm`)
  regardless.  To use a different font family for math rendering in Makie, the
  extension would need to honour this argument or provide an alternative
  configuration mechanism (e.g. a global `set_makie_font_family!` setter).

---

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.
