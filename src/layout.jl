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
A single glyph to be rendered.

`glyph_name` is the PostScript glyph name; the renderer resolves it to a glyph
index via its font handle.  `font_slot` tells the renderer which font to use:
`:math` for the OpenType math font (all math-mode glyphs), or `:regular` for
the companion text font (glyphs inside `\\text{}`/`\\mbox{}`).  The metric
fields are cached from the chosen font in design units so the renderer need not
re-query them.
"""
struct Glyph <: TeXElement
    glyph_name::String
    font_slot::Symbol       # :math | :regular
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
    vert_constructions::Dict{String, GlyphConstruction}
    horiz_constructions::Dict{String, GlyphConstruction}  # for \widehat, \widetilde
    top_accent_attachments::Dict{String, Int}  # PS glyph name → x position (design units)
    italic_corrections::Dict{String, Int}      # PS glyph name → design units (from MATH table)
    min_connector_overlap::Int
    mode::Symbol          # :math | :text
    font_variant::Symbol  # :default | :mathbf | :mathit | :mathrm | :mathbb | …
end

# Return a copy of `ctx` with `font_variant` replaced.  Used by NKFontSwitch so
# the rest of the context (family, math constants, mode, …) is inherited.
@inline _with_variant(ctx::_LayoutCtx, variant::Symbol) = _LayoutCtx(
    ctx.family, ctx.mc, ctx.upm, ctx.vert_constructions, ctx.horiz_constructions,
    ctx.top_accent_attachments, ctx.italic_corrections, ctx.min_connector_overlap,
    ctx.mode, variant,
)

# Propagate a font-size multiplier (from \large, \tiny, etc.) through a style
# transition.  `scale` is the parent's absolute scale (which already includes
# any sizing factor); `parent_s` and `child_s` are TeX styles.  The result is
# the child's absolute scale, preserving whatever sizing factor was embedded in
# the parent scale beyond what the parent style alone contributes.
#
#   child_scale = scale × (size_scale(child_s) / size_scale(parent_s))
#
# Because size_scale only returns 1.0, ~0.7, or ~0.5 (never zero), the
# division is always safe.
@inline _scale_for_child(
    scale::Float64, parent_s::TexStyle, child_s::TexStyle,
    mc::MathConstants
) =
    scale * (size_scale(child_s, mc) / size_scale(parent_s, mc))

# Return a copy of `ctx` with mode set to :text, preserving all other fields.
# Used by NKText so that character lookup uses upright (regular-font) glyphs and
# math-mode italic remapping and inter-atom spacing are suppressed.
@inline _with_text_mode(ctx::_LayoutCtx) = _LayoutCtx(
    ctx.family, ctx.mc, ctx.upm, ctx.vert_constructions, ctx.horiz_constructions,
    ctx.top_accent_attachments, ctx.italic_corrections, ctx.min_connector_overlap,
    :text, ctx.font_variant,
)

# Characters whose ASCII/Latin-1 codepoints differ from their correct math-mode
# glyph.  Applied only in :math mode; text mode uses the literal codepoint.
const _MATH_CHAR_REMAP = Dict{Char, Char}(
    '-' => '−',   # U+002D HYPHEN-MINUS  → U+2212 MINUS SIGN
    '*' => '∗',   # U+002A ASTERISK      → U+2217 ASTERISK OPERATOR
)

# ── Atom classification ───────────────────────────────────────────────────────

# Inter-atom spacing follows TeX's eight atom classes (Knuth, Chapter 17) and
# KaTeX's spacingData.ts.  Characters/commands not listed default to :ord.
# _MATH_CHAR_REMAP is applied before char lookup so '-' and '−' both yield :bin.
const _CHAR_ATOM_CLASS = Dict{Char, Symbol}(
    # Binary operators
    '+' => :bin,
    '-' => :bin,    # U+002D (also remapped to U+2212 for glyph lookup)
    '−' => :bin,    # U+2212 MINUS SIGN
    '*' => :bin,    # U+002A (remapped to U+2217)
    '∗' => :bin,    # U+2217 ASTERISK OPERATOR
    '×' => :bin, '÷' => :bin,
    '·' => :bin, '±' => :bin,
    '∓' => :bin, '∧' => :bin,
    '∨' => :bin, '∩' => :bin,
    '∪' => :bin, '⊕' => :bin,
    '⊖' => :bin, '⊗' => :bin,
    '⊘' => :bin, '⊙' => :bin,
    '∘' => :bin, '•' => :bin,
    '⋆' => :bin, '†' => :bin,
    '‡' => :bin,
    # Relations
    '=' => :rel, '<' => :rel,
    '>' => :rel, ':' => :rel,
    '≤' => :rel, '≥' => :rel,
    '≠' => :rel, '≈' => :rel,
    '∼' => :rel, '≃' => :rel,
    '≅' => :rel, '∝' => :rel,
    '⊥' => :rel, '∥' => :rel,
    '∣' => :rel, '⊂' => :rel,
    '⊃' => :rel, '⊆' => :rel,
    '⊇' => :rel, '∈' => :rel,
    '∉' => :rel, '∋' => :rel,
    '→' => :rel, '←' => :rel,
    '↔' => :rel, '⇒' => :rel,
    '⇐' => :rel, '⇔' => :rel,
    '↦' => :rel, '≡' => :rel,
    '≺' => :rel, '≻' => :rel,
    '≪' => :rel, '≫' => :rel,
    '⊢' => :rel, '⊣' => :rel,
    '⊨' => :rel, '↑' => :rel,
    '↓' => :rel, '⇑' => :rel,
    '⇓' => :rel,
    # Open delimiters
    '(' => :open, '[' => :open,
    # Close delimiters
    ')' => :close, ']' => :close,
    '!' => :close,
    # Punctuation
    ',' => :punct, ';' => :punct,
    # Inner (ellipses)
    '…' => :inner, '⋯' => :inner,
    '⋱' => :inner,
)

# Atom class by command name (bare, without leading backslash).
const _CMD_ATOM_CLASS = Dict{String, Symbol}(
    # ── Binary operators ────────────────────────────────────────────────────
    "pm" => :bin, "mp" => :bin,
    "times" => :bin, "div" => :bin,
    "cdot" => :bin, "ast" => :bin,
    "star" => :bin, "circ" => :bin,
    "bullet" => :bin,
    "cap" => :bin, "cup" => :bin,
    "sqcap" => :bin, "sqcup" => :bin,
    "wedge" => :bin, "land" => :bin,
    "vee" => :bin, "lor" => :bin,
    "setminus" => :bin, "smallsetminus" => :bin,
    "oplus" => :bin, "ominus" => :bin,
    "otimes" => :bin, "oslash" => :bin,
    "odot" => :bin,
    "boxplus" => :bin, "boxminus" => :bin,
    "boxtimes" => :bin, "boxdot" => :bin,
    "ltimes" => :bin, "rtimes" => :bin,
    "wr" => :bin, "amalg" => :bin,
    "dagger" => :bin, "ddagger" => :bin,
    "dag" => :bin, "ddag" => :bin,
    "triangleleft" => :bin, "triangleright" => :bin,
    "barwedge" => :bin, "curlywedge" => :bin,
    "curlyvee" => :bin, "intercal" => :bin,
    "dotplus" => :bin, "leftthreetimes" => :bin,
    "rightthreetimes" => :bin, "doublebarwedge" => :bin,
    "divideontimes" => :bin,

    # ── Relations ───────────────────────────────────────────────────────────
    "leq" => :rel, "le" => :rel,
    "geq" => :rel, "ge" => :rel,
    "neq" => :rel, "ne" => :rel,
    "equiv" => :rel, "approx" => :rel,
    "sim" => :rel, "simeq" => :rel,
    "cong" => :rel, "propto" => :rel,
    "perp" => :rel, "parallel" => :rel,
    "mid" => :rel, "nmid" => :rel,
    "subset" => :rel, "supset" => :rel,
    "subseteq" => :rel, "supseteq" => :rel,
    "sqsubseteq" => :rel, "sqsupseteq" => :rel,
    "in" => :rel, "notin" => :rel,
    "ni" => :rel, "owns" => :rel,
    "prec" => :rel, "succ" => :rel,
    "preceq" => :rel, "succeq" => :rel,
    "ll" => :rel, "gg" => :rel,
    "lll" => :rel, "ggg" => :rel,
    "to" => :rel,
    "leftarrow" => :rel, "rightarrow" => :rel,
    "Leftarrow" => :rel, "Rightarrow" => :rel,
    "leftrightarrow" => :rel, "Leftrightarrow" => :rel,
    "longleftarrow" => :rel, "longrightarrow" => :rel,
    "Longleftarrow" => :rel, "Longrightarrow" => :rel,
    "longleftrightarrow" => :rel, "Longleftrightarrow" => :rel,
    "iff" => :rel, "implies" => :rel,
    "mapsto" => :rel, "longmapsto" => :rel,
    "hookleftarrow" => :rel, "hookrightarrow" => :rel,
    "uparrow" => :rel, "downarrow" => :rel,
    "Uparrow" => :rel, "Downarrow" => :rel,
    "updownarrow" => :rel, "Updownarrow" => :rel,
    "nearrow" => :rel, "searrow" => :rel,
    "swarrow" => :rel, "nwarrow" => :rel,
    "vdash" => :rel, "dashv" => :rel,
    "models" => :rel,
    "smile" => :rel, "frown" => :rel,
    "asymp" => :rel, "bowtie" => :rel,
    "Join" => :rel, "not" => :rel,
    "nleq" => :rel, "ngeq" => :rel,
    "nless" => :rel, "ngtr" => :rel,
    "nsim" => :rel, "nparallel" => :rel,
    "nsubseteq" => :rel, "nsupseteq" => :rel,
    "subsetneq" => :rel, "supsetneq" => :rel,
    "varsubsetneq" => :rel, "varsupsetneq" => :rel,
    "lneq" => :rel, "gneq" => :rel,
    "lnsim" => :rel, "gnsim" => :rel,
    "preccurlyeq" => :rel, "succcurlyeq" => :rel,
    "curlyeqprec" => :rel, "curlyeqsucc" => :rel,
    "sqsubset" => :rel, "sqsupset" => :rel,
    "Supset" => :rel, "Subset" => :rel,
    "trianglelefteq" => :rel, "trianglerighteq" => :rel,
    "vartriangleleft" => :rel, "vartriangleright" => :rel,
    "blacktriangleleft" => :rel, "blacktriangleright" => :rel,
    "leqq" => :rel, "geqq" => :rel,
    "leqslant" => :rel, "geqslant" => :rel,
    "eqslantless" => :rel, "eqslantgtr" => :rel,
    "lesssim" => :rel, "gtrsim" => :rel,
    "lessapprox" => :rel, "gtrapprox" => :rel,
    "approxeq" => :rel,
    "lessdot" => :rel, "gtrdot" => :rel,
    "lessgtr" => :rel, "gtrless" => :rel,
    "lesseqgtr" => :rel, "gtreqless" => :rel,
    "lesseqqgtr" => :rel, "gtreqqless" => :rel,
    "doteq" => :rel, "doteqdot" => :rel,
    "risingdotseq" => :rel, "fallingdotseq" => :rel,
    "backsim" => :rel, "backsimeq" => :rel,
    "eqcirc" => :rel, "circeq" => :rel,
    "triangleq" => :rel,
    "bumpeq" => :rel, "Bumpeq" => :rel,
    "thicksim" => :rel, "thickapprox" => :rel,
    "supseteqq" => :rel, "subseteqq" => :rel,
    "shortparallel" => :rel, "between" => :rel,
    "pitchfork" => :rel, "therefore" => :rel,
    "because" => :rel, "shortmid" => :rel,
    "backepsilon" => :rel, "varpropto" => :rel,
    "nleqslant" => :rel, "ngeqslant" => :rel,
    "nleqq" => :rel, "ngeqq" => :rel,
    "lvertneqq" => :rel, "gvertneqq" => :rel,
    "nprec" => :rel, "nsucc" => :rel,
    "npreceq" => :rel, "nsucceq" => :rel,

    # ── Large operators ─────────────────────────────────────────────────────
    "int" => :op, "iint" => :op,
    "iiint" => :op, "iiiint" => :op,
    "oint" => :op, "oiint" => :op,
    "oiiint" => :op,
    "sum" => :op, "prod" => :op,
    "coprod" => :op,
    "bigcap" => :op, "bigcup" => :op,
    "bigsqcup" => :op, "bigsqcap" => :op,
    "bigwedge" => :op, "bigvee" => :op,
    "bigoplus" => :op, "bigotimes" => :op,
    "bigodot" => :op, "biguplus" => :op,
    "bigplus" => :op,

    # ── Manual delimiter sizing ──────────────────────────────────────────────
    "bigl" => :open, "Bigl" => :open,
    "biggl" => :open, "Biggl" => :open,
    "bigr" => :close, "Bigr" => :close,
    "biggr" => :close, "Biggr" => :close,
    "bigm" => :rel, "Bigm" => :rel,
    "biggm" => :rel, "Biggm" => :rel,

    # ── Open delimiters ─────────────────────────────────────────────────────
    "{" => :open,
    "langle" => :open,
    "lfloor" => :open,
    "lceil" => :open,
    "lvert" => :open,
    "lVert" => :open,
    "lgroup" => :open,
    "lmoustache" => :open,
    "llbracket" => :open,

    # ── Close delimiters ────────────────────────────────────────────────────
    "}" => :close,
    "rangle" => :close,
    "rfloor" => :close,
    "rceil" => :close,
    "rvert" => :close,
    "rVert" => :close,
    "rgroup" => :close,
    "rmoustache" => :close,
    "rrbracket" => :close,

    # ── Punctuation ─────────────────────────────────────────────────────────
    "colon" => :punct,
    "cdotp" => :punct,
    "ldotp" => :punct,

    # ── Inner (ellipses, \bmod, \pmod) ──────────────────────────────────────
    "ldots" => :inner,
    "cdots" => :inner,
    "ddots" => :inner,
    "dots" => :inner,
    "dotsb" => :inner,
    "dotsc" => :inner,
    "dotsi" => :inner,
    "dotsm" => :inner,
    "dotso" => :inner,
    "bmod" => :inner,
    "pmod" => :inner,

    # ── Ordinary symbols ────────────────────────────────────────────────────
    # Greek lowercase
    "alpha" => :ord, "beta" => :ord,
    "gamma" => :ord, "delta" => :ord,
    "epsilon" => :ord, "varepsilon" => :ord,
    "zeta" => :ord, "eta" => :ord,
    "theta" => :ord, "vartheta" => :ord,
    "iota" => :ord, "kappa" => :ord,
    "lambda" => :ord, "mu" => :ord,
    "nu" => :ord, "xi" => :ord,
    "pi" => :ord, "varpi" => :ord,
    "rho" => :ord, "varrho" => :ord,
    "sigma" => :ord, "varsigma" => :ord,
    "tau" => :ord, "upsilon" => :ord,
    "phi" => :ord, "varphi" => :ord,
    "chi" => :ord, "psi" => :ord,
    "omega" => :ord,
    # Greek uppercase
    "Gamma" => :ord, "Delta" => :ord,
    "Theta" => :ord, "Lambda" => :ord,
    "Xi" => :ord, "Pi" => :ord,
    "Sigma" => :ord, "Upsilon" => :ord,
    "Phi" => :ord, "Psi" => :ord,
    "Omega" => :ord,
    # Miscellaneous ordinary symbols
    "infty" => :ord, "partial" => :ord,
    "nabla" => :ord, "forall" => :ord,
    "exists" => :ord, "nexists" => :ord,
    "emptyset" => :ord, "varnothing" => :ord,
    "angle" => :ord, "measuredangle" => :ord,
    "sphericalangle" => :ord,
    "ell" => :ord,
    "imath" => :ord, "jmath" => :ord,
    "hbar" => :ord, "hslash" => :ord,
    "Re" => :ord, "Im" => :ord,
    "wp" => :ord,
    "aleph" => :ord, "beth" => :ord,
    "gimel" => :ord, "daleth" => :ord,
    "prime" => :ord, "backprime" => :ord,
    "complement" => :ord,
    "surd" => :ord,
    "top" => :ord, "bot" => :ord,
    "flat" => :ord, "natural" => :ord,
    "sharp" => :ord,
    "diagup" => :ord, "diagdown" => :ord,
    "eth" => :ord,
    "Finv" => :ord, "Game" => :ord,
    "Bbbk" => :ord,
    "triangle" => :ord, "triangledown" => :ord,
    "square" => :ord, "blacksquare" => :ord,
    "lozenge" => :ord, "blacklozenge" => :ord,
    "bigstar" => :ord,
    "clubsuit" => :ord, "diamondsuit" => :ord,
    "heartsuit" => :ord, "spadesuit" => :ord,
    "checkmark" => :ord,
    "vert" => :ord, "Vert" => :ord,
    "backslash" => :ord,
    "S" => :ord, "P" => :ord,
    "copyright" => :ord, "circledR" => :ord,
    "maltese" => :ord,
    "yen" => :ord, "pounds" => :ord,
    "mho" => :ord, "Angstrom" => :ord,
    "digamma" => :ord, "varkappa" => :ord,
    "circledS" => :ord, "degree" => :ord,
    "textdollar" => :ord,
    "vdots" => :ord,  # vertical — ordinary, not inner like \cdots
    # Accents (base is an ordinary atom in terms of spacing)
    "hat" => :ord, "bar" => :ord,
    "vec" => :ord, "dot" => :ord,
    "ddot" => :ord, "tilde" => :ord,
    "widehat" => :ord, "widetilde" => :ord,
    "overline" => :ord, "underline" => :ord,
    # Font-mode selectors: the result is an ordinary atom
    "mathbf" => :ord, "mathrm" => :ord,
    "mathit" => :ord, "mathbb" => :ord,
    "mathcal" => :ord, "mathfrak" => :ord,
    "mathsf" => :ord, "mathtt" => :ord,
    "boldsymbol" => :ord, "text" => :ord,
    "mbox" => :ord,
)

# Spacing amounts in em (18-mu convention: thin = 3 mu, medium = 4 mu, thick = 5 mu).
const _THIN = 3 / 18
const _MEDIUM = 4 / 18
const _THICK = 5 / 18

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

# NKOperator names that use limits placement in Display style (\lim, \max, etc.).
const _LIMITS_OPERATORS = Set{String}(
    [
        "lim", "limsup", "liminf",
        "det", "gcd", "inf", "sup", "max", "min", "Pr",
    ]
)

# Unicode codepoints for all large-operator symbols rendered via NKCommand.
# These are looked up by codepoint (not PS name) so the correct glyph is found.
const _DISPLAY_OP_CODEPOINTS = Dict{String, UInt32}(
    "sum" => 0x2211, "prod" => 0x220F, "coprod" => 0x2210,
    "int" => 0x222B, "iint" => 0x222C, "iiint" => 0x222D,
    "oint" => 0x222E, "oiint" => 0x222F, "oiiint" => 0x2230,
    "iiiint" => 0x2A0C,
    "bigcap" => 0x22C2, "bigcup" => 0x22C3,
    "bigsqcup" => 0x2A06, "bigsqcap" => 0x2A05,
    "bigwedge" => 0x22C0, "bigvee" => 0x22C1,
    "bigoplus" => 0x2A01, "bigotimes" => 0x2A02,
    "bigodot" => 0x2A00, "biguplus" => 0x2A04,
)

# Subset of _DISPLAY_OP_CODEPOINTS that also use limits placement in Display style.
const _LIMITS_OP_COMMANDS = Set{String}(
    [
        "sum", "prod", "coprod",
        "bigcap", "bigcup", "bigsqcup", "bigsqcap",
        "bigwedge", "bigvee",
        "bigoplus", "bigotimes", "bigodot", "biguplus",
    ]
)

# Accent commands that are horizontally extensible (selected from horiz_constructions).
# These share codepoints with their fixed-size counterparts but the layout engine
# selects a glyph variant wide enough to span the base, or assembles one.
const _WIDE_ACCENT_COMMANDS = Set{String}(["\\widehat", "\\widetilde"])

# Fallback codepoints for accents that use combining forms (U+0300–U+036F) rather
# than spacing modifier letters.  Fonts such as Luciole Math carry these glyphs
# at the combining codepoints instead of the spacing modifier codepoints used in
# _ACCENT_CODEPOINTS, so we try these when the primary lookup returns nothing.
const _ACCENT_FALLBACK_CODEPOINTS = Dict{String, UInt32}(
    "\\hat" => 0x0302,   # ̂  COMBINING CIRCUMFLEX ACCENT
    "\\acute" => 0x0301,   # ́  COMBINING ACUTE ACCENT
    "\\tilde" => 0x0303,   # ̃  COMBINING TILDE
    "\\breve" => 0x0306,   # ̆  COMBINING BREVE
    "\\check" => 0x030C,   # ̌  COMBINING CARON
    "\\dot" => 0x0307,   # ̇  COMBINING DOT ABOVE
    "\\mathring" => 0x030A,   # ̊  COMBINING RING ABOVE
    "\\ddot" => 0x0308,   # ̈  COMBINING DIAERESIS
    "\\grave" => 0x0300,   # ̀  COMBINING GRAVE ACCENT
    "\\bar" => 0x0305,   # ̅  COMBINING OVERLINE
)

# Horizontal brace/bracket/paren commands mapped to their PS glyph names in
# horiz_constructions.  Over-variants sit entirely above the baseline; under-
# variants sit entirely below — see the formulae in _layout_horiz_brace!.
const _HORIZ_BRACE_GLYPHS = Dict{String, String}(
    "\\overbrace" => "uni23DE",   # ⏞ TOP CURLY BRACKET
    "\\underbrace" => "uni23DF",   # ⏟ BOTTOM CURLY BRACKET
    "\\overbracket" => "uni23B4",   # ⎴ TOP SQUARE BRACKET
    "\\underbracket" => "uni23B5",   # ⎵ BOTTOM SQUARE BRACKET
    "\\overparen" => "uni23DC",   # ⏜ TOP PARENTHESIS
    "\\underparen" => "uni23DD",   # ⏝ BOTTOM PARENTHESIS
)

# Spacing constants for extensible arrow labels (amsmath xarrow conventions).
const _XARROW_KERN = 0.111   # em gap between arrow body and each label (≈ 2 mu)
const _XARROW_PAD = 0.3     # minimum em padding added on each side of the widest label

# Extensible arrow commands mapped to their Unicode codepoints.
# The layout engine resolves codepoint → uni-name → horiz_constructions key.
const _XARROW_CODEPOINTS = Dict{String, UInt32}(
    "\\xleftarrow" => 0x2190,  # ←
    "\\xrightarrow" => 0x2192,  # →
    "\\xLeftarrow" => 0x21D0,  # ⇐
    "\\xRightarrow" => 0x21D2,  # ⇒
    "\\xleftrightarrow" => 0x2194,  # ↔
    "\\xLeftrightarrow" => 0x21D4,  # ⇔
    "\\xhookleftarrow" => 0x21A9,  # ↩
    "\\xhookrightarrow" => 0x21AA,  # ↪
    "\\xmapsto" => 0x21A6,  # ↦
    "\\xrightharpoondown" => 0x21C1,  # ⇁
    "\\xrightharpoonup" => 0x21C0,  # ⇀
    "\\xleftharpoondown" => 0x21BD,  # ↽
    "\\xleftharpoonup" => 0x21BC,  # ↼
    "\\xrightleftharpoons" => 0x21CC,  # ⇌
    "\\xleftrightharpoons" => 0x21CB,  # ⇋
    "\\xtwoheadrightarrow" => 0x21A0,  # ↠
    "\\xtwoheadleftarrow" => 0x219E,  # ↞
    "\\xlongequal" => 0x003D,  # = (plain equals; extensible via horiz_constructions)
)

# Canonical PostScript name → Unicode codepoint for glyphs that some fonts
# (notably FiraMath) name using the "uni{HHHH}" convention instead of the
# traditional Adobe Glyph List (AGL) name.  Used in two places:
#   1. _construction_key: translate e.g. "parenleft" to the key actually
#      present in vert_constructions for the current font.
#   2. _cmd_glyph: codepoint fallback when the canonical PS name lookup fails.
const _CANONICAL_CODEPOINTS = Dict{String, UInt32}(
    "parenleft" => 0x0028,
    "parenright" => 0x0029,
    "bracketleft" => 0x005B,
    "bracketright" => 0x005D,
    "braceleft" => 0x007B,
    "braceright" => 0x007D,
    "bar" => 0x007C,
    "slash" => 0x002F,
    "backslash" => 0x005C,
    "radical" => 0x221A,
    "dblverticalbar" => 0x2016,
    "angleleft" => 0x27E8,
    "angleright" => 0x27E9,
    "lfloor" => 0x230A,
    "rfloor" => 0x230B,
    "lceil" => 0x2308,
    "rceil" => 0x2309,
)

# Unicode codepoints for symbol commands, resolved by codepoint so the correct
# PS glyph name is used regardless of font-specific naming.  This covers two
# cases: (1) commands where the AGL PS name differs from the LaTeX name (e.g.
# \infty → "infinity", \pm → "plusminus"); (2) Greek letters, which most fonts
# name "alpha", "pi", etc. but some (e.g. FiraMath) name "uni03B1", "uni03C0".
const _SYMBOL_CODEPOINTS = Dict{String, UInt32}(
    # Greek lowercase
    "alpha" => 0x03B1, "beta" => 0x03B2,
    "gamma" => 0x03B3, "delta" => 0x03B4,
    "epsilon" => 0x03F5, "varepsilon" => 0x03B5,
    "zeta" => 0x03B6, "eta" => 0x03B7,
    "theta" => 0x03B8, "vartheta" => 0x03D1,
    "iota" => 0x03B9, "kappa" => 0x03BA,
    "varkappa" => 0x03F0, "lambda" => 0x03BB,
    "mu" => 0x03BC, "nu" => 0x03BD,
    "xi" => 0x03BE, "pi" => 0x03C0,
    "varpi" => 0x03D6, "rho" => 0x03C1,
    "varrho" => 0x03F1, "sigma" => 0x03C3,
    "varsigma" => 0x03C2, "tau" => 0x03C4,
    "upsilon" => 0x03C5, "phi" => 0x03D5,
    "varphi" => 0x03C6, "chi" => 0x03C7,
    "psi" => 0x03C8, "omega" => 0x03C9,
    # Greek uppercase
    "Gamma" => 0x0393, "Delta" => 0x0394,
    "Theta" => 0x0398, "Lambda" => 0x039B,
    "Xi" => 0x039E, "Pi" => 0x03A0,
    "Sigma" => 0x03A3, "Upsilon" => 0x03A5,
    "Phi" => 0x03A6, "Psi" => 0x03A8,
    "Omega" => 0x03A9,
    # Misc math
    "infty" => 0x221E, "partial" => 0x2202,
    "forall" => 0x2200, "exists" => 0x2203,
    "nexists" => 0x2204, "emptyset" => 0x2205,
    "varnothing" => 0x2205, "nabla" => 0x2207,
    "hbar" => 0x210F, "ell" => 0x2113,
    "Re" => 0x211C, "Im" => 0x2111,
    "wp" => 0x2118, "aleph" => 0x2135,
    "beth" => 0x2136, "gimel" => 0x2137,
    "daleth" => 0x2138, "angle" => 0x2220,
    "top" => 0x22A4, "bot" => 0x22A5,
    "prime" => 0x2032, "backprime" => 0x2035,
    "surd" => 0x221A, "complement" => 0x2201,
    "eth" => 0x00F0,
    # Binary operators
    "pm" => 0x00B1, "mp" => 0x2213,
    "times" => 0x00D7, "div" => 0x00F7,
    "cdot" => 0x22C5, "ast" => 0x2217,
    "star" => 0x22C6, "circ" => 0x2218,
    "bullet" => 0x2219, "dagger" => 0x2020,
    "ddagger" => 0x2021, "dag" => 0x2020,
    "ddag" => 0x2021, "cap" => 0x2229,
    "cup" => 0x222A, "sqcap" => 0x2293,
    "sqcup" => 0x2294, "wedge" => 0x2227,
    "land" => 0x2227, "vee" => 0x2228,
    "lor" => 0x2228, "setminus" => 0x2216,
    "smallsetminus" => 0x2216, "oplus" => 0x2295,
    "ominus" => 0x2296, "otimes" => 0x2297,
    "oslash" => 0x2298, "odot" => 0x2299,
    "wr" => 0x2240, "amalg" => 0x2A3F,
    # Relations
    "leq" => 0x2264, "le" => 0x2264,
    "geq" => 0x2265, "ge" => 0x2265,
    "neq" => 0x2260, "ne" => 0x2260,
    "approx" => 0x2248, "equiv" => 0x2261,
    "sim" => 0x223C, "simeq" => 0x2243,
    "cong" => 0x2245, "propto" => 0x221D,
    "perp" => 0x22A5, "parallel" => 0x2225,
    "mid" => 0x2223, "nmid" => 0x2224,
    "subset" => 0x2282, "supset" => 0x2283,
    "subseteq" => 0x2286, "supseteq" => 0x2287,
    "sqsubseteq" => 0x2291, "sqsupseteq" => 0x2292,
    "in" => 0x2208, "notin" => 0x2209,
    "ni" => 0x220B, "owns" => 0x220B,
    "prec" => 0x227A, "succ" => 0x227B,
    "preceq" => 0x2AAF, "succeq" => 0x2AB0,
    "ll" => 0x226A, "gg" => 0x226B,
    "vdash" => 0x22A2, "dashv" => 0x22A3,
    "models" => 0x22A8, "smile" => 0x2323,
    "frown" => 0x2322, "asymp" => 0x224D,
    # Arrows
    "to" => 0x2192,
    "rightarrow" => 0x2192, "leftarrow" => 0x2190,
    "Rightarrow" => 0x21D2, "Leftarrow" => 0x21D0,
    "leftrightarrow" => 0x2194, "Leftrightarrow" => 0x21D4,
    "mapsto" => 0x21A6, "longmapsto" => 0x27FC,
    "longrightarrow" => 0x27F6, "longleftarrow" => 0x27F5,
    "Longrightarrow" => 0x27F9, "Longleftarrow" => 0x27F8,
    "hookrightarrow" => 0x21AA, "hookleftarrow" => 0x21A9,
    "uparrow" => 0x2191, "downarrow" => 0x2193,
    "Uparrow" => 0x21D1, "Downarrow" => 0x21D3,
    "updownarrow" => 0x2195, "Updownarrow" => 0x21D5,
    "nearrow" => 0x2197, "searrow" => 0x2198,
    "swarrow" => 0x2199, "nwarrow" => 0x2196,
    "iff" => 0x21D4, "implies" => 0x27F9,
    # Ellipses
    "ldots" => 0x2026, "cdots" => 0x22EF,
    "vdots" => 0x22EE, "ddots" => 0x22F1,
    "dots" => 0x2026,
    # Musical / misc
    "sharp" => 0x266F, "flat" => 0x266D,
    "natural" => 0x266E,
    # Extended binary operators (AMS)
    "boxplus" => 0x229E, "boxminus" => 0x229F,
    "boxtimes" => 0x22A0, "boxdot" => 0x22A1,
    "ltimes" => 0x22C9, "rtimes" => 0x22CA,
    "leftthreetimes" => 0x22CB, "rightthreetimes" => 0x22CC,
    "curlywedge" => 0x22CF, "curlyvee" => 0x22CE,
    "barwedge" => 0x22BC, "intercal" => 0x22BA,
    "dotplus" => 0x2214, "doublebarwedge" => 0x2A5E,
    "divideontimes" => 0x22C7, "triangleleft" => 0x25C3,
    "triangleright" => 0x25B9,
    # Extended relations (AMS)
    "bowtie" => 0x22C8, "lll" => 0x22D8,
    "ggg" => 0x22D9, "leqq" => 0x2266,
    "geqq" => 0x2267, "leqslant" => 0x2A7D,
    "geqslant" => 0x2A7E, "eqslantless" => 0x2A95,
    "eqslantgtr" => 0x2A96, "lesssim" => 0x2272,
    "gtrsim" => 0x2273, "lessapprox" => 0x2A85,
    "gtrapprox" => 0x2A86, "approxeq" => 0x224A,
    "lessdot" => 0x22D6, "gtrdot" => 0x22D7,
    "lessgtr" => 0x2276, "gtrless" => 0x2277,
    "lesseqgtr" => 0x22DA, "gtreqless" => 0x22DB,
    "lesseqqgtr" => 0x2A8B, "gtreqqless" => 0x2A8C,
    "doteqdot" => 0x2251, "risingdotseq" => 0x2253,
    "fallingdotseq" => 0x2252, "backsim" => 0x223D,
    "backsimeq" => 0x22CD, "eqcirc" => 0x2256,
    "circeq" => 0x2257, "triangleq" => 0x225C,
    "bumpeq" => 0x224F, "Bumpeq" => 0x224E,
    "thicksim" => 0x223C, "thickapprox" => 0x2248,
    "subseteqq" => 0x2AC5, "supseteqq" => 0x2AC6,
    "Subset" => 0x22D0, "Supset" => 0x22D1,
    "sqsubset" => 0x228F, "sqsupset" => 0x2290,
    "preccurlyeq" => 0x227C, "succcurlyeq" => 0x227D,
    "curlyeqprec" => 0x22DE, "curlyeqsucc" => 0x22DF,
    "trianglelefteq" => 0x22B4, "trianglerighteq" => 0x22B5,
    "vartriangleleft" => 0x22B2, "vartriangleright" => 0x22B3,
    "blacktriangleleft" => 0x25C0, "blacktriangleright" => 0x25B6,
    "between" => 0x226C, "pitchfork" => 0x22D4,
    "therefore" => 0x2234, "because" => 0x2235,
    "shortmid" => 0x2223, "shortparallel" => 0x2225,
    "backepsilon" => 0x220D, "varpropto" => 0x221D,
    "longleftrightarrow" => 0x27F7, "Longleftrightarrow" => 0x27FA,
    # Negated relations with single codepoints
    "nleq" => 0x2270, "ngeq" => 0x2271,
    "nless" => 0x226E, "ngtr" => 0x226F,
    "nsim" => 0x2241, "nparallel" => 0x2226,
    "nsubseteq" => 0x2288, "nsupseteq" => 0x2289,
    "subsetneq" => 0x228A, "supsetneq" => 0x228B,
    "lneq" => 0x2A87, "gneq" => 0x2A88,
    "lnsim" => 0x22E6, "gnsim" => 0x22E7,
    "nprec" => 0x2280, "nsucc" => 0x2281,
    "npreceq" => 0x22E0, "nsucceq" => 0x22E1,
    # Ordinary symbols (AMS)
    "measuredangle" => 0x2221, "sphericalangle" => 0x2222,
    "imath" => 0x0131, "jmath" => 0x0237,
    "hslash" => 0x210F, "triangle" => 0x25B3,
    "triangledown" => 0x25BD, "square" => 0x25A1,
    "blacksquare" => 0x25A0, "lozenge" => 0x25CA,
    "blacklozenge" => 0x29EB, "bigstar" => 0x2605,
    "clubsuit" => 0x2663, "diamondsuit" => 0x2662,
    "heartsuit" => 0x2661, "spadesuit" => 0x2660,
    "checkmark" => 0x2713, "S" => 0x00A7,
    "P" => 0x00B6, "copyright" => 0x00A9,
    "circledR" => 0x00AE, "circledS" => 0x24C8,
    "maltese" => 0x2720, "yen" => 0x00A5,
    "pounds" => 0x00A3, "mho" => 0x2127,
    "Angstrom" => 0x212B, "digamma" => 0x03DD,
    "Finv" => 0x2132, "Game" => 0x2141,
    "degree" => 0x00B0, "textdollar" => 0x0024,
    "diagup" => 0x2571, "diagdown" => 0x2572,
    "doteq" => 0x2250, "Join" => 0x2A1D,
    "Bbbk" => 0x0001D55C, "backslash" => 0x005C,
    # Delimiter aliases
    "lvert" => 0x007C, "rvert" => 0x007C,
    "lVert" => 0x2016, "rVert" => 0x2016,
    "lgroup" => 0x27EE, "rgroup" => 0x27EF,
    "lmoustache" => 0x23B0, "rmoustache" => 0x23B1,
    "llbracket" => 0x27E6, "rrbracket" => 0x27E7,
    # Delimiters (used in \big* manual sizing, where the name is the bare symbol)
    "langle" => 0x27E8, "rangle" => 0x27E9,
    "lfloor" => 0x230A, "rfloor" => 0x230B,
    "lceil" => 0x2308, "rceil" => 0x2309,
    "vert" => 0x007C, "Vert" => 0x2016,
    # Punctuation
    "colon" => 0x003A, "cdotp" => 0x22C5,
    "ldotp" => 0x002E,
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
        cmd = node.value
        name = startswith(cmd, "\\") ? cmd[2:end] : cmd
        return get(_CMD_ATOM_CLASS, name, :ord)
    elseif k === NKOperator
        return :op
    elseif k === NKFrac || k === NKGenfrac || k === NKDelimited || k === NKHorizBrace || k === NKMatrix
        return :inner
    elseif k === NKSqrt || k === NKAccent || k === NKOverUnder || k === NKText
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
    elseif k === NKStyleOverride || k === NKSizing
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from wrapped body
    elseif k === NKXArrow
        return :rel   # extensible arrows are relation atoms
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
# Always resolve by codepoint: the Unicode cmap yields the math-italic form for
# letters, whereas glyph_metrics(family, "x") returns the upright roman slot.
function _char_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph, Nothing}
    if ctx.mode === :math
        ch = get(_MATH_CHAR_REMAP, ch, ch)
    end
    cp = UInt32(ch)
    m = glyph_metrics_by_codepoint(ctx.family, cp)
    m === nothing && return nothing
    ps = glyph_name_by_codepoint(ctx.family, cp)
    return Glyph(
        isempty(ps) ? string(ch) : ps, :math,
        m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
end

# Return an upright Glyph for a character, or nothing if not in the font.
# Uses the regular font slot when present (both metrics and PS name come from
# the same font so the renderer can locate the glyph correctly); falls back to
# the math font when no regular font is configured.
function _upright_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph, Nothing}
    family = ctx.family
    if family.regular !== nothing
        m = glyph_metrics_upright(family, ch)
        m === nothing && return nothing
        ps = glyph_name_by_codepoint(family.regular, UInt32(ch))
        name = isempty(ps) ? string(ch) : ps
        return Glyph(
            name, :regular, m.advance_width, m.left_side_bearing,
            m.x_min, m.y_min, m.x_max, m.y_max
        )
    else
        m = glyph_metrics_by_codepoint(family, UInt32(ch))
        m === nothing && return nothing
        ps = glyph_name_by_codepoint(family.math, UInt32(ch))
        name = isempty(ps) ? string(ch) : ps
        return Glyph(
            name, :math, m.advance_width, m.left_side_bearing,
            m.x_min, m.y_min, m.x_max, m.y_max
        )
    end
end

# Return a Glyph for a PostScript glyph name, or nothing if not in the font.
# Used exclusively for font-internal names from the MATH table (size variants,
# assembly parts, radical/delimiter base glyphs) — not for TeX command names.
# Falls back via _CANONICAL_CODEPOINTS for AGL names that fail in fonts using
# Unicode-style PS names (e.g. FiraMath "uni0028" vs AGL "parenleft").
# The returned Glyph carries the font's own PS name so renderers can locate it.
function _cmd_glyph(ctx::_LayoutCtx, name::String)::Union{Glyph, Nothing}
    m = glyph_metrics(ctx.family, name)
    m !== nothing && return Glyph(
        name, :math, m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
    # Fallback 1: AGL name with a known codepoint (e.g. "parenleft" in a font
    # that uses "uni0028").
    cp = get(_CANONICAL_CODEPOINTS, name, nothing)
    # Fallback 2: "uni{HHHH}" name (e.g. "uni23DE") in a font that uses the AGL
    # name ("overbrace").  Parse the codepoint and resolve via the font's own map.
    if cp === nothing
        m2 = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
        m2 !== nothing && (cp = parse(UInt32, m2.captures[1], base = 16))
    end
    cp === nothing && return nothing
    m2 = glyph_metrics_by_codepoint(ctx.family, cp)
    m2 === nothing && return nothing
    ps = glyph_name_by_codepoint(ctx.family, cp)
    actual = isempty(ps) ? name : ps
    return Glyph(
        actual, :math, m2.advance_width, m2.left_side_bearing,
        m2.x_min, m2.y_min, m2.x_max, m2.y_max
    )
end

# Return the key under which a canonically-named glyph is stored in
# vert_constructions.  Fonts that use Unicode-style PS names (e.g. FiraMath)
# store the entry under "uni0028" rather than "parenleft"; we translate by
# resolving the codepoint to the font's own PS name.
function _construction_key(ctx::_LayoutCtx, canonical_name::String)::String
    haskey(ctx.vert_constructions, canonical_name) && return canonical_name
    cp = get(_CANONICAL_CODEPOINTS, canonical_name, nothing)
    cp === nothing && return canonical_name
    ps = glyph_name_by_codepoint(ctx.family, cp)
    !isempty(ps) && haskey(ctx.vert_constructions, ps) && return ps
    return canonical_name
end

# Return the key under which a Unicode-named brace glyph is stored in
# horiz_constructions.  Most fonts use "uni23DE" etc., but some (e.g. Luciole)
# use AGL names ("overbrace").  Resolve via the font's own codepoint→PS mapping.
function _horiz_construction_key(ctx::_LayoutCtx, uni_name::String)::String
    haskey(ctx.horiz_constructions, uni_name) && return uni_name
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", uni_name)
    m === nothing && return uni_name
    cp = parse(UInt32, m.captures[1], base = 16)
    ps = glyph_name_by_codepoint(ctx.family, cp)
    !isempty(ps) && haskey(ctx.horiz_constructions, ps) && return ps
    return uni_name
end

# Return a Glyph for character `ch` under the given font variant (Option C):
#   1. Try Unicode math-variant codepoint in the math font (covers mathbf, mathbb, etc.).
#   2. For :mathrm, fall through to the upright glyph lookup (regular font or math codepoint).
#   3. Fall through to the default character glyph (italic math form).
function _variant_glyph(ctx::_LayoutCtx, variant::Symbol, ch::Char)::Union{Glyph, Nothing}
    cp = _math_variant_codepoint(variant, ch)
    if cp !== nothing
        m = glyph_metrics_by_codepoint(ctx.family, cp)
        if m !== nothing
            ps = glyph_name_by_codepoint(ctx.family, cp)
            return Glyph(
                isempty(ps) ? string(Char(cp)) : ps, :math,
                m.advance_width, m.left_side_bearing,
                m.x_min, m.y_min, m.x_max, m.y_max
            )
        end
    end
    return _char_glyph(ctx, ch)
end

# Copy every element of `src` into `dst`, translating each box by (dx, dy).
# Used throughout the layout engine to splice a scratch sub-layout (laid out
# at origin (0,0) or some local origin) into the parent's coordinate system.
function _emit_shifted!(
        dst::Vector{LayoutBox}, src::Vector{LayoutBox},
        dx::Float64, dy::Float64
    )
    for b in src
        push!(dst, LayoutBox(b.element, b.x + dx, b.y + dy, b.scale))
    end
    return nothing
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
        h += parts[i].full_advance - _gap_min_overlap(parts[i - 1], parts[i], min_conn)
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
    upm = ctx.upm
    mc = ctx.mc
    min_conn = ctx.min_connector_overlap

    n = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    # Overlap for each gap between adjacent parts (minimum overlap, so the
    # assembly is as tall as the required extent).
    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in 1:length(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
    end

    # Total assembly height in design units.
    total_du = Float64(parts[1].full_advance)
    for i in 1:length(overlaps)
        total_du += parts[i + 1].full_advance - overlaps[i]
    end

    # Derive ink bounds from first/last glyph metrics.  When assembly parts have
    # y_min ≠ 0 (e.g. STIX Two bar: y_min=-234, y_max=706, full_advance=941),
    # centering by total_du/2 misplaces the stack.  Using actual ink bounds
    # centres correctly on the math axis regardless of font design conventions.
    g_first = _cmd_glyph(ctx, parts[1].glyph_name)
    g_last = _cmd_glyph(ctx, parts[end].glyph_name)
    ink_bot_du = (g_first !== nothing) ? Float64(g_first.y_min) : 0.0
    cursor_last = total_du - Float64(parts[end].full_advance)
    ink_top_du = cursor_last + ((g_last !== nothing) ? Float64(g_last.y_max) : Float64(parts[end].full_advance))
    ink_center_du = (ink_bot_du + ink_top_du) / 2.0
    axis_em = y0 + mc.axis_height / upm * scale
    asm_bot_em = axis_em - ink_center_du / upm * scale

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
# radical assemblies are top-anchored.  Returns the horizontal offset at which
# the radicand should start.
@inline _radical_cover_du(g::Glyph) = Float64(g.y_max - g.y_min)
# TeX packs the radical delimiter and the overbar/radicand into an hlist, so the
# body starts after the delimiter box width (advance width), not after the
# radical ink's right edge. Using x_max makes larger radical variants drift
# rightward in deep nesting because their ink overhang exceeds their advance.
@inline _radical_body_offset_du(g::Glyph) = Float64(g.advance_width)

function _assembly_total_du(parts::Vector{GlyphAssemblyPart}, overlaps::Vector{Int})::Float64
    isempty(parts) && return 0.0
    total_du = Float64(parts[1].full_advance)
    for i in eachindex(overlaps)
        total_du += parts[i + 1].full_advance - overlaps[i]
    end
    return total_du
end

function _layout_radical_assembly!(
        asm::GlyphAssembly,
        ctx::_LayoutCtx,
        required_du::Float64,
        rule_top_em::Float64,
        x0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    upm = ctx.upm
    min_conn = ctx.min_connector_overlap

    n = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in eachindex(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
    end

    total_du = _assembly_total_du(parts, overlaps)

    # All radical assembly parts have y_min=0, y_max=full_advance.
    # The top of the top cap is at asm_bot + total_du; pin it to rule_top_em.
    asm_bot_em = rule_top_em - total_du / upm * scale

    max_body_offset_du = 0.0
    cursor_du = 0.0
    for i in eachindex(parts)
        p = parts[i]
        g = _cmd_glyph(ctx, p.glyph_name)
        if g !== nothing
            push!(boxes, LayoutBox(g, x0, asm_bot_em + cursor_du / upm * scale, scale))
            max_body_offset_du = max(max_body_offset_du, _radical_body_offset_du(g))
        end
        i <= length(overlaps) && (cursor_du += Float64(p.full_advance) - overlaps[i])
    end

    return max_body_offset_du / upm * scale
end

# Return the GlyphMetrics for the smallest radical variant that covers
# `required_du` design units (same selection logic as `_layout_radical!`),
# or `nothing` if no variant information is available.  Does NOT push to boxes.
function _peek_radical_glyph(ctx::_LayoutCtx, required_du::Float64)::Union{Glyph, Nothing}
    rkey = _construction_key(ctx, "radical")
    if haskey(ctx.vert_constructions, rkey)
        vc = ctx.vert_constructions[rkey]
        for v in vc.variants
            Float64(v.advance) >= required_du && return _cmd_glyph(ctx, v.glyph_name)
        end
        !isempty(vc.variants) && return _cmd_glyph(ctx, last(vc.variants).glyph_name)
    end
    return _cmd_glyph(ctx, "radical")
end

function _peek_radical_cover_du(ctx::_LayoutCtx, required_du::Float64)::Float64
    rkey = _construction_key(ctx, "radical")
    if haskey(ctx.vert_constructions, rkey)
        vc = ctx.vert_constructions[rkey]
        for v in vc.variants
            if Float64(v.advance) >= required_du
                g = _cmd_glyph(ctx, v.glyph_name)
                return g === nothing ? 0.0 : _radical_cover_du(g)
            end
        end
        if vc.assembly !== nothing
            min_conn = ctx.min_connector_overlap
            n = _min_extender_reps(vc.assembly.parts, required_du, min_conn)
            parts = _expand_assembly_parts(vc.assembly.parts, n)
            overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
            for i in eachindex(overlaps)
                overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
            end
            return _assembly_total_du(parts, overlaps)
        end
    end
    g = _peek_radical_glyph(ctx, required_du)
    return g === nothing ? 0.0 : _radical_cover_du(g)
end

# Choose and place a radical glyph (or assembly) whose top ink aligns with
# `rule_top_em`.  `required_du` is the minimum vertical span (design units)
# the radical must cover.
# Returns the horizontal offset at which the radicand should start.
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
        push!(boxes, LayoutBox(g, x0, rule_top_em - g.y_max / upm * scale, scale))
        return _radical_body_offset_du(g) / upm * scale
    end

    rkey = _construction_key(ctx, "radical")
    if !haskey(ctx.vert_constructions, rkey)
        return _place_variant("radical")
    end

    vc = ctx.vert_constructions[rkey]

    for v in vc.variants
        Float64(v.advance) >= required_du && return _place_variant(v.glyph_name)
    end

    vc.assembly !== nothing && return _layout_radical_assembly!(
        vc.assembly, ctx, required_du, rule_top_em, x0, scale, boxes
    )

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
    mc = ctx.mc

    function _place_glyph(name::String)::Float64
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
        y_del = y0 + (mc.axis_height / upm - glyph_center) * scale
        push!(boxes, LayoutBox(g, x0, y_del, scale))
        return g.advance_width / upm * scale
    end

    dkey = _construction_key(ctx, glyph_name)
    if !haskey(ctx.vert_constructions, dkey)
        return _place_glyph(glyph_name)
    end

    vc = ctx.vert_constructions[dkey]

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

# Place a horizontally extensible accent glyph centred over a base of width
# `base_w_em` (em units) at vertical position `accent_y`.  Selects the smallest
# pre-built variant whose advance width covers the base; if none exists, assembles
# the glyph from parts using the same helpers used for vertical assemblies.
# Falls back to the largest variant (or the base glyph) if the assembly is empty.
function _layout_wide_accent!(
        ctx::_LayoutCtx,
        accent_ps::String,
        base_w_em::Float64,
        accent_y::Float64,
        x0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Nothing
    upm = ctx.upm
    min_conn = ctx.min_connector_overlap
    required_du = base_w_em / scale * upm   # convert em to design units

    hc = get(ctx.horiz_constructions, accent_ps, nothing)
    hc === nothing && return nothing

    # Helper: centre a named glyph over the base and push it to boxes.
    # Uses ink midpoint (x_min+x_max)/2 rather than advance_width/2: this correctly
    # handles zero-advance combining characters (e.g. circumflexcmb, adv_w=0) whose
    # ink lies at negative x values rather than spanning [0, advance_width].
    function _place(name::String)
        g = _cmd_glyph(ctx, name)
        g === nothing && return
        ink_center = (g.x_min + g.x_max) / (2.0 * upm) * scale
        return push!(boxes, LayoutBox(g, x0 + base_w_em / 2 - ink_center, accent_y, scale))
    end

    # Try pre-built variants first (smallest that covers the base).
    for v in hc.variants
        if Float64(v.advance) >= required_du
            _place(v.glyph_name)
            return nothing
        end
    end

    # Try extensible assembly.
    if hc.assembly !== nothing
        asm = hc.assembly
        n = _min_extender_reps(asm.parts, required_du, min_conn)
        parts = _expand_assembly_parts(asm.parts, n)
        if !isempty(parts)
            # Compute overlap for each adjacent pair.
            overlaps = [
                _gap_min_overlap(parts[i], parts[i + 1], min_conn)
                    for i in 1:(length(parts) - 1)
            ]
            # Total width of the assembly in design units.
            total_du = Float64(parts[1].full_advance) +
                sum(
                Float64(parts[i + 1].full_advance) - overlaps[i]
                    for i in eachindex(overlaps); init = 0.0
            )
            total_w = total_du / upm * scale
            # Centre the assembly over the base.
            ax = x0 + (base_w_em - total_w) / 2
            cursor_du = 0.0
            for i in eachindex(parts)
                p = parts[i]
                g = _cmd_glyph(ctx, p.glyph_name)
                g !== nothing &&
                    push!(boxes, LayoutBox(g, ax + cursor_du / upm * scale, accent_y, scale))
                if i <= length(overlaps)
                    cursor_du += Float64(p.full_advance) - overlaps[i]
                end
            end
            return nothing
        end
    end

    # Fall back to the largest pre-built variant, or the base glyph.
    _place(isempty(hc.variants) ? accent_ps : last(hc.variants).glyph_name)
    return nothing
end

# Lay out a horizontal brace node with optional script note.
#
# KaTeX horizBrace.ts algorithm:
#   - Body at current style; brace stretched horizontally to body width.
#   - Gap = 0.1 em between body ink edge and brace ink edge (body_gap).
#   - Gap = 0.2 em between brace ink edge and note ink edge (note_gap).
#   - Note (primary script) is centred over max(body_w, note_w).
#   - Secondary script (opposite side) is placed as a normal side script.
#
# sub_node / sup_node: subscript / superscript children (nothing if absent).
function _layout_horiz_brace!(
        brace_node::Node,
        sub_node::Union{Node, Nothing},
        sup_node::Union{Node, Nothing},
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    upm = ctx.upm
    mc = ctx.mc
    is_over = startswith(brace_node.value, "\\over")
    glyph_ps = _horiz_construction_key(ctx, _HORIZ_BRACE_GLYPHS[brace_node.value])

    # Primary note lives on the brace side; secondary note is the opposite.
    primary_node = is_over ? sup_node : sub_node
    secondary_node = is_over ? sub_node : sup_node

    # Body at current style.
    tmp_body = LayoutBox[]
    body_w = _layout_node!(brace_node.children[1], ctx, style, 0.0, 0.0, scale, tmp_body)
    body_top = _boxes_top(tmp_body, upm)
    body_bot = _boxes_bottom(tmp_body, upm)

    # Primary note at the script style of the brace side.
    pri_s = is_over ? sup_style(style) : sub_style(style)
    pri_scale = size_scale(pri_s, mc)
    tmp_pri = LayoutBox[]
    pri_w = 0.0
    if primary_node !== nothing
        pri_w = _layout_node!(primary_node, ctx, pri_s, 0.0, 0.0, pri_scale, tmp_pri)
    end

    # Total span: body and note are both centred over max(body_w, note_w).
    total_w = max(body_w, pri_w)
    Δbody = (total_w - body_w) / 2

    # Reference glyph for brace ink-extent calculation: find the same variant
    # that _layout_wide_accent! would select (smallest covering body_w or largest).
    hc = get(ctx.horiz_constructions, glyph_ps, nothing)
    req_du = body_w / scale * upm
    sel_name = glyph_ps
    if hc !== nothing
        for v in hc.variants
            Float64(v.advance) >= req_du && (sel_name = v.glyph_name; break)
        end
        sel_name == glyph_ps && !isempty(hc.variants) &&
            (sel_name = last(hc.variants).glyph_name)
    end
    g_ref = _cmd_glyph(ctx, sel_name)

    # Brace baseline y: place the ink edge of the brace at body_edge + body_gap.
    # For over: bottom ink of brace = body_top + body_gap
    #           brace_y + y_min/upm*scale = y0 + body_top + body_gap
    # For under: top ink of brace = body_bot - body_gap
    #           brace_y + y_max/upm*scale = y0 + body_bot - body_gap
    body_gap = 0.1 * scale
    if g_ref !== nothing
        brace_y = is_over ?
            y0 + body_top + body_gap - Float64(g_ref.y_min) / upm * scale :
            y0 + body_bot - body_gap - Float64(g_ref.y_max) / upm * scale
        brace_top = brace_y + Float64(g_ref.y_max) / upm * scale
        brace_bot = brace_y + Float64(g_ref.y_min) / upm * scale
    else
        # No glyph metrics available: assume the brace's baseline coincides with
        # the body-side ink edge (y_min=0 for over, y_max=0 for under) and pad by
        # 0.25 em on the opposite side as a placeholder for the missing glyph.
        brace_y = is_over ? y0 + body_top + body_gap : y0 + body_bot - body_gap
        brace_top = is_over ? brace_y + 0.25 * scale : brace_y
        brace_bot = is_over ? brace_y : brace_y - 0.25 * scale
    end

    # Place body (centred over total_w at y0).
    _emit_shifted!(boxes, tmp_body, x0 + Δbody, y0)

    # Place brace (centred over body_w; extension fills body width).
    _layout_wide_accent!(ctx, glyph_ps, body_w, brace_y, x0 + Δbody, scale, boxes)

    # Place primary note centred over total_w.
    # Gap = 0.2 em between brace ink edge and note ink edge (KaTeX horizBrace.ts).
    note_gap = 0.2 * scale
    if !isempty(tmp_pri)
        Δpri = (total_w - pri_w) / 2
        note_y = is_over ?
            brace_top + note_gap - _boxes_bottom(tmp_pri, upm) :
            brace_bot - note_gap - _boxes_top(tmp_pri, upm)
        _emit_shifted!(boxes, tmp_pri, x0 + Δpri, note_y)
    end

    # Secondary note: placed as a normal side script to the right of the stack.
    if secondary_node !== nothing
        sec_s = is_over ? sub_style(style) : sup_style(style)
        sec_scale = size_scale(sec_s, mc)
        tmp_sec = LayoutBox[]
        sec_w = _layout_node!(secondary_node, ctx, sec_s, 0.0, 0.0, sec_scale, tmp_sec)
        s = scale / upm
        script_x = x0 + total_w
        if is_over
            y_sub = min(
                y0 - mc.subscript_shift_down * s,
                y0 + body_bot - mc.subscript_baseline_drop_min * s
            )
            y_sub = min(y_sub, y0 - _boxes_top(tmp_sec, upm) + mc.subscript_top_max * s)
            _emit_shifted!(boxes, tmp_sec, script_x, y_sub)
        else
            min_sup = is_cramped(style) ?
                mc.superscript_shift_up_cramped * s : mc.superscript_shift_up * s
            y_sup = max(
                y0 + min_sup,
                y0 + body_top - mc.superscript_baseline_drop_max * s
            )
            y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(tmp_sec, upm))
            _emit_shifted!(boxes, tmp_sec, script_x, y_sup)
        end
        total_w += sec_w + mc.space_after_script * s
    end

    return total_w
end

# ── Limits-placement helpers ─────────────────────────────────────────────────

# Unwrap NKLimitsOverride to expose the actual operator node for layout.
_limits_base(node::Node) = node.kind === NKLimitsOverride ? node.children[1] : node

# Return the italic correction (in em units) of the first Glyph in `boxes`, or 0.0.
# Used to shift limits of slanted operators (e.g. ∫) so they track the diagonal stroke.
# Per the OpenType MATH spec and KaTeX, limits are offset by ±½ IC: subscripts shift
# left and superscripts shift right.
function _base_italic_correction_em(
        boxes::Vector{LayoutBox}, ctx::_LayoutCtx,
        scale::Float64
    )::Float64
    for b in boxes
        b.element isa Glyph || continue
        ic = get(ctx.italic_corrections, b.element.glyph_name, 0)
        return ic * scale / ctx.upm
    end
    return 0.0
end

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

# Return true when `node` renders as a single character glyph (KaTeX isCharacterBox).
# TeX Rules 18a–e apply supDrop/subDrop clamps only to non-character bases such as
# fractions, delimited expressions, and multi-child groups.
function _is_char_box(node::Node)::Bool
    n = node.kind === NKLimitsOverride ? node.children[1] : node
    n.kind === NKChar && return true
    n.kind === NKOperator && return false  # named operators (e.g. \sin) are not char boxes
    n.kind === NKCommand && return !_is_large_op(n)  # large ops are not char boxes
    # NKFontSwitch is constructed with exactly one body child by the parser, so the
    # recursion is unconditional.
    n.kind === NKFontSwitch && return _is_char_box(n.children[1])
    return false
end

# ── Recursive layout ──────────────────────────────────────────────────────────

# Atom classes that left-cancel a following mbin atom (Rule 5).
# A mbin at the start of a list or immediately after one of these is demoted to mord.
const _BIN_LEFT_CANCEL = (:bin, :open, :rel, :op, :punct)
# Atom classes that right-cancel a preceding mbin atom (Rule 6).
# A mbin immediately before one of these is demoted to mord.
const _BIN_RIGHT_CANCEL = (:rel, :close, :punct)

# Lay out a list of child nodes with inter-atom auto-spacing in math mode.
# Returns the total advance width.  Used by NKSequence, NKGroup, and the inner
# content loop of NKDelimited so spacing is consistent in all three contexts.
#
# Applies TeX Rules 5 & 6 (binary atom reclassification) before computing spacing:
# a mbin atom is demoted to mord when the surrounding context would produce
# nonsensical spacing (e.g. a leading or trailing binary operator).
function _layout_children!(
        children,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    isempty(children) && return 0.0

    # Collect into an indexable array and compute initial atom classes.
    nodes = children isa Vector ? children : collect(children)
    n = length(nodes)
    classes = Vector{Symbol}(undef, n)
    for i in 1:n
        classes[i] = _atom_class(nodes[i])
    end

    # Rule 5: mbin → mord when left-context is start-of-list, bin, open, rel, op, or punct.
    # Neutral (space) nodes are transparent: they do not update the context.
    prev_nc = :nothing
    for i in 1:n
        cls = classes[i]
        cls === :neutral && continue
        if cls === :bin && (prev_nc === :nothing || prev_nc ∈ _BIN_LEFT_CANCEL)
            classes[i] = :ord
        end
        prev_nc = classes[i]
    end

    # Rule 6: mbin → mord when right-context is rel, close, or punct.
    next_nc = :nothing
    for i in n:-1:1
        cls = classes[i]
        cls === :neutral && continue
        if cls === :bin && next_nc ∈ _BIN_RIGHT_CANCEL
            classes[i] = :ord
        end
        next_nc = classes[i]
    end

    # Emit nodes with inter-atom spacing using the reclassified classes.
    cursor = x0
    prev_class = :nothing
    for i in 1:n
        cls = classes[i]
        if cls === :neutral
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_class = :nothing
        else
            if ctx.mode === :math && prev_class !== :nothing
                sp = _interatom_space(prev_class, cls, style) * scale
                if sp > 0.0
                    push!(boxes, LayoutBox(Space(sp), cursor, y0, scale))
                    cursor += sp
                end
            end
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_class = cls
        end
    end
    return cursor - x0
end

# Inter-column and inter-row spacing constants for matrix environments.
# _MATRIX_COLSEP is the margin added on each side of a column (total gap between
# adjacent cells = 2 × _MATRIX_COLSEP), matching LaTeX's \arraycolsep ≈ 5 mu.
# _MATRIX_ROWGAP is extra baseline-to-baseline clearance added between rows.
const _MATRIX_COLSEP = 5 / 18   # 5 mu per side, matches LaTeX \arraycolsep
const _MATRIX_ROWGAP = 3 / 18   # extra row gap in em
const _MATRIX_DOUBLERULESEP = 2 / 18   # gap between two adjacent rules (≈ TeX \doublerulesep = 2pt)

# Parse a column-spec string (e.g. "|l||c|r|") into per-column alignment symbols
# and a vertical-rule count vector.
# col_aligns[c] ∈ {:l, :c, :r} for each column c = 1..ncol.
# vrule[c] = number of rules immediately before column c (c=1..ncol),
# vrule[ncol+1] = number of rules after the last column.
# '||' → vrule count 2 (double rule with _MATRIX_DOUBLERULESEP gap).
# Unknown tokens (e.g. @{}, p{width}) are silently ignored.
function _parse_colspec(spec::AbstractString)::Tuple{Vector{Symbol}, Vector{Int}}
    col_aligns = Symbol[]
    vrule = Int[]
    pending_rule = 0
    for ch in spec
        if ch === 'l' || ch === 'c' || ch === 'r'
            push!(vrule, pending_rule)
            push!(col_aligns, ch === 'l' ? :l : ch === 'c' ? :c : :r)
            pending_rule = 0
        elseif ch === '|'
            pending_rule += 1
        end
    end
    push!(vrule, pending_rule)   # possible rule(s) after the last column
    return col_aligns, vrule
end

# Lay out a matrix/array environment (NKMatrix node).
# Two-pass algorithm: measure all cells first, then place on a rectangular grid.
# Cells are laid out in Text style (even in Display), centred on the math axis.
# Returns the total horizontal advance in em units.
function _layout_matrix!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    # Decode value = "env_name\x00nrow\x00colspec".
    parts = split(node.value, '\x00'; limit = 3)
    length(parts) < 3 && return 0.0
    env_name = parts[1]
    nrow = parse(Int, parts[2])
    col_aligns, vrule = _parse_colspec(parts[3])
    ncol = length(col_aligns)
    (nrow == 0 || ncol == 0) && return 0.0

    info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
    upm = ctx.upm
    mc = ctx.mc

    # Cells are typeset in Text style (following TeX's rule for array environments).
    cell_style = is_cramped(style) ? CrampedText : Text

    # Scale factor for this environment (smallmatrix uses 0.9).
    cell_scale = scale * info.scale

    # ── First pass: lay out each cell into a scratch buffer, record metrics ──
    cell_boxes = [LayoutBox[] for _ in 1:nrow, _ in 1:ncol]
    cell_widths = zeros(Float64, nrow, ncol)
    cell_heights = zeros(Float64, nrow, ncol)   # max ink above baseline
    cell_depths = zeros(Float64, nrow, ncol)   # max ink below baseline (positive)

    for r in 1:nrow, c in 1:ncol
        ci = (r - 1) * ncol + c
        ci > length(node.children) && continue
        tmp = LayoutBox[]
        w = _layout_node!(node.children[ci], ctx, cell_style, 0.0, 0.0, cell_scale, tmp)
        cell_boxes[r, c] = tmp
        cell_widths[r, c] = w
        cell_heights[r, c] = max(0.0, _boxes_top(tmp, upm))
        cell_depths[r, c] = max(0.0, -_boxes_bottom(tmp, upm))
    end

    # ── Compute per-column widths and per-row extents ──
    col_widths = [maximum(cell_widths[:, c]; init = 0.0) for c in 1:ncol]
    row_heights = [maximum(cell_heights[r, :]; init = 0.0) for r in 1:nrow]
    row_depths = [maximum(cell_depths[r, :]; init = 0.0) for r in 1:nrow]

    # Provisional baseline y for each row (row 1 at y = 0).
    row_y = zeros(Float64, nrow)
    for r in 2:nrow
        row_y[r] = row_y[r - 1] - (row_depths[r - 1] + _MATRIX_ROWGAP * cell_scale + row_heights[r])
    end

    # Vertical extent of the provisional grid.
    grid_top = row_y[1] + row_heights[1]
    grid_bot = row_y[nrow] - row_depths[nrow]

    # Centre grid on the math axis.
    axis_em = mc.axis_height / upm * scale
    y_shift = y0 + axis_em - (grid_top + grid_bot) / 2

    # Column left-edge positions (relative to content origin, before adding left delimiter).
    # Vertical rules occupy space within the column separations.
    vrule_thick = mc.fraction_rule_thickness / upm * cell_scale
    x_col = zeros(Float64, ncol)
    x_col[1] = _MATRIX_COLSEP * cell_scale
    for c in 2:ncol
        x_col[c] = x_col[c - 1] + col_widths[c - 1] + 2 * _MATRIX_COLSEP * cell_scale
    end
    content_w = x_col[ncol] + col_widths[ncol] + _MATRIX_COLSEP * cell_scale

    # ── Delimiter sizing (if required) ──
    left_w = 0.0; right_w = 0.0
    if !isempty(info.left) || !isempty(info.right)
        actual_top = y_shift + grid_top - y0
        actual_bot = y_shift + grid_bot - y0
        h_above = max(0.0, actual_top - axis_em)
        h_below = max(0.0, axis_em - actual_bot)
        required_em = 2.0 * max(h_above, h_below)
        required_du = required_em / scale * upm
        left_w = _layout_delim!(ctx, info.left, required_du, x0, y0, scale, boxes)
        right_w = _layout_delim!(
            ctx, info.right, required_du,
            x0 + left_w + content_w, y0, scale, boxes
        )
    end

    # ── Second pass: emit all cells with correct offsets ──
    for r in 1:nrow, c in 1:ncol
        ci = (r - 1) * ncol + c
        ci > length(node.children) && continue
        tmp = cell_boxes[r, c]
        isempty(tmp) && continue

        # Per-column alignment: :l = flush left, :r = flush right, :c = centred.
        offset = col_aligns[c] === :l ? 0.0 :
            col_aligns[c] === :r ? col_widths[c] - cell_widths[r, c] :
            (col_widths[c] - cell_widths[r, c]) / 2
        x_cell = x0 + left_w + x_col[c] + offset
        y_cell = y_shift + row_y[r]
        _emit_shifted!(boxes, tmp, x_cell, y_cell)
    end

    # ── Emit vertical rules from colspec ──
    vrule_bot = y_shift + grid_bot
    vrule_height = grid_top - grid_bot
    # Base x positions of rule groups within the content area (relative to x0+left_w).
    # vrule[1]: before col 1; vrule[c+1]: between col c and c+1; vrule[ncol+1]: after last.
    # Multiple rules per slot (vrule[i] > 1) are emitted with _MATRIX_DOUBLERULESEP gaps.
    rule_sep = (vrule_thick + _MATRIX_DOUBLERULESEP * cell_scale)
    function emit_vrules!(base_x::Float64, n::Int)
        n == 0 && return
        # Centre the rule group around base_x.
        group_w = n * vrule_thick + (n - 1) * _MATRIX_DOUBLERULESEP * cell_scale
        x_start = base_x - group_w / 2
        for k in 0:(n - 1)
            push!(
                boxes, LayoutBox(
                    VRule(vrule_height, vrule_thick),
                    x0 + left_w + x_start + k * rule_sep, vrule_bot, scale
                )
            )
        end
        return
    end
    emit_vrules!(0.0, vrule[1])
    for c in 1:(ncol - 1)
        emit_vrules!(x_col[c] + col_widths[c] + _MATRIX_COLSEP * cell_scale, vrule[c + 1])
    end
    emit_vrules!(content_w, vrule[ncol + 1])

    return left_w + content_w + right_w
end

# ── Per-kind layout helpers ──────────────────────────────────────────────────
# Each `_layout_X!` takes the same signature and returns the horizontal advance
# of the node in em units.  `_layout_node!` at the bottom dispatches on
# `node.kind`.  This per-kind split keeps each rule small enough to read in one
# screen and isolates changes to a single function.

# Strip the leading '\' from a TKCommand value, returning the bare command name.
@inline _command_name(cmd::AbstractString) =
    startswith(cmd, '\\') ? cmd[2:end] : cmd

function _layout_char!(node, ctx, style, x0, y0, scale, boxes)
    ch = only(node.value)
    g = if ctx.font_variant !== :default
        _variant_glyph(ctx, ctx.font_variant, ch)
    elseif ctx.mode === :math && isletter(ch)
        # Standard LaTeX renders math-mode letters italic; use the
        # math-italic Unicode variant (U+1D400 block) so e.g. 'x' → u1D465.
        _variant_glyph(ctx, :mathit, ch)
    elseif ctx.mode === :text && ch == ' '
        # Space in text mode: emit a Space element with the font's word-space advance.
        m = glyph_metrics_upright(ctx.family, ' ')
        w = m === nothing ? 0.25 : m.advance_width / ctx.upm * scale
        push!(boxes, LayoutBox(Space(w), x0, y0, scale))
        return w
    elseif ctx.mode === :text
        # \text{}/\mbox{}: use upright (regular-font) glyph; no italic remapping.
        _upright_glyph(ctx, ch)
    else
        _char_glyph(ctx, ch)
    end
    g === nothing && return 0.0
    push!(boxes, LayoutBox(g, x0, y0, scale))
    return g.advance_width / ctx.upm * scale
end

function _layout_command!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    name = _command_name(node.value)
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
    end

    # Ordinary symbols are resolved by codepoint via _SYMBOL_CODEPOINTS so the
    # correct glyph is found regardless of font-specific PS naming.
    cp = get(_SYMBOL_CODEPOINTS, name, nothing)
    cp === nothing && return 0.0
    # Inside a font-switch context (\mathbf, \boldsymbol, etc.), try to map to
    # the variant codepoint (e.g. \alpha inside \mathbf{} → bold Greek alpha).
    if ctx.font_variant !== :default
        vcp = _math_variant_codepoint(ctx.font_variant, Char(cp))
        vcp !== nothing && (cp = vcp)
    end
    m = glyph_metrics_by_codepoint(ctx.family, cp)
    m === nothing && return 0.0
    ps = glyph_name_by_codepoint(ctx.family, cp)
    g = Glyph(
        isempty(ps) ? name : ps, :math,
        m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
    push!(boxes, LayoutBox(g, x0, y0, scale))
    return g.advance_width / upm * scale
end

function _layout_operator!(node, ctx, style, x0, y0, scale, boxes)
    # Render each character of the operator name upright (roman).
    cursor = x0
    for ch in node.value
        g = _upright_glyph(ctx, ch)
        g === nothing && continue
        push!(boxes, LayoutBox(g, cursor, y0, scale))
        cursor += g.advance_width / ctx.upm * scale
    end
    return cursor - x0
end

function _layout_space!(node, ctx, style, x0, y0, scale, boxes)
    iszero(node.width) && return 0.0
    w = node.width * scale
    push!(boxes, LayoutBox(Space(w), x0, y0, scale))
    return w
end

function _layout_superscript!(node, ctx, style, x0, y0, scale, boxes)
    base, sup = node.children[1], node.children[2]
    base.kind === NKHorizBrace &&
        return _layout_horiz_brace!(base, nothing, sup, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sup_s = sup_style(style);  sup_scale = _scale_for_child(scale, style, sup_s, mc)
    if _use_limits(base, style)
        # Limits placement: sup centred above base.
        tmp_base = LayoutBox[];  tmp_sup = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sup_w = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
        base_top = _boxes_top(tmp_base, upm)
        s = scale / upm
        y_sup = max(
            y0 + base_top + mc.upper_limit_baseline_rise_min * s,
            y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm)
        )
        total_w = max(base_w, sup_w)
        Δbase = (total_w - base_w) / 2;  Δsup = (total_w - sup_w) / 2
        # ±½ italic correction shifts superscript right over the slanted stroke.
        Δsup += _base_italic_correction_em(tmp_base, ctx, scale) / 2
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sup, x0 + Δsup, y_sup)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sup = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sup_adv = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
    append!(boxes, tmp_base)
    s = scale / upm
    min_sup = is_cramped(style) ?
        mc.superscript_shift_up_cramped * s :
        mc.superscript_shift_up * s
    # Rule 18a: for non-character bases (fractions, groups, …) the superscript
    # baseline must not drop below base_top − supDrop (SuperscriptBaselineDropMax).
    y_sup = _is_char_box(base) ? y0 + min_sup :
        max(y0 + min_sup, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max * s)
    # Rule 18c: superscript bottom must clear SuperscriptBottomMin above baseline.
    y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(tmp_sup, upm))
    _emit_shifted!(boxes, tmp_sup, x0 + base_adv, y_sup)
    return base_adv + sup_adv + mc.space_after_script * s
end

function _layout_subscript!(node, ctx, style, x0, y0, scale, boxes)
    base, sub = node.children[1], node.children[2]
    base.kind === NKHorizBrace &&
        return _layout_horiz_brace!(base, sub, nothing, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sub_s = sub_style(style);  sub_scale = _scale_for_child(scale, style, sub_s, mc)
    if _use_limits(base, style)
        # Limits placement: sub centred below base.
        tmp_base = LayoutBox[];  tmp_sub = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sub_w = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
        base_bot = _boxes_bottom(tmp_base, upm)
        s = scale / upm
        y_sub = min(
            y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
            y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s
        )
        total_w = max(base_w, sub_w)
        Δbase = (total_w - base_w) / 2;  Δsub = (total_w - sub_w) / 2
        # ±½ italic correction shifts subscript left under the slanted stroke.
        Δsub -= _base_italic_correction_em(tmp_base, ctx, scale) / 2
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sub, x0 + Δsub, y_sub)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sub = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sub_adv = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
    append!(boxes, tmp_base)
    s = scale / upm
    min_sub = mc.subscript_shift_down * s
    # Rule 18a: for non-character bases the subscript baseline must be placed
    # no higher than base_bottom − subDrop (SubscriptBaselineDropMin, σ₁₉).
    y_sub = _is_char_box(base) ? y0 - min_sub :
        min(y0 - min_sub, _boxes_bottom(tmp_base, upm) - mc.subscript_baseline_drop_min * s)
    # Rule 18b: subscript top must not exceed SubscriptTopMax above baseline.
    y_sub = min(y_sub, y0 - _boxes_top(tmp_sub, upm) + mc.subscript_top_max * s)
    # Italic correction: subscript on a slanted single-glyph base (e.g. ∫) is
    # shifted left by the full IC so it sits under the stroke, not the advance width.
    # Matches KaTeX supsub.ts: marginLeft = makeEm(-italic_correction) on subscript.
    ic_em = _base_italic_correction_em(tmp_base, ctx, scale)
    _emit_shifted!(boxes, tmp_sub, x0 + base_adv - ic_em, y_sub)
    return base_adv + sub_adv + mc.space_after_script * s
end

function _layout_decorated!(node, ctx, style, x0, y0, scale, boxes)
    base, sub, sup = node.children[1], node.children[2], node.children[3]
    base.kind === NKHorizBrace &&
        return _layout_horiz_brace!(base, sub, sup, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sub_s = sub_style(style);  sub_scale = _scale_for_child(scale, style, sub_s, mc)
    sup_s = sup_style(style);  sup_scale = _scale_for_child(scale, style, sup_s, mc)
    if _use_limits(base, style)
        # Limits placement: sub centred below, sup centred above.
        tmp_base = LayoutBox[];  tmp_sub = LayoutBox[];  tmp_sup = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sub_w = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
        sup_w = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
        base_top = _boxes_top(tmp_base, upm)
        base_bot = _boxes_bottom(tmp_base, upm)
        s = scale / upm
        y_sup = max(
            y0 + base_top + mc.upper_limit_baseline_rise_min * s,
            y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm)
        )
        y_sub = min(
            y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
            y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s
        )
        total_w = max(base_w, sub_w, sup_w)
        Δbase = (total_w - base_w) / 2
        Δsub = (total_w - sub_w) / 2
        Δsup = (total_w - sup_w) / 2
        # ±½ italic correction shifts sub/sup to track the slanted operator stroke.
        ic_half = _base_italic_correction_em(tmp_base, ctx, scale) / 2
        Δsub -= ic_half
        Δsup += ic_half
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sub, x0 + Δsub, y_sub)
        _emit_shifted!(boxes, tmp_sup, x0 + Δsup, y_sup)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sub = LayoutBox[];  tmp_sup = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sub_adv = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
    sup_adv = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
    append!(boxes, tmp_base)
    script_x = x0 + base_adv
    # Italic correction: subscript on a slanted single-glyph base (e.g. ∫) is
    # shifted left by the full IC so it sits under the stroke, not the advance width.
    # Superscript is not shifted. Matches KaTeX supsub.ts behaviour.
    ic_em = _base_italic_correction_em(tmp_base, ctx, scale)
    s = scale / upm
    min_sup = is_cramped(style) ?
        mc.superscript_shift_up_cramped * s :
        mc.superscript_shift_up * s
    min_sub = mc.subscript_shift_down * s
    # Rule 18a: for non-character bases apply supDrop/subDrop clamps (σ₁₈/σ₁₉).
    y_sup = _is_char_box(base) ? y0 + min_sup :
        max(y0 + min_sup, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max * s)
    y_sub = _is_char_box(base) ? y0 - min_sub :
        min(y0 - min_sub, _boxes_bottom(tmp_base, upm) - mc.subscript_baseline_drop_min * s)
    # Rule 18c: superscript bottom must clear SuperscriptBottomMin above baseline.
    y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(tmp_sup, upm))
    # Rule 18b: subscript top must not exceed SubscriptTopMax above baseline.
    y_sub = min(y_sub, y0 - _boxes_top(tmp_sub, upm) + mc.subscript_top_max * s)
    # Rule 18e: enforce minimum gap between superscript bottom and subscript top.
    sup_bot = y_sup + _boxes_bottom(tmp_sup, upm)
    sub_top = y_sub + _boxes_top(tmp_sub, upm)
    min_gap = mc.sub_superscript_gap_min * s
    if sup_bot - sub_top < min_gap
        y_sub = sup_bot - min_gap - _boxes_top(tmp_sub, upm)
        # Psi redistribution: if the superscript bottom falls below
        # SuperscriptBottomMaxWithSubscript, shift both scripts upward together
        # so that it reaches exactly that threshold (gap remains min_gap).
        psi = mc.superscript_bottom_max_with_subscript * s - sup_bot
        if psi > 0.0
            y_sup += psi
            y_sub += psi
        end
    end
    _emit_shifted!(boxes, tmp_sub, script_x - ic_em, y_sub)
    _emit_shifted!(boxes, tmp_sup, script_x, y_sup)
    return base_adv + max(sub_adv, sup_adv) + mc.space_after_script * s
end

# Apply an absolute style override (\dfrac, \displaystyle, etc.).
# value encodes the target style as "Display", "Text", "Script", or "ScriptScript".
# The scale is reset to size_scale(new_style) so that e.g. \dfrac inside a
# subscript renders at full display size, matching KaTeX behaviour.
function _layout_style_override!(node, ctx, style, x0, y0, scale, boxes)
    new_style = if node.value == "Display"
        Display
    elseif node.value == "Text"
        Text
    elseif node.value == "Script"
        Script
    else
        ScriptScript
    end
    new_scale = size_scale(new_style, ctx.mc)
    return _layout_node!(node.children[1], ctx, new_style, x0, y0, new_scale, boxes)
end

# Apply a relative font-size change (\large, \tiny, etc.).
# value is the Float64 multiplier serialised as a string.
function _layout_sizing!(node, ctx, style, x0, y0, scale, boxes)
    factor = parse(Float64, node.value)
    return _layout_node!(node.children[1], ctx, style, x0, y0, scale * factor, boxes)
end

# Lay out an extensible arrow with optional above and below labels.
#
# Vertical positioning follows KaTeX xarrow.ts:
#   - Arrow body centred on the math axis.
#   - Above label: bottom of ink at arrow_top + KERN.
#   - Below label: top of ink at arrow_bot − KERN.
#   - Minimum arrow width: max(natural width, widest_label + 2*PAD*scale).
#   - Both labels and arrow centred horizontally over the full advance.
function _layout_xarrow!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    cmd = node.value
    above_node = node.children[1]
    below_node = length(node.children) >= 2 ? node.children[2] : nothing

    # Labels rendered at sub/sup script style and scale.
    above_s = sup_style(style)
    above_scale = _scale_for_child(scale, style, above_s, mc)
    below_s = sub_style(style)
    below_scale = _scale_for_child(scale, style, below_s, mc)

    tmp_above = LayoutBox[]
    above_w = _layout_node!(above_node, ctx, above_s, 0.0, 0.0, above_scale, tmp_above)

    tmp_below = LayoutBox[]
    below_w = 0.0
    if below_node !== nothing
        below_w = _layout_node!(below_node, ctx, below_s, 0.0, 0.0, below_scale, tmp_below)
    end

    # Resolve the arrow glyph in horiz_constructions.
    cp = get(_XARROW_CODEPOINTS, cmd, 0x2192)
    uni_name = "uni" * uppercase(string(cp, base = 16, pad = 4))
    arrow_ps = _horiz_construction_key(ctx, uni_name)

    # Natural arrow width from the reference glyph (smallest pre-built variant
    # or the base glyph itself).
    hc = get(ctx.horiz_constructions, arrow_ps, nothing)
    ref_ps = arrow_ps
    if hc !== nothing && !isempty(hc.variants)
        ref_ps = hc.variants[1].glyph_name
    end
    g_ref = _cmd_glyph(ctx, ref_ps)
    natural_w = g_ref !== nothing ? Float64(g_ref.advance_width) / upm * scale : scale

    # Arrow width: at least as wide as the widest label plus horizontal padding.
    label_w = max(above_w, below_w)
    arrow_w = max(natural_w, label_w + 2 * _XARROW_PAD * scale)

    # Total advance: same as arrow width (labels are centred within it).
    total_w = arrow_w

    # Vertical: centre arrow on math axis.
    axis_em = mc.axis_height / upm * scale
    if g_ref !== nothing
        arrow_y = y0 + axis_em - (Float64(g_ref.y_min) + Float64(g_ref.y_max)) / (2.0 * upm) * scale
        arrow_top = arrow_y + Float64(g_ref.y_max) / upm * scale
        arrow_bot = arrow_y + Float64(g_ref.y_min) / upm * scale
    else
        arrow_y = y0 + axis_em
        arrow_top = arrow_y + 0.3 * scale
        arrow_bot = arrow_y - 0.3 * scale
    end

    # Place the extensible arrow body.
    _layout_wide_accent!(ctx, arrow_ps, arrow_w, arrow_y, x0, scale, boxes)

    # Place the above label: bottom of ink at arrow_top + kern.
    if !isempty(tmp_above)
        Δabove = (total_w - above_w) / 2
        label_y = arrow_top + _XARROW_KERN * scale - _boxes_bottom(tmp_above, upm)
        _emit_shifted!(boxes, tmp_above, x0 + Δabove, label_y)
    end

    # Place the below label: top of ink at arrow_bot − kern.
    if !isempty(tmp_below)
        Δbelow = (total_w - below_w) / 2
        label_y = arrow_bot - _XARROW_KERN * scale - _boxes_top(tmp_below, upm)
        _emit_shifted!(boxes, tmp_below, x0 + Δbelow, label_y)
    end

    return total_w
end

function _layout_frac!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    num_node, den_node = node.children[1], node.children[2]
    num_s = frac_num_style(style);  num_scale = _scale_for_child(scale, style, num_s, mc)
    den_s = frac_den_style(style);  den_scale = _scale_for_child(scale, style, den_s, mc)

    rule_thickness = mc.fraction_rule_thickness / upm * scale
    axis_em = mc.axis_height / upm * scale
    # Rule centre at the math axis; rule.y is the bottom edge.
    rule_y = y0 + axis_em - rule_thickness / 2

    # Initial shifts and minimum gap constants from the MATH table.
    if is_display(style)
        num_shift = mc.fraction_numerator_display_style_shift_up / upm * scale
        den_shift = mc.fraction_denominator_display_style_shift_down / upm * scale
        num_gap = mc.fraction_num_display_style_gap_min / upm * scale
        den_gap = mc.fraction_denom_display_style_gap_min / upm * scale
    else
        num_shift = mc.fraction_numerator_shift_up / upm * scale
        den_shift = mc.fraction_denominator_shift_down / upm * scale
        num_gap = mc.fraction_numerator_gap_min / upm * scale
        den_gap = mc.fraction_denominator_gap_min / upm * scale
    end

    # Layout at y=0 to measure ink extents before applying shifts.
    tmp_num = LayoutBox[];  tmp_den = LayoutBox[]
    num_w = _layout_node!(num_node, ctx, num_s, 0.0, 0.0, num_scale, tmp_num)
    den_w = _layout_node!(den_node, ctx, den_s, 0.0, 0.0, den_scale, tmp_den)

    # Clamp shifts so the minimum gap between content and rule is respected
    # (TeX Rule 15d/15e).  num_depth is how far the numerator ink extends below
    # its own baseline; den_height is how far the denominator ink extends above.
    num_depth = max(0.0, -_boxes_bottom(tmp_num, upm))
    den_height = max(0.0, _boxes_top(tmp_den, upm))
    num_shift = max(num_shift, axis_em + rule_thickness / 2 + num_gap + num_depth)
    den_shift = max(den_shift, den_height - axis_em + rule_thickness / 2 + den_gap)

    frac_w = max(num_w, den_w)
    Δnum = (frac_w - num_w) / 2
    Δden = (frac_w - den_w) / 2
    _emit_shifted!(boxes, tmp_num, x0 + Δnum, y0 + num_shift)
    _emit_shifted!(boxes, tmp_den, x0 + Δden, y0 - den_shift)
    push!(boxes, LayoutBox(HRule(frac_w, rule_thickness), x0, rule_y, scale))
    return frac_w
end

# Layout for \binom / \dbinom / \tbinom (NKGenfrac): a no-rule fraction wrapped
# in auto-sized delimiters.  Implements Rule 15c (no-rule gap clamping, i.e.
# rule_thickness = 0) and sizes the delimiters symmetrically around the math
# axis using the same algorithm as NKDelimited.
function _layout_genfrac!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm

    # Delimiter PS glyph names encoded in value as "left\x00right".
    delim_sep = findfirst('\x00', node.value)
    left_name = delim_sep === nothing ? "" : node.value[1:prevind(node.value, delim_sep)]
    right_name = delim_sep === nothing ? "" : node.value[nextind(node.value, delim_sep):end]

    num_node, den_node = node.children[1], node.children[2]
    num_s = frac_num_style(style)
    num_scale = _scale_for_child(scale, style, num_s, mc)
    den_s = frac_den_style(style)
    den_scale = _scale_for_child(scale, style, den_s, mc)

    axis_h = mc.axis_height / upm * scale

    # Initial shifts and gap minima from the MATH table (same constants as \frac).
    if is_display(style)
        num_shift = mc.fraction_numerator_display_style_shift_up / upm * scale
        den_shift = mc.fraction_denominator_display_style_shift_down / upm * scale
        num_gap = mc.fraction_num_display_style_gap_min / upm * scale
        den_gap = mc.fraction_denom_display_style_gap_min / upm * scale
    else
        num_shift = mc.fraction_numerator_shift_up / upm * scale
        den_shift = mc.fraction_denominator_shift_down / upm * scale
        num_gap = mc.fraction_numerator_gap_min / upm * scale
        den_gap = mc.fraction_denominator_gap_min / upm * scale
    end

    # Lay out numerator and denominator at origin to measure ink extents.
    tmp_num = LayoutBox[]
    tmp_den = LayoutBox[]
    num_w = _layout_node!(num_node, ctx, num_s, 0.0, 0.0, num_scale, tmp_num)
    den_w = _layout_node!(den_node, ctx, den_s, 0.0, 0.0, den_scale, tmp_den)

    # Rule 15c: gap clamping with no rule (rule_thickness = 0).
    num_depth = max(0.0, -_boxes_bottom(tmp_num, upm))
    den_height = max(0.0, _boxes_top(tmp_den, upm))
    num_shift = max(num_shift, axis_h + num_gap + num_depth)
    den_shift = max(den_shift, den_height - axis_h + den_gap)

    inner_w = max(num_w, den_w)

    # Compute the vertical extent of the fraction for delimiter sizing.
    # Both measured relative to y0 (i.e. the formula baseline).
    inner_top = num_shift + _boxes_top(tmp_num, upm)
    inner_bot = -den_shift + _boxes_bottom(tmp_den, upm)
    h_above = max(0.0, inner_top - axis_h)
    h_below = max(0.0, axis_h - inner_bot)
    required_du = 2.0 * max(h_above, h_below) / scale * upm

    # Place left delimiter, fraction content (centred), right delimiter.
    cursor = x0
    !isempty(left_name) && (cursor += _layout_delim!(ctx, left_name, required_du, cursor, y0, scale, boxes))
    Δnum = (inner_w - num_w) / 2
    Δden = (inner_w - den_w) / 2
    _emit_shifted!(boxes, tmp_num, cursor + Δnum, y0 + num_shift)
    _emit_shifted!(boxes, tmp_den, cursor + Δden, y0 - den_shift)
    cursor += inner_w
    !isempty(right_name) && (cursor += _layout_delim!(ctx, right_name, required_du, cursor, y0, scale, boxes))
    return cursor - x0
end

function _layout_sqrt!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    # \sqrt[degree]{body}: children are [body] or [degree, body].
    body_node = length(node.children) == 1 ? node.children[1] : node.children[2]
    tmp = LayoutBox[]
    # Rule 11: body is built in the cramped style (prevents superscripts inside
    # the radicand from protruding above the rule bar).
    body_w = _layout_node!(body_node, ctx, cramp_style(style), 0.0, 0.0, scale, tmp)
    body_top = _boxes_top(tmp, upm)
    body_bot = _boxes_bottom(tmp, upm)

    gap = is_display(style) ?
        mc.radical_display_style_vertical_gap / upm * scale :
        mc.radical_vertical_gap / upm * scale
    rule_thickness = mc.radical_rule_thickness / upm * scale

    # KaTeX Rule 11: when the radical hook extends significantly below the body,
    # redistribute excess vertical space so it is shared equally above and below
    # rather than entirely below.  Peek at the glyph that would be selected,
    # measure its depth below the rule bottom, and increase the gap if needed.
    let peek_du = (body_top + gap + rule_thickness - body_bot) / scale * upm
        cover_du = _peek_radical_cover_du(ctx, peek_du)
        if cover_du > 0.0
            delim_depth = cover_du / upm * scale - rule_thickness
            body_extent = body_top - body_bot
            if delim_depth > body_extent + gap
                gap = (gap + delim_depth - body_extent) / 2
            end
        end
    end

    rule_y_local = body_top + gap           # bottom of rule bar (em, relative to y0)
    rule_top_local = rule_y_local + rule_thickness

    # `required_cover_du` is the vertical span from body bottom to the rule top.
    required_cover_du = (rule_top_local - body_bot) / scale * upm
    required_du = required_cover_du
    rule_top_em = y0 + rule_top_local
    body_x_offset = _layout_radical!(ctx, required_du, rule_top_em, x0, scale, boxes)

    body_x = x0 + body_x_offset
    rule_overlap = rule_thickness / 2
    rule_x = body_x - rule_overlap

    _emit_shifted!(boxes, tmp, body_x, y0)
    push!(
        boxes, LayoutBox(
            HRule(body_w + rule_overlap, rule_thickness),
            rule_x, y0 + rule_y_local, scale
        )
    )
    return body_x_offset + body_w
end

function _layout_delimited!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    # \left…\right: size delimiters to the inner content, centred on the math axis.
    # node.value encodes "left_ps_name\x00right_ps_name".
    sep = findfirst('\x00', node.value)
    left_name = sep === nothing ? node.value : node.value[1:(sep - 1)]
    right_name = sep === nothing ? "" : node.value[(sep + 1):end]

    # Partition inner children into content segments separated by NKMiddle nodes.
    # segments[i] holds the children between the (i-1)-th and i-th \middle delimiter.
    # middles[i]  is the NKMiddle node separating segments[i] from segments[i+1].
    segments = Vector{Node}[]
    middles = Node[]
    current_seg = Node[]
    for child in node.children
        if child.kind === NKMiddle
            push!(segments, current_seg)
            push!(middles, child)
            current_seg = Node[]
        else
            push!(current_seg, child)
        end
    end
    push!(segments, current_seg)

    # Lay out each segment at the origin into a scratch buffer to measure dimensions.
    # x=0 is used so that box positions are relative; they are shifted when placed.
    seg_boxes = [LayoutBox[] for _ in segments]
    seg_widths = zeros(Float64, length(segments))
    for (i, seg) in enumerate(segments)
        seg_widths[i] = _layout_children!(seg, ctx, style, 0.0, y0, scale, seg_boxes[i])
    end

    # Measure the overall vertical extent across all segment boxes.
    all_tmp = isempty(seg_boxes) ? LayoutBox[] : reduce(vcat, seg_boxes)
    content_top = _boxes_top(all_tmp, upm)
    content_bot = _boxes_bottom(all_tmp, upm)
    # Ensure a sensible non-zero span when content has no glyph ink.
    content_top = max(content_top, y0 + mc.axis_height / upm * scale)
    content_bot = min(content_bot, y0 - mc.axis_height / upm * scale)

    # Required delimiter advance: sized so every delimiter covers the content
    # symmetrically around the math axis (same formula for left, middle, and right).
    # Converted to unscaled design units because GlyphVariant.advance and
    # GlyphAssemblyPart.full_advance are stored in unscaled design units.
    axis_em = y0 + mc.axis_height / upm * scale
    h_above = max(0.0, content_top - axis_em)
    h_below = max(0.0, axis_em - content_bot)
    required_em = 2.0 * max(h_above, h_below)
    required_du = required_em / scale * upm

    # Place left delimiter, then (segment + middle delimiter)*, then last segment + right.
    cursor = x0
    left_w = _layout_delim!(ctx, left_name, required_du, cursor, y0, scale, boxes)
    cursor += left_w
    for (i, (seg_b, seg_w)) in enumerate(zip(seg_boxes, seg_widths))
        _emit_shifted!(boxes, seg_b, cursor, 0.0)
        cursor += seg_w
        if i <= length(middles)
            mid_w = _layout_delim!(ctx, middles[i].value, required_du, cursor, y0, scale, boxes)
            cursor += mid_w
        end
    end
    right_w = _layout_delim!(ctx, right_name, required_du, cursor, y0, scale, boxes)
    return cursor - x0 + right_w
end

function _layout_font_switch!(node, ctx, style, x0, y0, scale, boxes)
    # Switch the active font variant for all recursive calls within the body.
    isempty(node.children) && return 0.0
    new_ctx = _with_variant(ctx, Symbol(node.value))
    return _layout_node!(node.children[1], new_ctx, style, x0, y0, scale, boxes)
end

function _layout_text!(node, ctx, style, x0, y0, scale, boxes)
    # Render the body in text mode: upright (regular-font) glyphs, no math-italic
    # remapping, no inter-atom spacing (guarded in _layout_children! by mode check).
    isempty(node.children) && return 0.0
    return _layout_node!(node.children[1], _with_text_mode(ctx), style, x0, y0, scale, boxes)
end

function _layout_accent!(node, ctx, style, x0, y0, scale, boxes)
    # KaTeX Rule 12 (accent.ts).  Build base in cramped style, then place the
    # accent glyph above it, aligned via MathTopAccentAttachment when available.
    isempty(node.children) && return 0.0
    mc, upm = ctx.mc, ctx.upm

    # Build base in cramped style (Rule 12: base is typeset cramped).
    tmp = LayoutBox[]
    base_w = _layout_node!(node.children[1], ctx, cramp_style(style), 0.0, 0.0, scale, tmp)
    base_top = _boxes_top(tmp, upm)   # body.height in em (measured at origin)
    _emit_shifted!(boxes, tmp, x0, y0)

    # Look up the accent glyph.  Try the primary codepoint first; if the font
    # does not have a glyph there, try the combining-form fallback (e.g. Luciole
    # Math uses U+0302–U+030C instead of the spacing modifier codepoints).
    accent_ps = glyph_name_by_codepoint(ctx.family, _ACCENT_CODEPOINTS[node.value])
    if isempty(accent_ps)
        fb = get(_ACCENT_FALLBACK_CODEPOINTS, node.value, nothing)
        fb !== nothing && (accent_ps = glyph_name_by_codepoint(ctx.family, fb))
    end
    isempty(accent_ps) && return base_w
    accent_m = glyph_metrics(ctx.family, accent_ps)
    accent_m === nothing && return base_w

    # Vertical placement: clearance = min(base_top, accent_base_height_em).
    # This places the accent so it just clears a normal x-height character while
    # riding higher above ascenders, matching the KaTeX clearance formula.
    accent_base_h = mc.accent_base_height * scale / upm
    accent_y = y0 + max(0.0, base_top - accent_base_h)

    # Wide accents (\widehat, \widetilde) are placed using a horizontally
    # extensible glyph centred over the base; no MathTopAccentAttachment alignment.
    if node.value ∈ _WIDE_ACCENT_COMMANDS && haskey(ctx.horiz_constructions, accent_ps)
        _layout_wide_accent!(ctx, accent_ps, base_w, accent_y, x0, scale, boxes)
        return base_w
    end

    # Horizontal placement via MathTopAccentAttachment.  If the base is a single
    # glyph with a known attachment point, align the attachment x of the accent
    # to the attachment x of the base.  Fall back to centering when attachment
    # data is unavailable.
    base_attach_du = if length(tmp) == 1 && tmp[1].element isa Glyph
        get(ctx.top_accent_attachments, (tmp[1].element::Glyph).glyph_name, nothing)
    else
        nothing
    end
    accent_attach_du = get(ctx.top_accent_attachments, accent_ps, nothing)

    accent_x = if base_attach_du !== nothing && accent_attach_du !== nothing
        x0 + (base_attach_du - accent_attach_du) * scale / upm
    else
        # Centre by ink midpoint rather than advance_width/2: handles zero-advance
        # combining characters (adv_w=0, x_min/x_max negative).
        x0 + base_w / 2 - (accent_m.x_min + accent_m.x_max) * scale / (2.0 * upm)
    end

    push!(
        boxes, LayoutBox(
            Glyph(
                accent_ps, :math, accent_m.advance_width,
                accent_m.left_side_bearing,
                accent_m.x_min, accent_m.y_min,
                accent_m.x_max, accent_m.y_max
            ),
            accent_x, accent_y, scale
        )
    )
    return base_w
end

function _layout_overunder!(node, ctx, style, x0, y0, scale, boxes)
    # Rules 9 & 10: \overline and \underline.
    # \overline  (Rule 9):  body in cramped style; HRule above with gap from MATH table.
    # \underline (Rule 10): body in current style; HRule below with gap from MATH table.
    isempty(node.children) && return 0.0
    mc, upm = ctx.mc, ctx.upm
    is_over = node.value == "overline"
    child_style = is_over ? cramp_style(style) : style

    tmp = LayoutBox[]
    body_w = _layout_node!(node.children[1], ctx, child_style, 0.0, 0.0, scale, tmp)

    rule_t = (is_over ? mc.overbar_rule_thickness : mc.underbar_rule_thickness) / upm * scale
    gap = (is_over ? mc.overbar_vertical_gap : mc.underbar_vertical_gap) / upm * scale
    _emit_shifted!(boxes, tmp, x0, y0)

    # Rule bottom at body_top + gap (over) or body_bot − gap − rule_t (under).
    rule_y = is_over ?
        y0 + _boxes_top(tmp, upm) + gap :
        y0 + _boxes_bottom(tmp, upm) - gap - rule_t
    push!(boxes, LayoutBox(HRule(body_w, rule_t), x0, rule_y, scale))
    return body_w
end

# Lay out `node` into `boxes`, with the left-baseline anchor at (x0, y0) and
# the given scale.  Returns the horizontal advance of the node in em units.
# Dispatches per `node.kind` to a specialised `_layout_X!` helper above.
function _layout_node!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    k = node.kind
    k === NKChar           && return _layout_char!(node, ctx, style, x0, y0, scale, boxes)
    k === NKCommand        && return _layout_command!(node, ctx, style, x0, y0, scale, boxes)
    k === NKOperator       && return _layout_operator!(node, ctx, style, x0, y0, scale, boxes)
    k === NKSpace          && return _layout_space!(node, ctx, style, x0, y0, scale, boxes)
    k === NKSequence       && return _layout_children!(node.children, ctx, style, x0, y0, scale, boxes)
    k === NKGroup          && return _layout_children!(node.children, ctx, style, x0, y0, scale, boxes)
    k === NKSuperscript    && return _layout_superscript!(node, ctx, style, x0, y0, scale, boxes)
    k === NKSubscript      && return _layout_subscript!(node, ctx, style, x0, y0, scale, boxes)
    k === NKDecorated      && return _layout_decorated!(node, ctx, style, x0, y0, scale, boxes)
    k === NKFrac           && return _layout_frac!(node, ctx, style, x0, y0, scale, boxes)
    k === NKGenfrac        && return _layout_genfrac!(node, ctx, style, x0, y0, scale, boxes)
    k === NKSqrt           && return _layout_sqrt!(node, ctx, style, x0, y0, scale, boxes)
    k === NKDelimited      && return _layout_delimited!(node, ctx, style, x0, y0, scale, boxes)
    k === NKFontSwitch     && return _layout_font_switch!(node, ctx, style, x0, y0, scale, boxes)
    k === NKAccent         && return _layout_accent!(node, ctx, style, x0, y0, scale, boxes)
    k === NKOverUnder      && return _layout_overunder!(node, ctx, style, x0, y0, scale, boxes)
    k === NKHorizBrace     &&
        return _layout_horiz_brace!(node, nothing, nothing, ctx, style, x0, y0, scale, boxes)
    k === NKMatrix         && return _layout_matrix!(node, ctx, style, x0, y0, scale, boxes)
    k === NKLimitsOverride && return _layout_node!(_limits_base(node), ctx, style, x0, y0, scale, boxes)
    k === NKText           && return _layout_text!(node, ctx, style, x0, y0, scale, boxes)
    k === NKStyleOverride  && return _layout_style_override!(node, ctx, style, x0, y0, scale, boxes)
    k === NKSizing         && return _layout_sizing!(node, ctx, style, x0, y0, scale, boxes)
    k === NKXArrow         && return _layout_xarrow!(node, ctx, style, x0, y0, scale, boxes)
    # NKMiddle outside \left…\right (malformed input) and unrecognised kinds: emit nothing.
    return 0.0
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    layout(node, family, style) -> Vector{LayoutBox}

Lay out `node` in the given style, using font metrics from `family`.
Returns a flat list of positioned elements.
"""
function layout(node::Node, family::FontFamily, style::TexStyle)::Vector{LayoutBox}
    mt = load_math_table(family.math)
    ctx = _LayoutCtx(
        family, mt.constants, Float64(mt.upm), mt.vert_constructions,
        mt.horiz_constructions, mt.top_accent_attachments,
        mt.italic_corrections,
        mt.min_connector_overlap, :math, :default
    )
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
    return layout(node, family, Display)
end
