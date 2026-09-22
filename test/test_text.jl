# Tests for the text/paragraph layout layer (src/shaping.jl, src/document.jl,
# src/compose.jl) and supporting additions to src/fonts.jl and src/parser.jl.
#
# New symbols are accessed as TeXLayout.Xxx — no module-level `using` for the
# not-yet-existing names, so this file can be included without aborting the
# existing test suite while the implementation is in progress.
#
# Spec reference: text-spec.md §9 cases 1–10, plus unit tests for each new layer.

@testset "Text and document layout" begin

    family = FontFamily(FIXTURE_FONT_PATH)
    is_glyph_box(box) = box.element isa Glyph || box.element isa GlyphID

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
            @test any(b.element isa Glyph for b in math_default)
            @test !any(b.element isa GlyphID for b in math_default)

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

    # ── Parser additions ──────────────────────────────────────────────────────

    @testset "Parser additions" begin

        @testset "Brace-word leniency: space before { in \\end {align}" begin
            tree = parse_latex("\\begin{align}x\\end {align}")
            @test tree.kind === NodeKind.Sequence
            @test length(tree.children) == 1
            @test tree.children[1].kind === NodeKind.Matrix
        end

        @testset "align, aligned, gather registered in _MATRIX_ENVS" begin
            for env in ("align", "aligned", "gather")
                @test haskey(TeXLayout._MATRIX_ENVS, env)
            end
        end

        @testset "Align colspec: 2 columns → rl" begin
            tree = parse_latex("\\begin{align}x&=y\\\\a&=b\\end{align}")
            mat = tree.children[1]
            @test mat.kind === NodeKind.Matrix
            @test split(mat.value, "\x00")[3] == "rl"
        end

        @testset "Align inserts empty group before post-& cells" begin
            tree = parse_latex("\\begin{align}x&=y\\\\a&=b\\end{align}")
            mat = tree.children[1]
            @test length(mat.children) == 4
            for idx in (2, 4)
                first = mat.children[idx].children[1]
                @test first.kind === NodeKind.Group
                @test isempty(first.children)
            end
            @test mat.children[1].children[1].kind !== NodeKind.Group
            @test mat.children[3].children[1].kind !== NodeKind.Group
        end

        @testset "Align colspec: 4 columns → rlrl" begin
            tree = parse_latex("\\begin{align}a&b&c&d\\end{align}")
            mat = tree.children[1]
            @test mat.kind === NodeKind.Matrix
            @test split(mat.value, "\x00")[3] == "rlrl"
        end

        @testset "Gather colspec: 1 column → c" begin
            tree = parse_latex("\\begin{gather}x\\\\y\\end{gather}")
            mat = tree.children[1]
            @test mat.kind === NodeKind.Matrix
            @test split(mat.value, "\x00")[3] == "c"
        end

        @testset "parse_environment! returns NodeKind.Matrix for align" begin
            # Parser positioned just after {align} — body starts here.
            toks = tokenize("x&=y\\end{align}")
            p = TeXLayout._Parser(toks, 1)
            node = TeXLayout.parse_environment!(p, "align")
            @test node.kind === NodeKind.Matrix
        end

        @testset "_parse_math_until_shift! stops before TokenKind.MathShift" begin
            toks = tokenize("x^2\$rest")
            p = TeXLayout._Parser(toks, 1)
            node = TeXLayout._parse_math_until_shift!(p)
            @test node.kind === NodeKind.Sequence
            @test length(node.children) >= 1
            # Dollar sign not consumed — still current.
            @test TeXLayout._current(p).kind === TokenKind.MathShift
        end

        @testset "_parse_math_until_shift! stops at EOF" begin
            toks = tokenize("x+1")
            p = TeXLayout._Parser(toks, 1)
            node = TeXLayout._parse_math_until_shift!(p)
            @test node.kind === NodeKind.Sequence
            @test !isempty(node.children)
            @test TeXLayout._current(p).kind === TokenKind.EOF
        end
    end

    # ── Document parser ───────────────────────────────────────────────────────

    @testset "Document parser" begin

        @testset "Plain text → one ParagraphBlock with one TextRun" begin
            doc = TeXLayout.parse_document("abc")
            @test length(doc) == 1
            @test doc[1] isa TeXLayout.ParagraphBlock
            @test length(doc[1].lines) == 1
            runs = doc[1].lines[1].runs
            @test length(runs) == 1
            @test runs[1] isa TeXLayout.TextRun
            spans = runs[1].spans
            @test length(spans) == 1
            @test spans[1].text == "abc"
            @test spans[1].attrs.slot === TeXLayout.FontSlot.Regular
        end

        @testset "Line break splits into two lines" begin
            doc = TeXLayout.parse_document("a\\\\b")
            @test length(doc) == 1
            @test doc[1] isa TeXLayout.ParagraphBlock
            @test length(doc[1].lines) == 2
            @test doc[1].lines[1].runs[1].spans[1].text == "a"
            @test doc[1].lines[2].runs[1].spans[1].text == "b"
        end

        @testset "Trailing line break: empty last line dropped" begin
            doc = TeXLayout.parse_document("a\\\\")
            @test length(doc[1].lines) == 1
        end

        @testset "\\textbf produces Bold span" begin
            doc = TeXLayout.parse_document("\\textbf{hello}")
            spans = doc[1].lines[1].runs[1].spans
            @test spans[1].text == "hello"
            @test spans[1].attrs.slot === TeXLayout.FontSlot.Bold
        end

        @testset "\\textit produces Italic span" begin
            doc = TeXLayout.parse_document("\\textit{hello}")
            spans = doc[1].lines[1].runs[1].spans
            @test spans[1].text == "hello"
            @test spans[1].attrs.slot === TeXLayout.FontSlot.Italic
        end

        @testset "\\textsc produces a small-caps span" begin
            doc = TeXLayout.parse_document("\\textsc{hello}")
            spans = doc[1].lines[1].runs[1].spans
            @test spans[1].text == "hello"
            @test spans[1].attrs.slot === TeXLayout.FontSlot.Regular
            @test spans[1].attrs.features.small_caps
        end

        @testset "small caps composes with font slots and restores after its group" begin
            doc = TeXLayout.parse_document("\\textbf{A\\textsc{b}C}")
            spans = doc[1].lines[1].runs[1].spans
            @test getfield.(spans, :text) == ["A", "b", "C"]
            @test all(span.attrs.slot === TeXLayout.FontSlot.Bold for span in spans)
            @test !spans[1].attrs.features.small_caps
            @test spans[2].attrs.features.small_caps
            @test !spans[3].attrs.features.small_caps
        end

        @testset "\\textnormal resets small caps inside its group" begin
            doc = TeXLayout.parse_document("\\textsc{a\\textnormal{b}c}")
            spans = doc[1].lines[1].runs[1].spans
            @test getfield.(spans, :text) == ["a", "b", "c"]
            @test spans[1].attrs.features.small_caps
            @test !spans[2].attrs.features.small_caps
            @test spans[3].attrs.features.small_caps
        end

        @testset "family commands preserve weight and features" begin
            doc = TeXLayout.parse_document("\\textbf{\\textrm{x}}")
            span = only(doc[1].lines[1].runs[1].spans)
            @test span.attrs.family === TeXLayout.TextFamily.Roman
            @test span.attrs.slot === TeXLayout.FontSlot.Bold

            cases = (
                ("\\textsf", TeXLayout.TextFamily.Sans),
                ("\\texttt", TeXLayout.TextFamily.Monospace),
            )
            for (cmd, expected_family) in cases
                styled = TeXLayout.parse_document("\\textsc{\\textbf{$cmd{x}}}")
                styled_span = only(styled[1].lines[1].runs[1].spans)
                @test styled_span.attrs.family === expected_family
                @test styled_span.attrs.slot === TeXLayout.FontSlot.Bold
                @test styled_span.attrs.features.small_caps
            end
        end

        @testset "independent text styles commute and restore their scopes" begin
            left = TeXLayout.parse_document("\\textsc{\\textsf{x}}y")
            right = TeXLayout.parse_document("\\textsf{\\textsc{x}}y")
            left_spans = left[1].lines[1].runs[1].spans
            right_spans = right[1].lines[1].runs[1].spans
            @test left_spans[1].attrs == right_spans[1].attrs
            @test left_spans[1].attrs.family === TeXLayout.TextFamily.Sans
            @test left_spans[1].attrs.features.small_caps
            @test left_spans[2].attrs.family === TeXLayout.TextFamily.Roman
            @test !left_spans[2].attrs.features.small_caps
        end

        @testset "\\emph toggles italic" begin
            doc1 = TeXLayout.parse_document("\\emph{x}")
            sp1 = vcat(
                [r.spans for r in doc1[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test any(s -> s.text == "x" && s.attrs.slot === TeXLayout.FontSlot.Italic, sp1)

            # \\emph inside \\textit toggles back to Regular.
            doc2 = TeXLayout.parse_document("\\textit{\\emph{x}}")
            sp2 = vcat(
                [r.spans for r in doc2[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test any(s -> s.text == "x" && s.attrs.slot === TeXLayout.FontSlot.Regular, sp2)
        end

        @testset "\\textbf{a\\textit{b}} -> Bold + BoldItalic spans" begin
            doc = TeXLayout.parse_document("\\textbf{a\\textit{b}}")
            all_spans = vcat(
                [r.spans for r in doc[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test any(s -> s.text == "a" && s.attrs.slot === TeXLayout.FontSlot.Bold, all_spans)
            @test any(s -> s.text == "b" && s.attrs.slot === TeXLayout.FontSlot.BoldItalic, all_spans)
        end

        @testset "Inline math inside text style preserves surrounding attributes" begin
            doc = TeXLayout.parse_document("\\textbf{a \$x\$ b}")
            runs = doc[1].lines[1].runs
            @test length(runs) == 3
            @test runs[1] isa TeXLayout.TextRun
            @test runs[2] isa TeXLayout.MathRun
            @test runs[3] isa TeXLayout.TextRun
            @test all(s.attrs.slot === TeXLayout.FontSlot.Bold for s in runs[1].spans)
            @test all(s.attrs.slot === TeXLayout.FontSlot.Bold for s in runs[3].spans)
            @test runs[2].style === Text
        end

        @testset "Inline math produces MathRun with Text style" begin
            doc = TeXLayout.parse_document("x is \$x^2\$ here")
            runs = doc[1].lines[1].runs
            math_runs = filter(r -> r isa TeXLayout.MathRun, runs)
            @test length(math_runs) == 1
            @test math_runs[1].style === Text   # TeXLayout.Text alias from runtests.jl
            @test math_runs[1].node.kind === NodeKind.Sequence
        end

        @testset "\\(…\\) is inline math" begin
            doc = TeXLayout.parse_document("a \\(x^2\\) b")
            runs = doc[1].lines[1].runs
            math_runs = filter(r -> r isa TeXLayout.MathRun, runs)
            @test length(math_runs) == 1
            @test math_runs[1].style === Text
            @test math_runs[1].node.children[1].kind === NodeKind.Superscript
        end

        @testset "\$\$…\$\$ is a display block (script preserved)" begin
            doc = TeXLayout.parse_document("Disp \$\$x^2\$\$ end.")
            @test length(doc) == 3
            @test doc[1] isa TeXLayout.ParagraphBlock
            @test doc[2] isa TeXLayout.DisplayBlock
            @test doc[2].kind === :displaymath
            @test doc[2].node.kind === NodeKind.Sequence
            @test doc[2].node.children[1].kind === NodeKind.Superscript
            @test doc[3] isa TeXLayout.ParagraphBlock
        end

        @testset "\\[…\\] is a display block" begin
            doc = TeXLayout.parse_document("Disp \\[x^2\\] end.")
            @test length(doc) == 3
            @test doc[2] isa TeXLayout.DisplayBlock
            @test doc[2].kind === :displaymath
            @test doc[2].node.children[1].kind === NodeKind.Superscript
        end

        @testset "Style declarations preserve inline-math boundaries" begin
            for source in (
                    raw"before $\displaystyle x$ after",
                    raw"before \(\displaystyle x\) after",
                )
                doc = TeXLayout.parse_document(source)
                @test length(doc) == 1
                runs = only(doc).lines[1].runs
                @test length(runs) == 3
                @test runs[1] isa TeXLayout.TextRun
                @test runs[2] isa TeXLayout.MathRun
                @test runs[3] isa TeXLayout.TextRun
                @test only(runs[1].spans).text == "before "
                @test only(runs[3].spans).text == " after"

                style = only(runs[2].node.children)
                @test style.kind === NodeKind.StyleOverride
                @test only(style.children).children[1].value == "x"
            end
        end

        @testset "Style declarations preserve display-math boundaries" begin
            for source in (
                    raw"before $$\displaystyle x$$ after",
                    raw"before \[\displaystyle x\] after",
                )
                doc = TeXLayout.parse_document(source)
                @test length(doc) == 3
                @test doc[1] isa TeXLayout.ParagraphBlock
                @test doc[2] isa TeXLayout.DisplayBlock
                @test doc[3] isa TeXLayout.ParagraphBlock
                @test only(doc[1].lines[1].runs[1].spans).text == "before"
                @test only(doc[3].lines[1].runs[1].spans).text == "after"

                style = only(doc[2].node.children)
                @test style.kind === NodeKind.StyleOverride
                @test only(style.children).children[1].value == "x"
            end
        end

        @testset "Sizing declarations preserve inline-math boundaries" begin
            doc = TeXLayout.parse_document(raw"before $\large x$ after")
            runs = only(doc).lines[1].runs
            @test length(runs) == 3
            @test runs[2] isa TeXLayout.MathRun
            @test only(runs[2].node.children).kind === NodeKind.Sizing
            @test only(runs[3].spans).text == " after"
        end

        @testset "\$ \$ (spaced) stays inline, not display" begin
            doc = TeXLayout.parse_document("a \$ \$ b")
            @test all(blk -> blk isa TeXLayout.ParagraphBlock, doc)
            @test any(r -> r isa TeXLayout.MathRun, doc[1].lines[1].runs)
        end

        @testset "\$\$ inside a text group does not open a display block" begin
            doc = TeXLayout.parse_document("\\textbf{a \$x\$ b}")
            @test all(blk -> blk isa TeXLayout.ParagraphBlock, doc)
        end

        @testset "^, _, & render as literal text outside math" begin
            doc = TeXLayout.parse_document("a^b_c&d")
            spans = vcat(
                [r.spans for r in doc[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test join(sp.text for sp in spans) == "a^b_c&d"
        end

        @testset "Blank line creates paragraph break block" begin
            doc = TeXLayout.parse_document("a\n\nb")
            @test length(doc) == 3
            @test doc[1] isa TeXLayout.ParagraphBlock
            @test doc[2] isa TeXLayout.ParagraphBreakBlock
            @test doc[3] isa TeXLayout.ParagraphBlock

            doc2 = TeXLayout.parse_document("\n\na\n\n")
            @test length(doc2) == 1
            @test doc2[1] isa TeXLayout.ParagraphBlock
        end

        @testset "Display align block parsed as DisplayBlock" begin
            doc = TeXLayout.parse_document("\\begin{align}x&=y\\end{align}")
            @test length(doc) == 1
            @test doc[1] isa TeXLayout.DisplayBlock
            @test doc[1].kind === :align
            @test doc[1].node.kind === NodeKind.Matrix
        end

        @testset "Adjacent display blocks parse without synthetic paragraph" begin
            doc = TeXLayout.parse_document(
                "\\begin{equation}x\\end{equation}\\begin{equation}y\\end{equation}",
            )
            @test length(doc) == 2
            @test all(blk -> blk isa TeXLayout.DisplayBlock, doc)
        end

        @testset "Display at start and end preserves neighbouring paragraphs" begin
            start_doc = TeXLayout.parse_document("\\begin{equation}x\\end{equation}tail")
            @test length(start_doc) == 2
            @test start_doc[1] isa TeXLayout.DisplayBlock
            @test start_doc[2] isa TeXLayout.ParagraphBlock
            @test start_doc[2].lines[1].runs[1].spans[1].text == "tail"

            end_doc = TeXLayout.parse_document("head\\begin{equation}x\\end{equation}")
            @test length(end_doc) == 2
            @test end_doc[1] isa TeXLayout.ParagraphBlock
            @test end_doc[2] isa TeXLayout.DisplayBlock
            @test end_doc[1].lines[1].runs[1].spans[1].text == "head"
        end

        @testset "Unknown environment in text mode is lenient" begin
            @test_nowarn TeXLayout.parse_document("\\begin{unknown}x\\end{unknown}")
            doc = TeXLayout.parse_document("\\begin{unknown}x\\end{unknown}")
            @test !isempty(doc)
            @test doc[1] isa TeXLayout.ParagraphBlock
        end

        @testset "The worked example: document structure (spec §3 worked example)" begin
            src = "\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"
            doc = TeXLayout.parse_document(src)

            # Two blocks: paragraph then display.
            @test length(doc) == 2
            @test doc[1] isa TeXLayout.ParagraphBlock
            @test length(doc[1].lines) == 1

            # Spans in the text line.
            all_spans = vcat(
                [r.spans for r in doc[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test any(s -> s.text == "Hello" && s.attrs.slot === TeXLayout.FontSlot.Bold, all_spans)
            @test any(s -> occursin("world", s.text) && s.attrs.slot === TeXLayout.FontSlot.Regular, all_spans)

            # Display block: 2-row align with "rl" colspec.
            @test doc[2] isa TeXLayout.DisplayBlock
            @test doc[2].kind === :align
            mat = doc[2].node
            @test mat.kind === NodeKind.Matrix
            parts = split(mat.value, "\x00")
            @test parse(Int, parts[2]) == 2
            @test parts[3] == "rl"
        end

        @testset "Lenience: unclosed dollar does not throw" begin
            @test_nowarn TeXLayout.parse_document("\$unclosed math")
            doc = TeXLayout.parse_document("\$unclosed math")
            @test !isempty(doc)
        end

        @testset "Lenience: trailing line break does not throw" begin
            @test_nowarn TeXLayout.parse_document("a\\\\")
        end

        @testset "Lenience: unknown command is ignored" begin
            @test_nowarn TeXLayout.parse_document("hello \\unknowncmd world")
            doc = TeXLayout.parse_document("hello \\unknowncmd world")
            @test !isempty(doc)
            @test doc[1] isa TeXLayout.ParagraphBlock
        end
    end

    # ── Composition primitives ────────────────────────────────────────────────

    @testset "Composition primitives" begin

        @testset "hconcat: empty input → zero TeXBox" begin
            result = TeXLayout.hconcat(TeXLayout.TeXBox[])
            @test result.width == 0.0
            @test result.ascent == 0.0
            @test result.descent == 0.0
            @test isempty(result.boxes)
        end

        @testset "hconcat: width = sum, extents = max of parts" begin
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.8, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.5, 0.9, 0.3)
            result = TeXLayout.hconcat([b1, b2])
            @test result.width ≈ 2.5
            @test result.ascent ≈ 0.9
            @test result.descent ≈ 0.3
        end

        @testset "hconcat: second-part boxes are shifted right by first width" begin
            lb = LayoutBox(Space(0.5), 0.0, 0.0, 1.0)
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.5, 0.1)
            b2 = TeXLayout.TeXBox([lb], 0.5, 0.5, 0.1)
            result = TeXLayout.hconcat([b1, b2])
            @test result.boxes[1].x ≈ 1.0
        end

        @testset "Internal HBox shapes children with horizontal advances" begin
            lb = LayoutBox(Space(0.5), 0.0, 0.0, 1.0)
            empty = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            visible = TeXLayout.ShapedBox([lb], 0.5, 0.5, 0.1)
            tree = TeXLayout.HBox([empty, visible])
            boxes = TeXLayout.shape(tree)
            @test tree.width ≈ 1.5
            @test length(boxes) == 1
            @test boxes[1].x ≈ 1.0
        end

        @testset "Internal boxes validate measured extents" begin
            leaf = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.ShapedBox(LayoutBox[], -1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.ShapedBox(LayoutBox[], 1.0, NaN, 0.1)
            @test_throws ArgumentError TeXLayout.HBox([leaf], 1.0, 0.5, -0.1)
            @test_throws ArgumentError TeXLayout.VBox([leaf], [0.0], Float64[], 1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.VBox([leaf], [Inf], [0.0], 1.0, 0.5, 0.1)
        end

        @testset "Internal boxes copy caller-owned vectors" begin
            lb = LayoutBox(Space(0.5), 0.25, 0.0, 1.0)
            shaped_source = [lb]
            shaped = TeXLayout.ShapedBox(shaped_source, 0.5, 0.5, 0.1)
            empty!(shaped_source)
            @test length(TeXLayout.shape(shaped)) == 1

            child_source = TeXLayout.Box[shaped]
            tree = TeXLayout.HBox(child_source)
            empty!(child_source)
            boxes = TeXLayout.shape(tree)
            @test length(boxes) == 1
            @test boxes[1].x ≈ 0.25
        end

        @testset "Internal nested boxes compose offsets recursively" begin
            lb = LayoutBox(Space(0.5), 0.25, 0.5, 1.0)
            empty = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            visible = TeXLayout.ShapedBox([lb], 0.5, 0.5, 0.1)
            row = TeXLayout.HBox([empty, visible])
            column = TeXLayout.VBox([row], [-2.0], [3.0], row.width, row.ascent, 2.0)
            boxes = TeXLayout.shape(column)
            @test length(boxes) == 1
            @test boxes[1].x ≈ 4.25
            @test boxes[1].y ≈ -1.5
        end

        @testset "vstack: empty input → zero TeXBox" begin
            result = TeXLayout.vstack(
                TeXLayout.TeXBox[];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> :left,
            )
            @test result.width == 0.0
            @test result.ascent == 0.0
            @test result.descent == 0.0
        end

        @testset "vstack: single item is a passthrough" begin
            b = TeXLayout.TeXBox(LayoutBox[], 2.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.width ≈ 2.0
            @test result.ascent ≈ 0.7
            @test result.descent ≈ 0.2
        end

        @testset "vstack: advance capped to line_height for short lines" begin
            # depth(b1) + ascent(b2) + lineskip = 0.2 + 0.7 + 0.1 = 1.0 < 1.2
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b1, b2]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.ascent ≈ 0.7
            @test result.descent ≈ 1.4   # advance 1.2 + b2.descent 0.2
        end

        @testset "vstack: tall line forces lineskip advance > line_height" begin
            # depth(b_tall) + ascent(b_next) + lineskip = 1.0 + 1.5 + 0.1 = 2.6 > 1.2
            b_tall = TeXLayout.TeXBox(LayoutBox[], 1.0, 1.5, 1.0)
            b_next = TeXLayout.TeXBox(LayoutBox[], 1.0, 1.5, 0.2)
            result = TeXLayout.vstack(
                [b_tall, b_next];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> :left,
            )
            @test result.descent ≈ 2.8   # advance 2.6 + b_next.descent 0.2
        end

        @testset "vstack: width is max of item natural widths" begin
            b1 = TeXLayout.TeXBox(LayoutBox[], 3.0, 0.7, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b1, b2]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.width ≈ 3.0
        end

        @testset "vstack: fixed width overrides natural width" begin
            b = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b]; line_height = 1.2, lineskip = 0.1, width = 10.0, align_of = i -> :left,
            )
            @test result.width ≈ 10.0
        end

        @testset "vstack: right alignment shifts narrow item" begin
            lb = LayoutBox(Space(1.0), 0.0, 0.0, 1.0)
            wide = TeXLayout.TeXBox(LayoutBox[], 3.0, 0.7, 0.2)
            narrow = TeXLayout.TeXBox([lb], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [wide, narrow];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> (i == 2 ? :right : :left),
            )
            # The Space box (at local x=0) must be shifted right by (3.0 - 1.0) = 2.0.
            @test result.boxes[1].x ≈ 2.0
        end

        @testset "vstack: center alignment shifts narrow item" begin
            lb = LayoutBox(Space(1.0), 0.0, 0.0, 1.0)
            wide = TeXLayout.TeXBox(LayoutBox[], 4.0, 0.7, 0.2)
            narrow = TeXLayout.TeXBox([lb], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [wide, narrow];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> (i == 2 ? :center : :left),
            )
            # Centred shift = (4.0 - 1.0) / 2 = 1.5.
            @test result.boxes[1].x ≈ 1.5
        end
    end

    # ── layout_document integration ───────────────────────────────────────────

    @testset "layout_document integration" begin

        @testset "LayoutOptions defaults" begin
            opts = TeXLayout.LayoutOptions()
            @test opts.align === TeXLayout.Alignment.Left
            @test opts.line_height ≈ 1.2
            @test opts.lineskip ≈ 0.1
            @test opts.width === nothing
            @test opts.display_align === TeXLayout.Alignment.Center
            @test opts.abovedisplayskip ≈ 0.5
            @test opts.belowdisplayskip ≈ 0.5
            @test opts.parskip ≈ 0.6
            @test opts.shaper isa TeXLayout.MetricShaper
        end

        @testset "Session-wide default layout options" begin
            saved = TeXLayout.default_layout_options()
            try
                @test TeXLayout.default_layout_options() isa TeXLayout.LayoutOptions

                # Keyword form overrides only the named fields (merge).
                TeXLayout.set_default_layout_options!(width = 30.0, display_align = :right)
                cur = TeXLayout.default_layout_options()
                @test cur.width == 30.0
                @test cur.display_align === TeXLayout.Alignment.Right
                @test cur.align === TeXLayout.Alignment.Left      # untouched
                @test cur.parskip ≈ 0.6                           # untouched

                # layout_document picks up the global default.
                doc = TeXLayout.layout_document("hi \$x\$"; family = family)
                @test doc.width ≈ 30.0

                # Per-call kwargs override the global for that call only.
                doc2 = TeXLayout.layout_document("hi \$x\$"; family = family, width = 10.0)
                @test doc2.width ≈ 10.0
                @test TeXLayout.default_layout_options().width == 30.0

                # Positional form replaces wholesale (factory reset).
                TeXLayout.set_default_layout_options!(TeXLayout.LayoutOptions())
                @test TeXLayout.default_layout_options().width === nothing

                # Unknown option name is rejected.
                @test_throws ArgumentError TeXLayout.set_default_layout_options!(widht = 1.0)
            finally
                TeXLayout.set_default_layout_options!(saved)
            end
        end

        @testset "Case 1: plain text, glyphs at y=0, ascent > 0" begin
            result = TeXLayout.layout_document("abc"; family = family)
            @test result isa TeXLayout.TeXBox
            @test result.ascent > 0.0
            @test result.descent >= 0.0
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 3
            @test all(b.y ≈ 0.0 for b in glyphs)
            @test glyphs[1].x ≈ 0.0
        end

        @testset "Case 2: line break → second baseline ≈ -1.2" begin
            result = TeXLayout.layout_document("a\\\\b"; family = family)
            glyphs = sort(
                filter(is_glyph_box, result.boxes);
                by = b -> b.y,
                rev = true,
            )
            @test length(glyphs) == 2
            @test glyphs[1].y ≈ 0.0
            @test glyphs[2].y ≈ -1.2   atol = 0.1
        end

        @testset "Blank line applies paragraph skip" begin
            line_result = TeXLayout.layout_document("a\\\\b"; family = family)
            para_result = TeXLayout.layout_document("a\n\nb"; family = family)

            line_ys = sort(
                unique(round(b.y; digits = 6) for b in line_result.boxes if is_glyph_box(b));
                rev = true,
            )
            para_ys = sort(
                unique(round(b.y; digits = 6) for b in para_result.boxes if is_glyph_box(b));
                rev = true,
            )
            @test length(line_ys) == 2
            @test length(para_ys) == 2
            @test line_ys[1] - line_ys[2] ≈ 1.2 atol = 0.1
            @test para_ys[1] - para_ys[2] ≈ 1.8 atol = 0.1

            custom = TeXLayout.layout_document("a\n\nb"; family = family, parskip = 0.25)
            custom_ys = sort(
                unique(round(b.y; digits = 6) for b in custom.boxes if is_glyph_box(b));
                rev = true,
            )
            @test custom_ys[1] - custom_ys[2] ≈ 1.45 atol = 0.1
        end

        @testset "Case 3: tall line forces advance > line_height" begin
            result = TeXLayout.layout_document("\$\\dfrac{a}{b}\$\\\\x"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test minimum(b.y for b in glyphs) < -1.2
        end

        @testset "Case 4: right alignment shifts narrow second line" begin
            result = TeXLayout.layout_document(
                "long text here\\\\x"; family = family, align = :right,
            )
            glyphs = filter(is_glyph_box, result.boxes)
            line2_glyphs = filter(b -> b.y < -0.5, glyphs)
            @test !isempty(line2_glyphs)
            @test minimum(b.x for b in line2_glyphs) > 0.0
        end

        @testset "Case 5: fixed width respected" begin
            result = TeXLayout.layout_document("abc"; family = family, width = 10.0)
            @test result.width ≈ 10.0
        end

        @testset "Case 6: inline math — superscript present, shared baseline" begin
            result = TeXLayout.layout_document("x is \$x^2\$ here"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) > 3
            # Math superscript must be above the baseline.
            @test maximum(b.y for b in glyphs) > 0.0
        end

        @testset "Case 8 (partial): display block appears below text line" begin
            result = TeXLayout.layout_document(
                "text\\\\\\begin{align}x&=y\\end{align}"; family = family,
            )
            @test !isempty(result.boxes)
            @test minimum(b.y for b in result.boxes) < 0.0
        end

        @testset "Case 8: worked example lays out without error" begin
            src = "\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"
            result = TeXLayout.layout_document(src; family = family)
            @test !isempty(result.boxes)
            @test minimum(b.y for b in result.boxes) < 0.0
        end

        @testset "Display-only document does not start with an empty baseline" begin
            full_family = font_family(:new_cm)
            result = TeXLayout.layout_document("\\begin{equation}x\\end{equation}"; family = full_family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 1
            @test abs(glyphs[1].y) < 0.2
            @test result.descent < 1.0
        end

        @testset "Display skips are explicit extra space, not synthetic lines" begin
            full_family = font_family(:new_cm)
            src = "\\begin{equation}x\\end{equation}b"
            no_skip = TeXLayout.layout_document(
                src; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.0,
            )
            below_skip = TeXLayout.layout_document(
                src; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.5,
            )

            function first_regular_y(box)
                glyphs = filter(
                    b -> is_glyph_box(b) &&
                        b.element.font_slot === TeXLayout.FontSlot.Regular,
                    box.boxes,
                )
                @test length(glyphs) == 1
                return glyphs[1].y
            end

            @test first_regular_y(below_skip) ≈ first_regular_y(no_skip) - 0.5

            src2 = "a\\begin{equation}x\\end{equation}"
            no_above = TeXLayout.layout_document(
                src2; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.0,
            )
            with_above = TeXLayout.layout_document(
                src2; family = full_family, abovedisplayskip = 0.5, belowdisplayskip = 0.0,
            )

            function first_math_y(box)
                glyphs = filter(
                    b -> b.element isa Glyph &&
                        b.element.font_slot === TeXLayout.FontSlot.Math,
                    box.boxes,
                )
                @test length(glyphs) == 1
                return glyphs[1].y
            end

            @test first_math_y(with_above) ≈ first_math_y(no_above) - 0.5
        end

        @testset "Adjacent display blocks stack below the first display" begin
            full_family = font_family(:new_cm)
            result = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}\\begin{equation}y\\end{equation}";
                family = full_family,
            )
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 2
            ys = sort([b.y for b in glyphs]; rev = true)
            @test abs(ys[1]) < 0.2
            @test ys[2] < ys[1] - 1.0
        end

        @testset "Display alignment shifts narrow display inside fixed width" begin
            full_family = font_family(:new_cm)
            left = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :left,
            )
            center = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :center,
            )
            right = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :right,
            )

            first_x(box) = only(filter(is_glyph_box, box.boxes)).x
            @test left.width ≈ 12.0
            @test center.width ≈ 12.0
            @test right.width ≈ 12.0
            @test first_x(left) < first_x(center) < first_x(right)
        end

        @testset "Fixed width smaller than content allows overflow but reports requested width" begin
            result = TeXLayout.layout_document(
                "wide text line"; family = family, width = 0.5, align = :center,
            )
            @test result.width ≈ 0.5
            @test minimum(b.x for b in result.boxes if is_glyph_box(b)) < 0.0
        end

        @testset "Case 9: first line glyphs have y ≈ 0 (y-origin invariant)" begin
            result = TeXLayout.layout_document("Hello world"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test !isempty(glyphs)
            @test all(b.y ≈ 0.0 for b in glyphs)
        end

        @testset "Case 10: lenience — unclosed dollar" begin
            @test_nowarn TeXLayout.layout_document("\$unclosed"; family = family)
        end

        @testset "Case 10: lenience — trailing line break" begin
            @test_nowarn TeXLayout.layout_document("a\\\\"; family = family)
        end

        @testset "Case 10: lenience — unknown command" begin
            @test_nowarn TeXLayout.layout_document("\\unknown"; family = family)
        end

        @testset "Empty document returns empty TeXBox" begin
            result = TeXLayout.layout_document(""; family = family)
            @test result.width == 0.0
        end
    end

    # ── Whitespace and comment conventions (document parser) ───────────────────

    @testset "Whitespace conventions in parse_document" begin
        # Concatenate all TextRun span texts of the first ParagraphBlock.
        function para_text(input)
            doc = TeXLayout.parse_document(input)
            blk = doc[findfirst(b -> b isa TeXLayout.ParagraphBlock, doc)]
            buf = IOBuffer()
            for line in blk.lines, run in line.runs
                run isa TeXLayout.TextRun || continue
                for sp in run.spans
                    write(buf, sp.text)
                end
            end
            return String(take!(buf))
        end

        @testset "Single newline becomes one space" begin
            @test para_text("line one\nline two") == "line one line two"
        end

        @testset "Indentation on a continuation line collapses to one space" begin
            @test para_text("line one\n      line two") == "line one line two"
        end

        @testset "Leading whitespace at document start is dropped" begin
            @test para_text("   leading text") == "leading text"
        end

        @testset "Trailing whitespace before a block boundary is dropped" begin
            doc = TeXLayout.parse_document("para one\n\npara two")
            paras = filter(b -> b isa TeXLayout.ParagraphBlock, doc)
            @test length(paras) == 2
            text(b) = join(
                sp.text for l in b.lines for r in l.runs
                    if r isa TeXLayout.TextRun for sp in r.spans
            )
            @test text(paras[1]) == "para one"
            @test text(paras[2]) == "para two"
        end

        @testset "Whitespace around a display block is trimmed" begin
            doc = TeXLayout.parse_document("before text\n  \\begin{equation}\n x \\end{equation}\n  after text")
            paras = filter(b -> b isa TeXLayout.ParagraphBlock, doc)
            text(b) = join(
                sp.text for l in b.lines for r in l.runs
                    if r isa TeXLayout.TextRun for sp in r.spans
            )
            @test text(paras[1]) == "before text"
            @test text(paras[2]) == "after text"
        end

        @testset "Spaces inside a group are significant" begin
            @test para_text("a {b} c") == "a b c"
            @test para_text("x \\textbf{y} z") == "x y z"
        end

        @testset "Space around inline math is preserved" begin
            doc = TeXLayout.parse_document("text \$x\$ more")
            runs = doc[1].lines[1].runs
            texts = [
                r isa TeXLayout.TextRun ? join(sp.text for sp in r.spans) : "<math>"
                    for r in runs
            ]
            @test texts == ["text ", "<math>", " more"]
        end

        @testset "Comment suppresses the line break and indent" begin
            @test para_text("foo%comment\n  bar") == "foobar"
        end

        @testset "Space before a comment is preserved" begin
            @test para_text("foo %comment\nbar") == "foo bar"
        end

        @testset "Comment before a blank line keeps the paragraph break" begin
            doc = TeXLayout.parse_document("a%\n\nb")
            paras = filter(b -> b isa TeXLayout.ParagraphBlock, doc)
            @test length(paras) == 2
        end

        @testset "Escaped specials and text literal aliases render literally" begin
            cases = (
                raw"\#" => "#",
                raw"\$" => "\$",
                raw"\%" => "%",
                raw"\&" => "&",
                raw"\_" => "_",
                raw"\{" => "{",
                raw"\}" => "}",
                raw"\textdollar" => "\$",
                raw"\textunderscore" => "_",
                raw"\textbraceleft" => "{",
                raw"\textbraceright" => "}",
                raw"\textasciitilde" => "~",
                raw"\textbackslash" => "\\",
                raw"\textasciicircum" => "^",
                raw"\textbar" => "|",
                raw"\textbardbl" => "‖",
            )
            for (source, expected) in cases
                @test para_text(source) == expected
                @test para_text("\\textbf{" * source * "}") == expected
            end
        end

        @testset "Non-breaking space ~ renders as a single inter-word space" begin
            @test para_text("Fig.~3") == "Fig. 3"
            @test para_text("a~b") == "a b"
            @test para_text("a ~ b") == "a b"   # collapses with adjacent spaces
        end

        @testset "Non-breaking space ~ is not trimmed at boundaries" begin
            # Unlike ordinary whitespace, a ~ survives leading/trailing trimming.
            @test para_text("~x") == " x"
            @test para_text("x~") == "x "
        end

        @testset "Non-breaking space ~ survives an explicit line break" begin
            doc = TeXLayout.parse_document("a~\\\\~b")
            line_text(l) = join(
                sp.text for r in l.runs
                    if r isa TeXLayout.TextRun for sp in r.spans
            )
            lines = doc[1].lines
            @test length(lines) == 2
            @test line_text(lines[1]) == "a "
            @test line_text(lines[2]) == " b"
        end
    end

end
