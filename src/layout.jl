# Layout engine: AST + style → positioned glyph elements.
#
# Converts a parsed AST into a flat list of (element, position, scale) triples
# that Makie (or any other renderer) can consume directly.  Positions are in em
# units relative to the formula baseline; x increases rightward, y upward.
# All constants are read from the font's OpenType MATH table; no hard-coded
# values are used.

"""Abstract base for all renderable elements."""
abstract type TeXElement end

"""
A single glyph to be rendered from the math font.

`glyph_name` is the PostScript glyph name; the renderer resolves it to a glyph
index via its font handle.  The metric fields are cached from the font in design
units so that the renderer need not re-query them.
"""
struct Glyph <: TeXElement
    glyph_name::String
    advance_width::Int
    left_side_bearing::Int
    x_min::Int; y_min::Int; x_max::Int; y_max::Int
end

"""A horizontal rule (fraction bar, radical bar, overline, …)."""
struct HRule <: TeXElement
    width::Float64      # em units
    thickness::Float64  # em units
end

"""A vertical rule (rarely needed; included for completeness)."""
struct VRule <: TeXElement
    height::Float64
    thickness::Float64
end

"""An explicit horizontal space."""
struct Space <: TeXElement
    width::Float64   # em units
end

"""
A positioned element: element + 2-D offset from the formula baseline origin.

`x` increases to the right; `y` increases upward.  Both are in em units.
`scale` is the font-size multiplier relative to the base font size (1.0 for
Text/Display style, 0.7 for Script, 0.5 for ScriptScript by default).
"""
struct LayoutBox
    element::TeXElement
    x::Float64
    y::Float64
    scale::Float64
end

# ── Internal helpers ──────────────────────────────────────────────────────────

# Immutable context shared across all recursive layout calls.
struct _LayoutCtx
    family::FontFamily
    mc::MathConstants
    upm::Float64
end

# Return a Glyph for a Unicode character.
# For ASCII letters, prefer the PostScript name lookup (more reliable in math
# fonts where the italic variant carries the same single-letter name).  Fall
# back to codepoint lookup for digits and other characters.
function _char_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph,Nothing}
    if isletter(ch)
        try
            m = glyph_metrics(ctx.family, string(ch))
            return Glyph(string(ch), m.advance_width, m.left_side_bearing,
                         m.x_min, m.y_min, m.x_max, m.y_max)
        catch
        end
    end
    try
        m = glyph_metrics_by_codepoint(ctx.family, UInt32(ch))
        return Glyph(string(ch), m.advance_width, m.left_side_bearing,
                     m.x_min, m.y_min, m.x_max, m.y_max)
    catch
        return nothing
    end
end

# Return an upright Glyph for a character, or nothing if not in the font.
# Uses the regular font slot when present; falls back to math font codepoint mapping.
function _upright_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph,Nothing}
    m = glyph_metrics_upright(ctx.family, ch)
    m === nothing && return nothing
    Glyph(string(ch), m.advance_width, m.left_side_bearing,
          m.x_min, m.y_min, m.x_max, m.y_max)
end

# Return a Glyph for a PostScript glyph name, or nothing if not in the font.
function _cmd_glyph(ctx::_LayoutCtx, name::String)::Union{Glyph,Nothing}
    try
        m = glyph_metrics(ctx.family, name)
        return Glyph(name, m.advance_width, m.left_side_bearing,
                     m.x_min, m.y_min, m.x_max, m.y_max)
    catch
        return nothing
    end
end

# Maximum y-extent (top of the ink) of all Glyph boxes, in em units.
function _boxes_top(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    top = 0.0
    for b in boxes
        if b.element isa Glyph
            top = max(top, b.y + b.element.y_max / upm * b.scale)
        end
    end
    return top
end

# ── Recursive layout ──────────────────────────────────────────────────────────

# Lay out `node` into `boxes`, with the left-baseline anchor at (x0, y0) and
# the given scale.  Returns the horizontal advance of the node in em units.
function _layout_node!(
    node::Node,
    ctx::_LayoutCtx,
    style::TexStyle,
    x0::Float64,
    y0::Float64,
    scale::Float64,
    boxes::Vector{LayoutBox},
)::Float64
    mc  = ctx.mc
    upm = ctx.upm

    if node.kind === NKChar
        g = _char_glyph(ctx, only(node.value))
        g === nothing && return 0.0
        push!(boxes, LayoutBox(g, x0, y0, scale))
        return g.advance_width / upm * scale

    elseif node.kind === NKCommand
        cmd  = node.value   # e.g. "\\alpha"
        name = startswith(cmd, "\\") ? cmd[2:end] : cmd
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        push!(boxes, LayoutBox(g, x0, y0, scale))
        return g.advance_width / upm * scale

    elseif node.kind === NKOperator
        # Render each character of the operator name upright (roman).
        cursor = x0
        for ch in node.value
            g = _upright_glyph(ctx, ch)
            g === nothing && continue
            push!(boxes, LayoutBox(g, cursor, y0, scale))
            cursor += g.advance_width / upm * scale
        end
        return cursor - x0

    elseif node.kind === NKSpace
        return 0.0

    elseif node.kind === NKSequence || node.kind === NKGroup
        cursor = x0
        for child in node.children
            cursor += _layout_node!(child, ctx, style, cursor, y0, scale, boxes)
        end
        return cursor - x0

    elseif node.kind === NKSuperscript
        base, sup = node.children[1], node.children[2]
        base_adv  = _layout_node!(base, ctx, style, x0, y0, scale, boxes)
        sup_s     = sup_style(style)
        sup_scale = size_scale(sup_s, mc)
        shift_up  = is_cramped(style) ?
            mc.superscript_shift_up_cramped / upm * scale :
            mc.superscript_shift_up / upm * scale
        sup_adv   = _layout_node!(sup, ctx, sup_s, x0 + base_adv, y0 + shift_up, sup_scale, boxes)
        return base_adv + sup_adv + mc.space_after_script / upm * scale

    elseif node.kind === NKSubscript
        base, sub = node.children[1], node.children[2]
        base_adv  = _layout_node!(base, ctx, style, x0, y0, scale, boxes)
        sub_s     = sub_style(style)
        sub_scale = size_scale(sub_s, mc)
        shift_dn  = mc.subscript_shift_down / upm * scale
        sub_adv   = _layout_node!(sub, ctx, sub_s, x0 + base_adv, y0 - shift_dn, sub_scale, boxes)
        return base_adv + sub_adv + mc.space_after_script / upm * scale

    elseif node.kind === NKDecorated
        base, sub, sup = node.children[1], node.children[2], node.children[3]
        base_adv  = _layout_node!(base, ctx, style, x0, y0, scale, boxes)
        script_x  = x0 + base_adv
        sub_s = sub_style(style);  sub_scale = size_scale(sub_s, mc)
        sup_s = sup_style(style);  sup_scale = size_scale(sup_s, mc)
        sub_adv = _layout_node!(sub, ctx, sub_s, script_x,
                                y0 - mc.subscript_shift_down / upm * scale, sub_scale, boxes)
        sup_adv = _layout_node!(sup, ctx, sup_s, script_x,
                                y0 + mc.superscript_shift_up / upm * scale, sup_scale, boxes)
        return base_adv + max(sub_adv, sup_adv) + mc.space_after_script / upm * scale

    elseif node.kind === NKFrac
        num_node, den_node = node.children[1], node.children[2]
        num_s = frac_num_style(style);  num_scale = size_scale(num_s, mc)
        den_s = frac_den_style(style);  den_scale = size_scale(den_s, mc)

        rule_thickness = mc.fraction_rule_thickness / upm * scale
        # Rule centre at the math axis; rule.y is the bottom edge.
        rule_y = y0 + mc.axis_height / upm * scale - rule_thickness / 2

        # Numerator and denominator baselines (measured from y0).
        if is_display(style)
            num_y = y0 + mc.fraction_numerator_display_style_shift_up / upm * scale
            den_y = y0 - mc.fraction_denominator_display_style_shift_down / upm * scale
        else
            num_y = y0 + mc.fraction_numerator_shift_up / upm * scale
            den_y = y0 - mc.fraction_denominator_shift_down / upm * scale
        end

        # Measure widths via temporary boxes, then centre.
        tmp_num = LayoutBox[];  tmp_den = LayoutBox[]
        num_w = _layout_node!(num_node, ctx, num_s, 0.0, num_y, num_scale, tmp_num)
        den_w = _layout_node!(den_node, ctx, den_s, 0.0, den_y, den_scale, tmp_den)
        frac_w = max(num_w, den_w)

        Δnum = (frac_w - num_w) / 2
        for b in tmp_num
            push!(boxes, LayoutBox(b.element, x0 + Δnum + b.x, b.y, b.scale))
        end
        Δden = (frac_w - den_w) / 2
        for b in tmp_den
            push!(boxes, LayoutBox(b.element, x0 + Δden + b.x, b.y, b.scale))
        end
        push!(boxes, LayoutBox(HRule(frac_w, rule_thickness), x0, rule_y, scale))
        return frac_w

    elseif node.kind === NKSqrt
        # \sqrt[degree]{body}: children are [body] or [degree, body].
        body_node = length(node.children) == 1 ? node.children[1] : node.children[2]
        tmp = LayoutBox[]
        body_w    = _layout_node!(body_node, ctx, style, x0, y0, scale, tmp)
        body_top  = _boxes_top(tmp, upm)

        gap = is_display(style) ?
            mc.radical_display_style_vertical_gap / upm * scale :
            mc.radical_vertical_gap / upm * scale
        rule_thickness = mc.radical_rule_thickness / upm * scale

        for b in tmp; push!(boxes, b); end
        push!(boxes, LayoutBox(HRule(body_w, rule_thickness), x0, body_top + gap, scale))
        return body_w

    elseif node.kind === NKDelimited
        # \left…\right: lay out the inner sequence (delimiters not yet sized).
        cursor = x0
        for child in node.children
            cursor += _layout_node!(child, ctx, style, cursor, y0, scale, boxes)
        end
        return cursor - x0

    elseif node.kind === NKAccent
        # Lay out the base; the accent mark is not yet implemented.
        isempty(node.children) && return 0.0
        return _layout_node!(node.children[1], ctx, style, x0, y0, scale, boxes)

    else
        return 0.0   # NKText and unrecognised nodes: emit nothing
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    layout(node, family, style) -> Vector{LayoutBox}

Lay out `node` in the given style, using font metrics from `family`.
Returns a flat list of positioned elements.
"""
function layout(node::Node, family::FontFamily, style::TexStyle)::Vector{LayoutBox}
    mt  = load_math_table(family.math)
    ctx = _LayoutCtx(family, mt.constants, Float64(mt.upm))
    boxes = LayoutBox[]
    _layout_node!(node, ctx, style, 0.0, 0.0, size_scale(style, mt.constants), boxes)
    return boxes
end

# ── Makie interface ────────────────────────────────────────────────────────────

"""
    generate_tex_elements(input, family) -> Vector{LayoutBox}

Top-level entry point: parse and lay out a LaTeX math string.
Returns the same flat `(element, x, y, scale)` representation consumed by
`texelems_and_glyph_collection` in Makie.
"""
function generate_tex_elements(
    input::AbstractString,
    family::FontFamily = default_font_family(),
)::Vector{LayoutBox}
    node = parse_latex(input)
    layout(node, family, Display)
end

"""Return the globally-configured default font family."""
function default_font_family()::FontFamily
    error("not implemented: default_font_family")
end
