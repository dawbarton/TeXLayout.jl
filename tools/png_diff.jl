# Render a signed visual diff between two PNGs.
#
# The script reads two input images, flattens them onto a white background,
# converts them to grayscale, and computes
#
#     diff = after - before
#
# per pixel. Zero difference maps to white. Positive differences are shown in
# green, negative differences in red, and the colour intensity is proportional
# to the absolute pixel delta, so tiny antialiasing changes remain faint.
#
# Usage:
#   julia tools/png_diff.jl before.png after.png [output.png]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io = devnull)

const WHITE = UInt8(0xff)
const IMAGEMAGICK = let magick = Sys.which("magick"), convert = Sys.which("convert")
    magick !== nothing ? magick : convert
end

function usage()
    println("Usage: julia tools/png_diff.jl before.png after.png [output.png]")
    println("Computes a signed grayscale diff: output = after - before")
    return exit(1)
end

imagemagick_cmd(args::Vector{String}) =
    IMAGEMAGICK === nothing ? error("ImageMagick not found (`magick` or `convert`)") :
    Cmd(vcat([IMAGEMAGICK], args))

function _read_token(io)::String
    buf = UInt8[]
    while !eof(io)
        b = read(io, UInt8)
        if b == UInt8('#')
            readline(io)
        elseif isspace(Char(b))
            continue
        else
            push!(buf, b)
            break
        end
    end
    isempty(buf) && error("Unexpected EOF while reading Netpbm header")
    while !eof(io)
        b = read(io, UInt8)
        if b == UInt8('#')
            readline(io)
            break
        elseif isspace(Char(b))
            break
        else
            push!(buf, b)
        end
    end
    return String(buf)
end

function read_pgm(path::String)::Matrix{UInt8}
    cmd = imagemagick_cmd(
        [
            path,
            "-background", "white",
            "-alpha", "remove",
            "-colorspace", "Gray",
            "pgm:-",
        ]
    )
    return open(cmd, "r") do io
        magic = _read_token(io)
        magic == "P5" || error("Expected P5 data from ImageMagick, got $magic")
        width = parse(Int, _read_token(io))
        height = parse(Int, _read_token(io))
        maxval = parse(Int, _read_token(io))
        maxval == 255 || error("Unsupported Netpbm max value $maxval")

        raw = read(io, width * height)
        length(raw) == width * height || error(
            "ImageMagick produced truncated data for $path"
        )

        image = Matrix{UInt8}(undef, height, width)
        offset = 1
        for row in 1:height
            image[row, :] = @view raw[offset:(offset + width - 1)]
            offset += width
        end
        return image
    end
end

function pad_image(image::Matrix{UInt8}, height::Int, width::Int)::Matrix{UInt8}
    size(image) == (height, width) && return image
    out = fill(WHITE, height, width)
    in_height, in_width = size(image)
    out[1:in_height, 1:in_width] .= image
    return out
end

@inline function diff_pixel(diff::Int)::NTuple{3, UInt8}
    if diff > 0
        v = UInt8(255 - diff)
        return (v, WHITE, v)
    elseif diff < 0
        v = UInt8(255 + diff)
        return (WHITE, v, v)
    else
        return (WHITE, WHITE, WHITE)
    end
end

function build_diff(before::Matrix{UInt8}, after::Matrix{UInt8})
    before_size = size(before)
    after_size = size(after)
    height = max(before_size[1], after_size[1])
    width = max(before_size[2], after_size[2])

    if before_size != after_size
        @warn "Image sizes differ; padding smaller image(s) with white" before_size after_size padded_size = (height, width)
    end

    before_padded = pad_image(before, height, width)
    after_padded = pad_image(after, height, width)
    out = Array{UInt8}(undef, height, width, 3)
    max_abs = 0

    for row in 1:height, col in 1:width
        diff = Int(after_padded[row, col]) - Int(before_padded[row, col])
        max_abs = max(max_abs, abs(diff))
        r, g, b = diff_pixel(diff)
        out[row, col, 1] = r
        out[row, col, 2] = g
        out[row, col, 3] = b
    end

    return out, max_abs
end

function write_png(path::String, image::Array{UInt8, 3})
    height, width, channels = size(image)
    channels == 3 || error("Expected RGB image data")

    open(imagemagick_cmd(["ppm:-", "png:$path"]), "w") do io
        write(io, "P6\n$width $height\n255\n")
        rowbuf = Vector{UInt8}(undef, 3 * width)
        for row in 1:height
            idx = 1
            for col in 1:width
                rowbuf[idx] = image[row, col, 1]
                rowbuf[idx + 1] = image[row, col, 2]
                rowbuf[idx + 2] = image[row, col, 3]
                idx += 3
            end
            write(io, rowbuf)
        end
    end
    return println("Written $path  ($(width)x$(height) px)")
end

function main()
    length(ARGS) in (2, 3) || usage()
    before_path = ARGS[1]
    after_path = ARGS[2]
    out_path = length(ARGS) == 3 ? ARGS[3] : "png_diff.png"

    isfile(before_path) || error("Input file not found: $before_path")
    isfile(after_path) || error("Input file not found: $after_path")

    before = read_pgm(before_path)
    after = read_pgm(after_path)
    diff_image, max_abs = build_diff(before, after)
    write_png(out_path, diff_image)
    return println("Max absolute grayscale delta: $max_abs")
end

main()
