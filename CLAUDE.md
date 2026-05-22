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
├── external/              # Source references (read-only; not part of the package)
│   ├── KaTeX/             # Original KaTeX JS implementation
│   ├── Makie.jl/          # Makie ecosystem packages
│   └── MathTeXEngine.jl/  # Previous Julia math typesetter
├── Project.toml
└── README.md
```

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
    Rendered upright using `glyph_metrics_upright`.
  - `NKDecorated` — children are `[base, sub, sup]` (always in that order regardless of
    source order).
  - `NKFrac` — children `[numerator, denominator]`.
  - `NKSqrt` — children `[body]` or `[degree, body]`.
  - `NKDelimited` — children are the interior sequence; `\right` is currently consumed as
    an `NKCommand` child (known limitation — delimiter auto-sizing not yet implemented).

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

5. **Layout is purely additive.** `_layout_node!` only pushes to `boxes`; it never
   removes or modifies existing entries.  Temporary `LayoutBox` vectors (used for
   centering fractions) are merged in with adjusted x coordinates.

---

## Known limitations / future work

(See `notes.md` for KaTeX test file locations and grep terms for each item.)

- **Limits placement** — `\lim_{x}` in Display style should place the subscript centred
  below; currently it is placed beside.  Detection hook: check
  `node.children[1].kind === NKOperator` in the `NKSubscript`/`NKDecorated` layout
  branch.  Relevant MATH constants: `upper_limit_baseline_rise_min`,
  `lower_limit_baseline_drop_min`.
- **Inter-atom spacing** — TeX inserts thin/medium spaces between atom classes
  (op/ord/bin/rel/…).  Requires classifying each node and looking up the spacing table.
  Explicit spacing commands (`\,` `\:` `\;` `\!` `\quad` `\qquad` `\kern` etc.) are
  already implemented; only the *automatic* inter-atom spacing remains.
- **Delimiter sizing** — `\left`/`\right` delimiters are not yet scaled to the height of
  the enclosed content.  The MATH table `GlyphConstruction` records provide the variant
  glyph sequences needed.
- **Accents** — `NKAccent` is parsed and represented in the AST but the layout engine
  emits only the base (accent mark not rendered).
- **Font switching** — `\mathbf`, `\mathrm`, `\mathbb`, `\mathit`, `\mathcal` etc. are
  not yet implemented; they fall through as `NKCommand`.
- **Array/matrix environments** — `\begin{array}…\end{array}`, `pmatrix`, `cases`, etc.
  Not yet parsed.
- **`default_font_family()`** — throws "not implemented"; must be configured before
  the zero-argument form of `generate_tex_elements` can be used from Makie.

---

## Test suite

Run with `julia --project=. -e 'using Pkg; Pkg.test()'`.

The fixture font is `NewCMMath-Regular.otf`; ground-truth constants are in
`test/fixtures/newcm_math.jl`.  KaTeX-derived tests live in `test/test_katex.jl` with
inline comments citing the originating KaTeX file and line numbers.
