#!/usr/bin/env julia
# ================================================================
# FILE: main.jl
#
# B-SPEC Physical Engine — Entry Point
#
# This file does three things only:
#   1. Include all modules in dependency order
#   2. Initialize the engine (register solvers)
#   3. Run queries through the pipeline
#
# To use: julia main.jl
#
# Pipeline (defined in engine.jl, not here):
#
#   String or Dict input
#       │
#       ▼  tokenizer.jl
#   PhysicalQuery  ── command + params
#       │
#       ▼  dispatcher.jl
#   SolverResult   ── outputs + units + status
#       │
#       ▼  engine.jl (format_output)
#   Human-readable terminal output
# ================================================================

# ── Step 1: Load all modules in dependency order ──────────────────────────────

include("core/types.jl")              # Shared contracts — loaded first, always
include("core/tokenizer.jl")          # Stage 1: raw input → PhysicalQuery
include("core/dispatcher.jl")         # Stage 2: registry + routing
include("core/engine.jl")             # Stage 3: pipeline orchestration + formatting

include("solvers/electromagnetics.jl")    # EM physics laws
include("solvers/classical_mechanics.jl") # Classical physics laws

# ── Step 2: Initialize engine ─────────────────────────────────────────────────

state = EngineState()

# Solver modules register themselves with the Dispatcher.
# The engine controls when this happens — not the solvers.
register_electromagnetics!()
register_classical!()

state.initialized    = true
state.solvers_loaded = [:electromagnetics, :classical_mechanics]

println("\n" * "█"^66)
println("  B-SPEC PHYSICAL ENGINE  v0.1")
println("  Solvers: $(join(state.solvers_loaded, "  |  "))")
println("█"^66)

list_solvers()    # print the full registry


# ================================================================
# DEMO QUERIES
# All queries use the exact same pipeline.
# String inputs and Dict inputs both work identically.
# ================================================================

println("═"^66)
println("  DEMO RUNS")
println("═"^66 * "\n")


# ── ELECTROMAGNETICS DEMOS ────────────────────────────────────────────────────

# 1. Electric field of a 1 nC charge at 1 m away
format_output(process(
    "get electric_field charge=1.0e-9 source=[0.0,0.0,0.0] field_point=[1.0,0.0,0.0]",
    state
))

# 2. Coulomb force between +1 nC and -2 nC, 5 cm apart
format_output(process(
    "get coulomb_force q1=1.0e-9 q2=-2.0e-9 r1=[0.0,0.0,0.0] r2=[0.05,0.0,0.0]",
    state
))

# 3. Electric potential of a 5 nC charge at 0.5 m
format_output(process(
    "compute electric_potential charge=5.0e-9 source=[0.0,0.0,0.0] field_point=[0.5,0.0,0.0]",
    state
))

# 4. Superposition: two charges — one positive, one negative (dipole-like)
format_output(process(
    Dict{String,Any}(
        "command"     => "electric_field_superposition",
        "charges"     => [1.0e-9, -1.0e-9],
        "sources"     => [[0.0,0.0,0.0], [0.02,0.0,0.0]],
        "field_point" => [0.01, 0.01, 0.0]
    ),
    state
))

# 5. Electric flux through 2 m² surface
format_output(process(
    "find electric_flux E_field=[1000.0,0.0,0.0] area=2.0 normal=[1.0,0.0,0.0]",
    state
))

# 6. Capacitor energy — 100 µF at 12 V
format_output(process(
    "get capacitor_energy capacitance=1.0e-4 voltage=12.0",
    state
))


# ── CLASSICAL MECHANICS DEMOS ─────────────────────────────────────────────────

# 7. Projectile: 50 m/s at 45° from ground level
format_output(process(
    "get projectile_motion initial_velocity=50.0 angle_deg=45.0 initial_height=0.0",
    state
))

# 8. Gravitational force: Earth–Moon
format_output(process(
    "find gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8",
    state
))

# 9. Kinetic energy: 2 kg at 30 m/s
format_output(process(
    "compute kinetic_energy mass=2.0 velocity=30.0",
    state
))

# 10. Harmonic oscillator: 0.5 kg on 200 N/m spring, slightly damped
format_output(process(
    "get harmonic_oscillator mass=0.5 spring_constant=200.0 damping=0.8 amplitude=0.1",
    state
))

# 11. Circular motion: 1000 kg car on 50 m radius at 20 m/s
format_output(process(
    "find circular_motion mass=1000.0 radius=50.0 speed=20.0",
    state
))

# 12. Elastic collision: 2 kg at 3 m/s hits stationary 1 kg
format_output(process(
    "solve elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0",
    state
))

# 13. Newton's second law
format_output(process(
    "compute newtons_second_law mass=5.0 acceleration=9.81",
    state
))


# ── ERROR HANDLING DEMOS ──────────────────────────────────────────────────────

# 14. Missing required parameters
println("─"^66)
println("  ERROR DEMO 1: missing required parameters")
println("─"^66)
format_output(process(
    "get electric_field charge=1.0e-9",   # missing source and field_point
    state
))

# 15. Unknown command
println("─"^66)
println("  ERROR DEMO 2: unknown command (typo)")
println("─"^66)
format_output(process(
    "get electric_feild charge=1.0e-9 source=[0,0,0] field_point=[1,0,0]",
    state
))

# 16. Physics domain error (charges at same point)
println("─"^66)
println("  ERROR DEMO 3: physics domain error")
println("─"^66)
format_output(process(
    "get coulomb_force q1=1e-9 q2=1e-9 r1=[0.0,0.0,0.0] r2=[0.0,0.0,0.0]",
    state
))


# ── Final status ──────────────────────────────────────────────────────────────

engine_status(state)
