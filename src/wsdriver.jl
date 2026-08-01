# wsdriver.jl -- W2. `WebSocketDriver <: ManyUITUI.Driver`: the nine
# methods, nothing more.
#
# Every method below is a public ManyUI generic. Nothing reaches into
# ManyUI internals, and `check_driver_interface(WebSocketDriver) ==
# Symbol[]` is a @testitem.

"""
A ManyUI driver whose target is a browser: ANSI bytes out over a
WebSocket, keystrokes back in through the SAME `ManyUITUI.InputParser` a
TTY uses.
"""
mutable struct WebSocketDriver <: ManyUITUI.Driver
    "The App's only input."
    const chan::Channel{ManyUITUI.Event}
    "Shared byte parser -- the terminal's parser, verbatim."
    const parser::ManyUITUI.InputParser
    "BACKPRESSURE ONLY. Never the pause mechanism."
    const outbox::Channel{Vector{UInt8}}
    "Staging buffer; `flush!` is the commit point."
    const outbuf::IOBuffer
    "Guards `ws` and the frame handover."
    const lock::ReentrantLock
    "The live socket, or `nothing` while detached."
    ws::Union{Nothing,HTTP.WebSockets.WebSocket}
    "Client-reported renderable area."
    size::ManyUITUI.Size
    "What the client claims to do."
    caps::ManyUITUI.DriverCaps
    "True while a socket is attached."
    connected::Bool
    "False once stopped."
    open::Bool
    "True between `start!` and `stop!`."
    started::Bool
    "The task draining `outbox` into the socket."
    pump::Union{Nothing,Task}
end

"""
A detached driver: no socket yet, but a live channel and parser.
"""
function WebSocketDriver(; size::ManyUITUI.Size = ManyUITUI.Size(80, 24),
                           depth::ManyUITUI.ColorDepth.T =
                               ManyUITUI.ColorDepth.TRUECOLOR,
                           buffer::Int = 256,
                           outbox::Int = 64)::WebSocketDriver
    buffer > 0 || throw(ArgumentError("buffer must be positive"))
    outbox > 0 || throw(ArgumentError("outbox must be positive"))
    # A browser terminal does everything a good TTY does, and unlike one
    # it always has a settable title.
    caps = ManyUITUI.DriverCaps(; color_depth = depth, title = true)
    return WebSocketDriver(Channel{ManyUITUI.Event}(buffer),
                           ManyUITUI.InputParser(),
                           Channel{Vector{UInt8}}(outbox),
                           IOBuffer(), ReentrantLock(), nothing, size,
                           caps, false, true, false, nothing)
end

"""
`caps` with `color_depth` replaced. `DriverCaps` is `isbits`, so this
rebuilds rather than mutates. Pure. Internal.
"""
_with_depth(c::ManyUITUI.DriverCaps,
            depth::ManyUITUI.ColorDepth.T)::ManyUITUI.DriverCaps =
    ManyUITUI.DriverCaps(depth, c.mouse, c.bracketed_paste, c.focus_events,
                      c.alt_screen, c.title, c.unicode, c.sync_output)

"""
Offer `v` to `ch` WITHOUT ever blocking: `true` when it was accepted,
`false` when `ch` is full or closed.

The capacity test and the `put!` happen under the channel's own lock, so
a full channel can never wedge the caller. Internal.
"""
function _offer!(ch::Channel{Vector{UInt8}}, v::Vector{UInt8})::Bool
    lock(ch)
    try
        (isopen(ch) && length(ch.data) < ch.sz_max) || return false
        put!(ch, v)                  # re-entrant: the lock is held
        return true
    catch err
        err isa InvalidStateException || rethrow()
        return false
    finally
        unlock(ch)
    end
end

"""
Discard everything queued on `ch`. Never blocks. Internal.
"""
function _drain!(ch::Channel{Vector{UInt8}})::Nothing
    lock(ch)
    try
        while isopen(ch) && length(ch.data) > 0
            take!(ch)
        end
    catch err
        err isa InvalidStateException || rethrow()
    finally
        unlock(ch)
    end
    return nothing
end

"""
The modes this driver turns ON at `start!`, gated on `caps`, exactly as
`TerminalDriver` does.

xterm.js is a terminal, and a terminal reports mouse, paste and focus
only once the application ASKS for them. Without this, a click in the
browser produces nothing at all -- the client's own comment says it is
waiting ("xterm.js routes SGR (1006) mouse reports through onData once
the app enables tracking"), and nothing was ever enabling it. Internal.
"""
function _ws_setup_bytes(caps::ManyUITUI.DriverCaps)::Vector{UInt8}
    io = IOBuffer()
    write(io, ManyUITUI.Ansi.CURSOR_HIDE)
    caps.mouse && write(io, ManyUITUI.Ansi.MOUSE_ON)
    caps.bracketed_paste && write(io, ManyUITUI.Ansi.PASTE_ON)
    caps.focus_events && write(io, ManyUITUI.Ansi.FOCUS_ON)
    return take!(io)
end

"""
The exact reverse of `_ws_setup_bytes`, innermost first. Internal.
"""
function _ws_teardown_bytes(caps::ManyUITUI.DriverCaps)::Vector{UInt8}
    io = IOBuffer()
    caps.focus_events && write(io, ManyUITUI.Ansi.FOCUS_OFF)
    caps.bracketed_paste && write(io, ManyUITUI.Ansi.PASTE_OFF)
    caps.mouse && write(io, ManyUITUI.Ansi.MOUSE_OFF)
    write(io, ManyUITUI.Ansi.CURSOR_SHOW)
    return take!(io)
end

"""
Mark the driver started; adopt `size_hint` when given -- a HELLO
carries cols/rows, so the session never paints one wrong-size frame.
Idempotent.

Does NOT emit the setup sequences: `attach!` does, because a RECONNECT
calls `attach!` and never `start!`.
"""
function ManyUITUI.start!(d::WebSocketDriver,
                       size_hint::Union{Nothing,ManyUITUI.Size} =
                           nothing)::Nothing
    lock(d.lock) do
        size_hint === nothing || (d.size = size_hint)
        d.started = true
    end
    return nothing
end

"""
Stop the pump, close the channels, detach the socket. Idempotent.
"""
function ManyUITUI.stop!(d::WebSocketDriver)::Nothing
    d.open || return nothing
    detach!(d)
    isopen(d.outbox) && close(d.outbox)
    isopen(d.chan) && close(d.chan)
    d.open = false
    d.started = false
    ManyUITUI.restore!(d)
    return nothing
end

"""
X3. A no-op: a browser needs nothing undone. Idempotent, never throws.
"""
function ManyUITUI.restore!(d::WebSocketDriver)::Nothing
    # X3. Undo what `start!` turned on, so a client that outlives the
    # session is not left with mouse reporting on and no cursor. MUST
    # NOT throw: this runs inside a `catch`, inside a `finally`, and the
    # socket is usually already gone by the time it does -- a failure to
    # tidy up must never mask the error that caused it.
    try
        ManyUITUI.emit!(d, _ws_teardown_bytes(d.caps))
        ManyUITUI.flush!(d)
    catch
    end
    return nothing
end

"""
W3. Append `b` to `outbuf`; returns the bytes accepted. NEVER touches
the socket.
"""
ManyUITUI.emit!(d::WebSocketDriver, b::AbstractVector{UInt8})::Int =
    lock(() -> write(d.outbuf, b), d.lock)

"""
W3. Push one frame onto `outbox` and return. MUST NOT block: when
detached (`ws === nothing`) or when `outbox` is full, it DISCARDS.

Discarding is safe precisely because reattach posts a `RefreshEvent`,
forcing a full repaint. `outbox` is backpressure ONLY -- it is never
the pause mechanism. Pausing is `ManyUITUI.pause!(app)`, called explicitly
by `detach!`.

`outbuf` is drained even when the frame is dropped, so a detached
driver never grows without bound.
"""
function ManyUITUI.flush!(d::WebSocketDriver)::Nothing
    frame = lock(d.lock) do
        position(d.outbuf) == 0 && return nothing
        bytes = take!(d.outbuf)          # drains, attached or not
        return d.ws === nothing ? nothing : bytes
    end
    frame === nothing && return nothing
    _offer!(d.outbox, frame)             # full => dropped on the floor
    return nothing
end

"""
The client-reported renderable area.
"""
ManyUITUI.display_size(d::WebSocketDriver)::ManyUITUI.Size = d.size

"""
What the client claims to do.
"""
ManyUITUI.capabilities(d::WebSocketDriver)::ManyUITUI.DriverCaps = d.caps

"""
The event channel.
"""
ManyUITUI.events(d::WebSocketDriver)::Channel{ManyUITUI.Event} = d.chan

"""
True while the driver can still deliver events. Note that a DETACHED
driver is still open: a drop is a pause, not a death.
"""
Base.isopen(d::WebSocketDriver)::Bool = d.open

"""
Send an OSC 0 title sequence to the client.

It rides the ordinary byte pipe rather than the socket, so it is
ordered with respect to the frames around it.
"""
function ManyUITUI.set_title!(d::WebSocketDriver, s::AbstractString)::Nothing
    ManyUITUI.emit!(d, codeunits(string("\e]0;", s, "\a")))
    return nothing
end

"""
Attach a live socket: set `connected`, update `size` from HELLO, set
`caps.color_depth` from HELLO's `tc`, and spawn the pump.

Any previous socket and pump are retired first, and the outbox is
drained: a frame queued before the drop is a diff against a screen this
client never had, and the full repaint that follows makes it worthless
anyway.
"""
function attach!(d::WebSocketDriver, ws::HTTP.WebSockets.WebSocket,
                 hello::ControlMessage)::Nothing
    detach!(d)
    _drain!(d.outbox)
    # A half-parsed CSI from before the drop would corrupt the first
    # keystroke after reconnect.
    empty!(d.parser)
    lock(d.lock) do
        d.ws = ws
        d.connected = true
        if hello.width > 0 && hello.height > 0
            d.size = ManyUITUI.Size(hello.width, hello.height)
        end
        depth = hello.truecolor ? ManyUITUI.ColorDepth.TRUECOLOR :
                                  ManyUITUI.ColorDepth.ANSI256
        d.caps = _with_depth(d.caps, depth)
        # Publish the task BEFORE it runs: the pump's first act is to
        # take this same lock, so it cannot observe a stale `d.pump`.
        t = Task(() -> _pump_loop!(d))
        d.pump = t
        schedule(t)
    end
    # Ask the client for mouse, paste and focus, and hide its cursor --
    # the same things `TerminalDriver.start!` asks a tty for. HERE and
    # not in `start!`: a reconnect calls `attach!` alone, so setup done
    # at start! would be lost on every reconnection and a resumed
    # session would come back with no mouse.
    ManyUITUI.emit!(d, _ws_setup_bytes(d.caps))
    ManyUITUI.flush!(d)
    return nothing
end

"""
X4. Detach the socket and stop the pump. Discards NO app state.
"""
function detach!(d::WebSocketDriver)::Nothing
    lock(d.lock) do
        d.ws = nothing
        d.connected = false
        # Orphan the pump by identity rather than by waiting on it: a
        # late wakeup sees `d.pump !== current_task()` and exits without
        # touching the next socket. No wait, so no way to hang.
        d.pump = nothing
    end
    _offer!(d.outbox, UInt8[])   # wake a pump parked in `take!`
    return nothing
end

# NOTE (contract deviation, reported): `feed_bytes!` is exported by
# ManyUI (headless.jl), so this MUST extend the ManyUI generic -- yet
# `:feed_bytes!` is absent from the bridge surface tuple in driver.jl,
# which the "uses only the web bridge surface" guard test checks. The
# tuple is the thing that needs the fix (`:set_title!` is missing from
# it too, for the same reason); see the report.
"""
W4. A binary frame becomes
`ManyUITUI.pump_input!(d.parser, d.chan, bytes)` -- the SAME parser the
terminal uses. This one call IS the entire "web input" implementation.
"""
ManyUITUI.feed_bytes!(d::WebSocketDriver, b::AbstractVector{UInt8})::Int =
    ManyUITUI.pump_input!(d.parser, d.chan, b)

"""
Handle a text frame from its JSON: `decode_control`, then act. Invalid
JSON is ignored, never thrown.

This is the string entry point; the transport decodes once and calls the
[`ControlMessage`](@ref) method directly, so a frontend never re-parses.
Kept because tests and any caller holding raw wire text still want it.
"""
handle_control!(d::WebSocketDriver, json::AbstractString)::Nothing =
    let m = decode_control(json)
        m === nothing ? nothing : handle_control!(d, m)
    end

"""
Act on an already-decoded control frame.

    RESIZE -> `d.size = Size(w, h)`; `ManyUITUI.notify_resize!(d, sz)` --
              the IDENTICAL seam SIGWINCH uses, so E4 needs no
              web-specific code
    HELLO  -> size and depth update
    PING   -> reply PONG
    else   -> ignore
"""
function handle_control!(d::WebSocketDriver,
                         m::ControlMessage)::Nothing
    if m.kind === ControlKind.RESIZE
        (m.width > 0 && m.height > 0) || return nothing
        sz = ManyUITUI.Size(m.width, m.height)
        lock(d.lock) do
            d.size = sz
        end
        ManyUITUI.notify_resize!(d, sz)
    elseif m.kind === ControlKind.HELLO
        lock(d.lock) do
            if m.width > 0 && m.height > 0
                d.size = ManyUITUI.Size(m.width, m.height)
            end
            depth = m.truecolor ? ManyUITUI.ColorDepth.TRUECOLOR :
                                  ManyUITUI.ColorDepth.ANSI256
            d.caps = _with_depth(d.caps, depth)
        end
    elseif m.kind === ControlKind.PING
        _send_control(d, ControlMessage(ControlKind.PONG))
    end
    return nothing
end

"""
Send `m` as a JSON text frame, if a socket is attached. A dead socket is
not this function's problem: the reader loop's `finally` detaches.
Internal.
"""
function _send_control(d::WebSocketDriver, m::ControlMessage)::Nothing
    ws = lock(() -> d.ws, d.lock)
    ws === nothing && return nothing
    try
        HTTP.WebSockets.send(ws, encode_control(m))
    catch
        # The drop is detected by the reader, which detaches.
    end
    return nothing
end

"""
Drain `outbox` into the socket: a straight pipe, ANSI bytes in, ANSI
bytes out, no transformation.

The loop owns its slot by identity (`d.pump === current_task()`), so a
pump retired by `detach!` exits at the next checkpoint and can never
write to the socket that replaced it.
"""
function _pump_loop!(d::WebSocketDriver)::Nothing
    me = current_task()
    while true
        ok = lock(d.lock) do
            d.pump === me && d.connected && d.ws !== nothing
        end
        ok || break
        isopen(d.outbox) || break
        local frame::Vector{UInt8}
        try
            frame = take!(d.outbox)
        catch err
            err isa InvalidStateException || rethrow()
            break
        end
        ws = lock(d.lock) do
            (d.pump === me && d.connected) ? d.ws : nothing
        end
        ws === nothing && break
        isempty(frame) && continue       # the detach! wakeup sentinel
        try
            HTTP.WebSockets.send(ws, frame)
        catch
            break                        # socket died; `detach!` follows
        end
    end
    return nothing
end
