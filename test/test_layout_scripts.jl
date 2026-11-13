# Layout tests: superscripts and subscripts (TeX rules 17 and 18), italic
# corrections before scripts, and `ssty` script alternates.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: scripts" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    @testset "Superscript is above baseline" begin
        # In x^2, the '2' must have a positive y offset.
        boxes = layout(parse_latex("x^2"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        base_y = glyphs[1].y
        sup_y = glyphs[2].y
        @test sup_y > base_y
        # The superscript shift is at least SuperscriptShiftUp/UPM (in em).
        min_shift = mt.constants.superscript_shift_up / FONT_UPM
        @test sup_y >= min_shift - 1.0e-6
    end

    @testset "Subscript is below baseline" begin
        boxes = layout(parse_latex("x_i"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 2
        sub_y = glyphs[2].y
        @test sub_y < 0.0   # below baseline
    end

    @testset "NodeKind.Decorated: both sub and sup positioned correctly" begin
        # x_i^2 should produce three glyphs: base at y=0, sup above baseline, sub below.
        boxes = layout(parse_latex("x_i^2"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 3
        # Base (x) is at the formula baseline.
        base_y = glyphs[1].y
        @test base_y ≈ 0.0
        # Superscript is above; subscript is below.
        ys = [b.y for b in glyphs]
        @test maximum(ys) > 0.0   # sup above baseline
        @test minimum(ys) < 0.0   # sub below baseline
        # Both scripts are at the same horizontal origin (x + base_advance).
        script_xs = sort([glyphs[2].x, glyphs[3].x])
        @test script_xs[1] ≈ script_xs[2] atol = 1.0e-6
    end

    @testset "Superscript scale in Text style" begin
        boxes = layout(parse_latex("x^2"), family, Text)
        glyphs = find_glyphs(boxes)
        base_scale = glyphs[1].scale
        sup_scale = glyphs[2].scale
        expected = mt.constants.script_percent_scale_down / 100.0
        @test sup_scale ≈ base_scale * expected atol = 1.0e-6
    end

    @testset "Italic correction: kern after math characters, scripts per TeX rule 17" begin
        ic(name) = get(mt.italic_corrections, name, 0) / mt.upm
        # V carries a large italic correction in New Computer Modern Math.
        v_boxes = layout(parse_latex("V_i"), family, Display)
        v = first(find_glyphs(v_boxes))
        v_adv = v.element.advance_width / mt.upm
        @test ic(v.element.glyph_name) > 0.1
        sub = only(filter(b -> b.element isa Glyph && b.scale < 0.99, v_boxes))
        @test sub.x ≈ v_adv atol = 1.0e-9                       # subscript at the advance
        f_boxes = layout(parse_latex("f^2"), family, Display)
        f = first(find_glyphs(f_boxes))
        sup = only(filter(b -> b.element isa Glyph && b.scale < 0.99, f_boxes))
        @test sup.x ≈ f.element.advance_width / mt.upm + ic(f.element.glyph_name) atol = 1.0e-9
        # A lone italic letter is followed by its italic kern (it counts in the width).
        lone = TeXLayout.measure(layout(parse_latex("f"), family, Display), Float64(mt.upm))
        @test lone.width ≈ f.element.advance_width / mt.upm + ic(f.element.glyph_name)
        # A compound base gets no correction from its first glyph.
        fa = layout(parse_latex("{fa}_i"), family, Display)
        fa_sub = only(filter(b -> b.element isa Glyph && b.scale < 0.99, fa))
        a = find_glyphs(fa)[2]
        @test fa_sub.x ≈ a.x + a.element.advance_width / mt.upm + ic(a.element.glyph_name)
        # Large operators keep the subscript tucked under the slanted stroke.
        int_boxes = layout(parse_latex(raw"\int_0"), family, Text)
        int = first(find_glyphs(int_boxes))
        int_sub = only(filter(b -> b.element isa Glyph && b.scale < 0.99, int_boxes))
        @test int_sub.x ≈ int.element.advance_width / mt.upm - ic(int.element.glyph_name)
    end

    @testset "Italic correction: kept on a lone character, dropped inside text-alphabet words" begin
        # XeTeX and LuaTeX with OpenType math fonts keep a lone character's
        # correction as a fraction part, script, or accent nucleus (measured with
        # TeX Gyre Bonum Math: \hat{f}( sets the parenthesis where f( does, and
        # \overline{f}, \frac{f}{f}, x^{f}, and x_V all keep it).  TeX82's
        # clean_box would drop it there; TeXLayout follows the OpenType engines.
        fic = get(mt.italic_corrections, "u1D453", 0) / mt.upm
        @test fic > 0
        fadv = glyph_metrics_by_codepoint(family, UInt32(0x0001D453)).advance_width / mt.upm
        # In a script f is its ssty alternate, which carries its own correction.
        function kern_after_f(src)
            bs = layout(parse_latex(src), family, Text)
            f = only(b for b in find_glyphs(bs) if startswith(b.element.glyph_name, "u1D453"))
            fic = get(mt.italic_corrections, f.element.glyph_name, 0) / mt.upm
            return fic > 0 && any(b -> b.element isa Space && b.element.width ≈ fic * b.scale, bs)
        end
        for src in ("f", raw"\frac{f}{2}", raw"\sqrt{f}", raw"x^{f}", raw"\overline{f}")
            @test kern_after_f(src)
        end
        star_x(src) = only(b.x for b in find_glyphs(layout(parse_latex(src), family, Text)) if b.element.glyph_name == "asteriskmath")
        @test star_x(raw"\hat{f}*") ≈ star_x("f*") atol = 1.0e-9
        # Text alphabets add no correction between letters, only after the word
        # (tex.web §752; unicode-math's \mathit is a text font, while the
        # math-font \symit keeps a correction after every letter).
        mathit = layout(parse_latex(raw"\mathit{ff}"), family, Text)
        fs = sort([b for b in find_glyphs(mathit)]; by = b -> b.x)
        @test fs[2].x - fs[1].x ≈ fadv atol = 1.0e-9
        @test count(b -> b.element isa Space, mathit) == 1
        plain = sort(find_glyphs(layout(parse_latex("ff"), family, Text)); by = b -> b.x)
        @test plain[2].x - plain[1].x ≈ fadv + fic atol = 1.0e-9
    end

    @testset "Scripts use the font's ssty alternates" begin
        # XeTeX and LuaTeX set script sizes with GSUB ssty=0 and scriptscript
        # sizes with ssty=1.  Widths are LuaLaTeX + unicode-math at 10 pt with
        # the bundled font files, in em; a trailing digit marks the end of a
        # scripted atom so that \scriptspace is included.
        names(src, fam = family) = Set(b.element.glyph_name for b in find_glyphs(layout(parse_latex(src), fam, Text)))
        @test names("x") == Set(["u1D465"])
        @test "u1D465.st" in names("a_x")
        @test "u1D465.sts" in names("a_{b_x}")
        @test "three.sts" in names(raw"\sqrt[3]{x}")
        @test "minute.st" in names("f'")
        # Text inside a script stays in the text font.
        @test !any(endswith(".st"), names(raw"a_{\text{x}}"))
        width(src, fam) = TeXLayout.measure(layout(parse_latex(src), fam, Text), Float64(load_math_table(fam.math).upm)).width
        marker(src, fam) = only(b.x for b in find_glyphs(layout(parse_latex(src * "1"), fam, Text)) if b.element.glyph_name == "one")
        @test width(raw"{\scriptscriptstyle 3}", family) ≈ 0.3405 atol = 1.0e-4
        @test width(raw"\sqrt[3]{x}", family) ≈ 1.4675 atol = 1.0e-4
        bonum = font_family(:bonum)
        @test width(raw"{\scriptstyle x}", bonum) ≈ 0.5598 atol = 1.0e-4
        @test width(raw"{\scriptstyle V}", bonum) ≈ 0.71995 atol = 1.0e-4
        @test marker("x_x", bonum) ≈ 1.1398 atol = 1.0e-4
        @test marker("x_V", bonum) ≈ 1.29995 atol = 1.0e-4
        # Primes: the ssty prime, unicode-math's multiple-prime characters, and
        # its -1.5 mu kern between the primes of a longer run.
        for (src, wd) in (("f'", 0.920898), ("f''", 1.088899), ("f'''", 1.256898), ("f''''", 1.4249), ("f'''''", 1.827167), ("f''^2", 1.4872))
            @test marker(src, family) ≈ wd atol = 1.0e-4
        end
        @test marker("f'''''", bonum) ≈ 2.054642 atol = 1.0e-4
    end
end
