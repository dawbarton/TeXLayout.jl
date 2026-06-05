# Future direction: a unified box-and-glue layout IR

This file records the **long-term** architectural target for TeXLayout's layout
engine.  It is *not* the plan for the current iteration — the text/paragraph work
landing on the `latex-text` branch follows the pragmatic wrapper approach
described in `text-spec.md` ("Option 1").  This document describes where that
wrapper is expected to evolve to ("Option 2"), so that the Option 1 data
structures are chosen to migrate cleanly rather than to be thrown away.

## Motivation

The layout engine today (`src/layout.jl`) walks the `Node` AST and pushes
`LayoutBox` values directly into a flat `Vector{LayoutBox}`, threading a single
`(x0, y0, scale)` cursor and returning only an *advance width*.  Vertical
construction (fractions, limits, radicals, matrix rows, accents) is done with
ad-hoc scratch vectors that are measured with `_boxes_top` / `_boxes_bottom` and
spliced back in with `_emit_shifted!`.  Every vertical construct re-implements
the same "measure a sub-layout, decide an offset, shift it in" dance by hand.

This works, but it has three structural costs:

1. **Dimensions are derived, not carried.** A laid-out sub-expression has no
   intrinsic width/ascent/descent; callers re-scan its boxes every time they need
   them.  Text/paragraph stacking (`text-spec.md`) has to bolt a measured
   `TeXBox` wrapper on top precisely because the engine throws this information
   away.
2. **Composition is bespoke per construct.** There is no shared vocabulary for
   "stack these on a baseline" or "stack these vertically with this gap".  Each
   `_layout_*!` open-codes it.
3. **No separation between arranging and emitting.** Position assignment and
   element emission are fused, so there is no point at which a whole sub-tree
   exists as a movable, measurable object before it is committed to absolute
   coordinates.

## Target model

Introduce an explicit intermediate representation — a **box tree** — between the
`Node` AST and the flat `Vector{LayoutBox}` the renderer consumes:

```
String → tokenize → parse → Node → build → Box tree → shape → Vector{LayoutBox}
```

The box tree is TeX's hbox/vbox (box-and-glue) model.  Every box carries its own
measured dimensions; container boxes carry a composition policy; a final `shape`
pass assigns absolute coordinates and flattens to the existing output type.

### Box types

```julia
abstract type Box end

# Leaves
struct GlyphBox <: Box     # one positioned glyph
    glyph::Glyph           # reuse existing element type
    width::Float64; ascent::Float64; descent::Float64
end
struct RuleBox <: Box      # horizontal/vertical rule (fraction bar, radical, …)
    width::Float64; ascent::Float64; descent::Float64
    thickness::Float64
end
struct Glue <: Box         # stretchable/shrinkable space (v1: natural size only)
    natural::Float64
    stretch::Float64       # 0.0 until justification is implemented
    shrink::Float64
end
struct Kern <: Box         # rigid space (inter-atom spacing, italic correction)
    amount::Float64
end

# Containers
struct HBox <: Box         # children share a baseline; laid left→right
    children::Vector{Box}
    width::Float64; ascent::Float64; descent::Float64
end
struct VBox <: Box         # children stacked top→bottom on successive baselines
    children::Vector{Box}
    offsets::Vector{Float64}   # baseline y of each child relative to VBox origin
    align::Symbol              # :left | :right | :center
    width::Float64; ascent::Float64; descent::Float64
end
```

All dimensions are in em units (design units / UPM × scale), matching the current
convention.  `ascent` is the extent above the box's own baseline (≥ 0); `descent`
is below (≥ 0).  A `VBox`'s baseline is, by convention, the baseline of its first
child (see `text-spec.md` — the y-origin decision is shared between the two
designs precisely so this migration is seamless).

### Construction (`build`)

Each `_layout_*!` becomes a pure `build_*(node, ctx, style) -> Box` returning a
measured box instead of mutating a shared vector:

- A character / symbol / command → `GlyphBox` (or a small `HBox` for multi-glyph
  constructions).
- A sequence → `HBox` whose children interleave the sub-boxes with `Kern`s for
  inter-atom spacing (replacing the inline `Space` pushes in `_layout_children!`).
- A fraction → `VBox` of `[numerator HBox, RuleBox, denominator HBox]` with the
  axis-height offset baked into `offsets`.  This replaces the hand-rolled
  centering in `_layout_frac!`.
- Limits / over-under / accents / radicals / matrix rows → `VBox`es.
- `\left…\right`, `\sqrt` radate → `HBox`es containing assembled delimiter boxes.

Because each builder returns a measured box, the "measure sub-layout, compute
offset, shift in" pattern collapses into "build child boxes, construct the
container, let the container compute its own extent from its children".

### Shaping (`shape`)

A single recursive pass walks the box tree with an absolute `(x, y)` accumulator
and emits the flat `Vector{LayoutBox}` exactly as today:

```julia
shape(box::Box, x::Float64, y::Float64, out::Vector{LayoutBox})
```

`HBox` advances `x` by each child's width; `VBox` places each child at
`y + offsets[i]` and applies the horizontal alignment shift; leaves push a single
`LayoutBox`.  `Glue`/`Kern` advance the cursor without emitting.  The renderer and
the Makie extension are **unchanged** — they still receive `Vector{LayoutBox}`.

## Why this subsumes the Option 1 text work

The `text-spec.md` design introduces:

- `TeXBox { boxes::Vector{LayoutBox}, width, ascent, descent }` — a measured,
  already-positioned horizontal run.
- `vstack(::Vector{TeXBox}; align, line_height)` and `hconcat(::Vector{TeXBox})`.

These are deliberately the *degenerate, eagerly-flattened* form of `VBox` /
`HBox`:

- `TeXBox` ≡ a `Box` that has already been `shape`d (its `boxes` are the shaped
  output, and it still carries `width/ascent/descent`).
- `vstack` ≡ constructing a `VBox` and immediately `shape`-ing it.
- `hconcat` ≡ constructing an `HBox` and immediately `shape`-ing it.

So the migration path is: keep the public `layout_document` API and the
`(width, ascent, descent)` contract; replace the `TeXBox`/`vstack`/`hconcat`
internals with `Box`/`VBox`/`HBox` + a single deferred `shape` at the very end;
then progressively rewrite the math `_layout_*!` functions into `build_*`
returning `Box`es, deleting `_emit_shifted!` and the scratch-vector idioms as each
construct is converted.  Nothing in the document/text layer or the renderer
contract changes.

## What the box tree unlocks later

- **Justification / glue.** `Glue` with non-zero stretch/shrink + a line-breaker
  enables full justification and (eventually) automatic line breaking — both
  currently out of scope.  The data model is in place from day one; only the
  break-point search and glue-setting pass are added.
- **`\raisebox`, `\phantom`, `\smash`, `\strut`, `\rule`** become trivial box
  manipulations rather than special cases.
- **Vertical alignment of inline material** (e.g. an inline fraction sitting on a
  text baseline) is just an `HBox` whose children have differing ascent/descent.
- **Caching / incremental relayout.** A measured, immutable box tree is reusable;
  only `shape` need re-run when only positions change.

## Non-goals (still out of scope at the Option 2 stage)

- Automatic line breaking and full justification *algorithms* (the data model
  permits them; the iterative optimiser is separate future work).
- Microtypography (protrusion, font expansion).
- Page/column breaking.
