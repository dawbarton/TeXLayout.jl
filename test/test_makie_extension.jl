# Tests for the optional MathTeXEngine extension.  The direct
# `julia --project=. test/runtests.jl` path does not install weak dependencies,
# so keep that core-only workflow usable and exercise this file under Pkg.test().

const _MAKIE_EXTENSION_PACKAGES = (
    "GeometryBasics",
    "LaTeXStrings",
    "MathTeXEngine",
)

if all(package -> Base.find_package(package) !== nothing, _MAKIE_EXTENSION_PACKAGES)
    @eval using GeometryBasics
    @eval using LaTeXStrings
    @eval import MathTeXEngine

    @testset "MathTeXEngine extension literal handling" begin
        ext = Base.get_extension(TeXLayout, :MathTeXEngineExt)
        @test ext !== nothing

        @test ext._is_inline_math(LaTeXString(raw"$x$"))
        @test ext._is_inline_math(LaTeXString(raw"$x\$$"))
        @test !ext._is_inline_math(LaTeXString(raw"$x\\$$"))
        @test !ext._is_inline_math(LaTeXString(raw"$x$ and $y$"))
        @test !ext._is_inline_math(LaTeXString(raw"$$x$$"))

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
else
    @info "Skipping MathTeXEngine extension tests; optional test dependencies are unavailable"
end
