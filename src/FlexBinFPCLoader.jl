module FlexBinFPCLoader

using XLSX, DataFrames

include("xlsxDef.jl")
include("readBinFiles.jl")

export load_DUFs, load_FlexBinFPC

end # module