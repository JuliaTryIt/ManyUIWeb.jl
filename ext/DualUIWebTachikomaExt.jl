# DualUIWebTachikomaExt -- the Tachikoma frontend.
#
# This is the second frontend for DualUIWeb's neutral transport, and the
# proof that "neutral" was real: it lives in another package's extension,
# defines one session type and one frontend type against the interface, and
# the unchanged server hosts a Tachikoma app in a browser.
#
# It reuses the transport whole -- the HTTP server, the xterm.js client
# bundle and the wire protocol are all DualUIWeb's; only the per-connection
# app instance is new. Both frameworks emit terminal bytes and xterm.js
# renders terminal bytes, so the wire never had to know the difference.
#
# CONSTRAINTS, and why. Tachikoma's terminal I/O is process-global -- input
# comes from a global `INPUT_IO`, and `app` captures the process's
# stdout/stderr -- so two Tachikoma apps cannot run in one process without
# fighting. Hence SINGLE-SESSION: `serve_tachikoma` forces
# `multi_session = false`. Lifting that is upstream work (a per-instance
# input source).
#
# Resize IS handled: `app`'s `on_terminal` hook hands us the Terminal, and
# a RESIZE control frame `resize!`s it live, so the app always renders at
# the size xterm.js is actually showing -- without it the client's
# post-font-load re-fit left every frame drifting.
module DualUIWebTachikomaExt

using DualUIWeb
import DualUIWeb: AbstractSession, AbstractFrontend, ServerConfig,
                  SessionState, ControlKind, session_id, session_attach!,
                  session_detach!, session_input!, session_control!,
                  session_state, session_touch!, session_expired,
                  session_terminate!, make_session, serve_tachikoma
import DualUI
import HTTP
import Tachikoma
const T = Tachikoma

# --------------------------------------------------------- the WS out sink

"""
An `IO` whose writes are shipped to the browser as binary WebSocket frames.

This is the whole output half of the bridge: Tachikoma writes ANSI to its
`Terminal`'s `io`, and that `io` is one of these, so every frame becomes a
binary frame on the wire with no copy through a terminal. `closed` is the
teardown lever -- once set, `write` throws, which is what unwinds `app`'s
render loop from the outside on a drop or a `stop!`.
"""
mutable struct WSOutIO <: IO
    ws::Any
    closed::Bool
    lock::ReentrantLock
end
WSOutIO() = WSOutIO(nothing, false, ReentrantLock())

function Base.write(io::WSOutIO, bytes::Vector{UInt8})
    lock(io.lock) do
        io.closed && error("WSOutIO is closed")   # unwinds app()'s loop
        w = io.ws
        w === nothing && return length(bytes)      # detached: drop, as a driver does
        try
            HTTP.WebSockets.send(w, bytes)
        catch
            # A dead socket is the reader loop's problem, not this write's.
        end
        return length(bytes)
    end
end
Base.write(io::WSOutIO, b::UInt8) = write(io, UInt8[b])
Base.unsafe_write(io::WSOutIO, p::Ptr{UInt8}, n::UInt) =
    (write(io, unsafe_wrap(Array, p, Int(n))); Int(n))
Base.flush(::WSOutIO) = nothing
Base.isopen(io::WSOutIO) = !io.closed

# ----------------------------------------------------------- the session

"""
One Tachikoma app instance behind the neutral session interface.

`session_input!` writes the client's bytes into `instream`, which is set as
Tachikoma's global `INPUT_IO` while the app runs; `session_attach!` starts
the app once and rebinds the socket on reconnect. Single-session, so there
is only ever one of these per server.
"""
mutable struct TachikomaSession <: AbstractSession
    id::String
    factory::Any
    out::WSOutIO
    instream::Base.BufferStream
    task::Union{Nothing,Task}
    state::SessionState.T
    last_seen::Float64
    w::Int
    h::Int
    "The running app's Terminal, captured via `on_terminal`, for resizes."
    terminal::Any
end

session_id(s::TachikomaSession) = s.id

function session_attach!(s::TachikomaSession, ws, hello)
    s.out.ws = ws
    if hello.width > 0 && hello.height > 0
        s.w, s.h = hello.width, hello.height
    end
    if s.state === SessionState.NEW
        model = s.factory()
        # Per-server input source. Global, hence single-session; set before
        # `app`, so `app` does not try to dup fd 0 (which is not a tty here).
        T.INPUT_IO[] = s.instream
        s.task = @async begin
            try
                # `on_terminal` hands us the Terminal so `session_control!`
                # can `resize!` it: the client re-fits after its font loads
                # and on every window change, and without this the app stays
                # frozen at the connect size while xterm.js grows -- every
                # line then drifts and the screen turns to noise.
                T.app(model; io = s.out,
                      tty_size = (rows = s.h, cols = s.w),
                      on_terminal = t -> (s.terminal = t))
            catch
                # A closed sink or dropped input ends the loop; that is the
                # teardown path, not a failure to report.
            finally
                T.INPUT_IO[] = nothing
            end
        end
    end
    s.state = SessionState.RUNNING
    s.last_seen = time()
    return nothing
end

# A drop does not kill the app: the sink detaches (writes become drops) and
# the app keeps running, so a reconnect rebinds and resumes. Single-session
# takeover reattaches the same running app to the new socket.
function session_detach!(s::TachikomaSession)
    s.out.ws = nothing
    s.state = SessionState.PAUSED
    s.last_seen = time()
    return nothing
end

function session_input!(s::TachikomaSession, bytes)
    write(s.instream, Vector{UInt8}(bytes))
    flush(s.instream)
    return length(bytes)
end

# RESIZE re-sizes the running app's Terminal, so the app re-lays-out to
# match what xterm.js is showing. Safe across tasks: Julia is cooperative,
# so this runs while the render loop is parked between frames, never
# mid-draw. A frame that arrives before the app has handed us its Terminal
# is dropped -- the client re-fits, so another will come. PING/PONG and
# HELLO are the transport's business, not the app's.
function session_control!(s::TachikomaSession, m::DualUIWeb.ControlMessage)
    if m.kind === DualUIWeb.ControlKind.RESIZE && m.width > 0 && m.height > 0
        s.w, s.h = m.width, m.height
        t = s.terminal
        t === nothing || resize!(t, (rows = m.height, cols = m.width))
    end
    return nothing
end

session_state(s::TachikomaSession) = s.state
session_touch!(s::TachikomaSession) = (s.last_seen = time(); nothing)
session_expired(s::TachikomaSession, timeout, now) =
    s.state === SessionState.PAUSED && (now - s.last_seen) >= timeout

function session_terminate!(s::TachikomaSession; deadline = 5.0)
    s.state = SessionState.DEAD
    lock(s.out.lock) do
        s.out.closed = true          # next app write throws -> loop unwinds
    end
    try; close(s.instream); catch; end
    t = s.task
    t === nothing || timedwait(() -> istaskdone(t), deadline; pollint = 0.01)
    s.task = nothing
    return nothing
end

Base.isopen(s::TachikomaSession) = s.state !== SessionState.DEAD

# ----------------------------------------------------------- the frontend

struct TachikomaFrontend <: AbstractFrontend
    factory::Any
end

make_session(fe::TachikomaFrontend, id, config) =
    TachikomaSession(id, fe.factory, WSOutIO(), Base.BufferStream(),
                     nothing, SessionState.NEW, 0.0,
                     config.default_size.width, config.default_size.height,
                     nothing)

# ------------------------------------------------------------ the entry

function serve_tachikoma(factory; host = DualUIWeb.Sockets.localhost,
                         port::Int = 8000, title::AbstractString = "Tachikoma",
                         default_size = DualUI.Size(80, 24), kwargs...)
    cfg = ServerConfig(; host = host, port = port, title = title,
                       default_size = default_size,
                       multi_session = false,   # process-global I/O: one app
                       kwargs...)
    server = DualUIWeb.WebServer(TachikomaFrontend(factory); config = cfg)
    return DualUI.start!(server)
end

end # module
