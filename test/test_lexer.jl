# Tests for the LaTeX lexer (src/lexer.jl).
#
# Each test provides an input string and checks the resulting token stream:
# kinds, values (raw source text), and—where relevant—positions.

@testset "Lexer" begin

    @testset "Single character" begin
        toks = tokenize("x")
        @test length(toks) == 2         # char + EOF
        @test toks[1].kind  === TKChar
        @test toks[1].value == "x"
        @test toks[1].pos   == 1
        @test toks[end].kind === TKEOF
    end

    @testset "Simple superscript: x^2" begin
        toks = tokenize("x^2")
        kinds = [t.kind for t in toks]
        @test kinds[1:3] == [TKChar, TKSup, TKChar]
        @test toks[1].value == "x"
        @test toks[2].value == "^"
        @test toks[3].value == "2"
    end

    @testset "Simple subscript: x_i" begin
        toks = tokenize("x_i")
        @test toks[1].kind === TKChar
        @test toks[2].kind === TKSub
        @test toks[2].value == "_"
        @test toks[3].kind === TKChar
        @test toks[3].value == "i"
    end

    @testset "Command: \\alpha" begin
        toks = tokenize("\\alpha")
        @test toks[1].kind  === TKCommand
        @test toks[1].value == "\\alpha"
    end

    @testset "Command with argument: \\frac{a}{b}" begin
        toks = tokenize("\\frac{a}{b}")
        kinds = [t.kind for t in toks if t.kind !== TKEOF]
        @test kinds == [TKCommand, TKLBrace, TKChar, TKRBrace,
                        TKLBrace, TKChar, TKRBrace]
        @test toks[1].value == "\\frac"
        @test toks[3].value == "a"
        @test toks[6].value == "b"
    end

    @testset "Nested braces: {x^2}" begin
        toks = tokenize("{x^2}")
        kinds = [t.kind for t in toks if t.kind !== TKEOF]
        @test kinds == [TKLBrace, TKChar, TKSup, TKChar, TKRBrace]
    end

    @testset "Multi-letter command followed by letter: \\alphax" begin
        # \\alphax is the command \alphax (greedy match), not \alpha followed by x.
        toks = tokenize("\\alphax")
        @test toks[1].kind  === TKCommand
        @test toks[1].value == "\\alphax"
    end

    @testset "Single-char special command: \\{" begin
        toks = tokenize("\\{")
        @test toks[1].kind  === TKCommand
        @test toks[1].value == "\\{"
    end

    @testset "Whitespace is collapsed inside math mode" begin
        # Multiple spaces → single TKSpace (or ignored, matching TeX semantics)
        toks = tokenize("x  y")
        char_toks = filter(t -> t.kind === TKChar, toks)
        @test length(char_toks) == 2
        @test char_toks[1].value == "x"
        @test char_toks[2].value == "y"
    end

    @testset "Mixed expression: x_i^{2} + y" begin
        toks = tokenize("x_i^{2}+y")
        kinds = [t.kind for t in toks if t.kind !== TKEOF]
        @test kinds == [TKChar, TKSub, TKChar, TKSup,
                        TKLBrace, TKChar, TKRBrace, TKChar, TKChar]
        @test toks[1].value == "x"
        @test toks[7].value == "}"
        @test toks[8].value == "+"
    end

    @testset "Math shift token: dollar sign" begin
        toks = tokenize("\$")
        @test toks[1].kind === TKMathShift
    end

    @testset "Position tracking" begin
        toks = tokenize("ab")
        @test toks[1].pos == 1
        @test toks[2].pos == 2
    end

    @testset "Backslash-space command: \\ " begin
        toks = tokenize("\\ ")
        @test toks[1].kind === TKCommand
        @test toks[1].value == "\\ "
    end

end
