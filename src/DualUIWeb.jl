"""
The web bridge: serves a vendored xterm.js page, tunnels the ANSI
stream over a WebSocket, and feeds browser keystrokes back into a
DualUI `App`.

DualUI itself has no HTTP dependency. Everything here plugs into the
nine-method `DualUI.Driver` seam from the outside, and uses nothing
beyond `DualUI.WEB_BRIDGE_SURFACE`.
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
include("wsdriver.jl")
include("session.jl")
include("server.jl")
include("backend.jl")

export WebServer, ServerConfig, WebSocketDriver, Session, serve
export WebBackend

end # module
