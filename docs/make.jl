using Documenter, FlexBinFPCLoader

makedocs(
    repo = " ",
    sitename = "FlexBinFPCLoader",
    format = Documenter.HTML(
        prettyurls = false,
        repolink = "..."
    ),
    modules = [FlexBinFPCLoader],
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Use" => "FlexBinFPC_Readme.md",
        "API" => "api.md",
    ]
)
