#!/usr/bin/env julia
# ================================================================
# FILE: gui_web.jl   B-SPEC Physical Engine  Web Interface v2.0
#
# Architecture (from design doc):
#   Browser → JSON request → Julia HTTP server → engine → JSON response → Browser
#
# Endpoints:
#   GET  /         → full single-page application (HTML/CSS/JS)
#   GET  /solvers  → solver registry + param metadata (drives auto-form)
#   POST /solve    → {mode, solver?, params?, query?} → {success, rows, plot_data}
#
# Modes:
#   "structured" → frontend sends {solver, params} dict — bypasses tokenizer
#   "command"    → frontend sends raw string — goes through full pipeline
#
# Key fix: uses @__DIR__ for all includes, so the file runs correctly
# from ANY directory (VSCode terminal, system terminal, anywhere).
#
# Key fix: HTML_PAGE uses raw string literal so JS ${...} template
# expressions are never seen by Julia's string interpolation.
#
# Run : julia gui_web.jl
# Open: http://localhost:8050
# ================================================================


# ================================================================
# FILE: gui_web.jl   B-SPEC Physical Engine  Web Interface v2.0
# ================================================================

using Revise

# ── Includes relative to THIS FILE, not the launch directory ─────
const _D = @__DIR__
includet(joinpath(_D, "core", "types.jl"))
includet(joinpath(_D, "core", "tokenizer.jl"))
includet(joinpath(_D, "core", "dispatcher.jl"))
includet(joinpath(_D, "core", "engine.jl"))
includet(joinpath(_D, "solvers", "electromagnetics.jl"))
includet(joinpath(_D, "solvers", "classical_mechanics.jl"))

using HTTP
using Printf

# ── Engine init ──────────────────────────────────────────────────
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]

# ── Param type registry ──────────────────────────────────────────
const PARAM_TYPES = Dict{Symbol,String}(
    :source       => "vector3", :field_point => "vector3",
    :r1           => "vector3", :r2          => "vector3",
    :normal       => "vector3", :E_field     => "vector3",
    :charge       => "scalar",  :q1          => "scalar",
    :q2           => "scalar",  :area        => "scalar",
    :capacitance  => "scalar",  :voltage     => "scalar",
    :V_in         => "scalar",  :initial_velocity => "scalar",
    :angle_deg    => "scalar",  :initial_height   => "scalar",
    :g            => "scalar",  :m1          => "scalar",
    :m2           => "scalar",  :distance    => "scalar",
    :mass         => "scalar",  :velocity    => "scalar",
    :force        => "scalar",  :displacement => "scalar",
    :spring_constant => "scalar", :damping   => "scalar",
    :amplitude    => "scalar",  :initial_position => "scalar",
    :radius       => "scalar",  :speed       => "scalar",
    :v1           => "scalar",  :v2          => "scalar",
    :acceleration => "scalar",  :charges     => "array",
    :sources      => "array",
)
param_type(p::Symbol) = get(PARAM_TYPES, p, "scalar")

# ── JSON serialiser ──────────────────────────────────────────────
function _jesc(s::AbstractString)::String
    s = replace(s, "\\" => "\\\\", "\"" => "\\\"",
                   "\n" => "\\n",  "\r" => "\\r", "\t" => "\\t")
    return s
end

function to_json(x)::String
    x isa Bool          && return x ? "true" : "false"
    x isa AbstractFloat && return isfinite(x) ? @sprintf("%.10g", x) : "null"
    x isa Integer       && return string(x)
    x isa AbstractString && return "\"" * _jesc(x) * "\""
    x isa AbstractVector && return "[" * join(to_json.(x), ",") * "]"
    x isa Dict          && return "{" * join(
        [to_json(string(k)) * ":" * to_json(v) for (k,v) in x], ",") * "}"
    x isa Nothing       && return "null"
    return "\"" * _jesc(string(x)) * "\""
end

# ── Request parser ────────────────────────────────────────────────
function _parse_number(s::AbstractString)
    v = tryparse(Float64, strip(s))
    isnothing(v) ? nothing : v
end

function _parse_array(s::AbstractString)::Vector{Float64}
    inner = strip(s)[2:end-1]
    [parse(Float64, strip(x)) for x in split(inner, ",")]
end

function _parse_params(s::AbstractString)::Dict{Symbol,Any}
    params = Dict{Symbol,Any}()
    pat = r"\"(\w+)\"\s*:\s*(\[[^\]]*\]|[-+]?(?:[0-9]+\.?[0-9]*|[0-9]*\.[0-9]+)(?:[eE][-+]?[0-9]+)?)"
    for m in eachmatch(pat, s)
        key = Symbol(m.captures[1])
        val = strip(m.captures[2])
        params[key] = startswith(val, "[") ? _parse_array(val) : parse(Float64, val)
    end
    return params
end

function parse_request(body::String)::Dict{String,Any}
    r = Dict{String,Any}()
    m = match(r"\"mode\"\s*:\s*\"([^\"]+)\"", body)
    !isnothing(m) && (r["mode"] = m.captures[1])
    m = match(r"\"solver\"\s*:\s*\"([^\"]+)\"", body)
    !isnothing(m) && (r["solver"] = m.captures[1])
    m = match(r"\"query\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", body)
    if !isnothing(m)
        s = m.captures[1]
        s = replace(s, "\\n"=>" ", "\\t"=>" ", "\\\\"=>"\\", "\\\"" => "\"")
        r["query"] = s
    end
    m = match(r"\"params\"\s*:\s*(\{[^}]*\})", body)
    !isnothing(m) && (r["params"] = _parse_params(m.captures[1]))
    return r
end

# ── Result formatters ────────────────────────────────────────────
function _fmtv(v)::String
    v isa AbstractVector && return "[" * join([@sprintf("%.5g",x) for x in v], ", ") * "]"
    v isa AbstractFloat  && return @sprintf("%.6g", v)
    v isa Bool           && return string(v)
    return string(v)
end

function result_to_dict(r::SolverResult)::Dict
    rows = Dict[]
    for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
        push!(rows, Dict("key"=>string(k), "value"=>_fmtv(v), "unit"=>get(r.units,k,"?")))
    end
    Dict("success"=>r.success, "command"=>string(r.command),
         "solver"=>string(r.solver_id), "message"=>r.message, "rows"=>rows)
end

function extract_plot_data(r::SolverResult)::Dict
    labels = String[]; values = Float64[]; units = String[]
    for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
        if v isa AbstractFloat && isfinite(v) && !(v isa Bool)
            push!(labels, string(k)); push!(values, v)
            push!(units, get(r.units,k,""))
        elseif v isa Integer
            push!(labels, string(k)); push!(values, Float64(v))
            push!(units, get(r.units,k,""))
        end
    end
    Dict("available"=>!isempty(values), "title"=>string(r.command),
         "labels"=>labels, "values"=>values, "units"=>units)
end

# ── Solver metadata for /solvers endpoint ────────────────────────
function build_solver_metadata()::Dict
    domains = Dict{String,Vector{Dict}}()
    for (cmd, e) in SOLVER_REGISTRY
        d = string(e.domain)
        types = Dict{String,String}()
        for p in [e.required_params; e.optional_params]
            types[string(p)] = param_type(p)
        end
        info = Dict(
            "command"     => string(cmd),
            "description" => e.description,
            "required"    => string.(e.required_params),
            "optional"    => string.(e.optional_params),
            "param_types" => types
        )
        push!(get!(domains, d, Dict[]), info)
    end
    for v in values(domains)
        sort!(v, by = x -> x["command"])
    end
    return domains
end

# ── HTML Application (raw string — $ signs are literal here) ─────
const HTML_PAGE = raw"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>B-SPEC Physical Engine</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  /* Elevated Dark Theme (Zinc Palette based) */
  --bg:         #09090b; 
  --panel:      #18181b; 
  --surface:    #27272a; 
  --border:     #3f3f46; 
  --accent:     #3b82f6; 
  --accent-hover:#2563eb;
  --success:    #10b981;
  --error:      #ef4444;
  --warn:       #f59e0b;
  --text:       #f4f4f5; 
  --text-dim:   #a1a1aa; 
  --val:        #60a5fa; 
  --unit:       #34d399;
  
  --font-sans: 'Inter', sans-serif;
  --font-mono: 'JetBrains Mono', monospace;
}

body {
  background: var(--bg); color: var(--text);
  font-family: var(--font-sans);
  font-size: 14px; height: 100dvh;
  display: flex; flex-direction: column; overflow: hidden;
}

/* ── Header ── */
.topbar {
  background: var(--panel); 
  border-bottom: 1px solid var(--border);
  padding: 12px 20px; display: flex;
  align-items: center; justify-content: space-between; flex-shrink: 0;
}
.topbar-title { color: var(--text); font-size: 16px; font-weight: 600; letter-spacing: 1px; display: flex; align-items: center; gap: 8px; }
.topbar-title span { color: var(--accent); }
.topbar-sub   { color: var(--text-dim); font-size: 12px; }
.pill {
  background: var(--surface); border: 1px solid var(--border);
  color: var(--text-dim); font-size: 11px; padding: 3px 8px;
  border-radius: 12px; font-family: var(--font-mono);
}

/* ── Main two-column layout ── */
.main { display: flex; flex: 1; overflow: hidden; }

.left-panel {
  width: 360px; min-width: 360px;
  background: var(--panel); border-right: 1px solid var(--border);
  display: flex; flex-direction: column; overflow: hidden;
}

.right-panel {
  flex: 1; display: flex; flex-direction: column; overflow: hidden;
  background: var(--bg);
}

/* ── Section label ── */
.sec-label {
  color: var(--text-dim); font-size: 11px; font-weight: 600;
  padding: 14px 16px 8px; text-transform: uppercase; flex-shrink: 0;
  letter-spacing: 0.5px;
}

/* ── Mode toggle ── */
.mode-row { display: flex; gap: 8px; padding: 0 16px 12px; flex-shrink: 0; }
.mode-btn {
  flex: 1; padding: 8px; border-radius: 6px; cursor: pointer;
  font-family: var(--font-sans); font-size: 12px; font-weight: 500;
  border: 1px solid var(--border); background: var(--surface);
  color: var(--text-dim); transition: all 0.2s ease;
}
.mode-btn:hover { border-color: #52525b; color: var(--text); }
.mode-btn.active { background: var(--accent); color: #fff; border-color: var(--accent); }

/* ── Form panel ── */
.form-panel { flex: 1; overflow-y: auto; padding: 0 16px 12px; }

select {
  width: 100%; background: var(--surface); border: 1px solid var(--border);
  border-radius: 6px; color: var(--text); font-family: var(--font-sans);
  font-size: 13px; padding: 8px 12px; outline: none; margin-bottom: 12px;
  cursor: pointer; appearance: none;
}
select:focus { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }

.solver-desc {
  font-size: 12px; color: var(--text-dim); padding: 0 4px 12px;
  line-height: 1.5; border-bottom: 1px solid var(--border);
  margin-bottom: 12px;
}

/* ── Param fields ── */
.field-group { margin-bottom: 12px; }
.field-label {
  display: flex; justify-content: space-between; font-size: 12px; 
  color: var(--text); margin-bottom: 6px; font-weight: 500;
}
.field-label .required { color: var(--text-dim); font-size: 10px; font-weight: 400; }
.field-label .optional { color: #52525b; font-size: 10px; font-weight: 400; }

input[type=number], input[type=text] {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 6px; color: var(--text); font-family: var(--font-mono);
  font-size: 13px; padding: 8px 12px; outline: none;
  transition: all 0.2s ease; width: 100%;
}
input:focus { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
input::placeholder { color: #52525b; }

.vec-row { display: flex; gap: 6px; }
.vec-input { text-align: center; }

/* ── Command mode textarea ── */
.cmd-panel { flex: 1; display: none; flex-direction: column; padding: 0 16px 12px; }
.cmd-panel.active { display: flex; }
textarea#cmd {
  flex: 1; width: 100%; min-height: 150px;
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 6px; color: var(--text); font-family: var(--font-mono);
  font-size: 13px; padding: 12px; outline: none; resize: none;
  line-height: 1.5;
}
textarea#cmd:focus { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
textarea#cmd::placeholder { color: #52525b; }
.cmd-hints { color: var(--text-dim); font-size: 11px; padding: 12px 4px; line-height: 1.8; }
.cmd-hints b { color: var(--text); font-weight: 600; }

/* ── Buttons ── */
.btn-row { display: flex; gap: 10px; padding: 12px 16px; flex-shrink: 0; background: var(--panel); border-top: 1px solid var(--border); }
button.solve {
  flex: 1; padding: 10px; border-radius: 6px;
  font-family: var(--font-sans); font-size: 13px; font-weight: 600;
  cursor: pointer; border: none; background: var(--accent);
  color: #fff; transition: background 0.2s;
}
button.solve:hover  { background: var(--accent-hover); }
button.solve:disabled { background: var(--border); color: var(--text-dim); cursor: not-allowed; }
button.clear {
  padding: 10px 16px; border-radius: 6px;
  font-family: var(--font-sans); font-size: 13px; font-weight: 500;
  cursor: pointer; border: 1px solid var(--border);
  background: transparent; color: var(--text); transition: all 0.2s;
}
button.clear:hover { background: var(--surface); }

#spinner {
  display: none; text-align: center; padding: 8px;
  color: var(--accent); font-size: 12px; font-family: var(--font-mono); flex-shrink: 0;
}
#spinner.active { display: block; }

/* ── Right panel — tabs ── */
.tab-bar {
  display: flex; background: var(--panel);
  border-bottom: 1px solid var(--border); flex-shrink: 0; padding: 0 16px;
}
.tab-btn {
  padding: 14px 16px; cursor: pointer; background: none;
  border: none; border-bottom: 2px solid transparent; margin-bottom: -1px;
  font-family: var(--font-sans); font-size: 12px; font-weight: 500;
  color: var(--text-dim); transition: all 0.2s;
}
.tab-btn:hover { color: var(--text); }
.tab-btn.active { color: var(--accent); border-bottom-color: var(--accent); }

.tab-content { display: none; flex: 1; overflow: hidden; flex-direction: column; }
.tab-content.active { display: flex; }

/* ── Empty State / Welcome Card ── */
.welcome-container {
  flex: 1; display: flex; align-items: center; justify-content: center;
  padding: 40px; background-image: radial-gradient(#27272a 1px, transparent 1px);
  background-size: 24px 24px;
}
.welcome-card {
  background: var(--panel); border: 1px solid var(--border);
  border-radius: 8px; padding: 32px; max-width: 500px; width: 100%;
  box-shadow: 0 10px 30px rgba(0,0,0,0.5);
}
.welcome-card h2 { font-weight: 600; font-size: 18px; margin-bottom: 4px; color: var(--text); }
.welcome-card p { color: var(--text-dim); font-size: 13px; margin-bottom: 24px; }
.example-box {
  background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
  padding: 12px; font-family: var(--font-mono); font-size: 12px; color: var(--val);
  margin-bottom: 8px; word-break: break-all;
}

/* ── Result tab ── */
.result-scroll { flex: 1; overflow-y: auto; padding: 24px; display: none; }
.result-scroll.active { display: block; }

#result-status {
  display: flex; align-items: flex-start; gap: 12px;
  margin-bottom: 24px; padding: 16px; background: var(--panel);
  border: 1px solid var(--border); border-radius: 6px;
}
.status-icon { font-size: 18px; line-height: 1; }
.status-cmd  { color: var(--text); font-family: var(--font-mono); font-size: 13px; }
.status-solver { color: var(--text-dim); font-family: var(--font-sans); font-size: 12px; }
.status-msg  { color: var(--text-dim); font-size: 13px; margin-top: 8px; font-family: var(--font-mono); }

.result-table { width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: 13px; }
.result-table th {
  color: var(--text-dim); text-align: left; padding: 8px 16px 12px 0;
  border-bottom: 1px solid var(--border); font-family: var(--font-sans);
  font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px;
}
.result-table td { padding: 12px 16px 12px 0; border-bottom: 1px solid var(--border); vertical-align: middle; }
.td-key  { color: var(--text-dim); width: 30%; }
.td-val  { color: var(--val); font-weight: 500; }
.td-unit { color: var(--unit); font-size: 12px; text-align: right; }

/* ── Plot tab ── */
.plot-scroll {
  flex: 1; overflow-y: auto; padding: 24px;
  display: flex; flex-direction: column; align-items: center;
}
#plot-canvas-wrap { width: 100%; max-width: 800px; background: var(--panel); padding: 16px; border-radius: 8px; border: 1px solid var(--border); }
#plot-msg { color: var(--text-dim); font-size: 13px; text-align: center; margin-top: 40px; }

/* ── History tab ── */
.history-scroll { flex: 1; overflow-y: auto; padding: 16px 24px; }
.history-item {
  display: flex; align-items: flex-start; gap: 12px;
  padding: 12px 0; border-bottom: 1px solid var(--border);
}
.h-icon { font-size: 14px; flex-shrink: 0; line-height: 1.2; }
.h-ok   { color: var(--success); }
.h-err  { color: var(--error); }
.h-cmd  { color: var(--text); font-family: var(--font-mono); font-size: 12px; }
.h-msg  { color: var(--text-dim); font-size: 12px; margin-top: 4px; }

/* ── Status bar ── */
.statusbar {
  background: var(--panel); border-top: 1px solid var(--border);
  padding: 6px 16px; font-size: 11px; color: var(--text-dim); font-family: var(--font-mono);
  flex-shrink: 0; display: flex; gap: 0; white-space: nowrap; overflow-x: auto;
}
.status-sep { margin: 0 12px; color: var(--border); }
#sdot { color: var(--success); font-size: 10px; margin-right: 6px; }

/* ── Scrollbar ── */
::-webkit-scrollbar { width: 8px; height: 8px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: #52525b; border-radius: 4px; }
::-webkit-scrollbar-thumb:hover { background: #71717a; }

/* ── Phone responsive ── */
@media (max-width: 768px) {
  .main        { flex-direction: column; }
  .left-panel  { width: 100%; min-width: unset; border-right: none;
                 border-bottom: 1px solid var(--border); max-height: 50vh; }
  .right-panel { flex: 1; min-height: 0; }
  .topbar-sub  { display: none; }
}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-title">&#x2B22; <span>B-SPEC</span> PHYSICAL ENGINE</div>
  <div class="topbar-sub">Scientific Computing Interface</div>
  <span class="pill">v2.0</span>
</div>

<div class="main">

  <div class="left-panel">
    <div class="sec-label">Input Mode</div>
    <div class="mode-row">
      <button class="mode-btn active" id="mode-form-btn" onclick="setMode('form')">Form Builder</button>
      <button class="mode-btn"        id="mode-cmd-btn"  onclick="setMode('command')">CLI Mode</button>
    </div>

    <div class="form-panel" id="form-panel">
      <div class="sec-label" style="padding: 0 0 8px;">Domain</div>
      <select id="domain-select" onchange="onDomainChange()">
        <option>loading...</option>
      </select>
      <div class="sec-label" style="padding: 8px 0 8px;">Solver Engine</div>
      <select id="solver-select" onchange="onSolverChange()">
        <option>loading...</option>
      </select>
      <div class="solver-desc" id="solver-desc">Select a solver above.</div>
      <div id="param-fields"></div>
    </div>

    <div class="cmd-panel" id="cmd-panel">
      <div class="sec-label" style="padding: 0 0 8px;">Raw Command</div>
      <textarea id="cmd" placeholder="get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]" spellcheck="false"></textarea>
      <div class="cmd-hints">
        <b>FORMAT:</b> [verb] command key=value key=[x,y,z]<br>
        <b>VERBS:</b> get | find | compute | solve<br>
        <b>TIP:</b> Ctrl+Enter to compute
      </div>
    </div>

    <div id="spinner">Computing...</div>
    <div class="btn-row">
      <button class="clear" onclick="clearAll()">Clear</button>
      <button class="solve" id="solve-btn" onclick="solve()">Compute &#x2192;</button>
    </div>
  </div>

  <div class="right-panel">
    <div class="tab-bar">
      <button class="tab-btn active" onclick="switchTab('result')"  id="tbtn-result">Results</button>
      <button class="tab-btn"        onclick="switchTab('plot')"    id="tbtn-plot">Visualization</button>
      <button class="tab-btn"        onclick="switchTab('history')" id="tbtn-history">History</button>
    </div>

    <div class="tab-content active" id="tab-result">
      
      <div class="welcome-container" id="welcome-state">
        <div class="welcome-card">
          <h2>&#x2B22; B-SPEC Physical Engine</h2>
          <p>Analytical & simulation core ready for queries.</p>
          <div style="font-size: 11px; color: var(--text-dim); margin-bottom: 8px; text-transform: uppercase;">Example Commands</div>
          <div class="example-box">get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]</div>
          <div class="example-box">get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8</div>
        </div>
      </div>

      <div class="result-scroll" id="result-container">
        <div id="result-status"></div>
        <div id="result-body"></div>
      </div>
    </div>

    <div class="tab-content" id="tab-plot">
      <div class="plot-scroll">
        <div id="plot-canvas-wrap" style="display:none;">
          <canvas id="plot-canvas"></canvas>
        </div>
        <div id="plot-msg">Run a solver to generate visualizations.</div>
      </div>
    </div>

    <div class="tab-content" id="tab-history">
      <div class="history-scroll" id="history-list">
        <div style="color:var(--text-dim);font-size:13px">No queries executed yet.</div>
      </div>
    </div>
  </div>
</div>

<div class="statusbar">
  <span id="sdot">&#x25CF;</span>
  <span id="s-queries">Queries: 0</span>
  <span class="status-sep">|</span>
  <span id="s-errors">Errors: 0</span>
  <span class="status-sep">|</span>
  <span id="s-last">Last: none</span>
  <span class="status-sep">|</span>
  <span id="s-mode">Mode: form</span>
</div>

<script>
// ── Global state ──────────────────────────────────────────────
var solverMeta  = {};
var currentMode = 'form';
var historyLog  = [];
var queryCount  = 0;
var errorCount  = 0;
var chartInstance = null;

// ── Tabs ──────────────────────────────────────────────────────
function switchTab(name) {
  ['result','plot','history'].forEach(function(t) {
    document.getElementById('tab-' + t).classList.remove('active');
    document.getElementById('tbtn-' + t).classList.remove('active');
  });
  document.getElementById('tab-' + name).classList.add('active');
  document.getElementById('tbtn-' + name).classList.add('active');
}

// ── Mode toggle ───────────────────────────────────────────────
function setMode(mode) {
  currentMode = mode;
  document.getElementById('mode-form-btn').classList.toggle('active', mode === 'form');
  document.getElementById('mode-cmd-btn').classList.toggle('active', mode === 'command');
  document.getElementById('form-panel').style.display = mode === 'form' ? '' : 'none';
  document.getElementById('cmd-panel').classList.toggle('active', mode === 'command');
  document.getElementById('s-mode').textContent = 'Mode: ' + mode;
}

// ── Solver registry ───────────────────────────────────────────
function loadSolvers() {
  fetch('/solvers')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      solverMeta = data;
      buildDomainSelect();
    })
    .catch(function() {
      document.getElementById('domain-select').innerHTML = '<option>Error loading solvers</option>';
    });
}

function buildDomainSelect() {
  var sel = document.getElementById('domain-select');
  sel.innerHTML = '';
  Object.keys(solverMeta).sort().forEach(function(d) {
    var opt = document.createElement('option');
    opt.value = d; opt.textContent = d.replace(/_/g, ' ').toUpperCase();
    sel.appendChild(opt);
  });
  buildSolverSelect();
}

function onDomainChange() { buildSolverSelect(); }
function onSolverChange() { buildParamFields(); }

function buildSolverSelect() {
  var domain = document.getElementById('domain-select').value;
  var sel = document.getElementById('solver-select');
  sel.innerHTML = '';
  var solvers = solverMeta[domain] || [];
  solvers.forEach(function(s) {
    var opt = document.createElement('option');
    opt.value = s.command; opt.textContent = s.command.replace(/_/g, ' ');
    sel.appendChild(opt);
  });
  buildParamFields();
}

function getSolverInfo() {
  var domain = document.getElementById('domain-select').value;
  var cmd    = document.getElementById('solver-select').value;
  return (solverMeta[domain] || []).find(function(s) { return s.command === cmd; });
}

// ── Auto-generate param input fields ─────────────────────────
function buildParamFields() {
  var solver = getSolverInfo();
  var container = document.getElementById('param-fields');
  container.innerHTML = '';
  if (!solver) return;

  document.getElementById('solver-desc').textContent = solver.description;

  solver.required.forEach(function(p) { container.appendChild(makeField(p, solver.param_types[p] || 'scalar', true)); });
  solver.optional.forEach(function(p) { container.appendChild(makeField(p, solver.param_types[p] || 'scalar', false)); });
}

function makeField(name, type, required) {
  var div = document.createElement('div');
  div.className = 'field-group';

  var lbl = document.createElement('label');
  lbl.className = 'field-label';
  lbl.innerHTML = name.replace(/_/g, ' ') + (required ? '<span class="required">(req)</span>' : '<span class="optional">(opt)</span>');
  div.appendChild(lbl);

  if (type === 'vector3') {
    var row = document.createElement('div');
    row.className = 'vec-row';
    ['x','y','z'].forEach(function(axis) {
      var inp = document.createElement('input');
      inp.type = 'number'; inp.step = 'any';
      inp.placeholder = axis; inp.className = 'vec-input';
      inp.id = 'p__' + name + '__' + axis;
      row.appendChild(inp);
    });
    div.appendChild(row);
  } else if (type === 'array') {
    var inp = document.createElement('input');
    inp.type = 'text'; inp.placeholder = 'e.g. [1e-9, -2e-9]';
    inp.id = 'p__' + name;
    div.appendChild(inp);
  } else {
    var inp = document.createElement('input');
    inp.type = 'number'; inp.step = 'any';
    inp.placeholder = 'value'; inp.id = 'p__' + name;
    div.appendChild(inp);
  }
  return div;
}

function collectParams() {
  var solver = getSolverInfo();
  if (!solver) return null;
  var params = {};
  var all = solver.required.concat(solver.optional);

  for (var i = 0; i < all.length; i++) {
    var name = all[i];
    var type = solver.param_types[name] || 'scalar';

    if (type === 'vector3') {
      var xi = document.getElementById('p__' + name + '__x');
      if (!xi || xi.value === '') continue;
      params[name] = [
        parseFloat(xi.value) || 0,
        parseFloat(document.getElementById('p__' + name + '__y').value) || 0,
        parseFloat(document.getElementById('p__' + name + '__z').value) || 0
      ];
    } else if (type === 'array') {
      var inp = document.getElementById('p__' + name);
      if (!inp || inp.value.trim() === '') continue;
      try { params[name] = JSON.parse(inp.value.trim()); } catch(e) { }
    } else {
      var inp = document.getElementById('p__' + name);
      if (!inp || inp.value === '') continue;
      params[name] = parseFloat(inp.value);
    }
  }
  return params;
}

// ── Helpers ───────────────────────────────────────────────────
function escHtml(s) {
  if (!s) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function updateStatus(cmd) {
  document.getElementById('s-queries').textContent = 'Queries: ' + queryCount;
  document.getElementById('s-errors').textContent  = 'Errors: ' + errorCount;
  document.getElementById('s-last').textContent    = 'Last: ' + (cmd === 'error' ? 'Failed' : 'Success');
}
function clearAll() {
  if(currentMode === 'form') {
    var inputs = document.getElementById('param-fields').querySelectorAll('input');
    inputs.forEach(function(i) { i.value = ''; });
  } else {
    document.getElementById('cmd').value = '';
  }
}
function addHistory(data) {
  var list = document.getElementById('history-list');
  if(queryCount === 1 && errorCount === (data.success?0:1)) list.innerHTML = '';
  var div = document.createElement('div');
  div.className = 'history-item';
  var icon = data.success ? '<span class="h-icon h-ok">&#x2713;</span>' : '<span class="h-icon h-err">&#x2717;</span>';
  div.innerHTML = icon + '<div><div class="h-cmd">' + escHtml(data.command) + '</div><div class="h-msg">' + (data.success ? 'Success' : escHtml(data.message)) + '</div></div>';
  list.insertBefore(div, list.firstChild);
}

// ── Solve ─────────────────────────────────────────────────────
function solve() {
  var payload;
  if (currentMode === 'form') {
    var solver = getSolverInfo();
    if (!solver) { alert('Please select a solver.'); return; }
    var params = collectParams();
    payload = JSON.stringify({ mode: 'structured', solver: solver.command, params: params });
  } else {
    var text = document.getElementById('cmd').value.trim();
    if (!text) return;
    payload = JSON.stringify({ mode: 'command', query: text });
  }

  document.getElementById('welcome-state').style.display = 'none';
  document.getElementById('result-container').classList.add('active');

  document.getElementById('spinner').classList.add('active');
  document.getElementById('solve-btn').disabled = true;
  document.getElementById('sdot').style.color = '#f59e0b';

  fetch('/solve', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: payload })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    queryCount++; if (!data.success) errorCount++;
    renderResult(data);
    if (data.plot_data) renderPlot(data.plot_data);
    addHistory(data); updateStatus(data.command); switchTab('result');
  })
  .catch(function(e) {
    errorCount++; showError('Network error: ' + e.message); updateStatus('error');
  })
  .finally(function() {
    document.getElementById('spinner').classList.remove('active');
    document.getElementById('solve-btn').disabled = false;
    document.getElementById('sdot').style.color = '#10b981';
  });
}

// ── Render result ─────────────────────────────────────────────
function renderResult(data) {
  var status = document.getElementById('result-status');
  var body   = document.getElementById('result-body');

  if (data.success) {
    status.style.borderColor = 'var(--border)';
    status.innerHTML =
      '<span class="status-icon h-ok">&#x2713;</span>' +
      '<div><div class="status-cmd">> ' + data.command + '</div>' +
      '<div class="status-msg">Engine: ' + data.solver + ' | ' + escHtml(data.message) + '</div></div>';

    var html = '<table class="result-table">' +
      '<thead><tr><th>Quantity</th><th>Computed Value</th><th style="text-align:right">Unit</th></tr></thead><tbody>';
    data.rows.forEach(function(row) {
      html += '<tr>' +
        '<td class="td-key">'  + escHtml(row.key.replace(/_/g, ' '))   + '</td>' +
        '<td class="td-val">'  + escHtml(row.value) + '</td>' +
        '<td class="td-unit">' + escHtml(row.unit)  + '</td>' +
        '</tr>';
    });
    html += '</tbody></table>';
    body.innerHTML = html;
  } else {
    showError('Failed to parse: ' + data.command + '\n\n' + data.message);
  }
}

function showError(msg) {
  var status = document.getElementById('result-status');
  status.style.borderColor = 'var(--error)';
  status.innerHTML = '<span class="status-icon h-err">&#x2717;</span><span style="color:var(--error); font-family:var(--font-mono); font-size:12px;">' + escHtml(msg) + '</span>';
  document.getElementById('result-body').innerHTML = '';
}

// ── Plot ──────────────────────────────────────────────────────
function renderPlot(pd) {
  var msg    = document.getElementById('plot-msg');
  var canvas = document.getElementById('plot-canvas');
  var wrap   = document.getElementById('plot-canvas-wrap');

  if (!pd.available || pd.values.length === 0) {
    msg.textContent = 'No scalar numeric values to plot for this result.';
    wrap.style.display = 'none'; return;
  }

  msg.textContent = ''; wrap.style.display = 'block';
  if (chartInstance) { chartInstance.destroy(); chartInstance = null; }

  var labels = pd.labels.map(function(l, i) { return l.replace(/_/g,' ') + (pd.units[i] ? ' (' + pd.units[i] + ')' : ''); });
  var absVals = pd.values.map(Math.abs);
  var colors  = pd.values.map(function(v) { return v >= 0 ? 'rgba(59, 130, 246, 0.8)' : 'rgba(239, 68, 68, 0.8)'; });

  var useLog = false;
  if (absVals.length > 1) {
    var mx = Math.max.apply(null, absVals.filter(function(v){ return v > 0; }));
    var mn = Math.min.apply(null, absVals.filter(function(v){ return v > 0; }));
    if (mx / mn > 1000) useLog = true;
  }

  chartInstance = new Chart(canvas, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [{
        label: pd.title.replace(/_/g,' '),
        data: absVals, backgroundColor: colors,
        borderColor: colors.map(function(c){ return c.replace('0.8','1'); }),
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: false },
        title: { display: true, text: pd.title.replace(/_/g,' ') + (useLog ? '  (log scale, |values|)' : '  (|values|)'), color: '#f4f4f5', font: { family: 'Inter', size: 14, weight: 500 } },
        tooltip: { callbacks: { label: function(ctx) { var i = ctx.dataIndex; return pd.values[i].toExponential(4) + ' ' + (pd.units[i] || ''); } } }
      },
      scales: {
        y: {
          type: useLog ? 'logarithmic' : 'linear',
          ticks: { color: '#a1a1aa', font: { family: 'JetBrains Mono', size: 11 } },
          grid:  { color: 'rgba(63, 63, 70, 0.5)' }
        },
        x: {
          ticks: { color: '#a1a1aa', font: { family: 'Inter', size: 11 }, maxRotation: 45 },
          grid: { color: 'rgba(63, 63, 70, 0.5)' }
        }
      }
    }
  });
}

// ── Keyboard shortcuts ──
document.getElementById('cmd').addEventListener('keydown', function(e) {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    solve();
  }
});

// Init
loadSolvers();
</script>
</body>
</html>
"""



# ── HTTP handlers ────────────────────────────────────────────────

function handle_index(req::HTTP.Request)
    HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], HTML_PAGE)
end

function handle_solvers(req::HTTP.Request)
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  to_json(build_solver_metadata()))
end

function handle_solve(req::HTTP.Request)
    try
        req_data = parse_request(String(req.body))
        mode     = get(req_data, "mode", "command")

        local res::SolverResult
        if mode == "structured"
            solver_name = get(req_data, "solver", "")
            raw_params  = get(req_data, "params", Dict{Symbol,Any}())
            params      = Dict{Symbol,Any}(Symbol(k) => v for (k,v) in raw_params)
            isempty(solver_name) && error("No solver specified in structured request.")
            # Bypass tokenizer — go straight to dispatcher with a PhysicalQuery
            query = PhysicalQuery(Symbol(solver_name), params, "structured-api")
            res   = dispatch(query)
            _state.query_count += 1
            _state.last_command = Symbol(solver_name)
        else
            query_str = get(req_data, "query", "")
            isempty(strip(query_str)) && error("Empty query string.")
            res = process(query_str, _state)
        end

        d           = result_to_dict(res)
        d["plot_data"] = extract_plot_data(res)

        HTTP.Response(200, ["Content-Type" => "application/json"], to_json(d))
    catch e
        err_dict = Dict(
            "success"  => false, "command" => "unknown",
            "solver"   => "server",
            "message"  => sprint(showerror, e),
            "rows"     => Dict[],
            "plot_data"=> Dict("available"=>false,"labels"=>[],"values"=>[],"units"=>[],"title"=>"")
        )
        HTTP.Response(500, ["Content-Type" => "application/json"], to_json(err_dict))
    end
end

function handle_404(req::HTTP.Request)
    HTTP.Response(404, "Not found: " * req.target)
end

# ── Router ───────────────────────────────────────────────────────
const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET",  "/",        handle_index)
HTTP.register!(ROUTER, "GET",  "/solvers", handle_solvers)
HTTP.register!(ROUTER, "POST", "/solve",   handle_solve)
HTTP.register!(ROUTER, "GET",  "/**",      handle_404)

# ── Start ────────────────────────────────────────────────────────
const PORT = 8050

println("\n" * "=" ^ 56)
println("  B-SPEC  Web GUI  v2.0")
println("  Solvers : " * join(string.(_state.solvers_loaded), " | "))
println("  Commands: " * string(length(SOLVER_REGISTRY)))
println("=" ^ 56)
println()
println("  Open -> http://localhost:" * string(PORT))
println()
println("  API endpoints:")
println("    GET  /solvers  -> solver registry + param types")
println("    POST /solve    -> {mode, solver?, params?, query?}")
println()
println("  Revise active. Edit any solver and save —")
println("  changes are live on next SOLVE.")
println()
println("  Ctrl+C to stop.")
println()

server = HTTP.serve!(ROUTER, "0.0.0.0", PORT)
try
    wait(server)
catch e
    e isa InterruptException || rethrow(e)
    close(server)
    println("\n  Server stopped.")
end