# Layout tests: large operators, limits placement, operator names, the `\bmod`
# family, and `\mathchoice`.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: operators and limits" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    # ── Limits placement ──────────────────────────────────────────────────────

    @testset "Limits: \\lim_{n} in Display places sub centred below" begin
        # In Display style \lim is a limits operator: subscript goes below, centred.
        boxes = layout(parse_latex("\\lim_{n}"), family, Display)
        glyphs = find_glyphs(boxes)
        # 3 upright glyphs from \lim (l, i, m) + 1 sub glyph (n).
        @test length(glyphs) == 4
        lim_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)   # base scale
        sub_glyph = filter(b -> b.scale < 0.9, glyphs)    # script scale
        @test length(lim_glyphs) == 3
        @test length(sub_glyph) == 1
        sub = sub_glyph[1]
        # Sub must be below baseline.
        @test sub.y < 0.0
        # Gap between base bottom ink and sub top ink must be ≥ lower_limit_gap_min.
        base_bot = minimum(b.y + b.element.y_min / FONT_UPM * b.scale for b in lim_glyphs)
        sub_top = sub.y + sub.element.y_max / FONT_UPM * sub.scale
        @test base_bot - sub_top >= mt.constants.lower_limit_gap_min / FONT_UPM - 1.0e-6
        # Sub is horizontally centred: since \lim (3 chars) is wider than n,
        # the sub's left x must be positive (shifted right to centre it).
        @test sub.x > 0.0
    end

    @testset "Limits: \\lim_{n} in Text uses side placement" begin
        # In Text style \lim is NOT a limits operator: sub goes to the right.
        boxes = layout(parse_latex("\\lim_{n}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 4
        # Sub glyph (smaller scale) must be to the right of all base glyphs.
        sub_glyph = filter(b -> b.scale < 0.9, glyphs)
        lim_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        @test length(sub_glyph) == 1
        rightmost_lim_x = maximum(b.x for b in lim_glyphs)
        @test sub_glyph[1].x > rightmost_lim_x
    end

    @testset "Limits: \\sin_{x} in Display uses side placement (not a limits op)" begin
        # \sin is never a limits operator, even in Display style.
        boxes = layout(parse_latex("\\sin_{x}"), family, Display)
        glyphs = find_glyphs(boxes)
        # 3 base glyphs (s, i, n) + 1 sub (x).
        @test length(glyphs) == 4
        sub_glyph = filter(b -> b.scale < 0.9, glyphs)
        sin_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        @test length(sub_glyph) == 1
        # Side placement: sub is to the right of the sin text.
        rightmost_sin_x = maximum(b.x for b in sin_glyphs)
        @test sub_glyph[1].x > rightmost_sin_x
    end

    @testset "Limits: \\sum has positive advance width (large-op codepoint fix)" begin
        # Before the codepoint fix, \\sum rendered as invisible (0 width) because
        # _cmd_glyph looked up "sum" which is not a PS name in NewCMMath.
        boxes = layout(parse_latex("\\sum"), family, Display)
        @test !isempty(find_glyphs(boxes))
        # Advance width must be positive.
        @test find_glyphs(boxes)[1].element.advance_width > 0
    end

    @testset "Limits: \\sum in Display uses display-size glyph" begin
        # In Display style the \sum glyph height should meet DisplayOperatorMinHeight.
        boxes_d = layout(parse_latex("\\sum"), family, Display)
        boxes_t = layout(parse_latex("\\sum"), family, Text)
        g_d = find_glyphs(boxes_d)[1].element
        g_t = find_glyphs(boxes_t)[1].element
        # Display variant is taller than Text variant.
        @test (g_d.y_max - g_d.y_min) > (g_t.y_max - g_t.y_min)
        # Display variant meets the minimum height threshold.
        @test (g_d.y_max - g_d.y_min) >= mt.constants.display_operator_min_height
    end

    @testset "Limits: \\sum_{i}^{n} in Display places limits above and below" begin
        # Both sub and sup should be centred above/below the \sum glyph.
        boxes = layout(parse_latex("\\sum_{i}^{n}"), family, Display)
        glyphs = find_glyphs(boxes)
        # Separate: base at scale≈1, scripts at script scale.
        base_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        script_glyphs = filter(b -> b.scale < 0.9, glyphs)
        @test length(base_glyphs) == 1     # \sum glyph
        @test length(script_glyphs) == 2   # i (sub) + n (sup)
        # Sub is below base, sup is above base.
        sub_glyph = argmin(b -> b.y, script_glyphs)
        sup_glyph = argmax(b -> b.y, script_glyphs)
        @test sub_glyph.y < 0.0
        @test sup_glyph.y > 0.0
        # Gap constraints: sub top ink below sum bottom ink, sup bottom ink above sum top ink.
        sum_box = base_glyphs[1]
        sum_top = sum_box.y + sum_box.element.y_max / FONT_UPM * sum_box.scale
        sum_bot = sum_box.y + sum_box.element.y_min / FONT_UPM * sum_box.scale
        sub_top = sub_glyph.y + sub_glyph.element.y_max / FONT_UPM * sub_glyph.scale
        sup_bot = sup_glyph.y + sup_glyph.element.y_min / FONT_UPM * sup_glyph.scale
        @test sub_top <= sum_bot + 1.0e-6   # sub ink at or below sum bottom
        @test sup_bot >= sum_top - 1.0e-6   # sup ink at or above sum top
    end

    @testset "Limits: \\int\\limits_0^1 in Text forces limits placement" begin
        # \nolimits / \limits override the automatic detection.
        # \int normally uses side placement in Text; \limits forces above/below.
        boxes = layout(parse_latex("\\int\\limits_0^1"), family, Text)
        glyphs = find_glyphs(boxes)
        base_glyphs = filter(b -> b.scale ≈ 1.0, glyphs)
        script_glyphs = filter(b -> b.scale < 0.9, glyphs)
        @test !isempty(base_glyphs)
        @test length(script_glyphs) == 2
        sub_glyph = argmin(b -> b.y, script_glyphs)
        sup_glyph = argmax(b -> b.y, script_glyphs)
        @test sub_glyph.y < 0.0   # 0 is below baseline
        @test sup_glyph.y > 0.0   # 1 is above baseline
        # Forced limits: sub/sup must NOT be to the right of the base.
        int_x_right = base_glyphs[1].x + base_glyphs[1].element.advance_width / FONT_UPM
        @test sub_glyph.x < int_x_right
        @test sup_glyph.x < int_x_right
    end

    @testset "Limits: \\sum\\nolimits_{i} in Display forces side placement" begin
        # \nolimits overrides the automatic limits detection.
        boxes_limits = layout(parse_latex("\\sum_{i}"), family, Display)
        boxes_nolimits = layout(parse_latex("\\sum\\nolimits_{i}"), family, Display)
        glyphs_l = find_glyphs(boxes_limits)
        glyphs_n = find_glyphs(boxes_nolimits)
        # With nolimits the sub goes to the right (side placement).
        sub_side = filter(b -> b.scale < 0.9, glyphs_n)
        sub_lim = filter(b -> b.scale < 0.9, glyphs_l)
        @test length(sub_side) == 1
        @test length(sub_lim) == 1
        # Sub x is farther right in side placement than in limits placement.
        @test sub_side[1].x > sub_lim[1].x
    end

    @testset "Limits: \\limsup and \\liminf are recognised operators" begin
        # limsup and liminf should render as upright text (NodeKind.Operator).
        for cmd in ("\\limsup", "\\liminf")
            boxes = layout(parse_latex(cmd), family, Display)
            @test !isempty(find_glyphs(boxes))
        end
    end

    @testset "Limits: two-word operator names have a thin space" begin
        # amsopn defines \liminf as \qopname\relax m{lim\,inf} (likewise \limsup,
        # \injlim, \projlim): a 3 mu thin space separates the words, and the
        # operator takes limits in Display style.
        advance(g) = g.element.advance_width / FONT_UPM * g.scale
        for (cmd, word1, word2) in (
                ("\\liminf", "lim", "inf"), ("\\limsup", "lim", "sup"),
                ("\\injlim", "inj", "lim"), ("\\projlim", "proj", "lim"),
            )
            for (source, scale) in ((cmd, 1.0), ("x_{" * cmd * "}", mt.constants.script_percent_scale_down / 100))
                glyphs = sort(filter(g -> g.scale ≈ scale, find_glyphs(layout(parse_latex(source), family, Text))); by = g -> g.x)
                @test length(glyphs) == length(word1) + length(word2)
                last1, first2 = glyphs[length(word1)], glyphs[length(word1) + 1]
                @test first2.x - (last1.x + advance(last1)) ≈ 3 / 18 * scale
            end
            # Limits placement in Display style is unchanged.
            glyphs = find_glyphs(layout(parse_latex(cmd * "_{n}"), family, Display))
            sub = only(filter(b -> b.scale < 0.9, glyphs))
            @test sub.y < 0.0
            @test sub.x > 0.0
        end
    end

    @testset "Limits: \\operatorname* and \\displaylimits take limits in Display only" begin
        # \displaylimits (TeX's default for \mathop, and amsopn's flag for
        # \operatorname*) behaves as \limits in Display style and as \nolimits
        # otherwise.
        positions(source, style) = [(b.x, b.y, b.scale) for b in layout(parse_latex(source), family, style)]
        for (base, starred) in (
                (raw"\operatorname{arg\,max}", raw"\operatorname*{arg\,max}"),
                (raw"\int", raw"\int\displaylimits"),
            )
            limits, nolimits = base * raw"\limits_{x}", base * raw"\nolimits_{x}"
            @test positions(limits, Display) != positions(nolimits, Display)   # not vacuous
            @test positions(starred * "_{x}", Display) == positions(limits, Display)
            @test positions(starred * "_{x}", Text) == positions(nolimits, Text)
        end
        # The unstarred form never takes limits.
        @test positions(raw"\operatorname{arg\,max}_{x}", Display) ==
            positions(raw"\operatorname{arg\,max}\nolimits_{x}", Display)
        # The thin space in arg\,max is kept.
        glyphs = sort(find_glyphs(layout(parse_latex(raw"\operatorname{arg\,max}"), family, Text)); by = g -> g.x)
        @test length(glyphs) == 6
        g, m = glyphs[3], glyphs[4]
        @test m.x - (g.x + g.element.advance_width / FONT_UPM * g.scale) ≈ 3 / 18
    end

    @testset "\\bmod, \\pmod, \\mod, \\pod spacing follows amsmath" begin
        advance(g) = g.element.advance_width / FONT_UPM * g.scale
        # Gap between the end of glyph i and the start of glyph i + 1, sorted by x.
        function gaps(source, style)
            glyphs = sort(find_glyphs(layout(parse_latex(source), family, style)); by = g -> g.x)
            return [glyphs[i + 1].x - (glyphs[i].x + advance(glyphs[i])) for i in 1:(length(glyphs) - 1)]
        end
        sscale = mt.constants.script_percent_scale_down / 100
        # a mod b: 5 mu either side in every style (glyphs a m o d b).
        for (source, style, s) in ((raw"a \bmod b", Display, 1.0), (raw"a \bmod b", Text, 1.0), (raw"x_{a \bmod b}", Text, sscale))
            g = gaps(source, style)
            @test g[end - 3] ≈ 5 / 18 * s
            @test g[end] ≈ 5 / 18 * s
        end
        # b (mod n): 18 mu before "(" in Display style, 8 mu otherwise; 6 mu before n.
        # The kern follows b's italic correction.
        ic_b = mt.italic_corrections[TeXLayout.glyph_name_by_codepoint(family, UInt32(0x0001D44F))] / FONT_UPM   # 𝑏
        for (style, kern) in ((Display, 18), (Text, 8))
            g = gaps(raw"b \pmod{n}", style)   # b ( m o d n )
            @test g[1] ≈ ic_b + kern / 18
            @test g[5] ≈ 6 / 18
            @test gaps(raw"b \pod{n}", style)[1] ≈ ic_b + kern / 18
        end
        # b mod n: 18 mu (Display) or 12 mu before "mod", then two thin spaces.
        for (style, kern) in ((Display, 18), (Text, 12))
            g = gaps(raw"b \mod{n}", style)   # b m o d n
            @test g[1] ≈ ic_b + kern / 18
            @test g[4] ≈ 6 / 18
        end
    end

    @testset "\\mathchoice selects its argument by style" begin
        chosen(source, style) = [g.element.glyph_name for g in find_glyphs(layout(parse_latex(source), family, style))]
        choice = raw"\mathchoice{a}{b}{c}{d}"
        @test chosen(choice, Display) == chosen("a", Display)
        @test chosen(choice, Text) == chosen("b", Text)
        @test chosen("x_{" * choice * "}", Text) == chosen("x_{c}", Text)
        @test chosen("x_{y_{" * choice * "}}", Text) == chosen("x_{y_{d}}", Text)
        # The chosen list is spliced into the surrounding list for spacing:
        # a + \mathchoice{+}{+}{+}{+} b has the same layout as a + + b.
        positions(source) = [(b.x, b.y) for b in layout(parse_latex(source), family, Text)]
        @test positions(raw"a \mathchoice{+}{+}{+}{+} b") == positions(raw"a + b")
    end
end
