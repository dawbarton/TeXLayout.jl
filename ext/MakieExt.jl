# MakieExt — implement Makie's public text-handler protocol for LaTeXString
# values. Makie 0.24 does not expose this protocol; the guarded definition keeps
# the weak dependency compatible while MathTeXEngineExt provides the legacy
# integration path there.

module MakieExt

import Makie
import TeXLayout
using FreeTypeAbstraction: FreeTypeAbstraction
using LaTeXStrings: LaTeXString

const _HAS_LAYOUT_TEXT_INTERFACE =
    isdefined(Makie, :TextAttributes) &&
    isdefined(Makie, :TextLayout) &&
    isdefined(Makie, :layout_text)

if _HAS_LAYOUT_TEXT_INTERFACE

    # ── Source routing ────────────────────────────────────────────────────────

    function _document_alignment(justification::Real)
        justification < 0.25 && return TeXLayout.Alignment.Left
        justification > 0.75 && return TeXLayout.Alignment.Right
        return TeXLayout.Alignment.Center
    end

    function _layout_source(
            handler::TeXLayout.TeXLayoutHandler,
            source::LaTeXString,
            attributes::Makie.TextAttributes,
            family::TeXLayout.FontFamily,
        )::TeXLayout.TeXBox
        base_options = something(handler.options, TeXLayout.default_layout_options())
        inline_tokens = TeXLayout._inline_math_tokens(source)
        if inline_tokens !== nothing
            node = TeXLayout.parse_latex(inline_tokens)
            boxes = TeXLayout.layout(
                node,
                family,
                TeXLayout.Display;
                shaper = base_options.shaper,
            )
            return TeXLayout.measure(boxes, TeXLayout._font_upm(family.math))
        end

        fontsize_x = Float64(attributes.fontsize[1])
        wrap_width = if attributes.word_wrap_width > 0 && fontsize_x > 0
            Float64(attributes.word_wrap_width) / fontsize_x
        else
            base_options.width
        end
        options = TeXLayout._merge_options(
            base_options;
            align = _document_alignment(attributes.justification),
            line_height = Float64(attributes.lineheight),
            width = wrap_width,
        )
        return TeXLayout.layout_document(String(source), options; family)
    end

    # ── Metrics ───────────────────────────────────────────────────────────────

    # Makie derives every glyph bounding box from `(0, descender)` to
    # `(hadvance, ascender)`, and its own layouters report the *font's* ascender
    # and descender there so that a box's height does not depend on which
    # characters it holds. Reporting bare ink bounds instead would make `align`
    # and axis tick-label space follow the tallest glyph in the string, so pad
    # the ink extents out to the face's line metrics the way MathTeXEngine's
    # `TeXChar` does.
    function _glyph_extent(glyph, font::FreeTypeAbstraction.FTFont, upm::Float64)
        left = Float32(glyph.x_min / upm)
        right = Float32(glyph.x_max / upm)
        bottom = Float32(glyph.y_min / upm)
        top = Float32(glyph.y_max / upm)
        return Makie.GlyphExtent(
            Makie.Rect2f(left, bottom, right - left, top - bottom),
            max(top, Float32(FreeTypeAbstraction.ascender(font))),
            min(bottom, Float32(FreeTypeAbstraction.descender(font))),
            Float32(glyph.advance_width / upm),
        )
    end

    # Accumulator for the block box `align` positions. Makie's own LaTeX path
    # builds it as the union of the placed glyph boxes rather than from separate
    # block extents, and its downstream `raw_string_boundingboxes` unions those
    # same boxes, so deriving it any other way would make a label align to one
    # box and measure as another.
    mutable struct _BBoxAccumulator
        xmin::Float32
        xmax::Float32
        ymin::Float32
        ymax::Float32
    end

    _BBoxAccumulator() = _BBoxAccumulator(Inf32, -Inf32, Inf32, -Inf32)

    function _include!(acc::_BBoxAccumulator, xmin, xmax, ymin, ymax)
        acc.xmin = min(acc.xmin, Float32(xmin))
        acc.xmax = max(acc.xmax, Float32(xmax))
        acc.ymin = min(acc.ymin, Float32(ymin))
        acc.ymax = max(acc.ymax, Float32(ymax))
        return acc
    end

    function _block_bbox(
            acc::_BBoxAccumulator,
            texbox::TeXLayout.TeXBox,
            fontsize::Makie.Vec2f,
        )
        # Horizontally the measured advance width is authoritative: `Space` boxes
        # emit no glyph, so a leading or trailing `\quad` is invisible to a union
        # over glyph boxes but does belong to the block.
        xmin = min(acc.xmin, 0.0f0)
        xmax = max(acc.xmax, Float32(texbox.width * fontsize[1]))
        # Vertically the union is authoritative, because it is exactly what
        # `raw_string_boundingboxes` will union downstream. It is empty only for
        # a block with nothing drawable (an empty string, or one whose glyphs are
        # all missing from the fonts), where `align` still needs an answer.
        ymin, ymax = if isfinite(acc.ymin)
            (acc.ymin, acc.ymax)
        else
            (
                Float32(-texbox.descent * fontsize[2]),
                Float32(texbox.ascent * fontsize[2]),
            )
        end
        return Makie.Rect2f(xmin, ymin, xmax - xmin, ymax - ymin)
    end

    # ── Rules ─────────────────────────────────────────────────────────────────

    # TeXLayout anchors rules at their bottom/left edge while Makie's line specs
    # are centred on the stroke, hence the half-thickness shifts. The reported
    # bounds pad every side by half the thickness: that over-covers the ends of
    # a butt-capped segment by half a stroke, which is cheaper than getting the
    # cap model wrong in the direction that clips.
    function _rule_spec(
            boxes::Vector{TeXLayout.LayoutBox},
            fontsize::Makie.Vec2f,
            color::Makie.RGBAf,
        )
        points = Makie.Point3f[]
        widths = Float32[]
        xmin = Inf
        xmax = -Inf
        ymin = Inf
        ymax = -Inf

        for box in boxes
            element = box.element
            if element isa TeXLayout.HRule
                thickness = Float32(element.thickness * fontsize[2])
                y = Float32((box.y + element.thickness / 2) * fontsize[2])
                p0 = Makie.Point3f(Float32(box.x * fontsize[1]), y, 0)
                p1 = Makie.Point3f(
                    Float32((box.x + element.width) * fontsize[1]),
                    y,
                    0,
                )
            elseif element isa TeXLayout.VRule
                thickness = Float32(element.thickness * fontsize[1])
                x = Float32((box.x + element.thickness / 2) * fontsize[1])
                p0 = Makie.Point3f(x, Float32(box.y * fontsize[2]), 0)
                p1 = Makie.Point3f(
                    x,
                    Float32((box.y + element.height) * fontsize[2]),
                    0,
                )
            else
                continue
            end

            push!(points, p0, p1)
            push!(widths, thickness, thickness)
            half_thickness = thickness / 2
            xmin = min(xmin, p0[1] - half_thickness, p1[1] - half_thickness)
            xmax = max(xmax, p0[1] + half_thickness, p1[1] + half_thickness)
            ymin = min(ymin, p0[2] - half_thickness, p1[2] - half_thickness)
            ymax = max(ymax, p0[2] + half_thickness, p1[2] + half_thickness)
        end

        isempty(points) && return (Makie.PlotSpec[], Makie.Rect3d[])
        spec = Makie.PlotSpec(
            :LineSegments,
            points;
            linewidth = widths,
            color,
        )
        bbox = Makie.Rect3d(
            Makie.Point3d(xmin, ymin, 0),
            Makie.Vec3d(xmax - xmin, ymax - ymin, 0),
        )
        return (Makie.PlotSpec[spec], Makie.Rect3d[bbox])
    end

    # ── Conversion ────────────────────────────────────────────────────────────

    function _text_layout(
            texbox::TeXLayout.TeXBox,
            runtime::TeXLayout.GlyphRuntime,
            attributes::Makie.TextAttributes,
        )
        glyphindices = UInt64[]
        fonts = Makie.NativeFont[]
        origins = Makie.Point3f[]
        extents = Makie.GlyphExtent[]
        scales = Makie.Vec2f[]
        fontsize = attributes.fontsize
        acc = _BBoxAccumulator()

        for box in texbox.boxes
            element = box.element
            if element isa TeXLayout.Glyph
                resolved = TeXLayout._resolve_glyph(
                    runtime, element.font_slot, element.glyph_name,
                )
                # No configured font has the glyph, so there is nothing to draw.
                resolved === nothing && continue
                gid, font, path = resolved
                upm = TeXLayout._font_upm(path)
            elseif element isa TeXLayout.GlyphID
                gid = UInt64(element.glyph_id)
                font = TeXLayout._runtime_font(runtime, element.font_path)
                upm = TeXLayout._font_upm(element.font_path)
            else
                # Rules become plot specs below; `Space` has no rendering at all.
                continue
            end

            extent = _glyph_extent(element, font, upm)
            scale = Float32(box.scale) * fontsize
            origin_x = Float32(box.x * fontsize[1])
            origin_y = Float32(box.y * fontsize[2])

            push!(glyphindices, gid)
            push!(fonts, font)
            push!(origins, Makie.Point3f(origin_x, origin_y, 0))
            push!(extents, extent)
            push!(scales, scale)
            # The same box Makie will derive from this extent downstream, so the
            # block bbox and `raw_string_boundingboxes` cannot disagree.
            _include!(
                acc,
                origin_x,
                origin_x + extent.hadvance * scale[1],
                origin_y + extent.descender * scale[2],
                origin_y + extent.ascender * scale[2],
            )
        end

        specs, spec_bboxes = _rule_spec(texbox.boxes, fontsize, attributes.color)
        for rect in spec_bboxes
            lo = minimum(rect)
            hi = maximum(rect)
            _include!(acc, lo[1], hi[1], lo[2], hi[2])
        end

        return Makie.TextLayout(
            glyphindices,
            fonts,
            origins,
            extents;
            bbox = _block_bbox(acc, texbox, fontsize),
            baseline = 0.0f0,
            scales,
            colors = attributes.color,
            strokecolors = attributes.strokecolor,
            strokewidths = attributes.strokewidth,
            specs,
            spec_bboxes,
        )
    end

    function Makie.layout_text(
            handler::TeXLayout.TeXLayoutHandler,
            source::LaTeXString,
            attributes::Makie.TextAttributes,
        )
        family = something(handler.family, TeXLayout.default_font_family())
        texbox = _layout_source(handler, source, attributes, family)
        return _text_layout(texbox, TeXLayout._glyph_runtime(family), attributes)
    end

end

end # module MakieExt
