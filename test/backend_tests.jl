# backend_tests.jl -- WebBackend, the out-of-tree half of ManyUI's launch
# seam.
#
# The claims worth pinning are the ones a reader would doubt: that a
# backend defined in ANOTHER package joins by dispatch alone, that the same
# factory and the same AppConfig work here as on a terminal, and that the
# handle answers the same verbs. Sockets are real but bound on port 0, so
# these are cheap and never collide.

@testitem "backend: WebBackend is a ManyUI.Backend" begin
    using ManyUIWeb
    using ManyUI

    @test WebBackend <: ManyUI.Backend
    @test WebBackend() isa ManyUI.Backend
    @test WebBackend(; port = 1234).config.port == 1234
    # serve's keywords are ServerConfig's, and they survive the wrapper.
    @test WebBackend(; title = "T").config.title == "T"
    @test WebBackend(; multi_session = false).config.multi_session == false
end

@testitem "backend: WebBackend defines no make_driver" begin
    using ManyUIWeb
    using ManyUI

    # The web mints one driver PER SESSION inside Session, so there is no
    # single driver to make. If this ever starts passing, someone has
    # misunderstood the seam.
    @test_throws MethodError ManyUI.make_driver(WebBackend())
end

@testitem "backend: launch(wait = false) returns a live WebServer" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI

    server = launch(() -> Container(Label("hi"));
                    backend = WebBackend(; port = 0), wait = false)
    try
        @test server isa WebServer
        @test isopen(server)
        @test ManyUIWeb.bound_port(server) > 0
    finally
        close(server)
    end
    @test !isopen(server)
end

@testitem "backend: the launch handle answers the same verbs everywhere" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI

    # isopen/close/wait is the whole cross-backend handle contract.
    server = launch(() -> Container(Label("x"));
                    backend = WebBackend(; port = 0), wait = false)
    @test isopen(server)
    close(server)
    wait(server)
    @test !isopen(server)
end

@testitem "backend: launch threads AppConfig into every session" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI

    # The regression this guards: Session used to rebuild an AppConfig from
    # min_size/title alone, so these three knobs never reached a session.
    cfg = ManyUI.AppConfig(; title = "threaded", min_size = ManyUI.Size(9, 2),
                             diff_gap = 11, esc_timeout = 0.25,
                             sync_frames = false)
    server = launch(() -> Container(Label("x"));
                    backend = WebBackend(; port = 0), config = cfg,
                    wait = false)
    try
        s = ManyUIWeb.create_session!(server)
        @test s !== nothing
        @test s.app.config.title == "threaded"
        @test s.app.config.min_size == ManyUI.Size(9, 2)
        @test s.app.config.diff_gap == 11
        @test s.app.config.esc_timeout == 0.25
        @test s.app.config.sync_frames == false
    finally
        close(server)
    end
end

@testitem "backend: serve's own config still reaches sessions" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI

    # Backward compatibility: ServerConfig(title=..., min_size=...) is the
    # documented spelling and must keep working untouched.
    server = serve(() -> Container(Label("x"));
                   port = 0, title = "legacy",
                   min_size = ManyUI.Size(7, 3))
    try
        s = ManyUIWeb.create_session!(server)
        @test s.app.config.title == "legacy"
        @test s.app.config.min_size == ManyUI.Size(7, 3)
    finally
        ManyUI.stop!(server)
    end
end

@testitem "backend: an explicit app config wins over title/min_size" begin
    using ManyUIWeb
    using ManyUI

    cfg = ServerConfig(; title = "ignored", min_size = ManyUI.Size(2, 2),
                         app = ManyUI.AppConfig(; title = "wins",
                                                  min_size = ManyUI.Size(5, 5)))
    @test cfg.app.title == "wins"
    @test cfg.app.min_size == ManyUI.Size(5, 5)
    # The transport-level fields keep their own values.
    @test cfg.title == "ignored"
end

@testitem "backend: launch calls the factory once per session, not once" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI

    # The reason launch takes a factory rather than a widget: a terminal
    # needs one app, a browser needs one PER CLIENT.
    calls = Ref(0)
    factory = () -> (calls[] += 1; Container(Label("x")))
    server = launch(factory; backend = WebBackend(; port = 0), wait = false)
    try
        @test calls[] == 0          # nothing built until a client arrives
        ManyUIWeb.create_session!(server)
        @test calls[] == 1
        ManyUIWeb.create_session!(server)
        @test calls[] == 2          # a second client, a second tree
    finally
        close(server)
    end
end
