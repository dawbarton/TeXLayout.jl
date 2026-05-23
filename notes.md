
## 2026-05-23T09:27+00:00 Fraction gap clamping fix and visualisation tools

- Added two visualisation tools to `tools/`:
  - `visualise_svg.jl`: SVG bounding-box diagram showing ink extents of each LayoutBox with reference lines for baseline and math axis; Space elements shown as dashed outlines
  - `visualise_bitmap.jl`: FreeType glyph rasterisation onto a PGM/PNG canvas; HRules filled directly; supports PNG output via ImageMagick pipe (`convert pgm:- png:$path`)
- **Bug fixed** (`src/layout.jl`): Deeply nested fractions had content overlapping the outer fraction rule bar
  - Root cause: `fraction_numerator_gap_min` / `fraction_num_display_style_gap_min` (and denominator equivalents) were parsed from the MATH table but never applied during fraction layout
  - Fix: implement TeX Rule 15d/15e — lay out numerator/denominator at y=0 first to measure ink extents, then clamp the initial MATH-table shifts: `num_shift = max(num_shift, axis_em + rule_thickness/2 + num_gap + num_depth)`
  - Also extended `_boxes_top`/`_boxes_bottom` to include HRule extents (previously Glyph-only), so nested fractions-as-numerator are measured correctly
  - All 511 tests pass after the fix

## 2026-05-23T09:53+00:00 Fix three rendering bugs: PS glyph names, digits/operators, radical glyph

### Bugs fixed (commit 24ca9d6)

**Bug 1 & 2: + − = and digits (0–9) were invisible**
- Root cause: `_char_glyph` in `layout.jl` stored `string(ch)` as the PostScript name for non-letter characters. FreeType's `renderface(face, name, size)` resolves glyphs by PS name; `"+"` is not a valid PS name (should be `"plus"`, `"hyphen"`, `"zero"`, `"equal"`, etc.).
- Fix: added `glyph_name_by_codepoint(family, cp)` to `fonts.jl` using `_FT.FT_Get_Glyph_Name`, then updated `_char_glyph` to call it and use the returned PS name.

**Bug 3: leading √ hook missing from `\sqrt`**
- Root cause: NKSqrt branch emitted only body boxes and an HRule bar; the radical glyph was never placed.
- Fix: restructured NKSqrt to lay out body at y=0, measure ink, compute `required_du` (total vertical span from body bottom to rule top in design units), then call new `_layout_radical!` helper.
- `_layout_radical!` selects the smallest pre-built variant from `vert_constructions["radical"]` with `advance >= required_du`, or falls back to `_layout_radical_assembly!`.
- Unlike delimiter assemblies (centred on math axis), the radical assembly is TOP-ANCHORED: the top of the top cap aligns with the rule-top em position.
- Body and HRule are then shifted right by `rad_adv` (advance width of radical glyph).

### Key facts about NewCMMath radical glyphs
- 5 pre-built variants: radical (1001 du), radical.v1 (1201), radical.v2 (1801), radical.v3 (2401), radical.v4 (3001)
- Assembly parts (bottom-to-top): uni23B7 (1820 du, cap), radical.ex (640 du, extender), radical.tp (620 du, cap)
- All assembly parts have y_min=0, y_max=full_advance (top-aligned bounding boxes)
- Base `radical` glyph: y_min=-960, y_max=40 (bar barely above origin; hook extends far below)
- Variant glyphs (v1–v4): origin shifts up so hook extends ~350–1250 du below, bar 850–1750 du above

### Test update
- "Sqrt: radical bar above radicand" test updated to exclude the radical glyph (leftmost x) from radicand_y computation
- All 513 tests pass

## 2026-05-23T12:44+00:00 Limits placement and large operator display-size glyphs

### Bug fixed: large operators (`\sum`, `\prod`, `\int`, etc.) were invisible
- Root cause: `_cmd_glyph` looked up PS name `"sum"` which does not exist in NewCMMath; correct name is `"summation"`, `"product"`, `"integral"`, etc.
- Fix: added `_DISPLAY_OP_CODEPOINTS` dict mapping command names to Unicode codepoints; `NKCommand` branch now uses `glyph_name_by_codepoint` to obtain the correct PS name.

### New feature: display-size large operators
- In Display style, `\sum`, `\prod`, `\int`, etc. select the smallest `vert_constructions` variant with `advance >= display_operator_min_height` (1300 du from MATH table).
- Operator glyph centred on the math axis (same approach as `\left`/`\right` delimiters).

### New feature: limits placement (TeX Rule 15 / KaTeX `assembleSupSub.ts`)
- `\lim`, `\limsup`, `\liminf`, `\det`, `\gcd`, `\inf`, `\sup`, `\max`, `\min`, `\Pr` automatically use limits placement in Display style.
- `\sum`, `\prod`, `\coprod`, `\bigcap`, `\bigcup`, etc. also use limits placement in Display style.
- `\limits` / `\nolimits` explicit overrides parsed as `NKLimitsOverride` AST node wrapping the base.
- Limits algorithm: lay each part at origin, measure ink extents with `_boxes_top`/`_boxes_bottom`, then apply four MATH constants:
  - `upper_limit_gap_min = 200 du` — minimum ink gap above base top
  - `upper_limit_baseline_rise_min = 111 du` — minimum sup baseline above base top
  - `lower_limit_gap_min = 167 du` — minimum ink gap below base bottom
  - `lower_limit_baseline_drop_min = 600 du` — minimum sub baseline below base bottom
- Each part centred horizontally over the base; total width = max(base_w, sub_w, sup_w).
- In Text/Script styles (or after `\nolimits`), sub/sup remain in normal beside-base positions.
- `limsup` and `liminf` added to `_OPERATOR_NAMES` in `parser.jl` (were previously falling through as `NKCommand`).
- 33 new test assertions across 8 `@testset` blocks; 556 total tests, all passing.

## 2026-05-23T11:55+00:00 Inter-atom spacing implementation

- Implemented full TeX atom-class spacing (Knuth Ch. 17 / KaTeX `spacingData.ts`).
- `_CHAR_ATOM_CLASS`: maps characters (including U+2212 minus, U+2217 asterisk) to `ord/bin/rel/open/close/punct/inner`.
- `_CMD_ATOM_CLASS`: maps LaTeX command names (all Greek, common operators, arrows, delimiters, etc.) similarly.
- `_SPACINGS` / `_TIGHT_SPACINGS`: thin=3/18, medium=4/18, thick=5/18 em lookup tables for Display/Text and Script/ScriptScript styles.
- `_atom_class(node)`: scripted nodes (NKSuperscript/NKSubscript/NKDecorated) inherit base atom class; NKSpace is `:neutral`.
- `_interatom_space(prev, next, style)`: selects tight table for Script/ScriptScript styles.
- `NKSequence`/`NKGroup` branch now inserts auto-spacing `Space` elements in `:math` mode; neutral explicit spaces reset the context preventing double-spacing.
- 6 new layout tests (523 total, all passing): `a+b` medium, `a=b` thick, `a,b` thin, `\sin x` thin, Script suppression, explicit-space no double-gap.
- Added `tools/visualise_spacing.jl`: 13-row grid rendering with auto-spacing gaps shaded.
- Open items remaining: limits placement (`\lim_{x}` in Display), inter-atom spacing for `\text{}`/`\mbox{}`, accent rendering, font switching commands, array/matrix environments.
