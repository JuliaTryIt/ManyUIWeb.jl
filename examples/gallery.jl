# gallery.jl -- every ManyUI widget on one page, in a browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/gallery.jl
#
#   tab / shift-tab   move focus between the interactive ones
#   arrows, wheel     drive whichever has focus
#
# This is the conformance page: if a widget renders wrong, it is wrong
# HERE, visibly, without reading a test. It is also the honest inventory
# -- what is on this page is what ManyUI has.

using ManyUI
using ManyUIWeb

const SHEET = parse_css("""
    #screen  { layout: column; padding: 1; }
    #title   { color: #7dd3fc; shrink: 0; }
    #row1    { layout: row; height: 7; gap: 1; shrink: 0; }
    #row2    { layout: row; height: 8; gap: 1; shrink: 0; }
    #status  { color: #94a3b8; shrink: 0; }

    #texts   { border: round #475569; width: 1fr; }
    #inputs  { border: round #475569; width: 1fr; }
    #listbox { border: round #475569; width: 1fr; }
    #tablebox{ border: round #475569; width: 2fr; }

    Label    { color: #e2e8f0; }
    Static   { color: #cbd5e1; }
    Button   { color: #bbf7d0; }
    List     { color: #e2e8f0; }
    Table    { color: #e2e8f0; }
    DataTable{ color: #e2e8f0; }
""")

const ROWS = [("Ada", 1815, "England"), ("Alan", 1912, "England"),
              ("Grace", 1906, "USA"), ("Edsger", 1930, "Netherlands"),
              ("Barbara", 1936, "USA")]

const COLS = [Column("who"; width = cells(9)),
              Column("born"; width = cells(6), align = Align.END),
              Column("where"; width = fr(1))]

"""
The gallery. Called once per client, so two tabs can be driven
independently.
"""
function gallery_app()
    presses = Ref(0)
    status = Label("ready"; id = :status)

    btn = Button("press me", w -> begin
                     presses[] += 1
                     status.text[] = "button pressed $(presses[]) times"
                     nothing
                 end; id = :btn)

    input = TextInput("", w -> begin
                          status.text[] = "submitted: $(w.text[])"
                          nothing
                      end; placeholder = "type, then enter", id = :input)

    area = TextArea("multi-line\nTextArea\n漢字 and 👨‍👩‍👧‍👦"; id = :area)

    lst = List(["alpha", "beta", "gamma", "delta", "epsilon", "zeta"];
               id = :list)

    tbl = DataTable(ROWS, COLS; key = (r, j) -> r[j], id = :table)

    # Wrapping text vs non-wrapping, side by side.
    texts = Container(
        Label("Label wraps its text onto as many lines as it needs";
              id = :lbl),
        Static("Static does not wrap"; id = :stat),
        btn;
        id = :texts,
    )

    inputs = Container(input, area; id = :inputs)
    listbox = Container(lst; id = :listbox)
    tablebox = Container(tbl; id = :tablebox)

    return Container(
        Label("ManyUI widget gallery  --  tab to move focus"; id = :title),
        Container(texts, inputs; id = :row1),
        Container(listbox, tablebox; id = :row2),
        status;
        id = :screen,
    )
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve(gallery_app; port = port, stylesheet = SHEET,
                   title = "ManyUI gallery")
    println("Gallery running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        ManyUI.stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
