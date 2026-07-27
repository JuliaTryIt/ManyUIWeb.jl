# ManyUIWeb.jl

The web bridge for [`ManyUI`](https://github.com/s-celles/ManyUI.jl): run the exact same
application in a browser instead of a terminal, with no change to the
widget tree or the application logic.

`ManyUIWeb` provides two distinct Web projections:

### 1. `WebTerminal` (Terminal Emulation)
Pipes the terminal ANSI byte stream into a `WebSocketDriver` and renders it via `xterm.js` in the browser.
This gives you a perfect 1-to-1 web clone of the Terminal UI.

### 2. `WebNative` (Native DOM)
Compiles the `ManyUI.Widget` tree recursively into semantic HTML tags (`<div>`, `<button>`, `<span>`) and serves it over HTTP. Events (like clicks) are sent back to the Julia backend via `fetch` requests, triggering state updates that instantly re-render the DOM.
This provides a modern, semantic web experience out of the box, styled with CSS.

## Quickstart

```julia
using ManyUI, ManyUIWeb

# Define your model and actions...
model = MyModel()

# To serve as a WebTerminal:
ManyUI.launch(model, WebTerminal(); port = 8000)

# To serve as a Native Web App:
ManyUI.launch(model, WebNative(); port = 8080)
```

## How it works

### WebTerminal
`ManyUIWeb` implements a `WebSocketDriver <: ManyUI.Driver`.
It offloads the terminal-rendering step to a JavaScript terminal emulator in the client:
* the ANSI byte stream ManyUI already produces is piped verbatim into the WebSocket as **binary** frames.
* keystrokes and mouse events come back as **binary** frames.
* resize and handshake travel as **text** JSON control frames.

### WebNative
`WebNative` does not use the `Driver` abstraction. Instead, it hooks directly into the `ManyUI.launch` mechanism, serializing the `ManyUI.Widget` component tree (e.g. `Container`, `Label`, `Button`) into HTML strings. 
It spins up a lightweight HTTP server using `HTTP.jl` that:
* Serves the HTML DOM on `GET /`
* Handles interactions on `POST /dispatch` by dynamically finding the widget in the tree and executing its `on_press` callback.

## Tests

```julia
julia --project=ManyUIWeb -e 'using Pkg; Pkg.test()'
```
