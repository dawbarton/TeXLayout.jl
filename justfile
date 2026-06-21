default:
    just --list

test:
    julia --project=. -e 'using Pkg; Pkg.test()'

stress-generate:
    julia --project=tools tools/stress_test_suite.jl generate

stress-generate-makie:
    julia --project=tools tools/stress_test_suite.jl generate --include-makie

stress-generate-font font:
    julia --project=tools tools/stress_test_suite.jl generate --fonts {{font}}

stress-pack:
    julia --project=tools tools/stress_test_suite.jl pack --input stress_outputs/current --out stress_test_reference.tar

stress-compare reference="stress_test_reference.tar":
    julia --project=tools tools/stress_test_suite.jl compare --current stress_outputs/current --reference {{reference}}

stress-all:
    julia --project=tools tools/stress_test_suite.jl all

stress-all-makie:
    julia --project=tools tools/stress_test_suite.jl all --include-makie

stress-clean:
    rm -rf stress_outputs stress_test_reference.tar
