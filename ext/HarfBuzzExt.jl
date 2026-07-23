module HarfBuzzExt

import HarfBuzz_jll
import TeXLayout
import TeXLayout: shape_span
using Unicode

const _HB = HarfBuzz_jll.libharfbuzz

struct _HBGlyphInfo
    codepoint::UInt32
    mask::UInt32
    cluster::UInt32
    var1::UInt32
    var2::UInt32
end

struct _HBGlyphPosition
    x_advance::Int32
    y_advance::Int32
    x_offset::Int32
    y_offset::Int32
    var::UInt32
end

struct _HBGlyphExtents
    x_bearing::Int32
    y_bearing::Int32
    width::Int32
    height::Int32
end

struct _HBFeature
    tag::UInt32
    value::UInt32
    start::UInt32
    stop::UInt32
end

mutable struct _HBFont
    blob::Ptr{Cvoid}
    face::Ptr{Cvoid}
    font::Ptr{Cvoid}
    upm::Float64
end

const _FONT_CACHE = Dict{String, _HBFont}()
const _FEATURE_CACHE = Dict{Tuple{String, UInt32}, Bool}()

_hb_blob_create_from_file(path::String) =
    ccall((:hb_blob_create_from_file_or_fail, _HB), Ptr{Cvoid}, (Cstring,), path)

_hb_blob_destroy(blob::Ptr{Cvoid}) =
    ccall((:hb_blob_destroy, _HB), Cvoid, (Ptr{Cvoid},), blob)

_hb_face_create(blob::Ptr{Cvoid}) =
    ccall((:hb_face_create, _HB), Ptr{Cvoid}, (Ptr{Cvoid}, UInt32), blob, UInt32(0))

_hb_face_destroy(face::Ptr{Cvoid}) =
    ccall((:hb_face_destroy, _HB), Cvoid, (Ptr{Cvoid},), face)

_hb_face_get_upem(face::Ptr{Cvoid}) =
    ccall((:hb_face_get_upem, _HB), UInt32, (Ptr{Cvoid},), face)

_hb_font_create(face::Ptr{Cvoid}) =
    ccall((:hb_font_create, _HB), Ptr{Cvoid}, (Ptr{Cvoid},), face)

_hb_font_destroy(font::Ptr{Cvoid}) =
    ccall((:hb_font_destroy, _HB), Cvoid, (Ptr{Cvoid},), font)

_hb_font_set_scale(font::Ptr{Cvoid}, x_scale::Integer, y_scale::Integer) =
    ccall((:hb_font_set_scale, _HB), Cvoid, (Ptr{Cvoid}, Int32, Int32), font, x_scale, y_scale)

_hb_ot_font_set_funcs(font::Ptr{Cvoid}) =
    ccall((:hb_ot_font_set_funcs, _HB), Cvoid, (Ptr{Cvoid},), font)

_hb_buffer_create() =
    ccall((:hb_buffer_create, _HB), Ptr{Cvoid}, ())

_hb_buffer_destroy(buffer::Ptr{Cvoid}) =
    ccall((:hb_buffer_destroy, _HB), Cvoid, (Ptr{Cvoid},), buffer)

_hb_buffer_add_utf8(buffer::Ptr{Cvoid}, text::String) =
    ccall(
    (:hb_buffer_add_utf8, _HB), Cvoid,
    (Ptr{Cvoid}, Cstring, Int32, UInt32, Int32),
    buffer, text, sizeof(text), UInt32(0), Int32(-1),
)

_hb_buffer_guess_segment_properties(buffer::Ptr{Cvoid}) =
    ccall((:hb_buffer_guess_segment_properties, _HB), Cvoid, (Ptr{Cvoid},), buffer)

function _hb_shape(
        font::Ptr{Cvoid},
        buffer::Ptr{Cvoid},
        features::Vector{_HBFeature},
    )
    feature_ptr = isempty(features) ? Ptr{_HBFeature}(C_NULL) : pointer(features)
    GC.@preserve features ccall(
        (:hb_shape, _HB), Cvoid,
        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{_HBFeature}, UInt32),
        font, buffer, feature_ptr, UInt32(length(features)),
    )
    return nothing
end

function _hb_buffer_get_glyph_infos(buffer::Ptr{Cvoid})
    len = Ref{UInt32}(0)
    ptr = ccall(
        (:hb_buffer_get_glyph_infos, _HB), Ptr{_HBGlyphInfo},
        (Ptr{Cvoid}, Ref{UInt32}), buffer, len,
    )
    return ptr, Int(len[])
end

function _hb_buffer_get_glyph_positions(buffer::Ptr{Cvoid})
    len = Ref{UInt32}(0)
    ptr = ccall(
        (:hb_buffer_get_glyph_positions, _HB), Ptr{_HBGlyphPosition},
        (Ptr{Cvoid}, Ref{UInt32}), buffer, len,
    )
    return ptr, Int(len[])
end

function _hb_font_get_glyph_extents(font::Ptr{Cvoid}, glyph_id::UInt32)
    ext = Ref{_HBGlyphExtents}()
    ok = ccall(
        (:hb_font_get_glyph_extents, _HB), Int32,
        (Ptr{Cvoid}, UInt32, Ref{_HBGlyphExtents}), font, glyph_id, ext,
    )
    return ok == 0 ? nothing : ext[]
end

function _destroy_font!(hbf::_HBFont)
    hbf.font != C_NULL && _hb_font_destroy(hbf.font)
    hbf.face != C_NULL && _hb_face_destroy(hbf.face)
    hbf.blob != C_NULL && _hb_blob_destroy(hbf.blob)
    hbf.font = C_NULL
    hbf.face = C_NULL
    hbf.blob = C_NULL
    return nothing
end

function _hb_font(path::String)::_HBFont
    return get!(_FONT_CACHE, path) do
        blob = _hb_blob_create_from_file(path)
        blob == C_NULL && error("HarfBuzz could not read font file: $path")
        face = _hb_face_create(blob)
        if face == C_NULL
            _hb_blob_destroy(blob)
            error("HarfBuzz could not create font face for: $path")
        end
        upm = _hb_face_get_upem(face)
        font = _hb_font_create(face)
        if font == C_NULL
            _hb_face_destroy(face)
            _hb_blob_destroy(blob)
            error("HarfBuzz could not create font for: $path")
        end
        _hb_font_set_scale(font, Int32(upm), Int32(upm))
        _hb_ot_font_set_funcs(font)
        hbf = _HBFont(blob, face, font, Float64(upm))
        finalizer(_destroy_font!, hbf)
        hbf
    end
end

function _font_covers_cluster(path::String, cluster::AbstractString)::Bool
    for ch in cluster
        TeXLayout._codepoint_metrics(path, UInt32(ch)) === nothing && return false
    end
    return true
end

function _fallback_runs(
        text::String,
        family::TeXLayout.FontFamily,
        attrs::TeXLayout.TextAttrs,
    )
    paths = TeXLayout._text_font_fallback(family, attrs.family, attrs.slot)
    required_tags = _required_feature_tags(attrs.features)
    eligible_paths = filter(paths) do path
        all(tag -> _font_supports_feature(path, tag), required_tags)
    end
    if !isempty(text) && !isempty(required_tags) && isempty(eligible_paths)
        names = join(TeXLayout._text_feature_names(attrs.features), ", ")
        throw(
            ArgumentError(
                "no configured $(TeXLayout._text_family_name(attrs.family)) font " *
                    "supports required OpenType features ($names)",
            ),
        )
    end

    runs = Tuple{String, String}[]
    isempty(text) && return runs

    buf = IOBuffer()
    current_path = nothing

    function flush!()
        current_path === nothing && return nothing
        s = String(take!(buf))
        isempty(s) || push!(runs, (current_path::String, s))
        return nothing
    end

    for cluster in Unicode.graphemes(text)
        path = nothing
        for candidate in eligible_paths
            if _font_covers_cluster(candidate, cluster)
                path = candidate
                break
            end
        end
        path === nothing && continue

        if current_path !== nothing && path != current_path
            flush!()
        end
        current_path = path
        write(buf, cluster)
    end
    flush!()
    return runs
end

function _cluster_representatives(text::String)
    reps = Dict{UInt32, Char}()
    for i in eachindex(text)
        reps[UInt32(i - 1)] = text[i]
    end
    return reps
end

function _hb_tag(tag::String)::UInt32
    ncodeunits(tag) == 4 || throw(ArgumentError("OpenType feature tags must contain four bytes"))
    return UInt32(codeunit(tag, 1)) << 24 |
        UInt32(codeunit(tag, 2)) << 16 |
        UInt32(codeunit(tag, 3)) << 8 |
        UInt32(codeunit(tag, 4))
end

function _hb_ot_layout_table_feature_tags(
        face::Ptr{Cvoid}, table_tag::UInt32
    )::Vector{UInt32}
    count = Ref{UInt32}(0)
    total = ccall(
        (:hb_ot_layout_table_get_feature_tags, _HB), UInt32,
        (Ptr{Cvoid}, UInt32, UInt32, Ref{UInt32}, Ptr{UInt32}),
        face, table_tag, UInt32(0), count, C_NULL,
    )
    total == 0 && return UInt32[]

    tags = Vector{UInt32}(undef, total)
    count[] = total
    GC.@preserve tags ccall(
        (:hb_ot_layout_table_get_feature_tags, _HB), UInt32,
        (Ptr{Cvoid}, UInt32, UInt32, Ref{UInt32}, Ptr{UInt32}),
        face, table_tag, UInt32(0), count, pointer(tags),
    )
    resize!(tags, count[])
    return tags
end

function _font_supports_feature(path::String, feature_tag::UInt32)::Bool
    return get!(_FEATURE_CACHE, (path, feature_tag)) do
        hbf = _hb_font(path)
        feature_tag in _hb_ot_layout_table_feature_tags(hbf.face, _hb_tag("GSUB"))
    end
end

function _required_feature_tags(features::TeXLayout.TextFeatures)::Vector{UInt32}
    result = UInt32[]
    features.small_caps && push!(result, _hb_tag("smcp"))
    return result
end

function _hb_features(features::TeXLayout.TextFeatures)::Vector{_HBFeature}
    result = _HBFeature[]
    # `smcp` substitutes lowercase letters only. Deliberately do not enable
    # `c2sc`: source capitals in \textsc remain full-height capitals.
    features.small_caps &&
        push!(result, _HBFeature(_hb_tag("smcp"), UInt32(1), UInt32(0), typemax(UInt32)))
    return result
end

function _shape_text_run(
        path::String,
        text::String,
        slot::TeXLayout.FontSlot.T,
        scale::Float64,
        features::TeXLayout.TextFeatures,
    )::TeXLayout.TeXBox
    hbf = _hb_font(path)
    buffer = _hb_buffer_create()
    buffer == C_NULL && error("HarfBuzz could not create a shape buffer")
    try
        _hb_buffer_add_utf8(buffer, text)
        _hb_buffer_guess_segment_properties(buffer)
        _hb_shape(hbf.font, buffer, _hb_features(features))

        info_ptr, info_len = _hb_buffer_get_glyph_infos(buffer)
        pos_ptr, pos_len = _hb_buffer_get_glyph_positions(buffer)
        info_len == pos_len || error("HarfBuzz returned mismatched glyph info/position lengths")

        reps = _cluster_representatives(text)
        boxes = TeXLayout.LayoutBox[]
        cursor = 0.0
        ascent = 0.0
        descent = 0.0

        for i in 1:info_len
            info = unsafe_load(info_ptr, i)
            pos = unsafe_load(pos_ptr, i)
            ext = _hb_font_get_glyph_extents(hbf.font, info.codepoint)
            ext === nothing && (ext = _HBGlyphExtents(0, 0, 0, 0))

            x_min = Int(ext.x_bearing)
            y_max = Int(ext.y_bearing)
            x_max = Int(ext.x_bearing + ext.width)
            y_min = Int(ext.y_bearing + ext.height)
            x = (cursor + pos.x_offset) / hbf.upm * scale
            y = pos.y_offset / hbf.upm * scale

            glyph = TeXLayout.GlyphID(
                info.codepoint, path, slot, get(reps, info.cluster, '?'),
                Int(pos.x_advance), x_min, x_min, y_min, x_max, y_max,
            )
            push!(boxes, TeXLayout.LayoutBox(glyph, x, y, scale))

            ascent = max(ascent, y + y_max / hbf.upm * scale)
            descent = max(descent, -(y + y_min / hbf.upm * scale))
            cursor += pos.x_advance
        end

        return TeXLayout.TeXBox(boxes, cursor / hbf.upm * scale, ascent, descent)
    finally
        _hb_buffer_destroy(buffer)
    end
end

function shape_span(
        ::TeXLayout.HarfBuzzShaper,
        span,
        family::TeXLayout.FontFamily,
        base_scale::Float64,
    )
    attrs = span.attrs
    slot = attrs.slot
    scale = base_scale * attrs.size
    parts = [
        _shape_text_run(path, text, slot, scale, attrs.features)
            for (path, text) in _fallback_runs(span.text, family, attrs)
    ]
    return TeXLayout.hconcat(parts)
end

end # module HarfBuzzExt
