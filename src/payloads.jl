# Encoded AST payload helpers.
#
# Node currently stores auxiliary data in `value::String`.  These helpers keep
# the wire format in one place while the AST migrates toward typed node payloads.

const _PAYLOAD_SEPARATOR = '\x00'

struct _DelimiterPairPayload
    left::String
    right::String
end

struct _BigDelimiterPayload
    glyph_name::String
    size::Int
    atom_class::Char
end

struct _MatrixPayload{E <: AbstractString, C <: AbstractString}
    env_name::E
    nrow::Int
    colspec::C
end

_payload_before(value::AbstractString, i::Integer) =
    i == firstindex(value) ? "" : String(value[firstindex(value):prevind(value, i)])

_payload_after(value::AbstractString, i::Integer) =
    i == lastindex(value) ? "" : String(value[nextind(value, i):lastindex(value)])

_encode_payload(p::_DelimiterPairPayload) =
    string(p.left, _PAYLOAD_SEPARATOR, p.right)

function _decode_delimiter_pair_payload(value::AbstractString)::_DelimiterPairPayload
    sep = findfirst(_PAYLOAD_SEPARATOR, value)
    sep === nothing && return _DelimiterPairPayload(String(value), "")
    return _DelimiterPairPayload(_payload_before(value, sep), _payload_after(value, sep))
end

_encode_payload(p::_BigDelimiterPayload) =
    string(p.glyph_name, _PAYLOAD_SEPARATOR, p.size, _PAYLOAD_SEPARATOR, p.atom_class)

function _decode_big_delimiter_payload(value::AbstractString)::_BigDelimiterPayload
    sep1 = findfirst(_PAYLOAD_SEPARATOR, value)
    sep2 = findlast(_PAYLOAD_SEPARATOR, value)
    (sep1 === nothing || sep2 === nothing || sep1 === sep2) &&
        return _BigDelimiterPayload("", 0, 'd')
    glyph_name = _payload_before(value, sep1)
    size_str = String(value[nextind(value, sep1):prevind(value, sep2)])
    size = something(tryparse(Int, size_str), 0)
    atom_class_str = _payload_after(value, sep2)
    atom_class = isempty(atom_class_str) ? 'd' : first(atom_class_str)
    return _BigDelimiterPayload(glyph_name, size, atom_class)
end

_encode_payload(p::_MatrixPayload) =
    string(p.env_name, _PAYLOAD_SEPARATOR, p.nrow, _PAYLOAD_SEPARATOR, p.colspec)

function _decode_matrix_payload(value::AbstractString)
    parts = split(value, _PAYLOAD_SEPARATOR; limit = 3)
    length(parts) < 3 && return _MatrixPayload("", 0, "")
    nrow = something(tryparse(Int, parts[2]), 0)
    return _MatrixPayload(parts[1], nrow, parts[3])
end
