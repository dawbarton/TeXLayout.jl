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
│   ├── TeXLayout.jl        # Module entry point; exports and include order
│   ├── math_table.jl       # OpenType MATH table parser + per-font MathTable cache
│   ├── fonts.jl            # FontFamily, GlyphMetrics, artifact-backed font lookup, font cache
│   ├── style.jl            # TexStyle enum (D/T/S/SS × cramped), style transition helpers
│   ├── lexer.jl            # Tokeniser: LaTeX string → Vector{Token}
│   ├── parser.jl           # Recursive-descent parser: tokens → Node AST
│   └── layout.jl           # Layout engine: Node + style → Vector{LayoutBox}
├── ext/
│   └── MathTeXEngineExt.jl # Makie/MathTeXEngine extension + cached runtime conversion bundle
├── test/
│   ├── runtests.jl         # Top-level testset; includes all test files
│   ├── fixtures/
│   │   └── newcm_math.jl   # Ground-truth constants extracted from NewCMMath-Regular.otf
│   ├── test_math_table.jl  # Tests for MATH table parsing and cache behaviour
│   ├── test_metrics.jl     # Tests for glyph metric lookups
│   ├── test_style.jl       # Tests for style cascade transitions
│   ├── test_lexer.jl       # Tests for the tokeniser
│   ├── test_parser.jl      # Tests for AST structure
│   ├── test_layout.jl      # Tests for layout engine invariants and feature coverage
│   └── test_katex.jl       # KaTeX-derived test suite (smoke, malformed, nested)
├── tools/
│   ├── visualise_bitmap.jl      # Rasterise one expression to PNG
│   ├── visualise_svg.jl         # SVG bounding-box / baseline / axis visualiser
│   ├── visualise_spacing.jl     # Inter-atom spacing visualiser
│   ├── visualise_metrics.jl     # MathTeXEngine-style glyph metric overlay visualiser
│   ├── visualise_metrics_makie.jl # CairoMakie text! + metric overlay visualiser
│   ├── demo_features.jl         # Feature panels for accents / over-under / braces / etc.
│   ├── demo_sheet.jl            # General single-page feature sheet for a font family
│   ├── demo_matrix.jl           # Matrix / array environment demo output
│   ├── demo_makie.jl            # Smoke test and CairoMakie integration demo
│   ├── demo_unified_fonts.jl    # Makie text+math font matching demo
│   ├── stress_test_sheet.jl     # Stress sheet targeting edge cases and regressions
│   ├── stress_test_all.sh       # Batch-render stress sheets for bundled families
│   ├── png_diff.jl              # Signed PNG diff visualiser for rendered outputs
│   └── prepare_font_artifacts.jl # Build artifact tarballs + draft Artifacts.toml stanzas
├── docs/
│   ├── make.jl             # Documenter.jl build script
│   ├── Project.toml
│   └── src/                # Markdown source pages
├── external/               # Source references (read-only; not part of the package)
│   ├── KaTeX/
│   ├── Makie.jl/
│   └── MathTeXEngine.jl/
├── artifacts/              # Bundled font payloads and extracted font files
├── Artifacts.toml          # Artifact definitions for bundled fonts
├── CLAUDE.md               # This architecture/developer guide
├── katex_rules.md          # Rule-by-rule implementation notes against KaTeX/TeX
├── notes.md                # Cross-session engineering notes
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
| `visualise_metrics.jl` | MathTeXEngine-style metric overlay view: rendered glyphs with coloured left-bearing / advance-gap / above-baseline / descender regions, plus baseline and axis guides. | `julia tools/visualise_metrics.jl "expr" [out.png\|out.ppm] [:font_symbol\|/path/to/math.otf]` |
| `visualise_metrics_makie.jl` | CairoMakie-backed companion to `visualise_metrics.jl`: draws the expression via Makie's `text!` and overlays the same TeXLayout-derived metric guides in data space. | `julia tools/visualise_metrics_makie.jl "expr" [out.png\|out.svg\|out.pdf] [:font_symbol\|/path/to/math.otf]` |
| `demo_features.jl` | Renders feature panels used for quick visual checks of accents, braces, over/under constructs, and related layout rules. | `julia tools/demo_features.jl /path/to/output/` |
| `demo_sheet.jl` | Comprehensive single-page PNG demo sheet showing major layout features for a given font family. | `julia tools/demo_sheet.jl [:symbol\|/path/to/math.otf] [out.png]` |
| `demo_makie.jl` / `demo_unified_fonts.jl` | Smoke-test the MathTeXEngine extension and show Makie figures with TeXLayout-driven math rendering. | `julia tools/demo_makie.jl` |
| `demo_matrix.jl` / `stress_test_sheet.jl` | Focused demos for matrix/array layout and a broader regression-oriented stress sheet. | `julia tools/stress_test_sheet.jl [:symbol\|/path] [out.png]` |
| `stress_test_all.sh` | Batch-renders the stress sheet for all bundled font families. | `bash tools/stress_test_all.sh` |
| `png_diff.jl` | Signed red/green PNG diff for comparing two rendered outputs; pads mismatched image sizes onto a white canvas first. | `julia tools/png_diff.jl before.png after.png [diff.png]` |
| `prepare_font_artifacts.jl` | Downloads fonts from CTAN/GitHub, builds Julia artifact tarballs and draft `Artifacts.toml` stanzas for all 8 font families.  Run once when adding new fonts or publishing a release. | `julia tools/prepare_font_artifacts.jl [output_dir]` |

### Formatting

Format Julia code with Runic.jl.  The simplest path is the `runic` Bash command
from the repository root; Runic is also installed in the global Julia
environment `@runic`.  Any touched Julia source or test files should be left in
Runic format before finishing a change.

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

Each stage is stateless and pure apart from memoization caches: `fonts.jl`
caches loaded FreeType faces and `hmtx` data by path, `math_table.jl` caches
parsed `MathTable` values by math-font path, and `ext/MathTeXEngineExt.jl`
caches the Makie-facing runtime bundle by effective `FontFamily`.

---

## Key types

### `Token` / `TokenKind` (`lexer.jl`)
- Kinds: `TKChar`, `TKCommand`, `TKSup` (`^`), `TKSub` (`_`), `TKLBrace`, `TKRBrace`,
  `TKMathShift`, `TKAmpersand`, `TKSpace`, `TKEOF`.
- The lexer always appends a single `TKEOF` sentinel at position `ncodeunits(s)+1`.
  **The parser must never advance past this sentinel** — the `_parse_primary!` function
  returns `Node(NKSpace, "")` without advancing when it sees `TKEOF`.

### `Node` / `NodeKind` (`parser.jl`)
- Immutable struct: `kind::NodeKind`, `value::String`, `children::Vector{Node}`,
  `width::Float64`.
- Leaf nodes (chars, spaces, commands, operators) have empty `children`; interior nodes
  have empty or placeholder `value`.  The `width` field is only meaningful for `NKSpace`
  nodes (em units); all other node kinds leave it at `0.0`.
- Key node kinds:
  - `NKChar` — single character; `value` is the one-character string.
  - `NKCommand` — unrecognised command; `value` is the full token including `\`.
  - `NKSpace` — explicit horizontal space; the em width (possibly negative for `\!` and
    similar) is stored in `node.width::Float64`.  `value` is always `""` for this kind.
    Commands `\,` `\:` `\;` `\!` `\quad` `\qquad` `\kern` `\mkern` `\hskip` `\mskip`
    and their aliases all produce this node.  1 mu = 1/18 em.
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
    `\underbracket`, `\overparen`, `\underparen`.  `value` is the bare command name;
    `children[1]` is the body.  The layout engine selects the widest-fitting variant
    (or extensible assembly) from `horiz_constructions`, then applies limits-style
    note placement for any sub/superscript on the brace node.
  - `NKLimitsOverride` — produced by `\limits` or `\nolimits`; wraps the preceding base
    node as its sole child; `value` is `"limits"` or `"nolimits"`.  The layout engine
    checks this before dispatching the script placement algorithm.
  - `NKStyleOverride` — produced by `\dfrac`, `\tfrac`, `\displaystyle`, `\textstyle`,
    `\scriptstyle`, `\scriptscriptstyle`.  `value` is one of `"Display"`, `"Text"`,
    `"Script"`, `"ScriptScript"`; `children[1]` is the body.  For `\dfrac`/`\tfrac` the
    body is an `NKFrac` node; for style-switch commands the body is an `NKSequence`
    containing the rest of the current group.  The layout engine resets both style and
    scale to `size_scale(new_style, mc)`, so `\dfrac` inside a subscript renders at
    full display size (matching KaTeX behaviour).
  - `NKSizing` — produced by `\large`, `\tiny`, `\normalsize`, etc.  `value` is the
    Float64 multiplier as a decimal string; `children[1]` is an `NKSequence` wrapping
    the rest of the current group.  The layout engine multiplies the current scale by
    this factor (style is unchanged).
  - `NKXArrow` — produced by `\xrightarrow`, `\xleftarrow`, and 16 other extensible-arrow
    commands.  `value` is the command string (e.g. `"\\xrightarrow"`); `children[1]` is
    the mandatory above-label argument; `children[2]` (optional) is the below-label from
    `[…]`.  The layout engine stretches the arrow to cover the labels with padding, centres
    it on the math axis, and places the labels at `_XARROW_KERN` (0.111 em) clearance.
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
  `bolditalic` (all optional).
- **Constructors:** `font_family(::Symbol)` looks up a named artifact (`:new_cm`,
  `:pagella`, `:termes`, `:schola`, `:bonum`, `:luciole`, `:stix_two`, `:fira_math`);
  `font_family(math_path; regular,
  bold, italic, bolditalic)` accepts file paths directly; `default_font_family()` returns
  the current session-wide default (initially `:new_cm`; overrideable with
  `set_default_font_family!`).
- **Three glyph lookup functions:**
  - `glyph_metrics(family, name)` — metrics for a PostScript glyph name in the math font
    (e.g. `"parenleft"`, `"alpha"`).  The form of single-letter names depends on the font;
    in NewCMMath, `"x"` maps to the *upright* roman form, not italic — use
    `glyph_metrics_by_codepoint` with a Unicode math-variant codepoint for italic letters.
  - `glyph_metrics_by_codepoint(family, cp)` — Unicode codepoint in the math font (returns
    `nothing` on miss).
  - `glyph_metrics_upright(family, ch)` — upright character; uses `regular` font if
    present, otherwise falls back to math font codepoint mapping which yields upright
    forms in OpenType math fonts like NewCMMath (returns `nothing` on miss).
- Fonts are cached by path in `_FONT_CACHE`; safe to call repeatedly.

### `LayoutBox` / `TeXElement` (`layout.jl`)
- `LayoutBox`: `element::TeXElement`, `x::Float64`, `y::Float64`, `scale::Float64`.
  Positions are in em units (design units / UPM × scale); x right, y up, origin at
  formula baseline.
- Element subtypes:
  - `Glyph` — PS name + `font_slot::Symbol` (`:math` or `:regular`) + advance/bearing/bbox
    metrics in design units.  `font_slot` tells the renderer which font file to use for
    glyph-index resolution: `:math` → `family.math`, `:regular` → `family.regular` (falls
    back to `family.math` when `regular` is `nothing`).  All math-mode glyphs carry `:math`;
    glyphs from `\text{}`/`\mbox{}` carry `:regular` when a companion regular font is
    configured.
  - `HRule` — width + thickness in em.
  - `VRule` — height + thickness in em.
  - `Space` — width in em.
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
`load_math_table(path)` returns a cached `MathTable` object keyed by the math-font
path, so repeated layouts with the same font do not reparse the binary table.

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

6. **All math symbol glyphs should be resolved by Unicode codepoint, not PostScript name.** (See also invariant 7 on layout purity.)
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

7. **Layout is purely additive.** `_layout_node!` only pushes to `boxes`; it never
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
| Named operators (`\sin`, `\cos`, `\lim`, …) | ✓ | Upright glyphs; 27 operators including `\limsup`, `\liminf` |
| Large operators (`\sum`, `\prod`, `\int`, …) | ✓ | Display-size variant selected via `display_operator_min_height` |
| Limits placement | ✓ | Sub/sup centred below/above in Display style; 4 MATH constants used |
| `\limits` / `\nolimits` override | ✓ | Parsed as `NKLimitsOverride`; respected in all script branches |
| Explicit spacing (`\,` `\;` `\quad` `\kern` …) | ✓ | Width in em; negative spaces supported |
| Inter-atom spacing | ✓ | TeX atom-class table (ord/bin/rel/op/open/close/punct/inner) |
| Accents (`\hat`, `\bar`, `\vec`, …) | ✓ | Rule 12; `MathTopAccentAttachment` alignment; 11 non-stretchy commands |
| `\overline`, `\underline` | ✓ | Rules 9 & 10; gap and thickness from MATH table |
| Horizontal extensibles (`\widehat`, `\widetilde`) | ✓ | Variant selection + extensible assembly from `horiz_constructions`; centred over base |
| Font switching (`\mathbf`, `\mathrm`, …) | ✓ | Unicode math-variant codepoints; `\mathrm` uses `_char_glyph` (math font codepoint); propagates into sub/superscripts |
| Horizontal braces (`\overbrace`, `\underbrace`, …) | ✓ | `NKHorizBrace`; variant selection from `horiz_constructions`; limits-style note placement; 6 commands |
| Array/matrix environments | ✓ | `NKMatrix`; 8 named environments + `\begin{array}{colspec}`; per-column l/c/r alignment; single and double (`||`) vertical rules from colspec; two-pass grid layout centred on math axis |
| `\middle` delimiter | ✓ | `NKMiddle`; auto-sized to the same height as the enclosing `\left`/`\right` pair; multiple `\middle` delimiters per group are supported |
| `\text{}`, `\mbox{}` | ✓ | `NKText`; switches to upright (regular-font) glyph lookup via `_with_text_mode`; spaces preserved as `Space` elements (word-space advance from font); inter-atom spacing suppressed inside text fragments |
| `default_font_family()` / `set_default_font_family!()` | ✓ | Returns current default (`:new_cm` initially); override with any `Symbol` or `FontFamily`; lazy download |
| `\dfrac`, `\tfrac` | ✓ | `NKStyleOverride`; forces Display or Text style (with absolute scale reset); `\dfrac` inside a subscript renders at full display size |
| `\binom`, `\dbinom`, `\tbinom` | ✓ | `NKGenfrac`; Rule 15c (no-rule gap clamping); auto-sized `(` `)` delimiters via `_layout_delim!`; `\dbinom`/`\tbinom` wrap in `NKStyleOverride` |
| Manual delimiter sizing (`\bigl`, `\bigr`, `\Bigl`, `\Bigr`, `\biggl`, `\biggr`, `\Biggl`, `\Biggr`, and `\bigm`/`\big` families) | ✓ | `NKBigDelim`; 4 size tiers (1.2/1.8/2.4/3.0 em × upm); reuses `_layout_delim!`; scale-independent variant selection; 16 commands + null delimiter support |
| Style switches (`\displaystyle`, `\textstyle`, `\scriptstyle`, `\scriptscriptstyle`) | ✓ | `NKStyleOverride`; consumes rest of current group; absolute style and scale override matching KaTeX |
| Font sizing (`\large`, `\tiny`, …) | ✓ | `NKSizing`; 10 commands from `\tiny` (0.5×) to `\Huge` (2.488×); multiplies current scale |
| Extensible arrows (`\xrightarrow`, `\xleftarrow`, …) | ✓ | `NKXArrow`; 18 commands; arrow from `horiz_constructions`; centred on math axis; optional below label; labels at 0.111 em kern |

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
  codepoints.  The `bold`, `italic`, `bolditalic` slots in `FontFamily` are not yet used;
  adding them would cover characters outside the Unicode math block.
- **Makie integration** — implemented via `ext/MathTeXEngineExt.jl` (a Julia package
  extension).  When `TeXLayout`, `MathTeXEngine`, `GeometryBasics`, and `LaTeXStrings`
  are all loaded, the extension adds a specialised
  `MathTeXEngine.generate_tex_elements(::LaTeXString)` method that uses TeXLayout's
  OpenType layout engine.  Makie's `texelems_and_glyph_collection` always passes a
  `LaTeXString`, so dispatch picks our method over MathTeXEngine's fallback.  The
  extension is fully precompiled (no `__precompile__(false)` needed) because adding
  a method with a more specific argument type is a new method, not an overwrite.
  The extension also maintains a per-font runtime cache so repeated Makie renders
  reuse the loaded math/regular faces, the derived `MathTeXEngine.FontFamily`, and
  glyph-name → glyph-index lookup tables.
  **Geometry contract:** `TeXLayout.HRule` / `VRule` store rectangle edges
  (`HRule.y` = bottom edge, `VRule.x` = left edge), while
  `MathTeXEngine.HLine` / `VLine` use line-centre positions.  The adapter in
  `_box_to_mte` is responsible for converting between these conventions by
  shifting rule positions by half the thickness.
  **This is type piracy**: TeXLayout owns neither the function (`MathTeXEngine.generate_tex_elements`)
  nor the argument type (`LaTeXStrings.LaTeXString`).  It is pragmatic and confined
  to the extension, but alternative integration strategies (e.g. a dedicated Makie
  recipe or a proper upstream extension point in MathTeXEngine) will be investigated
  in future.
- **Makie extension ignores caller-specified font family** — the overridden
  `generate_tex_elements` accepts a `font_family` argument (for API compatibility
  with MathTeXEngine) but always uses `TeXLayout.default_font_family()` regardless.
  Users can change the font used by Makie by calling `TeXLayout.set_default_font_family!`
  before rendering; the extension will pick up the new default automatically.

---

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.
