# Matrix and array environment layout.

# Inter-column and inter-row spacing constants for matrix environments.
# _MATRIX_COLSEP is the margin added on each side of a column (total gap between
# adjacent cells = 2 × _MATRIX_COLSEP), matching LaTeX's \arraycolsep ≈ 5 mu.
# _MATRIX_ROWGAP is extra baseline-to-baseline clearance added between rows.
const _MATRIX_COLSEP = 5 / 18   # 5 mu per side, matches LaTeX \arraycolsep
const _MATRIX_ROWGAP = 3 / 18   # extra row gap in em
const _MATRIX_DOUBLERULESEP = 2 / 18   # gap between two adjacent rules (≈ TeX \doublerulesep = 2pt)

# Parse a column-spec string (e.g. "|l||c|r|") into per-column alignment symbols
# and a vertical-rule count vector.
# col_aligns[c] ∈ {:l, :c, :r} for each column c = 1..ncol.
# vrule[c] = number of rules immediately before column c (c=1..ncol),
# vrule[ncol+1] = number of rules after the last column.
# '||' → vrule count 2 (double rule with _MATRIX_DOUBLERULESEP gap).
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

# Lay out a matrix/array environment (NodeKind.Matrix node).
# Two-pass algorithm: measure all cells first, then place on a rectangular grid.
# Cells are laid out in Text style (even in Display), centred on the math axis.
# Returns the total horizontal advance in em units.
function _layout_matrix!(
        node::Node,
        ctx::_LayoutCtx,
        style::TexStyle,
        x0::Float64,
        y0::Float64,
        scale::Float64,
        boxes::Vector{LayoutBox},
    )::Float64
    payload = _decode_matrix_payload(node.value)
    env_name = payload.env_name
    nrow = payload.nrow
    col_aligns, vrule = _parse_colspec(payload.colspec)
    ncol = length(col_aligns)
    (nrow == 0 || ncol == 0) && return 0.0

    info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
    upm = ctx.upm
    mc = ctx.mc

    # Cells are typeset in Text style (following TeX's rule for array environments).
    cell_style = is_cramped(style) ? CrampedText : Text

    # Scale factor for this environment (smallmatrix uses 0.9).
    cell_scale = scale * info.scale

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
    for r in 2:nrow
        row_y[r] = row_y[r - 1] - (row_depths[r - 1] + _MATRIX_ROWGAP * cell_scale + row_heights[r])
    end

    # Vertical extent of the provisional grid.
    grid_top = row_y[1] + row_heights[1]
    grid_bot = row_y[nrow] - row_depths[nrow]

    # Centre grid on the math axis.
    axis_em = mc.axis_height / upm * scale
    y_shift = y0 + axis_em - (grid_top + grid_bot) / 2

    # Column left-edge positions (relative to content origin, before adding left delimiter).
    # Vertical rules occupy space within the column separations.
    vrule_thick = mc.fraction_rule_thickness / upm * cell_scale
    x_col = zeros(Float64, ncol)
    x_col[1] = _MATRIX_COLSEP * cell_scale
    for c in 2:ncol
        x_col[c] = x_col[c - 1] + col_widths[c - 1] + 2 * _MATRIX_COLSEP * cell_scale
    end
    content_w = x_col[ncol] + col_widths[ncol] + _MATRIX_COLSEP * cell_scale

    # ── Delimiter sizing (if required) ──
    left_w = 0.0; right_w = 0.0
    if !isempty(info.left) || !isempty(info.right)
        actual_top = y_shift + grid_top - y0
        actual_bot = y_shift + grid_bot - y0
        h_above = max(0.0, actual_top - axis_em)
        h_below = max(0.0, axis_em - actual_bot)
        required_em = 2.0 * max(h_above, h_below)
        required_du = required_em / scale * upm
        left_w = _layout_delim!(ctx, info.left, required_du, x0, y0, scale, boxes)
        right_w = _layout_delim!(
            ctx, info.right, required_du,
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
    vrule_bot = y_shift + grid_bot
    vrule_height = grid_top - grid_bot
    # Base x positions of rule groups within the content area (relative to x0+left_w).
    # vrule[1]: before col 1; vrule[c+1]: between col c and c+1; vrule[ncol+1]: after last.
    # Multiple rules per slot (vrule[i] > 1) are emitted with _MATRIX_DOUBLERULESEP gaps.
    rule_sep = (vrule_thick + _MATRIX_DOUBLERULESEP * cell_scale)
    function emit_vrules!(base_x::Float64, n::Int)
        n == 0 && return
        # Centre the rule group around base_x.
        group_w = n * vrule_thick + (n - 1) * _MATRIX_DOUBLERULESEP * cell_scale
        x_start = base_x - group_w / 2
        for k in 0:(n - 1)
            push!(
                boxes, LayoutBox(
                    VRule(vrule_height, vrule_thick),
                    x0 + left_w + x_start + k * rule_sep, vrule_bot, scale
                )
            )
        end
        return
    end
    emit_vrules!(0.0, vrule[1])
    for c in 1:(ncol - 1)
        emit_vrules!(x_col[c] + col_widths[c] + _MATRIX_COLSEP * cell_scale, vrule[c + 1])
    end
    emit_vrules!(content_w, vrule[ncol + 1])

    return left_w + content_w + right_w
end
