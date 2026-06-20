# Composition layer: TeXBox, measurement, hconcat, vstack, layout_document.
#
# Sits above the math layout engine (layout.jl), the shaper (shaping.jl), and
# the document parser (document.jl).  Converts a Document into a flat
# Vector{LayoutBox} inside a measured TeXBox.

# ── Core box type ─────────────────────────────────────────────────────────────

"""
A measured, already-positioned layout fragment.

`boxes` are positioned relative to this box's own origin: baseline at y = 0,
left edge at x = 0. `ascent` and `descent` are ≥ 0 extents above/below the
baseline; `width` is the total advance. This is the eagerly-shaped form of the
Option-2 Box described in future.md.
"""
struct TeXBox
    boxes::Vector{LayoutBox}
    width::Float64
    ascent::Float64
    descent::Float64
end

# ── Layout options ────────────────────────────────────────────────────────────

"""Options controlling text-layer layout. All fields have sensible defaults."""
struct LayoutOptions
    align::Alignment.T                 # text lines
    line_height::Float64               # \baselineskip in em (default 1.2)
    lineskip::Float64                  # min baseline clearance in em (default 0.1)
    width::Union{Nothing, Float64}     # nothing ⇒ widest line; else fixed em width
    display_align::Alignment.T         # display blocks
    abovedisplayskip::Float64          # extra em above a display block (default 0.5)
    belowdisplayskip::Float64          # extra em below a display block (default 0.5)
    shaper::TextShaper                 # default MetricShaper()
end

function LayoutOptions(;
        align = :left,
        line_height = 1.2,
        lineskip = 0.1,
        width = nothing,
        display_align = :center,
        abovedisplayskip = 0.5,
        belowdisplayskip = 0.5,
        shaper = MetricShaper(),
    )
    return LayoutOptions(
        align isa Symbol ? _alignment_from_symbol(align) : align,
        line_height,
        lineskip,
        width,
        display_align isa Symbol ? _alignment_from_symbol(display_align) : display_align,
        abovedisplayskip,
        belowdisplayskip,
        shaper,
    )
end

# ── Measurement ───────────────────────────────────────────────────────────────

# Em advance contributed by a single LayoutBox.
# Glyph advance_width is in design units → divide by upm and multiply by scale.
# Space and HRule widths are already in em (pre-scaled by the layout engine).
_advance_em(b::LayoutBox, upm::Float64) =
    b.element isa Glyph ? b.element.advance_width / upm * b.scale :
    b.element isa Space ? b.element.width :
    b.element isa HRule ? b.element.width :
    0.0

"""
    measure(boxes, upm) -> TeXBox

Wrap an already-positioned `Vector{LayoutBox}` into a `TeXBox` by computing
its total advance width and ink extents.
"""
function measure(boxes::Vector{LayoutBox}, upm::Float64)::TeXBox
    width = 0.0
    for b in boxes
        width = max(width, b.x + _advance_em(b, upm))
    end
    asc = _boxes_top(boxes, upm)
    desc = -_boxes_bottom(boxes, upm)
    return TeXBox(boxes, width, max(asc, 0.0), max(desc, 0.0))
end

# ── hconcat ───────────────────────────────────────────────────────────────────

"""
    hconcat(parts) -> TeXBox

Concatenate `TeXBox` fragments horizontally, placing each part's origin at the
cursor after the previous part. Width = sum of part widths; ascent/descent = max.
"""
function hconcat(parts::Vector{TeXBox})::TeXBox
    isempty(parts) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)
    out = LayoutBox[]
    cursor = 0.0
    asc = 0.0
    desc = 0.0
    for p in parts
        _emit_shifted!(out, p.boxes, cursor, 0.0)
        cursor += p.width
        asc = max(asc, p.ascent)
        desc = max(desc, p.descent)
    end
    return TeXBox(out, cursor, asc, desc)
end

# ── vstack helpers ────────────────────────────────────────────────────────────

_normalise_alignment(a::Alignment.T) = a
_normalise_alignment(a::Symbol) = _alignment_from_symbol(a)

_dx_for(a, W::Float64, w::Float64) =
    _normalise_alignment(a) === Alignment.Right ? W - w :
    _normalise_alignment(a) === Alignment.Center ? (W - w) / 2.0 :
    0.0

_place!(out::Vector{LayoutBox}, box::TeXBox, dx::Float64, dy::Float64) =
    _emit_shifted!(out, box.boxes, dx, dy)

# Empty strut with height `h`: consumes vertical space via the ascent term of
# the next baseline-skip computation without emitting any visible boxes.
_vskip(h::Float64) = TeXBox(LayoutBox[], 0.0, h, 0.0)

# ── vstack ────────────────────────────────────────────────────────────────────

"""
    vstack(items; line_height, lineskip, width, align_of) -> TeXBox

Stack `TeXBox` items vertically, top→bottom.

Baseline advance between consecutive items follows the LaTeX `\\baselineskip` /
`\\lineskip` rule:
    advance = max(line_height, prevdepth + ascent(next) + lineskip)

`align_of(i)` returns an `Alignment` value for item `i`.
`width` fixes the column width; `nothing` uses the widest item.
"""
function vstack(
        items::Vector{TeXBox};
        line_height::Float64,
        lineskip::Float64,
        width::Union{Nothing, Float64},
        align_of,
    )::TeXBox
    isempty(items) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)
    W = width === nothing ? maximum(it.width for it in items) : width
    out = LayoutBox[]
    _place!(out, items[1], _dx_for(align_of(1), W, items[1].width), 0.0)
    prevdepth = items[1].descent
    last_y = 0.0
    y = 0.0
    for i in 2:length(items)
        it = items[i]
        adv = max(line_height, prevdepth + it.ascent + lineskip)
        y -= adv
        _place!(out, it, _dx_for(align_of(i), W, it.width), y)
        prevdepth = it.descent
        last_y = y
    end
    ascent = items[1].ascent
    descent = -last_y + items[end].descent
    return TeXBox(out, W, ascent, descent)
end

# ── Per-run and per-line layout ───────────────────────────────────────────────

function hlayout_math(node::Node, family::FontFamily, style::TexStyle)::TeXBox
    boxes = layout(node, family, style)
    upm = Float64(load_math_table(family.math).upm)
    return measure(boxes, upm)
end

function hlayout_run(run::Run, family::FontFamily, opts::LayoutOptions, base_scale::Float64)::TeXBox
    if run isa TextRun
        parts = [shape_span(opts.shaper, span, family, base_scale) for span in run.spans]
        return hconcat(parts)
    else   # MathRun
        return hlayout_math(run.node, family, run.style)
    end
end

function _layout_line(line::Line, family::FontFamily, opts::LayoutOptions, base_scale::Float64)::TeXBox
    return hconcat([hlayout_run(r, family, opts, base_scale) for r in line.runs])
end

# ── Top-level driver ──────────────────────────────────────────────────────────

"""
    layout_document(input; family, kwargs...) -> TeXBox

Lay out a mixed text/math string with line breaks and display blocks.

Keyword arguments populate `LayoutOptions` (see its docstring). The result's
coordinate frame has the first line's baseline at y = 0; later lines and
display blocks have negative y. `result.boxes` is a flat `Vector{LayoutBox}`
ready for the existing renderer and Makie extension.
"""
function layout_document(
        input::AbstractString;
        family::FontFamily = default_font_family(),
        kwargs...,
    )::TeXBox
    opts = LayoutOptions(; kwargs...)
    doc = parse_document(input)
    mc = load_math_table(family.math).constants
    base_scale = size_scale(Text, mc)

    items = TeXBox[]
    aligns = Alignment.T[]

    for blk in doc
        if blk isa ParagraphBlock
            for line in blk.lines
                push!(items, _layout_line(line, family, opts, base_scale))
                push!(aligns, opts.align)
            end
        else   # DisplayBlock
            opts.abovedisplayskip > 0 && (
                push!(items, _vskip(opts.abovedisplayskip)); push!(aligns, Alignment.Left)
            )
            push!(items, hlayout_math(blk.node, family, Display))
            push!(aligns, opts.display_align)
            opts.belowdisplayskip > 0 && (
                push!(items, _vskip(opts.belowdisplayskip)); push!(aligns, Alignment.Left)
            )
        end
    end

    isempty(items) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)

    return vstack(
        items;
        line_height = opts.line_height,
        lineskip = opts.lineskip,
        width = opts.width,
        align_of = i -> aligns[i],
    )
end
