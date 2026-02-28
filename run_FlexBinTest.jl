using FlexBinFPCLoader, DataFrames, XLSX

# Read in MDO File with FlexBinFPC
xlsFileName = "mdoDUFF.xlsx" #"mdoFormat_v0d3.xlsx"
wkDir = raw"C:\Users\mgwolf\Documents\MATLAB\Postflight_FMV\juliaWolfTools\FlexBinFPC"
# dufs = FlexBinFPC.load_DUFs(joinpath(wkDir,xlsFileName))
dufs = load_DUFs(joinpath(wkDir,xlsFileName))

# Define MDO file path
mdoPath = raw"C:\Users\mgwolf\Documents\MATLAB\Postflight_FMV\data\F9"

# Example single run MDO Files
mdoFiles = ["sxTM_FH-009_GNC_26950410_20231229.mdo",
            "sxTM_FH-008_GNC_26127627_20231013.mdo",
            "psyche_xSimNom_FMA_Oct-12_20231011.mdo",
            "H01_FH-008_GNC_26030492_20231006.mdo",
            "IMAP_xSimNom_PGAA-2_20250429.mdo",
            "IMAP_xSimMC_PGAA-2_20250429.mdo",
            "sxTM_F9-235_GNC_24728169_20231127.mdo", # PSN - IMAP Demo
            "PSN_xSimNom_FMA.mdo",   # IMAP Demo XSim nominal
            "sxTM_F9-148_GNC_18081878_20220415.mdo"]

mdo = load_FlexBinFPC(joinpath(mdoPath,mdoFiles[1]),joinpath(wkDir,xlsFileName))

# mdoData = Vector()
# for fn in mdoFiles
#   mdoFile = joinpath(mdoPath,fn)
#   @assert isfile(mdoFile) "Couldn't find file: $mdoFile"
#   rtn = load_mdoFile(mdoFile,dufs)
#   push!(mdoData,rtn)  
# end
