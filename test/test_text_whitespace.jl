# Text tests: LaTeX whitespace, comment, and non-breaking-space conventions in
# `parse_document`.
#
# The fixture font and helpers come from runtests.jl and helpers.jl.

@testset "Text: whitespace conventions" begin
    family = FontFamily(FIXTURE_FONT_PATH)

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
            # Windows line endings: the blank line is "\r\n", not "\n".
            for source in ("a%\r\n\r\nb", "a%\n\t\r\nb")
                doc = TeXLayout.parse_document(source)
                paras = filter(b -> b isa TeXLayout.ParagraphBlock, doc)
                @test length(paras) == 2
            end
            @test para_text("foo%comment\r\n  bar") == "foobar"
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
