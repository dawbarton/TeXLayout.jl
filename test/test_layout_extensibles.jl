# Layout tests: extensible arrows, horizontal assemblies, display-operator
# fallback, and assorted symbols.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: extensible arrows and assemblies" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    # ── Extensible arrows ──────────────────────────────────────────────────────

    @testset "Extensible arrows without a MATH construction are built from pieces" begin
        # Fira Math has no horizontal constructions for arrows (Luciole and STIX
        # Two lack some).  Like amsmath's \arrowfill@, TeXLayout then builds the
        # arrow from a left piece, repeated extenders, and a right piece.
        fira = font_family(:fira_math)
        name(cp) = TeXLayout.glyph_name_by_codepoint(fira, UInt32(cp))
        ink_left(g) = g.x + g.element.x_min / 1000 * g.scale
        ink_right(g) = g.x + g.element.x_max / 1000 * g.scale
        upm = TeXLayout.load_math_table(fira.math).upm
        @test upm == 1000
        for (source, pieces) in (
                (raw"\xrightarrow{abcdef}", (0x2212, 0x2192)),
                (raw"\xleftarrow{abcdef}", (0x2190, 0x2212)),
                (raw"\xleftrightarrow{abcdef}", (0x2190, 0x2192)),
                (raw"\xRightarrow{abcdef}", (0x003D, 0x21D2)),
            )
            glyphs = find_glyphs(layout(parse_latex(source), fira, Text))
            labels = filter(g -> g.scale < 0.9, glyphs)
            arrow = sort(filter(g -> g.scale ≈ 1.0, glyphs); by = g -> g.x)
            @test length(arrow) >= 3
            @test arrow[1].element.glyph_name == name(pieces[1])
            @test arrow[end].element.glyph_name == name(pieces[2])
            # The arrow spans the labels and sits below them, on the baseline.
            @test ink_left(arrow[1]) < minimum(ink_left, labels)
            @test ink_right(arrow[end]) > maximum(ink_right, labels)
            @test all(g -> g.y == 0.0, arrow)
            # Consecutive pieces overlap, so the shaft is continuous.
            @test all(i -> ink_left(arrow[i + 1]) < ink_right(arrow[i]), 1:(length(arrow) - 1))
        end
        # An arrow with no piece decomposition keeps its glyph at natural width.
        glyphs = find_glyphs(layout(parse_latex(raw"\xmapsto{abc}"), fira, Text))
        @test count(g -> g.element.glyph_name == name(0x21A6), glyphs) == 1
    end

    @testset "\\xrightarrow{f} lays out without error" begin
        boxes = layout(parse_latex(raw"\xrightarrow{f}"), family, Text)
        @test !isempty(boxes)
    end

    @testset "\\xrightarrow arrow is centred on the math axis" begin
        boxes = layout(parse_latex(raw"\xrightarrow{f}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test !isempty(glyphs)
        # The arrow glyph(s) should straddle the math axis (some above, some below or at zero).
        axis_em = mt.constants.axis_height / mt.upm
        # At least one glyph in the arrow box should have its midpoint near the axis.
        g = sort(
            glyphs;
            by = b -> abs(b.y + (b.element.y_min + b.element.y_max) / (2.0 * mt.upm) * b.scale - axis_em),
        )[1]
        mid = g.y + (g.element.y_min + g.element.y_max) / (2.0 * mt.upm) * g.scale
        @test abs(mid - axis_em) < 0.5   # within half-em of axis (coarse sanity check)
    end

    @testset "\\xrightarrow[g]{f} has more vertical extent than \\xrightarrow{f}" begin
        boxes_above = layout(parse_latex(raw"\xrightarrow{f}"), family, Text)
        boxes_both = layout(parse_latex(raw"\xrightarrow[g]{f}"), family, Text)
        # Adding a below label should push the ink further below the baseline.
        bot_above = minimum(
            b.y + (b.element isa Glyph ? b.element.y_min / mt.upm * b.scale : 0.0)
                for b in boxes_above
        )
        bot_both = minimum(
            b.y + (b.element isa Glyph ? b.element.y_min / mt.upm * b.scale : 0.0)
                for b in boxes_both
        )
        @test bot_both <= bot_above
    end

    @testset "\\xrightarrow is wider when label is wide" begin
        boxes_short = layout(parse_latex(raw"\xrightarrow{f}"), family, Text)
        boxes_long = layout(parse_latex(raw"\xrightarrow{\text{long label}}"), family, Text)
        w_short = maximum(
            b.x + (
                b.element isa Glyph ? b.element.advance_width / mt.upm * b.scale :
                    b.element isa HRule ? b.element.width : 0.0
            ) for b in boxes_short
        )
        w_long = maximum(
            b.x + (
                b.element isa Glyph ? b.element.advance_width / mt.upm * b.scale :
                    b.element isa HRule ? b.element.width : 0.0
            ) for b in boxes_long
        )
        @test w_long > w_short
    end

    @testset "extensible arrows without a MATH construction" begin
        # Fira Math has no horizontal constructions for its arrows and STIX Two
        # none for ↠ or =; these used to render no arrow at all.
        fira = font_family(:fira_math)
        fira_upm = Float64(load_math_table(fira.math).upm)
        ink(b, upm) = (b.x + b.element.x_min / upm * b.scale, b.x + b.element.x_max / upm * b.scale)
        cp_of(fam, b) = b.element isa Glyph &&
            something(findfirst(c -> TeXLayout.glyph_name_by_codepoint(fam, UInt32(c)) == b.element.glyph_name, collect("→−↦=↠")), 0)

        # \xrightarrow under a wide label: minus fillers then →, one continuous
        # ink run (amsmath's \arrowfill@) reaching beyond the label's ink.
        label = TeXLayout.layout(parse_latex(raw"\text{long label}"), fira, TeXLayout.Script)
        label_w = TeXLayout.measure(label, fira_upm).width
        boxes = TeXLayout.layout(parse_latex(raw"\xrightarrow{\text{long label}}"), fira, Text)
        pieces = filter(b -> cp_of(fira, b) in (1, 2), boxes)
        @test count(b -> cp_of(fira, b) == 1, pieces) == 1
        @test count(b -> cp_of(fira, b) == 2, pieces) >= 2
        @test length(unique(b.y for b in pieces)) == 1   # one shared baseline
        spans = sort([ink(b, fira_upm) for b in pieces])
        @test all(spans[i + 1][1] < spans[i][2] for i in 1:(length(spans) - 1))
        @test cp_of(fira, last(sort(pieces; by = b -> b.x))) == 1   # head on the right
        @test spans[end][2] - spans[1][1] > label_w

        # Arrows with no single-codepoint tail fall back to the natural glyph.
        @test count(b -> cp_of(fira, b) == 3, TeXLayout.layout(parse_latex(raw"\xmapsto{abc}"), fira, Text)) == 1

        stix = font_family(:stix_two)
        twohead = TeXLayout.layout(parse_latex(raw"\xtwoheadrightarrow{abc}"), stix, Text)
        @test count(b -> cp_of(stix, b) == 5, twohead) == 1
        @test count(b -> cp_of(stix, b) == 2, twohead) >= 1
        longeq = TeXLayout.layout(parse_latex(raw"\xlongequal{\text{def}}"), stix, Text)
        @test count(b -> cp_of(stix, b) == 4, longeq) >= 2

        # Arrows sit on the baseline like any relation, so a harpoon's shaft
        # stays on the axis instead of its ink being centred there.
        harpoon = TeXLayout.layout(parse_latex(raw"\xrightharpoonup{\text{long label}}"), fira, Text)
        @test all(b.y == 0.0 for b in boxes if cp_of(fira, b) in (1, 2))
        @test all(b.y == 0.0 for b in harpoon if b.element isa Glyph && b.scale == 1.0)
    end

    @testset "horizontal assemblies shrink to the required width" begin
        # Widening the part overlaps (as vertical assemblies already did) keeps
        # an assembled brace within its body; with minimum overlaps the Pagella
        # underbrace below overshot by 0.84 em on each side.
        pagella = font_family(:pagella)
        pupm = Float64(load_math_table(pagella.math).upm)
        src = raw"\underbrace{f(x_1)\cdot f(x_2)\cdots f(x_n)}_{n}"
        bx = TeXLayout.layout(parse_latex(src), pagella, Text)
        brace = [b for b in bx if b.element isa Glyph && occursin(r"brace|23DF", b.element.glyph_name)]
        @test length(brace) > 3   # an assembly, not a single variant
        body = TeXLayout.layout(parse_latex(raw"f(x_1)\cdot f(x_2)\cdots f(x_n)"), pagella, Text)
        body_w = TeXLayout.measure(body, pupm).width
        ink_l = minimum(b.x + b.element.x_min / pupm * b.scale for b in brace)
        ink_r = maximum(b.x + b.element.x_max / pupm * b.scale for b in brace)
        @test ink_r - ink_l <= body_w + 0.1
    end

    @testset "display operators fall back to the largest variant" begin
        # STIX Two's DisplayOperatorMinHeight (1800) exceeds every operator
        # variant; TeX then takes the largest rather than the base glyph.
        stix = font_family(:stix_two)
        names(src, st) = [b.element.glyph_name for b in TeXLayout.layout(parse_latex(src), stix, st) if b.element isa Glyph]
        @test names(raw"\sum", Display) == ["uni2211.s1"]
        @test names(raw"\bigoplus", Display) == ["uni2A01.s1"]
        @test names(raw"\sum", Text) == ["uni2211"]
    end

    @testset "logic symbols, harpoons, and spaced lim sup" begin
        for cmd in ("\\neg", "\\lnot", "\\leftharpoonup", "\\rightharpoondown", "\\rightleftharpoons", "\\upharpoonright")
            @test length(find_glyphs(layout(parse_latex(cmd), family, Text))) == 1
        end
        # Harpoons are relations: thick spaces around them.
        @test length(find_spaces(layout(parse_latex(raw"a\rightleftharpoons b"), family, Text))) == 2
        # amsmath sets \limsup as lim\,sup.
        ls = layout(parse_latex(raw"\limsup"), family, Text)
        @test length(find_glyphs(ls)) == 6
        @test only(b.element.width for b in ls if b.element isa Space) ≈ 3 / 18
    end
end
