# LaTeX lexer: raw string → flat token stream.
#
# Tokens are position-tagged so that parse errors can report column numbers.
# No macro expansion occurs here; that is the parser's responsibility.

"""A single lexer token."""
struct Token
    kind::TokenKind.T
    value::String   # raw source text of the token
    pos::Int        # 1-based byte offset in the source string
end

"""
    tokenize(input) -> Vector{Token}

Lex a LaTeX math-mode string into a flat token stream.
The input should not include surrounding dollar-sign delimiters.
"""
function tokenize(input::AbstractString)::Vector{Token}
    s = String(input)
    n = ncodeunits(s)
    tokens = Token[]
    i = 1

    while i <= n
        c = s[i]
        next = nextind(s, i)

        if c == '\\'
            # Backslash: consume the command name.
            if next > n
                # Bare backslash at end — treat as TokenKind.Char.
                push!(tokens, Token(TokenKind.Char, "\\", i))
                i = next
            elseif isletter(s[next])
                # Multi-letter command: greedily consume letters.
                j = nextind(s, next)
                while j <= n && isletter(s[j])
                    j = nextind(s, j)
                end
                push!(tokens, Token(TokenKind.Command, s[i:prevind(s, j)], i))
                i = j
            else
                # Single non-letter character after backslash (e.g. \{ \  \\).
                j = nextind(s, next)
                push!(tokens, Token(TokenKind.Command, s[i:prevind(s, j)], i))
                i = j
            end

        elseif c == '^'
            push!(tokens, Token(TokenKind.Sup, "^", i));  i = next
        elseif c == '_'
            push!(tokens, Token(TokenKind.Sub, "_", i));  i = next
        elseif c == '{'
            push!(tokens, Token(TokenKind.LBrace, "{", i));  i = next
        elseif c == '}'
            push!(tokens, Token(TokenKind.RBrace, "}", i));  i = next
        elseif c == '$'
            push!(tokens, Token(TokenKind.MathShift, "\$", i));  i = next
        elseif c == '&'
            push!(tokens, Token(TokenKind.Ampersand, "&", i));  i = next
        elseif c == '~'
            push!(tokens, Token(TokenKind.Space, "~", i));  i = next
        elseif isspace(c)
            # Collapse the entire whitespace run into one TokenKind.Space token.
            # The parser decides whether spaces are significant (text mode) or not (math mode).
            while next <= n && isspace(s[next])
                next = nextind(s, next)
            end
            push!(tokens, Token(TokenKind.Space, " ", i))
            i = next
        else
            # Everything else is an ordinary character (may be multi-byte UTF-8).
            push!(tokens, Token(TokenKind.Char, string(c), i));  i = next
        end
    end

    push!(tokens, Token(TokenKind.EOF, "", n + 1))
    return tokens
end
