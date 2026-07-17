# protocol_tests.jl -- @testitem blocks for DualUIWeb/src/protocol.jl.
#
# W1. The wire protocol between the browser and the session. The
# hostile-input testitem is the load-bearing one: `decode_control` sits
# directly on bytes an untrusted client chose, so "never throws" is a
# security property, not a convenience.

@testitem "protocol: ControlMessage keyword defaults" begin
    using DualUIWeb
    const P = DualUIWeb

    m = P.ControlMessage(P.ControlKind.PING)
    @test m.kind === P.ControlKind.PING
    @test m.width == 0
    @test m.height == 0
    @test m.session == ""
    @test m.truecolor

    m2 = P.ControlMessage(P.ControlKind.HELLO; width = 120, height = 40,
                          session = "abc", truecolor = false)
    @test m2.width == 120
    @test m2.height == 40
    @test m2.session == "abc"
    @test !m2.truecolor
end

@testitem "protocol: encode_control emits the documented shape" begin
    using DualUIWeb
    import JSON3
    const P = DualUIWeb

    m = P.ControlMessage(P.ControlKind.HELLO; width = 120, height = 40,
                         session = "ab", truecolor = true)
    o = JSON3.read(P.encode_control(m))
    @test o.t == "hello"
    @test o.w == 120
    @test o.h == 40
    @test o.session == "ab"
    @test o.tc === true
end

@testitem "protocol: every kind round-trips" begin
    using DualUIWeb
    const P = DualUIWeb

    for k in instances(P.ControlKind.T)
        m = P.ControlMessage(k; width = 80, height = 24,
                             session = "s1", truecolor = false)
        back = P.decode_control(P.encode_control(m))
        @test back !== nothing
        @test back.kind === k
        @test back.width == 80
        @test back.height == 24
        @test back.session == "s1"
        @test back.truecolor == false
    end
end

@testitem "protocol: decode_control never throws on hostile input" begin
    using DualUIWeb
    const P = DualUIWeb

    # A malformed frame must yield `nothing`, never an exception: this
    # runs on bytes an untrusted client chose, and a throw here would
    # take down the session that receives it.
    hostile = [
        "",                       # empty frame
        "{",                      # truncated JSON
        "not json at all",
        "null",
        "123",
        "[]",                     # array, not an object
        "\"just a string\"",
        "{}",                     # object with no tag
        "{\"w\":80,\"h\":24}",    # no tag
        "{\"t\":\"nope\"}",       # unknown tag
        "{\"t\":42}",             # tag of the wrong type
        "{\"t\":null}",
        "{\"t\":[\"hello\"]}",
        "{\"t\":\"hello\",\"w\":\"wide\"}",   # w of the wrong type
        "{\"t\":\"hello\",\"w\":{}}",
        "{\"t\":\"hello\",\"session\":42}",   # session of the wrong type
        "{\"t\":\"hello\",\"tc\":\"yes\"}",   # tc of the wrong type
        "{\"t\":\"resize\",\"w\":-5,\"h\":-9}",  # negative dimensions
    ]
    for s in hostile
        m = @test_nowarn P.decode_control(s)
        # Either a clean rejection, or a message with sane dimensions --
        # never a throw, and never a negative size reaching the App.
        if m !== nothing
            @test m.width >= 0
            @test m.height >= 0
        end
    end

    # The unparseable ones specifically reject rather than guess.
    @test P.decode_control("") === nothing
    @test P.decode_control("{") === nothing
    @test P.decode_control("[]") === nothing
    @test P.decode_control("{}") === nothing
    @test P.decode_control("{\"t\":\"nope\"}") === nothing
    @test P.decode_control("{\"t\":42}") === nothing
end

@testitem "protocol: decode_control fills missing fields with defaults" begin
    using DualUIWeb
    const P = DualUIWeb

    m = P.decode_control("{\"t\":\"hello\"}")
    @test m !== nothing
    @test m.kind === P.ControlKind.HELLO
    @test m.width == 0
    @test m.height == 0
    @test m.session == ""

    r = P.decode_control("{\"t\":\"resize\",\"w\":100,\"h\":30}")
    @test r !== nothing
    @test r.kind === P.ControlKind.RESIZE
    @test r.width == 100
    @test r.height == 30
end
