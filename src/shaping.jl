# Text shaping: interface + metrics-only implementation.
#
# The TextShaper interface is the seam that keeps HarfBuzz out of core.
# ext/HarfBuzzExt.jl adds the HarfBuzzShaper shape_span method when HarfBuzz_jll
# is loaded.

"""
Abstract interface for shaping text spans in document layout.

Subtypes implement `shape_span(shaper, span, family, base_scale)` and return a
measured `TeXBox` whose glyph positions are expressed in em units.
"""
abstract type TextShaper end

"""
    shape_span(shaper, span, family, base_scale) -> TeXBox

Shape one uniform-attribute text span into a measured layout fragment.

Contract (must be honoured by every shaper, including future extensions):
  - returned boxes are in em units, baseline at y = 0, first glyph at x = 0;
  - each emitted glyph element carries the `TextSpan`'s resolved text font slot;
  - semantic `TextFeatures` are applied faithfully or rejected explicitly;
  - width = total advance, ascent/descent = max ink extents (≥ 0);
  - missing glyphs are skipped (advance = 0).
"""
function shape_span end

"""
Metrics-only `TextShaper` implementation.

`MetricShaper` places one glyph per Unicode scalar using the configured font
metrics. It does not perform HarfBuzz shaping, ligature substitution, kerning, or
script-specific text layout.
"""
struct MetricShaper <: TextShaper end

"""
HarfBuzz-backed `TextShaper`.

The implementation lives in the optional `HarfBuzzExt` package extension and is
loaded when `HarfBuzz_jll` is available in the same Julia session.
"""
struct HarfBuzzShaper <: TextShaper end

function shape_span(::MetricShaper, span, family::FontFamily, base_scale::Float64)
    if _has_text_features(span.attrs.features)
        features = join(_text_feature_names(span.attrs.features), ", ")
        throw(
            ArgumentError(
                "MetricShaper cannot apply text features ($features); load HarfBuzz_jll " *
                    "and use HarfBuzzShaper()",
            ),
        )
    end

    slot = span.attrs.slot
    scale = base_scale * span.attrs.size
    boxes = LayoutBox[]
    cursor = 0.0
    ascent = 0.0
    descent = 0.0

    for ch in span.text
        r = glyph_metrics_slot(family, ch, slot)
        r === nothing && continue   # no glyph in any fallback — skip, zero advance

        m, font_path = r
        upm = _font_upm(font_path)   # cached; per-glyph because fallback fonts may differ

        ps = glyph_name_by_codepoint(font_path, UInt32(ch))
        isempty(ps) && (ps = string(ch))   # no post table → use char as last-resort name

        push!(
            boxes,
            LayoutBox(
                Glyph(
                    ps, slot, m.advance_width, m.left_side_bearing,
                    m.x_min, m.y_min, m.x_max, m.y_max,
                ),
                cursor, 0.0, scale,
            ),
        )
        cursor += m.advance_width / upm * scale
        ascent = max(ascent, m.y_max / upm * scale)
        descent = max(descent, -m.y_min / upm * scale)   # y_min ≤ 0 → -y_min ≥ 0
    end

    return TeXBox(boxes, cursor, ascent, descent)
end
