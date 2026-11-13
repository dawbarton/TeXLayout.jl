# Text tests: composition primitives (`hconcat`, `vstack`, the internal box
# tree) and `layout_document` (src/boxes.jl, src/compose.jl).
#
# The fixture font and helpers come from runtests.jl and helpers.jl.

@testset "Text: composition and layout_document" begin
    family = FontFamily(FIXTURE_FONT_PATH)

    # ── Composition primitives ────────────────────────────────────────────────

    @testset "Composition primitives" begin

        @testset "hconcat: empty input → zero TeXBox" begin
            result = TeXLayout.hconcat(TeXLayout.TeXBox[])
            @test result.width == 0.0
            @test result.ascent == 0.0
            @test result.descent == 0.0
            @test isempty(result.boxes)
        end

        @testset "hconcat: width = sum, extents = max of parts" begin
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.8, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.5, 0.9, 0.3)
            result = TeXLayout.hconcat([b1, b2])
            @test result.width ≈ 2.5
            @test result.ascent ≈ 0.9
            @test result.descent ≈ 0.3
        end

        @testset "hconcat: second-part boxes are shifted right by first width" begin
            lb = LayoutBox(Space(0.5), 0.0, 0.0, 1.0)
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.5, 0.1)
            b2 = TeXLayout.TeXBox([lb], 0.5, 0.5, 0.1)
            result = TeXLayout.hconcat([b1, b2])
            @test result.boxes[1].x ≈ 1.0
        end

        @testset "Internal HBox shapes children with horizontal advances" begin
            lb = LayoutBox(Space(0.5), 0.0, 0.0, 1.0)
            empty = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            visible = TeXLayout.ShapedBox([lb], 0.5, 0.5, 0.1)
            tree = TeXLayout.HBox([empty, visible])
            boxes = TeXLayout.shape(tree)
            @test tree.width ≈ 1.5
            @test length(boxes) == 1
            @test boxes[1].x ≈ 1.0
        end

        @testset "Internal boxes validate measured extents" begin
            leaf = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.ShapedBox(LayoutBox[], -1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.ShapedBox(LayoutBox[], 1.0, NaN, 0.1)
            @test_throws ArgumentError TeXLayout.HBox([leaf], 1.0, 0.5, -0.1)
            @test_throws ArgumentError TeXLayout.VBox([leaf], [0.0], Float64[], 1.0, 0.5, 0.1)
            @test_throws ArgumentError TeXLayout.VBox([leaf], [Inf], [0.0], 1.0, 0.5, 0.1)
        end

        @testset "Internal boxes copy caller-owned vectors" begin
            lb = LayoutBox(Space(0.5), 0.25, 0.0, 1.0)
            shaped_source = [lb]
            shaped = TeXLayout.ShapedBox(shaped_source, 0.5, 0.5, 0.1)
            empty!(shaped_source)
            @test length(TeXLayout.shape(shaped)) == 1

            child_source = TeXLayout.Box[shaped]
            tree = TeXLayout.HBox(child_source)
            empty!(child_source)
            boxes = TeXLayout.shape(tree)
            @test length(boxes) == 1
            @test boxes[1].x ≈ 0.25
        end

        @testset "Internal nested boxes compose offsets recursively" begin
            lb = LayoutBox(Space(0.5), 0.25, 0.5, 1.0)
            empty = TeXLayout.ShapedBox(LayoutBox[], 1.0, 0.5, 0.1)
            visible = TeXLayout.ShapedBox([lb], 0.5, 0.5, 0.1)
            row = TeXLayout.HBox([empty, visible])
            column = TeXLayout.VBox([row], [-2.0], [3.0], row.width, row.ascent, 2.0)
            boxes = TeXLayout.shape(column)
            @test length(boxes) == 1
            @test boxes[1].x ≈ 4.25
            @test boxes[1].y ≈ -1.5
        end

        @testset "vstack: empty input → zero TeXBox" begin
            result = TeXLayout.vstack(
                TeXLayout.TeXBox[];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> :left,
            )
            @test result.width == 0.0
            @test result.ascent == 0.0
            @test result.descent == 0.0
        end

        @testset "vstack: single item is a passthrough" begin
            b = TeXLayout.TeXBox(LayoutBox[], 2.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.width ≈ 2.0
            @test result.ascent ≈ 0.7
            @test result.descent ≈ 0.2
        end

        @testset "vstack: advance capped to line_height for short lines" begin
            # depth(b1) + ascent(b2) + lineskip = 0.2 + 0.7 + 0.1 = 1.0 < 1.2
            b1 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b1, b2]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.ascent ≈ 0.7
            @test result.descent ≈ 1.4   # advance 1.2 + b2.descent 0.2
        end

        @testset "vstack: tall line forces lineskip advance > line_height" begin
            # depth(b_tall) + ascent(b_next) + lineskip = 1.0 + 1.5 + 0.1 = 2.6 > 1.2
            b_tall = TeXLayout.TeXBox(LayoutBox[], 1.0, 1.5, 1.0)
            b_next = TeXLayout.TeXBox(LayoutBox[], 1.0, 1.5, 0.2)
            result = TeXLayout.vstack(
                [b_tall, b_next];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> :left,
            )
            @test result.descent ≈ 2.8   # advance 2.6 + b_next.descent 0.2
        end

        @testset "vstack: width is max of item natural widths" begin
            b1 = TeXLayout.TeXBox(LayoutBox[], 3.0, 0.7, 0.2)
            b2 = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b1, b2]; line_height = 1.2, lineskip = 0.1, width = nothing, align_of = i -> :left,
            )
            @test result.width ≈ 3.0
        end

        @testset "vstack: fixed width overrides natural width" begin
            b = TeXLayout.TeXBox(LayoutBox[], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [b]; line_height = 1.2, lineskip = 0.1, width = 10.0, align_of = i -> :left,
            )
            @test result.width ≈ 10.0
        end

        @testset "vstack: right alignment shifts narrow item" begin
            lb = LayoutBox(Space(1.0), 0.0, 0.0, 1.0)
            wide = TeXLayout.TeXBox(LayoutBox[], 3.0, 0.7, 0.2)
            narrow = TeXLayout.TeXBox([lb], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [wide, narrow];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> (i == 2 ? :right : :left),
            )
            # The Space box (at local x=0) must be shifted right by (3.0 - 1.0) = 2.0.
            @test result.boxes[1].x ≈ 2.0
        end

        @testset "vstack: center alignment shifts narrow item" begin
            lb = LayoutBox(Space(1.0), 0.0, 0.0, 1.0)
            wide = TeXLayout.TeXBox(LayoutBox[], 4.0, 0.7, 0.2)
            narrow = TeXLayout.TeXBox([lb], 1.0, 0.7, 0.2)
            result = TeXLayout.vstack(
                [wide, narrow];
                line_height = 1.2,
                lineskip = 0.1,
                width = nothing,
                align_of = i -> (i == 2 ? :center : :left),
            )
            # Centred shift = (4.0 - 1.0) / 2 = 1.5.
            @test result.boxes[1].x ≈ 1.5
        end
    end

    # ── layout_document integration ───────────────────────────────────────────

    @testset "layout_document integration" begin

        @testset "LayoutOptions defaults" begin
            opts = TeXLayout.LayoutOptions()
            @test opts.align === TeXLayout.Alignment.Left
            @test opts.line_height ≈ 1.2
            @test opts.lineskip ≈ 0.1
            @test opts.width === nothing
            @test opts.display_align === TeXLayout.Alignment.Center
            @test opts.abovedisplayskip ≈ 0.5
            @test opts.belowdisplayskip ≈ 0.5
            @test opts.parskip ≈ 0.6
            @test opts.shaper isa TeXLayout.MetricShaper
        end

        @testset "Session-wide default layout options" begin
            saved = TeXLayout.default_layout_options()
            try
                @test TeXLayout.default_layout_options() isa TeXLayout.LayoutOptions

                # Keyword form overrides only the named fields (merge).
                TeXLayout.set_default_layout_options!(; width = 30.0, display_align = :right)
                cur = TeXLayout.default_layout_options()
                @test cur.width == 30.0
                @test cur.display_align === TeXLayout.Alignment.Right
                @test cur.align === TeXLayout.Alignment.Left      # untouched
                @test cur.parskip ≈ 0.6                           # untouched

                # layout_document picks up the global default.
                doc = TeXLayout.layout_document("hi \$x\$"; family = family)
                @test doc.width ≈ 30.0

                # Per-call kwargs override the global for that call only.
                doc2 = TeXLayout.layout_document("hi \$x\$"; family = family, width = 10.0)
                @test doc2.width ≈ 10.0
                @test TeXLayout.default_layout_options().width == 30.0

                # Positional form replaces wholesale (factory reset).
                TeXLayout.set_default_layout_options!(TeXLayout.LayoutOptions())
                @test TeXLayout.default_layout_options().width === nothing

                # Unknown option name is rejected.
                @test_throws ArgumentError TeXLayout.set_default_layout_options!(; widht = 1.0)
            finally
                TeXLayout.set_default_layout_options!(saved)
            end
        end

        @testset "Case 1: plain text, glyphs at y=0, ascent > 0" begin
            result = TeXLayout.layout_document("abc"; family = family)
            @test result isa TeXLayout.TeXBox
            @test result.ascent > 0.0
            @test result.descent >= 0.0
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 3
            @test all(b.y ≈ 0.0 for b in glyphs)
            @test glyphs[1].x ≈ 0.0
        end

        @testset "Case 2: line break → second baseline ≈ -1.2" begin
            result = TeXLayout.layout_document("a\\\\b"; family = family)
            glyphs = sort(
                filter(is_glyph_box, result.boxes);
                by = b -> b.y,
                rev = true,
            )
            @test length(glyphs) == 2
            @test glyphs[1].y ≈ 0.0
            @test glyphs[2].y ≈ -1.2 atol = 0.1
        end

        @testset "Blank line applies paragraph skip" begin
            line_result = TeXLayout.layout_document("a\\\\b"; family = family)
            para_result = TeXLayout.layout_document("a\n\nb"; family = family)

            line_ys = sort(
                unique(round(b.y; digits = 6) for b in line_result.boxes if is_glyph_box(b));
                rev = true,
            )
            para_ys = sort(
                unique(round(b.y; digits = 6) for b in para_result.boxes if is_glyph_box(b));
                rev = true,
            )
            @test length(line_ys) == 2
            @test length(para_ys) == 2
            @test line_ys[1] - line_ys[2] ≈ 1.2 atol = 0.1
            @test para_ys[1] - para_ys[2] ≈ 1.8 atol = 0.1

            custom = TeXLayout.layout_document("a\n\nb"; family = family, parskip = 0.25)
            custom_ys = sort(
                unique(round(b.y; digits = 6) for b in custom.boxes if is_glyph_box(b));
                rev = true,
            )
            @test custom_ys[1] - custom_ys[2] ≈ 1.45 atol = 0.1
        end

        @testset "Case 3: tall line forces advance > line_height" begin
            result = TeXLayout.layout_document("\$\\dfrac{a}{b}\$\\\\x"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test minimum(b.y for b in glyphs) < -1.2
        end

        @testset "Case 4: right alignment shifts narrow second line" begin
            result = TeXLayout.layout_document(
                "long text here\\\\x"; family = family, align = :right,
            )
            glyphs = filter(is_glyph_box, result.boxes)
            line2_glyphs = filter(b -> b.y < -0.5, glyphs)
            @test !isempty(line2_glyphs)
            @test minimum(b.x for b in line2_glyphs) > 0.0
        end

        @testset "Case 5: fixed width respected" begin
            result = TeXLayout.layout_document("abc"; family = family, width = 10.0)
            @test result.width ≈ 10.0
        end

        @testset "Case 6: inline math — superscript present, shared baseline" begin
            result = TeXLayout.layout_document("x is \$x^2\$ here"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) > 3
            # Math superscript must be above the baseline.
            @test maximum(b.y for b in glyphs) > 0.0
        end

        @testset "Case 8 (partial): display block appears below text line" begin
            result = TeXLayout.layout_document(
                "text\\\\\\begin{align}x&=y\\end{align}"; family = family,
            )
            @test !isempty(result.boxes)
            @test minimum(b.y for b in result.boxes) < 0.0
        end

        @testset "Case 8: worked example lays out without error" begin
            src = "\\textbf{Hello} world\\\\\\begin{align}x&=y\\\\y&=x^2-z\\end{align}"
            result = TeXLayout.layout_document(src; family = family)
            @test !isempty(result.boxes)
            @test minimum(b.y for b in result.boxes) < 0.0
        end

        @testset "Display-only document does not start with an empty baseline" begin
            full_family = font_family(:new_cm)
            result = TeXLayout.layout_document("\\begin{equation}x\\end{equation}"; family = full_family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 1
            @test abs(glyphs[1].y) < 0.2
            @test result.descent < 1.0
        end

        @testset "equation is a plain display, like \\[…\\]" begin
            # amsmath's equation has no strut and no \vcenter: its content sits
            # on the display baseline exactly as in \[…\].
            full_family = font_family(:new_cm)
            records(box) = sort([(string(typeof(b.element)), b.x, b.y, b.scale) for b in box.boxes])
            for body in ("E = mc^2", raw"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}")
                env = TeXLayout.layout_document("A\\begin{equation}$body\\end{equation}B"; family = full_family)
                brk = TeXLayout.layout_document("A\\[$body\\]B"; family = full_family)
                @test records(env) == records(brk)
                @test (env.width, env.ascent, env.descent) == (brk.width, brk.ascent, brk.descent)
            end
        end

        @testset "Display skips are explicit extra space, not synthetic lines" begin
            full_family = font_family(:new_cm)
            src = "\\begin{equation}x\\end{equation}b"
            no_skip = TeXLayout.layout_document(
                src; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.0,
            )
            below_skip = TeXLayout.layout_document(
                src; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.5,
            )

            function first_regular_y(box)
                glyphs = filter(
                    b -> is_glyph_box(b) &&
                        b.element.font_slot === TeXLayout.FontSlot.Regular,
                    box.boxes,
                )
                @test length(glyphs) == 1
                return glyphs[1].y
            end

            @test first_regular_y(below_skip) ≈ first_regular_y(no_skip) - 0.5

            src2 = "a\\begin{equation}x\\end{equation}"
            no_above = TeXLayout.layout_document(
                src2; family = full_family, abovedisplayskip = 0.0, belowdisplayskip = 0.0,
            )
            with_above = TeXLayout.layout_document(
                src2; family = full_family, abovedisplayskip = 0.5, belowdisplayskip = 0.0,
            )

            function first_math_y(box)
                glyphs = filter(
                    b -> b.element isa Glyph &&
                        b.element.font_slot === TeXLayout.FontSlot.Math,
                    box.boxes,
                )
                @test length(glyphs) == 1
                return glyphs[1].y
            end

            @test first_math_y(with_above) ≈ first_math_y(no_above) - 0.5
        end

        @testset "Adjacent display blocks stack below the first display" begin
            full_family = font_family(:new_cm)
            result = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}\\begin{equation}y\\end{equation}";
                family = full_family,
            )
            glyphs = filter(is_glyph_box, result.boxes)
            @test length(glyphs) == 2
            ys = sort([b.y for b in glyphs]; rev = true)
            @test abs(ys[1]) < 0.2
            @test ys[2] < ys[1] - 1.0
        end

        @testset "Display alignment shifts narrow display inside fixed width" begin
            full_family = font_family(:new_cm)
            left = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :left,
            )
            center = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :center,
            )
            right = TeXLayout.layout_document(
                "\\begin{equation}x\\end{equation}";
                family = full_family,
                width = 12.0,
                display_align = :right,
            )

            first_x(box) = only(filter(is_glyph_box, box.boxes)).x
            @test left.width ≈ 12.0
            @test center.width ≈ 12.0
            @test right.width ≈ 12.0
            @test first_x(left) < first_x(center) < first_x(right)
        end

        @testset "Fixed width smaller than content allows overflow but reports requested width" begin
            result = TeXLayout.layout_document(
                "wide text line"; family = family, width = 0.5, align = :center,
            )
            @test result.width ≈ 0.5
            @test minimum(b.x for b in result.boxes if is_glyph_box(b)) < 0.0
        end

        @testset "Case 9: first line glyphs have y ≈ 0 (y-origin invariant)" begin
            result = TeXLayout.layout_document("Hello world"; family = family)
            glyphs = filter(is_glyph_box, result.boxes)
            @test !isempty(glyphs)
            @test all(b.y ≈ 0.0 for b in glyphs)
        end

        @testset "Case 10: lenience — unclosed dollar" begin
            @test_nowarn TeXLayout.layout_document("\$unclosed"; family = family)
        end

        @testset "Case 10: lenience — trailing line break" begin
            @test_nowarn TeXLayout.layout_document("a\\\\"; family = family)
        end

        @testset "Case 10: lenience — unknown command" begin
            @test_nowarn TeXLayout.layout_document("\\unknown"; family = family)
        end

        @testset "Empty document returns empty TeXBox" begin
            result = TeXLayout.layout_document(""; family = family)
            @test result.width == 0.0
        end
    end
end
