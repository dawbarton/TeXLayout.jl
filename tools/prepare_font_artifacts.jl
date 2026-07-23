# Prepare Julia font artifact tarballs for TeXLayout.jl.
#
# For each font family this script:
#   1. Creates a Julia artifact (via Pkg.Artifacts.create_artifact) to obtain
#      the canonical git-tree-sha1
#   2. Archives the artifact to a .tar.gz tarball (archive_artifact)
#   3. Computes the SHA-256 of the tarball
#   4. Writes a draft Artifacts.toml with placeholder download URLs
#
# Output tarballs → artifacts/  (or first CLI argument)
# After upload to a GitHub Release, replace PLACEHOLDER_*_URL in the draft.
#
# Usage:
#   julia tools/prepare_font_artifacts.jl [output_dir]

using Pkg
Pkg.activate(@__DIR__; io = devnull)

using Pkg.Artifacts
using SHA

const ARTIFACTS_DIR = joinpath(
    @__DIR__, "..", "artifacts"
)

# ── Helpers ────────────────────────────────────────────────────────────────────

function sha256_file(path)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
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
    output_dir = length(ARGS) >= 1 ? ARGS[1] : ARTIFACTS_DIR

    stanzas = String[]

    GITHUB_RELEASE =
        "https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.1.0-fonts"
    COMPANION_RELEASE =
        "https://github.com/dawbarton/TeXLayout.jl/releases/download/v0.3.0-fonts"

    # ── NewCMMath ────────────────────────────────────────────────────────────
    println("\n=== NewCMMath ===")
    src = joinpath(ARTIFACTS_DIR, "NewCMMath")
    h, s = make_artifact("NewCMMath", src, output_dir)
    push!(stanzas, toml_stanza("NewCMMath", h, s, "$GITHUB_RELEASE/NewCMMath.tar.gz"))

    # ── Luciole Math ─────────────────────────────────────────────────────────
    println("\n=== Luciole ===")
    src = joinpath(ARTIFACTS_DIR, "Luciole")
    h, s = make_artifact("Luciole", src, output_dir)
    push!(stanzas, toml_stanza("Luciole", h, s, "$GITHUB_RELEASE/Luciole.tar.gz"))

    # ── STIX Two ─────────────────────────────────────────────────────────────
    println("\n=== STIXTwo ===")
    src = joinpath(ARTIFACTS_DIR, "STIXTwo")
    h, s = make_artifact("STIXTwo", src, output_dir)
    push!(stanzas, toml_stanza("STIXTwo", h, s, "$GITHUB_RELEASE/STIXTwo.tar.gz"))

    # ── Fira Math + Fira Sans ────────────────────────────────────────────────
    println("\n=== FiraMath ===")
    src = joinpath(ARTIFACTS_DIR, "FiraMath")
    h, s = make_artifact("FiraMath", src, output_dir)
    push!(stanzas, toml_stanza("FiraMath", h, s, "$GITHUB_RELEASE/FiraMath.tar.gz"))

    # ── TeXGyre Bonum ────────────────────────────────────────────────────────
    println("\n=== Bonum ===")
    src = joinpath(ARTIFACTS_DIR, "Bonum")
    h, s = make_artifact("Bonum", src, output_dir)
    push!(stanzas, toml_stanza("Bonum", h, s, "$GITHUB_RELEASE/Bonum.tar.gz"))

    # ── TeXGyre Pagella ──────────────────────────────────────────────────────
    println("\n=== Pagella ===")
    src = joinpath(ARTIFACTS_DIR, "Pagella")
    h, s = make_artifact("Pagella", src, output_dir)
    push!(stanzas, toml_stanza("Pagella", h, s, "$GITHUB_RELEASE/Pagella.tar.gz"))

    # ── TeXGyre Schola ───────────────────────────────────────────────────────
    println("\n=== Schola ===")
    src = joinpath(ARTIFACTS_DIR, "Schola")
    h, s = make_artifact("Schola", src, output_dir)
    push!(stanzas, toml_stanza("Schola", h, s, "$GITHUB_RELEASE/Schola.tar.gz"))

    # ── TeXGyre Termes ───────────────────────────────────────────────────────
    println("\n=== Termes ===")
    src = joinpath(ARTIFACTS_DIR, "Termes")
    h, s = make_artifact("Termes", src, output_dir)
    push!(stanzas, toml_stanza("Termes", h, s, "$GITHUB_RELEASE/Termes.tar.gz"))

    # ── Shared text companions ───────────────────────────────────────────────
    println("\n=== Heros ===")
    src = joinpath(ARTIFACTS_DIR, "Heros")
    h, s = make_artifact("Heros", src, output_dir)
    push!(stanzas, toml_stanza("Heros", h, s, "$COMPANION_RELEASE/Heros.tar.gz"))

    println("\n=== Cursor ===")
    src = joinpath(ARTIFACTS_DIR, "Cursor")
    h, s = make_artifact("Cursor", src, output_dir)
    push!(stanzas, toml_stanza("Cursor", h, s, "$COMPANION_RELEASE/Cursor.tar.gz"))

    # ── Write draft Artifacts.toml ────────────────────────────────────────────
    toml_path = joinpath(output_dir, "Artifacts.toml.draft")
    println("\n=== Writing draft Artifacts.toml → $toml_path ===")
    open(toml_path, "w") do io
        println(io, "# Artifacts.toml for TeXLayout.jl")
        println(io, "#")
        println(io, "# Each entry is a lazy artifact: the tarball is downloaded only when the user")
        println(io, "# first calls font_family(:symbol) for that family.")
        println(io, "#")
        println(io, "# Internal structure of every tarball:")
        println(io, "#   math.otf           — OpenType math font (mandatory)")
        println(io, "#   regular.otf/.ttf   — upright text (optional)")
        println(io, "#   bold.otf/.ttf")
        println(io, "#   italic.otf/.ttf")
        println(io, "#   bolditalic.otf/.ttf")
        println(io, "#")
        println(io, "# Text-only companion artifacts omit math.otf.")
        println(io, "#   LICENSE / OFL.txt / README.md  — font license files")
        println(io)
        for stanza in stanzas
            print(io, stanza)
        end
    end

    return println(
        """
        Done.  Tarballs and a draft Artifacts.toml written to:
          $output_dir

        Next steps:
          1. Create a GitHub Release for any new font assets
          2. Upload the .tar.gz files as release assets
          3. Update URLs in Artifacts.toml.draft with the release asset URLs
             (format: https://github.com/dawbarton/TeXLayout.jl/releases/download/<tag>/<Name>.tar.gz)
          4. Copy the completed file to TeXLayout.jl/Artifacts.toml
        """
    )
end

main()
