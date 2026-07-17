# server.jl -- W5. The HTTP server, the session table and the reaper.
# Every session mutation goes through `s.lock`.

# `WS_PATH` is `assets.jl`'s: it templates the same constant into the
# page, so the route the client dials and the route this file upgrades
# cannot drift apart. Defining a second one here would be exactly the
# drift it exists to prevent.

"""
Seconds a freshly upgraded socket has to introduce itself with a HELLO
before it is dropped. A client that never speaks would otherwise hold a
task and a socket forever.
"""
const HELLO_TIMEOUT = 10.0

"""
Seconds the reaper sleeps between glances at `running`, so `stop!` never
waits a whole `reap_interval` for it to notice.
"""
const REAP_TICK = 0.1

"""
Seconds `stop!` gives the reaper to wind down before giving up on it.
"""
const STOP_TIMEOUT = 5.0

"""
The port a server was asked to bind is already taken.

Binding a busy port is the single most common way starting a server
fails, and a raw `IOError: listen: address already in use (EADDRINUSE)`
plus twenty frames of libuv stack tells an operator nothing actionable.
This says the host, the port, and what to do instead.
"""
struct PortInUseError <: Exception
    "The interface that could not be bound."
    host::Sockets.IPAddr
    "The port that was already taken."
    port::Int
end

"""
Print the address and the three ways out, in one sentence.
"""
Base.showerror(io::IO, e::PortInUseError)::Nothing =
    print(io, "DualUIWeb cannot listen on ", _host_string(e.host), ":",
          e.port, " -- that address is already in use. Stop whatever ",
          "holds it, pick another port, or pass `port = 0` to let the ",
          "OS choose a free one.")

"""
Server knobs. Immutable, and shared by every session.
"""
struct ServerConfig
    "Interface to bind."
    host::Sockets.IPAddr
    "Port to bind; `0` asks the OS for a free ephemeral port."
    port::Int
    "One independent App per client, rather than one shared App."
    multi_session::Bool
    "X4/X5. Seconds a PAUSED session lives before it is reaped."
    session_timeout::Float64
    "Seconds between reap sweeps."
    reap_interval::Float64
    "Refuse new sessions past this many."
    max_sessions::Int
    "Browser tab title."
    title::String
    "Size assumed before the first HELLO."
    default_size::DualUI.Size
    "X2. Below this a session shows the overlay."
    min_size::DualUI.Size
end

"""
Config with the documented defaults.
"""
ServerConfig(; host::Sockets.IPAddr = Sockets.localhost,
               port::Int = 8000,
               multi_session::Bool = true,
               session_timeout::Float64 = 300.0,
               reap_interval::Float64 = 10.0,
               max_sessions::Int = 64,
               title::AbstractString = "DualUI",
               default_size::DualUI.Size = DualUI.Size(80, 24),
               min_size::DualUI.Size = DualUI.Size(20, 5))::ServerConfig =
    ServerConfig(host, port, multi_session, session_timeout,
                 reap_interval, max_sessions, String(title),
                 default_size, min_size)

"""
W5. The listener, the session table and the reaper.

`factory::F` is `() -> DualUI.Widget`, PARAMETRIC (a concrete field, no
boxed closure), and it IS the isolation primitive: one call per
connection yields a fresh widget tree, which yields a fresh App,
Channel, Buffer pair and Task.

`() -> Widget`, NOT `(driver) -> App`: user application code must never
name a driver type. The SAME factory feeds
`App(factory(), TerminalDriver())` and `serve(factory)`.
"""
mutable struct WebServer{F}
    "Called once per session; returns a fresh widget tree."
    const factory::F
    "Shared, immutable."
    const stylesheet::DualUI.Stylesheet
    "Shared, immutable."
    const config::ServerConfig
    "Session id to session. Guarded by `lock`."
    const sessions::Dict{String,Session}
    "Guards `sessions`, `server` and `reaper`."
    const lock::ReentrantLock
    "The HTTP listener, once started."
    server::Union{Nothing,HTTP.Server}
    "The reap sweep task."
    reaper::Union{Nothing,Task}
    "False once stopped."
    running::Bool
end

"""
A server over `factory`, not yet listening.
"""
WebServer(factory::F;
          stylesheet::DualUI.Stylesheet = DualUI.STYLESHEET_EMPTY,
          config::ServerConfig = ServerConfig()) where {F} =
    WebServer{F}(factory, stylesheet, config, Dict{String,Session}(),
                 ReentrantLock(), nothing, nothing, false)

"""
W1 / req 2.4. Non-blocking: spawn the async HTTP server task and the
reaper, then return `s` while both keep running. Idempotent -- a second
call on a listening server binds nothing.

Throws `PortInUseError` when `config.port` is taken.
"""
function DualUI.start!(s::WebServer)::WebServer
    started = Base.@lock s.lock begin
        if s.server === nothing
            # `_bind` throws BEFORE anything is mutated, so a refused
            # port leaves `s` exactly as it was: still stoppable, still
            # restartable on another port.
            listener = _bind(s.config)
            s.server = HTTP.listen!(http -> _serve_stream(s, http),
                                    listener; verbose = -1)
            s.running = true
            true
        else
            false
        end
    end
    started || return s
    # Single-session mode owns exactly one App, built up front so the
    # first client attaches to a tree that already exists.
    s.config.multi_session || create_session!(s)
    Base.@lock s.lock begin
        s.reaper = Threads.@spawn _reaper_loop!(s)
    end
    return s
end

"""
Open the listening socket, turning a bind refusal into a sentence.

`port == 0` routes through libuv's `listenany`, which is what makes the
OS-assigned port readable afterwards via `bound_port`. Internal.
"""
function _bind(cfg::ServerConfig)::HTTP.Servers.Listener
    try
        return HTTP.Servers.Listener(cfg.host, cfg.port;
                                     listenany = cfg.port == 0,
                                     verbose = -1)
    catch e
        _is_addr_in_use(e) && throw(PortInUseError(cfg.host, cfg.port))
        rethrow()
    end
end

"""
True when `e` is libuv's "address already in use".

Matched on the errno rather than on the message text, which is libuv's
to reword. Every other bind failure -- a privileged port, a bad
interface -- keeps its own error, because only this one has advice worth
giving. Internal.
"""
_is_addr_in_use(e)::Bool =
    e isa Base.IOError && e.code == Base.UV_EADDRINUSE

"""
W1 / req 2.4. Build a server over `factory` and start listening.

Non-blocking: it returns the live `WebServer` handle, so the caller can
inspect it, `stop!` it, or `wait(s)` to block on purpose.

    s = serve(() -> MyRoot(); port = 8000, stylesheet = MY_CSS)
    ...
    stop!(s)
"""
serve(factory; host = Sockets.localhost, port::Int = 8000,
      stylesheet::DualUI.Stylesheet = DualUI.STYLESHEET_EMPTY,
      kwargs...)::WebServer =
    serve(factory, ServerConfig(; host = host, port = port, kwargs...);
          stylesheet = stylesheet)

"""
W1 / req 2.4. Start a server over a prebuilt config. Non-blocking.
"""
serve(factory, cfg::ServerConfig;
      stylesheet::DualUI.Stylesheet = DualUI.STYLESHEET_EMPTY)::WebServer =
    DualUI.start!(WebServer(factory; stylesheet = stylesheet,
                            config = cfg))

"""
Terminate every session, then close the listener and release the port.

Idempotent, and never throws: it runs from `finally` blocks that cannot
know whether it already ran. Sessions are terminated OUTSIDE `s.lock` --
`terminate!` waits on a session task, and a task that is mid-`reap!`
would deadlock against a held lock.
"""
function DualUI.stop!(s::WebServer)::Nothing
    Base.@lock s.lock begin
        s.running = false
    end
    for sess in sessions(s)
        kill_session!(s, sess)
    end
    srv, reaper = Base.@lock s.lock begin
        (s.server, s.reaper)
    end
    if srv !== nothing
        try
            # `forceclose` closes the listener FIRST -- that is what
            # frees the port -- then drops the connections and waits for
            # the accept loop. Graceful `close` would instead wait for
            # every connection to finish, and a WebSocket parked on a
            # read never does.
            HTTP.forceclose(srv)
        catch
            # A listener already torn down by its own task is not a
            # failure worth propagating out of teardown.
        end
    end
    reaper === nothing || _await(reaper, STOP_TIMEOUT)
    Base.@lock s.lock begin
        s.server = nothing
        s.reaper = nothing
    end
    return nothing
end

"""
Forward to `stop!`.
"""
Base.close(s::WebServer)::Nothing = DualUI.stop!(s)

"""
Block until the listener has finished. Returns immediately when the
server was never started.
"""
function Base.wait(s::WebServer)::Nothing
    srv = Base.@lock s.lock (s.server)
    srv === nothing && return nothing
    try
        wait(srv)
    catch
        # A listener that ended by being closed is a normal shutdown,
        # not something to raise at whoever was waiting on it.
    end
    return nothing
end

"""
True while the listener is up.
"""
Base.isopen(s::WebServer)::Bool = Base.@lock s.lock begin
    s.server !== nothing && isopen(s.server)
end

"""
A snapshot of the live sessions. Safe to iterate while clients come and
go: it is a copy, not a view onto the table.
"""
sessions(s::WebServer)::Vector{Session} =
    Base.@lock s.lock collect(values(s.sessions))

"""
The port actually bound, which is what `port = 0` makes worth asking
for: the OS picks, and this reports its choice. Falls back to the
configured port while the server is not listening.
"""
function bound_port(s::WebServer)::Int
    srv = Base.@lock s.lock (s.server)
    return srv === nothing ? s.config.port : HTTP.Servers.port(srv)
end

"""
The URL the server is reachable at, with the port it actually bound.
"""
url(s::WebServer)::String =
    string("http://", _host_string(s.config.host), ":", bound_port(s),
           "/")

"""
An IP address as it appears in a URL authority: IPv6 must be bracketed
or the port cannot be told from the address. Pure. Internal.
"""
_host_string(h::Sockets.IPAddr)::String =
    h isa Sockets.IPv6 ? string("[", h, "]") : string(h)

"""
The route table, for callers that would rather compose than dispatch.
Every route funnels into `handle_http`, which stays the one description
of what this server answers.
"""
function router(s::WebServer)::HTTP.Router
    r = HTTP.Router()
    HTTP.register!(r, "GET", "/**", req -> handle_http(s, req))
    return r
end

"""
W2. Serve the static bundle:

    GET /, /index.html      -> index_html(cfg)
    GET /xterm.js           -> XTERM_JS
    GET /xterm.css          -> XTERM_CSS
    GET /xterm-addon-fit.js -> XTERM_FIT_JS
    GET /healthz            -> session count, JSON
    *                       -> 404

Routing is an exact lookup against a table baked at precompile -- never
a path joined onto a directory -- so no request can reach a file the
bundle does not name, however many `..` it carries.
"""
function handle_http(s::WebServer, req::HTTP.Request)::HTTP.Response
    req.method == "GET" ||
        return HTTP.Response(405, ["Allow" => "GET",
                                   "Content-Type" => "text/plain"],
                             "method not allowed")
    path = _request_path(req)
    if path == "/" || path == "/index.html"
        return HTTP.Response(200,
                             ["Content-Type" => "text/html; charset=utf-8"],
                             index_html(s.config))
    elseif path == "/healthz"
        return HTTP.Response(200,
                             ["Content-Type" => "application/json"],
                             _healthz(s))
    elseif haskey(ASSETS, path)
        mime, body = ASSETS[path]
        return HTTP.Response(200, ["Content-Type" => mime], body)
    end
    return HTTP.Response(404, ["Content-Type" => "text/plain"],
                         "not found")
end

"""
The request target with its query string dropped: `/ws?session=ab`
routes as `/ws`. Pure. Internal.
"""
_request_path(req::HTTP.Request)::String =
    String(HTTP.URI(req.target).path)

"""
The health probe body: what an operator or a load balancer needs to know
without opening a session. Internal.
"""
_healthz(s::WebServer)::String =
    JSON3.write((sessions = length(sessions(s)),
                 max_sessions = s.config.max_sessions,
                 multi_session = s.config.multi_session))

"""
The one HTTP entry point: upgrade `/ws`, serve everything else.

`handle_http` is kept pure -- request in, response out -- so the whole
route table is testable without a socket; this is the only place that
touches the stream. Internal.
"""
function _serve_stream(s::WebServer, http::HTTP.Stream)::Nothing
    req = http.message
    if HTTP.WebSockets.isupgrade(req) && _request_path(req) == WS_PATH
        HTTP.WebSockets.upgrade(ws -> handle_ws(s, ws), http;
                                suppress_close_error = true)
        return nothing
    end
    req.body = read(http)
    r = handle_http(s, req)
    HTTP.setstatus(http, r.status)
    for (k, v) in r.headers
        HTTP.setheader(http, k => v)
    end
    HTTP.setheader(http, "Content-Length" => string(length(r.body)))
    HTTP.startwrite(http)
    write(http, r.body)
    return nothing
end

"""
W4 + X4. The socket lifetime.

The `finally` NEVER kills -- a drop is always a pause. Only `reap!`
kills, and only on timeout (X5). That split is the difference between
"reconnect works" and "reconnect works when the network is polite".
"""
function handle_ws(s::WebServer, ws)::Nothing
    hello = _read_hello(s, ws)
    sess = _acquire!(s, hello.session)
    sess === nothing && return nothing
    # Single-session takeover, and stale-socket reattach, are the same
    # move: whatever was attached loses the seat to the newcomer.
    state(sess) === SessionState.RUNNING && detach!(sess)
    attach!(sess, ws, hello)
    try
        for msg in ws
            if msg isa String
                handle_control!(sess.driver, msg)   # resize / ping
            else
                DualUI.feed_bytes!(sess.driver, msg)   # W4
            end
            sess.last_seen = time()
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError || rethrow()
    finally
        detach!(sess)   # X4: pause + preserve. NEVER kills.
    end
    return nothing
end

"""
Read the client's opening HELLO, or fall back to the configured default
size.

Bounded by `HELLO_TIMEOUT`: a socket that upgrades and then says nothing
is a task and a file descriptor held hostage, so the watchdog closes it
and the read fails out rather than parking forever. Internal.
"""
function _read_hello(s::WebServer, ws)::ControlMessage
    fallback = ControlMessage(ControlKind.HELLO;
                              width = s.config.default_size.width,
                              height = s.config.default_size.height)
    watchdog = Timer(_ -> _close_quietly(ws), HELLO_TIMEOUT)
    try
        msg = HTTP.WebSockets.receive(ws)
        msg isa String || return fallback
        hello = decode_control(msg)
        hello === nothing && return fallback
        hello.kind === ControlKind.HELLO || return fallback
        return hello
    catch
        # A hostile or merely broken client must not be able to take the
        # accept loop down with a bad first frame.
        return fallback
    finally
        close(watchdog)
    end
end

"""
Close `x`, swallowing whatever it thinks of that. Internal.
"""
function _close_quietly(x)::Nothing
    try
        close(x)
    catch
        # Teardown paths close things that may already be gone.
    end
    return nothing
end

"""
Get-or-create the session this connection belongs to; `nothing` when the
server is full and the client should be turned away.

Single-session mode ignores the requested id entirely: there is one App,
and every connection lands on it. Internal.
"""
function _acquire!(s::WebServer, id::AbstractString)::Union{Nothing,Session}
    if !s.config.multi_session
        existing = Base.@lock s.lock begin
            isempty(s.sessions) ? nothing : first(values(s.sessions))
        end
        existing === nothing || return existing
        return create_session!(s)
    end
    if !isempty(id)
        # X4's server half: a reconnecting client names the session it
        # left, and gets its state back rather than a fresh tree.
        sess = get_session(s, id)
        if sess !== nothing && isopen(sess)
            return sess
        end
    end
    return create_session!(s)
end

"""
W5. Fresh tree, fresh App, fresh everything. `nothing` when at
`max_sessions`.
"""
create_session!(s::WebServer)::Union{Nothing,Session} =
    Base.@lock s.lock begin
        if length(s.sessions) >= s.config.max_sessions
            nothing
        else
            id = _new_session_id(s)
            sess = Session(id, s.factory, s.stylesheet, s.config)
            s.sessions[id] = sess
            sess
        end
    end

"""
A session id no live session already holds. Called under `s.lock`.
Internal.
"""
function _new_session_id(s::WebServer)::String
    id = _random_hex()
    while haskey(s.sessions, id)
        id = _random_hex()
    end
    return id
end

"""
The OS entropy pool.
"""
const URANDOM = "/dev/urandom"

"""
32 hex characters of entropy.

A session id is a bearer token: guess it and you get someone else's
App, so it has to come from a cryptographic source rather than the
task-local RNG, whose state is recoverable from its own output.
`Random.RandomDevice` is the tool for that, but `Random` is not in
`DualUIWeb`'s `[deps]` and `Project.toml` is not this file's to edit, so
the OS entropy pool is read directly -- which is what `RandomDevice`
does on this platform anyway. Internal.
"""
function _random_hex()::String
    bytes = Vector{UInt8}(undef, 16)
    open(URANDOM, "r") do io
        read!(io, bytes)
    end
    return bytes2hex(bytes)
end

"""
The session with `id`, or `nothing`.
"""
get_session(s::WebServer,
            id::AbstractString)::Union{Nothing,Session} =
    Base.@lock s.lock get(s.sessions, String(id), nothing)

"""
Terminate `sess` and drop it from the table.
"""
function kill_session!(s::WebServer, sess::Session)::Nothing
    Base.@lock s.lock begin
        delete!(s.sessions, sess.id)
    end
    _terminate_quietly!(sess)
    return nothing
end

"""
X5. Kill every session with `is_expired(sess, config.session_timeout,
now)`; returns the count reaped.

Calls `GC.gc(false)` ONCE per non-empty batch -- never per session, as a
full GC per reap would be a self-inflicted pause.

`now` is INJECTED: the whole timeout policy is unit-testable without a
single sleep.
"""
function reap!(s::WebServer, now::Float64 = time())::Int
    doomed = Base.@lock s.lock begin
        expired = Session[]
        for sess in values(s.sessions)
            is_expired(sess, s.config.session_timeout, now) &&
                push!(expired, sess)
        end
        for sess in expired
            delete!(s.sessions, sess.id)
        end
        expired
    end
    isempty(doomed) && return 0
    for sess in doomed
        _terminate_quietly!(sess)
    end
    GC.gc(false)
    return length(doomed)
end

"""
Terminate `sess`, swallowing whatever it throws on the way out: one
stubborn session must not stop the sweep from reaping the rest of the
batch. Internal.
"""
function _terminate_quietly!(sess::Session)::Nothing
    try
        terminate!(sess)
    catch
        # A session that will not die politely is still leaving.
    end
    return nothing
end

"""
Sweep every `config.reap_interval` seconds until the server stops.
Internal.
"""
function _reaper_loop!(s::WebServer)::Nothing
    while s.running
        _idle_until(s, time() + s.config.reap_interval)
        s.running || break
        try
            reap!(s)
        catch
            # A failed sweep is not a reason to stop sweeping.
        end
    end
    return nothing
end

"""
Sleep towards `deadline` in `REAP_TICK` slices, so a `stop!` mid-interval
is noticed in a tick rather than in a whole `reap_interval`. Internal.
"""
function _idle_until(s::WebServer, deadline::Float64)::Nothing
    while s.running
        left = deadline - time()
        left > 0 || break
        sleep(min(REAP_TICK, left))
    end
    return nothing
end

"""
Wait for `t` for at most `timeout` seconds. Returns true when it
finished. Teardown must be bounded: a task that will not end must not
turn `stop!` into a hang. Internal.
"""
function _await(t::Task, timeout::Float64)::Bool
    deadline = time() + timeout
    while !istaskdone(t) && time() < deadline
        sleep(REAP_TICK)
    end
    return istaskdone(t)
end
