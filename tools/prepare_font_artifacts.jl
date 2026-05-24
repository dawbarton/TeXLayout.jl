# Prepare Julia font artifact tarballs for TeXLayout.jl.
#
# For each font family this script:
#   1. Downloads required OTF/TTF files (skipping if already cached)
#   2. Assembles them into a staging directory with consistent names:
#        math.otf, regular.otf, bold.otf, italic.otf, bolditalic.otf
#   3. Creates a Julia artifact (via Pkg.Artifacts.create_artifact) to obtain
#      the canonical git-tree-sha1
#   4. Archives the artifact to a .tar.gz tarball (archive_artifact)
#   5. Computes the SHA-256 of the tarball
#   6. Writes a draft Artifacts.toml with placeholder download URLs
#
# Output tarballs → shared/font_archives/  (or first CLI argument)
# After upload to a GitHub Release, replace PLACEHOLDER_*_URL in the draft.
#
# Usage:
#   julia tools/prepare_font_artifacts.jl [output_dir]
#
# Font sources
# ────────────
#  NewCMMath   local  (NewComputerModern from MathTeXEngine.jl assets)
#  Pagella     local  (TeXGyrePagellaMTE from MathTeXEngine.jl assets)
#  Luciole     local  (Luciole-Math from MathTeXEngine.jl assets)
#  STIXTwo     GitHub raw (stipub/stixfonts archive/STIXv2.0.2/OTF/)
#  FiraMath    GitHub release (firamath/firamath v0.3.4) + mozilla/Fira raw OTFs
#  Schola      CTAN mirrors (tex-gyre-math/schola + tex-gyre text)
#  Termes      CTAN mirrors (tex-gyre-math/termes + tex-gyre text)
#  Bonum       CTAN mirrors (tex-gyre-math/bonum  + tex-gyre text)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io = devnull)

using Pkg.Artifacts
using SHA

const FONTS_DIR = joinpath(
    @__DIR__, "..", "..", "external",
    "MathTeXEngine.jl", "assets", "fonts"
)

# ── Helpers ────────────────────────────────────────────────────────────────────

function sha256_file(path)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end

# Download url → dest, skipping if dest already exists.
function maybe_download(url, dest)
    if isfile(dest)
        println("  cached: $(basename(dest))")
        return
    end
    println("  downloading: $(basename(dest))")
    return run(`curl -fsSL -o $dest $url`)
end

# Build artifact from staging dir; return (tree_sha1_hex, tarball_sha256, tarball_path).
function make_artifact(family_name, staging, output_dir)
    println("  building artifact: $family_name")
    tree_sha1 = create_artifact() do dir
        for f in readdir(staging)
            cp(joinpath(staging, f), joinpath(dir, f); force = true)
        end
    end
    hex = bytes2hex(tree_sha1.bytes)
    tarball = joinpath(output_dir, "$(family_name).tar.gz")
    archive_artifact(tree_sha1, tarball)
    s256 = sha256_file(tarball)
    sz = filesize(tarball)
    println("  git-tree-sha1 : $hex")
    println("  sha256        : $s256")
    println("  size          : $(round(sz / 1024; digits = 1)) KB  →  $tarball")
    return (hex, s256)
end

# Return one Artifacts.toml stanza (String).
function toml_stanza(name, tree_sha1, sha256, placeholder_url)
    return """
    [$name]
    lazy = true
    git-tree-sha1 = "$tree_sha1"

        [[$(name).download]]
        url = "$placeholder_url"
        sha256 = "$sha256"
    """
end

# ── Main ───────────────────────────────────────────────────────────────────────

function main()
    output_dir = length(ARGS) >= 1 ? ARGS[1] :
        joinpath(@__DIR__, "..", "shared", "font_archives")
    mkpath(output_dir)
    dl = joinpath(output_dir, "_downloads")   # local download cache
    mkpath(dl)

    stanzas = String[]

    # ── 1. NewCMMath (local) ──────────────────────────────────────────────────
    println("\n=== NewCMMath ===")
    src = joinpath(FONTS_DIR, "NewComputerModern")
    staging = mktempdir()
    cp(joinpath(src, "NewCMMath-Regular.otf"), joinpath(staging, "math.otf"))
    cp(joinpath(src, "NewCM10-Regular.otf"), joinpath(staging, "regular.otf"))
    cp(joinpath(src, "NewCM10-Bold.otf"), joinpath(staging, "bold.otf"))
    cp(joinpath(src, "NewCM10-Italic.otf"), joinpath(staging, "italic.otf"))
    cp(joinpath(src, "NewCM10-BoldItalic.otf"), joinpath(staging, "bolditalic.otf"))
    cp(joinpath(src, "LICENCE"), joinpath(staging, "LICENSE"))  # GUST Font License (LPPL 1.3c)
    h, s = make_artifact("NewCMMath", staging, output_dir)
    push!(stanzas, toml_stanza("NewCMMath", h, s, "PLACEHOLDER_NEWCM_URL"))

    # ── 2. TeXGyre Pagella MTE (local) ───────────────────────────────────────
    println("\n=== Pagella ===")
    src = joinpath(FONTS_DIR, "TeXGyrePagellaMTE")
    staging = mktempdir()
    cp(joinpath(src, "TeXGyrePagellaMTE-Math.otf"), joinpath(staging, "math.otf"))
    cp(joinpath(src, "TeXGyrePagellaMTE-Regular.otf"), joinpath(staging, "regular.otf"))
    cp(joinpath(src, "TeXGyrePagellaMTE-Bold.otf"), joinpath(staging, "bold.otf"))
    cp(joinpath(src, "TeXGyrePagellaMTE-Italic.otf"), joinpath(staging, "italic.otf"))
    cp(joinpath(src, "TeXGyrePagellaMTE-BoldItalic.otf"), joinpath(staging, "bolditalic.otf"))
    cp(joinpath(src, "LICENSE"), joinpath(staging, "LICENSE"))  # GUST Font License (LPPL 1.3c)
    h, s = make_artifact("Pagella", staging, output_dir)
    push!(stanzas, toml_stanza("Pagella", h, s, "PLACEHOLDER_PAGELLA_URL"))

    # ── 3. Luciole Math (local) ───────────────────────────────────────────────
    println("\n=== Luciole ===")
    src = joinpath(FONTS_DIR, "Luciole-Math")
    staging = mktempdir()
    # Luciole text fonts are TTF; keep .ttf extension so FreeType handles them.
    cp(joinpath(src, "Luciole-Math.otf"), joinpath(staging, "math.otf"))
    cp(joinpath(src, "Luciole-Regular.ttf"), joinpath(staging, "regular.ttf"))
    cp(joinpath(src, "Luciole-Bold.ttf"), joinpath(staging, "bold.ttf"))
    cp(joinpath(src, "Luciole-Regular-Italic.ttf"), joinpath(staging, "italic.ttf"))
    cp(joinpath(src, "Luciole-Bold-Italic.ttf"), joinpath(staging, "bolditalic.ttf"))
    # README states: Luciole-Math.otf is SIL OFL 1.1; text TTFs are CC-BY.
    # This matches what the CTAN distribution ships (no separate OFL.txt there either).
    cp(joinpath(src, "README-Luciole.md"), joinpath(staging, "README.md"))
    h, s = make_artifact("Luciole", staging, output_dir)
    push!(stanzas, toml_stanza("Luciole", h, s, "PLACEHOLDER_LUCIOLE_URL"))

    # ── 4. STIX Two (GitHub raw — stipub/stixfonts archive/STIXv2.0.2) ───────
    println("\n=== STIXTwo ===")
    stix_base = "https://raw.githubusercontent.com/stipub/stixfonts/master/archive/STIXv2.0.2/OTF"
    stix_files = [
        ("STIX2Math.otf", "math.otf"),
        ("STIX2Text-Regular.otf", "regular.otf"),
        ("STIX2Text-Bold.otf", "bold.otf"),
        ("STIX2Text-Italic.otf", "italic.otf"),
        ("STIX2Text-BoldItalic.otf", "bolditalic.otf"),
    ]
    staging = mktempdir()
    for (src_name, dest_name) in stix_files
        dest = joinpath(dl, "stix_$(src_name)")
        maybe_download("$stix_base/$src_name", dest)
        cp(dest, joinpath(staging, dest_name))
    end
    # OFL.txt includes the STIX copyright notice and full license text.
    stix_ofl_dest = joinpath(dl, "stix_OFL.txt")
    maybe_download("https://raw.githubusercontent.com/stipub/stixfonts/master/OFL.txt", stix_ofl_dest)
    cp(stix_ofl_dest, joinpath(staging, "OFL.txt"))
    h, s = make_artifact("STIXTwo", staging, output_dir)
    push!(stanzas, toml_stanza("STIXTwo", h, s, "PLACEHOLDER_STIXTWO_URL"))

    # ── 5. Fira Math + Fira Sans (GitHub) ────────────────────────────────────
    println("\n=== FiraMath ===")
    fira_math_url = "https://github.com/firamath/firamath/releases/download/v0.3.4/FiraMath-Regular.otf"
    fira_sans_base = "https://raw.githubusercontent.com/mozilla/Fira/master/otf"
    fira_files = [
        (fira_math_url, "fira_math.otf", "math.otf"),
        ("$fira_sans_base/FiraSans-Regular.otf", "fira_sans_regular.otf", "regular.otf"),
        ("$fira_sans_base/FiraSans-Bold.otf", "fira_sans_bold.otf", "bold.otf"),
        ("$fira_sans_base/FiraSans-Italic.otf", "fira_sans_italic.otf", "italic.otf"),
        ("$fira_sans_base/FiraSans-BoldItalic.otf", "fira_sans_bolditalic.otf", "bolditalic.otf"),
    ]
    staging = mktempdir()
    for (url, cache_name, dest_name) in fira_files
        dest = joinpath(dl, cache_name)
        maybe_download(url, dest)
        cp(dest, joinpath(staging, dest_name))
    end
    # Separate OFL files for Fira Math (firamath/firamath) and Fira Sans (mozilla/Fira).
    fira_math_lic = joinpath(dl, "firamath_LICENSE")
    fira_sans_lic = joinpath(dl, "firasans_LICENSE")
    maybe_download("https://raw.githubusercontent.com/firamath/firamath/master/LICENSE", fira_math_lic)
    maybe_download("https://raw.githubusercontent.com/mozilla/Fira/master/LICENSE", fira_sans_lic)
    cp(fira_math_lic, joinpath(staging, "LICENSE-FiraMath"))
    cp(fira_sans_lic, joinpath(staging, "LICENSE-FiraSans"))
    h, s = make_artifact("FiraMath", staging, output_dir)
    push!(stanzas, toml_stanza("FiraMath", h, s, "PLACEHOLDER_FIRAMATH_URL"))

    # ── 6. TeX Gyre Schola Math (CTAN) ───────────────────────────────────────
    println("\n=== Schola ===")
    schola_base = "https://mirrors.ctan.org/fonts/tex-gyre-math/schola"
    schola_text = "https://mirrors.ctan.org/fonts/tex-gyre/fonts/opentype/public/tex-gyre"
    schola_files = [
        ("$schola_base/texgyreschola-math.otf", "schola_math.otf", "math.otf"),
        ("$schola_text/texgyreschola-regular.otf", "schola_regular.otf", "regular.otf"),
        ("$schola_text/texgyreschola-bold.otf", "schola_bold.otf", "bold.otf"),
        ("$schola_text/texgyreschola-italic.otf", "schola_italic.otf", "italic.otf"),
        ("$schola_text/texgyreschola-bolditalic.otf", "schola_bolditalic.otf", "bolditalic.otf"),
    ]
    staging = mktempdir()
    for (url, cache_name, dest_name) in schola_files
        dest = joinpath(dl, cache_name)
        maybe_download(url, dest)
        cp(dest, joinpath(staging, dest_name))
    end
    # GUST Font License (LPPL 1.3c) — fetched from the CTAN distribution.
    schola_lic = joinpath(dl, "schola_LICENSE.md")
    maybe_download("https://mirrors.ctan.org/fonts/tex-gyre-math/README-TeX-Gyre-Math.txt", schola_lic)
    cp(schola_lic, joinpath(staging, "LICENSE.txt"))
    h, s = make_artifact("Schola", staging, output_dir)
    push!(stanzas, toml_stanza("Schola", h, s, "PLACEHOLDER_SCHOLA_URL"))

    # ── 7. TeX Gyre Termes Math (CTAN) ───────────────────────────────────────
    println("\n=== Termes ===")
    termes_base = "https://mirrors.ctan.org/fonts/tex-gyre-math/termes"
    termes_text = "https://mirrors.ctan.org/fonts/tex-gyre/fonts/opentype/public/tex-gyre"
    termes_files = [
        ("$termes_base/texgyretermes-math.otf", "termes_math.otf", "math.otf"),
        ("$termes_text/texgyretermes-regular.otf", "termes_regular.otf", "regular.otf"),
        ("$termes_text/texgyretermes-bold.otf", "termes_bold.otf", "bold.otf"),
        ("$termes_text/texgyretermes-italic.otf", "termes_italic.otf", "italic.otf"),
        ("$termes_text/texgyretermes-bolditalic.otf", "termes_bolditalic.otf", "bolditalic.otf"),
    ]
    staging = mktempdir()
    for (url, cache_name, dest_name) in termes_files
        dest = joinpath(dl, cache_name)
        maybe_download(url, dest)
        cp(dest, joinpath(staging, dest_name))
    end
    termes_lic = joinpath(dl, "termes_LICENSE.md")
    maybe_download("https://mirrors.ctan.org/fonts/tex-gyre-math/README-TeX-Gyre-Math.txt", termes_lic)
    cp(termes_lic, joinpath(staging, "LICENSE.txt"))
    h, s = make_artifact("Termes", staging, output_dir)
    push!(stanzas, toml_stanza("Termes", h, s, "PLACEHOLDER_TERMES_URL"))

    # ── 8. TeX Gyre Bonum Math (CTAN) ────────────────────────────────────────
    println("\n=== Bonum ===")
    bonum_base = "https://mirrors.ctan.org/fonts/tex-gyre-math/bonum"
    bonum_text = "https://mirrors.ctan.org/fonts/tex-gyre/fonts/opentype/public/tex-gyre"
    bonum_files = [
        ("$bonum_base/texgyrebonum-math.otf", "bonum_math.otf", "math.otf"),
        ("$bonum_text/texgyrebonum-regular.otf", "bonum_regular.otf", "regular.otf"),
        ("$bonum_text/texgyrebonum-bold.otf", "bonum_bold.otf", "bold.otf"),
        ("$bonum_text/texgyrebonum-italic.otf", "bonum_italic.otf", "italic.otf"),
        ("$bonum_text/texgyrebonum-bolditalic.otf", "bonum_bolditalic.otf", "bolditalic.otf"),
    ]
    staging = mktempdir()
    for (url, cache_name, dest_name) in bonum_files
        dest = joinpath(dl, cache_name)
        maybe_download(url, dest)
        cp(dest, joinpath(staging, dest_name))
    end
    bonum_lic = joinpath(dl, "bonum_LICENSE.md")
    maybe_download("https://mirrors.ctan.org/fonts/tex-gyre-math/README-TeX-Gyre-Math.txt", bonum_lic)
    cp(bonum_lic, joinpath(staging, "LICENSE.txt"))
    h, s = make_artifact("Bonum", staging, output_dir)
    push!(stanzas, toml_stanza("Bonum", h, s, "PLACEHOLDER_BONUM_URL"))

    # ── Write draft Artifacts.toml ────────────────────────────────────────────
    toml_path = joinpath(output_dir, "Artifacts.toml.draft")
    println("\n=== Writing draft Artifacts.toml → $toml_path ===")
    open(toml_path, "w") do io
        println(io, "# Draft Artifacts.toml for TeXLayout.jl")
        println(io, "# Replace each PLACEHOLDER_*_URL with the actual GitHub Release asset URL")
        println(io, "# after uploading the .tar.gz files to the TeXLayout.jl release.")
        println(io, "# Copy the completed file to TeXLayout.jl/Artifacts.toml.")
        println(io)
        for stanza in stanzas
            print(io, stanza)
        end
    end

    return println(
        """
        Done.  Eight tarballs and a draft Artifacts.toml written to:
          $output_dir

        Next steps:
          1. Create a GitHub Release on your TeXLayout.jl repo (tag: e.g. v0.1-fonts)
          2. Upload the eight .tar.gz files as release assets
          3. Replace PLACEHOLDER_*_URL in Artifacts.toml.draft with the release asset URLs
             (format: https://github.com/<user>/TeXLayout.jl/releases/download/v0.1-fonts/<Name>.tar.gz)
          4. Copy the completed file to TeXLayout.jl/Artifacts.toml
          5. Re-add :schola/:termes/:bonum loaders to src/fonts.jl (see comments there)
        """
    )
end

main()
