# Layout tests: `\left…\right` sizing, extensible delimiter assemblies, and the
# `\big` family.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: delimiters" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    @testset "\\left(x\\right): three glyphs, left delim at x=0" begin
        # \left( x \right) should produce: parenleft, x, parenright (3 glyphs).
        boxes = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
        sorted = sort(glyphs; by = b -> b.x)
        # Left delimiter is placed at x=0 (the formula origin).
        @test sorted[1].x ≈ 0.0
        # Glyphs are ordered left to right.
        @test sorted[1].x < sorted[2].x < sorted[3].x
    end

    @testset "\\left( x \\right): delimiters centred on math axis" begin
        # Delimiter ink centre (y_min+y_max)/2 should equal the math axis height.
        boxes = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs = find_glyphs(boxes)
        axis_em = mt.constants.axis_height / FONT_UPM
        sorted = sort(glyphs; by = b -> b.x)
        for box in (first(sorted), last(sorted))   # left and right delimiter glyphs
            g = box.element
            glyph_center = (g.y_min + g.y_max) / (2.0 * FONT_UPM) * box.scale
            delim_center = box.y + glyph_center
            @test delim_center ≈ axis_em atol = 1.0e-6
        end
    end

    @testset "\\left( \\frac{a}{b} \\right): delimiter larger than plain parens" begin
        # Fractions are taller than a single character, so \left( should scale up.
        boxes_frac = layout(parse_latex("\\left( \\frac{a}{b} \\right)"), family, Text)
        boxes_plain = layout(parse_latex("\\left( x \\right)"), family, Text)
        glyphs_frac = find_glyphs(boxes_frac)
        glyphs_plain = find_glyphs(boxes_plain)
        # The glyph height (y_max - y_min) of the left delimiter in the frac case
        # must be strictly greater than in the plain case.
        height(b) = b.element.y_max - b.element.y_min
        left_frac = sort(glyphs_frac; by = b -> b.x)[1]
        left_plain = sort(glyphs_plain; by = b -> b.x)[1]
        @test height(left_frac) > height(left_plain)
    end

    @testset "\\left…\\right sizing allows TeX's delimiter factor and shortfall" begin
        # TeXbook rule 19: size ≥ max(0.901 × 2δ, 2δ − 0.5 em).
        req(δ) = TeXLayout._left_right_required_du(δ, 1.0, 1000.0)
        @test req(1.0) ≈ 1802.0       # factor dominates for tall content
        @test req(0.3) ≈ 0.901 * 600   # shortfall would allow 100
        @test req(5.0) ≈ 9500.0        # shortfall dominates once 2δ > 5.07 em
        @test req(0.0) == 0.0
        @test TeXLayout._left_right_required_du(1.0, 0.5, 1000.0) ≈ 3604.0   # in unscaled units
        # LuaLaTeX + NewCMMath choose these parenthesis variants (measured; XeLaTeX
        # takes v3 for the nested fraction, its fraction shifts differing).
        paren(src, style) = only(
            b.element.glyph_name for b in find_glyphs(layout(parse_latex(src), family, style))
                if startswith(b.element.glyph_name, "parenleft")
        )
        @test paren(raw"\left(\frac{a}{b}\right)", Text) == "parenleft.v1"
        @test paren(raw"\left(x^2\right)", Text) == "parenleft.v1"
        @test paren(raw"\left(\frac{a}{b}\right)", Display) == "parenleft.v4"
        @test paren(raw"\left(\frac{\frac{a}{b}}{c}\right)", Text) == "parenleft.v4"
        # Matrix delimiters follow the same rule against the array's strutted
        # box, whether from a matrix environment or from \left…\right around a
        # lone matrix; like TeX's, they may fall short of tall entries' ink.
        # LuaLaTeX widths at 10 pt: 35.45 pt and 37.486 pt.
        for (src, wd) in (
                (raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}", 3.545),
                (raw"\left( \begin{matrix} a & b \\ c & d \end{matrix} \right)", 3.545),
                (raw"\begin{pmatrix} \frac{1}{2} & b \\ c & \frac{1}{2} \end{pmatrix}", 3.7486),
                (raw"\left( \begin{matrix} \frac{1}{2} & b \\ c & \frac{1}{2} \end{matrix} \right)", 3.7486),
            )
            pm = layout(parse_latex(src), family, Text)
            @test paren(src, Text) == "parenleft.v6"
            @test TeXLayout.measure(pm, Float64(FONT_UPM)).width ≈ wd atol = 1.0e-4
        end
    end

    @testset "\\left. (null delimiter) places no glyph on the left" begin
        # Null delimiter "." produces no rendered glyph on the left.
        boxes_null = layout(parse_latex("\\left. x \\right)"), family, Text)
        boxes_paren = layout(parse_latex("\\left( x \\right)"), family, Text)
        # null version has one fewer glyph (no left delimiter)
        @test length(find_glyphs(boxes_null)) == length(find_glyphs(boxes_paren)) - 1
    end

    @testset "Assembly: 4-level nested fraction triggers extensible assembly" begin
        # \\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right) in Display
        # style produces required_du > 2991 (the largest parenleft pre-built variant),
        # so the glyph assembly (bottom cap + extender + top cap) is used for each
        # delimiter.  With 5 content chars and 3-part assemblies on each side the total
        # glyph count must exceed the 7 glyphs produced when single-glyph variants are used.
        expr = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        # Minimum: 5 letters + 3 (left assembly) + 3 (right assembly) = 11 glyphs.
        @test length(glyphs) >= 11
    end

    @testset "Assembly: delimiter height exceeds largest pre-built variant" begin
        # The assembly delimiter must be taller than any pre-built variant.
        # Largest parenleft variant advance = 2991 design units in NewCMMath.
        largest_variant_du = 2991
        expr = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        # Assembly parts are placed with y_min=0; their y_max = full_advance.
        # The outermost glyph in the assembly is the top cap (uni239B, full_adv=1495).
        # Assembly top = axis + total_height/2 > largest_variant_du/2 / upm.
        top_em = maximum(b.y + b.element.y_max / FONT_UPM * b.scale for b in glyphs)
        bot_em = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in glyphs)
        span_du = (top_em - bot_em) * FONT_UPM   # convert em → du (at scale=1)
        @test span_du > largest_variant_du
    end

    @testset "Assembly: delimiter centred on math axis" begin
        # The assembly's ink centre must lie on the math axis (±1 du tolerance).
        expr = "\\left( \\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e} \\right)"
        boxes = layout(parse_latex(expr), family, Display)
        glyphs = find_glyphs(boxes)
        axis_em = mt.constants.axis_height / FONT_UPM
        # Isolate the left-delimiter glyphs (all at x=0 with the same advance width).
        left_x = minimum(b.x for b in glyphs)
        left_glyphs = filter(b -> b.x ≈ left_x, glyphs)
        top_em = maximum(b.y + b.element.y_max / FONT_UPM * b.scale for b in left_glyphs)
        bot_em = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in left_glyphs)
        center = (top_em + bot_em) / 2
        @test center ≈ axis_em atol = 1.0e-3
    end

    # ── Manual delimiter sizing ────────────────────────────────────────────────

    @testset "\\bigl( x \\bigr): left delimiter at smallest x, right at largest" begin
        boxes = layout(parse_latex(raw"\bigl( x \bigr)"), family, Display)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) >= 3   # left paren + x + right paren
        left_x = minimum(g.x for g in glyphs)
        right_x = maximum(g.x for g in glyphs)
        @test right_x > left_x
    end

    @testset "\\bigl( advance_width > plain ( advance_width" begin
        # \bigl selects a larger variant; its advance_width must exceed the base glyph.
        boxes_big = layout(parse_latex(raw"\bigl("), family, Display)
        boxes_plain = layout(parse_latex("("), family, Display)
        glyphs_big = find_glyphs(boxes_big)
        glyphs_plain = find_glyphs(boxes_plain)
        @test !isempty(glyphs_big) && !isempty(glyphs_plain)
        adv_big = glyphs_big[1].element.advance_width
        adv_plain = glyphs_plain[1].element.advance_width
        @test adv_big > adv_plain
    end

    @testset "\\Bigl( advance_width > \\bigl( advance_width (size 2 > size 1)" begin
        boxes1 = layout(parse_latex(raw"\bigl("), family, Display)
        boxes2 = layout(parse_latex(raw"\Bigl("), family, Display)
        adv1 = find_glyphs(boxes1)[1].element.advance_width
        adv2 = find_glyphs(boxes2)[1].element.advance_width
        @test adv2 > adv1
    end

    @testset "\\big to \\Bigg: a delimiter at every size, growing with the size" begin
        # Each size reads its glyph and size from the node's payload, so a
        # layout that cannot read the payload draws nothing.  The largest sizes
        # may be assemblies, so measure the ink extent of all the glyphs.
        function ink_height(src)
            glyphs = find_glyphs(layout(parse_latex(src), family, Display))
            @test !isempty(glyphs)
            isempty(glyphs) && return 0.0
            top = maximum(g.y + g.element.y_max * g.scale / mt.upm for g in glyphs)
            bottom = minimum(g.y + g.element.y_min * g.scale / mt.upm for g in glyphs)
            return top - bottom
        end
        heights = ink_height.(["(", raw"\bigl(", raw"\Bigl(", raw"\biggl(", raw"\Biggl("])
        @test all(diff(heights) .> 0)
    end

    @testset "\\bigl, \\bigr, and \\bigm take open, close, and relation spacing" begin
        # The parser tests check the class stored in the payload; this checks
        # that layout reads it.  x of the i-th glyph; Display style, so
        # 1 mu = 1/18 em.
        gx(src, i) = find_glyphs(layout(parse_latex(src), family, Display))[i].x
        thick, medium = TeXLayout._THICK, TeXLayout._MEDIUM
        # A relation has a thick space on each side; a plain \big is ordinary.
        @test gx(raw"a\bigm|b", 2) - gx(raw"a\big|b", 2) ≈ thick atol = 1.0e-9
        @test gx(raw"a\bigm|b", 3) - gx(raw"a\big|b", 3) ≈ 2thick atol = 1.0e-9
        # A binary operator after an opening delimiter, or before a closing
        # one, becomes ordinary and loses its medium spaces (TeX rules 5 and 6).
        @test gx(raw"\big(+x", 3) - gx(raw"\bigl(+x", 3) ≈ 2medium atol = 1.0e-9
        @test gx(raw"x+\big)", 3) - gx(raw"x+\bigr)", 3) ≈ 2medium atol = 1.0e-9
    end

    @testset "\\bigl. produces no glyph boxes (null delimiter)" begin
        boxes = layout(parse_latex(raw"\bigl."), family, Display)
        @test isempty(find_glyphs(boxes))
    end

    @testset "\\bigl( x \\bigr)^2 does not crash" begin
        boxes = layout(parse_latex(raw"\bigl( x \bigr)^2"), family, Display)
        @test !isempty(boxes)
    end
end
