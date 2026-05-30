# Run the stress-test sheet for every bundled font family and compare the
# resulting PGM files against reference images.
#
# Reference images are downloaded from the GitHub release tagged
# v0.1.0-stress (if not already present in images_old/).  When no reference
# exists for a font, the new image is written and flagged as "no reference".
#
# Output directories (relative to the working directory):
#   images_new/         freshly rendered PGM files
#   images_old/         reference PGM files (downloaded on first run)
#   images_diff/        signed colour PPM diffs (green = added, red = removed)
#
# Public API (usable when included by another script):
#   run_all(font_names = ALL_FONTS; new_dir, old_dir, diff_dir) -> nothing
#
# Usage as script:
#   julia tools/stress_test_all.jl                      # all fonts
#   julia tools/stress_test_all.jl new_cm pagella        # selected fonts

using Pkg
Pkg.activate(@__DIR__; io = devnull)

include("stress_test_sheet.jl")  # defines run_stress_test, STRESS_SECTIONS, …

const IMAGES_BASE =
    "https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.1.0-stress"

# All font families bundled with TeXLayout.jl.
const ALL_FONTS = [
    :new_cm, :pagella, :luciole, :stix_two,
    :fira_math, :schola, :termes, :bonum,
]

# ── PGM I/O ───────────────────────────────────────────────────────────────────

# Read one whitespace/comment token from a Netpbm header.
function _pgm_token(io::IO)::String
    buf = UInt8[]
    while !eof(io)
        b = read(io, UInt8)
        if b == UInt8('#')
            readline(io)   # skip comment line
        elseif b in (0x20, 0x09, 0x0a, 0x0d)
            isempty(buf) || break   # whitespace ends a token; leading WS skipped
        else
            push!(buf, b)
        end
    end
    isempty(buf) && error("Unexpected EOF reading Netpbm header")
    return String(buf)
end

"""
    read_pgm(path) -> Matrix{UInt8}

Read a binary PGM (P5, maxval 255) file into a height×width matrix.
"""
function read_pgm(path::String)::Matrix{UInt8}
    return open(path, "r") do io
        magic = _pgm_token(io)
        magic == "P5" ||
            error("Expected P5 PGM format in $(path), got $(magic)")
        width = parse(Int, _pgm_token(io))
        height = parse(Int, _pgm_token(io))
        maxval = parse(Int, _pgm_token(io))
        maxval == 255 || error("Unsupported PGM maxval $(maxval) in $(path)")
        raw = read(io, width * height)
        length(raw) == width * height ||
            error("Truncated PGM pixel data in $(path)")
        img = Matrix{UInt8}(undef, height, width)
        for r in 1:height
            img[r, :] .= @view raw[(1 + (r - 1) * width):(r * width)]
        end
        return img
    end
end

# ── Comparison and diff image ─────────────────────────────────────────────────

"""
    compare_pgms(before, after, diff_path) -> (max_delta, n_changed)

Compute a signed per-pixel diff of two greyscale PGM matrices.
Writes a colour PPM diff to `diff_path`:
  green  — pixel is darker in `after`  (ink added)
  red    — pixel is lighter in `after` (ink removed)
  white  — no change
Returns the maximum absolute delta and the number of changed pixels.
"""
function compare_pgms(
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
    rowbuf = Vector{UInt8}(undef, 3W)

    open(diff_path, "w") do io
        write(io, "P6\n$W $H\n255\n")
        for row in 1:H
            idx = 1
            for col in 1:W
                d = Int(after[row, col]) - Int(before[row, col])
                if d != 0
                    max_delta = max(max_delta, abs(d))
                    n_changed += 1
                end
                if d > 0
                    # After is lighter (ink removed): red channel
                    rowbuf[idx] = 0xff
                    rowbuf[idx + 1] = UInt8(255 - d)
                    rowbuf[idx + 2] = UInt8(255 - d)
                elseif d < 0
                    # After is darker (ink added): green channel
                    rowbuf[idx] = UInt8(255 + d)
                    rowbuf[idx + 1] = 0xff
                    rowbuf[idx + 2] = UInt8(255 + d)
                else
                    rowbuf[idx] = rowbuf[idx + 1] = rowbuf[idx + 2] = 0xff
                end
                idx += 3
            end
            write(io, rowbuf)
        end
    end
    return (max_delta, n_changed)
end

# ── Reference download ────────────────────────────────────────────────────────

function _ensure_reference(name::Symbol, old_dir::String)::Union{String, Nothing}
    filename = "stress_test_$(name).ppm"
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

Run the stress test for each font in `font_names`, download reference PGMs
when absent, compare new outputs against references, and write signed diff PPMs.
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
        new_path = joinpath(new_dir, "stress_test_$(name).ppm")
        run_stress_test(":$(name)", :ppm, new_path)

        # Fetch reference
        ref_path = _ensure_reference(name, old_dir)
        if ref_path === nothing
            println("  No reference — skipping comparison for :$(name)")
            push!(results, (name, nothing, nothing, nothing))
            continue
        end

        # Compare
        diff_path = joinpath(diff_dir, "diff_$(name).ppm")
        local new_img, ref_img
        try
            new_img = read_pgm(new_path)
            ref_img = read_pgm(ref_path)
        catch e
            @warn "Could not read PGM files for :$(name): $e"
            push!(results, (name, nothing, nothing, nothing))
            continue
        end

        max_delta, n_changed = compare_pgms(ref_img, new_img, diff_path)
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
            ppm_file = joinpath(new_dir, "stress_test_$(name).ppm")
            try
                img = read_pgm(ppm_file); total_px = length(img)
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
