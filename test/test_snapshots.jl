using SHA

const SNAPSHOT_MATH_CASES = [
    ("simple_atom", raw"x+y=z", "0786a3175929982d6fd21cdf8b30cee84ff6664875a4fceedafd3b737eb40dcb"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}", "3d1d5fa752c26f2b349f1005241df8ada027d6be1aaa8920ab53def795a35489"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)", "e694695e4fd0a60b774b9df0e6427af0ec2d2f9aaefc8cfa7c7a7ea0e3e09819"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx", "93802cbb987572ab134833680f3adf05cf66aa703859a6818ff9f0fc9f99b3dc"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}", "a9bf70fe11b5ba491303efbaa12175e039de894f6262c294900ea6f414845960"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", "25f9e59f21d05c3f51882a661e098af95d1b56158332ee83585a5f179e5c9f23"),
]

const SNAPSHOT_DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}", "fbc536b930820864a65b8b7c01a899a129de901292b4f81e64db238f3193a603"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$", "9148e17818c1b28e8120e6dae5b1107d54a8aa4305d4db5f1dd7fbcfabc1edde"),
]

_snapshot_float(x) = string(round(Float64(x); digits = 10))
_snapshot_hash(s::AbstractString) = bytes2hex(sha256(codeunits(s)))

function _snapshot_boxes(boxes)
    io = IOBuffer()
    for box in boxes
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
            "\n",
        )
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
