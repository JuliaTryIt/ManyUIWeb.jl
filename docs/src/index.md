# ManyUIWeb.jl

```@meta
CurrentModule = ManyUIWeb
```

Serve a [ManyUI](https://github.com/s-celles/ManyUI.jl) application in
a web browser, without changing the application.

```@docs
ManyUIWeb
```

## How it works

A ManyUI application already produces a stream of ANSI escape
sequences. Rendering it in a browser does not mean translating it to
HTML — it means giving those bytes to a terminal emulator that happens
to run in a browser tab.

```
your App ─▶ ANSI bytes ─▶ WebSocket ─▶ xterm.js ─▶ the browser
   ▲                                                    │
   └──────── events ◀── ANSI input ◀── WebSocket ◀──────┘
```

`WebSocketDriver` implements ManyUI's nine-method `Driver` interface
over a socket. Outgoing frames are piped straight into the WebSocket;
incoming payloads are fed to ManyUI's input parser and injected into
the event loop as ordinary events. ManyUI itself never learns that any
of this happened, which is why it has no HTTP dependency and a pure
terminal application never pays for one.

## Installation

```julia
using Pkg
Pkg.develop(path = "path/to/ManyUI")
Pkg.develop(path = "path/to/ManyUIWeb")
```

## Quickstart

`serve` takes a factory that returns a fresh widget tree, and starts an
asynchronous HTTP server. It does not block — it hands back a live
handle:

```julia
using ManyUI, ManyUIWeb

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
ManyUI:

```julia
using ManyUI, ManyUIWeb

sheet = parse_css("""
    Container { layout: column; padding: 1; }
    Label     { color: cyan; }
""")

server = serve(() -> my_ui(); port = 8000, stylesheet = sheet)
```

## Configuration

Anything not given to `serve` directly comes from `ServerConfig`:

```@example cfg
using ManyUIWeb
cfg = ServerConfig()
(port = cfg.port, multi_session = cfg.multi_session,
 session_timeout = cfg.session_timeout, max_sessions = cfg.max_sessions,
 default_size = cfg.default_size, min_size = cfg.min_size)
```

`default_size` is what a session assumes before the browser's first
`hello` arrives carrying the real terminal dimensions, and `min_size`
is the threshold below which the client sees the "Increase Terminal
Size" overlay — exactly as it would on a small tty.

## `launch`: the same app, either target

`serve` is the web-specific entry point and is not going anywhere. But an
app that runs in a browser is a plain ManyUI app, and `launch` lets you say
so — the backend is the only thing that changes:

```julia
using ManyUI, ManyUIWeb

ui() = Container(Label("hello"))

launch(ui)                                   # this terminal
launch(ui; backend = WebBackend(port = 8000))  # a browser
```

`config::AppConfig` and `stylesheet` describe the app, so they are spelled
identically on both lines. `WebBackend` takes every [`serve`](@ref)
keyword, because it wraps a [`ServerConfig`](@ref):

```julia
launch(ui; backend = WebBackend(port = 8000, title = "Dashboard",
                                multi_session = false))
```

Like every `launch`, this blocks until the server stops and absorbs Ctrl-C
— the `try`/`wait`/`finally stop!` dance the examples write by hand. Pass
`wait = false` to get the live [`WebServer`](@ref) back instead; it answers
`isopen`/`close`/`wait` like any other `launch` handle.

### App config reaches sessions

`AppConfig` is threaded into every session, so knobs with no `ServerConfig`
twin — `diff_gap`, `esc_timeout`, `sync_frames` — now reach a served app:

```julia
launch(ui; backend = WebBackend(port = 8000),
       config = AppConfig(; title = "Dashboard", diff_gap = 8))
```

`ServerConfig(; title, min_size)` keeps working and keeps meaning what it
did; an explicit `app::AppConfig` wins over both.

## A neutral transport: ManyUI or Tachikoma

The server, the WebSocket loop and the reaper name no UI framework. They
drive whatever satisfies two interfaces -- [`AbstractSession`](@ref) (one
client's app instance) and [`AbstractFrontend`](@ref) (mints one session
per connection). ManyUI is the default frontend; `serve` builds it. Any
framework that emits terminal bytes can be another, because xterm.js
renders terminal bytes and the wire never cared where they came from.

### Tachikoma in the browser

A [Tachikoma](https://github.com/kahliburke/Tachikoma.jl) app runs over the
same transport, through a frontend that ships as a package extension:

```julia
using ManyUIWeb, Tachikoma

serve_tachikoma(() -> MyModel(); port = 8000)
```

This needs a Tachikoma that accepts an `io=` sink (`with_terminal`/`app`) --
[Tachikoma PR #39](https://github.com/kahliburke/Tachikoma.jl/pull/39), so
dev a patched Tachikoma until it lands. Two constraints follow from
Tachikoma's process-global terminal I/O, and are enforced or documented
rather than worked around: the app is **single-session** (one browser at a
time). Resize is handled live, so the app tracks the browser's size. See
`examples/tachikoma_web.jl`.
