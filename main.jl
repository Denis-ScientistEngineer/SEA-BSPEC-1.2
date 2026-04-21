#!/usr/bin/env julia
# ================================================================
# FILE: main.jl   —   B-SPEC Physical Engine  v2.3
#
# Terminal entry point.  Run:  julia main.jl
#
# Pipeline:
#   String input
#     │
#     ▼  detect_input_mode()       :command | :natural
#     │
#     ├── :command ──▶ tokenize()  ──▶ dispatch()
#     │
#     └── :natural ──▶ parse_natural_language()  ──▶ dispatch()
#     │
#     ▼  SolverResult  ──▶  format_output()
# ================================================================

# ── 1. Load modules in dependency order ──────────────────────────
include("core/types.jl")
include("core/tokenizer.jl")
include("core/nlp_parser.jl")       # NEW v2.3
include("core/dispatcher.jl")
include("core/engine.jl")

include("solvers/electromagnetics.jl")
include("solvers/classical_mechanics.jl")

# ── 2. Engine initialisation ─────────────────────────────────────
state = EngineState()

register_electromagnetics!()
register_classical!()

state.initialized    = true
state.solvers_loaded = [:electromagnetics, :classical_mechanics]

println("\n" * "█"^68)
println("  B-SPEC PHYSICAL ENGINE  v2.3")
println("  Solvers: $(join(state.solvers_loaded, "  |  "))")
println("  Commands: $(length(SOLVER_REGISTRY))")
println("█"^68)

list_solvers()

# ================================================================
# SECTION A — COMMAND FORMAT DEMOS
# Structured key=value input — fast, precise, explicit.
# ================================================================

println("═"^68)
println("  SECTION A — STRUCTURED COMMAND INPUT")
println("═"^68 * "\n")

# A1. Electric field from point charge
format_output(process(
    "get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]",
    state))

# A2. Coulomb force — classic two-charge problem
format_output(process(
    "get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]",
    state))

# A3. Inverse: find distance given force and charges
format_output(process(
    "get coulomb_force F_magnitude=3.595e-5 q1=1e-9 q2=-2e-9",
    state))

# A4. Inverse: find charge given E field and distance
format_output(process(
    "get electric_field E_magnitude=8.9876 r_magnitude=1.0",
    state))

# A5. Inverse: find spring constant given mass and frequency
format_output(process(
    "get harmonic_oscillator mass=0.5 angular_frequency=20.0",
    state))

# A6. Inverse: find m from kinetic energy and velocity
format_output(process(
    "get kinetic_energy KE=900.0 velocity=30.0",
    state))

# A7. Capacitor — find voltage given energy and capacitance
format_output(process(
    "get capacitor_energy energy=0.0072 capacitance=1e-4",
    state))

# A8. Inverse projectile — find launch speed from range
format_output(process(
    "get projectile_motion range=255.1 angle_deg=45.0 initial_height=0.0",
    state))

# A9. Circular motion — find radius given force, mass, speed
format_output(process(
    "get circular_motion centripetal_force=8000 mass=1000 speed=20",
    state))

# A10. Newton's second — find mass from F and a
format_output(process(
    "get newtons_second_law force=49.05 acceleration=9.81",
    state))


# ================================================================
# SECTION B — NATURAL LANGUAGE INPUT (Textbook problems)
# Copy-paste problems exactly as written — engine reads them.
# ================================================================

println("═"^68)
println("  SECTION B — NATURAL LANGUAGE INPUT")
println("═"^68 * "\n")

# ── B1. Hayt Engineering Electromagnetics  Problem 2.2 ────────────
println("─"^68)
println("  B1. Two-charge force problem (Hayt 2.2)")
println("─"^68)
format_output(process(
    "Point charges of 1 nC and -2 nC are located at (0, 0, 0) and (1, 1, 1), " *
    "respectively, in free space. Determine the vector force acting on each charge.",
    state))

# ── B2. Hayt Problem 2.3 — Force superposition ────────────────────
println("─"^68)
println("  B2. Four-charge superposition (Hayt 2.3)")
println("─"^68)
format_output(process(
    "Point charges of 50 nC each are located at A(1, 0, 0), B(-1, 0, 0), " *
    "C(0, 1, 0), and D(0, -1, 0) in free space. Find the total force on the " *
    "charge at A.",
    state))

# ── B3. Single charge field ────────────────────────────────────────
println("─"^68)
println("  B3. Single charge electric field (prose)")
println("─"^68)
format_output(process(
    "A point charge of 5 nC is located at the origin. " *
    "Find the electric field at the point (1, 0, 0) m.",
    state))

# ── B4. Classical mechanics — projectile prose ─────────────────────
println("─"^68)
println("  B4. Projectile motion (prose)")
println("─"^68)
format_output(process(
    "A ball is launched at 30 m/s at an angle of 60° from the ground. " *
    "Find the maximum height, range, and time of flight.",
    state))

# ── B5. Spring oscillator prose ────────────────────────────────────
println("─"^68)
println("  B5. Harmonic oscillator (prose)")
println("─"^68)
format_output(process(
    "A mass of 2 kg is attached to a spring with spring constant 50 N/m. " *
    "Find the natural frequency and period of oscillation.",
    state))

# ── B6. NL error: ambiguous input ─────────────────────────────────
println("─"^68)
println("  B6. NL input — insufficient data (error handling)")
println("─"^68)
format_output(process(
    "A charge is placed somewhere. Find the electric field.",
    state))

# ── B7. NL error: unknown physics ─────────────────────────────────
println("─"^68)
println("  B7. NL input — unknown problem type (error handling)")
println("─"^68)
format_output(process(
    "The temperature of the gas increases by 20 K. Find the entropy change.",
    state))


# ================================================================
# SECTION C — MODE DETECTION TRANSPARENCY
# Show which inputs route to which path
# ================================================================

println("═"^68)
println("  SECTION C — INPUT MODE DETECTION")
println("═"^68 * "\n")

test_inputs = [
    "get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]",
    "find electric_field E_magnitude=10 r_magnitude=0.5",
    "Point charges of 1 nC and -2 nC are at (0,0,0) and (1,1,1).",
    "50 nC charges at A(1,0,0), B(-1,0,0), C(0,1,0), D(0,-1,0). Force on A?",
    "A 2 kg mass on a 100 N/m spring. Find the period.",
    "compute harmonic_oscillator mass=2 spring_constant=100",
]

for s in test_inputs
    mode = detect_input_mode(s)
    label  = mode == :natural ? "natural language" : "structured command"
    icon   = mode == :natural ? "🔤" : "⌨ "
    short  = length(s) > 55 ? s[1:52] * "..." : s
    println("  $icon  [$label]  \"$short\"")
end
println()

engine_status(state)