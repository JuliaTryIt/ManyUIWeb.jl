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
    using DualUIWeb
    import DualUI

    @test DualUI.check_driver_interface(WebSocketDriver) == Symbol[]
    @test length(DualUI.REQUIRED_DRIVER_METHODS) == 9
end

@testitem "wsdriver: a fresh driver is open and detached" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    @test isopen(d)
    @test d.ws === nothing
    @test !d.connected
    @test DualUI.display_size(d) == DualUI.Size(80, 24)
    @test DualUI.capabilities(d).color_depth ===
          DualUI.ColorDepth.TRUECOLOR
    @test DualUI.events(d) isa Channel{DualUI.Event}
    DualUI.stop!(d)
    @test !isopen(d)
end

@testitem "wsdriver: start! honours the size_hint" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d, DualUI.Size(120, 40))
    @test DualUI.display_size(d) == DualUI.Size(120, 40)
    # Idempotent, and a nothing hint keeps the adopted size.
    DualUI.start!(d)
    @test DualUI.display_size(d) == DualUI.Size(120, 40)
    DualUI.stop!(d)
end

@testitem "wsdriver: emit flush pipes bytes verbatim" begin
    using DualUIWeb
    import DualUI
    import HTTP

    # A real WebSocket whose transport is an in-memory stream.
    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    d = WebSocketDriver()
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     100, 30, "", true)
    DualUI.start!(d)
    DualUIWeb.attach!(d, ws, hello)
    @test d.connected
    @test DualUI.display_size(d) == DualUI.Size(100, 30)

    # `attach!` asks the client for mouse/paste/focus and hides its
    # cursor before anything else goes out -- a terminal reports mouse
    # only when asked. Drain that frame so what follows is only what
    # `emit!` produced, and check it really reached the wire.
    @test timedwait(() -> bytesavailable(io) > 0, 10.0;
                    pollint = 0.001) === :ok
    setup = String(copy(readavailable(io)))
    @test occursin(DualUI.Ansi.MOUSE_ON, setup)
    @test occursin(DualUI.Ansi.CURSOR_HIDE, setup)

    ansi = UInt8[0x1b, 0x5b, 0x48, 0x41, 0x1b, 0x5b, 0x30, 0x6d]
    @test DualUI.emit!(d, ansi) == length(ansi)
    # emit! must NOT touch the socket; flush! is the commit point.
    @test bytesavailable(io) == 0

    DualUI.flush!(d)
    @test timedwait(() -> bytesavailable(io) >= length(ansi) + 2, 10.0;
                    pollint = 0.001) === :ok
    wire = readavailable(io)
    # 0x82 = FIN | binary opcode, then the length, then the payload
    # VERBATIM: the driver is a pipe, not a transformer.
    @test wire == vcat(UInt8[0x82, UInt8(length(ansi))], ansi)
    DualUI.stop!(d)
end

@testitem "wsdriver: flush! never blocks when detached" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    DualUI.emit!(d, UInt8[0x41, 0x42, 0x43])

    t = @async DualUI.flush!(d)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    @test fetch(t) === nothing

    # Detached => DISCARD. Safe because reattach forces a full repaint.
    @test Base.n_avail(d.outbox) == 0
    # The staging buffer is drained even so; a detached driver must not
    # grow without bound.
    @test position(d.outbuf) == 0
    DualUI.stop!(d)
end

@testitem "wsdriver: flush! discards when outbox is full" begin
    using DualUIWeb
    import DualUI
    import HTTP

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    d = WebSocketDriver(; outbox = 2)
    DualUI.start!(d)
    # Attach the socket WITHOUT the pump, so nothing drains the outbox.
    d.ws = ws
    d.connected = true
    put!(d.outbox, UInt8[0x01])
    put!(d.outbox, UInt8[0x02])
    @test Base.n_avail(d.outbox) == 2

    DualUI.emit!(d, UInt8[0x03])
    t = @async DualUI.flush!(d)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    # Dropped on the floor rather than wedging the app task.
    @test Base.n_avail(d.outbox) == 2
    DualUI.stop!(d)
end

@testitem "wsdriver: CSI split across frames parses" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    ch = DualUI.events(d)

    # A WebSocket frame boundary must not lose a CSI: ESC [ then A.
    @test DualUI.feed_bytes!(d, UInt8[0x1b, 0x5b]) == 0
    @test !isready(ch)
    @test DualUI.feed_bytes!(d, UInt8[0x41]) == 1

    e = take!(ch)
    @test e isa DualUI.KeyEvent
    @test e.code === DualUI.Key.UP
    DualUI.stop!(d)
end

@testitem "wsdriver: feed_bytes! injects plain keystrokes" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    ch = DualUI.events(d)
    @test DualUI.feed_bytes!(d, codeunits("hi")) == 2
    a = take!(ch)
    b = take!(ch)
    @test a.code === DualUI.Key.CHAR && a.char == 'h'
    @test b.code === DualUI.Key.CHAR && b.char == 'i'
    DualUI.stop!(d)
end

@testitem "wsdriver: attach resets the parser" begin
    using DualUIWeb
    import DualUI
    import HTTP

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    d = WebSocketDriver()
    DualUI.start!(d)
    # A half-parsed CSI stranded by the drop.
    DualUI.feed_bytes!(d, UInt8[0x1b, 0x5b])
    @test !isempty(d.parser)

    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    DualUIWeb.attach!(d, ws, hello)
    # Otherwise the first keystroke after reconnect is corrupted.
    @test isempty(d.parser)
    DualUI.stop!(d)
end

@testitem "wsdriver: detach! keeps the driver open" begin
    using DualUIWeb
    import DualUI
    import HTTP

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    d = WebSocketDriver()
    DualUI.start!(d)
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    DualUIWeb.attach!(d, ws, hello)
    @test d.connected

    DualUIWeb.detach!(d)
    @test !d.connected
    @test d.ws === nothing
    # X4: a drop is a PAUSE, not a death. The channel still lives, so no
    # app state is lost.
    @test isopen(d)
    @test isopen(DualUI.events(d))
    DualUI.stop!(d)
end

@testitem "wsdriver: attach adopts the HELLO color depth" begin
    using DualUIWeb
    import DualUI
    import HTTP

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    d = WebSocketDriver()
    DualUI.start!(d)
    # tc = false => X1 degradation is driven by the CLIENT's report.
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     90, 20, "", false)
    DualUIWeb.attach!(d, ws, hello)
    @test DualUI.capabilities(d).color_depth === DualUI.ColorDepth.ANSI256
    @test DualUI.display_size(d) == DualUI.Size(90, 20)
    DualUI.stop!(d)
end

@testitem "wsdriver: stop! is idempotent" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    DualUI.stop!(d)
    @test !isopen(d)
    @test !isopen(DualUI.events(d))
    DualUI.stop!(d)          # must not throw
    @test !isopen(d)
    # restore! is the crash path: idempotent, and never throws.
    @test DualUI.restore!(d) === nothing
    @test DualUI.restore!(d) === nothing
end

@testitem "wsdriver: resize control calls notify_resize!" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    ch = DualUI.events(d)

    # E4: the IDENTICAL seam SIGWINCH uses -- no web-specific path.
    DualUIWeb.handle_control!(d, "{\"t\":\"resize\",\"w\":100,\"h\":30}")
    @test DualUI.display_size(d) == DualUI.Size(100, 30)
    @test isready(ch)
    e = take!(ch)
    @test e isa DualUI.ResizeEvent
    @test e.size == DualUI.Size(100, 30)
    DualUI.stop!(d)
end

@testitem "wsdriver: handle_control! ignores garbage" begin
    using DualUIWeb
    import DualUI

    d = WebSocketDriver()
    DualUI.start!(d)
    before = DualUI.display_size(d)
    # A hostile client must not be able to crash a session.
    @test DualUIWeb.handle_control!(d, "not json at all") === nothing
    @test DualUIWeb.handle_control!(d, "{\"t\":\"nope\"}") === nothing
    @test DualUIWeb.handle_control!(d, "") === nothing
    @test DualUI.display_size(d) == before
    @test !isready(DualUI.events(d))
    DualUI.stop!(d)
end

@testitem "wsdriver: attach! asks the client for mouse and focus" begin
    using DualUIWeb
    import DualUI
    import HTTP

    # REGRESSION. `attach!` emitted nothing, so xterm.js was never told
    # to report mouse -- and a terminal reports mouse only when asked.
    # The browser therefore had NO mouse at all: click-to-sort, every
    # Button and all hit testing were dead on the web while working on a
    # tty. It lives in attach! and not start! because a RECONNECT calls
    # attach! alone.
    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)
    d = WebSocketDriver()
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     100, 30, "", true)
    DualUI.start!(d)
    DualUIWeb.attach!(d, ws, hello)

    caps = DualUI.capabilities(d)
    setup = String(copy(DualUIWeb._ws_setup_bytes(caps)))
    @test occursin(DualUI.Ansi.CURSOR_HIDE, setup)
    caps.mouse && @test occursin(DualUI.Ansi.MOUSE_ON, setup)
    caps.bracketed_paste && @test occursin(DualUI.Ansi.PASTE_ON, setup)
    caps.focus_events && @test occursin(DualUI.Ansi.FOCUS_ON, setup)

    # Teardown is the exact reverse, and restore! never throws.
    teardown = String(copy(DualUIWeb._ws_teardown_bytes(caps)))
    @test occursin(DualUI.Ansi.CURSOR_SHOW, teardown)
    caps.mouse && @test occursin(DualUI.Ansi.MOUSE_OFF, teardown)
    @test DualUI.restore!(d) === nothing
    @test DualUI.restore!(d) === nothing   # idempotent

    DualUI.stop!(d)
end
