# Helpers shared by the layout and text test files.  Included once from
# runtests.jl after the fixture constants.

# Layout boxes whose element satisfies `pred`, and common element filters.
find_elements(boxes, pred) = filter(b -> pred(b.element), boxes)
find_glyphs(boxes) = find_elements(boxes, e -> e isa Glyph)
find_hrules(boxes) = find_elements(boxes, e -> e isa HRule)
is_glyph_box(box) = box.element isa Glyph || box.element isa GlyphID

# True when `box` is the italic-correction kern that follows a math character
# (TeX rule 17) in a layout set in the fixture font.
function is_italic_kern(box, boxes, mt = load_math_table(FIXTURE_FONT_PATH))
    box.element isa Space || return false
    return any(boxes) do g
        g.element isa Glyph || return false
        ic = get(mt.italic_corrections, g.element.glyph_name, 0) / mt.upm * g.scale
        ic > 0 && isapprox(box.element.width, ic; atol = 1.0e-9) &&
            isapprox(box.x, g.x + g.element.advance_width / mt.upm * g.scale; atol = 1.0e-9)
    end
end

# Spacing boxes other than italic-correction kerns, which the spacing tests do
# not count.
find_spaces(boxes) = filter(b -> b.element isa Space && !is_italic_kern(b, boxes), boxes)
