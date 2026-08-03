# web_driver_tests.jl -- W2/W3/W4. The WebSocket driver.
#
# No test here touches the network. `_mock_ws` builds a REAL
# `HTTP.WebSockets.WebSocket` over an in-memory `Base.BufferStream`, so
# the driver is exercised through the genuine `WebSockets.send` framing
# path while the "wire" stays a byte buffer this process owns.
#
# Every wait is bounded by `timedwait`, so a regression fails the suite
# instead of hanging it.

@testitem "wsdriver: conforms to the driver interface" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    @test ManyUITUI.check_driver_interface(WebSocketDriver) == Symbol[]
    @test length(ManyUITUI.REQUIRED_DRIVER_METHODS) == 9
end

@testitem "wsdriver: a fresh driver is open and detached" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    @test isopen(d)
    @test d.ws === nothing
    @test !d.connected
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(80, 24)
    @test ManyUITUI.capabilities(d).color_depth ===
          ManyUITUI.ColorDepth.TRUECOLOR
    @test ManyUITUI.events(d) isa Channel{ManyUI.Event}
    ManyUITUI.stop!(d)
    @test !isopen(d)
end

@testitem "wsdriver: start! honours the size_hint" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d, ManyUITUI.Size(120, 40))
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(120, 40)
    # Idempotent, and a nothing hint keeps the adopted size.
    ManyUITUI.start!(d)
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(120, 40)
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: emit flush pipes bytes verbatim" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    # A real WebSocket whose transport is an in-memory stream.
    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)

    d = WebSocketDriver()
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     100, 30, "", true)
    ManyUITUI.start!(d)
    ManyUIWeb.attach!(d, ws, hello)
    @test d.connected
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(100, 30)

    # `attach!` asks the client for mouse/paste/focus and hides its
    # cursor before anything else goes out -- a terminal reports mouse
    # only when asked. Drain that frame so what follows is only what
    # `emit!` produced, and check it really reached the wire.
    @test timedwait(() -> bytesavailable(io) > 0, 10.0;
                    pollint = 0.001) === :ok
    setup = String(copy(readavailable(io)))
    @test occursin(ManyUITUI.Ansi.MOUSE_ON, setup)
    @test occursin(ManyUITUI.Ansi.CURSOR_HIDE, setup)

    ansi = UInt8[0x1b, 0x5b, 0x48, 0x41, 0x1b, 0x5b, 0x30, 0x6d]
    @test ManyUITUI.emit!(d, ansi) == length(ansi)
    # emit! must NOT touch the socket; flush! is the commit point.
    @test bytesavailable(io) == 0

    ManyUITUI.flush!(d)
    @test timedwait(() -> bytesavailable(io) >= length(ansi) + 2, 10.0;
                    pollint = 0.001) === :ok
    wire = readavailable(io)
    # 0x82 = FIN | binary opcode, then the length, then the payload
    # VERBATIM: the driver is a pipe, not a transformer.
    @test wire == vcat(UInt8[0x82, UInt8(length(ansi))], ansi)
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: flush! never blocks when detached" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    ManyUITUI.emit!(d, UInt8[0x41, 0x42, 0x43])

    t = @async ManyUITUI.flush!(d)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    @test fetch(t) === nothing

    # Detached => DISCARD. Safe because reattach forces a full repaint.
    @test Base.n_avail(d.outbox) == 0
    # The staging buffer is drained even so; a detached driver must not
    # grow without bound.
    @test position(d.outbuf) == 0
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: flush! discards when outbox is full" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)

    d = WebSocketDriver(; outbox = 2)
    ManyUITUI.start!(d)
    # Attach the socket WITHOUT the pump, so nothing drains the outbox.
    d.ws = ws
    d.connected = true
    put!(d.outbox, UInt8[0x01])
    put!(d.outbox, UInt8[0x02])
    @test Base.n_avail(d.outbox) == 2

    ManyUITUI.emit!(d, UInt8[0x03])
    t = @async ManyUITUI.flush!(d)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    # Dropped on the floor rather than wedging the app task.
    @test Base.n_avail(d.outbox) == 2
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: CSI split across frames parses" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    ch = ManyUITUI.events(d)

    # A WebSocket frame boundary must not lose a CSI: ESC [ then A.
    @test ManyUITUI.feed_bytes!(d, UInt8[0x1b, 0x5b]) == 0
    @test !isready(ch)
    @test ManyUITUI.feed_bytes!(d, UInt8[0x41]) == 1

    e = take!(ch)
    @test e isa ManyUI.KeyEvent
    @test e.code === ManyUI.Key.UP
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: feed_bytes! injects plain keystrokes" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    ch = ManyUITUI.events(d)
    @test ManyUITUI.feed_bytes!(d, codeunits("hi")) == 2
    a = take!(ch)
    b = take!(ch)
    @test a.code === ManyUI.Key.CHAR && a.char == 'h'
    @test b.code === ManyUI.Key.CHAR && b.char == 'i'
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: attach resets the parser" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    # A half-parsed CSI stranded by the drop.
    ManyUITUI.feed_bytes!(d, UInt8[0x1b, 0x5b])
    @test !isempty(d.parser)

    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    ManyUIWeb.attach!(d, ws, hello)
    # Otherwise the first keystroke after reconnect is corrupted.
    @test isempty(d.parser)
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: detach! keeps the driver open" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    ManyUIWeb.attach!(d, ws, hello)
    @test d.connected

    ManyUIWeb.detach!(d)
    @test !d.connected
    @test d.ws === nothing
    # X4: a drop is a PAUSE, not a death. The channel still lives, so no
    # app state is lost.
    @test isopen(d)
    @test isopen(ManyUITUI.events(d))
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: attach adopts the HELLO color depth" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    # tc = false => X1 degradation is driven by the CLIENT's report.
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     90, 20, "", false)
    ManyUIWeb.attach!(d, ws, hello)
    @test ManyUITUI.capabilities(d).color_depth === ManyUITUI.ColorDepth.ANSI256
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(90, 20)
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: stop! is idempotent" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    ManyUITUI.stop!(d)
    @test !isopen(d)
    @test !isopen(ManyUITUI.events(d))
    ManyUITUI.stop!(d)          # must not throw
    @test !isopen(d)
    # restore! is the crash path: idempotent, and never throws.
    @test ManyUITUI.restore!(d) === nothing
    @test ManyUITUI.restore!(d) === nothing
end

@testitem "wsdriver: resize control calls notify_resize!" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    ch = ManyUITUI.events(d)

    # E4: the IDENTICAL seam SIGWINCH uses -- no web-specific path.
    ManyUIWeb.handle_control!(d, "{\"t\":\"resize\",\"w\":100,\"h\":30}")
    @test ManyUITUI.display_size(d) == ManyUITUI.Size(100, 30)
    @test isready(ch)
    e = take!(ch)
    @test e isa ManyUI.ResizeEvent
    @test e.size == ManyUITUI.Size(100, 30)
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: handle_control! ignores garbage" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    d = WebSocketDriver()
    ManyUITUI.start!(d)
    before = ManyUITUI.display_size(d)
    # A hostile client must not be able to crash a session.
    @test ManyUIWeb.handle_control!(d, "not json at all") === nothing
    @test ManyUIWeb.handle_control!(d, "{\"t\":\"nope\"}") === nothing
    @test ManyUIWeb.handle_control!(d, "") === nothing
    @test ManyUITUI.display_size(d) == before
    @test !isready(ManyUITUI.events(d))
    ManyUITUI.stop!(d)
end

@testitem "wsdriver: attach! asks the client for mouse and focus" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import HTTP

    # REGRESSION. `attach!` emitted nothing, so xterm.js was never told
    # to report mouse -- and a terminal reports mouse only when asked.
    # The browser therefore had NO mouse at all: click-to-sort, every
    # Button and all hit testing were dead on the web while working on a
    # tty. It lives in attach! and not start! because a RECONNECT calls
    # attach! alone.
    io = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client = false)
    d = WebSocketDriver()
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     100, 30, "", true)
    ManyUITUI.start!(d)
    ManyUIWeb.attach!(d, ws, hello)

    caps = ManyUITUI.capabilities(d)
    setup = String(copy(ManyUIWeb._ws_setup_bytes(caps)))
    @test occursin(ManyUITUI.Ansi.CURSOR_HIDE, setup)
    caps.mouse && @test occursin(ManyUITUI.Ansi.MOUSE_ON, setup)
    caps.bracketed_paste && @test occursin(ManyUITUI.Ansi.PASTE_ON, setup)
    caps.focus_events && @test occursin(ManyUITUI.Ansi.FOCUS_ON, setup)

    # Teardown is the exact reverse, and restore! never throws.
    teardown = String(copy(ManyUIWeb._ws_teardown_bytes(caps)))
    @test occursin(ManyUITUI.Ansi.CURSOR_SHOW, teardown)
    caps.mouse && @test occursin(ManyUITUI.Ansi.MOUSE_OFF, teardown)
    @test ManyUITUI.restore!(d) === nothing
    @test ManyUITUI.restore!(d) === nothing   # idempotent

    ManyUITUI.stop!(d)
end
