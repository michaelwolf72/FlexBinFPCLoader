module FlexBinFPCLoader

using XLSX, DataFrames

"""
    load_DUFs(dufFile::AbstractString) -> Dict{String,DataFrame}

Load a FlexBinFPC **Defined User File Format (DUFF)** Excel workbook and return
a dictionary of DUF Tables.

Each worksheet in the DUFF `.xlsx` file is interpreted as a **Defined User
Format (DUF) Table** and converted into a `DataFrame`. The returned dictionary
maps worksheet names (i.e., DUF table names) to their corresponding table
representation:

where:
- **Key**   → DUF Table name (worksheet name)
- **Value** → DUF Table contents as a `DataFrame`

Empty worksheets (i.e., those containing no rows or columns) are skipped.

# Arguments
- `dufFile::AbstractString`: Path to the DUFF `.xlsx` file that defines the
  hierarchical binary schema used by FlexBinFPC to parse file containers.

# Returns
- `Dict{String,DataFrame}`: A dictionary of DUF Tables indexed by sheet name.

# Description
The DUFF workbook defines the hierarchical structure of a FlexBinFPC binary
file container. Each worksheet represents a DUF Table containing schema rows
with required columns such as:


These DUF Tables are later traversed recursively to interpret and load binary
data fields into a mission data object dictionary.

# Examples
```julia
julia> using FlexBinFPCLoader

julia> dufs = load_DUFs("DUFF.xlsx")

julia> keys(dufs)
KeySet for a Dict{String,DataFrame} with 3 entries:
  "header0"
  "mdoHdr"
  "mdoMeasHdr"

julia> dufs["header0"]
5×8 DataFrame
 Row │ varName     Type      Count  Description   Conditional  Argument  Default  Notes
     │ Any         Any       Any    Any           Any          Any       Any      Any
─────┼──────────────────────────────────────────────────────────────────────────────────
   1 │ mdoHdr      mdoHdr        1  Mission ...   missing      missing   missing  missing
   2 │ mdoMeasHdr  mdoMeasHdr    1  Measurement   missing      missing   missing  missing
```
"""
function load_DUFs(dufFile::AbstractString)::Dict{String,DataFrame}
    isfile(dufFile) || error("DUFF XLSX not found: $dufFile")

    duf = Dict{String,DataFrame}()

    XLSX.openxlsx(dufFile) do xf
        for name in XLSX.sheetnames(xf)
            # readtable returns something Tables.jl-compatible
            t = XLSX.readtable(dufFile, name)
            df = DataFrame(t)

            # Optionally skip empty sheets
            (nrow(df) == 0 || ncol(df) == 0) && continue

            duf[string(name)] = df
        end
    end

    return duf
end

end # module