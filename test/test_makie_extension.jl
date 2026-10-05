# Tests for the optional Makie integrations. The direct
# `julia --project=. test/runtests.jl` path does not install weak dependencies,
# so keep that core-only workflow usable and exercise this file under Pkg.test().

const _MAKIE_EXTENSION_PACKAGES = (
    "GeometryBasics",
    "LaTeXStrings",
    "MathTeXEngine",
)

# Both adapters route on this, and it needs no weak dependency, so it is tested
# unconditionally rather than only when the optional packages are installed.
@testset "inline-math routing" begin
    @test TeXLayout._is_inline_math(raw"$x$")
    @test TeXLayout._is_inline_math(raw"$α$")
    @test TeXLayout._is_inline_math(raw"$x\$$")
    @test !TeXLayout._is_inline_math(raw"$x\\$$")
    @test !TeXLayout._is_inline_math(raw"$x$ and $y$")
    @test !TeXLayout._is_inline_math(raw"$$x$$")

    # Delimiter stripping must use valid UTF-8 indices at both ends.
    @test TeXLayout._strip_math_delimiters(raw"$α$") == "α"
    @test TeXLayout._strip_math_delimiters("αβ") == "αβ"
    @test TeXLayout._strip_math_delimiters(raw"$$") == ""
end

if all(package -> Base.find_package(package) !== nothing, _MAKIE_EXTENSION_PACKAGES)
    @eval using GeometryBasics
    @eval using LaTeXStrings
    @eval import MathTeXEngine

    makie_ext = Base.get_extension(TeXLayout, :MakieExt)
    has_handler_interface =
        makie_ext !== nothing && makie_ext._HAS_LAYOUT_TEXT_INTERFACE

    if !has_handler_interface
        @testset "legacy MathTeXEngine extension literal handling" begin
            ext = Base.get_extension(TeXLayout, :MathTeXEngineExt)
            @test ext !== nothing

            texchars(elements) = [
                first(item) for item in elements
                    if first(item) isa MathTeXEngine.TeXChar
            ]

            previous_family = TeXLayout.default_font_family()
            try
                TeXLayout.set_default_font_family!(TeXLayout.font_family(:new_cm))

                math_commands = (
                    raw"\#", raw"\$", raw"\%", raw"\&", raw"\_",
                    raw"\{", raw"\}", raw"\lbrace", raw"\rbrace", raw"\|",
                )
                for command in math_commands
                    source = LaTeXString("\$" * command * "\$")
                    chars = texchars(MathTeXEngine.generate_tex_elements(source))
                    @test length(chars) == 1
                    @test only(chars).glyph_id > 0
                end

                text_commands = (
                    raw"\#", raw"\$", raw"\%", raw"\&", raw"\_", raw"\{", raw"\}",
                    raw"\textdollar", raw"\textunderscore",
                    raw"\textbraceleft", raw"\textbraceright",
                    raw"\textasciitilde", raw"\textbackslash",
                    raw"\textasciicircum", raw"\textbar", raw"\textbardbl",
                )
                for command in text_commands
                    chars = texchars(
                        MathTeXEngine.generate_tex_elements(LaTeXString(command)),
                    )
                    @test length(chars) == 1
                    @test only(chars).glyph_id > 0
                end
            finally
                TeXLayout.set_default_font_family!(previous_family)
            end
        end
    end
else
    @info "Skipping MathTeXEngine extension tests; optional test dependencies are unavailable"
end

if Base.find_package("Makie") !== nothing &&
        Base.find_package("LaTeXStrings") !== nothing
    @eval import Makie
    @eval using LaTeXStrings

    makie_ext = Base.get_extension(TeXLayout, :MakieExt)
    if makie_ext !== nothing && makie_ext._HAS_LAYOUT_TEXT_INTERFACE
        @testset "Makie text-handler extension" begin
            handler = TeXLayout.TeXLayoutHandler()
            scene = Makie.Scene(camera = Makie.campixel!)

            fraction = Makie.text!(
                scene,
                Makie.Point2f(0);
                text = LaTeXString(raw"$\frac{a}{b}$"),
                text_handler = handler,
                fontsize = 20,
            )
            @test length(fraction.glyph_indices[]) == 2
            @test length(fraction.text_specs[]) == 1
            @test length(fraction.text_spec_bboxes[]) == 1
            @test fraction.block_baselines[] == Float32[0]

            unicode_math = Makie.text!(
                scene,
                Makie.Point2f(0);
                text = LaTeXString(raw"$α$"),
                text_handler = handler,
            )
            @test length(unicode_math.glyph_indices[]) == 1

            ruled_matrix = Makie.text!(
                scene,
                Makie.Point2f(0);
                text = LaTeXString(raw"$\begin{array}{|c|}a\\b\end{array}$"),
                text_handler = handler,
                fontsize = 20,
            )
            @test length(ruled_matrix.text_specs[]) == 1
            @test length(first(ruled_matrix.text_specs[]).args[1]) >= 4
            @test Makie.width(first(ruled_matrix.text_spec_bboxes[])) > 0

            mixed = Makie.text!(
                scene,
                Makie.Point2f(0);
                text = LaTeXString(raw"left $x$ right"),
                text_handler = handler,
                fontsize = 20,
            )
            @test length(mixed.glyph_indices[]) == 12
            @test length(unique(mixed.glyph_fonts[])) >= 2

            combined = Makie.text!(
                scene,
                [Makie.Point2f(0), Makie.Point2f(100, 0)];
                text = Any[LaTeXString(raw"$x$"), "plain"],
                text_handler = handler,
            )
            @test length.(combined.text_blocks[]) == [1, 5]
        end
    else
        @info "Skipping Makie text-handler tests; installed Makie has no layout_text interface"
    end
else
    @info "Skipping Makie text-handler tests; optional test dependencies are unavailable"
end
