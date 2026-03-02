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