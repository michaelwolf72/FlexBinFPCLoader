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
