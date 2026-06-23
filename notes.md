
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
- Root cause: NodeKind.Sqrt branch emitted only body boxes and an HRule bar; the radical glyph was never placed.
- Fix: restructured NodeKind.Sqrt to lay out body at y=0, measure ink, compute `required_du` (total vertical span from body bottom to rule top in design units), then call new `_layout_radical!` helper.
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

## 2026-05-23T11:55+00:00 Inter-atom spacing implementation

- Implemented full TeX atom-class spacing (Knuth Ch. 17 / KaTeX `spacingData.ts`).
- `_CHAR_ATOM_CLASS`: maps characters (including U+2212 minus, U+2217 asterisk) to `ord/bin/rel/open/close/punct/inner`.
- `_CMD_ATOM_CLASS`: maps LaTeX command names (all Greek, common operators, arrows, delimiters, etc.) similarly.
- `_SPACINGS` / `_TIGHT_SPACINGS`: thin=3/18, medium=4/18, thick=5/18 em lookup tables for Display/Text and Script/ScriptScript styles.
- `_atom_class(node)`: scripted nodes (NodeKind.Superscript/NodeKind.Subscript/NodeKind.Decorated) inherit base atom class; NodeKind.Space is `:neutral`.
- `_interatom_space(prev, next, style)`: selects tight table for Script/ScriptScript styles.
- `NodeKind.Sequence`/`NodeKind.Group` branch now inserts auto-spacing `Space` elements in `:math` mode; neutral explicit spaces reset the context preventing double-spacing.
- 6 new layout tests (523 total, all passing): `a+b` medium, `a=b` thick, `a,b` thin, `\sin x` thin, Script suppression, explicit-space no double-gap.
- Added `tools/visualise_spacing.jl`: 13-row grid rendering with auto-spacing gaps shaded.
- Open items remaining: limits placement (`\lim_{x}` in Display), inter-atom spacing for `\text{}`/`\mbox{}`, accent rendering, font switching commands, array/matrix environments.

## 2026-05-23T12:44+00:00 Limits placement and large operator display-size glyphs

### Bug fixed: large operators (`\sum`, `\prod`, `\int`, etc.) were invisible
- Root cause: `_cmd_glyph` looked up PS name `"sum"` which does not exist in NewCMMath; correct name is `"summation"`, `"product"`, `"integral"`, etc.
- Fix: added `_DISPLAY_OP_CODEPOINTS` dict mapping command names to Unicode codepoints; `NodeKind.Command` branch now uses `glyph_name_by_codepoint` to obtain the correct PS name.

### New feature: display-size large operators
- In Display style, `\sum`, `\prod`, `\int`, etc. select the smallest `vert_constructions` variant with `advance >= display_operator_min_height` (1300 du from MATH table).
- Operator glyph centred on the math axis (same approach as `\left`/`\right` delimiters).

### New feature: limits placement (TeX Rule 15 / KaTeX `assembleSupSub.ts`)
- `\lim`, `\limsup`, `\liminf`, `\det`, `\gcd`, `\inf`, `\sup`, `\max`, `\min`, `\Pr` automatically use limits placement in Display style.
- `\sum`, `\prod`, `\coprod`, `\bigcap`, `\bigcup`, etc. also use limits placement in Display style.
- `\limits` / `\nolimits` explicit overrides parsed as `NodeKind.LimitsOverride` AST node wrapping the base.
- Limits algorithm: lay each part at origin, measure ink extents with `_boxes_top`/`_boxes_bottom`, then apply four MATH constants:
  - `upper_limit_gap_min = 200 du` — minimum ink gap above base top
  - `upper_limit_baseline_rise_min = 111 du` — minimum sup baseline above base top
  - `lower_limit_gap_min = 167 du` — minimum ink gap below base bottom
  - `lower_limit_baseline_drop_min = 600 du` — minimum sub baseline below base bottom
- Each part centred horizontally over the base; total width = max(base_w, sub_w, sup_w).
- In Text/Script styles (or after `\nolimits`), sub/sup remain in normal beside-base positions.
- `limsup` and `liminf` added to `_OPERATOR_NAMES` in `parser.jl` (were previously falling through as `NodeKind.Command`).
- 33 new test assertions across 8 `@testset` blocks; 556 total tests, all passing.

## 2026-05-23T22:14+00:00 Accents, overline/underline, binary reclassification

- Implemented KaTeX Rule 12 (accents): base in cramped style; vertical placement via `AccentBaseHeight`; horizontal via `MathTopAccentAttachment`; accent does not widen advance. 11 non-stretchy commands: `\hat`, `\acute`, `\grave`, `\ddot`, `\tilde`, `\bar`, `\breve`, `\check`, `\dot`, `\mathring`, `\vec`.
- Codepoint choice: `\acute`/`\grave`/`\bar` use U+00B4/U+0060/U+00AF (Latin-1) rather than KaTeX's Modifier Letter codepoints (U+02CA/02CB/02C9) absent in NewCMMath.
- Added `NodeKind.OverUnder` node kind (single kind, `value = "overline"/"underline"`) for `\overline` and `\underline`. Rule 9: body in cramped style, HRule above using `OverbarVerticalGap`/`OverbarRuleThickness`. Rule 10: body in current style, HRule below using `UnderbarVerticalGap`/`UnderbarRuleThickness`.
- Implemented TeX Rules 5 & 6 (binary atom reclassification) via two-pass algorithm in `_layout_children!`: left-to-right (Rule 5) then right-to-left (Rule 6). Neutral atoms (spaces) transparent to both passes. Constants `_BIN_LEFT_CANCEL`/`_BIN_RIGHT_CANCEL` as module-level tuples.
- All planned items (2 → 3 → 4) complete; 649 tests passing.
- Next: `default_font_family()` via Artifacts, array/matrix environments, or wide accents (`\widehat`/`\widetilde`).

## 2026-05-23T22:52+00:00 Implement \widehat and \widetilde (horizontal extensible accents)

- Added `\widehat => 0x02C6` and `\widetilde => 0x02DC` to `_ACCENT_CODEPOINTS` in `parser.jl`. They share codepoints with `\hat`/`\tilde`; the layout engine distinguishes them via `_WIDE_ACCENT_COMMANDS`.
- `horiz_constructions` was already parsed by `_parse_math_variants` in `math_table.jl` — no binary parsing changes needed.
- Added `horiz_constructions::Dict{String,GlyphConstruction}` field to `_LayoutCtx` struct; updated both constructor call sites (`layout()` and the `NodeKind.FontSwitch` branch).
- Added `_WIDE_ACCENT_COMMANDS = Set{String}(["\\widehat", "\\widetilde"])` constant.
- Added `_layout_wide_accent!` helper: tries pre-built variants (smallest whose `advance >= required_du`), then extensible assembly using the existing `_min_extender_reps`/`_expand_assembly_parts`/`_gap_min_overlap` helpers, then falls back to largest variant. All parts centred over the base via `x0 + (base_w - glyph_w) / 2`.
- `NodeKind.Accent` branch now dispatches wide accents to `_layout_wide_accent!` immediately after computing `accent_y`; fixed-size path unchanged.
- 666 tests passing (added 3 parser tests + 4 layout tests for wide accents).
- Updated `AGENTS.md` feature table, `katex_rules.md` Rule 12 status, and `demo_features.jl` accent panel.

## 2026-05-23T23:49+00:00 Implement horizontal brace family (\overbrace, \underbrace, etc.)

- Added `NodeKind.HorizBrace` node kind (`value = command name`, `children[1] = body`). Six commands: `\overbrace` (uni23DE), `\underbrace` (uni23DF), `\overbracket` (uni23B4), `\underbracket` (uni23B5), `\overparen` (uni23DC), `\underparen` (uni23DD).
- Normal `^`/`_` parsing naturally wraps `NodeKind.HorizBrace` in `NodeKind.Superscript`/`NodeKind.Subscript`/`NodeKind.Decorated`; the layout engine intercepts these before the standard script algorithm.
- Atom class: `NodeKind.HorizBrace → :inner` (matching KaTeX's `minner`).
- `_layout_horiz_brace!` algorithm: body → brace (horizontally stretched via `_layout_wide_accent!`) → note (primary script, limits-style centered over max(body_w, note_w)) → secondary script (side-placed to the right using standard shift constants).
- Brace placement: gap between body ink edge and brace ink edge = `0.1 * scale`; gap between brace ink edge and note ink edge = `0.2 * scale`. Reference glyph y_min/y_max obtained by same variant-selection logic as `_layout_wide_accent!` to derive brace_y from the chosen glyph's actual metrics.
- "Over" braces (overbrace/overbracket/overparen): note is the `sup`, placed above. "Under" braces (underbrace/underbracket/underparen): note is the `sub`, placed below. The opposite script becomes the secondary (side-placed).
- 712 tests passing (46 new: 9 parser + 11 layout, plus the existing KaTeX suite was unaffected).
- Updated `AGENTS.md` feature table; added `horiz_braces.png` demo panel to `demo_features.jl`.

## 2026-05-24T13:52+00:00 Implement \begin/\end environment parsing and matrix/array layout

- Added `NodeKind.Matrix` node kind; value encodes `"env\x00nrow\x00ncol"`, children are flat row-major cells (each a `NodeKind.Group`).
- `_MATRIX_ENVS` constant maps 8 environment names to delimiter glyph names, alignment symbol, and scale factor. Bare `matrix` and `smallmatrix` have no delimiters.
- `_read_brace_word!(p)` helper reads a brace-delimited name token for `\begin`/`\end`.
- `_parse_matrix_body!` handles `&` column separators, `\\` row breaks (with optional `[dim]` skip), `\end` stop, and lenient EOF. Uses `copy(current_cell)` to avoid Julia mutable aliasing pitfall — forgetting this made all cells empty.
- `\begin` dispatches to `_parse_matrix_body!` for known environments; unknown environments produce `NodeKind.Command`. Stray `\end` produces `NodeKind.Space`.
- `_layout_matrix!` two-pass algorithm: first pass lays out all cells at origin to measure widths/heights/depths; second pass positions cells using computed column/row extents.
- Grid centred on math axis via `y_shift`; cells always use Text style (not Display), matching TeX array rules.
- Column separation `5/18 em` per side; extra row gap `3/18 em`.
- Delimiter wrapping via `_layout_delim!`; left delimiter width applied as offset before emitting content boxes (not via retroactive splicing).
- Key bugs fixed during implementation: (1) Julia mutable aliasing bug with `current_cell` reference, (2) wrong `y0` argument to `_layout_delim!` (should not pre-add axis height — the function does this internally), (3) sort direction bug in layout test (negating y, not reversing both keys).
- 761 tests passing (25 new parser + 14 new layout + 5 new katex smoke tests).
- Updated `AGENTS.md` feature table (Array/matrix environments: ✗ → ✓).

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
- **Multi-codepoint issue**: ~10 negated/variant commands (`\nleqslant`, `\lvertneqq`, `\varsubsetneq`, etc.) have no single Unicode codepoint — they're defined as base + U+0338 (COMBINING SOLIDUS OVERLAY) or U+FE00 (VARIATION SELECTOR). Math fonts don't encode these at a consistent single codepoint. Current state: produce blank space. Fix requires two-glyph overlay (base + combining stroke). Documented in AGENTS.md Known Limitations.
- **Next step**: bulk-expand `_SYMBOL_CODEPOINTS` (~140 clean additions), simplify `_char_glyph` and `_cmd_glyph` to codepoint-only paths.

## 2026-05-24T18:36+00:00 Codepoint-only glyph resolution implemented

- Completed the codepoint-only strategy (continued from earlier session):
  - `_DISPLAY_OP_CODEPOINTS`: added `iiiint` (U+2A0C), `oiint` (U+222F), `oiiint` (U+2230).
  - `_SYMBOL_CODEPOINTS`: added ~85 new entries — AMS binary operators (`\boxplus`, `\ltimes`, `\curlywedge`, etc.), extended relations (`\leqslant`, `\lesssim`, `\bowtie`, `\doteqdot`, `\Subset`, `\preccurlyeq`, etc.), negated relations with single codepoints (`\nleq`, `\nprec`, `\subsetneq`, etc.), ordinary symbols (`\measuredangle`, `\imath`, `\triangle`, `\checkmark`, `\mho`, `\Finv`, etc.), delimiter aliases (`\lvert`, `\lVert`, `\llbracket`, `\lgroup`, `\lmoustache`), and punctuation (`\colon`, `\cdotp`, `\ldotp`).
  - `_char_glyph`: removed `isletter` PS-name-first block; now always resolves by codepoint. Fixes math-italic letter rendering (PS name "x" → upright roman; cmap U+0078 → italic by font design).
  - `_layout_node!` NodeKind.Command else-branch: replaced `_cmd_glyph` fallback with `nothing`; commands not in `_SYMBOL_CODEPOINTS` silently produce no glyph.
  - `_cmd_glyph`: updated comment to document it is now used exclusively for MATH table font-internal names (size variants, assembly parts).
- All 789 tests pass. Committed as `ddad75e`.
- Remaining open items: two-glyph overlay for multi-codepoint negated relations; Makie integration; Schola/Termes/Bonum artifacts.

## 2026-05-24T20:50+00:00 Three visual bug fixes: widehat centering, vmatrix bar, sqrt body position

### Bug 1: Widehat/accent horizontal centering (two sites in `src/layout.jl`)

- **Root cause**: `_layout_wide_accent!`'s `_place()` helper centred glyphs by `advance_width/2`. For zero-advance combining characters (e.g. New CM `circumflexcmb`: adv_w=0, x_min=-446, x_max=-82; STIX Two `uni0302`: adv_w=0, x_min=-371, x_max=-89), this placed the glyph at `x0 + base_w_em/2` but the ink lay entirely to the left of that position.
- Same bug in the NodeKind.Accent fixed-size fallback (`accent_w = advance_width * s / upm`).
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
- **Fix**: Added `italic_corrections::Dict{String,Int}` to `_LayoutCtx` (already parsed from the MATH table — no new parsing needed). Added `_base_italic_correction_em` helper that reads the first glyph's IC from a box list. Applied `±IC/2` to all three limits branches (NodeKind.Superscript, NodeKind.Subscript, NodeKind.Decorated): subscripts shift left, superscripts shift right.
- **OpenType MATH spec basis**: Offset limits by ±½ italic correction to track the slanted stroke.

## 2026-05-24T22:21+00:00 Italic correction for side-placement subscripts (integral limits)

- **Bug**: `\int_0^\infty` showed subscript and superscript horizontally aligned — no italic correction effect visible. Root cause: `\int` uses **side placement** (sub/sup to the right), not limits placement, so the limits-branch IC fix from the previous session had no effect.
- **Key distinction**: `_use_limits` returns `false` for `\int` — integrals always use side placement in standard TeX. The limits-placement IC fix (±½IC applied above/below) was correct but irrelevant for integrals.
- **KaTeX rule for side placement** (`supsub.ts` lines 117–131): for single-symbol bases, `marginLeft = makeEm(-italic_correction)` is applied **only to the subscript**. Superscripts are not shifted. This moves the subscript left by the full IC so it sits under the stroke bottom rather than the advance width.
- **Fix**: Applied `ic_em = _base_italic_correction_em(tmp_base, ctx, scale)` in both side-placement branches:
  - `NodeKind.Subscript`: `x0 + base_adv - ic_em + b.x`
  - `NodeKind.Decorated` (sub+sup together): subscript at `script_x - ic_em`, superscript at `script_x` unchanged
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
  - `NodeKind.Space` now carries a `width::Float64` field instead of round-tripping the value through `String` (`Node(NodeKind.Space, "0.5")` → `parse(Float64, sp.value)` on every layout). Added a `space_node(w)` constructor.
  - Factored the 22 repeated `for b in tmp; push!(boxes, LayoutBox(b.element, dx+b.x, dy+b.y, b.scale)); end` loops into `_emit_shifted!(boxes, src, dx, dy)`.
  - Added `_with_variant(ctx, variant)` helper so `NodeKind.FontSwitch` doesn't have to rebuild the whole 10-field `_LayoutCtx` by hand.
- **Architectural refactor**:
  - **Split `_layout_node!` per kind** (`src/layout.jl`): the 500-line if/elseif chain that handled every `NodeKind` is now a thin dispatcher delegating to `_layout_X!` helpers (one per kind). Behaviour is byte-identical; the goal was readability — each rule now lives in a function of 5–80 lines.
  - **`glyph_metrics` / `glyph_metrics_by_codepoint` now return `Union{GlyphMetrics, Nothing}`** instead of throwing. This is a breaking API change. Every internal caller previously wrapped them in `try/catch return nothing end`; the new contract removes the exception-driven control flow from the hot path. Test for `@test_throws Exception` replaced with `=== nothing`.
- **Considered and rejected**:
  - Removing the redundant `scale` parameter (which always equals `size_scale(style, mc)`): would touch ~40 sites mechanically for no functional gain and remove explicit documentation of the contract.
  - Reclassifying `NodeKind.HorizBrace` from `:inner` to `:ord`: KaTeX's `horizBrace.ts` emits `minner`, so our current classification matches.
  - Factoring the 3× repeated `base.kind === NodeKind.HorizBrace && return _layout_horiz_brace!(...)` dispatch: only 2 lines per site after the per-kind split, so factoring would add ceremony without saving meaningful code.
- **Verification**: All 797 tests pass after every commit (originally 789; +8 for new Unicode lexer tests and one nothing-return test). Smoke-tested a 18-input suite including direct-Unicode and empty/malformed inputs.

## 2026-05-25T09:01+00:00 Complete _SYMBOL_CODEPOINTS audit (item 2)

- Audited all entries in `_CMD_ATOM_CLASS` against `_SYMBOL_CODEPOINTS` and `_DISPLAY_OP_CODEPOINTS`.
- The 2026-05-24 session had already added ~85 entries; the residual "genuinely missing" symbols were: `\doteq` (U+2250), `\Join` (U+2A1D), `\Bbbk` (U+1D55C), `\backslash` (U+005C). All four added.
- All remaining entries in `_CMD_ATOM_CLASS` without a codepoint are legitimately handled by other code paths (font switch → NodeKind.FontSwitch, accents → NodeKind.Accent, `\big*` delimiters, `\bmod`/`\pmod`/`\xleftarrow`/`\xrightarrow`, ellipsis variants), or are negated composites without a single codepoint (documented limitation), or `\bigplus` (no standard Unicode codepoint).
- AGENTS.md Known Limitations updated: "~150 AMS symbols missing" bullet replaced with accurate `\bigplus` note.
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
  - `AGENTS.md`: updated "Makie integration" status in Known Limitations

- **Open questions / future work**:
  - The `font_family` argument to the overridden `generate_tex_elements` is currently ignored; TeXLayout always uses `default_font_family()`. Could honour caller-specified fonts in future.
  - `__precompile__(false)` adds ~1 s first-call compilation overhead; a more surgical fix (overloading on `str::LaTeXString` specifically to avoid the same-signature restriction) could restore precompilation, but requires investigation.

## 2026-05-25T15:03+00:00 \middle auto-sizing and \text{}/\mbox{} upright font

- **`\middle` auto-sizing** (NodeKind.Middle):
  - Added `NodeKind.Middle` to `NodeKind` enum; value holds PS glyph name.
  - `_parse_delimited_children!` now intercepts `\middle` tokens and emits `NodeKind.Middle` nodes instead of falling through to the command branch.
  - `_layout_delimited!` refactored to segment children at `NodeKind.Middle` boundaries; measures combined content height across all segments; then calls `_layout_delim!` for left, each middle, and right delimiter with identical `required_du` — all delimiters auto-size to the same height.
  - Multiple `\middle` delimiters per group are supported (n+1 segments for n middles).

- **`\text{}`/`\mbox{}` upright rendering** (NodeKind.Text):
  - Parser previously had `NodeKind.Text` in the enum but never produced it; `\text` fell through to the command error branch.
  - Added explicit `cmd == "\\text" || cmd == "\\mbox"` case in `_parse_command!`; consumes brace argument, returns `Node(NodeKind.Text, [body])`.
  - `_with_text_mode` helper copies `_LayoutCtx` with `mode = :text`.
  - `_layout_char!` uses `_upright_glyph` when `ctx.mode === :text` — regular font, no italic remapping.
  - `_layout_text!` applies `_with_text_mode` and delegates to the child node.
  - Dispatch added: `k === NodeKind.Text && return _layout_text!(...)` in `_layout_node!`.
  - Inter-atom spacing already suppressed inside text fragments (guard on `ctx.mode === :math`).

- All 813 tests pass. Stress test PNG generated for visual verification.
- Committed as `139bced`.

## 2026-05-25T15:28+00:00 Fix \mathrm font path and \text{} space preservation

- **Problem**: Both `\mathrm` and `\text{}` were routing through `_upright_glyph`, which is semantically wrong. `\mathrm` is a math-mode command and must use the math font's own codepoint lookup (`_char_glyph`), not the text font. `\text{}` correctly uses `_upright_glyph` (prefers `family.regular`).

- **Fix 1 — `\mathrm` uses math font**: Removed the `:mathrm → _upright_glyph` early-return branch from `_variant_glyph` in `layout.jl`. The function now falls through to `_char_glyph` for `\mathrm`, which uses math-font codepoint lookup.

- **Fix 2 — whitespace preserved as `TokenKind.Space` tokens**: Lexer previously silently discarded all whitespace runs. Changed `lexer.jl` to emit `Token(TokenKind.Space, " ", i)` for each whitespace run (collapsed to a single token). This enables the parser to see spaces and handle them mode-appropriately.

- **Fix 3 — math-mode parser skips `TokenKind.Space`**: Added `TokenKind.Space` skip guards to:
  - `_parse_sequence_children!` — skips `TokenKind.Space` in math-mode groups.
  - `_parse_delimited_children!` — skips `TokenKind.Space` before `\right`/`\middle` check.
  - `_parse_matrix_body!` — skips `TokenKind.Space` as a handled token kind.
  - `_parse_atom!` — already had a `while TokenKind.Space` skip; reviewed and confirmed correct.

- **Fix 4 — text-mode preserves spaces**: Added `_parse_text_sequence_children!` which converts `TokenKind.Space` to `Node(NodeKind.Char, " ")`. Added `_parse_text_argument!` which uses this for `\text{}`/`\mbox{}` brace arguments.

- **Fix 5 — `' '` in layout emits `Space` element**: In `_layout_char!`, added an early-return branch for `ctx.mode === :text && ch == ' '` that calls `glyph_metrics_upright(ctx.family, ' ')` to get the font's word-space advance and emits `LayoutBox(Space(w), x0, y0, scale)`.

- **Semantic distinction documented**: `\mathrm` → math font (`_char_glyph`); `\text{}` → regular font (`_upright_glyph`). Both currently use the math font's PS name in the `Glyph` struct — acceptable for matched font families like NewCM.

- 6 new tests added; 819 total, all pass.
- Committed to `TeXLayout.jl`.

## 2026-05-25T15:40+00:00 Thread font_slot through layout to enable correct text-font rendering

- **Problem**: `Glyph` only stored a PS name; the renderer always used `family.math` to resolve it. `\text{}` glyphs used `family.regular` for metrics but the math font for rendering — inconsistent for mismatched families.

- **Fix — `font_slot` field on `Glyph`**: Added `font_slot::Symbol` (`:math` | `:regular`) as the second field of `Glyph`. All glyph builders set this explicitly:
  - `_char_glyph`, `_cmd_glyph`, `_variant_glyph`, `_layout_command!`, `_layout_accent!` → `:math`
  - `_upright_glyph` → `:regular` when `family.regular !== nothing` (and looks up PS name from the regular font); `:math` as fallback.

- **PS name consistency fix**: Previously `_upright_glyph` got metrics from `family.regular` but the PS name from the math font. Now both come from the same font. Added `glyph_name_by_codepoint(font_path::String, cp::UInt32)` overload to `fonts.jl` to support this.

- **Makie extension updated**: `_box_to_mte` now takes `reg_font` alongside `math_font`; dispatches on `el.font_slot` to select the correct FreeType face for `glyph_index` resolution. `generate_tex_elements` loads `reg_font` (falling back to `math_font` if no regular font configured).

- **Known limitation (pre-existing)**: Metric values for regular-font glyphs are divided by `ctx.upm` (the math font's UPM). If `family.regular` has a different UPM than `family.math`, the em-unit widths will be slightly wrong. In practice, all supported font families use UPM=1000 consistently, so this is not currently an issue.

- 821 tests, all pass. Committed.

## 2026-05-25T16:22+00:00 Fix Luciole blank glyphs, operator font selection, and missing accents

- **Root causes identified and fixed** for three Luciole-specific bugs:

- **Issue #1 & #2 — blank glyphs in \text{} and named operators (\sin etc.)**
  - `_upright_glyph` correctly produces `font_slot = :regular` glyphs with PS names from `regular.ttf` (e.g. "s", "i", "n")
  - Both rendering tools (`demo_sheet.jl`, `stress_test_sheet.jl`) called `renderface(face_math, el.glyph_name, ...)` unconditionally — Luciole Math has no glyph named "s" → blank
  - Fix: load `face_regular = FTFont(family.regular)` when available; select render face by `el.font_slot` at render time
  - Note: using the regular font for operators is architecturally correct — it matches KaTeX behaviour

- **Issue #3 — Luciole accents dropped (\dot{q}, \tilde{a}, \breve{u}, etc.)**
  - `_ACCENT_CODEPOINTS` uses spacing modifier codepoints (U+02C6 ˆ, U+02DC ˜, U+02D8 ˘, U+02D9 ˙, U+02C7 ˇ, U+00B4 ´, U+02DA ˚)
  - Luciole Math carries these at combining-form codepoints (U+0302–U+030C) instead — primary lookup returned "" → silent drop
  - Fix: added `_ACCENT_FALLBACK_CODEPOINTS` in `layout.jl` mapping the 10 most common accent commands to their combining equivalents; `_layout_accent!` now tries fallback before giving up
  - Affected accents recovered: \hat, \acute, \tilde, \breve, \check, \dot, \mathring, \ddot, \grave, \bar

- **Incidental fix**: `stress_test_sheet.jl` was using `magick` (not installed); aligned with `demo_sheet.jl` to use `convert`

- All three fixes are in commit `4a22217`; verified visually with Luciole stress test and demo sheets, and NewCM regression check passed

## 2026-05-27T08:48+00:00 Makie-path performance review and caching opportunities

- Benchmarked the TeXLayout/Makie integration in a temporary Julia environment using `BenchmarkTools`, with `MathTeXEngine`, `LaTeXStrings`, and `GeometryBasics` loaded so the package extension was active.
- Current hot path findings:
  - `src/layout.jl:2504-2515` calls `load_math_table(family.math)` on every layout.
  - `src/math_table.jl:757-780` reparses the font file every time; there is no MATH-table cache.
  - `src/fonts.jl:49-87` already caches FreeType font handles and parsed `hmtx` tables by path, so lower-level font-face reuse exists but higher-level math-font metadata reuse does not.
  - `ext/MathTeXEngineExt.jl:147` uses `result = Tuple[]`, producing `Vector{Tuple}` and a type-unstable accumulation path in the Makie-facing conversion stage.
- Benchmark summary on repeated calls with the default font:
  - Small expression `x^2+y^2=z^2`: `parse_latex` ~0.7 μs; `load_math_table` ~0.97 ms; `layout(node, ff, Display)` ~0.65 ms; `MathTeXEngine.generate_tex_elements` ~0.70 ms.
  - Larger expression with `\int`, `\frac`, and `\sum`: `parse_latex` ~5.9 μs; `load_math_table` ~0.95 ms; `layout(node, ff, Display)` ~1.11 ms; `MathTeXEngine.generate_tex_elements` ~1.06 ms.
  - `load_math_table` alone allocates ~2.31 MiB per call, essentially dominating repeated-call cost.
- Simulated the effect of a per-font cache by reusing a prebuilt `_LayoutCtx`:
  - Cached lower-level layout: ~24 μs (small) and ~160 μs (large).
  - Cached MTE conversion from existing boxes: ~21 μs (small) and ~249 μs (large).
  - This suggests a per-font runtime cache could reduce repeated-call latency by roughly an order of magnitude for small formulas and by multiple times for larger ones, while also removing most current allocation pressure.

## 2026-05-27T08:56+00:00 Performance implementation plan for Makie path

- Agreed implementation scope for the first four speed-focused items:
  1. cache parsed `MathTable` data by math-font path,
  2. cache a higher-level Makie runtime bundle by effective `FontFamily`,
  3. remove abstract tuple accumulation in the Makie extension,
  4. cache glyph-name to glyph-index lookups per loaded font.
- Added execution todos and dependencies in the session SQL tracker:
  - `perf-cache-math-table`
  - `perf-cache-makie-runtime` depends on `perf-cache-math-table`
  - `perf-cache-glyph-index` depends on `perf-cache-makie-runtime`
  - `perf-validate-benchmarks` depends on all implementation items
- Plan emphasis: keep the public API unchanged, build on the existing font cache in `src/fonts.jl`, and benchmark each step separately so the impact of each optimization remains attributable.

## 2026-05-27T08:59+00:00 Implement Makie-path caches and concrete conversion container

- Implemented `MathTable` caching in `src/math_table.jl` via `_MATH_TABLE_CACHE`, keyed by math-font path. `load_math_table` now does a cached lookup instead of rereading and reparsing the font on repeated calls.
- Implemented a cached Makie runtime bundle in `ext/MathTeXEngineExt.jl`, keyed by the effective `FontFamily` path tuple. The bundle reuses:
  - loaded math and regular `FTFont` handles,
  - the derived `MathTeXEngine.FontFamily`,
  - separate glyph-name → glyph-index dictionaries for the math and regular font handles.
- Replaced the old abstract `Tuple[]` accumulation with a concrete `_MTEElementTuple` vector, so `MathTeXEngine.generate_tex_elements(::LaTeXString)` now infers a concrete return type instead of `Vector{Tuple}`.
- Minor helper cleanup: `_single_char` avoids `collect(name)` in glyph-name handling, reducing per-call string work in the conversion path.
- Added a regression test in `test/test_math_table.jl` asserting that repeated `load_math_table(FIXTURE_FONT_PATH)` calls return the same cached object.
- Validation results:
  - test suite: 862/862 passing
  - `parse_latex`: still ~0.7 us small / ~6.2 us large
  - `load_math_table`: ~60 ns, 0 allocations after warm-up
  - `layout`: ~25 us small / ~162 us large
  - `TeXLayout.generate_tex_elements`: ~26 us small / ~169 us large
- `MathTeXEngine.generate_tex_elements`: ~48 us small / ~199 us large
- Net effect versus the earlier baseline: repeated Makie rendering with the same font now avoids the ~0.95 ms MATH-table parse and multi-megabyte allocation spike on every call, moving the steady-state cost into the tens to low hundreds of microseconds for the benchmarked formulas.

## 2026-05-27T11:05+00:00 Compare cached TeXLayout path against plain MathTeXEngine

- Ran fresh steady-state `BenchmarkTools` benchmarks in two separate temporary Julia environments:
  - **Plain MathTeXEngine**: loaded `MathTeXEngine` and `LaTeXStrings`, without loading `TeXLayout`
  - **TeXLayout Makie path**: loaded `TeXLayout`, `MathTeXEngine`, `LaTeXStrings`, and `GeometryBasics` so the package extension was active
- Benchmarked the same two formulas in both cases via `MathTeXEngine.generate_tex_elements(::LaTeXString)` after warm-up:
  - small: `x^2+y^2=z^2`
  - large: `\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2} + \sum_{n=1}^{\infty} \frac{(-1)^n}{n^2}`
- Median results:
  - **Plain MathTeXEngine**
    - small: 155864 ns, 74160 bytes, 1568 allocs
    - large: 1131836 ns, 251256 bytes, 5747 allocs
  - **TeXLayout extension**
    - small: 48040 ns, 21528 bytes, 192 allocs
    - large: 147548 ns, 51608 bytes, 439 allocs
- Relative steady-state speedup of the cached TeXLayout path over plain MathTeXEngine:
  - small formula: ~3.2x faster, ~3.4x less memory, ~8.2x fewer allocations
  - large formula: ~7.7x faster, ~4.9x less memory, ~13.1x fewer allocations
- Caveat: this is a Makie-facing end-to-end comparison, not a claim that the internal layout algorithms are directly equivalent. The formulas and output API were matched, but the two engines make different implementation choices and do not emit identical intermediate structures.

## 2026-05-27T11:28+00:00 Signed PNG diff utility for stress-test comparisons

- Added `tools/png_diff.jl` to compare two rendered PNGs from TeXLayout runs.
- The tool flattens each input onto white, converts to grayscale, and computes a signed pixel delta `after - before`.
- Output encoding:
  - zero delta -> white,
  - positive delta -> green tint with intensity proportional to `abs(delta)`,
  - negative delta -> red tint with intensity proportional to `abs(delta)`.
- Dimension mismatches are now handled by padding both inputs onto a white canvas sized to the per-axis maximum of the two images; the tool emits a warning describing the original and padded sizes.
- Implementation uses ImageMagick via whichever binary is available on the host (`magick` or `convert`), matching the existing toolchain approach.

## 2026-05-27T11:38+00:00 Refresh AGENTS.md for current repository state

- Updated `AGENTS.md` to reflect the current tree layout, including `ext/MathTeXEngineExt.jl`, the broader `tools/` set, artifact-managed fonts, and repo-level notes files.
- Added explicit developer guidance that Julia code should be formatted with Runic.jl, using the `runic` command in Bash or the global Julia environment `@runic`.
- Documented the current cache layers more accurately: font cache in `src/fonts.jl`, `MathTable` cache in `src/math_table.jl`, and the Makie runtime cache in `ext/MathTeXEngineExt.jl`.

## 2026-05-27T11:42+00:00 Refresh published docs for cache behaviour

- Updated `docs/src/91-developer.md` so the architecture overview no longer claims the pipeline only mutates the font cache; it now documents both the font-handle cache and the parsed `MathTable` cache.
- Added a focused developer-doc note that `load_math_table(path)` memoizes the OpenType MATH table by math-font path, which matters for repeated layout and Makie rendering.
- Updated `docs/src/03-makie.md` to mention the extension/runtime caching story in steady-state Makie usage.
## 2026-05-27T15:23+00:00 Plan MathTeXEngine-style layout visualiser

- New task: add a command-line visualisation tool under `tools/` that reproduces the style of the older MathTeXEngine debug view for arbitrary expressions.
- Chosen implementation approach: use TeXLayout's own `parse_latex` + `layout` output and render a custom PNG with helper overlays, rather than introducing a CairoMakie dependency into the package project.
- Planned visual layers: rendered glyph/rule output, baseline + math-axis guides, and coloured metric overlays inspired by `external/MathTeXEngine.jl/prototype/prototype.jl` (left bearing / post-ink advance / above-baseline ink / descender).
- Need to update `AGENTS.md` tool list once the script exists and then run formatting plus the relevant Julia checks.

## 2026-05-27T15:35+00:00 Implement visualise_metrics CLI tool

- Added `tools/visualise_metrics.jl`, a self-contained command-line visualiser that renders TeXLayout output with MathTeXEngine-style metric overlays.
- The tool uses only `TeXLayout` + `FreeTypeAbstraction`, so it stays inside the package project rather than depending on CairoMakie.
- Output layers:
  - black glyph/rule rendering,
  - grey baseline and red math-axis guides,
  - yellow origin-to-left-ink region,
  - green right-ink-to-advance region,
  - red above-baseline ink region,
  - blue descender region,
  - outline/origin/advance guides per glyph.
- CLI shape: `julia tools/visualise_metrics.jl "expr" [out.png|out.ppm] [:font_symbol|/path/to/font.otf]`.
- Added a subprocess smoke test in `test/test_tools.jl`; because the tool self-activates via `using Pkg`, the test restores `JULIA_LOAD_PATH=@:@stdlib` before launching it.

## 2026-05-27T16:33+00:00 Plan CairoMakie visualise_metrics variant

- New follow-on task: add `tools/visualise_metrics_makie.jl` so the expression itself is drawn by Makie's `text!`, with metric boxes layered over the top.
- Dependency plan: use the existing `examples/` environment for CairoMakie, LaTeXStrings, and MathTeXEngine rather than adding Makie to the main package project.
- Alignment plan: match the old MathTeXEngine prototype by placing the text at `(0, 0)` in data space with `align = (:left, :baseline)` and scaling all overlay geometry from TeXLayout `LayoutBox` coordinates by the chosen font size.
- Need to confirm how best to make the local TeXLayout checkout visible from that environment, because the committed `examples/Manifest.toml` still points at a machine-local dev path.

## 2026-05-27T16:48+00:00 Implement visualise_metrics_makie and fix Makie alignment

- Added `tools/visualise_metrics_makie.jl`, a CairoMakie-backed companion to `visualise_metrics.jl`.
- The tool activates the repo's `examples/` environment (for CairoMakie / LaTeXStrings / MathTeXEngine) and pushes the local TeXLayout checkout onto `LOAD_PATH` so the current workspace code is used.
- Important debugging result: the first attempts misaligned the overlays because Makie applies an internal `tex_offset` inside `texelems_and_glyph_collection`; I also accidentally applied that offset to the whole `text!` call once, which shifted the rendered formula twice.
- Final implementation:
  - renders the formula with a single Makie `text!` call at `(0, 0)`,
  - queries Makie's own `texelems_and_glyph_collection` helper to obtain the exact internal `tex_offset`,
  - derives overlay rectangles from the same `MathTeXEngine.TeXChar` metrics that Makie uses to render,
  - applies the internal offset only to the overlays and guide geometry, not to the `text!` anchor.
- Smoke render for `\\frac{a}{b}` now aligns numerator and denominator overlays correctly in the saved PNG.
## 2026-05-27T20:47+00:00 Radical hook / top-rule alignment investigation

- Investigated the visible mismatch at the leading join of `\sqrt{...}` in `src/layout.jl`.
- Current implementation in `_layout_radical!` places the radical glyph so that its overall `y_max` aligns with the top of the separately drawn `HRule`.
- For NewCMMath this is not the correct visual anchor: raster inspection of the base `radical` glyph at a large size shows the topmost ink is a short slanted tip, while the long flat vinculum begins several pixels lower.
- Relevant metrics for the base radical glyph are `advance_width = 833`, `x_max = 853`, `y_min = -960`, `y_max = 40`; the flat rule is therefore currently joined using box metrics that describe the full outline, not the actual hook-to-vinculum transition.
- This explains why the hook appears slightly low relative to the top rule even though the layout boxes report exact `y_max`/rule-top agreement.
- Secondary finding: `RadicalExtraAscender` is parsed from the MATH table (`40` du in NewCMMath) but is not currently used anywhere in radical layout. This is likely a separate completeness issue for overall radical height / reserved whitespace, but it does not explain the visible join mismatch by itself.
- KaTeX avoids this exact problem by drawing the radical and vinculum as one SVG path (`external/KaTeX/src/svgGeometry.ts`) rather than splicing a font radical glyph to a separate rectangular rule.
- Proposed implementation direction:
  - derive a radical-specific vertical join metric from the chosen glyph / top assembly part, and align the rule to that metric rather than to `y_max`;
  - audit the horizontal join point as well, since the current splice uses `advance_width` even though the glyph ink extends to `x_max`;
  - fold `RadicalExtraAscender` into the radical box height / clearance calculation once the visual anchor is corrected;
  - add a rendered regression test so this class of mismatch is caught by pixels, not only by layout-box bounds.

## 2026-05-27T20:54+00:00 LuaTeX / unicode-math reference for radicals

- Checked `unicode-math` / LuaTeX sources for how square roots are built.
- `unicode-math` defines radicals in terms of engine primitives (`\Uradical` and `\Uroot`) rather than computing a visible hook/vinculum join from user-level box metrics.
- The LaTeX tagging adaptation in `latex3/latex2e` (`required/latex-lab/latex-lab-unicode-math.dtx`) reinforces this: the preferred path for `\sqrt` and `\root...\of` is `\tex_Uradical:D` / `\tex_Uroot:D`, with older box constructions used only as fallbacks for some offset cases.
- Takeaway for TeXLayout: LuaTeX is useful as a rendering oracle and as evidence that radicals should be treated as a font/engine construction problem. It does not expose a standard public “join metric”; that still appears to need deriving from the selected radical glyph / assembly geometry.

## 2026-05-27T21:02+00:00 Radical join alignment fix

- Updated `src/layout.jl` so radical variants are no longer aligned by raw glyph `y_max`; the rule now joins at a derived radical join height `y_max - RadicalExtraAscender`.
- Radical selection now treats `RadicalExtraAscender` as part of the required total height, while body-centering and Rule 11 redistribution use the span from the radical bottom up to the rule join.
- Changed the horizontal splice so the radicand begins at the radical's right ink bound (`x_max` / assembly max `x_max`) and the top rule starts half a rule thickness earlier for a small overlap, following the spirit of the old MathTeXEngine construction.
- Extended the `\sqrt{x}` layout test to check:
  - the radicand starts at the radical's right ink bound,
  - the rule overlaps the join by half the rule thickness,
  - the radical top sits `RadicalExtraAscender` above the rule top.
- Full test suite passes after the change (867/867), and `\sqrt` smoke tests succeeded across all bundled font families.

## 2026-05-27T21:09+00:00 Radical anchor correction

- After visual feedback, backed out the vertical `RadicalExtraAscender` anchor change.
- The mistake was treating `RadicalExtraAscender` as if it were the visible hook/vinculum join offset. Raster inspection does not support that for NewCMMath: the visible flat top sits much farther below `y_max` than one extra-ascender step.
- Current state:
  - keep the original vertical anchoring by glyph `y_max`,
  - keep the horizontal splice fix (body starts at the radical right ink bound; rule overlaps by half a rule thickness),
  - keep the stronger layout regression test for the horizontal join.
- Full test suite passes after the correction (866/866).

## 2026-05-27T21:32+00:00 Makie rule-anchor adapter fix

- Fixed the TeXLayout → MathTeXEngine adapter in `ext/MathTeXEngineExt.jl` so rule positions are converted between the two geometry conventions:
  - `TeXLayout.HRule.y` is the rule bottom edge, but `MathTeXEngine.HLine` expects the y centreline.
  - `TeXLayout.VRule.x` is the rule left edge, but `MathTeXEngine.VLine` expects the x centreline.
- `_box_to_mte` now shifts HRule positions by `+ thickness/2` in y and VRule positions by `+ thickness/2` in x before constructing `MathTeXEngine.HLine` / `VLine`.
- Documented this geometry contract in `AGENTS.md` under the Makie integration notes.
- Validation:
  - main test suite still passes (866/866),
  - CairoMakie/MathTeXEngine-path checks confirm exported `HLine` and `VLine` coordinates now match the expected centerlines derived from TeXLayout boxes.
## 2026-05-27T22:18+00:00 Nested radical horizontal alignment fix

- Investigated `\sqrt{1 + \sqrt{1 + \sqrt{1 + \sqrt{1 + x}}}}`: the repeated `1+` drifted slightly right at each larger radical variant.
- Root cause in `src/layout.jl`: `_radical_body_offset_du` used `max(advance_width, x_max)`, so the radicand started after the radical ink overhang instead of after the radical delimiter box width.
- In NewCMMath the prebuilt radical variants have `advance_width = 1000` du but `x_max = 1020` du (`radical` is `833` vs `853`), so each nested level picked up an unwanted extra `20` du.
- Checked LuaTeX `make_radical` (`texk/web2c/luatexdir/tex/mlist.c`): TeX builds the result as delimiter box followed by the overbar/radicand hlist, so horizontal placement is by delimiter **width**, not ink bounds.
- Fixed `_radical_body_offset_du` to use `advance_width` only and added a regression test that matches each nested radical glyph to its rule bar and asserts the radicand starts exactly one radical advance to the right.

## 2026-05-27T22:24+00:00 Nested radical vertical alignment fix

- Follow-up on the nested-radical investigation: the repeated `+` glyphs were also drifting downward in `\sqrt{1 + \sqrt{1 + \sqrt{1 + \sqrt{1 + x}}}}`.
- Root cause: after the usual TeX/KaTeX-style clearance adjustment, `_layout_sqrt!` applied a second `body_shift` that lowered the radicand by half of the selected radical's excess cover.
- LuaTeX `make_radical` does not do that extra centering step: it increases the clearance `clr` when needed and then packs the delimiter beside an overbar/radicand vlist.
- Removed the extra body shift so nested radicands keep their original baseline, and added a regression test asserting that all four `+` glyphs in the deep nested example share the same `y` position.

## 2026-05-30T19:03+00:00 Fix section-header overlap in stress_test_makie.jl

- **Root cause**: two compounding bugs in the Makie stress-test layout tool.
  1. `em_bbox` used the glyph's actual ink extents for vertical bounds, but Makie's
     `height_insensitive_boundingbox_with_advance` applies the *font-level* ascender/descender
     as a floor/ceiling for every glyph — making Makie's bounding boxes much taller.
  2. Makie's `text!` with `align = (:left, :baseline)` for `LaTeXString` falls through
     to `:bottom` behaviour (placing the formula's bounding-box bottom at the anchor),
     not the mathematical baseline.  These two errors compounded: formulas were shifted
     ~30–70 px higher than intended, extending into the section header of the same row.
- **Fix** (all changes in `tools/stress_test_makie.jl`):
  - `em_bbox` now takes `font_ascender` and `font_descender` (from
    `FreeTypeAbstraction.ascender/descender`) and applies per-glyph vertical clamping:
    `min(font_descender, el.y_min / upm) * box.scale`, matching Makie exactly.
  - `run_stress_test_makie` loads font-level metrics from the math face.
  - Rendering loop changes `align` to `(:left, :bottom)` and lowers the anchor by each
    expression's individual `below_px_i = round(Int, -by1_i * BASE_PX)` so the
    mathematical baseline ends up at the intended screen y.
- Rows are now correctly sized and expressions sit cleanly within their strips.

## 2026-05-31T09:05+00:00 Bug fix: STIX Two \middle| overshoots \langle/\rangle height

- **Symptom**: with STIX Two, `\left\langle \frac{a}{b} \,\middle|\, \frac{c}{d} \right\rangle` rendered the bar ~38% taller than the angle brackets.
- **Root cause**: STIX Two provides only one pre-built bar variant (advance=941). For display-mode fractions the required height is ~1820 DU; the single variant is insufficient, so the glyph assembly is used.
  - `_layout_assembly!` used **minimum overlaps** (= maximum assembly height): with `n=2` extenders and min overlap=100, total_du = 2623 ≫ required_du ≈ 1820.
  - The angle brackets have a 13-variant ladder and select the closest one (advance=1907), so they render at the correct height.
- **Fix** (`src/layout.jl:_layout_assembly!`): after selecting the minimum `n`, increase overlaps uniformly (proportional to each gap's connector capacity) to shrink total_du toward required_du. Each gap is clamped to its per-gap connector limit.
  - Result after fix: bar ink height ≈ 1819 DU vs langle 1906 DU — near-match (bar is slightly shorter than brackets, which is cosmetically acceptable and far better than 38% overshoot).
  - The slight residual discrepancy is because the langle variant overshoots by the quantisation of its size ladder (~87 DU), while the assembly can be sized almost exactly.
- **Not affected**: `_layout_radical_assembly!` (top-anchored, different centering semantics).
- All 950 tests pass.


## 2026-06-05T19:07+00:00 Text + multi-line layer design (branch latex-text)

- Goal: lay out general strings mixing styled text, `\\` line breaks, inline `$…$`
  math, and display environments (`align`). Auto line-breaking / full justification
  remain out of scope. Example target:
  `\textbf{Hello} world\\\begin{align}x&=y\\y&=x^2-z\end{align}`.
- Diagnosis: current engine is single-tree, single-baseline, dimensionless flat
  output, math-only top level. Missing abstraction = a *measured, composable box*
  (TeX hbox/vbox).
- Decision: **Option 1** (wrapper layer) now; **Option 2** (unified box-and-glue
  IR) is the long-term target. Wrote a temporary `future.md` design draft
  (not retained in the current tree; see `docs/src/91-developer.md` now) explaining
  how Option 1's `TeXBox`/`vstack`/`hconcat` are the eagerly-shaped degenerate form
  of `Box`/`VBox`/`HBox`, so migration is incremental, not a rewrite.
- Wrote `text-spec.md`: full, self-contained implementation spec. Key points:
  - New `src/{shaping,document,compose}.jl`; no breaking changes; renderer contract
    (`Vector{LayoutBox}`) preserved.
  - Document AST (`Block`/`Line`/`Run`/`TextSpan`/`TextAttrs`) separate from math
    `Node`; **text kept as source strings (spans), not NodeKind.Char** — required so a
    future HarfBuzz shaper can kern/ligature whole runs.
  - Pluggable `TextShaper` seam (`MetricShaper` in core; `HarfBuzzShaper` in a
    documented-but-unbuilt extension). Shaper contract: emit PS-name `Glyph(:regular)`
    boxes in em, baseline y=0, so renderer/Makie path is untouched (no GID glyphs in v1).
  - Decisions locked: y-origin = first baseline; bold/italic/bolditalic font slots
    used via new `glyph_metrics_slot`; width = widest line by default, optional fixed
    width; alignment per block (:left default; display blocks :center).
  - **Line height = LaTeX semantics**: baseline advance = `max(baselineskip,
    prevdepth + ascent(next) + lineskip)` (defaults 1.2 em / 0.1 em).
  - `align` reuses the matrix machinery (add to `_MATRIX_ENVS`; derive `rl…` colspec).
    Known v1 approximation: `&` uses matrix column gap, not true relation spacing.
- Open/limitations recorded in spec: align spacing approx; `\textsf`/`\texttt`→regular;
  blank-line paragraph breaks not honoured; HarfBuzz extension not yet implemented.

## 2026-06-05T20:35+00:00 Text layer test suite written

- Wrote `test/test_text.jl` covering all 10 spec §9 cases plus unit tests for each new layer.
- Structure: 6 testsets (font additions, MetricShaper, parser additions, document parser, composition
  primitives, layout_document integration); ~55 individual testsets, ~120 @test assertions.
- Strategy: all new symbols accessed as `TeXLayout.Xxx` (no module-level `using`), so the file
  can be included without aborting existing tests while implementation is in progress.
- Baseline on inclusion before implementation: 951 passed (all existing), 8 failed, 48 errored.
  - 8 failures: parser tests (brace leniency, missing align/gather/aligned envs, colspec derivation)
    — these are assertions that evaluate false rather than throwing.
  - 48 errors: `UndefVarError` for all new symbols not yet defined in the module.
- Implementation order from text-spec.md §12: fonts.jl → shaping.jl → parser.jl → document.jl
  → compose.jl → wire exports → iterate to green.

## 2026-06-06T10:17+00:00 Text layer implementation complete

- Implemented all six steps from text-spec.md §12: fonts.jl additions, shaping.jl,
  parser.jl modifications, document.jl, compose.jl, exports + housekeeping.
- Final test score: 1091/1091 passing (0 failed, 0 errored).
- Key implementation notes:
  - `_codepoint_metrics` extracted from `glyph_metrics_by_codepoint`; `glyph_metrics_slot`
    uses a priority fallback chain (bolditalic→bold→italic→regular→math, de-duplicated).
  - `shape_span` (MetricShaper) calls `_font_upm` per glyph to handle per-font UPM when
    fallback chains cross font boundaries.
  - `_parse_text_body!` + `_parse_text_group!` are mutually recursive; bare `{` grouping,
    font-switch commands, and `\text`/`\mbox` all call `_parse_text_group!` uniformly.
  - Test fix: Case 3 (tall line forces lineskip) uses `\dfrac` not `\frac` — Text-style
    fraction denominator (0.345 em) < line_height - lineskip - x_ascent (0.63 em); display-
    style (`\dfrac`) denominator (0.686 em) > threshold, correctly triggers lineskip path.
  - Exports: layout_document, TeXBox, LayoutOptions, TextShaper, MetricShaper.
  - Added tools/visualise_text.jl for FreeType rendering of layout_document output.

## 2026-06-20T14:42+00:00 Text layout architecture review

- Reviewed `future.md`, `text-spec.md`, and the recent refactor notes after the
  `latex-text` merge.
- Current state: Option 1 text/document layer is implemented as eager measured
  `TeXBox` composition (`shape_span`, `hconcat`, `vstack`, `layout_document`) while
  the math engine still lays out by mutating flat `Vector{LayoutBox}` scratch buffers.
- Structural direction: preserve the public `layout_document`/`TeXBox` contract,
  then introduce an internal box-tree module that first powers text composition and
  only later absorbs math constructs construct-by-construct.
- Codebase guardrail: build on the recent refactor boundaries (`enums.jl`,
  `payloads.jl`, `src/tables/`, `src/layout/*.jl`) instead of adding another parallel
  layout path.
- Near-term plan: harden the existing text wrapper, add richer document/layout
  regression tests, factor composition semantics into internal HBox/VBox primitives,
  then migrate selected math constructs where the box abstraction clearly removes
  scratch-vector measurement logic.

## 2026-06-20T14:59+00:00 Text wrapper hardening step

- Left HarfBuzz implementation out of scope and focused on validating the current
  `MetricShaper`/`TeXBox` wrapper layer.
- Fixed `layout_document` display spacing: `abovedisplayskip` and
  `belowdisplayskip` are now explicit extra gaps instead of synthetic empty
  baselines.  A display-only document therefore starts near the first real display
  baseline instead of being pushed down by an empty vskip item.
- Added text regression tests for styled span font slots, inline math inside a
  styled text group, display-only y-origin behavior, and display skip deltas.
- Updated the document layout snapshot for the intentional display-spacing change.
- Fixed FreeType debug renderers (`visualise_text.jl`, `visualise_metrics.jl`,
  `stress_test_freetype.jl`) to compare `Glyph.font_slot` as `FontSlot` enum values
  instead of stale symbols.
- Validation: full package test suite passes (1121/1121).  `visualise_text.jl` and
  `visualise_metrics.jl` smoke renders succeeded after refreshing the tools
  environment metadata for the local TeXLayout checkout.

## 2026-06-20T15:02+00:00 Internal box tree introduced for document composition

- Added `src/boxes.jl` with internal measured `Box` primitives:
  `ShapedBox`, `HBox`, `VBox`, and a recursive `shape` pass back to
  `Vector{LayoutBox}`.
- Rebased `hconcat`, `vstack`, and `layout_document` stacking through the internal
  box layer while preserving the public `TeXBox` result type and renderer contract.
- Kept math layout unchanged; existing math `_layout_*!` helpers still emit flat
  `LayoutBox` vectors directly.
- Added a direct composition test for `HBox` shaping, in addition to the existing
  `hconcat`/`vstack` behavior tests.
- Validation after the internal refactor: full package test suite passes
  (1124/1124), and `visualise_text.jl` / `visualise_metrics.jl` smoke renders still
  succeed.

## 2026-06-20T15:16+00:00 Text stress-test sheet tool

- Added `tools/stress_test_text.jl`, a PNG stress-test renderer for
  `layout_document` output.
- The sheet places literal LaTeX/document source in a left column and the rendered
  mixed text/math output in a right column.
- Coverage includes plain text, significant spaces, explicit line breaks, fixed
  width alignment, text styles/nesting, inline math, display `equation`/`align`/
  `gather`, tall inline math, line-height options, malformed inline math, unknown
  commands, empty styled groups, and display-only input.
- Implementation uses FreeType rendering directly so it exercises TeXLayout's
  document layout path rather than Makie's LaTeXString math-only path.
- Validation: `julia --project=tools tools/stress_test_text.jl :new_cm
  /tmp/texlayout-text-stress.png` succeeded and the generated sheet was visually
  inspected.

## 2026-06-20T15:36+00:00 Text-layer edge-case regression pass

- Added focused parser/layout tests for adjacent display blocks, display blocks at
  document start/end, unknown environments in text mode, display alignment within
  fixed width, fixed-width overflow, and display-block vertical stacking.
- Found and fixed a document text font-switch bug: `\textsf` and `\texttt` were
  preserving surrounding bold/italic state, despite the v1 decision that they map
  to the regular slot.  `_apply_font_switch` now clears bold/italic for those
  commands, matching `\textrm`/`\textnormal`.
- Validation: targeted text test run passed (1148/1148 through the package test
  harness), then the full package suite passed (1148/1148).

## 2026-06-20T15:53+00:00 Font-slot path resolution centralization

- Started step 4 of the text-layout cleanup by centralizing physical font-path
  selection for `Glyph.font_slot` in `_font_path_for_slot(family, slot)`.
- Updated FreeType render/debug tools and docs examples to use the shared helper
  instead of reimplementing text-slot fallback order locally.
- Added tests covering full bundled text-slot families and math-only fallback
  behaviour, so future renderer changes should not silently diverge from the
  layout font-slot contract.

## 2026-06-20T15:58+00:00 Internal box-tree hardening

- Strengthened `src/boxes.jl` constructors so `ShapedBox`, `HBox`, and `VBox`
  validate finite non-negative measured extents when constructed.
- Moved `VBox` child/offset/dx length validation from emission time to
  construction time, making malformed trees fail closer to their source.
- Box constructors now copy caller-owned vectors, preventing later mutation of
  temporary arrays from changing already-built box trees.
- Added composition tests for validation failures, defensive copies, and nested
  recursive offset shaping.

## 2026-06-21T13:13+00:00 Math flat layout range-emission first pass

- Reviewed `math-flat-layout-plan.local.md`; the plan is sound for scratch-buffer removal, with snapshot identity as the right guardrail.
- Added range-based `_boxes_top`, `_boxes_bottom`, `_boxes_vextent`, `_translate_range!`, and `_base_italic_correction_em` helpers in `src/layout.jl`.
- Converted `src/layout/scripts.jl` script and limits placement to emit base/sub/sup boxes into the shared output buffer, measure those emitted ranges, and translate script ranges in place.
- Updated `compose.measure` to use the same range-extent helpers for consistency.
- Focused `test_layout.jl` + `test_snapshots.jl` run passed after the conversion.
- Follow-up: constructs that currently emit delimiters or radicals before measured children (`sqrt`, `genfrac`, `delimited`, matrix delimiters) need explicit range reordering if converted without changing serialized emission order.

## 2026-06-21T13:39+00:00 Math flat layout constructs range-emission pass

- Relaxed the append-order requirement per user direction and converted `src/layout/constructs.jl` to the clearer emit/measure/translate flow for fractions, genfracs, radicals, delimiters, arrows, accents, and over/under rules.
- Removed all `LayoutBox[]` scratch buffers and `_emit_shifted!` use from `constructs.jl`; child ranges are emitted into the shared output buffer and translated in place.
- Updated layout tests that previously assumed glyph append order to select semantic glyphs by position or axis proximity.
- Changed snapshot serialization to sort rounded box records before hashing, so snapshots guard element geometry and metrics without treating append order as semantic.
- Validation: focused `test_layout.jl` + `test_snapshots.jl` passed (1168/1168).
- Benchmark smoke after this pass: `layout/scripts_fraction` 51 allocs / 6432 bytes, `layout/radical_delimited` 33 allocs / 3248 bytes, `layout/accents_braces_arrows` 116 allocs / 12800 bytes, `layout/matrix_cases` 139 allocs / 12816 bytes.

## 2026-06-21T13:49+00:00 Horizontal brace range-emission pass

- Converted `_layout_horiz_brace!` in `src/layout/extensible.jl` to emit body, primary note, and secondary note into the shared buffer and translate recorded ranges in place.
- Removed the remaining `LayoutBox[]` scratch buffers and `_emit_shifted!` use from `extensible.jl`.
- Validation: focused `test_layout.jl` + `test_snapshots.jl` passed (1168/1168).

## 2026-06-21T13:50+00:00 Matrix range-emission pass

- Converted `src/layout/matrix.jl` to emit cells into the shared output buffer during measurement, record `cell_starts`/`cell_stops`, and translate each cell range after row and column positions are computed.
- Removed per-cell scratch `LayoutBox` buffers from matrix/array layout and deleted the now-unused `_emit_shifted!` helper from `src/layout.jl`.
- Validation: focused `test_layout.jl` + `test_snapshots.jl` passed (1168/1168).
- Full package validation passed (1168/1168). Final benchmark smoke: `layout/scripts_fraction` 51 allocs / 6432 bytes, `layout/radical_delimited` 33 allocs / 3248 bytes, `layout/accents_braces_arrows` 112 allocs / 12128 bytes, `layout/matrix_cases` 128 allocs / 11328 bytes, `layout_document/document_inline_display` 671 allocs / 49648 bytes.

## 2026-06-21T14:04+00:00 Stress-test reference URL fix and visual diff run

- Fixed `tools/stress_test_all.jl` reference downloads to use GitHub release asset names `stress_test_output_<font>.png`; the previous `stress_test_<font>.png` pattern returned 404 for all bundled fonts.
- `julia --project=tools tools/stress_test_all.jl` rendered all eight current sheets and downloaded all eight references.
- Diff result: all fonts reported `CHANGED` with max delta 255 and ~27-29% changed pixels.
- The large diff is dominated by reference/current sheet size mismatch: current sheets are ~11999-13654 px tall while v0.1.0-stress references are ~7867-9032 px tall, so the comparison pads the shorter reference with white. A fresh reference baseline for the current stress sheet content is needed before this tool can distinguish real layout drift from sheet-content/canvas changes.

## 2026-06-21T14:24+00:00 Unified per-case stress-test suite

- Added `tools/stress_test_suite.jl`, a unified stress CLI with `generate`, `pack`, `compare`, and `all` commands.
- The suite renders stable per-case PNG paths grouped by font, suite, and section: `math_freetype`, `text_freetype`, and optional `makie_cairo`. Full math/text/Makie sheets are generated under `sheets/` for visual inspection but excluded from reference tarballs and comparisons.
- Reference packaging uses Julia stdlib `Tar` and writes `stress_test_reference.tar`; comparison accepts either a local tarball or URL. New current images missing from the reference are reported as `NEW` and do not fail by default, preserving backwards-compatible addition of stress cases.
- Added root `justfile` helpers for common test and stress commands.
- Updated `tools/stress_test_all.jl` to delegate to the unified suite while preserving old usage with bare font-name arguments.
- Validation: generated `new_cm` math/text outputs, packed and self-compared a reference tarball (152/152 identical); generated all eight font artifacts without sheets and self-compared the tarball (1216/1216 identical); verified a synthetic new case reports `NEW` without failing; generated the `new_cm` optional Makie subset (6 PNGs).

## 2026-06-21T14:30+00:00 Stress-suite documentation sweep

- Updated `AGENTS.md` / `CLAUDE.md` to list `tools/stress_test_suite.jl`, the `stress_test_all.jl` compatibility wrapper, and the root `justfile`.
- Documented the canonical stress reference workflow: generate per-case PNGs, pack `stress_test_reference.tar` with Julia's `Tar` stdlib, compare against a local or downloaded reference, and treat full sheets as visual-only outputs.
- Updated `README.md` with concise developer-tooling instructions and clarified that the linked release images are full-sheet stress-renderer examples.
- Refreshed `math-flat-layout-plan.local.md` so its validation steps point at the per-case stress suite rather than the older sheet-only comparison.

## 2026-06-21T14:41+00:00 Flat-layout documentation correction

- Audited documentation for the range-emission math layout refactor and found stale wording in `AGENTS.md` / `docs/src/91-developer.md`.
- Replaced the old "purely additive" invariant with the current contract: layout helpers append boxes, measure just-emitted ranges, and may translate only those ranges in place.
- Documented that snapshot records are sorted before hashing, so append-order changes from allocation-reduction refactors are not treated as layout changes.
- Updated the ignored `math-flat-layout-plan.local.md` workspace note to stop referring to `_emit_shifted!` and emission-order identity as current requirements.

## 2026-06-21T15:01+00:00 Root-index radical placement

- Implemented `\sqrt[n]{x}` degree placement in `_layout_sqrt!`; the parser already produced `[degree, body]`, but layout previously ignored the degree child.
- Radical placement helpers now return the radicand offset and actual radical cover height so the degree can use `RadicalKernBeforeDegree`, `RadicalKernAfterDegree`, and `RadicalDegreeBottomRaisePercent`.
- Added a layout regression test checking degree scale, horizontal placement, and MATH-table bottom raise for `\sqrt[3]{x}`.

## 2026-06-21T15:03+00:00 Align relation spacing

- Adjusted `parse_environment!` for `align` / `aligned` so every even column (the cell after an alignment marker) starts with an empty `NodeKind.Group`.
- The empty group classifies as an ordinary atom and emits no boxes, letting existing math-list spacing produce `ord-rel-ord` spacing for cells like `=y`.
- Added parser and layout regression tests for the inserted empty group and the relation-space box before a leading `=`.
- Updated the `document_inline_display` snapshot hash for the intentional `align` geometry change.

## 2026-06-21T15:08+00:00 Blank-line paragraph breaks

- Preserved raw whitespace runs in `TokenKind.Space.value` so document parsing can distinguish ordinary whitespace from blank lines while math parsing continues to ignore space tokens.
- Added internal `ParagraphBreakBlock` markers for top-level blank lines and `LayoutOptions.parskip` (default `0.6em`) to control the extra vertical gap.
- Updated `layout_document` to fold paragraph-break markers into its existing pending-skip flow, including before display blocks.
- Added lexer, parser, and layout tests for raw whitespace preservation, blank-line parsing, default paragraph spacing, and custom `parskip`.

## 2026-06-21T15:12+00:00 Child-layout atom-class allocation cleanup

- Reworked `_layout_children!` to stream TeX Rule 5/6 binary-operator reclassification instead of allocating a `Vector{Symbol}` of atom classes for each child list.
- Kept separate left-context and emitted-spacing classifications so right-cancelled binary operators do not accidentally change the left context seen by later atoms.
- Left a collect-based fallback for non-vector iterables; normal parser/layout paths use `Vector{Node}` and avoid the extra class vector.
- Validation: focused layout/snapshot tests passed (1194/1194). Benchmark smoke showed lower layout allocations on representative math cases: `simple_atom` 37 allocs, `scripts_fraction` 49, `radical_delimited` 31, `accents_braces_arrows` 108, `matrix_cases` 124.

## 2026-06-21T15:32 Tool verification after layout refactor

- Verified all `tools/` scripts run against the refactored code (split layout
  modules + new document/compose/shaping/boxes layers). Package loads cleanly.
- Working: `visualise_bitmap`, `visualise_metrics`, `visualise_text`,
  `stress_test_freetype`, `stress_test_text`, `stress_test_latex`,
  `stress_test_makie`, `stress_test_suite` (generate/pack/compare round-trip
  identical), `stress_test_all` (wrapper passthrough). `prepare_font_artifacts`
  is a self-contained downloader (no TeXLayout API), parses/loads fine.
- **Fixed (Fira headings):** `stress_test_freetype.jl render_text!` called
  `renderface(face, string(ch), px)`, which resolves by *PostScript glyph name*.
  Works on AGL-named fonts (NewCM) but yields `.notdef` tofu on FiraMath
  (uni-names) / Luciole. Changed to pass the `Char` → cmap lookup, portable
  across all fonts. The box-glyph path (TeXLayout-supplied glyph names) is
  unchanged and correct; the text stress tool already used Char.
- **Fixed (Makie metrics tool):** `visualise_metrics_makie.jl` did `import Makie`,
  but Makie is only a transitive dep of the tools project → load error. Changed
  to `import CairoMakie.Makie`.
- Doc fix: corrected stale arg-order examples in AGENTS.md for
  `stress_test_freetype.jl` / `stress_test_makie.jl` (all per-font tools take the
  font spec first; freetype: `[:font] [out]`; makie: `[:font] [fmt] [out]`).
- Note: font symbols changed to underscore form (`:new_cm`, not `:newcm`).

## 2026-06-21T15:40 Stress-sheet header baseline fix

- `stress_test_freetype.jl render_text!` was vertically centring each header glyph
  independently (`top = H÷2 - by_px÷2 + 2`), so glyphs did not share a baseline
  (period looked raised, descenders/caps misaligned). Replaced with a fixed
  baseline `H÷2 + px÷3` and `top = baseline - by_px`, matching the baseline logic
  in `stress_test_text.jl render_text_line!`. Verified on NewCM and FiraMath.

## 2026-06-21T15:55 Align spacing double-count fix

- Reported: too much space before `=` in `\begin{align}x&=y+z...`. Cause: the
  recent "Add align relation spacing" change inserts an empty ord group so the
  leading `=` gets ord-rel spacing (5mu), but the matrix layout was *also*
  applying inter-column `_MATRIX_COLSEP` (2×5mu) between the r/l pair → 15mu
  before `=` instead of 5mu.
- Fix (`src/layout/matrix.jl`): for align/aligned, columns form right/left pairs
  glued at the alignment point — `col_gap(c)=0` for even c (inside a pair), full
  `2·_MATRIX_COLSEP` only between pairs (odd c>1); outer margin 0. Relation
  spacing now matches plain math: `=` in `\begin{align}x&=y\end{align}` lands at
  the same x as in `x=y`.
- Added layout regression test (align `=` x == plain `=` x); updated
  `document_inline_display` snapshot hash. Full suite: 1195 pass.

## 2026-06-21T16:30 Display math ($$, \[) and text-mode literal tokens

- Document parser (`src/document.jl`) now recognises display math `$$…$$` and
  `\[…\]` (→ free-standing `DisplayBlock(node, :displaymath)`, Sequence body laid
  out in Display style) and inline `\(…\)` (→ `MathRun`, Text style). A single
  `:displaymath` kind is used for both `$$` and `\[` (kind is informational;
  `compose.jl` ignores it).
- `$$` vs `$ $`: disambiguated by peeking — `$$` is two adjacent `MathShift`
  tokens; a spaced `$ $` has a Space between and stays inline. Display forms are
  gated on `!in_group` so they never open inside `{…}`/`\text{}`.
- Generalised `_parse_math_until_shift!` into `_parse_math_until!(p, isstop)` +
  added `_parse_math_until_command!(p, close)` and a `_peek` helper in parser.jl.
- Text-mode token dropping: `^`/`_`/`&` (and stray top-level `}`) now render as
  literal characters instead of being dropped by the catch-all `else`. Genuine
  unknown control sequences in text mode are still dropped (future work: a
  text-mode command/escape table).
- 7 new testsets in test_text.jl; full suite 1213 pass, no snapshot changes.

## 2026-06-21T17:00 Makie extension: route mixed text/math via layout_document

- `ext/MathTeXEngineExt.jl` `generate_tex_elements(::LaTeXString)` now branches on
  `_is_inline_math(str)`: a single `$…$` span (starts/ends with `$`, exactly two `$`
  total) keeps the old behaviour (parse_latex + layout, Display style); everything
  else goes through `layout_document(String(str)).boxes`. The shared `_box_to_mte`
  loop converts either box list.
- Verified end-to-end via CairoMakie: `L"x^2+\frac12"` (math), `"Energy $E=mc^2$ is
  famous."` (mixed text+math), and `$$…$$` (display) all render correctly.
- Docs: README Makie section, docs/src/03-makie.md ("Inline math vs. mixed text and
  math"), AGENTS.md routing note, CHANGELOG Added entry.
- Limitation kept/documented: the Makie seam still ignores the caller font_family
  arg, and document-path LayoutOptions aren't exposed (use layout_document directly).

## 2026-06-21T17:30 Session-wide default LayoutOptions

- Added `default_layout_options()` / `set_default_layout_options!` (compose.jl),
  mirroring the `default_font_family` Ref pattern. Keyword setter merges over the
  current default via `_merge_options` (strict: unknown keys throw); positional
  setter replaces wholesale (`LayoutOptions()` resets).
- `layout_document` refactored into two methods: core takes `opts::LayoutOptions`;
  the kwarg convenience merges kwargs over `default_layout_options()`. So direct
  callers and the Makie path both honour the global; output unchanged until set.
- Makie extension (document path) now calls `layout_document(str, default_layout_
  options(); family)`. This is the only channel for width/alignment via Makie,
  since the `generate_tex_elements(::LaTeXString)` signature is fixed.
- Exported both names. 10 new tests (merge, per-call override, reset, typo error,
  Makie pickup). Suite 1223 pass, no snapshot change. Docs: README, 01/03/05 doc
  pages, AGENTS.md Makie note, CHANGELOG.

## 2026-06-21T20:25+00:00 eigen_demo Makie review

- Investigating `examples/eigen_demo.jl` showed the mixed text/math label goes
  through `MathTeXEngineExt`'s document path.
- Found likely root causes: the Makie adapter resolves every non-math glyph
  through the regular FreeType face, so `\textbf{...}` cannot render with a bold
  face; the demo's raw triple-quoted label also preserves indentation as leading
  spaces, which affects apparent left alignment.

## 2026-06-21T20:35+00:00 eigen_demo fixes verified

- Fixed `MathTeXEngineExt` to resolve glyphs through TeXLayout's per-slot fallback
  chains and preserve useful `represented_char` values for standard glyph names
  such as `space` and `Lambda`.
- Fixed the eigen demo annotation as one multiline `text!` call: no indented
  triple-quoted source, left-aligned display block, `V^{\,-1}` spacing, and a
  standard Julia `"\\\\"` separator because `raw"and\\"` produced only one trailing
  backslash and malformed the intended line break.
- Rendered `/tmp/eigen_demo.png`; the prose is left aligned, bold text is bold,
  and the `V^{-1}` superscript is visually separated.

## 2026-06-21T20:50+00:00 eigen_demo prose line break follow-up

- User review caught that the explanatory prose still had an awkward/misleading
  break around `and`, making later text look like it had leaked into math mode.
- Restored the original wording but made the break explicit as
  `... \textbf{eigenvectors}` + `"\\\\"` + `and $\Lambda$ ...`, so `and` and the
  following prose are text-mode on the next line while only `\Lambda` is math.
- Regenerated `/tmp/eigen_demo.png` and visually confirmed the prose line now
  breaks cleanly.

## 2026-06-21T21:14+00:00 future.md refresh

- Replaced stale `future.md` box-tree architecture note with a focused future
  work list for matrix vertical spacing helpers.
- Captured follow-up items: implement `\strut` and phantom-style invisible
  measured boxes, make matrix row spacing arguments like `\\[0.2em]` affect
  layout instead of being skipped, and revisit `_MATRIX_ROWGAP` only after
  comparing against TeX/KaTeX expectations.

## 2026-06-21T21:24+00:00 future.md text font slots

- Added future-work notes for dedicated `\textsf` and `\texttt` support.
- Current behavior maps both commands to the regular text slot; future work
  should add sans-serif and monospace slots/fallbacks, keep nested bold/italic
  behavior, update Makie extension font caches, and test fallback behavior.

## 2026-06-21T21:33+00:00 future.md whitespace conventions

- Added a parser-compatibility note to `future.md` to review leading, trailing,
  and repeated whitespace handling in math and document text modes against
  LaTeX conventions.

## 2026-06-21T21:34+00:00 AGENTS.md refresh

- Updated `AGENTS.md` for current session changes: added `future.md` to the file
  tree, clarified that document text uses configured bold/italic text slots
  while math-mode font switching remains Unicode-variant based, and updated the
  Makie extension runtime-cache description to cover all slot fallback font
  paths rather than only math/regular faces.
- Added future-work caveats for matrix vertical spacing helpers and whitespace
  convention review, pointing developers at `future.md`.

## 2026-06-21T21:37+00:00 main docs refresh

- Updated Documenter sources to match the current Makie extension behavior:
  inline-math vs document routing, font-slot fallback glyph lookup, cached
  FreeType faces, and session-wide document layout options.
- Clarified public command docs so math-mode font switching is documented as
  Unicode-variant based while document text styling uses the configured
  bold/italic/bolditalic text slots.
- Added public/developer limitations for future `\textsf`/`\texttt` slots,
  matrix vertical spacing helpers, and whitespace convention review.
- Verified the docs build with `julia --project=docs docs/make.jl`.

## 2026-06-22T16:56+00:00 HarfBuzz extension implementation and docs

- Implemented optional `HarfBuzzShaper` support through `ext/HarfBuzzExt.jl`,
  emitting `GlyphID` elements with exact font paths and final glyph IDs.
- Kept `MetricShaper` as the default and independently testable path; document
  layout and math `\text{}`/`\mbox{}` can opt into HarfBuzz with
  `shaper = HarfBuzzShaper()` after loading `HarfBuzz_jll`.
- Updated README, Documenter pages, `AGENTS.md`, `future.md`, and changelog
  coverage for `GlyphID`, optional HarfBuzz shaping, Makie conversion, and stress
  test behavior.

## 2026-06-23T22:23+00:00 Display style for alignment environments + split/gathered/starred forms

- **Problem**: `\frac` (and scripts, big ops) inside `align`/`gather`/etc. rendered
  at Text-style (script) size, not full display size. Root cause: `_layout_matrix!`
  forced `cell_style = Text` for *all* matrix-family environments (`matrix.jl:60`),
  but the amsmath display-alignment environments set each line in display style.
- **Fix (step 1+2 of the agreed plan)**:
  - Added `_DISPLAY_MATH_ENVS` (parser_tables.jl) = {align, aligned, split, gather,
    gathered, equation}. `_layout_matrix!` now uses Display/CrampedDisplay cells for
    these, Text for genuine arrays (matrix/array/cases) — so fractions keep full size.
  - Added `split` (≈ aligned) and `gathered` (≈ gather) as new envs in `_MATRIX_ENVS`
    + parser colspec/ordinary-atom branches. `split` also joins the `tight_pairs` set.
  - Starred forms (`align*`, `gather*`, …) now alias the unstarred via
    `_canonical_env_name` (strips trailing `*`) applied at all three env read sites
    (parser `\begin`, `parse_environment!`, document layer). Equation numbers aren't
    rendered, so the star has no visual effect.
  - document.jl `_DISPLAY_ENVS` now points at the shared `_DISPLAY_MATH_ENVS`.
- **Tests**: +2 snapshot cases (align_fraction, gathered_script) lock the display
  sizing; +2 layout testsets (display-env cell style; starred-alias payload equality).
  Full suite 1244 pass. Runic-formatted.
- **Deferred**: `multline` still a sentinel — does NOT fit the grid model (no `&`,
  per-row L/center/R alignment measured against target line width). Needs a separate
  width-aware path in compose.jl, scoped as future work.
