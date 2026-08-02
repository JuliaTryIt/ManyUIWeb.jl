# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

- WebNative DOM events now mirror the Julia callback vocabulary exactly:
  buttons dispatch `click`, selections dispatch `change`, activation
  dispatches `submit`, and focus transitions dispatch `focus`/`blur`.
  Selection changes no longer double-fire callbacks or implicitly submit.

- The transport is now framework-neutral. The server, the WebSocket loop
  and the reaper are driven through two new interfaces -- `AbstractSession`
  (one connected client's app instance) and `AbstractFrontend` (mints one
  session per connection via `make_session`) -- and name no UI framework.
  ManyUI is now one frontend: `serve` builds a `ManyUIFrontend`, and the
  existing `Session`/`WebSocketDriver` are its session. A second frontend
  (Tachikoma) ships as a package extension.
- `WebServer` is parametric in its frontend (`WebServer{<:AbstractFrontend}`),
  not in a widget factory. It no longer has `factory` or `stylesheet`
  fields; those moved onto `ManyUIFrontend`. `WebServer(factory; stylesheet)`
  still works and now wraps them in a `ManyUIFrontend`, so `serve` is
  unchanged.
- `handle_control!(::WebSocketDriver, ...)` gained a `ControlMessage`
  method; the transport decodes each text frame once and hands the frontend
  a decoded message rather than JSON.

### Added

- A WebNative HTML/DOM projection with WebSocket updates and HTTP polling
  fallback. It renders the core interactive widgets, preserves browser focus,
  and routes `on_click`, `on_change`, `on_submit`, `on_focus`, and `on_blur`
  back to their Julia widgets.

- A Tachikoma frontend, as a package extension (`ManyUIWebTachikomaExt`,
  loaded when Tachikoma is present). `serve_tachikoma(() -> model; port)`
  runs a Tachikoma Model/view/update app in the browser over this
  transport, input and all. Needs a Tachikoma that accepts an `io=` sink
  (Tachikoma PR #39). Single-session (Tachikoma's process-global terminal
  I/O); resize is handled live so the app tracks the browser's size. See
  `examples/tachikoma_web.jl`.
- `WebBackend`, the browser as a `ManyUI.Backend`. The same app now runs on
  either target with the backend as the only difference:
  `launch(ui; backend = WebBackend(port = 8000))`. It wraps a
  `ServerConfig`, so every `serve` keyword works and means the same thing.
  `launch` blocks and absorbs Ctrl-C -- the `try`/`wait`/`finally stop!`
  boilerplate every example wrote by hand -- or returns the live
  `WebServer` with `wait = false`.
- `ServerConfig` carries an `app::AppConfig`, threaded into every session.
  The `AppConfig` knobs with no `ServerConfig` twin -- `diff_gap`,
  `esc_timeout`, `sync_frames` -- were previously unreachable through
  `serve`. `ServerConfig(; title, min_size)` keeps working and keeps its
  meaning; an explicit `app` wins over both.

### Fixed

- `WebNativeServer` now implements `Base.isopen`, completing the common
  `isopen`/`close`/`wait` launch-handle contract used by every backend.
- WebNative now emits valid JavaScript for its `morphdom` update path. The
  malformed call previously stopped the entire browser script, preventing
  interactions such as text `on_change` and button `on_click` callbacks.
- Session ids are drawn from `Random.RandomDevice()` rather than by
  reading `/dev/urandom` by hand. That path does not exist on Windows, so
  every session id draw threw `SystemError` there and no session could be
  created at all. `RandomDevice` is the OS CSPRNG on every platform;
  entropy and the bearer-token property are unchanged.
- Socket tests allow for cold-start compilation. The first HTTP testitem to
  run also pays for compiling the server-side request path, which exceeds
  5s on a cold Windows runner while every later request answers in well
  under a second.
