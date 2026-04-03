# ================================================================
# FILE: core/types.jl
#
# Shared data contracts for the entire B-SPEC engine.
# These types are the "language" every module speaks.
# No logic here — pure data structures only.
# Every other file depends on this. It is included first.
# ================================================================

using LinearAlgebra   # for norm(), dot(), cross() used in solvers

# ── Input side ───────────────────────────────────────────────────────────────

"""
    PhysicalQuery

The structured form of a user's input after tokenization.
Produced by: Tokenizer
Consumed by: Dispatcher

Fields:
  command :: Symbol          — what to compute,  e.g. :electric_field
  params  :: Dict{Symbol,Any}— extracted key=value pairs
  raw     :: String          — original unmodified input (audit trail)
"""
struct PhysicalQuery
    command :: Symbol
    params  :: Dict{Symbol, Any}
    raw     :: String
end

# ── Registry ─────────────────────────────────────────────────────────────────

"""
    SolverEntry

One registered solver's full metadata + handler.
Stored in the Dispatcher registry.

Fields:
  command         — the command keyword that triggers this solver
  required_params — parameters that MUST be present; dispatch fails without them
  optional_params — parameters that MAY be present; solvers provide defaults
  handler         — the actual Julia function: Dict → SolverResult
  description     — human-readable one-liner
  domain          — which solver file owns this, e.g. :electromagnetics
"""
struct SolverEntry
    command         :: Symbol
    required_params :: Vector{Symbol}
    optional_params :: Vector{Symbol}
    handler         :: Function
    description     :: String
    domain          :: Symbol
end

# ── Output side ──────────────────────────────────────────────────────────────

"""
    SolverResult

Standardized output returned by every solver, always.
Solvers never print or return raw values — only SolverResult.
The Engine formats and delivers this to the user.

Fields:
  command   — the command that was handled
  outputs   — computed quantities as a named Dict
  units     — SI unit string for each output key
  solver_id — which domain/solver handled this (:electromagnetics, etc.)
  success   — whether computation completed without error
  message   — human-readable summary or error description
"""
struct SolverResult
    command   :: Symbol
    outputs   :: Dict{Symbol, Any}
    units     :: Dict{Symbol, String}
    solver_id :: Symbol
    success   :: Bool
    message   :: String
end

# ── Engine state ─────────────────────────────────────────────────────────────

"""
    EngineState

Mutable runtime state of the engine instance.
Tracks health metrics and what has been initialized.
"""
mutable struct EngineState
    initialized    :: Bool
    solvers_loaded :: Vector{Symbol}
    query_count    :: Int
    error_count    :: Int
    last_command   :: Union{Symbol, Nothing}
end

EngineState() = EngineState(false, Symbol[], 0, 0, nothing)

# ── Convenience constructors ─────────────────────────────────────────────────

"""Build a failed SolverResult with minimal boilerplate."""
function failed_result(cmd::Symbol, solver_id::Symbol, msg::String) :: SolverResult
    SolverResult(cmd, Dict{Symbol,Any}(), Dict{Symbol,String}(), solver_id, false, msg)
end
