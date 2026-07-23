# Render a stress-test sheet for mixed text/math document layout.
#
# Produces a PNG with the literal input source on the left and TeXLayout's
# `layout_document` rendering on the right.  This intentionally uses the
# document layout API directly rather than Makie's LaTeXString path.
#
# Usage:
#   julia tools/stress_test_text.jl                         # :new_cm -> png
#   julia tools/stress_test_text.jl :pagella                # Pagella -> png
#   julia tools/stress_test_text.jl :stix_two out.png       # custom output
#   julia tools/stress_test_text.jl /path/Math.otf out.png  # custom font

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using HarfBuzz_jll
using FreeTypeAbstraction
using PNGFiles
using Colors: Gray, N0f8

const BASE_PX = 64
const LABEL_PX = 18
const TITLE_PX = 22
const SECTION_PX = 18
const MARGIN = 18
const COLUMN_GAP = 28
const ROW_GAP = 14
const TITLE_H = 40
const SECTION_H = 30
const SOURCE_W = 520
const RENDER_W = 820
const LABEL_FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
]

const TextCase = NamedTuple{
    (:name, :source, :kwargs),
    Tuple{String, String, NamedTuple},
}

const TEXT_STRESS_SECTIONS = [
    "1. PLAIN TEXT, SPACING, AND LINES" => TextCase[
        (
            name = "plain text",
            source = raw"The quick brown fox jumps over 12345.",
            kwargs = (;),
        ),
        (
            name = "significant spaces",
            source = raw"Words   with   collapsed lexer spaces and punctuation: a,b; c!",
            kwargs = (;),
        ),
        (
            name = "explicit line breaks",
            source = raw"First line\\Second line\\Third line with descenders: gypq.",
            kwargs = (;),
        ),
        (
            name = "fixed width center alignment",
            source = raw"short\\a much longer text line\\mid",
            kwargs = (align = :center, width = 12.0),
        ),
    ],
    "2. TEXT STYLES AND NESTING" => TextCase[
        (
            name = "basic text styles",
            source = raw"\textbf{Bold} regular \textit{italic} \textrm{roman}.",
            kwargs = (;),
        ),
        (
            name = "bold italic nesting",
            source = raw"\textbf{bold \textit{bold italic} bold again}",
            kwargs = (;),
        ),
        (
            name = "emph toggles italic",
            source = raw"\emph{emphasized \emph{upright inside} emphasized}",
            kwargs = (;),
        ),
        (
            name = "text and mbox grouping",
            source = raw"before \text{literal text} and \mbox{boxed words} after",
            kwargs = (;),
        ),
    ],
    "3. INLINE MATHEMATICS" => TextCase[
        (
            name = "simple inline math",
            source = raw"Energy $E = mc^2$ relates mass and energy.",
            kwargs = (;),
        ),
        (
            name = "inline fraction and radical",
            source = raw"The value $\frac{1}{1 + \sqrt{x}}$ is inline with text.",
            kwargs = (;),
        ),
        (
            name = "inline operators and Greek",
            source = raw"For $\alpha,\beta \in \mathbb{R}$, $\sin^2 x + \cos^2 x = 1$.",
            kwargs = (;),
        ),
        (
            name = "inline math inside styled text",
            source = raw"\textbf{Bold text with inline $x_i^2 + y_i^2$ math} after.",
            kwargs = (;),
        ),
    ],
    "4. DISPLAY BLOCKS" => TextCase[
        (
            name = "text then equation",
            source = raw"A sentence before display.\begin{equation}E = mc^2\end{equation}Back to text.",
            kwargs = (;),
        ),
        (
            name = "align environment",
            source = raw"Aligned equations:\begin{align}x&=y+z\\y&=x^2-z\end{align}Done.",
            kwargs = (;),
        ),
        (
            name = "gather environment",
            source = raw"Gathered display:\begin{gather}a+b=c\\x^2+y^2=z^2\end{gather}Tail.",
            kwargs = (;),
        ),
        (
            name = "display alignment left",
            source = raw"Left display:\begin{equation}\frac{a}{b}=c\end{equation}Next.",
            kwargs = (display_align = :left, width = 12.0),
        ),
    ],
    "5. TALL INLINE AND LINE HEIGHT" => TextCase[
        (
            name = "display-style inline fraction",
            source = raw"Tall inline $\dfrac{1}{1+\dfrac{1}{x}}$ should force line spacing.\\Next baseline.",
            kwargs = (;),
        ),
        (
            name = "nested radicals inline",
            source = raw"Nested $\sqrt{1+\sqrt{1+\sqrt{x}}}$ remains on the text baseline.",
            kwargs = (;),
        ),
        (
            name = "subscripts and superscripts",
            source = raw"Sequences $x_i^2 + y_{n+1}^{m-1}$ beside regular text.",
            kwargs = (;),
        ),
        (
            name = "explicit line-height option",
            source = raw"Line one with $\frac{a}{b}$\\Line two with $\sqrt{x}$",
            kwargs = (line_height = 1.55,),
        ),
    ],
    "6. LENIENCE AND EDGE CASES" => TextCase[
        (
            name = "unclosed inline math",
            source = raw"Typing in progress: $x^2 + \frac{1}{",
            kwargs = (;),
        ),
        (
            name = "unknown command ignored in text",
            source = raw"Before \unknowncmd after, with $\unknown + x$ in math.",
            kwargs = (;),
        ),
        (
            name = "empty styled groups",
            source = raw"A\textbf{}B\textit{}C and empty math $$ done.",
            kwargs = (;),
        ),
        (
            name = "display-only document",
            source = raw"\begin{equation}\sum_{k=1}^{n} k = \frac{n(n+1)}{2}\end{equation}",
            kwargs = (;),
        ),
    ],
    "7. HARFBUZZ TEXT SHAPING" => TextCase[
        (
            name = "harfbuzz prose ligatures",
            source = raw"office affinity efficient AVATAR text shaped by HarfBuzz.",
            kwargs = (shaper = HarfBuzzShaper(),),
        ),
        (
            name = "harfbuzz styled spans",
            source = raw"Regular office, \textit{italic office}, and \textbf{bold office}.",
            kwargs = (shaper = HarfBuzzShaper(),),
        ),
        (
            name = "harfbuzz small capitals",
            source = raw"Termes-style \textsc{Small Capitals} with a full-height Initial.",
            kwargs = (shaper = HarfBuzzShaper(),),
        ),
        (
            name = "harfbuzz math text command",
            source = raw"Inline math with text: $x + \text{office affine}$ beside prose.",
            kwargs = (shaper = HarfBuzzShaper(),),
        ),
    ],
]

# ── Canvas helpers ────────────────────────────────────────────────────────────

@inline function composite!(canvas, ry, cx, alpha::UInt8, ink::UInt8 = 0x00)
    1 <= ry <= size(canvas, 1) && 1 <= cx <= size(canvas, 2) || return
    old = Int(canvas[ry, cx])
    a = Int(alpha)
    target = Int(ink)
    return canvas[ry, cx] = UInt8((old * (255 - a) + target * a) ÷ 255)
end

function fill_rect!(canvas, r1, c1, r2, c2, val::UInt8)
    r1c = clamp(min(r1, r2), 1, size(canvas, 1))
    r2c = clamp(max(r1, r2), 1, size(canvas, 1))
    c1c = clamp(min(c1, c2), 1, size(canvas, 2))
    c2c = clamp(max(c1, c2), 1, size(canvas, 2))
    return canvas[r1c:r2c, c1c:c2c] .= val
end

function paste!(dst, src, top::Int, left::Int)
    h, w = size(src)
    r1 = max(1, top); c1 = max(1, left)
    r2 = min(size(dst, 1), top + h - 1)
    c2 = min(size(dst, 2), left + w - 1)
    (r1 > r2 || c1 > c2) && return dst
    sr1 = r1 - top + 1
    sc1 = c1 - left + 1
    dst[r1:r2, c1:c2] .= src[sr1:(sr1 + r2 - r1), sc1:(sc1 + c2 - c1)]
    return dst
end

write_png(path, canvas) = PNGFiles.save(path, reinterpret(Gray{N0f8}, canvas))

function _slot_paths(family::FontFamily)
    return Dict(
        slot => TeXLayout._font_path_for_slot(family, slot) for slot in (
                TeXLayout.FontSlot.Math,
                TeXLayout.FontSlot.Regular,
                TeXLayout.FontSlot.Italic,
                TeXLayout.FontSlot.Bold,
                TeXLayout.FontSlot.BoldItalic,
            )
    )
end

function _face_for!(cache::Dict{String, FTFont}, paths, slot)
    path = get(paths, slot, paths[TeXLayout.FontSlot.Math])
    return get!(cache, path) do
        FTFont(path)
    end
end

function _face_for_path!(cache::Dict{String, FTFont}, path::String)
    return get!(cache, path) do
        FTFont(path)
    end
end

function _label_face(paths)
    for path in LABEL_FONT_CANDIDATES
        isfile(path) && return FTFont(path)
    end
    return FTFont(paths[TeXLayout.FontSlot.Regular])
end

# ── Literal source-label rendering ────────────────────────────────────────────

function _char_advance(face::FTFont, ch::Char, px::Int)::Int
    isspace(ch) && return max(1, px ÷ 2)
    try
        _, ext = renderface(face, ch, px)
        return max(1, round(Int, ext.advance[1]))
    catch
        return max(1, px ÷ 2)
    end
end

function _wrap_literal(face::FTFont, text::String, px::Int, max_width::Int)::Vector{String}
    words = split(text, ' '; keepempty = true)
    lines = String[]
    line = ""
    line_w = 0
    space_w = _char_advance(face, ' ', px)
    for word in words
        word_w = sum(_char_advance(face, ch, px) for ch in word; init = 0)
        extra_w = isempty(line) ? 0 : space_w
        if !isempty(line) && line_w + extra_w + word_w > max_width
            push!(lines, line)
            line = word
            line_w = word_w
        else
            if isempty(line)
                line = word
                line_w = word_w
            else
                line *= " " * word
                line_w += extra_w + word_w
            end
        end
    end
    !isempty(line) && push!(lines, line)
    return isempty(lines) ? [""] : lines
end

function render_text_line!(
        canvas, face::FTFont, text::String, x0::Int, baseline::Int, px::Int;
        ink::UInt8 = 0x00,
    )
    x = x0
    for ch in text
        if isspace(ch)
            x += max(1, px ÷ 2)
            continue
        end
        local bmp, ext
        try
            bmp, ext = renderface(face, ch, px)
        catch
            x += max(1, px ÷ 2)
            continue
        end
        left = x + round(Int, ext.horizontal_bearing[1])
        top = baseline - round(Int, ext.horizontal_bearing[2])
        for row in axes(bmp, 2), col in axes(bmp, 1)
            alpha = bmp[col, row]
            alpha == 0x00 && continue
            composite!(canvas, top + row - 1, left + col - 1, alpha, ink)
        end
        x += round(Int, ext.advance[1])
    end
    return nothing
end

function render_label(face::FTFont, case::TextCase, width::Int)::Matrix{UInt8}
    body_width = width - 2MARGIN
    source_lines = _wrap_literal(face, case.source, LABEL_PX, body_width)
    line_h = round(Int, LABEL_PX * 1.35)
    H = 2MARGIN + line_h * (length(source_lines) + 1)
    canvas = fill(0xff, H, width)
    render_text_line!(canvas, face, case.name, MARGIN, MARGIN + LABEL_PX, LABEL_PX; ink = 0x00)
    y = MARGIN + LABEL_PX + line_h
    for line in source_lines
        render_text_line!(canvas, face, line, MARGIN, y, LABEL_PX; ink = 0x55)
        y += line_h
    end
    return canvas
end

# ── Document rendering ────────────────────────────────────────────────────────

function render_document(case::TextCase, family::FontFamily, paths)::Matrix{UInt8}
    result = try
        layout_document(case.source; family, case.kwargs...)
    catch err
        @warn "layout_document failed for $(case.name): $err"
        TeXBox(LayoutBox[], 1.0, 0.35, 0.15)
    end

    W = RENDER_W
    content_w = max(result.width, 1.0)
    usable_w = W - 2MARGIN
    scale_px = min(BASE_PX, max(24, floor(Int, usable_w / content_w)))
    H = max(90, 2MARGIN + round(Int, (result.ascent + result.descent + 0.3) * scale_px))
    canvas = fill(0xff, H, W)

    face_cache = Dict{String, FTFont}()
    em_x(x) = MARGIN + round(Int, x * scale_px)
    baseline_row = MARGIN + round(Int, result.ascent * scale_px)
    em_y(y) = baseline_row - round(Int, y * scale_px)

    # First baseline guide.
    guide = clamp(baseline_row, 1, H)
    canvas[guide, MARGIN:(W - MARGIN)] .= 0xdd

    for box in result.boxes
        el = box.element
        if el isa Glyph
            face = _face_for!(face_cache, paths, el.font_slot)
            px_size = max(1, round(Int, box.scale * scale_px))
            pen_cx = em_x(box.x)
            pen_cy = em_y(box.y)
            local bmp, ext
            try
                bmp, ext = renderface(face, el.glyph_name, px_size)
            catch err
                @warn "renderface failed for $(el.glyph_name): $err"
                continue
            end
            left = pen_cx + round(Int, ext.horizontal_bearing[1])
            top = pen_cy - round(Int, ext.horizontal_bearing[2])
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, top + row - 1, left + col - 1, alpha)
            end
        elseif el isa GlyphID
            face = _face_for_path!(face_cache, el.font_path)
            px_size = max(1, round(Int, box.scale * scale_px))
            pen_cx = em_x(box.x)
            pen_cy = em_y(box.y)
            local bmp, ext
            try
                bmp, ext = renderface(face, Int(el.glyph_id), px_size)
            catch err
                @warn "renderface failed for glyph id $(el.glyph_id): $err"
                continue
            end
            left = pen_cx + round(Int, ext.horizontal_bearing[1])
            top = pen_cy - round(Int, ext.horizontal_bearing[2])
            for row in axes(bmp, 2), col in axes(bmp, 1)
                alpha = bmp[col, row]
                alpha == 0x00 && continue
                composite!(canvas, top + row - 1, left + col - 1, alpha)
            end
        elseif el isa HRule
            fill_rect!(
                canvas,
                em_y(box.y + el.thickness), em_x(box.x),
                em_y(box.y), em_x(box.x + el.width),
                0x00,
            )
        elseif el isa VRule
            fill_rect!(
                canvas,
                em_y(box.y + el.height), em_x(box.x),
                em_y(box.y), em_x(box.x + el.thickness),
                0x00,
            )
        end
    end
    return canvas
end

function hjoin(left::Matrix{UInt8}, right::Matrix{UInt8})::Matrix{UInt8}
    H = max(size(left, 1), size(right, 1))
    W = size(left, 2) + COLUMN_GAP + size(right, 2)
    out = fill(0xff, H, W)
    paste!(out, left, 1 + (H - size(left, 1)) ÷ 2, 1)
    paste!(out, right, 1 + (H - size(right, 1)) ÷ 2, size(left, 2) + COLUMN_GAP + 1)
    return out
end

function pad_to_width(canvas::Matrix{UInt8}, W::Int)::Matrix{UInt8}
    h, w = size(canvas)
    w >= W && return canvas
    out = fill(0xff, h, W)
    paste!(out, canvas, 1, 1)
    return out
end

function vstack(rows::Vector{Matrix{UInt8}}, gap::Int = ROW_GAP)::Matrix{UInt8}
    isempty(rows) && return fill(0xff, 40, 40)
    W = maximum(size(r, 2) for r in rows)
    parts = Matrix{UInt8}[]
    for (i, row) in enumerate(rows)
        push!(parts, pad_to_width(row, W))
        i < length(rows) && push!(parts, fill(0xff, gap, W))
    end
    return vcat(parts...)
end

function header_strip(face::FTFont, text::String, width::Int, height::Int, px::Int, bg::UInt8)
    strip = fill(bg, height, width)
    render_text_line!(strip, face, text, MARGIN, height ÷ 2 + px ÷ 3, px; ink = 0xff)
    return strip
end

# ── Sheet construction ────────────────────────────────────────────────────────

function build_sheet(family::FontFamily, font_name::String)::Matrix{UInt8}
    paths = _slot_paths(family)
    label_face = _label_face(paths)
    W = SOURCE_W + COLUMN_GAP + RENDER_W
    rows = Matrix{UInt8}[
        header_strip(
            label_face,
            "TeXLayout.jl TEXT STRESS TEST  -  $(uppercase(font_name))",
            W,
            TITLE_H,
            TITLE_PX,
            0x18,
        ),
    ]

    for (section, cases) in TEXT_STRESS_SECTIONS
        push!(rows, header_strip(label_face, section, W, SECTION_H, SECTION_PX, 0x44))
        for case in cases
            push!(rows, hjoin(render_label(label_face, case, SOURCE_W), render_document(case, family, paths)))
        end
    end

    push!(rows, fill(UInt8(0x18), 4, W))
    return vstack(rows, 0)
end

# ── Font helpers ──────────────────────────────────────────────────────────────

function _resolve_font(spec)::FontFamily
    spec isa FontFamily && return spec
    s = string(spec)
    startswith(s, ":") && return font_family(Symbol(s[2:end]))
    isfile(s) && return FontFamily(s)
    return font_family(Symbol(s))
end

function _default_output(font_name::String)::String
    slug = lowercase(replace(font_name, r"[^a-zA-Z0-9]+" => "_"))
    slug = strip(slug, '_')
    return "stress_test_text_$(slug).png"
end

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _output = length(ARGS) >= 2 ? ARGS[2] : nothing

    family = _resolve_font(_font_spec)
    face = FTFont(family.math)
    font_name = FreeTypeAbstraction.family_name(face)
    outpath = _output !== nothing ? String(_output) : _default_output(font_name)

    canvas = build_sheet(family, font_name)
    write_png(outpath, canvas)
    H, W = size(canvas)
    println("Written $outpath  ($(W)x$(H) px)")
end
