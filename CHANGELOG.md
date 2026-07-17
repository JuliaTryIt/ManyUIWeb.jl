# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `WebBackend`, the browser as a `DualUI.Backend`. The same app now runs on
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

- Session ids are drawn from `Random.RandomDevice()` rather than by
  reading `/dev/urandom` by hand. That path does not exist on Windows, so
  every session id draw threw `SystemError` there and no session could be
  created at all. `RandomDevice` is the OS CSPRNG on every platform;
  entropy and the bearer-token property are unchanged.
- Socket tests allow for cold-start compilation. The first HTTP testitem to
  run also pays for compiling the server-side request path, which exceeds
  5s on a cold Windows runner while every later request answers in well
  under a second.
