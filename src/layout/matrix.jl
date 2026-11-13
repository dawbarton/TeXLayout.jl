# Matrix and array environment layout.

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
# the environment's own: one with no delimiters of its own (`matrix`, `array`,
# `aligned`, …).
function _takes_outer_delimiters(m::Node)::Bool
    info = get(_MATRIX_ENVS, _decode_matrix_payload(m.value).env_name, _MATRIX_ENVS["matrix"])
    return isempty(info.left) && isempty(info.right)
end

# Lay out a matrix/array environment (NodeKind.Matrix node).
# Two-pass algorithm: measure all cells first, then place them on a grid
# centred on the math axis.  `left` and `right`, when given, replace the
# environment's delimiters: `\left…\right` around a lone array passes its
# delimiters here so that they are sized against the array's strutted box, as
# in TeX, which the emitted glyphs do not show.
# Returns the total horizontal advance in em units.
_layout_matrix!(node, ctx, style, x0, y0, scale, boxes; kwargs...) =
    _layout_matrix_box!(node, ctx, style, x0, y0, scale, boxes; kwargs...).width

# As `_layout_matrix!`, returning the environment's box: its advance `width`
# and the `height` and `depth` of TeX's box about the baseline y0, struts
# included (they are invisible, so the emitted glyphs do not show them).
function _layout_matrix_box!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox};
        left::Union{Nothing, String} = nothing,
        right::Union{Nothing, String} = nothing,
    )
    payload = _decode_matrix_payload(node.value)
    env_name = payload.env_name
    nrow = payload.nrow
    nrow == 0 && return (width = 0.0, height = 0.0, depth = 0.0)
    col_aligns, vrule = _parse_colspec(payload.colspec)
    # Cells are stored row-major with the observed column count as stride.  An
    # explicit `array` colspec may declare more columns than are used (valid
    # LaTeX) or fewer (extra cells are centred and carry no rules).
    stride = length(node.children) ÷ nrow
    for _ in (length(col_aligns) + 1):stride
        push!(col_aligns, :c)
        insert!(vrule, lastindex(vrule), 0)   # keep trailing rules after the last column
    end
    ncol = length(col_aligns)
    ncol == 0 && return (width = 0.0, height = 0.0, depth = 0.0)
    # Index of the cell at (r, c), or 0 when that column was not used in the source.
    cell_index(r, c) = c <= stride ? (r - 1) * stride + c : 0

    info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
    spacing = get(_MATRIX_SPACING, env_name, _MATRIX_SPACING["matrix"])
    left_name = something(left, info.left)
    right_name = something(right, info.right)
    upm = ctx.upm
    mc = ctx.mc

    # Display alignment environments (align/gather/split/…) typeset each cell in
    # Display style, so fractions, scripts and big operators keep their full
    # display size.  Genuine array environments (matrix/array/cases) typeset
    # cells in Text style, following TeX's rule for array entries, and
    # smallmatrix in script style.
    small = env_name == "smallmatrix"
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
        ci = cell_index(r, c)
        if ci == 0
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

    # Every row is at least as tall and deep as the environment's strut.
    row_heights .= max.(row_heights, spacing.strut * _ARRAY_STRUT_HEIGHT * cell_scale)
    row_depths .= max.(row_depths, spacing.strut * _ARRAY_STRUT_DEPTH * cell_scale)

    # \\[len] after row r.  In LaTeX's array a positive length deepens the row
    # to at least the strut depth plus the length (\@xargarraycr); otherwise,
    # and in amsmath's smallmatrix and alignments, it is extra space below.
    # The length is in the environment's size (smallmatrix's entries are smaller).
    gaps = payload.row_gaps .* scale
    extra = zeros(Float64, nrow)
    for r in 1:nrow
        g = r <= length(gaps) ? gaps[r] : 0.0
        if spacing.rows === :touch && g > 0
            row_depths[r] = max(row_depths[r], spacing.strut * _ARRAY_STRUT_DEPTH * cell_scale + g)
        elseif r < nrow
            extra[r] = g
        end
    end

    # Provisional baseline y for each row (row 1 at y = 0).
    row_y = zeros(Float64, nrow)
    for r in 2:nrow
        clearance = row_depths[r - 1] + row_heights[r]
        step = if spacing.rows === :touch
            clearance   # LaTeX's array rows abut
        else
            # TeX's interline glue: baselines \baselineskip apart unless that
            # leaves less than \lineskiplimit between the rows, else \lineskip.
            baselineskip = spacing.baselineskip * scale
            baselineskip - clearance >= spacing.lineskiplimit * scale ? baselineskip :
                clearance + spacing.lineskip * scale
        end
        row_y[r] = row_y[r - 1] - step - extra[r - 1]
    end

    # Vertical extent of the provisional grid.
    grid_top = row_y[1] + row_heights[1]
    grid_bot = row_y[nrow] - row_depths[nrow]

    # Centre the grid on the math axis, or keep the first row on the baseline.
    axis_em = mc.axis_height / upm * scale
    y_shift = spacing.vcenter ? y0 + axis_em - (grid_top + grid_bot) / 2 : y0 - row_y[1]

    # In align/aligned the columns form right/left pairs glued together at the
    # alignment point (the `&`): no inter-column space is inserted within a pair,
    # so the spacing around a leading relation comes solely from the math-list
    # relation atom (see the empty-group insertion in the parser).  Successive
    # pairs are `gap` (\minalignsep) apart.
    tight_pairs = env_name ∈ ("align", "aligned", "split")
    outer = spacing.outer * scale
    gap = spacing.gap * scale
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
    # amsmath's `cases` template is @{}l@{\quad}l@{}: the \quad belongs to the
    # first column, so a one-column `cases` still ends with it.
    cases_quad = env_name == "cases" && ncol == 1 ? gap : 0.0
    content_w = x_col[ncol] + col_widths[ncol] + outer + rules_extra(vrule[ncol + 1]) + cases_quad

    # ── Delimiter sizing (if required) ──
    left_w = 0.0; right_w = 0.0
    if left !== nothing || right !== nothing || !isempty(left_name) || !isempty(right_name)
        actual_top = y_shift + grid_top - y0
        actual_bot = y_shift + grid_bot - y0
        h_above = max(0.0, actual_top - axis_em)
        h_below = max(0.0, axis_em - actual_bot)
        δ = max(h_above, h_below)
        # amsmath's delimiters are \left…\right around the array's box, which
        # rule 19 lets fall short of it (`_left_right_required_du`).
        required_du = _left_right_required_du(δ, scale, upm)
        left_w = _layout_delim!(ctx, left_name, required_du, x0, y0, scale, boxes)
        right_w = _layout_delim!(
            ctx, right_name, required_du,
            x0 + left_w + content_w, y0, scale, boxes
        )
    end

    # ── Second pass: move all cells to their row/column positions ──
    for r in 1:nrow, c in 1:ncol
        cell_index(r, c) == 0 && continue
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
    trailing = outer + rules_extra(vrule[ncol + 1]) + cases_quad
    if trailing > 0
        push!(boxes, LayoutBox(Space(trailing), x0 + left_w + content_w - trailing, y_shift + row_y[nrow], scale))
    end

    return (
        width = left_w + content_w + right_w,
        height = y_shift + grid_top - y0, depth = y0 - (y_shift + grid_bot),
    )
end
