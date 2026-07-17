# assets_tests.jl -- W4 / EARS 2.4.
#
# The root URL must serve a static HTML/JS bundle carrying a terminal
# emulator and a WebSocket client. These tests pin that bundle's shape:
# non-empty, an xterm mount point, the WS bootstrap, and honest MIME
# types.
#
# `ServerConfig` is built POSITIONALLY on purpose: the keyword
# constructor is server.jl's to implement, and these tests must not fail
# on another file's TODO.

@testitem "Assets: index_html is non-empty and mounts xterm" begin
    using DualUIWeb
    import Sockets
    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "DualUI",
                                 DualUIWeb.DualUI.Size(80, 24),
                                 DualUIWeb.DualUI.Size(20, 5))
    html = DualUIWeb.index_html(cfg)

    @test html isa String
    @test !isempty(html)
    @test length(html) > 500

    # A real document, not a fragment.
    @test occursin("<!DOCTYPE html>", html)
    @test occursin("</html>", html)

    # The mount point the client attaches the Terminal to.
    @test occursin(DualUIWeb.TERMINAL_MOUNT_ID, html)
    @test occursin("id=\"$(DualUIWeb.TERMINAL_MOUNT_ID)\"", html)

    # xterm.js itself, and the addon that reports cols/rows.
    @test occursin("new Terminal(", html)
    @test occursin(".open(", html)
    @test occursin("FitAddon", html)
    @test occursin("loadAddon", html)

    # The contract's Terminal options.
    @test occursin("allowProposedApi", html)
    @test occursin("convertEol", html)
end

@testitem "Assets: index_html carries the WebSocket bootstrap" begin
    using DualUIWeb
    import Sockets
    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "DualUI",
                                 DualUIWeb.DualUI.Size(80, 24),
                                 DualUIWeb.DualUI.Size(20, 5))
    html = DualUIWeb.index_html(cfg)

    # A WebSocket client, pointed at the server's own path.
    @test occursin("new WebSocket(", html)
    @test occursin(DualUIWeb.WS_PATH, html)
    @test occursin("location.host", html)

    # Same-host scheme selection, never a hardcoded ws://.
    @test occursin("wss://", html)
    @test occursin("ws://", html)

    # Frames arrive as bytes and go straight into the terminal.
    @test occursin("binaryType", html)
    @test occursin("arraybuffer", html)
    @test occursin("Uint8Array", html)
    @test occursin(".write(", html)

    # Keystrokes and SGR mouse reports go back as binary ANSI bytes.
    @test occursin("onData", html)
    @test occursin("onBinary", html)
    @test occursin("TextEncoder", html)

    # The size handshake: hello before the first frame, then resizes.
    @test occursin("\"hello\"", html) || occursin("'hello'", html)
    @test occursin("\"resize\"", html) || occursin("'resize'", html)
    @test occursin("onresize", html) || occursin("resize\"", html) ||
          occursin("ResizeObserver", html)
    @test occursin("cols", html)
    @test occursin("rows", html)
end

@testitem "Assets: index_html reconnects with a notice and backoff" begin
    using DualUIWeb
    import Sockets
    cfg = DualUIWeb.ServerConfig(Sockets.localhost, 8000, true, 300.0,
                                 10.0, 64, "DualUI",
                                 DualUIWeb.DualUI.Size(80, 24),
                                 DualUIWeb.DualUI.Size(20, 5))
    html = DualUIWeb.index_html(cfg)

    # X4's client half: a close is a pause, not a death.
    @test occursin("onclose", html)
    @test occursin("sessionStorage", html)
    @test occursin("session=", html)

    # The user is told, and the retry backs off rather than spinning.
    @test occursin(DualUIWeb.RECONNECT_NOTICE_ID, html)
    @test occursin("Reconnecting", html)
    @test occursin("setTimeout", html)
    @test occursin("BACKOFF_MAX_MS", html)
    @test occursin("BACKOFF_BASE_MS", html)
end

@testitem "Assets: index_html templates the configured title" begin
    using DualUIWeb
    import Sockets
    mk = t -> DualUIWeb.ServerConfig(Sockets.localhost, 8000, true,
                                     300.0, 10.0, 64, t,
                                     DualUIWeb.DualUI.Size(80, 24),
                                     DualUIWeb.DualUI.Size(20, 5))

    html = DualUIWeb.index_html(mk("My Dashboard"))
    @test occursin("<title>My Dashboard</title>", html)

    # No placeholder survives templating.
    @test !occursin("{{", html)
    @test !occursin("}}", html)

    # Pure: same config in, same bytes out.
    @test DualUIWeb.index_html(mk("My Dashboard")) == html

    # A different title really changes the output.
    @test DualUIWeb.index_html(mk("Other")) != html
    @test occursin("<title>Other</title>", DualUIWeb.index_html(mk("Other")))

    # A hostile title cannot break out of the document.
    evil = DualUIWeb.index_html(mk("</title><script>alert(1)</script>"))
    @test !occursin("<script>alert(1)</script>", evil)
    @test occursin("&lt;script&gt;", evil)
end

@testitem "Assets: content_type maps every served path" begin
    using DualUIWeb
    ct = DualUIWeb.content_type

    @test ct("/") == "text/html; charset=utf-8"
    @test ct("/index.html") == "text/html; charset=utf-8"
    @test ct("index.html") == "text/html; charset=utf-8"
    @test ct("/xterm.js") == "text/javascript; charset=utf-8"
    @test ct("/xterm.css") == "text/css; charset=utf-8"
    @test ct("/healthz.json") == "application/json; charset=utf-8"
    @test ct("/favicon.svg") == "image/svg+xml"

    # Total: an unknown extension is a byte stream, never an error.
    @test ct("/nope.bin") == "application/octet-stream"
    @test ct("/no-extension") == "application/octet-stream"
    @test ct("") == "application/octet-stream"

    # Case-insensitive on the extension.
    @test ct("/LOUD.HTML") == "text/html; charset=utf-8"
    @test ct("/LOUD.JS") == "text/javascript; charset=utf-8"

    # A query string is not part of the extension.
    @test ct("/xterm.js?v=1") == "text/javascript; charset=utf-8"

    # Pure and total on anything a client can send.
    for p in ("/", "//", "/a/b/c", "/.", "/..", "/x.", "/.js")
        @test ct(p) isa String
        @test !isempty(ct(p))
    end
end

@testitem "Assets: ASSETS bakes the bundle with its mime types" begin
    using DualUIWeb
    @test DualUIWeb.ASSETS isa Dict{String,Tuple{String,Vector{UInt8}}}
    @test isdir(DualUIWeb.ASSET_DIR)

    @test haskey(DualUIWeb.ASSETS, "/favicon.svg")
    mime, body = DualUIWeb.ASSETS["/favicon.svg"]
    @test mime == "image/svg+xml"
    @test !isempty(body)
    @test occursin("<svg", String(copy(body)))

    # Every baked entry is a rooted path whose mime agrees with
    # content_type, and no entry is empty.
    for (path, (m, b)) in DualUIWeb.ASSETS
        @test startswith(path, "/")
        @test m == DualUIWeb.content_type(path)
        @test !isempty(b)
    end

    # The templated page is NOT baked: serving it verbatim would ship
    # `{{TITLE}}` to the browser. `/` goes through `index_html(cfg)`.
    @test !haskey(DualUIWeb.ASSETS, "/index.html")

    # INDEX_HTML is the raw template; index_html(cfg) is the rendering.
    @test DualUIWeb.INDEX_HTML isa String
    @test !isempty(DualUIWeb.INDEX_HTML)
    @test occursin("{{TITLE}}", DualUIWeb.INDEX_HTML)

    # CDN mode vendors nothing, but a vendored drop-in is still served.
    @test DualUIWeb.XTERM_JS isa Vector{UInt8}
    @test DualUIWeb.XTERM_CSS isa Vector{UInt8}
    @test DualUIWeb.XTERM_FIT_JS isa Vector{UInt8}
    @test isempty(DualUIWeb.XTERM_JS) ==
          !haskey(DualUIWeb.ASSETS, "/xterm.js")
    @test isempty(DualUIWeb.XTERM_CSS) ==
          !haskey(DualUIWeb.ASSETS, "/xterm.css")
    @test isempty(DualUIWeb.XTERM_FIT_JS) ==
          !haskey(DualUIWeb.ASSETS, "/xterm-addon-fit.js")
end

@testitem "Assets: xterm loads from a pinned CDN version" begin
    using DualUIWeb
    html = DualUIWeb.INDEX_HTML

    # Pinned, not floating: no `@latest`, no bare package name.
    @test occursin(DualUIWeb.XTERM_VERSION, html)
    @test occursin(DualUIWeb.XTERM_FIT_VERSION, html)
    @test occursin(DualUIWeb.XTERM_CANVAS_VERSION, html)
    @test !occursin("@latest", html)

    # Served by tag, not vendored as a minified blob.
    @test occursin("<script src=\"", html)
    @test occursin("<link rel=\"stylesheet\"", html)

    # Every remote subresource is integrity-pinned and https. Four now:
    # xterm.js, its CSS, the fit addon and the canvas renderer.
    @test !occursin("http://cdn", html)
    n_sri = count(_ -> true, eachmatch(r"integrity=\"sha384-", html))
    @test n_sri == 4
    n_cdn = count(_ -> true, eachmatch(r"https://cdn\.jsdelivr\.net", html))
    @test n_cdn == 4
    @test count(_ -> true, eachmatch(r"crossorigin=", html)) == 4

    @test occursin(DualUIWeb.XTERM_JS_URL, html)
    @test occursin(DualUIWeb.XTERM_CSS_URL, html)
    @test occursin(DualUIWeb.XTERM_FIT_JS_URL, html)
    @test occursin(DualUIWeb.XTERM_CANVAS_JS_URL, html)
    for u in (DualUIWeb.XTERM_JS_URL, DualUIWeb.XTERM_CSS_URL,
              DualUIWeb.XTERM_FIT_JS_URL, DualUIWeb.XTERM_CANVAS_JS_URL)
        @test startswith(u, "https://")
    end
end
