
# --- Column access helpers (DataFrame rows can hold Any/missing) ---

getstr(row, col::Symbol) = hasproperty(row, col) && getproperty(row, col) !== missing ?
                           strip(string(getproperty(row, col))) : ""

getany(row, col::Symbol) = hasproperty(row, col) ? getproperty(row, col) : missing

# --- Primitive type handling ---

const PRIM_TYPES = Set(["Int8","UInt8","Int16","UInt16","Int32","UInt32","Int64","UInt64","Float32","Float64"])

is_primitive_type(typ::AbstractString) = typ in PRIM_TYPES

"""
    primitive_T(typ::AbstractString) -> DataType

Map a DUF/schema primitive type name (provided as a string) to the
corresponding Julia primitive numeric `DataType`.

Supported type strings:

- `"Int8"`, `"UInt8"`
- `"Int16"`, `"UInt16"`
- `"Int32"`, `"UInt32"`
- `"Int64"`, `"UInt64"`
- `"Float32"`, `"Float64"`

# Errors
Throws an error if `typ` does not match a supported primitive type.

# Examples
```julia
primitive_T("Int16")   # → Int16
primitive_T("Float64") # → Float64
```
"""
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

                                  
"""
    read_T(io::IO, ::Type{T}; endian::Symbol) where {T} -> T

Read a single value of type `T` from the IO stream `io`, applying
endianness conversion for integer types.

The raw value is read using `read(io, T)`. If `T <: Integer`,
byte-order conversion is applied:

- `endian === :little` → `ltoh`
- `endian === :big`    → `ntoh`

Non-integer types (e.g. floating-point values) are returned as read.

# Arguments
- `io`: Input stream
- `T`: Concrete element type
- `endian`: `:little` or `:big`

# Errors
Throws an error if `endian` is not `:little` or `:big`.

# Examples
```julia
x = read_T(io, UInt32; endian=:little)
```
"""

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

"""
    read_primitive(io::IO, typ::AbstractString, count::Int; endian::Symbol) -> Union{T, Vector{T}}

Read one or more primitive values from the IO stream `io`,
where the element type is specified as a string.

The type string `typ` is resolved using [`primitive_T`](@ref).

If `count == 1`, a single scalar value is returned.
If `count > 1`, a `Vector{T}` of length `count` is returned.

# Arguments
- `io`: Input stream
- `typ`: Primitive type name as string
- `count`: Number of elements to read
- `endian`: `:little` or `:big`

# Returns
- Scalar value when `count == 1`
- `Vector{T}` when `count > 1`

# Errors
- If `typ` is not recognized
- If `endian` is invalid
- If the stream cannot be read

# Examples
```julia
val  = read_primitive(io, "UInt16", 1; endian=:little)
vals = read_primitive(io, "Float32", 10; endian=:big)
```
"""
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

"""
    read_static_str(io::IO, n::Int) -> String

Read a fixed-length string field of `n` bytes from the IO stream `io`.

If a NUL byte (`0x00`) is encountered, the string is treated as
NUL-terminated and truncated at the first NUL.

This is commonly used for fixed-width string fields in binary headers.

# Arguments
- `io`: Input stream
- `n`: Number of bytes to read

# Returns
A `String` constructed from the read bytes.

# Examples
```julia
name = read_static_str(io, 32)
```
"""

function read_static_str(io::IO, n::Int)::String
    bytes = read(io, n)
    # common binary-header convention: allow NUL-terminated strings
    nul = findfirst(==(0x00), bytes)
    if nul !== nothing
        bytes = bytes[1:(nul-1)]
    end
    return String(Vector{UInt8}(bytes))
end


"""
    read_bitarray(ctx::ParseContext, bit_table_name::AbstractString) -> Dict{String,Bool}

Read a packed bitfield from the binary stream and return a dictionary
mapping bit names to boolean values.

Bit names and ordering are defined by a DUF table stored in
`ctx.DUFs[bit_table_name]`. The table must contain a `:varName`
column listing the bit names.

Bits are interpreted LSB-first within each byte.

# Arguments
- `ctx`: Parsing context containing `io` and `DUFs`
- `bit_table_name`: Name of DUF table defining bit names

# Returns
`Dict{String,Bool}` mapping each bit name to `true` or `false`.

# Errors
Throws an error if the DUF table is missing or the stream cannot be read.

# Examples
```julia
flags = read_bitarray(ctx, "StatusBits")
flags["is_valid"]  # → true/false
```
"""

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

"""
    lookup_var(scope::Dict{String,Any},
               scope_stack::Vector{Dict{String,Any}},
               name::String) -> Any

Resolve a variable `name` within a nested scope hierarchy.

Lookup order:

1. The current `scope`
2. Each dictionary in `scope_stack`, searched from most recent
   (last element) to oldest
3. Returns `nothing` if not found

This is typically used when evaluating `Count` or `Conditional`
expressions during parsing.

# Arguments
- `scope`: Current scope dictionary
- `scope_stack`: Stack of parent scopes
- `name`: Variable name to resolve

# Returns
The stored value if found, otherwise `nothing`.

# Examples
```julia
value = lookup_var(local_scope, scope_stack, "numElements")
```
"""
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