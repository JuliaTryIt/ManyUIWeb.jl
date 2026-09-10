# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **A `StatusBar` reached the browser as an empty node.** The same shape as the
  tab strip below: its content lives in `left`, `center` and `right`, not in
  children, so the generic container branch had nothing to walk. The three slots
  are now emitted as cells and laid out with `space-between`, which is what the
  terminal backend achieves by padding.

  Found by rebuilding the KaimonSlateDesktop status panel
  (`ManyUIDemos/demos/slate_status.jl`), whose footer simply vanished.

  Worth naming as a class of defect rather than two incidents: **a widget whose
  content lives in fields rather than in children is invisible to the WebNative
  backend** unless it has its own branch.

- **A widget's class was emitted twice.** `manyui-<type>` is pushed for every
  widget from `node.type_name`, and the `DataTable` branch pushed
  `manyui-datatable` again, producing
  `class="manyui-datatable manyui-datatable"`.

- **A `TabStrip` reached the browser as an empty box.** Its captions live in
  `titles`, not as children, so the generic container branch of `to_html` had
  nothing to walk and emitted a blank rounded rectangle. The monitor demo — the
  rebuild of Kaimon's Server tab — showed three of them where
  `1 Server | 2 Sessions | 3 Activity` belongs.

  The strip now projects each caption as a clickable `.manyui-tab`, marks the
  chosen one `.manyui-tab-selected`, and dispatches `change` on click, as the
  terminal backend does. The captions stay `RichText`, so the shortcut digit
  keeps its own colour inside the caption — which is the reason `titles` are
  `RichText` at all (ROADMAP §10.1).

  A stylesheet rule lays the strip out as a row and gives the chosen tab a
  visible state; without it the tabs inherited the container's column direction
  and stacked vertically.

  Found by rendering a real screen rather than by a unit test, which is the
  argument ROADMAP §10 makes for building screens.


### Changed (breaking)

- ManyUIWeb now requires HTTP.jl 2 instead of retaining HTTP.jl 1 support.
- JSON3.jl has been replaced by JSON.jl 1, its officially recommended
  successor.

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

- Render ZWJ emoji sequences as one glyph in the browser terminal.
  xterm.js measured codepoints rather than grapheme clusters, so
  👨‍👩‍👧‍👦 was drawn as four one-cell characters overlapping each other on
  the grid. The Unicode-graphemes and ligatures addons are now loaded
  (version- and integrity-pinned like every other subresource), the
  font stack puts a colour emoji face first, and the canvas renderer is
  no longer used -- it splits ZWJ sequences, while the DOM renderer
  emits spans the browser composes correctly.
- Server listeners disable address reuse on Windows, where Winsock otherwise
  permits two HTTP servers to bind the same port instead of reporting it busy.
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
