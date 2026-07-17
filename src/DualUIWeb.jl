"""
A web transport for character-grid UIs: serves a vendored xterm.js page,
tunnels a terminal-byte stream over a WebSocket, and feeds browser input
back to an application loop.

The transport is framework-neutral. Its core -- the wire protocol, the
xterm.js client, and a server driven through the [`AbstractSession`](@ref)
/ [`AbstractFrontend`](@ref) seam -- names no UI framework. DualUI is one
frontend (the default: `serve`, [`WebSocketDriver`](@ref), [`Session`](@ref)),
built on the nine-method `DualUI.Driver` seam and nothing beyond
`DualUI.WEB_BRIDGE_SURFACE`. A Tachikoma frontend ships as a package
extension, loaded when Tachikoma is present.
"""
module DualUIWeb

using DualUI
using DocStringExtensions
import HTTP
import JSON3
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

# neutral core
export AbstractSession, AbstractFrontend, make_session
export session_id, session_attach!, session_detach!, session_input!
export session_control!, session_state, session_touch!, session_expired
export session_terminate!, frontend_session_interface
export SessionState
# DualUI frontend
export WebServer, ServerConfig, WebSocketDriver, Session, DualUIFrontend, serve
export WebBackend

end # module
