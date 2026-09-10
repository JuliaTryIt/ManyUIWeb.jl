@testitem "native: serve_native starts an HTTP server" begin
    import HTTP
    import ManyUI
    import ManyUIWeb

    model = () -> ManyUI.Button("Click me", (btn) -> nothing)
    server = ManyUIWeb.serve_native(model, ManyUI.WebNative(), 0) # 0 means random port

    @test server isa ManyUIWeb.WebNativeServer
    @test server.http_server isa HTTP.Server
    @test isopen(server)

    # Close it
    Base.close(server)
    @test !isopen(server)
end

@testitem "native: generate_document contains CSS and JS" begin
    import ManyUI
    import ManyUIWeb

    model = () -> ManyUI.Button("Click me", (btn) -> nothing)
    root = ManyUI.render(model, ManyUI.WebNative())

    html = ManyUIWeb.generate_document(root)
    @test occursin("<!DOCTYPE html>", html)
    @test occursin("<style>", html)
    @test occursin("function connect()", html)
    @test occursin("ws = new WebSocket", html)
    @test occursin("                });\n            } else {", html)
end

@testitem "native: DOM callback names match the Julia API" begin
    import ManyUI
    import ManyUIWeb

    button = ManyUI.Button("Save", _ -> nothing; id = :save)
    input = ManyUI.TextInput("", _ -> nothing; id = :name)
    list = ManyUI.List(["a", "b"]; id = :items)

    button_html = ManyUIWeb.to_html(button)
    input_html = ManyUIWeb.to_html(input)
    list_html = ManyUIWeb.to_html(list)

    @test occursin("'click'", button_html)
    @test occursin("'input'", input_html)
    @test occursin("'submit'", input_html)
    @test occursin("'change'", list_html)
    @test occursin("'submit'", list_html)
    @test occursin("'focus'", button_html)
    @test occursin("'blur'", button_html)
    @test !occursin("on_press", button_html)
    @test !occursin("on_activate", list_html)
end

@testitem "native: events invoke each callback exactly once" begin
    import ManyUI
    import ManyUIWeb

    clicks = Ref(0)
    changes = Ref(0)
    submissions = Ref(0)
    focuses = Ref(0)
    blurs = Ref(0)

    button = ManyUI.Button("Save", _ -> (clicks[] += 1); id = :save)
    ManyUI.node(button).on_focus = _ -> (focuses[] += 1)
    ManyUI.node(button).on_blur = _ -> (blurs[] += 1)
    list = ManyUI.List(["a", "b"], _ -> (submissions[] += 1);
                       on_change = _ -> (changes[] += 1), id = :items)
    root = ManyUI.Container(button, list)

    @test ManyUIWeb.process_native_event!(root,
        (id = "save", event = "focus", value = nothing))
    @test ManyUIWeb.process_native_event!(root,
        (id = "save", event = "click", value = nothing))
    @test ManyUIWeb.process_native_event!(root,
        (id = "save", event = "blur", value = nothing))
    @test ManyUIWeb.process_native_event!(root,
        (id = "items", event = "change", value = 2))
    @test ManyUIWeb.process_native_event!(root,
        (id = "items", event = "submit", value = 2))

    @test clicks[] == 1
    @test changes[] == 1
    @test submissions[] == 1
    @test focuses[] == 1
    @test blurs[] == 1
end

@testitem "native: selection widgets render and dispatch on_change" begin
    import ManyUI
    import ManyUIWeb

    checkbox_changes = Ref(0)
    radio_changes = Ref(0)
    dropdown_changes = Ref(0)
    tree_changes = Ref(0)

    checkbox = ManyUI.Checkbox("Ready", _ -> (checkbox_changes[] += 1);
                               id = :ready)
    radio = ManyUI.RadioGroup(["One", "Two"], _ -> (radio_changes[] += 1);
                              id = :choice)
    dropdown = ManyUI.DropDown(["One", "Two"],
                               _ -> (dropdown_changes[] += 1);
                               id = :dropdown)
    tree = ManyUI.TreeView([ManyUI.TreeNode("a"), ManyUI.TreeNode("b")];
                           on_change = _ -> (tree_changes[] += 1), id = :tree)
    root = ManyUI.Container(checkbox, radio, dropdown, tree)

    @test occursin("type=\"checkbox\"", ManyUIWeb.to_html(checkbox))
    @test occursin("type=\"radio\"", ManyUIWeb.to_html(radio))
    @test occursin("<select", ManyUIWeb.to_html(dropdown))
    @test occursin("manyui-tree-row", ManyUIWeb.to_html(tree))

    @test ManyUIWeb.process_native_event!(root,
        (id = "ready", event = "change", value = true))
    @test ManyUIWeb.process_native_event!(root,
        (id = "choice", event = "change", value = 2))
    @test ManyUIWeb.process_native_event!(root,
        (id = "dropdown", event = "change", value = "2"))
    @test ManyUIWeb.process_native_event!(root,
        (id = "tree", event = "change", value = 2))

    @test checkbox_changes[] == 1
    @test radio_changes[] == 1
    @test dropdown_changes[] == 1
    @test tree_changes[] == 1
end

@testitem "native: a plain Label is a bare span" begin
    import ManyUI
    import ManyUIWeb

    html = ManyUIWeb.to_html(ManyUI.Label("hello"))
    @test occursin(">hello<", html)
    # Nothing to style, so no nested span is emitted: the common case
    # must not pay for the feature.
    @test !occursin("<span style", html)
end

@testitem "native: a RichText Label emits one styled span per run" begin
    import ManyUI
    import ManyUIWeb

    warn = ManyUI.Style(fg = ManyUI.rgb(255, 200, 0), bold = true)
    rt = ManyUI.RichText(ManyUI.TextRun("1", warn), ManyUI.TextRun(" Server"))

    html = ManyUIWeb.to_html(ManyUI.Label(rt))

    # The styled run carries its own colour and weight ...
    @test occursin("color: rgb(255, 200, 0)", html)
    @test occursin("font-weight: bold", html)
    @test occursin(">1</span>", html)
    # ... and the unstyled run stays bare text rather than being wrapped
    # in an empty span.
    @test occursin(" Server", html)
    @test count("<span style", html) == 1

    # Whatever the styling, the text is all there and in order.
    @test occursin("1", html) && occursin("Server", html)
end

@testitem "native: an ANSI colour on a run converts to CSS rgb" begin
    import ManyUI
    import ManyUIWeb

    # A run may name a palette colour; the browser only speaks rgb, so
    # it has to be converted rather than dropped.
    rt = ManyUI.RichText("x", ManyUI.Style(fg = ManyUI.ansi16(1)))
    html = ManyUIWeb.to_html(ManyUI.Label(rt))
    @test occursin("color: rgb(", html)
end

@testitem "native: a rich List format reaches the DOM as spans" begin
    import ManyUI
    import ManyUIWeb

    # format may now return a RichText, so every callback the HTML
    # projection interpolates has to go through the same helper the
    # Label does -- otherwise the page gets the struct's repr.
    warn = ManyUI.Style(fg = ManyUI.rgb(255, 0, 0))
    fmt = x -> ManyUI.RichText(ManyUI.TextRun("!", warn), ManyUI.TextRun(x))
    l = ManyUI.List(["boom"]; format = fmt)

    html = ManyUIWeb.to_html(l)
    @test occursin("color: rgb(255, 0, 0)", html)
    @test occursin(">!</span>", html)
    @test occursin("boom", html)
    @test !occursin("RichText", html)
end

@testitem "native: a rich Table cell reaches the DOM as spans" begin
    import ManyUI
    import ManyUIWeb

    bold = ManyUI.Style(bold = true)
    t = ManyUI.Table([1], [ManyUI.Column("N")];
                     cell = (r, j) -> ManyUI.RichText(
                         ManyUI.TextRun("a", bold), ManyUI.TextRun("b")))

    html = ManyUIWeb.to_html(t)
    @test occursin("font-weight: bold", html)
    @test !occursin("RichText", html)
end

@testitem "native: a captioned Container shows its caption" begin
    import ManyUI
    import ManyUIWeb

    # The TUI paints the caption on the border; the DOM has no border
    # row to paint on, so it becomes a leading element instead. Either
    # way it is chrome, never a child -- mounting it would put it in the
    # tab order and in the layout.
    c = ManyUI.Container(ManyUI.Label("body"); title = "Server Log")
    html = ManyUIWeb.to_html(c)

    @test occursin("manyui-panel-title", html)
    @test occursin("Server Log", html)
    @test occursin("body", html)
    @test length(ManyUI.children(c)) == 1
end

@testitem "native: a theme token resolves on the way to CSS" begin
    import ManyUI
    import ManyUIWeb

    before = ManyUI.theme()
    try
        ManyUI.set_theme!(:dark)
        rt = ManyUI.RichText("x", ManyUI.Style(fg = ManyUI.token(:accent)))
        dark = ManyUIWeb.to_html(ManyUI.Label(rt))
        @test occursin("color: rgb(", dark)
        @test !occursin("TOKEN", dark)

        # The same tree, a different palette, different CSS. Nothing was
        # rebuilt between the two.
        ManyUI.set_theme!(:light)
        @test ManyUIWeb.to_html(ManyUI.Label(rt)) != dark
    finally
        ManyUI.set_theme!(before)
    end
end

@testitem "native: a Splitter projects as a flex row with its handles" begin
    import ManyUI
    import ManyUIWeb

    sp = ManyUI.Splitter(ManyUI.Label("left"), ManyUI.Label("right");
                         weights = [3, 1])
    ManyUI.apply_stylesheet!(ManyUI.STYLESHEET_EMPTY, sp)
    html = ManyUIWeb.to_html(sp)

    @test occursin("display: flex", html)
    @test occursin("flex-direction: row", html)
    # The weights survive as flex-grow, so the browser splits the row
    # the same way the terminal does.
    @test occursin("flex-grow: 3", html)
    @test occursin("flex-grow: 1", html)
    @test occursin("left", html) && occursin("right", html)
end

@testitem "native: a WebNative server answers url, like the other one" begin
    import ManyUI
    import ManyUIWeb

    # One verb for both server types. WebServer answered `url`,
    # WebNativeServer did not, so every demo that launched WebNative and
    # printed its address hit a MethodError -- unnoticed, because a
    # demo's `main` is never called by a test.
    model = () -> ManyUI.Label("hi")
    server = ManyUIWeb.serve_native(model, ManyUI.WebNative(), 0)
    try
        @test ManyUIWeb.bound_port(server) > 0
        u = ManyUIWeb.url(server)
        @test startswith(u, "http://")
        @test endswith(u, "/")
        @test occursin(string(ManyUIWeb.bound_port(server)), u)
    finally
        Base.close(server)
    end
end

@testitem "native: a tab strip projects its captions" begin
    import ManyUI
    import ManyUIWeb

    # A `TabStrip` holds its captions in `titles`, not as children, so the
    # generic container branch emitted an empty box: the monitor screen showed
    # three blank rounded rectangles where `1 Server | 2 Sessions | 3 Activity`
    # belongs. Found by rendering a real screen, not by a unit test.
    tabs = ManyUI.Tabs("1 Server" => ManyUI.Label("a"),
                       "2 Sessions" => ManyUI.Label("b"),
                       "3 Activity" => ManyUI.Label("c"))
    html = ManyUIWeb.to_html(tabs.strip)

    @test occursin("1 Server", html)
    @test occursin("2 Sessions", html)
    @test occursin("3 Activity", html)
end

@testitem "native: the selected tab is distinguishable, and the others are clickable" begin
    import ManyUI
    import ManyUIWeb

    tabs = ManyUI.Tabs("One" => ManyUI.Label("a"), "Two" => ManyUI.Label("b"))
    html = ManyUIWeb.to_html(tabs.strip)

    # Selection has to reach the DOM, or a browser cannot show which tab is open.
    @test occursin("manyui-tab-selected", html)
    # And a tab is a control: clicking it selects, as it does in the terminal.
    @test occursin("dispatch_event", html)
end

@testitem "native: a tab caption keeps the styling of its runs" begin
    import ManyUI
    import ManyUIWeb

    # Kaimon colours the shortcut digit inside the caption — "**1** Server" with
    # the digit in yellow. That is the whole reason `TabStrip.titles` are
    # `RichText`, so flattening them here would undo §10.1 of the roadmap.
    caption = ManyUI.RichText([ManyUI.TextRun("1", ManyUI.Style(fg = ManyUI.token(:warning))),
                               ManyUI.TextRun(" Server", ManyUI.Style())])
    tabs = ManyUI.Tabs(caption => ManyUI.Label("a"))
    html = ManyUIWeb.to_html(tabs.strip)

    @test occursin("Server", html)
    @test occursin("<span", html)
end

@testitem "native: the document styles a tab strip as a row" begin
    import ManyUI
    import ManyUIWeb

    # Emitting the captions is half of it. Without a rule the strip inherits the
    # container's column layout and the tabs stack vertically, which is not a
    # tab strip.
    model = () -> ManyUI.Tabs("One" => ManyUI.Label("a"), "Two" => ManyUI.Label("b"))
    root = ManyUI.render(model, ManyUI.WebNative())
    doc = ManyUIWeb.generate_document(root)

    @test occursin(".manyui-tabstrip", doc)
    @test occursin("flex-direction: row", doc)
    @test occursin(".manyui-tab-selected", doc)
end

@testitem "native: a status bar projects its three slots" begin
    import ManyUI
    import ManyUIWeb

    # Same family as the tab strip: a StatusBar's content lives in `left`,
    # `center` and `right`, not in children, so the generic container branch had
    # nothing to walk and emitted an empty node. Found by rebuilding the
    # KaimonSlateDesktop status panel, whose footer simply vanished.
    bar = ManyUI.StatusBar(; left = ManyUI.RichText(ManyUI.TextRun("KaimonSlateDesktop")),
                             center = ManyUI.RichText(ManyUI.TextRun("middle")),
                             right = ManyUI.RichText(ManyUI.TextRun("q:quit")))
    html = ManyUIWeb.to_html(bar)

    @test occursin("KaimonSlateDesktop", html)
    @test occursin("middle", html)
    @test occursin("q:quit", html)
end

@testitem "native: a widget's class is emitted once" begin
    import ManyUI
    import ManyUIWeb

    # `manyui-<type>` is pushed for every widget from `node.type_name`; pushing
    # it again in a branch produced `class="manyui-datatable manyui-datatable"`.
    rows = [(name = "a", n = 1)]
    table = ManyUI.DataTable(rows, [ManyUI.Column("name"), ManyUI.Column("n")];
                             key = r -> r.name,
                             cell = (r, j) -> j == 1 ? r.name : string(r.n))
    html = ManyUIWeb.to_html(table)

    class_attr = match(r"class=\"([^\"]*)\"", html)
    @test class_attr !== nothing
    names = split(class_attr[1])
    @test length(names) == length(unique(names))
end

@testitem "native: every widget type either shows its content or is knowingly exempt" begin
    import ManyUI, ManyUIWeb
    using ManyUI
    using InteractiveUtils

    # The ratchet for one class of defect: `to_html` walks children, so a widget
    # holding its content in FIELDS renders an empty element — silently, since
    # the element is emitted, just blank. Seven widgets shipped that way before
    # anyone noticed, and only because a real screen was rebuilt.
    #
    # A new widget type must land in one list or the other. Adding it to
    # `EXEMPT` is a decision someone makes on purpose; forgetting is what this
    # test refuses to allow.
    const MARK = "ZZMARKERZZ"

    builders = Dict{Symbol,Function}(
        :Label         => () -> Label(MARK),
        :Static        => () -> Static(RichText(TextRun(MARK))),
        :Button        => () -> Button(MARK, _ -> nothing),
        :Checkbox      => () -> Checkbox(MARK),
        :Container     => () -> Container(Label(MARK)),
        :ErrorBoundary => () -> ErrorBoundary(Label(MARK)),
        :Scrollpane    => () -> Scrollpane(Label(MARK)),
        :Splitter      => () -> Splitter(Label(MARK), Label("b")),
        :Tabs          => () -> Tabs(MARK => Label("panel")),
        :TabStrip      => () -> Tabs(MARK => Label("panel")).strip,
        :StatusBar     => () -> StatusBar(; left = RichText(TextRun(MARK))),
        :MarkdownPane  => () -> MarkdownPane(MARK),
        :ProgressList  => () -> ProgressList([ProgressItem(MARK, 0.5)]),
        :List          => () -> List([MARK]),
        :TextArea      => () -> TextArea(MARK),
        :TextInput     => () -> TextInput(MARK),
    )

    # Each exemption states WHY, because an unexplained one is how a defect hides.
    exempt = Dict{Symbol,String}(
        :Sparkline          => "content is numbers; covered by its own test",
        :ProgressBar        => "content is a fraction, not text",
        :Slider             => "content is a number, not text",
        :Spinner            => "content is a frame of animation",
        :RadioGroup         => "content is its options; covered by DropDown's path",
        :DropDown           => "renders a <select>; options covered separately",
        :DropDownList       => "built inside DropDown, never reached on its own",
        :Scrollbar          => "chrome the browser supplies itself",
        :SplitHandle        => "chrome, no content",
        :MinSizeOverlay     => "chrome shown only when a pane is too small",
        :Form               => "mounts real children through add_field!",
        :ImmediateContainer => "a container; children are mounted",
        :LayoutBox          => "a container; children are mounted",
        :DataTable          => "covered by the table tests",
        :Table              => "covered by the table tests",
        :TreeView           => "covered by the tree tests",
    )

    # Only ManyUI's OWN widgets: other test files define their own `Widget`
    # subtypes as fixtures, and auditing those says nothing about the backend.
    concrete = Type[]
    walk(T) = for S in subtypes(T)
        isabstracttype(S) ? walk(S) :
            (parentmodule(S) === ManyUI && push!(concrete, S))
    end
    walk(ManyUI.Widget)
    @test !isempty(concrete)

    for S in concrete
        name = nameof(S)
        if haskey(builders, name)
            html = ManyUIWeb.to_html(builders[name]())
            @test occursin(MARK, html)
        else
            @test haskey(exempt, name)
        end
    end
end

@testitem "native: a widget can be embedded in a host page as a fragment" begin
    import ManyUI, ManyUIWeb

    # `generate_document` produces a whole page. A host that already owns its
    # document -- a notebook cell, a dashboard, a docs site -- had no supported
    # way to place one widget: `to_html` gave markup with no styles, and the
    # rules lived inside the document function.
    frag = ManyUIWeb.fragment_html(ManyUI.Label("hello"); id = "panel1")

    @test occursin("hello", frag)
    @test occursin("<style>", frag)
    @test occursin("manyui-label", frag)
    # No document furniture: a fragment goes INSIDE someone else's page.
    @test !occursin("<!DOCTYPE", frag)
    @test !occursin("<html", frag)
end

@testitem "native: an embedded fragment cannot restyle its host" begin
    import ManyUI, ManyUIWeb

    # Rules are nested under the fragment's own id, so a host page keeps its
    # own look. Unscoped, `body { … }` alone would repaint the whole page.
    frag = ManyUIWeb.fragment_html(ManyUI.Label("hi"); id = "panel2")
    @test occursin("#panel2", frag)

    # And it must not fetch a remote font: the host owns its typography, and a
    # fetch would fail on an offline install.
    @test !occursin("fonts.googleapis", frag)
end

@testitem "native: a fragment's tabs switch without a live runtime" begin
    import ManyUI, ManyUIWeb

    # A fragment has no `dispatch_event`: that lives in `generate_document`'s
    # client. So the tab strip's handlers pointed at nothing, and — worse —
    # every panel showed at once, because hiding the inactive ones is what the
    # live runtime would have done. Switching a tab is a VIEW concern and every
    # panel is already in the DOM, so the fragment can do it itself.
    tabs = ManyUI.Tabs("One" => ManyUI.Label("first"),
                       "Two" => ManyUI.Label("second"))
    frag = ManyUIWeb.fragment_html(tabs; id = "frag1")

    @test occursin("manyui-tab", frag)
    @test occursin("first", frag) && occursin("second", frag)
    # A behaviour script, and one that does not need the live client.
    @test occursin("manyui-fragment-tabs", frag)
    @test !occursin("dispatch_event(", split(frag, "<script")[end])
end
