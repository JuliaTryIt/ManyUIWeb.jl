# snake.jl -- the classic game, in a browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/snake.jl
#
#   arrows    steer
#   space     pause
#   r         restart
#
# Keystrokes arrive over a WebSocket, go through the SAME input parser a
# tty uses, and reach this widget as ordinary KeyEvents. Nothing here
# knows a browser is involved.

using ManyUI
using ManyUIWeb

const HEAD = Style(; fg = rgb(0xbb, 0xf7, 0xd0), bold = true)
const BODY = Style(; fg = rgb(0x22, 0xc5, 0x5e))
const FOOD = Style(; fg = rgb(0xf8, 0x71, 0x71), bold = true)
const WALL = Style(; fg = rgb(0x33, 0x41, 0x55))
const OVER = Style(; fg = rgb(0xfb, 0xbf, 0x24), bold = true)

"""
The board. The snake is a `Vector` of cells, not a widget per segment.
"""
mutable struct Snake <: ManyUI.Widget
    node::WidgetNode
    body::Vector{Tuple{Int,Int}}   # (x, y), head first
    dir::Tuple{Int,Int}
    food::Tuple{Int,Int}
    w::Int
    h::Int
    score::Int
    dead::Bool
    paused::Bool
end

function Snake(w::Int = 40, h::Int = 16)
    s = Snake(WidgetNode(; id = :snake, type_name = :Snake,
                         focusable = true),
              Tuple{Int,Int}[], (1, 0), (1, 1), w, h, 0, false, true)
    restart!(s)
    return s
end

ManyUI.measure(::Snake, avail::Size) = avail

"""Put the food somewhere the snake is not."""
function place_food!(s::Snake)
    while true
        p = (rand(2:(s.w - 1)), rand(2:(s.h - 1)))
        p in s.body || (s.food = p; return nothing)
    end
end

function restart!(s::Snake)
    mid = (s.w ÷ 2, s.h ÷ 2)
    s.body = [mid, (mid[1] - 1, mid[2]), (mid[1] - 2, mid[2])]
    s.dir = (1, 0)
    s.score = 0
    s.dead = false
    s.paused = true          # wait for the player, do not run into a wall
    place_food!(s)
    mark!(s, Dirty.PAINT)
    return nothing
end

"""
One tick. Walls and self are fatal; food grows the snake.
"""
function step!(s::Snake)
    (s.dead || s.paused) && return nothing
    hx, hy = s.body[1]
    nx, ny = hx + s.dir[1], hy + s.dir[2]
    if nx <= 1 || nx >= s.w || ny <= 1 || ny >= s.h || (nx, ny) in s.body
        s.dead = true
        mark!(s, Dirty.PAINT)
        return nothing
    end
    pushfirst!(s.body, (nx, ny))
    if (nx, ny) == s.food
        s.score += 1
        place_food!(s)
    else
        pop!(s.body)
    end
    mark!(s, Dirty.PAINT)
    return nothing
end

function ManyUI.render!(s::Snake, buf::AbstractMatrix{Cell})
    width, height = size(buf)
    (width < 4 || height < 4) && return nothing
    w = min(s.w, width)
    h = min(s.h, height - 1)
    # Walls.
    for x in 1:w
        set_cell!(buf, x, 1, Cell("─", WALL))
        set_cell!(buf, x, h, Cell("─", WALL))
    end
    for y in 1:h
        set_cell!(buf, 1, y, Cell("│", WALL))
        set_cell!(buf, w, y, Cell("│", WALL))
    end
    # Food, then the snake over it.
    fx, fy = s.food
    (1 <= fx <= w && 1 <= fy <= h) && set_cell!(buf, fx, fy, Cell("●", FOOD))
    for (i, (x, y)) in enumerate(s.body)
        (1 <= x <= w && 1 <= y <= h) || continue
        set_cell!(buf, x, y, Cell(i == 1 ? "█" : "▓", i == 1 ? HEAD : BODY))
    end
    # A status line under the board.
    msg = s.dead ? "score $(s.score)  --  DEAD, r to restart" :
          s.paused ? "score $(s.score)  --  SPACE to start, arrows steer" :
          "score $(s.score)  --  arrows steer, space pauses"
    height > h && write_text!(buf, 1, h + 1, msg, s.dead ? OVER : WALL)
    return nothing
end

function ManyUI.on_event!(s::Snake, d::Dispatch{KeyEvent})
    e = event(d)
    moved = true
    # A snake cannot reverse into itself.
    if e.code === Key.UP && s.dir != (0, 1)
        s.dir = (0, -1)
    elseif e.code === Key.DOWN && s.dir != (0, -1)
        s.dir = (0, 1)
    elseif e.code === Key.LEFT && s.dir != (1, 0)
        s.dir = (-1, 0)
    elseif e.code === Key.RIGHT && s.dir != (-1, 0)
        s.dir = (1, 0)
    elseif e.code === Key.SPACE || (e.code === Key.CHAR && e.char == ' ')
        # BOTH forms: the parser emits Key.SPACE for 0x20, never
        # Key.CHAR(' '). Checking only the latter is a space bar that
        # does nothing -- which is exactly what shipped until this was
        # tried in a browser.
        s.paused = !s.paused
        mark!(s, Dirty.PAINT)
    elseif e.code === Key.CHAR && e.char == 'r'
        restart!(s)
    else
        moved = false
    end
    moved && consume!(d)
    return nothing
end

snake_app() = Snake(40, 16)

const SHEET = parse_css("""
    Snake { background: #0f172a; }
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
    server = serve(snake_app; port = port, stylesheet = SHEET,
                   title = "Snake")
    println("Snake running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        while true
            sleep(0.12)
            for s in sessions_of(server)
                r = s.app.root
                r isa Snake || continue
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
