# Compatibility wrapper for the unified stress-test suite.
#
# Old usage still works:
#   julia tools/stress_test_all.jl
#   julia tools/stress_test_all.jl new_cm pagella
#
# For the full CLI, use tools/stress_test_suite.jl directly.

include("stress_test_suite.jl")

if abspath(PROGRAM_FILE) == @__FILE__
    if isempty(ARGS)
        main(["all"])
    elseif first(ARGS) in ("generate", "pack", "compare", "all")
        main(ARGS)
    else
        main(["all", "--fonts", join(ARGS, ",")])
    end
end
