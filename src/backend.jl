# backend.jl -- WebBackend: the browser, as a ManyUI Backend.
#
# This file is the out-of-tree half of ManyUI's `launch` seam, and it is
# deliberately small. ManyUI knows nothing about it. It joins by defining
# one type and one method, from another package, with no cooperation from
# ManyUI beyond the abstract type -- which is the same claim
# `WebSocketDriver` makes about the `Driver` seam, one level up.
#
# It does NOT define `make_driver`. That method is for backends that have
# ONE driver; a web server has one per browser, minted inside `Session`
# when a client says HELLO, and it cannot know how many it needs until
# they arrive. So this overrides `launch` itself, which is exactly the
# escape hatch ManyUI's Backend docstring names for multiplexing targets.

"""
The browser, as a `ManyUI.Backend`.

Wraps a [`ServerConfig`](@ref), so every `serve` keyword works here and
means the same thing:

    launch(ui; backend = WebBackend(port = 8000))

Unlike a terminal, this target multiplexes: each browser that connects
gets its OWN app, built by calling the factory again. That is why a
`WebBackend` defines no `make_driver` -- there is no single driver to make.
"""
struct WebBackend <: ManyUI.Backend
    "The transport. Every `serve` keyword lives here."
    config::ServerConfig
end

"""
$(SIGNATURES)

A [`WebBackend`](@ref). Keywords are [`ServerConfig`](@ref)'s.

`min_size` and `title` are accepted for symmetry with `serve`, but prefer
`launch`'s `config::AppConfig` -- it reaches every app knob, not just those
two, and it is spelled the same way on every backend.
"""
WebBackend(; kwargs...)::WebBackend = WebBackend(ServerConfig(; kwargs...))

"""
$(SIGNATURES)

Serve `factory` in a browser.

Overrides the single-driver `ManyUI.launch` path because the web
multiplexes: `factory` is called once PER SESSION, not once here.

`config` describes the app and is threaded into every session, so the same
`AppConfig` that a terminal `launch` takes works unchanged. It overrides
any `title`/`min_size` already on the backend's `ServerConfig` -- app
config is the app's, whichever backend is carrying it.

With `wait = true` this blocks until the server stops, absorbing Ctrl-C
the way the examples do by hand, and always stops the server on the way
out. Returns `0`. With `wait = false` it returns the live
[`WebServer`](@ref), which answers `isopen`/`close`/`wait` like any other
`launch` handle.
"""
function ManyUI.launch(factory, backend::WebBackend;
                       config::Union{Nothing,ManyUI.AppConfig} = nothing,
                       stylesheet::ManyUI.Stylesheet = ManyUI.STYLESHEET_EMPTY,
                       wait::Bool = true)
    cfg = config === nothing ? backend.config :
          _with_app_config(backend.config, config)
    server = serve(factory, cfg; stylesheet = stylesheet)
    wait || return server
    try
        Base.wait(server)
    catch e
        # Ctrl-C at a served app is how you stop it, not a crash. Every
        # example wrote this by hand; `launch` owes them it.
        e isa InterruptException || rethrow()
    finally
        ManyUI.stop!(server)
    end
    return 0
end

"""
$(SIGNATURES)

`cfg` with its app config replaced by `app`. Internal.
"""
_with_app_config(cfg::ServerConfig, app::ManyUI.AppConfig)::ServerConfig =
    ServerConfig(; host = cfg.host, port = cfg.port,
                   multi_session = cfg.multi_session,
                   session_timeout = cfg.session_timeout,
                   reap_interval = cfg.reap_interval,
                   max_sessions = cfg.max_sessions,
                   title = cfg.title,
                   default_size = cfg.default_size,
                   min_size = cfg.min_size,
                   app = app)

"""
$(SIGNATURES)

Declarative entry point: launch a generic application `model` onto a `WebTerminal` Projection.
It automatically sets up the factory to render the widget tree per session.
"""
function ManyUI.launch(model, proj::ManyUI.WebTerminal; kwargs...)
    factory = () -> ManyUI.render(model, proj)
    return ManyUI.launch(factory, WebBackend(); kwargs...)
end
