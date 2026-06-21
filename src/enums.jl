using EnumX

EnumX.@enumx FontSlot begin
    Math
    Regular
    Bold
    Italic
    BoldItalic
end

EnumX.@enumx LayoutMode begin
    Math
    Text
end

EnumX.@enumx Alignment begin
    Left
    Center
    Right
end

"""Kinds of AST node produced by the parser."""
EnumX.@enumx NodeKind begin
    Char          # single character (letter, digit, punctuation)
    Sequence      # implicit group: ordered list of children
    Group         # explicit braced group: {…}
    Superscript   # base^{exponent} when subscript is absent
    Subscript     # base_{subscript} when superscript is absent
    Decorated     # base with both sub and sup: x_i^2
    Frac          # \frac{num}{den}
    Genfrac       # \binom etc.: no-rule fraction + delimiters; value encoded by _DelimiterPairPayload
    Sqrt          # \sqrt[degree]{body}
    Delimited     # \left…\right pair; value encoded by _DelimiterPairPayload
    BigDelim      # \bigl/\bigr/\big etc.; value encoded by _BigDelimiterPayload
    Accent        # \hat, \bar, \vec, etc.
    OverUnder     # \overline / \underline; value is "overline" or "underline"
    Command       # unrecognised command or atom-producing command (\alpha, \int, …)
    Space         # explicit space token (\, \; \quad etc.)
    Text          # \text{…} / \mbox{…}: text-mode fragment; children[1] = body
    Operator      # named math operator rendered upright: \sin, \cos, \operatorname{…}
    LimitsOverride # \limits / \nolimits: wraps a base; value is "limits" or "nolimits"
    FontSwitch    # \mathbf{…}, \mathit{…}, etc.; value = variant name; children[1] = body
    HorizBrace    # \overbrace / \underbrace / …; value = command name; children[1] = body
    Matrix        # \begin{env}…\end{env}: value encoded by _MatrixPayload; children = flat row-major cells
    Middle        # \middle<delim>: auto-sized inner delimiter; value = PS glyph name
    StyleOverride # \dfrac / \displaystyle etc.; value = style name; children[1] = body
    Sizing        # \large / \tiny etc.; value = Float64 multiplier string; children[1] = body
    XArrow        # \xrightarrow etc.; value = command name; children = [above] or [above, below]
end

"""Categories of token produced by the lexer."""
EnumX.@enumx TokenKind begin
    Char        # ordinary character: letter, digit, punctuation
    Command     # \commandname or \\ or \{ etc.
    Sup         # ^
    Sub         # _
    LBrace      # {
    RBrace      # }
    MathShift   # $
    Ampersand   # &
    Space       # whitespace run or explicit space (\ ~); math-mode parser skips these
    EOF
end

_font_slot_from_symbol(slot::Symbol) =
    slot === :math ? FontSlot.Math :
    slot === :regular ? FontSlot.Regular :
    slot === :bold ? FontSlot.Bold :
    slot === :italic ? FontSlot.Italic :
    slot === :bolditalic ? FontSlot.BoldItalic :
    error("unknown font slot: $slot")

_font_slot_symbol(slot::FontSlot.T) =
    slot === FontSlot.Math ? :math :
    slot === FontSlot.Regular ? :regular :
    slot === FontSlot.Bold ? :bold :
    slot === FontSlot.Italic ? :italic :
    slot === FontSlot.BoldItalic ? :bolditalic :
    error("unknown font slot: $slot")

_alignment_from_symbol(align::Symbol) =
    align === :left ? Alignment.Left :
    align === :center ? Alignment.Center :
    align === :right ? Alignment.Right :
    error("unknown alignment: $align")

_alignment_symbol(align::Alignment.T) =
    align === Alignment.Left ? :left :
    align === Alignment.Center ? :center :
    align === Alignment.Right ? :right :
    error("unknown alignment: $align")
