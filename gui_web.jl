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

# ── 1. Engine includes ───────────────────────────────────────────
includet("core/types.jl")
includet("core/tokenizer.jl")
includet("core/dispatcher.jl")
includet("core/engine.jl")
includet("solvers/electromagnetics.jl")
includet("solvers/classical_mechanics.jl")

# ── 2. Web packages ──────────────────────────────────────────────
using Bonito, WGLMakie
using Printf

# ── 3. Engine init ───────────────────────────────────────────────
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]

# ── 4. CSS — dark scientific theme, mobile-first ─────────────────
# Bonito.CSS() doesn't accept a plain string — inject via DOM.style() instead.
# STYLES_STR holds the raw CSS; it's wrapped in DOM.style() inside build_page.
const STYLES_STR = """
  /* ── Reset & base ─────────────────────────────────────────── */
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background : #0C1016;
    color       : #E1E8F1;
    font-family : 'Courier New', Courier, monospace;
    font-size   : 14px;
    min-height  : 100vh;
  }

  /* ── Layout shell ──────────────────────────────────────────── */
  .shell {
    display        : flex;
    flex-direction : column;
    height         : 100vh;
    overflow       : hidden;
  }

  /* ── Header ────────────────────────────────────────────────── */
  .topbar {
    background    : #151A21;
    border-bottom : 1px solid #2A3240;
    padding       : 10px 18px;
    display       : flex;
    align-items   : center;
    justify-content: space-between;
    flex-shrink   : 0;
  }
  .topbar-title {
    color       : #53A2FF;
    font-size   : 15px;
    letter-spacing: 2px;
    font-weight : bold;
  }
  .topbar-sub {
    color     : #606870;
    font-size : 11px;
  }
  .pill {
    background : #1B2129;
    border     : 1px solid #2A3240;
    color      : #53A2FF;
    font-size  : 10px;
    padding    : 2px 8px;
    border-radius: 12px;
    letter-spacing: 1px;
  }

  /* ── Main area — two columns on wide, stacked on narrow ─────── */
  .main {
    display  : flex;
    flex     : 1;
    overflow : hidden;
  }

  /* ── Left panel ────────────────────────────────────────────── */
  .left-panel {
    width          : 340px;
    min-width      : 340px;
    background     : #151A21;
    border-right   : 1px solid #2A3240;
    display        : flex;
    flex-direction : column;
    overflow-y     : auto;
    padding-bottom : 12px;
  }

  /* ── Right panel ───────────────────────────────────────────── */
  .right-panel {
    flex           : 1;
    display        : flex;
    flex-direction : column;
    overflow       : hidden;
    background     : #0F1419;
  }

  /* ── Section labels ─────────────────────────────────────────── */
  .sec-label {
    color          : #53A2FF;
    font-size      : 10px;
    letter-spacing : 2px;
    padding        : 12px 14px 6px;
    text-transform : uppercase;
  }

  /* ── Input box ──────────────────────────────────────────────── */
  .input-wrap { padding: 0 12px 8px; }

  .cmd-input {
    width         : 100%;
    background    : #1B2129;
    border        : 1px solid #2A3240;
    border-radius : 4px;
    color         : #E1E8F1;
    font-family   : 'Courier New', monospace;
    font-size     : 13px;
    padding       : 10px 12px;
    outline       : none;
    resize        : vertical;
    min-height    : 72px;
    transition    : border-color 0.15s;
  }
  .cmd-input:focus { border-color: #53A2FF; }
  .cmd-input::placeholder { color: #404850; }

  /* ── Button row ─────────────────────────────────────────────── */
  .btn-row {
    display    : flex;
    gap        : 8px;
    padding    : 0 12px 10px;
  }
  .btn {
    padding       : 8px 20px;
    border-radius : 4px;
    font-family   : 'Courier New', monospace;
    font-size     : 13px;
    cursor        : pointer;
    border        : none;
    transition    : background 0.15s, transform 0.08s;
  }
  .btn:active { transform: scale(0.97); }
  .btn-solve {
    background : #2465A8;
    color      : #E1E8F1;
    flex       : 1;
    letter-spacing: 1px;
  }
  .btn-solve:hover { background: #3381D1; }
  .btn-clear {
    background : #1B2129;
    color      : #818B98;
    border     : 1px solid #2A3240;
  }
  .btn-clear:hover { background: #252D38; color: #E1E8F1; }

  /* ── Divider ────────────────────────────────────────────────── */
  .divider {
    border     : none;
    border-top : 1px solid #2A3240;
    margin     : 6px 12px;
  }

  /* ── Registry list ──────────────────────────────────────────── */
  .registry {
    padding   : 4px 14px;
    font-size : 12px;
    color     : #818B98;
    line-height: 1.9;
  }
  .reg-domain { color: #53A2FF; margin-top: 4px; }
  .reg-cmd {
    padding-left : 14px;
    color        : #606870;
    font-size    : 11.5px;
  }
  .reg-cmd:hover { color: #53A2FF; cursor: default; }

  /* ── Format guide ───────────────────────────────────────────── */
  .guide {
    padding   : 6px 14px 4px;
    font-size : 11px;
    color     : #505860;
    line-height: 1.8;
    border-top: 1px solid #2A3240;
    margin-top: 4px;
  }
  .guide span { color: #818B98; }

  /* ── Result panel ───────────────────────────────────────────── */
  .result-wrap {
    flex           : 1;
    overflow-y     : auto;
    padding        : 12px 14px;
    background     : #0F1419;
  }

  /* Result states */
  .result-idle    { color: #506070; white-space: pre; font-size: 13px; line-height: 1.75; }
  .result-success { color: #3CBD52; white-space: pre; font-size: 13px; line-height: 1.75; }
  .result-error   { color: #F44D45; white-space: pre; font-size: 13px; line-height: 1.75; }

  /* ── History strip ──────────────────────────────────────────── */
  .history-wrap {
    background    : #151A21;
    border-top    : 1px solid #2A3240;
    padding       : 6px 14px 8px;
    max-height    : 160px;
    overflow-y    : auto;
    flex-shrink   : 0;
  }
  .history-label {
    color          : #53A2FF;
    font-size      : 10px;
    letter-spacing : 2px;
    padding-bottom : 4px;
  }
  .history-item {
    font-size   : 11.5px;
    color       : #606870;
    padding     : 2px 0;
    line-height : 1.6;
    white-space : nowrap;
    overflow    : hidden;
    text-overflow: ellipsis;
  }
  .ok  { color: #3CBD52; }
  .err { color: #F44D45; }

  /* ── Status bar ─────────────────────────────────────────────── */
  .statusbar {
    background    : #151A21;
    border-top    : 1px solid #2A3240;
    padding       : 4px 14px;
    font-size     : 11px;
    color         : #606870;
    display       : flex;
    gap           : 12px;
    flex-shrink   : 0;
    white-space   : nowrap;
    overflow-x    : auto;
  }
  .status-dot { color: #3CBD52; }

  /* ── Responsive: stack on narrow screens (phone) ────────────── */
  @media (max-width: 700px) {
    .main         { flex-direction: column; }
    .left-panel   { width: 100%; min-width: unset; border-right: none;
                    border-bottom: 1px solid #2A3240; max-height: 55vh;
                    overflow-y: auto; }
    .right-panel  { flex: 1; min-height: 0; }
    .topbar-sub   { display: none; }
    .cmd-input    { min-height: 56px; font-size: 14px; }
    .btn          { padding: 10px 14px; font-size: 14px; }
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
    bar = "─" ^ 62
    io  = IOBuffer()
    if r.success
        println(io, "\n  ✓  :$(r.command)")
        println(io, "       solver  :  :$(r.solver_id)")
        println(io, "  $bar\n")
        println(io, "  $(rpad("Quantity", 30)) $(rpad("Value", 22)) Unit")
        println(io, "  $(rpad("─"^30, 30)) $(rpad("─"^22, 22)) ────────────────")
        println(io, "")
        for (k, v) in sort(collect(r.outputs), by = x -> string(x[1]))
            u = get(r.units, k, "?")
            println(io, "  $(rpad(string(k),30)) $(rpad(_fmtv(v),22)) $u")
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
        println(io, "  Tip: check the solver list on the left panel\n")
    end
    String(take!(io))
end

function build_registry_html()::String
    io      = IOBuffer()
    domains = Dict{Symbol, Vector{Symbol}}()
    for (cmd, e) in SOLVER_REGISTRY
        push!(get!(domains, e.domain, Symbol[]), cmd)
    end
    for (dom, cmds) in sort(collect(domains), by = x -> string(x[1]))
        println(io, """<div class="reg-domain">▸ :$dom</div>""")
        for cmd in sort(cmds, by = string)
            println(io, """<div class="reg-cmd">:$cmd</div>""")
        end
    end
    String(take!(io))
end

function build_history_html(entries::Vector{Tuple{String,Bool}})::String
    isempty(entries) && return """<div class="history-item" style="color:#404850">No queries yet.</div>"""
    io = IOBuffer()
    for (i, (cmd, ok)) in enumerate(entries)
        icon  = ok ? """<span class="ok">✓</span>""" : """<span class="err">✗</span>"""
        trim  = length(cmd) > 72 ? cmd[1:69] * "..." : cmd
        n     = length(entries) - i + 1
        println(io, """<div class="history-item">$(lpad(n,2)).&nbsp;$icon&nbsp;$trim</div>""")
    end
    String(take!(io))
end

# ── 6. Reactive state ────────────────────────────────────────────
const MAX_HISTORY = 16
history_store     = Tuple{String, Bool}[]

result_class = Observable{String}("result-idle")
result_text  = Observable{String}(
    "\n  ⬡  B-SPEC Physical Engine  v0.1" *
    "\n  ──────────────────────────────────────────────────────────────" *
    "\n" *
    "\n  Type a command and press SOLVE (or tap ↵ on mobile)." *
    "\n" *
    "\n  EXAMPLES" *
    "\n  get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]" *
    "\n  get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]" *
    "\n  get projectile_motion initial_velocity=50 angle_deg=45 initial_height=0" *
    "\n  get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8 amplitude=0.1" *
    "\n  get gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8" *
    "\n  get elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0" *
    "\n"
)
history_html = Observable{String}(build_history_html(history_store))
status_text  = Observable{String}(
    "● Ready  │  Solvers: $(length(SOLVER_REGISTRY))  │  Queries: 0  │  Errors: 0  │  Last: —"
)

# ── 7. Query runner ──────────────────────────────────────────────
function run_query!(text::String)
    text = strip(text)
    isempty(text) && return
    res = process(text, _state)

    result_text[]  = build_result_text(res)
    result_class[] = res.success ? "result-success" : "result-error"

    pushfirst!(history_store, (text, res.success))
    length(history_store) > MAX_HISTORY && pop!(history_store)
    history_html[] = build_history_html(history_store)

    q = _state.query_count
    e = _state.error_count
    l = isnothing(_state.last_command) ? "—" : ":$(_state.last_command)"
    n = length(SOLVER_REGISTRY)
    status_text[] = "● Ready  │  Solvers: $n  │  Queries: $q  │  Errors: $e  │  Last: $l"
end

# ── 8. Page builder ──────────────────────────────────────────────
function build_page(session::Session)
    # Textarea + buttons are plain HTML/JS via Bonito DOM helpers
    cmd_input = Bonito.TextField("";
        placeholder = "get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]",
    )

    solve_btn = Bonito.Button("SOLVE")
    clear_btn = Bonito.Button("CLEAR")

    # Wire solve button
    on(solve_btn) do _
        run_query!(cmd_input.value[])
    end

    # Wire clear button
    on(clear_btn) do _
        cmd_input.value[] = ""
        result_text[]     = "\n  Cleared. Ready for next command.\n"
        result_class[]    = "result-idle"
    end

    # Wire Enter key on textarea (JS side)
    # Bonito allows injecting JS; we use onkeydown to catch Ctrl+Enter
    js_enter = js"""
        (function(){
          const ta = document.querySelector('textarea');
          if(!ta) return;
          ta.addEventListener('keydown', function(e){
            if((e.ctrlKey || e.metaKey) && e.key === 'Enter'){
              e.preventDefault();
              $(solve_btn).click();
            }
          });
        })();
    """

    return Bonito.DOM.div(
        Bonito.DOM.style(STYLES_STR),
        Bonito.DOM.div(class="shell",
            # ── Header ──────────────────────────────────────────
            Bonito.DOM.div(class="topbar",
                Bonito.DOM.div(class="topbar-title",
                    "⬡  B-SPEC  PHYSICAL  ENGINE"),
                Bonito.DOM.div(class="topbar-sub",
                    "Scientific Computing Solver Interface"),
                Bonito.DOM.span(class="pill", "v0.1")
            ),

            # ── Main ────────────────────────────────────────────
            Bonito.DOM.div(class="main",

                # ── Left panel ──────────────────────────────────
                Bonito.DOM.div(class="left-panel",
                    Bonito.DOM.div(class="sec-label", "COMMAND INPUT"),
                    Bonito.DOM.div(class="input-wrap",
                        Bonito.DOM.textarea(cmd_input;
                            class       = "cmd-input",
                            rows        = "4",
                            spellcheck  = "false",
                            autocorrect = "off",
                            autocomplete= "off",
                        )
                    ),
                    Bonito.DOM.div(class="btn-row",
                        Bonito.DOM.button(solve_btn; class="btn btn-solve"),
                        Bonito.DOM.button(clear_btn; class="btn btn-clear"),
                    ),
                    Bonito.DOM.hr(class="divider"),
                    Bonito.DOM.div(class="sec-label", "SOLVER REGISTRY"),
                    Bonito.DOM.div(class="registry",
                        Bonito.DOM.innerHTML(build_registry_html())
                    ),
                    Bonito.DOM.div(class="guide",
                        Bonito.DOM.innerHTML(
                            "<span>FORMAT:</span>  [verb] command key=value key=[x,y,z]<br>" *
                            "<span>VECTORS:</span> position=[0.0, 1.0, 0.0]<br>" *
                            "<span>VERBS:</span>   get | find | compute | solve<br>" *
                            "<span>HINT:</span>    Ctrl+Enter = SOLVE on keyboard"
                        )
                    ),
                ),

                # ── Right panel ──────────────────────────────────
                Bonito.DOM.div(class="right-panel",
                    # Result body
                    Bonito.DOM.div(class="result-wrap",
                        Bonito.DOM.pre(result_text;
                            class = @map("result-" * ($result_class == "result-idle" ? "idle" :
                                         $result_class == "result-success" ? "success" : "error"))
                        )
                    ),
                    # History strip
                    Bonito.DOM.div(class="history-wrap",
                        Bonito.DOM.div(class="history-label", "QUERY HISTORY"),
                        Bonito.DOM.div(Bonito.DOM.innerHTML(history_html))
                    ),
                ),
            ),

            # ── Status bar ───────────────────────────────────────
            Bonito.DOM.div(class="statusbar",
                Bonito.DOM.span(Bonito.DOM.innerHTML(
                    @map("<span class='status-dot'>●</span> " * $status_text)
                ))
            ),

            # JS for Ctrl+Enter
            Bonito.DOM.script(Bonito.DOM.innerHTML("""
                document.addEventListener('DOMContentLoaded', function(){
                    $js_enter
                });
            """))
        )
    )
end

# ── 9. Start server ──────────────────────────────────────────────
const PORT = 8050

app = App() do session::Session
    return build_page(session)
end

println("\n" * "█"^62)
println("  B-SPEC  Web GUI  v0.1")
println("  Solvers loaded: $(join(_state.solvers_loaded, "  |  "))")
println("  Total commands: $(length(SOLVER_REGISTRY))")
println("█"^62)
println()
println("  Local  →  http://localhost:$PORT")
println("  Phone  →  http://$(get(ENV, "HOST_IP", "<your-IP>"))  :$PORT")
println("             (phone must be on same WiFi, or use Termux)")
println()
println("  Tip: edit any solver file and save — Revise patches it live.")
println("  Tip: Ctrl+C to stop the server.")
println()

server = Bonito.Server(app, "0.0.0.0", PORT)

# Keep Julia alive
try
    while true
        sleep(1)
    end
catch e
    e isa InterruptException || rethrow(e)
    println("\n  Server stopped.")
end