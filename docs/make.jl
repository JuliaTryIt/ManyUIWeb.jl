using Documenter
using ManyUI
using ManyUIWeb

DocMeta.setdocmeta!(ManyUIWeb, :DocTestSetup, :(using ManyUIWeb);
                    recursive = true)

makedocs(;
    modules = [ManyUIWeb],
    sitename = "ManyUIWeb.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/ManyUIWeb.jl",
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
