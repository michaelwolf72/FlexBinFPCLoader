module FlexBinFPCLoader

using XLSX, DataFrames

"""
    load_flexbinfpc(binfile::AbstractString, duff_xlsx::AbstractString;
                    toplevel::AbstractString="header0",
                    endian::Symbol=:little) -> Dict{String,Any}

Load a FlexBinFPC binary file into a dictionary using a DUFF XLSX schema.

Assumptions (per your doc):
- DUFF XLSX contains sheets (DUF tables) with required columns:
  varName, Type, Count, Description, Conditional, Argument, Default, Notes
- Parsing starts at the `toplevel` sheet (default `"header0"`)
- A binary read occurs only when `Type` is a primitive (e.g. UInt64, Int64, Float64...)
- Otherwise:
  - If `Type == "StaticStr"`: read Count bytes and convert to ASCII string
  - If `Type == "BitArray"`: read enough bytes to cover boolean flags defined
    in a DUF table named by `varName` (LSB->MSB over rows)
  - Else: treat `Type` as another DUF table name and recurse.

This is a framework: extend `is_primitive_type` and `read_primitive`
as your format grows (e.g., endianness, arrays, structs, etc.).
"""
function load_flexbinfpc(binfile::AbstractString, duff_xlsx::AbstractString;
                         toplevel::AbstractString="header0",
                         endian::Symbol=:little)::Dict{String,Any}
    duff = read_duff_tables(duff_xlsx)

    isfile(binfile) || error("Binary file not found: $binfile")
    haskey(duff, toplevel) || error("Top-level DUF table '$toplevel' not found in DUFF XLSX")

    out = Dict{String,Any}()

    open(binfile, "r") do io
        ctx = ParseContext(out, duff, io, endian)
        parse_table!(ctx, toplevel)
    end

    return out
end

# ----------------------------
# Internal types / helpers
# ----------------------------

struct ParseContext
    out::Dict{String,Any}
    tables::Dict{String,Vector{Dict{String,Any}}}  # sheet => rows (each row is Dict col=>val)
    io::IO
    endian::Symbol
end

"""
    load_DUFs(xlsx_path::AbstractString) -> Vector{Dict{String,DataFrame}}

Load the DUFF XLSX file and return a vector of dictionaries where each element
corresponds to one DUF table (sheet). Each dictionary has a single entry:

    Dict(sheetname => DataFrame)

The vector order matches the workbook's sheet order.
"""
function load_DUFs(xlsx_path::AbstractString)::Vector{Dict{String,DataFrame}}
    isfile(xlsx_path) || error("DUFF XLSX not found: $xlsx_path")

    out = Vector{Dict{String,DataFrame}}()

    XLSX.openxlsx(xlsx_path) do xf
        for sheetname in XLSX.sheetnames(xf)
            sh = xf[sheetname]
            df = sheet_to_dataframe(sh)

            # Skip completely empty sheets (no columns or no rows)
            if ncol(df) == 0 || nrow(df) == 0
                continue
            end

            push!(out, Dict(string(sheetname) => df))
        end
    end

    return out
end

# --------------------------
# Helpers
# --------------------------

"""
Convert an XLSX worksheet into a DataFrame using the first row as column names
(as returned by XLSX.gettable). Drops rows that are entirely empty/missing.
"""
function sheet_to_dataframe(sh::XLSX.Worksheet)::DataFrame
    tbl = XLSX.gettable(sh; infer_eltypes=false)

    hdrs_raw = tbl.column_labels
    data_raw = tbl.data

    # Empty sheet / no table
    if hdrs_raw === nothing || data_raw === nothing
        return DataFrame()
    end

    # Normalize headers -> Strings (blank headers become "")
    hdrs_all = [h === missing ? "" : strip(string(h)) for h in hdrs_raw]
    ndecl = length(hdrs_all)

    # Keep only columns with non-empty headers
    keep_col = [hdrs_all[j] != "" for j in 1:ndecl]
    if all(!k for k in keep_col)
        return DataFrame()
    end

    hdrs = hdrs_all[keep_col]
    nkeep = length(hdrs)

    # Collect rows safely (guard against UndefRefError)
    rows = Vector{Vector{Any}}()
    for r in data_raw
        rr = Vector{Any}(undef, nkeep)
        k = 0

        for j in 1:ndecl
            keep_col[j] || continue
            k += 1

            v = missing
            # Safely attempt to access cell j (can throw UndefRefError)
            try
                v = r[j]
            catch
                v = missing
            end

            rr[k] = v
        end

        # Drop rows that are entirely missing/empty-string
        isempty_row = true
        for v in rr
            if !(v === missing || v == "")
                isempty_row = false
                break
            end
        end
        isempty_row && continue

        push!(rows, rr)
    end

    # Build DataFrame column-wise
    if isempty(rows)
        return DataFrame([Any[] for _ in 1:nkeep], hdrs)
    end

    cols = [Vector{Any}(undef, length(rows)) for _ in 1:nkeep]
    for irow in 1:length(rows)
        rr = rows[irow]
        @inbounds for j in 1:nkeep
            cols[j][irow] = rr[j]
        end
    end

    return DataFrame(cols, hdrs)
end

# Convert a sheet into row dicts, using first row as headers
function sheet_to_rows(sh::XLSX.Worksheet)
    tbl  = XLSX.gettable(sh; infer_eltypes=false)
    hdrs = String.(tbl.column_labels)

    out = Vector{Dict{String,Any}}()

    for r in tbl.data
        row = Dict{String,Any}()
        allmissing = true

        for (h, v) in zip(hdrs, r)
            row[h] = v
            allmissing &= (v === missing || v == "")
        end

        allmissing && continue
        push!(out, row)
    end

    return out
end
# ---- DUF parsing ----

function parse_table!(ctx::ParseContext, tablename::AbstractString)
    rows = get(ctx.tables, tablename, nothing)
    rows === nothing && error("DUF table '$tablename' not found in DUFF XLSX")

    for row in rows
        var = str_or_empty(row, "varName")
        isempty(var) && continue

        typ  = str_or_empty(row, "Type")
        cnts = str_or_empty(row, "Count")
        cond = str_or_empty(row, "Conditional")

        # Optional conditional parsing
        if !isempty(cond)
            ok = eval_bool_expr(ctx.out, cond)
            ok || continue
        end

        count = eval_count(ctx.out, cnts; default=1)

        # Dispatch
        if is_primitive_type(typ)
            ctx.out[var] = read_primitive(ctx.io, typ, count; endian=ctx.endian)

        elseif typ == "StaticStr"
            # Count = number of bytes/chars
            ctx.out[var] = read_static_str(ctx.io, count)

        elseif typ == "BitArray"
            # The bit names come from a DUF table named by varName (per your doc)
            ctx.out[var] = read_bitarray(ctx, var)

        else
            # Treat as user-defined composite (DUF table) and recurse
            # If Count>1 you may want vector-of-composites; we support that.
            if count == 1
                parse_table!(ctx, typ)
            else
                # For composites repeated `count` times, store as Vector of Dict snapshots
                comps = Vector{Dict{String,Any}}(undef, count)
                for i in 1:count
                    before = deepcopy(ctx.out)  # snapshot to isolate each composite if desired
                    parse_table!(ctx, typ)
                    after = deepcopy(ctx.out)
                    comps[i] = Dict(k => after[k] for k in keys(after) if get(before, k, nothing) != after[k])
                end
                ctx.out[var] = comps
            end
        end
    end

    return nothing
end

# ---- Primitive reading ----

function is_primitive_type(typ::AbstractString)
    typ in ("Int8","UInt8","Int16","UInt16","Int32","UInt32","Int64","UInt64","Float32","Float64")
end

function read_primitive(io::IO, typ::AbstractString, count::Int; endian::Symbol=:little)
    T = primitive_T(typ)
    if count == 1
        return read_T(io, T; endian=endian)
    else
        a = Vector{T}(undef, count)
        for i in 1:count
            a[i] = read_T(io, T; endian=endian)
        end
        return a
    end
end

primitive_T(typ::AbstractString) = typ == "Int8"    ? Int8  :
                                  typ == "UInt8"   ? UInt8 :
                                  typ == "Int16"   ? Int16 :
                                  typ == "UInt16"  ? UInt16 :
                                  typ == "Int32"   ? Int32 :
                                  typ == "UInt32"  ? UInt32 :
                                  typ == "Int64"   ? Int64 :
                                  typ == "UInt64"  ? UInt64 :
                                  typ == "Float32" ? Float32 :
                                  typ == "Float64" ? Float64 :
                                  error("Unknown primitive type: $typ")

# Endianness-aware scalar read
function read_T(io::IO, ::Type{T}; endian::Symbol) where {T}
    x = read(io, T)
    if endian === :little
        return x isa Integer ? ltoh(x) : x
    elseif endian === :big
        return x isa Integer ? ntoh(x) : x
    else
        error("endian must be :little or :big, got $endian")
    end
end

# ---- FlexBinFPC unique types ----

read_static_str(io::IO, n::Int) = String(Vector{UInt8}(read(io, n)))

function read_bitarray(ctx::ParseContext, varname::AbstractString)
    bitrows = get(ctx.tables, varname, nothing)
    bitrows === nothing && error("BitArray '$varname' expects a DUF table named '$varname' defining bit names")

    # Each row's varName is a bit label; order is LSB->MSB
    bitnames = String[]
    for r in bitrows
        nm = str_or_empty(r, "varName")
        isempty(nm) && continue
        push!(bitnames, nm)
    end

    nbits   = length(bitnames)
    nbytes  = max(1, cld(nbits, 8))
    bytes   = read(ctx.io, nbytes)

    # Map bits into Dict{String,Bool}
    d = Dict{String,Bool}()
    for (i, name) in enumerate(bitnames)
        bit_index  = i - 1
        byte_index = (bit_index ÷ 8) + 1
        bit_in_byte = bit_index % 8
        d[name] = ((bytes[byte_index] >> bit_in_byte) & 0x01) == 0x01
    end

    return d
end

# ---- Expression helpers ----
# Minimal, safe-ish count evaluation: supports:
# - integers
# - a previously-parsed varName that is an integer
# - simple expressions with + - * / and parentheses
#
# Example: "numRun * (numMeas + 1)"
#
# NOTE: This intentionally does NOT allow arbitrary Julia evaluation.

function eval_count(vars::Dict{String,Any}, s::AbstractString; default::Int=1)::Int
    ss = strip(s)
    isempty(ss) && return default

    # direct integer?
    if occursin(r"^\d+$", ss)
        return parse(Int, ss)
    end

    # variable reference?
    if occursin(r"^[A-Za-z_]\w*$", ss) && haskey(vars, ss)
        v = vars[ss]
        v isa Integer || error("Count '$ss' references '$ss' but it is not an Integer (got $(typeof(v)))")
        return Int(v)
    end

    # expression: tokenize and evaluate
    return eval_simple_arith(vars, ss)
end

function eval_bool_expr(vars::Dict{String,Any}, s::AbstractString)::Bool
    # Minimal support: allow "varName" (truthy), "varName == 3", "varName != 0"
    ss = strip(s)
    isempty(ss) && return true

    if occursin("==", ss) || occursin("!=", ss)
        op = occursin("==", ss) ? "==" : "!="
        a, b = strip.(split(ss, op; limit=2))
        av = get(vars, a, nothing)
        bv = occursin(r"^\d+$", b) ? parse(Int, b) : get(vars, b, b)
        return op == "==" ? (av == bv) : (av != bv)
    end

    v = get(vars, ss, false)
    return v == true || (v isa Integer && v != 0)
end

# Very small expression evaluator for + - * / (integers) with parentheses
function eval_simple_arith(vars::Dict{String,Any}, expr::AbstractString)::Int
    toks = tokenize(expr)
    pos = Ref(1)
    val = parse_expr(vars, toks, pos)
    pos[] <= length(toks) && error("Unexpected token: $(toks[pos[]]) in expression '$expr'")
    return val
end

function tokenize(s::AbstractString)
    out = String[]
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
        elseif c in ('+','-','*','/','(',')')
            push!(out, string(c))
            i = nextind(s, i)
        else
            j = i
            while j <= lastindex(s) && (isalnum(s[j]) || s[j] == '_')
                j = nextind(s, j)
            end
            push!(out, strip(s[i:prevind(s, j)]))
            i = j
        end
    end
    return out
end

# Grammar:
# expr := term ((+|-) term)*
# term := factor ((*|/) factor)*
# factor := INT | VAR | '(' expr ')'

function parse_expr(vars, toks, pos)
    v = parse_term(vars, toks, pos)
    while pos[] <= length(toks) && (toks[pos[]] == "+" || toks[pos[]] == "-")
        op = toks[pos[]]; pos[] += 1
        rhs = parse_term(vars, toks, pos)
        v = op == "+" ? (v + rhs) : (v - rhs)
    end
    return v
end

function parse_term(vars, toks, pos)
    v = parse_factor(vars, toks, pos)
    while pos[] <= length(toks) && (toks[pos[]] == "*" || toks[pos[]] == "/")
        op = toks[pos[]]; pos[] += 1
        rhs = parse_factor(vars, toks, pos)
        op == "*" && (v *= rhs)
        op == "/" && (v = fld(v, rhs))
    end
    return v
end

function parse_factor(vars, toks, pos)
    pos[] <= length(toks) || error("Unexpected end of expression")
    t = toks[pos[]]; pos[] += 1

    if t == "("
        v = parse_expr(vars, toks, pos)
        pos[] <= length(toks) && toks[pos[]] == ")" || error("Missing ')' in expression")
        pos[] += 1
        return v
    elseif occursin(r"^\d+$", t)
        return parse(Int, t)
    elseif occursin(r"^[A-Za-z_]\w*$", t)
        haskey(vars, t) || error("Unknown variable '$t' in expression")
        v = vars[t]
        v isa Integer || error("Variable '$t' used in expression but is not Integer (got $(typeof(v)))")
        return Int(v)
    else
        error("Bad token '$t' in expression")
    end
end

str_or_empty(row::Dict{String,Any}, key::AbstractString) =
    (haskey(row, key) && row[key] !== missing) ? strip(string(row[key])) : ""

end # module