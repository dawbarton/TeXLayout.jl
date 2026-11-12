# Matrix and array environment layout.

# Spacing of the display alignment environments (`align`, `gather`, …), which
# have no `_MATRIX_SPACING` entry: `_MATRIX_COLSEP` on each side of a column and
# `_MATRIX_ROWGAP` between ink-tight rows.  amsmath sets these rows with
# `\strut@` and `\jot` instead (see future.md).
const _MATRIX_COLSEP = 5 / 18   # 5 mu per side
const _MATRIX_ROWGAP = 3 / 18   # extra row gap in em

# Parse a column-spec string (e.g. "|l||c|r|") into per-column alignment symbols
# and a vertical-rule count vector.
# col_aligns[c] ∈ {:l, :c, :r} for each column c = 1..ncol.
# vrule[c] = number of rules immediately before column c (c=1..ncol),
# vrule[ncol+1] = number of rules after the last column.
# '||' → vrule count 2 (two rules `_DOUBLERULESEP` apart).
# Unknown tokens (e.g. @{}, p{width}) are silently ignored.
function _parse_colspec(spec::AbstractString)::Tuple{Vector{Symbol}, Vector{Int}}
    col_aligns = Symbol[]
    vrule = Int[]
    pending_rule = 0
    for ch in spec
        if ch === 'l' || ch === 'c' || ch === 'r'
            push!(vrule, pending_rule)
            push!(col_aligns, ch === 'l' ? :l : ch === 'c' ? :c : :r)
            pending_rule = 0
        elseif ch === '|'
            pending_rule += 1
        end
    end
    push!(vrule, pending_rule)   # possible rule(s) after the last column
    return col_aligns, vrule
end

# The lone array-like environment that is the whole content of `children`, if
# any, looking through groups.
function _sole_matrix(children::Vector{Node})::Union{Node, Nothing}
    length(children) == 1 || return nothing
    c = only(children)
    c.kind === NodeKind.Matrix && return c
    c.kind in (NodeKind.Group, NodeKind.Sequence) && return _sole_matrix(c.children)
    return nothing
end

# True when `\left…\right` around matrix node `m` should size its delimiters as
# the environment's own: an array-like environment (rows with TeX's struts, or
# smallmatrix) with no delimiters of its own.
function _takes_outer_delimiters(m::Node)::Bool
    env = _decode_matrix_payload(m.value).env_name
    haskey(_MATRIX_SPACING, env) || return false
    info = get(_MATRIX_ENVS, env, _MATRIX_ENVS["matrix"])
    return isempty(info.left) && isempty(info.right)
end

# Lay out a matrix/array environment (NodeKind.Matrix node).
# Two-pass algorithm: measure all cells first, then place them on a grid
# centred on the math axis.  `left` and `right`, when given, replace the
# environment's delimiters: `\left…\right` around a lone array passes its
# delimiters here so that they are sized against the array's strutted box, as
# in TeX, which the emitted glyphs do not show.
# Returns the total horizontal advance in em units.
function _layout_matrix!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox};
        left::Union{Nothing, String} = nothing,
        right::Union{Nothing, String} = nothing,
    )::Float64
    payload = _decode_matrix_payload(node.value)
    env_name = payload.env_name
    nrow = payload.nrow
    col_aligns, vrule = _parse_colspec(payload.colspec)
    ncol = length(col_aligns)
    (nrow == 0 || ncol == 0) && return 0.0

    info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
    spacing = get(_MATRIX_SPACING, env_name, nothing)
    left_name = something(left, info.left)
    right_name = something(right, info.right)
    upm = ctx.upm
    mc = ctx.mc

    # Display alignment environments (align/gather/split/…) typeset each cell in
    # Display style, so fractions, scripts and big operators keep their full
    # display size.  Genuine array environments (matrix/array/cases) typeset
    # cells in Text style, following TeX's rule for array entries, and
    # smallmatrix in script style.
    small = spacing !== nothing && spacing.rows === :baselineskip
    cell_style = if env_name ∈ _DISPLAY_MATH_ENVS
        is_cramped(style) ? CrampedDisplay : Display
    elseif small
        Script
    else
        is_cramped(style) ? CrampedText : Text
    end
    cell_scale = small ? scale * mc.script_percent_scale_down / 100 : scale

    # ── First pass: lay out each cell into the shared buffer, record ranges ──
    cell_starts = Matrix{Int}(undef, nrow, ncol)
    cell_stops = Matrix{Int}(undef, nrow, ncol)
    cell_widths = zeros(Float64, nrow, ncol)
    cell_heights = zeros(Float64, nrow, ncol)   # max ink above baseline
    cell_depths = zeros(Float64, nrow, ncol)   # max ink below baseline (positive)

    for r in 1:nrow, c in 1:ncol
        cell_starts[r, c] = lastindex(boxes) + 1
        ci = (r - 1) * ncol + c
        if ci > length(node.children)
            cell_stops[r, c] = lastindex(boxes)
            continue
        end
        w = _layout_node!(node.children[ci], ctx, cell_style, 0.0, 0.0, cell_scale, boxes)
        cell_stops[r, c] = lastindex(boxes)
        cell_widths[r, c] = w
        cell_heights[r, c] = max(0.0, _boxes_top(boxes, cell_starts[r, c], cell_stops[r, c], upm))
        cell_depths[r, c] = max(0.0, -_boxes_bottom(boxes, cell_starts[r, c], cell_stops[r, c], upm))
    end

    # ── Compute per-column widths and per-row extents ──
    col_widths = [maximum(cell_widths[:, c]; init = 0.0) for c in 1:ncol]
    row_heights = [maximum(cell_heights[r, :]; init = 0.0) for r in 1:nrow]
    row_depths = [maximum(cell_depths[r, :]; init = 0.0) for r in 1:nrow]

    # Provisional baseline y for each row (row 1 at y = 0).
    row_y = zeros(Float64, nrow)
    if spacing === nothing
        for r in 2:nrow
            row_y[r] = row_y[r - 1] - (row_depths[r - 1] + _MATRIX_ROWGAP * cell_scale + row_heights[r])
        end
    elseif spacing.rows === :strut
        # Every row is at least as tall and deep as \@arstrut; rows then touch.
        row_heights .= max.(row_heights, spacing.stretch * _ARRAY_STRUT_HEIGHT * cell_scale)
        row_depths .= max.(row_depths, spacing.stretch * _ARRAY_STRUT_DEPTH * cell_scale)
        for r in 2:nrow
            row_y[r] = row_y[r - 1] - (row_depths[r - 1] + row_heights[r])
        end
    else
        # TeX's interline glue: baselines \baselineskip apart unless that
        # leaves less than \lineskiplimit between the rows, else \lineskip.
        baselineskip = _SMALLMATRIX_BASELINESKIP * scale
        lineskip = _SMALLMATRIX_LINESKIP * scale
        for r in 2:nrow
            clearance = row_depths[r - 1] + row_heights[r]
            step = baselineskip - clearance >= lineskip ? baselineskip : clearance + lineskip
            row_y[r] = row_y[r - 1] - step
        end
    end

    # Vertical extent of the provisional grid.
    grid_top = row_y[1] + row_heights[1]
    grid_bot = row_y[nrow] - row_depths[nrow]

    # Centre grid on the math axis.
    axis_em = mc.axis_height / upm * scale
    y_shift = y0 + axis_em - (grid_top + grid_bot) / 2

    # In align/aligned the columns form right/left pairs glued together at the
    # alignment point (the `&`): no inter-column space is inserted within a pair,
    # so the spacing around a leading relation comes solely from the math-list
    # relation atom (see the empty-group insertion in the parser). Space is only
    # added between successive pairs, and the grid carries no outer margin.
    tight_pairs = spacing === nothing && env_name ∈ ("align", "aligned", "split")
    outer = spacing !== nothing ? spacing.outer * scale :
        tight_pairs ? 0.0 : _MATRIX_COLSEP * cell_scale
    gap = spacing !== nothing ? spacing.gap * scale : 2 * _MATRIX_COLSEP * cell_scale
    # A `|` rule takes no width; each further rule in a slot adds \doublerulesep.
    rule_sep = _DOUBLERULESEP * cell_scale
    rules_extra(n) = max(n - 1, 0) * rule_sep
    # Gap inserted to the left of column c (c = 2..ncol).
    col_gap(c) = (tight_pairs && iseven(c) ? 0.0 : gap) + rules_extra(vrule[c])

    # Column left-edge positions (relative to content origin, before adding left delimiter).
    x_col = zeros(Float64, ncol)
    x_col[1] = outer + rules_extra(vrule[1])
    for c in 2:ncol
        x_col[c] = x_col[c - 1] + col_widths[c - 1] + col_gap(c)
    end
    content_w = x_col[ncol] + col_widths[ncol] + outer + rules_extra(vrule[ncol + 1])

    # ── Delimiter sizing (if required) ──
    left_w = 0.0; right_w = 0.0
    if left !== nothing || right !== nothing || !isempty(left_name) || !isempty(right_name)
        actual_top = y_shift + grid_top - y0
        actual_bot = y_shift + grid_bot - y0
        h_above = max(0.0, actual_top - axis_em)
        h_below = max(0.0, axis_em - actual_bot)
        δ = max(h_above, h_below)
        # amsmath's delimiters are \left…\right around the array's box, which
        # rule 19 lets fall short of it (`_left_right_required_du`).  The
        # display alignments' rows here are ink-tight, without amsmath's
        # struts, so their delimiters cover the whole grid instead.
        required_du = spacing === nothing ? 2δ / scale * upm : _left_right_required_du(δ, scale, upm)
        left_w = _layout_delim!(ctx, left_name, required_du, x0, y0, scale, boxes)
        right_w = _layout_delim!(
            ctx, right_name, required_du,
            x0 + left_w + content_w, y0, scale, boxes
        )
    end

    # ── Second pass: move all cells to their row/column positions ──
    for r in 1:nrow, c in 1:ncol
        ci = (r - 1) * ncol + c
        ci > length(node.children) && continue
        cell_starts[r, c] <= cell_stops[r, c] || continue

        # Per-column alignment: :l = flush left, :r = flush right, :c = centred.
        offset = col_aligns[c] === :l ? 0.0 :
            col_aligns[c] === :r ? col_widths[c] - cell_widths[r, c] :
            (col_widths[c] - cell_widths[r, c]) / 2
        x_cell = x0 + left_w + x_col[c] + offset
        y_cell = y_shift + row_y[r]
        _translate_range!(boxes, cell_starts[r, c], cell_stops[r, c], x_cell, y_cell)
    end

    # ── Emit vertical rules from colspec ──
    # Rules span the full grid, struts included, as TeX's `|` spans every row.
    # vrule[1]: before col 1; vrule[c]: before col c; vrule[ncol+1]: after the
    # last.  Each rule is centred on its position; a slot's rules start at the
    # outer edge or in the middle of the column gap and are `rule_sep` apart.
    vrule_thick = mc.fraction_rule_thickness / upm * cell_scale
    vrule_bot = y_shift + grid_bot
    vrule_height = grid_top - grid_bot
    function emit_vrules!(start_x::Float64, n::Int)
        for k in 0:(n - 1)
            push!(
                boxes, LayoutBox(
                    VRule(vrule_height, vrule_thick),
                    x0 + left_w + start_x + k * rule_sep - vrule_thick / 2, vrule_bot, scale
                )
            )
        end
        return
    end
    emit_vrules!(0.0, vrule[1])
    for c in 2:ncol
        emit_vrules!(x_col[c - 1] + col_widths[c - 1] + gap / 2, vrule[c])
    end
    emit_vrules!(x_col[ncol] + col_widths[ncol] + outer, vrule[ncol + 1])

    # The trailing margin is part of the array's box, as the leading one is;
    # a Space keeps it in measured extents (`measure`, Makie bounding boxes).
    trailing = outer + rules_extra(vrule[ncol + 1])
    if spacing !== nothing && trailing > 0
        push!(boxes, LayoutBox(Space(trailing), x0 + left_w + content_w - trailing, y_shift + row_y[nrow], scale))
    end

    return left_w + content_w + right_w
end
