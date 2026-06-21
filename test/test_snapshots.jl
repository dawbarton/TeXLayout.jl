using SHA

const SNAPSHOT_MATH_CASES = [
    ("simple_atom", raw"x+y=z", "c406b97f98f6af05b1c4ebd3799146c83cbb0d3954eb459706ac6e10e213c3f4"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}", "8590527a7489dd33a2f7c5ae9db6cdf8c42ccc64dd8f89b0b5e4268cf1f88aca"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)", "413d86661ebf097751806d50b9f63148fd8758d5b880d113fe41b15cf7880716"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx", "d9e0cafba1bfb7f18ec3a45d3e2d576b8b20639919ad8c41953afbf705633f8b"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}", "e5733c68ddfc5dd66a8ca3e69387c56e7d26062f05fe985cb889d1c8901828be"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", "e1950914fa964ae4c7f30c182137d7750da18a2de46ed0be1aa5440b0828b075"),
]

const SNAPSHOT_DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}", "936a2e4ea04a26f89cbe396226acf7f8d701c4105868ae1d7dc8809d49f0709f"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$", "38e695096188a456a72c1e4fa4d8ef2f8f036e7bc275b2f23b1b9fcea504516f"),
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
