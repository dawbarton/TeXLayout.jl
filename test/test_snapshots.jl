using SHA

const SNAPSHOT_MATH_CASES = [
    ("simple_atom", raw"x+y=z", "e6602eacd72a905048cffc0c2ec8ad9bcbd7a1df29ae4fe2b0de981fd31ddf84"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}", "8590527a7489dd33a2f7c5ae9db6cdf8c42ccc64dd8f89b0b5e4268cf1f88aca"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)", "2157c21643a4090b28bb59bd15166e0589e08bb0c64676c7a883709273052467"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx", "68f95243cb51d3f6846e121840d2d7c0eaf6b318955258833f9379dd8c12f6a0"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}", "ea1a16135a9433bb0356309eaec3607e1587c8ee538ba95cc6c67d5760dd9289"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", "e1950914fa964ae4c7f30c182137d7750da18a2de46ed0be1aa5440b0828b075"),
    # Display alignment environments typeset cells in Display style: fractions and
    # scripts keep full display size (contrast with the text-sized matrix cells above).
    ("align_fraction", raw"\begin{align} \frac{a}{b} &= c \\ d &= \frac{e}{f} \end{align}", "6ada751677923d5bb91b2218afe62822c1dfbef8a750beb15427b057749d9fc1"),
    ("gathered_script", raw"\begin{gathered} x^{\frac{1}{2}} \\ \sum_{i=1}^{n} i \end{gathered}", "f54bd6a7425b58b1e466221d5e924f33bb7844ff2bdcac07ca38a9b1cde4c4a2"),
]

const SNAPSHOT_DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}", "789c8ef0f310f5f949ca502bb7fab972eda2255a8d4857c04a64f8822ccc8d11"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$", "b363bb9f6cc25cb4b967de541d791fad42a24aa887ea8d9a7e39208f6c4b9589"),
]

_snapshot_float(x) = string(round(Float64(x); digits = 10))
_snapshot_hash(s::AbstractString) = bytes2hex(sha256(codeunits(s)))

function _snapshot_box_line(box)
    io = IOBuffer()
    el = box.element
    print(io, nameof(typeof(el)), "|")
    if el isa Glyph
        print(
            io,
            el.glyph_name, "|", TeXLayout._font_slot_symbol(el.font_slot), "|",
            el.advance_width, "|", el.left_side_bearing, "|",
            el.x_min, "|", el.y_min, "|", el.x_max, "|", el.y_max,
        )
    elseif el isa GlyphID
        stable_path = joinpath(basename(dirname(el.font_path)), basename(el.font_path))
        print(
            io,
            el.glyph_id, "|", stable_path, "|",
            TeXLayout._font_slot_symbol(el.font_slot), "|",
            el.represented_char, "|",
            el.advance_width, "|", el.left_side_bearing, "|",
            el.x_min, "|", el.y_min, "|", el.x_max, "|", el.y_max,
        )
    elseif el isa HRule
        print(io, _snapshot_float(el.width), "|", _snapshot_float(el.thickness))
    elseif el isa VRule
        print(io, _snapshot_float(el.height), "|", _snapshot_float(el.thickness))
    elseif el isa Space
        print(io, _snapshot_float(el.width))
    end
    print(
        io,
        "|", _snapshot_float(box.x),
        "|", _snapshot_float(box.y),
        "|", _snapshot_float(box.scale),
    )
    return String(take!(io))
end

function _snapshot_boxes(boxes)
    lines = sort!([_snapshot_box_line(box) for box in boxes])
    io = IOBuffer()
    for line in lines
        println(io, line)
    end
    return String(take!(io))
end

function _snapshot_box(box::TeXBox)
    return string(
        _snapshot_float(box.width), "|",
        _snapshot_float(box.ascent), "|",
        _snapshot_float(box.descent), "\n",
        _snapshot_boxes(box.boxes),
    )
end

@testset "layout snapshots" begin
    family = font_family(:new_cm)
    for (name, expr, expected) in SNAPSHOT_MATH_CASES
        actual = _snapshot_hash(_snapshot_boxes(generate_tex_elements(expr, family)))
        @test actual == expected
    end
    for (name, expr, expected) in SNAPSHOT_DOCUMENT_CASES
        actual = _snapshot_hash(_snapshot_box(layout_document(expr; family)))
        @test actual == expected
    end
end
