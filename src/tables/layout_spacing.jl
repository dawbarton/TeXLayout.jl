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

# Array geometry of LaTeX + amsmath at 10 pt (\baselineskip 12 pt), in em.
# `array` puts `\arraycolsep` (5 pt) on both sides of every column; amsmath's
# matrices cancel the outer two, and `cases` is `@{}l@{\quad}l@{}`.  Every row
# carries `\@arstrut`, `\arraystretch` × 0.7 `\baselineskip` high and
# `\arraystretch` × 0.3 `\baselineskip` deep, and rows are stacked with no
# further gap.  A `|` rule takes no width; consecutive rules (`||`) are
# `\doublerulesep` (2 pt) apart.
const _ARRAYCOLSEP = 0.5
const _ARRAY_STRUT_HEIGHT = 0.84
const _ARRAY_STRUT_DEPTH = 0.36
const _DOUBLERULESEP = 0.2

# amsmath's `smallmatrix` is `\null\,\vcenter{…}\,` with `\scriptstyle` entries
# separated by `\thickspace` (0.2777 em, in text mode there) and rows on a 6 pt
# `\baselineskip` with 1.5 pt `\lineskip` and `\lineskiplimit`.
const _SMALLMATRIX_GAP = 0.2777
const _SMALLMATRIX_BASELINESKIP = 0.6
const _SMALLMATRIX_LINESKIP = 0.15

# Column spacing and row model of the array-like environments, in em of the
# environment's size: `outer` before the first and after the last column,
# `gap` between columns, and `rows` either `:strut` (TeX array rows with struts
# `stretch` times the default) or `:baselineskip` (smallmatrix).  Environments
# not listed (the display alignments) keep their own spacing in matrix.jl.
const _MatrixSpacing = @NamedTuple{outer::Float64, gap::Float64, rows::Symbol, stretch::Float64}
const _ARRAY_ROWS = (rows = :strut, stretch = 1.0)
const _MATRIX_SPACING = Dict{String, _MatrixSpacing}(
    "array" => (; outer = _ARRAYCOLSEP, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "matrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "pmatrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "bmatrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "Bmatrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "vmatrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "Vmatrix" => (; outer = 0.0, gap = 2 * _ARRAYCOLSEP, _ARRAY_ROWS...),
    "cases" => (outer = 0.0, gap = 1.0, rows = :strut, stretch = 1.2),
    "smallmatrix" => (outer = _THIN, gap = _SMALLMATRIX_GAP, rows = :baselineskip, stretch = 1.0),
)

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
