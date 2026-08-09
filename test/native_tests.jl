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
