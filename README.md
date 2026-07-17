# DualUIWeb

The web bridge for [`DualUI`](../DualUI): run the exact same
application in a browser instead of a terminal, with no change to the
widget tree, the stylesheet, or the application logic.

```julia
using DualUI, DualUIWeb

serve(() -> Container(Label("hello from the browser")); port = 8000)
```

## How it works

`DualUIWeb` implements one thing: a `WebSocketDriver <: DualUI.Driver`.
It offloads the terminal-rendering step to a JavaScript terminal
emulator in the client:

* the ANSI byte stream DualUI already produces is piped verbatim into
  the WebSocket as **binary** frames;
* keystrokes and mouse events come back as **binary** frames and go
  through the very same `DualUI.InputParser` a TTY uses;
* resize and handshake travel as **text** JSON control frames, and a
  resize funnels into `DualUI.notify_resize!` -- the identical seam
  SIGWINCH uses.

The bridge uses only the names in `DualUI.WEB_BRIDGE_SURFACE`; a test
asserts it.

## Sessions

Every connection gets its own `Session`: its own widget tree, `App`,
event channel, buffer pair and task. Sessions share nothing but the
immutable `Stylesheet` and `ServerConfig`. Isolation comes from the
factory, `() -> DualUI.Widget`, called once per session -- so user code
never names a driver type.

A dropped socket **pauses** a session and preserves its state; only the
reaper kills it, and only after `session_timeout`.

## Layout

| Path | Responsibility |
|---|---|
| `src/protocol.jl` | `ControlKind`, `ControlMessage`, JSON encode/decode |
| `src/wsdriver.jl` | `WebSocketDriver`: the nine methods, nothing more |
| `src/session.jl` | `Session`, `attach!`, `detach!`, `is_expired` |
| `src/assets.jl` | The client bundle and `index_html` |
| `src/server.jl` | `WebServer{F}`, `serve`, `handle_ws`, `reap!` |
| `assets/` | `index.html` and the favicon |

The served page pulls xterm.js, its fit addon and its CSS from
jsdelivr at pinned versions, so **the client needs network access to
that CDN**. Vendoring them locally would make the page self-contained;
that is not done today.

## Tests

```julia
julia --project=DualUIWeb -e 'using Pkg; Pkg.test()'
```
