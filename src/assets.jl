# assets.jl -- W4 / EARS 2.4. The static client bundle.
#
# The page is baked into the .ji at precompile: `INDEX_HTML` and every
# file in `assets/` are read at module load, so serving a client costs
# no I/O and the bundle cannot drift from the code that serves it.
#
# xterm.js itself is NOT vendored -- it is loaded from jsdelivr at a
# pinned version with an SRI digest (see `XTERM_JS_URL`). That is a
# deliberate departure from the contract's "vendored, no CDN"; the
# offline escape hatch is preserved: drop `xterm.js`, `xterm.css` and
# `xterm-addon-fit.js` into `assets/` and they are baked and served
# from `/xterm.js` etc. like any other asset.

"""
Where the bundle lives.
"""
const ASSET_DIR = normpath(@__DIR__, "..", "assets")

# The bundle is `read` at module load, and a plain `read` is invisible
# to the precompile staleness check: without this, editing
# `assets/index.html` would leave a stale page baked in the .ji and the
# edit would silently do nothing. Tracking the DIRECTORY also catches a
# vendored file being added or removed, which per-file tracking cannot.
include_dependency(ASSET_DIR)

# ------------------------------------------------------------- the CDN

"""
Pinned xterm.js version. Bumping this REQUIRES recomputing the SRI
digests in `assets/index.html`.
"""
const XTERM_VERSION = "5.5.0"

"""
Pinned `@xterm/addon-fit` version.
"""
const XTERM_FIT_VERSION = "0.10.0"

"""
Pinned `@xterm/addon-canvas` version. The 2D-canvas renderer, whose custom
glyphs fill each cell exactly -- block and box-drawing characters render
solid, where the DOM renderer leaves inter-row gaps.
"""
const XTERM_CANVAS_VERSION = "0.7.0"

"""
Pinned `@xterm/addon-image` version. Decodes SIXEL, so a Tachikoma pixel
pane renders as an image instead of its braille fallback.
"""
const XTERM_IMAGE_VERSION = "0.8.0"

"""
Pinned `@xterm/addon-unicode-graphemes` version. Makes xterm.js measure
GRAPHEME CLUSTERS rather than codepoints, so a ZWJ sequence such as
👨‍👩‍👧‍👦 occupies one cell pair instead of four that overlap.
"""
const XTERM_UNICODE_GRAPHEMES_VERSION = "0.4.0"

"""
Pinned `@xterm/addon-ligatures` version. Lets the font form its
ligatures rather than drawing each codepoint on its own.
"""
const XTERM_LIGATURES_VERSION = "0.9.0"

"""
CDN origin. Every subresource is https, version-pinned and
integrity-pinned.
"""
const XTERM_CDN = "https://cdn.jsdelivr.net/npm"

"""
The pinned xterm.js UMD bundle. Defines `window.Terminal`.
"""
const XTERM_JS_URL =
    "$(XTERM_CDN)/@xterm/xterm@$(XTERM_VERSION)/lib/xterm.js"

"""
The pinned xterm.js stylesheet.
"""
const XTERM_CSS_URL =
    "$(XTERM_CDN)/@xterm/xterm@$(XTERM_VERSION)/css/xterm.css"

"""
The pinned fit addon. Defines `window.FitAddon.FitAddon`.
"""
const XTERM_FIT_JS_URL =
    "$(XTERM_CDN)/@xterm/addon-fit@$(XTERM_FIT_VERSION)/lib/addon-fit.js"

"""
The pinned canvas renderer addon. Defines `window.CanvasAddon.CanvasAddon`.
"""
const XTERM_CANVAS_JS_URL =
    "$(XTERM_CDN)/@xterm/addon-canvas@$(XTERM_CANVAS_VERSION)/lib/addon-canvas.js"

"""
The pinned SIXEL image addon. Defines `window.ImageAddon.ImageAddon`.
"""
const XTERM_IMAGE_JS_URL =
    "$(XTERM_CDN)/@xterm/addon-image@$(XTERM_IMAGE_VERSION)/lib/addon-image.js"

"""
The pinned Unicode graphemes addon. Defines
`window.UnicodeGraphemesAddon.UnicodeGraphemesAddon`.
"""
const XTERM_UNICODE_GRAPHEMES_JS_URL =
    "$(XTERM_CDN)/@xterm/addon-unicode-graphemes@$(XTERM_UNICODE_GRAPHEMES_VERSION)/lib/addon-unicode-graphemes.js"

"""
The pinned ligatures addon. Defines `window.LigaturesAddon.LigaturesAddon`.
"""
const XTERM_LIGATURES_JS_URL =
    "$(XTERM_CDN)/@xterm/addon-ligatures@$(XTERM_LIGATURES_VERSION)/lib/addon-ligatures.js"

# ------------------------------------------------- the client contract

"""
The element the client mounts its `Terminal` on. Shared with
`assets/index.html`; the test suite asserts they agree.
"""
const TERMINAL_MOUNT_ID = "terminal"

"""
The element carrying the reconnect notice.
"""
const RECONNECT_NOTICE_ID = "reconnect"

"""
The path the client opens its WebSocket on, templated into the page so
the route and the client cannot drift.
"""
const WS_PATH = "/ws"

# ------------------------------------------------------------- serving

"""
Extension to MIME type. Everything not named here is an opaque byte
stream.
"""
const MIME_TYPES = Dict{String,String}(
    ".html"  => "text/html; charset=utf-8",
    ".htm"   => "text/html; charset=utf-8",
    ".js"    => "text/javascript; charset=utf-8",
    ".mjs"   => "text/javascript; charset=utf-8",
    ".css"   => "text/css; charset=utf-8",
    ".json"  => "application/json; charset=utf-8",
    ".map"   => "application/json; charset=utf-8",
    ".txt"   => "text/plain; charset=utf-8",
    ".svg"   => "image/svg+xml",
    ".ico"   => "image/x-icon",
    ".png"   => "image/png",
    ".woff2" => "font/woff2",
)

"""
Served when a path names no known extension.
"""
const MIME_DEFAULT = "application/octet-stream"

"""
The MIME type served for `path`.

Total and pure: a query string and a fragment are stripped, the
extension is matched case-insensitively, a directory path is HTML, and
anything unrecognised is `MIME_DEFAULT`. Never throws -- `path` comes
straight off the wire.
"""
function content_type(path::AbstractString)::String
    p = first(split(path, '?'; limit = 2))
    p = first(split(p, '#'; limit = 2))
    isempty(p) && return MIME_DEFAULT
    endswith(p, '/') && return MIME_TYPES[".html"]
    ext = lowercase(splitext(p)[2])
    return get(MIME_TYPES, ext, MIME_DEFAULT)
end

# ------------------------------------------------------------- the page

"""
`name`'s bytes, or empty when it is not vendored. CDN mode leaves all
three xterm files absent.
"""
function _read_asset(name::AbstractString)::Vector{UInt8}
    p = joinpath(ASSET_DIR, name)
    isfile(p) || return UInt8[]
    include_dependency(p)
    return read(p)
end

"""
The untemplated page. `{{TITLE}}` and `{{WS_PATH}}` are still in it;
`index_html` is what a client gets.
"""
const INDEX_HTML = String(_read_asset("index.html"))

"""
The vendored xterm.js, or empty in CDN mode.
"""
const XTERM_JS = _read_asset("xterm.js")

"""
The vendored xterm.css, or empty in CDN mode.
"""
const XTERM_CSS = _read_asset("xterm.css")

"""
The vendored fit addon, or empty in CDN mode.
"""
const XTERM_FIT_JS = _read_asset("xterm-addon-fit.js")

"""
Every servable file in `ASSET_DIR`, as `path => (mime, body)`.

The `index.html` template is deliberately excluded: it is templated
per-request by `index_html` and serving it verbatim would ship
`{{TITLE}}` to a browser.
"""
function _bake_assets()::Dict{String,Tuple{String,Vector{UInt8}}}
    out = Dict{String,Tuple{String,Vector{UInt8}}}()
    isdir(ASSET_DIR) || return out
    for name in readdir(ASSET_DIR; sort = true)
        name == "index.html" && continue
        isfile(joinpath(ASSET_DIR, name)) || continue
        body = _read_asset(name)
        isempty(body) && continue
        out["/" * name] = (content_type(name), body)
    end
    return out
end

"""
path => (mime, body). Baked at precompile.
"""
const ASSETS = _bake_assets()

"""
Escape `s` for interpolation into HTML text or an attribute value. The
title is developer-supplied, but it must not be able to close a tag.
"""
function _escape_html(s::AbstractString)::String
    return replace(s, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;",
                   '"' => "&quot;", '\'' => "&#39;")
end

# NOTE (contract defect, scaffold): `ServerConfig` is defined in
# server.jl, which the normative include order places AFTER this file,
# so `cfg` cannot carry its type annotation here. It is a
# `ServerConfig`; all this reads off it is `cfg.title`.
"""
2.4. Template the title and the WebSocket path into `INDEX_HTML`.

One `replace` over both placeholders, so the substitutions are
simultaneous and no substituted text is ever re-scanned. Pure.
"""
function index_html(cfg)::String
    return replace(INDEX_HTML,
                   "{{TITLE}}" => _escape_html(String(cfg.title)),
                   "{{WS_PATH}}" => WS_PATH)
end
