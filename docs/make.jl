using Documenter
using DualUI
using DualUIWeb

DocMeta.setdocmeta!(DualUIWeb, :DocTestSetup, :(using DualUIWeb);
                    recursive = true)

makedocs(;
    modules = [DualUIWeb],
    sitename = "DualUIWeb.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/DualUIWeb.jl",
        edit_link = nothing,
        repolink = nothing,
    ),
    # The package is not in a git checkout yet, so there is no remote to
    # infer source links from. Drop them rather than guess a URL that
    # would 404.
    remotes = nothing,
    pages = [
        "Home" => "index.md",
        "Sessions" => "sessions.md",
        "API reference" => "api.md",
    ],
    checkdocs = :exports,
    warnonly = false,
)
