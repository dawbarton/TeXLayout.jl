# TeXLayout.jl test suite.
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
using TeXLayout
using TeXLayout:
    FontFamily,
    TexStyle,
    parse_latex,
    layout,
    LayoutBox,
    TeXElement,
    Glyph,
    GlyphID,
    HRule,
    VRule,
    Space,
    generate_tex_elements,
    layout_document,
    TeXBox,
    LayoutOptions,
    TextShaper,
    MetricShaper

# ── Style enum values ─────────────────────────────────────────────────────────
# Brought in as const aliases rather than `using TeXLayout: Display` because
# Display, Text, and MathConstants conflict with Base exports.
const Display = TeXLayout.Display
const CrampedDisplay = TeXLayout.CrampedDisplay
const Text = TeXLayout.Text
const CrampedText = TeXLayout.CrampedText
const Script = TeXLayout.Script
const CrampedScript = TeXLayout.CrampedScript
const ScriptScript = TeXLayout.ScriptScript
const CrampedScriptScript = TeXLayout.CrampedScriptScript
const MathConstants = TeXLayout.MathConstants

# ── Internal names used by the test suite ────────────────────────────────────
# These are not part of the public API but are exercised directly in tests that
# cover the MATH-table parser, glyph-metric layer, style engine, lexer, and
# parser internals.

# MATH table
using TeXLayout: load_math_table, MathTable

# Glyph metrics
using TeXLayout: GlyphMetrics, glyph_metrics, glyph_metrics_by_codepoint,
    glyph_metrics_upright

# Style helpers
using TeXLayout: is_cramped, is_display, is_script, is_script_script,
    sup_style, sub_style, frac_num_style, frac_den_style,
    cramp_style, size_scale

# Lexer
using TeXLayout: tokenize, TokenKind

# Parser / AST node kinds
using TeXLayout: NodeKind

# Ground-truth fixture constants (NewCMMath-Regular.otf values from fonttools/ttx).
# Included once here so that test_math_table.jl, test_metrics.jl, and
# test_layout.jl can all reference them without redefining constants.
include("fixtures/newcm_math.jl")

# Wrap all test files in a single top-level testset so that an "Error During Test"
# in one file (e.g., a stub throwing "not implemented") does not abort the run for
# subsequent files.  The top-level testset collects all results and throws once at
# the very end.
@testset "TeXLayout.jl" begin
    include("test_math_table.jl")
    include("test_metrics.jl")
    include("test_style.jl")
    include("test_lexer.jl")
    include("test_parser.jl")
    include("test_layout.jl")
    include("test_katex.jl")
    include("test_text.jl")
    include("test_snapshots.jl")
end
