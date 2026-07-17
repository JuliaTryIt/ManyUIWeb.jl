# session.jl -- W3. One fully independent application instance.

"""
Where a session is in its life. Only a `PAUSED` session can expire.
"""
module SessionState
@enum T::UInt8 begin
    NEW = 0
    RUNNING = 1  # socket attached, loop live
    PAUSED = 2   # socket dropped, state preserved, reap clock running
    CLOSING = 3
    DEAD = 4
end
end

"""
One fully independent application instance: its own App, event loop,
driver and widget tree. Sessions share NOTHING but the immutable
`Stylesheet` and `ServerConfig`.

`DualUI.App{WebSocketDriver}` is fully CONCRETE -- the per-session
render loop is as type-stable over a WebSocket as over a TTY. That is
the parametric `App{D}` decision paying off across a package boundary.
"""
mutable struct Session
    "32 hex chars from a cryptographic RNG."
    const id::String
    "This session's driver; nothing is shared."
    const driver::WebSocketDriver
    "This session's app; note the concrete parameter."
    const app::DualUI.App{WebSocketDriver}
    "Where the session is in its life."
    state::SessionState.T
    "The task running `DualUI.run!`."
    task::Union{Nothing,Task}
    "X5. Stamp of the last client contact; the reap clock."
    last_seen::Float64
    "Stamp of creation."
    const created::Float64
end

"""
Seconds `terminate!` waits for a session's loop to unwind before it
gives up and declares the session dead anyway.
"""
const TERMINATE_DEADLINE = 5.0

# NOTE (contract defect, scaffold): `ServerConfig` is defined in
# server.jl, which the normative include order places AFTER this file,
# so `config` cannot carry its type annotation here. It is a
# `ServerConfig`.
"""
W5. Build a session. `factory` is `() -> DualUI.Widget` and is called
ONCE, here: a fresh tree per session, nothing captured, nothing
shared.
"""
function Session(id::AbstractString, factory,
                 stylesheet::DualUI.Stylesheet,
                 config)::Session
    driver = WebSocketDriver(; size = config.default_size)
    # ONE call, and it is the whole isolation story: a fresh tree yields
    # a fresh App, Channel, Buffer pair and Task.
    root = factory()::DualUI.Widget
    # `config.app` is the whole AppConfig, not a two-field copy of it:
    # building one here from `min_size`/`title` alone silently dropped
    # `diff_gap`, `esc_timeout` and `sync_frames` on every session.
    app = DualUI.App(root, driver;
                     config = config.app,
                     stylesheet = stylesheet)
    now = time()
    return Session(String(id), driver, app, SessionState.NEW, nothing,
                   now, now)
end

"""
Where `s` is in its life. Pure.
"""
state(s::Session)::SessionState.T = s.state

"""
Seconds since `s` was created. Pure in `now`. Pure.
"""
age(s::Session, now::Float64 = time())::Float64 = now - s.created

"""
Seconds since the last client contact. Pure in `now`. Pure.
"""
idle(s::Session, now::Float64 = time())::Float64 = now - s.last_seen

"""
True while `s` is neither closing nor dead.
"""
Base.isopen(s::Session)::Bool =
    s.state !== SessionState.CLOSING && s.state !== SessionState.DEAD

"""
Attach or REATTACH a socket.

On reattach: `DualUI.resume!(sess.app)` (which implies `invalidate!`)
AND `DualUI.post!(app, RefreshEvent())`, so the reconnected client
receives ONE full frame and is instantly consistent -- no replay log.
Also `empty!(driver.parser)`: a half-parsed CSI from before the drop
would corrupt the first keystroke after reconnect.
"""
function attach!(s::Session, ws::HTTP.WebSockets.WebSocket,
                 hello::ControlMessage)::Nothing
    isopen(s) || return nothing
    empty!(s.driver.parser)
    attach!(s.driver, ws, hello)
    if s.state === SessionState.NEW
        # First client: bring the loop up. `run!` calls `start!` on the
        # driver itself, so the size_hint from HELLO is already in.
        s.task = DualUI.start!(s.app)
    else
        # The reconnected client's screen is blank, so the diff baseline
        # must be reset. `resume!` implies `invalidate!`; the explicit
        # RefreshEvent is what wakes a loop parked on `take!`.
        DualUI.resume!(s.app)
        DualUI.post!(s.app, DualUI.RefreshEvent())
    end
    s.state = SessionState.RUNNING
    s.last_seen = time()
    return nothing
end

"""
X4. The socket dropped: `detach!(s.driver)`, `DualUI.pause!(s.app)`,
`state = PAUSED`, stamp `last_seen`.

The App, its tree and its state stay RESIDENT. NEVER kills.
"""
function detach!(s::Session)::Nothing
    isopen(s) || return nothing
    detach!(s.driver)
    DualUI.pause!(s.app)
    s.state = SessionState.PAUSED
    s.last_seen = time()
    return nothing
end

"""
X5. `DualUI.quit!`, close the driver and channels, `wait(task)` with a
deadline, `state = DEAD`.

`deadline` is injectable so the suite never waits seconds for a
shutdown; the default is `TERMINATE_DEADLINE`.
"""
function terminate!(s::Session;
                    deadline::Float64 = TERMINATE_DEADLINE)::Nothing
    s.state === SessionState.DEAD && return nothing
    s.state = SessionState.CLOSING
    # Ask the loop to leave on its own terms, but NEVER wait on the ask:
    # a PAUSED session's channel can be full, and `post!` blocks on a
    # full channel, which would wedge the reaper on exactly the path X5
    # exists to serve. The `stop!` below closes the channel, which both
    # ends `_loop!` and unblocks this `put!` (as an InvalidStateException
    # that `post!` swallows).
    @async DualUI.quit!(s.app)
    # The floor comes out from under it regardless: `stop!` closes the
    # event channel, which ends `_loop!` even if the QuitEvent never
    # lands.
    DualUI.stop!(s.driver)
    t = s.task
    if t !== nothing
        # Bounded: a wedged loop must not wedge the reaper.
        timedwait(() -> istaskdone(t), deadline; pollint = 0.001)
    end
    s.task = nothing
    s.state = SessionState.DEAD
    return nothing
end

"""
X5. The reap policy, as a total function of the four things that decide
it. No clock, no socket, no server. Pure. Internal.

Only a `PAUSED` session can expire: a live session is never reaped,
however long ago its `last_seen` was stamped.
"""
_is_expired(st::SessionState.T, last_seen::Float64, timeout::Float64,
            now::Float64)::Bool =
    st === SessionState.PAUSED && (now - last_seen) >= timeout

"""
X5. A PURE predicate over `(state, last_seen, timeout, now)`. The whole
reap policy is unit-testable with no clock, no socket, no server:

    is_expired(s, 300.0, s.last_seen + 301.0) === true

Only a PAUSED session can expire.
"""
is_expired(s::Session, timeout::Float64, now::Float64 = time())::Bool =
    _is_expired(s.state, s.last_seen, timeout, now)
