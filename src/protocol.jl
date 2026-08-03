# protocol.jl -- W1. The wire protocol: opinionated, zero framing
# overhead, exactly what xterm.js hands you.
#
#   server -> client  binary  raw ANSI bytes
#   client -> server  binary  raw input bytes -> feed_bytes!
#   client -> server  text    JSON control
#   server -> client  text    JSON control (BYE only)
#
# JSON shape: {"t":"hello","w":120,"h":40,"session":"ab..","tc":true}
# "t" values: "hello", "resize", "ping", "pong", "bye".

"""
The five control message kinds carried as JSON text frames.
"""
module ControlKind
@enum T::UInt8 begin
    HELLO = 0   # c->s: caps + initial size + optional session id
    RESIZE = 1  # c->s: {"t":"resize","w":120,"h":40}
    PING = 2
    PONG = 3
    BYE = 4     # s->c: session terminated
end
end

"""
One decoded control frame. Flat and total: every kind uses the same
struct, and unused fields are zero or empty.
"""
struct ControlMessage
    "Which control this is."
    kind::ControlKind.T
    "Client columns; 0 when not carried."
    width::Int
    "Client rows; 0 when not carried."
    height::Int
    "Session id the client wants to resume; empty for a new session."
    session::String
    "Client claims 24-bit color support."
    truecolor::Bool
end

"""
A control message with the documented defaults.
"""
ControlMessage(kind::ControlKind.T; width::Int = 0, height::Int = 0,
               session::AbstractString = "",
               truecolor::Bool = true)::ControlMessage =
    ControlMessage(kind, width, height, String(session), truecolor)

"""
The `"t"` tag of each kind. The wire spelling is fixed and independent
of the enum's Julia names.
"""
const _KIND_TAGS = ((ControlKind.HELLO, "hello"),
                    (ControlKind.RESIZE, "resize"),
                    (ControlKind.PING, "ping"),
                    (ControlKind.PONG, "pong"),
                    (ControlKind.BYE, "bye"))

const _TAG_OF = Dict{ControlKind.T,String}(k => t for (k, t) in _KIND_TAGS)
const _KIND_OF = Dict{String,ControlKind.T}(t => k for (k, t) in _KIND_TAGS)

# Every kind is on the wire, or a control exists that cannot be sent.
@assert length(_TAG_OF) == length(instances(ControlKind.T))

"""
Encode `m` as a JSON text frame. Pure.
"""
encode_control(m::ControlMessage)::String =
    JSON.json((t = _TAG_OF[m.kind], w = m.width, h = m.height,
               session = m.session, tc = m.truecolor))

"""
`o[k]` when it is a non-negative integer, else `default`.

A dimension is the one field a client can use to reach the layout
engine, so a non-integer, negative or non-finite value is dropped to
the default rather than forwarded. Pure. Internal.
"""
function _int_field(o, k::AbstractString, default::Int)::Int
    haskey(o, k) || return default
    v = o[k]
    v isa Bool && return default
    if v isa Integer
        return v < 0 ? default : Int(v)
    elseif v isa Real
        (isfinite(v) && v >= 0 && round(v) == v &&
         v <= typemax(Int)) || return default
        return Int(v)
    end
    return default
end

"""
`o[k]` when it is a string, else `default`. Pure. Internal.
"""
function _string_field(o, k::AbstractString, default::String)::String
    haskey(o, k) || return default
    v = o[k]
    return v isa AbstractString ? String(v) : default
end

"""
`o[k]` when it is a boolean, else `default`. Pure. Internal.
"""
function _bool_field(o, k::AbstractString, default::Bool)::Bool
    haskey(o, k) || return default
    v = o[k]
    return v isa Bool ? v : default
end

"""
Decode a JSON text frame.

Returns `nothing` on ANY invalid input and NEVER throws: a hostile
client must not be able to crash a session with malformed JSON. Pure.
"""
function decode_control(s::AbstractString)::Union{Nothing,ControlMessage}
    try
        o = JSON.parse(s)
        o isa JSON.Object || return nothing
        haskey(o, "t") || return nothing
        tag = o["t"]
        tag isa AbstractString || return nothing
        kind = get(_KIND_OF, String(tag), nothing)
        kind === nothing && return nothing
        return ControlMessage(kind;
                              width = _int_field(o, "w", 0),
                              height = _int_field(o, "h", 0),
                              session = _string_field(o, "session", ""),
                              truecolor = _bool_field(o, "tc", true))
    catch
        # Deliberately total: the caller is a receive loop on an
        # untrusted socket, and every malformed frame is the same
        # answer -- reject it and keep the session alive.
        return nothing
    end
end
