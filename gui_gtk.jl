#!/usr/bin/env julia
# ================================================================
# FILE: gui_desktop.jl   —   B-SPEC Physical Engine  Desktop GUI  v2.1
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

using Gtk4
using Gtk4.Pango
using Printf

# ── Engine init ──────────────────────────────────────────────────
const _state = EngineState()
register_electromagnetics!()
register_classical!()
_state.initialized    = true
_state.solvers_loaded = [:electromagnetics, :classical_mechanics]

# ── PARAM_META ───────────────────────────────────────────────────
const PARAM_META = Dict{Symbol, Tuple{String,String}}(
    :source            => ("vector3","m"),    :field_point  => ("vector3","m"),
    :r1               => ("vector3","m"),    :r2           => ("vector3","m"),
    :normal           => ("vector3","—"),    :E_field      => ("vector3","N/C"),
    :charge           => ("scalar","C"),     :q1           => ("scalar","C"),
    :q2               => ("scalar","C"),     :area         => ("scalar","m²"),
    :capacitance      => ("scalar","F"),     :voltage      => ("scalar","V"),
    :V_in             => ("scalar","V"),     :initial_velocity => ("scalar","m/s"),
    :angle_deg        => ("scalar","°"),     :initial_height   => ("scalar","m"),
    :g                => ("scalar","m/s²"),  :m1           => ("scalar","kg"),
    :m2               => ("scalar","kg"),    :distance     => ("scalar","m"),
    :mass             => ("scalar","kg"),    :velocity     => ("scalar","m/s"),
    :force            => ("scalar","N"),     :displacement => ("scalar","m"),
    :spring_constant  => ("scalar","N/m"),   :damping      => ("scalar","N·s/m"),
    :amplitude        => ("scalar","m"),     :radius       => ("scalar","m"),
    :speed            => ("scalar","m/s"),   :v1           => ("scalar","m/s"),
    :v2               => ("scalar","m/s"),   :acceleration => ("scalar","m/s²"),
    :charges          => ("array","C"),      :sources      => ("array","m"),
    :E_magnitude      => ("scalar","N/C"),   :r_magnitude  => ("scalar","m"),
    :F_magnitude      => ("scalar","N"),     :test_force   => ("scalar","N"),
    :test_charge      => ("scalar","C"),     :V            => ("scalar","V"),
    :KE               => ("scalar","J"),     :work         => ("scalar","J"),
    :energy           => ("scalar","J"),     :flux         => ("scalar","N·m²/C"),
    :centripetal_force => ("scalar","N"),    :angular_frequency => ("scalar","rad/s"),
    :frequency_hz     => ("scalar","Hz"),    :period       => ("scalar","s"),
    :range            => ("scalar","m"),     :momentum     => ("scalar","kg·m/s"),
)
param_type(p::Symbol) = get(PARAM_META, p, ("scalar",""))[1]
param_unit(p::Symbol) = get(PARAM_META, p, ("scalar",""))[2]

# ── Result formatters ─────────────────────────────────────────────
function _fmtv(v)::String
    v isa AbstractVector && return "[" * join([@sprintf("%.5g",x) for x in v], ", ") * "]"
    v isa AbstractFloat  && return @sprintf("%.6g", v)
    v isa Bool           && return string(v)
    string(v)
end

function format_result_text(r::SolverResult, elapsed_ms::Float64)::String
    bar = "─" ^ 62
    io  = IOBuffer()
    if r.success
        println(io, "")
        println(io, "  ✓  :$(r.command)   solver: :$(r.solver_id)   ⏱ $(elapsed_ms) ms")
        println(io, "  $bar")
        println(io, "")
        println(io, "  $(rpad("Quantity",28))  $(rpad("Value",22))  Unit")
        println(io, "  $(rpad("─"^28,28))  $(rpad("─"^22,22))  ──────────────────")
        println(io, "")
        for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
            u = get(r.units, k, "?")
            println(io, "  $(rpad(string(k),28))  $(rpad(_fmtv(v),22))  $u")
        end
        println(io, "")
        println(io, "  $bar")
        println(io, "  ✎  $(r.message)")
        println(io, "")
    else
        println(io, "")
        println(io, "  ✗  :$(r.command)   solver: :$(r.solver_id)   ⏱ $(elapsed_ms) ms")
        println(io, "  $bar")
        println(io, "")
        for line in split(r.message, "\n")
            println(io, "  $line")
        end
        println(io, "")
        println(io, "  $bar")
        println(io, "")
    end
    String(take!(io))
end

function build_solver_metadata()::Dict
    domains = Dict{String,Vector{Dict}}()
    for (cmd, e) in SOLVER_REGISTRY
        d = string(e.domain)
        types = Dict{String,String}(string(p) => param_type(p)  for p in e.all_vars)
        uhint = Dict{String,String}(string(p) => param_unit(p)  for p in e.all_vars)
        info  = Dict(
            "command"     => string(cmd),
            "description" => e.description,
            "equation"    => e.equation,
            "all_vars"    => string.(e.all_vars),
            "param_types" => types,
            "param_units" => uhint,
            "variants"    => map(v -> Dict("given"=>string.(v.given), "solves"=>string(v.solves), "description"=>v.description), e.variants),
            "_entry"      => e,
        )
        push!(get!(domains, d, Dict[]), info)
    end
    for v in values(domains); sort!(v, by=x->x["command"]); end
    domains
end

function format_ascii_chart(r::SolverResult)::String
    labels = String[]; values = Float64[]; units = String[]
    for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
        if v isa AbstractFloat && isfinite(v) && !(v isa Bool)
            push!(labels, string(k)); push!(values, v); push!(units, get(r.units,k,""))
        elseif v isa Integer
            push!(labels, string(k)); push!(values, Float64(v)); push!(units, get(r.units,k,""))
        end
    end
    isempty(values) && return "\n  No numeric values to plot.\n"

    io   = IOBuffer()
    println(io, "")
    println(io, "  $(replace(string(r.command),"_"=>" "))  —  |values| ($(r.solver_id))")
    println(io, "  " * "─"^60)

    abs_vals = abs.(values)
    max_val  = maximum(abs_vals)
    max_val ≈ 0 && (max_val = 1.0)

    bar_width = 38
    for i in eachindex(labels)
        filled = round(Int, abs_vals[i] / max_val * bar_width)
        bar    = "█" ^ filled * "░" ^ (bar_width - filled)
        sign   = values[i] < 0 ? "−" : " "
        val_s  = @sprintf("%.4g", abs_vals[i])
        lbl    = rpad(labels[i][1:min(length(labels[i]),18)], 19)
        println(io, "  $(lbl) │$(bar)│ $(sign)$(val_s) $(units[i])")
    end
    println(io, "")
    String(take!(io))
end

# ── CSS ───────────────────────────────────────────────────────────
const BSPEC_CSS = """
window { background-color: #09090b; color: #f4f4f5; font-family: Inter, Ubuntu, sans-serif; font-size: 14px; }
.bspec-header { background-color: #18181b; border-bottom: 1px solid #3f3f46; padding: 10px 20px; }
.bspec-title { font-size: 16px; font-weight: 600; letter-spacing: 1px; color: #f4f4f5; }
.bspec-subtitle { color: #a1a1aa; font-size: 12px; }
.bspec-pill { background-color: #27272a; border: 1px solid #3f3f46; color: #a1a1aa; font-size: 11px; padding: 2px 8px; border-radius: 12px; }
.bspec-left { background-color: #18181b; border-right: 1px solid #3f3f46; min-width: 360px; }
.bspec-right { background-color: #09090b; }
.bspec-sec-label { color: #a1a1aa; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; padding: 12px 16px 6px 16px; }
.bspec-mode-btn { background-color: #27272a; border: 1px solid #3f3f46; color: #a1a1aa; border-radius: 6px; font-size: 11px; font-weight: 500; padding: 6px 10px; min-width: 90px; }
.bspec-mode-btn:hover { border-color: #52525b; color: #f4f4f5; }
.bspec-mode-active { background-color: #3b82f6; border-color: #3b82f6; color: #ffffff; }
.bspec-chain-active { background-color: #a78bfa; border-color: #a78bfa; color: #ffffff; }
.bspec-field-label { color: #f4f4f5; font-size: 12px; font-weight: 500; padding-bottom: 4px; }
.bspec-unit-badge { color: #34d399; font-size: 10px; border: 1px solid rgba(52,211,153,0.3); border-radius: 4px; padding: 1px 5px; background-color: #27272a; }
entry { background-color: #27272a; border: 1px solid #3f3f46; border-radius: 6px; color: #f4f4f5; font-family: "JetBrains Mono", "Courier New", monospace; font-size: 13px; padding: 6px 10px; }
entry:focus { border-color: #3b82f6; }
combobox button, combobox { background-color: #27272a; border: 1px solid #3f3f46; color: #f4f4f5; border-radius: 6px; padding: 6px 10px; font-size: 13px; }
textview, textview > text { background-color: #27272a; color: #f4f4f5; font-family: "JetBrains Mono", "Courier New", monospace; font-size: 13px; }
.bspec-compute-btn { background-color: #3b82f6; color: #ffffff; border: none; border-radius: 6px; font-size: 13px; font-weight: 600; padding: 10px 16px; }
.bspec-compute-btn:hover { background-color: #2563eb; }
.bspec-compute-btn:disabled { background-color: #3f3f46; color: #a1a1aa; }
.bspec-chain-btn { background-color: #a78bfa; color: #ffffff; border: none; border-radius: 6px; font-size: 13px; font-weight: 600; padding: 10px 16px; }
.bspec-clear-btn { background-color: transparent; border: 1px solid #3f3f46; color: #f4f4f5; border-radius: 6px; font-size: 13px; font-weight: 500; padding: 10px 16px; }
.bspec-clear-btn:hover { background-color: #27272a; }
.bspec-action-bar { background-color: #18181b; border-top: 1px solid #3f3f46; padding: 10px 16px; }
notebook { background-color: #09090b; }
notebook header { background-color: #18181b; border-bottom: 1px solid #3f3f46; padding: 0 16px; }
notebook header tabs tab { color: #a1a1aa; font-size: 12px; font-weight: 500; padding: 12px 16px; border: none; background-color: transparent; }
notebook header tabs tab:checked { color: #3b82f6; border-bottom: 2px solid #3b82f6; background-color: transparent; }
notebook header tabs tab:hover { color: #f4f4f5; }
.bspec-result-view, .bspec-result-view > text { background-color: #0f1419; color: #f4f4f5; font-family: "JetBrains Mono", "Courier New", monospace; font-size: 13px; padding: 16px; }
.bspec-variant-ready { color: #10b981; font-size: 12px; font-weight: 500; }
.bspec-variant-dim   { color: #a1a1aa; font-size: 12px; }
.bspec-solver-eq { color: #34d399; font-family: "JetBrains Mono", monospace; font-size: 11px; }
.bspec-desc-lbl  { color: #a1a1aa; font-size: 12px; }
.bspec-statusbar { background-color: #18181b; border-top: 1px solid #3f3f46; padding: 5px 16px; font-family: "JetBrains Mono", "Courier New", monospace; font-size: 11px; color: #a1a1aa; }
.bspec-add-step { border: 1px dashed #3f3f46; background-color: transparent; color: #a1a1aa; border-radius: 6px; padding: 8px; font-size: 12px; }
.bspec-add-step:hover { border-color: #a78bfa; color: #a78bfa; }
.bspec-spinner { color: #3b82f6; font-size: 12px; }
scrolledwindow { background-color: transparent; }
scrollbar { background-color: transparent; min-width: 6px; }
scrollbar slider { background-color: #3f3f46; border-radius: 4px; min-width: 6px; }
"""

function _apply_css!()
    provider = GtkCssProvider(BSPEC_CSS)
    manager = Gtk4.G_.get()
    display = Gtk4.default_display(manager)
    push!(display, provider)
end

# ── UI mutable state ──────────────────────────────────────────────
const _W = Dict{String,Any}()   
const _S = Dict{String,Any}(
    "mode"          => "command",
    "query_count"   => 0,
    "error_count"   => 0,
    "last_cmd"      => "none",
    "computing"     => false,
    "solver_meta"   => Dict(),
    "domain_keys"   => String[],   # Safely mapped index for combobox
    "solver_keys"   => String[],   # Safely mapped index for combobox
    "history"       => Dict[],
    "chain_steps"   => Pair{Int,GtkWidget}[],
    "chain_count"   => 0,
    "param_entries" => Dict{String,Any}(),
    "current_solver"=> nothing,
)

# ── Param field builders ──────────────────────────────────────────

function _clear_box!(box::GtkBox)
    while (c = Gtk4.first_child(box)) !== nothing
        delete!(box, c)
    end
end

function rebuild_param_fields!(solver_info::Dict)
    box = _W["param_fields_box"]::GtkBox
    _clear_box!(box)
    empty!(_S["param_entries"])

    _W["solver_desc_lbl"].label  = solver_info["description"]
    _W["solver_eq_lbl"].label    = solver_info["equation"]
    _W["variant_lbl"].label      = "Fill in the known values above"
    Gtk4.remove_css_class(_W["variant_lbl"], "bspec-variant-ready")
    Gtk4.add_css_class(_W["variant_lbl"], "bspec-variant-dim")

    all_vars = solver_info["all_vars"]
    ptypes   = solver_info["param_types"]
    punits   = solver_info["param_units"]

    for var_name in all_vars
        ptype = get(ptypes, var_name, "scalar")
        punit = get(punits, var_name, "")

        field_box = GtkBox(:v)
        field_box.spacing = 3
        field_box.margin_start  = 16
        field_box.margin_end    = 16
        field_box.margin_bottom = 6

        lbl_row = GtkBox(:h)
        lbl_row.spacing = 6
        name_lbl = GtkLabel(replace(var_name, "_" => " "))
        name_lbl.halign = Gtk4.Align_START
        Gtk4.add_css_class(name_lbl, "bspec-field-label")
        push!(lbl_row, name_lbl)
        if !isempty(punit)
            unit_lbl = GtkLabel(punit)
            Gtk4.add_css_class(unit_lbl, "bspec-unit-badge")
            push!(lbl_row, unit_lbl)
        end
        push!(field_box, lbl_row)

        if ptype == "vector3"
            vec_row = GtkBox(:h)
            vec_row.spacing = 4
            entries = GtkEntry[]
            for axis in ["x", "y", "z"]
                e = GtkEntry()
                e.placeholder_text = axis
                e.hexpand = true
                e.input_purpose = Gtk4.InputPurpose_NUMBER
                push!(vec_row, e)
                push!(entries, e)
                signal_connect(e, "changed") do _
                    _update_variant_preview!(solver_info)
                end
            end
            push!(field_box, vec_row)
            _S["param_entries"][var_name] = entries

        elseif ptype == "array"
            e = GtkEntry()
            e.placeholder_text = "e.g. [1e-9, -2e-9]"
            e.hexpand = true
            push!(field_box, e)
            _S["param_entries"][var_name] = e
            signal_connect(e, "changed") do _
                _update_variant_preview!(solver_info)
            end

        else
            e = GtkEntry()
            e.placeholder_text = "value"
            e.hexpand = true
            e.input_purpose = Gtk4.InputPurpose_NUMBER
            push!(field_box, e)
            _S["param_entries"][var_name] = e
            signal_connect(e, "changed") do _
                _update_variant_preview!(solver_info)
            end
        end

        push!(box, field_box)
    end
end

function _update_variant_preview!(solver_info::Dict)
    entry = _S["param_entries"]
    provided = Set{Symbol}()
    for (name, entry_or_vec) in entry
        if entry_or_vec isa Vector
            any(e -> !isempty(e.text), entry_or_vec) && push!(provided, Symbol(name))
        else
            !isempty(entry_or_vec.text) && push!(provided, Symbol(name))
        end
    end

    lbl = _W["variant_lbl"]::GtkLabel
    solver_entry = get(solver_info, "_entry", nothing)
    if isnothing(solver_entry)
        lbl.label = "Select a solver"
        return
    end

    variant = select_variant(solver_entry, provided)
    if isempty(provided)
        lbl.label = "Fill in the known values above"
        Gtk4.remove_css_class(lbl, "bspec-variant-ready")
        Gtk4.add_css_class(lbl, "bspec-variant-dim")
    elseif isnothing(variant)
        lbl.label = "Need more values to determine what to compute"
        Gtk4.remove_css_class(lbl, "bspec-variant-ready")
        Gtk4.add_css_class(lbl, "bspec-variant-dim")
    else
        lbl.label = "→ Will solve for: $(variant.solves) — $(variant.description)"
        Gtk4.remove_css_class(lbl, "bspec-variant-dim")
        Gtk4.add_css_class(lbl, "bspec-variant-ready")
    end
end

function collect_form_params()::Dict{Symbol,Any}
    params  = Dict{Symbol,Any}()
    entries = _S["param_entries"]
    meta    = _S["current_solver"]
    isnothing(meta) && return params
    ptypes  = meta["param_types"]

    for (name, entry_or_vec) in entries
        ptype = get(ptypes, name, "scalar")
        if ptype == "vector3" && entry_or_vec isa Vector
            vals = [tryparse(Float64, strip(e.text)) for e in entry_or_vec]
            any(isnothing, vals) && continue
            params[Symbol(name)] = Float64.(something.(vals))
        elseif ptype == "array"
            txt = strip(entry_or_vec.text)
            isempty(txt) && continue
            try
                params[Symbol(name)] = eval(Meta.parse(txt))
            catch
            end
        else
            txt = strip(entry_or_vec.text)
            isempty(txt) && continue
            v = tryparse(Float64, txt)
            isnothing(v) && continue
            params[Symbol(name)] = v
        end
    end
    params
end

# ── Async compute runner ──────────────────────────────────────────

function run_query_async!(query_str::String)
    _S["computing"] && return
    _S["computing"] = true

    Gtk4.GLib.@idle_add begin
        _W["spinner_lbl"].visible = true
        _W["compute_btn"].sensitive = false
    end

    Threads.@spawn begin
        t0     = time_ns()
        result = try
            process(query_str, _state)
        catch e
            failed_result(:unknown, :desktop_gui, sprint(showerror, e))
        end
        elapsed_ms = round((time_ns() - t0) / 1_000_000, digits = 2)

        Gtk4.GLib.@idle_add begin
            invokelatest(_on_result!, result, elapsed_ms)
        end
    end
end

function run_form_async!(solver_name::Symbol, params::Dict{Symbol,Any})
    _S["computing"] && return
    _S["computing"] = true

    Gtk4.GLib.@idle_add begin
        _W["spinner_lbl"].visible = true
        _W["compute_btn"].sensitive = false
    end

    Threads.@spawn begin
        t0     = time_ns()
        result = try
            query = PhysicalQuery(solver_name, params, "desktop-form")
            r = dispatch(query)
            _state.query_count += 1
            _state.last_command = solver_name
            r
        catch e
            failed_result(solver_name, :desktop_gui, sprint(showerror, e))
        end
        elapsed_ms = round((time_ns() - t0) / 1_000_000, digits = 2)

        Gtk4.GLib.@idle_add begin
            invokelatest(_on_result!, result, elapsed_ms)
        end
    end
end

function run_chain_async!(steps::Vector{Dict})
    _S["computing"] && return
    _S["computing"] = true

    Gtk4.GLib.@idle_add begin
        _W["spinner_lbl"].visible = true
        _W["compute_btn"].sensitive = false
    end

    Threads.@spawn begin
        t0      = time_ns()
        outputs = Dict{String,Any}()
        results = SolverResult[]
        msgs    = String[]

        for (i, step) in enumerate(steps)
            solver_name = Symbol(get(step, "solver", "unknown"))
            params_raw  = get(step, "params", Dict())
            step_id     = get(step, "id", "step$i")

            params = Dict{Symbol,Any}()
            for (k, v) in params_raw
                if v isa Dict && haskey(v, "from_step")
                    ref = v["from_step"] * "." * get(v, "key", "")
                    if haskey(outputs, ref)
                        params[Symbol(k)] = outputs[ref]
                    else
                        push!(msgs, "Step $i: reference '$ref' not found")
                        break
                    end
                elseif v isa Vector
                    params[Symbol(k)] = Float64.(v)
                else
                    params[Symbol(k)] = Float64(v)
                end
            end

            r = try
                q = PhysicalQuery(solver_name, params, "chain-$(step_id)")
                dispatch(q)
            catch e
                failed_result(solver_name, :chain, sprint(showerror, e))
            end

            for (k, v) in r.outputs
                outputs["$(step_id).$(k)"] = v
            end
            push!(results, r)
        end

        elapsed_ms = round((time_ns() - t0) / 1_000_000, digits = 2)

        Gtk4.GLib.@idle_add begin
            invokelatest(_on_chain_result!, results, elapsed_ms)
        end
    end
end

# ── Result display callbacks ──────────────────────────────────────

function _on_result!(r::SolverResult, elapsed_ms::Float64)
    _S["computing"]   = false
    _S["query_count"] = _state.query_count
    _S["error_count"] = _state.error_count
    r.success || (_S["error_count"] += 1)

    text = format_result_text(r, elapsed_ms)

    # Use property assignment for text buffer
    buf = Gtk4.buffer(_W["result_tv"]::GtkTextView)
    buf.text = text

    viz_buf = Gtk4.buffer(_W["viz_tv"]::GtkTextView)
    chart   = r.success ? format_ascii_chart(r) : "\n  No data to visualize.\n"
    viz_buf.text = chart

    _add_to_history!(r, elapsed_ms)
    _update_statusbar!(elapsed_ms)

    # Use property assignment for notebook page
    _W["notebook"].page = 0

    _W["spinner_lbl"].visible   = false
    _W["compute_btn"].sensitive = true
end

function _on_chain_result!(results::Vector{SolverResult}, elapsed_ms::Float64)
    _S["computing"] = false

    io = IOBuffer()
    println(io, "")
    println(io, "  Pipeline — $(length(results)) step$(length(results)==1 ? "" : "s")  ⏱ $(elapsed_ms) ms total")
    println(io, "  " * "─"^62)
    for (i, r) in enumerate(results)
        icon = r.success ? "✓" : "✗"
        println(io, "")
        println(io, "  $icon  Step $i  :$(r.command)  →  :$(r.solver_id)")
        if r.success
            for (k,v) in sort(collect(r.outputs), by=x->string(x[1]))
                u = get(r.units, k, "?")
                println(io, "     $(rpad(string(k),26))  $(rpad(_fmtv(v),20))  $u")
            end
            println(io, "     ✎  $(r.message)")
        else
            println(io, "     ✗  $(r.message)")
        end
    end
    println(io, "")
    
    buf = Gtk4.buffer(_W["result_tv"]::GtkTextView)
    buf.text = String(take!(io))
   
    _W["notebook"].page = 0

    _update_statusbar!(elapsed_ms)
    _W["spinner_lbl"].visible   = false
    _W["compute_btn"].sensitive = true
end

function _add_to_history!(r::SolverResult, elapsed_ms::Float64)
    entry = Dict("command"=>string(r.command), "solver"=>string(r.solver_id),
                 "success"=>r.success, "message"=>r.message[1:min(end,80)],
                 "ms"=>elapsed_ms)
    pushfirst!(_S["history"], entry)
    length(_S["history"]) > 40 && pop!(_S["history"])

    history_box = _W["history_box"]::GtkBox
    _clear_box!(history_box)

    if isempty(_S["history"])
        lbl = GtkLabel("No queries executed yet.")
        Gtk4.add_css_class(lbl, "bspec-desc-lbl")
        push!(history_box, lbl)
        return
    end

    for (i, h) in enumerate(_S["history"])
        row = GtkBox(:h)
        row.spacing = 8
        row.margin_start = 16; row.margin_end = 16
        row.margin_top = 6; row.margin_bottom = 6

        icon_lbl = GtkLabel(h["success"] ? "✓" : "✗")
        icon_lbl.width_chars = 2
        push!(row, icon_lbl)

        info = GtkBox(:v)
        info.spacing = 2
        info.hexpand = true
        cmd_lbl = GtkLabel(":$(h["command"])  →  :$(h["solver"])   ⏱ $(h["ms"]) ms")
        cmd_lbl.halign = Gtk4.Align_START
        Gtk4.add_css_class(cmd_lbl, "bspec-field-label")
        push!(info, cmd_lbl)
        
        msg_lbl = GtkLabel(h["message"])
        msg_lbl.halign = Gtk4.Align_START
        Gtk4.add_css_class(msg_lbl, "bspec-desc-lbl")
        msg_lbl.ellipsize = Pango.EllipsizeMode_END
        push!(info, msg_lbl)
        push!(row, info)

        num_lbl = GtkLabel(string(length(_S["history"]) - i + 1))
        Gtk4.add_css_class(num_lbl, "bspec-desc-lbl")
        push!(row, num_lbl)

        sep = GtkSeparator(:h)
        wrap = GtkBox(:v)
        push!(wrap, row); push!(wrap, sep)
        push!(history_box, wrap)
    end
end

function _update_statusbar!(elapsed_ms::Float64)
    qc = _state.query_count
    ec = _state.error_count
    lc = isnothing(_state.last_command) ? "none" : string(_state.last_command)

    _W["sb_queries"].label = "Queries: $qc"
    _W["sb_errors"].label  = "Errors: $ec"
    _W["sb_last"].label    = "Last: $lc"
    _W["sb_time"].label    = "Time: $(elapsed_ms) ms"
    _W["sb_mode"].label    = "Mode: $(_S["mode"])"
end

# ── Mode switching ────────────────────────────────────────────────

function _set_mode!(mode::String)
    _S["mode"] = mode

    for (m, key) in [("form","btn_form"),("command","btn_cmd"),("chain","btn_pipeline")]
        btn = _W[key]::GtkButton
        Gtk4.remove_css_class(btn, "bspec-mode-active")
        Gtk4.remove_css_class(btn, "bspec-chain-active")
        if m == mode
            mode == "chain" ? Gtk4.add_css_class(btn, "bspec-chain-active") : Gtk4.add_css_class(btn, "bspec-mode-active")
        end
    end

    _W["form_panel"].visible     = (mode == "form")
    _W["cmd_panel"].visible      = (mode == "command")
    _W["pipeline_panel"].visible = (mode == "chain")

    btn = _W["compute_btn"]::GtkButton
    if mode == "chain"
        btn.label = "Run Pipeline →"
        Gtk4.remove_css_class(btn, "bspec-compute-btn")
        Gtk4.add_css_class(btn, "bspec-chain-btn")
    else
        btn.label = "Compute →"
        Gtk4.remove_css_class(btn, "bspec-chain-btn")
        Gtk4.add_css_class(btn, "bspec-compute-btn")
    end

    _W["sb_mode"] !== nothing && (_W["sb_mode"].label = "Mode: $mode")
end

# ── Solver dropdowns ──────────────────────────────────────────────

function _build_domain_combo!()
    meta = _S["solver_meta"]
    cb   = _W["domain_combo"]::GtkComboBoxText
    
    # Safe array clearing for GTK4
    empty!(cb)

    domains = sort(collect(keys(meta)))
    _S["domain_keys"] = domains
    
    for d in domains
        push!(cb, replace(uppercase(d), "_"=>" "))
    end
    cb.active = 0
    _build_solver_combo!()
end

function _build_solver_combo!()
    meta        = _S["solver_meta"]
    domain_cb   = _W["domain_combo"]::GtkComboBoxText
    solver_cb   = _W["solver_combo"]::GtkComboBoxText

    idx = domain_cb.active
    idx < 0 && return
    
    # Safely index into our stored keys
    domain_key = _S["domain_keys"][idx + 1]
    solvers = get(meta, domain_key, Dict[])
    _S["solver_keys"] = [s["command"] for s in solvers]

    empty!(solver_cb)
    for s in solvers
        push!(solver_cb, replace(s["command"], "_"=>" "))
    end
    solver_cb.active = 0
    _on_solver_change!()
end

function _on_solver_change!()
    meta      = _S["solver_meta"]
    domain_cb = _W["domain_combo"]::GtkComboBoxText
    solver_cb = _W["solver_combo"]::GtkComboBoxText

    d_idx = domain_cb.active
    s_idx = solver_cb.active
    (d_idx < 0 || s_idx < 0) && return

    domain_key = _S["domain_keys"][d_idx + 1]
    solvers = get(meta, domain_key, Dict[])
    
    si = solvers[s_idx + 1]
    _S["current_solver"] = si
    rebuild_param_fields!(si)
end

# ── Pipeline step management ──────────────────────────────────────

function _add_chain_step!()
    _S["chain_count"] += 1
    step_id  = _S["chain_count"]
    
    step_box = GtkBox(:v)
    step_box.spacing = 4
    step_box.margin_start = 8; step_box.margin_end = 8
    step_box.margin_bottom = 6

    hdr = GtkBox(:h)
    hdr.spacing = 8
    step_lbl = GtkLabel("Step $step_id")
    Gtk4.add_css_class(step_lbl, "bspec-field-label")
    step_lbl.hexpand = true
    hdr.margin_top = 4

    del_btn = GtkButton("✕")
    Gtk4.add_css_class(del_btn, "bspec-clear-btn")
    del_btn.tooltip_text = "Remove this step"
    signal_connect(del_btn, "clicked") do _
        _remove_chain_step!(step_id, step_box)
    end
    push!(hdr, step_lbl); push!(hdr, del_btn)
    push!(step_box, hdr)

    entry_lbl = GtkLabel("Command (solver param=val ...):")
    Gtk4.add_css_class(entry_lbl, "bspec-desc-lbl")
    entry_lbl.halign = Gtk4.Align_START
    push!(step_box, entry_lbl)

    step_entry = GtkEntry()
    step_entry.placeholder_text = "get coulomb_force q1=1e-9 q2=-2e-9 ..."
    step_entry.hexpand = true
    push!(step_box, step_entry)

    sep = GtkSeparator(:h); push!(step_box, sep)

    push!(_W["chain_steps_box"]::GtkBox, step_box)
    push!(_S["chain_steps"], step_id => step_box)

    _W["chain_entry_$(step_id)"] = step_entry
end

function _remove_chain_step!(step_id::Int, step_box::GtkBox)
    parent = _W["chain_steps_box"]::GtkBox
    delete!(parent, step_box)
    filter!(p -> p.first != step_id, _S["chain_steps"])
    delete!(_W, "chain_entry_$(step_id)")
end

# ── Compute dispatcher ────────────────────────────────────────────

function _on_compute!()
    mode = _S["mode"]

    if mode == "command"
        buf = Gtk4.buffer(_W["cmd_tv"]::GtkTextView)
        txt = strip(buf.text)
        isempty(txt) && return
        run_query_async!(String(txt))

    elseif mode == "form"
        si = _S["current_solver"]
        isnothing(si) && return
        params = collect_form_params()
        isempty(params) && return
        run_form_async!(Symbol(si["command"]), params)

    elseif mode == "chain"
        steps = Dict[]
        for (id, _) in _S["chain_steps"]
            entry_key = "chain_entry_$(id)"
            haskey(_W, entry_key) || continue
            e   = _W[entry_key]::GtkEntry
            txt = strip(e.text)
            isempty(txt) && continue
            push!(steps, Dict("id"=>"step$id", "solver"=>_parse_chain_solver(txt),
                              "params"=>_parse_chain_params(txt)))
        end
        isempty(steps) && return
        run_chain_async!(steps)
    end
end

function _parse_chain_solver(cmd::String)::String
    tokens = split(strip(cmd))
    isempty(tokens) && return "unknown"
    t1 = lowercase(tokens[1])
    RECOGNIZED_VERBS = ("get","find","compute","calculate","solve","determine","evaluate","derive")
    t1 in RECOGNIZED_VERBS && length(tokens) >= 2 && return lowercase(tokens[2])
    return t1
end

function _parse_chain_params(cmd::String)::Dict
    params = Dict()
    for tok in split(strip(cmd))
        m = match(r"^(\w+)=(.+)$", tok)
        isnothing(m) && continue
        v = tryparse(Float64, m.captures[2])
        isnothing(v) || (params[m.captures[1]] = v)
    end
    params
end

# ── Main UI constructor ───────────────────────────────────────────

function build_ui()
    win = GtkWindow()
    win.title = "B-SPEC Physical Engine  v2.1"
    win.width_request = 1340
    win.height_request = 900
    win.resizable = true
    _W["win"] = win

    root = GtkBox(:v)
    win[] = root

    header = GtkBox(:h)
    header.spacing = 12
    Gtk4.add_css_class(header, "bspec-header")
    header.margin_start = 20; header.margin_end = 20
    header.margin_top = 10; header.margin_bottom = 10

    title_box = GtkBox(:h)
    title_box.spacing = 8
    hex_lbl   = GtkLabel("⬡")
    Gtk4.add_css_class(hex_lbl, "bspec-title")
    name_lbl = GtkLabel("B-SPEC  PHYSICAL ENGINE")
    Gtk4.add_css_class(name_lbl, "bspec-title")
    push!(title_box, hex_lbl); push!(title_box, name_lbl)

    sub_lbl = GtkLabel("Scientific Computing Interface")
    Gtk4.add_css_class(sub_lbl, "bspec-subtitle")
    sub_lbl.hexpand = true

    pill = GtkLabel("v2.1")
    Gtk4.add_css_class(pill, "bspec-pill")

    push!(header, title_box); push!(header, sub_lbl); push!(header, pill)
    push!(root, header)
    push!(root, GtkSeparator(:h))

    main_box = GtkBox(:h)
    main_box.vexpand = true
    push!(root, main_box)

    # ══ LEFT PANEL ═══════════════════════════════════════════════
    left_outer = GtkBox(:v)
    Gtk4.add_css_class(left_outer, "bspec-left")
    left_outer.width_request = 370
    left_outer.hexpand = false
    push!(main_box, left_outer)
    push!(main_box, GtkSeparator(:v))

    mode_label = GtkLabel("INPUT MODE")
    Gtk4.add_css_class(mode_label, "bspec-sec-label")
    mode_label.halign = Gtk4.Align_START
    push!(left_outer, mode_label)

    mode_row = GtkBox(:h)
    mode_row.spacing = 6
    mode_row.margin_start = 16; mode_row.margin_end = 16
    mode_row.margin_bottom = 8

    btn_form     = GtkButton("Form Builder")
    btn_cmd      = GtkButton("CLI Mode")
    btn_pipeline = GtkButton("Pipeline")
    for b in [btn_form, btn_cmd, btn_pipeline]
        Gtk4.add_css_class(b, "bspec-mode-btn")
        b.hexpand = true
    end
    Gtk4.add_css_class(btn_form, "bspec-mode-active")
    push!(mode_row, btn_form); push!(mode_row, btn_cmd); push!(mode_row, btn_pipeline)
    push!(left_outer, mode_row)

    _W["btn_form"] = btn_form; _W["btn_cmd"] = btn_cmd; _W["btn_pipeline"] = btn_pipeline

    signal_connect(btn_form,     "clicked") do _ _set_mode!("form")     end
    signal_connect(btn_cmd,      "clicked") do _ _set_mode!("command")  end
    signal_connect(btn_pipeline, "clicked") do _ _set_mode!("chain")    end

    push!(left_outer, GtkSeparator(:h))

    # ── FORM PANEL ───────────────────────────────────────────────
    form_sw = GtkScrolledWindow()
    form_sw.vexpand = true
    form_sw.hscrollbar_policy = Gtk4.PolicyType_NEVER
    form_inner = GtkBox(:v)
    form_sw[] = form_inner

    domain_lbl = GtkLabel("DOMAIN")
    Gtk4.add_css_class(domain_lbl, "bspec-sec-label")
    domain_lbl.halign = Gtk4.Align_START
    push!(form_inner, domain_lbl)

    domain_combo = GtkComboBoxText()
    domain_combo.margin_start = 16; domain_combo.margin_end = 16
    domain_combo.margin_bottom = 6
    push!(form_inner, domain_combo)
    _W["domain_combo"] = domain_combo
    signal_connect(domain_combo, "changed") do _ _build_solver_combo!() end

    solver_lbl = GtkLabel("SOLVER ENGINE")
    Gtk4.add_css_class(solver_lbl, "bspec-sec-label")
    solver_lbl.halign = Gtk4.Align_START
    push!(form_inner, solver_lbl)

    solver_combo = GtkComboBoxText()
    solver_combo.margin_start = 16; solver_combo.margin_end = 16
    solver_combo.margin_bottom = 4
    push!(form_inner, solver_combo)
    _W["solver_combo"] = solver_combo
    signal_connect(solver_combo, "changed") do _ _on_solver_change!() end

    desc_lbl = GtkLabel("Select a solver above.")
    Gtk4.add_css_class(desc_lbl, "bspec-desc-lbl")
    desc_lbl.margin_start = 16; desc_lbl.margin_end = 16
    desc_lbl.margin_bottom = 2; desc_lbl.halign = Gtk4.Align_START
    desc_lbl.wrap = true; desc_lbl.max_width_chars = 42
    push!(form_inner, desc_lbl)
    _W["solver_desc_lbl"] = desc_lbl

    eq_lbl = GtkLabel("")
    Gtk4.add_css_class(eq_lbl, "bspec-solver-eq")
    eq_lbl.margin_start = 16; eq_lbl.margin_end = 16
    eq_lbl.margin_bottom = 4; eq_lbl.halign = Gtk4.Align_START
    push!(form_inner, eq_lbl)
    _W["solver_eq_lbl"] = eq_lbl

    push!(form_inner, GtkSeparator(:h))

    variant_lbl = GtkLabel("Fill in the known values above")
    Gtk4.add_css_class(variant_lbl, "bspec-variant-dim")
    variant_lbl.margin_start = 16; variant_lbl.margin_end = 16
    variant_lbl.margin_top = 4; variant_lbl.margin_bottom = 4
    variant_lbl.halign = Gtk4.Align_START; variant_lbl.wrap = true
    variant_lbl.max_width_chars = 42
    push!(form_inner, variant_lbl)
    _W["variant_lbl"] = variant_lbl

    push!(form_inner, GtkSeparator(:h))

    param_fields_box = GtkBox(:v)
    param_fields_box.margin_top = 4
    push!(form_inner, param_fields_box)
    _W["param_fields_box"] = param_fields_box

    _W["form_panel"] = form_sw
    push!(left_outer, form_sw)

    # ── CLI / NLP PANEL ──────────────────────────────────────────
    cmd_panel = GtkBox(:v)
    cmd_panel.vexpand = true

    cmd_sec = GtkLabel("RAW COMMAND OR PROBLEM TEXT")
    Gtk4.add_css_class(cmd_sec, "bspec-sec-label")
    cmd_sec.halign = Gtk4.Align_START
    push!(cmd_panel, cmd_sec)

    cmd_sw = GtkScrolledWindow()
    cmd_sw.vexpand = true
    cmd_sw.margin_start = 16; cmd_sw.margin_end = 16; cmd_sw.margin_bottom = 4
    cmd_tv = GtkTextView()
    cmd_tv.wrap_mode = Gtk4.WrapMode_WORD
    cmd_tv.left_margin = 8; cmd_tv.right_margin = 8
    cmd_tv.top_margin = 8;  cmd_tv.bottom_margin = 8
    cmd_sw[] = cmd_tv
    push!(cmd_panel, cmd_sw)
    _W["cmd_tv"] = cmd_tv

    hints = GtkLabel(
        "COMMAND:  get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]\n" *
        "NATURAL:  Point charges of 1 nC and -2 nC at (0,0,0) and (1,1,1).\n" *
        "              Determine the vector force on each charge.\n" *
        "TIP:        Ctrl+Enter = Compute"
    )
    Gtk4.add_css_class(hints, "bspec-desc-lbl")
    hints.margin_start = 16; hints.margin_end = 16; hints.margin_bottom = 4
    hints.halign = Gtk4.Align_START; hints.wrap = true
    push!(cmd_panel, hints)

    _W["cmd_panel"] = cmd_panel
    push!(left_outer, cmd_panel)
    cmd_panel.visible = false

    # ── PIPELINE PANEL ───────────────────────────────────────────
    pipeline_panel = GtkBox(:v)
    pipeline_panel.vexpand = true

    pl_sec = GtkLabel("PIPELINE STEPS")
    Gtk4.add_css_class(pl_sec, "bspec-sec-label")
    pl_sec.halign = Gtk4.Align_START
    push!(pipeline_panel, pl_sec)

    chain_sw = GtkScrolledWindow()
    chain_sw.vexpand = true; chain_sw.hscrollbar_policy = Gtk4.PolicyType_NEVER
    chain_steps_box = GtkBox(:v)
    chain_sw[] = chain_steps_box
    push!(pipeline_panel, chain_sw)
    _W["chain_steps_box"] = chain_steps_box

    add_step_btn = GtkButton("+ Add Step")
    Gtk4.add_css_class(add_step_btn, "bspec-add-step")
    add_step_btn.margin_start = 16; add_step_btn.margin_end = 16
    add_step_btn.margin_top = 4;    add_step_btn.margin_bottom = 4
    signal_connect(add_step_btn, "clicked") do _ _add_chain_step!() end
    push!(pipeline_panel, add_step_btn)

    _W["pipeline_panel"] = pipeline_panel
    push!(left_outer, pipeline_panel)
    pipeline_panel.visible = false

    # ── Action bar: Spinner + Clear + Compute ────────────────────
    action_bar = GtkBox(:h)
    action_bar.spacing = 8
    Gtk4.add_css_class(action_bar, "bspec-action-bar")

    spinner_lbl = GtkLabel("Computing...")
    Gtk4.add_css_class(spinner_lbl, "bspec-spinner")
    spinner_lbl.hexpand = true
    spinner_lbl.halign  = Gtk4.Align_START
    spinner_lbl.visible = false
    _W["spinner_lbl"] = spinner_lbl

    clear_btn = GtkButton("Clear")
    Gtk4.add_css_class(clear_btn, "bspec-clear-btn")

    compute_btn = GtkButton("Compute →")
    Gtk4.add_css_class(compute_btn, "bspec-compute-btn")
    compute_btn.hexpand = true

    push!(action_bar, spinner_lbl)
    push!(action_bar, clear_btn)
    push!(action_bar, compute_btn)
    push!(left_outer, action_bar)

    _W["compute_btn"] = compute_btn
    _W["clear_btn"]   = clear_btn

    signal_connect(compute_btn, "clicked") do _ _on_compute!() end
    signal_connect(clear_btn,   "clicked") do _
        mode = _S["mode"]
        if mode == "command"
            buf = Gtk4.buffer(cmd_tv)
            buf.text = ""
        elseif mode == "form"
            for (_, e) in _S["param_entries"]
                e isa Vector ? foreach(x->x.text = "", e) : (e.text = "")
            end
        end
        buf = Gtk4.buffer(_W["result_tv"]::GtkTextView)
        buf.text = "\n  Cleared. Ready for next command.\n"
    end

    # ══ RIGHT PANEL ═══════════════════════════════════════════════
    right_box = GtkBox(:v)
    Gtk4.add_css_class(right_box, "bspec-right")
    right_box.hexpand = true; right_box.vexpand = true
    push!(main_box, right_box)

    notebook = GtkNotebook()
    notebook.vexpand = true; notebook.hexpand = true
    _W["notebook"] = notebook
    push!(right_box, notebook)

    # ── Results tab ──────────────────────────────────────────────
    result_sw = GtkScrolledWindow()
    result_sw.hexpand = true; result_sw.vexpand = true

    result_tv = GtkTextView()
    result_tv.editable = false; result_tv.cursor_visible = false
    result_tv.left_margin = 16; result_tv.right_margin = 16
    result_tv.top_margin = 16; result_tv.bottom_margin = 16
    result_tv.wrap_mode = Gtk4.WrapMode_WORD
    Gtk4.add_css_class(result_tv, "bspec-result-view")
    
    buf0 = Gtk4.buffer(result_tv)
    buf0.text = "\n  ⬡  B-SPEC Physical Engine  v2.1\n" *
        "  ────────────────────────────────────────────────────────────\n\n" *
        "  Select a solver from the Form Builder on the left,\n" *
        "  or switch to CLI Mode and type a command.\n\n" *
        "  EXAMPLE COMMANDS:\n" *
        "  get electric_field charge=1e-9 source=[0,0,0] field_point=[1,0,0]\n" *
        "  get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]\n" *
        "  get projectile_motion initial_velocity=50 angle_deg=45 initial_height=0\n" *
        "  get harmonic_oscillator mass=0.5 spring_constant=200 damping=0.8\n\n" *
        "  NATURAL LANGUAGE:\n" *
        "  Point charges of 1 nC and -2 nC at (0,0,0) and (1,1,1).\n" *
        "  Determine the vector force on each charge.\n"
    
    result_sw[] = result_tv
    _W["result_tv"] = result_tv
    push!(notebook, result_sw, "Results")

    # ── Visualization tab ────────────────────────────────────────
    viz_sw = GtkScrolledWindow()
    viz_sw.hexpand = true; viz_sw.vexpand = true

    viz_tv = GtkTextView()
    viz_tv.editable = false; viz_tv.cursor_visible = false
    viz_tv.left_margin = 16; viz_tv.right_margin = 16
    viz_tv.top_margin = 16; viz_tv.bottom_margin = 16
    Gtk4.add_css_class(viz_tv, "bspec-result-view")
    
    buf_viz = Gtk4.buffer(viz_tv)
    buf_viz.text = "\n  Run a solver to generate a visualization.\n"
    
    viz_sw[] = viz_tv
    _W["viz_tv"] = viz_tv
    push!(notebook, viz_sw, "Visualization")

    # ── History tab ──────────────────────────────────────────────
    hist_sw = GtkScrolledWindow()
    hist_sw.hexpand = true; hist_sw.vexpand = true
    hist_sw.hscrollbar_policy = Gtk4.PolicyType_NEVER

    history_box = GtkBox(:v)
    history_box.vexpand = true
    no_hist = GtkLabel("No queries executed yet.")
    Gtk4.add_css_class(no_hist, "bspec-desc-lbl")
    no_hist.margin_start = 16; no_hist.margin_top = 16
    no_hist.halign = Gtk4.Align_START
    push!(history_box, no_hist)
    hist_sw[] = history_box
    _W["history_box"] = history_box
    push!(notebook, hist_sw, "History")

    # ── Status bar ───────────────────────────────────────────────
    push!(root, GtkSeparator(:h))
    sb = GtkBox(:h)
    Gtk4.add_css_class(sb, "bspec-statusbar")

    function _make_sep() s = GtkLabel("  |  "); Gtk4.add_css_class(s,"bspec-desc-lbl"); s end

    dot_lbl = GtkLabel("●")
    dot_lbl.margin_start = 0; dot_lbl.margin_end = 6

    sb_q  = GtkLabel("Queries: 0")
    sb_e  = GtkLabel("Errors: 0")
    sb_l  = GtkLabel("Last: none")
    sb_t  = GtkLabel("Time: --")
    sb_m  = GtkLabel("Mode: command")

    for w in [dot_lbl, sb_q, _make_sep(), sb_e, _make_sep(),
              sb_l, _make_sep(), sb_t, _make_sep(), sb_m]
        push!(sb, w)
    end
    push!(root, sb)

    _W["sb_queries"] = sb_q; _W["sb_errors"] = sb_e
    _W["sb_last"]    = sb_l; _W["sb_time"]   = sb_t
    _W["sb_mode"]    = sb_m

    # ── Keyboard shortcut ───────────────────────────────────────
    key_ctrl = GtkEventControllerKey()
    push!(cmd_tv, key_ctrl) 
    signal_connect(key_ctrl, "key-pressed") do _, keyval, keycode, state
        is_ctrl  = (state & Gtk4.GLib.ModifierType_CONTROL_MASK) != 0
        is_enter = keyval in (Gtk4.GLib.keyval_from_name("Return"), Gtk4.GLib.keyval_from_name("KP_Enter"))
        is_ctrl && is_enter && _on_compute!()
        return false
    end

    return win
end

# ── Entry point ───────────────────────────────────────────────────

function main()
    println("\n" * "=" ^ 56)
    println("  B-SPEC  Desktop GUI  v2.1  (Gtk4.jl)")
    println("  Solvers : " * join(string.(_state.solvers_loaded), " | "))
    println("  Commands: " * string(length(SOLVER_REGISTRY)))
    println("=" ^ 56)
    println()

    _apply_css!()
    win = build_ui()

    _S["solver_meta"] = build_solver_metadata()
    _build_domain_combo!()
    _set_mode!("command")

    done = Condition()
    signal_connect(win, "close-request") do _
        notify(done)
        return false
    end

    win.visible = true
    println("  Window open. Close it to exit.")
    wait(done)
    println("\n  B-SPEC Desktop GUI closed.")
end

main()