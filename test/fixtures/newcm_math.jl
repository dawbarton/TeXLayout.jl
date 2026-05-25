# Fixture data extracted from NewCMMath-Regular.otf via fonttools/ttx.
# UPM = 1000; all design-unit values are integers. Do not edit by hand.
#
# Regeneration command (run after downloading the font via the artifact):
#   uv run python3 utils/extract_math_fixture.py \
#       <artifact-dir>/math.otf \
#       TeXLayout.jl/test/fixtures/newcm_math.jl

# Resolve via the registered NewCMMath artifact, consistent with the rest of the package.
const FIXTURE_FONT_PATH = font_family(:new_cm).math

const FONT_UPM = 1000

# All 56 OpenType MATH MathConstants (design units).
const MATH_CONSTANTS = Dict{Symbol,Int}(
    :ScriptPercentScaleDown => 70,
    :ScriptScriptPercentScaleDown => 50,
    :DelimitedSubFormulaMinHeight => 1300,
    :DisplayOperatorMinHeight => 1300,
    :MathLeading => 154,
    :AxisHeight => 250,
    :AccentBaseHeight => 450,
    :FlattenedAccentBaseHeight => 664,
    :SubscriptShiftDown => 247,
    :SubscriptTopMax => 344,
    :SubscriptBaselineDropMin => 200,
    :SuperscriptShiftUp => 363,
    :SuperscriptShiftUpCramped => 289,
    :SuperscriptBottomMin => 108,
    :SuperscriptBaselineDropMax => 250,
    :SubSuperscriptGapMin => 160,
    :SuperscriptBottomMaxWithSubscript => 344,
    :SpaceAfterScript => 56,
    :UpperLimitGapMin => 200,
    :UpperLimitBaselineRiseMin => 111,
    :LowerLimitGapMin => 167,
    :LowerLimitBaselineDropMin => 600,
    :StackTopShiftUp => 444,
    :StackTopDisplayStyleShiftUp => 677,
    :StackBottomShiftDown => 345,
    :StackBottomDisplayStyleShiftDown => 686,
    :StackGapMin => 120,
    :StackDisplayStyleGapMin => 280,
    :StretchStackTopShiftUp => 111,
    :StretchStackBottomShiftDown => 600,
    :StretchStackGapAboveMin => 200,
    :StretchStackGapBelowMin => 167,
    :FractionNumeratorShiftUp => 394,
    :FractionNumeratorDisplayStyleShiftUp => 677,
    :FractionDenominatorShiftDown => 345,
    :FractionDenominatorDisplayStyleShiftDown => 686,
    :FractionNumeratorGapMin => 40,
    :FractionNumDisplayStyleGapMin => 120,
    :FractionRuleThickness => 40,
    :FractionDenominatorGapMin => 40,
    :FractionDenomDisplayStyleGapMin => 120,
    :SkewedFractionHorizontalGap => 350,
    :SkewedFractionVerticalGap => 96,
    :OverbarVerticalGap => 120,
    :OverbarRuleThickness => 40,
    :OverbarExtraAscender => 40,
    :UnderbarVerticalGap => 120,
    :UnderbarRuleThickness => 40,
    :UnderbarExtraDescender => 40,
    :RadicalVerticalGap => 50,
    :RadicalDisplayStyleVerticalGap => 148,
    :RadicalRuleThickness => 40,
    :RadicalExtraAscender => 40,
    :RadicalKernBeforeDegree => 278,
    :RadicalKernAfterDegree => -556,
    :RadicalDegreeBottomRaisePercent => 60,
)

# Sample italic corrections (design units). Covers glyphs exercised in layout tests.
const ITALIC_CORRECTIONS = Dict{String,Int}(
    "f"        => 79,
    "x"        => 16,
    "a"        => 11,
    "alpha"    => 24,
    "v"        => 8,
    "w"        => 9,
    "y"        => 8,
    "R"        => 24,
    "V"        => 8,
    "W"        => 9,
    "Y"        => 16,
    "integral" => 232,
)

# Sample top-accent attachment x-positions (design units).
const TOP_ACCENT_ATTACHMENTS = Dict{String,Int}(
    "f" => 234,
    "x" => 258,
    "a" => 214,
    "h" => 146,
    "v" => 278,
    "A" => 375,
    "B" => 340,
    "C" => 397,
)

# Horizontal metrics: advance width and left side bearing (design units).
const HMTX = Dict{String,NamedTuple{(:advance, :lsb),Tuple{Int,Int}}}(
    "f"        => (advance=306,  lsb=33),
    "x"        => (advance=528,  lsb=12),
    "alpha"    => (advance=641,  lsb=57),
    "parenleft" => (advance=389, lsb=101),
    "braceleft" => (advance=500, lsb=75),
    "integral" => (advance=665,  lsb=56),
    "A"        => (advance=750,  lsb=32),
    "plus"     => (advance=778,  lsb=56),
    "equal"    => (advance=778,  lsb=56),
    "period"   => (advance=278,  lsb=86),
)

const MIN_CONNECTOR_OVERLAP = 20

# Vertical size variants for parenleft.
const PARENLEFT_VERT_VARIANTS = [
    (glyph="parenleft",    advance=997),
    (glyph="parenleft.v1", advance=1095),
    (glyph="parenleft.v2", advance=1195),
    (glyph="parenleft.v3", advance=1445),
    (glyph="parenleft.v4", advance=1793),
    (glyph="parenleft.v5", advance=2093),
    (glyph="parenleft.v6", advance=2393),
    (glyph="parenleft.v7", advance=2991),
]

# Vertical glyph assembly for parenleft (bottom→top ordering).
# Parts: glyph, full_advance, start_connector, end_connector, extender.
const PARENLEFT_ASSEMBLY_PARTS = [
    (glyph="uni239D", full_advance=1495, start_connector=0,   end_connector=249, extender=false),
    (glyph="uni239C", full_advance=498,  start_connector=498, end_connector=498, extender=true),
    (glyph="uni239B", full_advance=1495, start_connector=249, end_connector=0,   extender=false),
]
const PARENLEFT_ASSEMBLY_ITALIC_CORRECTION = 0

# Vertical glyph assembly for braceleft (5 parts including two extender slots).
const BRACELEFT_ASSEMBLY_PARTS = [
    (glyph="uni23A9",      full_advance=750,  start_connector=0,   end_connector=374, extender=false),
    (glyph="braceleft.ex", full_advance=748,  start_connector=748, end_connector=748, extender=true),
    (glyph="uni23A8",      full_advance=1500, start_connector=374, end_connector=374, extender=false),
    (glyph="braceleft.ex", full_advance=748,  start_connector=748, end_connector=748, extender=true),
    (glyph="uni23A7",      full_advance=750,  start_connector=374, end_connector=0,   extender=false),
]
