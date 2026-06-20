# Benchmarks

Run the benchmark suite against the local checkout:

```julia
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/runbenchmarks.jl
```

To create or refresh the local baseline:

```julia
julia --project=benchmark benchmark/runbenchmarks.jl --update-baseline
```

If `benchmark/baseline.toml` exists, subsequent runs compare against it and fail
when median runtime regresses by more than 15% or memory/allocations by more
than 20%.
