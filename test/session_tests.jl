# session_tests.jl -- W3/W5, X4, X5. The per-client session.
#
# The reap policy is tested through the PURE core `_is_expired`, so the
# whole of X5 is asserted with no clock, no socket and no server. The
# lifecycle tests inject a millisecond timeout, so the suite never
# sleeps for a timeout to elapse.

@testitem "session: is_expired pure predicate table" begin
    using ManyUIWeb, ManyUITUI

    S = ManyUIWeb.SessionState
    exp = ManyUIWeb._is_expired

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
    using ManyUIWeb, ManyUITUI

    S = ManyUIWeb.SessionState
    exp = ManyUIWeb._is_expired

    # A live session is never reaped, however long since last_seen --
    # that is what makes a long-running app safe.
    for st in (S.NEW, S.RUNNING, S.CLOSING, S.DEAD)
        @test exp(st, 100.0, 300.0, 10_000.0) === false
    end
    @test exp(S.PAUSED, 100.0, 300.0, 10_000.0) === true
end

@testitem "session: App is concrete over WebSocketDriver" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    # The parametric App{D} decision paying off across a package
    # boundary: the per-session render loop is as type-stable over a
    # WebSocket as over a TTY.
    @test isconcretetype(ManyUITUI.App{WebSocketDriver})
    @test fieldtype(ManyUIWeb.Session, :app) ===
          ManyUITUI.App{WebSocketDriver}
    @test fieldtype(ManyUIWeb.Session, :driver) === WebSocketDriver
end

@testitem "session: factory yields an independent tree per session" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI

    # W5's isolation primitive, asserted with no App and no socket.
    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    factory = () -> Counter()
    @test factory() !== factory()
    a = factory()
    b = factory()
    a.count = 7
    @test b.count == 0
end

@testitem "session: two sessions share no mutable state" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s1 = ManyUIWeb.Session("a"^32, () -> Counter(),
                           ManyUITUI.STYLESHEET_EMPTY, cfg)
    s2 = ManyUIWeb.Session("b"^32, () -> Counter(),
                           ManyUITUI.STYLESHEET_EMPTY, cfg)

    # 2.4: an INDEPENDENT application state, event loop and virtual
    # component tree for each connected client.
    @test s1.app !== s2.app
    @test s1.driver !== s2.driver
    @test s1.app.root !== s2.app.root
    @test ManyUITUI.events(s1.driver) !== ManyUITUI.events(s2.driver)
    @test s1.app.front !== s2.app.front
    @test s1.app.back !== s2.app.back

    # Mutate one session's app state; the other is untouched.
    s1.app.root.count = 42
    ManyUITUI.pause!(s1.app)
    @test s2.app.root.count == 0
    @test s2.app.paused === false

    ManyUIWeb.terminate!(s1; deadline = 0.5)
    ManyUIWeb.terminate!(s2; deadline = 0.5)
end

@testitem "session: detach pauses and preserves state" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets
    import HTTP

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("c"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.NEW

    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    ManyUIWeb.attach!(s, ws, hello)
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.RUNNING

    root = s.app.root
    root.count = 5

    # X4: the socket drops unexpectedly.
    ManyUIWeb.detach!(s)
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.PAUSED
    # The event loop is PAUSED, not killed...
    @test s.app.paused === true
    @test s.driver.ws === nothing
    @test !s.driver.connected
    # ...and the state is PRESERVED IN MEMORY, identically.
    @test s.app.root === root
    @test s.app.root.count == 5
    @test isopen(ManyUITUI.events(s.driver))
    @test isopen(s)

    ManyUIWeb.terminate!(s; deadline = 0.5)
end

@testitem "session: attach resumes and forces a full frame" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets
    import HTTP

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    mk_ws = function ()
        io = Base.BufferStream()
        conn = HTTP.Connections.Connection(io)
        return HTTP.WebSockets.WebSocket(conn, HTTP.Request(),
                                         HTTP.Response(); client = false)
    end

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("d"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    ManyUIWeb.attach!(s, mk_ws(), hello)
    s.app.root.count = 9
    ManyUIWeb.detach!(s)
    @test s.app.paused === true

    # A half-parsed CSI stranded by the drop.
    ManyUITUI.feed_bytes!(s.driver, UInt8[0x1b, 0x5b])
    @test !isempty(s.driver.parser)

    # Reconnect within the timeout with a BRAND NEW socket.
    ws2 = mk_ws()
    ManyUIWeb.attach!(s, ws2, hello)

    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.RUNNING
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

    ManyUIWeb.terminate!(s; deadline = 0.5)
end

@testitem "session: reap after the timeout expires" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets
    import HTTP

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    io = Base.BufferStream()
    conn = HTTP.Connections.Connection(io)
    ws = HTTP.WebSockets.WebSocket(conn, HTTP.Request(), HTTP.Response();
                                   client = false)

    # A 50 ms timeout: the policy is injected, so the test is fast.
    timeout = 0.05
    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, timeout,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("e"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)
    hello = ManyUIWeb.ControlMessage(ManyUIWeb.ControlKind.HELLO,
                                     80, 24, "", true)
    ManyUIWeb.attach!(s, ws, hello)

    # A RUNNING session never expires, however stale last_seen looks.
    @test ManyUIWeb.is_expired(s, timeout, s.last_seen + 1000.0) === false

    ManyUIWeb.detach!(s)
    # Within the timeout: still reapable-by-nobody.
    @test ManyUIWeb.is_expired(s, timeout, s.last_seen + 0.01) === false
    # Past it: the client failed to reconnect.
    @test ManyUIWeb.is_expired(s, timeout, s.last_seen + 0.5) === true

    # X5: terminate gracefully and release the resources.
    ManyUIWeb.terminate!(s; deadline = 1.0)
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.DEAD
    @test !isopen(s)
    @test !isopen(ManyUITUI.events(s.driver))
    @test !isopen(s.driver)
    @test s.task === nothing
    # A DEAD session can never expire again -- reap! must not re-kill.
    @test ManyUIWeb.is_expired(s, timeout, s.last_seen + 10_000.0) ===
          false
end

@testitem "session: terminate! is idempotent" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("f"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)
    ManyUIWeb.terminate!(s; deadline = 0.5)
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.DEAD
    ManyUIWeb.terminate!(s; deadline = 0.5)   # must not throw
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.DEAD
end

@testitem "session: terminate! never wedges on a full channel" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("9"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)

    # Fill the event channel to capacity. `post!` -- and so `quit!` --
    # BLOCKS on a full channel, so a naive terminate! would hang the
    # reaper here forever. X5 is the one path that must never wedge.
    ch = ManyUITUI.events(s.driver)
    while Base.n_avail(ch) < ch.sz_max
        put!(ch, ManyUITUI.RefreshEvent())
    end
    @test Base.n_avail(ch) == ch.sz_max

    t = @async ManyUIWeb.terminate!(s; deadline = 0.5)
    @test timedwait(() -> istaskdone(t), 10.0; pollint = 0.001) === :ok
    @test ManyUIWeb.state(s) === ManyUIWeb.SessionState.DEAD
    @test !isopen(ch)
end

@testitem "session: age and idle are pure in now" begin
    using ManyUIWeb, ManyUITUI
    import ManyUI
    import Sockets

    mutable struct Counter <: ManyUI.Widget
        node::ManyUI.WidgetNode
        count::Int
    end
    Counter() = Counter(ManyUI.WidgetNode(), 0)
    ManyUI.node(w::Counter) = w.node

    cfg = ManyUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "t", ManyUITUI.Size(80, 24),
                                 ManyUITUI.Size(20, 5))
    s = ManyUIWeb.Session("0"^32, () -> Counter(),
                          ManyUITUI.STYLESHEET_EMPTY, cfg)
    @test ManyUIWeb.age(s, s.created + 12.0) == 12.0
    @test ManyUIWeb.idle(s, s.last_seen + 3.5) == 3.5
    ManyUIWeb.terminate!(s; deadline = 0.5)
end
