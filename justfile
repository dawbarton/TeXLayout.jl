STRESS_TEST_REFERENCE := "https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.3.0-stress/stress_test_reference.tar"

default:
    just --list

test:
    julia --project=. -e 'using Pkg; Pkg.test()'

stress-generate:
    julia --project=tools tools/stress_test_suite.jl generate

stress-generate-no-sheets:
    julia --project=tools tools/stress_test_suite.jl generate --no-sheets

stress-generate-makie:
    julia --project=tools tools/stress_test_suite.jl generate --include-makie

stress-generate-font font:
    julia --project=tools tools/stress_test_suite.jl generate --fonts {{font}}

stress-reference-generate: stress-clean stress-generate-no-sheets
    julia --project=tools tools/stress_test_suite.jl pack --input stress_outputs/current --out stress_test_reference.tar

stress-reference-compare reference="stress_test_reference_github.tar":
    #!/usr/bin/env bash
    if [ ! -f {{reference}} ]; then
        just stress-reference-download
    fi
    julia --project=tools tools/stress_test_suite.jl compare --current stress_outputs/current --reference {{reference}}

stress-reference-download:
    curl -L {{STRESS_TEST_REFERENCE}} -o stress_test_reference_github.tar

stress-clean:
    rm -rf stress_outputs stress_test_reference.tar
