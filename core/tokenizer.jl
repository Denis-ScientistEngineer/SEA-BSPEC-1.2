# ================================================================
# FILE: core/tokenizer.jl
#
# Tokenizer — Stage 1 of the engine pipeline.
#
# v2.3 UPDATE:
#   Added detect_input_mode() which classifies raw input as:
#     :command  — "get coulomb_force q1=1e-9 ..."
#     :natural  — "Point charges of 1 nC and -2 nC are at..."
#
#   The engine uses this to route:
#     :command  → tokenize()              (this file, unchanged)
#     :natural  → parse_natural_language() (nlp_parser.jl)
# ================================================================

const RECOGNIZED_VERBS = ("get", "find", "compute", "calculate", "solve",
                           "determine", "evaluate", "derive")

# ── Input mode detection ─────────────────────────────────────────

"""
    detect_input_mode(s::AbstractString) :: Symbol

Returns :command or :natural based on what the input looks like.
"""
function detect_input_mode(s::AbstractString)::Symbol
    s = strip(s)
    isempty(s) && return :command
    lc = lowercase(s)

    # Fast path: tight key=value pattern (no spaces around =)
    kv_tight = length(collect(eachmatch(r"\b\w+=[^\s=]", s)))
    kv_tight >= 2 && return :command

    # Command verb + command_word + at least one key=value
    cmd_re = r"^(?:get|find|compute|calculate|solve|determine|evaluate|derive)?\s*\w+\s+\w+=[^\s]"
    occursin(cmd_re, lc) && return :command

    # Natural language: long word sequence before any =
    m = match(r"^(.+?)\b\w+=", s)
    if !isnothing(m)
        n = length(split(strip(m.captures[1])))
        n >= 4 && return :natural
    end

    # Strong NL phrase patterns
    nl_patterns = [
        r"\b(?:located|positioned|placed|situated)\s+at\b",
        r"\bfree\s+space\b",
        r"\bin\s+the\s+[xy][yz]?\s*-?\s*plane\b",
        r"\brespectively\b",
        r"\bpoint\s+charge[sd]?\b",
        r"\beach\b.{0,30}\d+\s*(?:nc|uc|μc|pc)",
        r"\b(?:determine|find)\s+the\s+(?:vector|total|net|required)\b",
        r"\bacting\s+on\b",
        r"\bproduces?\s+(?:a\s+)?zero\b",
        r"\bcoordinates\s+of\b",
    ]
    nl_score = sum(1 for re in nl_patterns if occursin(re, lc))
    nl_score >= 1 && return :natural

    # Physics units in prose context
    unit_prose = occursin(r"\d+\s*(?:nC|uC|μC|pC|mC|cm|mm|nN|kN|kV|mV|nJ|kJ|pF|nF|kg\b)", s)
    unit_prose && !occursin(r"\w+=\d", s) && return :natural

    # Multiple coordinate tuples
    length(collect(eachmatch(r"\(-?\s*[\d.]+\s*,", s))) >= 2 && return :natural

    return :command
end

# ── Command tokenizer ─────────────────────────────────────────────

"""
    tokenize(raw::AbstractString) :: PhysicalQuery

Parse a structured command string into a PhysicalQuery.
Format: [verb] command [key=value ...]
"""
function tokenize(raw::AbstractString)::PhysicalQuery
    s = strip(raw)
    isempty(s) && throw(ArgumentError("Tokenizer received empty input."))

    tokens = _split_respecting_brackets(s)
    isempty(tokens) && throw(ArgumentError("No tokens found."))

    idx = 1
    if lowercase(tokens[1]) ∈ RECOGNIZED_VERBS
        length(tokens) < 2 && throw(ArgumentError(
            "Verb '$(tokens[1])' found but no command follows it."))
        idx = 2
    end

    command = Symbol(lowercase(tokens[idx]))
    params  = Dict{Symbol, Any}()
    for token in tokens[idx+1:end]
        isempty(strip(token)) && continue
        _parse_param!(params, token)
    end

    PhysicalQuery(command, params, String(raw))
end

"""
    tokenize(raw::Dict{String,Any}) :: PhysicalQuery

Accept a pre-structured Dict. Must contain a "command" key.
"""
function tokenize(raw::Dict{String, Any})::PhysicalQuery
    haskey(raw, "command") || throw(ArgumentError(
        "Dict input must contain a \"command\" key."))
    command = Symbol(lowercase(strip(raw["command"])))
    params  = Dict{Symbol, Any}(Symbol(k) => v for (k,v) in raw if k != "command")
    PhysicalQuery(command, params, repr(raw))
end

# ── Private helpers ───────────────────────────────────────────────

function _split_respecting_brackets(s::AbstractString)::Vector{String}
    tokens = String[]; current = IOBuffer(); depth = 0
    for ch in s
        if ch == '[';     depth += 1; write(current, ch)
        elseif ch == ']'; depth -= 1; write(current, ch)
            depth < 0 && throw(ArgumentError("Unmatched ']' in input."))
        elseif ch == ' ' && depth == 0
            t = String(take!(current)); isempty(t) || push!(tokens, t)
        else
            write(current, ch)
        end
    end
    t = String(take!(current)); isempty(t) || push!(tokens, t)
    depth != 0 && throw(ArgumentError("Unclosed '[' in input."))
    tokens
end

function _parse_param!(params::Dict{Symbol, Any}, token::String)
    eq_idx = findfirst(==('='), token)
    isnothing(eq_idx) && throw(ArgumentError(
        "Malformed token \"$token\" — expected key=value format."))
    key_str = token[1:eq_idx-1]; val_str = token[eq_idx+1:end]
    isempty(key_str) && throw(ArgumentError("Empty key in \"$token\"."))
    isempty(val_str) && throw(ArgumentError("Empty value in \"$token\"."))
    occursin(r"^[a-zA-Z_]\w*$", key_str) || throw(ArgumentError(
        "Key \"$key_str\" is not a valid identifier."))
    params[Symbol(key_str)] = _parse_value(val_str)
end

function _parse_value(s::AbstractString)
    s = strip(s)
    if startswith(s, "[") && endswith(s, "]")
        inner  = s[2:end-1]; parts = split(inner, ',')
        parsed = [_parse_scalar(strip(p)) for p in parts]
        all(x -> x isa Number, parsed) && return Float64.(parsed)
        return parsed
    end
    _parse_scalar(s)
end

function _parse_scalar(s::AbstractString)
    s = strip(s)
    f = tryparse(Float64, s); !isnothing(f) && return f
    i = tryparse(Int64, s);   !isnothing(i) && return i
    if (startswith(s,"\"") && endswith(s,"\"")) || (startswith(s,"'") && endswith(s,"'"))
        return String(s[2:end-1])
    end
    String(s)
end