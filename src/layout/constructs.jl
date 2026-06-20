# Compound math construct layout helpers.

# Apply an absolute style override (\dfrac, \displaystyle, etc.).
# value encodes the target style as "Display", "Text", "Script", or "ScriptScript".
# The scale is reset to size_scale(new_style) so that e.g. \dfrac inside a
# subscript renders at full display size, matching KaTeX behaviour.
function _layout_style_override!(node, ctx, style, x0, y0, scale, boxes)
    new_style = if node.value == "Display"
        Display
    elseif node.value == "Text"
        Text
    elseif node.value == "Script"
        Script
    else
        ScriptScript
    end
    new_scale = size_scale(new_style, ctx.mc)
    return _layout_node!(node.children[1], ctx, new_style, x0, y0, new_scale, boxes)
end

# Apply a relative font-size change (\large, \tiny, etc.).
# value is the Float64 multiplier serialised as a string.
function _layout_sizing!(node, ctx, style, x0, y0, scale, boxes)
    factor = parse(Float64, node.value)
    return _layout_node!(node.children[1], ctx, style, x0, y0, scale * factor, boxes)
end

# Lay out an extensible arrow with optional above and below labels.
#
# Vertical positioning follows KaTeX xarrow.ts:
#   - Arrow body centred on the math axis.
#   - Above label: bottom of ink at arrow_top + KERN.
#   - Below label: top of ink at arrow_bot − KERN.
#   - Minimum arrow width: max(natural width, widest_label + 2*PAD*scale).
#   - Both labels and arrow centred horizontally over the full advance.
function _layout_xarrow!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    cmd = node.value
    above_node = node.children[1]
    below_node = length(node.children) >= 2 ? node.children[2] : nothing

    # Labels rendered at sub/sup script style and scale.
    above_s = sup_style(style)
    above_scale = _scale_for_child(scale, style, above_s, mc)
    below_s = sub_style(style)
    below_scale = _scale_for_child(scale, style, below_s, mc)

    tmp_above = LayoutBox[]
    above_w = _layout_node!(above_node, ctx, above_s, 0.0, 0.0, above_scale, tmp_above)

    tmp_below = LayoutBox[]
    below_w = 0.0
    if below_node !== nothing
        below_w = _layout_node!(below_node, ctx, below_s, 0.0, 0.0, below_scale, tmp_below)
    end

    # Resolve the arrow glyph in horiz_constructions.
    cp = get(_XARROW_CODEPOINTS, cmd, 0x2192)
    uni_name = "uni" * uppercase(string(cp, base = 16, pad = 4))
    arrow_ps = _horiz_construction_key(ctx, uni_name)

    # Natural arrow width from the reference glyph (smallest pre-built variant
    # or the base glyph itself).
    hc = get(ctx.horiz_constructions, arrow_ps, nothing)
    ref_ps = arrow_ps
    if hc !== nothing && !isempty(hc.variants)
        ref_ps = hc.variants[1].glyph_name
    end
    g_ref = _cmd_glyph(ctx, ref_ps)
    natural_w = g_ref !== nothing ? Float64(g_ref.advance_width) / upm * scale : scale

    # Arrow width: at least as wide as the widest label plus horizontal padding.
    label_w = max(above_w, below_w)
    arrow_w = max(natural_w, label_w + 2 * _XARROW_PAD * scale)

    # Total advance: same as arrow width (labels are centred within it).
    total_w = arrow_w

    # Vertical: centre arrow on math axis.
    axis_em = mc.axis_height / upm * scale
    if g_ref !== nothing
        arrow_y = y0 + axis_em - (Float64(g_ref.y_min) + Float64(g_ref.y_max)) / (2.0 * upm) * scale
        arrow_top = arrow_y + Float64(g_ref.y_max) / upm * scale
        arrow_bot = arrow_y + Float64(g_ref.y_min) / upm * scale
    else
        arrow_y = y0 + axis_em
        arrow_top = arrow_y + 0.3 * scale
        arrow_bot = arrow_y - 0.3 * scale
    end

    # Place the extensible arrow body.
    _layout_wide_accent!(ctx, arrow_ps, arrow_w, arrow_y, x0, scale, boxes)

    # Place the above label: bottom of ink at arrow_top + kern.
    if !isempty(tmp_above)
        Δabove = (total_w - above_w) / 2
        label_y = arrow_top + _XARROW_KERN * scale - _boxes_bottom(tmp_above, upm)
        _emit_shifted!(boxes, tmp_above, x0 + Δabove, label_y)
    end

    # Place the below label: top of ink at arrow_bot − kern.
    if !isempty(tmp_below)
        Δbelow = (total_w - below_w) / 2
        label_y = arrow_bot - _XARROW_KERN * scale - _boxes_top(tmp_below, upm)
        _emit_shifted!(boxes, tmp_below, x0 + Δbelow, label_y)
    end

    return total_w
end

# Layout for \bigl/\bigr/\big etc. (NodeKind.BigDelim): a single delimiter glyph
# at a fixed size tier, centred on the math axis.  required_du is scale-independent:
# the same glyph variant is selected at every style level; the glyph renders at the
# current scale so it appears smaller in subscripts, matching KaTeX behaviour.
function _layout_big_delim!(node, ctx, style, x0, y0, scale, boxes)
    isempty(node.value) && return 0.0
    payload = _decode_big_delimiter_payload(node.value)
    ps_name = payload.glyph_name
    size = payload.size
    (isempty(ps_name) || size < 1 || size > length(_BIG_DELIM_HEIGHTS)) && return 0.0
    required_du = _BIG_DELIM_HEIGHTS[size] * ctx.upm
    return _layout_delim!(ctx, ps_name, required_du, x0, y0, scale, boxes)
end

function _layout_frac!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    num_node, den_node = node.children[1], node.children[2]
    num_s = frac_num_style(style);  num_scale = _scale_for_child(scale, style, num_s, mc)
    den_s = frac_den_style(style);  den_scale = _scale_for_child(scale, style, den_s, mc)

    rule_thickness = mc.fraction_rule_thickness / upm * scale
    axis_em = mc.axis_height / upm * scale
    # Rule centre at the math axis; rule.y is the bottom edge.
    rule_y = y0 + axis_em - rule_thickness / 2

    # Initial shifts and minimum gap constants from the MATH table.
    if is_display(style)
        num_shift = mc.fraction_numerator_display_style_shift_up / upm * scale
        den_shift = mc.fraction_denominator_display_style_shift_down / upm * scale
        num_gap = mc.fraction_num_display_style_gap_min / upm * scale
        den_gap = mc.fraction_denom_display_style_gap_min / upm * scale
    else
        num_shift = mc.fraction_numerator_shift_up / upm * scale
        den_shift = mc.fraction_denominator_shift_down / upm * scale
        num_gap = mc.fraction_numerator_gap_min / upm * scale
        den_gap = mc.fraction_denominator_gap_min / upm * scale
    end

    # Layout at y=0 to measure ink extents before applying shifts.
    tmp_num = LayoutBox[];  tmp_den = LayoutBox[]
    num_w = _layout_node!(num_node, ctx, num_s, 0.0, 0.0, num_scale, tmp_num)
    den_w = _layout_node!(den_node, ctx, den_s, 0.0, 0.0, den_scale, tmp_den)

    # Clamp shifts so the minimum gap between content and rule is respected
    # (TeX Rule 15d/15e).  num_depth is how far the numerator ink extends below
    # its own baseline; den_height is how far the denominator ink extends above.
    num_depth = max(0.0, -_boxes_bottom(tmp_num, upm))
    den_height = max(0.0, _boxes_top(tmp_den, upm))
    num_shift = max(num_shift, axis_em + rule_thickness / 2 + num_gap + num_depth)
    den_shift = max(den_shift, den_height - axis_em + rule_thickness / 2 + den_gap)

    frac_w = max(num_w, den_w)
    Δnum = (frac_w - num_w) / 2
    Δden = (frac_w - den_w) / 2
    _emit_shifted!(boxes, tmp_num, x0 + Δnum, y0 + num_shift)
    _emit_shifted!(boxes, tmp_den, x0 + Δden, y0 - den_shift)
    push!(boxes, LayoutBox(HRule(frac_w, rule_thickness), x0, rule_y, scale))
    return frac_w
end

# Layout for \binom / \dbinom / \tbinom (NodeKind.Genfrac): a no-rule fraction wrapped
# in auto-sized delimiters.  Implements Rule 15c (no-rule gap clamping, i.e.
# rule_thickness = 0) and sizes the delimiters symmetrically around the math
# axis using the same algorithm as NodeKind.Delimited.
function _layout_genfrac!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm

    payload = _decode_delimiter_pair_payload(node.value)
    left_name = payload.left
    right_name = payload.right

    num_node, den_node = node.children[1], node.children[2]
    num_s = frac_num_style(style)
    num_scale = _scale_for_child(scale, style, num_s, mc)
    den_s = frac_den_style(style)
    den_scale = _scale_for_child(scale, style, den_s, mc)

    axis_h = mc.axis_height / upm * scale

    # Initial shifts and gap minima from the MATH table (same constants as \frac).
    if is_display(style)
        num_shift = mc.fraction_numerator_display_style_shift_up / upm * scale
        den_shift = mc.fraction_denominator_display_style_shift_down / upm * scale
        num_gap = mc.fraction_num_display_style_gap_min / upm * scale
        den_gap = mc.fraction_denom_display_style_gap_min / upm * scale
    else
        num_shift = mc.fraction_numerator_shift_up / upm * scale
        den_shift = mc.fraction_denominator_shift_down / upm * scale
        num_gap = mc.fraction_numerator_gap_min / upm * scale
        den_gap = mc.fraction_denominator_gap_min / upm * scale
    end

    # Lay out numerator and denominator at origin to measure ink extents.
    tmp_num = LayoutBox[]
    tmp_den = LayoutBox[]
    num_w = _layout_node!(num_node, ctx, num_s, 0.0, 0.0, num_scale, tmp_num)
    den_w = _layout_node!(den_node, ctx, den_s, 0.0, 0.0, den_scale, tmp_den)

    # Rule 15c: gap clamping with no rule (rule_thickness = 0).
    num_depth = max(0.0, -_boxes_bottom(tmp_num, upm))
    den_height = max(0.0, _boxes_top(tmp_den, upm))
    num_shift = max(num_shift, axis_h + num_gap + num_depth)
    den_shift = max(den_shift, den_height - axis_h + den_gap)

    inner_w = max(num_w, den_w)

    # Compute the vertical extent of the fraction for delimiter sizing.
    # Both measured relative to y0 (i.e. the formula baseline).
    inner_top = num_shift + _boxes_top(tmp_num, upm)
    inner_bot = -den_shift + _boxes_bottom(tmp_den, upm)
    h_above = max(0.0, inner_top - axis_h)
    h_below = max(0.0, axis_h - inner_bot)
    required_du = 2.0 * max(h_above, h_below) / scale * upm

    # Place left delimiter, fraction content (centred), right delimiter.
    cursor = x0
    !isempty(left_name) && (cursor += _layout_delim!(ctx, left_name, required_du, cursor, y0, scale, boxes))
    Δnum = (inner_w - num_w) / 2
    Δden = (inner_w - den_w) / 2
    _emit_shifted!(boxes, tmp_num, cursor + Δnum, y0 + num_shift)
    _emit_shifted!(boxes, tmp_den, cursor + Δden, y0 - den_shift)
    cursor += inner_w
    !isempty(right_name) && (cursor += _layout_delim!(ctx, right_name, required_du, cursor, y0, scale, boxes))
    return cursor - x0
end

function _layout_sqrt!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    # \sqrt[degree]{body}: children are [body] or [degree, body].
    body_node = length(node.children) == 1 ? node.children[1] : node.children[2]
    tmp = LayoutBox[]
    # Rule 11: body is built in the cramped style (prevents superscripts inside
    # the radicand from protruding above the rule bar).
    body_w = _layout_node!(body_node, ctx, cramp_style(style), 0.0, 0.0, scale, tmp)
    body_top = _boxes_top(tmp, upm)
    body_bot = _boxes_bottom(tmp, upm)

    gap = is_display(style) ?
        mc.radical_display_style_vertical_gap / upm * scale :
        mc.radical_vertical_gap / upm * scale
    rule_thickness = mc.radical_rule_thickness / upm * scale

    # KaTeX Rule 11: when the radical hook extends significantly below the body,
    # redistribute excess vertical space so it is shared equally above and below
    # rather than entirely below.  Peek at the glyph that would be selected,
    # measure its depth below the rule bottom, and increase the gap if needed.
    let peek_du = (body_top + gap + rule_thickness - body_bot) / scale * upm
        cover_du = _peek_radical_cover_du(ctx, peek_du)
        if cover_du > 0.0
            delim_depth = cover_du / upm * scale - rule_thickness
            body_extent = body_top - body_bot
            if delim_depth > body_extent + gap
                gap = (gap + delim_depth - body_extent) / 2
            end
        end
    end

    rule_y_local = body_top + gap           # bottom of rule bar (em, relative to y0)
    rule_top_local = rule_y_local + rule_thickness

    # `required_cover_du` is the vertical span from body bottom to the rule top.
    required_cover_du = (rule_top_local - body_bot) / scale * upm
    required_du = required_cover_du
    rule_top_em = y0 + rule_top_local
    body_x_offset = _layout_radical!(ctx, required_du, rule_top_em, x0, scale, boxes)

    body_x = x0 + body_x_offset
    rule_overlap = rule_thickness / 2
    rule_x = body_x - rule_overlap

    _emit_shifted!(boxes, tmp, body_x, y0)
    push!(
        boxes, LayoutBox(
            HRule(body_w + rule_overlap, rule_thickness),
            rule_x, y0 + rule_y_local, scale
        )
    )
    return body_x_offset + body_w
end

function _layout_delimited!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    # \left…\right: size delimiters to the inner content, centred on the math axis.
    payload = _decode_delimiter_pair_payload(node.value)
    left_name = payload.left
    right_name = payload.right

    # Partition inner children into content segments separated by NodeKind.Middle nodes.
    # segments[i] holds the children between the (i-1)-th and i-th \middle delimiter.
    # middles[i]  is the NodeKind.Middle node separating segments[i] from segments[i+1].
    segments = Vector{Node}[]
    middles = Node[]
    current_seg = Node[]
    for child in node.children
        if child.kind === NodeKind.Middle
            push!(segments, current_seg)
            push!(middles, child)
            current_seg = Node[]
        else
            push!(current_seg, child)
        end
    end
    push!(segments, current_seg)

    # Lay out each segment at the origin into a scratch buffer to measure dimensions.
    # x=0 is used so that box positions are relative; they are shifted when placed.
    seg_boxes = [LayoutBox[] for _ in segments]
    seg_widths = zeros(Float64, length(segments))
    for (i, seg) in enumerate(segments)
        seg_widths[i] = _layout_children!(seg, ctx, style, 0.0, y0, scale, seg_boxes[i])
    end

    # Measure the overall vertical extent across all segment boxes.
    all_tmp = isempty(seg_boxes) ? LayoutBox[] : reduce(vcat, seg_boxes)
    content_top = _boxes_top(all_tmp, upm)
    content_bot = _boxes_bottom(all_tmp, upm)
    # Ensure a sensible non-zero span when content has no glyph ink.
    content_top = max(content_top, y0 + mc.axis_height / upm * scale)
    content_bot = min(content_bot, y0 - mc.axis_height / upm * scale)

    # Required delimiter advance: sized so every delimiter covers the content
    # symmetrically around the math axis (same formula for left, middle, and right).
    # Converted to unscaled design units because GlyphVariant.advance and
    # GlyphAssemblyPart.full_advance are stored in unscaled design units.
    axis_em = y0 + mc.axis_height / upm * scale
    h_above = max(0.0, content_top - axis_em)
    h_below = max(0.0, axis_em - content_bot)
    required_em = 2.0 * max(h_above, h_below)
    required_du = required_em / scale * upm

    # Place left delimiter, then (segment + middle delimiter)*, then last segment + right.
    cursor = x0
    left_w = _layout_delim!(ctx, left_name, required_du, cursor, y0, scale, boxes)
    cursor += left_w
    for (i, (seg_b, seg_w)) in enumerate(zip(seg_boxes, seg_widths))
        _emit_shifted!(boxes, seg_b, cursor, 0.0)
        cursor += seg_w
        if i <= length(middles)
            mid_w = _layout_delim!(ctx, middles[i].value, required_du, cursor, y0, scale, boxes)
            cursor += mid_w
        end
    end
    right_w = _layout_delim!(ctx, right_name, required_du, cursor, y0, scale, boxes)
    return cursor - x0 + right_w
end

function _layout_font_switch!(node, ctx, style, x0, y0, scale, boxes)
    # Switch the active font variant for all recursive calls within the body.
    isempty(node.children) && return 0.0
    new_ctx = _with_variant(ctx, Symbol(node.value))
    return _layout_node!(node.children[1], new_ctx, style, x0, y0, scale, boxes)
end

function _layout_text!(node, ctx, style, x0, y0, scale, boxes)
    # Render the body in text mode: upright (regular-font) glyphs, no math-italic
    # remapping, no inter-atom spacing (guarded in _layout_children! by mode check).
    isempty(node.children) && return 0.0
    return _layout_node!(node.children[1], _with_text_mode(ctx), style, x0, y0, scale, boxes)
end

function _layout_accent!(node, ctx, style, x0, y0, scale, boxes)
    # KaTeX Rule 12 (accent.ts).  Build base in cramped style, then place the
    # accent glyph above it, aligned via MathTopAccentAttachment when available.
    isempty(node.children) && return 0.0
    mc, upm = ctx.mc, ctx.upm

    # Build base in cramped style (Rule 12: base is typeset cramped).
    tmp = LayoutBox[]
    base_w = _layout_node!(node.children[1], ctx, cramp_style(style), 0.0, 0.0, scale, tmp)
    base_top = _boxes_top(tmp, upm)   # body.height in em (measured at origin)
    _emit_shifted!(boxes, tmp, x0, y0)

    # Look up the accent glyph.  Try the primary codepoint first; if the font
    # does not have a glyph there, try the combining-form fallback (e.g. Luciole
    # Math uses U+0302–U+030C instead of the spacing modifier codepoints).
    accent_ps = glyph_name_by_codepoint(ctx.family, _ACCENT_CODEPOINTS[node.value])
    if isempty(accent_ps)
        fb = get(_ACCENT_FALLBACK_CODEPOINTS, node.value, nothing)
        fb !== nothing && (accent_ps = glyph_name_by_codepoint(ctx.family, fb))
    end
    isempty(accent_ps) && return base_w
    accent_m = glyph_metrics(ctx.family, accent_ps)
    accent_m === nothing && return base_w

    # Vertical placement: clearance = min(base_top, accent_base_height_em).
    # This places the accent so it just clears a normal x-height character while
    # riding higher above ascenders, matching the KaTeX clearance formula.
    accent_base_h = mc.accent_base_height * scale / upm
    accent_y = y0 + max(0.0, base_top - accent_base_h)

    # Wide accents (\widehat, \widetilde) are placed using a horizontally
    # extensible glyph centred over the base; no MathTopAccentAttachment alignment.
    if node.value ∈ _WIDE_ACCENT_COMMANDS && haskey(ctx.horiz_constructions, accent_ps)
        _layout_wide_accent!(ctx, accent_ps, base_w, accent_y, x0, scale, boxes)
        return base_w
    end

    # Horizontal placement via MathTopAccentAttachment.  If the base is a single
    # glyph with a known attachment point, align the attachment x of the accent
    # to the attachment x of the base.  Fall back to centering when attachment
    # data is unavailable.
    base_attach_du = if length(tmp) == 1 && tmp[1].element isa Glyph
        get(ctx.top_accent_attachments, (tmp[1].element::Glyph).glyph_name, nothing)
    else
        nothing
    end
    accent_attach_du = get(ctx.top_accent_attachments, accent_ps, nothing)

    accent_x = if base_attach_du !== nothing && accent_attach_du !== nothing
        x0 + (base_attach_du - accent_attach_du) * scale / upm
    else
        # Centre by ink midpoint rather than advance_width/2: handles zero-advance
        # combining characters (adv_w=0, x_min/x_max negative).
        x0 + base_w / 2 - (accent_m.x_min + accent_m.x_max) * scale / (2.0 * upm)
    end

    push!(
        boxes, LayoutBox(
            Glyph(
                accent_ps, FontSlot.Math, accent_m.advance_width,
                accent_m.left_side_bearing,
                accent_m.x_min, accent_m.y_min,
                accent_m.x_max, accent_m.y_max
            ),
            accent_x, accent_y, scale
        )
    )
    return base_w
end

function _layout_overunder!(node, ctx, style, x0, y0, scale, boxes)
    # Rules 9 & 10: \overline and \underline.
    # \overline  (Rule 9):  body in cramped style; HRule above with gap from MATH table.
    # \underline (Rule 10): body in current style; HRule below with gap from MATH table.
    isempty(node.children) && return 0.0
    mc, upm = ctx.mc, ctx.upm
    is_over = node.value == "overline"
    child_style = is_over ? cramp_style(style) : style

    tmp = LayoutBox[]
    body_w = _layout_node!(node.children[1], ctx, child_style, 0.0, 0.0, scale, tmp)

    rule_t = (is_over ? mc.overbar_rule_thickness : mc.underbar_rule_thickness) / upm * scale
    gap = (is_over ? mc.overbar_vertical_gap : mc.underbar_vertical_gap) / upm * scale
    _emit_shifted!(boxes, tmp, x0, y0)

    # Rule bottom at body_top + gap (over) or body_bot − gap − rule_t (under).
    rule_y = is_over ?
        y0 + _boxes_top(tmp, upm) + gap :
        y0 + _boxes_bottom(tmp, upm) - gap - rule_t
    push!(boxes, LayoutBox(HRule(body_w, rule_t), x0, rule_y, scale))
    return body_w
end

