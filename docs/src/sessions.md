# Sessions

```@meta
CurrentModule = DualUIWeb
```

A session is one browser client's application. In multi-session mode —
the default — every connected client gets an **independent** widget
tree, application state and event loop. Nothing is shared, so two users
of the same server cannot see or disturb each other's interface.

That is why `serve` takes a *factory* rather than a tree: it is called
once per client.

```julia
# Each tab gets its own counter.
serve(() -> Counter(0); port = 8000)
```

## Lifecycle

```@example states
using DualUIWeb
instances(DualUIWeb.SessionState.T)
```

| State | Meaning |
|:--|:--|
| `NEW` | created, no client attached yet |
| `RUNNING` | attached to a live socket, painting frames |
| `PAUSED` | the socket dropped; state preserved, loop stopped |
| `CLOSING` | shutting down |
| `DEAD` | terminated, resources released |

A client that connects sends a `hello` control frame carrying its
dimensions; `attach!` moves the session to `RUNNING` and the
application begins painting into the socket.

## Dropped connections

Networks fail, laptops sleep, tabs get backgrounded. A dropped
WebSocket does not destroy the application.

When the socket drops unexpectedly, the session is **paused**: its
event loop stops and its state is preserved in memory. Frames are not
produced for a client that is not there, and the pause is explicit
rather than a side effect of a full buffer — a detached driver
discards writes rather than blocking, so nothing can wedge the
application task.

If the client reconnects within `session_timeout`, the new socket is
attached, the loop resumes, and a full repaint is forced: the
browser's screen is blank, so the diff baseline must be reset rather
than assumed.

```@example states
using DualUIWeb
ServerConfig().session_timeout   # seconds a paused session survives
```

If the client does not come back in time, a reap sweep terminates the
application instance, releases its resources and triggers a garbage
collection. Sweeps run every `reap_interval` seconds:

```@example states
ServerConfig().reap_interval
```

Both are configurable — set them low in tests so nothing has to sleep:

```julia
cfg = ServerConfig(; port = 0, session_timeout = 0.05,
                   reap_interval = 0.01)
server = serve(() -> my_ui(), cfg)
```

## Limits

`max_sessions` caps how many sessions a server will hold; past that,
new clients are refused rather than allowed to exhaust memory.

```@example states
ServerConfig().max_sessions
```

## Single-session mode

Setting `multi_session = false` gives every client the *same*
application — useful when the server exists to expose one running
program rather than to host many independent ones.

```julia
cfg = ServerConfig(; port = 8000, multi_session = false)
server = serve(() -> the_one_ui(), cfg)
```

## The wire protocol

Deliberately minimal, with no framing overhead beyond what a WebSocket
already gives:

| Direction | Frame | Payload |
|:--|:--|:--|
| server → client | binary | raw ANSI bytes |
| client → server | binary | raw input bytes |
| client → server | text | JSON control |
| server → client | text | JSON control (`bye` only) |

Control frames are JSON: `{"t":"hello","w":120,"h":40,"tc":true}`,
`{"t":"resize","w":120,"h":40}`, `ping`/`pong`, and `bye`.

Decoding is total. A malformed frame from a hostile or buggy client is
rejected and the session survives — `decode_control` returns `nothing`
rather than throwing, because it sits directly on bytes an untrusted
client chose.

```@example proto
using DualUIWeb
(DualUIWeb.decode_control("{\"t\":\"resize\",\"w\":100,\"h\":30}"),
 DualUIWeb.decode_control("not json at all"))
```
