# Structured data carried by some AST nodes in `Node.payload`.
#
#   NodeKind.Delimited, NodeKind.Genfrac   _DelimiterPairPayload
#   NodeKind.BigDelim                      _BigDelimiterPayload
#   NodeKind.Matrix                        _MatrixPayload
#
# Every other node carries `nothing`.  The accessors in ast.jl
# (`_delimiter_pair`, `_big_delimiter`, `_matrix_payload`) return a neutral
# default when a node lacks the expected payload, so layout never throws on a
# hand-built node.

"""Left and right delimiters as PostScript glyph names; `""` is a null delimiter."""
struct _DelimiterPairPayload
    left::String
    right::String
end

"""A `\\big`-family delimiter: glyph name, size 1–4 (`\\big` … `\\Bigg`), and atom class."""
struct _BigDelimiterPayload
    glyph_name::String
    size::Int
    atom_class::Char   # 'o' open, 'c' close, 'r' relation, 'd' ordinary
end

"""
A matrix-like environment: its name, row count, column specification (verbatim
for `array`, derived for the others), and `row_gaps[r]`, the `\\\\[len]`
argument after row `r` in em (0.0 without one).
"""
struct _MatrixPayload
    env_name::String
    nrow::Int
    colspec::String
    row_gaps::Vector{Float64}
end

_MatrixPayload(env_name, nrow, colspec) = _MatrixPayload(env_name, nrow, colspec, zeros(nrow))

const _NodePayload = Union{Nothing, _DelimiterPairPayload, _BigDelimiterPayload, _MatrixPayload}

# Payloads compare and hash by value (`_MatrixPayload` holds a vector, which
# the default `===`-based equality would compare by identity).
for T in (:_DelimiterPairPayload, :_BigDelimiterPayload, :_MatrixPayload)
    @eval Base.:(==)(a::$T, b::$T) = all(getfield(a, i) == getfield(b, i) for i in 1:fieldcount($T))
    @eval Base.hash(p::$T, h::UInt) = hash(ntuple(i -> getfield(p, i), fieldcount($T)), hash($T, h))
end
