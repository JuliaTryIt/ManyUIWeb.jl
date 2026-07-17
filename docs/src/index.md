# DualUIWeb.jl

```@meta
CurrentModule = DualUIWeb
```

Serve a [DualUI](https://github.com/s-celles/DualUI.jl) application in
a web browser, without changing the application.

```@docs
DualUIWeb
```

## How it works

A DualUI application already produces a stream of ANSI escape
sequences. Rendering it in a browser does not mean translating it to
HTML — it means giving those bytes to a terminal emulator that happens
to run in a browser tab.

```
your App ─▶ ANSI bytes ─▶ WebSocket ─▶ xterm.js ─▶ the browser
   ▲                                                    │
   └──────── events ◀── ANSI input ◀── WebSocket ◀──────┘
```

`WebSocketDriver` implements DualUI's nine-method `Driver` interface
over a socket. Outgoing frames are piped straight into the WebSocket;
incoming payloads are fed to DualUI's input parser and injected into
the event loop as ordinary events. DualUI itself never learns that any
of this happened, which is why it has no HTTP dependency and a pure
terminal application never pays for one.

## Installation

```julia
using Pkg
Pkg.develop(path = "path/to/DualUI")
Pkg.develop(path = "path/to/DualUIWeb")
```

## Quickstart

`serve` takes a factory that returns a fresh widget tree, and starts an
asynchronous HTTP server. It does not block — it hands back a live
handle:

```julia
using DualUI, DualUIWeb

server = serve(() -> Container(Label("Hello from the browser!"));
               port = 8000)

# ... the app is now live at http://127.0.0.1:8000/ ...

stop!(server)   # terminates every session and releases the port
```

Open the URL and you get a terminal emulator wired to a Julia
application, with keystrokes and mouse events routed back.

Passing `port = 0` asks the OS for a free ephemeral port, which is what
you want in tests so two suites never collide. `bound_port` reports
what you actually got:

```julia
server = serve(() -> my_ui(); port = 0)
bound_port(server)   # e.g. 63367
url(server)          # "http://127.0.0.1:63367/"
```

The factory is called **once per client**, so each browser tab gets its
own independent tree and its own application state. See
[Sessions](@ref).

## Styling

A stylesheet is shared across sessions and passed straight through to
DualUI:

```julia
using DualUI, DualUIWeb

sheet = parse_css("""
    Container { layout: column; padding: 1; }
    Label     { color: cyan; }
""")

server = serve(() -> my_ui(); port = 8000, stylesheet = sheet)
```

## Configuration

Anything not given to `serve` directly comes from `ServerConfig`:

```@example cfg
using DualUIWeb
cfg = ServerConfig()
(port = cfg.port, multi_session = cfg.multi_session,
 session_timeout = cfg.session_timeout, max_sessions = cfg.max_sessions,
 default_size = cfg.default_size, min_size = cfg.min_size)
```

`default_size` is what a session assumes before the browser's first
`hello` arrives carrying the real terminal dimensions, and `min_size`
is the threshold below which the client sees the "Increase Terminal
Size" overlay — exactly as it would on a small tty.
