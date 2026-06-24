# Parser command and environment tables.

# Normal interword space.  TeX's fontdimen2 (~3.333 pt at 10 pt) is 1/3 em,
# i.e. 6 mu in the 18-mu-per-em convention used throughout this table.  This is
# the width KaTeX renders for the U+00A0 glyph produced by `~`, `\ `, `\space`,
# and `\nobreakspace`.
const _NORMAL_SPACE_EM = 6 / 18

# Explicit horizontal spacing commands mapped to their width in em units.
# Thin/medium/thick spaces use TeX's 18-mu-per-em convention (3, 4, 5 mu).
const _SPACE_WIDTHS = Dict{String, Float64}(
    "\\," => 3 / 18,   # thin space
    "\\thinspace" => 3 / 18,
    "\\:" => 4 / 18,   # medium space
    "\\medspace" => 4 / 18,
    "\\;" => 5 / 18,   # thick space
    "\\thickspace" => 5 / 18,
    "\\!" => -3 / 18,   # negative thin space
    "\\negthinspace" => -3 / 18,
    "\\negmedspace" => -4 / 18,
    "\\negthickspace" => -5 / 18,
    "\\enspace" => 0.5,
    "\\quad" => 1.0,
    "\\qquad" => 2.0,
    "\\ " => _NORMAL_SPACE_EM,   # control space
    "\\space" => _NORMAL_SPACE_EM,
    "\\nobreakspace" => _NORMAL_SPACE_EM,
)

# Mapping from delimiter token text to OpenType PostScript glyph name.
# The "." null delimiter (e.g. \left. or \right.) maps to an empty string.
const _DELIM_GLYPH_NAMES = Dict{String, String}(
    "(" => "parenleft",
    ")" => "parenright",
    "[" => "bracketleft",
    "]" => "bracketright",
    "\\{" => "braceleft",
    "\\}" => "braceright",
    "|" => "bar",
    "\\|" => "dblverticalbar",
    "/" => "slash",
    "\\backslash" => "backslash",
    "\\langle" => "angleleft",
    "\\rangle" => "angleright",
    "\\lfloor" => "lfloor",
    "\\rfloor" => "rfloor",
    "\\lceil" => "lceil",
    "\\rceil" => "rceil",
    # Arrow delimiters — used by \bigl\uparrow, \left\uparrow, etc.
    "\\uparrow" => "uparrow",
    "\\downarrow" => "downarrow",
    "\\updownarrow" => "updownarrow",
    "\\Uparrow" => "Uparrow",
    "\\Downarrow" => "Downarrow",
    "\\Updownarrow" => "Updownarrow",
    # Angle brackets via < > characters (KaTeX treats these as \langle/\rangle)
    "<" => "angleleft",
    ">" => "angleright",
    "." => "",   # null delimiter — renders nothing
)

# Manual delimiter sizing: \bigl/\bigr/\big etc.
# Each entry maps a command to (size_char, class_char) where
# size_char ∈ '1'-'4' and class_char ∈ 'o'(open), 'c'(close), 'r'(rel), 'd'(ord).
const _BIG_DELIM_COMMANDS = Dict{String, Tuple{Char, Char}}(
    "\\bigl" => ('1', 'o'),
    "\\Bigl" => ('2', 'o'),
    "\\biggl" => ('3', 'o'),
    "\\Biggl" => ('4', 'o'),
    "\\bigr" => ('1', 'c'),
    "\\Bigr" => ('2', 'c'),
    "\\biggr" => ('3', 'c'),
    "\\Biggr" => ('4', 'c'),
    "\\bigm" => ('1', 'r'),
    "\\Bigm" => ('2', 'r'),
    "\\biggm" => ('3', 'r'),
    "\\Biggm" => ('4', 'r'),
    "\\big" => ('1', 'd'),
    "\\Big" => ('2', 'd'),
    "\\bigg" => ('3', 'd'),
    "\\Bigg" => ('4', 'd'),
)

# Math accent commands mapped to the Unicode codepoint of the accent glyph.
# Codepoints follow KaTeX's symbols.ts.  The layout engine looks up the PS glyph
# name via the font's cmap so that the correct variant is used in each math font.
# \widehat and \widetilde share codepoints with \hat and \tilde; the layout engine
# distinguishes them via the _WIDE_ACCENT_COMMANDS set and selects a horizontally
# extensible glyph from horiz_constructions when the base is wide enough to warrant it.
const _ACCENT_CODEPOINTS = Dict{String, UInt32}(
    "\\hat" => 0x02C6,   # ˆ MODIFIER LETTER CIRCUMFLEX ACCENT (has MathTopAccentAttachment; U+005E asciicircum does not)
    "\\widehat" => 0x0302,   # ̂ COMBINING CIRCUMFLEX ACCENT — maps to circumflexcmb which has horiz_constructions variants
    "\\acute" => 0x00B4,   # ´ ACUTE ACCENT (Latin-1; U+02CA absent in most math fonts)
    "\\grave" => 0x0060,   # ` GRAVE ACCENT (ASCII; U+02CB absent in most math fonts)
    "\\ddot" => 0x00A8,   # ¨ DIAERESIS
    "\\tilde" => 0x02DC,   # ˜ SMALL TILDE (has MathTopAccentAttachment; U+007E asciitilde does not)
    "\\widetilde" => 0x0303,  # ̃ COMBINING TILDE — maps to tildecomb which has horiz_constructions variants
    "\\bar" => 0x00AF,   # ¯ MACRON (Latin-1; U+02C9 absent in most math fonts)
    "\\breve" => 0x02D8,   # ˘ BREVE
    "\\check" => 0x02C7,   # ˇ CARON
    "\\dot" => 0x02D9,   # ˙ DOT ABOVE
    "\\mathring" => 0x02DA,   # ˚ RING ABOVE
    "\\vec" => 0x20D7,   # ⃗ COMBINING RIGHT ARROW ABOVE
)

# Font-switching commands mapped to their variant name.
# The variant name is passed as `value` in the NodeKind.FontSwitch node and is used by
# the layout engine to select the correct Unicode math-variant codepoints.
const _FONT_SWITCH_COMMANDS = Dict{String, String}(
    "\\mathbf" => "mathbf",
    "\\mathit" => "mathit",
    "\\mathrm" => "mathrm",
    "\\mathbb" => "mathbb",
    "\\mathcal" => "mathcal",
    "\\mathfrak" => "mathfrak",
    "\\mathscr" => "mathscr",
    "\\mathsf" => "mathsf",
    "\\mathtt" => "mathtt",
    "\\boldsymbol" => "boldsymbol",
    "\\bm" => "boldsymbol",
    "\\mathnormal" => "mathnormal",
    "\\mathsfit" => "mathsfit",
    "\\Bbb" => "mathbb",    # AMS alias for \mathbb
    "\\bold" => "mathbf",    # KaTeX alias for \mathbf
    "\\frak" => "mathfrak",  # KaTeX alias for \mathfrak
)

# Set of horizontal brace/bracket/paren commands that stretch over a body.
# The matching command → PS-glyph-name map lives in layout.jl as
# `_HORIZ_BRACE_GLYPHS`; the parser only needs to recognise the command names.
const _HORIZ_BRACE_COMMANDS = Set{String}(
    [
        "\\overbrace", "\\underbrace",
        "\\overbracket", "\\underbracket",
        "\\overparen", "\\underparen",
    ]
)

# Matrix/array-like environments introduced by \begin{name}.
# Each entry specifies the PostScript glyph names of the auto-sized left and right
# delimiters (empty string = no delimiter), the column alignment,
# and a scale factor relative to the surrounding text (1.0 for all except smallmatrix).
# "dblverticalbar" is the NewCMMath PS name for U+2016 ‖; other fonts may differ, but
# glyph_name_by_codepoint fallback is used if the literal name is absent.
const _MatrixEnvInfo = @NamedTuple{left::String, right::String, align::Alignment.T, scale::Float64}
const _MATRIX_ENVS = Dict{String, _MatrixEnvInfo}(
    "matrix" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "pmatrix" => (left = "parenleft", right = "parenright", align = Alignment.Center, scale = 1.0),
    "bmatrix" => (left = "bracketleft", right = "bracketright", align = Alignment.Center, scale = 1.0),
    "Bmatrix" => (left = "braceleft", right = "braceright", align = Alignment.Center, scale = 1.0),
    "vmatrix" => (left = "bar", right = "bar", align = Alignment.Center, scale = 1.0),
    "Vmatrix" => (left = "dblverticalbar", right = "dblverticalbar", align = Alignment.Center, scale = 1.0),
    "smallmatrix" => (left = "", right = "", align = Alignment.Center, scale = 0.9),
    "cases" => (left = "braceleft", right = "", align = Alignment.Left, scale = 1.0),
    # \begin{array}{colspec} — explicit per-column alignment and vertical rules.
    "array" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    # Display-math environments (document layer treats these as DisplayBlocks).
    "align" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "aligned" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "split" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "gather" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "gathered" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
    "equation" => (left = "", right = "", align = Alignment.Center, scale = 1.0),
)

# Display alignment/math environments.  Their cells are typeset in Display style
# (TeX/amsmath sets each line of these environments in display style), and the
# document layer turns the whole environment into a free-standing DisplayBlock.
# Contrast with matrix/array/cases, whose cells are typeset in Text style.
const _DISPLAY_MATH_ENVS = Set{String}(
    [
        "align", "aligned", "split", "gather", "gathered", "equation",
    ]
)

# Mapping from style-switch commands to the target TeX style name (Display/Text/Script/ScriptScript).
# \dfrac and \tfrac are not in this map; they are handled inline in _parse_command!.
const _STYLE_COMMANDS = Dict{String, String}(
    "\\displaystyle" => "Display",
    "\\textstyle" => "Text",
    "\\scriptstyle" => "Script",
    "\\scriptscriptstyle" => "ScriptScript",
)

# Font sizing commands mapped to scale multipliers relative to the current scale.
# Values follow the standard LaTeX font size ladder at the default 10pt base.
const _SIZING_MULTIPLIERS = Dict{String, Float64}(
    "\\tiny" => 0.5,
    "\\scriptsize" => 0.7,
    "\\footnotesize" => 0.8,
    "\\small" => 0.9,
    "\\normalsize" => 1.0,
    "\\large" => 1.2,
    "\\Large" => 1.44,
    "\\LARGE" => 1.728,
    "\\huge" => 2.074,
    "\\Huge" => 2.488,
)

# All extensible arrow commands (amsmath xarrows plus common variants).
# Each corresponds to a Unicode arrow codepoint in _XARROW_CODEPOINTS in layout.jl.
const _XARROW_COMMANDS = Set{String}(
    [
        "\\xleftarrow", "\\xrightarrow",
        "\\xLeftarrow", "\\xRightarrow",
        "\\xleftrightarrow", "\\xLeftrightarrow",
        "\\xhookleftarrow", "\\xhookrightarrow",
        "\\xmapsto",
        "\\xrightharpoondown", "\\xrightharpoonup",
        "\\xleftharpoondown", "\\xleftharpoonup",
        "\\xrightleftharpoons", "\\xleftrightharpoons",
        "\\xtwoheadrightarrow", "\\xtwoheadleftarrow",
        "\\xlongequal",
    ]
)

# Environments that require an explicit column-spec argument after the env name.
const _COLSPEC_ENVS = Set{String}(["array"])

# Standard named math operators rendered as upright multi-character strings.
const _OPERATOR_NAMES = Set{String}(
    [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan",
        "ln", "log", "exp",
        "lim", "limsup", "liminf", "sup", "inf", "max", "min",
        "det", "dim", "ker", "deg", "gcd", "hom", "Pr", "arg",
    ]
)
