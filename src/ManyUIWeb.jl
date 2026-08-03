"""
A web transport for character-grid UIs: serves a vendored xterm.js page,
tunnels a terminal-byte stream over a WebSocket, and feeds browser input
back to an application loop.

The transport is framework-neutral. Its core -- the wire protocol, the
xterm.js client, and a server driven through the [`AbstractSession`](@ref)
/ [`AbstractFrontend`](@ref) seam -- names no UI framework. ManyUI is one
frontend (the default: `serve`, [`WebSocketDriver`](@ref), [`Session`](@ref)),
built on the nine-method `ManyUITUI.Driver` seam and nothing beyond
`ManyUI.WEB_BRIDGE_SURFACE`. A Tachikoma frontend ships as a package
extension, loaded when Tachikoma is present.
"""
module ManyUIWeb

using ManyUI, ManyUITUI
using DocStringExtensions
import HTTP
import JSON
import Random
import Sockets

@template (FUNCTIONS, METHODS, MACROS) = """
    $(TYPEDSIGNATURES)
    $(DOCSTRING)
    """
@template TYPES = """
    $(TYPEDEF)
    $(DOCSTRING)

    # Fields
    $(TYPEDFIELDS)
    """

include("protocol.jl")
include("assets.jl")
include("transport.jl")
include("wsdriver.jl")
include("session.jl")
include("server.jl")
include("backend.jl")
include("native.jl")

# neutral core
export AbstractSession, AbstractFrontend, make_session
export session_id, session_attach!, session_detach!, session_input!
export session_control!, session_state, session_touch!, session_expired
export session_terminate!, frontend_session_interface
export SessionState
# ManyUI frontend
export WebServer, ServerConfig, WebSocketDriver, Session, ManyUIFrontend, serve
export WebBackend
# Tachikoma frontend (provided by the extension when Tachikoma is loaded)
export serve_tachikoma

"""
$(SIGNATURES)

Serve a Tachikoma app in the browser over this transport.

`factory` is `() -> Tachikoma.Model`, called once to build the app. Returns
a live [`WebServer`](@ref); `stop!` it or `wait` on it like any other.

This is a stub: the real method lives in the `Tachikoma` package extension
and appears only once Tachikoma is loaded. It also requires a Tachikoma
that accepts an `io=` sink (`with_terminal`/`app`); see Tachikoma PR #39.

    using ManyUI, ManyUITUIWeb, Tachikoma
    serve_tachikoma(() -> MyModel(); port = 8000)

Constraint, from Tachikoma's process-global terminal I/O: the app is
**single-session** -- one browser at a time, because input and stdout
capture are process-wide. Resize is handled live, so the app tracks the
browser's size.
"""
serve_tachikoma(args...; kwargs...) =
    error("serve_tachikoma requires Tachikoma to be loaded: add `using " *
          "Tachikoma`. It also needs a Tachikoma that accepts an `io=` " *
          "sink (PR #39).")

end # module
