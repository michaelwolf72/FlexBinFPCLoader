"""
    load_FlexBinFPC(binFile::AbstractString, dufFile::AbstractString;
                    toplevel::AbstractString="header0",
                    endian::Symbol=:little) -> Dict{String,Any}

Open and read a FlexBinFPC binary file using a DUFF `.xlsx` schema.

Returns a nested dictionary:
- keys are DUF `varName`s
- values are:
  - primitive scalars/vectors
  - FlexBinFPC unique types:
      * `StaticStr` => `String`
      * `BitArray`  => `Dict{String,Bool}`
  - nested DUF tables (`Dict{String,Any}`) or vectors of nested dicts

Notes:
- This implementation supports `Count` as:
  - an integer literal (e.g., `8`)
  - a previously parsed integer `varName` (e.g., `numRun`)
  - simple arithmetic: `+ - * /` and parentheses (integer math)
- `Conditional` is supported in a minimal way (`varName`, `varName == 3`, `varName != 0`).

Extend points:
- `remBytes` / `remBytesHdr` style counts typically require bounding a table region.
  You can add region-tracking once your DUFF conventions are finalized.
"""
function load_FlexBinFPC(binFile::AbstractString, dufFile::AbstractString;
                         toplevel::AbstractString="header0",
                         endian::Symbol=:little)::Dict{String,Any}

    isfile(binFile) || error("Binary file not found: $binFile")

    DUFs = load_DUFs(dufFile)
    haskey(DUFs, toplevel) || error("Top-level DUF table '$toplevel' not found in DUFF")

    open(binFile, "r") do io
        ctx = ParseContext(io, DUFs, endian)
        return parse_table(ctx, toplevel, Dict{String,Any}(); scope_stack=Vector{Dict{String,Any}}())
    end
end

# -------------------------------------------------------------------
# Internal machinery
# -------------------------------------------------------------------

struct ParseContext
    io::IO
    DUFs::Dict{String,DataFrame}
    endian::Symbol
end

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

"""
    eval_bool(scope, scope_stack, expr::AbstractString) -> Bool

Evaluate a DUF `Conditional` expression to determine whether a row should be
parsed from the binary file.

Supported conditional forms include:

- Variable truthiness:

Interpreted as `true` if the referenced variable exists and is:
- `true`
- or a non-zero integer

- Equality / Inequality:

Variable values are resolved first from the current DUF Table's `scope` and
then from parent scopes stored in `scope_stack`.

Rows whose condition evaluates to `false` are skipped during parsing.

This mechanism enables DUF Tables to specify conditional binary layouts based
on previously parsed header fields.

# Minimal conditional evaluation:
# - "flag"            => truthy
# - "x == 3" / "x != 0"
"""
function eval_bool(scope, scope_stack, s::AbstractString)::Bool
    ss = strip(s)
    isempty(ss) && return true

    if occursin("==", ss) || occursin("!=", ss)
        op = occursin("==", ss) ? "==" : "!="
        a, b = strip.(split(ss, op; limit=2))
        av = lookup_var(scope, scope_stack, a)
        bv = occursin(r"^\d+$", b) ? parse(Int, b) : lookup_var(scope, scope_stack, b)
        bv === nothing && (bv = b)
        return op == "==" ? (av == bv) : (av != bv)
    end

    v = lookup_var(scope, scope_stack, ss)
    v === nothing && return false
    return v == true || (v isa Integer && v != 0)
end

"""
    eval_count(scope, scope_stack, count_expr::AbstractString; default=1) -> Int

Evaluate the DUF `Count` field for a variable definition.

The `Count` determines how many elements of the associated `Type` should be
read from the binary stream.

Supported formats include:

- Empty string:
  Uses the provided `default` value (typically 1).

- Integer literal:

- Variable reference:

The referenced variable must already be parsed and must be an integer.

- Simple arithmetic expression:

Expressions may include:
- `+`, `-`, `*`, `/`
- Parentheses for grouping
- References to previously parsed integer variables

Variables are resolved from the current `scope` and parent scopes via
`scope_stack`.

This allows DUF Tables to define dynamic array sizes within the binary format.
"""
# Count evaluation:
# - "" => default=1
# - integer literal
# - varName referencing an Integer
# - simple arithmetic + - * / with parentheses (integer division via fld)
function eval_count(scope, scope_stack, s::AbstractString; default::Int=1)::Int
    ss = strip(s)
    isempty(ss) && return default

    if occursin(r"^\d+$", ss)
        return parse(Int, ss)
    end

    if occursin(r"^[A-Za-z_]\w*$", ss)
        v = lookup_var(scope, scope_stack, ss)
        v === nothing && error("Count references '$ss' but it is not defined yet in scope")
        v isa Integer || error("Count references '$ss' but it is not an Integer (got $(typeof(v)))")
        return Int(v)
    end

    return eval_simple_arith(scope, scope_stack, ss)
end

# Tiny arithmetic evaluator: expr := term ((+|-) term)* ; term := factor ((*|/) factor)* ; factor := INT | VAR | '(' expr ')'
function tokenize_expr(s::AbstractString)
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

"""
    eval_simple_arith(scope, scope_stack, expr::AbstractString) -> Int

Evaluate a simple integer arithmetic expression used within a DUF `Count`
field.

Expressions may include:
- Integer literals
- Previously parsed variable names
- Operators: `+`, `-`, `*`, `/`
- Parentheses

Variable references are resolved using `scope` and `scope_stack`. Division
is performed using integer floor division (`fld`).

This function provides safe, restricted expression evaluation for DUF Count
fields without executing arbitrary Julia code.
"""
function eval_simple_arith(scope, scope_stack, expr::AbstractString)::Int
    toks = tokenize_expr(expr)
    pos = Ref(1)
    val = parse_expr(scope, scope_stack, toks, pos)
    pos[] <= length(toks) && error("Unexpected token '$(toks[pos[]])' in Count expression '$expr'")
    return val
end

"""
    parse_expr(scope, scope_stack, tokens, pos) -> Int

Parse and evaluate an additive expression (`+` / `-`) from a tokenized DUF
`Count` expression.

This function implements the top level of a recursive descent parser:

    expr := term ((+|-) term)*

It delegates multiplication and division operations to `parse_term`.
"""
function parse_expr(scope, scope_stack, toks, pos)
    v = parse_term(scope, scope_stack, toks, pos)
    while pos[] <= length(toks) && (toks[pos[]] == "+" || toks[pos[]] == "-")
        op = toks[pos[]]; pos[] += 1
        rhs = parse_term(scope, scope_stack, toks, pos)
        v = op == "+" ? (v + rhs) : (v - rhs)
    end
    return v
end

"""
    parse_term(scope, scope_stack, tokens, pos) -> Int

Parse and evaluate a multiplicative expression (`*` / `/`) from a tokenized
DUF `Count` expression.

Implements:

    term := factor ((*|/) factor)*

Delegates atomic value parsing to `parse_factor`.
"""
function parse_term(scope, scope_stack, toks, pos)
    v = parse_factor(scope, scope_stack, toks, pos)
    while pos[] <= length(toks) && (toks[pos[]] == "*" || toks[pos[]] == "/")
        op = toks[pos[]]; pos[] += 1
        rhs = parse_factor(scope, scope_stack, toks, pos)
        if op == "*"
            v *= rhs
        else
            v = fld(v, rhs)
        end
    end
    return v
end

"""
    parse_factor(scope, scope_stack, tokens, pos) -> Int

Parse and evaluate an atomic element of a DUF `Count` expression.

A factor may be:

- Integer literal
- Variable reference
- Parenthesized sub-expression

Variable references are resolved using the current `scope` and parent scopes.
Errors are raised if referenced variables are undefined or non-integer.

Implements:

    factor := INT | VAR | '(' expr ')'
"""
function parse_factor(scope, scope_stack, toks, pos)
    pos[] <= length(toks) || error("Unexpected end of Count expression")
    t = toks[pos[]]; pos[] += 1

    if t == "("
        v = parse_expr(scope, scope_stack, toks, pos)
        pos[] <= length(toks) && toks[pos[]] == ")" || error("Missing ')' in Count expression")
        pos[] += 1
        return v
    elseif occursin(r"^\d+$", t)
        return parse(Int, t)
    elseif occursin(r"^[A-Za-z_]\w*$", t)
        v = lookup_var(scope, scope_stack, t)
        v === nothing && error("Unknown variable '$t' in Count expression")
        v isa Integer || error("Variable '$t' used in Count expression is not Integer (got $(typeof(v)))")
        return Int(v)
    else
        error("Bad token '$t' in Count expression")
    end
end

# --- Core recursive parser ---

"""
    parse_table(ctx::ParseContext, tablename::AbstractString, scope::Dict{String,Any};
                scope_stack::Vector{Dict{String,Any}}) -> Dict{String,Any}

Recursively parse a DUF Table and its associated binary data from the active
FlexBinFPC file stream.

This function interprets a DUF Table (represented as a `DataFrame`) as a
hierarchical schema describing how to read structured binary data. Each row
within the DUF Table represents a variable definition (`varName`) whose
associated `Type` determines how the binary file is interpreted:

- **Primitive Types** (e.g., `UInt64`, `Float32`)  
  A binary read operation is performed using the row's `Count`.

- **FlexBinFPC Unique Types**
  - `StaticStr` → Reads `Count` bytes and returns an ASCII string.
  - `BitArray`  → Reads packed boolean flags using a DUF Table whose name
                  matches the current row's `varName`.

- **Composite Types**  
  If the `Type` matches another DUF Table name, this function calls itself
  recursively to interpret the nested structure.

The resulting data are accumulated into a nested dictionary whose keys are the
DUF `varName`s and whose values are either primitives, unique data types, or
further nested dictionaries.

# Scope
- `scope` contains variables parsed within the current DUF Table.
- `scope_stack` maintains parent scopes to allow child DUF Tables to reference
  previously parsed variables (e.g., in `Count` or `Conditional` expressions).

This enables DUF Tables to define hierarchical, interdependent binary layouts.
"""
function parse_table(ctx::ParseContext, tablename::AbstractString, scope::Dict{String,Any};
                     scope_stack::Vector{Dict{String,Any}})::Dict{String,Any}

    haskey(ctx.DUFs, tablename) || error("DUF table '$tablename' not found in DUFF")
    df = ctx.DUFs[tablename]

    # push current scope so children can reference it
    push!(scope_stack, scope)
    local out = Dict{String,Any}()

    for r in eachrow(df)
        var = getstr(r, :varName)
        isempty(var) && continue

        typ = getstr(r, :Type)
        isempty(typ) && continue

        cond = getstr(r, :Conditional)
        if !isempty(cond) && !eval_bool(out, scope_stack, cond)
            continue
        end

        cnt_raw = getstr(r, :Count)
        count = eval_count(out, scope_stack, cnt_raw; default=1)

        # Dispatch by Type
        value =
            if is_primitive_type(typ)
                read_primitive(ctx.io, typ, count; endian=ctx.endian)

            elseif typ == "StaticStr"
                read_static_str(ctx.io, count)

            elseif typ == "BitArray"
                # Per spec: BitArray uses the DUF table named by varName to define bits
                read_bitarray(ctx, var)

            else
                # Treat as nested DUF table
                if count == 1
                    parse_table(ctx, typ, out; scope_stack=scope_stack)
                else
                    vec = Vector{Dict{String,Any}}(undef, count)
                    for i in 1:count
                        vec[i] = parse_table(ctx, typ, out; scope_stack=scope_stack)
                    end
                    vec
                end
            end

        out[var] = value
    end

    pop!(scope_stack)
    return out
end
