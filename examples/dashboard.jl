# dashboard.jl -- a filter box driving a list, in a browser.
#
#     julia --project=DualUIWeb DualUIWeb/examples/dashboard.jl
#
# then open http://127.0.0.1:8000/.
#
#   type            to filter
#   enter           to apply the filter
#   tab             to move between the box and the list
#   up/down         to move the cursor, the wheel to scroll
#
# The point of this one is the wiring: a widget's callback mutates
# another widget, that mutation marks only what changed, and the next
# frame sends only the cells that differ.

using DualUI
using DualUIWeb

const LANGUAGES = [
    "Julia", "Python", "Rust", "Go", "C", "C++", "Haskell", "OCaml",
    "Elm", "Elixir", "Erlang", "Clojure", "Scheme", "Common Lisp",
    "Racket", "F#", "Scala", "Kotlin", "Swift", "Zig", "Nim", "Crystal",
    "Ruby", "Perl", "Lua", "JavaScript", "TypeScript", "Fortran",
    "COBOL", "Ada", "Prolog", "Smalltalk", "Forth", "APL", "J",
]

# `shrink: 0` on the three fixed rows is load-bearing, and the reason is
# worth knowing: a `List` measures to the whole viewport, so a column
# holding one asks for more height than it has. Flex then shrinks every
# child that CAN shrink, and with the default `shrink: 1` the labels are
# what give way -- a one-row label becomes a zero-row label and simply
# vanishes. Pinning them makes the list the only thing that yields.
#
# `height: 1` on the filter is its CONTENT height; the border adds the
# two rows around it, for three in total.
const SHEET = parse_css("""
    #screen { layout: column; }
    #title  { color: #7dd3fc; shrink: 0; }
    #filter { border: round #475569; height: 1; shrink: 0; }
    #hits   { color: #94a3b8; shrink: 0; }
    #langs  { grow: 1; }
    List    { color: #e2e8f0; }
""")

"""
The screen. Called once per client, so each browser tab filters its own
copy without disturbing anyone else's.
"""
function dashboard_app()
    list = List(copy(LANGUAGES); id = :langs)
    hits = Label("$(length(LANGUAGES)) of $(length(LANGUAGES))"; id = :hits)

    # `on_submit` fires on ENTER. Filtering is just: recompute the
    # items, hand them over, and let the framework work out what moved.
    filter_box = TextInput("", w -> begin
                               q = lowercase(w.text[])
                               keep = isempty(q) ? copy(LANGUAGES) :
                                   filter(l -> occursin(q, lowercase(l)),
                                          LANGUAGES)
                               set_items!(list, keep)
                               hits.text[] =
                                   "$(length(keep)) of $(length(LANGUAGES))"
                               nothing
                           end;
                           placeholder = "type to filter, enter to apply",
                           id = :filter)

    return Container(
        Label("languages"; id = :title),
        filter_box,
        hits,
        list;
        id = :screen,
    )
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve(dashboard_app; port = port, stylesheet = SHEET,
                   title = "Dashboard")
    println("Dashboard running at ", DualUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        DualUI.stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
