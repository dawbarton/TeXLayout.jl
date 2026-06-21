# Extensible delimiters, radicals, accents, and horizontal braces.

# ── Extensible assembly helpers ───────────────────────────────────────────────

# Build the expanded parts list with extenders repeated `n` times each.
# Parts are in bottom-to-top order (as stored in the font).
function _expand_assembly_parts(
        parts::Vector{GlyphAssemblyPart},
        n::Int,
    )::Vector{GlyphAssemblyPart}
    n == 1 && return parts
    result = GlyphAssemblyPart[]
    for p in parts
        reps = p.is_extender ? n : 1
        for _ in 1:reps
            push!(result, p)
        end
    end
    return result
end

# The minimum permissible overlap between two adjacent parts (design units).
# Clamped to the per-gap maximum so we never exceed the connector lengths.
@inline function _gap_min_overlap(
        p1::GlyphAssemblyPart,
        p2::GlyphAssemblyPart,
        min_conn::Int,
    )::Int
    max_allowed = min(p1.end_connector, p2.start_connector)
    return min(min_conn, max_allowed)
end

# Total height of an expanded parts list with minimum overlaps (design units).
# Minimum overlaps → maximum possible height for that n.
function _assembly_max_height(parts::Vector{GlyphAssemblyPart}, min_conn::Int)::Float64
    isempty(parts) && return 0.0
    h = Float64(parts[1].full_advance)
    for i in 2:length(parts)
        h += parts[i].full_advance - _gap_min_overlap(parts[i - 1], parts[i], min_conn)
    end
    return h
end

# Find the minimum number of extender repetitions so the assembly is at least
# `required_du` tall.  Uses minimum overlaps (giving the tallest assembly) to
# find the tightest bound on n.
function _min_extender_reps(
        parts::Vector{GlyphAssemblyPart},
        required_du::Float64,
        min_conn::Int,
    )::Int
    for n in 0:256
        _assembly_max_height(_expand_assembly_parts(parts, n), min_conn) >= required_du &&
            return n
    end
    return 256
end

# Lay out a glyph assembly centred on the math axis.  Returns the horizontal
# advance of the widest part.
function _layout_assembly!(
        asm::GlyphAssembly,
        ctx::_LayoutCtx,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        required_du::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    upm = ctx.upm
    mc = ctx.mc
    min_conn = ctx.min_connector_overlap

    n = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    # Start with minimum overlaps at each gap (giving the maximum possible height
    # for this n), then increase them uniformly to shrink the assembly toward
    # required_du.  Without this adjustment, fonts that provide only one pre-built
    # variant (e.g. STIX Two bar/|) always overshoot: n extenders round the height
    # up to the nearest multiple, making assembled delimiters visibly taller than
    # their \left/\right companions (which use exact pre-built variants).
    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in eachindex(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
    end

    # Total assembly height in design units with minimum overlaps.
    total_du = Float64(parts[1].full_advance)
    for i in eachindex(overlaps)
        total_du += parts[i + 1].full_advance - overlaps[i]
    end

    # Distribute extra overlap to bring total_du toward required_du.
    # Excess is spread proportionally across gaps by their available connector
    # capacity; each gap is clamped to its per-gap maximum.
    if !isempty(overlaps) && total_du > required_du
        excess = total_du - required_du
        max_extra = [
            min(parts[i].end_connector, parts[i + 1].start_connector) - overlaps[i]
                for i in eachindex(overlaps)
        ]
        total_cap = Float64(sum(max_extra))
        if total_cap > 0.0
            for i in eachindex(overlaps)
                extra = round(Int, excess * max_extra[i] / total_cap)
                overlaps[i] += min(extra, max_extra[i])
            end
            total_du = Float64(parts[1].full_advance)
            for i in eachindex(overlaps)
                total_du += parts[i + 1].full_advance - overlaps[i]
            end
        end
    end

    # Derive ink bounds from first/last glyph metrics.  When assembly parts have
    # y_min ≠ 0 (e.g. STIX Two bar: y_min=-234, y_max=706, full_advance=941),
    # centering by total_du/2 misplaces the stack.  Using actual ink bounds
    # centres correctly on the math axis regardless of font design conventions.
    g_first = _cmd_glyph(ctx, parts[1].glyph_name)
    g_last = _cmd_glyph(ctx, parts[end].glyph_name)
    ink_bot_du = (g_first !== nothing) ? Float64(g_first.y_min) : 0.0
    cursor_last = total_du - Float64(parts[end].full_advance)
    ink_top_du = cursor_last + ((g_last !== nothing) ? Float64(g_last.y_max) : Float64(parts[end].full_advance))
    ink_center_du = (ink_bot_du + ink_top_du) / 2.0
    axis_em = y0 + mc.axis_height / upm * scale
    asm_bot_em = axis_em - ink_center_du / upm * scale

    max_adv_w = 0
    cursor_du = 0.0
    for i in 1:length(parts)
        p = parts[i]
        g = _cmd_glyph(ctx, p.glyph_name)
        if g !== nothing
            # Each part has y_min=0, y_max=full_advance; place baseline at bottom of part.
            y_part = asm_bot_em + cursor_du / upm * scale
            push!(boxes, LayoutBox(g, x0, y_part, scale))
            max_adv_w = max(max_adv_w, g.advance_width)
        end
        if i <= length(overlaps)
            cursor_du += Float64(p.full_advance) - overlaps[i]
        end
    end

    return max_adv_w / upm * scale
end

# Lay out a radical glyph assembly so that the TOP of the assembly aligns with
# `rule_top_em`.  Unlike delimiter assemblies (centred on the math axis),
# radical assemblies are top-anchored.  Returns placement data for the radical:
# the horizontal offset at which the radicand should start, and the actual
# vertical cover of the chosen radical sign in em units.
@inline _radical_cover_du(g::Glyph) = Float64(g.y_max - g.y_min)
# TeX packs the radical delimiter and the overbar/radicand into an hlist, so the
# body starts after the delimiter box width (advance width), not after the
# radical ink's right edge. Using x_max makes larger radical variants drift
# rightward in deep nesting because their ink overhang exceeds their advance.
@inline _radical_body_offset_du(g::Glyph) = Float64(g.advance_width)

function _assembly_total_du(parts::Vector{GlyphAssemblyPart}, overlaps::Vector{Int})::Float64
    isempty(parts) && return 0.0
    total_du = Float64(parts[1].full_advance)
    for i in eachindex(overlaps)
        total_du += parts[i + 1].full_advance - overlaps[i]
    end
    return total_du
end

function _layout_radical_assembly!(
        asm::GlyphAssembly,
        ctx::_LayoutCtx,
        required_du::Float64,
        rule_top_em::Float64,
        x0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )
    upm = ctx.upm
    min_conn = ctx.min_connector_overlap

    n = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return (body_offset = 0.0, cover = 0.0)

    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in eachindex(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
    end

    total_du = _assembly_total_du(parts, overlaps)

    # All radical assembly parts have y_min=0, y_max=full_advance.
    # The top of the top cap is at asm_bot + total_du; pin it to rule_top_em.
    asm_bot_em = rule_top_em - total_du / upm * scale

    max_body_offset_du = 0.0
    cursor_du = 0.0
    for i in eachindex(parts)
        p = parts[i]
        g = _cmd_glyph(ctx, p.glyph_name)
        if g !== nothing
            push!(boxes, LayoutBox(g, x0, asm_bot_em + cursor_du / upm * scale, scale))
            max_body_offset_du = max(max_body_offset_du, _radical_body_offset_du(g))
        end
        i <= length(overlaps) && (cursor_du += Float64(p.full_advance) - overlaps[i])
    end

    return (body_offset = max_body_offset_du / upm * scale, cover = total_du / upm * scale)
end

# Return the GlyphMetrics for the smallest radical variant that covers
# `required_du` design units (same selection logic as `_layout_radical!`),
# or `nothing` if no variant information is available.  Does NOT push to boxes.
function _peek_radical_glyph(ctx::_LayoutCtx, required_du::Float64)::Union{Glyph, Nothing}
    rkey = _construction_key(ctx, "radical")
    if haskey(ctx.vert_constructions, rkey)
        vc = ctx.vert_constructions[rkey]
        for v in vc.variants
            Float64(v.advance) >= required_du && return _cmd_glyph(ctx, v.glyph_name)
        end
        !isempty(vc.variants) && return _cmd_glyph(ctx, last(vc.variants).glyph_name)
    end
    return _cmd_glyph(ctx, "radical")
end

function _peek_radical_cover_du(ctx::_LayoutCtx, required_du::Float64)::Float64
    rkey = _construction_key(ctx, "radical")
    if haskey(ctx.vert_constructions, rkey)
        vc = ctx.vert_constructions[rkey]
        for v in vc.variants
            if Float64(v.advance) >= required_du
                g = _cmd_glyph(ctx, v.glyph_name)
                return g === nothing ? 0.0 : _radical_cover_du(g)
            end
        end
        if vc.assembly !== nothing
            min_conn = ctx.min_connector_overlap
            n = _min_extender_reps(vc.assembly.parts, required_du, min_conn)
            parts = _expand_assembly_parts(vc.assembly.parts, n)
            overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
            for i in eachindex(overlaps)
                overlaps[i] = _gap_min_overlap(parts[i], parts[i + 1], min_conn)
            end
            return _assembly_total_du(parts, overlaps)
        end
    end
    g = _peek_radical_glyph(ctx, required_du)
    return g === nothing ? 0.0 : _radical_cover_du(g)
end

# Choose and place a radical glyph (or assembly) whose top ink aligns with
# `rule_top_em`.  `required_du` is the minimum vertical span (design units)
# the radical must cover.  Returns placement data for the radical.
function _layout_radical!(
        ctx::_LayoutCtx,
        required_du::Float64,
        rule_top_em::Float64,
        x0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )
    upm = ctx.upm

    function _place_variant(name::String)
        g = _cmd_glyph(ctx, name)
        g === nothing && return (body_offset = 0.0, cover = 0.0)
        push!(boxes, LayoutBox(g, x0, rule_top_em - g.y_max / upm * scale, scale))
        return (
            body_offset = _radical_body_offset_du(g) / upm * scale,
            cover = _radical_cover_du(g) / upm * scale,
        )
    end

    rkey = _construction_key(ctx, "radical")
    if !haskey(ctx.vert_constructions, rkey)
        return _place_variant("radical")
    end

    vc = ctx.vert_constructions[rkey]

    for v in vc.variants
        Float64(v.advance) >= required_du && return _place_variant(v.glyph_name)
    end

    vc.assembly !== nothing && return _layout_radical_assembly!(
        vc.assembly, ctx, required_du, rule_top_em, x0, scale, boxes
    )

    chosen = isempty(vc.variants) ? "radical" : last(vc.variants).glyph_name
    return _place_variant(chosen)
end

# Lay out one delimiter (left or right) at position (x0, y0), centred on the
# math axis.  Tries pre-built size variants first; falls back to the glyph
# assembly when no variant is large enough.  Returns horizontal advance.
function _layout_delim!(
        ctx::_LayoutCtx,
        glyph_name::String,
        required_du::Float64,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    isempty(glyph_name) && return 0.0
    upm = ctx.upm
    mc = ctx.mc

    function _place_glyph(name::String)::Float64
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
        y_del = y0 + (mc.axis_height / upm - glyph_center) * scale
        push!(boxes, LayoutBox(g, x0, y_del, scale))
        return g.advance_width / upm * scale
    end

    dkey = _construction_key(ctx, glyph_name)
    if !haskey(ctx.vert_constructions, dkey)
        return _place_glyph(glyph_name)
    end

    vc = ctx.vert_constructions[dkey]

    # Try pre-built variants (smallest sufficient first).
    for v in vc.variants
        Float64(v.advance) >= required_du && return _place_glyph(v.glyph_name)
    end

    # No variant is large enough; try the glyph assembly.
    if vc.assembly !== nothing
        return _layout_assembly!(vc.assembly, ctx, x0, y0, scale, required_du, boxes)
    end

    # Fall back to largest variant (or base glyph when no variants exist).
    chosen = isempty(vc.variants) ? glyph_name : last(vc.variants).glyph_name
    return _place_glyph(chosen)
end

# Place a horizontally extensible accent glyph centred over a base of width
# `base_w_em` (em units) at vertical position `accent_y`.  Selects the smallest
# pre-built variant whose advance width covers the base; if none exists, assembles
# the glyph from parts using the same helpers used for vertical assemblies.
# Falls back to the largest variant (or the base glyph) if the assembly is empty.
function _layout_wide_accent!(
        ctx::_LayoutCtx,
        accent_ps::String,
        base_w_em::Float64,
        accent_y::Float64,
        x0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Nothing
    upm = ctx.upm
    min_conn = ctx.min_connector_overlap
    required_du = base_w_em / scale * upm   # convert em to design units

    hc = get(ctx.horiz_constructions, accent_ps, nothing)
    hc === nothing && return nothing

    # Helper: centre a named glyph over the base and push it to boxes.
    # Uses ink midpoint (x_min+x_max)/2 rather than advance_width/2: this correctly
    # handles zero-advance combining characters (e.g. circumflexcmb, adv_w=0) whose
    # ink lies at negative x values rather than spanning [0, advance_width].
    function _place(name::String)
        g = _cmd_glyph(ctx, name)
        g === nothing && return
        ink_center = (g.x_min + g.x_max) / (2.0 * upm) * scale
        return push!(boxes, LayoutBox(g, x0 + base_w_em / 2 - ink_center, accent_y, scale))
    end

    # Try pre-built variants first (smallest that covers the base).
    for v in hc.variants
        if Float64(v.advance) >= required_du
            _place(v.glyph_name)
            return nothing
        end
    end

    # Try extensible assembly.
    if hc.assembly !== nothing
        asm = hc.assembly
        n = _min_extender_reps(asm.parts, required_du, min_conn)
        parts = _expand_assembly_parts(asm.parts, n)
        if !isempty(parts)
            # Compute overlap for each adjacent pair.
            overlaps = [
                _gap_min_overlap(parts[i], parts[i + 1], min_conn)
                    for i in 1:(length(parts) - 1)
            ]
            # Total width of the assembly in design units.
            total_du = Float64(parts[1].full_advance) +
                sum(
                Float64(parts[i + 1].full_advance) - overlaps[i]
                    for i in eachindex(overlaps); init = 0.0
            )
            total_w = total_du / upm * scale
            # Centre the assembly over the base.
            ax = x0 + (base_w_em - total_w) / 2
            cursor_du = 0.0
            for i in eachindex(parts)
                p = parts[i]
                g = _cmd_glyph(ctx, p.glyph_name)
                g !== nothing &&
                    push!(boxes, LayoutBox(g, ax + cursor_du / upm * scale, accent_y, scale))
                if i <= length(overlaps)
                    cursor_du += Float64(p.full_advance) - overlaps[i]
                end
            end
            return nothing
        end
    end

    # Fall back to the largest pre-built variant, or the base glyph.
    _place(isempty(hc.variants) ? accent_ps : last(hc.variants).glyph_name)
    return nothing
end

# Lay out a horizontal brace node with optional script note.
#
# KaTeX horizBrace.ts algorithm:
#   - Body at current style; brace stretched horizontally to body width.
#   - Gap = 0.1 em between body ink edge and brace ink edge (body_gap).
#   - Gap = 0.2 em between brace ink edge and note ink edge (note_gap).
#   - Note (primary script) is centred over max(body_w, note_w).
#   - Secondary script (opposite side) is placed as a normal side script.
#
# sub_node / sup_node: subscript / superscript children (nothing if absent).
function _layout_horiz_brace!(
        brace_node::Node,
        sub_node::Union{Node, Nothing},
        sup_node::Union{Node, Nothing},
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    upm = ctx.upm
    mc = ctx.mc
    is_over = startswith(brace_node.value, "\\over")
    glyph_ps = _horiz_construction_key(ctx, _HORIZ_BRACE_GLYPHS[brace_node.value])

    # Primary note lives on the brace side; secondary note is the opposite.
    primary_node = is_over ? sup_node : sub_node
    secondary_node = is_over ? sub_node : sup_node

    # Body at current style.
    body_start = lastindex(boxes) + 1
    body_w = _layout_node!(brace_node.children[1], ctx, style, 0.0, 0.0, scale, boxes)
    body_stop = lastindex(boxes)
    body_top = _boxes_top(boxes, body_start, body_stop, upm)
    body_bot = _boxes_bottom(boxes, body_start, body_stop, upm)

    # Primary note at the script style of the brace side.
    pri_s = is_over ? sup_style(style) : sub_style(style)
    pri_scale = size_scale(pri_s, mc)
    pri_start = lastindex(boxes) + 1
    pri_w = 0.0
    if primary_node !== nothing
        pri_w = _layout_node!(primary_node, ctx, pri_s, 0.0, 0.0, pri_scale, boxes)
    end
    pri_stop = lastindex(boxes)

    # Total span: body and note are both centred over max(body_w, note_w).
    total_w = max(body_w, pri_w)
    Δbody = (total_w - body_w) / 2

    # Reference glyph for brace ink-extent calculation: find the same variant
    # that _layout_wide_accent! would select (smallest covering body_w or largest).
    hc = get(ctx.horiz_constructions, glyph_ps, nothing)
    req_du = body_w / scale * upm
    sel_name = glyph_ps
    if hc !== nothing
        for v in hc.variants
            Float64(v.advance) >= req_du && (sel_name = v.glyph_name; break)
        end
        sel_name == glyph_ps && !isempty(hc.variants) &&
            (sel_name = last(hc.variants).glyph_name)
    end
    g_ref = _cmd_glyph(ctx, sel_name)

    # Brace baseline y: place the ink edge of the brace at body_edge + body_gap.
    # For over: bottom ink of brace = body_top + body_gap
    #           brace_y + y_min/upm*scale = y0 + body_top + body_gap
    # For under: top ink of brace = body_bot - body_gap
    #           brace_y + y_max/upm*scale = y0 + body_bot - body_gap
    body_gap = 0.1 * scale
    if g_ref !== nothing
        brace_y = is_over ?
            y0 + body_top + body_gap - Float64(g_ref.y_min) / upm * scale :
            y0 + body_bot - body_gap - Float64(g_ref.y_max) / upm * scale
        brace_top = brace_y + Float64(g_ref.y_max) / upm * scale
        brace_bot = brace_y + Float64(g_ref.y_min) / upm * scale
    else
        # No glyph metrics available: assume the brace's baseline coincides with
        # the body-side ink edge (y_min=0 for over, y_max=0 for under) and pad by
        # 0.25 em on the opposite side as a placeholder for the missing glyph.
        brace_y = is_over ? y0 + body_top + body_gap : y0 + body_bot - body_gap
        brace_top = is_over ? brace_y + 0.25 * scale : brace_y
        brace_bot = is_over ? brace_y : brace_y - 0.25 * scale
    end

    # Place body (centred over total_w at y0).
    _translate_range!(boxes, body_start, body_stop, x0 + Δbody, y0)

    # Place brace (centred over body_w; extension fills body width).
    _layout_wide_accent!(ctx, glyph_ps, body_w, brace_y, x0 + Δbody, scale, boxes)

    # Place primary note centred over total_w.
    # Gap = 0.2 em between brace ink edge and note ink edge (KaTeX horizBrace.ts).
    note_gap = 0.2 * scale
    if pri_start <= pri_stop
        Δpri = (total_w - pri_w) / 2
        note_y = is_over ?
            brace_top + note_gap - _boxes_bottom(boxes, pri_start, pri_stop, upm) :
            brace_bot - note_gap - _boxes_top(boxes, pri_start, pri_stop, upm)
        _translate_range!(boxes, pri_start, pri_stop, x0 + Δpri, note_y)
    end

    # Secondary note: placed as a normal side script to the right of the stack.
    if secondary_node !== nothing
        sec_s = is_over ? sub_style(style) : sup_style(style)
        sec_scale = size_scale(sec_s, mc)
        sec_start = lastindex(boxes) + 1
        sec_w = _layout_node!(secondary_node, ctx, sec_s, 0.0, 0.0, sec_scale, boxes)
        sec_stop = lastindex(boxes)
        s = scale / upm
        script_x = x0 + total_w
        if is_over
            y_sub = min(
                y0 - mc.subscript_shift_down * s,
                y0 + body_bot - mc.subscript_baseline_drop_min * s
            )
            y_sub = min(y_sub, y0 - _boxes_top(boxes, sec_start, sec_stop, upm) + mc.subscript_top_max * s)
            _translate_range!(boxes, sec_start, sec_stop, script_x, y_sub)
        else
            min_sup = is_cramped(style) ?
                mc.superscript_shift_up_cramped * s : mc.superscript_shift_up * s
            y_sup = max(
                y0 + min_sup,
                y0 + body_top - mc.superscript_baseline_drop_max * s
            )
            y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(boxes, sec_start, sec_stop, upm))
            _translate_range!(boxes, sec_start, sec_stop, script_x, y_sup)
        end
        total_w += sec_w + mc.space_after_script * s
    end

    return total_w
end
