# Benchmarks

Run the benchmark suite against the local checkout:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/runbenchmarks.jl
```

For a quick smoke check while refactoring:

```sh
julia --project=benchmark benchmark/runbenchmarks.jl --seconds=0.05 --samples=2 --output=/tmp/texlayout-bench-smoke.toml
```

To create or refresh the local baseline:

```sh
julia --project=benchmark benchmark/runbenchmarks.jl --update-baseline
```

If `benchmark/baseline.toml` exists, subsequent runs compare against it and fail
when median runtime regresses by more than 15% or memory/allocations by more
than 20%.

Use `--baseline=/path/to/baseline.toml`, `--time-threshold=1.15`, and
`--allocation-threshold=1.20` to compare against a specific baseline or adjust
regression thresholds for a particular machine.
