# Smoke tests for command-line tools in `tools/`.

using Test

@testset "Tool smoke tests" begin
    repo_root = normpath(joinpath(@__DIR__, ".."))
    tool = joinpath(repo_root, "tools", "visualise_metrics.jl")
    out = joinpath(mktempdir(), "visualise_metrics.ppm")
    expr = raw"\frac{a}{b}"

    cmd = setenv(
        `$(Base.julia_cmd()) $tool $expr $out`,
        "JULIA_LOAD_PATH" => "@:@stdlib",
    )
    run(cmd)

    @test isfile(out)
    open(out, "r") do io
        @test readline(io) == "P6"
    end
end
