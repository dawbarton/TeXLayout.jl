using SHA

const SNAPSHOT_MATH_CASES = [
    ("simple_atom", raw"x+y=z", "89a80264270cc3247752bca2a9fb9db97664c671a3a0e4d43c1bc1f2af75015b"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}", "8590527a7489dd33a2f7c5ae9db6cdf8c42ccc64dd8f89b0b5e4268cf1f88aca"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)", "23ab2a4f832e4ec3a2605f40bdbaefc7b05e2e2b85b20e360df95c6cde2e195f"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx", "9d6d0826eaafb71b4453a080254614f6d7397969d7aa10ef110c3accf8723c23"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}", "72458b7ec3aebcac5dc84732b38c7cc104e56edcde41cf982ef5c97801b7d7ac"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", "e1950914fa964ae4c7f30c182137d7750da18a2de46ed0be1aa5440b0828b075"),
    # Display alignment environments typeset cells in Display style: fractions and
    # scripts keep full display size (contrast with the text-sized matrix cells above).
    ("align_fraction", raw"\begin{align} \frac{a}{b} &= c \\ d &= \frac{e}{f} \end{align}", "367f6e4f32adfc80ef10403fde0328d711e968041cd644c8ddd6569183b55b32"),
    ("gathered_script", raw"\begin{gathered} x^{\frac{1}{2}} \\ \sum_{i=1}^{n} i \end{gathered}", "f54bd6a7425b58b1e466221d5e924f33bb7844ff2bdcac07ca38a9b1cde4c4a2"),
]

const SNAPSHOT_DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}", "e64e449a7fdd6b98353f0291190bcf88c0108693c4c12ce3a90cc42d781f88e5"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$", "7d6a2b3a26baa8504f046bc567a05c109c7f4e81d8f18f7a6478161da24417e0"),
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
