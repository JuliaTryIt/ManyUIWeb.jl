# tachikoma_web.jl -- a Tachikoma app in the browser, over DualUIWeb.
#
# Runs a Tachikoma Model/view/update app through DualUIWeb's WebSocket
# transport: xterm.js in the browser renders the exact ANSI a terminal
# would, and keystrokes travel back over the socket.
#
#     julia --project=. examples/tachikoma_web.jl
#     # open http://127.0.0.1:8000  -- press 'a', watch the count rise
#
# REQUIREMENTS. This needs a Tachikoma that accepts an `io=` sink
# (with_terminal/app) -- Tachikoma PR #39, unmerged at time of writing. Dev
# a patched Tachikoma into this environment first:
#
#     pkg> dev /path/to/patched/Tachikoma.jl
#
# CONSTRAINTS, both from Tachikoma's process-global terminal I/O:
#   - SINGLE-SESSION: one browser at a time (input and stdout capture are
#     process-wide). serve_tachikoma forces multi_session = false.
#   - Resize IS handled live: the app tracks the browser window's size.

using DualUIWeb
using DualUI: wait, stop!
using Tachikoma
const T = Tachikoma

@kwdef mutable struct Counter <: T.Model
    n::Int = 0
end

T.should_quit(m::Counter) = false

function T.update!(m::Counter, e::T.KeyEvent)
    e.char == 'a' && (m.n += 1)
    e.key == :escape && exit()
end

function T.view(m::Counter, f::T.Frame)
    T.render(Block(title = " press 'a' -- count = $(m.n) "), f.area, f.buffer)
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve_tachikoma(() -> Counter(); port = port)
    println("Tachikoma in the browser at ", DualUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
