# Superscript, subscript, and combined script placement.

function _layout_superscript!(node, ctx, style, x0, y0, scale, boxes)
    base, sup = node.children[1], node.children[2]
    base.kind === NodeKind.HorizBrace &&
        return _layout_horiz_brace!(base, nothing, sup, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sup_s = sup_style(style);  sup_scale = _scale_for_child(scale, style, sup_s, mc)
    if _use_limits(base, style)
        # Limits placement: sup centred above base.
        tmp_base = LayoutBox[];  tmp_sup = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sup_w = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
        base_top = _boxes_top(tmp_base, upm)
        s = scale / upm
        y_sup = max(
            y0 + base_top + mc.upper_limit_baseline_rise_min * s,
            y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm)
        )
        total_w = max(base_w, sup_w)
        Δbase = (total_w - base_w) / 2;  Δsup = (total_w - sup_w) / 2
        # ±½ italic correction shifts superscript right over the slanted stroke.
        Δsup += _base_italic_correction_em(tmp_base, ctx, scale) / 2
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sup, x0 + Δsup, y_sup)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sup = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sup_adv = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
    append!(boxes, tmp_base)
    s = scale / upm
    min_sup = is_cramped(style) ?
        mc.superscript_shift_up_cramped * s :
        mc.superscript_shift_up * s
    # Rule 18a: for non-character bases (fractions, groups, …) the superscript
    # baseline must not drop below base_top − supDrop (SuperscriptBaselineDropMax).
    y_sup = _is_char_box(base) ? y0 + min_sup :
        max(y0 + min_sup, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max * s)
    # Rule 18c: superscript bottom must clear SuperscriptBottomMin above baseline.
    y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(tmp_sup, upm))
    _emit_shifted!(boxes, tmp_sup, x0 + base_adv, y_sup)
    return base_adv + sup_adv + mc.space_after_script * s
end

function _layout_subscript!(node, ctx, style, x0, y0, scale, boxes)
    base, sub = node.children[1], node.children[2]
    base.kind === NodeKind.HorizBrace &&
        return _layout_horiz_brace!(base, sub, nothing, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sub_s = sub_style(style);  sub_scale = _scale_for_child(scale, style, sub_s, mc)
    if _use_limits(base, style)
        # Limits placement: sub centred below base.
        tmp_base = LayoutBox[];  tmp_sub = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sub_w = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
        base_bot = _boxes_bottom(tmp_base, upm)
        s = scale / upm
        y_sub = min(
            y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
            y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s
        )
        total_w = max(base_w, sub_w)
        Δbase = (total_w - base_w) / 2;  Δsub = (total_w - sub_w) / 2
        # ±½ italic correction shifts subscript left under the slanted stroke.
        Δsub -= _base_italic_correction_em(tmp_base, ctx, scale) / 2
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sub, x0 + Δsub, y_sub)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sub = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sub_adv = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
    append!(boxes, tmp_base)
    s = scale / upm
    min_sub = mc.subscript_shift_down * s
    # Rule 18a: for non-character bases the subscript baseline must be placed
    # no higher than base_bottom − subDrop (SubscriptBaselineDropMin, σ₁₉).
    y_sub = _is_char_box(base) ? y0 - min_sub :
        min(y0 - min_sub, _boxes_bottom(tmp_base, upm) - mc.subscript_baseline_drop_min * s)
    # Rule 18b: subscript top must not exceed SubscriptTopMax above baseline.
    y_sub = min(y_sub, y0 - _boxes_top(tmp_sub, upm) + mc.subscript_top_max * s)
    # Italic correction: subscript on a slanted single-glyph base (e.g. ∫) is
    # shifted left by the full IC so it sits under the stroke, not the advance width.
    # Matches KaTeX supsub.ts: marginLeft = makeEm(-italic_correction) on subscript.
    ic_em = _base_italic_correction_em(tmp_base, ctx, scale)
    _emit_shifted!(boxes, tmp_sub, x0 + base_adv - ic_em, y_sub)
    return base_adv + sub_adv + mc.space_after_script * s
end

function _layout_decorated!(node, ctx, style, x0, y0, scale, boxes)
    base, sub, sup = node.children[1], node.children[2], node.children[3]
    base.kind === NodeKind.HorizBrace &&
        return _layout_horiz_brace!(base, sub, sup, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    sub_s = sub_style(style);  sub_scale = _scale_for_child(scale, style, sub_s, mc)
    sup_s = sup_style(style);  sup_scale = _scale_for_child(scale, style, sup_s, mc)
    if _use_limits(base, style)
        # Limits placement: sub centred below, sup centred above.
        tmp_base = LayoutBox[];  tmp_sub = LayoutBox[];  tmp_sup = LayoutBox[]
        base_w = _layout_node!(_limits_base(base), ctx, style, 0.0, 0.0, scale, tmp_base)
        sub_w = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
        sup_w = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
        base_top = _boxes_top(tmp_base, upm)
        base_bot = _boxes_bottom(tmp_base, upm)
        s = scale / upm
        y_sup = max(
            y0 + base_top + mc.upper_limit_baseline_rise_min * s,
            y0 + base_top + mc.upper_limit_gap_min * s - _boxes_bottom(tmp_sup, upm)
        )
        y_sub = min(
            y0 + base_bot - mc.lower_limit_baseline_drop_min * s,
            y0 + base_bot - _boxes_top(tmp_sub, upm) - mc.lower_limit_gap_min * s
        )
        total_w = max(base_w, sub_w, sup_w)
        Δbase = (total_w - base_w) / 2
        Δsub = (total_w - sub_w) / 2
        Δsup = (total_w - sup_w) / 2
        # ±½ italic correction shifts sub/sup to track the slanted operator stroke.
        ic_half = _base_italic_correction_em(tmp_base, ctx, scale) / 2
        Δsub -= ic_half
        Δsup += ic_half
        _emit_shifted!(boxes, tmp_base, x0 + Δbase, y0)
        _emit_shifted!(boxes, tmp_sub, x0 + Δsub, y_sub)
        _emit_shifted!(boxes, tmp_sup, x0 + Δsup, y_sup)
        return total_w
    end

    tmp_base = LayoutBox[];  tmp_sub = LayoutBox[];  tmp_sup = LayoutBox[]
    base_adv = _layout_node!(base, ctx, style, x0, y0, scale, tmp_base)
    sub_adv = _layout_node!(sub, ctx, sub_s, 0.0, 0.0, sub_scale, tmp_sub)
    sup_adv = _layout_node!(sup, ctx, sup_s, 0.0, 0.0, sup_scale, tmp_sup)
    append!(boxes, tmp_base)
    script_x = x0 + base_adv
    # Italic correction: subscript on a slanted single-glyph base (e.g. ∫) is
    # shifted left by the full IC so it sits under the stroke, not the advance width.
    # Superscript is not shifted. Matches KaTeX supsub.ts behaviour.
    ic_em = _base_italic_correction_em(tmp_base, ctx, scale)
    s = scale / upm
    min_sup = is_cramped(style) ?
        mc.superscript_shift_up_cramped * s :
        mc.superscript_shift_up * s
    min_sub = mc.subscript_shift_down * s
    # Rule 18a: for non-character bases apply supDrop/subDrop clamps (σ₁₈/σ₁₉).
    y_sup = _is_char_box(base) ? y0 + min_sup :
        max(y0 + min_sup, _boxes_top(tmp_base, upm) - mc.superscript_baseline_drop_max * s)
    y_sub = _is_char_box(base) ? y0 - min_sub :
        min(y0 - min_sub, _boxes_bottom(tmp_base, upm) - mc.subscript_baseline_drop_min * s)
    # Rule 18c: superscript bottom must clear SuperscriptBottomMin above baseline.
    y_sup = max(y_sup, y0 + mc.superscript_bottom_min * s - _boxes_bottom(tmp_sup, upm))
    # Rule 18b: subscript top must not exceed SubscriptTopMax above baseline.
    y_sub = min(y_sub, y0 - _boxes_top(tmp_sub, upm) + mc.subscript_top_max * s)
    # Rule 18e: enforce minimum gap between superscript bottom and subscript top.
    sup_bot = y_sup + _boxes_bottom(tmp_sup, upm)
    sub_top = y_sub + _boxes_top(tmp_sub, upm)
    min_gap = mc.sub_superscript_gap_min * s
    if sup_bot - sub_top < min_gap
        y_sub = sup_bot - min_gap - _boxes_top(tmp_sub, upm)
        # Psi redistribution: if the superscript bottom falls below
        # SuperscriptBottomMaxWithSubscript, shift both scripts upward together
        # so that it reaches exactly that threshold (gap remains min_gap).
        psi = mc.superscript_bottom_max_with_subscript * s - sup_bot
        if psi > 0.0
            y_sup += psi
            y_sub += psi
        end
    end
    _emit_shifted!(boxes, tmp_sub, script_x - ic_em, y_sub)
    _emit_shifted!(boxes, tmp_sup, script_x, y_sup)
    return base_adv + max(sub_adv, sup_adv) + mc.space_after_script * s
end

