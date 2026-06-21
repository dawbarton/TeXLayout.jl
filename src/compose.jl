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
baseline; `width` is the total advance. This is the measured output container
returned by document layout and composition helpers.
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
    parskip::Float64                   # extra em between paragraphs split by blank lines
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
        parskip = 0.6,
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
        parskip,
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
    asc = _boxes_top(boxes, firstindex(boxes), lastindex(boxes), upm)
    desc = -_boxes_bottom(boxes, firstindex(boxes), lastindex(boxes), upm)
    return TeXBox(boxes, width, max(asc, 0.0), max(desc, 0.0))
end

_as_box(box::TeXBox) = ShapedBox(box.boxes, box.width, box.ascent, box.descent)
_as_texbox(box::Box) = TeXBox(shape(box), _box_width(box), _box_ascent(box), _box_descent(box))

# ── hconcat ───────────────────────────────────────────────────────────────────

"""
    hconcat(parts) -> TeXBox

Concatenate `TeXBox` fragments horizontally, placing each part's origin at the
cursor after the previous part. Width = sum of part widths; ascent/descent = max.
"""
function hconcat(parts::Vector{TeXBox})::TeXBox
    return _as_texbox(HBox([_as_box(part) for part in parts]))
end

# ── vstack helpers ────────────────────────────────────────────────────────────

_normalise_alignment(a::Alignment.T) = a
_normalise_alignment(a::Symbol) = _alignment_from_symbol(a)

_dx_for(a, W::Float64, w::Float64) =
    _normalise_alignment(a) === Alignment.Right ? W - w :
    _normalise_alignment(a) === Alignment.Center ? (W - w) / 2.0 :
    0.0

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
    return _as_texbox(
        _vstack_tree(
            items;
            line_height,
            lineskip,
            width,
            align_of,
            extra_before = zeros(length(items)),
        ),
    )
end

function _vstack_tree(
        items::Vector{TeXBox};
        line_height::Float64,
        lineskip::Float64,
        width::Union{Nothing, Float64},
        align_of,
        extra_before::Vector{Float64},
        extra_after_last::Float64 = 0.0,
    )::VBox
    isempty(items) && return VBox(Box[], Float64[], Float64[], 0.0, 0.0, 0.0)
    length(extra_before) == length(items) || error("extra_before length must match items")

    W = width === nothing ? maximum(it.width for it in items) : width
    children = Box[_as_box(item) for item in items]
    offsets = Float64[0.0]
    dxs = Float64[_dx_for(align_of(1), W, items[1].width)]

    prevdepth = items[1].descent
    last_y = 0.0
    y = 0.0
    for i in 2:length(items)
        it = items[i]
        adv = max(line_height, prevdepth + it.ascent + lineskip) + extra_before[i]
        y -= adv
        push!(offsets, y)
        push!(dxs, _dx_for(align_of(i), W, it.width))
        prevdepth = it.descent
        last_y = y
    end

    ascent = items[1].ascent
    descent = -last_y + items[end].descent + extra_after_last
    return VBox(children, offsets, dxs, W, ascent, descent)
end

function _vstack_with_skips(
        items::Vector{TeXBox};
        line_height::Float64,
        lineskip::Float64,
        width::Union{Nothing, Float64},
        align_of,
        extra_before::Vector{Float64},
        extra_after_last::Float64 = 0.0,
    )::TeXBox
    return _as_texbox(
        _vstack_tree(
            items;
            line_height,
            lineskip,
            width,
            align_of,
            extra_before,
            extra_after_last,
        ),
    )
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
    extra_before = Float64[]
    pending_skip = 0.0

    function push_item!(item::TeXBox, align::Alignment.T, skip_before::Float64 = 0.0)
        push!(items, item)
        push!(aligns, align)
        push!(extra_before, length(items) == 1 ? 0.0 : skip_before)
        return nothing
    end

    for blk in doc
        if blk isa ParagraphBlock
            for line in blk.lines
                push_item!(_layout_line(line, family, opts, base_scale), opts.align, pending_skip)
                pending_skip = 0.0
            end
        elseif blk isa ParagraphBreakBlock
            !isempty(items) && (pending_skip = max(pending_skip, opts.parskip))
        else   # DisplayBlock
            skip = (isempty(items) ? 0.0 : pending_skip + opts.abovedisplayskip)
            push_item!(hlayout_math(blk.node, family, Display), opts.display_align, skip)
            pending_skip = opts.belowdisplayskip
        end
    end

    isempty(items) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)

    return _vstack_with_skips(
        items;
        line_height = opts.line_height,
        lineskip = opts.lineskip,
        width = opts.width,
        align_of = i -> aligns[i],
        extra_before,
        extra_after_last = pending_skip,
    )
end
