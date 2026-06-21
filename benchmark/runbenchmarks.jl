using BenchmarkTools
using Printf
using TOML
using TeXLayout

const ROOT = dirname(@__DIR__)
const DEFAULT_BASELINE = joinpath(@__DIR__, "baseline.toml")
const DEFAULT_OUTPUT = joinpath(@__DIR__, "latest.toml")

const MATH_CASES = [
    ("simple_atom", raw"x+y=z"),
    ("scripts_fraction", raw"\frac{x_i^2}{1+\sqrt{x}}"),
    ("radical_delimited", raw"\left(\frac{a}{b}\right)"),
    ("large_operator", raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx"),
    ("accents_braces_arrows", raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}"),
    ("matrix_cases", raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}"),
]

const DOCUMENT_CASES = [
    ("document_inline_display", raw"Energy $E=mc^2$\\\begin{align} a&=b+c\\ d&=e-f \end{align}"),
    ("document_text_styles", raw"A \textbf{bold $x_i$} word and $\frac{1}{2}$"),
]

function _arg_value(prefix::String, default)
    for arg in ARGS
        startswith(arg, prefix * "=") && return split(arg, "="; limit = 2)[2]
    end
    return default
end

function _arg_float(prefix::String, default::Float64)
    value = _arg_value(prefix, nothing)
    value === nothing && return default
    parsed = tryparse(Float64, value)
    parsed === nothing && error("invalid --$prefix value: $value")
    return parsed
end

function _arg_int(prefix::String, default::Int)
    value = _arg_value(prefix, nothing)
    value === nothing && return default
    parsed = tryparse(Int, value)
    parsed === nothing && error("invalid --$prefix value: $value")
    return parsed
end

function _benchmark_specs(family)
    specs = Pair{String, Any}[]
    for (name, expr) in MATH_CASES
        node = TeXLayout.parse_latex(expr)
        push!(specs, "tokenize/$name" => @benchmarkable TeXLayout.tokenize($expr))
        push!(specs, "parse/$name" => @benchmarkable TeXLayout.parse_latex($expr))
        push!(specs, "layout/$name" => @benchmarkable TeXLayout.layout($node, $family, TeXLayout.Display))
        push!(specs, "generate/$name" => @benchmarkable TeXLayout.generate_tex_elements($expr, $family))
    end
    for (name, expr) in DOCUMENT_CASES
        push!(specs, "layout_document/$name" => @benchmarkable TeXLayout.layout_document($expr; family = $family))
    end
    return specs
end

function _run_benchmarks(; seconds::Float64, samples::Int)
    family = TeXLayout.font_family(:new_cm)
    results = Dict{String, Any}()
    for (name, bench) in _benchmark_specs(family)
        trial = run(bench; seconds, samples)
        estimate = median(trial)
        results[name] = Dict(
            "time_ns" => Float64(estimate.time),
            "memory_bytes" => Int(estimate.memory),
            "allocs" => Int(estimate.allocs),
        )
        @printf(
            "%-48s %10.1f ns  %8d bytes  %5d allocs\n",
            name, estimate.time, estimate.memory, estimate.allocs
        )
    end
    return results
end

function _write_results(path::AbstractString, results)
    open(path, "w") do io
        TOML.print(io, results)
    end
    return path
end

function _compare_results(results, baseline; time_threshold::Float64, allocation_threshold::Float64)
    failed = String[]
    for name in sort(collect(keys(baseline)))
        haskey(results, name) || continue
        current = results[name]
        previous = baseline[name]
        time_ratio = current["time_ns"] / previous["time_ns"]
        memory_ratio = previous["memory_bytes"] == 0 ? 1.0 :
            current["memory_bytes"] / previous["memory_bytes"]
        alloc_ratio = previous["allocs"] == 0 ? 1.0 :
            current["allocs"] / previous["allocs"]
        if time_ratio > time_threshold || memory_ratio > allocation_threshold ||
                alloc_ratio > allocation_threshold
            push!(
                failed,
                @sprintf(
                    "%s: time %.2fx, memory %.2fx, allocs %.2fx",
                    name, time_ratio, memory_ratio, alloc_ratio
                ),
            )
        end
    end
    return failed
end

function main()
    seconds = _arg_float("--seconds", 1.0)
    samples = _arg_int("--samples", 10)
    output = _arg_value("--output", DEFAULT_OUTPUT)
    baseline_path = _arg_value("--baseline", DEFAULT_BASELINE)
    time_threshold = _arg_float("--time-threshold", 1.15)
    allocation_threshold = _arg_float("--allocation-threshold", 1.2)
    update_baseline = "--update-baseline" in ARGS
    compare = "--compare" in ARGS || isfile(baseline_path)

    results = _run_benchmarks(; seconds, samples)
    _write_results(output, results)
    @info "wrote benchmark results" output

    if update_baseline
        _write_results(baseline_path, results)
        @info "updated benchmark baseline" baseline_path
    elseif compare && isfile(baseline_path)
        baseline = TOML.parsefile(baseline_path)
        failures = _compare_results(
            results, baseline;
            time_threshold,
            allocation_threshold,
        )
        if !isempty(failures)
            for failure in failures
                @error "benchmark regression" failure
            end
            error("benchmark regression threshold exceeded")
        end
    end
    return nothing
end

main()
