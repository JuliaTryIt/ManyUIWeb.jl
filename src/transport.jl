# transport.jl -- the framework-neutral core.
#
# Everything in this file, in protocol.jl and in assets.jl knows nothing
# about DualUI. The wire is terminal bytes plus JSON control (protocol.jl),
# the client is xterm.js (assets.jl), and the server drives whatever
# satisfies the two interfaces below. DualUI is one such thing -- see
# `Session` and `DualUIFrontend` -- and Tachikoma is another, in an
# extension. Neither is named here.
#
# The split is the same one DualUI draws at its `Driver` seam, one layer
# out: a session moves bytes to and from a client and runs an app loop; it
# never hands the transport a widget, a buffer or a model.

# ------------------------------------------------------------- a session

"""
One connected client's application instance: its own app, its own loop,
its own state, sharing nothing with any other session.

This is the seam a UI framework plugs into. A frontend's session type
subtypes this and implements the interface below; the server calls exactly
these methods and nothing else, so a frontend that satisfies them works
without the server knowing which framework it is.

The verbs, and the whole of the contract:

| method | when | must |
|---|---|---|
| [`session_id`](@ref) | table key | return a stable id |
| [`session_attach!`](@ref) | client connects / reconnects | wire `ws`, start or resume the loop |
| [`session_detach!`](@ref) | socket drops | pause, preserve state, NEVER kill |
| [`session_input!`](@ref) | binary frame | deliver input bytes to the app |
| [`session_control!`](@ref) | text frame | act on a decoded [`ControlMessage`](@ref) |
| [`session_state`](@ref) | takeover / reap decisions | report lifecycle state |
| [`session_touch!`](@ref) | any client contact | stamp the reap clock |
| [`session_expired`](@ref) | reap sweep | pure predicate over `(timeout, now)` |
| [`session_terminate!`](@ref) | reap / shutdown | stop the loop, free resources |
| `Base.isopen` | everywhere | true until closing or dead |
"""
abstract type AbstractSession end

"""
$(SIGNATURES)

`s`'s id: the key it lives under in the session table. Stable for `s`'s
whole life.
"""
function session_id end

"""
$(SIGNATURES)

Wire `ws` to `s` and bring its loop up, or resume it on a reconnect.
`hello` carries the client's opening size and capabilities.
"""
function session_attach! end

"""
$(SIGNATURES)

The socket dropped. Pause `s` and preserve its state for a later reattach.
MUST NOT kill: only [`session_terminate!`](@ref) does, and only on the reap
timeout.
"""
function session_detach! end

"""
$(SIGNATURES)

Deliver a binary input frame -- raw terminal bytes from the client -- to
`s`'s app.
"""
function session_input! end

"""
$(SIGNATURES)

Act on a decoded control frame: a resize reaches the layout, a ping earns a
pong. `msg` has already been parsed from the wire, so a frontend never
touches JSON.
"""
function session_control! end

"""
$(SIGNATURES)

Where `s` is in its life, as a [`SessionState.T`](@ref).
"""
function session_state end

"""
$(SIGNATURES)

Stamp `s`'s reap clock: the client was just heard from.
"""
function session_touch! end

"""
$(SIGNATURES)

Whether `s` has outlived `timeout` seconds of silence as of `now`. A pure
predicate -- no clock, no socket -- so the reap policy is testable without
either. Only a paused session can expire.
"""
function session_expired end

"""
$(SIGNATURES)

Stop `s`'s loop and free its resources. `deadline` bounds the wait so a
wedged loop can never wedge the reaper.
"""
function session_terminate! end

# ------------------------------------------------------------ a frontend

"""
A UI framework, as the transport sees it: a thing that mints one
[`AbstractSession`](@ref) per connection.

A frontend holds whatever a session needs to be built -- a widget factory
and stylesheet for DualUI, a model factory for Tachikoma -- and implements
the single method [`make_session`](@ref). That is the whole seam: give the
server a frontend and it can host that framework, with no other change.
"""
abstract type AbstractFrontend end

"""
$(SIGNATURES)

A fresh [`AbstractSession`](@ref) with id `id`, built for one new client.

Called once per session, under the server lock. `config` is the
[`ServerConfig`](@ref); a frontend reads the fields it needs (`default_size`,
`title`, ...) and ignores the rest. There is no fallback: a frontend that
forgets this gets a `MethodError` naming its type.
"""
function make_session end

"""
$(SIGNATURES)

The names an [`AbstractSession`](@ref) subtype must implement, in the order
the server needs them. Returns the missing ones; empty means conformant, so
a frontend package can prove it fits without reading this source:

    @test frontend_session_interface(MySession) == Symbol[]
"""
frontend_session_interface(::Type{S}) where {S<:AbstractSession} =
    filter(m -> !_implements(m, S), collect(REQUIRED_SESSION_METHODS))

"""
The methods every session type must provide. Data, so a test can iterate
it.
"""
const REQUIRED_SESSION_METHODS = (:session_id, :session_attach!,
                                  :session_detach!, :session_input!,
                                  :session_control!, :session_state,
                                  :session_touch!, :session_expired,
                                  :session_terminate!)

"""
Whether a method named `m` has a definition accepting `S`, past the bare
`AbstractSession` fallback. Internal.
"""
function _implements(m::Symbol, ::Type{S}) where {S<:AbstractSession}
    isdefined(@__MODULE__, m) || return false
    f = getfield(@__MODULE__, m)
    for meth in methods(f)
        sig = meth.sig
        sig isa UnionAll && (sig = Base.unwrap_unionall(sig))
        ps = sig.parameters
        length(ps) >= 2 || continue
        pt = ps[2]
        pt isa TypeVar && (pt = pt.ub)
        pt === AbstractSession && continue          # the fallback, not an impl
        S <: pt && return true
    end
    return false
end
