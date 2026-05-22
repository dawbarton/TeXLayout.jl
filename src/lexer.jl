# LaTeX lexer: raw string → flat token stream.
#
# Tokens are position-tagged so that parse errors can report column numbers.
# No macro expansion occurs here; that is the parser's responsibility.

"""Categories of token produced by the lexer."""
@enum TokenKind begin
    TKChar        # ordinary character: letter, digit, punctuation
    TKCommand     # \commandname or \\ or \{ etc.
    TKSup         # ^
    TKSub         # _
    TKLBrace      # {
    TKRBrace      # }
    TKMathShift   # $
    TKAmpersand   # &
    TKSpace       # explicit space (\ or ~ or whitespace run inside text mode)
    TKEOF
end

"""A single lexer token."""
struct Token
    kind::TokenKind
    value::String   # raw source text of the token
    pos::Int        # 1-based byte offset in the source string
end

"""
    tokenize(input) -> Vector{Token}

Lex a LaTeX math-mode string into a flat token stream.
The input should not include surrounding dollar-sign delimiters.
"""
function tokenize(input::AbstractString)::Vector{Token}
    s      = String(input)
    n      = ncodeunits(s)
    tokens = Token[]
    i      = 1

    while i <= n
        c = s[i]

        if c == '\\'
            # Backslash: consume the command name.
            if i == n
                # Bare backslash at end — treat as TKChar.
                push!(tokens, Token(TKChar, "\\", i))
                i += 1
            else
                j = i + 1
                next = s[j]
                if isletter(next)
                    # Multi-letter command: greedily consume letters.
                    while j <= n && isletter(s[j])
                        j += 1
                    end
                    push!(tokens, Token(TKCommand, s[i:j-1], i))
                else
                    # Single non-letter character after backslash (e.g. \{ \  \\).
                    push!(tokens, Token(TKCommand, s[i:j], i))
                    j += 1
                end
                i = j
            end

        elseif c == '^'
            push!(tokens, Token(TKSup, "^", i));  i += 1
        elseif c == '_'
            push!(tokens, Token(TKSub, "_", i));  i += 1
        elseif c == '{'
            push!(tokens, Token(TKLBrace, "{", i));  i += 1
        elseif c == '}'
            push!(tokens, Token(TKRBrace, "}", i));  i += 1
        elseif c == '$'
            push!(tokens, Token(TKMathShift, "\$", i));  i += 1
        elseif c == '&'
            push!(tokens, Token(TKAmpersand, "&", i));  i += 1
        elseif c == '~'
            push!(tokens, Token(TKSpace, "~", i));  i += 1
        elseif isspace(c)
            # Spaces are insignificant in math mode; skip the entire run.
            while i <= n && isspace(s[i])
                i += 1
            end
        else
            # Everything else is an ordinary character.
            push!(tokens, Token(TKChar, string(c), i));  i += 1
        end
    end

    push!(tokens, Token(TKEOF, "", n + 1))
    return tokens
end
