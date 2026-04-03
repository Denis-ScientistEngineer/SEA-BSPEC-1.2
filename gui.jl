#!/usr/bin/env julia
# ================================================================
# FILE: gui.jl   —   B-SPEC Physical Engine Desktop GUI
# Run: julia gui.jl
#
# Architecture:
#   This file owns the VIEW layer only.
#   It includes the engine (which owns the pipeline) and
#   binds Observables to trigger and display results.
#
#   User types/clicks
#       │
#       ▼  run_query!(text)
#   engine.process()      ← same pipeline as terminal mode
#       │
#       ▼  SolverResult
#   update Observables    ← GUI reacts automatically
#       │
#       ▼  GLMakie renders new state
#
# Revise.jl:
#   includet() (instead of include) tells Revise to watch each
#   file. If you edit and save a solver or core file, Revise
#   patches it into the running session — no restart needed.
#   The next SOLVE click will use the updated code.
# ================================================================

# ── 0. Revise — load FIRST so it can track all subsequent files ──
using Revise

# ── 1. ENGINE INCLUDES (includet = include + Revise tracking) ────
includet("core/types.jl")
includet("core/tokenizer.jl")
includet("core/dispatcher.jl")
includet("core/engine.jl")
includet("solvers/electromagnetics.jl")
includet("solvers/classical_mechanics.jl")

using GLMakie
using Printf

# ── 2. ENGINE INIT ───────────────────────────────────────────────
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]

# ── 3. COLOR PALETTE — dark scientific aesthetic ─────────────────
# Deep navy-slate base, electric blue accent, teal success, crimson error
const C = (
    bg        = RGBf(0.047, 0.063, 0.086),   # #0C1016  background
    panel     = RGBf(0.082, 0.102, 0.129),   # #151A21  panel surface
    surface   = RGBf(0.106, 0.129, 0.161),   # #1B2129  inset surface
    border    = RGBf(0.200, 0.224, 0.255),   # #333A41  border
    accent    = RGBf(0.325, 0.635, 1.000),   # #53A2FF  electric blue
    accent2   = RGBf(0.200, 0.820, 0.980),   # #33D1FA  cyan for emphasis
    success   = RGBf(0.235, 0.741, 0.322),   # #3CBD52  teal green
    error     = RGBf(0.957, 0.302, 0.271),   # #F44D45  crimson red
    warn      = RGBf(0.894, 0.690, 0.176),   # #E4B02D  amber
    text      = RGBf(0.882, 0.910, 0.945),   # #E1E8F1  primary text
    text_dim  = RGBf(0.506, 0.545, 0.596),   # #818B98  secondary text
    text_val  = RGBf(0.463, 0.749, 1.000),   # #76BFFF  output values
    text_unit = RGBf(0.600, 0.780, 0.580),   # #99C794  unit strings
    btn_solve = RGBf(0.141, 0.396, 0.659),   # #2465A8  solve button
    btn_hover = RGBf(0.200, 0.506, 0.820),   # #3381D1
)

# ── 4. TEXT FORMATTERS ───────────────────────────────────────────

"""Format a single output value to a compact string."""
function _fmtv(v)::String
    v isa Vector        && return "[" * join([@sprintf("%.5g", x) for x in v], ", ") * "]"
    v isa AbstractFloat && return @sprintf("%.6g", v)
    v isa Bool          && return v ? "true" : "false"
    return string(v)
end

"""Build the full result display text from a SolverResult."""
function build_result_text(r::SolverResult)::String
    bar = "─" ^ 60
    io  = IOBuffer()

    if r.success
        println(io, "")
        println(io, "  ✓  :$(r.command)")
        println(io, "       Solver  :  :$(r.solver_id)")
        println(io, "  $bar")
        println(io, "")
        println(io, "  $(rpad("Quantity", 28))  $(rpad("Value", 22))  Unit")
        println(io, "  $(rpad("─"^28, 28))  $(rpad("─"^22, 22))  ─────────────────")
        println(io, "")
        for (k, v) in sort(collect(r.outputs), by = x -> string(x[1]))
            u  = get(r.units, k, "?")
            ks = rpad(string(k), 28)
            vs = rpad(_fmtv(v), 22)
            println(io, "  $ks  $vs  $u")
        end
        println(io, "")
        println(io, "  $bar")
        println(io, "  ✎  $(r.message)")
        println(io, "")
    else
        println(io, "")
        println(io, "  ✗  :$(r.command)   [$(r.solver_id)]")
        println(io, "  $bar")
        println(io, "")
        for line in split(r.message, "\n")
            println(io, "  $line")
        end
        println(io, "")
        println(io, "  $bar")
        println(io, "  Tip: run the app and check the solver list (left panel)")
        println(io, "       for correct command names and required parameters.")
        println(io, "")
    end

    String(take!(io))
end

"""Build the query history display text."""
function build_history_text(entries::Vector{Tuple{String,Bool}})::String
    isempty(entries) && return "\n  No queries yet.\n"
    io = IOBuffer()
    println(io, "")
    for (i, (cmd, ok)) in enumerate(entries)
        n       = length(entries) - i + 1
        icon    = ok ? "✓" : "✗"
        trimmed = length(cmd) > 68 ? cmd[1:65] * "..." : cmd
        println(io, "  $(lpad(n, 2)).  $icon  $trimmed")
    end
    String(take!(io))
end

"""Build the solver registry summary text."""
function build_registry_text()::String
    io      = IOBuffer()
    domains = Dict{Symbol, Vector{Symbol}}()
    for (cmd, e) in SOLVER_REGISTRY
        push!(get!(domains, e.domain, Symbol[]), cmd)
    end
    for (dom, cmds) in sort(collect(domains), by = x -> string(x[1]))
        println(io, "  ▸ :$dom")
        for cmd in sort(cmds, by = string)
            e = SOLVER_REGISTRY[cmd]
            req = isempty(e.required_params) ? "" :
                  "  ← " * join(e.required_params, ", ")
            println(io, "      :$(rpad(string(cmd), 30))$req")
        end
        println(io, "")
    end
    String(take!(io))
end

# ── 5. OBSERVABLES — all reactive GUI state ──────────────────────
const MAX_HISTORY   = 14
committed_input     = Observable{String}("")
result_text         = Observable{String}(
    "\n  ⬡  B-SPEC Physical Engine  v0.1" *
    "\n  ─────────────────────────────────────────────────────" *
    "\n" *
    "\n  Type a command below and press  SOLVE  or hit Enter." *
    "\n" *
    "\n  EXAMPLES:" *
    "\n    get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]" *
    "\n    get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]" *
    "\n    get electric_potential charge=5e-9 source=[0,0,0] field_point=[0.5,0,0]" *
    "\n    get projectile_motion initial_velocity=50.0 angle_deg=45.0 initial_height=0.0" *
    "\n    get harmonic_oscillator mass=0.5 spring_constant=200.0 damping=0.8 amplitude=0.1" *
    "\n    get elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0" *
    "\n    get gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8" *
    "\n"
)
result_color        = Observable{RGBf}(C.text)
history_text        = Observable{String}("\n  No queries yet.\n")
status_text         = Observable{String}(
    "  ● Ready  │  Solvers: $(length(SOLVER_REGISTRY))  │  Queries: 0  │  Errors: 0  │  Last: —"
)
history_store       = Tuple{String, Bool}[]

# ── 6. QUERY RUNNER — the seam between GUI and engine ────────────

function run_query!(text::String)
    text = strip(text)
    isempty(text) && return

    # Hand off to engine — same pipeline used by main.jl
    res = process(text, _state)

    # Update reactive state — GUI redraws automatically
    result_text[]  = build_result_text(res)
    result_color[] = res.success ? C.success : C.error

    pushfirst!(history_store, (text, res.success))
    length(history_store) > MAX_HISTORY && pop!(history_store)
    history_text[] = build_history_text(history_store)

    q = _state.query_count
    e = _state.error_count
    l = isnothing(_state.last_command) ? "—" : ":$(_state.last_command)"
    n = length(SOLVER_REGISTRY)
    status_text[] = "  ● Ready  │  Solvers: $n  │  Queries: $q  │  Errors: $e  │  Last: $l"
end

# ── 7. FIGURE & LAYOUT ───────────────────────────────────────────

GLMakie.activate!(title = "B-SPEC Physical Engine  v0.1", focus_on_show = true)
set_theme!(theme_dark())

fig = Figure(
    backgroundcolor = C.bg,
    size            = (1340, 900),
)

# ── Row sizing: header(52) | main(fills) | statusbar(28)
rowsize!(fig.layout, 1, Fixed(52))
rowsize!(fig.layout, 3, Fixed(28))
rowgap!(fig.layout, 4)

# ══ HEADER ═══════════════════════════════════════════════════════
Box(fig[1, 1:2], color = C.panel, strokewidth = 0)
hdr = fig[1, 1:2] = GridLayout()
colgap!(hdr, 1, 20)

Label(hdr[1, 1],
    "  ⬡  B - S P E C   P H Y S I C A L   E N G I N E",
    fontsize   = 18,
    font       = "Courier New",
    color      = C.accent,
    halign     = :left,
    tellwidth  = false)

Label(hdr[1, 2],
    "Scientific Computing Solver Interface  ·  v0.1  ",
    fontsize  = 12,
    color     = C.text_dim,
    halign    = :right,
    tellwidth = false)

# ══ MAIN AREA ════════════════════════════════════════════════════
main = fig[2, 1:2] = GridLayout()
colsize!(main, 1, Fixed(420))
colgap!(main, 1, 6)

# ══ LEFT PANEL ═══════════════════════════════════════════════════
Box(main[1, 1], color = C.panel, strokewidth = 1, strokecolor = C.border)
left = main[1, 1] = GridLayout()
rowgap!(left, 5)

# ─ Section: Command Input ─────────────────────────────────────────
Label(left[1, 1],
    "  COMMAND INPUT",
    fontsize  = 11,
    font      = "Courier New",
    color     = C.accent,
    halign    = :left,
    tellwidth = false)
rowsize!(left, 1, Fixed(28))

# Textbox
tb = Textbox(left[2, 1],
    placeholder        = "get electric_field charge=1e-9 source=[0,0,0] ...",
    stored_string      = committed_input,
    fontsize           = 13,
    bordercolor        = C.border,
    bordercolor_focused = C.accent,
    textcolor          = C.text,
    fontfamily         = "monospace")
rowsize!(left, 2, Fixed(40))

# Button row
brow = left[3, 1] = GridLayout()
colgap!(brow, 1, 8)

solve_btn = Button(brow[1, 1],
    label              = "  SOLVE  ",
    fontsize           = 13,
    height             = 36,
    buttoncolor        = C.btn_solve,
    buttoncolor_hover  = C.btn_hover,
    buttoncolor_active = C.accent,
    labelcolor         = C.text,
    font               = "Courier New")

clear_btn = Button(brow[1, 2],
    label              = "  CLEAR  ",
    fontsize           = 13,
    height             = 36,
    buttoncolor        = C.surface,
    buttoncolor_hover  = C.border,
    labelcolor         = C.text_dim,
    font               = "Courier New")

rowsize!(left, 3, Fixed(44))

# ─ Divider ────────────────────────────────────────────────────────
Label(left[4, 1],
    "  ──────────────────────────────────────",
    color = C.border, fontsize = 10, halign = :left, tellwidth = false)
rowsize!(left, 4, Fixed(16))

# ─ Section: Solver Registry ──────────────────────────────────────
Label(left[5, 1],
    "  SOLVER REGISTRY",
    fontsize = 11, font = "Courier New",
    color = C.accent, halign = :left, tellwidth = false)
rowsize!(left, 5, Fixed(26))

Label(left[6, 1],
    build_registry_text(),
    fontsize      = 11,
    font          = "Courier New",
    color         = C.text_dim,
    halign        = :left,
    justification = :left,
    tellwidth     = false)

# ─ Divider ────────────────────────────────────────────────────────
Label(left[7, 1],
    "  ──────────────────────────────────────",
    color = C.border, fontsize = 10, halign = :left, tellwidth = false)
rowsize!(left, 7, Fixed(16))

# ─ Section: Format Guide ─────────────────────────────────────────
Label(left[8, 1],
    "  FORMAT GUIDE\n" *
    "  [verb] command  key=value  key=[x,y,z]\n\n" *
    "  VERBS (optional prefix):\n" *
    "    get | find | compute | calculate | solve\n\n" *
    "  SCALARS:   charge=1.5e-9   mass=0.5\n" *
    "  VECTORS:   position=[0.0,1.0,0.0]\n" *
    "  NEGATIVE:  q2=-2.0e-9",
    fontsize      = 11,
    font          = "Courier New",
    color         = C.text_dim,
    halign        = :left,
    justification = :left,
    tellwidth     = false)

# ══ RIGHT PANEL ══════════════════════════════════════════════════
Box(main[1, 2], color = C.panel, strokewidth = 1, strokecolor = C.border)
right = main[1, 2] = GridLayout()
rowgap!(right, 5)

# ─ Result Header ─────────────────────────────────────────────────
result_hdr = right[1, 1] = GridLayout()
colgap!(result_hdr, 1, 10)

Label(result_hdr[1, 1],
    "  RESULT",
    fontsize = 11, font = "Courier New",
    color = C.accent, halign = :left, tellwidth = false)

rowsize!(right, 1, Fixed(28))

# ─ Result Body ───────────────────────────────────────────────────
Box(right[2, 1], color = C.surface, strokewidth = 1, strokecolor = C.border)

Label(right[2, 1],
    result_text,
    fontsize      = 13,
    font          = "Courier New",
    color         = result_color,
    halign        = :left,
    justification = :left,
    valign        = :top,
    tellwidth     = false,
    tellheight    = false)

rowsize!(right, 2, Relative(0.60))

# ─ History Header ────────────────────────────────────────────────
Label(right[3, 1],
    "  QUERY HISTORY",
    fontsize = 11, font = "Courier New",
    color = C.accent, halign = :left, tellwidth = false)
rowsize!(right, 3, Fixed(28))

# ─ History Body ──────────────────────────────────────────────────
Box(right[4, 1], color = C.surface, strokewidth = 1, strokecolor = C.border)

Label(right[4, 1],
    history_text,
    fontsize      = 12,
    font          = "Courier New",
    color         = C.text_dim,
    halign        = :left,
    justification = :left,
    valign        = :top,
    tellwidth     = false,
    tellheight    = false)

# ══ STATUS BAR ═══════════════════════════════════════════════════
Box(fig[3, 1:2], color = C.surface, strokewidth = 0)
Label(fig[3, 1:2],
    status_text,
    fontsize  = 11,
    font      = "Courier New",
    color     = C.text_dim,
    halign    = :left,
    tellwidth = false)

# ── 8. EVENT HANDLERS ────────────────────────────────────────────

# Enter key in textbox commits stored_string → run query
on(committed_input) do text
    run_query!(text)
end

# SOLVE button — read live displayed text (works even without Enter)
on(solve_btn.clicks) do _
    # Try displayed_string (live) first, fall back to committed
    text = try
        tb.displayed_string[]
    catch
        committed_input[]
    end
    run_query!(text)
end

# CLEAR button
on(clear_btn.clicks) do _
    result_text[]  = "\n  Cleared. Ready for next command.\n"
    result_color[] = C.text_dim
    # Note: setting committed_input triggers on() → run_query!("") → returns early
    committed_input[] = ""
end

# ── 9. LAUNCH ────────────────────────────────────────────────────
@info "B-SPEC GUI starting..."
display(fig)

while isopen(fig.scene)
    sleep(0.033)   # ~30 fps idle loop — keeps window alive without burning CPU
end

@info "B-SPEC GUI closed."