# Tests for the LaTeX lexer (src/lexer.jl).
#
# Each test provides an input string and checks the resulting token stream:
# kinds, values (raw source text), and—where relevant—positions.

@testset "Lexer" begin

    @testset "Single character" begin
        toks = tokenize("x")
        @test length(toks) == 2         # char + EOF
        @test toks[1].kind === TokenKind.Char
        @test toks[1].value == "x"
        @test toks[1].pos == 1
        @test toks[end].kind === TokenKind.EOF
    end

    @testset "Simple superscript: x^2" begin
        toks = tokenize("x^2")
        kinds = [t.kind for t in toks]
        @test kinds[1:3] == [TokenKind.Char, TokenKind.Sup, TokenKind.Char]
        @test toks[1].value == "x"
        @test toks[2].value == "^"
        @test toks[3].value == "2"
    end

    @testset "Simple subscript: x_i" begin
        toks = tokenize("x_i")
        @test toks[1].kind === TokenKind.Char
        @test toks[2].kind === TokenKind.Sub
        @test toks[2].value == "_"
        @test toks[3].kind === TokenKind.Char
        @test toks[3].value == "i"
    end

    @testset "Command: \\alpha" begin
        toks = tokenize("\\alpha")
        @test toks[1].kind === TokenKind.Command
        @test toks[1].value == "\\alpha"
    end

    @testset "Command with argument: \\frac{a}{b}" begin
        toks = tokenize("\\frac{a}{b}")
        kinds = [t.kind for t in toks if t.kind !== TokenKind.EOF]
        @test kinds == [
            TokenKind.Command, TokenKind.LBrace, TokenKind.Char, TokenKind.RBrace,
            TokenKind.LBrace, TokenKind.Char, TokenKind.RBrace,
        ]
        @test toks[1].value == "\\frac"
        @test toks[3].value == "a"
        @test toks[6].value == "b"
    end

    @testset "Nested braces: {x^2}" begin
        toks = tokenize("{x^2}")
        kinds = [t.kind for t in toks if t.kind !== TokenKind.EOF]
        @test kinds == [TokenKind.LBrace, TokenKind.Char, TokenKind.Sup, TokenKind.Char, TokenKind.RBrace]
    end

    @testset "Multi-letter command followed by letter: \\alphax" begin
        # \\alphax is the command \alphax (greedy match), not \alpha followed by x.
        toks = tokenize("\\alphax")
        @test toks[1].kind === TokenKind.Command
        @test toks[1].value == "\\alphax"
    end

    @testset "Single-char special command: \\{" begin
        toks = tokenize("\\{")
        @test toks[1].kind === TokenKind.Command
        @test toks[1].value == "\\{"
    end

    @testset "Whitespace is collapsed inside math mode" begin
        # Multiple spaces → single TokenKind.Space (or ignored, matching TeX semantics)
        toks = tokenize("x  y")
        char_toks = filter(t -> t.kind === TokenKind.Char, toks)
        @test length(char_toks) == 2
        @test char_toks[1].value == "x"
        @test char_toks[2].value == "y"
    end

    @testset "Whitespace token preserves raw run" begin
        toks = tokenize("x \n\n y")
        spaces = filter(t -> t.kind === TokenKind.Space, toks)
        @test length(spaces) == 1
        @test spaces[1].value == " \n\n "
    end

    @testset "Mixed expression: x_i^{2} + y" begin
        toks = tokenize("x_i^{2}+y")
        kinds = [t.kind for t in toks if t.kind !== TokenKind.EOF]
        @test kinds == [
            TokenKind.Char, TokenKind.Sub, TokenKind.Char, TokenKind.Sup,
            TokenKind.LBrace, TokenKind.Char, TokenKind.RBrace, TokenKind.Char, TokenKind.Char,
        ]
        @test toks[1].value == "x"
        @test toks[7].value == "}"
        @test toks[8].value == "+"
    end

    @testset "Math shift token: dollar sign" begin
        toks = tokenize("\$")
        @test toks[1].kind === TokenKind.MathShift
    end

    @testset "Position tracking" begin
        toks = tokenize("ab")
        @test toks[1].pos == 1
        @test toks[2].pos == 2
    end

    @testset "Backslash-space command: \\ " begin
        toks = tokenize("\\ ")
        @test toks[1].kind === TokenKind.Command
        @test toks[1].value == "\\ "
    end

    @testset "Multi-byte UTF-8 characters" begin
        # Direct Unicode math characters must not throw StringIndexError.
        toks = tokenize("α+β")
        kinds = [t.kind for t in toks if t.kind !== TokenKind.EOF]
        @test kinds == [TokenKind.Char, TokenKind.Char, TokenKind.Char]
        @test toks[1].value == "α"
        @test toks[2].value == "+"
        @test toks[3].value == "β"
        # Positions are byte offsets; α and β are 2 bytes each in UTF-8.
        @test toks[1].pos == 1
        @test toks[2].pos == 3
        @test toks[3].pos == 4
    end

    @testset "Whitespace runs containing Unicode neighbours" begin
        # The whitespace-skip loop must use nextind, not byte += 1.
        toks = tokenize("α  β")
        char_toks = filter(t -> t.kind === TokenKind.Char, toks)
        @test [t.value for t in char_toks] == ["α", "β"]
    end

end
