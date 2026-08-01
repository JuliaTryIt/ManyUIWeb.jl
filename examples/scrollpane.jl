# scrollpane.jl -- a live log with auto-follow, in a browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/scrollpane.jl
#
#   the wheel / arrows / pageup / pagedown   scroll
#   f                                        toggle auto-follow
#
# Auto-follow is the interesting bit: while you are at the bottom, new
# lines pull the view down; scroll up and it lets go, so reading is not
# yanked out from under you. That is one call to `scroll_to!`, decided
# by comparing the offset against `max_scroll`.

using ManyUI, ManyUITUI
using ManyUIWeb

const LEVELS = [("INFO", rgb(0x7d, 0xd3, 0xfc)),
                ("WARN", rgb(0xfb, 0xbf, 0x24)),
                ("ERROR", rgb(0xf8, 0x71, 0x71)),
                ("DEBUG", rgb(0x94, 0xa3, 0xb8))]

const SOURCES = ["session", "driver", "layout", "paint", "input",
                 "diff", "server"]

const MESSAGES = [
    "client connected", "frame emitted in 1.2ms", "resize 120x40",
    "websocket ping", "session paused", "session resumed",
    "reap sweep: 0 expired", "stylesheet recascaded",
    "buffer resized", "input parser flushed", "cursor moved",
]

"""
A log line: a level, a source and a message. Lines are DATA in a
`List`, so a hundred thousand of them cost one node.
"""
mutable struct LogView <: ManyUI.Widget
    node::WidgetNode
    lines::Vector{String}
    follow::Bool
    seq::Int
end

LogView() = LogView(WidgetNode(; id = :log, type_name = :LogView,
                               focusable = true), String[], true, 0)

ManyUI.measure(::LogView, avail::Size) = avail

ManyUI.content_extent(w::LogView) =
    Size(maximum(text_width, w.lines; init = 0), length(w.lines))

"""
Append a line, without touching the view.

Separate from `emit!` on purpose: `max_scroll` is measured against the
CONTENT BOX, which is empty until layout has run, so pinning before the
first layout stores an offset that is later out of range -- and a view
scrolled past its own last line renders nothing at all.
"""
function add_line!(w::LogView)
    w.seq += 1
    (lvl, _) = LEVELS[rand(1:length(LEVELS))]
    push!(w.lines,
          string(lpad(w.seq, 5), "  ", rpad(lvl, 5), " ",
                 rpad(SOURCES[rand(1:length(SOURCES))], 8), " ",
                 MESSAGES[rand(1:length(MESSAGES))]))
    length(w.lines) > 5000 && popfirst!(w.lines)
    mark!(w, Dirty.PAINT)
    return nothing
end

"""
Append a line and, while following, stay pinned to the bottom. Otherwise
leave the view exactly where the reader put it.
"""
function emit!(w::LogView)
    add_line!(w)
    w.follow && scroll_to!(w, max_scroll(w))
    return nothing
end

function ManyUITUI.render!(w::LogView, buf::AbstractMatrix{Cell})
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    off = scroll_of(w)
    n = length(w.lines)
    for row in 1:height
        li = off.y + row
        (1 <= li <= n) || break
        line = w.lines[li]
        # Colour by level, which sits at a known offset in the line.
        st = STYLE_NONE
        for (name, col) in LEVELS
            if occursin(name, line)
                st = Style(; fg = col)
                break
            end
        end
        write_text!(buf, 1 - off.x, row, line, st)
    end
    return nothing
end

function ManyUI.on_event!(w::LogView, d::Dispatch{KeyEvent})
    e = event(d)
    if e.code === Key.CHAR && e.char == 'f'
        w.follow = !w.follow
        w.follow && scroll_to!(w, max_scroll(w))
        mark!(w, Dirty.PAINT)
        consume!(d)
    end
    return nothing
end

# Scrolling away from the bottom by hand drops auto-follow; scrolling
# back to the bottom picks it up again.
function ManyUI.on_event!(w::LogView, d::Dispatch{MouseEvent})
    e = event(d)
    is_scroll(e) || return nothing
    dy = e.button === MouseButton.WHEEL_UP ? -3 : 3
    scroll_by!(w, Offset(0, dy))
    w.follow = scroll_of(w).y >= max_scroll(w).y
    mark!(w, Dirty.PAINT)
    consume!(d)
    return nothing
end

const SHEET = parse_css("""
    #screen { layout: column; }
    #title  { color: #7dd3fc; shrink: 0; }
    #log    { grow: 1; }
""")

function log_app()
    lv = LogView()
    for _ in 1:200
        add_line!(lv)   # no pinning before layout
    end
    return Container(
        Label("live log  --  wheel/arrows scroll, f toggles follow";
              id = :title),
        lv;
        id = :screen,
    )
end

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
    server = serve(log_app; port = port, stylesheet = SHEET,
                   title = "Live log")
    println("Log running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        while true
            sleep(0.25)
            for s in sessions_of(server)
                lv = query_one(s.app.root, "#log")
                lv isa LogView || continue
                emit!(lv)
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
