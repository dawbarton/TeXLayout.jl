# Text tests: the export list, text-font slot fallback, `MetricShaper`,
# `GlyphID`, and the HarfBuzz extension (src/fonts.jl, src/shaping.jl,
# ext/HarfBuzzExt.jl).
#
# The fixture font and helpers come from runtests.jl and helpers.jl.

@testset "Text: fonts and shaping" begin
    family = FontFamily(FIXTURE_FONT_PATH)

    @testset "exports stay limited to Makie-facing configuration" begin
        @test Set(names(TeXLayout)) == Set(
            (
                :TeXLayout,
                :font_family,
                :default_font_family,
                :set_default_font_family!,
                :default_layout_options,
                :set_default_layout_options!,
                :HarfBuzzShaper,
                :TeXLayoutHandler,
            )
        )
    end

    # ── Font additions ────────────────────────────────────────────────────────

    @testset "glyph_metrics_slot: fallback to math for math-only family" begin
        # Regular → math font (no regular slot configured)
        result = TeXLayout.glyph_metrics_slot(family, 'a', TeXLayout.FontSlot.Regular)
        @test result !== nothing
        m, path = result
        @test m isa GlyphMetrics
        @test path == FIXTURE_FONT_PATH

        # Bold, italic, bolditalic all fall through to the math font.
        for slot in (TeXLayout.FontSlot.Bold, TeXLayout.FontSlot.Italic, TeXLayout.FontSlot.BoldItalic)
            r = TeXLayout.glyph_metrics_slot(family, 'a', slot)
            @test r !== nothing
            _, p2 = r
            @test p2 == FIXTURE_FONT_PATH
        end

        # Unknown codepoint (\x01) is absent from all slots.
        @test TeXLayout.glyph_metrics_slot(family, '\x01', TeXLayout.FontSlot.Regular) === nothing
    end

    @testset "_font_path_for_slot: text slots follow configured fallback order" begin
        full_family = font_family(:new_cm)
        @test TeXLayout._font_path_for_slot(full_family, TeXLayout.FontSlot.Math) == full_family.math
        @test TeXLayout._font_path_for_slot(full_family, TeXLayout.FontSlot.Regular) == full_family.regular
        @test TeXLayout._font_path_for_slot(full_family, TeXLayout.FontSlot.Bold) == full_family.bold
        @test TeXLayout._font_path_for_slot(full_family, TeXLayout.FontSlot.Italic) == full_family.italic
        @test TeXLayout._font_path_for_slot(full_family, TeXLayout.FontSlot.BoldItalic) == full_family.bolditalic

        @test TeXLayout._font_path_for_slot(family, TeXLayout.FontSlot.Regular) == family.math
        @test TeXLayout._font_path_for_slot(family, TeXLayout.FontSlot.Bold) == family.math
        @test TeXLayout._font_path_for_slot(family, TeXLayout.FontSlot.Italic) == family.math
        @test TeXLayout._font_path_for_slot(family, TeXLayout.FontSlot.BoldItalic) == family.math
    end

    @testset "text-family fallback keeps family and face as independent axes" begin
        termes = font_family(:termes)
        @test termes.sans isa TeXLayout.TextFontSet
        @test termes.monospace isa TeXLayout.TextFontSet
        @test TeXLayout._text_font_fallback(
            termes, TeXLayout.TextFamily.Sans, TeXLayout.FontSlot.BoldItalic,
        )[1] == termes.sans.bolditalic
        @test TeXLayout._text_font_fallback(
            termes, TeXLayout.TextFamily.Monospace, TeXLayout.FontSlot.Italic,
        )[1] == termes.monospace.italic

        no_companions = FontFamily(
            termes.math, termes.regular, termes.italic, termes.bold, termes.bolditalic,
        )
        @test TeXLayout._text_font_fallback(
            no_companions, TeXLayout.TextFamily.Sans, TeXLayout.FontSlot.Bold,
        )[1] == termes.bold
        @test last(
            TeXLayout._text_font_fallback(
                no_companions, TeXLayout.TextFamily.Monospace, TeXLayout.FontSlot.Regular,
            ),
        ) == termes.math
    end

    @testset "_font_upm returns correct UPM for fixture font" begin
        upm = TeXLayout._font_upm(FIXTURE_FONT_PATH)
        @test upm isa Float64
        @test upm == Float64(FONT_UPM)
    end

    # ── Shaping ───────────────────────────────────────────────────────────────

    @testset "MetricShaper" begin
        shaper = TeXLayout.MetricShaper()

        @testset "TextAttrs two-argument constructor defaults to no features" begin
            attrs = TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0)
            @test !attrs.features.small_caps
        end

        @testset "Glyph x-positions advance left to right" begin
            span = TeXLayout.TextSpan("abc", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            box = TeXLayout.shape_span(shaper, span, family, 1.0)
            @test box isa TeXLayout.TeXBox
            @test length(box.boxes) == 3
            @test box.boxes[1].x ≈ 0.0
            @test box.boxes[2].x > 0.0
            @test box.boxes[3].x > box.boxes[2].x
            @test all(b.element isa GlyphID for b in box.boxes)
        end

        @testset "Emitted glyphs carry FontSlot.Regular" begin
            span = TeXLayout.TextSpan("ab", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            box = TeXLayout.shape_span(shaper, span, family, 1.0)
            @test all(b.element.font_slot === TeXLayout.FontSlot.Regular for b in box.boxes)
        end

        @testset "Styled spans emit glyphs with the requested text font slot" begin
            full_family = font_family(:new_cm)
            cases = (
                TeXLayout.FontSlot.Bold,
                TeXLayout.FontSlot.Italic,
                TeXLayout.FontSlot.BoldItalic,
            )
            for slot in cases
                span = TeXLayout.TextSpan("A", TeXLayout.TextAttrs(slot, 1.0))
                box = TeXLayout.shape_span(shaper, span, full_family, 1.0)
                @test length(box.boxes) == 1
                @test box.boxes[1].element.font_slot === slot
            end
        end

        @testset "Ascent > 0 and descent >= 0 for uppercase letter" begin
            span = TeXLayout.TextSpan("A", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            box = TeXLayout.shape_span(shaper, span, family, 1.0)
            @test box.ascent > 0.0
            @test box.descent >= 0.0
        end

        @testset "Size multiplier scales width linearly" begin
            span1 = TeXLayout.TextSpan("a", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            span2 = TeXLayout.TextSpan("a", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 2.0))
            box1 = TeXLayout.shape_span(shaper, span1, family, 1.0)
            box2 = TeXLayout.shape_span(shaper, span2, family, 1.0)
            @test box2.width ≈ 2 * box1.width
        end

        @testset "Missing glyph (control char) does not throw" begin
            span = TeXLayout.TextSpan("\x01\x02", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            @test_nowarn TeXLayout.shape_span(shaper, span, family, 1.0)
        end

        @testset "OpenType features fail explicitly instead of being approximated" begin
            attrs = TeXLayout.TextAttrs(
                TeXLayout.FontSlot.Regular,
                1.0,
                TeXLayout.TextFeatures(true),
            )
            span = TeXLayout.TextSpan("small", attrs)
            err = try
                TeXLayout.shape_span(shaper, span, family, 1.0)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("HarfBuzzShaper", sprint(showerror, err))
        end
    end

    @testset "GlyphID render primitive" begin
        upm = TeXLayout._font_upm(FIXTURE_FONT_PATH)
        g = GlyphID(
            42, FIXTURE_FONT_PATH, TeXLayout.FontSlot.Regular, 'A',
            500, 10, -20, -100, 480, 700,
        )
        lb = LayoutBox(g, 0.25, -0.1, 2.0)

        @test g.glyph_id === UInt32(42)
        @test g.font_path == FIXTURE_FONT_PATH
        @test g.font_slot === TeXLayout.FontSlot.Regular

        measured = TeXLayout.measure([lb], upm)
        @test measured.width ≈ 0.25 + 500 / upm * 2.0
        @test measured.ascent ≈ -0.1 + 700 / upm * 2.0
        @test measured.descent ≈ -(-0.1 + -100 / upm * 2.0)
    end

    @testset "HarfBuzzShaper extension" begin
        if Base.find_package("HarfBuzz_jll") === nothing
            @info "Skipping HarfBuzzShaper tests; HarfBuzz_jll is not in this environment"
        else
            @eval using HarfBuzz_jll

            shaper = TeXLayout.HarfBuzzShaper()
            full_family = font_family(:new_cm)
            span = TeXLayout.TextSpan(
                "office",
                TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0),
            )
            box = TeXLayout.shape_span(shaper, span, full_family, 1.0)

            @test box isa TeXLayout.TeXBox
            @test box.width > 0.0
            @test box.ascent > 0.0
            @test all(b.element isa GlyphID for b in box.boxes)
            @test all(b.element.font_path == full_family.regular for b in box.boxes)
            @test all(b.element.font_slot === TeXLayout.FontSlot.Regular for b in box.boxes)

            metric_box = TeXLayout.shape_span(TeXLayout.MetricShaper(), span, full_family, 1.0)
            @test all(b.element isa GlyphID for b in metric_box.boxes)

            math_default = TeXLayout.layout(
                parse_latex(raw"x+\text{office}"),
                full_family,
                TeXLayout.Text,
            )
            @test any(b.element isa Glyph for b in math_default)   # the math x and +
            # The default path does not shape: one regular-font glyph per character.
            default_text = filter(b -> b.element isa GlyphID, math_default)
            @test [b.element.represented_char for b in default_text] == collect("office")
            @test all(b.element.font_path == full_family.regular for b in default_text)

            math_hb = TeXLayout.layout(
                parse_latex(raw"x+\text{office}"),
                full_family,
                TeXLayout.Text;
                shaper = shaper,
            )
            text_glyphs = filter(b -> b.element isa GlyphID, math_hb)
            @test !isempty(text_glyphs)
            @test all(b.element.font_path == full_family.regular for b in text_glyphs)

            double = TeXLayout.shape_span(
                shaper,
                TeXLayout.TextSpan("office", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 2.0)),
                full_family,
                1.0,
            )
            @test double.width ≈ 2 * box.width

            @testset "small caps uses the OpenType smcp substitution" begin
                termes = font_family(:termes)
                normal_attrs = TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0)
                small_caps_attrs = TeXLayout.TextAttrs(
                    TeXLayout.FontSlot.Regular,
                    1.0,
                    TeXLayout.TextFeatures(true),
                )

                normal_lower = TeXLayout.shape_span(
                    shaper,
                    TeXLayout.TextSpan("a", normal_attrs),
                    termes,
                    1.0,
                )
                small_lower = TeXLayout.shape_span(
                    shaper,
                    TeXLayout.TextSpan("a", small_caps_attrs),
                    termes,
                    1.0,
                )
                normal_upper = TeXLayout.shape_span(
                    shaper,
                    TeXLayout.TextSpan("A", normal_attrs),
                    termes,
                    1.0,
                )
                small_upper = TeXLayout.shape_span(
                    shaper,
                    TeXLayout.TextSpan("A", small_caps_attrs),
                    termes,
                    1.0,
                )

                @test only(normal_lower.boxes).element.glyph_id !=
                    only(small_lower.boxes).element.glyph_id
                @test only(normal_upper.boxes).element.glyph_id ==
                    only(small_upper.boxes).element.glyph_id
                @test only(small_lower.boxes).element.represented_char == 'a'

                expr = raw"\text{\textsc{This text should be in small caps}}"
                small_math = TeXLayout.layout(
                    parse_latex(expr),
                    termes,
                    TeXLayout.Display;
                    shaper,
                )
                plain_math = TeXLayout.layout(
                    parse_latex(raw"\text{This text should be in small caps}"),
                    termes,
                    TeXLayout.Display;
                    shaper,
                )
                small_ids = [
                    b.element.glyph_id for b in small_math
                        if b.element isa GlyphID
                ]
                plain_ids = [
                    b.element.glyph_id for b in plain_math
                        if b.element isa GlyphID
                ]
                @test length(small_ids) == length(plain_ids)
                @test small_ids != plain_ids

                small_document = TeXLayout.layout_document(
                    raw"\textsc{This text should be in small caps}";
                    family = termes,
                    shaper,
                )
                plain_document = TeXLayout.layout_document(
                    "This text should be in small caps";
                    family = termes,
                    shaper,
                )
                document_small_ids = [
                    b.element.glyph_id for b in small_document.boxes
                        if b.element isa GlyphID
                ]
                document_plain_ids = [
                    b.element.glyph_id for b in plain_document.boxes
                        if b.element isa GlyphID
                ]
                @test length(document_small_ids) == length(document_plain_ids)
                @test document_small_ids != document_plain_ids
            end

            @testset "sans-serif and monospace families compose with text features" begin
                termes = font_family(:termes)
                sans_small = TeXLayout.layout_document(
                    raw"\textsc{\textsf{Small caps}}";
                    family = termes,
                    shaper,
                )
                sans_small_reversed = TeXLayout.layout_document(
                    raw"\textsf{\textsc{Small caps}}";
                    family = termes,
                    shaper,
                )
                mono = TeXLayout.layout_document(
                    raw"\texttt{Typewriter}";
                    family = termes,
                    shaper,
                )

                sans_glyphs = [
                    b.element for b in sans_small.boxes if b.element isa GlyphID
                ]
                reversed_glyphs = [
                    b.element for b in sans_small_reversed.boxes if b.element isa GlyphID
                ]
                mono_glyphs = [b.element for b in mono.boxes if b.element isa GlyphID]

                @test !isempty(sans_glyphs)
                @test !isempty(mono_glyphs)
                @test all(g.font_path == termes.sans.regular for g in sans_glyphs)
                @test all(g.font_path == termes.monospace.regular for g in mono_glyphs)
                @test getfield.(sans_glyphs, :glyph_id) ==
                    getfield.(reversed_glyphs, :glyph_id)

                title = TeXLayout.layout(
                    parse_latex(
                        raw"\text{\textsc{Small caps} and \textsf{sans serif font} and \textsc{\textsf{both combined!}}}",
                    ),
                    termes,
                    TeXLayout.Display;
                    shaper,
                )
                @test any(
                    b -> b.element isa GlyphID &&
                        b.element.font_path == termes.sans.regular,
                    title,
                )
            end
        end
    end

    @testset "Explicit spaces keep their width in styled and shaped math \\text" begin
        # Styled text (\textbf inside \text) and any non-metric shaper take the
        # shaping path, which used to turn \quad, \, and \kern into a single
        # interword space.  `{}` ends each control word without a space.
        last_x(source; kwargs...) = maximum(
            b.x for b in layout(parse_latex(source), family, Text; kwargs...)
                if b.element isa Union{Glyph, GlyphID}
        )
        for (space, width) in ((raw"\quad", 1.0), (raw"\,", 3 / 18), (raw"\kern2em", 2.0))
            @test last_x("\\text{\\textbf{a}" * space * "{}b}") - last_x(raw"\text{\textbf{a}b}") ≈ width
        end
        if Base.get_extension(TeXLayout, :HarfBuzzExt) !== nothing
            shaper = TeXLayout.HarfBuzzShaper()
            @test last_x(raw"\text{a\quad{}b}"; shaper) - last_x(raw"\text{a\,{}b}"; shaper) ≈ 1.0 - 3 / 18
        end
    end
end
