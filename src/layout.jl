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
`FontSlot.Math` for the OpenType math font (all math-mode glyphs), or `FontSlot.Regular` for
the companion text font (glyphs inside `\\text{}`/`\\mbox{}`).  The metric
fields are cached from the chosen font in design units so the renderer need not
re-query them.
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

# Copy every element of `src` into `dst`, translating each box by (dx, dy).
# Used throughout the layout engine to splice a scratch sub-layout (laid out
# at origin (0,0) or some local origin) into the parent's coordinate system.
function _emit_shifted!(
        dst::Vector{LayoutBox}, src::Vector{LayoutBox},
        dx::Float64, dy::Float64
    )
    for b in src
        push!(dst, LayoutBox(b.element, b.x + dx, b.y + dy, b.scale))
    end
    return nothing
end

# Maximum y-extent (top of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y; its top is box.y + element.thickness.
function _boxes_top(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    top = 0.0
    for b in boxes
        el = b.element
        if el isa Glyph
            top = max(top, b.y + el.y_max / upm * b.scale)
        elseif el isa HRule
            top = max(top, b.y + el.thickness)
        end
    end
    return top
end

# Minimum y-extent (bottom of the ink) of all boxes, in em units.
# HRule stores its bottom edge in box.y.
function _boxes_bottom(boxes::Vector{LayoutBox}, upm::Float64)::Float64
    bot = 0.0
    for b in boxes
        el = b.element
        if el isa Glyph
            bot = min(bot, b.y + el.y_min / upm * b.scale)
        elseif el isa HRule
            bot = min(bot, b.y)
        end
    end
    return bot
end

# ── Limits-placement helpers ─────────────────────────────────────────────────

# Unwrap NodeKind.LimitsOverride to expose the actual operator node for layout.
_limits_base(node::Node) = node.kind === NodeKind.LimitsOverride ? node.children[1] : node

# Return the italic correction (in em units) of the first Glyph in `boxes`, or 0.0.
# Used to shift limits of slanted operators (e.g. ∫) so they track the diagonal stroke.
# Per the OpenType MATH spec and KaTeX, limits are offset by ±½ IC: subscripts shift
# left and superscripts shift right.
function _base_italic_correction_em(
        boxes::Vector{LayoutBox}, ctx::_LayoutCtx,
        scale::Float64
    )::Float64
    for b in boxes
        b.element isa Glyph || continue
        ic = get(ctx.italic_corrections, b.element.glyph_name, 0)
        return ic * scale / ctx.upm
    end
    return 0.0
end

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
        children,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    isempty(children) && return 0.0

    # Collect into an indexable array and compute initial atom classes.
    nodes = children isa Vector ? children : collect(children)
    n = length(nodes)
    classes = Vector{Symbol}(undef, n)
    for i in 1:n
        classes[i] = _atom_class(nodes[i])
    end

    # Rule 5: mbin → mord when left-context is start-of-list, bin, open, rel, op, or punct.
    # Neutral (space) nodes are transparent: they do not update the context.
    prev_nc = :nothing
    for i in 1:n
        cls = classes[i]
        cls === :neutral && continue
        if cls === :bin && (prev_nc === :nothing || prev_nc ∈ _BIN_LEFT_CANCEL)
            classes[i] = :ord
        end
        prev_nc = classes[i]
    end

    # Rule 6: mbin → mord when right-context is rel, close, or punct.
    next_nc = :nothing
    for i in n:-1:1
        cls = classes[i]
        cls === :neutral && continue
        if cls === :bin && next_nc ∈ _BIN_RIGHT_CANCEL
            classes[i] = :ord
        end
        next_nc = classes[i]
    end

    # Emit nodes with inter-atom spacing using the reclassified classes.
    cursor = x0
    prev_class = :nothing
    for i in 1:n
        cls = classes[i]
        if cls === :neutral
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_class = :nothing
        else
            if ctx.mode === LayoutMode.Math && prev_class !== :nothing
                sp = _interatom_space(prev_class, cls, style) * scale
                if sp > 0.0
                    push!(boxes, LayoutBox(Space(sp), cursor, y0, scale))
                    cursor += sp
                end
            end
            cursor += _layout_node!(nodes[i], ctx, style, cursor, y0, scale, boxes)
            prev_class = cls
        end
    end
    return cursor - x0
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
