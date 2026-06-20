using EnumX

EnumX.@enumx FontSlot begin
    Math
    Regular
    Bold
    Italic
    BoldItalic
end

EnumX.@enumx LayoutMode begin
    Math
    Text
end

EnumX.@enumx Alignment begin
    Left
    Center
    Right
end

_font_slot_from_symbol(slot::Symbol) =
    slot === :math ? FontSlot.Math :
    slot === :regular ? FontSlot.Regular :
    slot === :bold ? FontSlot.Bold :
    slot === :italic ? FontSlot.Italic :
    slot === :bolditalic ? FontSlot.BoldItalic :
    error("unknown font slot: $slot")

_font_slot_symbol(slot::FontSlot.T) =
    slot === FontSlot.Math ? :math :
    slot === FontSlot.Regular ? :regular :
    slot === FontSlot.Bold ? :bold :
    slot === FontSlot.Italic ? :italic :
    slot === FontSlot.BoldItalic ? :bolditalic :
    error("unknown font slot: $slot")

_alignment_from_symbol(align::Symbol) =
    align === :left ? Alignment.Left :
    align === :center ? Alignment.Center :
    align === :right ? Alignment.Right :
    error("unknown alignment: $align")

_alignment_symbol(align::Alignment.T) =
    align === Alignment.Left ? :left :
    align === Alignment.Center ? :center :
    align === Alignment.Right ? :right :
    error("unknown alignment: $align")
