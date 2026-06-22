# Unified stress-test generation, packaging, and comparison.
#
# Outputs are case-addressed rather than sheet-addressed, so adding new stress
# cases does not invalidate comparisons for old cases. Full sheets are still
# generated under each font's `sheets/` folder for quick visual inspection, but
# they are not included in reference tarballs or case comparisons.

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using TeXLayout
using FreeTypeAbstraction
using PNGFiles
using Colors: Gray, RGB, N0f8
using Downloads
using SHA
using Tar
using TOML
using CairoMakie
using LaTeXStrings

module MathStress
    include("stress_test_freetype.jl")
end

module TextStress
    include("stress_test_text.jl")
end

const REFERENCE_ASSET = "stress_test_reference.tar"

const ALL_FONTS = [
    :new_cm, :pagella, :luciole, :stix_two,
    :fira_math, :schola, :termes, :bonum,
]

const MAKIE_CASES = [
    (
        section = "1. BASIC MATH",
        name = "simple atom",
        source = raw"x+y=z",
    ),
    (
        section = "2. FRACTIONS AND SCRIPTS",
        name = "scripts fraction",
        source = raw"\frac{x_i^2}{1+\sqrt{x}}",
    ),
    (
        section = "3. DELIMITERS",
        name = "radical delimited",
        source = raw"\left(\frac{a}{b}\right)",
    ),
    (
        section = "4. LARGE OPERATORS",
        name = "sum integral limits",
        source = raw"\sum_{i=1}^{n} i^2 + \int_0^\infty e^{-x}\,dx",
    ),
    (
        section = "5. MATRICES",
        name = "cases matrix",
        source = raw"\begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \geq 0 \end{cases}",
    ),
    (
        section = "6. ACCENTS AND ARROWS",
        name = "accents braces arrows",
        source = raw"\widehat{ABC}+\overbrace{x+y}^{n}+\xrightarrow[a]{b}",
    ),
]

# ── Small utilities ──────────────────────────────────────────────────────────

function _slug(s::AbstractString)::String
    out = lowercase(replace(s, r"[^A-Za-z0-9]+" => "_"))
    out = strip(out, '_')
    return isempty(out) ? "case" : out
end

_hash8(s::AbstractString)::String = bytes2hex(sha1(codeunits(s)))[1:8]

function _stable_dir(label::AbstractString, key::AbstractString)::String
    return "$(_slug(label))__$(_hash8(key))"
end

function _write_png(path::String, canvas::Matrix{UInt8})
    mkpath(dirname(path))
    PNGFiles.save(path, reinterpret(Gray{N0f8}, canvas))
    return path
end

function _read_png(path::String)::Matrix{UInt8}
    return collect(reinterpret(UInt8, PNGFiles.load(path)))
end

function _font_name(family::FontFamily)::String
    face = FTFont(family.math)
    return FreeTypeAbstraction.family_name(face)
end

function _resolve_font(name::Symbol)::FontFamily
    return font_family(name)
end

function _manifest_case!(
        cases::Vector{Dict{String, Any}},
        font::Symbol,
        suite::String,
        section::String,
        case_name::String,
        source::String,
        path::String,
        image::Matrix{UInt8};
        kwargs::NamedTuple = (;),
    )
    h, w = size(image)
    push!(
        cases,
        Dict{String, Any}(
            "font" => string(font),
            "suite" => suite,
            "section" => section,
            "name" => case_name,
            "source" => source,
            "path" => path,
            "width" => w,
            "height" => h,
            "kwargs" => Dict(string(k) => string(v) for (k, v) in pairs(kwargs)),
        ),
    )
    return nothing
end

# ── Renderers ────────────────────────────────────────────────────────────────

function _render_math_cases!(root::String, font::Symbol, manifest_cases)
    family = _resolve_font(font)
    mt = TeXLayout.load_math_table(family.math)
    face_math = FTFont(family.math)
    face_regular = family.regular !== nothing ? FTFont(family.regular) : nothing

    for (section_title, items) in MathStress.STRESS_SECTIONS
        section_dir = _stable_dir(section_title, section_title)
        for (style, expr) in items
            case_name = String(first(split(expr, '\n')))
            case_dir = _stable_dir(case_name, "math|$(section_title)|$(style)|$(expr)")
            rel = joinpath(string(font), "math_freetype", section_dir, case_dir * ".png")
            canvas = MathStress.render_expr(expr, family, mt, face_math, face_regular, style)
            _write_png(joinpath(root, rel), canvas)
            _manifest_case!(
                manifest_cases, font, "math_freetype", section_title,
                case_name, expr, rel, canvas; kwargs = (; style = string(style)),
            )
        end
    end
    return nothing
end

function _render_text_cases!(root::String, font::Symbol, manifest_cases)
    family = _resolve_font(font)
    paths = TextStress._slot_paths(family)

    for (section_title, cases) in TextStress.TEXT_STRESS_SECTIONS
        section_dir = _stable_dir(section_title, section_title)
        for case in cases
            case_dir = _stable_dir(case.name, "text|$(section_title)|$(case.name)|$(case.source)|$(case.kwargs)")
            rel = joinpath(string(font), "text_freetype", section_dir, case_dir * ".png")
            canvas = TextStress.render_document(case, family, paths)
            _write_png(joinpath(root, rel), canvas)
            _manifest_case!(
                manifest_cases, font, "text_freetype", section_title,
                case.name, case.source, rel, canvas; kwargs = case.kwargs,
            )
        end
    end
    return nothing
end

function _render_makie_case(expr::String, family::FontFamily)::Matrix{UInt8}
    TeXLayout.set_default_font_family!(family)
    mt = TeXLayout.load_math_table(family.math)
    boxes = try
        TeXLayout.layout(TeXLayout.parse_latex(expr), family, TeXLayout.Display)
    catch
        TeXLayout.LayoutBox[]
    end
    bx1, bx2, by1, by2 = isempty(boxes) ?
        (0.0, 4.0, -1.0, 1.0) :
        MathStress.em_bbox(boxes, mt.upm; pad = 0.4)

    px = MathStress.BASE_PX
    margin = 32
    w = max(240, 2margin + ceil(Int, (bx2 - bx1) * px))
    h = max(160, 2margin + ceil(Int, (by2 - by1) * px))
    fig = CairoMakie.Figure(size = (w, h), backgroundcolor = :white)
    ax = CairoMakie.Axis(fig[1, 1]; backgroundcolor = :white)
    CairoMakie.hidespines!(ax)
    CairoMakie.hidedecorations!(ax)
    CairoMakie.xlims!(ax, 0, w)
    CairoMakie.ylims!(ax, 0, h)

    x = margin - bx1 * px
    y = margin - by1 * px
    CairoMakie.text!(
        ax, x, y;
        text = LaTeXStrings.LaTeXString("\$" * expr * "\$"),
        fontsize = px,
        align = (:left, :bottom),
        space = :data,
        markerspace = :data,
    )

    tmp = tempname() * ".png"
    CairoMakie.save(tmp, fig)
    return _read_png(tmp)
end

function _render_makie_cases!(root::String, font::Symbol, manifest_cases)
    family = _resolve_font(font)
    for case in MAKIE_CASES
        section_dir = _stable_dir(case.section, case.section)
        case_dir = _stable_dir(case.name, "makie|$(case.section)|$(case.name)|$(case.source)")
        rel = joinpath(string(font), "makie_cairo", section_dir, case_dir * ".png")
        canvas = _render_makie_case(case.source, family)
        _write_png(joinpath(root, rel), canvas)
        _manifest_case!(
            manifest_cases, font, "makie_cairo", case.section,
            case.name, case.source, rel, canvas,
        )
    end
    return nothing
end

function _render_sheets!(root::String, font::Symbol; include_makie::Bool)
    family = _resolve_font(font)
    font_name = _font_name(family)
    sheet_dir = joinpath(root, string(font), "sheets")
    mkpath(sheet_dir)

    mt = TeXLayout.load_math_table(family.math)
    face_math = FTFont(family.math)
    face_regular = family.regular !== nothing ? FTFont(family.regular) : nothing
    _write_png(
        joinpath(sheet_dir, "$(string(font))_math_freetype.png"),
        MathStress._build_sheet(family, mt, face_math, face_regular, font_name),
    )
    _write_png(
        joinpath(sheet_dir, "$(string(font))_text_freetype.png"),
        TextStress.build_sheet(family, font_name),
    )

    if include_makie
        # Keep Makie sheet generation on the existing wrapper for now: per-case
        # Makie outputs are the reference-bearing artifacts.
        try
            makie_path = joinpath(sheet_dir, "makie_cairo.png")
            include("stress_test_makie.jl")
            run_stress_test_makie(family, makie_path, mt, font_name)
        catch err
            @warn "Makie sheet generation failed for :$(font): $err"
        end
    end
    return nothing
end

# ── Generation ───────────────────────────────────────────────────────────────

function generate_outputs(;
        out::String = "stress_outputs/current",
        fonts = ALL_FONTS,
        include_makie::Bool = false,
        sheets::Bool = true,
    )
    mkpath(out)
    manifest_cases = Vector{Dict{String, Any}}()

    for font in fonts
        println("\n# Generating :$(font)")
        _render_math_cases!(out, font, manifest_cases)
        _render_text_cases!(out, font, manifest_cases)
        include_makie && _render_makie_cases!(out, font, manifest_cases)
        sheets && _render_sheets!(out, font; include_makie)
    end

    manifest = Dict{String, Any}(
        "schema_version" => 1,
        "case_id_version" => 1,
        "reference_asset" => REFERENCE_ASSET,
        "sheets_are_reference" => false,
        "fonts" => [string(f) for f in fonts],
        "suites" => include_makie ?
            ["math_freetype", "text_freetype", "makie_cairo"] :
            ["math_freetype", "text_freetype"],
        "cases" => manifest_cases,
    )
    open(joinpath(out, "manifest.toml"), "w") do io
        TOML.print(io, manifest)
    end
    println("\nWrote stress outputs to $(out)")
    return out
end

# ── Tarball packaging ────────────────────────────────────────────────────────

function _copy_reference_tree(src::String, dst::String)
    mkpath(dst)
    for (root, dirs, files) in walkdir(src)
        filter!(d -> d != "sheets", dirs)
        relroot = relpath(root, src)
        relroot == "." && (relroot = "")
        for file in files
            endswith(file, ".png") || file == "manifest.toml" || continue
            from = joinpath(root, file)
            to = joinpath(dst, relroot, file)
            mkpath(dirname(to))
            cp(from, to; force = true)
        end
    end
    return dst
end

function pack_reference(input::String = "stress_outputs/current", out::String = REFERENCE_ASSET)
    staging = mktempdir()
    _copy_reference_tree(input, staging)
    isfile(out) && rm(out)
    Tar.create(staging, out)
    println("Wrote reference tarball: $(out)")
    return out
end

function _reference_dir(reference::String)::String
    dir = mktempdir()
    ref = reference
    if startswith(reference, "http://") || startswith(reference, "https://")
        ref = joinpath(dir, basename(reference))
        Downloads.download(reference, ref)
    end
    Tar.extract(ref, dir)
    return dir
end

# ── Comparison ───────────────────────────────────────────────────────────────

function _diff_images(before::Matrix{UInt8}, after::Matrix{UInt8}, diff_path::String)
    h_b, w_b = size(before)
    h_a, w_a = size(after)
    H = max(h_b, h_a)
    W = max(w_b, w_a)
    if (h_b, w_b) != (H, W)
        tmp = fill(UInt8(0xff), H, W)
        tmp[1:h_b, 1:w_b] .= before
        before = tmp
    end
    if (h_a, w_a) != (H, W)
        tmp = fill(UInt8(0xff), H, W)
        tmp[1:h_a, 1:w_a] .= after
        after = tmp
    end

    max_delta = 0
    n_changed = 0
    diff_img = Matrix{RGB{N0f8}}(undef, H, W)
    for row in 1:H, col in 1:W
        d = Int(after[row, col]) - Int(before[row, col])
        d != 0 && (max_delta = max(max_delta, abs(d)); n_changed += 1)
        diff_img[row, col] = if d > 0
            v = reinterpret(N0f8, UInt8(255 - d))
            RGB{N0f8}(reinterpret(N0f8, 0xff), v, v)
        elseif d < 0
            v = reinterpret(N0f8, UInt8(255 + d))
            RGB{N0f8}(v, reinterpret(N0f8, 0xff), v)
        else
            RGB{N0f8}(
                reinterpret(N0f8, 0xff),
                reinterpret(N0f8, 0xff),
                reinterpret(N0f8, 0xff),
            )
        end
    end
    mkpath(dirname(diff_path))
    PNGFiles.save(diff_path, diff_img)
    return (max_delta, n_changed, H * W)
end

function compare_outputs(;
        current::String = "stress_outputs/current",
        reference::String = REFERENCE_ASSET,
        diff_dir::String = "stress_outputs/diff",
        fail_on_new::Bool = false,
    )
    ref_dir = _reference_dir(reference)
    current_pngs = Set{String}()
    ref_pngs = Set{String}()
    for (root, dirs, files) in walkdir(current)
        filter!(d -> d != "sheets", dirs)
        for file in files
            endswith(file, ".png") || continue
            push!(current_pngs, relpath(joinpath(root, file), current))
        end
    end
    for (root, dirs, files) in walkdir(ref_dir)
        filter!(d -> d != "sheets", dirs)
        for file in files
            endswith(file, ".png") || continue
            push!(ref_pngs, relpath(joinpath(root, file), ref_dir))
        end
    end

    all_paths = sort!(collect(union(current_pngs, ref_pngs)))
    counts = Dict("IDENTICAL" => 0, "AA" => 0, "CHANGED" => 0, "NEW" => 0, "MISSING" => 0)
    changed = String[]

    for rel in all_paths
        in_cur = rel in current_pngs
        in_ref = rel in ref_pngs
        if in_cur && !in_ref
            counts["NEW"] += 1
            println("NEW       $(rel)")
            fail_on_new && push!(changed, rel)
        elseif in_ref && !in_cur
            counts["MISSING"] += 1
            println("MISSING   $(rel)")
            push!(changed, rel)
        else
            cur_img = _read_png(joinpath(current, rel))
            ref_img = _read_png(joinpath(ref_dir, rel))
            diff_path = joinpath(diff_dir, rel)
            max_delta, n_changed, total = _diff_images(ref_img, cur_img, diff_path)
            status = n_changed == 0 ? "IDENTICAL" :
                max_delta <= 3 ? "AA" : "CHANGED"
            counts[status] += 1
            status == "CHANGED" && push!(changed, rel)
            if status != "IDENTICAL"
                pct = round(100n_changed / max(1, total); digits = 3)
                println("$(rpad(status, 9)) $(rel) max Δ=$(max_delta) changed=$(n_changed)/$(total) ($(pct)%)")
            end
        end
    end

    println("\nSummary:")
    for key in ("IDENTICAL", "AA", "CHANGED", "NEW", "MISSING")
        println("  $(rpad(key, 10)) $(counts[key])")
    end
    if !isempty(changed)
        error("stress comparison found $(length(changed)) blocking difference(s)")
    end
    return counts
end

# ── CLI ──────────────────────────────────────────────────────────────────────

function _option(args::Vector{String}, name::String, default = nothing)
    idx = findfirst(==(name), args)
    idx === nothing && return default
    idx == length(args) && error("missing value for $(name)")
    return args[idx + 1]
end

function _flag(args::Vector{String}, name::String)::Bool
    return any(==(name), args)
end

function _fonts(args::Vector{String})
    spec = _option(args, "--fonts", nothing)
    spec === nothing && return ALL_FONTS
    return Symbol.(split(spec, ','))
end

function main(args = ARGS)
    cmd = isempty(args) ? "all" : first(args)
    rest = isempty(args) ? String[] : args[2:end]

    if cmd == "generate"
        generate_outputs(
            out = _option(rest, "--out", "stress_outputs/current"),
            fonts = _fonts(rest),
            include_makie = _flag(rest, "--include-makie"),
            sheets = !_flag(rest, "--no-sheets"),
        )
    elseif cmd == "pack"
        pack_reference(
            _option(rest, "--input", "stress_outputs/current"),
            _option(rest, "--out", REFERENCE_ASSET),
        )
    elseif cmd == "compare"
        compare_outputs(
            current = _option(rest, "--current", "stress_outputs/current"),
            reference = _option(rest, "--reference", REFERENCE_ASSET),
            diff_dir = _option(rest, "--diff", "stress_outputs/diff"),
            fail_on_new = _flag(rest, "--fail-on-new"),
        )
    elseif cmd == "all"
        out = _option(rest, "--out", "stress_outputs/current")
        generate_outputs(
            out = out,
            fonts = _fonts(rest),
            include_makie = _flag(rest, "--include-makie"),
            sheets = !_flag(rest, "--no-sheets"),
        )
        reference = _option(
            rest,
            "--reference",
            "$(REFERENCE_ASSET)",
        )
        compare_outputs(
            current = out,
            reference = reference,
            diff_dir = _option(rest, "--diff", "stress_outputs/diff"),
            fail_on_new = _flag(rest, "--fail-on-new"),
        )
    else
        error("unknown command $(cmd); use generate, pack, compare, or all")
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
