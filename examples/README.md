# DualUIWeb examples

Run any of these, then open the URL it prints:

```bash
julia --project=DualUIWeb DualUIWeb/examples/gallery.jl        # port 8000
julia --project=DualUIWeb DualUIWeb/examples/unicode.jl   8001
julia --project=DualUIWeb DualUIWeb/examples/datatable.jl 8002
```

Each takes an optional port as its first argument.

| Example | Shows |
|:--|:--|
| `gallery.jl` | **every widget on one page** -- the conformance view |
| `unicode.jl` | **wide characters, combining marks, graphemes** -- the rendering test |
| `life.jl` | Conway's Game of Life: a custom widget, animation, a grid as data |
| `rain.jl` | Matrix rain: pure character-buffer animation |
| `snake.jl` | a game: keys, timer, collision |
| `datatable.jl` | 5000 sortable rows: click-to-sort, `O(window)` painting |
| `dashboard.jl` | a `TextInput` filtering a `List`: widgets wiring to each other |
| `scrollpane.jl` | a live log with auto-follow that lets go when you scroll up |

Start with `gallery.jl` and `unicode.jl`. The first is the honest
inventory -- what is on that page is what DualUI has. The second is the
one that would catch a rendering bug: a terminal grid is not a string,
and if the columns in that table line up, the width model is right.

## These are DualUI apps, not web apps

`serve` points them at a browser; the same code runs on a tty by
swapping the driver:

```julia
run!(App(gallery_app(), TerminalDriver()))
```

`DualUI` has no HTTP dependency and no idea any of this is happening.

## Every tab is its own session

`serve` takes a *factory*, not a widget, and calls it once per client.
Open `datatable.jl` in two tabs and sort them differently: they share
nothing. Close a tab and the session pauses with its state intact; come
back within `session_timeout` and it resumes where it was.

## Verified in a real browser

Every example here has been opened in Chrome and driven, not merely
checked for an HTTP 200. That is not pedantry: serving a 200 hid two
bugs that made the whole web target useless -- the animation loop never
woke, and the mouse was never enabled. Both are fixed; both were
invisible to the headless suite.

## The one that matters: waking the loop

An animation driver **must post an event**. `invalidate!` is internal to
the App: it marks state dirty but does not wake the event loop, which is
blocked on `take!` of its channel. Call it from outside and your demo
marks a board dirty that nothing ever repaints -- it renders once and
freezes. Every animated example here posts a `TickEvent` instead:

```julia
tick!(app) = post!(app, TickEvent(time()))
```

A `RefreshEvent` also wakes it, but forces a FULL repaint every frame
and throws the diff away. The channel is the only way in -- by design,
and the App's docstrings say so.

## Three more things that will bite you

**The space bar is `Key.SPACE`, not `Key.CHAR(' ')`.** The parser emits
`Key.SPACE` for byte `0x20`. A handler checking only `e.char == ' '` is
a space bar that silently does nothing. `snake.jl` checks both.

**A list in a column can eat its neighbours.** `List`, `Table` and
`DataTable` measure to the whole viewport, so a column holding one asks
for more height than exists. Flex then shrinks whatever it can, and a
one-row `Label` next to a list becomes a zero-row label and vanishes.
Pin the fixed rows with `shrink: 0` -- `dashboard.jl` does. If a widget
mysteriously disappears from a column, check this first.

**Iterating `server.sessions` needs the lock.** It is guarded; a client
connecting or dropping mid-iteration throws. Take a snapshot under
`server.lock` first -- every animated example here has a `sessions_of`
helper that does.

**`max_scroll` needs a layout.** It measures against the content box,
which is empty until layout has run, so pinning a view to the bottom
before the first layout stores an offset that is later out of range --
and a view scrolled past its own last line renders *nothing*.
`scrollpane.jl` separates `add_line!` from `emit!` for exactly this
reason.

## What is missing, and why

Tachikoma ships 40 demos. Most of them cannot be ported yet, because
they exercise widgets DualUI does not have:

| Their demos need | Blocked until |
|:--|:--|
| braille canvas (2x4 sub-cell dots) | a `Canvas` widget |
| `Sparkline`, `Chart`, `BarChart`, `Gauge` | the chart tier |
| `Tabs`, `Checkbox`, `DropDown`, `Form`, `TreeView` | the controls tier |
| `MarkdownPane`, `CodeEditor`, `ReplWidget` | later still |
| `FloatingWindow`, z-order | a compositor change: paint order **is** document order today, with no z-index |
| sixel / `PixelImage` | no sixel support at all |

The examples here are the ones that fit what exists today.
