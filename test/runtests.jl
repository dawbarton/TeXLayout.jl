# Formatic.jl test suite.
#
# Tests are organised in six levels mirroring the implementation pipeline:
#   1. MATH table parser   — OpenType binary parsing
#   2. Glyph metrics       — advance widths, ink bounds via FreeType
#   3. Lexer               — token stream output
#   4. Parser              — AST structure
#   5. Style cascade       — TeX style transitions
#   6. Layout engine       — positioned elements, rule thicknesses, shifts
#
# All ground-truth values for levels 1 and 2 come from NewCMMath-Regular.otf
# parsed independently by fonttools/ttx (see test/fixtures/newcm_math.jl).

using Test
using Formatic

# Resolve conflicts with Base exports (Base.Text, Base.Display, Base.MathConstants).
# These constants are used throughout the included test files.
const Display             = Formatic.Display
const CrampedDisplay      = Formatic.CrampedDisplay
const Text                = Formatic.Text
const CrampedText         = Formatic.CrampedText
const Script              = Formatic.Script
const CrampedScript       = Formatic.CrampedScript
const ScriptScript        = Formatic.ScriptScript
const CrampedScriptScript = Formatic.CrampedScriptScript
const MathConstants       = Formatic.MathConstants

# Ground-truth fixture constants (NewCMMath-Regular.otf values from fonttools/ttx).
# Included once here so that test_math_table.jl, test_metrics.jl, and
# test_layout.jl can all reference them without redefining constants.
include("fixtures/newcm_math.jl")

# Wrap all test files in a single top-level testset so that an "Error During Test"
# in one file (e.g., a stub throwing "not implemented") does not abort the run for
# subsequent files.  The top-level testset collects all results and throws once at
# the very end.
@testset "Formatic.jl" begin
    include("test_math_table.jl")
    include("test_metrics.jl")
    include("test_style.jl")
    include("test_lexer.jl")
    include("test_parser.jl")
    include("test_layout.jl")
    include("test_katex.jl")
end
