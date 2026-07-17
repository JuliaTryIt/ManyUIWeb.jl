# session_tests.jl -- W3/W5, X4, X5. The per-client session.
#
# The reap policy is tested through the PURE core `_is_expired`, so the
# whole of X5 is asserted with no clock, no socket and no server. The
# lifecycle tests inject a millisecond timeout, so the suite never
# sleeps for a timeout to elapse.

@testitem "session: is_expired pure predicate table" begin
    using DualUIWeb

    S = DualUIWeb.SessionState
    exp = DualUIWeb._is_expired

    # X5: only the elapsed idle time against the timeout decides.
    @test exp(S.PAUSED, 100.0, 300.0, 401.0) === true    # 301 > 300
    @test exp(S.PAUSED, 100.0, 300.0, 399.0) === false   # 299 < 300
    @test exp(S.PAUSED, 100.0, 300.0, 400.0) === true    # exactly at
    @test exp(S.PAUSED, 100.0, 0.0, 100.0) === true      # zero timeout
    @test exp(S.PAUSED, 100.0, 300.0, 100.0) === false   # no idle yet

    # The predicate is pure: same inputs, same answer, no clock read.
    @test exp(S.PAUSED, 100.0, 300.0, 401.0) ===
          exp(S.PAUSED, 100.0, 300.0, 401.0)
end

@testitem "session: only a PAUSED session can expire" begin
    using DualUIWeb

    S = DualUIWeb.SessionState
    exp = DualUIWeb._is_expired

    # A live session is never reaped, however long since last_seen --
    # that is what makes a long-running app safe.
    for st in (S.NEW, S.RUNNING, S.CLOSING, S.DEAD)
        @test exp(st, 100.0, 300.0, 10_000.0) === false
    end
    @test exp(S.PAUSED, 100.0, 300.0, 10_000.0) === true
end

@testitem "session: App is concrete over WebSocketDriver" begin
    using DualUIWeb
    import DualUI

    # The parametric App{D} decision paying off across a package
    # boundary: the per-session render loop is as type-stable over a
    # WebSocket as over a TTY.
    @test isconcretetype(DualUI.App{WebSocketDriver})
    @test fieldtype(DualUIWeb.Session, :app) ===
          DualUI.App{WebSocketDriver}
    @test fieldtype(DualUIWeb.Session, :driver) === WebSocketDriver
end

@testitem "session: factory yields an independent tree per session" begin
    using DualUIWeb
    import DualUI

    # W5's isolation primitive, asserted with no App and no socket.
    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    factory = () -> Counter()
    @test factory() !== factory()
    a = factory()
    b = factory()
    a.count = 7
    @test b.count == 0
end

@testitem "session: two sessions share no mutable state" begin
    using DualUIWeb
    import DualUI
    import Sockets

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s1 = DualUIWeb.Session("a"^32, () -> Counter(),
                           DualUI.STYLESHEET_EMPTY, cfg)
    s2 = DualUIWeb.Session("b"^32, () -> Counter(),
                           DualUI.STYLESHEET_EMPTY, cfg)

    # 2.4: an INDEPENDENT application state, event loop and virtual
    # component tree for each connected client.
    @test s1.app !== s2.app
    @test s1.driver !== s2.driver
    @test s1.app.root !== s2.app.root
    @test DualUI.events(s1.driver) !== DualUI.events(s2.driver)
    @test s1.app.front !== s2.app.front
    @test s1.app.back !== s2.app.back

    # Mutate one session's app state; the other is untouched.
    s1.app.root.count = 42
    DualUI.pause!(s1.app)
    @test s2.app.root.count == 0
    @test s2.app.paused === false

    DualUIWeb.terminate!(s1; deadline = 0.5)
    DualUIWeb.terminate!(s2; deadline = 0.5)
end

@testitem "session: detach pauses and preserves state" begin
    using DualUIWeb
    import DualUI
    import Sockets
    import HTTP

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("c"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.NEW

    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    DualUIWeb.attach!(s, ws, hello)
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.RUNNING

    root = s.app.root
    root.count = 5

    # X4: the socket drops unexpectedly.
    DualUIWeb.detach!(s)
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.PAUSED
    # The event loop is PAUSED, not killed...
    @test s.app.paused === true
    @test s.driver.ws === nothing
    @test !s.driver.connected
    # ...and the state is PRESERVED IN MEMORY, identically.
    @test s.app.root === root
    @test s.app.root.count == 5
    @test isopen(DualUI.events(s.driver))
    @test isopen(s)

    DualUIWeb.terminate!(s; deadline = 0.5)
end

@testitem "session: attach resumes and forces a full frame" begin
    using DualUIWeb
    import DualUI
    import Sockets
    import HTTP

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    mk_ws = function ()
        io = Base.BufferStream()
        conn = HTTP.Connections.Connection(io)
        return HTTP.WebSockets.WebSocket(conn, HTTP.Request(),
                                         HTTP.Response(); client = false)
    end

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("d"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    DualUIWeb.attach!(s, mk_ws(), hello)
    s.app.root.count = 9
    DualUIWeb.detach!(s)
    @test s.app.paused === true

    # A half-parsed CSI stranded by the drop.
    DualUI.feed_bytes!(s.driver, UInt8[0x1b, 0x5b])
    @test !isempty(s.driver.parser)

    # Reconnect within the timeout with a BRAND NEW socket.
    ws2 = mk_ws()
    DualUIWeb.attach!(s, ws2, hello)

    @test DualUIWeb.state(s) === DualUIWeb.SessionState.RUNNING
    @test s.app.paused === false
    @test s.driver.ws === ws2
    @test s.driver.connected
    # The reconnected client's screen is blank, so the diff baseline
    # must be reset: one full frame, no replay log.
    @test s.app.needs_full === true
    # Otherwise the first keystroke after reconnect is corrupted.
    @test isempty(s.driver.parser)
    # The app state survived the round trip.
    @test s.app.root.count == 9

    DualUIWeb.terminate!(s; deadline = 0.5)
end

@testitem "session: reap after the timeout expires" begin
    using DualUIWeb
    import DualUI
    import Sockets
    import HTTP

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    # A 50 ms timeout: the policy is injected, so the test is fast.
    timeout = 0.05
    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, timeout,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("e"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)
    hello = DualUIWeb.ControlMessage(DualUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    DualUIWeb.attach!(s, ws, hello)

    # A RUNNING session never expires, however stale last_seen looks.
    @test DualUIWeb.is_expired(s, timeout, s.last_seen + 1000.0) === false

    DualUIWeb.detach!(s)
    # Within the timeout: still reapable-by-nobody.
    @test DualUIWeb.is_expired(s, timeout, s.last_seen + 0.01) === false
    # Past it: the client failed to reconnect.
    @test DualUIWeb.is_expired(s, timeout, s.last_seen + 0.5) === true

    # X5: terminate gracefully and release the resources.
    DualUIWeb.terminate!(s; deadline = 1.0)
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.DEAD
    @test !isopen(s)
    @test !isopen(DualUI.events(s.driver))
    @test !isopen(s.driver)
    @test s.task === nothing
    # A DEAD session can never expire again -- reap! must not re-kill.
    @test DualUIWeb.is_expired(s, timeout, s.last_seen + 10_000.0) ===
          false
end

@testitem "session: terminate! is idempotent" begin
    using DualUIWeb
    import DualUI
    import Sockets

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("f"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)
    DualUIWeb.terminate!(s; deadline = 0.5)
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.DEAD
    DualUIWeb.terminate!(s; deadline = 0.5)   # must not throw
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.DEAD
end

@testitem "session: terminate! never wedges on a full channel" begin
    using DualUIWeb
    import DualUI
    import Sockets

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("9"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)

    # Fill the event channel to capacity. `post!` -- and so `quit!` --
    # BLOCKS on a full channel, so a naive terminate! would hang the
    # reaper here forever. X5 is the one path that must never wedge.
    ch = DualUI.events(s.driver)
    while Base.n_avail(ch) < ch.sz_max
        put!(ch, DualUI.RefreshEvent())
    end
    @test Base.n_avail(ch) == ch.sz_max

    t = @async DualUIWeb.terminate!(s; deadline = 0.5)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    @test DualUIWeb.state(s) === DualUIWeb.SessionState.DEAD
    @test !isopen(ch)
end

@testitem "session: age and idle are pure in now" begin
    using DualUIWeb
    import DualUI
    import Sockets

    mutable struct Counter <: DualUI.Widget
        node::DualUI.WidgetNode
        count::Int
    end
    Counter() = Counter(DualUI.WidgetNode(), 0)
    DualUI.node(w::Counter) = w.node

    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", DualUI.Size(80, 24),
                                 DualUI.Size(20, 5))
    s = DualUIWeb.Session("0"^32, () -> Counter(),
                          DualUI.STYLESHEET_EMPTY, cfg)
    @test DualUIWeb.age(s, s.created + 12.0) == 12.0
    @test DualUIWeb.idle(s, s.last_seen + 3.5) == 3.5
    DualUIWeb.terminate!(s; deadline = 0.5)
end
