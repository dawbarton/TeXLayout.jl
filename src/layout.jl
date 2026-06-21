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
A single glyph to be rendered.

`glyph_name` is the PostScript glyph name; the renderer resolves it to a glyph
index via its font handle.  `font_slot` tells the renderer which font to use:
`FontSlot.Math` for the OpenType math font (math-mode glyphs), or one of the text
font slots (`FontSlot.Regular`, `FontSlot.Bold`, `FontSlot.Italic`,
`FontSlot.BoldItalic`) for document text glyphs.  The metric fields are cached
from the chosen font in design units so the renderer need not re-query them.
"""
struct Glyph <: TeXElement
    glyph_name::String
    font_slot::FontSlot.T
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
# `mode` is either LayoutMode.Math (default) or LayoutMode.Text (inside \text{…}/\mbox{…}).
# Math-mode character remapping and automatic inter-atom spacing are suppressed
# in text mode.
# `font_variant` is :default or the variant name set by an enclosing NodeKind.FontSwitch
# node (e.g. :mathbf, :mathbb).  Propagates through all recursive calls so that
# \mathbf{x_i} produces bold x and bold subscript i.
struct _LayoutCtx
    family::FontFamily
    mc::MathConstants
    upm::Float64
    vert_constructions::Dict{String, GlyphConstruction}
    horiz_constructions::Dict{String, GlyphConstruction}  # for \widehat, \widetilde
    top_accent_attachments::Dict{String, Int}  # PS glyph name → x position (design units)
    italic_corrections::Dict{String, Int}      # PS glyph name → design units (from MATH table)
    min_connector_overlap::Int
    mode::LayoutMode.T
    font_variant::Symbol  # :default | :mathbf | :mathit | :mathrm | :mathbb | …
end

# Return a copy of `ctx` with `font_variant` replaced.  Used by NodeKind.FontSwitch so
# the rest of the context (family, math constants, mode, …) is inherited.
@inline _with_variant(ctx::_LayoutCtx, variant::Symbol) = _LayoutCtx(
    ctx.family, ctx.mc, ctx.upm, ctx.vert_constructions, ctx.horiz_constructions,
    ctx.top_accent_attachments, ctx.italic_corrections, ctx.min_connector_overlap,
    ctx.mode, variant,
)

# Propagate a font-size multiplier (from \large, \tiny, etc.) through a style
# transition.  `scale` is the parent's absolute scale (which already includes
# any sizing factor); `parent_s` and `child_s` are TeX styles.  The result is
# the child's absolute scale, preserving whatever sizing factor was embedded in
# the parent scale beyond what the parent style alone contributes.
#
#   child_scale = scale × (size_scale(child_s) / size_scale(parent_s))
#
# Because size_scale only returns 1.0, ~0.7, or ~0.5 (never zero), the
# division is always safe.
@inline _scale_for_child(
    scale::Float64, parent_s::TexStyle, child_s::TexStyle,
    mc::MathConstants
) =
    scale * (size_scale(child_s, mc) / size_scale(parent_s, mc))

# Return a copy of `ctx` with mode set to :text, preserving all other fields.
# Used by NodeKind.Text so that character lookup uses upright (regular-font) glyphs and
# math-mode italic remapping and inter-atom spacing are suppressed.
@inline _with_text_mode(ctx::_LayoutCtx) = _LayoutCtx(
    ctx.family, ctx.mc, ctx.upm, ctx.vert_constructions, ctx.horiz_constructions,
    ctx.top_accent_attachments, ctx.italic_corrections, ctx.min_connector_overlap,
    LayoutMode.Text, ctx.font_variant,
)

# Return the TeX atom class for a given AST node.
# Scripted nodes (NodeKind.Superscript, NodeKind.Subscript, NodeKind.Decorated) inherit from their
# base (first child).  Groups and sequences are treated as ordinary atoms.
# NodeKind.Space yields :neutral — these nodes are transparent to auto-spacing.
function _atom_class(node::Node)::Symbol
    k = node.kind
    if k === NodeKind.Char
        ch = only(node.value)
        ch = get(_MATH_CHAR_REMAP, ch, ch)   # same remap as _char_glyph
        return get(_CHAR_ATOM_CLASS, ch, :ord)
    elseif k === NodeKind.Command
        cmd = node.value
        name = startswith(cmd, "\\") ? cmd[2:end] : cmd
        return get(_CMD_ATOM_CLASS, name, :ord)
    elseif k === NodeKind.Operator
        return :op
    elseif k === NodeKind.BigDelim
        # Class char is the last byte of value: 'o'=open, 'c'=close, 'r'=rel, 'd'=ord.
        isempty(node.value) && return :ord
        c = node.value[end]
        c == 'o' && return :open
        c == 'c' && return :close
        c == 'r' && return :rel
        return :ord
    elseif k === NodeKind.Frac || k === NodeKind.Genfrac || k === NodeKind.Delimited || k === NodeKind.HorizBrace || k === NodeKind.Matrix
        return :inner
    elseif k === NodeKind.Sqrt || k === NodeKind.Accent || k === NodeKind.OverUnder || k === NodeKind.Text
        return :ord
    elseif k === NodeKind.Superscript || k === NodeKind.Subscript || k === NodeKind.Decorated
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from base
    elseif k === NodeKind.LimitsOverride
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from wrapped base
    elseif k === NodeKind.FontSwitch
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from body (e.g. \mathbf{+} is :bin)
    elseif k === NodeKind.StyleOverride || k === NodeKind.Sizing
        isempty(node.children) && return :ord
        return _atom_class(node.children[1])   # inherit from wrapped body
    elseif k === NodeKind.XArrow
        return :rel   # extensible arrows are relation atoms
    elseif k === NodeKind.Space
        return :neutral   # explicit spaces reset the spacing context
    else
        return :ord   # NodeKind.Sequence, NodeKind.Group: braced sub-expressions are ordinary
    end
end

# Return automatic inter-atom spacing in em between atoms of class `prev` and
# `next`.  Uses tight spacings in Script/ScriptScript style.
function _interatom_space(prev::Symbol, next::Symbol, style::TexStyle)::Float64
    tight = is_script(style) || is_script_script(style)
    return get(tight ? _TIGHT_SPACINGS : _SPACINGS, (prev, next), 0.0)
end

@inline function _left_reclassified_atom_class(cls::Symbol, prev_nc::Symbol)::Symbol
    cls === :bin && (prev_nc === :nothing || prev_nc ∈ _BIN_LEFT_CANCEL) && return :ord
    return cls
end

function _next_left_reclassified_atom_class(
        nodes::AbstractVector{Node},
        i::Int,
        prev_nc::Symbol,
    )::Symbol
    for j in (i + 1):lastindex(nodes)
        cls = _atom_class(nodes[j])
        cls === :neutral && continue
        return _left_reclassified_atom_class(cls, prev_nc)
    end
    return :nothing
end

# Return a Glyph for a Unicode character.
# In math mode, certain ASCII characters are remapped to their correct math
# Unicode equivalents before the glyph lookup (e.g. '-' → U+2212).
# Always resolve by codepoint: the Unicode cmap yields the math-italic form for
# letters, whereas glyph_metrics(family, "x") returns the upright roman slot.
function _char_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph, Nothing}
    if ctx.mode === LayoutMode.Math
        ch = get(_MATH_CHAR_REMAP, ch, ch)
    end
    cp = UInt32(ch)
    m = glyph_metrics_by_codepoint(ctx.family, cp)
    m === nothing && return nothing
    ps = glyph_name_by_codepoint(ctx.family, cp)
    return Glyph(
        isempty(ps) ? string(ch) : ps, FontSlot.Math,
        m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
end

# Return an upright Glyph for a character, or nothing if not in the font.
# Uses the regular font slot when present (both metrics and PS name come from
# the same font so the renderer can locate the glyph correctly); falls back to
# the math font when no regular font is configured.
function _upright_glyph(ctx::_LayoutCtx, ch::Char)::Union{Glyph, Nothing}
    family = ctx.family
    if family.regular !== nothing
        m = glyph_metrics_upright(family, ch)
        m === nothing && return nothing
        ps = glyph_name_by_codepoint(family.regular, UInt32(ch))
        name = isempty(ps) ? string(ch) : ps
        return Glyph(
            name, FontSlot.Regular, m.advance_width, m.left_side_bearing,
            m.x_min, m.y_min, m.x_max, m.y_max
        )
    else
        m = glyph_metrics_by_codepoint(family, UInt32(ch))
        m === nothing && return nothing
        ps = glyph_name_by_codepoint(family.math, UInt32(ch))
        name = isempty(ps) ? string(ch) : ps
        return Glyph(
            name, FontSlot.Math, m.advance_width, m.left_side_bearing,
            m.x_min, m.y_min, m.x_max, m.y_max
        )
    end
end

# Return a Glyph for a PostScript glyph name, or nothing if not in the font.
# Used exclusively for font-internal names from the MATH table (size variants,
# assembly parts, radical/delimiter base glyphs) — not for TeX command names.
# Falls back via _CANONICAL_CODEPOINTS for AGL names that fail in fonts using
# Unicode-style PS names (e.g. FiraMath "uni0028" vs AGL "parenleft").
# The returned Glyph carries the font's own PS name so renderers can locate it.
function _cmd_glyph(ctx::_LayoutCtx, name::String)::Union{Glyph, Nothing}
    m = glyph_metrics(ctx.family, name)
    m !== nothing && return Glyph(
        name, FontSlot.Math, m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
    # Fallback 1: AGL name with a known codepoint (e.g. "parenleft" in a font
    # that uses "uni0028").
    cp = get(_CANONICAL_CODEPOINTS, name, nothing)
    # Fallback 2: "uni{HHHH}" name (e.g. "uni23DE") in a font that uses the AGL
    # name ("overbrace").  Parse the codepoint and resolve via the font's own map.
    if cp === nothing
        m2 = match(r"^uni([0-9A-Fa-f]{4,6})$", name)
        m2 !== nothing && (cp = parse(UInt32, m2.captures[1], base = 16))
    end
    cp === nothing && return nothing
    m2 = glyph_metrics_by_codepoint(ctx.family, cp)
    m2 === nothing && return nothing
    ps = glyph_name_by_codepoint(ctx.family, cp)
    actual = isempty(ps) ? name : ps
    return Glyph(
        actual, FontSlot.Math, m2.advance_width, m2.left_side_bearing,
        m2.x_min, m2.y_min, m2.x_max, m2.y_max
    )
end

# Return the key under which a canonically-named glyph is stored in
# vert_constructions.  Fonts that use Unicode-style PS names (e.g. FiraMath)
# store the entry under "uni0028" rather than "parenleft"; we translate by
# resolving the codepoint to the font's own PS name.
function _construction_key(ctx::_LayoutCtx, canonical_name::String)::String
    haskey(ctx.vert_constructions, canonical_name) && return canonical_name
    cp = get(_CANONICAL_CODEPOINTS, canonical_name, nothing)
    cp === nothing && return canonical_name
    ps = glyph_name_by_codepoint(ctx.family, cp)
    !isempty(ps) && haskey(ctx.vert_constructions, ps) && return ps
    return canonical_name
end

# Return the key under which a Unicode-named brace glyph is stored in
# horiz_constructions.  Most fonts use "uni23DE" etc., but some (e.g. Luciole)
# use AGL names ("overbrace").  Resolve via the font's own codepoint→PS mapping.
function _horiz_construction_key(ctx::_LayoutCtx, uni_name::String)::String
    haskey(ctx.horiz_constructions, uni_name) && return uni_name
    m = match(r"^uni([0-9A-Fa-f]{4,6})$", uni_name)
    m === nothing && return uni_name
    cp = parse(UInt32, m.captures[1], base = 16)
    ps = glyph_name_by_codepoint(ctx.family, cp)
    !isempty(ps) && haskey(ctx.horiz_constructions, ps) && return ps
    return uni_name
end

# Return a Glyph for character `ch` under the given font variant (Option C):
#   1. Try Unicode math-variant codepoint in the math font (covers mathbf, mathbb, etc.).
#   2. For :mathrm, fall through to the upright glyph lookup (regular font or math codepoint).
#   3. Fall through to the default character glyph (italic math form).
function _variant_glyph(ctx::_LayoutCtx, variant::Symbol, ch::Char)::Union{Glyph, Nothing}
    cp = _math_variant_codepoint(variant, ch)
    if cp !== nothing
        m = glyph_metrics_by_codepoint(ctx.family, cp)
        if m !== nothing
            ps = glyph_name_by_codepoint(ctx.family, cp)
            return Glyph(
                isempty(ps) ? string(Char(cp)) : ps, FontSlot.Math,
                m.advance_width, m.left_side_bearing,
                m.x_min, m.y_min, m.x_max, m.y_max
            )
        end
    end
    return _char_glyph(ctx, ch)
end

function _translate_range!(
        boxes::Vector{LayoutBox},
        start::Int,
        stop::Int,
        dx::Float64,
        dy::Float64,
    )::Nothing
    start > stop && return nothing
    for i in start:stop
        b = boxes[i]
        boxes[i] = LayoutBox(b.element, b.x + dx, b.y + dy, b.scale)
    end
    return nothing
end

# Maximum y-extent (top of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y; its top is box.y + element.thickness.
function _boxes_top(boxes::Vector{LayoutBox}, start::Int, stop::Int, upm::Float64)::Float64
    top = 0.0
    start > stop && return top
    for i in start:stop
        b = boxes[i]
        el = b.element
        if el isa Glyph
            top = max(top, b.y + el.y_max / upm * b.scale)
        elseif el isa HRule
            top = max(top, b.y + el.thickness)
        end
    end
    return top
end

_boxes_top(boxes::Vector{LayoutBox}, upm::Float64)::Float64 =
    _boxes_top(boxes, firstindex(boxes), lastindex(boxes), upm)

# Minimum y-extent (bottom of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y.
function _boxes_bottom(boxes::Vector{LayoutBox}, start::Int, stop::Int, upm::Float64)::Float64
    bot = 0.0
    start > stop && return bot
    for i in start:stop
        b = boxes[i]
        el = b.element
        if el isa Glyph
            bot = min(bot, b.y + el.y_min / upm * b.scale)
        elseif el isa HRule
            bot = min(bot, b.y)
        end
    end
    return bot
end

_boxes_bottom(boxes::Vector{LayoutBox}, upm::Float64)::Float64 =
    _boxes_bottom(boxes, firstindex(boxes), lastindex(boxes), upm)

_boxes_vextent(boxes::Vector{LayoutBox}, start::Int, stop::Int, upm::Float64)::Tuple{Float64, Float64} =
    (_boxes_top(boxes, start, stop, upm), _boxes_bottom(boxes, start, stop, upm))

# ── Limits-placement helpers ─────────────────────────────────────────────────

# Unwrap NodeKind.LimitsOverride to expose the actual operator node for layout.
_limits_base(node::Node) = node.kind === NodeKind.LimitsOverride ? node.children[1] : node

# Return the italic correction (in em units) of the first Glyph in `boxes`, or 0.0.
# Used to shift limits of slanted operators (e.g. ∫) so they track the diagonal stroke.
# Per the OpenType MATH spec and KaTeX, limits are offset by ±½ IC: subscripts shift
# left and superscripts shift right.
function _base_italic_correction_em(
        boxes::Vector{LayoutBox}, start::Int, stop::Int, ctx::_LayoutCtx,
        scale::Float64
    )::Float64
    start > stop && return 0.0
    for i in start:stop
        b = boxes[i]
        b.element isa Glyph || continue
        ic = get(ctx.italic_corrections, b.element.glyph_name, 0)
        return ic * scale / ctx.upm
    end
    return 0.0
end

_base_italic_correction_em(boxes::Vector{LayoutBox}, ctx::_LayoutCtx, scale::Float64)::Float64 =
    _base_italic_correction_em(boxes, firstindex(boxes), lastindex(boxes), ctx, scale)

# Return true when the script children of a decorated atom should be placed above
# and below the base (limits style) rather than beside it (side style).
function _use_limits(base::Node, style::TexStyle)::Bool
    base.kind === NodeKind.LimitsOverride && return base.value == "limits"
    if base.kind === NodeKind.Operator
        return base.value ∈ _LIMITS_OPERATORS && is_display(style)
    end
    if base.kind === NodeKind.Command
        name = startswith(base.value, "\\") ? base.value[2:end] : base.value
        return name ∈ _LIMITS_OP_COMMANDS && is_display(style)
    end
    return false
end

# Return true when `node` is a large operator whose scripts should be clamped
# to the glyph extents in Display style (integral-family operators).  Unlike
# _use_limits, this returns true for integrals and oint which use side placement.
function _is_large_op(node::Node)::Bool
    n = node.kind === NodeKind.LimitsOverride ? node.children[1] : node
    n.kind === NodeKind.Command || return false
    name = startswith(n.value, "\\") ? n.value[2:end] : n.value
    return haskey(_DISPLAY_OP_CODEPOINTS, name)
end

# Return true when `node` renders as a single character glyph (KaTeX isCharacterBox).
# TeX Rules 18a–e apply supDrop/subDrop clamps only to non-character bases such as
# fractions, delimited expressions, and multi-child groups.
function _is_char_box(node::Node)::Bool
    n = node.kind === NodeKind.LimitsOverride ? node.children[1] : node
    n.kind === NodeKind.Char && return true
    n.kind === NodeKind.Operator && return false  # named operators (e.g. \sin) are not char boxes
    n.kind === NodeKind.Command && return !_is_large_op(n)  # large ops are not char boxes
    # NodeKind.FontSwitch is constructed with exactly one body child by the parser, so the
    # recursion is unconditional.
    n.kind === NodeKind.FontSwitch && return _is_char_box(n.children[1])
    return false
end

# ── Recursive layout ──────────────────────────────────────────────────────────

# Lay out a list of child nodes with inter-atom auto-spacing in math mode.
# Returns the total advance width.  Used by NodeKind.Sequence, NodeKind.Group, and the inner
# content loop of NodeKind.Delimited so spacing is consistent in all three contexts.
#
# Applies TeX Rules 5 & 6 (binary atom reclassification) before computing spacing:
# a mbin atom is demoted to mord when the surrounding context would produce
# nonsensical spacing (e.g. a leading or trailing binary operator).
function _layout_children!(
        nodes::AbstractVector{Node},
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    isempty(nodes) && return 0.0

    # Emit nodes with inter-atom spacing using the reclassified classes.
    cursor = x0
    prev_left_class = :nothing
    prev_emit_class = :nothing
    for i in eachindex(nodes)
        raw_cls = _atom_class(nodes[i])
        if raw_cls === :neutral
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_emit_class = :nothing
        else
            left_cls = _left_reclassified_atom_class(raw_cls, prev_left_class)
            next_cls = _next_left_reclassified_atom_class(nodes, i, left_cls)
            cls = left_cls === :bin && next_cls ∈ _BIN_RIGHT_CANCEL ? :ord : left_cls
            if ctx.mode === LayoutMode.Math && prev_emit_class !== :nothing
                sp = _interatom_space(prev_emit_class, cls, style) * scale
                if sp > 0.0
                    push!(boxes, LayoutBox(Space(sp), cursor, y0, scale))
                    cursor += sp
                end
            end
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_left_class = left_cls
            prev_emit_class = cls
        end
    end
    return cursor - x0
end

function _layout_children!(
        children,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    return _layout_children!(collect(children), ctx, style, x0, y0, scale, boxes)
end

# ── Per-kind layout helpers ──────────────────────────────────────────────────
# Each `_layout_X!` takes the same signature and returns the horizontal advance
# of the node in em units.  `_layout_node!` at the bottom dispatches on
# `node.kind`.  This per-kind split keeps each rule small enough to read in one
# screen and isolates changes to a single function.

# Strip the leading '\' from a TokenKind.Command value, returning the bare command name.
@inline _command_name(cmd::AbstractString) =
    startswith(cmd, '\\') ? cmd[2:end] : cmd

function _layout_char!(node, ctx, style, x0, y0, scale, boxes)
    ch = only(node.value)
    g = if ctx.font_variant !== :default
        _variant_glyph(ctx, ctx.font_variant, ch)
    elseif ctx.mode === LayoutMode.Math && isletter(ch)
        # Standard LaTeX renders math-mode letters italic; use the
        # math-italic Unicode variant (U+1D400 block) so e.g. 'x' → u1D465.
        _variant_glyph(ctx, :mathit, ch)
    elseif ctx.mode === LayoutMode.Text && ch == ' '
        # Space in text mode: emit a Space element with the font's word-space advance.
        m = glyph_metrics_upright(ctx.family, ' ')
        w = m === nothing ? 0.25 : m.advance_width / ctx.upm * scale
        push!(boxes, LayoutBox(Space(w), x0, y0, scale))
        return w
    elseif ctx.mode === LayoutMode.Text
        # \text{}/\mbox{}: use upright (regular-font) glyph; no italic remapping.
        _upright_glyph(ctx, ch)
    else
        _char_glyph(ctx, ch)
    end
    g === nothing && return 0.0
    push!(boxes, LayoutBox(g, x0, y0, scale))
    return g.advance_width / ctx.upm * scale
end

function _layout_command!(node, ctx, style, x0, y0, scale, boxes)
    mc, upm = ctx.mc, ctx.upm
    name = _command_name(node.value)
    if haskey(_DISPLAY_OP_CODEPOINTS, name)
        # Large operator: resolve glyph by codepoint so the correct PS name
        # (e.g. "summation") is used instead of the bare command name ("sum").
        ps = glyph_name_by_codepoint(ctx.family, _DISPLAY_OP_CODEPOINTS[name])
        isempty(ps) && return 0.0
        # In Display style, pick the smallest vert_constructions variant that
        # meets or exceeds display_operator_min_height (in design units).
        chosen = ps
        if is_display(style) && haskey(ctx.vert_constructions, ps)
            min_h = Float64(mc.display_operator_min_height)
            for v in ctx.vert_constructions[ps].variants
                if Float64(v.advance) >= min_h
                    chosen = v.glyph_name
                    break
                end
            end
        end
        g = _cmd_glyph(ctx, chosen)
        g === nothing && return 0.0
        # Centre large operator on the math axis (same logic as _layout_delim!).
        glyph_center = (g.y_min + g.y_max) / (2.0 * upm)
        y_op = y0 + (mc.axis_height / upm - glyph_center) * scale
        push!(boxes, LayoutBox(g, x0, y_op, scale))
        return g.advance_width / upm * scale
    end

    # Ordinary symbols are resolved by codepoint via _SYMBOL_CODEPOINTS so the
    # correct glyph is found regardless of font-specific PS naming.
    cp = get(_SYMBOL_CODEPOINTS, name, nothing)
    cp === nothing && return 0.0
    # Inside a font-switch context (\mathbf, \boldsymbol, etc.), try to map to
    # the variant codepoint (e.g. \alpha inside \mathbf{} → bold Greek alpha).
    if ctx.font_variant !== :default
        vcp = _math_variant_codepoint(ctx.font_variant, Char(cp))
        vcp !== nothing && (cp = vcp)
    else
        # In default math mode, Greek lowercase letters, their variants, and ∂
        # are italic (LaTeX convention).  ∇ is intentionally excluded: it is
        # upright in LaTeX.  Uppercase Greek is also excluded (upright by default).
        ch = Char(cp)
        if 'α' <= ch <= 'ω' || ch === '∂' ||
                ch === 'ϵ' || ch === 'ϑ' || ch === 'ϰ' ||
                ch === 'ϕ' || ch === 'ϱ' || ch === 'ϖ'
            vcp = _math_variant_codepoint(:mathit, ch)
            vcp !== nothing && (cp = vcp)
        end
    end
    m = glyph_metrics_by_codepoint(ctx.family, cp)
    m === nothing && return 0.0
    ps = glyph_name_by_codepoint(ctx.family, cp)
    g = Glyph(
        isempty(ps) ? name : ps, FontSlot.Math,
        m.advance_width, m.left_side_bearing,
        m.x_min, m.y_min, m.x_max, m.y_max
    )
    push!(boxes, LayoutBox(g, x0, y0, scale))
    return g.advance_width / upm * scale
end

function _layout_operator!(node, ctx, style, x0, y0, scale, boxes)
    # Render each character of the operator name upright (roman).
    cursor = x0
    for ch in node.value
        g = _upright_glyph(ctx, ch)
        g === nothing && continue
        push!(boxes, LayoutBox(g, cursor, y0, scale))
        cursor += g.advance_width / ctx.upm * scale
    end
    return cursor - x0
end

function _layout_space!(node, ctx, style, x0, y0, scale, boxes)
    iszero(node.width) && return 0.0
    w = node.width * scale
    push!(boxes, LayoutBox(Space(w), x0, y0, scale))
    return w
end

# Lay out `node` into `boxes`, with the left-baseline anchor at (x0, y0) and
# the given scale.  Returns the horizontal advance of the node in em units.
# Dispatches per `node.kind` to a specialised `_layout_X!` helper above.
function _layout_node!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    k = node.kind
    k === NodeKind.Char           && return _layout_char!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Command        && return _layout_command!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Operator       && return _layout_operator!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Space          && return _layout_space!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Sequence       && return _layout_children!(node.children, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Group          && return _layout_children!(node.children, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Superscript    && return _layout_superscript!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Subscript      && return _layout_subscript!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Decorated      && return _layout_decorated!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Frac           && return _layout_frac!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Genfrac        && return _layout_genfrac!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.BigDelim       && return _layout_big_delim!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Sqrt           && return _layout_sqrt!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Delimited      && return _layout_delimited!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.FontSwitch     && return _layout_font_switch!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Accent         && return _layout_accent!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.OverUnder      && return _layout_overunder!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.HorizBrace     &&
        return _layout_horiz_brace!(node, nothing, nothing, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Matrix         && return _layout_matrix!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.LimitsOverride && return _layout_node!(_limits_base(node), ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Text           && return _layout_text!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.StyleOverride  && return _layout_style_override!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.Sizing         && return _layout_sizing!(node, ctx, style, x0, y0, scale, boxes)
    k === NodeKind.XArrow         && return _layout_xarrow!(node, ctx, style, x0, y0, scale, boxes)
    # NodeKind.Middle outside \left…\right (malformed input) and unrecognised kinds: emit nothing.
    return 0.0
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    layout(node, family, style) -> Vector{LayoutBox}

Lay out `node` in the given style, using font metrics from `family`.
Returns a flat list of positioned elements.
"""
function layout(node::Node, family::FontFamily, style::TexStyle)::Vector{LayoutBox}
    mt = load_math_table(family.math)
    ctx = _LayoutCtx(
        family, mt.constants, Float64(mt.upm), mt.vert_constructions,
        mt.horiz_constructions, mt.top_accent_attachments,
        mt.italic_corrections,
        mt.min_connector_overlap, LayoutMode.Math, :default
    )
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
    return layout(node, family, Display)
end
