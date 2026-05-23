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
    vert_constructions::Dict{String,GlyphConstruction}
    min_connector_overlap::Int
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

# Minimum y-extent (bottom of the ink) of all Glyph boxes, in em units.
function _boxes_bottom(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    bot = 0.0
    for b in boxes
        if b.element isa Glyph
            bot = min(bot, b.y + b.element.y_min / upm * b.scale)
        end
    end
    return bot
end

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
        h += parts[i].full_advance - _gap_min_overlap(parts[i-1], parts[i], min_conn)
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
    upm      = ctx.upm
    mc       = ctx.mc
    min_conn = ctx.min_connector_overlap

    n     = _min_extender_reps(asm.parts, required_du, min_conn)
    parts = _expand_assembly_parts(asm.parts, n)
    isempty(parts) && return 0.0

    # Overlap for each gap between adjacent parts (minimum overlap, so the
    # assembly is as tall as the required extent).
    overlaps = Vector{Int}(undef, max(0, length(parts) - 1))
    for i in 1:length(overlaps)
        overlaps[i] = _gap_min_overlap(parts[i], parts[i+1], min_conn)
    end

    # Total assembly height in design units.
    total_du = Float64(parts[1].full_advance)
    for i in 1:length(overlaps)
        total_du += parts[i+1].full_advance - overlaps[i]
    end

    # Place the assembly so its ink centre aligns with the math axis.
    axis_em     = y0 + mc.axis_height / upm * scale
    asm_bot_em  = axis_em - (total_du / upm * scale) / 2.0

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
    mc  = ctx.mc

    function _place_glyph(name::String)::Float64
        g = _cmd_glyph(ctx, name)
        g === nothing && return 0.0
        glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
        y_del = y0 + (mc.axis_height / upm - glyph_center) * scale
        push!(boxes, LayoutBox(g, x0, y_del, scale))
        return g.advance_width / upm * scale
    end

    if !haskey(ctx.vert_constructions, glyph_name)
        return _place_glyph(glyph_name)
    end

    vc = ctx.vert_constructions[glyph_name]

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
        w = parse(Float64, node.value) * scale
        iszero(w) && return 0.0
        push!(boxes, LayoutBox(Space(w), x0, y0, scale))
        return w

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
        # \left…\right: size delimiters to the inner content, centred on the math axis.
        # node.value encodes "left_ps_name\x00right_ps_name".
        sep        = findfirst('\x00', node.value)
        left_name  = sep === nothing ? node.value : node.value[1:sep-1]
        right_name = sep === nothing ? ""          : node.value[sep+1:end]

        # Lay out inner content in a scratch buffer to measure its vertical extent.
        tmp    = LayoutBox[]
        cursor = x0
        for child in node.children
            cursor += _layout_node!(child, ctx, style, cursor, y0, scale, tmp)
        end
        content_w = cursor - x0

        # Vertical extent of the inner content (in em units relative to y0).
        content_top = _boxes_top(tmp, upm)
        content_bot = _boxes_bottom(tmp, upm)
        # Ensure a sensible non-zero span when content has no glyph ink.
        content_top = max(content_top, y0 + mc.axis_height / upm * scale)
        content_bot = min(content_bot, y0 - mc.axis_height / upm * scale)

        # Required delimiter advance: sized so the delimiter covers the content
        # symmetrically around the math axis.  Converted to unscaled design units
        # because GlyphVariant.advance and GlyphAssemblyPart.full_advance are
        # both stored in unscaled design units.
        axis_em     = y0 + mc.axis_height / upm * scale
        h_above     = max(0.0, content_top - axis_em)
        h_below     = max(0.0, axis_em - content_bot)
        required_em = 2.0 * max(h_above, h_below)
        required_du = required_em / scale * upm

        # Place left delimiter (variant or assembly), then inner content, then right.
        left_w  = _layout_delim!(ctx, left_name,  required_du, x0,               y0, scale, boxes)
        inner_x = x0 + left_w
        for b in tmp
            push!(boxes, LayoutBox(b.element, inner_x + (b.x - x0), b.y, b.scale))
        end
        right_w = _layout_delim!(ctx, right_name, required_du, inner_x + content_w, y0, scale, boxes)

        return left_w + content_w + right_w

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
    ctx = _LayoutCtx(family, mt.constants, Float64(mt.upm), mt.vert_constructions,
                     mt.min_connector_overlap)
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
