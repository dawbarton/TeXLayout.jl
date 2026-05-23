# Layout engine: AST + style → positioned glyph elements.
#
# Converts a parsed AST into a flat list of (element, position, scale) triples
# that Makie (or any other renderer) can consume directly.  Positions are in em
# units relative to the formula baseline; x increases rightward, y upward.
# All constants are read from the font's OpenType MATH table; no hard-coded
# values are used.

"""Abstract base for all renderable elements."""
abstract type TeXElement end

"""
A single glyph to be rendered from the math font.

`glyph_name` is the PostScript glyph name; the renderer resolves it to a glyph
index via its font handle.  The metric fields are cached from the font in design
units so that the renderer need not re-query them.
"""
struct Glyph <: TeXElement
    glyph_name::String
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int
end

"""A horizontal rule (fraction bar, radical bar, overline, …)."""
struct HRule <: TeXElement
    width::Float64      # em units
    thickness::Float64  # em units
end

"""A vertical rule (rarely needed; included for completeness)."""
struct VRule <: TeXElement
    height::Float64
    thickness::Float64
end

"""An explicit horizontal space."""
struct Space <: TeXElement
    width::Float64   # em units
end

"""
A positioned element: element + 2-D offset from the formula baseline origin.

`x` increases to the right; `y` increases upward.  Both are in em units.
`scale` is the font-size multiplier relative to the base font size (1.0 for
Text/Display style, 0.7 for Script, 0.5 for ScriptScript by default).
"""
struct LayoutBox
    element::TeXElement
    x::Float64
    y::Float64
    scale::Float64
end

# ── Internal helpers ──────────────────────────────────────────────────────────

# Immutable context shared across all recursive layout calls.
# `mode` is either :math (default) or :text (inside \text{…}/\mbox{…}).
# Math-mode character remapping and automatic inter-atom spacing are suppressed
# in text mode.
# `font_variant` is :default or the variant name set by an enclosing NKFontSwitch
# node (e.g. :mathbf, :mathbb).  Propagates through all recursive calls so that
# \mathbf{x_i} produces bold x and bold subscript i.
struct _LayoutCtx
    family::FontFamily
    mc::MathConstants
    upm::Float64
    vert_constructions::Dict{String,GlyphConstruction}
    min_connector_overlap::Int
    mode::Symbol          # :math | :text
    font_variant::Symbol  # :default | :mathbf | :mathit | :mathrm | :mathbb | …
end

# Characters whose ASCII/Latin-1 codepoints differ from their correct math-mode
# glyph.  Applied only in :math mode; text mode uses the literal codepoint.
const _MATH_CHAR_REMAP = Dict{Char,Char}(
    '-' => '−',   # U+002D HYPHEN-MINUS  → U+2212 MINUS SIGN
    '*' => '∗',   # U+002A ASTERISK      → U+2217 ASTERISK OPERATOR
)

# ── Atom classification ───────────────────────────────────────────────────────

# Inter-atom spacing follows TeX's eight atom classes (Knuth, Chapter 17) and
# KaTeX's spacingData.ts.  Characters/commands not listed default to :ord.
# _MATH_CHAR_REMAP is applied before char lookup so '-' and '−' both yield :bin.
const _CHAR_ATOM_CLASS = Dict{Char,Symbol}(
    # Binary operators
    '+' => :bin,
    '-' => :bin,    # U+002D (also remapped to U+2212 for glyph lookup)
    '−' => :bin,    # U+2212 MINUS SIGN
    '*' => :bin,    # U+002A (remapped to U+2217)
    '∗' => :bin,    # U+2217 ASTERISK OPERATOR
    '×' => :bin,    '÷' => :bin,
    '·' => :bin,    '±' => :bin,
    '∓' => :bin,    '∧' => :bin,
    '∨' => :bin,    '∩' => :bin,
    '∪' => :bin,    '⊕' => :bin,
    '⊖' => :bin,    '⊗' => :bin,
    '⊘' => :bin,    '⊙' => :bin,
    '∘' => :bin,    '•' => :bin,
    '⋆' => :bin,    '†' => :bin,
    '‡' => :bin,
    # Relations
    '=' => :rel,    '<' => :rel,
    '>' => :rel,    ':' => :rel,
    '≤' => :rel,    '≥' => :rel,
    '≠' => :rel,    '≈' => :rel,
    '∼' => :rel,    '≃' => :rel,
    '≅' => :rel,    '∝' => :rel,
    '⊥' => :rel,    '∥' => :rel,
    '∣' => :rel,    '⊂' => :rel,
    '⊃' => :rel,    '⊆' => :rel,
    '⊇' => :rel,    '∈' => :rel,
    '∉' => :rel,    '∋' => :rel,
    '→' => :rel,    '←' => :rel,
    '↔' => :rel,    '⇒' => :rel,
    '⇐' => :rel,    '⇔' => :rel,
    '↦' => :rel,    '≡' => :rel,
    '≺' => :rel,    '≻' => :rel,
    '≪' => :rel,    '≫' => :rel,
    '⊢' => :rel,    '⊣' => :rel,
    '⊨' => :rel,    '↑' => :rel,
    '↓' => :rel,    '⇑' => :rel,
    '⇓' => :rel,
    # Open delimiters
    '(' => :open,   '[' => :open,
    # Close delimiters
    ')' => :close,  ']' => :close,
    '!' => :close,
    # Punctuation
    ',' => :punct,  ';' => :punct,
    # Inner (ellipses)
    '…' => :inner,  '⋯' => :inner,
    '⋱' => :inner,
)

# Atom class by command name (bare, without leading backslash).
const _CMD_ATOM_CLASS = Dict{String,Symbol}(
    # ── Binary operators ────────────────────────────────────────────────────
    "pm"                => :bin,  "mp"                => :bin,
    "times"             => :bin,  "div"               => :bin,
    "cdot"              => :bin,  "ast"               => :bin,
    "star"              => :bin,  "circ"              => :bin,
    "bullet"            => :bin,
    "cap"               => :bin,  "cup"               => :bin,
    "sqcap"             => :bin,  "sqcup"             => :bin,
    "wedge"             => :bin,  "land"              => :bin,
    "vee"               => :bin,  "lor"               => :bin,
    "setminus"          => :bin,  "smallsetminus"     => :bin,
    "oplus"             => :bin,  "ominus"            => :bin,
    "otimes"            => :bin,  "oslash"            => :bin,
    "odot"              => :bin,
    "boxplus"           => :bin,  "boxminus"          => :bin,
    "boxtimes"          => :bin,  "boxdot"            => :bin,
    "ltimes"            => :bin,  "rtimes"            => :bin,
    "wr"                => :bin,  "amalg"             => :bin,
    "dagger"            => :bin,  "ddagger"           => :bin,
    "dag"               => :bin,  "ddag"              => :bin,
    "triangleleft"      => :bin,  "triangleright"     => :bin,
    "barwedge"          => :bin,  "curlywedge"        => :bin,
    "curlyvee"          => :bin,  "intercal"          => :bin,
    "dotplus"           => :bin,  "leftthreetimes"    => :bin,
    "rightthreetimes"   => :bin,  "doublebarwedge"    => :bin,
    "divideontimes"     => :bin,

    # ── Relations ───────────────────────────────────────────────────────────
    "leq"               => :rel,  "le"                => :rel,
    "geq"               => :rel,  "ge"                => :rel,
    "neq"               => :rel,  "ne"                => :rel,
    "equiv"             => :rel,  "approx"            => :rel,
    "sim"               => :rel,  "simeq"             => :rel,
    "cong"              => :rel,  "propto"            => :rel,
    "perp"              => :rel,  "parallel"          => :rel,
    "mid"               => :rel,  "nmid"              => :rel,
    "subset"            => :rel,  "supset"            => :rel,
    "subseteq"          => :rel,  "supseteq"          => :rel,
    "sqsubseteq"        => :rel,  "sqsupseteq"        => :rel,
    "in"                => :rel,  "notin"             => :rel,
    "ni"                => :rel,  "owns"              => :rel,
    "prec"              => :rel,  "succ"              => :rel,
    "preceq"            => :rel,  "succeq"            => :rel,
    "ll"                => :rel,  "gg"                => :rel,
    "lll"               => :rel,  "ggg"               => :rel,
    "to"                => :rel,
    "leftarrow"         => :rel,  "rightarrow"        => :rel,
    "Leftarrow"         => :rel,  "Rightarrow"        => :rel,
    "leftrightarrow"    => :rel,  "Leftrightarrow"    => :rel,
    "longleftarrow"     => :rel,  "longrightarrow"    => :rel,
    "Longleftarrow"     => :rel,  "Longrightarrow"    => :rel,
    "longleftrightarrow" => :rel, "Longleftrightarrow" => :rel,
    "iff"               => :rel,  "implies"           => :rel,
    "mapsto"            => :rel,  "longmapsto"        => :rel,
    "hookleftarrow"     => :rel,  "hookrightarrow"    => :rel,
    "uparrow"           => :rel,  "downarrow"         => :rel,
    "Uparrow"           => :rel,  "Downarrow"         => :rel,
    "updownarrow"       => :rel,  "Updownarrow"       => :rel,
    "nearrow"           => :rel,  "searrow"           => :rel,
    "swarrow"           => :rel,  "nwarrow"           => :rel,
    "vdash"             => :rel,  "dashv"             => :rel,
    "models"            => :rel,
    "smile"             => :rel,  "frown"             => :rel,
    "asymp"             => :rel,  "bowtie"            => :rel,
    "Join"              => :rel,  "not"               => :rel,
    "xleftarrow"        => :rel,  "xrightarrow"       => :rel,
    "nleq"              => :rel,  "ngeq"              => :rel,
    "nless"             => :rel,  "ngtr"              => :rel,
    "nsim"              => :rel,  "nparallel"         => :rel,
    "nsubseteq"         => :rel,  "nsupseteq"         => :rel,
    "subsetneq"         => :rel,  "supsetneq"         => :rel,
    "varsubsetneq"      => :rel,  "varsupsetneq"      => :rel,
    "lneq"              => :rel,  "gneq"              => :rel,
    "lnsim"             => :rel,  "gnsim"             => :rel,
    "preccurlyeq"       => :rel,  "succcurlyeq"       => :rel,
    "curlyeqprec"       => :rel,  "curlyeqsucc"       => :rel,
    "sqsubset"          => :rel,  "sqsupset"          => :rel,
    "Supset"            => :rel,  "Subset"            => :rel,
    "trianglelefteq"    => :rel,  "trianglerighteq"   => :rel,
    "vartriangleleft"   => :rel,  "vartriangleright"  => :rel,
    "blacktriangleleft" => :rel,  "blacktriangleright" => :rel,
    "leqq"              => :rel,  "geqq"              => :rel,
    "leqslant"          => :rel,  "geqslant"          => :rel,
    "eqslantless"       => :rel,  "eqslantgtr"        => :rel,
    "lesssim"           => :rel,  "gtrsim"            => :rel,
    "lessapprox"        => :rel,  "gtrapprox"         => :rel,
    "approxeq"          => :rel,
    "lessdot"           => :rel,  "gtrdot"            => :rel,
    "lessgtr"           => :rel,  "gtrless"           => :rel,
    "lesseqgtr"         => :rel,  "gtreqless"         => :rel,
    "lesseqqgtr"        => :rel,  "gtreqqless"        => :rel,
    "doteq"             => :rel,  "doteqdot"          => :rel,
    "risingdotseq"      => :rel,  "fallingdotseq"     => :rel,
    "backsim"           => :rel,  "backsimeq"         => :rel,
    "eqcirc"            => :rel,  "circeq"            => :rel,
    "triangleq"         => :rel,
    "bumpeq"            => :rel,  "Bumpeq"            => :rel,
    "thicksim"          => :rel,  "thickapprox"       => :rel,
    "supseteqq"         => :rel,  "subseteqq"         => :rel,
    "shortparallel"     => :rel,  "between"           => :rel,
    "pitchfork"         => :rel,  "therefore"         => :rel,
    "because"           => :rel,  "shortmid"          => :rel,
    "backepsilon"       => :rel,  "varpropto"         => :rel,
    "nleqslant"         => :rel,  "ngeqslant"         => :rel,
    "nleqq"             => :rel,  "ngeqq"             => :rel,
    "lvertneqq"         => :rel,  "gvertneqq"         => :rel,
    "nprec"             => :rel,  "nsucc"             => :rel,
    "npreceq"           => :rel,  "nsucceq"           => :rel,

    # ── Large operators ─────────────────────────────────────────────────────
    "int"               => :op,   "iint"              => :op,
    "iiint"             => :op,   "iiiint"            => :op,
    "oint"              => :op,   "oiint"             => :op,
    "oiiint"            => :op,
    "sum"               => :op,   "prod"              => :op,
    "coprod"            => :op,
    "bigcap"            => :op,   "bigcup"            => :op,
    "bigsqcup"          => :op,   "bigsqcap"          => :op,
    "bigwedge"          => :op,   "bigvee"            => :op,
    "bigoplus"          => :op,   "bigotimes"         => :op,
    "bigodot"           => :op,   "biguplus"          => :op,
    "bigplus"           => :op,

    # ── Manual delimiter sizing ──────────────────────────────────────────────
    "bigl"              => :open,  "Bigl"             => :open,
    "biggl"             => :open,  "Biggl"            => :open,
    "bigr"              => :close, "Bigr"             => :close,
    "biggr"             => :close, "Biggr"            => :close,
    "bigm"              => :rel,   "Bigm"             => :rel,
    "biggm"             => :rel,   "Biggm"            => :rel,

    # ── Open delimiters ─────────────────────────────────────────────────────
    "{"                 => :open,
    "langle"            => :open,
    "lfloor"            => :open,
    "lceil"             => :open,
    "lvert"             => :open,
    "lVert"             => :open,
    "lgroup"            => :open,
    "lmoustache"        => :open,
    "llbracket"         => :open,

    # ── Close delimiters ────────────────────────────────────────────────────
    "}"                 => :close,
    "rangle"            => :close,
    "rfloor"            => :close,
    "rceil"             => :close,
    "rvert"             => :close,
    "rVert"             => :close,
    "rgroup"            => :close,
    "rmoustache"        => :close,
    "rrbracket"         => :close,

    # ── Punctuation ─────────────────────────────────────────────────────────
    "colon"             => :punct,
    "cdotp"             => :punct,
    "ldotp"             => :punct,

    # ── Inner (ellipses, \bmod, \pmod) ──────────────────────────────────────
    "ldots"             => :inner,
    "cdots"             => :inner,
    "ddots"             => :inner,
    "dots"              => :inner,
    "dotsb"             => :inner,
    "dotsc"             => :inner,
    "dotsi"             => :inner,
    "dotsm"             => :inner,
    "dotso"             => :inner,
    "bmod"              => :inner,
    "pmod"              => :inner,

    # ── Ordinary symbols ────────────────────────────────────────────────────
    # Greek lowercase
    "alpha"             => :ord,  "beta"              => :ord,
    "gamma"             => :ord,  "delta"             => :ord,
    "epsilon"           => :ord,  "varepsilon"        => :ord,
    "zeta"              => :ord,  "eta"               => :ord,
    "theta"             => :ord,  "vartheta"          => :ord,
    "iota"              => :ord,  "kappa"             => :ord,
    "lambda"            => :ord,  "mu"                => :ord,
    "nu"                => :ord,  "xi"                => :ord,
    "pi"                => :ord,  "varpi"             => :ord,
    "rho"               => :ord,  "varrho"            => :ord,
    "sigma"             => :ord,  "varsigma"          => :ord,
    "tau"               => :ord,  "upsilon"           => :ord,
    "phi"               => :ord,  "varphi"            => :ord,
    "chi"               => :ord,  "psi"               => :ord,
    "omega"             => :ord,
    # Greek uppercase
    "Gamma"             => :ord,  "Delta"             => :ord,
    "Theta"             => :ord,  "Lambda"            => :ord,
    "Xi"                => :ord,  "Pi"                => :ord,
    "Sigma"             => :ord,  "Upsilon"           => :ord,
    "Phi"               => :ord,  "Psi"               => :ord,
    "Omega"             => :ord,
    # Miscellaneous ordinary symbols
    "infty"             => :ord,  "partial"           => :ord,
    "nabla"             => :ord,  "forall"            => :ord,
    "exists"            => :ord,  "nexists"           => :ord,
    "emptyset"          => :ord,  "varnothing"        => :ord,
    "angle"             => :ord,  "measuredangle"     => :ord,
    "sphericalangle"    => :ord,
    "ell"               => :ord,
    "imath"             => :ord,  "jmath"             => :ord,
    "hbar"              => :ord,  "hslash"            => :ord,
    "Re"                => :ord,  "Im"                => :ord,
    "wp"                => :ord,
    "aleph"             => :ord,  "beth"              => :ord,
    "gimel"             => :ord,  "daleth"            => :ord,
    "prime"             => :ord,  "backprime"         => :ord,
    "complement"        => :ord,
    "surd"              => :ord,
    "top"               => :ord,  "bot"               => :ord,
    "flat"              => :ord,  "natural"           => :ord,
    "sharp"             => :ord,
    "diagup"            => :ord,  "diagdown"          => :ord,
    "eth"               => :ord,
    "Finv"              => :ord,  "Game"              => :ord,
    "Bbbk"              => :ord,
    "triangle"          => :ord,  "triangledown"      => :ord,
    "square"            => :ord,  "blacksquare"       => :ord,
    "lozenge"           => :ord,  "blacklozenge"      => :ord,
    "bigstar"           => :ord,
    "clubsuit"          => :ord,  "diamondsuit"       => :ord,
    "heartsuit"         => :ord,  "spadesuit"         => :ord,
    "checkmark"         => :ord,
    "vert"              => :ord,  "Vert"              => :ord,
    "backslash"         => :ord,
    "S"                 => :ord,  "P"                 => :ord,
    "copyright"         => :ord,  "circledR"          => :ord,
    "maltese"           => :ord,
    "yen"               => :ord,  "pounds"            => :ord,
    "mho"               => :ord,  "Angstrom"          => :ord,
    "digamma"           => :ord,  "varkappa"          => :ord,
    "circledS"          => :ord,  "degree"            => :ord,
    "textdollar"        => :ord,
    "vdots"             => :ord,  # vertical — ordinary, not inner like \cdots
    # Accents (base is an ordinary atom in terms of spacing)
    "hat"               => :ord,  "bar"               => :ord,
    "vec"               => :ord,  "dot"               => :ord,
    "ddot"              => :ord,  "tilde"             => :ord,
    "widehat"           => :ord,  "widetilde"         => :ord,
    "overline"          => :ord,  "underline"         => :ord,
    # Font-mode selectors: the result is an ordinary atom
    "mathbf"            => :ord,  "mathrm"            => :ord,
    "mathit"            => :ord,  "mathbb"            => :ord,
    "mathcal"           => :ord,  "mathfrak"          => :ord,
    "mathsf"            => :ord,  "mathtt"            => :ord,
    "boldsymbol"        => :ord,  "text"              => :ord,
    "mbox"              => :ord,
)

# Spacing amounts in em (18-mu convention: thin = 3 mu, medium = 4 mu, thick = 5 mu).
const _THIN   = 3 / 18
const _MEDIUM = 4 / 18
const _THICK  = 5 / 18

# Automatic inter-atom spacing for Display/Text style: (prev, next) → em.
# Derived from KaTeX spacingData.ts; pairs with no entry have zero spacing.
const _SPACINGS = Dict{Tuple{Symbol,Symbol},Float64}(
    (:ord,   :op)    => _THIN,   (:ord,   :bin)   => _MEDIUM,
    (:ord,   :rel)   => _THICK,  (:ord,   :inner) => _THIN,
    (:op,    :ord)   => _THIN,   (:op,    :op)    => _THIN,
    (:op,    :rel)   => _THICK,  (:op,    :inner) => _THIN,
    (:bin,   :ord)   => _MEDIUM, (:bin,   :op)    => _MEDIUM,
    (:bin,   :open)  => _MEDIUM, (:bin,   :inner) => _MEDIUM,
    (:rel,   :ord)   => _THICK,  (:rel,   :op)    => _THICK,
    (:rel,   :open)  => _THICK,  (:rel,   :inner) => _THICK,
    # :open has no outgoing entries
    (:close, :op)    => _THIN,   (:close, :bin)   => _MEDIUM,
    (:close, :rel)   => _THICK,  (:close, :inner) => _THIN,
    (:punct, :ord)   => _THIN,   (:punct, :op)    => _THIN,
    (:punct, :rel)   => _THICK,  (:punct, :open)  => _THIN,
    (:punct, :close) => _THIN,   (:punct, :punct) => _THIN,
    (:punct, :inner) => _THIN,
    (:inner, :ord)   => _THIN,   (:inner, :op)    => _THIN,
    (:inner, :bin)   => _MEDIUM, (:inner, :rel)   => _THICK,
    (:inner, :open)  => _THIN,   (:inner, :punct) => _THIN,
    (:inner, :inner) => _THIN,
)

# Tight spacing for Script/ScriptScript: only thin spaces survive (KaTeX tightSpacings).
const _TIGHT_SPACINGS = Dict{Tuple{Symbol,Symbol},Float64}(
    (:ord,   :op) => _THIN,
    (:op,    :ord) => _THIN,  (:op,    :op)  => _THIN,
    (:close, :op)  => _THIN,
    (:inner, :op)  => _THIN,
)

# NKOperator names that use limits placement in Display style (\lim, \max, etc.).
const _LIMITS_OPERATORS = Set{String}([
    "lim", "limsup", "liminf",
    "det", "gcd", "inf", "sup", "max", "min", "Pr",
])

# Unicode codepoints for all large-operator symbols rendered via NKCommand.
# These are looked up by codepoint (not PS name) so the correct glyph is found.
const _DISPLAY_OP_CODEPOINTS = Dict{String,UInt32}(
    "sum"       => 0x2211,  "prod"      => 0x220F,  "coprod"    => 0x2210,
    "int"       => 0x222B,  "iint"      => 0x222C,  "iiint"     => 0x222D,
    "oint"      => 0x222E,
    "bigcap"    => 0x22C2,  "bigcup"    => 0x22C3,
    "bigsqcup"  => 0x2A06,  "bigsqcap"  => 0x2A05,
    "bigwedge"  => 0x22C0,  "bigvee"    => 0x22C1,
    "bigoplus"  => 0x2A01,  "bigotimes" => 0x2A02,
    "bigodot"   => 0x2A00,  "biguplus"  => 0x2A04,
)

# Subset of _DISPLAY_OP_CODEPOINTS that also use limits placement in Display style.
const _LIMITS_OP_COMMANDS = Set{String}([
    "sum", "prod", "coprod",
    "bigcap", "bigcup", "bigsqcup", "bigsqcap",
    "bigwedge", "bigvee",
    "bigoplus", "bigotimes", "bigodot", "biguplus",
])

# Unicode codepoints for symbols whose LaTeX command name differs from the
# PostScript glyph name used in OpenType math fonts (e.g. \infty → "infinity",
# not "infty").  Looked up by codepoint so the correct PS name is resolved
# independently of font-specific naming conventions.
const _SYMBOL_CODEPOINTS = Dict{String,UInt32}(
    # Misc math
    "infty"          => 0x221E,  "partial"        => 0x2202,
    "forall"         => 0x2200,  "exists"         => 0x2203,
    "nexists"        => 0x2204,  "emptyset"       => 0x2205,
    "varnothing"     => 0x2205,  "nabla"          => 0x2207,
    "hbar"           => 0x210F,  "ell"            => 0x2113,
    "Re"             => 0x211C,  "Im"             => 0x2111,
    "wp"             => 0x2118,  "aleph"          => 0x2135,
    "beth"           => 0x2136,  "gimel"          => 0x2137,
    "daleth"         => 0x2138,  "angle"          => 0x2220,
    "top"            => 0x22A4,  "bot"            => 0x22A5,
    "prime"          => 0x2032,  "backprime"      => 0x2035,
    "surd"           => 0x221A,  "complement"     => 0x2201,
    "eth"            => 0x00F0,
    # Binary operators
    "pm"             => 0x00B1,  "mp"             => 0x2213,
    "times"          => 0x00D7,  "div"            => 0x00F7,
    "cdot"           => 0x22C5,  "ast"            => 0x2217,
    "star"           => 0x22C6,  "circ"           => 0x2218,
    "bullet"         => 0x2219,  "dagger"         => 0x2020,
    "ddagger"        => 0x2021,  "dag"            => 0x2020,
    "ddag"           => 0x2021,  "cap"            => 0x2229,
    "cup"            => 0x222A,  "sqcap"          => 0x2293,
    "sqcup"          => 0x2294,  "wedge"          => 0x2227,
    "land"           => 0x2227,  "vee"            => 0x2228,
    "lor"            => 0x2228,  "setminus"       => 0x2216,
    "smallsetminus"  => 0x2216,  "oplus"          => 0x2295,
    "ominus"         => 0x2296,  "otimes"         => 0x2297,
    "oslash"         => 0x2298,  "odot"           => 0x2299,
    "wr"             => 0x2240,  "amalg"          => 0x2A3F,
    # Relations
    "leq"            => 0x2264,  "le"             => 0x2264,
    "geq"            => 0x2265,  "ge"             => 0x2265,
    "neq"            => 0x2260,  "ne"             => 0x2260,
    "approx"         => 0x2248,  "equiv"          => 0x2261,
    "sim"            => 0x223C,  "simeq"          => 0x2243,
    "cong"           => 0x2245,  "propto"         => 0x221D,
    "perp"           => 0x22A5,  "parallel"       => 0x2225,
    "mid"            => 0x2223,  "nmid"           => 0x2224,
    "subset"         => 0x2282,  "supset"         => 0x2283,
    "subseteq"       => 0x2286,  "supseteq"       => 0x2287,
    "sqsubseteq"     => 0x2291,  "sqsupseteq"     => 0x2292,
    "in"             => 0x2208,  "notin"          => 0x2209,
    "ni"             => 0x220B,  "owns"           => 0x220B,
    "prec"           => 0x227A,  "succ"           => 0x227B,
    "preceq"         => 0x2AAF,  "succeq"         => 0x2AB0,
    "ll"             => 0x226A,  "gg"             => 0x226B,
    "vdash"          => 0x22A2,  "dashv"          => 0x22A3,
    "models"         => 0x22A8,  "smile"          => 0x2323,
    "frown"          => 0x2322,  "asymp"          => 0x224D,
    # Arrows
    "to"             => 0x2192,
    "rightarrow"     => 0x2192,  "leftarrow"      => 0x2190,
    "Rightarrow"     => 0x21D2,  "Leftarrow"      => 0x21D0,
    "leftrightarrow" => 0x2194,  "Leftrightarrow" => 0x21D4,
    "mapsto"         => 0x21A6,  "longmapsto"     => 0x27FC,
    "longrightarrow" => 0x27F6,  "longleftarrow"  => 0x27F5,
    "Longrightarrow" => 0x27F9,  "Longleftarrow"  => 0x27F8,
    "hookrightarrow" => 0x21AA,  "hookleftarrow"  => 0x21A9,
    "uparrow"        => 0x2191,  "downarrow"      => 0x2193,
    "Uparrow"        => 0x21D1,  "Downarrow"      => 0x21D3,
    "updownarrow"    => 0x2195,  "Updownarrow"    => 0x21D5,
    "nearrow"        => 0x2197,  "searrow"        => 0x2198,
    "swarrow"        => 0x2199,  "nwarrow"        => 0x2196,
    "iff"            => 0x21D4,  "implies"        => 0x27F9,
    # Ellipses
    "ldots"          => 0x2026,  "cdots"          => 0x22EF,
    "vdots"          => 0x22EE,  "ddots"          => 0x22F1,
    "dots"           => 0x2026,
    # Musical / misc
    "sharp"          => 0x266F,  "flat"           => 0x266D,
    "natural"        => 0x266E,
    # Delimiters (used in \big* manual sizing, where the name is the bare symbol)
    "langle"         => 0x27E8,  "rangle"         => 0x27E9,
    "lfloor"         => 0x230A,  "rfloor"         => 0x230B,
    "lceil"          => 0x2308,  "rceil"          => 0x2309,
    "vert"           => 0x007C,  "Vert"           => 0x2016,
)

# Return the TeX atom class for a given AST node.
# Scripted nodes (NKSuperscript, NKSubscript, NKDecorated) inherit from their
# base (first child).  Groups and sequences are treated as ordinary atoms.
# NKSpace yields :neutral — these nodes are transparent to auto-spacing.
function _atom_class(node::Node)::Symbol
    k = node.kind
    if k === NKChar
        ch = only(node.value)
        ch = get(_MATH_CHAR_REMAP, ch, ch)   # same remap as _char_glyph
        return get(_CHAR_ATOM_CLASS, ch, :ord)
    elseif k === NKCommand
        cmd  = node.value
        name = startswith(cmd, "\\") ? cmd[2:end] : cmd
        return get(_CMD_ATOM_CLASS, name, :ord)
    elseif k === NKOperator
        return :op
    elseif k === NKFrac || k === NKDelimited
        return :inner
    elseif k === NKSqrt || k === NKAccent || k === NKText
        return :ord
    elseif k === NKSuperscript || k === NKSubscript || k === NKDecorated
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from base
    elseif k === NKLimitsOverride
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from wrapped base
    elseif k === NKFontSwitch
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from body (e.g. \mathbf{+} is :bin)
    elseif k === NKSpace
        return :neutral   # explicit spaces reset the spacing context
    else
        return :ord   # NKSequence, NKGroup: braced sub-expressions are ordinary
    end
end

# Return automatic inter-atom spacing in em between atoms of class `prev` and
# `next`.  Uses tight spacings in Script/ScriptScript style.
function _interatom_space(prev::Symbol, next::Symbol, style::TexStyle)::Float64
    tight = is_script(style) || is_script_script(style)
    return get(tight ? _TIGHT_SPACINGS : _SPACINGS, (prev, next), 0.0)
end

# Return a Glyph for a Unicode character.
# In math mode, certain ASCII characters are remapped to their correct math
# Unicode equivalents before the glyph lookup (e.g. '-' → U+2212).
# For letters, prefer the PostScript name lookup (more reliable in math fonts
# where the italic variant carries the same single-letter name).  Fall back to
# codepoint lookup for digits and other characters.
function _char_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph,Nothing}
    if ctx.mode === :math
        ch = get(_MATH_CHAR_REMAP, ch, ch)
    end
    if isletter(ch)
        try
            m = glyph_metrics(ctx.family, string(ch))
            return Glyph(string(ch), m.advance_width, m.left_side_bearing,
                         m.x_min, m.y_min, m.x_max, m.y_max)
        catch
        end
    end
    try
        cp = UInt32(ch)
        m  = glyph_metrics_by_codepoint(ctx.family, cp)
        ps = glyph_name_by_codepoint(ctx.family, cp)
        return Glyph(isempty(ps) ? string(ch) : ps,
                     m.advance_width, m.left_side_bearing,
                     m.x_min, m.y_min, m.x_max, m.y_max)
    catch
        return nothing
    end
end

# Return an upright Glyph for a character, or nothing if not in the font.
# Uses the regular font slot when present; falls back to math font codepoint mapping.
function _upright_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph,Nothing}
    m = glyph_metrics_upright(ctx.family, ch)
    m === nothing && return nothing
    # Use the actual PS name from the math font so the renderer gets the correct glyph.
    ps = glyph_name_by_codepoint(ctx.family, UInt32(ch))
    name = isempty(ps) ? string(ch) : ps
    Glyph(name, m.advance_width, m.left_side_bearing,
          m.x_min, m.y_min, m.x_max, m.y_max)
end

# Return a Glyph for a PostScript glyph name, or nothing if not in the font.
function _cmd_glyph(ctx::_LayoutCtx, name::String)::Union{Glyph,Nothing}
    try
        m = glyph_metrics(ctx.family, name)
        return Glyph(name, m.advance_width, m.left_side_bearing,
                     m.x_min, m.y_min, m.x_max, m.y_max)
    catch
        return nothing
    end
end

# Return a Glyph for character `ch` under the given font variant (Option C):
#   1. Try Unicode math-variant codepoint in the math font (covers mathbf, mathbb, etc.).
#   2. For :mathrm, fall through to the upright glyph lookup (regular font or math codepoint).
#   3. Fall through to the default character glyph (italic math form).
function _variant_glyph(ctx::_LayoutCtx, variant::Symbol, ch::Char)::Union{Glyph,Nothing}
    cp_opt = _math_variant_codepoint(variant, ch)
    if cp_opt !== nothing
        try
            cp = cp_opt
            m  = glyph_metrics_by_codepoint(ctx.family, cp)
            ps = glyph_name_by_codepoint(ctx.family, cp)
            return Glyph(isempty(ps) ? string(Char(cp)) : ps,
                         m.advance_width, m.left_side_bearing,
                         m.x_min, m.y_min, m.x_max, m.y_max)
        catch
        end
    end
    # :mathrm (and :boldsymbol for non-latin chars) fall back to upright rendering.
    if variant === :mathrm
        g = _upright_glyph(ctx, ch)
        g !== nothing && return g
    end
    return _char_glyph(ctx, ch)
end

# Maximum y-extent (top of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y; its top is box.y + element.thickness.
function _boxes_top(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    top = 0.0
    for b in boxes
        el = b.element
        if el isa Glyph
            top = max(top, b.y + el.y_max / upm * b.scale)
        elseif el isa HRule
            top = max(top, b.y + el.thickness)
        end
    end
    return top
end

# Minimum y-extent (bottom of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y.
function _boxes_bottom(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    bot = 0.0
    for b in boxes
        el = b.element
        if el isa Glyph
            bot = min(bot, b.y + el.y_min / upm * b.scale)
        elseif el isa HRule
            bot = min(bot, b.y)
        end
    end
    return bot
end

# ── Extensible assembly helpers ───────────────────────────────────────────────

# Build the expanded parts list with extenders repeated `n` times each.
# Parts are in bottom-to-top order (as stored in the font).
function _expand_assembly_parts(
    parts::Vector{GlyphAssemblyPart},
    n::Int,
)::Vector{GlyphAssemblyPart}
    n == 1 && return parts
    result = GlyphAssemblyPart[]
    for p in parts
        reps = p.is_extender ? n : 1
        for _ in 1:reps
            push!(result, p)
        end
    end
    return result
end

# The minimum permissible overlap between two adjacent parts (design units).
# Clamped to the per-gap maximum so we never exceed the connector lengths.
@inline function _gap_min_overlap(
    p1::GlyphAssemblyPart,
    p2::GlyphAssemblyPart,
    min_conn::Int,
)::Int
    max_allowed = min(p1.end_connector, p2.start_connector)
    return min(min_conn, max_allowed)
end

# Total height of an expanded parts list with minimum overlaps (design units).
# Minimum overlaps → maximum possible height for that n.
function _assembly_max_height(parts::Vector{GlyphAssemblyPart}, min_conn::Int)::Float64
    isempty(parts) && return 0.0
    h = Float64(parts[1].full_advance)
    for i in 2:length(parts)
        h += parts[i].full_advance - _gap_min_overlap(parts[i-1], parts[i], min_conn)
    end
    return h
end

# Find the minimum number of extender repetitions so the assembly is at least
# `required_du` tall.  Uses minimum overlaps (giving the tallest assembly) to
# find the tightest bound on n.
function _min_extender_reps(
    parts::Vector{GlyphAssemblyPart},
    required_du::Float64,
    min_conn::Int,
)::Int
    for n in 0:256
        _assembly_max_height(_expand_assembly_parts(parts, n), min_conn) >= required_du &&
            return n
    end
    return 256
end

# Lay out a glyph assembly centred on the math axis.  Returns the horizontal
# advance of the widest part.
function _layout_assembly!(
    asm::GlyphAssembly,
    ctx::_LayoutCtx,
    x0::Float64,
    y0::Float64,
    scale::Float64,
    required_du::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    upm      = ctx.upm
    mc       = ctx.mc
    min_conn = ctx.min_connector_overlap

    n     = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    # Overlap for each gap between adjacent parts (minimum overlap, so the
    # assembly is as tall as the required extent).
    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in 1:length(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i+1], min_conn)
    end

    # Total assembly height in design units.
    total_du = Float64(parts[1].full_advance)
    for i in 1:length(overlaps)
        total_du += parts[i+1].full_advance - overlaps[i]
    end

    # Place the assembly so its ink centre aligns with the math axis.
    axis_em     = y0 + mc.axis_height / upm * scale
    asm_bot_em  = axis_em - (total_du / upm * scale) / 2.0

    max_adv_w = 0
    cursor_du = 0.0
    for i in 1:length(parts)
        p = parts[i]
        g = _cmd_glyph(ctx, p.glyph_name)
        if g !== nothing
            # Each part has y_min=0, y_max=full_advance; place baseline at bottom of part.
            y_part = asm_bot_em + cursor_du / upm * scale
            push!(boxes, LayoutBox(g, x0, y_part, scale))
            max_adv_w = max(max_adv_w, g.advance_width)
        end
        if i <= length(overlaps)
            cursor_du += Float64(p.full_advance) - overlaps[i]
        end
    end

    return max_adv_w / upm * scale
end

# Lay out a radical glyph assembly so that the TOP of the assembly aligns with
# `rule_top_em`.  Unlike delimiter assemblies (centred on the math axis),
# radical assemblies are top-anchored.  Returns horizontal advance.
function _layout_radical_assembly!(
    asm::GlyphAssembly,
    ctx::_LayoutCtx,
    required_du::Float64,
    rule_top_em::Float64,
    x0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    upm      = ctx.upm
    min_conn = ctx.min_connector_overlap

    n     = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in eachindex(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i+1], min_conn)
    end

    total_du = Float64(parts[1].full_advance)
    for i in eachindex(overlaps)
        total_du += parts[i+1].full_advance - overlaps[i]
    end

    # All radical assembly parts have y_min=0, y_max=full_advance.
    # The top of the top cap is at asm_bot + total_du; pin it to rule_top_em.
    asm_bot_em = rule_top_em - total_du / upm * scale

    max_adv_w = 0
    cursor_du = 0.0
    for i in eachindex(parts)
        p = parts[i]
        g = _cmd_glyph(ctx, p.glyph_name)
        if g !== nothing
            push!(boxes, LayoutBox(g, x0, asm_bot_em + cursor_du / upm * scale, scale))
            max_adv_w = max(max_adv_w, g.advance_width)
        end
        i <= length(overlaps) && (cursor_du += Float64(p.full_advance) - overlaps[i])
    end

    return max_adv_w / upm * scale
end

# Choose and place a radical glyph (or assembly) whose ink top aligns with
# `rule_top_em`.  `required_du` is the minimum vertical span (design units)
# the radical must cover — from the body's bottom ink to the rule top.
# Returns horizontal advance.
function _layout_radical!(
    ctx::_LayoutCtx,
    required_du::Float64,
    rule_top_em::Float64,
    x0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    upm = ctx.upm

    function _place_variant(name::String)::Float64
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        # Place so the glyph's top ink (y_max) aligns with rule_top_em.
        push!(boxes, LayoutBox(g, x0, rule_top_em - g.y_max / upm * scale, scale))
        return g.advance_width / upm * scale
    end

    if !haskey(ctx.vert_constructions, "radical")
        return _place_variant("radical")
    end

    vc = ctx.vert_constructions["radical"]

    for v in vc.variants
        Float64(v.advance) >= required_du && return _place_variant(v.glyph_name)
    end

    vc.assembly !== nothing && return _layout_radical_assembly!(
        vc.assembly, ctx, required_du, rule_top_em, x0, scale, boxes)

    chosen = isempty(vc.variants) ? "radical" : last(vc.variants).glyph_name
    return _place_variant(chosen)
end

# Lay out one delimiter (left or right) at position (x0, y0), centred on the
# math axis.  Tries pre-built size variants first; falls back to the glyph
# assembly when no variant is large enough.  Returns horizontal advance.
function _layout_delim!(
    ctx::_LayoutCtx,
    glyph_name::String,
    required_du::Float64,
    x0::Float64,
    y0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    isempty(glyph_name) && return 0.0
    upm = ctx.upm
    mc  = ctx.mc

    function _place_glyph(name::String)::Float64
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
        y_del = y0 + (mc.axis_height / upm - glyph_center) * scale
        push!(boxes, LayoutBox(g, x0, y_del, scale))
        return g.advance_width / upm * scale
    end

    if !haskey(ctx.vert_constructions, glyph_name)
        return _place_glyph(glyph_name)
    end

    vc = ctx.vert_constructions[glyph_name]

    # Try pre-built variants (smallest sufficient first).
    for v in vc.variants
        Float64(v.advance) >= required_du && return _place_glyph(v.glyph_name)
    end

    # No variant is large enough; try the glyph assembly.
    if vc.assembly !== nothing
        return _layout_assembly!(vc.assembly, ctx, x0, y0, scale, required_du, boxes)
    end

    # Fall back to largest variant (or base glyph when no variants exist).
    chosen = isempty(vc.variants) ? glyph_name : last(vc.variants).glyph_name
    return _place_glyph(chosen)
end

# ── Limits-placement helpers ─────────────────────────────────────────────────

# Unwrap NKLimitsOverride to expose the actual operator node for layout.
_limits_base(node::Node) = node.kind === NKLimitsOverride ? node.children[1] : node

# Return true when the script children of a decorated atom should be placed above
# and below the base (limits style) rather than beside it (side style).
function _use_limits(base::Node, style::TexStyle)::Bool
    base.kind === NKLimitsOverride && return base.value == "limits"
    if base.kind === NKOperator
        return base.value ∈ _LIMITS_OPERATORS && is_display(style)
    end
    if base.kind === NKCommand
        name = startswith(base.value, "\\") ? base.value[2:end] : base.value
        return name ∈ _LIMITS_OP_COMMANDS && is_display(style)
    end
    return false
end

# Return true when `node` is a large operator whose scripts should be clamped
# to the glyph extents in Display style (integral-family operators).  Unlike
# _use_limits, this returns true for integrals and oint which use side placement.
function _is_large_op(node::Node)::Bool
    n = node.kind === NKLimitsOverride ? node.children[1] : node
    n.kind === NKCommand || return false
    name = startswith(n.value, "\\") ? n.value[2:end] : n.value
    return haskey(_DISPLAY_OP_CODEPOINTS, name)
end

# ── Recursive layout ──────────────────────────────────────────────────────────

# Lay out a list of child nodes with inter-atom auto-spacing in math mode.
# Returns the total advance width.  Used by NKSequence, NKGroup, and the inner
# content loop of NKDelimited so spacing is consistent in all three contexts.
function _layout_children!(
    children,
    ctx::_LayoutCtx,
    style::TexStyle,
    x0::Float64,
    y0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    cursor = x0
    prev_class = :nothing
    for child in children
        cls = _atom_class(child)
        if cls === :neutral
            cursor += _layout_node!(child, ctx, style, cursor, y0, scale, boxes)
            prev_class = :nothing
        else
            if ctx.mode === :math && prev_class !== :nothing
                sp = _interatom_space(prev_class, cls, style) * scale
                if sp > 0.0
                    push!(boxes, LayoutBox(Space(sp), cursor, y0, scale))
                    cursor += sp
                end
            end
            cursor += _layout_node!(child, ctx, style, cursor, y0, scale, boxes)
            prev_class = cls
        end
    end
    return cursor - x0
end

# Lay out `node` into `boxes`, with the left-baseline anchor at (x0, y0) and
# the given scale.  Returns the horizontal advance of the node in em units.
function _layout_node!(
    node::Node,
    ctx::_LayoutCtx,
    style::TexStyle,
    x0::Float64,
    y0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    mc  = ctx.mc
    upm = ctx.upm

    if node.kind === NKChar
        ch = only(node.value)
        g  = if ctx.font_variant !== :default
                 _variant_glyph(ctx, ctx.font_variant, ch)
             elseif ctx.mode === :math && isletter(ch)
                 # Standard LaTeX renders math-mode letters italic; use the
                 # math-italic Unicode variant (U+1D400 block) so e.g. 'x' → u1D465.
                 _variant_glyph(ctx, :mathit, ch)
             else
                 _char_glyph(ctx, ch)
             end
        g === nothing && return 0.0
        push!(boxes, LayoutBox(g, x0, y0, scale))
        return g.advance_width / upm * scale

    elseif node.kind === NKCommand
        cmd  = node.value   # e.g. "\\alpha"
        name = startswith(cmd, "\\") ? cmd[2:end] : cmd
        if haskey(_DISPLAY_OP_CODEPOINTS, name)
            # Large operator: resolve glyph by codepoint so the correct PS name
            # (e.g. "summation") is used instead of the bare command name ("sum").
            ps = glyph_name_by_codepoint(ctx.family, _DISPLAY_OP_CODEPOINTS[name])
            isempty(ps) && return 0.0
            # In Display style, pick the smallest vert_constructions variant that
            # meets or exceeds display_operator_min_height (in design units).
            chosen = ps
            if is_display(style) && haskey(ctx.vert_constructions, ps)
                min_h = Float64(mc.display_operator_min_height)
                for v in ctx.vert_constructions[ps].variants
                    if Float64(v.advance) >= min_h
                        chosen = v.glyph_name
                        break
                    end
                end
            end
            g = _cmd_glyph(ctx, chosen)
            g === nothing && return 0.0
            # Centre large operator on the math axis (same logic as _layout_delim!).
            glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
            y_op = y0 + (mc.axis_height / upm - glyph_center) * scale
            push!(boxes, LayoutBox(g, x0, y_op, scale))
            return g.advance_width / upm * scale
        else
            # Try the symbol codepoint table first so that commands whose PS
            # glyph name differs from the command name (e.g. \infty → "infinity")
            # are resolved correctly regardless of font-specific naming.
            g = if haskey(_SYMBOL_CODEPOINTS, name)
                    cp = _SYMBOL_CODEPOINTS[name]
                    try
                        m  = glyph_metrics_by_codepoint(ctx.family, cp)
                        ps = glyph_name_by_codepoint(ctx.family, cp)
                        Glyph(isempty(ps) ? name : ps,
                              m.advance_width, m.left_side_bearing,
                              m.x_min, m.y_min, m.x_max, m.y_max)
                    catch
                        _cmd_glyph(ctx, name)
                    end
                else
                    _cmd_glyph(ctx, name)
                end
            g === nothing && return 0.0
            push!(boxes, LayoutBox(g, x0, y0, scale))
            return g.advance_width / upm * scale
        end

    elseif node.kind === NKLimitsOverride
        # \limits / \nolimits override node: lay out the wrapped base normally.
        # The script placement decision (limits vs. side) is made in the script branches.
        return _layout_node!(_limits_base(node), ctx, style, x0, y0, scale, boxes)

    elseif node.kind === NKOperator
        # Render each character of the operator name upright (roman).
        cursor = x0
        for ch in node.value
            g = _upright_glyph(ctx, ch)
            g === nothing && continue
            push!(boxes, LayoutBox(g, cursor, y0, scale))
            cursor += g.advance_width / upm * scale
        end
        return cursor - x0

    elseif node.kind === NKSpace
        w = parse(Float64, node.value) * scale
        iszero(w) && return 0.0
        push!(boxes, LayoutBox(Space(w), x0, y0, scale))
        return w

    elseif node.kind === NKSequence || node.kind === NKGroup
        return _layout_children!(node.children, ctx, style, x0, y0, scale, boxes)

    elseif node.kind === NKSuperscript
        base, sup = node.children[1], node.children[2]
        sup_s     = sup_style(style);  sup_scale = size_scale(sup_s, mc)
        if _use_limits(base, style)
            # Limits placement: sup centred above base.
            tmp_base = LayoutBox[];  tmp_sup = LayoutBox[]
            base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
            sup_w  = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
            base_top = _boxes_top(tmp_base, upm)
            s = scale / upm
            y_sup = max(y0 + base_top + mc.upper_limit_baseline_rise_min * s,
                        y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm))
            total_w = max(base_w, sup_w)
            Δbase = (total_w - base_w) / 2;  Δsup = (total_w - sup_w) / 2
            for b in tmp_base
                push!(boxes, LayoutBox(b.element, x0 + Δbase + b.x, y0 + b.y, b.scale))
            end
            for b in tmp_sup
                push!(boxes, LayoutBox(b.element, x0 + Δsup + b.x, y_sup + b.y, b.scale))
            end
            return total_w
        else
            tmp_base = LayoutBox[]
            base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
            append!(boxes, tmp_base)
            shift_up = is_cramped(style) ?
                mc.superscript_shift_up_cramped / upm * scale :
                mc.superscript_shift_up / upm * scale
            # For large operators (e.g. \int) in Display style, apply TeX Rule 18:
            # the superscript baseline must not drop below base_top − supDrop, where
            # supDrop = SuperscriptBaselineDropMax (OpenType equivalent of σ₁₈).
            y_sup = _is_large_op(base) && is_display(style) ?
                max(y0 + shift_up, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max / upm * scale) : y0 + shift_up
            sup_adv  = _layout_node!(sup, ctx, sup_s, x0 + base_adv, y_sup, sup_scale, boxes)
            return base_adv + sup_adv + mc.space_after_script / upm * scale
        end

    elseif node.kind === NKSubscript
        base, sub = node.children[1], node.children[2]
        sub_s     = sub_style(style);  sub_scale = size_scale(sub_s, mc)
        if _use_limits(base, style)
            # Limits placement: sub centred below base.
            tmp_base = LayoutBox[];  tmp_sub = LayoutBox[]
            base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
            sub_w  = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
            base_bot = _boxes_bottom(tmp_base, upm)
            s = scale / upm
            y_sub = min(y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
                        y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s)
            total_w = max(base_w, sub_w)
            Δbase = (total_w - base_w) / 2;  Δsub = (total_w - sub_w) / 2
            for b in tmp_base
                push!(boxes, LayoutBox(b.element, x0 + Δbase + b.x, y0 + b.y, b.scale))
            end
            for b in tmp_sub
                push!(boxes, LayoutBox(b.element, x0 + Δsub + b.x, y_sub + b.y, b.scale))
            end
            return total_w
        else
            tmp_base = LayoutBox[]
            base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
            append!(boxes, tmp_base)
            shift_dn = mc.subscript_shift_down / upm * scale
            # For large operators in Display style, apply TeX Rule 18: the subscript
            # baseline must not rise above base_bottom + subDrop, where subDrop =
            # SubscriptBaselineDropMin (OpenType equivalent of σ₁₉).
            y_sub = _is_large_op(base) && is_display(style) ?
                min(y0 - shift_dn, _boxes_bottom(tmp_base, upm) + mc.subscript_baseline_drop_min / upm * scale) : y0 - shift_dn
            sub_adv  = _layout_node!(sub, ctx, sub_s, x0 + base_adv, y_sub, sub_scale, boxes)
            return base_adv + sub_adv + mc.space_after_script / upm * scale
        end

    elseif node.kind === NKDecorated
        base, sub, sup = node.children[1], node.children[2], node.children[3]
        sub_s = sub_style(style);  sub_scale = size_scale(sub_s, mc)
        sup_s = sup_style(style);  sup_scale = size_scale(sup_s, mc)
        if _use_limits(base, style)
            # Limits placement: sub centred below, sup centred above.
            tmp_base = LayoutBox[];  tmp_sub = LayoutBox[];  tmp_sup = LayoutBox[]
            base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
            sub_w  = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
            sup_w  = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
            base_top = _boxes_top(tmp_base, upm)
            base_bot = _boxes_bottom(tmp_base, upm)
            s = scale / upm
            y_sup = max(y0 + base_top + mc.upper_limit_baseline_rise_min * s,
                        y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm))
            y_sub = min(y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
                        y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s)
            total_w = max(base_w, sub_w, sup_w)
            Δbase = (total_w - base_w) / 2
            Δsub  = (total_w - sub_w)  / 2
            Δsup  = (total_w - sup_w)  / 2
            for b in tmp_base
                push!(boxes, LayoutBox(b.element, x0 + Δbase + b.x, y0 + b.y, b.scale))
            end
            for b in tmp_sub
                push!(boxes, LayoutBox(b.element, x0 + Δsub + b.x, y_sub + b.y, b.scale))
            end
            for b in tmp_sup
                push!(boxes, LayoutBox(b.element, x0 + Δsup + b.x, y_sup + b.y, b.scale))
            end
            return total_w
        else
            tmp_base = LayoutBox[]
            base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
            append!(boxes, tmp_base)
            script_x = x0 + base_adv
            shift_up = is_cramped(style) ?
                mc.superscript_shift_up_cramped / upm * scale :
                mc.superscript_shift_up / upm * scale
            shift_dn = mc.subscript_shift_down / upm * scale
            # For large operators in Display style, apply TeX Rule 18 (σ₁₈/σ₁₉):
            # scripts may not fall within base_top − supDrop .. base_bottom + subDrop.
            y_sup, y_sub = if _is_large_op(base) && is_display(style)
                max(y0 + shift_up, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max / upm * scale),
                min(y0 - shift_dn, _boxes_bottom(tmp_base, upm) + mc.subscript_baseline_drop_min / upm * scale)
            else
                y0 + shift_up, y0 - shift_dn
            end
            sub_adv = _layout_node!(sub, ctx, sub_s, script_x, y_sub, sub_scale, boxes)
            sup_adv = _layout_node!(sup, ctx, sup_s, script_x, y_sup, sup_scale, boxes)
            return base_adv + max(sub_adv, sup_adv) + mc.space_after_script / upm * scale
        end

    elseif node.kind === NKFrac
        num_node, den_node = node.children[1], node.children[2]
        num_s = frac_num_style(style);  num_scale = size_scale(num_s, mc)
        den_s = frac_den_style(style);  den_scale = size_scale(den_s, mc)

        rule_thickness = mc.fraction_rule_thickness / upm * scale
        axis_em = mc.axis_height / upm * scale
        # Rule centre at the math axis; rule.y is the bottom edge.
        rule_y = y0 + axis_em - rule_thickness / 2

        # Initial shifts and minimum gap constants from the MATH table.
        if is_display(style)
            num_shift = mc.fraction_numerator_display_style_shift_up / upm * scale
            den_shift = mc.fraction_denominator_display_style_shift_down / upm * scale
            num_gap   = mc.fraction_num_display_style_gap_min / upm * scale
            den_gap   = mc.fraction_denom_display_style_gap_min / upm * scale
        else
            num_shift = mc.fraction_numerator_shift_up / upm * scale
            den_shift = mc.fraction_denominator_shift_down / upm * scale
            num_gap   = mc.fraction_numerator_gap_min / upm * scale
            den_gap   = mc.fraction_denominator_gap_min / upm * scale
        end

        # Layout at y=0 to measure ink extents before applying shifts.
        tmp_num = LayoutBox[];  tmp_den = LayoutBox[]
        num_w = _layout_node!(num_node, ctx, num_s, 0.0, 0.0, num_scale, tmp_num)
        den_w = _layout_node!(den_node, ctx, den_s, 0.0, 0.0, den_scale, tmp_den)

        # Clamp shifts so the minimum gap between content and rule is respected
        # (TeX Rule 15d/15e).  num_depth is how far the numerator ink extends
        # below its own baseline; den_height is how far the denominator ink
        # extends above its own baseline.
        num_depth  = max(0.0, -_boxes_bottom(tmp_num, upm))
        den_height = max(0.0,  _boxes_top(tmp_den,    upm))
        num_shift  = max(num_shift, axis_em + rule_thickness / 2 + num_gap + num_depth)
        den_shift  = max(den_shift, den_height - axis_em + rule_thickness / 2 + den_gap)

        frac_w = max(num_w, den_w)
        num_y  = y0 + num_shift
        den_y  = y0 - den_shift

        Δnum = (frac_w - num_w) / 2
        for b in tmp_num
            push!(boxes, LayoutBox(b.element, x0 + Δnum + b.x, num_y + b.y, b.scale))
        end
        Δden = (frac_w - den_w) / 2
        for b in tmp_den
            push!(boxes, LayoutBox(b.element, x0 + Δden + b.x, den_y + b.y, b.scale))
        end
        push!(boxes, LayoutBox(HRule(frac_w, rule_thickness), x0, rule_y, scale))
        return frac_w

    elseif node.kind === NKSqrt
        # \sqrt[degree]{body}: children are [body] or [degree, body].
        body_node = length(node.children) == 1 ? node.children[1] : node.children[2]
        tmp = LayoutBox[]
        body_w   = _layout_node!(body_node, ctx, style, 0.0, 0.0, scale, tmp)
        body_top = _boxes_top(tmp, upm)
        body_bot = _boxes_bottom(tmp, upm)

        gap            = is_display(style) ?
            mc.radical_display_style_vertical_gap / upm * scale :
            mc.radical_vertical_gap / upm * scale
        rule_thickness = mc.radical_rule_thickness / upm * scale
        rule_y_local   = body_top + gap           # bottom of rule bar (em, relative to y0)
        rule_top_local = rule_y_local + rule_thickness

        # required_du: vertical span from body bottom to rule top, in design
        # units at scale=1 (matching the vert_constructions advance values).
        required_du  = (rule_top_local - body_bot) / scale * upm
        rule_top_em  = y0 + rule_top_local
        rad_adv = _layout_radical!(ctx, required_du, rule_top_em, x0, scale, boxes)

        for b in tmp
            push!(boxes, LayoutBox(b.element, x0 + rad_adv + b.x, y0 + b.y, b.scale))
        end
        push!(boxes, LayoutBox(HRule(body_w, rule_thickness), x0 + rad_adv, y0 + rule_y_local, scale))
        return rad_adv + body_w

    elseif node.kind === NKDelimited
        # \left…\right: size delimiters to the inner content, centred on the math axis.
        # node.value encodes "left_ps_name\x00right_ps_name".
        sep        = findfirst('\x00', node.value)
        left_name  = sep === nothing ? node.value : node.value[1:sep-1]
        right_name = sep === nothing ? ""          : node.value[sep+1:end]

        # Lay out inner content in a scratch buffer to measure its vertical extent.
        tmp       = LayoutBox[]
        content_w = _layout_children!(node.children, ctx, style, x0, y0, scale, tmp)

        # Vertical extent of the inner content (in em units relative to y0).
        content_top = _boxes_top(tmp, upm)
        content_bot = _boxes_bottom(tmp, upm)
        # Ensure a sensible non-zero span when content has no glyph ink.
        content_top = max(content_top, y0 + mc.axis_height / upm * scale)
        content_bot = min(content_bot, y0 - mc.axis_height / upm * scale)

        # Required delimiter advance: sized so the delimiter covers the content
        # symmetrically around the math axis.  Converted to unscaled design units
        # because GlyphVariant.advance and GlyphAssemblyPart.full_advance are
        # both stored in unscaled design units.
        axis_em     = y0 + mc.axis_height / upm * scale
        h_above     = max(0.0, content_top - axis_em)
        h_below     = max(0.0, axis_em - content_bot)
        required_em = 2.0 * max(h_above, h_below)
        required_du = required_em / scale * upm

        # Place left delimiter (variant or assembly), then inner content, then right.
        left_w  = _layout_delim!(ctx, left_name,  required_du, x0,               y0, scale, boxes)
        inner_x = x0 + left_w
        for b in tmp
            push!(boxes, LayoutBox(b.element, inner_x + (b.x - x0), b.y, b.scale))
        end
        right_w = _layout_delim!(ctx, right_name, required_du, inner_x + content_w, y0, scale, boxes)

        return left_w + content_w + right_w

    elseif node.kind === NKFontSwitch
        # Switch the active font variant for all recursive calls within the body.
        new_ctx = _LayoutCtx(ctx.family, ctx.mc, ctx.upm, ctx.vert_constructions,
                             ctx.min_connector_overlap, ctx.mode,
                             Symbol(node.value))
        isempty(node.children) && return 0.0
        return _layout_node!(node.children[1], new_ctx, style, x0, y0, scale, boxes)

    elseif node.kind === NKAccent
        # Lay out the base; the accent mark is not yet implemented.
        isempty(node.children) && return 0.0
        return _layout_node!(node.children[1], ctx, style, x0, y0, scale, boxes)

    else
        return 0.0   # NKText and unrecognised nodes: emit nothing
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    layout(node, family, style) -> Vector{LayoutBox}

Lay out `node` in the given style, using font metrics from `family`.
Returns a flat list of positioned elements.
"""
function layout(node::Node, family::FontFamily, style::TexStyle)::Vector{LayoutBox}
    mt  = load_math_table(family.math)
    ctx = _LayoutCtx(family, mt.constants, Float64(mt.upm), mt.vert_constructions,
                     mt.min_connector_overlap, :math, :default)
    boxes = LayoutBox[]
    _layout_node!(node, ctx, style, 0.0, 0.0, size_scale(style, mt.constants), boxes)
    return boxes
end

# ── Makie interface ────────────────────────────────────────────────────────────

"""
    generate_tex_elements(input, family) -> Vector{LayoutBox}

Top-level entry point: parse and lay out a LaTeX math string.
Returns the same flat `(element, x, y, scale)` representation consumed by
`texelems_and_glyph_collection` in Makie.
"""
function generate_tex_elements(
    input::AbstractString,
    family::FontFamily = default_font_family(),
)::Vector{LayoutBox}
    node = parse_latex(input)
    layout(node, family, Display)
end

"""Return the globally-configured default font family."""
function default_font_family()::FontFamily
    error("not implemented: default_font_family")
end
