
# --- Column access helpers (DataFrame rows can hold Any/missing) ---

getstr(row, col::Symbol) = hasproperty(row, col) && getproperty(row, col) !== missing ?
                           strip(string(getproperty(row, col))) : ""

getany(row, col::Symbol) = hasproperty(row, col) ? getproperty(row, col) : missing

# --- Primitive type handling ---

const PRIM_TYPES = Set(["Int8","UInt8","Int16","UInt16","Int32","UInt32","Int64","UInt64","Float32","Float64"])

is_primitive_type(typ::AbstractString) = typ in PRIM_TYPES

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

function read_primitive(io::IO, typ::AbstractString, count::Int; endian::Symbol)::Any
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

# --- FlexBinFPC unique types ---

function read_static_str(io::IO, n::Int)::String
    bytes = read(io, n)
    # common binary-header convention: allow NUL-terminated strings
    nul = findfirst(==(0x00), bytes)
    if nul !== nothing
        bytes = bytes[1:(nul-1)]
    end
    return String(Vector{UInt8}(bytes))
end

function read_bitarray(ctx::ParseContext, bit_table_name::AbstractString)::Dict{String,Bool}
    haskey(ctx.DUFs, bit_table_name) || error("BitArray expects a DUF table named '$bit_table_name' listing bit names")
    df = ctx.DUFs[bit_table_name]

    bitnames = String[]
    for r in eachrow(df)
        nm = getstr(r, :varName)
        isempty(nm) && continue
        push!(bitnames, nm)
    end

    nbits  = length(bitnames)
    nbytes = max(1, cld(nbits, 8))
    bytes  = read(ctx.io, nbytes)

    d = Dict{String,Bool}()
    for (i, name) in enumerate(bitnames)
        bit_index   = i - 1
        byte_index  = (bit_index ÷ 8) + 1
        bit_in_byte = bit_index % 8
        d[name] = ((bytes[byte_index] >> bit_in_byte) & 0x01) == 0x01
    end

    return d
end

# --- Scope lookup for Count / Conditional evaluation ---

function lookup_var(scope::Dict{String,Any}, scope_stack::Vector{Dict{String,Any}}, name::String)
    if haskey(scope, name)
        return scope[name]
    end
    for i in length(scope_stack):-1:1
        d = scope_stack[i]
        if haskey(d, name)
            return d[name]
        end
    end
    return nothing
end