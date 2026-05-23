# TeXbook Layout Rules as implemented in KaTeX

These are the TeXbook "rules" referenced in KaTeX's source, collected here for
quick lookup during Formatic.jl development.  Page numbers refer to the TeXbook
(Knuth, 5th edition).  The OpenType equivalents are noted where they differ from
the original TeX metric names.

The **Status** field for each rule describes Formatic.jl's implementation
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

**Status:** Not implemented.  Inter-atom spacing uses the atom class as parsed;
`mbin` atoms are never reclassified.

---

## Rule 9 — Overline (pg. 443)

**Source:** `src/functions/overline.ts`

Build the body in the **cramped** style.  Place a rule above it with:

```
gap = 3 × defaultRuleThickness   (between body top and rule bottom)
rule height = defaultRuleThickness
```

OpenType equivalent: `defaultRuleThickness` ≈ `FractionRuleThickness` from the
MATH table.

**Status:** Not implemented (`\overline` unrecognised).

---

## Rule 10 — Underline (pg. 443)

**Source:** `src/functions/underline.ts`

Build the body in the **current** style (not cramped).  Place a rule below it with:

```
gap = 3 × defaultRuleThickness   (between rule top and body bottom)
rule height = defaultRuleThickness
```

**Status:** Not implemented (`\underline` unrecognised).

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

**Status — partial deviation.**
- Gap adjustment (step 4) implemented in commit `8d9ac39`. ✓
- Step 2 uses `radical_vertical_gap` / `radical_display_style_vertical_gap` from
  the OpenType MATH table instead of the KaTeX formula; these are purpose-built
  constants that subsume the `ruleThickness + phi/4` calculation. ✓
- **Bug:** body is rendered in the current style, not the cramped style (step 1).
  Should call `_layout_node!(body_node, ctx, cramp_style(style), …)`.

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

**Status — matches KaTeX for `\frac`.**
Rules 15b and 15d are implemented using the OpenType MATH table constants
`FractionNumeratorGapMin` / `FractionDenominatorGapMin` and their Display-style
variants, which encode the clearance directly.  Rule 15c (no-rule fraction, i.e.
`\atop`) and Rule 15e (`\genfrac` delimiters) are not implemented.

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

**Status — partial deviation.**  Formatic.jl applies the supDrop/subDrop clamp
only for `_is_large_op` bases in Display style.  KaTeX applies it to any
non-character box (fractions, grouped expressions, etc.).

### 18b — Subscript only

```
subShift = max(subShift, sub1, subm.height − 0.8 × xHeight)
```

`sub1` → `SubscriptShiftDown`.

**Status — deviation.**  Formatic.jl uses only `max(subShift, subscript_shift_down)`;
the third term `subm.height − 0.8 × xHeight` (which prevents the subscript top
from rising too far above the x-height) is missing.

### 18c — Superscript only

```
supShift = max(supShift, minSupShift, supm.depth + 0.25 × xHeight)
```

`minSupShift` (three cases):
- Display style: `sup1`
- Cramped style: `sup3` (`SuperscriptShiftUpCramped`)
- Otherwise: `sup2` (`SuperscriptShiftUp`)

**Status — two deviations.**
1. The `supm.depth + 0.25 × xHeight` clamp (preventing the superscript bottom
   from sinking too close to the baseline) is missing.
2. KaTeX uses three minSupShift cases; Formatic.jl uses two (cramped vs
   not-cramped), matching the two OpenType constants available.  The Display
   case (`sup1`) has no OpenType equivalent — the font designer is expected to
   encode the appropriate value in `SuperscriptShiftUp`.

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

**Status — not implemented.**  The `NKDecorated` branch in Formatic.jl applies
the 18a supDrop/subDrop clamp for large operators but does not enforce the
minimum gap between the superscript bottom and the subscript top, nor the psi
redistribution.

---

## Rule 19 — Binary atom spacing context (pg. 446)

**Source:** mentioned in `src/buildHTML.ts` preamble.

Defines the inter-atom spacing table for atom class pairs
(ord/op/bin/rel/open/close/punct/inner).  KaTeX uses this to insert thin,
medium, or thick spaces (or no space) between adjacent atoms.

**Status:** Inter-atom spacing implemented in `_interatom_space` in `layout.jl`.
Binary reclassification (Rules 5 & 6) not yet applied.
