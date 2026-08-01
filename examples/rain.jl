# rain.jl -- Matrix rain, in a browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/rain.jl
#
# Falling halfwidth katakana and latin with brightness falloff. Pure
# character-buffer animation: no widgets below the top one, no layout
# per frame -- just cells.
#
# The diff earns its keep here. Only the cells that changed are sent, so
# a mostly-still screen costs almost nothing even at 20 frames a second.

using ManyUI, ManyUITUI
using ManyUIWeb

# Halfwidth katakana: one cell each, unlike their fullwidth cousins.
const GLYPHS = vcat(collect('ｦ':'ﾝ'), collect('A':'Z'),
                    collect('0':'9'))

# Head to tail, brightest first.
const TRAIL = [
    Style(; fg = rgb(0xd9, 0xff, 0xd9), bold = true),
    Style(; fg = rgb(0x4a, 0xde, 0x80)),
    Style(; fg = rgb(0x22, 0xc5, 0x5e)),
    Style(; fg = rgb(0x16, 0xa3, 0x4a)),
    Style(; fg = rgb(0x14, 0x53, 0x2d)),
]

"""
One falling column: where its head is, how fast, and how long its tail.
"""
mutable struct Drop
    y::Int
    speed::Int
    len::Int
    tick::Int
end

Drop(h::Int) = Drop(rand(-h:0), rand(1:2), rand(4:12), 0)

"""
The rain. Columns are DATA -- a `Vector{Drop}` -- not one widget each.
"""
mutable struct Rain <: ManyUI.Widget
    node::WidgetNode
    drops::Vector{Drop}
    height::Int
end

Rain() = Rain(WidgetNode(; id = :rain, type_name = :Rain), Drop[], 24)

ManyUI.measure(::Rain, avail::Size) = avail

"""
Grow or shrink the column set to fit `sz`. Called on resize; a drop per
column, no more.
"""
function fit!(r::Rain, sz::Size)
    r.height = max(1, sz.height)
    n = max(0, sz.width)
    while length(r.drops) < n
        push!(r.drops, Drop(r.height))
    end
    length(r.drops) > n && resize!(r.drops, n)
    return nothing
end

"""
One frame. Each drop falls at its own speed and restarts above the top
once its tail has cleared the bottom.
"""
function step!(r::Rain)
    for d in r.drops
        d.tick += 1
        if d.tick >= d.speed
            d.tick = 0
            d.y += 1
            if d.y - d.len > r.height
                d.y = rand(-8:0)
                d.speed = rand(1:2)
                d.len = rand(4:12)
            end
        end
    end
    mark!(r, Dirty.PAINT)   # cells change; the box never does
    return nothing
end

function ManyUITUI.render!(r::Rain, buf::AbstractMatrix{Cell})
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    for (x, d) in enumerate(r.drops)
        x > width && break
        for k in 0:(d.len - 1)
            y = d.y - k
            (1 <= y <= height) || continue
            # Brightness falls off along the tail.
            si = 1 + (k * length(TRAIL)) ÷ max(1, d.len)
            st = TRAIL[clamp(si, 1, length(TRAIL))]
            set_cell!(buf, x, y, Cell(string(rand(GLYPHS)), st))
        end
    end
    return nothing
end

# The rain refits itself whenever the window changes.
function ManyUI.on_event!(r::Rain, d::Dispatch{ResizeEvent})
    fit!(r, event(d).size)
    return nothing
end

rain_app() = Rain()

const SHEET = parse_css("""
    Rain { background: #000000; }
""")

"""
A snapshot of the live sessions, taken under the server's lock.

The `sessions` Dict is guarded: iterating it live races a client
connecting or dropping, which throws mid-frame. Copy, then iterate.
"""
sessions_of(server) =
    Base.@lock server.lock collect(values(server.sessions))

"""
Wake `app`'s event loop so it paints.

`invalidate!` is INTERNAL: it marks state dirty but does not wake the
loop, which is blocked on `take!` of its event channel -- so calling it
from out here marks a board dirty that nothing ever repaints. The
channel is the only way in. A `TickEvent` wakes the loop and lets the
diff do its job; a `RefreshEvent` would too, but forces a FULL repaint
every frame and throws the diff away.
"""
tick!(app) = post!(app, TickEvent(time()))

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve(rain_app; port = port, stylesheet = SHEET,
                   title = "Matrix rain")
    println("Rain running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        while true
            sleep(0.06)
            for s in sessions_of(server)
                r = s.app.root
                r isa Rain || continue
                isempty(r.drops) && fit!(r, buffer_size(s.app.back))
                step!(r)
                tick!(s.app)
            end
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        ManyUITUI.stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
