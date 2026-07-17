# transport_tests.jl -- the framework-neutral core.
#
# The refactor's whole claim is that the server drives anything satisfying
# AbstractSession/AbstractFrontend, with no DualUI in sight. The proof is a
# frontend defined HERE, in the test, out of nothing but the interface --
# if the real server can run it end to end over a socket, the transport is
# neutral. (DualUIWeb's own Tachikoma extension is the production instance
# of exactly this shape.)

@testitem "transport: a mock frontend records what the server delivers" tags=[:socket] begin
    using DualUIWeb
    using DualUI
    import HTTP

    # A session that is not DualUI and not Tachikoma: it just records every
    # interface call. Enough to prove the server speaks only the interface.
    mutable struct RecSession <: DualUIWeb.AbstractSession
        id::String
        state::DualUIWeb.SessionState.T
        last_seen::Float64
        input::Vector{Vector{UInt8}}
        controls::Vector{DualUIWeb.ControlMessage}
        attaches::Int
        detaches::Int
    end

    DualUIWeb.session_id(s::RecSession) = s.id
    function DualUIWeb.session_attach!(s::RecSession, ws, hello)
        s.attaches += 1
        s.state = DualUIWeb.SessionState.RUNNING
        nothing
    end
    function DualUIWeb.session_detach!(s::RecSession)
        s.detaches += 1
        s.state = DualUIWeb.SessionState.PAUSED
        nothing
    end
    DualUIWeb.session_input!(s::RecSession, b) = (push!(s.input, collect(b)); length(b))
    DualUIWeb.session_control!(s::RecSession, m) = (push!(s.controls, m); nothing)
    DualUIWeb.session_state(s::RecSession) = s.state
    DualUIWeb.session_touch!(s::RecSession) = (s.last_seen = 1.0; nothing)
    DualUIWeb.session_expired(s::RecSession, timeout, now) =
        s.state === DualUIWeb.SessionState.PAUSED
    DualUIWeb.session_terminate!(s::RecSession; deadline = 5.0) =
        (s.state = DualUIWeb.SessionState.DEAD; nothing)
    Base.isopen(s::RecSession) =
        s.state !== DualUIWeb.SessionState.DEAD

    struct RecFrontend <: DualUIWeb.AbstractFrontend
        made::Vector{RecSession}
    end
    function DualUIWeb.make_session(fe::RecFrontend, id, config)
        s = RecSession(id, DualUIWeb.SessionState.NEW, 0.0,
                       Vector{UInt8}[], DualUIWeb.ControlMessage[], 0, 0)
        push!(fe.made, s)
        return s
    end

    # The mock satisfies the interface, provably.
    @test DualUIWeb.frontend_session_interface(RecSession) == Symbol[]

    fe = RecFrontend(RecSession[])
    server = DualUIWeb.WebServer(fe; config = ServerConfig(port = 0))
    DualUI.start!(server)
    try
        port = DualUIWeb.bound_port(server)
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
        @test any(m -> m.kind === DualUIWeb.ControlKind.RESIZE &&
                       m.width == 100 && m.height == 30, s.controls)
    finally
        DualUI.stop!(server)
    end
end

@testitem "transport: an incomplete frontend is caught by the interface check" begin
    using DualUIWeb

    struct HalfSession <: DualUIWeb.AbstractSession end
    DualUIWeb.session_id(::HalfSession) = "x"
    # everything else is missing

    gaps = DualUIWeb.frontend_session_interface(HalfSession)
    @test :session_attach! in gaps
    @test :session_input! in gaps
    @test :session_id ∉ gaps                        # the one we defined
    @test length(gaps) == length(DualUIWeb.REQUIRED_SESSION_METHODS) - 1
end
