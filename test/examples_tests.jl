# examples_tests.jl -- the examples in ManyUIWeb/examples/ must keep
# working.
#
# These are not smoke tests. An example that builds but paints a blank
# screen is exactly the failure worth catching -- the log example did
# precisely that while being written, because it pinned its scroll
# before layout had run and ended up scrolled past its own last line.
# So every testitem here paints into a headless buffer and asserts what
# is actually IN it.
#
# Each example guards its `main()` behind a PROGRAM_FILE check, so
# including one never starts a server.

"""
The absolute path of an example, from this test file. Internal.
"""
example_path(name) = joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", name)

"""
Paint `w` at `sz` and return its rows as strings. Internal.
"""
function example_rows(w, sz::ManyUITUI.Size)
    buf = ManyUITUI.Buffer(sz)
    ManyUI.clear!(buf)
    ManyUI.paint!(buf, w)
    return [join(String(buf.cells[x, y].content) for x in 1:sz.width)
            for y in 1:sz.height]
end

@testitem "examples: gallery shows every widget" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "gallery.jl"))

    ui = gallery_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 76, 20))
    buf = Buffer(Size(76, 20))
    clear!(buf)
    paint!(buf, ui)
    screen = join([join(String(buf.cells[x, y].content) for x in 1:76)
                   for y in 1:20], "\n")

    # One assertion per widget, so a regression names itself.
    @test occursin("ManyUI widget gallery", screen)   # Label
    @test occursin("Static does not wrap", screen)    # Static
    @test occursin("press me", screen)                # Button
    @test occursin("type, then enter", screen)        # TextInput placeholder
    @test occursin("TextArea", screen)                # TextArea
    @test occursin("alpha", screen)                   # List
    @test occursin("Ada", screen)                     # DataTable
    @test occursin("╭", screen)                       # Container borders
    # The TextArea's wide text survives the trip.
    @test occursin("漢字", screen)
end

@testitem "examples: unicode demo agrees with the width model" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "unicode.jl"))

    # The demo's own table is its assertion: each case declares the
    # width it must have, and that must be what text_width says.
    for (text, what, expected) in CASES
        @test text_width(text) == expected
    end

    # The cases where Base.textwidth is WRONG are the reason the demo
    # exists. If these ever agree, either Base changed or we broke.
    @test text_width("❤️") == 2
    @test textwidth("❤️") == 1
    @test text_width("👨‍👩‍👧‍👦") == 2
    @test textwidth("👨‍👩‍👧‍👦") == 8

    ui = unicode_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 80, 19))
    buf = Buffer(Size(80, 19))
    clear!(buf)
    paint!(buf, ui)
    screen = join([join(String(buf.cells[x, y].content) for x in 1:80)
                   for y in 1:19], "\n")
    @test occursin("unicode & graphemes", screen)
    @test occursin("ZWJ family", screen)
    @test occursin("CJK ideograph", screen)
end

@testitem "examples: life oscillates a blinker" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "life.jl"))

    b = LifeBoard(24, 5)
    b.grid = falses(5, 24)
    b.grid[3, 5:7] .= true              # a horizontal blinker
    apply_stylesheet!(SHEET, b)
    layout!(b, Region(1, 1, 24, 6))

    live() = [(i, j) for i in 1:5, j in 1:24 if b.grid[i, j]]
    @test length(live()) == 3

    step!(b)                            # -> vertical
    @test b.generation == 1
    @test b.grid[2, 6] && b.grid[3, 6] && b.grid[4, 6]
    @test !b.grid[3, 5] && !b.grid[3, 7]

    step!(b)                            # -> horizontal again
    @test b.grid[3, 5] && b.grid[3, 6] && b.grid[3, 7]
    @test length(live()) == 3
end

@testitem "examples: rain falls without growing the tree" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "rain.jl"))

    r = rain_app()
    apply_stylesheet!(SHEET, r)
    layout!(r, Region(1, 1, 40, 8))
    fit!(r, Size(40, 8))

    # One drop per column, and NOT one widget per column.
    @test length(r.drops) == 40
    @test isempty(descendants(r))

    for _ in 1:12
        step!(r)
    end
    @test isempty(descendants(r))       # still flat after animating

    buf = Buffer(Size(40, 8))
    clear!(buf)
    paint!(buf, r)
    painted = count(x -> strip(String(buf.cells[x[1], x[2]].content)) != "",
                    [(x, y) for x in 1:40, y in 1:8])
    @test painted > 0                   # something actually fell

    # Resizing refits rather than reallocating a widget per column.
    fit!(r, Size(10, 4))
    @test length(r.drops) == 10
end

@testitem "examples: snake steers, eats and dies" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "snake.jl"))

    s = snake_app()
    apply_stylesheet!(SHEET, s)
    layout!(s, Region(1, 1, 40, 17))

    @test length(s.body) == 3
    @test !s.dead
    @test s.paused                    # it waits rather than hitting a wall
    dispatch_event!(s, key(Key.SPACE), s)
    @test !s.paused

    head = s.body[1]
    step!(s)
    @test s.body[1] == (head[1] + 1, head[2])   # moved right

    # A real KeyEvent steers it.
    dispatch_event!(s, key(Key.DOWN), s)
    @test s.dir == (0, 1)
    h2 = s.body[1]
    step!(s)
    @test s.body[1] == (h2[1], h2[2] + 1)

    # It cannot reverse into itself.
    dispatch_event!(s, key(Key.UP), s)
    @test s.dir == (0, 1)

    # Eating grows it.
    s.food = (s.body[1][1], s.body[1][2] + 1)
    n = length(s.body)
    step!(s)
    @test length(s.body) == n + 1
    @test s.score == 1

    # SPACE pauses and resumes. The parser emits Key.SPACE for 0x20 --
    # NOT Key.CHAR(' ') -- and a handler checking only the latter is a
    # space bar that silently does nothing.
    @test !s.paused
    dispatch_event!(s, key(Key.SPACE), s)
    @test s.paused
    n2 = length(s.body)
    head2 = s.body[1]
    step!(s)
    @test s.body[1] == head2          # paused means paused
    dispatch_event!(s, key(Key.SPACE), s)
    @test !s.paused

    # A wall is fatal.
    for _ in 1:40
        step!(s)
    end
    @test s.dead

    # ... and r restarts.
    dispatch_event!(s, key('r'), s)
    @test !s.dead
    @test s.score == 0
end

@testitem "examples: datatable sorts 5000 rows without touching them" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "datatable.jl"))

    ui = table_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 44, 8))
    dt = query_one(ui, "#elements")

    @test row_count(dt) == 5000
    # 5000 rows, zero extra nodes: rows are data.
    @test isempty(descendants(dt))

    rows_before = copy(dt.rows)
    sort_by!(dt, 3; dir = SortDir.DESCENDING)
    @test sort_column(dt) == 3
    @test sort_direction(dt) === SortDir.DESCENDING
    # The caller's data is untouched: sorting permutes an index.
    @test dt.rows == rows_before
    # The view really is descending by Z.
    zs = [dt.rows[source_index(dt, k)][3] for k in 1:5]
    @test issorted(zs; rev = true)

    buf = Buffer(Size(44, 8))
    clear!(buf)
    paint!(buf, ui)
    screen = join([join(String(buf.cells[x, y].content) for x in 1:44)
                   for y in 1:8], "\n")
    @test occursin("element", screen)
    @test occursin("▼", screen)         # the sort indicator
end

@testitem "examples: dashboard filters its list" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "dashboard.jl"))

    ui = dashboard_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 34, 9))
    box = query_one(ui, "#filter")
    list = query_one(ui, "#langs")
    hits = query_one(ui, "#hits")

    @test row_count(list) == length(LANGUAGES)

    insert_text!(box, "li")
    box.on_submit(box)                  # what ENTER calls
    @test row_count(list) == 4
    @test list.items == ["Julia", "Elixir", "Common Lisp", "Kotlin"]
    # `plain`, because a Label's cell holds a RichText now. This
    # assertion was unreachable while the file failed to load at all,
    # which is exactly what a masked failure buys you.
    @test occursin("4 of", plain(hits.text[]))

    # Clearing it puts everything back. Cleared by backspacing, the way
    # a user would: `set_text!` exists for TextArea but NOT TextInput.
    move_to!(box, typemax(Int))
    while !isempty(box.text[])
        backspace!(box)
    end
    box.on_submit(box)
    @test row_count(list) == length(LANGUAGES)

    # The title must not be shrunk away by the list -- this is what
    # `shrink: 0` in the example's stylesheet buys, and it regressed to
    # a zero-height label while the example was being written.
    @test region(query_one(ui, "#title")).height == 1
end

@testitem "examples: log follows the tail, then lets go" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos", "scrollpane.jl"))

    ui = log_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 56, 7))
    lv = query_one(ui, "#log")

    emit!(lv)                           # first tick after layout pins it
    @test lv.follow
    @test scroll_of(lv).y == max_scroll(lv).y

    # Pinned means the NEWEST line is on screen -- the bug this catches
    # is a view scrolled past its own end, which renders nothing at all.
    buf = Buffer(Size(56, 7))
    clear!(buf)
    paint!(buf, ui)
    screen = join([join(String(buf.cells[x, y].content) for x in 1:56)
                   for y in 1:7], "\n")
    @test occursin(string(lv.seq), screen)
    @test !isempty(strip(replace(screen, "\n" => "")))

    # Scrolling up by hand drops auto-follow...
    dispatch_event!(ui, MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_UP,
                                   2, 4, MOD_NONE), lv)
    @test !lv.follow
    # ... and then new lines leave the view exactly where it was.
    where = scroll_of(lv).y
    emit!(lv)
    @test scroll_of(lv).y == where

    # Scrolling back to the bottom picks follow up again.
    for _ in 1:10
        dispatch_event!(ui, MouseEvent(MouseAction.PRESS,
                                       MouseButton.WHEEL_DOWN, 2, 4,
                                       MOD_NONE), lv)
    end
    @test lv.follow
end

@testitem "examples: a demo loads without a GPU stack" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos",
                     "gallery.jl"))

    # THE regression this file exists to prevent. Every demo used to
    # `import CImGui, GLFW, ModernGL` at the top, so including one for
    # its widget tree dragged in a GPU stack -- and every testitem in
    # this file failed on a machine without one, silently, for long
    # enough that a real assertion below it went unchecked.
    #
    # No demo uses a symbol from any of the three. Building the widgets
    # must need none of them.
    @test gallery_app() isa Widget
    @test HAS_CIMGUI isa Bool

    # And when the backend is genuinely absent, a CImGui mode refuses
    # with a message naming what is missing, rather than an
    # UndefVarError on a package name.
    #
    # The guard is a MACRO and it does not throw: it prints what is
    # missing and RETURNS 0 from the enclosing function, so someone
    # without a GPU stack gets an explanation instead of a stacktrace.
    # That `return` is exactly why it cannot be a plain function, and
    # why it can only be written inside one.
    if !HAS_CIMGUI
        refuse() = (@need_cimgui(); :reached_the_backend)

        pipe = Pipe()
        Base.link_pipe!(pipe)
        saved = stdout
        redirect_stdout(pipe.in)
        result = try
            refuse()
        finally
            redirect_stdout(saved)
            close(pipe.in)
        end
        msg = read(pipe, String)

        # It refused: the backend line was never reached.
        @test result == 0
        @test occursin("CImGui", msg)
        @test occursin("need none of them", msg)
        # And it says WHERE the GPU stack lives, which is the whole
        # point of refusing with a message.
        @test occursin("CImGuiEnv", msg)
    end
end

@testitem "examples: the monitor rebuilds a real screen" begin
    using ManyUI, ManyUITUI
    include(joinpath(@__DIR__, "..", "..", "ManyUIDemos", "demos",
                     "monitor.jl"))

    # This demo exists to answer a question a feature checklist cannot:
    # could ManyUI render the Server tab of a real Tachikoma
    # application? These assertions are that answer, so they check the
    # five things that were inexpressible before the parity work --
    # not merely that something painted.
    ui = monitor_app()
    apply_stylesheet!(SHEET, ui)
    layout!(ui, Region(1, 1, 62, 16))
    buf = Buffer(Size(62, 16))
    clear!(buf)
    paint!(buf, ui)
    rows = [join(String(buf.cells[x, y].content) for x in 1:62)
            for y in 1:16]

    # Rows are found by CONTENT, never by index: adding a frame round
    # the screen shifted every one of them, and a test that pins a
    # layout rather than a capability breaks on every cosmetic change.
    rowof(pat) = findfirst(r -> occursin(pat, r), rows)
    # A row contains box-drawing glyphs, so a BYTE index is not a CELL
    # column. Every lookup below goes through this.
    function colof(row, pat)
        r = findfirst(pat, row)
        r === nothing && return nothing
        return length(row[1:prevind(row, first(r))]) + 1
    end

    # 1. A tab strip whose shortcut key is coloured INSIDE the caption.
    tabrow = rowof("1 Server")
    @test tabrow !== nothing
    @test occursin("2 Sessions", rows[tabrow])
    kx = colof(rows[tabrow], "1 Server")
    key = buf.cells[kx, tabrow]
    @test String(key.content) == "1"
    @test has(key.style, Attr.BOLD)
    @test key.style.fg != buf.cells[kx + 2, tabrow].style.fg   # "S"

    # 2. Captioned frames, with the caption ON the border.
    @test rowof("─ Server Status ") !== nothing
    @test rowof("─ Server Log (9) ") !== nothing
    @test rowof("─ ManyUI monitor ") !== nothing     # the outer frame

    # 3. A log list where the stamp and level carry and the message
    #    recedes -- a log is scanned down its left edge.
    warnrow = rowof("warn")
    @test warnrow !== nothing
    lvl = colof(rows[warnrow], "warn")
    stamp = colof(rows[warnrow], "10:42:23")
    @test buf.cells[lvl, warnrow].style.fg !=
          buf.cells[stamp, warnrow].style.fg
    @test buf.cells[lvl, warnrow].style.fg !=
          buf.cells[lvl + 6, warnrow].style.fg        # level vs message
    @test buf.cells[stamp, warnrow].style.fg !=
          buf.cells[lvl + 6, warnrow].style.fg        # stamp vs message

    # 4. A status bar that puts its two ends where they belong.
    barrow = rowof("localhost:2828")
    @test barrow !== nothing
    @test occursin("q:quit", rows[barrow])
    @test colof(rows[barrow], "localhost:2828") <
          colof(rows[barrow], "q:quit")

    # 5. A palette named by TOKENS. The screen names `--accent`, never a
    #    hex value, so the SAME tree serves every theme.
    trow = findfirst(r -> occursin("1 Server", r), rows)
    accent = buf.cells[colof(rows[trow], "1 Server"), trow].style.fg
    @test is_token(accent)

    before = theme()
    try
        set_theme!(:dark)
        d = Buffer(Size(62, 16)); clear!(d); paint!(d, ui)
        set_theme!(:light)
        l = Buffer(Size(62, 16)); clear!(l); paint!(l, ui)

        # The two buffers are IDENTICAL, and that is the design rather
        # than a bug: a token becomes a colour at EMISSION, so nothing
        # in the tree or the buffer holds a resolved one. It is also
        # exactly why set_theme! owes the caller a full repaint -- the
        # frame diff compares these cells and finds nothing.
        @test isempty(ManyUITUI.diff(d, l).spans)

        # The difference lives one layer down, where a colour meets a
        # device.
        set_theme!(:dark);  dark = resolve_token(accent)
        set_theme!(:light); light = resolve_token(accent)
        @test !is_token(dark) && !is_token(light)
        @test dark != light
    finally
        set_theme!(before)
    end
end
