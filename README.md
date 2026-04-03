# ⬡ B-SPEC Physical Engine

A modular scientific computing engine built in Julia, structured around the universal physics simulation framework:

> *"I have a **[System]** in its **[Initial State]**. I apply **[Stimulus/Input]** governed by **[Physical Laws]** and I get **[Response/Output]**."*

---

## Architecture

```
bspec_engine/
├── main.jl                      ← Terminal runner (16 demo queries)
├── gui.jl                       ← Native desktop GUI  (GLMakie + Revise)
├── gui_web.jl                   ← Web GUI — access from phone (Bonito + WGLMakie)
├── Project.toml                 ← Julia package declarations
│
├── core/                        ← Engine pipeline (zero physics)
│   ├── types.jl                 │  Shared contracts: PhysicalQuery, SolverResult
│   ├── tokenizer.jl             │  Stage 1: raw string/dict → PhysicalQuery
│   ├── dispatcher.jl            │  Stage 2: registry, routing, validation
│   └── engine.jl                │  Stage 3: orchestration + output formatting
│
└── solvers/                     ← Physics lives here only
    ├── electromagnetics.jl      │  6 solvers: E-field, Coulomb, potential, etc.
    └── classical_mechanics.jl  │  8 solvers: projectile, gravity, oscillator, etc.
```

---

## Quick Start

```bash
# Install dependencies (first time only)
julia --project=. -e "using Pkg; Pkg.instantiate()"

# Terminal mode
julia main.jl

# Desktop GUI  (GLMakie window)
julia gui.jl

# Web GUI  (open browser at http://localhost:8050)
julia gui_web.jl
```

---

## Command Format

```
[verb] command  key=value  key=[x,y,z]

# Verbs (optional):  get | find | compute | calculate | solve
# Scalars:           charge=1.5e-9    mass=0.5
# Vectors:           source=[0.0,0.0,0.0]
# Negative:          q2=-2.0e-9
```

---

## Available Solvers

### ⚡ Electromagnetics (`solvers/electromagnetics.jl`)

| Command | Required Parameters |
|---|---|
| `electric_field` | `charge`, `source`, `field_point` |
| `coulomb_force` | `q1`, `q2`, `r1`, `r2` |
| `electric_potential` | `charge`, `source`, `field_point` |
| `electric_field_superposition` | `charges`, `sources`, `field_point` |
| `electric_flux` | `E_field`, `area`, `normal` |
| `capacitor_energy` | `capacitance`, `voltage` |

### 🔧 Classical Mechanics (`solvers/classical_mechanics.jl`)

| Command | Required Parameters |
|---|---|
| `projectile_motion` | `initial_velocity`, `angle_deg`, `initial_height` |
| `gravitational_force` | `m1`, `m2`, `distance` |
| `kinetic_energy` | `mass`, `velocity` |
| `work_energy` | `force`, `displacement`, `angle_deg` |
| `harmonic_oscillator` | `mass`, `spring_constant` |
| `circular_motion` | `mass`, `radius`, `speed` |
| `elastic_collision` | `m1`, `v1`, `m2`, `v2` |
| `newtons_second_law` | `mass`, `acceleration` |

---

## Example Queries

```
get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]
get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]
get projectile_motion initial_velocity=50.0 angle_deg=45.0 initial_height=0.0
get harmonic_oscillator mass=0.5 spring_constant=200.0 damping=0.8 amplitude=0.1
get elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0
get gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8
```

---

## Adding a New Solver Domain

1. Create `solvers/quantum_mechanics.jl`
2. Define `register_quantum!()` calling `register_solver!(SolverEntry(...))`
3. In `main.jl` / `gui.jl` / `gui_web.jl` add:
   ```julia
   include("solvers/quantum_mechanics.jl")
   register_quantum!()
   ```
4. Done — engine, dispatcher, and both GUIs need zero changes.

---

## On-Phone Usage (Termux + Ubuntu)

```bash
# Clone the repo
git clone https://github.com/<your-username>/bspec_engine.git
cd bspec_engine

# Install Julia packages
julia --project=. -e "using Pkg; Pkg.instantiate()"

# Run web GUI
julia gui_web.jl

# Open browser on phone
# → http://localhost:8050
```

---

## Pillars Roadmap

- [x] Classical Mechanics
- [x] Electromagnetics
- [ ] Statistical Mechanics
- [ ] Quantum Mechanics
- [ ] Relativistic Mechanics
