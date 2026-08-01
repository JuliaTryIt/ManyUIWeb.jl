# unicode.jl -- wide characters, combining marks and graphemes, in a
# browser.
#
#     julia --project=ManyUIWeb ManyUIWeb/examples/unicode.jl
#
# This is the demo worth looking at closely. A terminal grid is not a
# string: an emoji or a CJK ideograph occupies TWO cells, a combining
# mark occupies NONE, and getting either wrong corrupts every column to
# the right of the mistake.
#
# The table below is the test: if the columns line up, the width model
# is right. If anything is off by one, it is wrong -- and you can see it
# without reading a single assertion.
#
# `Base.textwidth` gets several of these wrong, which is why ManyUI has
# `text_width` and `grapheme_width` of its own. The last column shows
# what it would have said.

using ManyUI, ManyUITUI
using ManyUIWeb

"""
Each case: the text, what it is, and what should be true of it.
"""
const CASES = [
    ("a",          "ASCII",              1),
    ("é",          "precomposed",        1),
    ("é",          "e + combining acute", 1),
    ("漢",         "CJK ideograph",      2),
    ("字",         "CJK ideograph",      2),
    ("か",         "hiragana",           2),
    ("ｆ",         "fullwidth latin",    2),
    ("❤️",         "emoji + VS16",       2),
    ("☝️",         "emoji + VS16",       2),
    ("😀",         "emoji",              2),
    ("👨‍👩‍👧‍👦",        "ZWJ family",         2),
    ("🇫🇷",         "regional indicators", 2),
]

const COLUMNS = [
    Column("text"; width = cells(8), align = Align.CENTER),
    Column("what it is"; width = cells(21)),
    Column("cells"; width = cells(6), align = Align.END),
    Column("bytes"; width = cells(6), align = Align.END),
    Column("textwidth"; width = cells(10), align = Align.END),
]

const SHEET = parse_css("""
    #screen { layout: column; }
    #title  { color: #7dd3fc; shrink: 0; }
    #note   { color: #94a3b8; shrink: 0; }
    #ruler  { color: #475569; shrink: 0; }
    #bars   { color: #fbbf24; shrink: 0; }
    #grid   { grow: 1; }
    Table   { color: #e2e8f0; }
""")

"""
A row per case: the glyph, its description, our width, its byte length,
and what `Base.textwidth` would have claimed.
"""
make_rows() =
    [(t, what, string(text_width(t)), string(ncodeunits(t)),
      string(textwidth(t)))
     for (t, what, _) in CASES]

"""
Every case between bars, one per line. Because each glyph sits in a
2-cell slot, the closing bars form a straight vertical line -- IF the
width model is right. A misjudged width bends the line, visibly.
"""
function bar_lines()
    out = String[]
    for (t, _, _) in CASES
        pad = " "^max(0, 2 - text_width(t))
        push!(out, "|$(t)$(pad)|")
    end
    return join(out, " ")
end

function unicode_app()
    rows = make_rows()
    tbl = Table(rows, COLUMNS; id = :grid)
    node(tbl).focusable = true
    return Container(
        Label("unicode & graphemes"; id = :title),
        Label("a wide glyph takes 2 cells; a combining mark takes 0"; id = :note),
        Label("1234567890" ^ 6; id = :ruler),
        Label(bar_lines(); id = :bars),
        tbl;
        id = :screen,
    )
end

function main()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8000
    server = serve(unicode_app; port = port, stylesheet = SHEET,
                   title = "Unicode & graphemes")
    println("Unicode demo running at ", ManyUIWeb.url(server))
    println("Ctrl-C to stop.")
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        ManyUITUI.stop!(server)
        println("stopped")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
