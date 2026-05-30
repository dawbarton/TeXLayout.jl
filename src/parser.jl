# LaTeX parser: token stream → AST.
#
# Produces a typed tree of `Node` values.  The parser handles grouping,
# sub/superscripts, fractions, roots, and a small set of core commands.
# Atom classification (mord/mbin/mrel/…) is deferred to the layout engine
# so that the parser remains context-free.

"""Kinds of AST node produced by the parser."""
@enum NodeKind begin
    NKChar          # single character (letter, digit, punctuation)
    NKSequence      # implicit group: ordered list of children
    NKGroup         # explicit braced group: {…}
    NKSuperscript   # base^{exponent} when subscript is absent
    NKSubscript     # base_{subscript} when superscript is absent
    NKDecorated     # base with both sub and sup: x_i^2
    NKFrac          # \frac{num}{den}
    NKGenfrac       # \binom etc.: no-rule fraction + delimiters; value = "left_ps\x00right_ps"
    NKSqrt          # \sqrt[degree]{body}
    NKDelimited     # \left…\right pair; value = "left_ps_name\x00right_ps_name"
    NKBigDelim      # \bigl/\bigr/\big etc.; value = "ps_name\x00<size>\x00<class>" (size ∈ '1'-'4', class ∈ 'o','c','r','d')
    NKAccent        # \hat, \bar, \vec, etc.
    NKOverUnder     # \overline / \underline; value is "overline" or "underline"
    NKCommand        # unrecognised command or atom-producing command (\alpha, \int, …)
    NKSpace          # explicit space token (\, \; \quad etc.)
    NKText           # \text{…} / \mbox{…}: text-mode fragment; children[1] = body
    NKOperator       # named math operator rendered upright: \sin, \cos, \operatorname{…}
    NKLimitsOverride # \limits / \nolimits: wraps a base; value is "limits" or "nolimits"
    NKFontSwitch     # \mathbf{…}, \mathit{…}, etc.; value = variant name; children[1] = body
    NKHorizBrace     # \overbrace / \underbrace / …; value = command name; children[1] = body
    NKMatrix         # \begin{env}…\end{env}: value = "env\x00nrow\x00colspec"; children = flat row-major cells
    NKMiddle         # \middle<delim>: auto-sized inner delimiter; value = PS glyph name
    NKStyleOverride  # \dfrac / \displaystyle etc.; value = style name; children[1] = body
    NKSizing         # \large / \tiny etc.; value = Float64 multiplier string; children[1] = body
    NKXArrow         # \xrightarrow etc.; value = command name; children = [above] or [above, below]
end

"""
An AST node.  Leaf nodes (chars, spaces, standalone commands) have an empty
`children` vector and carry their source text in `value`.  Interior nodes
carry children and may carry auxiliary text in `value` (e.g. the command name
for `NKAccent`).

The `width` field is meaningful only for `NKSpace` nodes; it carries the
explicit horizontal space in em units (may be negative for `\\!`, etc.).
All other node kinds leave it at the default of `0.0`.
"""
struct Node
    kind::NodeKind
    value::String           # source text for leaf nodes; command name for interior
    children::Vector{Node}
    width::Float64          # em units; NKSpace only, 0.0 otherwise
end

# Convenience constructors
Node(kind::NodeKind, value::String) = Node(kind, value, Node[], 0.0)
Node(kind::NodeKind, children::Vector{Node}) = Node(kind, "", children, 0.0)
Node(kind::NodeKind, value::String, children::Vector{Node}) = Node(kind, value, children, 0.0)

"""Construct an `NKSpace` node carrying an explicit horizontal width in em."""
space_node(w::Real) = Node(NKSpace, "", Node[], Float64(w))

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
# The variant name is passed as `value` in the NKFontSwitch node and is used by
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
# delimiters (empty string = no delimiter), the column alignment (:center or :left),
# and a scale factor relative to the surrounding text (1.0 for all except smallmatrix).
# "dblverticalbar" is the NewCMMath PS name for U+2016 ‖; other fonts may differ, but
# glyph_name_by_codepoint fallback is used if the literal name is absent.
const _MatrixEnvInfo = @NamedTuple{left::String, right::String, align::Symbol, scale::Float64}
const _MATRIX_ENVS = Dict{String, _MatrixEnvInfo}(
    "matrix" => (left = "", right = "", align = :center, scale = 1.0),
    "pmatrix" => (left = "parenleft", right = "parenright", align = :center, scale = 1.0),
    "bmatrix" => (left = "bracketleft", right = "bracketright", align = :center, scale = 1.0),
    "Bmatrix" => (left = "braceleft", right = "braceright", align = :center, scale = 1.0),
    "vmatrix" => (left = "bar", right = "bar", align = :center, scale = 1.0),
    "Vmatrix" => (left = "dblverticalbar", right = "dblverticalbar", align = :center, scale = 1.0),
    "smallmatrix" => (left = "", right = "", align = :center, scale = 0.9),
    "cases" => (left = "braceleft", right = "", align = :left, scale = 1.0),
    # \begin{array}{colspec} — explicit per-column alignment and vertical rules.
    "array" => (left = "", right = "", align = :center, scale = 1.0),
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

# ── Recursive-descent implementation ─────────────────────────────────────────

# Extract the plain-text content of a node as a string.  Used to recover the
# operator name from the braced argument of \operatorname{…}.
function _node_text(node::Node)::String
    node.kind === NKChar    && return node.value
    node.kind === NKCommand && return startswith(node.value, "\\") ? node.value[2:end] : node.value
    (node.kind === NKSequence || node.kind === NKGroup) &&
        return join(_node_text(c) for c in node.children)
    return ""
end

mutable struct _Parser
    tokens::Vector{Token}
    pos::Int
end

# Parse a TeX dimension after \kern / \mkern / \hskip / \mskip and return its
# value in em units.  Supports a braced form (\kern{1em}) and an unbraced form
# (\kern1em).  Only "em" and "mu" units are recognised; anything else yields 0.
# One math unit (mu) = 1/18 em by the standard TeX convention.
function _parse_kern_dimension!(p::_Parser, mu_units::Bool)::Float64
    braced = _current(p).kind === TKLBrace
    braced && _advance!(p)   # consume '{'

    # Collect sign + digits + decimal point.
    num = Char[]
    while _current(p).kind === TKChar
        c = only(_current(p).value)
        c ∈ "0123456789.+-" || break
        push!(num, c); _advance!(p)
    end

    # Collect exactly 2 letter chars for the unit (em, mu, ex, pt, …).
    unit = Char[]
    for _ in 1:2
        _current(p).kind === TKChar || break
        c = only(_current(p).value)
        isletter(c) || break
        push!(unit, c); _advance!(p)
    end

    braced && _current(p).kind === TKRBrace && _advance!(p)   # consume '}'

    val = tryparse(Float64, isempty(num) ? "0" : String(num))
    val === nothing && return 0.0
    unit_str = lowercase(String(unit))
    if mu_units || unit_str == "mu"
        return val / 18
    elseif unit_str == "em"
        return val
    else
        return 0.0   # unsupported unit: zero-width space
    end
end

@inline _current(p::_Parser) = p.tokens[p.pos]
@inline _advance!(p::_Parser) = (t = p.tokens[p.pos]; p.pos += 1; t)

# Consume the delimiter token following \left or \right and return its PS glyph
# name (e.g. "parenleft").  Returns "" for unknown or null delimiters.
function _parse_delim_name!(p::_Parser)::String
    _current(p).kind === TKEOF && return ""
    tok = _advance!(p)
    return get(_DELIM_GLYPH_NAMES, tok.value, "")
end

# Parse atoms until \right, '}' or EOF.  The \right token is left unconsumed so
# that the caller can record the right-delimiter glyph name.  \middle<delim> inside
# the body is consumed here and emitted as an NKMiddle node; the layout engine uses
# it to place an auto-sized inner delimiter at the correct position.
function _parse_delimited_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        k === TKSpace && (_advance!(p); continue)
        (k === TKEOF || k === TKRBrace) && break
        k === TKCommand && _current(p).value == "\\right" && break
        if k === TKCommand && _current(p).value == "\\middle"
            _advance!(p)   # consume \middle
            ps = _parse_delim_name!(p)
            push!(children, Node(NKMiddle, ps))
        else
            push!(children, _parse_atom!(p))
        end
    end
    return children
end

# Consume one argument for a command (e.g. \frac numerator).
# A braced group is parsed as its interior sequence; single elements are
# unwrapped.  This differs from _parse_group! which preserves the NKGroup
# wrapper for explicit braces that appear in a sequence.
function _parse_argument!(p::_Parser)::Node
    if _current(p).kind === TKLBrace
        _advance!(p)   # consume '{'
        children = _parse_sequence_children!(p)
        _current(p).kind === TKRBrace && _advance!(p)   # consume '}'
        length(children) == 1 && return children[1]
        return Node(NKSequence, children)
    else
        return _parse_primary!(p)
    end
end

# Parse a braced group {…} and return NKGroup with the interior children.
function _parse_group!(p::_Parser)::Node
    _advance!(p)   # consume '{'
    children = _parse_sequence_children!(p)
    _current(p).kind === TKRBrace && _advance!(p)   # consume '}'
    return Node(NKGroup, children)
end

# Parse atoms until '}' or EOF, returning the list of child nodes.
# Whitespace tokens are skipped (math mode: spaces are insignificant).
function _parse_sequence_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        (k === TKEOF || k === TKRBrace) && break
        k === TKSpace && (_advance!(p); continue)
        push!(children, _parse_atom!(p))
    end
    return children
end

# Like _parse_sequence_children! but preserves whitespace as NKChar(' ') nodes.
# Used for the argument of \text{} and \mbox{}, where spaces are significant.
function _parse_text_sequence_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        (k === TKEOF || k === TKRBrace) && break
        if k === TKSpace
            push!(children, Node(NKChar, " "))
            _advance!(p)
        else
            push!(children, _parse_atom!(p))
        end
    end
    return children
end

# Parse the braced argument of \text{} or \mbox{}, preserving spaces.
function _parse_text_argument!(p::_Parser)::Node
    if _current(p).kind === TKLBrace
        _advance!(p)   # consume '{'
        children = _parse_text_sequence_children!(p)
        _current(p).kind === TKRBrace && _advance!(p)   # consume '}'
        length(children) == 1 && return children[1]
        return Node(NKSequence, children)
    else
        return _parse_primary!(p)
    end
end

# Parse a single "atom": a primary optionally decorated with ^ and/or _.
function _parse_atom!(p::_Parser)::Node
    # Space tokens in math mode are ignored at the atom level.
    while _current(p).kind === TKSpace
        _advance!(p)
    end

    base = _parse_primary!(p)

    # Consume an explicit \limits or \nolimits modifier immediately after the primary,
    # wrapping the base so the script branches can dispatch on it.
    if _current(p).kind === TKCommand &&
            (_current(p).value == "\\limits" || _current(p).value == "\\nolimits")
        flag = _advance!(p).value == "\\limits" ? "limits" : "nolimits"
        base = Node(NKLimitsOverride, flag, [base])
    end

    has_sup = false; has_sub = false
    sup_node = base;  sub_node = base  # placeholders

    # Collect at most one ^ and one _, in either order.
    for _ in 1:2
        k = _current(p).kind
        if k === TKSup && !has_sup
            _advance!(p)
            sup_node = _parse_argument!(p)
            has_sup = true
        elseif k === TKSub && !has_sub
            _advance!(p)
            sub_node = _parse_argument!(p)
            has_sub = true
        else
            break
        end
    end

    if has_sup && has_sub
        return Node(NKDecorated, [base, sub_node, sup_node])
    elseif has_sup
        return Node(NKSuperscript, [base, sup_node])
    elseif has_sub
        return Node(NKSubscript, [base, sub_node])
    else
        return base
    end
end

# Parse a single primary (no script decoration).
function _parse_primary!(p::_Parser)::Node
    tok = _current(p)

    if tok.kind === TKChar
        _advance!(p)
        return Node(NKChar, tok.value)

    elseif tok.kind === TKLBrace
        return _parse_group!(p)

    elseif tok.kind === TKCommand
        return _parse_command!(p)

    elseif tok.kind === TKSpace
        _advance!(p)
        return space_node(0.0)   # ~ and explicit spaces are zero-width in math

    elseif tok.kind === TKEOF
        # Do not advance past the sentinel — leave it in place so every caller
        # that loops on _current(p).kind sees TKEOF and exits cleanly.
        return space_node(0.0)

    else
        # Anything else (unlikely in well-formed input): emit as TKChar.
        _advance!(p)
        return Node(NKChar, tok.value)
    end
end

# Read a mandatory braced word argument {name} and return the text content.
# Consumes '{', all TKChar/TKCommand tokens, and '}' (lenient: stops at EOF).
# Used to extract the environment name from \begin{pmatrix} and \end{pmatrix}.
function _read_brace_word!(p::_Parser)::String
    _current(p).kind === TKLBrace && _advance!(p)   # consume '{'
    buf = Char[]
    while _current(p).kind !== TKEOF && _current(p).kind !== TKRBrace
        tok = _advance!(p)
        append!(buf, tok.value)
    end
    _current(p).kind === TKRBrace && _advance!(p)   # consume '}'
    return String(buf)
end

# Parse the body of a matrix environment up to the matching \end{env_name}.
# Returns an NKMatrix node with value "env_name\x00nrow\x00colspec" and a flat
# row-major list of NKGroup children (one per cell).
# colspec: explicit column-spec string (e.g. "|l|c|r|") for \begin{array};
#          empty for shorthand environments (pmatrix, cases, etc.) — derived
#          automatically from info.align and the observed column count.
function _parse_matrix_body!(p::_Parser, env_name::String, colspec::String = "")::Node
    cells = Node[]   # flat row-major list of completed cells
    row_lengths = Int[]   # number of cells in each row
    current_cell = Node[]
    ncol_current = 0   # cells completed in the current row (0-based)

    function finish_cell!()
        push!(cells, Node(NKGroup, copy(current_cell)))
        empty!(current_cell)
        return ncol_current += 1
    end

    function finish_row!()
        finish_cell!()
        push!(row_lengths, ncol_current)
        return ncol_current = 0
    end

    while true
        tok = _current(p)

        if tok.kind === TKEOF
            break   # unclosed environment: lenient, keep what we have

        elseif tok.kind === TKCommand && tok.value == "\\end"
            _advance!(p)
            _read_brace_word!(p)   # consume {env_name}; we don't check it matches
            break

        elseif tok.kind === TKAmpersand
            _advance!(p)
            finish_cell!()

        elseif tok.kind === TKCommand && tok.value == "\\\\"
            _advance!(p)
            # Skip optional row-spacing argument \\[dim]
            if _current(p).kind === TKChar && _current(p).value == "["
                _advance!(p)   # consume '['
                while _current(p).kind !== TKEOF && _current(p).value != "]"
                    _advance!(p)
                end
                _current(p).kind !== TKEOF && _advance!(p)   # consume ']'
            end
            finish_row!()

        elseif tok.kind === TKSpace
            _advance!(p)   # skip whitespace in matrix bodies (math mode)

        else
            push!(current_cell, _parse_atom!(p))
        end
    end

    # Commit the last (possibly incomplete) row if non-empty.
    if !isempty(current_cell) || ncol_current > 0
        finish_row!()
    end

    nrow = length(row_lengths)
    ncol = nrow == 0 ? 0 : maximum(row_lengths)

    # Pad short rows with empty cells so the grid is rectangular.
    insert_idx = 0
    for (r, rlen) in enumerate(row_lengths)
        insert_idx += rlen
        for _ in 1:(ncol - rlen)
            insert!(cells, insert_idx + 1, Node(NKGroup, Node[]))
            insert_idx += 1
        end
    end

    # Derive colspec from env alignment if not explicitly provided.
    if isempty(colspec)
        info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
        align_ch = info.align === :left ? 'l' : 'c'
        colspec = repeat(align_ch, ncol)
    end

    return Node(NKMatrix, "$(env_name)\x00$(nrow)\x00$(colspec)", cells)
end

# Parse a command token and return the appropriate node.
function _parse_command!(p::_Parser)::Node
    tok = _advance!(p)
    cmd = tok.value

    if haskey(_SPACE_WIDTHS, cmd)
        return space_node(_SPACE_WIDTHS[cmd])

    elseif cmd ∈ ("\\kern", "\\hskip")
        return space_node(_parse_kern_dimension!(p, false))

    elseif cmd ∈ ("\\mkern", "\\mskip")
        return space_node(_parse_kern_dimension!(p, true))

    elseif cmd == "\\frac"
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKFrac, [num, den])

    elseif cmd == "\\dfrac"
        # \dfrac forces Display style regardless of nesting context (KaTeX behaviour).
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKStyleOverride, "Display", [Node(NKFrac, [num, den])])

    elseif cmd == "\\tfrac"
        # \tfrac forces Text style (inline fraction) regardless of nesting context.
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKStyleOverride, "Text", [Node(NKFrac, [num, den])])

    elseif cmd == "\\binom"
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKGenfrac, "parenleft\x00parenright", [num, den])

    elseif cmd == "\\dbinom"
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKStyleOverride, "Display", [Node(NKGenfrac, "parenleft\x00parenright", [num, den])])

    elseif cmd == "\\tbinom"
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKStyleOverride, "Text", [Node(NKGenfrac, "parenleft\x00parenright", [num, den])])

    elseif haskey(_BIG_DELIM_COMMANDS, cmd)
        # \bigl( \bigr) \Bigl[ \bigm| etc.: consume the following delimiter token.
        size_ch, cls_ch = _BIG_DELIM_COMMANDS[cmd]
        ps = _parse_delim_name!(p)
        return Node(NKBigDelim, "$(ps)\x00$(size_ch)\x00$(cls_ch)", Node[])

    elseif haskey(_STYLE_COMMANDS, cmd)
        # \displaystyle / \textstyle / \scriptstyle / \scriptscriptstyle: consume the
        # rest of the current group and render all of it at the overridden style.
        children = _parse_sequence_children!(p)
        return Node(NKStyleOverride, _STYLE_COMMANDS[cmd], [Node(NKSequence, children)])

    elseif haskey(_SIZING_MULTIPLIERS, cmd)
        # \large / \tiny etc.: consume the rest of the current group and scale it.
        children = _parse_sequence_children!(p)
        return Node(NKSizing, string(_SIZING_MULTIPLIERS[cmd]), [Node(NKSequence, children)])

    elseif cmd ∈ _XARROW_COMMANDS
        # \xrightarrow[below]{above}: optional below label, mandatory above label.
        below_node = nothing
        if _current(p).kind === TKChar && _current(p).value == "["
            _advance!(p)   # consume '['
            below_children = Node[]
            while _current(p).kind !== TKEOF && _current(p).value != "]"
                push!(below_children, _parse_atom!(p))
            end
            _current(p).value == "]" && _advance!(p)   # consume ']'
            below_node = Node(NKGroup, below_children)
        end
        above_node = _parse_argument!(p)
        children = below_node === nothing ? [above_node] : [above_node, below_node]
        return Node(NKXArrow, cmd, children)

    elseif cmd == "\\sqrt"
        # Optional degree: \sqrt[3]{x}
        if _current(p).kind === TKChar && _current(p).value == "["
            # Consume the degree argument up to the matching ']'.
            _advance!(p)   # consume '['
            deg_children = Node[]
            while _current(p).kind !== TKEOF && _current(p).value != "]"
                push!(deg_children, _parse_atom!(p))
            end
            _current(p).value == "]" && _advance!(p)  # consume ']'
            degree = Node(NKGroup, deg_children)
            body = _parse_argument!(p)
            return Node(NKSqrt, [degree, body])
        else
            body = _parse_argument!(p)
            return Node(NKSqrt, [body])
        end

    elseif cmd == "\\left"
        # \left<delim> … \right<delim>
        # Consume left delimiter and record its PS glyph name.
        left_name = _parse_delim_name!(p)
        inner = _parse_delimited_children!(p)
        # Consume \right and record the right delimiter's PS glyph name.
        right_name = ""
        if _current(p).kind === TKCommand && _current(p).value == "\\right"
            _advance!(p)
            right_name = _parse_delim_name!(p)
        end
        return Node(NKDelimited, "$(left_name)\x00$(right_name)", inner)

    elseif cmd == "\\operatorname"
        arg = _parse_argument!(p)
        return Node(NKOperator, _node_text(arg))

    elseif haskey(_ACCENT_CODEPOINTS, cmd)
        body = _parse_argument!(p)
        return Node(NKAccent, cmd, [body])

    elseif cmd == "\\overline" || cmd == "\\underline"
        body = _parse_argument!(p)
        return Node(NKOverUnder, cmd[2:end], [body])   # value = "overline" or "underline"

    elseif haskey(_FONT_SWITCH_COMMANDS, cmd)
        variant = _FONT_SWITCH_COMMANDS[cmd]
        body = _parse_argument!(p)
        return Node(NKFontSwitch, variant, [body])

    elseif cmd ∈ _HORIZ_BRACE_COMMANDS
        body = _parse_argument!(p)
        return Node(NKHorizBrace, cmd, [body])

    elseif cmd == "\\begin"
        env_name = _read_brace_word!(p)
        if haskey(_MATRIX_ENVS, env_name)
            # Environments in _COLSPEC_ENVS require an explicit column-spec argument.
            colspec = env_name ∈ _COLSPEC_ENVS ? _read_brace_word!(p) : ""
            return _parse_matrix_body!(p, env_name, colspec)
        else
            # Unknown environment: emit a sentinel so the layout engine can skip it gracefully.
            return Node(NKCommand, "\\begin{$(env_name)}")
        end

    elseif cmd == "\\end"
        # \end encountered outside a \begin context (malformed input): consume and ignore.
        _read_brace_word!(p)
        return space_node(0.0)

    elseif cmd == "\\text" || cmd == "\\mbox"
        body = _parse_text_argument!(p)
        return Node(NKText, [body])

    else
        bare = cmd[2:end]   # strip leading '\'
        return bare ∈ _OPERATOR_NAMES ? Node(NKOperator, bare) : Node(NKCommand, cmd)
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    parse_latex(tokens) -> Node

Parse a flat token stream (from `tokenize`) into an AST.
Returns an `NKSequence` node at the top level.
"""
function parse_latex(tokens::Vector{Token})::Node
    p = _Parser(tokens, 1)
    children = _parse_sequence_children!(p)
    return Node(NKSequence, children)
end

"""
    parse_latex(input) -> Node

Convenience wrapper: lex and parse in one call.
"""
function parse_latex(input::AbstractString)::Node
    return parse_latex(tokenize(input))
end
