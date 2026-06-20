# Document AST and parser: mixed text/math input → Document (Vector{Block}).
#
# Sits above the math parser (parser.jl) and below the composition layer
# (compose.jl).  Significant spaces, line breaks (\\), inline math ($…$), and
# display-math environments (\begin{align}…) are all handled here.

# ── Data types ────────────────────────────────────────────────────────────────

"""Font attributes for a run of text. `size` is an em multiplier (1.0 = body)."""
struct TextAttrs
    slot::FontSlot.T
    size::Float64
end
TextAttrs() = TextAttrs(FontSlot.Regular, 1.0)

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
    node::Node     # NKMatrix (align/aligned/gather/equation) or NKSequence
    kind::Symbol   # :align | :aligned | :gather | :equation
end

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
    _flush_text_run!(b)
    push!(b.cur_lines, Line(copy(b.cur_runs)))
    return empty!(b.cur_runs)
end

function _end_paragraph!(b::_DocBuilder)
    _end_line!(b)
    nonempty = filter(l -> !isempty(l.runs), b.cur_lines)
    !isempty(nonempty) && push!(b.blocks, ParagraphBlock(nonempty))
    return empty!(b.cur_lines)
end

# ── Font-switch helpers ───────────────────────────────────────────────────────

# Commands that change the text font slot and are followed by a braced group.
const _TEXT_FONT_SWITCH_CMDS = Set{String}(
    [
        "\\textbf",
        "\\textit",
        "\\textrm",
        "\\textnormal",
        "\\emph",
        "\\textsf",
        "\\texttt",
    ]
)

# Environments that the document layer treats as free-standing display blocks.
const _DISPLAY_ENVS = Set{String}(["align", "aligned", "gather", "equation"])

# Compute new TextAttrs by applying a font-switch command to the current attrs.
function _apply_font_switch(cmd::String, attrs::TextAttrs)::TextAttrs
    slot = attrs.slot
    bold = slot === FontSlot.Bold || slot === FontSlot.BoldItalic
    italic = slot === FontSlot.Italic || slot === FontSlot.BoldItalic

    if cmd == "\\textbf"
        bold = true
    elseif cmd == "\\textit"
        italic = true
    elseif cmd == "\\emph"
        italic = !italic   # toggle
    elseif cmd == "\\textrm" || cmd == "\\textnormal"
        bold = false
        italic = false
        # \\textsf / \\texttt: v1 maps to regular slot — no change to bold/italic
    end

    new_slot = bold && italic ? FontSlot.BoldItalic :
        bold ? FontSlot.Bold :
        italic ? FontSlot.Italic : FontSlot.Regular
    return TextAttrs(new_slot, attrs.size)
end

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
    _current(p).kind === TKLBrace && _advance!(p)   # consume '{'
    _parse_text_body!(p, builder, true)             # stop at matching '}'
    _flush_span!(builder)
    builder.attrs = old_attrs
    return _current(p).kind === TKRBrace && _advance!(p)   # consume '}'
end

# Core text-mode dispatch loop.
# `in_group`: when true, stop at the next TKRBrace (matching the group's '{').
function _parse_text_body!(p::_Parser, builder::_DocBuilder, in_group::Bool)
    while true
        tok = _current(p)
        tok.kind === TKEOF && break
        in_group && tok.kind === TKRBrace && break

        if tok.kind === TKChar
            write(builder.buf, tok.value)
            _advance!(p)

        elseif tok.kind === TKSpace
            write(builder.buf, " ")
            _advance!(p)

        elseif tok.kind === TKMathShift
            _advance!(p)   # consume opening $
            _flush_text_run!(builder)
            node = _parse_math_until_shift!(p)
            _current(p).kind === TKMathShift && _advance!(p)   # consume closing $
            push!(builder.cur_runs, MathRun(node, Text))

        elseif tok.kind === TKCommand && tok.value == "\\\\"
            _advance!(p)
            _end_line!(builder)

        elseif tok.kind === TKCommand && tok.value == "\\begin"
            _advance!(p)
            env_name = _read_brace_word!(p)
            if env_name ∈ _DISPLAY_ENVS
                _end_paragraph!(builder)
                node = parse_environment!(p, env_name)
                push!(builder.blocks, DisplayBlock(node, Symbol(env_name)))
            else
                _flush_text_run!(builder)
                node = parse_environment!(p, env_name)
                push!(builder.cur_runs, MathRun(node, Text))
            end

        elseif tok.kind === TKCommand && tok.value ∈ _TEXT_FONT_SWITCH_CMDS
            cmd = _advance!(p).value
            _parse_text_group!(p, builder, _apply_font_switch(cmd, builder.attrs))

        elseif tok.kind === TKCommand && (tok.value == "\\text" || tok.value == "\\mbox")
            _advance!(p)
            _parse_text_group!(p, builder, builder.attrs)   # no attr change

        elseif tok.kind === TKLBrace
            _parse_text_group!(p, builder, builder.attrs)   # bare grouping

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
    builder = _DocBuilder(Block[], Line[], Run[], TextSpan[], IOBuffer(), TextAttrs())
    _parse_text_body!(p, builder, false)
    _end_paragraph!(builder)
    return builder.blocks
end
