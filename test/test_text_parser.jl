# Text tests: display-environment parsing and the document parser
# (src/parser.jl, src/document.jl).
#
# The fixture font and helpers come from runtests.jl and helpers.jl.

@testset "Text: document parser" begin
    family = FontFamily(FIXTURE_FONT_PATH)

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
            @test mat.payload.colspec == "rl"
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
            @test mat.payload.colspec == "rlrl"
        end

        @testset "Gather colspec: 1 column → c" begin
            tree = parse_latex("\\begin{gather}x\\\\y\\end{gather}")
            mat = tree.children[1]
            @test mat.kind === NodeKind.Matrix
            @test mat.payload.colspec == "c"
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

        @testset "Space between a text command and its group is skipped" begin
            # TeX drops the space after a control word: `\textbf {bold}` takes
            # `{bold}` as its argument instead of emboldening the rest of the input.
            for command in ("\\textbf", "\\text")
                doc = TeXLayout.parse_document(command * " {bold} rest")
                spans = doc[1].lines[1].runs[1].spans
                @test join(getfield.(spans, :text)) == "bold rest"
                @test spans[end].text == " rest"
                @test spans[end].attrs.slot === TeXLayout.FontSlot.Regular
            end
            spans = TeXLayout.parse_document("\\textbf {bold} rest")[1].lines[1].runs[1].spans
            @test spans[1].text == "bold"
            @test spans[1].attrs.slot === TeXLayout.FontSlot.Bold
        end

        @testset "Unbraced text commands take one token as their argument" begin
            # TeX reads an undelimited argument as the next token, after the
            # spaces that follow the control word: `\textbf x rest` is bold "x".
            spans_of(source) = [
                (sp.text, sp.attrs.slot) for b in TeXLayout.parse_document(source)
                    if b isa TeXLayout.ParagraphBlock for l in b.lines
                    for r in l.runs if r isa TeXLayout.TextRun for sp in r.spans
            ]
            Bold, Regular, BoldItalic = TeXLayout.FontSlot.Bold, TeXLayout.FontSlot.Regular, TeXLayout.FontSlot.BoldItalic
            @test spans_of("\\textbf x rest") == [("x", Bold), (" rest", Regular)]
            @test spans_of("\\textbf xy rest") == [("x", Bold), ("y rest", Regular)]
            @test spans_of("\\textbf\\%x y") == [("%", Bold), ("x y", Regular)]
            # Degraded but contained: a nested command is taken with its group.
            @test spans_of("\\textit\\textbf{x} y") == [("x", BoldItalic), (" y", Regular)]
            @test all(sp -> sp[2] === Regular, spans_of("rest \\textbf"))
            # A paragraph break is not skipped to reach an argument (TeX would
            # stop with "Paragraph ended before ... was complete").
            doc = TeXLayout.parse_document("a \\textbf\n\n{x} y")
            @test count(b -> b isa TeXLayout.ParagraphBlock, doc) == 2
            @test all(sp -> sp[2] === Regular, spans_of("a \\textbf\n\n{x} y"))
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
            # The body is kept as ordinary text; only the delimiters vanish.
            @test doc[1].lines[1].runs[1].spans[1].text == "x"
            centred = TeXLayout.parse_document(raw"\begin{center}Hi\end{center} there")
            @test only(only(centred).lines[1].runs).spans[1].text == "Hi there"
        end

        @testset "Unbraced and spaced command arguments take one item" begin
            span_texts(doc) = [(s.text, s.attrs.slot) for s in only(only(doc).lines).runs[1].spans]
            unbraced = TeXLayout.parse_document(raw"\textbf x and more")
            @test span_texts(unbraced) ==
                [("x", TeXLayout.FontSlot.Bold), (" and more", TeXLayout.FontSlot.Regular)]
            spaced = TeXLayout.parse_document(raw"\textbf {x} y")
            @test span_texts(spaced) ==
                [("x", TeXLayout.FontSlot.Bold), (" y", TeXLayout.FontSlot.Regular)]
            # An unbraced argument does not swallow a paragraph break.
            broken = TeXLayout.parse_document("\\textbf x\n\nNext")
            @test count(b -> b isa TeXLayout.ParagraphBlock, broken) == 2
        end

        @testset "Explicit spaces in text" begin
            width(s) = TeXLayout.layout_document(s; family).width
            @test width(raw"Mr.\ Smith") ≈ width("Mr. Smith")
            @test width(raw"Mr.\ Smith") > width("Mr.Smith")
            # Control words swallow the following space; control symbols do not.
            @test width(raw"a\quad b") ≈ width("ab") + 1.0
            @test width(raw"a\,b") ≈ width("ab") + 3 / 18
            @test width(raw"a\qquad b") ≈ width("ab") + 2.0
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
            @test (mat.payload.nrow, mat.payload.colspec) == (2, "rl")
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
end
