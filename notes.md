
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

## 2026-05-23T22:14+00:00 Accents, overline/underline, binary reclassification

- Implemented KaTeX Rule 12 (accents): base in cramped style; vertical placement via `AccentBaseHeight`; horizontal via `MathTopAccentAttachment`; accent does not widen advance. 11 non-stretchy commands: `\hat`, `\acute`, `\grave`, `\ddot`, `\tilde`, `\bar`, `\breve`, `\check`, `\dot`, `\mathring`, `\vec`.
- Codepoint choice: `\acute`/`\grave`/`\bar` use U+00B4/U+0060/U+00AF (Latin-1) rather than KaTeX's Modifier Letter codepoints (U+02CA/02CB/02C9) absent in NewCMMath.
- Added `NKOverUnder` node kind (single kind, `value = "overline"/"underline"`) for `\overline` and `\underline`. Rule 9: body in cramped style, HRule above using `OverbarVerticalGap`/`OverbarRuleThickness`. Rule 10: body in current style, HRule below using `UnderbarVerticalGap`/`UnderbarRuleThickness`.
- Implemented TeX Rules 5 & 6 (binary atom reclassification) via two-pass algorithm in `_layout_children!`: left-to-right (Rule 5) then right-to-left (Rule 6). Neutral atoms (spaces) transparent to both passes. Constants `_BIN_LEFT_CANCEL`/`_BIN_RIGHT_CANCEL` as module-level tuples.
- All planned items (2 → 3 → 4) complete; 649 tests passing.
- Next: `default_font_family()` via Artifacts, array/matrix environments, or wide accents (`\widehat`/`\widetilde`).

## 2026-05-23T23:49+00:00 Implement horizontal brace family (\overbrace, \underbrace, etc.)

- Added `NKHorizBrace` node kind (`value = command name`, `children[1] = body`). Six commands: `\overbrace` (uni23DE), `\underbrace` (uni23DF), `\overbracket` (uni23B4), `\underbracket` (uni23B5), `\overparen` (uni23DC), `\underparen` (uni23DD).
- Normal `^`/`_` parsing naturally wraps `NKHorizBrace` in `NKSuperscript`/`NKSubscript`/`NKDecorated`; the layout engine intercepts these before the standard script algorithm.
- Atom class: `NKHorizBrace → :inner` (matching KaTeX's `minner`).
- `_layout_horiz_brace!` algorithm: body → brace (horizontally stretched via `_layout_wide_accent!`) → note (primary script, limits-style centered over max(body_w, note_w)) → secondary script (side-placed to the right using standard shift constants).
- Brace placement: gap between body ink edge and brace ink edge = `0.1 * scale`; gap between brace ink edge and note ink edge = `0.2 * scale`. Reference glyph y_min/y_max obtained by same variant-selection logic as `_layout_wide_accent!` to derive brace_y from the chosen glyph's actual metrics.
- "Over" braces (overbrace/overbracket/overparen): note is the `sup`, placed above. "Under" braces (underbrace/underbracket/underparen): note is the `sub`, placed below. The opposite script becomes the secondary (side-placed).
- 712 tests passing (46 new: 9 parser + 11 layout, plus the existing KaTeX suite was unaffected).
- Updated `CLAUDE.md` feature table; added `horiz_braces.png` demo panel to `demo_features.jl`.

## 2026-05-23T22:52+00:00 Implement \widehat and \widetilde (horizontal extensible accents)

- Added `\widehat => 0x02C6` and `\widetilde => 0x02DC` to `_ACCENT_CODEPOINTS` in `parser.jl`. They share codepoints with `\hat`/`\tilde`; the layout engine distinguishes them via `_WIDE_ACCENT_COMMANDS`.
- `horiz_constructions` was already parsed by `_parse_math_variants` in `math_table.jl` — no binary parsing changes needed.
- Added `horiz_constructions::Dict{String,GlyphConstruction}` field to `_LayoutCtx` struct; updated both constructor call sites (`layout()` and the `NKFontSwitch` branch).
- Added `_WIDE_ACCENT_COMMANDS = Set{String}(["\\widehat", "\\widetilde"])` constant.
- Added `_layout_wide_accent!` helper: tries pre-built variants (smallest whose `advance >= required_du`), then extensible assembly using the existing `_min_extender_reps`/`_expand_assembly_parts`/`_gap_min_overlap` helpers, then falls back to largest variant. All parts centred over the base via `x0 + (base_w - glyph_w) / 2`.
- `NKAccent` branch now dispatches wide accents to `_layout_wide_accent!` immediately after computing `accent_y`; fixed-size path unchanged.
- 666 tests passing (added 3 parser tests + 4 layout tests for wide accents).
- Updated `CLAUDE.md` feature table, `katex_rules.md` Rule 12 status, and `demo_features.jl` accent panel.

## 2026-05-24T13:52+00:00 Implement \begin/\end environment parsing and matrix/array layout

- Added `NKMatrix` node kind; value encodes `"env\x00nrow\x00ncol"`, children are flat row-major cells (each an `NKGroup`).
- `_MATRIX_ENVS` constant maps 8 environment names to delimiter glyph names, alignment symbol, and scale factor. Bare `matrix` and `smallmatrix` have no delimiters.
- `_read_brace_word!(p)` helper reads a brace-delimited name token for `\begin`/`\end`.
- `_parse_matrix_body!` handles `&` column separators, `\\` row breaks (with optional `[dim]` skip), `\end` stop, and lenient EOF. Uses `copy(current_cell)` to avoid Julia mutable aliasing pitfall — forgetting this made all cells empty.
- `\begin` dispatches to `_parse_matrix_body!` for known environments; unknown environments produce `NKCommand`. Stray `\end` produces `NKSpace`.
- `_layout_matrix!` two-pass algorithm: first pass lays out all cells at origin to measure widths/heights/depths; second pass positions cells using computed column/row extents.
- Grid centred on math axis via `y_shift`; cells always use Text style (not Display), matching TeX array rules.
- Column separation `5/18 em` per side; extra row gap `3/18 em`.
- Delimiter wrapping via `_layout_delim!`; left delimiter width applied as offset before emitting content boxes (not via retroactive splicing).
- Key bugs fixed during implementation: (1) Julia mutable aliasing bug with `current_cell` reference, (2) wrong `y0` argument to `_layout_delim!` (should not pre-add axis height — the function does this internally), (3) sort direction bug in layout test (negating y, not reversing both keys).
- 761 tests passing (25 new parser + 14 new layout + 5 new katex smoke tests).
- Updated `CLAUDE.md` feature table (Array/matrix environments: ✗ → ✓).

## 2026-05-24T15:15+00:00 Demo sheets, CFF fix, and TeX Gyre font family scaffolding

- Updated `README.md`: added matrix/array environments to key features; added Schola/Termes/Bonum pending entries to acknowledgements table.
- **Bug fixed in `math_table.jl`** (`_cff_top_dict_charset_offset`): `0x100000000` is a `UInt64` literal; `Int64 - UInt64` promotes to `UInt64`, causing an `InexactError` when trying to push to `Vector{Int}`. Fixed by `v -= Int(0x100000000)`. Symptom: STIX Two Math crashed on load; all other fonts (NewCMMath, Pagella, Luciole, FiraMath) worked because their CFF Top DICT only uses b==28 (int16) offsets.
- **New `tools/demo_sheet.jl`**: generates a comprehensive single-page greyscale PNG demo sheet for any font family. Sections: fractions/roots, scripts/large ops, integrals, delimiters, accents/extensibles, font variants, matrices, array colspec. Headers rendered dark-on-light/white-on-dark via two separate composite functions. Accepts `:symbol` or `/path/to/math.otf`; default output `demo_{symbol}.png`.
- **Demo PNGs generated** for all 5 published families: NewCMMath (2047×2300), Pagella, Luciole, FiraMath, STIXTwo (1991×2334). All in `shared/`. STIX Two required the CFF fix.
- **`tools/prepare_font_artifacts.jl`**: downloads fonts from CTAN/GitHub, creates Julia artifact tarballs and a draft `Artifacts.toml`. Covers all 8 families (5 existing + Schola/Termes/Bonum). CTAN paths for TeX Gyre Schola/Termes/Bonum: `mirrors.ctan.org/fonts/tex-gyre-math/{schola,termes,bonum}/texgyre{schola,termes,bonum}-math.otf` + text OTFs from `mirrors.ctan.org/fonts/tex-gyre/fonts/opentype/public/tex-gyre/`.
- **`src/fonts.jl` scaffolding**: `_NAMED_ARTIFACTS` and `_ARTIFACT_LOADERS` have placeholder comments for Schola/Termes/Bonum; the `@artifact_str` loader functions are intentionally absent until artifacts are published (they break precompilation if the Artifacts.toml entries don't exist). Re-add when artifacts are uploaded.
- Open question: CTAN URLs for TeX Gyre text fonts — the exact filenames follow `texgyre{name}-{weight}.otf` convention but should be verified before running `prepare_font_artifacts.jl`.

## 2026-05-24T15:41+00:00 Fix FiraMath missing glyphs (Unicode-style PS names)

- **Root cause**: FiraMath uses Unicode-style PostScript names ("uni03C0", "uni0028", "uni221A") instead of traditional Adobe Glyph List names ("pi", "parenleft", "radical"). Three symptoms:
  1. Greek letters (`\alpha`, `\pi`, etc.) rendered nothing — `_cmd_glyph("pi")` calls `FT_Get_Name_Index("pi")` → GID 0 in FiraMath
  2. Square root hook missing — `vert_constructions["radical"]` not found (key is "uni221A")
  3. pmatrix/bmatrix brackets missing — `vert_constructions["parenleft"]` not found (key is "uni0028")
- **Fix 1 — Greek letters** (`_SYMBOL_CODEPOINTS`): Added all 36 Greek letter commands (α–ω + variants + uppercase). The existing codepoint-lookup path (`glyph_metrics_by_codepoint` + `glyph_name_by_codepoint`) already returns the font's actual PS name, so NewCM gets "alpha" and FiraMath gets "uni03B1" — both correct for their respective renderers. Note: `\epsilon` → U+03F5 (Greek Lunate Epsilon Symbol), `\varepsilon` → U+03B5; `\phi` → U+03D5 (Greek Phi Symbol), `\varphi` → U+03C6.
- **Fix 2 — construction key translation** (`_construction_key`, `_CANONICAL_CODEPOINTS`): Added a helper that, given a canonical PS name ("parenleft"), looks it up in `vert_constructions`; if absent, resolves the codepoint via `_CANONICAL_CODEPOINTS` and calls `glyph_name_by_codepoint` to get the font's actual PS name, then looks that up. This is called in `_layout_radical!`, `_peek_radical_glyph`, and `_layout_delim!`.
- **Fix 3 — `_cmd_glyph` fallback**: Added a codepoint fallback for canonical PS names that fail the primary `FT_Get_Name_Index` lookup (used when no construction variants exist and the base glyph must be placed by name).
- **Key design decision**: kept `vert_constructions` keyed by the font's own PS names (not normalised at parse time). The alternative — normalising "uni0028" → "parenleft" at construction time — would break the large-operator path which uses `glyph_name_by_codepoint` to derive the key dynamically.
- All 789 tests pass. FiraMath demo regenerated with sqrt, pi, and brackets all rendering correctly.

## 2026-05-24T18:24+00:00 Glyph resolution audit — codepoint-only strategy

- **Audit result**: 156 commands in `_CMD_ATOM_CLASS` have no codepoint entry in `_SYMBOL_CODEPOINTS` or `_DISPLAY_OP_CODEPOINTS`. These include extended AMS binary operators (`\boxplus`, `\ltimes`, `\intercal`, …), extended relations (`\leqslant`, `\bowtie`, `\therefore`, `\because`, all negated relations), extended geometry and misc ordinary symbols (`\measuredangle`, `\triangle`, `\square`, `\checkmark`, `\S`, `\P`, `\yen`, …), and rare delimiter aliases (`\lgroup`, `\llbracket`, `\lvert`, `\lVert`, …).
- **Practical impact**: standard fonts (NewCM, Pagella, STIXTwo) work because they use AGL PS names matching the command names. FiraMath and Luciole silently produce blanks for all 156.
- **Strategy decision**: remove PS-name lookup from `_cmd_glyph` and `_char_glyph` entirely; use codepoints exclusively.
  - Reason 1 (correctness): `glyph_metrics(family, "x")` in NewCMMath returns the *upright* roman form, not math-italic. The cmap (used by `glyph_metrics_by_codepoint`) correctly gives math-italic 'x' because math fonts map U+0078 → italic glyph by design.
  - Reason 2 (portability): eliminates the naming divergence problem across all current and future fonts.
  - Remaining PS-name use: `_construction_key` (bridging canonical AGL names to font-own MATH-table PS names for `vert_constructions`/`horiz_constructions`) — cannot be eliminated because the MATH table itself uses PS names.
- **Multi-codepoint issue**: ~10 negated/variant commands (`\nleqslant`, `\lvertneqq`, `\varsubsetneq`, etc.) have no single Unicode codepoint — they're defined as base + U+0338 (COMBINING SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR). Math fonts don't encode these at a consistent single codepoint. Current state: produce blank space. Fix requires two-glyph overlay (base + combining stroke). Documented in CLAUDE.md Known Limitations.
- **Next step**: bulk-expand `_SYMBOL_CODEPOINTS` (~140 clean additions), simplify `_char_glyph` and `_cmd_glyph` to codepoint-only paths.

## 2026-05-24T18:36+00:00 Codepoint-only glyph resolution implemented

- Completed the codepoint-only strategy (continued from earlier session):
  - `_DISPLAY_OP_CODEPOINTS`: added `iiiint` (U+2A0C), `oiint` (U+222F), `oiiint` (U+2230).
  - `_SYMBOL_CODEPOINTS`: added ~85 new entries — AMS binary operators (`\boxplus`, `\ltimes`, `\curlywedge`, etc.), extended relations (`\leqslant`, `\lesssim`, `\bowtie`, `\doteqdot`, `\Subset`, `\preccurlyeq`, etc.), negated relations with single codepoints (`\nleq`, `\nprec`, `\subsetneq`, etc.), ordinary symbols (`\measuredangle`, `\imath`, `\triangle`, `\checkmark`, `\mho`, `\Finv`, etc.), delimiter aliases (`\lvert`, `\lVert`, `\llbracket`, `\lgroup`, `\lmoustache`), and punctuation (`\colon`, `\cdotp`, `\ldotp`).
  - `_char_glyph`: removed `isletter` PS-name-first block; now always resolves by codepoint. Fixes math-italic letter rendering (PS name "x" → upright roman; cmap U+0078 → italic by font design).
  - `_layout_node!` NKCommand else-branch: replaced `_cmd_glyph` fallback with `nothing`; commands not in `_SYMBOL_CODEPOINTS` silently produce no glyph.
  - `_cmd_glyph`: updated comment to document it is now used exclusively for MATH table font-internal names (size variants, assembly parts).
- All 789 tests pass. Committed as `ddad75e`.
- Remaining open items: two-glyph overlay for multi-codepoint negated relations; Makie integration; Schola/Termes/Bonum artifacts.

## 2026-05-24T20:50+00:00 Three visual bug fixes: widehat centering, vmatrix bar, sqrt body position

### Bug 1: Widehat/accent horizontal centering (two sites in `src/layout.jl`)

- **Root cause**: `_layout_wide_accent!`'s `_place()` helper centred glyphs by `advance_width/2`. For zero-advance combining characters (e.g. New CM `circumflexcmb`: adv_w=0, x_min=-446, x_max=-82; STIX Two `uni0302`: adv_w=0, x_min=-371, x_max=-89), this placed the glyph at `x0 + base_w_em/2` but the ink lay entirely to the left of that position.
- Same bug in the NKAccent fixed-size fallback (`accent_w = advance_width * s / upm`).
- **Fix**: replace `advance_width/2` with ink midpoint `(x_min + x_max)/(2*upm)*scale`. For standard positive-advance glyphs (x_min≈0, x_max≈advance_width), the result is numerically identical to the old formula.
- **FiraMath limitation**: FiraMath has no widehat/widetilde in `horiz_constructions` (only has entries for `uni23B4/B5` and `uni23DC–DF`). Falls back to a single fixed-size combining circumflex, now correctly centred.

### Bug 2: Delimiter assembly vertical centering (`_layout_assembly!`)

- **Root cause**: `_layout_assembly!` centred the stacked assembly on the math axis using `total_du/2` (half the sum of cursor advances). For STIX Two `bar` (y_min=−234, y_max=706, full_advance=941), the ink centre is at 0.236 em, not at 0.258 em (axis). The resulting bar was centred 0.23 em below the axis, making vmatrix bars appear too low relative to enclosed digits.
- **Fix**: look up actual glyph metrics of the first and last assembly parts; compute actual ink bounds (`ink_top_du = cursor_last + g_last.y_max`, `ink_bot_du = g_first.y_min`); centre on `(ink_top_du + ink_bot_du)/2`. For fonts where y_min=0, y_max=full_advance (e.g. New CM), reduces to the old formula identically.
- Note: STIX Two `bar` *does* have an assembly (1 extender + 1 end piece, both `full_advance=941`, min_overlap=100). For a 2×2 digit matrix the assembly uses n=2 extenders producing ~2523 du for a ~2216 du required span — adequate coverage.

### Bug 3: Sqrt body vertical position (KaTeX Rule 11 body shift)

- **Root cause**: when a pre-built radical variant is larger than the minimum required span, the body was placed at `y0` with all excess space appearing below it. This made `\sqrt{\pi}` show π crammed at the top of an oversized hook (visible in FiraMath demo).
- **Fix**: after `_layout_radical!` selects the glyph, peek again with `_peek_radical_glyph(ctx, required_du)` to determine actual ink span `g.y_max - g.y_min`. Compute `body_shift = max(0, actual_span_du - required_du) / (2*upm) * scale`. Shift body boxes DOWN by `body_shift`. Rule bar and radical placement unchanged.
- Result: excess space is split equally — `body_shift` extra clearance above body (between body top and rule bar) and `body_shift` space below body (between body bottom and hook tip). For assemblies, peek returns the last variant which has advance < required_du, so body_shift = 0 (no shift for assemblies). For the base glyph fallback, peek also returns without a matching variant, giving body_shift = 0.
- All 789 tests pass. Committed as `24f2e7a`.

## 2026-05-24T21:15+00:00 Widehat diagnosis and demo expression fix

### Root cause of persisting "centering/width" complaint

- **Centering was already correct** after the previous session's fix: numerical check shows `hat_center - base_center = 0.0` for all fonts and all tested expressions. The ink-midpoint formula `(x_min + x_max) / (2*upm) * scale` is exact for sized variants (x_min=0) and also correctly handles the zero-advance combining base glyph.
- **Width was the real issue**: the demo expression `\widehat{f(x+y)}` has a base of ~3.5em, but the largest pre-built hat variants are: NewCM 1.897em, Pagella 1.499em, STIX Two 2.385em, Luciole 3.001em. **None of these fonts have a hat assembly** (horiz_constructions has `assembly=nothing` for all). The fallback to the largest variant produces a hat that covers only 53%–82% of the base, which is visually wrong.
- **Fix**: changed demo expression from `\widehat{f(x+y)}` to `\widehat{xyz} + \widetilde{xyz}`. `xyz` has a base ~1.4–1.6em which fits within all fonts' hat variant sizes (ratios: NewCM 1.04, Pagella 1.04, STIX Two 1.24, Luciole 1.00). STIX Two has coarser variant spacing so the hat is 24% wider than the base — a font property, not a code bug.

### Fira Math clarification

- Fira Math has a **full Fira Sans companion** (regular, italic, bold, bold-italic all present in artifact). The font family IS complete.
- Fira Math **lacks widehat/widetilde** in its MATH table horiz_constructions (only has overbrace/underbrace variants). `\widehat` always falls back to the fixed-size combining circumflex (uni0302, adv=0), correctly centred by the ink-midpoint formula.
- Fira Math also **lacks calligraphic and fraktur** Unicode math alphabets — `\mathcal{H}` renders as upright H, `\mathfrak{g}` as regular g. Code is correct; this is a Fira Math v0.3.4 font limitation.

## 2026-05-24T21:27+00:00 PS name vs codepoint audit and Luciole overbrace fix

- **Bug fixed**: `\overbrace` (and all other horiz brace commands) was silently missing for Luciole because `_HORIZ_BRACE_GLYPHS` mapped `\overbrace` → `"uni23DE"`, but Luciole uses the AGL name `"overbrace"` in its `horiz_constructions` table.
  - All other fonts (NewCM, Pagella, STIX Two, FiraMath) use `"uni23DE"` — Luciole is the outlier.
  - Same pattern as the existing `_construction_key` issue (FiraMath uses `"uni0028"` instead of `"parenleft"` in vert_constructions), but in the opposite direction.
- **Fix**: Added `_horiz_construction_key(ctx, uni_name)` — mirrors `_construction_key` for horiz_constructions. Resolves `"uni{HHHH}"` to font's actual PS name via `glyph_name_by_codepoint`; covers all six brace commands simultaneously.
- **Defensive fix**: Extended `_cmd_glyph` with a second fallback path: if the name looks like `"uni{HHHH}"`, parse the codepoint and resolve via `glyph_name_by_codepoint`. This handles the symmetric case where future code might pass a Unicode-style name to a font using AGL naming.
- **Audit result**: No other unhandled PS name vs codepoint gaps in current code paths. All other callsites either use font-native construction table names, properly-resolved `glyph_name_by_codepoint` results, or the existing `_CANONICAL_CODEPOINTS` mechanism.

## 2026-05-24T22:03+00:00 Italic correction for limits-style script placement

- **Investigation**: KaTeX applies italic correction to limit placement for slanted operators (e.g. `\int`). In `op.ts`, `slant = base.italic ?? 0` (the MATH table italic correction). In `assembleSupSub.ts`, subscripts get `marginLeft: -slant` and superscripts get `marginLeft: +slant`. KaTeX's comment notes the *intent* is ±½ slant, with the CSS centering making a full-margin shift achieve that half-shift.
- **Scale of effect**: NewCMMath's `integral.v1` (display-size `\int`) has IC = 459 design units = 0.459 em — nearly half an em. This produces a very visible shift at display size. Symmetric operators (`\sum`, `\prod`) have IC = 0, so they are unaffected.
- **Fix**: Added `italic_corrections::Dict{String,Int}` to `_LayoutCtx` (already parsed from the MATH table — no new parsing needed). Added `_base_italic_correction_em` helper that reads the first glyph's IC from a box list. Applied `±IC/2` to all three limits branches (NKSuperscript, NKSubscript, NKDecorated): subscripts shift left, superscripts shift right.
- **OpenType MATH spec basis**: Offset limits by ±½ italic correction to track the slanted stroke.

## 2026-05-24T22:21+00:00 Italic correction for side-placement subscripts (integral limits)

- **Bug**: `\int_0^\infty` showed subscript and superscript horizontally aligned — no italic correction effect visible. Root cause: `\int` uses **side placement** (sub/sup to the right), not limits placement, so the limits-branch IC fix from the previous session had no effect.
- **Key distinction**: `_use_limits` returns `false` for `\int` — integrals always use side placement in standard TeX. The limits-placement IC fix (±½IC applied above/below) was correct but irrelevant for integrals.
- **KaTeX rule for side placement** (`supsub.ts` lines 117–131): for single-symbol bases, `marginLeft = makeEm(-italic_correction)` is applied **only to the subscript**. Superscripts are not shifted. This moves the subscript left by the full IC so it sits under the stroke bottom rather than the advance width.
- **Fix**: Applied `ic_em = _base_italic_correction_em(tmp_base, ctx, scale)` in both side-placement branches:
  - `NKSubscript`: `x0 + base_adv - ic_em + b.x`
  - `NKDecorated` (sub+sup together): subscript at `script_x - ic_em`, superscript at `script_x` unchanged
- **Verification**: For `\int_0^\infty` with NewCMMath, subscript (`zero`) lands at x=0.5400, superscript (`infinity`) at x=0.9990. Difference = 0.459 em = IC of `integral.v1` (459/1000 du). Correct.
- **No effect on symmetric operators**: `\sum`, `\prod` etc. have IC = 0, so they are unaffected.
- All 789 tests pass. Demo sheets regenerated.

## 2026-05-25T00:17+00:00 Code review and clean-up pass

- **Scope**: Audit for idiomatic Julia, abstractions, logic bugs, and KaTeX-equivalence; apply agreed fixes incrementally.
- **Bugs found and fixed**:
  - **Lexer UTF-8 unsafe**: `src/lexer.jl` advanced byte indices with `i += 1` rather than `nextind`. Any multi-byte char in math input (e.g. `α + β`) raised `StringIndexError` on the first non-ASCII codepoint. Fixed; two regression tests added.
  - **Brace fallback inversion** in `_layout_horiz_brace!`: when the font lacked a brace glyph the `brace_top`/`brace_bot` placeholder values referenced the wrong side of the body in both `is_over` and `!is_over` cases, so any secondary script note would have been mis-positioned. Rare path (none of the bundled fonts hit it) but logic is now consistent with the comment above.
- **Idiomatic clean-up**:
  - Deduplicated `_HORIZ_BRACE_COMMANDS` (parser) / `_HORIZ_BRACE_GLYPHS` (layout) — same six-entry dict in two places; reduced the parser-side copy to a `Set{String}` of recognised commands.
  - `NKSpace` now carries a `width::Float64` field instead of round-tripping the value through `String` (`Node(NKSpace, "0.5")` → `parse(Float64, sp.value)` on every layout). Added a `space_node(w)` constructor.
  - Factored the 22 repeated `for b in tmp; push!(boxes, LayoutBox(b.element, dx+b.x, dy+b.y, b.scale)); end` loops into `_emit_shifted!(boxes, src, dx, dy)`.
  - Added `_with_variant(ctx, variant)` helper so `NKFontSwitch` doesn't have to rebuild the whole 10-field `_LayoutCtx` by hand.
- **Architectural refactor**:
  - **Split `_layout_node!` per kind** (`src/layout.jl`): the 500-line if/elseif chain that handled every `NodeKind` is now a thin dispatcher delegating to `_layout_X!` helpers (one per kind). Behaviour is byte-identical; the goal was readability — each rule now lives in a function of 5–80 lines.
  - **`glyph_metrics` / `glyph_metrics_by_codepoint` now return `Union{GlyphMetrics, Nothing}`** instead of throwing. This is a breaking API change. Every internal caller previously wrapped them in `try/catch return nothing end`; the new contract removes the exception-driven control flow from the hot path. Test for `@test_throws Exception` replaced with `=== nothing`.
- **Considered and rejected**:
  - Removing the redundant `scale` parameter (which always equals `size_scale(style, mc)`): would touch ~40 sites mechanically for no functional gain and remove explicit documentation of the contract.
  - Reclassifying `NKHorizBrace` from `:inner` to `:ord`: KaTeX's `horizBrace.ts` emits `minner`, so our current classification matches.
  - Factoring the 3× repeated `base.kind === NKHorizBrace && return _layout_horiz_brace!(...)` dispatch: only 2 lines per site after the per-kind split, so factoring would add ceremony without saving meaningful code.
- **Verification**: All 797 tests pass after every commit (originally 789; +8 for new Unicode lexer tests and one nothing-return test). Smoke-tested a 18-input suite including direct-Unicode and empty/malformed inputs.

## 2026-05-25T09:01+00:00 Complete _SYMBOL_CODEPOINTS audit (item 2)

- Audited all entries in `_CMD_ATOM_CLASS` against `_SYMBOL_CODEPOINTS` and `_DISPLAY_OP_CODEPOINTS`.
- The 2026-05-24 session had already added ~85 entries; the residual "genuinely missing" symbols were: `\doteq` (U+2250), `\Join` (U+2A1D), `\Bbbk` (U+1D55C), `\backslash` (U+005C). All four added.
- All remaining entries in `_CMD_ATOM_CLASS` without a codepoint are legitimately handled by other code paths (font switch → NKFontSwitch, accents → NKAccent, `\big*` delimiters, `\bmod`/`\pmod`/`\xleftarrow`/`\xrightarrow`, ellipsis variants), or are negated composites without a single codepoint (documented limitation), or `\bigplus` (no standard Unicode codepoint).
- CLAUDE.md Known Limitations updated: "~150 AMS symbols missing" bullet replaced with accurate `\bigplus` note.
- 798 tests pass.

## 2026-05-25T11:00+00:00 Makie integration via MathTeXEngine extension

- **Goal**: Make CairoMakie/GLMakie use TeXLayout's OpenType-aware typesetter when both packages are loaded, as a transparent drop-in replacement for MathTeXEngine's layout engine.

- **Architecture**: Julia package extension system (`[weakdeps]` + `[extensions]` in Project.toml). Extension `ext/MathTeXEngineExt.jl` overrides `MathTeXEngine.generate_tex_elements` when both MathTeXEngine and GeometryBasics are loaded. GeometryBasics is listed as a co-trigger because it is always transitively loaded with MathTeXEngine and the extension needs `Point2f`.

- **Key constraint — `__precompile__(false)`**: Julia raises `"Method overwriting is not permitted during Module precompilation"` when an extension replaces an existing method. The extension opts out of precompilation entirely; methods are JIT-compiled at runtime as normal.

- **Data flow**:
  1. `generate_tex_elements(str)` receives a `LaTeXString` whose content is `"$...$"` — strip surrounding `$` before passing to `parse_latex`.
  2. `layout(node, tl_family, Display)` returns a flat list of `LayoutBox` values.
  3. Each box is converted to `(MTE.TeXChar, Point2f, Float64)` or `(MTE.HLine, …)` / `(MTE.VLine, …)`.
  4. Makie's `texelems_and_glyph_collection` consumes the result unchanged (it filters on `isa MathTeXEngine.TeXChar` etc., so real MTE types are mandatory).

- **Glyph resolution**: `FreeTypeAbstraction.glyph_index(font, name::String)` for PostScript names, with fallbacks for single-char names and `uniXXXX` encoded names.

- **MTE FontFamily construction**: Built from TeXLayout's `FontFamily` absolute paths; `MathTeXEngine.FontFamily(Dict(:math => path, ...))` passes absolute paths through unchanged.

- **Position type**: Must be `Point2f` (a `StaticVector`/`VecTypes`) — Makie's `to_ndim` requires `VecTypes`; plain tuples fail.

- **Validation**: Smoke-tested with `L"x^2"` (2 TeXChars at correct positions/scales), `L"\frac{a}{b}"` (1 HLine), and a CairoMakie figure with five formulae (fraction, sum, integral, sqrt, Greek letters). All rendered correctly.

- **Files added/modified**:
  - `ext/MathTeXEngineExt.jl` (new): full extension with five helper functions
  - `Project.toml`: added `[weakdeps]` and `[extensions]` sections
  - `tools/demo_makie.jl` (new): self-contained CairoMakie demo
  - `CLAUDE.md`: updated "Makie integration" status in Known Limitations

- **Open questions / future work**:
  - The `font_family` argument to the overridden `generate_tex_elements` is currently ignored; TeXLayout always uses `default_font_family()`. Could honour caller-specified fonts in future.
  - `__precompile__(false)` adds ~1 s first-call compilation overhead; a more surgical fix (overloading on `str::LaTeXString` specifically to avoid the same-signature restriction) could restore precompilation, but requires investigation.

## 2026-05-25T15:03+00:00 \middle auto-sizing and \text{}/\mbox{} upright font

- **`\middle` auto-sizing** (NKMiddle):
  - Added `NKMiddle` to `NodeKind` enum; value holds PS glyph name.
  - `_parse_delimited_children!` now intercepts `\middle` tokens and emits `NKMiddle` nodes instead of falling through to the command branch.
  - `_layout_delimited!` refactored to segment children at `NKMiddle` boundaries; measures combined content height across all segments; then calls `_layout_delim!` for left, each middle, and right delimiter with identical `required_du` — all delimiters auto-size to the same height.
  - Multiple `\middle` delimiters per group are supported (n+1 segments for n middles).

- **`\text{}`/`\mbox{}` upright rendering** (NKText):
  - Parser previously had `NKText` in the enum but never produced it; `\text` fell through to the command error branch.
  - Added explicit `cmd == "\\text" || cmd == "\\mbox"` case in `_parse_command!`; consumes brace argument, returns `Node(NKText, [body])`.
  - `_with_text_mode` helper copies `_LayoutCtx` with `mode = :text`.
  - `_layout_char!` uses `_upright_glyph` when `ctx.mode === :text` — regular font, no italic remapping.
  - `_layout_text!` applies `_with_text_mode` and delegates to the child node.
  - Dispatch added: `k === NKText && return _layout_text!(...)` in `_layout_node!`.
  - Inter-atom spacing already suppressed inside text fragments (guard on `ctx.mode === :math`).

- All 813 tests pass. Stress test PNG generated for visual verification.
- Committed as `139bced`.

## 2026-05-25T15:28+00:00 Fix \mathrm font path and \text{} space preservation

- **Problem**: Both `\mathrm` and `\text{}` were routing through `_upright_glyph`, which is semantically wrong. `\mathrm` is a math-mode command and must use the math font's own codepoint lookup (`_char_glyph`), not the text font. `\text{}` correctly uses `_upright_glyph` (prefers `family.regular`).

- **Fix 1 — `\mathrm` uses math font**: Removed the `:mathrm → _upright_glyph` early-return branch from `_variant_glyph` in `layout.jl`. The function now falls through to `_char_glyph` for `\mathrm`, which uses math-font codepoint lookup.

- **Fix 2 — whitespace preserved as `TKSpace` tokens**: Lexer previously silently discarded all whitespace runs. Changed `lexer.jl` to emit `Token(TKSpace, " ", i)` for each whitespace run (collapsed to a single token). This enables the parser to see spaces and handle them mode-appropriately.

- **Fix 3 — math-mode parser skips `TKSpace`**: Added `TKSpace` skip guards to:
  - `_parse_sequence_children!` — skips `TKSpace` in math-mode groups.
  - `_parse_delimited_children!` — skips `TKSpace` before `\right`/`\middle` check.
  - `_parse_matrix_body!` — skips `TKSpace` as a handled token kind.
  - `_parse_atom!` — already had a `while TKSpace` skip; reviewed and confirmed correct.

- **Fix 4 — text-mode preserves spaces**: Added `_parse_text_sequence_children!` which converts `TKSpace` to `Node(NKChar, " ")`. Added `_parse_text_argument!` which uses this for `\text{}`/`\mbox{}` brace arguments.

- **Fix 5 — `' '` in layout emits `Space` element**: In `_layout_char!`, added an early-return branch for `ctx.mode === :text && ch == ' '` that calls `glyph_metrics_upright(ctx.family, ' ')` to get the font's word-space advance and emits `LayoutBox(Space(w), x0, y0, scale)`.

- **Semantic distinction documented**: `\mathrm` → math font (`_char_glyph`); `\text{}` → regular font (`_upright_glyph`). Both currently use the math font's PS name in the `Glyph` struct — acceptable for matched font families like NewCM.

- 6 new tests added; 819 total, all pass.
- Committed to `TeXLayout.jl`.
