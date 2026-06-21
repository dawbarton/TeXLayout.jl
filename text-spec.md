# Implementation spec: text + multi-line + embedded math layout

Status: **ready to implement** on branch `latex-text`.
Audience: an implementing agent with no other context than this file, `CLAUDE.md`,
and the existing source tree.

This spec adds a **text/paragraph layer** on top of the existing math engine so
that strings mixing styled text, explicit line breaks (`\\`), inline math
(`$…$`), and display-math environments (`align`, …) can be laid out.  It follows
the "wrapper layer" approach (Option 1).  The long-term target (a unified box IR,
Option 2) is documented in `future.md`; **read its "Why this subsumes the Option 1
work" section** — the data structures below are chosen to migrate into it
cleanly, so do not deviate from the `TeXBox` / `vstack` / `hconcat` shapes.

## Scope

In scope:
- Top-level **text mode** (significant spaces, literal characters).
- Styled text via `\textrm \textbf \textit \texttt \textsf \textnormal \emph`
  and `\text{…}`, with nesting (`\textbf{\textit{x}}` → bold-italic).
- Explicit line breaks with `\\` at top level.
- Inline math `$…$` embedded in a text line.
- Display-math blocks: `\begin{align}…\end{align}` (and `aligned`, `gather`,
  `equation`) appearing at top level **without** `$` delimiters.
- Per-block horizontal alignment: `:left` (default), `:right`, `:center`.
- Configurable line height (LaTeX `\baselineskip` semantics, see below).
- Optional fixed block width; otherwise width = widest line.
- A pluggable **text shaper** interface so a future HarfBuzz extension can provide
  kerning/ligatures without any core change.

Out of scope (do **not** implement):
- Automatic line breaking, full justification (inter-word glue stretching).
- Paragraph-fill, hyphenation, page/column breaking.
- Microtypography.

## The worked example

Input (as a Julia string literal the test will use):

```julia
"\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"
```

i.e. the LaTeX source `\textbf{Hello} world\\\begin{align}x&=y\\y&=x^2-z\end{align}`.

Expected document structure after parsing:

```
Document = [
  ParagraphBlock(lines = [
    Line(runs = [ TextRun(spans = [ TextSpan("Hello", bold), TextSpan(" world", regular) ]) ])
  ]),
  DisplayBlock(node = NKMatrix("align\x002\x00rl"), kind = :align)
]
```

(The `\\` after `world` ends the text line; the immediately following
`\begin{align}` ends the paragraph and starts a display block. The blank trailing
text line produced by the `\\` is dropped — see "Lenience rules".)

Expected rendering: line 1 "**Hello** world" with its baseline at `y = 0`; below
it, the two-row aligned equation `x = y` / `y = x² − z` aligned on the `=`, the
whole equation block centred (display default), with baseline-to-baseline spacing
governed by the line-height rule.

## Conventions (must hold throughout)

- **Units:** em (design units / UPM × scale), identical to the existing engine.
- **Coordinate frame:** `x` right, `y` up.
- **y-origin of the composed result is the baseline of the first line.** Lines
  below it have negative baseline `y`. The returned `TeXBox` reports
  `ascent` = first line's ascent and `descent` = distance from the first baseline
  down to the bottom of the last line.
- **Output contract is unchanged:** the final product is a
  `Vector{LayoutBox}` (inside a `TeXBox`) in a single coordinate system. The
  renderer and `ext/MathTeXEngineExt.jl` need no changes to consume
  `layout_document(…).boxes`.

## New / modified files

```
src/shaping.jl    NEW  — TextShaper interface, MetricShaper, font-slot glyph lookup
src/document.jl   NEW  — Document AST (Block/Line/Run/TextSpan/TextAttrs) + parse_document
src/compose.jl    NEW  — TeXBox, measurement, hconcat, vstack, LayoutOptions, layout_document
src/fonts.jl      MOD  — add glyph_metrics_slot, _font_upm
src/parser.jl     MOD  — display-env table entries, brace-word leniency, inline-math entry,
                          align colspec derivation, a public parse_environment! entry
src/TeXLayout.jl  MOD  — include order + exports
ext/HarfBuzzExt.jl  (documented here, NOT implemented in v1)
CHANGELOG.md      MOD  — [Unreleased]/Added
notes.md          MOD  — session note
docs              optional follow-up
```

`include` order in `src/TeXLayout.jl` (append after `layout.jl`):
```julia
include("shaping.jl")
include("document.jl")
include("compose.jl")
```
(`compose.jl` uses `layout`, `_boxes_top`, `_boxes_bottom` from `layout.jl`;
`document.jl` uses the parser; `shaping.jl` uses `fonts.jl`.)

New exports: `layout_document`, `TeXBox`, `LayoutOptions`, `TextShaper`,
`MetricShaper`. (Block/Line/Run types stay internal — accessible as
`TeXLayout.Xxx` but not exported.)

---

## 1. Data structures

### 1.1 Document AST (`src/document.jl`)

```julia
"""Font attributes for a run of text. `size` is an em multiplier (1.0 = body)."""
struct TextAttrs
    slot::Symbol     # :regular | :bold | :italic | :bolditalic
    size::Float64
end
TextAttrs() = TextAttrs(:regular, 1.0)

"""A maximal run of characters sharing one set of TextAttrs."""
struct TextSpan
    text::String
    attrs::TextAttrs
end

abstract type Run end

"""Contiguous text on a line. Held as spans (not pre-decomposed glyphs) so a
shaper can apply kerning/ligatures per span. Spans are positioned end-to-end."""
struct TextRun <: Run
    spans::Vector{TextSpan}
end

"""Inline math (`\$…\$`). Laid out by the existing math engine at `style`."""
struct MathRun <: Run
    node::Node
    style::TexStyle   # always Text for inline `$…$`
end

"""One typeset line: a horizontal sequence of runs sharing a baseline."""
struct Line
    runs::Vector{Run}
end

abstract type Block end

"""A run of text lines (split on top-level `\\`)."""
struct ParagraphBlock <: Block
    lines::Vector{Line}
end

"""A display-math environment occupying its own vertical space."""
struct DisplayBlock <: Block
    node::Node       # an NKMatrix (align/aligned/gather) or a plain NKSequence (equation)
    kind::Symbol     # :align | :aligned | :gather | :equation
end

const Document = Vector{Block}
```

**Rationale (do not change):** text is kept as `TextSpan`s carrying the source
string, not as `NKChar` nodes. This is the single most important data-structure
decision for the HarfBuzz future: a shaper must see whole strings to form
ligatures and apply kerning. Math stays as `Node` (reusing the entire existing
grammar). Block structure lives in its own hierarchy and never pollutes the
`NodeKind` enum.

### 1.2 Measured box (`src/compose.jl`)

```julia
"""A measured, already-positioned horizontal/vertical layout fragment.

`boxes` are positioned relative to THIS box's own origin: baseline at y = 0,
left edge at x = 0. `ascent`/`descent` are ≥ 0 extents above/below the baseline;
`width` is the advance. This is the degenerate, eagerly-shaped form of the
Option-2 `Box` (see future.md)."""
struct TeXBox
    boxes::Vector{LayoutBox}
    width::Float64
    ascent::Float64
    descent::Float64
end
```

### 1.3 Layout options (`src/compose.jl`)

```julia
struct LayoutOptions
    align::Symbol            # text lines: :left (default) | :right | :center
    line_height::Float64     # \baselineskip in em (default 1.2)
    lineskip::Float64        # min baseline clearance in em (default 0.1)
    width::Union{Nothing, Float64}   # nothing ⇒ widest line; else fixed em width
    display_align::Symbol    # display blocks: :center (default) | :left | :right
    abovedisplayskip::Float64  # extra em above a display block (default 0.5)
    belowdisplayskip::Float64  # extra em below a display block (default 0.5)
    shaper::TextShaper       # default MetricShaper()
end

function LayoutOptions(;
        align = :left, line_height = 1.2, lineskip = 0.1, width = nothing,
        display_align = :center, abovedisplayskip = 0.5, belowdisplayskip = 0.5,
        shaper = MetricShaper())
    return LayoutOptions(align, line_height, lineskip, width,
        display_align, abovedisplayskip, belowdisplayskip, shaper)
end
```

---

## 2. Text shaping (`src/shaping.jl`)

The shaper is the seam that keeps HarfBuzz out of core. Core ships a metrics-only
shaper; an extension may register a better one and the caller selects it via
`LayoutOptions.shaper`.

```julia
abstract type TextShaper end

"""Shape one uniform-attribute span into a measured TeXBox.

Contract (MUST be honoured by every shaper, including the HarfBuzz extension):
  • returned boxes are in em units, baseline at y = 0, first glyph origin at x = 0;
  • each emitted Glyph carries the font's PostScript glyph_name and the resolved
    text font slot (`:regular`, `:bold`, `:italic`, or `:bolditalic`);
  • width = total advance, ascent/descent = max ink extents (≥ 0);
  • missing glyphs are skipped (advance still applied if known, else 0)."""
function shape_span end

struct MetricShaper <: TextShaper end
```

`shape_span(::MetricShaper, span, family, base_scale)::TeXBox` algorithm:

1. Resolve the font path and per-glyph metrics for each character via
   `glyph_metrics_slot(family, ch, span.attrs.slot)` (see §5). Get the font's UPM
   with `_font_upm(font_path)`.
2. `scale = base_scale * span.attrs.size`.
3. Walk characters left→right; maintain `cursor = 0.0`. For each `ch`:
   - `(m, font_path) = glyph_metrics_slot(...)`; if `nothing`, `cursor += 0`;
     continue.
   - `ps = glyph_name_by_codepoint(font_path, UInt32(ch))`; fall back to
     `string(ch)` if empty.
   - Push `LayoutBox(Glyph(ps, :regular, m.advance_width, m.left_side_bearing,
     m.x_min, m.y_min, m.x_max, m.y_max), cursor, 0.0, scale)`.
   - `cursor += m.advance_width / upm * scale`.
   - Track `ascent = max(ascent, m.y_max/upm*scale)`,
     `descent = max(descent, -m.y_min/upm*scale)`.
4. Return `TeXBox(boxes, cursor, ascent, descent)`.

`shape_span` for a whole `TextRun` = shape each span and `hconcat` (§6) the
results.

> No `_MATH_CHAR_REMAP` in text mode (hyphen stays hyphen, etc.) — this matches
> the existing `:text` mode behaviour.

### HarfBuzz extension (`ext/HarfBuzzExt.jl`) — documented, NOT built in v1

- Triggered by loading e.g. `HarfBuzz_jll` (declare under `[weakdeps]` /
  `[extensions]` in `Project.toml` when implemented).
- Defines `struct HarfBuzzShaper <: TextShaper` and
  `TeXLayout.shape_span(::HarfBuzzShaper, span, family, base_scale)`.
- It buffers the span text, runs HarfBuzz with the slot's font face, then maps
  each output cluster's GID→PS name via FreeType `FT_Get_Glyph_Name`, emitting the
  same `LayoutBox`/`Glyph(:regular)` form so the renderer is unchanged.
- Users opt in with `layout_document(s; shaper = HarfBuzzShaper())`.

**v1 constraint that keeps this open:** `Glyph` is identified by PS name. Do not
introduce GID-only glyphs in v1. If a font ever lacks a `post` name table, a
later enhancement may add an optional `gid::Int` field to `Glyph`; flag it as a
known limitation but do not implement it now.

---

## 3. Parser modifications (`src/parser.jl`)

### 3.1 Brace-word leniency

In `_read_brace_word!` (and at the `\begin` / `\end` call sites), **skip leading
`TKSpace`** before the `{`. The example contains `\end {align}`.

```julia
function _read_brace_word!(p::_Parser)::String
    while _current(p).kind === TKSpace; _advance!(p); end   # NEW
    _current(p).kind === TKLBrace && _advance!(p)
    # … unchanged …
end
```

### 3.2 Display / alignment environments

Add to `_MATRIX_ENVS`:
```julia
"align"    => (left = "", right = "", align = :center, scale = 1.0),
"aligned"  => (left = "", right = "", align = :center, scale = 1.0),
"gather"   => (left = "", right = "", align = :center, scale = 1.0),
```
(`equation` is handled as a plain sequence, see §3.4.)

`align`/`aligned` need alternating right/left columns. In `_parse_matrix_body!`,
where the colspec is derived for shorthand environments, special-case these:
```julia
if isempty(colspec)
    if env_name in ("align", "aligned")
        # alternating r,l pairs across the observed column count
        colspec = String(collect(Iterators.take(Iterators.cycle("rl"), ncol)))
    elseif env_name == "gather"
        colspec = repeat("c", ncol)
    else
        info = get(_MATRIX_ENVS, env_name, _MATRIX_ENVS["matrix"])
        align_ch = info.align === :left ? 'l' : 'c'
        colspec = repeat(align_ch, ncol)
    end
end
```

> **Spacing approximation (intended for v1):** `align` reuses the matrix column
> machinery, so the `&` gap uses `_MATRIX_COLSEP` rather than true relation
> spacing. This renders `x =y` with a small column gap instead of TeX's
> `x = y` relation spacing. Accept this for v1 and record it under "Known
> limitations" in `CLAUDE.md`. A later refinement can give `align` its own layout
> that classifies the post-`&` cell's leading atom as a relation.

### 3.3 A public environment entry for the document parser

Expose a function the document parser calls when it has consumed `\begin` and the
environment name:

```julia
# Parse the body of a known environment, returning its Node. `p` is positioned
# just after `{env_name}` (and after its colspec arg, if any). Mirrors the
# `\begin` branch of _parse_command!.
function parse_environment!(p::_Parser, env_name::String)::Node
    if haskey(_MATRIX_ENVS, env_name)
        colspec = env_name in _COLSPEC_ENVS ? _read_brace_word!(p) : ""
        return _parse_matrix_body!(p, env_name, colspec)
    else
        # consume to matching \end{env} leniently, return empty sequence
        _skip_to_end_env!(p, env_name)
        return Node(NKSequence, Node[])
    end
end
```
(`_skip_to_end_env!` advances until `\end` + brace word, discarding tokens.)

### 3.4 Inline-math and equation sequence entry

Add a sequence parser that stops at `$`:

```julia
# Parse math atoms until TKMathShift or TKEOF. Does NOT consume the closing `$`.
function _parse_math_until_shift!(p::_Parser)::Node
    children = Node[]
    while true
        k = _current(p).kind
        (k === TKEOF || k === TKMathShift) && break
        k === TKSpace && (_advance!(p); continue)
        push!(children, _parse_atom!(p))
    end
    return Node(NKSequence, children)
end
```

For `\begin{equation}…\end{equation}`: parse the body as math until
`\end` using a helper analogous to `_parse_math_until_shift!` but stopping at
`\end` (reuse `_parse_sequence_children!`-style loop with an added `\end` break),
returning an `NKSequence`. The document layer wraps it in
`DisplayBlock(node, :equation)`.

These math entries reuse the existing recursive-descent functions unchanged.

---

## 4. Document parser (`src/document.jl`)

`parse_document(input::AbstractString)::Document` lexes once
(`tokenize`) and drives an `_Parser` (`TeXLayout._Parser`, reused), starting in
**text mode**.

### 4.1 Builder state

```julia
mutable struct _DocBuilder
    blocks::Vector{Block}
    cur_lines::Vector{Line}
    cur_runs::Vector{Run}
    cur_spans::Vector{TextSpan}
    buf::IOBuffer            # current span text
    attrs::TextAttrs
end
```

Flush helpers (call in this nesting order):
- `flush_span!`: if `buf` non-empty → push `TextSpan(text, attrs)` to `cur_spans`; reset `buf`.
- `flush_text_run!`: `flush_span!`; if `cur_spans` non-empty → push `TextRun(copy)` to `cur_runs`; clear.
- `end_line!`: `flush_text_run!`; push `Line(cur_runs)`; clear `cur_runs`.
- `end_paragraph!`: `end_line!`; if `cur_lines` has any **non-empty** line → push `ParagraphBlock`; clear.

### 4.2 Token dispatch (text mode)

Loop over tokens via the shared `_Parser`. For each `_current(p)`:

| Token | Action |
|-------|--------|
| `TKChar` | append `tok.value` to `buf`; advance |
| `TKSpace` | append `" "` to `buf`; advance (significant in text) |
| `TKMathShift` (`$`) | advance; `flush_text_run!`; `node = _parse_math_until_shift!(p)`; consume closing `$` if present; push `MathRun(node, Text)` to `cur_runs` |
| `TKCommand "\\\\"` (two backslashes) | advance; `end_line!` (start a new line in the current paragraph) |
| `TKCommand "\\begin"` | advance; `name = _read_brace_word!(p)`; **if display env** (`name ∈ _DISPLAY_ENVS`): `end_paragraph!`; `node = parse_environment!(p, name)`; push `DisplayBlock(node, Symbol(name))`. **else** treat as inline/unknown: `parse_environment!` and ignore, or for matrix envs wrap as a `MathRun` (see note) |
| text font-switch command | handle per §4.3 |
| `TKCommand "\\text"`/`"\\mbox"` | parse braced group as text (§4.3) with current attrs |
| other `TKCommand` | v1: a small text-symbol table (optional) or **ignore** leniently; advance |
| `TKLBrace` | advance; push current attrs on a local stack; (plain grouping in text just scopes font switches) |
| `TKRBrace` | advance; `flush_span!`; pop attrs |
| `TKEOF` | `end_paragraph!`; break |

`_DISPLAY_ENVS = Set(["align", "aligned", "gather", "equation"])`.

> Note: a bare matrix env (e.g. `pmatrix`) at text top level is unusual. v1 may
> treat any non-display `\begin` as: parse via `parse_environment!` and emit a
> `MathRun(node, Text)` on the current line. This is a minor path; correctness for
> the in-scope display envs is what matters.

### 4.3 Text font switches

Commands and their attr effect (computed from a small running state of
`bold`, `italic`, `family`):

| Command | Effect |
|---------|--------|
| `\textrm`, `\textnormal` | reset family to roman; (textnormal also clears bold/italic) |
| `\textbf` | `bold = true` |
| `\textit` | `italic = true` |
| `\emph` | toggle `italic` |
| `\textsf` | family sans (v1: maps to :regular slot — note as limitation) |
| `\texttt` | family mono (v1: maps to :regular slot — note as limitation) |
| `\text`, `\mbox` | no attr change; just a text group |

Slot resolution from `(bold, italic)`:
`bold & italic → :bolditalic`, `bold → :bold`, `italic → :italic`, else `:regular`.

Each switch command is followed by a braced group. Implement a recursive
`_parse_text_group!(p, builder, attrs)`:
- `flush_span!` (so the preceding span closes under the old attrs);
- save `builder.attrs`; set `builder.attrs = attrs_with_switch_applied`;
- `_advance!` past `{`; loop the **same text-mode dispatch** (§4.2) until the
  matching `TKRBrace` (track brace depth), so nested switches and inline `$…$`
  inside `\textbf{…}` work;
- on the matching `}`: `flush_span!`; restore `builder.attrs`.

This keeps each `TextSpan` uniform-attr while leaving adjacent spans in the same
`TextRun` (so the shaper still sees a contiguous run).

---

## 5. Font modifications (`src/fonts.jl`)

```julia
"""Return (GlyphMetrics, font_path) for `ch` in the requested style slot, or
nothing. Falls back: requested slot → regular → math. `font_path` is the file the
metrics came from, so callers can resolve the matching PS name with
glyph_name_by_codepoint(font_path, cp)."""
function glyph_metrics_slot(family::FontFamily, ch::Char, slot::Symbol)
    paths = _slot_fallback(family, slot)        # Vector{String}, in priority order
    for path in paths
        m = _codepoint_metrics(path, UInt32(ch))   # factor out of glyph_metrics_by_codepoint
        m !== nothing && return (m, path)
    end
    return nothing
end
```

- `_slot_fallback(family, slot)` returns the non-`nothing` paths for the slot then
  `family.regular` then `family.math`, de-duplicated:
  - `:regular` → `[regular, math]`
  - `:bold` → `[bold, regular, math]`
  - `:italic` → `[italic, regular, math]`
  - `:bolditalic` → `[bolditalic, bold, italic, regular, math]`
- `_codepoint_metrics(path, cp)` is the body of the existing
  `glyph_metrics_by_codepoint` generalised to an arbitrary font path (refactor:
  have `glyph_metrics_by_codepoint(family, cp)` call
  `_codepoint_metrics(family.math, cp)`).

```julia
"""Units-per-em of the font at `path` (cached via _load_font)."""
function _font_upm(path::String)::Float64
    face, _ = _load_font(path)
    return Float64(face.units_per_EM)
end
```
(If `face.units_per_EM` is not directly available from `FreeTypeAbstraction`,
read `head.unitsPerEm` with the existing raw-table helpers in `math_table.jl`.)

---

## 6. Composition (`src/compose.jl`)

### 6.1 Measuring a math layout into a TeXBox

```julia
# Advance (em) contributed by one element, for width measurement.
_advance_em(b::LayoutBox, upm::Float64) =
    b.element isa Glyph ? b.element.advance_width / upm * b.scale :
    b.element isa Space ? b.element.width :
    b.element isa HRule ? b.element.width :
    0.0

function measure(boxes::Vector{LayoutBox}, upm::Float64)::TeXBox
    width = 0.0
    for b in boxes
        width = max(width, b.x + _advance_em(b, upm))
    end
    asc  = _boxes_top(boxes, upm)      # reuse from layout.jl
    desc = -_boxes_bottom(boxes, upm)  # _boxes_bottom ≤ 0
    return TeXBox(boxes, width, max(asc, 0.0), max(desc, 0.0))
end
```

`hlayout_math(node, family, style)::TeXBox`:
`boxes = layout(node, family, style); upm = load_math_table(family.math).upm;`
`return measure(boxes, upm)`.

`hlayout_run(run::Run, family, opts, base_scale)::TeXBox`:
- `TextRun` → `hconcat(shape_span(opts.shaper, span, family, base_scale) for span in run.spans)`.
- `MathRun` → `hlayout_math(run.node, family, run.style)`.

### 6.2 hconcat (horizontal mode)

```julia
function hconcat(parts::Vector{TeXBox})::TeXBox
    isempty(parts) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)
    out = LayoutBox[]; cursor = 0.0; asc = 0.0; desc = 0.0
    for p in parts
        _emit_shifted!(out, p.boxes, cursor, 0.0)   # reuse from layout.jl
        cursor += p.width
        asc = max(asc, p.ascent); desc = max(desc, p.descent)
    end
    return TeXBox(out, cursor, asc, desc)
end
```

### 6.3 vstack (vertical mode) — the line-height rule

Implements LaTeX `\baselineskip` / `\lineskip`:
**baseline-to-baseline advance = `max(line_height, prevdepth + ascent(next) + lineskip)`.**

```julia
# items: vertical items top→bottom. align_of(i): per-item horizontal alignment.
function vstack(items::Vector{TeXBox};
        line_height::Float64, lineskip::Float64,
        width::Union{Nothing,Float64}, align_of)::TeXBox
    isempty(items) && return TeXBox(LayoutBox[], 0.0, 0.0, 0.0)
    W = width === nothing ? maximum(it.width for it in items) : width
    out = LayoutBox[]
    y = 0.0                       # first baseline at y = 0
    _place!(out, items[1], dx_for(align_of(1), W, items[1].width), 0.0)
    prevdepth = items[1].descent
    last_y = 0.0
    for i in 2:length(items)
        it = items[i]
        adv = max(line_height, prevdepth + it.ascent + lineskip)
        y  -= adv                 # downward ⇒ negative
        _place!(out, it, dx_for(align_of(i), W, it.width), y)
        prevdepth = it.descent
        last_y = y
    end
    ascent  = items[1].ascent
    descent = -last_y + items[end].descent
    return TeXBox(out, W, ascent, descent)
end

dx_for(a, W, w) = a === :right ? (W - w) : a === :center ? (W - w)/2 : 0.0
_place!(out, box, dx, dy) = _emit_shifted!(out, box.boxes, dx, dy)
```

### 6.4 Top-level driver

```julia
"""
    layout_document(input; family=default_font_family(), kwargs...) -> TeXBox

Lay out a mixed text/math string with line breaks and display blocks.
Keyword args populate LayoutOptions (align, line_height, lineskip, width,
display_align, abovedisplayskip, belowdisplayskip, shaper).

The result's coordinate frame has the FIRST line's baseline at y = 0; later
lines have negative baseline y. `result.boxes` is a flat Vector{LayoutBox}
ready for the existing renderer / Makie extension.
"""
function layout_document(input::AbstractString;
        family::FontFamily = default_font_family(), kwargs...)::TeXBox
    opts = LayoutOptions(; kwargs...)
    doc  = parse_document(input)
    base_scale = size_scale(Text, load_math_table(family.math).constants)

    items = TeXBox[]          # vertical items, top→bottom
    aligns = Symbol[]         # per-item alignment
    for blk in doc
        if blk isa ParagraphBlock
            for line in blk.lines
                push!(items, _layout_line(line, family, opts, base_scale))
                push!(aligns, opts.align)
            end
        else  # DisplayBlock
            # optional spacing above
            opts.abovedisplayskip > 0 && (push!(items, _vskip(opts.abovedisplayskip)); push!(aligns, :left))
            push!(items, hlayout_math(blk.node, family, Display))
            push!(aligns, opts.display_align)
            opts.belowdisplayskip > 0 && (push!(items, _vskip(opts.belowdisplayskip)); push!(aligns, :left))
        end
    end
    return vstack(items;
        line_height = opts.line_height, lineskip = opts.lineskip,
        width = opts.width, align_of = i -> aligns[i])
end

_layout_line(line, family, opts, base_scale) =
    hconcat([hlayout_run(r, family, opts, base_scale) for r in line.runs])
```

`_vskip(h)` returns an empty `TeXBox(LayoutBox[], 0.0, h, 0.0)` so it consumes
vertical space via the ascent term of the next advance. (Simpler alternative:
fold `abovedisplayskip` directly into the advance; either is acceptable as long as
the gap appears. Pick the empty-strut form for clarity.)

Inline math uses `Text` style (`MathRun.style = Text`); display blocks use
`Display`. Body text base scale = `size_scale(Text, …)` so text and inline math
share a size.

---

## 7. Lenience rules (mirror the parser's "never throw" invariant)

- Unclosed `$`: `_parse_math_until_shift!` stops at EOF; emit the partial MathRun.
- Unclosed `\begin{…}`: matrix/equation body parsing already stops at EOF.
- Trailing `\\` producing an empty final line: dropped by `end_paragraph!`
  (only non-empty lines are kept). An empty line *between* content is also
  dropped in v1 (no blank-line vertical space); record as a limitation.
- Unknown text command: ignored (no glyph), parser advances past it.
- Missing glyph in a slot: skipped per the shaper contract.
- Empty document: `layout_document` returns an empty `TeXBox`.

---

## 8. Public API summary

```julia
layout_document(input; family, align, line_height, lineskip, width,
                display_align, abovedisplayskip, belowdisplayskip, shaper) -> TeXBox
```
Exported: `layout_document`, `TeXBox`, `LayoutOptions`, `TextShaper`, `MetricShaper`.
Unchanged & still exported: `parse_latex`, `layout`, `generate_tex_elements`,
font and style API. **No breaking changes.**

---

## 9. Testing plan

Add `test/test_text.jl`; include it from `test/runtests.jl`. Fixture font is
`NewCMMath-Regular.otf` (it has upright letters via codepoint; for a real
`bold` slot in tests, configure a `FontFamily` with a bold text font if one is
bundled — otherwise assert on the `:bold` slot's *fallback* to regular/math and
test slot resolution separately).

Cases:
1. **Plain text line.** `layout_document("abc")` → one line, baseline at y=0,
   `ascent>0`, `descent≥0`, boxes are `:regular` glyphs, widths monotonic.
2. **Line break.** `"a\\\\b"` → two items; second baseline `y ≈ -line_height`
   (since both lines short, advance = line_height). Assert the second line's
   glyph `y` ≈ `-line_height`.
3. **Tall line forces lineskip.** A line containing a big fraction followed by a
   normal line: assert the advance equals `prevdepth + ascent + lineskip`, not
   `line_height` (i.e. `> line_height`).
4. **Alignment.** Same content, `align=:right` vs `:left`: right-aligned short
   line's first glyph `x` equals `W - width(line)`.
5. **Fixed width.** `width=10.0` with `align=:right`: offsets computed against 10.
6. **Inline math.** `"x is \$x^2\$ here"` → a `MathRun` between text; the math
   superscript present; baseline continuous (all on y of that line).
7. **Font switch nesting.** `"\\textbf{a\\textit{b}}"` → spans
   `[("a",:bold), ("b",:bolditalic)]`. Assert parse_document structure directly.
8. **The worked example** (§"The worked example"): assert the Document structure
   (2 blocks; paragraph with one line of one TextRun with the two expected spans;
   DisplayBlock kind `:align` with an `NKMatrix` node whose colspec is `"rl"`),
   and that `layout_document(...)` returns a non-empty `TeXBox` with the align
   rows below the text line.
9. **y-origin.** First line's glyph `y` values are ≈ 0 (on baseline); confirm the
   first baseline is the origin.
10. **Lenience.** Unclosed `$`, trailing `\\`, unknown `\foo` in text — no throw,
    structurally valid output.

Also add a unit test for `glyph_metrics_slot` fallback order and `_font_upm`.

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`.

## 10. Tooling (optional but recommended)

Add a small visualiser path so the result can be eyeballed: extend
`tools/visualise_bitmap.jl` (or add `tools/visualise_text.jl`) to call
`layout_document` and rasterise the resulting `TeXBox.boxes` with the existing
FreeType renderer. Not required for correctness; helpful for review.

## 11. Housekeeping (required)

- **Runic-format** every touched/new `.jl` file (`runic` from repo root).
- **`CHANGELOG.md`** → `[Unreleased]`/`Added`: text + multi-line + inline/display
  math layout via `layout_document`, with pluggable text shaper.
- **`CLAUDE.md`** → File-structure table: add `shaping.jl`, `document.jl`,
  `compose.jl`. Add to "Known limitations / future work": align column-spacing
  approximation; `\textsf`/`\texttt` mapped to regular; blank-line paragraph
  breaks not yet honoured; HarfBuzz shaper not yet implemented (extension seam in
  place). Point the "future work" toward `future.md` / `text-spec.md`.
- **`notes.md`** → session note (`## <ISO datetime via `date -Iminutes`> …`)
  summarising the text-layer design and what was implemented.
- **`future.md`** is already written; keep it consistent if the API drifts.

## 12. Implementation order (suggested)

1. `fonts.jl`: `glyph_metrics_slot`, `_font_upm`, refactor `_codepoint_metrics`.
2. `shaping.jl`: `TextShaper`, `MetricShaper`, `shape_span`.
3. `parser.jl`: brace leniency, display-env table, align colspec,
   `parse_environment!`, `_parse_math_until_shift!`.
4. `document.jl`: AST types + `parse_document`. Unit-test parsing of the worked
   example before touching layout.
5. `compose.jl`: `TeXBox`, `measure`, `hconcat`, `vstack`, `LayoutOptions`,
   `layout_document`.
6. Wire `TeXLayout.jl` includes/exports.
7. `test/test_text.jl`; iterate to green.
8. Housekeeping (§11).
