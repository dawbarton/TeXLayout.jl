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

    @testset "_font_upm returns correct UPM for fixture font" begin
        upm = TeXLayout._font_upm(FIXTURE_FONT_PATH)
        @test upm isa Float64
        @test upm == Float64(FONT_UPM)
    end

    # ── Shaping ───────────────────────────────────────────────────────────────

    @testset "MetricShaper" begin
        shaper = TeXLayout.MetricShaper()

        @testset "Glyph x-positions advance left to right" begin
            span = TeXLayout.TextSpan("abc", TeXLayout.TextAttrs(TeXLayout.FontSlot.Regular, 1.0))
            box = TeXLayout.shape_span(shaper, span, family, 1.0)
            @test box isa TeXLayout.TeXBox
            @test length(box.boxes) == 3
            @test box.boxes[1].x ≈ 0.0
            @test box.boxes[2].x > 0.0
            @test box.boxes[3].x > box.boxes[2].x
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

        @testset "\\textrm inside \\textbf resets slot to Regular" begin
            doc = TeXLayout.parse_document("\\textbf{\\textrm{x}}")
            all_spans = vcat(
                [r.spans for r in doc[1].lines[1].runs if r isa TeXLayout.TextRun]...,
            )
            @test any(s -> s.text == "x" && s.attrs.slot === TeXLayout.FontSlot.Regular, all_spans)
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

        @testset "Display align block parsed as DisplayBlock" begin
            doc = TeXLayout.parse_document("\\begin{align}x&=y\\end{align}")
            @test length(doc) == 1
            @test doc[1] isa TeXLayout.DisplayBlock
            @test doc[1].kind === :align
            @test doc[1].node.kind === NodeKind.Matrix
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
            @test opts.shaper isa TeXLayout.MetricShaper
        end

        @testset "Case 1: plain text, glyphs at y=0, ascent > 0" begin
            result = TeXLayout.layout_document("abc"; family = family)
            @test result isa TeXLayout.TeXBox
            @test result.ascent > 0.0
            @test result.descent >= 0.0
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
            @test length(glyphs) == 3
            @test all(b.y ≈ 0.0 for b in glyphs)
            @test glyphs[1].x ≈ 0.0
        end

        @testset "Case 2: line break → second baseline ≈ -1.2" begin
            result = TeXLayout.layout_document("a\\\\b"; family = family)
            glyphs = sort(
                filter(b -> b.element isa Glyph, result.boxes);
                by = b -> b.y,
                rev = true,
            )
            @test length(glyphs) == 2
            @test glyphs[1].y ≈ 0.0
            @test glyphs[2].y ≈ -1.2   atol = 0.1
        end

        @testset "Case 3: tall line forces advance > line_height" begin
            result = TeXLayout.layout_document("\$\\dfrac{a}{b}\$\\\\x"; family = family)
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
            @test minimum(b.y for b in glyphs) < -1.2
        end

        @testset "Case 4: right alignment shifts narrow second line" begin
            result = TeXLayout.layout_document(
                "long text here\\\\x"; family = family, align = :right,
            )
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
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
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
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
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
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
                    b -> b.element isa Glyph &&
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

        @testset "Case 9: first line glyphs have y ≈ 0 (y-origin invariant)" begin
            result = TeXLayout.layout_document("Hello world"; family = family)
            glyphs = filter(b -> b.element isa Glyph, result.boxes)
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

end
