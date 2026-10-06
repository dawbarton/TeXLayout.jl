# Concurrent layout from several threads.  Glyph metrics are read from cached
# FreeType faces and module-level Dict caches that all threads share; before
# they were locked, concurrent layout crashed inside FreeType or returned
# wrong metrics.  A race needs real threads, so the check runs in a child
# process started with four threads, using the fixture font.

const _THREAD_CHILD_SCRIPT = raw"""
using TeXLayout, Base.Threads
const FAMILY = TeXLayout.FontFamily(ARGS[1])
const EXPRS = [
    raw"\frac{1}{1 + \frac{1}{1 + \frac{1}{2}}}", raw"\sqrt[3]{x^{a^{b}} + y_{m_{n}}}",
    raw"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}", raw"\int_{-\infty}^{\infty} e^{-x^2/2}\,dx",
    raw"\left( \begin{matrix} a & b \\ c & d \end{matrix} \right) \widehat{xyz} \overbrace{a+b}^{n}",
    raw"\alpha\beta\gamma\delta\epsilon\zeta\eta\theta\iota\kappa\lambda\mu\nu\xi\pi\rho\sigma\tau",
    raw"\mathbf{ABC} + \mathcal{L} + \mathbb{R} \xrightarrow[a]{b} \binom{n}{k} \sin x",
    raw"\text{text with words} \leq \geq \neq \approx \partial \nabla \infty",
]
fingerprint(boxes) = sort!([string(b.element, b.x, b.y, b.scale) for b in boxes])
lay(style, expr) = fingerprint(TeXLayout.layout(TeXLayout.parse_latex(expr), FAMILY, style))
jobs = [(s, e) for s in (TeXLayout.Display, TeXLayout.Text) for e in EXPRS for _ in 1:8]
reference = Dict(job => lay(job...) for job in unique(jobs))
for trial in 1:5
    # Start each trial from cold caches so that cache population also races.
    empty!(TeXLayout._FONT_CACHE)
    empty!(TeXLayout._MATH_TABLE_CACHE)
    out = Vector{Any}(undef, length(jobs))
    @threads :dynamic for k in eachindex(jobs)
        out[k] = lay(jobs[k]...)
    end
    all(k -> out[k] == reference[jobs[k]], eachindex(jobs)) || exit(1)
end
"""

@testset "Concurrent layout from several threads matches serial layout" begin
    script = tempname() * ".jl"
    write(script, _THREAD_CHILD_SCRIPT)
    try
        project = something(Base.active_project(), dirname(@__DIR__))
        cmd = `$(Base.julia_cmd()) --startup-file=no --threads=4 --project=$project $script $FIXTURE_FONT_PATH`
        @test success(pipeline(cmd; stdout = devnull, stderr = devnull))
    finally
        rm(script; force = true)
    end
end
