# ================================================================
# FILE: core/engine.jl
#
# Engine — the master flow controller.
#
# v2.3 PIPELINE UPDATE:
#
#   Raw Input
#     │
#     ▼ detect_input_mode()          ← NEW: classify input type
#     │
#     ├─── :command ──▶ tokenize()   ← existing structured path
#     │
#     └─── :natural ──▶ parse_natural_language()   ← NEW NLP path
#                         │
#                         ▼ NLPParseResult
#                         │
#                         ▼ _nlp_to_query()         ← convert to PhysicalQuery
#     │
#     ▼ dispatch(PhysicalQuery)
#     │
#     ▼ SolverResult
#     │
#     ▼ format_output()
#
# The engine NEVER knows about physics. It only controls flow.
# ================================================================

using Printf

# ── Main entry point ─────────────────────────────────────────────

"""
    process(input, state::EngineState) :: SolverResult

Full pipeline: detect mode → parse/tokenize → dispatch → return.
Accepts String, Dict{String,Any}, or any other structured input.
Always returns a SolverResult — never throws to the caller.
"""
function process(input, state::EngineState)::SolverResult
    !state.initialized && @warn "Engine.process called before initialization."

    state.query_count += 1
    label = "[Q#$(state.query_count)]"

    # ── Route based on input type ────────────────────────────────
    if input isa String
        mode = detect_input_mode(input)
        @info "$label Input mode: $mode"

        if mode == :natural
            return _process_natural(input, state, label)
        end
    end

    # ── Standard command path ────────────────────────────────────
    query = try
        tokenize(input)
    catch e
        state.error_count += 1
        @error "$label Tokenizer failed." exception=e
        return failed_result(:unknown, :tokenizer,
            "Could not parse input.\n\n" *
            "  Error: $(sprint(showerror, e))\n\n" *
            "  Command format: get <solver> key=value key=value\n" *
            "  Example: get coulomb_force q1=1e-9 q2=-2e-9 r1=[0,0,0] r2=[0.05,0,0]\n\n" *
            "  Or type a physics problem in plain English:\n" *
            "  \"Point charges of 1 nC and -2 nC are at (0,0,0) and (1,1,1). Find the force.\"")
    end

    state.last_command = query.command
    @info "$label Tokenized." command=query.command params=collect(keys(query.params))

    result = dispatch(query)
    _update_state!(state, result, label)
    return result
end

# ── Natural language processing path ─────────────────────────────

function _process_natural(input::String, state::EngineState, label::String)::SolverResult
    @info "$label Routing to NLP parser."

    # Stage 1: Parse natural language
    nlp = try
        parse_natural_language(input)
    catch e
        state.error_count += 1
        @error "$label NLP parser crashed." exception=e
        return failed_result(:unknown, :nlp_parser,
            "NLP parser error: $(sprint(showerror, e))")
    end

    # Always surface the parse log to the user via the result message
    log_text = join(nlp.parse_log, "\n")

    # Stage 2: Handle partial parse (missing params)
    if nlp.partial || !nlp.success
        state.error_count += 1

        reason = nlp.partial ? nlp.partial_reason :
                 "Could not determine the problem type."

        msg = "NLP Parser — problem understood but parameters incomplete.\n\n" *
              "  Problem type : $(nlp.problem_type)\n" *
              "  Intent       : $(nlp.intent)\n" *
              "  Missing      : $(reason)\n\n" *
              "  What was extracted:\n" *
              join(["  " * l for l in nlp.parse_log
                    if startswith(l, "  ") || startswith(l, "Quant") ||
                       startswith(l, "Posit") || startswith(l, "Param")], "\n") *
              "\n\n  Tip: Switch to command mode for complete control:\n" *
              "  get $(nlp.solver) param=value ..."

        return failed_result(nlp.solver, :nlp_parser, msg)
    end

    # Stage 3: Build PhysicalQuery from NLP result
    query = PhysicalQuery(nlp.solver, nlp.params, input)
    state.last_command = nlp.solver
    @info "$label NLP parse success." solver=nlp.solver params=collect(keys(nlp.params))

    # Stage 4: Dispatch
    result = dispatch(query)

    # Attach parse log to message so the UI can show what was understood
    enriched_msg = result.message *
        "\n\n── NLP Parse Report ────────────────────────────────────\n" *
        "  Problem : $(nlp.problem_type)\n" *
        "  Intent  : $(nlp.intent)\n" *
        join(["  " * l for l in nlp.parse_log
              if startswith(l, "  ") &&
                 (contains(l, "→") || contains(l, "assembled") || contains(l, "✓"))], "\n")

    # Build enriched result
    enriched = SolverResult(result.command, result.outputs, result.units,
                            result.solver_id, result.success, enriched_msg)

    _update_state!(state, enriched, label)
    return enriched
end

function _update_state!(state::EngineState, result::SolverResult, label::String)
    if result.success
        @info "$label Dispatch complete." command=result.command solver=result.solver_id
    else
        state.error_count += 1
        @warn "$label Dispatch returned failure." message=result.message
    end
end

# ── Output formatting ─────────────────────────────────────────────

"""Render a SolverResult in a clean, readable terminal format."""
function format_output(result::SolverResult; io::IO=stdout)
    bar = "─"^64

    if result.success
        println(io, "\n┌" * bar * "┐")
        println(io, "│  ✓  :$(rpad(string(result.command),24)) " *
                    "solver: :$(rpad(string(result.solver_id),14))│")
        println(io, "├" * bar * "┤")
        println(io, "│  Outputs:" * " "^54 * "│")
        for (k, v) in sort(collect(result.outputs), by=x->string(x[1]))
            unit  = get(result.units, k, "?")
            row   = "│    $(rpad(string(k),22)) = $(_fmt_value(v))  [$unit]"
            println(io, length(row) < 65 ? row * " "^(65-length(row)) * "│" : row[1:64]*"│")
        end
        println(io, "├" * bar * "┤")
        for line in _wrap_text("✎  " * result.message, 62)
            println(io, "│  $(rpad(line, 62))│")
        end
        println(io, "└" * bar * "┘")
    else
        println(io, "\n┌" * bar * "┐")
        println(io, "│  ✗  :$(rpad(string(result.command),24)) " *
                    "solver: :$(rpad(string(result.solver_id),14))│")
        println(io, "├" * bar * "┤")
        for line in _wrap_text("ERROR: " * result.message, 62)
            println(io, "│  $(rpad(line, 62))│")
        end
        println(io, "└" * bar * "┘")
    end
    println(io)
end

"""Print engine runtime status."""
function engine_status(state::EngineState)
    println("\n  ╔══════════════════════════════════╗")
    println("  ║   B-SPEC ENGINE STATUS           ║")
    println("  ╠══════════════════════════════════╣")
    println("  ║  Initialized  : $(rpad(state.initialized ? "yes" : "no", 18))  ║")
    println("  ║  Solvers      : $(rpad(join(string.(state.solvers_loaded),", "),18))  ║")
    println("  ║  Queries run  : $(rpad(state.query_count,18))  ║")
    println("  ║  Errors       : $(rpad(state.error_count,18))  ║")
    cmd_s = isnothing(state.last_command) ? "none" : string(state.last_command)
    println("  ║  Last command : :$(rpad(cmd_s, 17))  ║")
    println("  ╚══════════════════════════════════╝\n")
end

# ── Private helpers ───────────────────────────────────────────────

function _fmt_value(v)::String
    v isa Vector       && return "[" * join([@sprintf("%.6g",x) for x in v],", ") * "]"
    v isa AbstractFloat && return @sprintf("%.6g", v)
    v isa Bool         && return string(v)
    string(v)
end

function _wrap_text(text::String, width::Int)::Vector{String}
    words = split(text); lines = String[]; line = IOBuffer(); col = 0
    for word in words
        w = length(word)
        if col + w + (col>0 ? 1 : 0) > width
            push!(lines, String(take!(line))); write(line, word); col = w
        else
            col > 0 && write(line, ' '); write(line, word); col += w + (col>0 ? 1 : 0)
        end
    end
    s = String(take!(line)); isempty(s) || push!(lines, s)
    lines
end