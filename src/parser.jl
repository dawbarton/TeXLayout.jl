# LaTeX parser: token stream → AST.
#
# Produces a typed tree of `Node` values.  The parser handles grouping,
# sub/superscripts, fractions, roots, and a small set of core commands.
# Atom classification (mord/mbin/mrel/…) is deferred to the layout engine
# so that the parser remains context-free.

# ── Recursive-descent implementation ─────────────────────────────────────────

mutable struct _Parser
    tokens::Vector{Token}
    pos::Int
end

# Characters that may start or continue the number of a TeX dimension.
const _DIMEN_NUMBER_CHARS = "0123456789.+-"

# Parse a TeX dimension after \kern / \mkern / \hskip / \mskip and return its
# value in em units.  Supports a braced form (\kern{1em}) and an unbraced form
# (\kern1em).  Only "em" and "mu" units are recognised; anything else yields 0.
# One math unit (mu) = 1/18 em by the standard TeX convention.
function _parse_kern_dimension!(p::_Parser, mu_units::Bool)::Float64
    # `\kern 1em`: TeX drops the space after a control word.  Look past it only
    # when a dimension follows, so letters in malformed `\kern x` stay content.
    n = _ignorable_space_run(p)
    next_tok = _peek(p, n)
    if next_tok.kind === TokenKind.LBrace ||
            (next_tok.kind === TokenKind.Char && only(next_tok.value) ∈ _DIMEN_NUMBER_CHARS)
        p.pos += n
    end
    braced = _current(p).kind === TokenKind.LBrace
    braced && _advance!(p)   # consume '{'

    # Collect sign + digits + decimal point.
    num = Char[]
    while _current(p).kind === TokenKind.Char
        c = only(_current(p).value)
        c ∈ _DIMEN_NUMBER_CHARS || break
        push!(num, c); _advance!(p)
    end

    # Collect exactly 2 letter chars for the unit (em, mu, ex, pt, …).
    unit = Char[]
    for _ in 1:2
        _current(p).kind === TokenKind.Char || break
        c = only(_current(p).value)
        isletter(c) || break
        push!(unit, c); _advance!(p)
    end

    braced && _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'

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
# Look ahead `n` tokens without consuming; clamps to the EOF sentinel.
@inline _peek(p::_Parser, n::Int = 1) = p.tokens[min(p.pos + n, lastindex(p.tokens))]

# A Space token the math parser may skip: ordinary whitespace (space/tab/
# newline runs), which is insignificant in math mode.  The non-breaking space
# `~` is also lexed as a Space token but is significant, so it is excluded here
# and instead emitted as a normal interword space by `_parse_primary!`.
@inline _is_ignorable_space(tok::Token) = tok.kind === TokenKind.Space && tok.value != "~"

function _skip_ignorable_spaces!(p::_Parser)
    while _is_ignorable_space(_current(p))
        _advance!(p)
    end
    return nothing
end

# Number of ignorable Space tokens starting at the current position.  Used to
# look past whitespace without consuming it when the following token decides
# whether the whitespace is significant.
function _ignorable_space_run(p::_Parser)::Int
    n = 0
    while _is_ignorable_space(_peek(p, n))
        n += 1
    end
    return n
end

# Expression parsers leave their boundary token unconsumed for the caller that
# owns it. Explicit braced groups always establish a fresh `}` boundary, while
# implicit declaration bodies inherit the surrounding expression boundary.
@inline _is_group_end(tok::Token) = tok.kind === TokenKind.RBrace

# Consume the delimiter token following \left or \right and return its PS glyph
# name (e.g. "parenleft").  Returns "" for unknown or null delimiters.
# Whitespace before the delimiter is skipped, so `\left (` matches `\left(`.
function _parse_delim_name!(p::_Parser)::String
    _skip_ignorable_spaces!(p)
    _current(p).kind === TokenKind.EOF && return ""
    tok = _advance!(p)
    return get(_DELIM_GLYPH_NAMES, tok.value, "")
end

# Parse atoms until \right, '}' or EOF.  The \right token is left unconsumed so
# that the caller can record the right-delimiter glyph name.  \middle<delim> inside
# the body is consumed here and emitted as a NodeKind.Middle node; the layout engine uses
# it to place an auto-sized inner delimiter at the correct position.
function _parse_delimited_children!(p::_Parser, outer_stop = _is_group_end)::Vector{Node}
    isstop(tok) = outer_stop(tok) ||
        (tok.kind === TokenKind.Command && tok.value == "\\right")
    children = Node[]
    while true
        tok = _current(p)
        _is_ignorable_space(tok) && (_advance!(p); continue)
        (tok.kind === TokenKind.EOF || isstop(tok)) && break
        if tok.kind === TokenKind.Command && tok.value == "\\middle"
            _advance!(p)   # consume \middle
            ps = _parse_delim_name!(p)
            push!(children, Node(NodeKind.Middle, ps))
        else
            push!(children, _parse_atom!(p, isstop))
        end
    end
    return children
end

# Consume one argument for a command (e.g. \frac numerator).
# A braced group is parsed as its interior sequence; single elements are
# unwrapped.  This differs from _parse_group! which preserves the NodeKind.Group
# wrapper for explicit braces that appear in a sequence.
function _parse_argument!(p::_Parser, isstop = _is_group_end)::Node
    # Ignorable whitespace before an argument is skipped, so `x^ 2` and `\frac 1 2`
    # bind to the following token rather than capturing the space.
    _skip_ignorable_spaces!(p)
    if _current(p).kind === TokenKind.LBrace
        _advance!(p)   # consume '{'
        children = _parse_sequence_children!(p)
        _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'
        length(children) == 1 && return children[1]
        return Node(NodeKind.Sequence, children)
    else
        return _parse_primary!(p, isstop)
    end
end

# Parse a braced group {…} and return NodeKind.Group with the interior children.
function _parse_group!(p::_Parser)::Node
    _advance!(p)   # consume '{'
    children = _parse_sequence_children!(p)
    _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'
    return Node(NodeKind.Group, children)
end

# Parse atoms until `isstop(token)` or EOF, returning the list of child nodes.
# The stop token is not consumed. Whitespace tokens are skipped (math mode:
# spaces are insignificant).
function _parse_expression_children!(p::_Parser, isstop)::Vector{Node}
    children = Node[]
    while true
        tok = _current(p)
        (tok.kind === TokenKind.EOF || isstop(tok)) && break
        _is_ignorable_space(tok) && (_advance!(p); continue)
        push!(children, _parse_atom!(p, isstop))
    end
    return children
end

# Parse a top-level sequence or explicit braced group. Style and sizing
# declarations inside it inherit the matching `}` boundary.
_parse_sequence_children!(p::_Parser) = _parse_expression_children!(p, _is_group_end)

# Like _parse_sequence_children! but preserves whitespace as NodeKind.Char(' ') nodes.
# Used for the argument of \text{} and \mbox{}, where spaces are significant.
function _parse_text_literal_command!(p::_Parser)::Union{Node, Nothing}
    tok = _current(p)
    tok.kind === TokenKind.Command || return nothing
    ch = get(_TEXT_LITERAL_CHARS, tok.value, nothing)
    ch === nothing && return nothing
    _advance!(p)
    return Node(NodeKind.Char, string(ch))
end

function _parse_text_sequence_children!(p::_Parser)::Vector{Node}
    children = Node[]
    while true
        k = _current(p).kind
        (k === TokenKind.EOF || k === TokenKind.RBrace) && break
        if k === TokenKind.Space
            push!(children, Node(NodeKind.Char, " "))
            _advance!(p)
        else
            literal = _parse_text_literal_command!(p)
            push!(children, literal === nothing ? _parse_atom!(p) : literal)
        end
    end
    return children
end

# Parse the braced argument of \text{} or \mbox{}, preserving spaces.  Spaces
# before the argument are math-mode whitespace, so `\text {a}` matches `\text{a}`.
function _parse_text_argument!(p::_Parser)::Node
    _skip_ignorable_spaces!(p)
    if _current(p).kind === TokenKind.LBrace
        _advance!(p)   # consume '{'
        children = _parse_text_sequence_children!(p)
        _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'
        length(children) == 1 && return children[1]
        return Node(NodeKind.Sequence, children)
    else
        literal = _parse_text_literal_command!(p)
        return literal === nothing ? _parse_primary!(p) : literal
    end
end

# \limits, \nolimits, and \displaylimits (limits in Display style only, TeX's
# default for \mathop) map to the NodeKind.LimitsOverride flag.
const _LIMITS_MODIFIERS = Dict{String, String}(
    "\\limits" => "limits",
    "\\nolimits" => "nolimits",
    "\\displaylimits" => "displaylimits",
)

@inline _is_limits_modifier(tok::Token) = tok.kind === TokenKind.Command && haskey(_LIMITS_MODIFIERS, tok.value)

# Skip whitespace between a base and its scripts (`x ^2`, `\sum \limits_{i}`),
# which TeX ignores in math mode.  The whitespace is consumed only when a script
# or limits modifier follows, so significant spaces in \text{…} bodies survive.
function _skip_spaces_before_script!(p::_Parser)
    n = _ignorable_space_run(p)
    n == 0 && return nothing
    tok = _peek(p, n)
    if tok.kind === TokenKind.Sup || tok.kind === TokenKind.Sub || _is_limits_modifier(tok)
        p.pos += n
    end
    return nothing
end

# Parse a single "atom": a primary optionally decorated with ^ and/or _.
function _parse_atom!(p::_Parser, isstop = _is_group_end)::Node
    # Ordinary whitespace is ignored at the atom level; `~` falls through to
    # _parse_primary! and becomes a normal interword space.
    _skip_ignorable_spaces!(p)

    base = _parse_primary!(p, isstop)

    # Consume explicit \limits / \nolimits / \displaylimits modifiers after the
    # primary, wrapping the base so the script branches can dispatch on it.  As
    # in TeX the last modifier wins; it replaces an existing override (including
    # the \displaylimits of \operatorname*) instead of nesting another wrapper.
    _skip_spaces_before_script!(p)
    while _is_limits_modifier(_current(p))
        flag = _LIMITS_MODIFIERS[_advance!(p).value]
        inner = base.kind === NodeKind.LimitsOverride ? base.children[1] : base
        base = Node(NodeKind.LimitsOverride, flag, [inner])
        _skip_spaces_before_script!(p)
    end

    has_sup = false; has_sub = false
    sup_node = base;  sub_node = base  # placeholders

    # Collect at most one ^ and one _, in either order.
    for _ in 1:2
        _skip_spaces_before_script!(p)
        k = _current(p).kind
        if k === TokenKind.Sup && !has_sup
            _advance!(p)
            sup_node = _parse_argument!(p, isstop)
            has_sup = true
        elseif k === TokenKind.Sub && !has_sub
            _advance!(p)
            sub_node = _parse_argument!(p, isstop)
            has_sub = true
        else
            break
        end
    end

    if has_sup && has_sub
        return Node(NodeKind.Decorated, [base, sub_node, sup_node])
    elseif has_sup
        return Node(NodeKind.Superscript, [base, sup_node])
    elseif has_sub
        return Node(NodeKind.Subscript, [base, sub_node])
    else
        return base
    end
end

@inline _is_close_bracket(tok::Token) = tok.kind === TokenKind.Char && tok.value == "]"

# Parse an optional `[…]` argument (\sqrt[n]{…}, \xrightarrow[below]{…}) and
# return it as a NodeKind.Group, or `nothing` when no `[` follows.  Like LaTeX's
# \@ifnextchar, whitespace before the `[` is skipped; whitespace inside it is
# ordinary math whitespace and must not hide the closing `]`.
function _parse_optional_bracket!(p::_Parser, isstop)::Union{Node, Nothing}
    n = _ignorable_space_run(p)
    tok = _peek(p, n)
    (tok.kind === TokenKind.Char && tok.value == "[") || return nothing
    p.pos += n + 1   # skip the whitespace and consume '['
    children = Node[]
    while true
        _skip_ignorable_spaces!(p)
        tok = _current(p)
        (tok.kind === TokenKind.EOF || isstop(tok) || _is_close_bracket(tok)) && break
        push!(children, _parse_atom!(p, isstop))
    end
    _is_close_bracket(_current(p)) && _advance!(p)   # consume ']'
    return Node(NodeKind.Group, children)
end

# A named operator such as \sin.  `value` is the name used for lookups (limits,
# tests); children spell the rendered body when it is more than the name's
# letters, e.g. `lim`, thin space, `inf` for \liminf.
function _operator_node(name::String)::Node
    words = get(_SPACED_OPERATOR_NAMES, name, nothing)
    words === nothing && return Node(NodeKind.Operator, name)
    children = Node[Node(NodeKind.Char, string(c)) for c in words[1]]
    push!(children, space_node(_SPACE_WIDTHS["\\,"]))
    append!(children, Node(NodeKind.Char, string(c)) for c in words[2])
    return Node(NodeKind.Operator, name, children)
end

# Flatten the argument of \operatorname into its rendered spelling: upright
# characters and explicit spaces (`arg\,max`).  Commands contribute their bare
# names, as in `_node_text`.
function _operator_body!(out::Vector{Node}, node::Node)::Vector{Node}
    k = node.kind
    if k === NodeKind.Char || k === NodeKind.Space
        push!(out, node)
    elseif k === NodeKind.Command
        append!(out, Node(NodeKind.Char, string(c)) for c in _node_text(node))
    elseif k === NodeKind.Sequence || k === NodeKind.Group
        foreach(c -> _operator_body!(out, c), node.children)
    end
    return out
end

# Parse a single primary (no script decoration).
function _parse_primary!(p::_Parser, isstop = _is_group_end)::Node
    tok = _current(p)

    if tok.kind === TokenKind.Char
        _advance!(p)
        return Node(NodeKind.Char, tok.value)

    elseif tok.kind === TokenKind.LBrace
        return _parse_group!(p)

    elseif tok.kind === TokenKind.Command
        return _parse_command!(p, isstop)

    elseif tok.kind === TokenKind.Space
        _advance!(p)
        # `~` is a non-breaking interword space; ordinary whitespace reaching
        # here (e.g. an empty script argument) contributes nothing.
        return space_node(tok.value == "~" ? _NORMAL_SPACE_EM : 0.0)

    elseif tok.kind === TokenKind.EOF || isstop(tok)
        # Do not advance past EOF or an expression boundary. Leave it in place
        # so the parser that owns the boundary can consume it.
        return space_node(0.0)

    else
        # Anything else (unlikely in well-formed input): emit as TokenKind.Char.
        _advance!(p)
        return Node(NodeKind.Char, tok.value)
    end
end

# Read a mandatory braced word argument {name} and return the text content.
# Consumes '{', all TokenKind.Char/TokenKind.Command tokens, and '}' (lenient: stops at EOF).
# Used to extract the environment name from \begin{pmatrix} and \end{pmatrix}.
function _read_brace_word!(p::_Parser)::String
    while _current(p).kind === TokenKind.Space
        _advance!(p)
    end
    _current(p).kind === TokenKind.LBrace && _advance!(p)   # consume '{'
    buf = Char[]
    while _current(p).kind !== TokenKind.EOF && _current(p).kind !== TokenKind.RBrace
        tok = _advance!(p)
        append!(buf, tok.value)
    end
    _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'
    return String(buf)
end

# Strip a trailing '*' so starred display environments (align*, gather*, …)
# share the layout of their unstarred form.  Equation numbering is not rendered,
# so the star has no visual effect here.
_canonical_env_name(name::AbstractString) = endswith(name, "*") ? String(chop(name)) : String(name)

# Parse the body of a matrix environment up to the matching \end{env_name}.
# Returns a NodeKind.Matrix node with encoded _MatrixPayload and a flat
# row-major list of NodeKind.Group children (one per cell).
# colspec: explicit column-spec string (e.g. "|l|c|r|") for \begin{array};
#          empty for shorthand environments (pmatrix, cases, etc.) — derived
#          automatically from info.align and the observed column count.
function _parse_matrix_body!(
        p::_Parser, env_name::String, colspec::String = "", outer_stop = _is_group_end,
    )::Node
    cells = Node[]   # flat row-major list of completed cells
    row_lengths = Int[]   # number of cells in each row
    current_cell = Node[]
    ncol_current = 0   # cells completed in the current row (0-based)

    is_cell_end(tok) = outer_stop(tok) || tok.kind === TokenKind.Ampersand ||
        (tok.kind === TokenKind.Command && tok.value ∈ ("\\\\", "\\end"))

    function finish_cell!()
        push!(cells, Node(NodeKind.Group, copy(current_cell)))
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

        if tok.kind === TokenKind.EOF
            break   # unclosed environment: lenient, keep what we have

        elseif outer_stop(tok)
            break   # malformed environment: preserve the surrounding boundary

        elseif tok.kind === TokenKind.Command && tok.value == "\\end"
            _advance!(p)
            _read_brace_word!(p)   # consume {env_name}; we don't check it matches
            break

        elseif tok.kind === TokenKind.Ampersand
            _advance!(p)
            finish_cell!()

        elseif tok.kind === TokenKind.Command && tok.value == "\\\\"
            _advance!(p)
            # Skip optional row-spacing argument \\[dim]
            if _current(p).kind === TokenKind.Char && _current(p).value == "["
                _advance!(p)   # consume '['
                while _current(p).kind !== TokenKind.EOF && _current(p).value != "]"
                    _advance!(p)
                end
                _current(p).kind !== TokenKind.EOF && _advance!(p)   # consume ']'
            end
            finish_row!()

        elseif _is_ignorable_space(tok)
            _advance!(p)   # skip whitespace in matrix bodies (math mode); `~` is kept

        else
            push!(current_cell, _parse_atom!(p, is_cell_end))
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
            insert!(cells, insert_idx + 1, Node(NodeKind.Group, Node[]))
            insert_idx += 1
        end
    end

    if env_name ∈ ("align", "aligned", "split")
        for r in 1:nrow, c in 2:2:ncol
            idx = (r - 1) * ncol + c
            cell = cells[idx]
            cells[idx] = Node(cell.kind, cell.value, [Node(NodeKind.Group, Node[]); cell.children])
        end
    end

    # Derive colspec from env alignment if not explicitly provided.
    if isempty(colspec)
        if env_name ∈ ("align", "aligned", "split")
            # alternating right/left pairs across observed column count
            colspec = String(collect(Iterators.take(Iterators.cycle("rl"), ncol)))
        elseif env_name ∈ ("gather", "gathered")
            colspec = repeat("c", ncol)
        else
            info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
            align_ch = info.align === Alignment.Left ? 'l' : 'c'
            colspec = repeat(align_ch, ncol)
        end
    end

    return Node(NodeKind.Matrix, _encode_payload(_MatrixPayload(env_name, nrow, colspec)), cells)
end

# Parse a command token and return the appropriate node.
function _parse_command!(p::_Parser, isstop = _is_group_end)::Node
    tok = _advance!(p)
    cmd = tok.value

    literal = get(_MATH_LITERAL_CHARS, cmd, nothing)
    if literal !== nothing
        return Node(NodeKind.Char, string(literal))

    elseif haskey(_SPACE_WIDTHS, cmd)
        return space_node(_SPACE_WIDTHS[cmd])

    elseif cmd ∈ ("\\kern", "\\hskip")
        return space_node(_parse_kern_dimension!(p, false))

    elseif cmd ∈ ("\\mkern", "\\mskip")
        return space_node(_parse_kern_dimension!(p, true))

    elseif cmd == "\\frac"
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        return Node(NodeKind.Frac, [num, den])

    elseif cmd == "\\dfrac"
        # \dfrac forces Display style regardless of nesting context (KaTeX behaviour).
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        return Node(NodeKind.StyleOverride, "Display", [Node(NodeKind.Frac, [num, den])])

    elseif cmd == "\\tfrac"
        # \tfrac forces Text style (inline fraction) regardless of nesting context.
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        return Node(NodeKind.StyleOverride, "Text", [Node(NodeKind.Frac, [num, den])])

    elseif cmd == "\\binom"
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        return Node(NodeKind.Genfrac, _encode_payload(_DelimiterPairPayload("parenleft", "parenright")), [num, den])

    elseif cmd == "\\dbinom"
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        payload = _encode_payload(_DelimiterPairPayload("parenleft", "parenright"))
        return Node(NodeKind.StyleOverride, "Display", [Node(NodeKind.Genfrac, payload, [num, den])])

    elseif cmd == "\\tbinom"
        num = _parse_argument!(p, isstop)
        den = _parse_argument!(p, isstop)
        payload = _encode_payload(_DelimiterPairPayload("parenleft", "parenright"))
        return Node(NodeKind.StyleOverride, "Text", [Node(NodeKind.Genfrac, payload, [num, den])])

    elseif haskey(_BIG_DELIM_COMMANDS, cmd)
        # \bigl( \bigr) \Bigl[ \bigm| etc.: consume the following delimiter token.
        size_ch, cls_ch = _BIG_DELIM_COMMANDS[cmd]
        ps = _parse_delim_name!(p)
        payload = _encode_payload(_BigDelimiterPayload(ps, parse(Int, string(size_ch)), cls_ch))
        return Node(NodeKind.BigDelim, payload, Node[])

    elseif haskey(_STYLE_COMMANDS, cmd)
        # \displaystyle / \textstyle / \scriptstyle / \scriptscriptstyle: consume the
        # rest of the current group and render all of it at the overridden style.
        children = _parse_expression_children!(p, isstop)
        return Node(NodeKind.StyleOverride, _STYLE_COMMANDS[cmd], [Node(NodeKind.Sequence, children)])

    elseif haskey(_SIZING_MULTIPLIERS, cmd)
        # \large / \tiny etc.: consume the rest of the current group and scale it.
        children = _parse_expression_children!(p, isstop)
        return Node(NodeKind.Sizing, string(_SIZING_MULTIPLIERS[cmd]), [Node(NodeKind.Sequence, children)])

    elseif cmd ∈ _XARROW_COMMANDS
        # \xrightarrow[below]{above}: optional below label, mandatory above label.
        below_node = _parse_optional_bracket!(p, isstop)
        above_node = _parse_argument!(p, isstop)
        children = below_node === nothing ? [above_node] : [above_node, below_node]
        return Node(NodeKind.XArrow, cmd, children)

    elseif cmd == "\\sqrt"
        # Optional degree: \sqrt[3]{x}
        degree = _parse_optional_bracket!(p, isstop)
        body = _parse_argument!(p, isstop)
        return degree === nothing ? Node(NodeKind.Sqrt, [body]) : Node(NodeKind.Sqrt, [degree, body])

    elseif cmd == "\\left"
        # \left<delim> … \right<delim>
        # Consume left delimiter and record its PS glyph name.
        left_name = _parse_delim_name!(p)
        inner = _parse_delimited_children!(p, isstop)
        # Consume \right and record the right delimiter's PS glyph name.
        right_name = ""
        if _current(p).kind === TokenKind.Command && _current(p).value == "\\right"
            _advance!(p)
            right_name = _parse_delim_name!(p)
        end
        return Node(NodeKind.Delimited, _encode_payload(_DelimiterPairPayload(left_name, right_name)), inner)

    elseif cmd == "\\operatorname"
        # amsopn: \operatorname* is \qopname\newmcodes@ m, i.e. limits in
        # Display style only (\displaylimits); \@ifstar skips spaces before `*`.
        n = _ignorable_space_run(p)
        starred = _peek(p, n).kind === TokenKind.Char && _peek(p, n).value == "*"
        starred && (p.pos += n + 1)
        arg = _parse_argument!(p, isstop)
        body = _operator_body!(Node[], arg)
        children = any(c -> c.kind === NodeKind.Space, body) ? body : Node[]
        op = Node(NodeKind.Operator, _node_text(arg), children)
        return starred ? Node(NodeKind.LimitsOverride, "displaylimits", [op]) : op

    elseif haskey(_ACCENT_CODEPOINTS, cmd)
        body = _parse_argument!(p, isstop)
        return Node(NodeKind.Accent, cmd, [body])

    elseif cmd == "\\overline" || cmd == "\\underline"
        body = _parse_argument!(p, isstop)
        return Node(NodeKind.OverUnder, cmd[2:end], [body])   # value = "overline" or "underline"

    elseif haskey(_FONT_SWITCH_COMMANDS, cmd)
        variant = _FONT_SWITCH_COMMANDS[cmd]
        body = _parse_argument!(p, isstop)
        return Node(NodeKind.FontSwitch, variant, [body])

    elseif cmd ∈ _HORIZ_BRACE_COMMANDS
        body = _parse_argument!(p, isstop)
        return Node(NodeKind.HorizBrace, cmd, [body])

    elseif cmd == "\\begin"
        env_name = _canonical_env_name(_read_brace_word!(p))
        if haskey(_MATRIX_ENVS, env_name)
            # Environments in _COLSPEC_ENVS require an explicit column-spec argument.
            colspec = env_name ∈ _COLSPEC_ENVS ? _read_brace_word!(p) : ""
            return _parse_matrix_body!(p, env_name, colspec, isstop)
        else
            # Unknown environment: emit a sentinel so the layout engine can skip it gracefully.
            return Node(NodeKind.Command, "\\begin{$(env_name)}")
        end

    elseif cmd == "\\end"
        # \end encountered outside a \begin context (malformed input): consume and ignore.
        _read_brace_word!(p)
        return space_node(0.0)

    elseif cmd == "\\text" || cmd == "\\mbox"
        body = _parse_text_argument!(p)
        return Node(NodeKind.Text, [body])

    elseif cmd ∈ _TEXT_STYLE_COMMANDS
        body = _parse_text_argument!(p)
        return Node(NodeKind.Text, cmd, [body])

    else
        bare = cmd[2:end]   # strip leading '\'
        return bare ∈ _OPERATOR_NAMES ? _operator_node(bare) : Node(NodeKind.Command, cmd)
    end
end

# Parse math atoms until `isstop(token)` is true or TokenKind.EOF, without consuming
# the stop token. Used by the document parser for inline ($…$, \(…\)) and display
# ($$…$$, \[…\]) math, each of which stops at a different closing delimiter.
function _parse_math_until!(p::_Parser, isstop)::Node
    children = _parse_expression_children!(p, isstop)
    return Node(NodeKind.Sequence, children)
end

# Stop at the next math-shift ($) token; used for $…$ and $$…$$ math.
_parse_math_until_shift!(p::_Parser) = _parse_math_until!(p, t -> t.kind === TokenKind.MathShift)

# Stop at a specific closing command token (e.g. "\]" or "\)").
function _parse_math_until_command!(p::_Parser, close::String)::Node
    return _parse_math_until!(p, t -> t.kind === TokenKind.Command && t.value == close)
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    parse_latex(tokens) -> Node

Parse a flat token stream (from `tokenize`) into an AST.
Returns a `NodeKind.Sequence` node at the top level.
"""
function parse_latex(tokens::Vector{Token})::Node
    p = _Parser(tokens, 1)
    children = _parse_sequence_children!(p)
    return Node(NodeKind.Sequence, children)
end

"""
    parse_latex(input) -> Node

Convenience wrapper: lex and parse in one call.
"""
function parse_latex(input::AbstractString)::Node
    return parse_latex(tokenize(input))
end

# Advance past all tokens up to and including the matching \end{…}.
# Used by parse_environment! when the environment name is unrecognised.
function _skip_to_end_env!(p::_Parser, env_name::String)
    while _current(p).kind !== TokenKind.EOF
        if _current(p).kind === TokenKind.Command && _current(p).value == "\\end"
            _advance!(p)
            _read_brace_word!(p)   # consume {name}; correctness not checked
            return
        end
        _advance!(p)
    end
    return
end

"""
    parse_environment!(p, env_name) -> Node

Parse the body of a known environment, returning its Node. `p` must be
positioned immediately after the `{env_name}` token that follows `\\begin`.
Called by the document parser after it has consumed `\\begin{env_name}`.
"""
function parse_environment!(p::_Parser, env_name::String)::Node
    env_name = _canonical_env_name(env_name)
    if haskey(_MATRIX_ENVS, env_name)
        colspec = env_name ∈ _COLSPEC_ENVS ? _read_brace_word!(p) : ""
        return _parse_matrix_body!(p, env_name, colspec)
    else
        _skip_to_end_env!(p, env_name)
        return Node(NodeKind.Sequence, Node[])
    end
end
