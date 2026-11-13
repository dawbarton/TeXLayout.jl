# TeXLayout.jl test suite.
#
# Files follow the pipeline: MATH table and glyph metrics, style cascade,
# lexer, parser, math layout (one file per feature area), KaTeX-derived
# cases, text and document layout, renderer adapters, layout snapshots, and
# thread safety.  Ground-truth values for the MATH table and metrics come
# from NewCMMath-Regular.otf parsed independently by fonttools/ttx (see
# test/fixtures/newcm_math.jl).
#
# Run a subset by naming files (any substring of the file name):
#
#     julia --project=. -e 'using Pkg; Pkg.test(test_args = ["layout_scripts"])'
#     julia --project=. -e 'using Pkg; Pkg.test(test_args = ["layout", "parser"])'

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

# Parser / AST node kinds and their structured payloads
using TeXLayout: NodeKind, _DelimiterPairPayload, _BigDelimiterPayload, _MatrixPayload

# Ground-truth fixture constants (NewCMMath-Regular.otf values from fonttools/ttx).
# Included once here so that every test file can reference them without
# redefining constants.
include("fixtures/newcm_math.jl")

include("helpers.jl")

const TEST_FILES = [
    "test_math_table.jl",
    "test_metrics.jl",
    "test_style.jl",
    "test_lexer.jl",
    "test_parser.jl",
    "test_layout_core.jl",
    "test_layout_scripts.jl",
    "test_layout_fractions.jl",
    "test_layout_delimiters.jl",
    "test_layout_operators.jl",
    "test_layout_alphabets.jl",
    "test_layout_accents.jl",
    "test_layout_matrices.jl",
    "test_layout_extensibles.jl",
    "test_katex.jl",
    "test_text_shaping.jl",
    "test_text_parser.jl",
    "test_text_composition.jl",
    "test_text_whitespace.jl",
    "test_makie_extension.jl",
    "test_snapshots.jl",
    "test_threads.jl",
]

# Test arguments select files by substring; none runs everything.
const SELECTED = isempty(ARGS) ? TEST_FILES : filter(f -> any(a -> occursin(a, f), ARGS), TEST_FILES)
isempty(SELECTED) && error("no test file matches $(ARGS); files: $(join(TEST_FILES, ", "))")

# One top-level testset, so an error in one file does not stop the files
# after it; the results are reported together at the end.
@testset "TeXLayout.jl" begin
    for file in SELECTED
        include(file)
    end
end
