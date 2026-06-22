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

mutable struct _HBFont
    blob::Ptr{Cvoid}
    face::Ptr{Cvoid}
    font::Ptr{Cvoid}
    upm::Float64
end

const _FONT_CACHE = Dict{String, _HBFont}()

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

_hb_shape(font::Ptr{Cvoid}, buffer::Ptr{Cvoid}) =
    ccall(
    (:hb_shape, _HB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, UInt32),
    font, buffer, C_NULL, UInt32(0)
)

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

function _fallback_runs(text::String, family::TeXLayout.FontFamily, slot::TeXLayout.FontSlot.T)
    paths = TeXLayout._slot_fallback(family, slot)
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
        for candidate in paths
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

function _shape_text_run(
        path::String,
        text::String,
        slot::TeXLayout.FontSlot.T,
        scale::Float64,
    )::TeXLayout.TeXBox
    hbf = _hb_font(path)
    buffer = _hb_buffer_create()
    buffer == C_NULL && error("HarfBuzz could not create a shape buffer")
    try
        _hb_buffer_add_utf8(buffer, text)
        _hb_buffer_guess_segment_properties(buffer)
        _hb_shape(hbf.font, buffer)

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
    slot = span.attrs.slot
    scale = base_scale * span.attrs.size
    parts = [
        _shape_text_run(path, text, slot, scale)
            for (path, text) in _fallback_runs(span.text, family, slot)
    ]
    return TeXLayout.hconcat(parts)
end

end # module HarfBuzzExt
