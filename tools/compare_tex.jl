# Overlay TeXLayout's layout on LuaLaTeX (or XeLaTeX) output that uses the same
# OpenType font files, one PDF (and PNG) per font.
#
# The TeX engine typesets each expression with unicode-math and the bundled
# font files themselves.  TeXLayout's boxes are drawn into the same PDF at their
# computed positions, glyph by glyph (by glyph ID under XeLaTeX, by glyph name
# through luaotfload under LuaLaTeX), so no shaping or font substitution is
# involved.  The two layers are combined with a multiply blend:
#
#   cyan     the TeX engine
#   magenta  TeXLayout
#   dark     both agree
#
# LuaLaTeX is the default reference: it implements OpenType MATH directly.
# XeLaTeX needs two corrections for a like-for-like comparison, both applied
# here: it puts \scriptspace (LaTeX: 0.5pt) after scripts where OpenType MATH,
# LuaTeX, and TeXLayout use the font's SpaceAfterScript, so \scriptspace is set
# from the font; and both engines get \@displaytrue for Display-style cases,
# because $\displaystyle ...$ is still inline mode for amsmath's \if@display.
#
# Requirements: lualatex or xelatex with unicode-math, fontspec, mathtools,
# extarrows, and TikZ (TeX Live), and ImageMagick (`magick`) for the PNGs.
#
# Usage:
#   julia --project=tools tools/compare_tex.jl [options] EXPR [EXPR ...]
#
# Options:
#   --engine=lualatex|xelatex  reference engine (default lualatex)
#   --fonts=new_cm,stix_two    bundled font symbols (default new_cm)
#   --out=DIR                  output directory (default compare_outputs)
#   --name=STEM                file stem; files are STEM_<font>.{tex,pdf,png} (default compare)
#   --size=24                  font size in pt
#   --density=150              PNG resolution in dpi; 0 skips the PNGs
#
# Each EXPR may start with prefixes, in any order:
#   T:         Text style (default Display style, typeset as display math)
#   S:         Script style
#   B:         a binomial without its delimiters: B:{n}{k} compares TeXLayout's
#              \binom{n}{k} minus its parentheses with {n \atop k}, which
#              isolates the numerator and denominator shifts
#   LABEL|     show LABEL instead of the source above the case
#
# Example:
#   julia --project=tools tools/compare_tex.jl --fonts=new_cm,stix_two \
#       '\sqrt[3]{\frac{a}{b}}' 'T:a\,+b' 'B:{n}{k}'

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using TeXLayout: Glyph, GlyphID, HRule, VRule, layout, parse_latex
using FreeTypeAbstraction

struct Options
    engine::String
    fonts::Vector{Symbol}
    out::String
    name::String
    size::Float64
    density::Int
    exprs::Vector{String}
end

function parse_options(args)::Options
    engine, fonts, out, name, size, density = "lualatex", [:new_cm], "compare_outputs", "compare", 24.0, 150
    exprs = String[]
    for arg in args
        if startswith(arg, "--")
            key, value = occursin('=', arg) ? split(arg[3:end], '='; limit = 2) : (arg[3:end], "")
            if key == "engine"
                value in ("lualatex", "xelatex") || error("--engine must be lualatex or xelatex")
                engine = String(value)
            elseif key == "fonts"
                fonts = Symbol.(split(value, ','))
            elseif key == "out"
                out = String(value)
            elseif key == "name"
                name = String(value)
            elseif key == "size"
                size = parse(Float64, value)
            elseif key == "density"
                density = parse(Int, value)
            else
                error("unknown option --$key")
            end
        else
            push!(exprs, arg)
        end
    end
    isempty(exprs) && error("no expressions given; see the usage notes at the top of tools/compare_tex.jl")
    return Options(engine, fonts, out, name, size, density, exprs)
end

fmt(x) = string(round(x; digits = 4))

const _FACES = Dict{String, FTFont}()
_face(path) = get!(() -> FTFont(path), _FACES, path)

# PostScript name of glyph `gid` in the font at `path` (for luaotfload).
function _glyph_name_of_id(path::String, gid::Integer)::String
    face = _face(path)
    buf = zeros(UInt8, 128)
    @lock face.lock FreeTypeAbstraction.FreeType.FT_Get_Glyph_Name(face, UInt32(gid), buf, UInt32(length(buf)))
    i = findfirst(==(0x00), buf)
    return String(buf[1:(something(i, length(buf) + 1) - 1)])
end

# TeX code that prints one glyph of the font at `path`, by name or by ID.
function _glyph_tex(engine::String, path::String, size::Float64; name = nothing, gid = nothing)
    font = "\\font\\tlf=\"[$path]\" at $(fmt(size))pt\\tlf"
    if engine == "lualatex"
        glyph_name = name === nothing ? _glyph_name_of_id(path, gid) : name
        return font * "\\directlua{tex.sprint(\"\\\\char\" .. luaotfload.aux.slot_of_name(font.current(), \"$glyph_name\"))}"
    end
    id = gid === nothing ? FreeTypeAbstraction.glyph_index(_face(path), name) : gid
    return font * "\\XeTeXglyph$(id)"
end

# A binomial node with its delimiters removed (for `B:` cases).
function _strip_binomial_delimiters(node)
    node.kind === TeXLayout.NodeKind.Genfrac && return TeXLayout.Node(node.kind, "\0", node.children)
    return TeXLayout.Node(node.kind, node.value, [_strip_binomial_delimiters(c) for c in node.children], node.width)
end

function texlayout_tikz(io, tree, family, style, opts::Options)
    pt = opts.size
    for b in layout(tree, family, style)
        el = b.element
        x, y = fmt(b.x * pt), fmt(b.y * pt)
        if el isa Glyph
            path = TeXLayout._font_path_for_slot(family, el.font_slot)
            glyph = _glyph_tex(opts.engine, path, pt * b.scale; name = el.glyph_name)
            println(io, "  \\node[tl] at ($(x)pt,$(y)pt) {$glyph};")
        elseif el isa GlyphID
            glyph = _glyph_tex(opts.engine, el.font_path, pt * b.scale; gid = el.glyph_id)
            println(io, "  \\node[tl] at ($(x)pt,$(y)pt) {$glyph};")
        elseif el isa HRule
            println(io, "  \\fill[tlfill] ($(x)pt,$(y)pt) rectangle ++($(fmt(el.width * pt))pt,$(fmt(el.thickness * pt))pt);")
        elseif el isa VRule
            println(io, "  \\fill[tlfill] ($(x)pt,$(y)pt) rectangle ++($(fmt(el.thickness * pt))pt,$(fmt(el.height * pt))pt);")
        end
    end
    return nothing
end

function latex_escape(s::AbstractString)
    return replace(
        s, "\\" => "\\textbackslash{}", "{" => "\\{", "}" => "\\}", "_" => "\\_",
        "^" => "\\^{}", "&" => "\\&", "%" => "\\%", "\$" => "\\\$", "#" => "\\#", "~" => "\\~{}",
    )
end

# Split "{num}{den}" at the end of the first balanced group.
function _split_two_groups(expr::AbstractString)
    depth = 0
    for (i, ch) in pairs(expr)
        ch == '{' && (depth += 1)
        ch == '}' && (depth -= 1)
        depth == 0 && return expr[1:i], expr[nextind(expr, i):end]
    end
    error("B: expects {numerator}{denominator}, got $expr")
end

function parse_case(raw::AbstractString)
    label = nothing
    if occursin('|', raw)
        label, raw = split(raw, '|'; limit = 2)
    end
    style, binomial = TeXLayout.Display, false
    while true
        if startswith(raw, "T:")
            style, raw = TeXLayout.Text, raw[3:end]
        elseif startswith(raw, "S:")
            style, raw = TeXLayout.Script, raw[3:end]
        elseif startswith(raw, "B:")
            binomial, raw = true, raw[3:end]
        else
            break
        end
    end
    return (; label, style, binomial, expr = String(raw))
end

function write_tex(path::String, font::Symbol, opts::Options)
    family = TeXLayout.font_family(font)
    pt = opts.size
    mathdir, mathfile = splitdir(family.math)
    regular = something(family.regular, family.math)
    regdir, regfile = splitdir(regular)
    fontspec = ["Path=$regdir/"]
    for (key, face) in (("BoldFont", family.bold), ("ItalicFont", family.italic), ("BoldItalicFont", family.bolditalic))
        face !== nothing && dirname(face) == regdir && push!(fontspec, "$key=$(basename(face))")
    end
    open(path, "w") do io
        println(io, raw"\documentclass[border=6pt,varwidth=40cm]{standalone}")
        println(io, raw"\usepackage{mathtools}")   # amsmath plus \xRightarrow, \xmapsto, …
        println(io, raw"\usepackage{extarrows}")   # \xlongequal
        println(io, raw"\usepackage{unicode-math}")
        println(io, "\\setmainfont{$regfile}[$(join(fontspec, ", "))]")
        println(io, "\\setmathrm{$regfile}[Path=$regdir/]")
        println(io, "\\setmathfont{$mathfile}[Path=$mathdir/]")
        println(io, raw"\makeatletter\newcommand\tldisplay{\@displaytrue}\makeatother")
        println(io, raw"\usepackage{tikz}")
        println(io, raw"\tikzset{tl/.style={anchor=base west,inner sep=0pt,outer sep=0pt,text=magenta},tlfill/.style={fill=magenta},ref/.style={anchor=base west,inner sep=0pt,outer sep=0pt,text=cyan}}")
        if opts.engine == "xelatex"
            mt = TeXLayout.load_math_table(family.math)
            println(io, "\\AtBeginDocument{\\scriptspace=$(fmt(mt.constants.space_after_script / mt.upm * pt))pt}")
        end
        println(io, raw"\begin{document}")
        println(io, "\\fontsize{$(pt)pt}{$(1.2pt)pt}\\selectfont")
        engine = opts.engine == "lualatex" ? "LuaLaTeX" : "XeLaTeX"
        println(io, "{\\fontsize{9pt}{10pt}\\selectfont\\ttfamily $(latex_escape(string(font))): cyan = $engine, magenta = TeXLayout, dark = both}\\par\\medskip")
        for raw in opts.exprs
            case = parse_case(raw)
            if case.binomial
                num, den = _split_two_groups(case.expr)
                refexpr = "{\\nulldelimiterspace=0pt {$num\\atop$den}}"
                tree = _strip_binomial_delimiters(parse_latex("\\binom" * case.expr))
            else
                refexpr = case.expr
                tree = parse_latex(case.expr)
            end
            ref = case.style == TeXLayout.Text ? "\$\\textstyle $refexpr\$" :
                case.style == TeXLayout.Script ? "\$\\scriptstyle $refexpr\$" :
                "\$\\tldisplay\\displaystyle $refexpr\$"
            println(io, "{\\fontsize{8pt}{9pt}\\selectfont\\ttfamily $(latex_escape(something(case.label, raw)))}\\par")
            println(io, raw"\begin{tikzpicture}[baseline=0pt]")
            println(io, raw"  \begin{scope}[blend group=multiply]")
            println(io, "  \\node[ref] at (0,0) {$ref};")
            texlayout_tikz(io, tree, family, case.style, opts)
            println(io, raw"  \end{scope}")
            println(io, raw"\end{tikzpicture}\par\medskip")
        end
        println(io, raw"\end{document}")
    end
    return path
end

function main(args = ARGS)
    opts = parse_options(args)
    mkpath(opts.out)
    for font in opts.fonts
        tex = abspath(joinpath(opts.out, "$(opts.name)_$(font).tex"))
        write_tex(tex, font, opts)
        cmd = `$(opts.engine) -interaction=nonstopmode -halt-on-error -output-directory=$(dirname(tex)) $tex`
        if !success(pipeline(cmd; stdout = devnull, stderr = devnull))
            println(stderr, "$(opts.engine) failed for :$font; see $(splitext(tex)[1]).log")
            continue
        end
        pdf = splitext(tex)[1] * ".pdf"
        println(pdf)
        if opts.density > 0
            png = splitext(tex)[1] * ".png"
            run(`magick -density $(opts.density) $pdf -background white -alpha remove -alpha off $png`)
            println(png)
        end
    end
    return nothing
end

(abspath(PROGRAM_FILE) == @__FILE__) && main()
