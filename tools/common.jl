# Shared helpers for the scripts in `tools/`.
#
# - `resolve_font` turns a command-line font argument into a `FontFamily`.
# - `resolve_glyph` finds the face and glyph index for a layout element through
#   TeXLayout's `GlyphRuntime`, the path the Makie and MathTeXEngine adapters
#   take.  A name-based `Glyph` walks its slot's whole fallback chain (with the
#   codepoint and `uniXXXX` name fallbacks), and a shaped `GlyphID` uses its
#   exact font file, so a tool draws what a renderer would draw.
# - The rest rasterises layout boxes with FreeType onto a greyscale canvas, a
#   `Matrix{UInt8}` indexed [row, column] with 0 = black and 255 = white.
#
# Include this file after `using TeXLayout`.  It holds plain definitions, so a
# script included inside a module (as `stress_test_suite.jl` does) gets its own
# copy.

using FreeTypeAbstraction
using PNGFiles
using Colors: Gray, N0f8
using TeXLayout: FontFamily, Glyph, GlyphID, HRule, LayoutBox, Space, VRule

# ── Fonts and glyphs ──────────────────────────────────────────────────────────

"""
    resolve_font(spec) -> FontFamily

`spec` is a `FontFamily`, a bundled family name with or without a leading colon
(`:pagella`, `pagella`), or the path of a math font file.
"""
function resolve_font(spec)::FontFamily
    spec isa FontFamily && return spec
    s = string(spec)
    startswith(s, ":") && return font_family(Symbol(s[2:end]))
    isfile(s) && return FontFamily(s)
    return font_family(Symbol(s))
end

"""File-name slug for a font's family name: lower case, `_` between words."""
font_slug(font_name::AbstractString)::String =
    strip(lowercase(replace(font_name, r"[^a-zA-Z0-9]+" => "_")), '_')

"""
    resolve_glyph(family, el) -> Union{Tuple{FTFont, UInt64, String}, Nothing}

Face, glyph index, and font path that a renderer adapter would draw `el` with.
Returns `nothing`, warning once per glyph, when no font in the slot's fallback
chain has the glyph; the adapters then draw nothing either.
"""
function resolve_glyph(family::FontFamily, el::Glyph)
    runtime = TeXLayout._glyph_runtime(family)
    resolved = TeXLayout._resolve_glyph(runtime, el.font_slot, el.glyph_name)
    if resolved === nothing
        @warn "No font in the $(el.font_slot) fallback chain has glyph $(repr(el.glyph_name))" _id = (el.font_slot, el.glyph_name) maxlog = 1
        return nothing
    end
    gid, face, path = resolved
    return (face, gid, path)
end

function resolve_glyph(family::FontFamily, el::GlyphID)
    face = TeXLayout._runtime_font(TeXLayout._glyph_runtime(family), el.font_path)
    return (face, UInt64(el.glyph_id), el.font_path)
end

"""
    render_glyph(family, el, px) -> Union{Tuple{bitmap, extent}, Nothing}

FreeType bitmap and extent of `el` at `px` pixels per em, from the face that
[`resolve_glyph`](@ref) chooses.  `nothing` when the glyph cannot be drawn.
"""
function render_glyph(family::FontFamily, el::Union{Glyph, GlyphID}, px::Int)
    resolved = resolve_glyph(family, el)
    resolved === nothing && return nothing
    face, gid, _ = resolved
    return try
        renderface(face, Int(gid), px)
    catch err
        @warn "FreeType could not render $(el): $(err)" _id = (:render, el) maxlog = 1
        nothing
    end
end

# ── Measurement ───────────────────────────────────────────────────────────────

"""
    em_bbox(boxes, upm; advance = false, ymin = -0.15, ymax = 0.15, pad = 0.0)
        -> (x1, x2, y1, y2)

Box around the boxes' glyph ink and rules in em (y up), always containing the
origin and the band `ymin`–`ymax` about the baseline, then padded by `pad` on
every side.  With `advance = true` each glyph's advance is included as well.
`upm` is the math font's units per em; a `GlyphID` uses its own font's.
"""
function em_bbox(
        boxes, upm::Real;
        advance::Bool = false, ymin::Real = -0.15, ymax::Real = 0.15, pad::Real = 0.0,
    )
    x1 = x2 = y1 = y2 = 0.0
    for box in boxes
        el = box.element
        if el isa Glyph || el isa GlyphID
            s = box.scale / (el isa GlyphID ? TeXLayout._font_upm(el.font_path) : Float64(upm))
            x1 = min(x1, box.x + el.x_min * s)
            x2 = max(x2, box.x + el.x_max * s)
            if advance
                x1 = min(x1, box.x + el.advance_width * s)
                x2 = max(x2, box.x + el.advance_width * s)
            end
            y1 = min(y1, box.y + el.y_min * s)
            y2 = max(y2, box.y + el.y_max * s)
        elseif el isa HRule
            x1 = min(x1, box.x); x2 = max(x2, box.x + el.width)
            y1 = min(y1, box.y); y2 = max(y2, box.y + el.thickness)
        elseif el isa VRule
            x1 = min(x1, box.x); x2 = max(x2, box.x + el.thickness)
            y1 = min(y1, box.y); y2 = max(y2, box.y + el.height)
        elseif el isa Space
            x1 = min(x1, box.x, box.x + el.width)
            x2 = max(x2, box.x, box.x + el.width)
        end
    end
    y1 = min(y1, ymin); y2 = max(y2, ymax)
    return (x1 - pad, x2 + pad, y1 - pad, y2 + pad)
end

# ── Greyscale canvas ──────────────────────────────────────────────────────────

"""Blend coverage `alpha` of grey level `ink` into one pixel; off-canvas is a no-op."""
@inline function composite!(canvas::Matrix{UInt8}, row, col, alpha::UInt8, ink::UInt8 = 0x00)
    1 <= row <= size(canvas, 1) && 1 <= col <= size(canvas, 2) || return nothing
    a = Int(alpha)
    canvas[row, col] = UInt8((Int(canvas[row, col]) * (255 - a) + Int(ink) * a) ÷ 255)
    return nothing
end

"""Fill rows `r1`–`r2` and columns `c1`–`c2` (either order, inclusive), clipped."""
function fill_rect!(canvas::Matrix{UInt8}, r1, c1, r2, c2, val::UInt8 = 0x00)
    rlo = max(min(r1, r2), 1); rhi = min(max(r1, r2), size(canvas, 1))
    clo = max(min(c1, c2), 1); chi = min(max(c1, c2), size(canvas, 2))
    (rlo > rhi || clo > chi) && return nothing
    canvas[rlo:rhi, clo:chi] .= val
    return nothing
end

"""One-pixel horizontal line on `row` from column `c1` to `c2`, clipped."""
hline!(canvas::Matrix{UInt8}, row, c1, c2, val::UInt8) = fill_rect!(canvas, row, c1, row, c2, val)

"""
    foreach_ink(f, bitmap, extent, pen_col, pen_row)

Call `f(row, col, alpha)` for every inked pixel of a FreeType glyph bitmap whose
pen (its origin on the baseline) sits at canvas column `pen_col`, row `pen_row`.
"""
function foreach_ink(f, bmp, ext, pen_col::Int, pen_row::Int)
    left = pen_col + round(Int, ext.horizontal_bearing[1])
    top = pen_row - round(Int, ext.horizontal_bearing[2])
    for row in axes(bmp, 2), col in axes(bmp, 1)   # bitmaps are indexed [x, y]
        alpha = bmp[col, row]
        alpha == 0x00 && continue
        f(top + row - 1, left + col - 1, alpha)
    end
    return nothing
end

"""Composite a glyph bitmap onto a greyscale canvas in grey level `ink`."""
blit!(canvas::Matrix{UInt8}, bmp, ext, pen_col::Int, pen_row::Int; ink::UInt8 = 0x00) =
    foreach_ink((r, c, a) -> composite!(canvas, r, c, a, ink), bmp, ext, pen_col, pen_row)

"""
    draw_boxes!(canvas, boxes, family, px_per_em, col, row)

Draw the glyphs and rules in `boxes` in black.  `px_per_em` is the pixel size of
a glyph at scale 1, and `col(x)` and `row(y)` map em coordinates to canvas
pixels.  Spaces draw nothing.
"""
function draw_boxes!(canvas::Matrix{UInt8}, boxes, family::FontFamily, px_per_em::Real, col, row)
    for box in boxes
        el = box.element
        if el isa Glyph || el isa GlyphID
            glyph = render_glyph(family, el, max(1, round(Int, box.scale * px_per_em)))
            glyph === nothing || blit!(canvas, glyph..., col(box.x), row(box.y))
        elseif el isa HRule
            fill_rect!(canvas, row(box.y + el.thickness), col(box.x), row(box.y), col(box.x + el.width))
        elseif el isa VRule
            fill_rect!(canvas, row(box.y + el.height), col(box.x), row(box.y), col(box.x + el.thickness))
        end
    end
    return canvas
end

"""Write a greyscale canvas as an 8-bit PNG."""
write_gray_png(path::AbstractString, canvas::Matrix{UInt8}) =
    PNGFiles.save(path, reinterpret(Gray{N0f8}, canvas))
