# Symbol, delimiter, accent, and operator lookup tables used by layout.jl.

# NodeKind.Operator names that use limits placement in Display style (\lim, \max, etc.).
const _LIMITS_OPERATORS = Set{String}(
    [
        "lim", "limsup", "liminf",
        "det", "gcd", "inf", "sup", "max", "min", "Pr",
    ]
)

# Unicode codepoints for all large-operator symbols rendered via NodeKind.Command.
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

# Total heights (em units at base scale) for each \bigl/\Bigl/\biggl/\Biggl size tier.
# From KaTeX's sizeToMaxHeight = [0, 1.2, 1.8, 2.4, 3.0] (delimiter.ts).
# required_du = _BIG_DELIM_HEIGHTS[size] × upm — scale-independent, so the same
# glyph variant is chosen regardless of the ambient style size.
const _BIG_DELIM_HEIGHTS = [1.2, 1.8, 2.4, 3.0]

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
    # Arrow delimiters (used via \bigl\uparrow, \left\uparrow, etc.)
    "uparrow" => 0x2191,
    "downarrow" => 0x2193,
    "updownarrow" => 0x2195,
    "Uparrow" => 0x21D1,
    "Downarrow" => 0x21D3,
    "Updownarrow" => 0x21D5,
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

