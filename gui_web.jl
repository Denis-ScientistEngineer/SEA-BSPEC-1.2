#!/usr/bin/env julia
# ================================================================
# FILE: gui_web.jl   鈥�   B-SPEC Physical Engine  Web GUI
#
# Stack : HTTP.jl (web server) + JSON3.jl (data exchange)
#         Revise.jl (live-reload during development)
#
# Why NOT Bonito widgets:
#   Bonito's Button/TextField API changes between minor versions.
#   Using HTTP.jl + vanilla JS means zero widget-API dependency 鈥�
#   it works on every Julia version that has HTTP.jl.
#
# How it works:
#   GET  /          鈫� serves the full HTML page (below)
#   POST /solve     鈫� runs engine.process(), returns JSON result
#   GET  /registry  鈫� returns solver list as JSON
#
#   The browser page calls fetch('/solve', ...) on button click
#   or Enter key. Julia processes it through the normal engine
#   pipeline and returns a JSON SolverResult.
#
# Run  : julia gui_web.jl
# Open : http://localhost:8050
# ================================================================

# 鈹€鈹€ 0. Revise 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
using Revise

# 鈹€鈹€ 1. Engine 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
includet("core/types.jl")
includet("core/tokenizer.jl")
includet("core/dispatcher.jl")
includet("core/engine.jl")
includet("solvers/electromagnetics.jl")
includet("solvers/classical_mechanics.jl")

# 鈹€鈹€ 2. Packages 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# Only HTTP.jl 鈥� no JSON3, no Bonito, no external JSON library.
# Our payloads are small and fixed-shape so we handle JSON ourselves.
using HTTP
using Printf

# 鈹€鈹€ 2b. Minimal JSON helpers (no external dependency) 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

"""Escape a string for safe embedding inside a JSON string value."""
function _json_esc(s::AbstractString)::String
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

"""Serialise a result-row Dict to a JSON object string."""
function _row_to_json(row::Dict)::String
    k = _json_esc(row["key"])
    v = _json_esc(row["value"])
    u = _json_esc(row["unit"])
    """{"key":"$k","value":"$v","unit":"$u"}"""
end

"""Serialise the full solver result to a JSON string."""
function result_to_json(d::Dict)::String
    success = d["success"] ? "true" : "false"
    command = _json_esc(d["command"])
    solver  = _json_esc(d["solver"])
    message = _json_esc(d["message"])
    rows    = join([_row_to_json(r) for r in d["rows"]], ",")
    """{"success":$success,"command":"$command","solver":"$solver","message":"$message","rows":[$rows]}"""
end

"""Parse the query string out of a JSON body like {"query":"..."}."""
function _parse_query(body::String)::String
    # Simple extraction 鈥� find "query":"..." pattern
    m = match(r"\"query\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", body)
    isnothing(m) && return ""
    # Unescape basic JSON escapes
    s = m.captures[1]
    s = replace(s, "\\n"  => "\n")
    s = replace(s, "\\t"  => "\t")
    s = replace(s, "\\\"" => "\"")
    s = replace(s, "\\\\" => "\\")
    return s
end

"""Build a JSON registry response: {"domain":["cmd1","cmd2"],...}"""
function registry_to_json()::String
    domains = Dict{String, Vector{String}}()
    for (cmd, entry) in SOLVER_REGISTRY
        d = string(entry.domain)
        push!(get!(domains, d, String[]), string(cmd))
    end
    for v in values(domains)
        sort!(v)
    end
    pairs = String[]
    for (dom, cmds) in sort(collect(domains), by = x -> x[1])
        cmd_list = join(["\"$(c)\"" for c in cmds], ",")
        push!(pairs, "\"$(dom)\":[$cmd_list]")
    end
    "{" * join(pairs, ",") * "}"
end

# 鈹€鈹€ 3. Engine init 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]

# 鈹€鈹€ 4. Result serialiser 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

function _fmtv(v)::String
    v isa Vector        && return "[" * join([@sprintf("%.5g", x) for x in v], ", ") * "]"
    v isa AbstractFloat && return @sprintf("%.6g", v)
    v isa Bool          && return string(v)
    return string(v)
end

"""Convert SolverResult 鈫� plain Dict ready for result_to_json()."""
function result_to_dict(r::SolverResult)::Dict
    rows = Dict[]
    for (k, v) in sort(collect(r.outputs), by = x -> string(x[1]))
        push!(rows, Dict(
            "key"   => string(k),
            "value" => _fmtv(v),
            "unit"  => get(r.units, k, "?")
        ))
    end
    Dict(
        "success" => r.success,
        "command" => string(r.command),
        "solver"  => string(r.solver_id),
        "message" => r.message,
        "rows"    => rows
    )
end

# 鈹€鈹€ 5. HTML page (sent once; JS handles all updates) 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>B-SPEC Physical Engine</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: #0C1016; color: #E1E8F1;
    font-family: 'Courier New', Courier, monospace;
    font-size: 14px; height: 100dvh;
    display: flex; flex-direction: column; overflow: hidden;
  }

  /* 鈹€鈹€ Header 鈹€鈹€ */
  .topbar {
    background: #151A21; border-bottom: 1px solid #2A3240;
    padding: 10px 18px; display: flex;
    align-items: center; justify-content: space-between; flex-shrink: 0;
  }
  .topbar-title { color: #53A2FF; font-size: 15px; letter-spacing: 2px; font-weight: bold; }
  .topbar-sub   { color: #606870; font-size: 11px; }
  .pill {
    background: #1B2129; border: 1px solid #2A3240;
    color: #53A2FF; font-size: 10px; padding: 2px 8px;
    border-radius: 12px; letter-spacing: 1px;
  }

  /* 鈹€鈹€ Two-column layout 鈹€鈹€ */
  .main { display: flex; flex: 1; overflow: hidden; }

  .left-panel {
    width: 320px; min-width: 320px;
    background: #151A21; border-right: 1px solid #2A3240;
    display: flex; flex-direction: column;
    overflow-y: auto; padding-bottom: 12px;
  }

  .right-panel {
    flex: 1; display: flex; flex-direction: column; overflow: hidden;
    background: #0F1419;
  }

  /* 鈹€鈹€ Section labels 鈹€鈹€ */
  .sec-label {
    color: #53A2FF; font-size: 10px; letter-spacing: 2px;
    padding: 12px 14px 6px; text-transform: uppercase;
  }

  /* 鈹€鈹€ Input 鈹€鈹€ */
  .input-wrap { padding: 0 12px 8px; }
  textarea#cmd {
    width: 100%; background: #1B2129; border: 1px solid #2A3240;
    border-radius: 4px; color: #E1E8F1;
    font-family: 'Courier New', monospace; font-size: 13px;
    padding: 10px 12px; outline: none; resize: vertical;
    min-height: 80px;
  }
  textarea#cmd:focus { border-color: #53A2FF; }
  textarea#cmd::placeholder { color: #404850; }

  /* 鈹€鈹€ Buttons 鈹€鈹€ */
  .btn-row { display: flex; gap: 8px; padding: 0 12px 10px; }
  button {
    padding: 9px 16px; border-radius: 4px;
    font-family: 'Courier New', monospace; font-size: 13px;
    cursor: pointer; border: none; transition: background 0.15s;
  }
  #solve-btn {
    background: #2465A8; color: #E1E8F1;
    flex: 1; letter-spacing: 1px;
  }
  #solve-btn:hover  { background: #3381D1; }
  #solve-btn:active { background: #1A4A80; }
  #clear-btn {
    background: #1B2129; color: #818B98;
    border: 1px solid #2A3240;
  }
  #clear-btn:hover { background: #252D38; color: #E1E8F1; }

  /* 鈹€鈹€ Spinner 鈹€鈹€ */
  #spinner {
    display: none; color: #53A2FF;
    padding: 0 12px 6px; font-size: 11px; letter-spacing: 1px;
  }
  #spinner.active { display: block; }

  hr.divider { border: none; border-top: 1px solid #2A3240; margin: 6px 12px; }

  /* 鈹€鈹€ Registry 鈹€鈹€ */
  #registry {
    padding: 4px 14px; font-size: 11.5px;
    color: #606870; line-height: 1.9;
    white-space: pre; overflow-x: hidden;
  }
  .reg-domain { color: #53A2FF; }

  /* 鈹€鈹€ Guide 鈹€鈹€ */
  .guide {
    padding: 8px 14px 4px; font-size: 11px;
    color: #505860; line-height: 1.8;
    border-top: 1px solid #2A3240;
    white-space: pre;
  }
  .guide b { color: #818B98; }

  /* 鈹€鈹€ Result area 鈹€鈹€ */
  .result-wrap {
    flex: 1; overflow-y: auto; padding: 14px 16px;
  }
  #result-box {
    white-space: pre; font-size: 13px; line-height: 1.8;
    font-family: 'Courier New', monospace;
    color: #506070;
  }
  #result-box.success { color: #3CBD52; }
  #result-box.error   { color: #F44D45; }

  /* 鈹€鈹€ Result table 鈹€鈹€ */
  .result-table {
    width: 100%; border-collapse: collapse;
    font-size: 13px; font-family: 'Courier New', monospace;
    margin-top: 8px;
  }
  .result-table th {
    color: #818B98; text-align: left;
    padding: 2px 12px 6px 0; border-bottom: 1px solid #2A3240;
    font-weight: normal; font-size: 11px; letter-spacing: 1px;
  }
  .result-table td {
    padding: 3px 12px 3px 0; vertical-align: top;
  }
  .td-key  { color: #76BFFF; }
  .td-val  { color: #E1E8F1; }
  .td-unit { color: #99C794; }

  /* 鈹€鈹€ History 鈹€鈹€ */
  .history-wrap {
    background: #151A21; border-top: 1px solid #2A3240;
    padding: 6px 14px 8px; max-height: 150px;
    overflow-y: auto; flex-shrink: 0;
  }
  .history-label {
    color: #53A2FF; font-size: 10px;
    letter-spacing: 2px; padding-bottom: 4px;
  }
  #history-list { font-size: 11.5px; color: #606870; line-height: 1.75; }
  .h-ok  { color: #3CBD52; }
  .h-err { color: #F44D45; }

  /* 鈹€鈹€ Status bar 鈹€鈹€ */
  .statusbar {
    background: #151A21; border-top: 1px solid #2A3240;
    padding: 5px 14px; font-size: 11px; color: #606870;
    flex-shrink: 0; white-space: nowrap; overflow-x: auto;
  }
  #status-dot { color: #3CBD52; }

  /* 鈹€鈹€ Phone: stack columns 鈹€鈹€ */
  @media (max-width: 680px) {
    .main        { flex-direction: column; }
    .left-panel  { width: 100%; min-width: unset; border-right: none;
                   border-bottom: 1px solid #2A3240; max-height: 50vh; }
    .right-panel { flex: 1; min-height: 0; }
    .topbar-sub  { display: none; }
    textarea#cmd { min-height: 60px; font-size: 14px; }
    button       { font-size: 14px; padding: 10px 14px; }
  }
</style>
</head>
<body>

<!-- Header -->
<div class="topbar">
  <div class="topbar-title">猬�&nbsp;&nbsp;B-SPEC&nbsp;&nbsp;PHYSICAL&nbsp;&nbsp;ENGINE</div>
  <div class="topbar-sub">Scientific Computing Solver Interface</div>
  <span class="pill">v0.1</span>
</div>

<!-- Main -->
<div class="main">

  <!-- Left panel -->
  <div class="left-panel">
    <div class="sec-label">Command Input</div>
    <div class="input-wrap">
      <textarea id="cmd"
        placeholder="get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]"
        spellcheck="false" autocorrect="off" autocomplete="off"
      ></textarea>
    </div>
    <div class="btn-row">
      <button id="solve-btn">&#9654;&nbsp; SOLVE</button>
      <button id="clear-btn">CLEAR</button>
    </div>
    <div id="spinner">  鈼� computing...</div>

    <hr class="divider">
    <div class="sec-label">Solver Registry</div>
    <div id="registry">  loading...</div>

    <div class="guide"><b>FORMAT</b>   [verb] command key=value key=[x,y,z]
<b>VECTORS</b>  source=[0.0, 0.0, 0.0]
<b>VERBS</b>    get | find | compute | solve
<b>ENTER</b>    Ctrl+Enter = SOLVE</div>
  </div>

  <!-- Right panel -->
  <div class="right-panel">
    <div class="result-wrap">
      <div id="result-header" style="color:#53A2FF;font-size:10px;letter-spacing:2px;padding-bottom:8px;">RESULT</div>
      <div id="result-box">
  猬�  B-SPEC Physical Engine  v0.1
  鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  Type a command and press SOLVE.

  EXAMPLES:
  get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]
  get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]
  get projectile_motion initial_velocity=50 angle_deg=45 initial_height=0
  get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8
  get gravitational_force m1=5.972e24 m2=7.342e22 distance=3.844e8
  get elastic_collision m1=2.0 v1=3.0 m2=1.0 v2=0.0
      </div>
    </div>

    <div class="history-wrap">
      <div class="history-label">QUERY HISTORY</div>
      <div id="history-list">  No queries yet.</div>
    </div>
  </div>
</div>

<!-- Status bar -->
<div class="statusbar">
  <span id="status-dot">鈼�</span>
  <span id="status-text">Ready  鈹�  loading solvers...</span>
</div>

<script>
// 鈹€鈹€ State 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
let history = [];
let queryCount = 0;
let errorCount = 0;
let lastCmd = '鈥�';
const MAX_HISTORY = 16;

// 鈹€鈹€ DOM refs 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const cmdInput   = document.getElementById('cmd');
const solveBtn   = document.getElementById('solve-btn');
const clearBtn   = document.getElementById('clear-btn');
const resultBox  = document.getElementById('result-box');
const histList   = document.getElementById('history-list');
const statusText = document.getElementById('status-text');
const statusDot  = document.getElementById('status-dot');
const spinner    = document.getElementById('spinner');
const registry   = document.getElementById('registry');

// 鈹€鈹€ Load registry on page load 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
async function loadRegistry() {
  try {
    const r = await fetch('/registry');
    const data = await r.json();
    let html = '';
    for (const [domain, cmds] of Object.entries(data)) {
      html += `<span class="reg-domain">  鈻� :${domain}</span>\\n`;
      for (const cmd of cmds) {
        html += `      :${cmd}\\n`;
      }
      html += '\\n';
    }
    registry.innerHTML = html;
    updateStatus();
  } catch(e) {
    registry.textContent = '  (registry unavailable)';
  }
}

// 鈹€鈹€ Solve 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
async function solve() {
  const text = cmdInput.value.trim();
  if (!text) return;

  spinner.classList.add('active');
  solveBtn.disabled = true;
  statusDot.style.color = '#E4B02D';

  try {
    const resp = await fetch('/solve', {
      method : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body   : JSON.stringify({ query: text })
    });
    const data = await resp.json();

    queryCount++;
    lastCmd = data.command;
    if (!data.success) errorCount++;

    renderResult(data);
    addHistory(text, data.success);
    updateStatus();

  } catch(e) {
    renderError('Network error: ' + e.message);
    errorCount++;
    updateStatus();
  } finally {
    spinner.classList.remove('active');
    solveBtn.disabled = false;
    statusDot.style.color = '#3CBD52';
  }
}

// 鈹€鈹€ Render result 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
function renderResult(data) {
  if (data.success) {
    resultBox.className = 'success';
    // Header text
    let html = `<span style="color:#3CBD52">鉁�  :${data.command}</span>\\n`;
    html += `<span style="color:#818B98">     solver  :  :${data.solver}</span>\\n`;
    html += `<span style="color:#2A3240">${'鈹€'.repeat(62)}</span>\\n\\n`;

    // Table of results
    if (data.rows.length > 0) {
      html += `<table class="result-table">`;
      html += `<tr><th>Quantity</th><th>Value</th><th>Unit</th></tr>`;
      for (const row of data.rows) {
        html += `<tr>`;
        html += `<td class="td-key">${row.key}</td>`;
        html += `<td class="td-val">${row.value}</td>`;
        html += `<td class="td-unit">${row.unit}</td>`;
        html += `</tr>`;
      }
      html += `</table>\\n`;
    }

    html += `\\n<span style="color:#2A3240">${'鈹€'.repeat(62)}</span>\\n`;
    html += `<span style="color:#53A2FF">鉁�  ${data.message}</span>`;

    resultBox.innerHTML = html;
  } else {
    renderError(`:${data.command}\\n\\n${data.message}`);
  }
}

function renderError(msg) {
  resultBox.className = 'error';
  resultBox.textContent = '\\n  鉁�  ' + msg;
}

// 鈹€鈹€ History 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
function addHistory(text, ok) {
  history.unshift({ text, ok });
  if (history.length > MAX_HISTORY) history.pop();

  let html = '';
  history.forEach((entry, i) => {
    const n    = history.length - i;
    const icon = entry.ok
      ? '<span class="h-ok">鉁�</span>'
      : '<span class="h-err">鉁�</span>';
    const trim = entry.text.length > 70
      ? entry.text.slice(0, 67) + '...'
      : entry.text;
    html += `  ${String(n).padStart(2)}.  ${icon}  ${trim}\\n`;
  });
  histList.innerHTML = html;
}

// 鈹€鈹€ Status bar 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
function updateStatus() {
  const solverCount = (registry.textContent.match(/鈻�/g) || []).length;
  statusText.textContent =
    `Ready  鈹�  Queries: ${queryCount}  鈹�  Errors: ${errorCount}  鈹�  Last: ${lastCmd}`;
}

// 鈹€鈹€ Events 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
solveBtn.addEventListener('click', solve);

clearBtn.addEventListener('click', () => {
  resultBox.className = '';
  resultBox.textContent = '\\n  Cleared. Ready for next command.';
});

cmdInput.addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    solve();
  }
});

// 鈹€鈹€ Init 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
loadRegistry();
</script>
</body>
</html>
"""

# 鈹€鈹€ 6. HTTP request handlers 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

"""Serve the HTML page."""
function handle_index(req::HTTP.Request)
    HTTP.Response(200,
        ["Content-Type" => "text/html; charset=utf-8"],
        HTML_PAGE
    )
end

"""Run a query through the engine, return JSON."""
function handle_solve(req::HTTP.Request)
    try
        query = _parse_query(String(req.body))

        if isempty(strip(query))
            return HTTP.Response(400,
                ["Content-Type" => "application/json"],
                result_to_json(Dict("success" => false,
                                    "command" => "unknown",
                                    "solver"  => "server",
                                    "message" => "Empty query.",
                                    "rows"    => Dict[]))
            )
        end

        res  = process(query, _state)
        data = result_to_dict(res)

        HTTP.Response(200,
            ["Content-Type" => "application/json"],
            result_to_json(data)
        )
    catch e
        HTTP.Response(500,
            ["Content-Type" => "application/json"],
            result_to_json(Dict("success" => false,
                                "command" => "unknown",
                                "solver"  => "server",
                                "message" => sprint(showerror, e),
                                "rows"    => Dict[]))
        )
    end
end

"""Return the solver registry as JSON for the browser to render."""
function handle_registry(req::HTTP.Request)
    HTTP.Response(200,
        ["Content-Type" => "application/json"],
        registry_to_json()
    )
end

"""Simple 404."""
function handle_404(req::HTTP.Request)
    HTTP.Response(404, "Not found: $(req.target)")
end

# 鈹€鈹€ 7. Router 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET",  "/",         handle_index)
HTTP.register!(ROUTER, "POST", "/solve",    handle_solve)
HTTP.register!(ROUTER, "GET",  "/registry", handle_registry)
HTTP.register!(ROUTER, "GET",  "/**",       handle_404)

# 鈹€鈹€ 8. Start server 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
const PORT = 8050

println("\n" * "鈻�"^58)
println("  B-SPEC  Web GUI  v0.1")
println("  Solvers : $(join(_state.solvers_loaded, "  |  "))")
println("  Commands: $(length(SOLVER_REGISTRY))")
println("鈻�"^58)
println()
println("  Local  鈫�  http://localhost:$PORT")
println()
println("  Revise active 鈥� edit any solver and save;")
println("  changes are live on next SOLVE click.")
println()
println("  Press Ctrl+C to stop.")
println()

server = HTTP.serve!(ROUTER, "0.0.0.0", PORT)

try
    wait(server)
catch e
    e isa InterruptException || rethrow(e)
    close(server)
    println("\n  Server stopped.")
end
