# server_tests.jl -- W1/W2. The async HTTP server: binding, routing and
# teardown.
#
# Tests tagged `:socket` bind a REAL listener and are the only ones here
# that touch the network. A sandbox without socket permissions skips
# them with
#
#     @run_package_tests filter = ti -> !(:socket in ti.tags)
#
# Every one of them binds port 0 -- the OS hands back a free ephemeral
# port, so two suites running at once never collide -- and every one
# tears its server down in a `finally`, so a failed assertion can never
# leak a bound port into the next test. No test sleeps to wait for the
# server: `start!` returns only once the listen loop is accepting, and
# every client call carries a timeout.

@testitem "server: ServerConfig carries the documented defaults" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import Sockets

    c = ServerConfig()
    @test c.host === Sockets.localhost
    @test c.port == 8000
    @test c.multi_session
    @test c.session_timeout == 300.0
    @test c.reap_interval == 10.0
    @test c.max_sessions == 64
    @test c.title == "ManyUI"
    @test c.default_size === Size(80, 24)
    @test c.min_size === Size(20, 5)
    @test isbitstype(fieldtype(ServerConfig, :default_size))
end

@testitem "server: every ServerConfig keyword lands in its own field" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import Sockets

    # Every value below differs from the default, so a keyword wired to
    # the wrong field cannot pass.
    c = ServerConfig(host = Sockets.IPv4(0), port = 9123,
                     multi_session = false, session_timeout = 12.5,
                     reap_interval = 0.25, max_sessions = 3,
                     title = "probe", default_size = Size(100, 30),
                     min_size = Size(10, 3))
    @test c.host === Sockets.IPv4(0)
    @test c.port == 9123
    @test !c.multi_session
    @test c.session_timeout == 12.5
    @test c.reap_interval == 0.25
    @test c.max_sessions == 3
    @test c.title == "probe"
    @test c.default_size === Size(100, 30)
    @test c.min_size === Size(10, 3)
end

@testitem "server: WebServer is parametric in its frontend" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI

    f = () -> Container()
    s = WebServer(f)
    # The server is parametric in its FRONTEND, and the frontend holds the
    # factory concretely -- so no boxed closure sits on the per-session
    # path, and the server itself names no framework.
    @test s isa WebServer{<:ManyUIFrontend}
    @test s.frontend isa ManyUIFrontend
    @test isconcretetype(fieldtype(typeof(s.frontend), :factory))
    @test s.frontend.factory === f
    @test s.server === nothing
    @test s.reaper === nothing
    @test !s.running
    @test isempty(s.sessions)
    @test !isopen(s)
    @test isempty(ManyUIWeb.sessions(s))
end

@testitem "server: handle_http serves index at root" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = WebServer(() -> Container())
    for target in ("/", "/index.html")
        r = ManyUIWeb.handle_http(s, HTTP.Request("GET", target))
        @test r.status == 200
        @test startswith(HTTP.header(r, "Content-Type"), "text/html")
        @test !isempty(r.body)
        # W2. The root IS `index_html`; the router adds nothing of its
        # own.
        @test String(r.body) == ManyUIWeb.index_html(s.config)
    end
end

@testitem "server: handle_http serves the vendored bundle" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = WebServer(() -> Container())
    # The root and the health probe are generated per request, not
    # vendored, so they are not the bundle's to serve.
    vendored = [p for p in keys(ManyUIWeb.ASSETS)
                if p != "/" && p != "/healthz"]
    # W2 is not satisfiable by an empty bundle.
    @test !isempty(vendored)
    for path in vendored
        mime, body = ManyUIWeb.ASSETS[path]
        r = ManyUIWeb.handle_http(s, HTTP.Request("GET", path))
        @test r.status == 200
        @test HTTP.header(r, "Content-Type") == mime
        @test r.body == body
    end
end

@testitem "server: handle_http 404s an unknown path" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = WebServer(() -> Container())
    # `/ws` is upgraded before `handle_http` ever sees it, so a plain GET
    # of it is just another unknown path. The traversal attempts prove
    # the router is an exact dictionary lookup and never a file read:
    # there is no directory for a `..` to climb out of.
    for target in ("/nope", "/xterm.js.map", "/ws",
                   "/../Project.toml", "/assets/../../etc/passwd",
                   "/index.html/", "/favicon.svg/x")
        r = ManyUIWeb.handle_http(s, HTTP.Request("GET", target))
        @test r.status == 404
    end
end

@testitem "server: handle_http refuses a non-GET" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = WebServer(() -> Container())
    for method in ("POST", "PUT", "DELETE", "PATCH")
        r = ManyUIWeb.handle_http(s, HTTP.Request(method, "/"))
        @test r.status == 405
        @test HTTP.header(r, "Allow") == "GET"
    end
end

@testitem "server: handle_http ignores the query string when routing" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = WebServer(() -> Container())
    r = ManyUIWeb.handle_http(s, HTTP.Request("GET", "/?session=abc"))
    @test r.status == 200
    @test String(r.body) == ManyUIWeb.index_html(s.config)
end

@testitem "server: handle_http reports the session count at healthz" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP
    import JSON

    s = WebServer(() -> Container(); config = ServerConfig(max_sessions = 7))
    r = ManyUIWeb.handle_http(s, HTTP.Request("GET", "/healthz"))
    @test r.status == 200
    @test startswith(HTTP.header(r, "Content-Type"), "application/json")
    body = JSON.parse(String(r.body))
    @test body.sessions == 0
    @test body.max_sessions == 7
    @test body.multi_session === true
end

@testitem "server: url reports the configured port before it binds" begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import Sockets

    s = WebServer(() -> Container();
                  config = ServerConfig(port = 8123))
    @test ManyUIWeb.url(s) == "http://127.0.0.1:8123/"
    @test ManyUIWeb.bound_port(s) == 8123
    # An IPv6 host has to be bracketed or the URL is unusable.
    v6 = WebServer(() -> Container();
                   config = ServerConfig(host = Sockets.IPv6(1),
                                         port = 8123))
    @test ManyUIWeb.url(v6) == "http://[::1]:8123/"
end

@testitem "server: session ids are 32 unguessable hex chars" begin
    using ManyUIWeb, ManyUITUI

    ids = Set{String}()
    for _ in 1:256
        id = ManyUIWeb._random_hex()
        @test length(id) == 32
        @test all(c -> c in "0123456789abcdef", id)
        push!(ids, id)
    end
    # A session id is a bearer token: a repeat would hand one client
    # another client's App. 128 bits of OS entropy must not collide in
    # 256 draws.
    @test length(ids) == 256
end

@testitem "server: PortInUseError explains itself" begin
    using ManyUIWeb, ManyUITUI
    import Sockets

    e = ManyUIWeb.PortInUseError(Sockets.localhost, 8000)
    msg = sprint(showerror, e)
    # The whole point is that the operator reads a sentence, not a libuv
    # errno.
    @test occursin("8000", msg)
    @test occursin("already in use", msg)
    @test !occursin("EADDRINUSE", msg)
    @test !occursin("IOError", msg)
end

@testitem "server: serve binds port and is non-blocking" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    # W1 / req 2.4. `port = 0` asks the OS for a free ephemeral port.
    s = serve(() -> Container(); port = 0)
    try
        # Reaching this line at all is the non-blocking assertion: a
        # blocking `serve` would still be inside its listen loop.
        @test s isa WebServer
        @test isopen(s)
        @test s.running
        @test s.server !== nothing
        port = ManyUIWeb.bound_port(s)
        @test port > 0
        @test port != s.config.port
        # And it really is listening, not merely constructed.
        #
        # The timeouts are generous on purpose. They exist to stop a wedged
        # server hanging CI forever, NOT to assert latency: whichever socket
        # testitem runs first pays for compiling the whole request path
        # server-side, which can exceed 5s on a cold Windows runner even
        # though every later request lands in well under a second.
        r = HTTP.get("http://127.0.0.1:$port/healthz";
                     retry = false, status_exception = false,
                     connect_timeout = 30, request_timeout = 60)
        @test r.status == 200
    finally
        ManyUITUI.stop!(s)
    end
    @test !isopen(s)
end

@testitem "server: a real GET / returns the html bundle" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = serve(() -> Container(); port = 0)
    try
        port = ManyUIWeb.bound_port(s)
        r = HTTP.get("http://127.0.0.1:$port/";
                     retry = false, status_exception = false,
                     connect_timeout = 30, request_timeout = 60)
        @test r.status == 200
        @test startswith(HTTP.header(r, "Content-Type"), "text/html")
        @test !isempty(r.body)
        @test String(r.body) == ManyUIWeb.index_html(s.config)
    finally
        ManyUITUI.stop!(s)
    end
end

@testitem "server: a real GET of an unknown path 404s" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    s = serve(() -> Container(); port = 0)
    try
        port = ManyUIWeb.bound_port(s)
        r = HTTP.get("http://127.0.0.1:$port/definitely-not-a-route";
                     retry = false, status_exception = false,
                     connect_timeout = 30, request_timeout = 60)
        @test r.status == 404
        # A 404 must not take the listener down with it.
        @test isopen(s)
        ok = HTTP.get("http://127.0.0.1:$port/healthz";
                      retry = false, status_exception = false,
                      connect_timeout = 30, request_timeout = 60)
        @test ok.status == 200
    finally
        ManyUITUI.stop!(s)
    end
end

@testitem "server: url reflects the bound port" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI

    s = serve(() -> Container(); port = 0)
    port = ManyUIWeb.bound_port(s)
    try
        @test ManyUIWeb.url(s) == "http://127.0.0.1:$port/"
    finally
        ManyUITUI.stop!(s)
    end
    # Once stopped there is no bound port left to report, so `url` falls
    # back to what was configured.
    @test ManyUIWeb.url(s) == "http://127.0.0.1:0/"
end

@testitem "server: stop! frees the bound port" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP
    import Sockets

    s = serve(() -> Container(); port = 0)
    port = ManyUIWeb.bound_port(s)
    try
        @test port > 0
        r = HTTP.get("http://127.0.0.1:$port/healthz";
                     retry = false, status_exception = false,
                     connect_timeout = 30, request_timeout = 60)
        @test r.status == 200
    finally
        ManyUITUI.stop!(s)
    end
    @test !isopen(s)
    @test s.server === nothing
    @test !s.running

    # THE assertion: `listenany` returns the port it was ASKED for only
    # when that port is actually free. Anything else means `stop!` left
    # the listener behind.
    p2, server2 = Sockets.listenany(Sockets.localhost, UInt16(port))
    try
        @test Int(p2) == port
    finally
        close(server2)
    end
end

@testitem "server: a busy port reports a clear error" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI

    incumbent = serve(() -> Container(); port = 0)
    try
        port = ManyUIWeb.bound_port(incumbent)
        loser = WebServer(() -> Container();
                          config = ServerConfig(port = port))
        err = try
            ManyUITUI.start!(loser)
            nothing
        catch e
            e
        end
        @test err isa ManyUIWeb.PortInUseError
        @test err.port == port
        msg = sprint(showerror, err)
        @test occursin(string(port), msg)
        @test occursin("already in use", msg)
        # A failed bind must leave nothing half-started behind.
        @test loser.server === nothing
        @test !loser.running
        @test !isopen(loser)
        @test loser.reaper === nothing
        # And it must not have disturbed the incumbent.
        @test isopen(incumbent)
    finally
        ManyUITUI.stop!(incumbent)
    end
end

@testitem "server: start! and stop! are idempotent" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI

    s = WebServer(() -> Container(); config = ServerConfig(port = 0))
    try
        @test ManyUITUI.start!(s) === s
        port = ManyUIWeb.bound_port(s)
        # A second start must not bind a second listener.
        @test ManyUITUI.start!(s) === s
        @test ManyUIWeb.bound_port(s) == port
        @test isopen(s)
    finally
        ManyUITUI.stop!(s)
    end
    @test !isopen(s)
    # Stopping twice is a no-op, not a throw -- teardown runs from
    # `finally` blocks that cannot know whether it already ran.
    @test ManyUITUI.stop!(s) === nothing
    @test ManyUITUI.stop!(s) === nothing
    @test !isopen(s)
end

@testitem "server: close forwards to stop!" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI

    s = serve(() -> Container(); port = 0)
    try
        @test isopen(s)
    finally
        close(s)
    end
    @test !isopen(s)
    @test s.server === nothing
end

@testitem "server: serve accepts a prebuilt config" tags=[:socket] begin
    using ManyUIWeb, ManyUITUI
    using ManyUI, ManyUITUI
    import HTTP

    cfg = ServerConfig(port = 0, title = "prebuilt", max_sessions = 5)
    s = serve(() -> Container(), cfg)
    try
        @test s.config === cfg
        @test s.config.title == "prebuilt"
        @test isopen(s)
        port = ManyUIWeb.bound_port(s)
        r = HTTP.get("http://127.0.0.1:$port/healthz";
                     retry = false, status_exception = false,
                     connect_timeout = 30, request_timeout = 60)
        @test r.status == 200
    finally
        ManyUITUI.stop!(s)
    end
end
