# datatable.jl -- a sortable table of 5000 rows, in a browser.
#
#     julia --project=DualUIWeb DualUIWeb/examples/datatable.jl
#
# then open http://127.0.0.1:8000/.
#
#   up/down, pageup/pagedown, home/end   move the cursor
#   the wheel                            scrolls
#   click a column header                sorts by it (again flips it)
#
# 5000 rows is the point: they are DATA, not 5000 widgets, so the frame
# costs the same as it would for five. Try 5_000_000 if you like -- the
# only thing that grows is the Vector.

using DualUI
using DualUIWeb

const ELEMENTS = [
    ("Hydrogen", "H", 1, 1.008), ("Helium", "He", 2, 4.003),
    ("Lithium", "Li", 3, 6.941), ("Beryllium", "Be", 4, 9.012),
    ("Boron", "B", 5, 10.811), ("Carbon", "C", 6, 12.011),
    ("Nitrogen", "N", 7, 14.007), ("Oxygen", "O", 8, 15.999),
    ("Fluorine", "F", 9, 18.998), ("Neon", "Ne", 10, 20.180),
]

"""
`n` rows built from the periodic table, cycled and numbered, so the
demo has something real to sort without shipping a data file.
"""
function make_rows(n::Int)
    rows = Vector{NTuple{4,Any}}(undef, n)
    for i in 1:n
        (name, sym, z, mass) = ELEMENTS[mod1(i, length(ELEMENTS))]
        rows[i] = ("$name-$i", sym, z + 10 * ((i - 1) ÷ length(ELEMENTS)),
                   round(mass * (1 + i / 1000); digits = 3))
    end
    return rows
end

const COLUMNS = [
    Column("element"; width = cells(18)),
    Column("sym"; width = cells(5), align = Align.CENTER),
    Column("Z"; width = cells(6), align = Align.END),
    Column("mass"; width = fr(1), align = Align.END),
]

const SHEET = parse_css("""
    DataTable { color: #e2e8f0; background: #0f172a; }
""")

"""
The screen: a hint line and the table. Called once per client, so every
browser tab sorts and scrolls independently.
"""
function table_app()
    rows = make_rows(5000)
    dt = DataTable(rows, COLUMNS; key = (r, j) -> r[j], id = :elements)
    node(dt).focusable = true
    return Container(
        Label("$(length(rows)) elements  --  click a header to sort";
              id = :hint),
        dt;
        id = :screen,
    )
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve(table_app; port = port, stylesheet = SHEET,
                   title = "DataTable")
    println("DataTable running at ", DualUIWeb.url(server))
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
