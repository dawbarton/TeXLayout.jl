# TeXbook Layout Rules as implemented in KaTeX

These are the TeXbook "rules" referenced in KaTeX's source, collected here for
quick lookup during TeXLayout.jl development.  Page numbers refer to the TeXbook
(Knuth, 5th edition).  The OpenType equivalents are noted where they differ from
the original TeX metric names.

The **Status** field for each rule describes TeXLayout.jl's implementation
relative to what KaTeX does.  "Matches KaTeX" means the algorithm agrees
modulo the OpenType/TeX metric naming differences; deviations are noted
explicitly.

---

## Rule 3 — Style changes (pg. 442)

**Source:** `src/functions/styling.ts`

When a style command (`\displaystyle`, `\textstyle`, `\scriptstyle`,
`\scriptscriptstyle`) is encountered, switch to the specified style for the
remainder of the group.  The font size multiplier changes accordingly.

**Status:** Matches KaTeX — `TexStyle` propagated through `_layout_node!`.

---

## Rules 5 & 6 — Binary atom reclassification (pg. 442–446)

**Source:** `src/buildHTML.ts` (preamble, before the rule-number comments)

A `mbin` atom is demoted to `mord` if:
- it appears at the start of a list, or immediately after `mbin`, `mopen`,
  `mrel`, `mop`, or `mpunct` (Rule 5 / left-canceller), or
- it appears immediately before `mrel`, `mclose`, or `mpunct` (Rule 6 /
  right-canceller).

**Status — matches KaTeX.**
- Two-pass reclassification in `_layout_children!`: left-to-right (Rule 5) then
  right-to-left (Rule 6). ✓
- Neutral atoms (`:neutral` — spaces, `NodeKind.Space`) are transparent to both passes. ✓
- `_BIN_LEFT_CANCEL = (:bin, :open, :rel, :op, :punct)` and
  `_BIN_RIGHT_CANCEL = (:rel, :close, :punct)` defined as module-level constants. ✓

---

## Rule 9 — Overline (pg. 443)

**Source:** `src/functions/overline.ts`

Build the body in the **cramped** style.  Place a rule above it with:

```
gap = 3 × defaultRuleThickness   (between body top and rule bottom)
rule height = defaultRuleThickness
```

OpenType equivalent: `defaultRuleThickness` ≈ `FractionRuleThickness` from the
MATH table.  The OpenType MATH table provides purpose-built constants
`OverbarVerticalGap` and `OverbarRuleThickness` that supersede the KaTeX
formula.

**Status — matches KaTeX.**
- Body built in `cramp_style(style)` as required. ✓
- Gap and rule thickness read from `OverbarVerticalGap` / `OverbarRuleThickness`
  rather than the KaTeX `3 × defaultRuleThickness` heuristic. ✓
- HRule emitted above the body with bottom edge at `body_top + gap`. ✓

---

## Rule 10 — Underline (pg. 443)

**Source:** `src/functions/underline.ts`

Build the body in the **current** style (not cramped).  Place a rule below it with:

```
gap = 3 × defaultRuleThickness   (between rule top and body bottom)
rule height = defaultRuleThickness
```

OpenType equivalents: `UnderbarVerticalGap` and `UnderbarRuleThickness`.

**Status — matches KaTeX.**
- Body built in the current (uncramped) style as required. ✓
- Gap and rule thickness read from `UnderbarVerticalGap` / `UnderbarRuleThickness`. ✓
- HRule emitted below the body with top edge at `body_bottom − gap`. ✓

---

## Rule 12 — Accents (pg. 443)

**Source:** `src/functions/accent.ts`

1. Build the base in the **cramped** style.
2. Compute the clearance:
   ```
   clearance = min(base.height, xHeight)
   ```
   where `xHeight` is the OpenType constant `AccentBaseHeight`.  For tall bases
   the accent floats above `xHeight`; for short ones it sits at the formula baseline.
3. Place the accent glyph at vertical position `base.top − clearance` (i.e. the
   accent baseline is at `max(0, base.height − xHeight)` above the formula
   baseline).
4. Align horizontally using `MathTopAccentAttachment` records from the MATH table:
   - If both the base glyph and the accent glyph have attachment records,
     `accent_x = base_attach_x − accent_attach_x`.
   - Otherwise, centre the accent over the base: `accent_x = (base_w − accent_w) / 2`.
5. The accent does not contribute to the overall advance width; the box width
   equals the base width.

OpenType equivalent: `xHeight` → `AccentBaseHeight`; attachment records in
`MathTopAccentAttachment` subtable of the MATH table.

**Status — matches KaTeX.**
- Rule 12 steps 1–5 fully implemented for 11 non-stretchy accent commands:
  `\hat`, `\acute`, `\grave`, `\ddot`, `\tilde`, `\bar`, `\breve`, `\check`,
  `\dot`, `\mathring`, `\vec`. ✓
- `MathTopAccentAttachment` alignment used when both glyphs have records;
  falls back to centering for complex multi-glyph bases. ✓
- Wide/stretchy accents (`\widehat`, `\widetilde`) implemented: share codepoints
  with their fixed-size counterparts; layout dispatches to `_layout_wide_accent!`
  which selects the smallest pre-built variant from `horiz_constructions` wide
  enough to cover the base, or assembles one from extensible parts. ✓
- **Codepoint note:** KaTeX's `symbols.ts` maps `\acute`/`\grave`/`\bar` to
  Modifier Letter codepoints (U+02CA/U+02CB/U+02C9) absent in most OpenType
  math fonts.  TeXLayout.jl uses Latin-1/ASCII equivalents (U+00B4/U+0060/U+00AF)
  which are present in NewCMMath and render to the same glyphs.

---

## Rule 11 — Square root (pg. 443)

**Source:** `src/functions/sqrt.ts`

1. Build the body in the **cramped** style.
2. Compute the initial clearance:
   - Display style: `phi = xHeight`,  `lineClearance = ruleThickness + xHeight / 4`
   - Otherwise:     `phi = ruleThickness`, `lineClearance = ruleThickness + ruleThickness / 4`
3. Select the radical delimiter with minimum height
   `= body.height + body.depth + lineClearance + ruleThickness`.
4. **Gap adjustment** — if `delimDepth > body.height + body.depth + lineClearance`:
   ```
   lineClearance = (lineClearance + delimDepth − body.height − body.depth) / 2
   ```
   where `delimDepth` is the depth of the radical glyph below the rule arm.
   This distributes the excess space equally above and below the body rather
   than leaving it all below, preventing an oversized hook for small radicands.
5. Position the radical so its rule arm aligns with `body.top + lineClearance`.

**Status — matches KaTeX.**
- Gap adjustment (step 4) implemented. ✓
- Step 2 uses `radical_vertical_gap` / `radical_display_style_vertical_gap` from
  the OpenType MATH table instead of the KaTeX formula; these are purpose-built
  constants that subsume the `ruleThickness + phi/4` calculation. ✓
- Body is built in `cramp_style(style)` as required. ✓

---

## Rule 15 — Fractions (pg. 444–445)

**Source:** `src/functions/genfrac.ts`

### 15b — Initial numerator/denominator shifts

| Style | With rule | Without rule |
|-------|-----------|--------------|
| Display | `num1`, `denom1`, clearance=3×rule | `num1`, `denom1`, clearance=7×rule |
| Non-display | `num2`, `denom2`, clearance=1×rule | `num3`, `denom2`, clearance=3×rule |

OpenType equivalents: `num1`/`num2` → `FractionNumeratorDisplayStyleShiftUp` /
`FractionNumeratorShiftUp`; `denom1`/`denom2` → `FractionDenominatorDisplayStyleShiftDown` /
`FractionDenominatorShiftDown`.

### 15c — Fraction without rule: minimum gap clamp

```
candidateClearance = (numShift − num.depth) − (denom.height − denomShift)
if candidateClearance < clearance:
    numShift   += 0.5 × (clearance − candidateClearance)
    denomShift += 0.5 × (clearance − candidateClearance)
```

### 15d — Fraction with rule: gap clamp relative to axis

```
# Numerator must not come too close to the rule top:
if (numShift − num.depth) − (axisHeight + 0.5 × ruleWidth) < clearance:
    numShift += clearance − gap_above_rule

# Denominator must not come too close to the rule bottom:
if (axisHeight − 0.5 × ruleWidth) − (denom.height − denomShift) < clearance:
    denomShift += clearance − gap_below_rule
```

Clearance is `3 × ruleWidth` in Display, `1 × ruleWidth` otherwise.

### 15e — Delimiter size for `\genfrac`

Minimum delimiter height:
- Display: `delim1`
- ScriptScript: `delim2` (at Script size)
- Otherwise: `delim2`

**Status — matches KaTeX for `\frac` and `\binom`.**
Rules 15b and 15d are implemented using the OpenType MATH table constants
`FractionNumeratorGapMin` / `FractionDenominatorGapMin` and their Display-style
variants, which encode the clearance directly.

Rule 15c is implemented for `NodeKind.Genfrac` (`\binom`/`\dbinom`/`\tbinom`) via
`_layout_genfrac!`.  KaTeX uses `num3` (no-rule non-display shift) which has no
OpenType equivalent; TeXLayout uses `FractionNumeratorShiftUp` (`num2`) instead.
The visual difference is negligible because the gap clamping still guarantees a
reasonable minimum gap via `FractionNumeratorGapMin`.

Rule 15e (`\genfrac` arbitrary delimiters) and `\atop` (no-rule, no delimiters)
are not implemented.

---

## Rules 18a–f — Superscripts and subscripts (pg. 445–446)

**Source:** `src/functions/supsub.ts`

### 18a — supDrop / subDrop (for non-character bases)

For bases that are **not** a single character box:

```
supShift = base.height − supDrop × script_size_multiplier
subShift = base.depth  + subDrop × script_size_multiplier
```

`supDrop` (σ₁₈) and `subDrop` (σ₁₉) are the OpenType constants
`SuperscriptBaselineDropMax` and `SubscriptBaselineDropMin`.

**Status — matches KaTeX.**  The `_is_char_box` helper mirrors KaTeX's
`isCharacterBox`: true for `NodeKind.Char`, for `NodeKind.Command` nodes that are not large
operators (Greek letters, etc.), and recursively for `NodeKind.FontSwitch` wrapping a
single character.  Large operators (`\int`, `\sum`, …), named operators (`\sin`,
…), fractions, and groups all return false, triggering the supDrop/subDrop clamp.

### 18b — Subscript only

```
subShift = max(subShift, sub1, subm.height − 0.8 × xHeight)
```

`sub1` → `SubscriptShiftDown`.

**Status — matches KaTeX.**  All three terms are applied using the OpenType
constant `SubscriptTopMax` in place of `0.8 × xHeight`. ✓

### 18c — Superscript only

```
supShift = max(supShift, minSupShift, supm.depth + 0.25 × xHeight)
```

`minSupShift` (three cases):
- Display style: `sup1`
- Cramped style: `sup3` (`SuperscriptShiftUpCramped`)
- Otherwise: `sup2` (`SuperscriptShiftUp`)

**Status — one deviation (structural).**
1. The `supm.depth + 0.25 × xHeight` clamp is implemented using the OpenType
   constant `SuperscriptBottomMin`. ✓
2. KaTeX uses three minSupShift cases; TeXLayout.jl uses two (cramped vs
   not-cramped), matching the two OpenType constants available.  The Display
   case (`sup1`) has no OpenType equivalent — the font designer is expected to
   encode the appropriate value in `SuperscriptShiftUp`.  This structural
   difference is intentional and not treated as a bug.

### 18d — Superscript only (covered by 18c in KaTeX)

Subsumed in the `max(…)` of Rule 18c above.

### 18e — Both super and subscript: gap clamp

```
supShift = max(supShift, minSupShift, supm.depth + 0.25 × xHeight)
subShift = max(subShift, sub2)   # sub2 ≈ SubscriptShiftDown

# Ensure minimum gap between sup bottom and sub top:
maxWidth = 4 × defaultRuleThickness
if (supShift − supm.depth) − (subm.height − subShift) < maxWidth:
    subShift = maxWidth − (supShift − supm.depth) + subm.height
    psi = 0.8 × xHeight − (supShift − supm.depth)
    if psi > 0:
        supShift += psi
        subShift -= psi
```

**Status — matches KaTeX.**  The gap clamp and psi redistribution are
implemented using OpenType constants `SubSuperscriptGapMin` (min gap) and
`SuperscriptBottomMaxWithSubscript` (psi threshold). ✓

---

## Rule 19 — Binary atom spacing context (pg. 446)

**Source:** mentioned in `src/buildHTML.ts` preamble.

Defines the inter-atom spacing table for atom class pairs
(ord/op/bin/rel/open/close/punct/inner).  KaTeX uses this to insert thin,
medium, or thick spaces (or no space) between adjacent atoms.

**Status:** Matches KaTeX.  Inter-atom spacing implemented in `_interatom_space`
in `layout.jl`.  Binary reclassification (Rules 5 & 6) applied via two-pass
`_layout_children!` — see the Rule 5 & 6 entry above.

---

## Feature implementation index

Features not covered by a numbered TeX/KaTeX rule.  NodeKind names and key
constants are noted for quick lookup.

| Feature | NodeKind | Key implementation detail |
|---------|----------|--------------------------|
| `\left`/`\right` auto-sized delimiters | `NodeKind.Delimited` | Smallest variant from `vert_constructions` that clears the inner content height; centred on math axis |
| `\middle` delimiter | `NodeKind.Middle` | Auto-sized to match the enclosing `\left`/`\right` pair; multiple per group supported |
| `\bigl`/`\bigr`/`\big` families | `NodeKind.BigDelim` | 4 fixed tiers (1.2/1.8/2.4/3.0 em × upm); size is scale-independent |
| Named operators (`\sin`, `\lim`, …) | `NodeKind.Operator` | Upright glyphs via `glyph_metrics_upright`; 27 operators; Display-style limits for operators in `_LIMITS_OPERATORS` |
| Large operators (`\sum`, `\int`, …) | `NodeKind.Command` | Display-size variant from `vert_constructions` using `display_operator_min_height`; codepoints in `_DISPLAY_OP_CODEPOINTS` |
| Limits placement | `NodeKind.Decorated` | Sub/sup centred below/above in Display style; uses `UpperLimitGapMin`, `LowerLimitGapMin`, `UpperLimitBaselineRiseMin`, `LowerLimitBaselineDropMin` |
| `\limits`/`\nolimits` override | `NodeKind.LimitsOverride` | Wraps the preceding base; checked before script dispatch |
| Horizontal extensibles (`\widehat`, `\widetilde`) | `NodeKind.Accent` | Smallest pre-built variant from `horiz_constructions` that covers the base; extensible assembly if no variant fits |
| Horizontal braces (`\overbrace`, `\underbrace`, …) | `NodeKind.HorizBrace` | Widest-fitting variant or assembly from `horiz_constructions`; limits-style note placement for sub/superscripts; 6 commands |
| Extensible arrows (`\xrightarrow`, …) | `NodeKind.XArrow` | 18 commands; arrow stretched to cover labels; labels at `_XARROW_KERN` (0.111 em) clearance |
| Font switching (`\mathbf`, `\mathrm`, …) | `NodeKind.FontSwitch` | Maps Latin/Greek/symbols to Unicode math-variant codepoints; propagates through sub/superscripts via `ctx.font_variant` |
| Style switches (`\displaystyle`, …) | `NodeKind.StyleOverride` | Consumes rest of current group; resets both style and scale absolutely (see AGENTS.md encoding note) |
| Font sizing (`\large`, `\tiny`, …) | `NodeKind.Sizing` | Multiplier stored as decimal string in `value`; multiplies current scale; 10 levels from 0.5× to 2.488× |
| `\dfrac`, `\tfrac` | `NodeKind.StyleOverride` wrapping `NodeKind.Frac` | Forces Display or Text style with absolute scale reset |
| `\binom`, `\dbinom`, `\tbinom` | `NodeKind.Genfrac` | Rule 15c gap clamping; auto-sized `()` delimiters via `_layout_delim!` |
| Array/matrix environments | `NodeKind.Matrix` | 8 named environments + `\begin{array}{colspec}`; per-column l/c/r alignment; single and double `||` vertical rules; two-pass grid layout |
| `\text{}`, `\mbox{}` | `NodeKind.Text` | Switches to `_with_text_mode`; upright glyphs from `regular` font slot; spaces preserved; inter-atom spacing suppressed |
| Text styles (`\textbf`, `\textit`, `\textsc`, …) | `NodeKind.Text` inside math; `TextAttrs` in documents | Shared command semantics in `text_styles.jl`; `\textsc` becomes a semantic feature and HarfBuzz applies OpenType `smcp` |
| Escaped literal characters (`\#`, `\$`, `\%`, …) | `NodeKind.Char` in math; text buffer characters in documents | Shared special-character table plus mode-specific math/text aliases in `parser_tables.jl`; escaped dollars are excluded from Makie's math-shift count |
| `default_font_family()` / `set_default_font_family!()` | — | Session-wide default; lazy artifact download; Makie extension picks up changes automatically |
| Explicit spacing (`\,` `\;` `\quad` `\kern` …) | `NodeKind.Space` | Width in `node.width` (em); negative spaces supported; 1 mu = 1/18 em |
