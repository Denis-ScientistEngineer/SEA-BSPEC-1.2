# ================================================================
# FILE: core/types.jl
#
# Shared data contracts for the entire B-SPEC engine.
# Every other file depends on this. Loaded first, always.
#
# v2.2:  SolverEntry → SolverVariant multi-variant system
# v2.3:  NLPParseResult added for natural language input path
# ================================================================

using LinearAlgebra

# ── Input side ───────────────────────────────────────────────────

"""
The structured form of user input after tokenization or NLP parsing.
Produced by Tokenizer or NLP Parser. Consumed by Dispatcher.
"""
struct PhysicalQuery
    command :: Symbol
    params  :: Dict{Symbol, Any}
    raw     :: String
end

# ── Variant system ────────────────────────────────────────────────

"""One specific rearrangement of a physical equation."""
struct SolverVariant
    given       :: Vector{Symbol}
    solves      :: Symbol
    handler     :: Function
    description :: String
end

"""
A complete solver family: one physical equation with all its
possible algebraic rearrangements as SolverVariants.
"""
struct SolverEntry
    command     :: Symbol
    domain      :: Symbol
    description :: String
    equation    :: String
    all_vars    :: Vector{Symbol}
    variants    :: Vector{SolverVariant}
end

# ── NLP types (v2.3) ─────────────────────────────────────────────

"""
Result of the natural language parsing stage.
The engine converts this into a PhysicalQuery for dispatch.

Fields:
  success        — true if a solver + complete params were found
  solver         — the solver command to dispatch
  params         — assembled parameters ready for the dispatcher
  parse_log      — step-by-step extraction transcript shown to user
  problem_type   — human-readable description of what was detected
  intent         — what the problem is asking for
  partial        — true if params are incomplete (need more info)
  partial_reason — explanation of what is missing, if partial
"""
struct NLPParseResult
    success        :: Bool
    solver         :: Symbol
    params         :: Dict{Symbol, Any}
    parse_log      :: Vector{String}
    problem_type   :: String
    intent         :: String
    partial        :: Bool
    partial_reason :: String
end

# ── Output side ──────────────────────────────────────────────────

"""Standardised output returned by every solver, always."""
struct SolverResult
    command   :: Symbol
    outputs   :: Dict{Symbol, Any}
    units     :: Dict{Symbol, String}
    solver_id :: Symbol
    success   :: Bool
    message   :: String
end

# ── Engine state ─────────────────────────────────────────────────

"""Mutable runtime state of the engine instance."""
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