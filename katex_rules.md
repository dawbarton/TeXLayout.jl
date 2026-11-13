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
- Neutral atoms are also transparent when inter-atom spacing is emitted: the
  previous atom class survives an explicit space or kern, so `a\,+b` gets a
  thin space, a medium space, `+`, and a medium space.  This matches TeX
  (`mlist_to_hlist` skips glue and kern nodes without updating `r_type`) and
  KaTeX (`traverseNonSpaceNodes`).  Until 2026-10 explicit spaces reset the
  spacing context. ✓
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
- Scripts on an accented single character attach to the character (TeXbook
  rule 12's final step; KaTeX `supsub.ts` delegates to `accent.ts`), so
  `\hat{y}_{t+1}` and `\tilde{A}^2` place their scripts exactly as `y_{t+1}` and
  `A^2` do.  `_is_char_box` treats an accent over a character box as a
  character box.  Before 2026-11 the accent box was used as a compound base,
  which lowered subscripts by the character's depth plus
  `SubscriptBaselineDropMin` and raised superscripts with the accent. ✓
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
- **Degree (`\sqrt[n]{…}`)** follows LuaTeX's `\Uroot`, not KaTeX's or LaTeX's
  `\root` (which raise the degree by 0.6 × (height − depth) of the radical box
  and ignore the MATH table).  The degree is set in ScriptScript style; its
  baseline sits `RadicalDegreeBottomRaisePercent` of the radical sign's height
  above the sign's bottom; `RadicalKernBeforeDegree` and
  `RadicalKernAfterDegree` separate it from the sign, with the negative
  after-kern clamped so that the degree and kerns never have negative width.
  Checked against LuaLaTeX + unicode-math with NewCMMath: the degree baseline
  agrees to 0.001 pt at 10 pt in Text and Display style, and with the `ssty`
  degree glyph (see 18) `\sqrt[3]{x}` is 14.675 pt wide in both.

### Radical degree (`\sqrt[n]{…}`)

The degree is set in ScriptScript style after `RadicalKernBeforeDegree`, and
the sign follows after `RadicalKernAfterDegree`.  Its vertical position uses
`RadicalDegreeBottomRaisePercent`, which the OpenType MATH spec describes as the
"height of the bottom of the radical degree, if such is present, in proportion
to the height (ascender + descender) of the radical sign".  The spec does not
say what that height is measured from; the engines differ:

| Implementation | Degree baseline |
|----------------|-----------------|
| LuaTeX `make_radical` (`mlist.c`, `\Uroot`) | sign bottom + p × (sign height + depth) |
| XeTeX with unicode-math (`\r@@t`, fontdimen 65) | p × (ht − dp) of the whole radical box |
| KaTeX `sqrt.ts`, plain/LaTeX `\root` | 0.6 × (ht − dp) of the radical box |

**Status — follows LuaTeX.**  The degree's baseline is placed at
`sign_bottom + RadicalDegreeBottomRaisePercent × sign_height`, with the sign
measured from its own glyph boxes, so variants and assemblies are treated alike.
This is the direct reading of the spec's "(ascender + descender)" (unicode-math's
`ht − dp` is not the sign's height), and an overlay against LuaLaTeX with the
same font files matches on all bundled fonts.  XeTeX sets the degree lower by
0.2 × (sign depth) for the 60% default.  Until 2026-10 the raise was measured
from the formula baseline, which left the degree above deep radical signs.

Not matched: LuaTeX clamps `RadicalKernAfterDegree` so that the sign never
starts left of the degree's origin (`-ar > wr + br`); TeXLayout does not.

---

## Rule 15 — Fractions (pg. 444–445)

**Source:** `src/functions/genfrac.ts`

### 15b — Initial numerator/denominator shifts

| Style | With rule | Without rule |
|-------|-----------|--------------|
| Display | `num1`, `denom1`, clearance=3×rule | `num1`, `denom1`, clearance=7×rule |
| Non-display | `num2`, `denom2`, clearance=1×rule | `num3`, `denom2`, clearance=3×rule |

OpenType equivalents with a rule: `num1`/`num2` → `FractionNumeratorDisplayStyleShiftUp` /
`FractionNumeratorShiftUp`; `denom1`/`denom2` → `FractionDenominatorDisplayStyleShiftDown` /
`FractionDenominatorShiftDown`.

Without a rule, the MATH table has a separate family, the Stack* constants:
`num1` → `StackTopDisplayStyleShiftUp`, `num3` → `StackTopShiftUp`,
`denom1` → `StackBottomDisplayStyleShiftDown`, `denom2` → `StackBottomShiftDown`,
7θ → `StackDisplayStyleGapMin`, 3θ → `StackGapMin`.  Sources: the spec suggests
3× and 7× the default rule thickness for the two gaps and the same values as the
display-style Fraction* shifts for the display-style Stack* shifts; LuaTeX's
`make_fraction` (`mlist.c`) uses exactly these for rule-less fractions, and fills
them from `num3`/`num1`/`denom2`/`denom1` for TFM fonts.  XeTeX
(`XeTeXOTMath.cpp`, `TeX_sym_to_OT_map`) maps only `num3` and the gaps to Stack*,
and keeps the Fraction* shifts for `num1`, `denom1`, and `denom2`.  The two
engines agree for fonts whose Stack* and Fraction* shifts are equal (New CM,
Pagella, Schola, Termes, Bonum, Fira Math), and differ for STIX Two and Luciole.

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
`_layout_genfrac!` with the Stack* constants and TeX's single mutual clearance,
as in LuaTeX.  (Until 2026-10 it used the Fraction* constants with separate
clearances against the math axis, i.e. Rule 15d with zero rule thickness, on the
mistaken premise that `num3` had no OpenType equivalent.)

Rule 15e is implemented for `\binom`: the delimiters have the fixed minimum
size `delim1` in Display style and `delim2` otherwise, whatever the content
(`_GENFRAC_DELIM_EM`).  The MATH table has no equivalent, so TeXLayout uses
Computer Modern's values, 2.39 em and 1.01 em (cmsy10 `\fontdimen20`/`21`), as
KaTeX does.  LuaTeX's luaotfload defaults to 2.40 and 1.01, which in New CM
selects the next parenthesis variant (2.99 em rather than 2.39 em); XeTeX maps
`delim1` to `DelimitedSubFormulaMinHeight` and `delim2` to
`min(1.5 em, delim1)`.  Until 2026-10 the delimiters were sized to the content.

TeX, amsmath, and KaTeX treat `\frac` and `\binom` as ordinary atoms (amsmath
wraps them in a brace group; KaTeX builds an `mord`), but TeXLayout's
`_atom_class` returns `:inner` for `NodeKind.Frac` and `NodeKind.Genfrac`, which
adds thin spaces around them.  Not yet changed.

Rule 15e (`\genfrac` arbitrary delimiters) and `\atop` (no-rule, no delimiters)
are not implemented.

Null delimiters are implemented: `\frac` is flanked by spaces of
`_NULL_DELIMITER_SPACE` (0.12 em, TeX's `\nulldelimiterspace` of 1.2 pt), and an
empty delimiter (`\left.`, the right side of `cases`) gives the same space.  As
in TeX and in KaTeX's `makeNullDelimiter` (which resets to the base size), the
width is fixed in em of the formula's base size and does not shrink in script
styles.  Checked against XeLaTeX: `\scriptstyle\frac{a}{a}` is exactly 2.4 pt
wider than its numerator at 10 pt.

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
single character.  A group holding exactly one such node (`{x}`) also returns
true, because TeX replaces a one-atom group by the atom (tex.web §1186).  Large
operators (`\int`, `\sum`, …), named operators (`\sin`, …), fractions, and
longer groups return false, triggering the supDrop/subDrop clamp.

### Italic correction after math characters

**Source:** tex.web §752–§756 (`make_ord`, `make_scripts`), §749 (`make_op`);
xetex.web keeps both rules for OpenType math fonts.

TeX appends a kern of the character's italic correction after every math
character that has no subscript.  With a subscript, the kern is omitted and the
correction δ is passed to `make_scripts`: the subscript sits at the uncorrected
advance and the superscript δ to its right.  The script box's width is
`max(sub, δ + sup)` plus the space after the script.

**Status — matches LuaTeX and XeTeX.**  `_layout_char!` and the ordinary-symbol
path of `_layout_command!` return the advance plus the MATH-table italic
correction, for `FontSlot.Math` glyphs in math mode only; upright text,
`\text{…}`, and operator names get none.  `_subscript_italic_correction_em`
takes the correction back for a subscript on a character base (as decided by
`_is_char_box`) or a large operator.  Large operators keep XeTeX's OpenType
`make_op` rule: the operator's width excludes δ, the subscript sits at
advance − δ, and the superscript at the advance.  Measured with LuaLaTeX and
XeLaTeX (New CM Math, 10 pt), `$f$`, `$fg$`, `$VW$`, `$\sqrt{f}$`,
`$\overline{fy}$`, and `$b \pmod{n}$` now have exactly TeX's widths.  Both
engines keep the kern inside fraction parts, radicands, accents, overlines,
and scripts: `\overline{f}` and `\overline{f\kern0pt}` measure the same, and
likewise for the other constructs.  Classic TeX's `clean_box` drops the kern
from a box holding one character and its kern.  XeTeX's OpenType glyphs are
not character nodes, so that simplification never applies; LuaTeX's
`clean_box` (mlist.c) still contains it, but LuaLaTeX measures the same as
XeLaTeX.  Why it does not fire there was not traced.

Upright, sans-serif, and monospace math-alphabet letters (`\mathrm`,
`\mathsf`, `\mathtt`) also take the MATH table's correction where the font
gives one (New CM Math: up to 0.079 em for upright, 0.04 em for monospace), as
LuaTeX does for unicode-math's `\symup` and `\symtt`.  unicode-math's default
`\mathrm` and `\mathtt` use the text fonts instead, which carry no correction.

KaTeX differs: it adds the italic correction as a right margin only to the
characters it marks as needing it and shifts subscripts left by it
(`supsub.ts`).  TeXLayout follows TeX here.

**Not implemented:** OpenType math kerning (`MathKernInfo`) between a base and
its scripts, and the `ssty` script-size glyph variants.  TeX's script glyphs
are wider (New CM Math `i.st` has an advance of 404 units against 345 for
`i`), so TeXLayout's scripts are narrower than LuaTeX's.

**Deviation — drops are taken at the base size.**  TeX reads σ₁₈/σ₁₉ from the
script font, and KaTeX and XeTeX scale the drops by the script size multiplier
as above.  LuaTeX, the OpenType-native engine, applies
`SuperscriptBaselineDropMax` and `SubscriptBaselineDropMin` unscaled, and
TeXLayout follows it.  Measured with NewCMMath at 10 pt: a subscript on a
20 pt-deep rule ends 22.0 pt down in LuaLaTeX and in TeXLayout, 21.4 pt in
XeLaTeX; `\displaystyle\int_0^1 f` agrees with LuaLaTeX to 0.02 pt and differs
from XeLaTeX by 0.6–0.75 pt.

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

### Rules 13 and 17 — Italic correction of the base

TeX appends a character's italic correction δ as a kern unless a subscript
follows (rule 17), then sets the superscript δ to the right of the subscript
(rule 18f).  KaTeX does the same with `margin-right` on italic symbols and
`marginLeft = −italic` on the subscript (`supsub.ts`).

**Status — matches KaTeX/TeX.**  `_push_math_char!` emits the kern (as a
`Space` box) after every math-font character with a `MathItalicsCorrection`
entry, so `f(x)` clears f's hook and a lone `f` measures its kern.  The script
helpers subtract δ again for the subscript, which puts the subscript of `V_i`
at V's advance and the superscript of `f^2` at advance + δ.  Large operators
(rule 13) emit no kern because an OpenType operator's advance already spans its
ink; subtracting δ tucks the subscript of `\int_0` under the stroke.  Compound
bases (`{fa}_i`) get no correction from their first glyph.  Before 2026-11 no
kern was emitted and δ was subtracted for every base, which pushed letter
subscripts δ to the left of the advance.

**`clean_box` is deliberately not applied.**  TeX82 (tex.web §720–721) drops
the kern when a fraction part, script, radicand, or accent nucleus is a single
character, but XeTeX and LuaTeX with OpenType math fonts keep it.  Measured with
the real TeX Gyre Bonum Math file at 10 pt: `\hat{f}(` sets the parenthesis
exactly where `f(` does, `\overline{f}` is as wide as `f`, and `\frac{f}{f}`,
`x^{f}`, and `x_V` include the script's correction.  A version that dropped it
(2026-11-12, reverted the same day) made Bonum's f collide with a following
parenthesis and subscripts collide with an integrand.

One TeX refinement does apply:

- **Text alphabets** (tex.web §752): `\mathrm`, `\mathit`, `\mathbf`,
  `\mathsf`, `\mathtt` and `\mathsfit` are text fonts in LaTeX, which add no
  correction between consecutive letters, so `\mathit{diff}` is not
  letter-spaced.  Symbol alphabets (`\mathnormal`, `\boldsymbol`, `\mathcal`,
  …) keep the per-letter kern, as cmmi does.

The kern makes an atom after a subscripted large operator sit closer than
before 2026-11 (`\int_D f`).  This is TeX's arithmetic (the operator width
loses δ under a subscript): measured with the real font files in LuaLaTeX,
`\int_D f` is 0.64–0.71 pt wider at 10 pt in Termes, Bonum, Pagella and
NewCM, entirely because LuaTeX sets the subscript with the wider `ssty`
script glyphs.  With `ssty` applied (below) TeXLayout's `\int_D` widths
agree with LuaLaTeX's to 0.001 pt in all four fonts.

### Script alternates (`ssty`)

XeTeX and LuaTeX with unicode-math load the script-size math font with the
OpenType feature `ssty=0` and the scriptscript size with `ssty=1`, so every
glyph set in Script or ScriptScript style is replaced by the first or second
alternate of the font's GSUB `ssty` lookup (letters, digits, primes, and
some symbols; Luciole and STIX Two also cover delimiters, and Luciole large
operators).  TeXLayout parses the lookup into `MathTable.script_alternates`
and swaps characters, symbols, and large operators in `_script_glyph`; the
alternate carries its own italic correction and accent attachment.
Delimiters and accents are not yet substituted, and neither are text-mode
glyphs (`\text{…}` in a script), which come from the text font.
KaTeX has no equivalent (its fonts are already script-designed per size).
Verified against LuaLaTeX with the bundled font files at 10 pt: `\scriptstyle
x`, `x_x`, `x_V`, and `\iiint_V` in Bonum, `\scriptscriptstyle 3` and
`\sqrt[3]{x}` in NewCM, and `\int_D` in four fonts all agree to 0.001 pt.

### Primes

`'` is `^{\prime}`, as in TeX.  unicode-math additionally replaces a run of
two, three, or four primes with one multiple-prime character (U+2033,
U+2034, U+2057) when the font has it, and otherwise sets single primes with
`\g__um_primekern_muskip` = -1.5 mu between them; TeXLayout does the same in
the parser (`_MULTI_PRIME_COMMANDS`, `_kerned_primes`) and falls back to the
kerned primes in layout.  `f'`, `f''`, …, `f'''''` and `f''^2` agree with
LuaLaTeX to 0.001 pt in NewCM and Bonum.  KaTeX sets repeated `\prime`s.

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
| `\left`/`\right` auto-sized delimiters | `NodeKind.Delimited` | Smallest variant from `vert_constructions` reaching max(0.901 × 2δ, 2δ − 0.5 em), δ being the content's greatest extent from the math axis (TeXbook rule 19, `\delimiterfactor` 901, `\delimitershortfall` 5 pt); centred on math axis.  Matches LuaLaTeX's variant choice for NewCMMath in every case tried; XeLaTeX differs for `\left(\frac{\frac{a}{b}}{c}\right)` and `\left(\int_0^1 f\right)`, where its fraction and script placement differ (see 18a).  Matrix environments size their delimiters by the same rule against the array's strutted box, and `\left…\right` around a lone array-like environment hands its delimiters to the matrix layout so that they do too (as in LuaLaTeX, a parenthesis can then fall short of a tall entry's ink); a matrix among other content gets full ink coverage, because its struts are not visible to the measurement |
| `\middle` delimiter | `NodeKind.Middle` | Auto-sized to match the enclosing `\left`/`\right` pair; multiple per group supported |
| `\bigl`/`\bigr`/`\big` families | `NodeKind.BigDelim` | 4 fixed tiers (1.2/1.8/2.4/3.0 em × upm), as KaTeX; size is scale-independent.  amsmath instead sets `\left⟨d⟩\vcenter to k\big@size{}\right.` with k = 1, 1.5, 2, 2.5 and `\big@size` = 1.2 × (height + depth) of `\Mathstrutbox@`, so TeX's size follows the font's parenthesis and passes through Rule 19's `\delimiterfactor`.  KaTeX's tiers are kept by choice (2026-11), as simpler and font-independent: against amsmath's box in LuaLaTeX at 10 pt (an upper bound on its delimiter), TeXLayout's `\big` delimiters are 1.1 to 1.43 times as tall in Pagella, Termes, Bonum, Schola, and STIX Two, 1.1 times for Fira Math's three larger sizes, and 1.17 to 1.25 times for New Computer Modern's parentheses, and agree in Luciole and for New Computer Modern's brackets and braces |
| Named operators (`\sin`, `\lim`, …) | `NodeKind.Operator` | Upright glyphs via `glyph_metrics_upright`; 34 operators; Display-style limits for operators in `_LIMITS_OPERATORS`; two-word names (`\liminf`, `\injlim`, …) carry spelling children with amsopn's 3 mu thin space (`_SPACED_OPERATOR_NAMES`) |
| `\bmod`, `\pmod`, `\mod`, `\pod` | `NodeKind.Group` (expanded in the parser) | amsmath definitions: `\bmod` is 5 mu, upright "mod", 5 mu (net effect of its `\nonscript\mskip-\medmuskip` glue in every style); `\pod`/`\pmod`/`\mod` open with 18 mu in Display style and 8/8/12 mu otherwise via `NodeKind.MathChoice`.  amsmath decides by display *mode* (`\if@display`), TeXLayout and KaTeX by display *style* |
| `\mathchoice{D}{T}{S}{SS}` | `NodeKind.MathChoice` | Branch chosen by style and spliced into the surrounding list before inter-atom spacing, as in TeX's `mlist_to_hlist` |
| Large operators (`\sum`, `\int`, …) | `NodeKind.Command` | Display-size variant: the first in `vert_constructions` at least `display_operator_min_height` tall, else the largest (STIX Two's minimum exceeds all its variants); codepoints in `_DISPLAY_OP_CODEPOINTS` |
| Limits placement | `NodeKind.Decorated` | Sub/sup centred below/above in Display style; uses `UpperLimitGapMin`, `LowerLimitGapMin`, `UpperLimitBaselineRiseMin`, `LowerLimitBaselineDropMin` |
| `\limits`/`\nolimits`/`\displaylimits` override | `NodeKind.LimitsOverride` | Wraps the preceding base; checked before script dispatch.  `"displaylimits"` (also produced by `\operatorname*`) means limits in Display style only; the last modifier wins |
| Horizontal extensibles (`\widehat`, `\widetilde`) | `NodeKind.Accent` | Smallest pre-built variant from `horiz_constructions` that covers the base; extensible assembly if no variant fits |
| Horizontal braces (`\overbrace`, `\underbrace`, …) | `NodeKind.HorizBrace` | Widest-fitting variant or assembly from `horiz_constructions`; limits-style note placement for sub/superscripts; 6 commands |
| Extensible arrows (`\xrightarrow`, …) | `NodeKind.XArrow` | 18 commands; arrow stretched to cover labels and set on the baseline like a relation (the font puts the shaft on the axis; centring the ink would misplace harpoon shafts); assemblies widen their overlaps to match the width exactly; labels at `_XARROW_KERN` (0.111 em) clearance.  Where the MATH table cannot stretch the arrow (Fira Math, some STIX Two arrows), it is built from pieces as amsmath's `\arrowfill@` does (`_XARROW_FILL_PIECES`); `\xmapsto`, the hook arrows and stacked harpoons then keep their natural width.  amsmath's `\ext@arrow` (`\xrightarrow` is `\ext@arrow 0359`) instead pads each label by 5 mu and 9 mu in script style and sets the labels as `\limits` scripts of a `\mathop`.  KaTeX's padding is kept by choice (2026-11): in LuaLaTeX at 10 pt, `\xrightarrow[a]{b}` is 0.03 to 0.35 em wider here, depending on the font, with its lower label higher (depth 0.44 em against 0.62 em in New Computer Modern); with a long label (`\xrightarrow{abcdef}`) the widths agree within 0.06 em except in Luciole (0.35 em) |
| Font switching (`\mathbf`, `\mathrm`, …) | `NodeKind.FontSwitch` | Maps Latin/Greek/symbols to Unicode math-variant codepoints; propagates through sub/superscripts via `ctx.font_variant` |
| Style switches (`\displaystyle`, …) | `NodeKind.StyleOverride` | Consumes rest of current group; resets both style and scale absolutely (see AGENTS.md encoding note) |
| Font sizing (`\large`, `\tiny`, …) | `NodeKind.Sizing` | Multiplier stored as decimal string in `value`; multiplies current scale; 10 levels from 0.5× to 2.488× |
| `\dfrac`, `\tfrac` | `NodeKind.StyleOverride` wrapping `NodeKind.Frac` | Forces Display or Text style with absolute scale reset |
| `\binom`, `\dbinom`, `\tbinom` | `NodeKind.Genfrac` | Rule 15c with the Stack* constants and one mutual clearance; Rule 15e delimiters of fixed size `delim1`/`delim2` (2.39/1.01 em) via `_layout_delim!` |
| Array/matrix environments | `NodeKind.Matrix` | 8 named environments + `\begin{array}{colspec}`; per-column l/c/r alignment; single and double `||` vertical rules; two-pass grid layout.  Spacing follows LaTeX + amsmath (`_MATRIX_SPACING`): `array` has `\arraycolsep` (0.5 em) on both sides of every column, the matrix family drops the outer two, `cases` is `@{}l@{\quad}l@{}` (the `\quad` is part of the first column) with `\arraystretch` 1.2, and every row has an `\@arstrut` of 0.84/0.36 em × `\arraystretch` with no further row gap; a `|` takes no width and `||` adds `\doublerulesep` (0.2 em).  `\\[len]` deepens an array row to at least the strut depth plus len (`\@xargarraycr`) and adds to the gap when negative.  `smallmatrix` sets `\scriptstyle` entries 0.2777 em apart, inside thin spaces, on a 0.6 em `\baselineskip` with 0.15 em `\lineskip`; `\\[len]` adds space.  Widths and heights agree with LuaLaTeX to 0.001 pt in NewCM and Bonum, except that LuaTeX adds a `\left` delimiter variant's italic correction (XeTeX does not).  `_layout_matrix_box!` returns the strutted box for tests |
| Alignments (`aligned`, `gathered`, `align`, `gather`, `split`) and `equation` | `NodeKind.Matrix` | Display-style cells; right/left column pairs glued at the `&` (the right cell starts with `{}`), pairs `\minalignsep` (1 em) apart, no outer margin; every row carries `\strut@` (0.84/0.36 em) and rows are `\baselineskip` + `\jot` (1.5 em) apart, or `\lineskip` + `\jot` (0.4 em) clear when taller (`\openup\jot` also raises `\lineskiplimit` to 0.3 em); `\\[len]` adds space; Ord atoms (`\vcenter`).  The display forms are set as the inline ones.  `equation` is a plain display (`vcenter = false`, no strut), identical to `\[…\]`.  Widths, heights, and depths agree with LuaLaTeX to 0.001 pt (30 cases, NewCM and Bonum) |
| `\text{}`, `\mbox{}` | `NodeKind.Text` | Switches to `_with_text_mode`; upright glyphs from `regular` font slot; spaces preserved; inter-atom spacing suppressed.  An enclosing math alphabet (`\mathbf`, `\boldsymbol`, …) does not restyle the text, as in LaTeX; KaTeX deviates (its `makeOrd` keeps the math font in text mode) |
| Text styles (`\textbf`, `\textit`, `\textsc`, …) | `NodeKind.Text` inside math; `TextAttrs` in documents | Shared command semantics in `text_styles.jl`; `\textsc` becomes a semantic feature and HarfBuzz applies OpenType `smcp` |
| Escaped literal characters (`\#`, `\$`, `\%`, …) | `NodeKind.Char` in math; text buffer characters in documents | Shared special-character table plus mode-specific math/text aliases in `parser_tables.jl`; escaped dollars are excluded from Makie's math-shift count |
| `default_font_family()` / `set_default_font_family!()` | — | Session-wide default; lazy artifact download; Makie extension picks up changes automatically |
| Explicit spacing (`\,` `\;` `\quad` `\kern` …) | `NodeKind.Space` | Width in `node.width` (em); negative spaces supported; 1 mu = 1/18 em |
