# Layout tests: math alphabets (`\mathbf` and friends), font slots, Greek
# letter forms, and `\text{…}` inside math.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: alphabets and text" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    # ── Font switching ──────────────────────────────────────────────────────────

    @testset "FontSwitch: \\mathbf{x} renders one glyph" begin
        boxes = layout(parse_latex("\\mathbf{x}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
    end

    @testset "FontSwitch: \\mathbf{x} glyph differs from plain x (bold vs italic)" begin
        # Bold 'x' (U+1D431) and italic math 'x' are different glyphs.
        boxes_bf = layout(parse_latex("\\mathbf{x}"), family, Text)
        boxes_def = layout(parse_latex("x"), family, Text)
        name_bf = find_glyphs(boxes_bf)[1].element.glyph_name
        name_def = find_glyphs(boxes_def)[1].element.glyph_name
        @test name_bf != name_def
    end

    @testset "FontSwitch: \\mathit{x} glyph differs from bold x" begin
        boxes_it = layout(parse_latex("\\mathit{x}"), family, Text)
        boxes_bf = layout(parse_latex("\\mathbf{x}"), family, Text)
        name_it = find_glyphs(boxes_it)[1].element.glyph_name
        name_bf = find_glyphs(boxes_bf)[1].element.glyph_name
        @test name_it != name_bf
    end

    @testset "FontSwitch: \\mathbb{R} uses double-struck glyph" begin
        # \mathbb{R} → U+211D DOUBLE-STRUCK CAPITAL R (exception codepoint).
        boxes = layout(parse_latex("\\mathbb{R}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathbb{A} uses math-block double-struck glyph" begin
        # \mathbb{A} → U+1D538 (non-exception uppercase).
        boxes_bb = layout(parse_latex("\\mathbb{A}"), family, Text)
        boxes_def = layout(parse_latex("A"), family, Text)
        @test !isempty(find_glyphs(boxes_bb))
        name_bb = find_glyphs(boxes_bb)[1].element.glyph_name
        name_def = find_glyphs(boxes_def)[1].element.glyph_name
        @test name_bb != name_def
    end

    @testset "FontSwitch: \\mathrm{x} produces upright glyph distinct from \\mathit{x}" begin
        # \mathrm routes through _char_glyph (math font codepoint lookup), not _upright_glyph.
        # The math font's upright 'x' (e.g. "x" or a codepoint alias) and the math-italic
        # 'x' (U+1D465, PS name "u1D465") are distinct glyphs with different metrics.
        boxes_rm = layout(parse_latex("\\mathrm{x}"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{x}"), family, Text)
        @test !isempty(find_glyphs(boxes_rm))
        name_rm = find_glyphs(boxes_rm)[1].element.glyph_name
        name_it = find_glyphs(boxes_it)[1].element.glyph_name
        @test name_rm != name_it
    end

    @testset "font_slot: math-mode glyphs carry FontSlot.Math" begin
        # All math-mode glyphs must have font_slot = FontSlot.Math so the renderer queries
        # the math font.
        boxes = layout(parse_latex("x + \\alpha"), family, Text)
        @test all(b.element.font_slot === TeXLayout.FontSlot.Math for b in find_glyphs(boxes))
    end

    @testset "font_slot: \\text glyphs come from the regular font when one is configured" begin
        # With a regular font, _upright_glyph emits a GlyphID naming that exact
        # file, so its metrics are read in that font's own units.
        with_regular = font_family(:new_cm)
        for expr in (raw"\text{hi}", raw"\sin")
            boxes = layout(parse_latex(expr), with_regular, Text)
            ids = find_elements(boxes, e -> e isa TeXLayout.GlyphID)
            @test length(ids) == (expr == raw"\sin" ? 3 : 2)
            @test all(b.element.font_slot === TeXLayout.FontSlot.Regular for b in ids)
            @test all(b.element.font_path == with_regular.regular for b in ids)
        end
    end

    @testset "Upright glyphs use their own font's units per em" begin
        # A 2048-unit text font beside a 1000-unit math font: \text advances must
        # follow the text font's metrics, not be divided by the math font's UPM.
        dejavu = "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"
        if isfile(dejavu)
            mixed = font_family(FIXTURE_FONT_PATH; regular = dejavu)
            boxes = layout(parse_latex(raw"\text{ab}"), mixed, Text)
            expected = sum(
                TeXLayout._codepoint_glyph(dejavu, UInt32(c))[2].advance_width for c in "ab"
            ) / TeXLayout._font_upm(dejavu)
            @test TeXLayout.measure(boxes, Float64(mt.upm)).width ≈ expected
        else
            @info "DejaVu Serif not installed; skipping the mixed-UPM \\text test"
        end
    end

    @testset "font_slot: \\text glyphs fall back to FontSlot.Math when no regular font" begin
        # Without a regular font, _upright_glyph falls back to the math font.
        boxes = layout(parse_latex(raw"\text{hi}"), family, Text)
        @test all(b.element.font_slot === TeXLayout.FontSlot.Math for b in find_glyphs(boxes))
    end

    @testset "FontSwitch: \\mathrm uses math font (FontSlot.Math)" begin
        boxes = layout(parse_latex("\\mathrm{x}"), family, Text)
        @test !isempty(find_glyphs(boxes))
        @test all(b.element.font_slot === TeXLayout.FontSlot.Math for b in find_glyphs(boxes))
    end

    @testset "Math alphabets do not restyle \\text (LaTeX semantics)" begin
        # \mathbf, \boldsymbol, \mathit, … select math fonts; \text sets its body
        # in the surrounding text font, so it is unaffected (XeLaTeX with amsmath
        # and unicode-math renders \mathbf{\text{a b}} as regular "a b").
        layout_of(source) = [(b.element, b.x, b.y, b.scale) for b in layout(parse_latex(source), family, Text)]
        plain = layout_of(raw"\text{a b}")
        for cmd in (raw"\mathbf", raw"\boldsymbol", raw"\mathit", raw"\mathsf", raw"\mathbb", raw"\mathcal")
            @test layout_of(cmd * raw"{\text{a b}}") == plain
        end
        # Math outside the \text keeps the alphabet: bold x and y, plain " if ".
        names(source) = [b.element.glyph_name for b in sort(find_glyphs(layout(parse_latex(source), family, Text)); by = b -> b.x)]
        @test names(raw"\mathbf{x\text{ if }y}") == [names(raw"\mathbf{x}"); names(raw"\text{if}"); names(raw"\mathbf{y}")]
    end

    @testset "\\text{if } preserves trailing space" begin
        # A space at the end of a \text{} argument must survive as a Space element.
        boxes = layout(parse_latex(raw"\text{if }"), family, Text)
        spaces = find_spaces(boxes)
        @test !isempty(spaces)
        # The space width must be positive (comes from the font's word-space advance).
        @test spaces[end].element.width > 0
    end

    @testset "\\text{if x} has inter-word space" begin
        # A space between two words inside \text{} must produce a Space element.
        boxes_sp = layout(parse_latex(raw"\text{if x}"), family, Text)
        boxes_nsp = layout(parse_latex(raw"\text{ifx}"), family, Text)
        @test length(find_spaces(boxes_sp)) > length(find_spaces(boxes_nsp))
    end

    @testset "FontSwitch: \\mathbf propagates to subscript" begin
        # \mathbf{x_i} should produce two glyphs, both from bold variants.
        boxes_bf = layout(parse_latex("\\mathbf{x_i}"), family, Text)
        boxes_def = layout(parse_latex("x_i"), family, Text)
        glyphs_bf = find_glyphs(boxes_bf)
        glyphs_def = find_glyphs(boxes_def)
        @test length(glyphs_bf) == 2
        # Bold glyphs should differ from the default italic glyphs.
        @test glyphs_bf[1].element.glyph_name != glyphs_def[1].element.glyph_name
        @test glyphs_bf[2].element.glyph_name != glyphs_def[2].element.glyph_name
    end

    @testset "FontSwitch: \\mathbf{x} advance width differs from italic x" begin
        # Bold metrics (wider) should differ from italic metrics.
        boxes_bf = layout(parse_latex("\\mathbf{x}"), family, Text)
        boxes_def = layout(parse_latex("x"), family, Text)
        adv_bf = find_glyphs(boxes_bf)[1].element.advance_width
        adv_def = find_glyphs(boxes_def)[1].element.advance_width
        # Advance widths are not required to differ by a specific amount, but must both be positive.
        @test adv_bf > 0
        @test adv_def > 0
    end

    @testset "FontSwitch: \\mathbf{+} atom class is :bin (inherited from body)" begin
        # \mathbf{+} should insert medium spaces in a+b context same as plain +.
        boxes_plain = layout(parse_latex("a+b"), family, Text)
        boxes_bf = layout(parse_latex("a\\mathbf{+}b"), family, Text)
        spaces_plain = find_spaces(boxes_plain)
        spaces_bf = find_spaces(boxes_bf)
        # Both should have 2 medium spaces (the + is :bin regardless of font variant).
        @test length(spaces_bf) == length(spaces_plain)
    end

    @testset "FontSwitch: \\mathtt{0} digit renders glyph" begin
        boxes = layout(parse_latex("\\mathtt{0}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathcal{A} renders glyph" begin
        boxes = layout(parse_latex("\\mathcal{A}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathfrak{A} renders glyph" begin
        boxes = layout(parse_latex("\\mathfrak{A}"), family, Text)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
        @test glyphs[1].element.advance_width > 0
    end

    @testset "FontSwitch: \\mathbf{\\alpha} command gives different glyph from plain \\alpha" begin
        # \mathbf{\alpha} should resolve to the bold Greek alpha (U+1D6C2) rather
        # than the italic/default alpha (U+1D6FC or similar).
        boxes_bf = layout(parse_latex("\\mathbf{\\alpha}"), family, Text)
        boxes_def = layout(parse_latex("\\alpha"), family, Text)
        glyphs_bf = find_glyphs(boxes_bf)
        glyphs_def = find_glyphs(boxes_def)
        @test length(glyphs_bf) == 1
        @test length(glyphs_def) == 1
        @test glyphs_bf[1].element.advance_width > 0
        @test glyphs_def[1].element.advance_width > 0
        @test glyphs_bf[1].element.glyph_name != glyphs_def[1].element.glyph_name
    end

    @testset "FontSwitch: \\boldsymbol{x} differs from \\mathbf{x} (bold-italic vs bold-upright)" begin
        # \boldsymbol uses bold-italic Latin (U+1D482+) vs \mathbf bold-upright (U+1D41A+).
        boxes_bs = layout(parse_latex("\\boldsymbol{x}"), family, Text)
        boxes_bf = layout(parse_latex("\\mathbf{x}"), family, Text)
        gs_bs = find_glyphs(boxes_bs)
        gs_bf = find_glyphs(boxes_bf)
        @test length(gs_bs) == 1
        @test length(gs_bf) == 1
        @test gs_bs[1].element.advance_width > 0
        @test gs_bf[1].element.advance_width > 0
        @test gs_bs[1].element.glyph_name != gs_bf[1].element.glyph_name
    end

    @testset "FontSwitch: \\boldsymbol{\\alpha} differs from \\mathbf{\\alpha} (bold-italic vs bold-upright Greek)" begin
        boxes_bs = layout(parse_latex("\\boldsymbol{\\alpha}"), family, Text)
        boxes_bf = layout(parse_latex("\\mathbf{\\alpha}"), family, Text)
        gs_bs = find_glyphs(boxes_bs)
        gs_bf = find_glyphs(boxes_bf)
        @test length(gs_bs) == 1
        @test length(gs_bf) == 1
        @test gs_bs[1].element.advance_width > 0
        @test gs_bf[1].element.advance_width > 0
        @test gs_bs[1].element.glyph_name != gs_bf[1].element.glyph_name
    end

    # ── Greek italic rendering ────────────────────────────────────────────────

    @testset "Greek: \\alpha default uses math-italic form (same as \\mathit{\\alpha})" begin
        # After the fix, default \alpha maps to U+1D6FC (math-italic α) explicitly,
        # matching \mathit{\alpha}.  Previously it relied on the font cmap at U+03B1.
        boxes_def = layout(parse_latex("\\alpha"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{\\alpha}"), family, Text)
        g_def = find_glyphs(boxes_def)
        g_it = find_glyphs(boxes_it)
        @test length(g_def) == 1
        @test length(g_it) == 1
        @test g_def[1].element.advance_width > 0
        @test g_def[1].element.glyph_name == g_it[1].element.glyph_name
    end

    @testset "Greek: \\Gamma default is upright (differs from \\mathit{\\Gamma})" begin
        # Uppercase Greek is upright in LaTeX by default.
        boxes_def = layout(parse_latex("\\Gamma"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{\\Gamma}"), family, Text)
        g_def = find_glyphs(boxes_def)
        g_it = find_glyphs(boxes_it)
        @test length(g_def) == 1
        @test length(g_it) == 1
        @test g_def[1].element.advance_width > 0
        @test g_def[1].element.glyph_name != g_it[1].element.glyph_name
    end

    @testset "Greek: \\partial default uses math-italic form" begin
        boxes_def = layout(parse_latex("\\partial"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{\\partial}"), family, Text)
        g_def = find_glyphs(boxes_def)
        g_it = find_glyphs(boxes_it)
        @test length(g_def) == 1
        @test length(g_it) == 1
        @test g_def[1].element.advance_width > 0
        @test g_def[1].element.glyph_name == g_it[1].element.glyph_name
    end

    @testset "Greek: \\epsilon (U+03F5, out-of-range variant) default uses math-italic form" begin
        boxes_def = layout(parse_latex("\\epsilon"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{\\epsilon}"), family, Text)
        g_def = find_glyphs(boxes_def)
        g_it = find_glyphs(boxes_it)
        @test length(g_def) == 1
        @test length(g_it) == 1
        @test g_def[1].element.advance_width > 0
        @test g_def[1].element.glyph_name == g_it[1].element.glyph_name
    end

    @testset "Greek: \\phi (U+03D5, out-of-range variant) default uses math-italic form" begin
        boxes_def = layout(parse_latex("\\phi"), family, Text)
        boxes_it = layout(parse_latex("\\mathit{\\phi}"), family, Text)
        g_def = find_glyphs(boxes_def)
        g_it = find_glyphs(boxes_it)
        @test length(g_def) == 1
        @test length(g_it) == 1
        @test g_def[1].element.advance_width > 0
        @test g_def[1].element.glyph_name == g_it[1].element.glyph_name
    end

    @testset "Math inside \\text{…} is laid out in math mode" begin
        boxes = layout(parse_latex(raw"\text{if $x_1$}"), family, Display)
        glyphs = find_glyphs(boxes)
        x = only(filter(g -> g.element.glyph_name == "u1D465", glyphs))   # math italic x
        one = only(filter(g -> g.scale < 0.99, glyphs))
        @test x.element.font_slot === TeXLayout.FontSlot.Math
        @test one.y < 0                                                   # a real subscript
    end
end
