module FlexBinFPCLoader

using XLSX, DataFrames

include("load.jl")
include("parser.jl")
include("eval_expr.jl")
include("readBinFiles.jl")

export load_DUFs, load_FlexBinFPC

end # module