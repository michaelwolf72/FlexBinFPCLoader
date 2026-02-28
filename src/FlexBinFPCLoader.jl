module FlexBinFPCLoader

using XLSX, DataFrames

include("readBinFiles.jl")
include("eval_expr.jl")
include("parser.jl")
include("load.jl")

export load_DUFs, load_FlexBinFPC

end # module