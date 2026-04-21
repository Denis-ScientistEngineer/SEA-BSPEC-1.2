#!/usr/bin/env julia
# ================================================================
# FILE: gui_web.jl   —   B-SPEC Physical Engine  Web UI  v2.1
#
# What's new in v2.1:
#   - /chain endpoint: multi-step solver pipelines where the output
#     of one solver feeds directly into the next
#   - Plot type system: solvers declare bar/line/vector plot hints
#   - Fixed _parse_params: handles nested arrays [[x,y,z],[x,y,z]]
#   - Rich history: stores full result rows, click to replay
#   - Unit hints on every param field label
#   - "Use as input" button on result rows for chain building
#   - Pipeline UI: visual step builder (3rd mode tab)
#
# API:
#   GET  /         → single-page application
#   GET  /solvers  → solver registry + param metadata + unit hints
#   POST /solve    → {mode, solver?, params?, query?}
#   POST /chain    → {steps:[{id,solver,params},...]}   NEW
#
# Run : julia gui_web.jl   (from any directory — uses @__DIR__)
# Open: http://localhost:8050
# ================================================================

using Revise

const _D = @__DIR__
includet(joinpath(_D, "core", "types.jl"))
includet(joinpath(_D, "core", "tokenizer.jl"))
includet(joinpath(_D, "core", "nlp_parser.jl"))
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

# ── Param metadata: type + SI unit hint ─────────────────────────
const PARAM_META = Dict{Symbol, Tuple{String,String}}(
    :source           => ("vector3","m"),
    :field_point      => ("vector3","m"),
    :r1               => ("vector3","m"),
    :r2               => ("vector3","m"),
    :normal           => ("vector3","dimensionless"),
    :E_field          => ("vector3","N/C"),
    :charge           => ("scalar","C"),
    :q1                => ("scalar","C"),
    :q2                => ("scalar","C"),
    :area              => ("scalar","m²"),
    :capacitance       => ("scalar","F"),
    :voltage           => ("scalar","V"),
    :V_in              => ("scalar","V"),
    :initial_velocity  => ("scalar","m/s"),
    :angle_deg         => ("scalar","°"),
    :initial_height    => ("scalar","m"),
    :g                 => ("scalar","m/s²"),
    :m1                => ("scalar","kg"),
    :m2                => ("scalar","kg"),
    :distance          => ("scalar","m"),
    :mass              => ("scalar","kg"),
    :velocity          => ("scalar","m/s"),
    :force             => ("scalar","N"),
    :displacement      => ("scalar","m"),
    :spring_constant   => ("scalar","N/m"),
    :damping           => ("scalar","N·s/m"),
    :amplitude         => ("scalar","m"),
    :initial_position  => ("scalar","m"),
    :radius            => ("scalar","m"),
    :speed             => ("scalar","m/s"),
    :v1                => ("scalar","m/s"),
    :v2                => ("scalar","m/s"),
    :acceleration      => ("scalar","m/s²"),
    :charges           => ("array","C"),
    :sources           => ("array","m"),
    # ── Computed quantities that can also be provided as inputs ──
    :E_magnitude       => ("scalar","N/C"),
    :r_magnitude       => ("scalar","m"),
    :F_magnitude       => ("scalar","N"),
    :test_force        => ("scalar","N"),
    :test_charge       => ("scalar","C"),
    :V                 => ("scalar","V"),
    :KE                => ("scalar","J"),
    :work              => ("scalar","J"),
    :energy            => ("scalar","J"),
    :momentum          => ("scalar","kg·m/s"),
    :flux              => ("scalar","N·m²/C"),
    :centripetal_force => ("scalar","N"),
    :angular_frequency => ("scalar","rad/s"),
    :frequency_hz      => ("scalar","Hz"),
    :period            => ("scalar","s"),
    :range             => ("scalar","m"),
)
param_type(p::Symbol) = get(PARAM_META, p, ("scalar",""))[1]
param_unit(p::Symbol) = get(PARAM_META, p, ("scalar",""))[2]

# ── Plot type hints per solver ───────────────────────────────────
const PLOT_HINTS = Dict{Symbol, Dict{String,Any}}(
    :projectile_motion   => Dict("type"=>"bar","note"=>"Kinematics summary"),
    :harmonic_oscillator => Dict("type"=>"bar","note"=>"Oscillator parameters"),
    :elastic_collision   => Dict("type"=>"bar","note"=>"Before/after comparison"),
    :electric_field      => Dict("type"=>"bar","note"=>"Field components"),
    :coulomb_force       => Dict("type"=>"bar","note"=>"Force components"),
    :circular_motion     => Dict("type"=>"bar","note"=>"Circular motion parameters"),
)
plot_hint(cmd::Symbol) = get(PLOT_HINTS, cmd, Dict("type"=>"bar","note"=>""))

# ── JSON serialiser ──────────────────────────────────────────────
function _jesc(s::AbstractString)::String
    s = replace(s, "\\" => "\\\\", "\"" => "\\\"",
                    "\n" => "\\n",  "\r" => "\\r", "\t" => "\\t")
    return s
end

function to_json(x)::String
    x isa Bool           && return x ? "true" : "false"
    x isa AbstractFloat  && return isfinite(x) ? @sprintf("%.10g", x) : "null"
    x isa Integer        && return string(x)
    x isa AbstractString && return "\"" * _jesc(x) * "\""
    x isa AbstractVector && return "[" * join(to_json.(x), ",") * "]"
    x isa Dict           && return "{" * join(
        [to_json(string(k)) * ":" * to_json(v) for (k,v) in x], ",") * "}"
    x isa Nothing        && return "null"
    return "\"" * _jesc(string(x)) * "\""
end

# ── JSON request parser ──────────────────────────────────────────

"""Parse a JSON array string like [1,2,3] or [[0,0,0],[1,0,0]]."""
function _parse_json_array(s::AbstractString)
    s = strip(s)
    if startswith(s, "[[")
        inner = s[2:end-1]
        parts = String[]
        depth = 0; start_i = 1
        for (i,c) in enumerate(inner)
            if c == '['; depth += 1
            elseif c == ']'; depth -= 1
                if depth == 0
                    push!(parts, strip(inner[start_i:i]))
                    start_i = i + 2
                end
            end
        end
        return [_parse_json_array(p) for p in parts]
    end
    inner = s[2:end-1]
    return [parse(Float64, strip(x)) for x in split(inner, ",") if !isempty(strip(x))]
end

"""Parse a JSON params object into Dict{Symbol,Any} robustly."""
function _parse_params_obj(s::AbstractString)::Dict{Symbol,Any}
    params = Dict{Symbol,Any}()
    i = 1
    n = length(s)
    while i <= n
        km = match(r"\"(\w+)\"\s*:", s[i:end])
        isnothing(km) && break
        key_pos   = i + km.offset - 1
        key       = km.captures[1]
        val_start = key_pos + length(km.match)
        rest      = lstrip(s[val_start:end])
        offset    = length(s[val_start:end]) - length(rest)

        if startswith(rest, "[[")
            depth = 0; j = 1
            for (ji,c) in enumerate(rest)
                if c == '['; depth += 1
                elseif c == ']'; depth -= 1
                    if depth == 0; j = ji; break; end
                end
            end
            params[Symbol(key)] = _parse_json_array(rest[1:j])
            i = val_start + offset + j
        elseif startswith(rest, "[")
            j = findfirst(']', rest)
            isnothing(j) && break
            params[Symbol(key)] = _parse_json_array(rest[1:j])
            i = val_start + offset + j
        elseif startswith(rest, "{")
            depth = 0; j = 1
            for (ji, c) in enumerate(rest)
                if c == '{'; depth += 1
                elseif c == '}'; depth -= 1
                    if depth == 0; j = ji; break; end
                end
            end
            obj = rest[1:j]
            fs_m = match(r"\"from_step\"\s*:\s*\"([^\"]+)\"", obj)
            fk_m = match(r"\"key\"\s*:\s*\"([^\"]+)\"", obj)
            if !isnothing(fs_m) && !isnothing(fk_m)
                params[Symbol(key)] = Dict("from_step"=>fs_m.captures[1],
                                           "key"=>fk_m.captures[1])
            end
            i = val_start + offset + j
        else
            nm = match(r"^-?(?:[0-9]+\.?[0-9]*|[0-9]*\.[0-9]+)(?:[eE][-+]?[0-9]+)?", rest)
            isnothing(nm) && (i = val_start + 1; continue)
            params[Symbol(key)] = parse(Float64, nm.match)
            i = val_start + offset + length(nm.match)
        end
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
        s = replace(m.captures[1], "\\n"=>" ","\\t"=>" ","\\\\"=>"\\","\\\"" =>"\"")
        r["query"] = s
    end
    m = match(r"\"params\"\s*:\s*(\{)", body)
    if !isnothing(m)
        start = m.offset + length(m.match) - 1
        depth = 0; close = start
        for (i,c) in enumerate(body[start:end])
            if c == '{'; depth += 1
            elseif c == '}'; depth -= 1
                if depth == 0; close = start + i - 1; break; end
            end
        end
        r["params"] = _parse_params_obj(body[start:close])
    end
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
        is_scalar = (v isa AbstractFloat && isfinite(v) && !(v isa Bool)) || v isa Integer
        is_vector = v isa AbstractVector
        push!(rows, Dict(
            "key"       => string(k),
            "value"     => _fmtv(v),
            "unit"      => get(r.units, k, "?"),
            "chainable" => is_scalar || is_vector,
            "raw_type"  => is_vector ? "vector3" : (is_scalar ? "scalar" : "text")
        ))
    end
    Dict("success"=>r.success, "command"=>string(r.command),
         "solver"=>string(r.solver_id), "message"=>r.message, "rows"=>rows)
end

function extract_plot_data(r::SolverResult)::Dict
    labels = String[]; values = Float64[]; units = String[]
    for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
        if v isa AbstractFloat && isfinite(v) && !(v isa Bool)
            push!(labels, string(k)); push!(values, v)
            push!(units, get(r.units, k, ""))
        elseif v isa Integer
            push!(labels, string(k)); push!(values, Float64(v))
            push!(units, get(r.units, k, ""))
        end
    end
    hint = plot_hint(r.command)
    Dict("available"=>!isempty(values), "type"=>hint["type"], "note"=>hint["note"],
         "title"=>string(r.command), "labels"=>labels, "values"=>values, "units"=>units)
end

# ── Solver metadata ──────────────────────────────────────────────
function build_solver_metadata()::Dict
    domains = Dict{String,Vector{Dict}}()
    for (cmd, e) in SOLVER_REGISTRY
        d     = string(e.domain)
        types = Dict{String,String}()
        uhint = Dict{String,String}()
        for p in e.all_vars
            types[string(p)] = param_type(p)
            uhint[string(p)] = param_unit(p)
        end
        # Expose each variant so the frontend can do real-time variant preview
        variants_info = map(e.variants) do v
            Dict("given"       => string.(v.given),
                 "solves"      => string(v.solves),
                 "description" => v.description)
        end
        info = Dict(
            "command"     => string(cmd),
            "description" => e.description,
            "equation"    => e.equation,
            "all_vars"    => string.(e.all_vars),
            "param_types" => types,
            "param_units" => uhint,
            "variants"    => variants_info
        )
        push!(get!(domains, d, Dict[]), info)
    end
    for v in values(domains); sort!(v, by=x->x["command"]); end
    return domains
end

# ── Chain execution ──────────────────────────────────────────────
function execute_chain(steps::Vector)::Vector{Dict}
    results = Dict[]
    outputs = Dict{String,Any}()

    for step in steps
        step_id     = get(step, "id",     "step$(length(results)+1)")
        solver_name = get(step, "solver", "")
        raw_params  = get(step, "params", Dict())

        resolved = Dict{Symbol,Any}()
        for (k, v) in raw_params
            if v isa Dict && haskey(v, "from_step")
                ref = v["from_step"] * "." * get(v, "key", "")
                if haskey(outputs, ref)
                    resolved[Symbol(k)] = outputs[ref]
                else
                    push!(results, Dict("step_id"=>step_id,"success"=>false,
                        "command"=>solver_name,"solver"=>"chain",
                        "message"=>"Reference '$(ref)' not found.",
                        "rows"=>Dict[],"plot_data"=>Dict("available"=>false,"labels"=>[],
                        "values"=>[],"units"=>[],"title"=>"","type"=>"bar","note"=>"")))
                    return results
                end
            elseif v isa Vector
                resolved[Symbol(k)] = Float64.(v)
            elseif v isa Dict
                resolved[Symbol(k)] = v   # nested dict, pass through
            else
                resolved[Symbol(k)] = Float64(v)
            end
        end

        local res::SolverResult
        try
            query = PhysicalQuery(Symbol(solver_name), resolved, "chain-$(step_id)")
            res   = dispatch(query)
            _state.query_count += 1
            _state.last_command = Symbol(solver_name)
        catch e
            push!(results, Dict("step_id"=>step_id,"success"=>false,
                "command"=>solver_name,"solver"=>"chain",
                "message"=>sprint(showerror, e), "rows"=>Dict[],
                "plot_data"=>Dict("available"=>false,"labels"=>[],"values"=>[],
                                  "units"=>[],"title"=>"","type"=>"bar","note"=>"")))
            return results
        end

        for (k,v) in res.outputs
            outputs["$(step_id).$(k)"] = v
        end

        sd             = result_to_dict(res)
        sd["step_id"]  = step_id
        sd["plot_data"] = extract_plot_data(res)
        push!(results, sd)
    end
    return results
end


# ── HTML Application (raw string literal) ────────────────────────
# raw"""...""" means Julia NEVER interpolates anything inside.
# JS ${...} expressions and backticks are completely safe here.

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
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#09090b;--panel:#18181b;--surface:#27272a;--border:#3f3f46;
  --accent:#3b82f6;--accent-hover:#2563eb;--success:#10b981;
  --error:#ef4444;--warn:#f59e0b;--text:#f4f4f5;--text-dim:#a1a1aa;
  --val:#60a5fa;--unit:#34d399;--chain:#a78bfa;
  --font-sans:'Inter',sans-serif;--font-mono:'JetBrains Mono',monospace;
}
body{background:var(--bg);color:var(--text);font-family:var(--font-sans);
  font-size:14px;height:100dvh;display:flex;flex-direction:column;overflow:hidden}
.topbar{background:var(--panel);border-bottom:1px solid var(--border);
  padding:12px 20px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.topbar-title{color:var(--text);font-size:16px;font-weight:600;letter-spacing:1px;
  display:flex;align-items:center;gap:8px}
.topbar-title span{color:var(--accent)}
.topbar-sub{color:var(--text-dim);font-size:12px}
.pill{background:var(--surface);border:1px solid var(--border);color:var(--text-dim);
  font-size:11px;padding:3px 8px;border-radius:12px;font-family:var(--font-mono)}
.main{display:flex;flex:1;overflow:hidden}
.left-panel{width:360px;min-width:360px;background:var(--panel);
  border-right:1px solid var(--border);display:flex;flex-direction:column;overflow:hidden}
.right-panel{flex:1;display:flex;flex-direction:column;overflow:hidden;background:var(--bg)}
.sec-label{color:var(--text-dim);font-size:11px;font-weight:600;padding:14px 16px 8px;
  text-transform:uppercase;letter-spacing:.5px;flex-shrink:0}
.mode-row{display:flex;gap:6px;padding:0 16px 10px;flex-shrink:0}
.mode-btn{flex:1;padding:7px 4px;border-radius:6px;cursor:pointer;font-family:var(--font-sans);
  font-size:11px;font-weight:500;border:1px solid var(--border);background:var(--surface);
  color:var(--text-dim);transition:all .2s}
.mode-btn:hover{border-color:#52525b;color:var(--text)}
.mode-btn.active{background:var(--accent);color:#fff;border-color:var(--accent)}
.mode-btn.chain-btn.active{background:var(--chain);border-color:var(--chain)}
.form-panel{flex:1;overflow-y:auto;padding:0 16px 8px}
.cmd-panel{flex:1;display:none;flex-direction:column;padding:0 16px 8px}
.cmd-panel.active{display:flex}
select{width:100%;background:var(--surface);border:1px solid var(--border);
  border-radius:6px;color:var(--text);font-family:var(--font-sans);font-size:13px;
  padding:8px 12px;outline:none;margin-bottom:10px;cursor:pointer;appearance:none}
select:focus{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.solver-desc{font-size:12px;color:var(--text-dim);padding:0 2px 10px;line-height:1.5;
  border-bottom:1px solid var(--border);margin-bottom:10px}
.variant-preview{font-size:12px;padding:6px 4px 10px;line-height:1.5;border-bottom:1px solid var(--border);margin-bottom:8px}
.variant-preview.dim{color:var(--text-dim)}
.variant-preview.ready{color:var(--success);font-weight:500}
.field-group{margin-bottom:10px}
.field-label{display:flex;justify-content:space-between;align-items:center;
  font-size:12px;color:var(--text);margin-bottom:5px;font-weight:500}
.badge{font-size:10px;font-weight:400;padding:1px 6px;border-radius:4px;
  background:var(--surface);border:1px solid var(--border)}
.badge.req{color:var(--warn);border-color:var(--warn)}
.badge.opt{color:var(--text-dim)}
.badge.unit{color:var(--unit);border-color:rgba(52,211,153,.3)}
input[type=number],input[type=text]{background:var(--surface);border:1px solid var(--border);
  border-radius:6px;color:var(--text);font-family:var(--font-mono);font-size:13px;
  padding:8px 12px;outline:none;transition:all .2s;width:100%}
input:focus{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
input::placeholder{color:#52525b}
.vec-row{display:flex;gap:5px}
.vec-input{text-align:center}
textarea#cmd{flex:1;width:100%;min-height:150px;background:var(--surface);
  border:1px solid var(--border);border-radius:6px;color:var(--text);
  font-family:var(--font-mono);font-size:13px;padding:12px;outline:none;
  resize:none;line-height:1.5}
textarea#cmd:focus{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
textarea#cmd::placeholder{color:#52525b}
.cmd-hints{color:var(--text-dim);font-size:11px;padding:10px 2px;line-height:1.8}
.cmd-hints b{color:var(--text)}
.chain-panel{flex:1;display:none;flex-direction:column;overflow:hidden}
.chain-panel.active{display:flex}
.chain-steps{flex:1;overflow-y:auto;padding:0 16px 8px}
.chain-step{background:var(--surface);border:1px solid var(--border);
  border-radius:6px;margin-bottom:10px;overflow:hidden}
.chain-step-header{display:flex;align-items:center;justify-content:space-between;
  padding:8px 12px;background:rgba(167,139,250,.08);border-bottom:1px solid var(--border)}
.chain-step-title{font-size:12px;font-weight:600;color:var(--chain)}
.chain-step-body{padding:10px 12px}
.chain-step-body select{margin-bottom:6px;font-size:12px}
.btn-add-step{margin:0 16px 8px;padding:8px;border-radius:6px;cursor:pointer;
  font-family:var(--font-sans);font-size:12px;font-weight:500;
  border:1px dashed var(--border);background:transparent;color:var(--text-dim);
  transition:all .2s;width:calc(100% - 32px)}
.btn-add-step:hover{border-color:var(--chain);color:var(--chain)}
.btn-del-step{background:none;border:none;cursor:pointer;color:var(--text-dim);
  font-size:14px;padding:2px 6px;border-radius:4px}
.btn-del-step:hover{color:var(--error);background:rgba(239,68,68,.1)}
.btn-row{display:flex;gap:10px;padding:12px 16px;flex-shrink:0;
  background:var(--panel);border-top:1px solid var(--border)}
button.solve{flex:1;padding:10px;border-radius:6px;font-family:var(--font-sans);
  font-size:13px;font-weight:600;cursor:pointer;border:none;
  background:var(--accent);color:#fff;transition:background .2s}
button.solve:hover{background:var(--accent-hover)}
button.solve:disabled{background:var(--border);color:var(--text-dim);cursor:not-allowed}
button.solve.chain-solve{background:var(--chain)}
button.solve.chain-solve:hover{background:#8b5cf6}
button.clear{padding:10px 16px;border-radius:6px;font-family:var(--font-sans);
  font-size:13px;font-weight:500;cursor:pointer;border:1px solid var(--border);
  background:transparent;color:var(--text);transition:all .2s}
button.clear:hover{background:var(--surface)}
#spinner{display:none;text-align:center;padding:8px;color:var(--accent);
  font-size:12px;font-family:var(--font-mono);flex-shrink:0}
#spinner.active{display:block}
.tab-bar{display:flex;background:var(--panel);border-bottom:1px solid var(--border);
  flex-shrink:0;padding:0 16px}
.tab-btn{padding:14px 16px;cursor:pointer;background:none;border:none;
  border-bottom:2px solid transparent;margin-bottom:-1px;font-family:var(--font-sans);
  font-size:12px;font-weight:500;color:var(--text-dim);transition:all .2s}
.tab-btn:hover{color:var(--text)}
.tab-btn.active{color:var(--accent);border-bottom-color:var(--accent)}
.tab-content{display:none;flex:1;overflow:hidden;flex-direction:column}
.tab-content.active{display:flex}
.welcome-container{flex:1;display:flex;align-items:center;justify-content:center;
  padding:40px;background-image:radial-gradient(circle,#27272a 1px,transparent 1px);
  background-size:24px 24px}
.welcome-card{background:var(--panel);border:1px solid var(--border);border-radius:8px;
  padding:32px;max-width:520px;width:100%;box-shadow:0 10px 30px rgba(0,0,0,.5)}
.welcome-card h2{font-weight:600;font-size:18px;margin-bottom:4px}
.welcome-card p{color:var(--text-dim);font-size:13px;margin-bottom:20px}
.example-box{background:var(--bg);border:1px solid var(--border);border-radius:6px;
  padding:10px 14px;font-family:var(--font-mono);font-size:12px;color:var(--val);
  margin-bottom:8px;word-break:break-all;cursor:pointer}
.example-box:hover{border-color:var(--accent)}
.result-scroll{flex:1;overflow-y:auto;padding:24px;display:none}
.result-scroll.active{display:block}
.chain-result-block{background:var(--panel);border:1px solid var(--border);
  border-left:3px solid var(--chain);border-radius:6px;margin-bottom:16px;overflow:hidden}
.chain-result-header{padding:10px 16px;background:rgba(167,139,250,.06);
  border-bottom:1px solid var(--border);font-size:12px;color:var(--chain);font-weight:600}
#result-status{display:flex;align-items:flex-start;gap:12px;margin-bottom:20px;
  padding:14px 16px;background:var(--panel);border:1px solid var(--border);border-radius:6px}
.status-icon{font-size:18px;line-height:1}
.status-cmd{color:var(--text);font-family:var(--font-mono);font-size:13px}
.status-msg{color:var(--text-dim);font-size:12px;margin-top:6px}
.result-table{width:100%;border-collapse:collapse;font-family:var(--font-mono);font-size:13px}
.result-table th{color:var(--text-dim);text-align:left;padding:6px 16px 10px 0;
  border-bottom:1px solid var(--border);font-family:var(--font-sans);
  font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.result-table td{padding:10px 16px 10px 0;border-bottom:1px solid rgba(63,63,70,.5);vertical-align:middle}
.td-key{color:var(--text-dim);width:28%;font-size:12px}
.td-val{color:var(--val);font-weight:500}
.td-unit{color:var(--unit);font-size:12px;min-width:80px}
.td-use{width:40px}
.btn-use{display:none;padding:2px 8px;border-radius:4px;cursor:pointer;font-size:10px;
  border:1px solid rgba(167,139,250,.4);background:rgba(167,139,250,.08);
  color:var(--chain);font-family:var(--font-sans);white-space:nowrap}
tr:hover .btn-use{display:inline-block}
.btn-use:hover{background:rgba(167,139,250,.2)}
.plot-scroll{flex:1;overflow-y:auto;padding:24px;display:flex;flex-direction:column;align-items:center}
#plot-canvas-wrap{width:100%;max-width:820px;background:var(--panel);
  padding:16px;border-radius:8px;border:1px solid var(--border)}
#plot-note{color:var(--text-dim);font-size:12px;text-align:center;margin-top:8px}
#plot-msg{color:var(--text-dim);font-size:13px;text-align:center;margin-top:50px}
.history-scroll{flex:1;overflow-y:auto;padding:16px 24px}
.history-item{display:flex;align-items:flex-start;gap:12px;padding:12px 0;
  border-bottom:1px solid var(--border);cursor:pointer}
.history-item:hover{opacity:.8}
.h-icon{font-size:14px;flex-shrink:0;line-height:1.2}
.h-ok{color:var(--success)}.h-err{color:var(--error)}.h-chain{color:var(--chain)}
.h-cmd{color:var(--text);font-family:var(--font-mono);font-size:12px}
.h-msg{color:var(--text-dim);font-size:12px;margin-top:4px}
.h-rows{font-size:11px;color:var(--text-dim);margin-top:4px;font-family:var(--font-mono)}
.statusbar{background:var(--panel);border-top:1px solid var(--border);padding:6px 16px;
  font-size:11px;color:var(--text-dim);font-family:var(--font-mono);
  flex-shrink:0;display:flex;white-space:nowrap;overflow-x:auto}
.status-sep{margin:0 12px;color:var(--border)}
#sdot{color:var(--success);font-size:10px;margin-right:6px}
::-webkit-scrollbar{width:6px;height:6px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#3f3f46;border-radius:4px}
::-webkit-scrollbar-thumb:hover{background:#52525b}
@media(max-width:768px){
  .main{flex-direction:column}
  .left-panel{width:100%;min-width:unset;border-right:none;
    border-bottom:1px solid var(--border);max-height:50vh}
  .right-panel{flex:1;min-height:0}
  .topbar-sub{display:none}
}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-title">&#x2B22; <span>B-SPEC</span> PHYSICAL ENGINE</div>
  <div class="topbar-sub">Scientific Computing Interface</div>
  <span class="pill">v2.1</span>
</div>

<div class="main">
  <div class="left-panel">
    <div class="sec-label">Input Mode</div>
    <div class="mode-row">
      <button class="mode-btn active"    id="mode-form-btn"  onclick="setMode('form')">Form Builder</button>
      <button class="mode-btn"           id="mode-cmd-btn"   onclick="setMode('command')">CLI Mode</button>
      <button class="mode-btn chain-btn" id="mode-chain-btn" onclick="setMode('chain')">Pipeline</button>
    </div>
    <div class="form-panel" id="form-panel">
      <div class="sec-label" style="padding:0 0 8px">Domain</div>
      <select id="domain-select" onchange="onDomainChange()"><option>loading...</option></select>
      <div class="sec-label" style="padding:4px 0 8px">Solver Engine</div>
      <select id="solver-select" onchange="onSolverChange()"><option>loading...</option></select>
      <div class="solver-desc" id="solver-desc">Select a solver above.</div>
      <div id="solver-equation" style="font-size:11px;color:var(--unit);padding:0 2px 6px;font-family:var(--font-mono);letter-spacing:.5px"></div>
      <div id="variant-preview" class="variant-preview dim">Select a solver to begin.</div>
      <div id="param-fields"></div>
    </div>
    <div class="cmd-panel" id="cmd-panel">
      <div class="sec-label" style="padding:0 0 8px">Raw Command or Problem Text</div>
      <textarea id="cmd" placeholder="Type a command OR paste a physics problem in plain English..."
        spellcheck="false" autocorrect="off" autocomplete="off"></textarea>
      <div class="cmd-hints">
        <b>COMMAND FORMAT:</b><br>
        get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]<br>
        get electric_field charge=5e-9 source=[0,0,0] field_point=[1,0,0]<br><br>
        <b>NATURAL LANGUAGE (paste textbook problems directly):</b><br>
        Point charges of 1 nC and -2 nC are at (0,0,0) and (1,1,1).<br>
        Determine the vector force acting on each charge.<br><br>
        <b>TIP:</b> Ctrl+Enter to compute
      </div>
    </div>
    <div class="chain-panel" id="chain-panel">
      <div class="sec-label" style="padding:0 16px 8px">Pipeline Steps</div>
      <div class="chain-steps" id="chain-steps"></div>
      <button class="btn-add-step" onclick="addChainStep()">+ Add Step</button>
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
          <p>Analytical &amp; simulation core ready for queries.</p>
          <div style="font-size:11px;color:var(--text-dim);margin-bottom:8px;text-transform:uppercase;letter-spacing:.5px">Example commands (click to load)</div>
          <div class="example-box" onclick="loadExample(this)">get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]</div>
          <div class="example-box" onclick="loadExample(this)">get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8</div>
          <div class="example-box" onclick="loadExample(this)">get projectile_motion initial_velocity=50 angle_deg=45 initial_height=0</div>
          <div style="font-size:11px;color:var(--text-dim);margin:12px 0 8px;text-transform:uppercase;letter-spacing:.5px">Natural language (click to load)</div>
          <div class="example-box" onclick="loadExample(this)">Point charges of 1 nC and -2 nC are located at (0, 0, 0) and (1, 1, 1), respectively, in free space. Determine the vector force acting on each charge.</div>
          <div class="example-box" onclick="loadExample(this)">Point charges of 50 nC each are located at A(1, 0, 0), B(-1, 0, 0), C(0, 1, 0), and D(0, -1, 0) in free space. Find the total force on the charge at A.</div>
        </div>
      </div>
      <div class="result-scroll" id="result-container">
        <div id="result-status"></div>
        <div id="result-body"></div>
      </div>
    </div>
    <div class="tab-content" id="tab-plot">
      <div class="plot-scroll">
        <div id="plot-canvas-wrap" style="display:none"><canvas id="plot-canvas"></canvas></div>
        <div id="plot-note"></div>
        <div id="plot-msg">Run a solver to generate visualizations.</div>
      </div>
    </div>
    <div class="tab-content" id="tab-history">
      <div class="history-scroll" id="history-list">
        <div style="color:var(--text-dim);font-size:13px;padding:16px">No queries executed yet.</div>
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
var solverMeta={},currentMode='form',historyLog=[],queryCount=0,errorCount=0,chartInst=null,chainStepNum=0;

function switchTab(name){
  ['result','plot','history'].forEach(function(t){
    document.getElementById('tab-'+t).classList.remove('active');
    document.getElementById('tbtn-'+t).classList.remove('active');
  });
  document.getElementById('tab-'+name).classList.add('active');
  document.getElementById('tbtn-'+name).classList.add('active');
}

function setMode(mode){
  currentMode=mode;
  document.getElementById('mode-form-btn').classList.toggle('active',mode==='form');
  document.getElementById('mode-cmd-btn').classList.toggle('active',mode==='command');
  document.getElementById('mode-chain-btn').classList.toggle('active',mode==='chain');
  document.getElementById('form-panel').style.display=mode==='form'?'':'none';
  document.getElementById('cmd-panel').classList.toggle('active',mode==='command');
  document.getElementById('chain-panel').classList.toggle('active',mode==='chain');
  var btn=document.getElementById('solve-btn');
  btn.textContent=mode==='chain'?'Run Pipeline \u2192':'Compute \u2192';
  btn.className=mode==='chain'?'solve chain-solve':'solve';
  document.getElementById('s-mode').textContent='Mode: '+mode;
  if(mode==='chain'&&document.getElementById('chain-steps').children.length===0){
    addChainStep();addChainStep();
  }
}

function loadSolvers(){
  fetch('/solvers').then(function(r){return r.json();})
  .then(function(data){solverMeta=data;buildDomainSelect();})
  .catch(function(){document.getElementById('domain-select').innerHTML='<option>Error</option>';});
}

function buildDomainSelect(){
  var sel=document.getElementById('domain-select');sel.innerHTML='';
  Object.keys(solverMeta).sort().forEach(function(d){
    var opt=document.createElement('option');opt.value=d;
    opt.textContent=d.replace(/_/g,' ').toUpperCase();sel.appendChild(opt);
  });buildSolverSelect();
}

function onDomainChange(){buildSolverSelect();}
function onSolverChange(){buildParamFields();}

function buildSolverSelect(){
  var domain=document.getElementById('domain-select').value;
  var sel=document.getElementById('solver-select');sel.innerHTML='';
  (solverMeta[domain]||[]).forEach(function(s){
    var opt=document.createElement('option');opt.value=s.command;
    opt.textContent=s.command.replace(/_/g,' ');sel.appendChild(opt);
  });buildParamFields();
}

function getSolverInfo(domSel,slvSel){
  var domain=domSel||document.getElementById('domain-select').value;
  var cmd=slvSel||document.getElementById('solver-select').value;
  return (solverMeta[domain]||[]).find(function(s){return s.command===cmd;});
}

function allSolvers(){
  var list=[];
  Object.keys(solverMeta).sort().forEach(function(d){
    (solverMeta[d]||[]).forEach(function(s){list.push(s);});
  });return list;
}

function buildParamFields(){
  var solver=getSolverInfo();
  var container=document.getElementById('param-fields');
  container.innerHTML='';if(!solver)return;
  document.getElementById('solver-desc').textContent=solver.description;
  // Show the physical equation
  var eqEl=document.getElementById('solver-equation');
  if(eqEl)eqEl.textContent=solver.equation||'';
  // Show ALL variables (not just required) — user fills in what they know
  var allVars=solver.all_vars||(solver.required||[]).concat(solver.optional||[]);
  allVars.forEach(function(p){
    var fld=makeField(p,solver.param_types[p]||'scalar',solver.param_units[p]||'','',false);
    container.appendChild(fld);
    fld.querySelectorAll('input').forEach(function(inp){
      inp.addEventListener('input',updateVariantPreview);
    });
  });
  // Add variant preview indicator
  var prev=document.getElementById('variant-preview');
  if(prev){prev.textContent='Fill in the values you know above';prev.className='variant-preview dim';}
  updateVariantPreview();
}

function updateVariantPreview(){
  var solver=getSolverInfo();
  var prev=document.getElementById('variant-preview');
  if(!solver||!prev)return;
  var allVars=solver.all_vars||(solver.required||[]).concat(solver.optional||[]);
  var filled=new Set();
  allVars.forEach(function(p){
    var type=solver.param_types[p]||'scalar';
    if(type==='vector3'){
      var xi=document.getElementById('p__'+p+'__x');
      if(xi&&xi.value!=='')filled.add(p);
    }else{
      var inp=document.getElementById('p__'+p);
      if(inp&&inp.value!=='')filled.add(p);
    }
  });
  var variants=solver.variants||[];
  var matching=variants.filter(function(v){
    return v.given.every(function(p){return filled.has(p);})&&!filled.has(v.solves);
  });
  if(filled.size===0){
    prev.textContent='Fill in the values you know above'; prev.className='variant-preview dim';
  }else if(matching.length===0){
    prev.textContent='Need more values to determine what to compute'; prev.className='variant-preview dim';
  }else{
    matching.sort(function(a,b){return b.given.length-a.given.length;});
    var best=matching[0];
    prev.textContent='\u2192 Will solve for: '+best.solves.replace(/_/g,' ')+' \u2014 '+best.description;
    prev.className='variant-preview ready';
  }
}

function makeField(name,type,unit,_unused_req,prefix){
  var idpre=prefix?prefix+'__'+name:'p__'+name;
  var div=document.createElement('div');div.className='field-group';
  var lbl=document.createElement('div');lbl.className='field-label';
  var ns=document.createElement('span');ns.textContent=name.replace(/_/g,' ');lbl.appendChild(ns);
  var bs=document.createElement('span');bs.style.display='flex';bs.style.gap='4px';
  if(unit){var ub=document.createElement('span');ub.className='badge unit';ub.textContent=unit;bs.appendChild(ub);}
  lbl.appendChild(bs);div.appendChild(lbl);
  if(type==='vector3'){
    var row=document.createElement('div');row.className='vec-row';
    ['x','y','z'].forEach(function(axis){
      var inp=document.createElement('input');inp.type='number';inp.step='any';
      inp.placeholder=axis;inp.className='vec-input';inp.id=idpre+'__'+axis;row.appendChild(inp);
    });div.appendChild(row);
  }else if(type==='array'){
    var inp=document.createElement('input');inp.type='text';
    inp.placeholder='e.g. [1e-9,-2e-9]';inp.id=idpre;div.appendChild(inp);
  }else{
    var inp=document.createElement('input');inp.type='number';inp.step='any';
    inp.placeholder='value';inp.id=idpre;div.appendChild(inp);
  }
  return div;
}

function collectParams(prefix,solver){
  if(!solver)return null;
  var params={};var idpre=prefix?prefix+'__':'p__';
  var all=solver.all_vars||(solver.required||[]).concat(solver.optional||[]);
  for(var i=0;i<all.length;i++){
    var name=all[i];var type=solver.param_types[name]||'scalar';
    if(type==='vector3'){
      var xi=document.getElementById(idpre+name+'__x');
      if(!xi||xi.value==='')continue;
      params[name]=[parseFloat(xi.value)||0,
        parseFloat(document.getElementById(idpre+name+'__y').value)||0,
        parseFloat(document.getElementById(idpre+name+'__z').value)||0];
    }else if(type==='array'){
      var inp=document.getElementById(idpre+name);
      if(!inp||!inp.value.trim())continue;
      try{params[name]=JSON.parse(inp.value.trim());}catch(e){}
    }else{
      var inp=document.getElementById(idpre+name);
      if(!inp||inp.value==='')continue;
      params[name]=parseFloat(inp.value);
    }
  }
  return params;
}

function addChainStep(){
  chainStepNum++;
  var idx=chainStepNum,id='cstep'+idx;
  var wrap=document.getElementById('chain-steps');
  var div=document.createElement('div');div.className='chain-step';div.id='chain-step-'+id;
  var hdr=document.createElement('div');hdr.className='chain-step-header';
  hdr.innerHTML='<span class="chain-step-title">Step '+idx+'</span>'+
    '<button class="btn-del-step" onclick="removeChainStep(\'chain-step-'+id+'\')">&#x2715;</button>';
  div.appendChild(hdr);
  var body=document.createElement('div');body.className='chain-step-body';
  var slvSel=document.createElement('select');slvSel.id='chain-solver-'+id;
  slvSel.onchange=function(){buildChainStepFields(id);};
  allSolvers().forEach(function(s){
    var opt=document.createElement('option');opt.value=s.command;
    opt.textContent=s.command.replace(/_/g,' ');slvSel.appendChild(opt);
  });
  body.appendChild(slvSel);
  var flds=document.createElement('div');flds.id='chain-fields-'+id;
  body.appendChild(flds);div.appendChild(body);wrap.appendChild(div);
  buildChainStepFields(id);
}

function removeChainStep(elemId){var el=document.getElementById(elemId);if(el)el.remove();}

function getChainSolverInfo(id){
  var cmd=document.getElementById('chain-solver-'+id).value;
  for(var domain in solverMeta){
    var found=(solverMeta[domain]||[]).find(function(s){return s.command===cmd;});
    if(found)return found;
  }return null;
}

function buildChainStepFields(id){
  var solver=getChainSolverInfo(id);
  var cont=document.getElementById('chain-fields-'+id);cont.innerHTML='';
  if(!solver)return;
  var allVars=solver.all_vars||(solver.required||[]).concat(solver.optional||[]);
  allVars.forEach(function(p){cont.appendChild(makeField(p,solver.param_types[p]||'scalar',solver.param_units[p]||'','','chain_'+id));});
}

function collectChainSteps(){
  var steps=[],stepEls=document.getElementById('chain-steps').children;
  for(var i=0;i<stepEls.length;i++){
    var el=stepEls[i],id=el.id.replace('chain-step-','');
    var sol=getChainSolverInfo(id);if(!sol)continue;
    var params=collectParams('chain_'+id,sol);
    steps.push({id:id,solver:sol.command,params:params||{}});
  }return steps;
}

function solve(){
  if(currentMode==='chain'){runChain();return;}
  var payload;
  if(currentMode==='form'){
    var solver=getSolverInfo();if(!solver){alert('Please select a solver.');return;}
    payload=JSON.stringify({mode:'structured',solver:solver.command,params:collectParams('',solver)});
  }else{
    var text=document.getElementById('cmd').value.trim();if(!text)return;
    payload=JSON.stringify({mode:'command',query:text});
  }
  submitSolve(payload);
}

function submitSolve(payload){
  document.getElementById('welcome-state').style.display='none';
  document.getElementById('result-container').classList.add('active');
  document.getElementById('spinner').classList.add('active');
  document.getElementById('solve-btn').disabled=true;
  document.getElementById('sdot').style.color='#f59e0b';
  fetch('/solve',{method:'POST',headers:{'Content-Type':'application/json'},body:payload})
  .then(function(r){return r.json();})
  .then(function(data){
    queryCount++;if(!data.success)errorCount++;
    renderResult(data);if(data.plot_data)renderPlot(data.plot_data);
    addHistory(data,false);updateStatus(data.command);switchTab('result');
  })
  .catch(function(e){errorCount++;showError('Network error: '+e.message);updateStatus('error');})
  .finally(function(){
    document.getElementById('spinner').classList.remove('active');
    document.getElementById('solve-btn').disabled=false;
    document.getElementById('sdot').style.color='#10b981';
  });
}

function runChain(){
  var steps=collectChainSteps();if(steps.length===0){alert('Add at least one step.');return;}
  document.getElementById('welcome-state').style.display='none';
  document.getElementById('result-container').classList.add('active');
  document.getElementById('spinner').classList.add('active');
  document.getElementById('solve-btn').disabled=true;
  document.getElementById('sdot').style.color='#f59e0b';
  fetch('/chain',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({steps:steps})})
  .then(function(r){return r.json();})
  .then(function(results){
    queryCount++;results.forEach(function(d){if(!d.success)errorCount++;});
    renderChainResults(results);
    if(results.length>0&&results[results.length-1].plot_data)renderPlot(results[results.length-1].plot_data);
    addHistory({command:'pipeline['+steps.length+' steps]',success:results.every(function(d){return d.success;}),message:steps.length+' steps executed',rows:[]},true);
    updateStatus('chain');switchTab('result');
  })
  .catch(function(e){errorCount++;showError('Chain error: '+e.message);updateStatus('error');})
  .finally(function(){
    document.getElementById('spinner').classList.remove('active');
    document.getElementById('solve-btn').disabled=false;
    document.getElementById('sdot').style.color='#10b981';
  });
}

function makeResultTable(rows){
  var html='<table class="result-table"><thead><tr><th>Quantity</th><th>Computed Value</th><th>Unit</th><th></th></tr></thead><tbody>';
  rows.forEach(function(row){
    var useBtn=row.chainable?'<button class="btn-use" onclick="useAsInput(\''+escAttr(row.key)+'\',\''+escAttr(row.value)+'\')">Use as input</button>':'';
    html+='<tr><td class="td-key">'+escHtml(row.key.replace(/_/g,' '))+'</td>'+
      '<td class="td-val">'+escHtml(row.value)+'</td>'+
      '<td class="td-unit">'+escHtml(row.unit)+'</td>'+
      '<td class="td-use">'+useBtn+'</td></tr>';
  });
  return html+'</tbody></table>';
}

function renderResult(data){
  var status=document.getElementById('result-status');
  var body=document.getElementById('result-body');
  if(data.success){
    status.style.borderColor='';
    status.innerHTML='<span class="status-icon h-ok">&#x2713;</span>'+
      '<div><div class="status-cmd">> :'+escHtml(data.command)+'&nbsp;&nbsp;'+
      '<span style="color:var(--text-dim);font-size:12px;font-family:var(--font-sans)">&#x2192; :'+escHtml(data.solver)+'</span></div>'+
      '<div class="status-msg">&#x270E; '+escHtml(data.message)+'</div></div>';
    body.innerHTML=makeResultTable(data.rows);
  }else{showError(':'+data.command+'\n\n'+data.message);}
}

function renderChainResults(results){
  var status=document.getElementById('result-status');
  var body=document.getElementById('result-body');
  var allOk=results.every(function(d){return d.success;});
  status.style.borderColor=allOk?'':'var(--error)';
  status.innerHTML='<span class="status-icon '+(allOk?'h-chain':'h-err')+'">'+(allOk?'&#x2713;':'&#x2717;')+'</span>'+
    '<div><div class="status-cmd">Pipeline &mdash; '+results.length+' steps</div>'+
    '<div class="status-msg">'+(allOk?'All steps completed.':'One or more steps failed.')+'</div></div>';
  var html='';
  results.forEach(function(d,i){
    html+='<div class="chain-result-block">'+
      '<div class="chain-result-header">'+(d.success?'&#x2713;':'&#x2717;')+
      '  Step '+(i+1)+' &mdash; :'+escHtml(d.command)+
      '&nbsp;&nbsp;<span style="font-weight:400;color:var(--text-dim)">:: '+escHtml(d.solver)+'</span></div>'+
      '<div style="padding:12px 16px">';
    if(d.success&&d.rows.length>0){html+=makeResultTable(d.rows);}
    else if(!d.success){html+='<div style="color:var(--error);font-size:12px">'+escHtml(d.message)+'</div>';}
    html+='</div></div>';
  });
  body.innerHTML=html;
}

function showError(msg){
  var status=document.getElementById('result-status');
  status.style.borderColor='var(--error)';
  status.innerHTML='<span class="status-icon h-err">&#x2717;</span>'+
    '<span style="color:var(--error);font-family:var(--font-mono);font-size:12px">'+escHtml(msg)+'</span>';
  document.getElementById('result-body').innerHTML='';
}

function useAsInput(key,value){
  setMode('command');
  document.getElementById('cmd').value=key+'='+value;
  document.getElementById('cmd').focus();
}

function renderPlot(pd){
  var msg=document.getElementById('plot-msg');
  var note=document.getElementById('plot-note');
  var canvas=document.getElementById('plot-canvas');
  var wrap=document.getElementById('plot-canvas-wrap');
  if(!pd.available||pd.values.length===0){msg.textContent='No numeric values for this result.';wrap.style.display='none';return;}
  msg.textContent='';note.textContent=pd.note||'';wrap.style.display='block';
  if(chartInst){chartInst.destroy();chartInst=null;}
  var labels=pd.labels.map(function(l,i){return l.replace(/_/g,' ')+(pd.units[i]?' ('+pd.units[i]+')':'');});
  var absVals=pd.values.map(Math.abs);
  var colors=pd.values.map(function(v){return v>=0?'rgba(59,130,246,.8)':'rgba(239,68,68,.8)';});
  var useLog=false;
  if(absVals.length>1){
    var pos=absVals.filter(function(v){return v>0;});
    if(pos.length>1&&Math.max.apply(null,pos)/Math.min.apply(null,pos)>1000)useLog=true;
  }
  var ct=pd.type==='line'?'line':'bar';
  chartInst=new Chart(canvas,{
    type:ct,
    data:{labels:labels,datasets:[{label:pd.title.replace(/_/g,' '),data:absVals,
      backgroundColor:ct==='line'?'rgba(59,130,246,.1)':colors,
      borderColor:ct==='line'?'#3b82f6':colors.map(function(c){return c.replace('.8','1');}),
      borderWidth:ct==='line'?2:1,borderRadius:4,fill:ct==='line',tension:.4,pointBackgroundColor:'#3b82f6'}]},
    options:{responsive:true,plugins:{
      legend:{display:false},
      title:{display:true,text:pd.title.replace(/_/g,' ')+(useLog?' (log scale)':''),
        color:'#f4f4f5',font:{family:'Inter',size:14,weight:500}},
      tooltip:{callbacks:{label:function(ctx){var i=ctx.dataIndex;return pd.values[i].toExponential(4)+' '+(pd.units[i]||'');}}}
    },scales:{
      y:{type:useLog?'logarithmic':'linear',ticks:{color:'#a1a1aa',font:{family:'JetBrains Mono',size:11}},grid:{color:'rgba(63,63,70,.5)'}},
      x:{ticks:{color:'#a1a1aa',font:{family:'Inter',size:11},maxRotation:45},grid:{color:'rgba(63,63,70,.5)'}}
    }}
  });
}

function addHistory(data,isChain){
  historyLog.unshift({data:data,chain:isChain});if(historyLog.length>40)historyLog.pop();
  var list=document.getElementById('history-list');
  if(historyLog.length===1)list.innerHTML='';
  var entry=historyLog[0],d=entry.data;
  var div=document.createElement('div');div.className='history-item';
  div.onclick=function(){replayHistory(entry);};
  var iconClass=d.success?(isChain?'h-chain':'h-ok'):'h-err';
  var iconChar=d.success?'&#x2713;':'&#x2717;';
  var rowPreview='';
  if(d.rows&&d.rows.length>0){
    rowPreview='<div class="h-rows">';
    d.rows.slice(0,3).forEach(function(r){
      rowPreview+=r.key.replace(/_/g,' ')+': <span style="color:var(--val)">'+escHtml(r.value)+'</span> <span style="color:var(--unit)">'+escHtml(r.unit)+'</span>  ';
    });
    if(d.rows.length>3)rowPreview+='...';
    rowPreview+='</div>';
  }
  div.innerHTML='<span class="h-icon '+iconClass+'">'+iconChar+'</span>'+
    '<div style="flex:1;min-width:0"><div class="h-cmd">:'+escHtml(d.command)+'</div>'+
    '<div class="h-msg">'+escHtml((d.message||'').slice(0,80))+'</div>'+rowPreview+'</div>';
  list.insertBefore(div,list.firstChild);
}

function replayHistory(entry){
  var data=entry.data;
  document.getElementById('welcome-state').style.display='none';
  document.getElementById('result-container').classList.add('active');
  if(!entry.chain)renderResult(data);
  if(data.plot_data)renderPlot(data.plot_data);
  switchTab('result');
}

function loadExample(el){
  setMode('command');
  document.getElementById('cmd').value=el.textContent.trim();
  document.getElementById('welcome-state').style.display='none';
  document.getElementById('result-container').classList.add('active');
}

function escHtml(s){
  if(s===null||s===undefined)return'';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function escAttr(s){return escHtml(s).replace(/'/g,'&#39;');}

function clearAll(){
  if(currentMode==='form'){
    document.getElementById('param-fields').querySelectorAll('input').forEach(function(i){i.value='';});
  }else if(currentMode==='command'){
    document.getElementById('cmd').value='';
  }else{
    document.getElementById('chain-steps').querySelectorAll('input').forEach(function(i){i.value='';});
  }
}

function updateStatus(cmd){
  document.getElementById('s-queries').textContent='Queries: '+queryCount;
  document.getElementById('s-errors').textContent='Errors: '+errorCount;
  document.getElementById('s-last').textContent='Last: '+(cmd||'none');
}

document.getElementById('cmd').addEventListener('keydown',function(e){
  if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){e.preventDefault();solve();}
});

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
            isempty(solver_name) && error("No solver specified.")
            query = PhysicalQuery(Symbol(solver_name), params, "structured-api")
            res   = dispatch(query)
            _state.query_count += 1
            _state.last_command = Symbol(solver_name)
        else
            query_str = get(req_data, "query", "")
            isempty(strip(query_str)) && error("Empty query.")
            res = process(query_str, _state)
        end
        d = result_to_dict(res)
        d["plot_data"] = extract_plot_data(res)
        HTTP.Response(200, ["Content-Type" => "application/json"], to_json(d))
    catch e
        HTTP.Response(500, ["Content-Type" => "application/json"],
            to_json(Dict("success"=>false,"command"=>"unknown","solver"=>"server",
                         "message"=>sprint(showerror,e),"rows"=>Dict[],
                         "plot_data"=>Dict("available"=>false,"labels"=>[],"values"=>[],
                                           "units"=>[],"title"=>"","type"=>"bar","note"=>""))))
    end
end

function handle_chain(req::HTTP.Request)
    try
        body = String(req.body)
        # Find steps array
        m = match(r"\"steps\"\s*:\s*(\[)", body)
        isnothing(m) && error("No 'steps' key in chain request.")

        # Find matching ] for the steps array
        start = m.offset + length(m.match) - 1
        depth = 0; arr_close = start
        for (i,c) in enumerate(body[start:end])
            if c == '['; depth += 1
            elseif c == ']'; depth -= 1
                if depth == 0; arr_close = start + i - 1; break; end
            end
        end

        steps_str = body[start+1:arr_close-1]
        steps = Dict[]
        obj_depth = 0; obj_start = 1
        for (i,c) in enumerate(steps_str)
            if c == '{'
                obj_depth += 1; obj_depth == 1 && (obj_start = i)
            elseif c == '}'
                obj_depth -= 1
                if obj_depth == 0
                    obj_str = steps_str[obj_start:i]
                    step    = Dict{String,Any}()
                    mi = match(r"\"id\"\s*:\s*\"([^\"]+)\"", obj_str)
                    !isnothing(mi) && (step["id"] = mi.captures[1])
                    ms = match(r"\"solver\"\s*:\s*\"([^\"]+)\"", obj_str)
                    !isnothing(ms) && (step["solver"] = ms.captures[1])
                    mp = match(r"\"params\"\s*:\s*(\{)", obj_str)
                    if !isnothing(mp)
                        ps = mp.offset + length(mp.match) - 1
                        pd = 0; pc = ps
                        for (j,c2) in enumerate(obj_str[ps:end])
                            if c2 == '{'; pd += 1
                            elseif c2 == '}'; pd -= 1
                                if pd == 0; pc = ps + j - 1; break; end
                            end
                        end
                        step["params"] = _parse_params_obj(obj_str[ps:pc])
                    end
                    push!(steps, step)
                end
            end
        end

        results = execute_chain(steps)
        HTTP.Response(200, ["Content-Type" => "application/json"], to_json(results))
    catch e
        HTTP.Response(500, ["Content-Type" => "application/json"],
            to_json([Dict("step_id"=>"chain","success"=>false,"command"=>"chain",
                          "solver"=>"server","message"=>sprint(showerror,e),
                          "rows"=>Dict[],"plot_data"=>Dict("available"=>false,"labels"=>[],
                          "values"=>[],"units"=>[],"title"=>"","type"=>"bar","note"=>""))]))
    end
end

function handle_404(req::HTTP.Request)
    HTTP.Response(404, "Not found: " * req.target)
end

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET",  "/",        handle_index)
HTTP.register!(ROUTER, "GET",  "/solvers", handle_solvers)
HTTP.register!(ROUTER, "POST", "/solve",   handle_solve)
HTTP.register!(ROUTER, "POST", "/chain",   handle_chain)
HTTP.register!(ROUTER, "GET",  "/**",      handle_404)

const PORT = 8050
println("\n" * "=" ^ 58)
println("  B-SPEC  Web UI  v2.1")
println("  Solvers : " * join(string.(_state.solvers_loaded), " | "))
println("  Commands: " * string(length(SOLVER_REGISTRY)))
println("=" ^ 58)
println()
println("  http://localhost:" * string(PORT))
println()
println("  Endpoints:")
println("    GET  /solvers   solver registry + unit hints")
println("    POST /solve     {mode, solver?, params?, query?}")
println("    POST /chain     {steps:[{id,solver,params},...]}  NEW")
println()
println("  Modes: Form Builder | CLI Mode | Pipeline")
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