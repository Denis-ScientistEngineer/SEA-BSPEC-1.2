# ================================================================
# FILE: core/dispatcher.jl
#
# Dispatcher — Central Brain of the B-SPEC engine.
#
# Responsibilities:
#   1. Maintain the solver registry (Dict of SolverEntry)
#   2. Accept a PhysicalQuery
#   3. AUTO-SELECT the correct SolverVariant based on which
#      variables the user provided (the key new capability)
#   4. Validate and invoke the variant handler
#   5. Return a SolverResult — always, even on failure
#
# Variant selection logic:
#   A variant MATCHES when:
#     (a) all params in variant.given are present in query.params
#     (b) variant.solves is NOT in query.params  (we're not
#         computing something the user already knows)
#   Among multiple matches, the most specific (most given params)
#   wins.  This handles over-specified inputs gracefully.
#
# The Dispatcher knows NOTHING about physics.
# It only routes, validates, and invokes.
# ================================================================

# ── Registry ─────────────────────────────────────────────────────

"""Global solver registry. Maps command Symbol → SolverEntry."""
const SOLVER_REGISTRY = Dict{Symbol, SolverEntry}()

"""Register a solver. Warns on duplicate."""
function register_solver!(entry::SolverEntry)
    if haskey(SOLVER_REGISTRY, entry.command)
        @warn "Dispatcher: overwriting existing solver for :$(entry.command)"
    end
    SOLVER_REGISTRY[entry.command] = entry
    @debug "Dispatcher: registered [:$(entry.command)] ← :$(entry.domain) ($(length(entry.variants)) variants)"
end

# ── Variant selection ─────────────────────────────────────────────

"""
    select_variant(entry, provided) → SolverVariant or nothing

Find the best-matching variant given the set of provided param keys.

Rules:
  1. All variant.given params must be in provided
  2. variant.solves must NOT be in provided
  3. Among matches, most-given-params wins (most specific)
"""
function select_variant(entry::SolverEntry, provided::Set{Symbol})::Union{SolverVariant, Nothing}
    candidates = filter(entry.variants) do v
        all(p ∈ provided for p in v.given) && v.solves ∉ provided
    end
    isempty(candidates) && return nothing
    # Most specific first
    sort!(candidates, by = v -> length(v.given), rev = true)
    return first(candidates)
end

# ── Core dispatch ────────────────────────────────────────────────

"""
    dispatch(query::PhysicalQuery) → SolverResult

Route a query to its solver variant and return a SolverResult.
Never throws — all errors are returned as failed SolverResults.
"""
function dispatch(query::PhysicalQuery)::SolverResult

    # ── Step 1: find solver ──────────────────────────────────────
    if !haskey(SOLVER_REGISTRY, query.command)
        similar = _suggest_similar(query.command)
        hint    = isempty(similar) ? "" :
                  "  Did you mean: $(join(similar, ", "))?"
        return failed_result(
            query.command, :dispatcher,
            "No solver registered for :$(query.command).$hint\n" *
            "  Available: $(join(sort(string.(keys(SOLVER_REGISTRY))), ", "))"
        )
    end

    entry    = SOLVER_REGISTRY[query.command]
    provided = Set(keys(query.params))

    # ── Step 2: auto-select variant ──────────────────────────────
    variant  = select_variant(entry, provided)

    if isnothing(variant)
        # Build a helpful error showing all available modes
        modes = join(
            ["  • $(v.description)\n    Needs: [$(join(v.given, ", "))]"
             for v in entry.variants],
            "\n"
        )
        what_given = isempty(provided) ? "(nothing)" : join(sort(string.(provided)), ", ")

        return failed_result(
            query.command, entry.domain,
            "Cannot find a matching calculation mode for :$(query.command).\n" *
            "  You provided : [$what_given]\n\n" *
            "  Available modes:\n$modes\n\n" *
            "  Tip: provide exactly the variables listed under 'Needs' for the mode you want."
        )
    end

    # ── Step 3: invoke variant handler (sandboxed) ───────────────
    try
        result = variant.handler(query.params)
        result isa SolverResult || error(
            "Handler for :$(query.command) returned $(typeof(result)), expected SolverResult.")
        return result
    catch e
        return failed_result(
            query.command, entry.domain,
            "Calculation error in :$(query.command) [$(variant.description)]:\n" *
            "  $(sprint(showerror, e))"
        )
    end
end

# ── Registry inspection ──────────────────────────────────────────

registered_commands()::Vector{Symbol} =
    sort(collect(keys(SOLVER_REGISTRY)), by = string)

"""Pretty-print the complete solver registry."""
function list_solvers()
    println("\n┌" * "─"^68 * "┐")
    n = length(SOLVER_REGISTRY)
    println("│  SOLVER REGISTRY  ($n solver$(n==1 ? "" : "s") loaded)" *
            " "^(34 - ndigits(n)) * "│")
    println("├" * "─"^68 * "┤")

    if isempty(SOLVER_REGISTRY)
        println("│  (empty)  " * " "^57 * "│")
    else
        domains = Dict{Symbol, Vector{SolverEntry}}()
        for e in values(SOLVER_REGISTRY)
            push!(get!(domains, e.domain, SolverEntry[]), e)
        end
        for (domain, entries) in sort(collect(domains), by = x -> string(x[1]))
            println("│  ▸ Domain: :$(domain)" * " "^(55 - length(string(domain))) * "│")
            for e in sort(entries, by = x -> string(x.command))
                println("│    :$(rpad(string(e.command), 30))  $(e.equation)" *
                        " "^max(0, 30 - length(e.equation)) * "│")
                for v in e.variants
                    desc = "       $(v.description)"
                    length(desc) > 67 && (desc = desc[1:64] * "...")
                    println("│$(rpad(desc, 68))│")
                end
            end
        end
    end
    println("└" * "─"^68 * "┘\n")
end

# ── Private helpers ──────────────────────────────────────────────

function _suggest_similar(cmd::Symbol, n::Int = 3)::Vector{Symbol}
    cmd_s  = string(cmd)
    scored = [(c, _similarity(cmd_s, string(c))) for c in keys(SOLVER_REGISTRY)]
    sorted = sort(scored, by = x -> x[2], rev = true)
    [s[1] for s in sorted[1:min(n, end)] if s[2] > 0.3]
end

function _similarity(a::String, b::String)::Float64
    bigrams(s) = Set(s[i:i+1] for i in 1:max(1, length(s)-1))
    A, B = bigrams(a), bigrams(b)
    isempty(A) && isempty(B) && return 1.0
    (isempty(A) || isempty(B)) && return 0.0
    length(intersect(A, B)) / length(union(A, B))
end