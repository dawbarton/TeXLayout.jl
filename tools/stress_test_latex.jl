# Generate a LaTeX stress-test sheet for TeXLayout.jl.
#
# Writes a .tex source file that approximately reproduces the stress-test sheet.
# Compile with xelatex (handles Unicode section titles without extra packages):
#
#   xelatex stress_test_<font>.tex
#
# Required LaTeX packages beyond standard:
#   stmaryrd  (\bigsqcap, \bigsqcup)
#   mathtools (\overbracket, \underbracket)
#   esint     (\iiiint, \oiint, \oiiint)
#   mathrsfs  (\mathscr)
#
# Usage:
#   julia tools/stress_test_latex.jl                       # :new_cm → .tex
#   julia tools/stress_test_latex.jl :pagella              # Pagella
#   julia tools/stress_test_latex.jl :stix_two out.tex     # custom path

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using FreeTypeAbstraction

# ── Stress-test content ────────────────────────────────────────────────────────

include("stress_test_content.jl")

# ── LaTeX output ──────────────────────────────────────────────────────────────

# Escape text for use in a LaTeX context (e.g. section titles).
function _latex_escape(s::String)
    s = replace(s, "\\" => "\\textbackslash{}")
    s = replace(s, "&" => "\\&")
    s = replace(s, "%" => "\\%")
    s = replace(s, "\$" => "\\\$")
    s = replace(s, "#" => "\\#")
    s = replace(s, "_" => "\\_")
    return s
end

"""
    run_stress_test_tex(outpath, font_name)

Write a LaTeX source file that approximately reproduces the stress-test sheet.
Compile with `xelatex` (handles Unicode section titles without extra packages).
"""
function run_stress_test_tex(outpath::String, font_name::String)
    open(outpath, "w") do io
        println(io, "% TeXLayout.jl stress-test (approximate LaTeX equivalent)")
        println(io, "% Compile with: xelatex $(basename(outpath))")
        println(io, "% Required packages beyond standard LaTeX:")
        println(io, "%   stmaryrd  (\\bigsqcap, \\bigsqcup extensions)")
        println(io, "%   mathtools (\\overbracket, \\underbracket)")
        println(io, "%   esint     (\\iiiint, \\oiint, \\oiiint)")
        println(io, "%   mathrsfs  (\\mathscr)")
        println(io, "% Note: \\overparen, \\underparen, \\kern{...} are TeXLayout-")
        println(io, "% specific; approximated below.  Font-size commands inside")
        println(io, "% math (sections 25-27) have no standard LaTeX equivalent.")
        println(io, "\\documentclass[10pt,a4paper,landscape]{article}")
        println(io, "\\usepackage{amsmath,amssymb,mathtools,bm}")
        println(io, "\\usepackage{stmaryrd}")
        println(io, "\\usepackage{esint}")
        println(io, "\\usepackage{mathrsfs}")
        println(io, "\\usepackage[margin=1.5cm]{geometry}")
        println(io, "\\setlength{\\parindent}{0pt}")
        println(io, "\\setlength{\\parskip}{3pt}")
        println(io, "\\pagestyle{empty}")
        println(io)
        println(io, "% Fallback definitions for TeXLayout-specific commands:")
        println(io, "\\providecommand{\\overparen}[1]{\\overset{\\frown}{#1}}")
        println(io, "\\providecommand{\\underparen}[1]{\\underset{\\smile}{#1}}")
        println(io, "\\providecommand{\\degree}{^{\\circ}}")
        println(io, "% Non-standard xarrow variants: approximate with standard ones.")
        println(io, "\\providecommand{\\xtwoheadrightarrow}[1]{\\xrightarrow{#1}}")
        println(io, "\\providecommand{\\xtwoheadleftarrow}[1]{\\xleftarrow{#1}}")
        println(io, "\\providecommand{\\xlongequal}[1]{\\xrightarrow{\\;#1\\;}}")
        println(io, "% \\oiiint not in esint; approximate with \\oiint.")
        println(io, "\\providecommand{\\oiiint}{\\oiint}")
        println(io)
        println(io, "\\begin{document}")
        println(io)
        println(io, "\\begin{center}")
        println(io, "  {\\Large\\bfseries TeXLayout.jl Stress Test}\\\\[2pt]")
        println(io, "  {\\large\\itshape $(font_name)}")
        println(io, "\\end{center}")
        println(io, "\\medskip\\hrule\\medskip")
        println(io)

        for (sec_title, items) in STRESS_SECTIONS
            escaped = _latex_escape(sec_title)
            println(io, "\\subsection*{$escaped}")

            # All items are Display style; group in one \[...\] block.
            display_exprs = [expr for (_, expr) in items]
            if !isempty(display_exprs)
                println(io, "\\[")
                for (k, expr) in enumerate(display_exprs)
                    sep = k < length(display_exprs) ? " \\qquad" : ""
                    # \kern{dim} is TeXLayout syntax; LaTeX \kern takes a bare
                    # dimension.  Replace with \hspace which accepts braces.
                    tex_expr = replace(expr, "\\kern{" => "\\hspace{")
                    println(io, "  $tex_expr$sep")
                end
                println(io, "\\]")
            end
            println(io)
        end

        println(io, "\\end{document}")
    end
    return println("Written $outpath")
end

# ── Font helpers ───────────────────────────────────────────────────────────────

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
    return "stress_test_$(slug).tex"
end

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_spec = length(ARGS) >= 1 ? ARGS[1] : ":new_cm"
    _output = length(ARGS) >= 2 ? ARGS[2] : nothing

    family = _resolve_font(_font_spec)
    face_math = FTFont(family.math)
    font_name = FreeTypeAbstraction.family_name(face_math)
    outpath = _output !== nothing ? String(_output) : _default_output(font_name)

    run_stress_test_tex(outpath, font_name)
end
