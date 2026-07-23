# Document AST and parser: mixed text/math input → Document (Vector{Block}).
#
# Sits above the math parser (parser.jl) and below the composition layer
# (compose.jl).  Significant spaces, line breaks (\\), inline math ($…$), and
# display-math environments (\begin{align}…) are all handled here.

# ── Data types ────────────────────────────────────────────────────────────────

"""A maximal run of characters sharing one set of TextAttrs."""
struct TextSpan
    text::String
    attrs::TextAttrs
end

abstract type Run end

"""Contiguous text on a line, held as spans so a shaper can kern/ligate per span."""
struct TextRun <: Run
    spans::Vector{TextSpan}
end

"""Inline math (`\$…\$`), laid out by the existing math engine at `style`."""
struct MathRun <: Run
    node::Node
    style::TexStyle   # always Text for inline $…$
end

"""One typeset line: a horizontal sequence of runs sharing a baseline."""
struct Line
    runs::Vector{Run}
end

abstract type Block end

"""A run of text lines split on top-level \\."""
struct ParagraphBlock <: Block
    lines::Vector{Line}
end

"""A display-math environment occupying its own vertical space."""
struct DisplayBlock <: Block
    node::Node     # NodeKind.Matrix (align/aligned/gather/equation) or NodeKind.Sequence
    kind::Symbol   # :align | :aligned | :gather | :equation
end

"""A blank-line paragraph break between document blocks."""
struct ParagraphBreakBlock <: Block end

"""A parsed document: an ordered sequence of paragraph and display blocks."""
const Document = Vector{Block}

# ── Builder and flush helpers ─────────────────────────────────────────────────

mutable struct _DocBuilder
    blocks::Vector{Block}
    cur_lines::Vector{Line}
    cur_runs::Vector{Run}
    cur_spans::Vector{TextSpan}
    buf::IOBuffer
    attrs::TextAttrs
    pending_space::Bool    # a top-level inter-word space awaiting content
    pending_nbsp::Bool     # the pending space contains a `~` (non-breaking)
    at_line_start::Bool    # suppress leading whitespace at this position
end

# Commit a deferred top-level inter-word space (honouring leading-whitespace
# suppression) before writing content.  Call at the start of every top-level
# content-producing branch.  Inside a group `pending_space` is already false, so
# this is a harmless no-op there.  A non-breaking (`~`) space is significant and
# is emitted even at a line start, where ordinary whitespace would be dropped.
function _commit_space!(b::_DocBuilder)
    if b.pending_space
        (b.pending_nbsp || !b.at_line_start) && write(b.buf, " ")
        b.pending_space = false
        b.pending_nbsp = false
    end
    b.at_line_start = false
    return
end

# A line / block boundary: drop any trailing deferred space and suppress the
# leading whitespace of whatever comes next.
function _begin_line_boundary!(b::_DocBuilder)
    b.pending_space = false
    b.pending_nbsp = false
    b.at_line_start = true
    return
end

function _flush_span!(b::_DocBuilder)
    s = String(take!(b.buf))   # take! reads and resets the buffer atomically
    isempty(s) && return
    return push!(b.cur_spans, TextSpan(s, b.attrs))
end

function _flush_text_run!(b::_DocBuilder)
    _flush_span!(b)
    isempty(b.cur_spans) && return
    push!(b.cur_runs, TextRun(copy(b.cur_spans)))
    return empty!(b.cur_spans)
end

function _end_line!(b::_DocBuilder)
    b.pending_nbsp && _commit_space!(b)   # keep a trailing non-breaking space
    _flush_text_run!(b)
    push!(b.cur_lines, Line(copy(b.cur_runs)))
    empty!(b.cur_runs)
    _begin_line_boundary!(b)
    return
end

function _end_paragraph!(b::_DocBuilder)
    _end_line!(b)
    nonempty = filter(l -> !isempty(l.runs), b.cur_lines)
    !isempty(nonempty) && push!(b.blocks, ParagraphBlock(nonempty))
    return empty!(b.cur_lines)
end

function _push_paragraph_break!(b::_DocBuilder)
    _end_paragraph!(b)
    isempty(b.blocks) && return nothing
    b.blocks[end] isa ParagraphBreakBlock && return nothing
    push!(b.blocks, ParagraphBreakBlock())
    return nothing
end

# ── Font-switch helpers ───────────────────────────────────────────────────────

# Environments that the document layer treats as free-standing display blocks.
# Shared with the layout layer (see `_DISPLAY_MATH_ENVS` in parser_tables.jl).
const _DISPLAY_ENVS = _DISPLAY_MATH_ENVS
const _BLANK_LINE_RE = r"\n[ \t\r\f\v]*\n"

# ── Recursive text-mode parser ────────────────────────────────────────────────

# Handle a single {…} group, applying new_attrs inside it, then restoring.
# Called with `{` as the current token in all three calling contexts:
#   - font-switch command (new_attrs differs from builder.attrs)
#   - \text / \mbox (new_attrs == builder.attrs, just a grouping scope)
#   - bare { (new_attrs == builder.attrs, plain grouping)
function _parse_text_group!(p::_Parser, builder::_DocBuilder, new_attrs::TextAttrs)
    _flush_span!(builder)
    old_attrs = builder.attrs
    builder.attrs = new_attrs
    _current(p).kind === TokenKind.LBrace && _advance!(p)   # consume '{'
    _parse_text_body!(p, builder, true)             # stop at matching '}'
    _flush_span!(builder)
    builder.attrs = old_attrs
    return _current(p).kind === TokenKind.RBrace && _advance!(p)   # consume '}'
end

# Core text-mode dispatch loop.
# `in_group`: when true, stop at the next TokenKind.RBrace (matching the group's '{').
function _parse_text_body!(p::_Parser, builder::_DocBuilder, in_group::Bool)
    while true
        tok = _current(p)
        tok.kind === TokenKind.EOF && break
        in_group && tok.kind === TokenKind.RBrace && break

        if tok.kind === TokenKind.Char
            in_group || _commit_space!(builder)
            write(builder.buf, tok.value)
            _advance!(p)

        elseif tok.kind === TokenKind.Space
            if in_group
                write(builder.buf, " ")              # significant inside {…}
            elseif tok.value == "~"
                # Non-breaking space: a significant inter-word space that must not
                # be dropped at a line/block boundary.  It still collapses with
                # adjacent ordinary whitespace into a single space.
                builder.pending_space = true
                builder.pending_nbsp = true
            elseif occursin(_BLANK_LINE_RE, tok.value)
                _advance!(p)
                _push_paragraph_break!(builder)
                continue
            else
                builder.pending_space = true         # defer; commit when content follows
            end
            _advance!(p)

        elseif tok.kind === TokenKind.MathShift
            if !in_group && _peek(p).kind === TokenKind.MathShift
                # $$…$$ display math (free-standing block).
                _advance!(p); _advance!(p)   # consume opening $$
                _end_paragraph!(builder)
                node = _parse_math_until_shift!(p)
                _current(p).kind === TokenKind.MathShift && _advance!(p)   # consume closing $
                _current(p).kind === TokenKind.MathShift && _advance!(p)   # …$
                push!(builder.blocks, DisplayBlock(node, :displaymath))
            else
                # $…$ inline math.
                in_group || _commit_space!(builder)
                _advance!(p)   # consume opening $
                _flush_text_run!(builder)
                node = _parse_math_until_shift!(p)
                _current(p).kind === TokenKind.MathShift && _advance!(p)   # consume closing $
                push!(builder.cur_runs, MathRun(node, Text))
            end

        elseif tok.kind === TokenKind.Command && tok.value == "\\[" && !in_group
            # \[…\] display math (free-standing block).
            _advance!(p)   # consume \[
            _end_paragraph!(builder)
            node = _parse_math_until_command!(p, "\\]")
            _current(p).value == "\\]" && _advance!(p)   # consume \]
            push!(builder.blocks, DisplayBlock(node, :displaymath))

        elseif tok.kind === TokenKind.Command && tok.value == "\\("
            # \(…\) inline math.
            in_group || _commit_space!(builder)
            _advance!(p)   # consume \(
            _flush_text_run!(builder)
            node = _parse_math_until_command!(p, "\\)")
            _current(p).value == "\\)" && _advance!(p)   # consume \)
            push!(builder.cur_runs, MathRun(node, Text))

        elseif tok.kind === TokenKind.Command && tok.value == "\\\\"
            _advance!(p)
            _end_line!(builder)

        elseif tok.kind === TokenKind.Command && tok.value == "\\begin"
            _advance!(p)
            env_name = _canonical_env_name(_read_brace_word!(p))
            if env_name ∈ _DISPLAY_ENVS
                _end_paragraph!(builder)
                node = parse_environment!(p, env_name)
                push!(builder.blocks, DisplayBlock(node, Symbol(env_name)))
            else
                in_group || _commit_space!(builder)
                _flush_text_run!(builder)
                node = parse_environment!(p, env_name)
                push!(builder.cur_runs, MathRun(node, Text))
            end

        elseif tok.kind === TokenKind.Command && tok.value ∈ _TEXT_STYLE_COMMANDS
            in_group || _commit_space!(builder)
            cmd = _advance!(p).value
            _parse_text_group!(p, builder, _apply_text_style(cmd, builder.attrs))

        elseif tok.kind === TokenKind.Command && (tok.value == "\\text" || tok.value == "\\mbox")
            in_group || _commit_space!(builder)
            _advance!(p)
            _parse_text_group!(p, builder, builder.attrs)   # no attr change

        elseif tok.kind === TokenKind.LBrace
            in_group || _commit_space!(builder)
            _parse_text_group!(p, builder, builder.attrs)   # bare grouping

        elseif tok.kind === TokenKind.Sup || tok.kind === TokenKind.Sub ||
                tok.kind === TokenKind.Ampersand || tok.kind === TokenKind.RBrace
            # These have no scripting/alignment meaning in text mode; render the
            # literal character (^, _, &, }) instead of silently dropping it.
            in_group || _commit_space!(builder)
            write(builder.buf, tok.value)
            _advance!(p)

        else
            _advance!(p)   # unknown command, stray token — skip
        end
    end
    return
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    parse_document(input) -> Document

Parse a mixed text/math string into a `Document` (a `Vector{Block}`).

Text mode is the default; inline math is delimited by `\$…\$`; display-math
blocks (`\\begin{align}`, `\\begin{equation}`, etc.) appear without `\$`
delimiters. Line breaks within a paragraph are created with `\\\\`.
"""
function parse_document(input::AbstractString)::Document
    p = _Parser(tokenize(input), 1)
    builder = _DocBuilder(Block[], Line[], Run[], TextSpan[], IOBuffer(), TextAttrs(), false, false, true)
    _parse_text_body!(p, builder, false)
    _end_paragraph!(builder)
    while !isempty(builder.blocks) && builder.blocks[end] isa ParagraphBreakBlock
        pop!(builder.blocks)
    end
    return builder.blocks
end
