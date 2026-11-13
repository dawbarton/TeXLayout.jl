# Unicode math-alphabet codepoints for the \math… font switches.
#
# `_math_variant_codepoint` maps a character and a math-alphabet command
# (`\mathbf`, `\mathbb`, `\boldsymbol`, …) to its codepoint in the Mathematical
# Alphanumeric Symbols block (U+1D400–U+1D7FF) or, for the letters that Unicode
# encodes earlier, in the Letterlike Symbols block.  It depends on Unicode only,
# not on a font; layout then looks the codepoint up in the math font.

# Exception tables for variants whose Unicode math codepoints are not contiguous
# with the main Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF).
# Sources: Unicode 15 Table 2.8 and the Mathematical Alphanumeric Symbols chart.

# \mathbb exceptions: letters that have dedicated BMP codepoints in addition to
# (or instead of) their Mathematical Double-Struck equivalents.
const _MATHBB_EXCEPTIONS = Dict{Char, UInt32}(
    'C' => 0x2102,  # ℂ  DOUBLE-STRUCK CAPITAL C
    'H' => 0x210D,  # ℍ  DOUBLE-STRUCK CAPITAL H
    'N' => 0x2115,  # ℕ  DOUBLE-STRUCK CAPITAL N
    'P' => 0x2119,  # ℙ  DOUBLE-STRUCK CAPITAL P
    'Q' => 0x211A,  # ℚ  DOUBLE-STRUCK CAPITAL Q
    'R' => 0x211D,  # ℝ  DOUBLE-STRUCK CAPITAL R
    'Z' => 0x2124,  # ℤ  DOUBLE-STRUCK CAPITAL Z
)

# \mathcal exceptions: uppercase letters with BMP Letterlike Symbols codepoints.
const _MATHCAL_UC_EXCEPTIONS = Dict{Char, UInt32}(
    'B' => 0x212C,  # ℬ  SCRIPT CAPITAL B
    'E' => 0x2130,  # ℰ  SCRIPT CAPITAL E
    'F' => 0x2131,  # ℱ  SCRIPT CAPITAL F
    'H' => 0x210B,  # ℋ  SCRIPT CAPITAL H
    'I' => 0x2110,  # ℐ  SCRIPT CAPITAL I
    'L' => 0x2112,  # ℒ  SCRIPT CAPITAL L
    'M' => 0x2133,  # ℳ  SCRIPT CAPITAL M
    'R' => 0x211B,  # ℛ  SCRIPT CAPITAL R
)

# \mathcal lowercase exceptions.
const _MATHCAL_LC_EXCEPTIONS = Dict{Char, UInt32}(
    'e' => 0x212F,  # ℯ  SCRIPT SMALL E
    'g' => 0x210A,  # ℊ  SCRIPT SMALL G
    'o' => 0x2134,  # ℴ  SCRIPT SMALL O
)

# \mathfrak uppercase exceptions: letters with BMP Letterlike Symbols codepoints.
const _MATHFRAK_UC_EXCEPTIONS = Dict{Char, UInt32}(
    'C' => 0x212D,  # ℭ  FRAKTUR CAPITAL C
    'H' => 0x210C,  # ℌ  FRAKTUR CAPITAL H
    'I' => 0x2111,  # ℑ  FRAKTUR CAPITAL I (BLACK-LETTER)
    'R' => 0x211C,  # ℜ  FRAKTUR CAPITAL R (BLACK-LETTER)
    'Z' => 0x2128,  # ℨ  FRAKTUR CAPITAL Z
)

# \mathit lowercase exceptions.
const _MATHIT_LC_EXCEPTIONS = Dict{Char, UInt32}(
    'h' => 0x210E,  # ℎ  PLANCK CONSTANT (italic h)
)

"""
    _math_variant_codepoint(variant, ch) -> Union{UInt32, Nothing}

Return the Unicode codepoint for character `ch` in the requested math font
variant, or `nothing` if no variant codepoint exists for that character.

Uses the Mathematical Alphanumeric Symbols block (U+1D400–U+1D7FF) for
continuous ranges, and dedicated BMP Letterlike Symbols for exceptions.
"""
function _math_variant_codepoint(variant::Symbol, ch::Char)::Union{UInt32, Nothing}
    cp = UInt32(ch)

    # ── \mathbf: bold upright Latin, digits, and Greek ─────────────────────────
    # Unicode Mathematical Bold block: Latin UC 1D400–1D419, LC 1D41A–1D433,
    # digits 1D7CE–1D7D7; Greek UC 1D6A8–1D6C0, LC 1D6C2–1D6DA.
    # The Greek UC gap at 0x03A2 (no such letter) aligns with the ϴ-symbol slot
    # 1D6B9 in the math block, so a single offset covers Α–Ρ and Σ–Ω uniformly.
    if variant === :mathbf
        'A' <= ch <= 'Z' && return 0x0001D400 + (cp - UInt32('A'))  # 𝐀–𝐙
        'a' <= ch <= 'z' && return 0x0001D41A + (cp - UInt32('a'))  # 𝐚–𝐳
        '0' <= ch <= '9' && return 0x0001D7CE + (cp - UInt32('0'))  # 𝟎–𝟗
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D6A8 + (cp - UInt32('Α'))             # 𝚨–𝛀
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D6C2 + (cp - UInt32('α'))             # 𝛂–𝛚
        ch === '∇' && return 0x0001D6C1  # bold ∇
        ch === '∂' && return 0x0001D6DB  # bold ∂
        ch === 'ϵ' && return 0x0001D6DC  # bold ϵ (varepsilon)
        ch === 'ϑ' && return 0x0001D6DD  # bold ϑ (vartheta)
        ch === 'ϰ' && return 0x0001D6DE  # bold ϰ (varkappa)
        ch === 'ϕ' && return 0x0001D6DF  # bold ϕ (varphi)
        ch === 'ϱ' && return 0x0001D6E0  # bold ϱ (varrho)
        ch === 'ϖ' && return 0x0001D6E1  # bold ϖ (varpi)
        return nothing

        # ── \boldsymbol: bold italic Latin and Greek ──────────────────────────────
        # Unlike \mathbf, bold italic uses separate Latin slots (1D468 UC, 1D482 LC)
        # and a separate Greek block (UC 1D71C–1D734, LC 1D736–1D74E).
    elseif variant === :boldsymbol
        'A' <= ch <= 'Z' && return 0x0001D468 + (cp - UInt32('A'))  # 𝑨–𝒁
        'a' <= ch <= 'z' && return 0x0001D482 + (cp - UInt32('a'))  # 𝒂–𝒛
        '0' <= ch <= '9' && return 0x0001D7CE + (cp - UInt32('0'))  # 𝟎–𝟗 (bold only; no bold-italic digit block)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D71C + (cp - UInt32('Α'))             # 𝜜–𝜴
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D736 + (cp - UInt32('α'))             # 𝜶–𝝎
        ch === '∇' && return 0x0001D735  # bold italic ∇
        ch === '∂' && return 0x0001D74F  # bold italic ∂
        ch === 'ϵ' && return 0x0001D750  # bold italic ϵ
        ch === 'ϑ' && return 0x0001D751  # bold italic ϑ
        ch === 'ϰ' && return 0x0001D752  # bold italic ϰ
        ch === 'ϕ' && return 0x0001D753  # bold italic ϕ
        ch === 'ϱ' && return 0x0001D754  # bold italic ϱ
        ch === 'ϖ' && return 0x0001D755  # bold italic ϖ
        return nothing

        # ── \mathit / \mathnormal: italic Latin and Greek ─────────────────────────
        # Greek italic: UC 1D6E2–1D6FA, LC 1D6FC–1D714 (default math style for Greek).
    elseif variant === :mathit || variant === :mathnormal
        'A' <= ch <= 'Z' && return 0x0001D434 + (cp - UInt32('A'))  # 𝐴–𝑍
        'a' <= ch <= 'z' && return get(
            _MATHIT_LC_EXCEPTIONS, ch,
            0x0001D44E + (cp - UInt32('a'))
        )  # 𝑎–𝑧 (ℎ exception)
        if ('Α' <= ch <= 'Ρ') || ('Σ' <= ch <= 'Ω')
            return 0x0001D6E2 + (cp - UInt32('Α'))             # 𝛢–𝛺
        end
        'α' <= ch <= 'ω' &&
            return 0x0001D6FC + (cp - UInt32('α'))             # 𝛼–𝜔
        ch === '∇' && return 0x0001D6FB  # italic ∇
        ch === '∂' && return 0x0001D715  # italic ∂
        ch === 'ϵ' && return 0x0001D716  # italic ϵ
        ch === 'ϑ' && return 0x0001D717  # italic ϑ
        ch === 'ϰ' && return 0x0001D718  # italic ϰ
        ch === 'ϕ' && return 0x0001D719  # italic ϕ
        ch === 'ϱ' && return 0x0001D71A  # italic ϱ
        ch === 'ϖ' && return 0x0001D71B  # italic ϖ
        return nothing

        # ── \mathrm: upright via regular font or math-font codepoint ──────────────
    elseif variant === :mathrm
        # ASCII letters map directly; the layout engine will use _upright_glyph.
        # Return nothing here to signal "use upright lookup, not variant codepoint".
        return nothing

        # ── \mathbb: double-struck ─────────────────────────────────────────────────
    elseif variant === :mathbb
        haskey(_MATHBB_EXCEPTIONS, ch) && return _MATHBB_EXCEPTIONS[ch]
        'A' <= ch <= 'Z' && return 0x0001D538 + (cp - UInt32('A'))  # 𝔸–𝕑
        'a' <= ch <= 'z' && return 0x0001D552 + (cp - UInt32('a'))  # 𝕒–𝕫
        '0' <= ch <= '9' && return 0x0001D7D8 + (cp - UInt32('0'))  # 𝟘–𝟡
        return nothing

        # ── \mathcal / \mathscr: script ───────────────────────────────────────────
    elseif variant === :mathcal || variant === :mathscr
        'A' <= ch <= 'Z' && return get(
            _MATHCAL_UC_EXCEPTIONS, ch,
            0x0001D49C + (cp - UInt32('A'))
        )  # 𝒜–𝒵
        'a' <= ch <= 'z' && return get(
            _MATHCAL_LC_EXCEPTIONS, ch,
            0x0001D4B6 + (cp - UInt32('a'))
        )  # 𝒶–𝓏
        return nothing

        # ── \mathfrak: fraktur ────────────────────────────────────────────────────
    elseif variant === :mathfrak
        'A' <= ch <= 'Z' && return get(
            _MATHFRAK_UC_EXCEPTIONS, ch,
            0x0001D504 + (cp - UInt32('A'))
        )  # 𝔄–𝔷
        'a' <= ch <= 'z' && return 0x0001D51E + (cp - UInt32('a'))       # 𝔞–𝔷
        return nothing

        # ── \mathsf: sans-serif upright ───────────────────────────────────────────
    elseif variant === :mathsf
        'A' <= ch <= 'Z' && return 0x0001D5A0 + (cp - UInt32('A'))  # 𝖠–𝖹
        'a' <= ch <= 'z' && return 0x0001D5BA + (cp - UInt32('a'))  # 𝖺–𝗓
        '0' <= ch <= '9' && return 0x0001D7E2 + (cp - UInt32('0'))  # 𝟢–𝟫
        return nothing

        # ── \mathtt: monospace ────────────────────────────────────────────────────
    elseif variant === :mathtt
        'A' <= ch <= 'Z' && return 0x0001D670 + (cp - UInt32('A'))  # 𝙰–𝚉
        'a' <= ch <= 'z' && return 0x0001D68A + (cp - UInt32('a'))  # 𝚊–𝚣
        '0' <= ch <= '9' && return 0x0001D7F6 + (cp - UInt32('0'))  # 𝟶–𝟿
        return nothing

        # ── \mathsfit: sans-serif italic ─────────────────────────────────────────
    elseif variant === :mathsfit
        'A' <= ch <= 'Z' && return 0x0001D608 + (cp - UInt32('A'))  # 𝘈–𝘡
        'a' <= ch <= 'z' && return 0x0001D622 + (cp - UInt32('a'))  # 𝘢–𝘻
        return nothing

    else
        return nothing
    end
end
