# Run the stress-test sheet for every bundled font family and compare the
# resulting PNG files against reference images.
#
# Reference images are downloaded from the GitHub release tagged
# v0.1.0-stress (if not already present in images_old/).  When no reference
# exists for a font, the new image is written and flagged as "no reference".
#
# Output directories (relative to the working directory):
#   images_new/         freshly rendered PNG files
#   images_old/         reference PNG files (downloaded on first run)
#   images_diff/        signed colour PNG diffs (green = added, red = removed)
#
# Public API (usable when included by another script):
#   run_all(font_names = ALL_FONTS; new_dir, old_dir, diff_dir) -> nothing
#
# Usage as script:
#   julia tools/stress_test_all.jl                      # all fonts
#   julia tools/stress_test_all.jl new_cm pagella        # selected fonts

using Pkg
Pkg.activate(@__DIR__; io = devnull)

include("stress_test_freetype.jl")

using Colors: Gray, RGB, N0f8

const IMAGES_BASE =
    "https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.1.0-stress"

# All font families bundled with TeXLayout.jl.
const ALL_FONTS = [
    :new_cm, :pagella, :luciole, :stix_two,
    :fira_math, :schola, :termes, :bonum,
]

# ── PNG I/O ────────────────────────────────────────────────────────────────

"""
    read_png(path) -> Matrix{UInt8}

Read an 8-bit greyscale PNG file into a height×width matrix of UInt8 pixel values.
"""
function read_png(path::String)::Matrix{UInt8}
    return collect(reinterpret(UInt8, PNGFiles.load(path)))
end

# ── Comparison and diff image ─────────────────────────────────────────────────

"""
    compare_imgs(before, after, diff_path) -> (max_delta, n_changed)

Compute a signed per-pixel diff of two greyscale matrices.
Writes a colour PNG diff to `diff_path`:
  green  — pixel is darker in `after`  (ink added)
  red    — pixel is lighter in `after` (ink removed)
  white  — no change
Returns the maximum absolute delta and the number of changed pixels.
"""
function compare_imgs(
        before::Matrix{UInt8}, after::Matrix{UInt8},
        diff_path::String,
    )::Tuple{Int, Int}
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
        if d != 0
            max_delta = max(max_delta, abs(d))
            n_changed += 1
        end
        if d > 0
            # lighter in after (ink removed): red
            v = reinterpret(N0f8, UInt8(255 - d))
            diff_img[row, col] = RGB{N0f8}(reinterpret(N0f8, 0xff), v, v)
        elseif d < 0
            # darker in after (ink added): green
            v = reinterpret(N0f8, UInt8(255 + d))
            diff_img[row, col] = RGB{N0f8}(v, reinterpret(N0f8, 0xff), v)
        else
            diff_img[row, col] = RGB{N0f8}(
                reinterpret(N0f8, 0xff),
                reinterpret(N0f8, 0xff),
                reinterpret(N0f8, 0xff),
            )
        end
    end

    PNGFiles.save(diff_path, diff_img)
    return (max_delta, n_changed)
end

# ── Reference download ────────────────────────────────────────────────────────

function _ensure_reference(name::Symbol, old_dir::String)::Union{String, Nothing}
    filename = "stress_test_output_$(name).png"
    path = joinpath(old_dir, filename)
    isfile(path) && return path

    url = "$(IMAGES_BASE)/$(filename)"
    try
        download(url, path)
        println("  Downloaded reference: $(filename)")
        return path
    catch e
        @warn "Could not download reference for :$(name) from $(url): $e"
        return nothing
    end
end

# ── Main loop ─────────────────────────────────────────────────────────────────

"""
    run_all(font_names = ALL_FONTS; new_dir, old_dir, diff_dir)

Run the stress test for each font in `font_names`, download reference PNGs
when absent, compare new outputs against references, and write signed diff PNGs.
"""
function run_all(
        font_names = ALL_FONTS;
        new_dir::String = "images_new",
        old_dir::String = "images_old",
        diff_dir::String = "images_diff",
    )
    mkpath(new_dir); mkpath(old_dir); mkpath(diff_dir)
    results = []

    for name in font_names
        println("\n# Testing font: $(name)")

        # Render new output
        new_path = joinpath(new_dir, "stress_test_$(name).png")
        let fam = _resolve_font(":$(name)")
            mt = TeXLayout.load_math_table(fam.math)
            face_math = FTFont(fam.math)
            face_regular = fam.regular !== nothing ? FTFont(fam.regular) : nothing
            font_name = FreeTypeAbstraction.family_name(face_math)
            write_png(new_path, _build_sheet(fam, mt, face_math, face_regular, font_name))
        end

        # Fetch reference
        ref_path = _ensure_reference(name, old_dir)
        if ref_path === nothing
            println("  No reference — skipping comparison for :$(name)")
            push!(results, (name, nothing, nothing, nothing))
            continue
        end

        # Compare
        diff_path = joinpath(diff_dir, "diff_$(name).png")
        local new_img, ref_img
        try
            new_img = read_png(new_path)
            ref_img = read_png(ref_path)
        catch e
            @warn "Could not read PNG files for :$(name): $e"
            push!(results, (name, nothing, nothing, nothing))
            continue
        end

        max_delta, n_changed = compare_imgs(ref_img, new_img, diff_path)
        push!(results, (name, max_delta, n_changed, diff_path))

        total_px = length(new_img)
        pct = round(100.0 * n_changed / max(1, total_px); digits = 2)
        println(
            "  max Δ = $(max_delta)  changed = $(n_changed)/$(total_px)" *
                "  ($(pct)%)  diff → $(diff_path)"
        )
    end

    # ── Summary ───────────────────────────────────────────────────────────────
    println("\n$(repeat('─', 60))")
    println("SUMMARY")
    println(repeat('─', 60))
    for (name, max_delta, n_changed, diff_path) in results
        if max_delta === nothing
            println("  :$(name)  — no reference")
        else
            total_px = 0
            png_file = joinpath(new_dir, "stress_test_$(name).png")
            try
                img = read_png(png_file); total_px = length(img)
            catch
            end
            pct = round(100.0 * n_changed / max(1, total_px); digits = 2)
            status = n_changed == 0 ? "IDENTICAL" :
                max_delta <= 3 ? "ok (minor AA)" : "CHANGED"
            println(
                "  :$(rpad(string(name), 10))  $(status)  " *
                    "max Δ = $(max_delta)  $(n_changed) px  ($(pct)%)"
            )
        end
    end
    println(repeat('─', 60))
    return nothing
end

# ── Script entrypoint ─────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    _font_names = isempty(ARGS) ? ALL_FONTS :
        [Symbol(a) for a in ARGS]
    run_all(_font_names)
end
