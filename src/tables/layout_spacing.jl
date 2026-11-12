# TeX atom spacing tables used by layout.jl.

# Spacing amounts in em (18-mu convention: thin = 3 mu, medium = 4 mu, thick = 5 mu).
const _THIN = 3 / 18
const _MEDIUM = 4 / 18
const _THICK = 5 / 18

# Width of a null delimiter (`\left.`, the missing delimiters of `\frac`), in em
# of the formula's base size.  TeX's `\nulldelimiterspace` is a fixed 1.2 pt at
# 10 pt, unscaled in script styles, and KaTeX resets the null delimiter to the
# base size likewise.
const _NULL_DELIMITER_SPACE = 0.12

# TeX's `\delimiterfactor` (901, as a fraction of 1000) and `\delimitershortfall`
# (5 pt at 10 pt, in em of the formula's base size): a `\left…\right` delimiter
# need cover only max(0.901 × 2δ, 2δ − 0.5 em) of content extending δ from the
# axis (rule 19).  LaTeX's defaults; KaTeX uses the same values.
const _DELIMITER_FACTOR = 0.901
const _DELIMITER_SHORTFALL = 0.5

# Automatic inter-atom spacing for Display/Text style: (prev, next) → em.
# Derived from KaTeX spacingData.ts; pairs with no entry have zero spacing.
const _SPACINGS = Dict{Tuple{Symbol, Symbol}, Float64}(
    (:ord, :op) => _THIN, (:ord, :bin) => _MEDIUM,
    (:ord, :rel) => _THICK, (:ord, :inner) => _THIN,
    (:op, :ord) => _THIN, (:op, :op) => _THIN,
    (:op, :rel) => _THICK, (:op, :inner) => _THIN,
    (:bin, :ord) => _MEDIUM, (:bin, :op) => _MEDIUM,
    (:bin, :open) => _MEDIUM, (:bin, :inner) => _MEDIUM,
    (:rel, :ord) => _THICK, (:rel, :op) => _THICK,
    (:rel, :open) => _THICK, (:rel, :inner) => _THICK,
    # :open has no outgoing entries
    (:close, :op) => _THIN, (:close, :bin) => _MEDIUM,
    (:close, :rel) => _THICK, (:close, :inner) => _THIN,
    (:punct, :ord) => _THIN, (:punct, :op) => _THIN,
    (:punct, :rel) => _THICK, (:punct, :open) => _THIN,
    (:punct, :close) => _THIN, (:punct, :punct) => _THIN,
    (:punct, :inner) => _THIN,
    (:inner, :ord) => _THIN, (:inner, :op) => _THIN,
    (:inner, :bin) => _MEDIUM, (:inner, :rel) => _THICK,
    (:inner, :open) => _THIN, (:inner, :punct) => _THIN,
    (:inner, :inner) => _THIN,
)

# Tight spacing for Script/ScriptScript: only thin spaces survive (KaTeX tightSpacings).
const _TIGHT_SPACINGS = Dict{Tuple{Symbol, Symbol}, Float64}(
    (:ord, :op) => _THIN,
    (:op, :ord) => _THIN, (:op, :op) => _THIN,
    (:close, :op) => _THIN,
    (:inner, :op) => _THIN,
)

# Atom classes that left-cancel a following mbin atom (Rule 5).
# A mbin at the start of a list or immediately after one of these is demoted to mord.
const _BIN_LEFT_CANCEL = (:bin, :open, :rel, :op, :punct)

# Atom classes that right-cancel a preceding mbin atom (Rule 6).
# A mbin immediately before one of these is demoted to mord.
const _BIN_RIGHT_CANCEL = (:rel, :close, :punct)
