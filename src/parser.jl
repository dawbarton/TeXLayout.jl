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
    NKSqrt          # \sqrt[degree]{body}
    NKDelimited     # \left…\right pair; value = "left_ps_name\x00right_ps_name"
    NKAccent        # \hat, \bar, \vec, etc.
    NKOverUnder     # \overline / \underline; value is "overline" or "underline"
    NKCommand        # unrecognised command or atom-producing command (\alpha, \int, …)
    NKSpace          # explicit space token (\, \; \quad etc.)
    NKText           # \text{…} — text-mode fragment
    NKOperator       # named math operator rendered upright: \sin, \cos, \operatorname{…}
    NKLimitsOverride # \limits / \nolimits: wraps a base; value is "limits" or "nolimits"
    NKFontSwitch     # \mathbf{…}, \mathit{…}, etc.; value = variant name; children[1] = body
end

"""
An AST node.  Leaf nodes (chars, spaces, standalone commands) have an empty
`children` vector and carry their source text in `value`.  Interior nodes
carry children and may carry auxiliary text in `value` (e.g. the command name
for `NKAccent`).
"""
struct Node
    kind::NodeKind
    value::String           # source text for leaf nodes; command name for interior
    children::Vector{Node}
end

# Convenience constructors
Node(kind::NodeKind, value::String) = Node(kind, value, Node[])
Node(kind::NodeKind, children::Vector{Node}) = Node(kind, "", children)

# Explicit horizontal spacing commands mapped to their width in em units.
# Thin/medium/thick spaces use TeX's 18-mu-per-em convention (3, 4, 5 mu).
const _SPACE_WIDTHS = Dict{String,Float64}(
    "\\,"             =>  3/18,   # thin space
    "\\thinspace"     =>  3/18,
    "\\:"             =>  4/18,   # medium space
    "\\medspace"      =>  4/18,
    "\\;"             =>  5/18,   # thick space
    "\\thickspace"    =>  5/18,
    "\\!"             => -3/18,   # negative thin space
    "\\negthinspace"  => -3/18,
    "\\negmedspace"   => -4/18,
    "\\negthickspace" => -5/18,
    "\\enspace"       =>  0.5,
    "\\quad"          =>  1.0,
    "\\qquad"         =>  2.0,
)

# Mapping from delimiter token text to OpenType PostScript glyph name.
# The "." null delimiter (e.g. \left. or \right.) maps to an empty string.
const _DELIM_GLYPH_NAMES = Dict{String,String}(
    "("          => "parenleft",
    ")"          => "parenright",
    "["          => "bracketleft",
    "]"          => "bracketright",
    "\\{"        => "braceleft",
    "\\}"        => "braceright",
    "|"          => "bar",
    "\\|"        => "dblverticalbar",
    "/"          => "slash",
    "\\backslash" => "backslash",
    "\\langle"   => "angleleft",
    "\\rangle"   => "angleright",
    "\\lfloor"   => "uni230A",
    "\\rfloor"   => "uni230B",
    "\\lceil"    => "uni2308",
    "\\rceil"    => "uni2309",
    "."          => "",   # null delimiter — renders nothing
)

# Math accent commands mapped to the Unicode codepoint of the accent glyph.
# Codepoints follow KaTeX's symbols.ts.  The layout engine looks up the PS glyph
# name via the font's cmap so that the correct variant is used in each math font.
# Wide/stretchy accents (\widehat, \widetilde) are excluded; they need horizontal
# extensible constructions and are not yet implemented.
const _ACCENT_CODEPOINTS = Dict{String,UInt32}(
    "\\hat"      => 0x02C6,   # ˆ MODIFIER LETTER CIRCUMFLEX ACCENT (has MathTopAccentAttachment; U+005E asciicircum does not)
    "\\acute"    => 0x00B4,   # ´ ACUTE ACCENT (Latin-1; U+02CA absent in most math fonts)
    "\\grave"    => 0x0060,   # ` GRAVE ACCENT (ASCII; U+02CB absent in most math fonts)
    "\\ddot"     => 0x00A8,   # ¨ DIAERESIS
    "\\tilde"    => 0x02DC,   # ˜ SMALL TILDE (has MathTopAccentAttachment; U+007E asciitilde does not)
    "\\bar"      => 0x00AF,   # ¯ MACRON (Latin-1; U+02C9 absent in most math fonts)
    "\\breve"    => 0x02D8,   # ˘ BREVE
    "\\check"    => 0x02C7,   # ˇ CARON
    "\\dot"      => 0x02D9,   # ˙ DOT ABOVE
    "\\mathring" => 0x02DA,   # ˚ RING ABOVE
    "\\vec"      => 0x20D7,   # ⃗ COMBINING RIGHT ARROW ABOVE
)

# Font-switching commands mapped to their variant name.
# The variant name is passed as `value` in the NKFontSwitch node and is used by
# the layout engine to select the correct Unicode math-variant codepoints.
const _FONT_SWITCH_COMMANDS = Dict{String,String}(
    "\\mathbf"      => "mathbf",
    "\\mathit"      => "mathit",
    "\\mathrm"      => "mathrm",
    "\\mathbb"      => "mathbb",
    "\\mathcal"     => "mathcal",
    "\\mathfrak"    => "mathfrak",
    "\\mathscr"     => "mathscr",
    "\\mathsf"      => "mathsf",
    "\\mathtt"      => "mathtt",
    "\\boldsymbol"  => "boldsymbol",
    "\\bm"          => "boldsymbol",
    "\\mathnormal"  => "mathnormal",
    "\\mathsfit"    => "mathsfit",
    "\\Bbb"         => "mathbb",    # AMS alias for \mathbb
    "\\bold"        => "mathbf",    # KaTeX alias for \mathbf
    "\\frak"        => "mathfrak",  # KaTeX alias for \mathfrak
)

# Standard named math operators rendered as upright multi-character strings.
const _OPERATOR_NAMES = Set{String}([
    "sin", "cos", "tan", "cot", "sec", "csc",
    "arcsin", "arccos", "arctan",
    "ln", "log", "exp",
    "lim", "limsup", "liminf", "sup", "inf", "max", "min",
    "det", "dim", "ker", "deg", "gcd", "hom", "Pr", "arg",
])

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
# that the caller can record the right-delimiter glyph name.
function _parse_delimited_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        (k === TKEOF || k === TKRBrace) && break
        k === TKCommand && _current(p).value == "\\right" && break
        push!(children, _parse_atom!(p))
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
function _parse_sequence_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        (k === TKEOF || k === TKRBrace) && break
        push!(children, _parse_atom!(p))
    end
    return children
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
            has_sup  = true
        elseif k === TKSub && !has_sub
            _advance!(p)
            sub_node = _parse_argument!(p)
            has_sub  = true
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
        return Node(NKSpace, "0.0")   # ~ and explicit spaces are zero-width in math

    elseif tok.kind === TKEOF
        # Do not advance past the sentinel — leave it in place so every caller
        # that loops on _current(p).kind sees TKEOF and exits cleanly.
        return Node(NKSpace, "0.0")

    else
        # Anything else (unlikely in well-formed input): emit as TKChar.
        _advance!(p)
        return Node(NKChar, tok.value)
    end
end

# Parse a command token and return the appropriate node.
function _parse_command!(p::_Parser)::Node
    tok = _advance!(p)
    cmd = tok.value

    if haskey(_SPACE_WIDTHS, cmd)
        return Node(NKSpace, string(_SPACE_WIDTHS[cmd]))

    elseif cmd ∈ ("\\kern", "\\hskip")
        w = _parse_kern_dimension!(p, false)
        return Node(NKSpace, string(w))

    elseif cmd ∈ ("\\mkern", "\\mskip")
        w = _parse_kern_dimension!(p, true)
        return Node(NKSpace, string(w))

    elseif cmd == "\\frac"
        num = _parse_argument!(p)
        den = _parse_argument!(p)
        return Node(NKFrac, [num, den])

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
            body   = _parse_argument!(p)
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
        body    = _parse_argument!(p)
        return Node(NKFontSwitch, variant, [body])

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
    parse_latex(tokenize(input))
end
