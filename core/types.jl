# ================================================================
# FILE: core/types.jl
#
# Shared data contracts for the entire B-SPEC engine.
# This file is the single source of truth for all types.
# Every other file depends on this. Loaded first, always.
#
# KEY ARCHITECTURAL CHANGE (v2.2):
#   SolverEntry now contains a list of SolverVariants.
#   Each SolverVariant defines ONE rearrangement of a physical
#   equation — e.g. "find E given Q and r", or "find Q given E and r".
#   The Dispatcher auto-selects the correct variant based on
#   which variables the user provides.
#
#   This means every solver can now compute ANY variable in its
#   equation, not just the one fixed output it had before.
# ================================================================

using LinearAlgebra

# ── Input side ───────────────────────────────────────────────────

"""
    PhysicalQuery

The structured form of user input after tokenization.
Produced by: Tokenizer.  Consumed by: Dispatcher.

Fields:
  command   — which solver family, e.g. :electric_field
  params    — key=value pairs the user provided
  raw       — original unmodified input (audit trail)
"""
struct PhysicalQuery
    command :: Symbol
    params  :: Dict{Symbol, Any}
    raw     :: String
end

# ── Variant system (new) ─────────────────────────────────────────

"""
    SolverVariant

One specific rearrangement of a physical equation.

Fields:
  given       — params that MUST be present for this variant to run
  solves      — the primary unknown this variant computes (Symbol used
                for dispatch matching — should NOT be in given)
  handler     — the Julia function: Dict{Symbol,Any} → SolverResult
  description — human-readable label, e.g. "Find E given Q and r"
"""
struct SolverVariant
    given       :: Vector{Symbol}
    solves      :: Symbol
    handler     :: Function
    description :: String
end

"""
    SolverEntry

A complete solver family: one physical equation with all its
possible algebraic rearrangements as SolverVariants.

Fields:
  command     — dispatch key, e.g. :electric_field
  domain      — solver module, e.g. :electromagnetics
  description — one-line summary of what this solver handles
  equation    — the physical equation as a readable string
  all_vars    — every variable in the equation (for UI form building)
  variants    — all supported rearrangements
"""
struct SolverEntry
    command     :: Symbol
    domain      :: Symbol
    description :: String
    equation    :: String
    all_vars    :: Vector{Symbol}
    variants    :: Vector{SolverVariant}
end

# ── Output side ──────────────────────────────────────────────────

"""
    SolverResult

Standardised output returned by every solver, always.
Solvers never print or return raw values — only SolverResult.
The Engine and GUI format and deliver this to the user.
"""
struct SolverResult
    command   :: Symbol
    outputs   :: Dict{Symbol, Any}
    units     :: Dict{Symbol, String}
    solver_id :: Symbol
    success   :: Bool
    message   :: String
end

# ── Engine state ─────────────────────────────────────────────────

"""
    EngineState

Mutable runtime state of the engine instance.
Tracks health metrics and what has been initialised.
"""
mutable struct EngineState
    initialized    :: Bool
    solvers_loaded :: Vector{Symbol}
    query_count    :: Int
    error_count    :: Int
    last_command   :: Union{Symbol, Nothing}
end

EngineState() = EngineState(false, Symbol[], 0, 0, nothing)

# ── Convenience helpers ──────────────────────────────────────────

"""Build a failed SolverResult with minimal boilerplate."""
function failed_result(cmd::Symbol, solver_id::Symbol, msg::String)::SolverResult
    SolverResult(cmd, Dict{Symbol,Any}(), Dict{Symbol,String}(), solver_id, false, msg)
end