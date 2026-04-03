# ================================================================
# FILE: core/dispatcher.jl
#
# Dispatcher — Stage 2 of the engine pipeline. The Central Brain.
#
# Responsibility:
#   1. Maintain the solver registry (a Dict of SolverEntry records)
#   2. Accept a PhysicalQuery from the Engine
#   3. Find the matching solver
#   4. Validate that all required parameters are present
#   5. Invoke the solver's handler function
#   6. Return a SolverResult — always, even on failure
#
# The Dispatcher knows NOTHING about physics.
# It only knows how to route, validate, and invoke.
#
# Solvers self-register at startup by calling register_solver!().
# ================================================================

# ── Registry ─────────────────────────────────────────────────────────────────

"""
Global solver registry.
Maps command Symbol → SolverEntry.
Populated at engine initialization by each solver module.
"""
const SOLVER_REGISTRY = Dict{Symbol, SolverEntry}()

"""
    register_solver!(entry::SolverEntry)

Add a solver to the global registry.
Called by each solver module during engine initialization.
Warns (but does not error) on duplicate registration.
"""
function register_solver!(entry::SolverEntry)
    if haskey(SOLVER_REGISTRY, entry.command)
        @warn "Dispatcher: overwriting existing solver for command :$(entry.command)"
    end
    SOLVER_REGISTRY[entry.command] = entry
    @debug "Dispatcher: registered [:$(entry.command)] ← domain :$(entry.domain)"
end

# ── Core dispatch logic ───────────────────────────────────────────────────────

"""
    dispatch(query::PhysicalQuery) :: SolverResult

Route a PhysicalQuery to its solver and return a SolverResult.

Pipeline:
  1. Lookup command in registry         → fail gracefully if not found
  2. Validate required parameters       → fail gracefully if missing
  3. Invoke solver handler in try/catch → fail gracefully on solver error
  4. Always return a SolverResult

This function NEVER throws. All errors are captured in the SolverResult.
"""
function dispatch(query::PhysicalQuery) :: SolverResult

    # ── Step 1: find solver ──────────────────────────────────────────────
    if !haskey(SOLVER_REGISTRY, query.command)
        similar = _suggest_similar(query.command)
        hint    = isempty(similar) ? "" : " Did you mean: $(join(similar, ", "))?"
        return failed_result(
            query.command, :dispatcher,
            "No solver registered for command :$(query.command).$hint\n" *
            "  Available commands: $(join(sort(string.(keys(SOLVER_REGISTRY))), ", "))"
        )
    end

    entry = SOLVER_REGISTRY[query.command]

    # ── Step 2: validate required parameters ────────────────────────────
    present        = Set(keys(query.params))
    required       = Set(entry.required_params)
    missing_params = setdiff(required, present)

    if !isempty(missing_params)
        return failed_result(
            query.command, entry.domain,
            "Missing required parameter(s) for :$(query.command): " *
            "[ $(join(missing_params, ", ")) ]\n" *
            "  Required : $(join(entry.required_params, ", "))\n" *
            "  Optional : $(join(entry.optional_params, ", "))\n" *
            "  Provided : $(join(keys(query.params), ", "))"
        )
    end

    # ── Step 3: invoke solver (fully sandboxed) ──────────────────────────
    try
        result = entry.handler(query.params)
        # Ensure the solver returned the right type
        result isa SolverResult || error(
            "Solver for :$(query.command) returned $(typeof(result)) instead of SolverResult.")
        return result
    catch e
        return failed_result(
            query.command, entry.domain,
            "Solver :$(query.command) raised an error:\n  $(sprint(showerror, e))"
        )
    end
end

# ── Registry inspection ───────────────────────────────────────────────────────

"""
    registered_commands() :: Vector{Symbol}

Return all currently registered command symbols, sorted.
"""
registered_commands() :: Vector{Symbol} =
    sort(collect(keys(SOLVER_REGISTRY)), by=string)

"""
    list_solvers()

Pretty-print the complete solver registry to stdout.
"""
function list_solvers()
    println("\n" * "┌" * "─"^62 * "┐")
    println("│  SOLVER REGISTRY  ($(length(SOLVER_REGISTRY)) solvers loaded)" *
            " "^(28 - ndigits(length(SOLVER_REGISTRY))) * "│")
    println("├" * "─"^62 * "┤")

    if isempty(SOLVER_REGISTRY)
        println("│  (no solvers registered)                               │")
    else
        # Group by domain for readability
        domains = Dict{Symbol, Vector{SolverEntry}}()
        for entry in values(SOLVER_REGISTRY)
            push!(get!(domains, entry.domain, SolverEntry[]), entry)
        end

        for (domain, entries) in sort(collect(domains), by=x->string(x[1]))
            println("│  ▸ Domain: :$(domain)" * " "^(50 - length(string(domain))) * "│")
            for e in sort(entries, by=x->string(x.command))
                cmd_str = "  :$(rpad(string(e.command), 30))"
                println("│$(cmd_str)│")
                desc_str = "    └ $(e.description)"
                # Truncate if too long
                if length(desc_str) > 61
                    desc_str = desc_str[1:58] * "..."
                end
                println("│$(rpad(desc_str, 62))│")
                req_str = "    └ Required: [$(join(e.required_params, ", "))]"
                println("│$(rpad(req_str, 62))│")
            end
        end
    end
    println("└" * "─"^62 * "┘\n")
end

# ── Private helpers ───────────────────────────────────────────────────────────

"""
Suggest commands similar to an unknown one (simple character-overlap heuristic).
Helps users who mistype commands get a useful hint.
"""
function _suggest_similar(cmd::Symbol, n::Int=3) :: Vector{Symbol}
    cmd_s   = string(cmd)
    scored  = [(c, _similarity(cmd_s, string(c))) for c in keys(SOLVER_REGISTRY)]
    sorted  = sort(scored, by=x->x[2], rev=true)
    # Only suggest if reasonably similar
    [s[1] for s in sorted[1:min(n, end)] if s[2] > 0.3]
end

"""Simple Jaccard similarity on character bigrams."""
function _similarity(a::String, b::String) :: Float64
    bigrams(s) = Set(s[i:i+1] for i in 1:max(1, length(s)-1))
    A, B = bigrams(a), bigrams(b)
    isempty(A) && isempty(B) && return 1.0
    isempty(A) || isempty(B) && return 0.0
    length(intersect(A, B)) / length(union(A, B))
end
