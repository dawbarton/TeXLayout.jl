# Shared helper for the CairoMakie-based tools.
#
# On Makie 0.25 the tools must ask for TeXLayout explicitly through the
# `text_handler` attribute; on Makie 0.24 that attribute does not exist and the
# legacy `MathTeXEngineExt` adapter applies automatically. Splatting the result
# into a `text!` call covers both without branching at every call site.
#
# Include this after `TeXLayout` and `CairoMakie` are in scope.

function makie_handler_kwargs()
    extension = Base.get_extension(TeXLayout, :MakieExt)
    extension !== nothing && extension._HAS_LAYOUT_TEXT_INTERFACE ||
        return NamedTuple()
    return (; text_handler = TeXLayout.TeXLayoutHandler())
end
