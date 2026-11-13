# Layout tests: matrix, array, and `cases` environments, and the amsmath
# alignments, against LaTeX + amsmath geometry.
#
# Layout tests check structural invariants derivable from the OpenType MATH
# constants rather than pixel positions.  Positions are in em; the fixture font
# and helpers come from runtests.jl and helpers.jl.

@testset "Layout: matrices and alignments" begin
    family = FontFamily(FIXTURE_FONT_PATH)
    mt = load_math_table(FIXTURE_FONT_PATH)

    # ── Matrix environments ───────────────────────────────────────────────────

    @testset "pmatrix 2×2: structure and centering" begin
        upm = Float64(mt.upm)
        boxes = layout(
            parse_latex(raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"),
            family, Display
        )
        glyphs = find_glyphs(boxes)
        # 4 letter glyphs + 2 parenthesis glyphs (left and right)
        @test length(glyphs) >= 6

        # Matrix must have positive total width and non-zero vertical extent.
        xs = [b.x for b in glyphs]
        @test maximum(xs) > minimum(xs)
        ys = [b.y for b in glyphs]
        @test maximum(ys) > minimum(ys)

        # Matrix should be vertically centred on the math axis.
        # The four content glyphs form two rows; top of upper row and bottom of
        # lower row should be roughly equidistant from the axis.
        axis_em = mt.constants.axis_height / upm
        letter_glyphs = filter(b -> !contains(b.element.glyph_name, "paren"), glyphs)
        top_y = maximum(b.y + b.element.y_max / upm * b.scale for b in letter_glyphs)
        bot_y = minimum(b.y + b.element.y_min / upm * b.scale for b in letter_glyphs)
        center = (top_y + bot_y) / 2
        @test abs(center - axis_em) < 0.15   # within 0.15 em of axis
    end

    @testset "pmatrix 2×2: columns and rows correctly separated" begin
        upm = Float64(mt.upm)
        boxes = layout(
            parse_latex(raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"),
            family, Display
        )
        glyphs = find_glyphs(boxes)
        letter_glyphs = sort(
            filter(b -> !contains(b.element.glyph_name, "paren"), glyphs);
            by = b -> (-round(b.y; digits = 2), b.x)
        )
        @test length(letter_glyphs) == 4
        # Row 0 (a, b) should be above row 1 (c, d).
        row0 = letter_glyphs[1:2]
        row1 = letter_glyphs[3:4]
        @test minimum(b.y for b in row0) > maximum(b.y for b in row1) - 1.0e-6
        # Column 0 (a, c) should be to the left of column 1 (b, d).
        @test row0[1].x < row0[2].x
        @test row1[1].x < row1[2].x
    end

    @testset "matrix (no delimiters): no parenthesis glyphs" begin
        boxes = layout(
            parse_latex(raw"\begin{matrix} a & b \\ c & d \end{matrix}"),
            family, Display
        )
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 4
        paren_boxes = filter(b -> contains(b.element.glyph_name, "paren"), glyphs)
        @test isempty(paren_boxes)
    end

    @testset "array: colspec column count differs from the cells used" begin
        glyph_name_of(ch) = TeXLayout.glyph_name_by_codepoint(family, UInt32(ch))
        digit_glyph(glyphs, ch) = only(filter(b -> b.element.glyph_name == glyph_name_of(ch), glyphs))
        centre(g) = g.x + g.element.advance_width / mt.upm * g.scale / 2
        for source in (
                # Valid LaTeX: the colspec declares more columns than are used.
                raw"\begin{array}{ccc} 1 & 2 \\ 3 & 4 \end{array}",
                # Malformed: more cells than declared columns; keep them all.
                raw"\begin{array}{|c|} 1 & 2 \\ 3 & 4 \end{array}",
            )
            boxes = layout(parse_latex(source), family, Display)
            glyphs = find_glyphs(boxes)
            @test length(glyphs) == 4
            g1, g2, g3, g4 = (digit_glyph(glyphs, ch) for ch in ('1', '2', '3', '4'))
            # Cells stay in their source rows and (centred) columns.
            @test g1.y ≈ g2.y
            @test g3.y ≈ g4.y
            @test g3.y < g1.y
            @test centre(g1) < centre(g2)
            @test centre(g1) ≈ centre(g3)
            @test centre(g2) ≈ centre(g4)
        end
        # The declared rules stay outermost; the extra column carries none.
        boxes = layout(parse_latex(raw"\begin{array}{|c|} 1 & 2 \end{array}"), family, Display)
        rules = find_elements(boxes, e -> e isa VRule)
        digits = find_glyphs(boxes)
        @test length(rules) == 2
        @test minimum(r.x for r in rules) < minimum(g.x for g in digits)
        @test maximum(r.x for r in rules) > maximum(g.x for g in digits)
    end

    @testset "cases: left brace present, no right brace" begin
        boxes = layout(
            parse_latex(raw"\begin{cases} f & x > 0 \\ 0 & \text{otherwise}\end{cases}"),
            family, Display
        )
        glyphs = find_glyphs(boxes)
        brace_boxes = filter(b -> contains(b.element.glyph_name, "brace"), glyphs)
        @test length(brace_boxes) >= 1
        # All braces should be on the left side.
        @test all(b.x < 0.5 for b in brace_boxes)
    end

    @testset "1×1 matrix: single cell" begin
        boxes = layout(parse_latex(raw"\begin{matrix} x \end{matrix}"), family, Display)
        glyphs = find_glyphs(boxes)
        @test length(glyphs) == 1
    end

    @testset "matrix in Display style uses Text style for cells" begin
        # In Display style, a standalone \frac shows the full-size fraction.
        # Inside a matrix (which uses Text style), the \frac numerator/denominator
        # should be at Script size, not Text size.
        upm = Float64(mt.upm)
        script_pct = mt.constants.script_percent_scale_down / 100.0
        boxes_plain = layout(parse_latex(raw"\frac{1}{2}"), family, Display)
        boxes_mat = layout(
            parse_latex(raw"\begin{matrix}\frac{1}{2}\end{matrix}"),
            family, Display
        )
        # Count distinct scales in the matrix fraction — should include script scale
        mat_glyphs = find_glyphs(boxes_mat)
        scales = unique(round.(b.scale for b in mat_glyphs; digits = 4))
        # Text-style \frac: numerator and denominator at ScriptScript ≈ 0.5
        # We just check that a sub-1.0 scale is present.
        @test any(s < 0.9 for s in scales)
    end

    @testset "Display alignment envs use Display style for cells" begin
        # align/gather/split/gathered are display environments: a \frac keeps its
        # full display size, unlike a matrix cell (which uses Text style).
        for env in ("align", "aligned", "split", "gather", "gathered", "equation")
            boxes = layout(
                parse_latex("\\begin{$env}\\frac{1}{2}\\end{$env}"),
                family, Display
            )
            scales = unique(round.(b.scale for b in find_glyphs(boxes); digits = 4))
            @test all(s ≈ 1.0 for s in scales)   # no script-size shrink
        end
        # A genuine array environment must still shrink the fraction (Text style).
        mat_scales = unique(
            round.(
                b.scale for b in find_glyphs(
                        layout(parse_latex(raw"\begin{matrix}\frac{1}{2}\end{matrix}"), family, Display)
                    );
                digits = 4,
            )
        )
        @test any(s < 0.9 for s in mat_scales)
    end

    @testset "Starred display envs alias the unstarred form" begin
        # Locate the first NodeKind.Matrix node in a tree (depth-first), or nothing.
        function find_matrix(n)
            n.kind == NodeKind.Matrix && return n
            for c in n.children
                m = find_matrix(c)
                m === nothing || return m
            end
            return nothing
        end
        for env in ("align", "gather", "equation")
            mu = find_matrix(parse_latex("\\begin{$env} a \\end{$env}"))
            ms = find_matrix(parse_latex("\\begin{$env*} a \\end{$env*}"))
            @test mu !== nothing && ms !== nothing
            @test mu.payload == ms.payload   # identical matrix payload
        end
    end

    @testset "array{lcr}: per-column alignment" begin
        # Left col should have its cell flush-left; right col flush-right; centre col centred.
        # Use wide characters so column widths differ enough to detect misalignment.
        boxes = layout(
            parse_latex(raw"\begin{array}{lcr} a & b & c \end{array}"),
            family, Display
        )
        glyphs = sort(find_glyphs(boxes); by = b -> b.x)
        # Three content glyphs: a (left-aligned), b (centred), c (right-aligned).
        @test length(glyphs) == 3
        # Glyphs must be left-to-right.
        @test glyphs[1].x < glyphs[2].x < glyphs[3].x
    end

    @testset "array with vertical rules: VRule boxes present" begin
        boxes = layout(
            parse_latex(raw"\begin{array}{|l|c|r|} a & b & c \end{array}"),
            family, Display
        )
        vrule_boxes = filter(b -> b.element isa VRule, boxes)
        glyph_boxes = find_glyphs(boxes)
        # Colspec "|l|c|r|" has 4 vertical rules: before col1, between 1-2, 2-3, after col3.
        @test length(vrule_boxes) == 4
        @test length(glyph_boxes) == 3
        # All vrule x positions should be distinct.
        vxs = sort([b.x for b in vrule_boxes])
        @test length(unique(round.(vxs; digits = 3))) == 4
    end

    @testset "array with no vertical rules: no VRule boxes" begin
        boxes = layout(
            parse_latex(raw"\begin{array}{lc} a & b \end{array}"),
            family, Display
        )
        @test isempty(filter(b -> b.element isa VRule, boxes))
    end

    @testset "array outer vertical rules only" begin
        boxes = layout(
            parse_latex(raw"\begin{array}{|ll|} a & b \end{array}"),
            family, Display
        )
        vrule_boxes = filter(b -> b.element isa VRule, boxes)
        @test length(vrule_boxes) == 2
        vxs = sort([b.x for b in vrule_boxes])
        # Left rule must be to the left of all glyphs; right rule to the right.
        glyph_xs = [b.x for b in find_glyphs(boxes)]
        @test vxs[1] < minimum(glyph_xs)
        @test vxs[2] > maximum(glyph_xs)
    end

    @testset "array lcr vs matrix: same cell x-span, different alignment" begin
        # In a centred matrix with identical content, cell 1 and cell 3 should be
        # at the same x in matrix{ccc} but at different x in array{lcr}.
        boxes_ccc = layout(
            parse_latex(raw"\begin{array}{ccc} a & b & c \end{array}"),
            family, Display
        )
        boxes_lcr = layout(
            parse_latex(raw"\begin{array}{lcr} a & b & c \end{array}"),
            family, Display
        )
        # Both should have 3 glyphs.
        g_ccc = sort(find_glyphs(boxes_ccc); by = b -> b.x)
        g_lcr = sort(find_glyphs(boxes_lcr); by = b -> b.x)
        @test length(g_ccc) == 3
        @test length(g_lcr) == 3
        # In lcr, col 1 (left-aligned) starts at the column left edge;
        # col 3 (right-aligned) starts further right than in the ccc version.
        # The leftmost glyph of lcr should be left of the leftmost glyph of ccc
        # (since ccc centres within the column, lcr flushes left).
        @test g_lcr[1].x <= g_ccc[1].x + 1.0e-6
    end

    @testset "array geometry matches LaTeX + amsmath" begin
        # Widths in em: LuaLaTeX + unicode-math at 10 pt with the bundled font
        # files.  array has \arraycolsep on both sides of every column, the
        # amsmath matrices drop the outer two, cases is @{}l@{\quad}l@{}, a `|`
        # takes no width and `||` adds \doublerulesep, and smallmatrix sets
        # script-style entries \thickspace apart inside thin spaces.
        width(src, fam = family) = TeXLayout.measure(layout(parse_latex(src), fam, Text), Float64(load_math_table(fam.math).upm)).width
        for (src, wd) in (
                (raw"\begin{matrix} a & b \\ c & d \end{matrix}", 2.073),
                (raw"\begin{array}{cc} a & b \end{array}", 2.972),
                (raw"\begin{array}{|c|c|} a & b \end{array}", 2.972),
                (raw"\begin{array}{c||c} a & b \end{array}", 3.172),
                (raw"\begin{pmatrix} 1 & 0 & 0 \\ 0 & 1 & 0 \\ 0 & 0 & 1 \end{pmatrix}", 5.25),
                (raw"\begin{cases} a & b \\ c & d \end{cases}", 3.095),
                (raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}", 5.832542),
                (raw"\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}", 1.467119),
                (raw"\left[\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}\right]", 2.147118),
            )
            @test width(src) ≈ wd atol = 1.0e-4
        end
        bonum = font_family(:bonum)
        @test width(raw"\begin{pmatrix} a & b \\ c & d \end{pmatrix}", bonum) ≈ 3.911 atol = 1.0e-4
        @test width(raw"\begin{bmatrix} a & b \\ c & d \end{bmatrix}", bonum) ≈ 3.575 atol = 1.0e-4

        # Rows carry \arraystretch × (0.84 em, 0.36 em) struts and touch, so
        # short entries sit 1.2 em apart (1.44 em in cases, stretch 1.2), and
        # the grid is centred on the axis by its strutted box.
        baseline(src, ps) = only(b.y for b in find_glyphs(layout(parse_latex(src), family, Text)) if b.element.glyph_name == ps)
        @test baseline(raw"\begin{matrix} a \\ b \end{matrix}", "u1D44E") - baseline(raw"\begin{matrix} a \\ b \end{matrix}", "u1D44F") ≈ 1.2 atol = 1.0e-9
        @test baseline(raw"\begin{cases} a \\ b \end{cases}", "u1D44E") - baseline(raw"\begin{cases} a \\ b \end{cases}", "u1D44F") ≈ 1.44 atol = 1.0e-9
        axis = mt.constants.axis_height / mt.upm
        @test baseline(raw"\begin{matrix} a \end{matrix}", "u1D44E") ≈ axis - (0.84 - 0.36) / 2 atol = 1.0e-9
        # smallmatrix entries are script style, so they take ssty alternates.
        small = layout(parse_latex(raw"\begin{smallmatrix} a \end{smallmatrix}"), family, Text)
        @test only(find_glyphs(small)).element.glyph_name == "u1D44E.st"
        @test only(find_glyphs(small)).scale ≈ mt.constants.script_percent_scale_down / 100
        # A one-column cases still ends with the \quad of its l@{\quad}l template.
        @test width(raw"\begin{cases} a \\ c \end{cases}") ≈ 2.551 atol = 1.0e-4
    end

    @testset "row spacing and alignments match LaTeX + amsmath" begin
        # TeX's box of each environment (struts included), from
        # `_layout_matrix_box!`, against LuaLaTeX's \ht and \dp at 10 pt in
        # NewCM, in em.  \\[len] deepens an array row to at least strut depth
        # plus len, but adds to the gap when negative and in smallmatrix and
        # the alignments; aligned and gathered rows carry \strut@ and are
        # \baselineskip + \jot (1.5 em) apart, or \lineskip + \jot (0.4 em)
        # clear of each other when taller.
        ctx = TeXLayout._LayoutCtx(family)
        function box(src)
            m = only(c for c in parse_latex(src).children if c.kind === NodeKind.Matrix)
            return TeXLayout._layout_matrix_box!(m, ctx, Text, 0.0, 0.0, 1.0, TeXLayout.LayoutBox[])
        end
        for (src, ht, dp) in (
                (raw"\begin{matrix} a \\[10pt] b \end{matrix}", 1.95, 1.45),
                (raw"\begin{matrix} a \\[1em] b \end{matrix}", 1.95, 1.45),
                (raw"\begin{matrix} a \\[-2pt] b \end{matrix}", 1.35, 0.85),
                (raw"\begin{matrix} \dfrac{a}{b} \\[2pt] c \end{matrix}", 1.758, 1.258),
                (raw"\begin{matrix} a \\ b \\[5pt] \end{matrix}", 1.7, 1.2),
                (raw"\begin{matrix} a \\[3mm] b \end{matrix}", 1.876791, 1.37679),
                (raw"\begin{smallmatrix} a \\[2pt] b \end{smallmatrix}", 0.829251, 0.329251),
                (raw"\begin{aligned} a &= b \\ c &= d \\ e &= f \end{aligned}", 2.35, 1.85),
                (raw"\begin{aligned} a &= b \\[5pt] c &= d \end{aligned}", 1.85, 1.35),
                (raw"\begin{aligned} a &= b \\[-2pt] c &= d \end{aligned}", 1.5, 1.0),
                (raw"\begin{aligned} x &= \sum_{i=1}^n a_i \\ y &= \sum_{j=1}^n b_j \end{aligned}", 3.072401, 2.5724),
                (raw"\begin{gathered} \sum_{i=1}^n a_i \\ b \end{gathered}", 2.32725, 1.82725),
            )
            b = box(src)
            @test b.height ≈ ht atol = 1.0e-4
            @test b.depth ≈ dp atol = 1.0e-4
        end
        # Column pairs are \minalignsep (1 em) apart, with no outer margin, and
        # alignments are Ord atoms (no space after `x`).
        width(src) = TeXLayout.measure(layout(parse_latex(src), family, Text), Float64(FONT_UPM)).width
        @test width(raw"\begin{aligned} a &= b & c &= d \end{aligned}") ≈ 5.641083 atol = 1.0e-4
        @test width(raw"\begin{aligned} a &= b & c &= d & e &= f \end{aligned}") ≈ 9.020624 atol = 1.0e-4
        @test width(raw"x\begin{aligned} a &= b \end{aligned}") ≈ 2.87754 atol = 1.0e-4
        @test width(raw"\begin{gathered} a \\ bbbb \end{gathered}") ≈ 1.771997 atol = 1.0e-4
    end

    @testset "align inserts relation spacing after alignment marker" begin
        boxes = layout(parse_latex("\\begin{align}x&=y\\end{align}"), family, Display)
        equal = only(filter(b -> b.element isa Glyph && b.element.glyph_name == "equal", boxes))
        relation_spaces = filter(
            b -> b.element isa Space &&
                isapprox(b.element.width, 5 / 18; atol = 1.0e-6) &&
                isapprox(b.x + b.element.width, equal.x; atol = 1.0e-6),
            boxes,
        )
        @test length(relation_spaces) == 1
    end

    @testset "align glues r/l pair without extra column spacing" begin
        # The relation in an align pair must sit exactly where it would in a plain
        # math list: only the relation atom's spacing, no inter-column colsep.
        align_eq = only(
            filter(
                b -> b.element isa Glyph && b.element.glyph_name == "equal",
                layout(parse_latex("\\begin{align}x&=y\\end{align}"), family, Display),
            ),
        )
        plain_eq = only(
            filter(
                b -> b.element isa Glyph && b.element.glyph_name == "equal",
                layout(parse_latex("x=y"), family, Display),
            ),
        )
        @test isapprox(align_eq.x, plain_eq.x; atol = 1.0e-6)
    end
end
