# life.jl -- Conway's Game of Life, in a browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/life.jl
#
# then open http://127.0.0.1:8000/. Every browser tab gets its OWN
# board: the factory below runs once per client.
#
# The same widget runs on a terminal with
# `run!(App(LifeBoard(), TerminalDriver()))` -- the application does not
# know which one it is talking to.

using ManyUI
using ManyUIWeb

"""
A Game of Life board. The grid is DATA, not a widget per cell: a
120x40 board is one node, not 4800.
"""
mutable struct LifeBoard <: ManyUI.Widget
    node::WidgetNode
    grid::Matrix{Bool}
    generation::Int
end

function LifeBoard(w::Int = 80, h::Int = 24)
    LifeBoard(WidgetNode(; id = :life, type_name = :LifeBoard),
              rand(h, w) .< 0.25, 0)
end

# Take whatever room the layout gives us.
ManyUI.measure(::LifeBoard, avail::Size) = avail

"""
One generation, in place. Wraps at the edges, so gliders come back
around instead of dying at the wall.
"""
function step!(b::LifeBoard)
    g = b.grid
    h, w = size(g)
    nxt = similar(g)
    for i in 1:h, j in 1:w
        n = 0
        for di in -1:1, dj in -1:1
            (di == 0 && dj == 0) && continue
            ii = mod1(i + di, h)
            jj = mod1(j + dj, w)
            n += g[ii, jj]
        end
        nxt[i, j] = n == 3 || (g[i, j] && n == 2)
    end
    b.grid = nxt
    b.generation += 1
    mark!(b, Dirty.PAINT)   # repaint, not relayout: the box never moves
    return nothing
end

const ALIVE = Style(; fg = rgb(0x7d, 0xd3, 0xfc))
const HUD = Style(; fg = rgb(0x94, 0xa3, 0xb8))

function ManyUI.render!(b::LifeBoard, buf::AbstractMatrix{Cell})
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    h, w = size(b.grid)
    for y in 1:min(height - 1, h), x in 1:min(width, w)
        b.grid[y, x] && set_cell!(buf, x, y, Cell("█", ALIVE))
    end
    # A one-line HUD along the bottom.
    height >= 1 || return nothing
    live = count(b.grid)
    write_text!(buf, 1, height,
                "gen $(b.generation)   alive $(live)   q to quit",
                HUD)
    return nothing
end

# Space toggles the simulation; q quits. Keys reach the board because
# it is focusable and focused.
function ManyUI.on_event!(b::LifeBoard, d::Dispatch{KeyEvent})
    e = d.event
    if e.code === Key.CHAR && e.char == 'q'
        a = ManyUI.app(b)
        a === nothing || quit!(a)
        consume!(d)
    end
    return nothing
end

"""
A fresh board plus the timer that drives it. Called once per client.
"""
function life_app()
    board = LifeBoard(80, 24)
    node(board).focusable = true
    return board
end

const SHEET = parse_css("""
    LifeBoard { background: #0f172a; }
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
    server = serve(life_app; port = port, stylesheet = SHEET,
                   title = "Game of Life")
    # One timer per SESSION would be better; this drives every session's
    # board through the server's session list.
    println("Life running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        while true
            sleep(0.1)
            for s in sessions_of(server)
                r = s.app.root
                r isa LifeBoard || continue
                step!(r)
                tick!(s.app)
            end
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        ManyUI.stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
