# transport_tests.jl -- the framework-neutral core.
#
# The refactor's whole claim is that the server drives anything satisfying
# AbstractSession/AbstractFrontend, with no ManyUI in sight. The proof is a
# frontend defined HERE, in the test, out of nothing but the interface --
# if the real server can run it end to end over a socket, the transport is
# neutral. (ManyUIWeb's own Tachikoma extension is the production instance
# of exactly this shape.)

@testitem "transport: a mock frontend records what the server delivers" tags=[:socket] begin
    using ManyUIWeb
    using ManyUI
    import HTTP

    # A session that is not ManyUI and not Tachikoma: it just records every
    # interface call. Enough to prove the server speaks only the interface.
    mutable struct RecSession <: ManyUIWeb.AbstractSession
        id::String
        state::ManyUIWeb.SessionState.T
        last_seen::Float64
        input::Vector{Vector{UInt8}}
        controls::Vector{ManyUIWeb.ControlMessage}
        attaches::Int
        detaches::Int
    end

    ManyUIWeb.session_id(s::RecSession) = s.id
    function ManyUIWeb.session_attach!(s::RecSession, ws, hello)
        s.attaches += 1
        s.state = ManyUIWeb.SessionState.RUNNING
        nothing
    end
    function ManyUIWeb.session_detach!(s::RecSession)
        s.detaches += 1
        s.state = ManyUIWeb.SessionState.PAUSED
        nothing
    end
    ManyUIWeb.session_input!(s::RecSession, b) = (push!(s.input, collect(b)); length(b))
    ManyUIWeb.session_control!(s::RecSession, m) = (push!(s.controls, m); nothing)
    ManyUIWeb.session_state(s::RecSession) = s.state
    ManyUIWeb.session_touch!(s::RecSession) = (s.last_seen = 1.0; nothing)
    ManyUIWeb.session_expired(s::RecSession, timeout, now) =
        s.state === ManyUIWeb.SessionState.PAUSED
    ManyUIWeb.session_terminate!(s::RecSession; deadline = 5.0) =
        (s.state = ManyUIWeb.SessionState.DEAD; nothing)
    Base.isopen(s::RecSession) =
        s.state !== ManyUIWeb.SessionState.DEAD

    struct RecFrontend <: ManyUIWeb.AbstractFrontend
        made::Vector{RecSession}
    end
    function ManyUIWeb.make_session(fe::RecFrontend, id, config)
        s = RecSession(id, ManyUIWeb.SessionState.NEW, 0.0,
                       Vector{UInt8}[], ManyUIWeb.ControlMessage[], 0, 0)
        push!(fe.made, s)
        return s
    end

    # The mock satisfies the interface, provably.
    @test ManyUIWeb.frontend_session_interface(RecSession) == Symbol[]

    fe = RecFrontend(RecSession[])
    server = ManyUIWeb.WebServer(fe; config = ServerConfig(port = 0))
    ManyUI.start!(server)
    try
        port = ManyUIWeb.bound_port(server)
        HTTP.WebSockets.open("ws://127.0.0.1:$port/ws") do ws
            HTTP.WebSockets.send(ws, "{\"t\":\"hello\",\"w\":80,\"h\":24}")
            HTTP.WebSockets.send(ws, UInt8[0x68, 0x69])          # "hi"
            HTTP.WebSockets.send(ws, "{\"t\":\"resize\",\"w\":100,\"h\":30}")
            sleep(0.2)
        end
        sleep(0.2)
        @test length(fe.made) == 1
        s = fe.made[1]
        @test s.attaches == 1
        @test s.detaches == 1                       # the drop paused it
        @test [0x68, 0x69] in s.input               # raw bytes reached the session
        @test any(m -> m.kind === ManyUIWeb.ControlKind.RESIZE &&
                       m.width == 100 && m.height == 30, s.controls)
    finally
        ManyUI.stop!(server)
    end
end

@testitem "transport: an incomplete frontend is caught by the interface check" begin
    using ManyUIWeb

    struct HalfSession <: ManyUIWeb.AbstractSession end
    ManyUIWeb.session_id(::HalfSession) = "x"
    # everything else is missing

    gaps = ManyUIWeb.frontend_session_interface(HalfSession)
    @test :session_attach! in gaps
    @test :session_input! in gaps
    @test :session_id ∉ gaps                        # the one we defined
    @test length(gaps) == length(ManyUIWeb.REQUIRED_SESSION_METHODS) - 1
end
