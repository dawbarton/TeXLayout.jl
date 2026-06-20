# Internal measured box tree used by the document composition layer.
#
# This is the first step toward the future unified box-and-glue layout IR.  It
# deliberately shapes back to the existing `Vector{LayoutBox}` renderer contract.

abstract type Box end

struct ShapedBox <: Box
    boxes::Vector{LayoutBox}
    width::Float64
    ascent::Float64
    descent::Float64
end

struct HBox <: Box
    children::Vector{Box}
    width::Float64
    ascent::Float64
    descent::Float64
end

function HBox(children::AbstractVector{<:Box})
    boxed = Box[children...]
    width = sum(_box_width(child) for child in boxed; init = 0.0)
    ascent = maximum((_box_ascent(child) for child in boxed); init = 0.0)
    descent = maximum((_box_descent(child) for child in boxed); init = 0.0)
    return HBox(boxed, width, ascent, descent)
end

struct VBox <: Box
    children::Vector{Box}
    offsets::Vector{Float64}
    dxs::Vector{Float64}
    width::Float64
    ascent::Float64
    descent::Float64
end

_box_width(box::ShapedBox) = box.width
_box_width(box::HBox) = box.width
_box_width(box::VBox) = box.width

_box_ascent(box::ShapedBox) = box.ascent
_box_ascent(box::HBox) = box.ascent
_box_ascent(box::VBox) = box.ascent

_box_descent(box::ShapedBox) = box.descent
_box_descent(box::HBox) = box.descent
_box_descent(box::VBox) = box.descent

function shape(box::Box)::Vector{LayoutBox}
    out = LayoutBox[]
    shape!(out, box, 0.0, 0.0)
    return out
end

function shape!(out::Vector{LayoutBox}, box::ShapedBox, x::Float64, y::Float64)
    _emit_shifted!(out, box.boxes, x, y)
    return nothing
end

function shape!(out::Vector{LayoutBox}, box::HBox, x::Float64, y::Float64)
    cursor = 0.0
    for child in box.children
        shape!(out, child, x + cursor, y)
        cursor += _box_width(child)
    end
    return nothing
end

function shape!(out::Vector{LayoutBox}, box::VBox, x::Float64, y::Float64)
    length(box.children) == length(box.offsets) == length(box.dxs) ||
        error("VBox children, offsets, and dxs must have matching lengths")
    for i in eachindex(box.children)
        shape!(out, box.children[i], x + box.dxs[i], y + box.offsets[i])
    end
    return nothing
end
