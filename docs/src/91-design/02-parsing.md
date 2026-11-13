# Lexer, parser, and AST

## Lexer (`src/lexer.jl`)

The lexer turns a LaTeX string into a flat stream of position-tagged tokens.  It
does no macro expansion and no semantic analysis; that is the parser's job.

```julia
struct Token
    kind::TokenKind.T
    value::String   # raw source text of the token
    pos::Int        # 1-based byte offset in the source string
end
```

| `TokenKind` | Description |
|:------|:------------|
| `Char` | Any ordinary character: letter, digit, punctuation, or other Unicode scalar |
| `Command` | A backslash command: `\alpha`, `\\`, `\{`, `\,`, … |
| `Sup`, `Sub` | `^` and `_` |
| `LBrace`, `RBrace` | `{` and `}` |
| `MathShift` | `$` |
| `Ampersand` | `&`, the column separator in arrays and alignments |
| `Space` | A whitespace run, or `~` |
| `EOF` | End-of-input sentinel, always the last token |

The lexer walks the string by codepoint (`nextind`):

- A `\` followed by a letter starts a command that takes every following letter
  (`\alpha`); followed by any other character, the command is that one character
  (`\{`, `\\`).  A bare `\` at the end of the input is a `Char`.
- A run of whitespace is one `Space` token whose value keeps the raw run, so the
  document parser can tell a blank line (a paragraph break) from a space.
- `~` is a `Space` token of its own, which the parser treats as a significant
  space rather than ignorable whitespace.
- `%` discards the rest of the line.  When a line ends in `%`, the newline and
  the next line's indentation go too, unless the next line is blank, so a
  paragraph break survives.  An escaped `\%` is a command and is not affected.
- Every other codepoint, including multi-byte UTF-8, is a one-character `Char`.

The lexer always appends one `EOF` token at `ncodeunits(input) + 1`, even for the
empty string.  The parser never moves past it (see the
[invariants](01-overview.md#Invariants)).

## AST (`src/ast.jl`, `src/payloads.jl`)

```julia
struct Node
    kind::NodeKind.T
    value::String           # source text for leaves; command or style name for some interior nodes
    children::Vector{Node}
    width::Float64          # em; NodeKind.Space only, 0.0 otherwise
    payload::_NodePayload   # structured data for four kinds; nothing otherwise
end

Node(kind, value)                 # leaf
Node(kind, children)              # interior, empty value
Node(kind, value, children)       # interior with a value
Node(kind, payload, children)     # interior with a payload
space_node(w)                     # NodeKind.Space of width w em
```

`NodeKind` is an internal EnumX namespace:

| Kind | Children | `value` or `payload` | Source |
|:-----|:---------|:---------------------|:-------|
| `Char` | none | the character | letters, digits, punctuation |
| `Sequence` | the items | | the whole formula; the body of a style or size switch |
| `Group` | the items | | `{…}`; matrix cells |
| `Superscript`, `Subscript` | `[base, script]` | | `x^2`, `x_i` |
| `Decorated` | `[base, sub, sup]` | | `x_i^2` in either order |
| `Frac` | `[num, den]` | | `\frac` |
| `Genfrac` | `[num, den]` | `_DelimiterPairPayload` | `\binom` and friends |
| `Sqrt` | `[body]` or `[degree, body]` | | `\sqrt`, `\sqrt[n]` |
| `Delimited` | the inner items | `_DelimiterPairPayload` | `\left…\right` |
| `Middle` | none | delimiter glyph name | `\middle` inside `\left…\right` |
| `BigDelim` | none | `_BigDelimiterPayload` | `\bigl(`, `\Bigr]`, `\bigm\vert`, … |
| `Accent` | `[base]` | command, e.g. `"\\hat"` | non-stretchy and wide accents |
| `OverUnder` | `[body]` | `"overline"` or `"underline"` | `\overline`, `\underline` |
| `HorizBrace` | `[body]` | command, e.g. `"\\overbrace"` | `\overbrace`, `\underbrace`, … |
| `XArrow` | `[above]` or `[above, below]` | command, e.g. `"\\xrightarrow"` | `\xrightarrow` and friends |
| `Command` | none | the command, with `\` | symbols, and any unknown command |
| `Operator` | the spelling, when it has spaces | operator name, e.g. `"sin"` | `\sin`, `\liminf`, `\operatorname{…}` |
| `LimitsOverride` | `[base]` | `"limits"`, `"nolimits"`, or `"displaylimits"` | `\limits`, `\nolimits`, `\displaylimits`, `\operatorname*` |
| `FontSwitch` | `[body]` | alphabet, e.g. `"mathbf"` | `\mathbf{…}`, `\mathbb{…}`, `\boldsymbol{…}`, … |
| `StyleOverride` | `[body]` | style, e.g. `"Display"` | `\displaystyle`, `\dfrac`, `\tbinom`, … |
| `Sizing` | `[body]` | multiplier, as text | `\large`, `\tiny`, … |
| `Matrix` | the cells, row by row | `_MatrixPayload` | `\begin{env}…\end{env}` |
| `Space` | none | | explicit spaces and kerns; the width is in `width` |
| `Text` | `[body]` | empty, or a text-style command such as `"\\textsc"` | `\text{…}`, `\mbox{…}`, `\textbf{…}` in math |
| `InlineMath` | `[body]` | | `$…$` inside `\text{…}` |
| `MathChoice` | `[display, text, script, scriptscript]` | | `\mathchoice`; the style-dependent kerns of `\pmod` and friends |

Points worth knowing:

- **`Decorated` children are always `[base, sub, sup]`**, whatever order `_`
  and `^` had in the source.
- **`Space.width`** holds the width in em, negative for `\!` and other negative
  spaces.  `\kern`, `\mkern`, `\hskip`, and `\mskip` become `Space` nodes too,
  with their dimension converted by `_TEX_UNIT_EM` (`pt`, `em`, `ex`, `mu`, `mm`,
  `cm`, `in`, `bp`, `pc`, `dd`, `cc`, `sp`, at 10 pt = 1 em).
- **`StyleOverride`** resets style and scale absolutely, so `\dfrac` inside a
  subscript is set at full display size.  For `\displaystyle` and its siblings
  the body is the rest of the enclosing group; for `\dfrac` and `\tfrac` it is
  the one fraction.
- **`Operator` names in `_LIMITS_OPERATORS`** (`\lim`, `\max`, …) take limits
  in Display style.
- **`Text`** shares its text-style transitions with the document layer
  (`text_styles.jl`).

### Payloads

Four kinds carry their structured data in `payload`, never packed into `value`:

| Payload | Kinds | Fields |
|:--------|:------|:-------|
| `_DelimiterPairPayload` | `Delimited`, `Genfrac` | `left`, `right`: PostScript glyph names, `""` for a null delimiter (`\left.`) |
| `_BigDelimiterPayload` | `BigDelim` | `glyph_name`; `size` 1 to 4 (`\big` … `\Bigg`, 1.2, 1.8, 2.4, and 3.0 em); `atom_class` `'o'`, `'c'`, `'r'`, or `'d'` (open, close, relation, ordinary) |
| `_MatrixPayload` | `Matrix` | `env_name`; `nrow`; `colspec`, verbatim for `array` and derived for the others; `row_gaps`, the `\\[len]` after each row in em |

Layout reads them through `_delimiter_pair`, `_big_delimiter`, and
`_matrix_payload`, which return a neutral default for a node without the
expected payload, so a hand-built node cannot make layout throw.  Payloads
compare by value.  An `array` keeps its column specification as written, rule
markers included (`"|l||c|r|"`).  A new construct that needs structured data
should add a payload type to `_NodePayload` rather than encode fields into
`value`.

## Parser (`src/parser.jl`)

The parser is hand-written recursive descent with one token of look-ahead, over a
small mutable `_Parser` holding the tokens and a position.  `_current(p)` peeks
and `_advance!(p)` moves on.  `parse_latex(input)` takes a string or a token
vector and returns one `NodeKind.Sequence`.

- **`_parse_expression_children!`** parses items until a stop condition (a
  closing brace, `EOF`, `\right`, `&`, `\\`, …).
- **`_parse_atom!`** parses one primary, then attaches any `_` and `^` to make a
  `Subscript`, `Superscript`, or `Decorated`, and wraps the base for `\limits`,
  `\nolimits`, or `\displaylimits` (a later modifier replaces an earlier one).
- **`_parse_primary!`** dispatches on the token: a `Char` becomes a `Char` node,
  a `Command` goes to `_parse_command!`, a `{` reads a group, a stray `^`, `_`,
  `$`, or `&` is literal, and `EOF` returns a zero-width `Space` without moving.
- **`_parse_command!`** handles every command with arguments or structure:
  fractions, radicals, `\left`…`\right`, environments, operators, font, style,
  and size switches, spaces and kerns, accents, braces, and extensible arrows.
  The command tables live in `src/tables/parser_tables.jl`.  An unknown command
  becomes a `Command` leaf, which layout draws as nothing.
- **`_parse_argument!`** reads one argument: a braced group, or a single primary.
- **`_parse_matrix_body!`** reads the cells of an environment, the `\\[len]` row
  gaps, and the column count, and derives the column specification.

### Whitespace in math

Math mode ignores ordinary whitespace: leading, trailing, and repeated spaces,
a space after `^` or `_` or before a command argument (`x^ 2`, `\frac 1 2`),
before `^`, `_`, or `\limits` (`x ^2`), before a delimiter, dimension, or
`\text` argument (`\left (`, `\kern 1em`, `\text {a}`), and around the optional
`[…]` of `\sqrt` and the extensible arrows.  The space before a script is
dropped only when a script follows (`_peek_past_spaces` in `_parse_atom!`), so
significant spaces inside `\text{…}` survive.

`~`, `\ `, `\space`, and `\nobreakspace` are not ignorable: they give a normal
interword space (`_NORMAL_SPACE_EM`, TeX's `fontdimen2`, 6/18 em) in math and
inside `\text{…}`.  `_is_ignorable_space` tells them apart: a `~` token is
significant, a pure-whitespace token is not.  `\text{…}` collapses runs of
whitespace and keeps single spaces, like document groups.

In matrices `\\[dim]` does not skip a space before `[`, as amsmath's matrix
environments, `cases`, and `align` use `\new@ifnextchar`.  A plain LaTeX `array`
uses the kernel's space-skipping `\@ifnextchar`, so there `\\ [2pt]` is a
row-spacing argument; TeXLayout sets it as cell content.

### Resilience

The parser never throws.  Ill-formed input gives a degraded but well-formed tree:

| Input | Result |
|:------|:-------|
| `x^2^3`, `x_i_j` | the second script is a fresh atom |
| `{unclosed` | the group runs to `EOF` |
| `\left( x` | `\left` runs to `EOF` |
| `\frac{a}` | the missing argument is an empty group |
| `\unknown` | a `Command` leaf that draws nothing |
