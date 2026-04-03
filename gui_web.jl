#!/usr/bin/env julia
# ================================================================
# FILE: gui_web.jl   —   B-SPEC Physical Engine  Web GUI
#
# Stack: Bonito.jl (reactive web server) + WGLMakie (canvas)
#        Revise.jl (live-reload during development)
#
# Run:  julia gui_web.jl
# Open: http://localhost:8050  in any browser
#       On phone (same WiFi): http://<your-PC-or-phone-IP>:8050
#
# Architecture — identical pipeline to gui.jl, different renderer:
#
#   Browser (phone/PC)
#       │  HTTP + WebSocket
#       ▼
#   Bonito.jl server (this file)
#       │  Observable updates
#       ▼
#   engine.process()  ←  same core/ + solvers/ as always
#       │
#       ▼
#   SolverResult → update DOM Observables → browser redraws
# ================================================================

# ── 0. Revise (load first so it can track subsequent includes) ───
using Revise
 
# ── 1. Engine (includet = Revise-tracked) ────────────────────────
includet("core/types.jl")
includet("core/tokenizer.jl")
includet("core/dispatcher.jl")
includet("core/engine.jl")
includet("solvers/electromagnetics.jl")
includet("solvers/classical_mechanics.jl")
 
# ── 2. Packages ──────────────────────────────────────────────────
using Bonito
using Observables
using Printf
 
# ── 3. Engine init ───────────────────────────────────────────────
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]
 
# ── 4. CSS ───────────────────────────────────────────────────────
const STYLES_STR = """
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
 
  body {
    background  : #0C1016;
    color       : #E1E8F1;
    font-family : 'Courier New', Courier, monospace;
    font-size   : 14px;
    min-height  : 100vh;
  }
 
  .shell {
    display        : flex;
    flex-direction : column;
    height         : 100vh;
    overflow       : hidden;
  }
 
  .topbar {
    background     : #151A21;
    border-bottom  : 1px solid #2A3240;
    padding        : 10px 18px;
    display        : flex;
    align-items    : center;
    justify-content: space-between;
    flex-shrink    : 0;
  }
  .topbar-title { color: #53A2FF; font-size: 15px; letter-spacing: 2px; font-weight: bold; }
  .topbar-sub   { color: #606870; font-size: 11px; }
  .pill {
    background: #1B2129; border: 1px solid #2A3240;
    color: #53A2FF; font-size: 10px; padding: 2px 8px;
    border-radius: 12px; letter-spacing: 1px;
  }
 
  .main { display: flex; flex: 1; overflow: hidden; }
 
  .left-panel {
    width: 340px; min-width: 340px;
    background: #151A21; border-right: 1px solid #2A3240;
    display: flex; flex-direction: column;
    overflow-y: auto; padding-bottom: 12px;
  }
 
  .right-panel {
    flex: 1; display: flex; flex-direction: column;
    overflow: hidden; background: #0F1419;
  }
 
  .sec-label {
    color: #53A2FF; font-size: 10px; letter-spacing: 2px;
    padding: 12px 14px 6px; text-transform: uppercase;
  }
 
  /* Style the Bonito TextField widget */
  .input-wrap { padding: 0 12px 8px; }
  .input-wrap input, .input-wrap textarea {
    width: 100% !important;
    background: #1B2129 !important;
    border: 1px solid #2A3240 !important;
    border-radius: 4px !important;
    color: #E1E8F1 !important;
    font-family: 'Courier New', monospace !important;
    font-size: 13px !important;
    padding: 10px 12px !important;
    outline: none !important;
    box-sizing: border-box !important;
  }
  .input-wrap input:focus, .input-wrap textarea:focus {
    border-color: #53A2FF !important;
  }
 
  /* Style the Bonito Button widgets */
  .btn-row { display: flex; gap: 8px; padding: 0 12px 10px; }
  .btn-row button {
    padding: 8px 16px; border-radius: 4px;
    font-family: 'Courier New', monospace; font-size: 13px;
    cursor: pointer; border: none; transition: background 0.15s;
  }
  .btn-row button:first-child {
    background: #2465A8; color: #E1E8F1; flex: 1; letter-spacing: 1px;
  }
  .btn-row button:first-child:hover { background: #3381D1; }
  .btn-row button:last-child {
    background: #1B2129; color: #818B98; border: 1px solid #2A3240;
  }
  .btn-row button:last-child:hover { background: #252D38; color: #E1E8F1; }
 
  hr.divider { border: none; border-top: 1px solid #2A3240; margin: 6px 12px; }
 
  .registry-pre {
    padding: 4px 14px; font-size: 11.5px;
    color: #606870; line-height: 1.9;
    white-space: pre; overflow-x: hidden;
    font-family: 'Courier New', monospace;
  }
 
  .guide-pre {
    padding: 8px 14px 4px; font-size: 11px;
    color: #505860; line-height: 1.8;
    border-top: 1px solid #2A3240;
    white-space: pre; font-family: 'Courier New', monospace;
  }
 
  .result-wrap {
    flex: 1; overflow-y: auto;
    padding: 12px 14px; background: #0F1419;
  }
  .result-pre {
    white-space: pre; font-size: 13px; line-height: 1.75;
    font-family: 'Courier New', monospace;
  }
 
  .history-wrap {
    background: #151A21; border-top: 1px solid #2A3240;
    padding: 6px 14px 8px; max-height: 160px;
    overflow-y: auto; flex-shrink: 0;
  }
  .history-label {
    color: #53A2FF; font-size: 10px;
    letter-spacing: 2px; padding-bottom: 4px;
  }
  .history-pre {
    font-size: 11.5px; color: #606870;
    line-height: 1.7; white-space: pre;
    font-family: 'Courier New', monospace;
  }
 
  .statusbar {
    background: #151A21; border-top: 1px solid #2A3240;
    padding: 5px 14px; font-size: 11px; color: #606870;
    flex-shrink: 0; white-space: nowrap; overflow-x: auto;
  }
 
  @media (max-width: 700px) {
    .main       { flex-direction: column; }
    .left-panel { width: 100%; min-width: unset; border-right: none;
                  border-bottom: 1px solid #2A3240; max-height: 52vh; }
    .right-panel { flex: 1; min-height: 0; }
    .topbar-sub  { display: none; }
  }
"""
 
# ── 5. Text builders ─────────────────────────────────────────────
 
function _fmtv(v)::String
    v isa Vector        && return "[" * join([@sprintf("%.5g", x) for x in v], ", ") * "]"
    v isa AbstractFloat && return @sprintf("%.6g", v)
    v isa Bool          && return string(v)
    return string(v)
end
 
function build_result_text(r::SolverResult)::String
    bar = "─" ^ 60
    io  = IOBuffer()
    if r.success
        println(io, "\n  ✓  :$(r.command)")
        println(io, "       solver  :  :$(r.solver_id)")
        println(io, "  $bar\n")
        println(io, "  $(rpad("Quantity", 28))  $(rpad("Value", 22))  Unit")
        println(io, "  $(rpad("─"^28,28))  $(rpad("─"^22,22))  ────────────────")
        println(io, "")
        for (k, v) in sort(collect(r.outputs), by = x -> string(x[1]))
            u = get(r.units, k, "?")
            println(io, "  $(rpad(string(k),28))  $(rpad(_fmtv(v),22))  $u")
        end
        println(io, "\n  $bar")
        println(io, "  ✎  $(r.message)\n")
    else
        println(io, "\n  ✗  :$(r.command)   [$(r.solver_id)]")
        println(io, "  $bar\n")
        for line in split(r.message, "\n")
            println(io, "  $line")
        end
        println(io, "\n  $bar")
        println(io, "  Tip: check the solver list in the left panel.\n")
    end
    String(take!(io))
end
 
function build_registry_text()::String
    io      = IOBuffer()
    domains = Dict{Symbol, Vector{Symbol}}()
    for (cmd, e) in SOLVER_REGISTRY
        push!(get!(domains, e.domain, Symbol[]), cmd)
    end
    for (dom, cmds) in sort(collect(domains), by = x -> string(x[1]))
        println(io, "  ▸ :$dom")
        for cmd in sort(cmds, by = string)
            println(io, "      :$cmd")
        end
        println(io, "")
    end
    String(take!(io))
end
 
function build_history_text(entries::Vector{Tuple{String,Bool}})::String
    isempty(entries) && return "  No queries yet."
    io = IOBuffer()
    for (i, (cmd, ok)) in enumerate(entries)
        n    = length(entries) - i + 1
        icon = ok ? "✓" : "✗"
        trim = length(cmd) > 68 ? cmd[1:65] * "..." : cmd
        println(io, "  $(lpad(n,2)).  $icon  $trim")
    end
    String(take!(io))
end
 
# ── 6. Reactive state ────────────────────────────────────────────
const MAX_HISTORY   = 16
const STYLE_IDLE    = "color:#506070;"
const STYLE_SUCCESS = "color:#3CBD52;"
const STYLE_ERROR   = "color:#F44D45;"
 
history_store = Tuple{String, Bool}[]
 
result_text  = Observable{String}(
    "\n  ⬡  B-SPEC Physical Engine  v0.1"                                         *
    "\n  ─────────────────────────────────────────────────────────────"            *
    "\n"                                                                           *
    "\n  Type a command and press SOLVE."                                          *
    "\n"                                                                           *
    "\n  EXAMPLES:"                                                                *
    "\n  get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]"      *
    "\n  get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]"           *
    "\n  get projectile_motion initial_velocity=50 angle_deg=45 initial_height=0" *
    "\n  get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8"        *
    "\n  get gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8"       *
    "\n  get elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0"                      *
    "\n"
)
result_style = Observable{String}(STYLE_IDLE)
history_text = Observable{String}(build_history_text(history_store))
status_text  = Observable{String}(
    "● Ready  │  Solvers: $(length(SOLVER_REGISTRY))  │  Queries: 0  │  Errors: 0  │  Last: —"
)
 
# ── 7. Query runner ──────────────────────────────────────────────
function run_query!(text::String)
    text = strip(text)
    isempty(text) && return
 
    res = process(text, _state)
 
    result_text[]  = build_result_text(res)
    result_style[] = res.success ? STYLE_SUCCESS : STYLE_ERROR
 
    pushfirst!(history_store, (text, res.success))
    length(history_store) > MAX_HISTORY && pop!(history_store)
    history_text[] = build_history_text(history_store)
 
    q = _state.query_count
    e = _state.error_count
    l = isnothing(_state.last_command) ? "—" : ":$(_state.last_command)"
    n = length(SOLVER_REGISTRY)
    status_text[] = "● Ready  │  Solvers: $n  │  Queries: $q  │  Errors: $e  │  Last: $l"
end
 
# ── 8. Page builder ──────────────────────────────────────────────
function build_page(session::Session)
 
    cmd_input = Bonito.TextField(
        "get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]"
    )
    solve_btn = Bonito.Button("SOLVE")
    clear_btn = Bonito.Button("CLEAR")
 
    # .clicks is an Observable{Int} that increments on each click
    on(solve_btn.clicks) do _
        run_query!(cmd_input.value[])
    end
 
    on(clear_btn.clicks) do _
        cmd_input.value[] = ""
        result_text[]     = "\n  Cleared. Ready for next command.\n"
        result_style[]    = STYLE_IDLE
    end
 
    return Bonito.DOM.div(
        Bonito.DOM.style(STYLES_STR),
        Bonito.DOM.div(class="shell",
 
            # Header
            Bonito.DOM.div(class="topbar",
                Bonito.DOM.div(class="topbar-title",
                    "⬡  B-SPEC  PHYSICAL  ENGINE"),
                Bonito.DOM.div(class="topbar-sub",
                    "Scientific Computing Solver Interface"),
                Bonito.DOM.span(class="pill", "v0.1"),
            ),
 
            Bonito.DOM.div(class="main",
 
                # Left panel
                Bonito.DOM.div(class="left-panel",
                    Bonito.DOM.div(class="sec-label", "COMMAND INPUT"),
                    Bonito.DOM.div(class="input-wrap", cmd_input),
                    Bonito.DOM.div(class="btn-row", solve_btn, clear_btn),
                    Bonito.DOM.hr(class="divider"),
                    Bonito.DOM.div(class="sec-label", "SOLVER REGISTRY"),
                    Bonito.DOM.pre(class="registry-pre", build_registry_text()),
                    Bonito.DOM.pre(class="guide-pre",
                        "  FORMAT:   [verb] command key=value key=[x,y,z]\n" *
                        "  VECTORS:  source=[0.0, 0.0, 0.0]\n"              *
                        "  VERBS:    get | find | compute | solve\n"         *
                        "  UNITS:    all values in SI"
                    ),
                ),
 
                # Right panel
                Bonito.DOM.div(class="right-panel",
                    Bonito.DOM.div(class="result-wrap",
                        Bonito.DOM.pre(result_text;
                            class = "result-pre",
                            style = result_style,
                        ),
                    ),
                    Bonito.DOM.div(class="history-wrap",
                        Bonito.DOM.div(class="history-label", "QUERY HISTORY"),
                        Bonito.DOM.pre(history_text; class="history-pre"),
                    ),
                ),
            ),
 
            Bonito.DOM.div(class="statusbar", status_text),
        )
    )
end
 
# ── 9. Start server ──────────────────────────────────────────────
const PORT = 8050
 
app = App() do session::Session
    build_page(session)
end
 
println("\n" * "█"^58)
println("  B-SPEC  Web GUI  v0.1")
println("  Solvers : $(join(_state.solvers_loaded, "  |  "))")
println("  Commands: $(length(SOLVER_REGISTRY))")
println("█"^58)
println()
println("  Local  →  http://localhost:$PORT")
println()
println("  Revise active — edit any solver file and save;")
println("  the next SOLVE uses the updated code immediately.")
println()
println("  Press Ctrl+C to stop the server.")
println()
 
server = Bonito.Server(app, "0.0.0.0", PORT)
 
try
    while true
        sleep(1)
    end
catch e
    e isa InterruptException || rethrow(e)
    println("\n  Server stopped.")
end