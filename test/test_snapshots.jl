using SHA

const SNAPSHOT_MATH_CASES = [
    ("simple_atom", raw"x+y=z", "89a80264270cc3247752bca2a9fb9db97664c671a3a0e4d43c1bc1f2af75015b"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}", "8f1a4922cbf994fb3c0a913e61ff2f98aa0e0b6ef36c74469424f0a4c68ca807"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)", "331abc8eca97da723f53ef1f038fe06ff9151bc564affac990843b7ad2c1bbd6"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx", "cd971a18c0d3c608917a1a131a034f4d65031afe1a8d158d57edac95ee23a748"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}", "5ab7bcc8435f0601653206a1e3209e5f84874b89b212755ed8452521bef2a9d4"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", "fb0d711ec94511853009b8cb54d5bc8505ce6da2c5874e68e0210021a0179e56"),
    # Display alignment environments typeset cells in Display style: fractions and
    # scripts keep full display size (contrast with the text-sized matrix cells above).
    ("align_fraction", raw"\begin{align} \frac{a}{b} &= c \\ d &= \frac{e}{f} \end{align}", "2cdb3c6e57faafc4a150d99b9bcd4f692e5d81f8d2e9f3fc74a3a4218a0a08f1"),
    ("gathered_script", raw"\begin{gathered} x^{\frac{1}{2}} \\ \sum_{i=1}^{n} i \end{gathered}", "4acc36219cb53cf2bf454443966e95eea9403d44e85f50f7d5c1726163676f00"),
]

const SNAPSHOT_DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}", "9e2225a12622b6fb899a598e18d3aada3423e312fe3d852f819c184ecc2b7a68"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$", "0c5c7f52083014d15d82916f3bd476d6b039361f1a559d854f15a50eb8774101"),
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
