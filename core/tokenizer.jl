# ================================================================
# FILE: core/tokenizer.jl
#
# Tokenizer — Stage 1 of the engine pipeline.
#
# Responsibility: parse raw user input into a PhysicalQuery.
# This file knows NOTHING about physics, solvers, or dispatch.
# It only knows how to extract structure from text or dicts.
#
# Supported string format:
#   "[verb] <command> [key=value ...]"
#
#   verb       : optional — get | find | compute | calculate | solve
#   command    : the physics operation to perform
#   key=value  : parameter pairs; values auto-typed:
#                  [x,y,z]   → Vector{Float64}
#                  1.5, 1e-9 → Float64
#                  2         → Int64
#                  text      → String
#
# Examples:
#   "get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]"
#   "coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]"
# ================================================================

# Leading verbs stripped before command extraction
const RECOGNIZED_VERBS = ("get", "find", "compute", "calculate", "solve",
                           "determine", "evaluate", "derive")

"""
    tokenize(raw::AbstractString) :: PhysicalQuery

Parse a command string into a structured PhysicalQuery.
Throws ArgumentError if the input is malformed.
"""
function tokenize(raw::AbstractString) :: PhysicalQuery
    s = strip(raw)
    isempty(s) && throw(ArgumentError(
        "Tokenizer received empty input — nothing to parse."))

    # Split on whitespace, respecting bracket groups for vectors
    tokens = _split_respecting_brackets(s)
    isempty(tokens) && throw(ArgumentError("No tokens found in input."))

    # Strip optional leading verb
    idx = 1
    if lowercase(tokens[1]) ∈ RECOGNIZED_VERBS
        length(tokens) < 2 && throw(ArgumentError(
            "Verb '$(tokens[1])' found but no command follows it."))
        idx = 2
    end

    command_str = tokens[idx]
    command     = Symbol(lowercase(command_str))

    # Parse remaining tokens as key=value pairs
    params = Dict{Symbol, Any}()
    for token in tokens[idx+1:end]
        isempty(strip(token)) && continue
        _parse_param!(params, token)
    end

    PhysicalQuery(command, params, String(raw))
end

"""
    tokenize(raw::Dict{String,Any}) :: PhysicalQuery

Accept a pre-structured Dict. Must contain a "command" key.
All other entries become the params dict.

Example:
    tokenize(Dict("command"=>"electric_field",
                  "charge"=>1e-9,
                  "source"=>[0.0,0.0,0.0],
                  "field_point"=>[1.0,0.0,0.0]))
"""
function tokenize(raw::Dict{String, Any}) :: PhysicalQuery
    haskey(raw, "command") || throw(ArgumentError(
        "Dict input must contain a \"command\" key."))

    command = Symbol(lowercase(strip(raw["command"])))
    params  = Dict{Symbol, Any}(
        Symbol(k) => v
        for (k, v) in raw
        if k != "command"
    )
    PhysicalQuery(command, params, repr(raw))
end

# ── Private helpers ───────────────────────────────────────────────────────────

"""
Split a string on whitespace but keep `[...]` vector literals intact.
e.g. "source=[0.0,1.0,0.0] charge=1e-9" → ["source=[0.0,1.0,0.0]", "charge=1e-9"]
"""
function _split_respecting_brackets(s::AbstractString) :: Vector{String}
    tokens  = String[]
    current = IOBuffer()
    depth   = 0

    for ch in s
        if ch == '['
            depth += 1
            write(current, ch)
        elseif ch == ']'
            depth -= 1
            write(current, ch)
            depth < 0 && throw(ArgumentError("Unmatched ']' in input."))
        elseif ch == ' ' && depth == 0
            t = String(take!(current))
            isempty(t) || push!(tokens, t)
        else
            write(current, ch)
        end
    end

    t = String(take!(current))
    isempty(t) || push!(tokens, t)
    depth != 0 && throw(ArgumentError("Unclosed '[' in input — check vector notation."))
    tokens
end

"""
Parse one `key=value` token, inserting the result into params.
The first `=` is the separator; value may contain `=` inside brackets.
"""
function _parse_param!(params::Dict{Symbol, Any}, token::String)
    eq_idx = findfirst(==('='), token)
    isnothing(eq_idx) && throw(ArgumentError(
        "Malformed token \"$token\" — expected key=value format."))

    key_str = token[1:eq_idx-1]
    val_str = token[eq_idx+1:end]

    isempty(key_str) && throw(ArgumentError("Empty key in token \"$token\"."))
    isempty(val_str) && throw(ArgumentError("Empty value in token \"$token\"."))

    # Validate key is a legal identifier
    occursin(r"^[a-zA-Z_]\w*$", key_str) || throw(ArgumentError(
        "Key \"$key_str\" is not a valid identifier."))

    params[Symbol(key_str)] = _parse_value(val_str)
end

"""
Infer and parse the type of a value string.
  [x,y,z] → Vector{Float64}
  scalar  → Float64, Int64, or String
"""
function _parse_value(s::AbstractString)
    s = strip(s)
    # Vector literal: [x, y, z]
    if startswith(s, "[") && endswith(s, "]")
        inner  = s[2:end-1]
        parts  = split(inner, ',')
        parsed = [_parse_scalar(strip(p)) for p in parts]
        # If all numeric, return Float64 vector
        if all(x -> x isa Number, parsed)
            return Float64.(parsed)
        else
            return parsed   # mixed → Any vector
        end
    end
    return _parse_scalar(s)
end

"""
Parse a single scalar token. Tries Float64 → Int64 → String.
"""
function _parse_scalar(s::AbstractString)
    s = strip(s)

    # Float64 handles integer inputs too — try it first for scientific notation
    f = tryparse(Float64, s)
    !isnothing(f) && return f

    # Pure integer (no decimal point or exponent)
    i = tryparse(Int64, s)
    !isnothing(i) && return i

    # Strip surrounding quotes if present, return as String
    if (startswith(s, "\"") && endswith(s, "\"")) ||
       (startswith(s, "'")  && endswith(s, "'"))
        return String(s[2:end-1])
    end

    return String(s)
end
