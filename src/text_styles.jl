# Shared text-style attributes and command semantics.
#
# This file is included before both parser.jl and document.jl so math-internal
# \text{...} fragments and document text use one source of truth for nested
# text commands. Backend-specific details such as OpenType feature tags belong
# in the corresponding TextShaper implementation, not here.

"""
Text features that are independent of font family/series selection.

`small_caps` represents semantic small-capitals text. Shapers are responsible
for applying it faithfully; in particular, the HarfBuzz backend maps it to the
OpenType `smcp` feature.
"""
struct TextFeatures
    small_caps::Bool
end

TextFeatures(; small_caps::Bool = false) = TextFeatures(small_caps)

"""
Resolved font and feature attributes for one text span.

`size` is an em multiplier (`1.0` is the surrounding body size). The
two-argument constructor remains the feature-free compatibility path.
"""
struct TextAttrs
    family::TextFamily.T
    slot::FontSlot.T
    size::Float64
    features::TextFeatures
end

TextAttrs(slot::FontSlot.T, size::Real) =
    TextAttrs(TextFamily.Roman, slot, Float64(size), TextFeatures())
TextAttrs(slot::FontSlot.T, size::Real, features::TextFeatures) =
    TextAttrs(TextFamily.Roman, slot, Float64(size), features)
TextAttrs() = TextAttrs(TextFamily.Roman, FontSlot.Regular, 1.0, TextFeatures())

const _TEXT_STYLE_COMMANDS = (
    "\\textbf",
    "\\textit",
    "\\textrm",
    "\\textnormal",
    "\\emph",
    "\\textsf",
    "\\texttt",
    "\\textsc",
)

"""
Apply a braced LaTeX text-style command to resolved span attributes.

Font family, weight, shape, and semantic features are independent axes:
family commands preserve the current weight, shape, and features; weight and
shape commands preserve the current family and features. `\\textnormal` is the
only command that resets all axes.
"""
function _apply_text_style(cmd::String, attrs::TextAttrs)::TextAttrs
    cmd ∈ _TEXT_STYLE_COMMANDS || throw(ArgumentError("unknown text-style command: $cmd"))

    family = attrs.family
    slot = attrs.slot
    bold = slot === FontSlot.Bold || slot === FontSlot.BoldItalic
    italic = slot === FontSlot.Italic || slot === FontSlot.BoldItalic
    features = attrs.features

    if cmd == "\\textbf"
        bold = true
    elseif cmd == "\\textit"
        italic = true
    elseif cmd == "\\emph"
        italic = !italic
    elseif cmd == "\\textsc"
        features = TextFeatures(true)
    elseif cmd == "\\textrm"
        family = TextFamily.Roman
    elseif cmd == "\\textsf"
        family = TextFamily.Sans
    elseif cmd == "\\texttt"
        family = TextFamily.Monospace
    elseif cmd == "\\textnormal"
        family = TextFamily.Roman
        bold = false
        italic = false
        features = TextFeatures()
    end

    new_slot = bold && italic ? FontSlot.BoldItalic :
        bold ? FontSlot.Bold :
        italic ? FontSlot.Italic : FontSlot.Regular
    return TextAttrs(family, new_slot, attrs.size, features)
end

function _text_feature_names(features::TextFeatures)::Vector{String}
    result = String[]
    features.small_caps && push!(result, "small caps")
    return result
end

_has_text_features(features::TextFeatures) = features.small_caps

_text_family_name(family::TextFamily.T) =
    family === TextFamily.Roman ? "Roman" :
    family === TextFamily.Sans ? "sans-serif" : "monospace"
