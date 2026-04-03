# ================================================================
# FILE: core/engine.jl
#
# Engine — the master flow controller.
#
# This file defines the PIPELINE — how data moves.
# It does NOT contain physics, parsing rules, or routing logic.
# It orchestrates the three stages in order and handles the seams.
#
# Pipeline:
#   Raw Input
#     │
#     ▼ Stage 1 ── tokenizer.jl
#   PhysicalQuery
#     │
#     ▼ Stage 2 ── dispatcher.jl
#   SolverResult
#     │
#     ▼ Stage 3 ── format_output()
#   Formatted Output (stdout or returned String)
# ================================================================

using Printf

# ── Main entry point ─────────────────────────────────────────────────────────

"""
    process(input, state::EngineState) :: SolverResult

Full pipeline: tokenize → dispatch → return result.
Accepts either a String or Dict{String,Any} as input.
Updates EngineState metrics throughout.
Always returns a SolverResult — never throws to the caller.
"""


function process(input, state::EngineState) :: SolverResult
    !state.initialized && @warn "Engine.process called before initialization."

    state.query_count += 1
    label = "[Q#$(state.query_count)]"

    # ── Stage 1: Tokenize ────────────────────────────────────────────────
    query = try
        tokenize(input)
    catch e
        state.error_count += 1
        @error "$label Tokenizer failed." exception=e
        return failed_result(:unknown, :tokenizer,
            "Input could not be parsed: $(sprint(showerror, e))")
    end

    state.last_command = query.command
    @info "$label Tokenized successfully." command=query.command params=collect(keys(query.params))

    # ── Stage 2: Dispatch ────────────────────────────────────────────────
    result = dispatch(query)

    if result.success
        @info "$label Dispatch complete." command=result.command solver=result.solver_id
    else
        state.error_count += 1
        @warn "$label Dispatch returned failure." message=result.message
    end

    return result
end

# ── Output formatting ─────────────────────────────────────────────────────────

#=
    format_output(result::SolverResult; io::IO=stdout)

Render a SolverResult in a clean, readable format.
Physics values are shown with their units.
=#

function format_output(result::SolverResult; io::IO=stdout)
    bar = "─"^64

    if result.success
        println(io, "\n┌" * bar * "┐")
        println(io, ("│  ✓  Command   : :$(result.command)" *
                    "  │  Solver: :$(result.solver_id)" *
                    " "^max(0, 22 - length(string(result.command)) - length(string(result.solver_id))) * "│"))
        println(io, "│  ✎  $(result.message)" * " "^max(0, 63 - length(result.message)) * "│")
        println(io, "├" * bar * "┤")
        println(io, "│  Outputs:$(repeat(" ", 54))│")

        for (k, v) in sort(collect(result.outputs), by=x->string(x[1]))
            unit  = get(result.units, k, "?")
            key_s = rpad(string(k), 22)
            val_s = _fmt_value(v)
            row   = "│    $(key_s) = $(val_s)  [$(unit)]"
            if length(row) < 65
                row = row * repeat(" ", 65 - length(row)) * "│"
            else
                row = row[1:64] * "│"
            end
            println(io, row)
        end
        println(io, "└" * bar * "┘")
    else
        println(io, "\n┌" * bar * "┐")
        println(io, ("│  ✗  Command   : :$(result.command)" *
                    "  │  Solver: :$(result.solver_id)" *
                    " "^max(0, 22 - length(string(result.command)) -
                                      length(string(result.solver_id))) * "│"))
        println(io, "├" * bar * "┤")
        # Word-wrap the error message
        for line in _wrap_text("ERROR: " * result.message, 62)
            println(io, "│  $(rpad(line, 62))│")
        end
        println(io, "└" * bar * "┘")
    end
    println(io)
end

# Print a dashboard summary of the engine's runtime state.

function engine_status(state::EngineState)
    println("\n  ╔══════════════════════════════════╗")
    println("  ║   B-SPEC ENGINE STATUS           ║")
    println("  ╠══════════════════════════════════╣")
    println("  ║  Initialized  : $(state.initialized ? "yes" : "no ")              ║")
    println("  ║  Solvers      : $(join(state.solvers_loaded, ", "))" *
            " "^max(0, 18 - sum(length.(string.(state.solvers_loaded))) - 2*(length(state.solvers_loaded)-1)) * "  ║")
    println("  ║  Queries run  : $(state.query_count)" * " "^(18 - ndigits(state.query_count)) * "  ║")
    println("  ║  Errors       : $(state.error_count)" * " "^(18 - ndigits(state.error_count)) * "  ║")
    cmd_s = isnothing(state.last_command) ? "none" : string(state.last_command)
    println("  ║  Last command : :$(rpad(cmd_s, 17))  ║")
    println("  ╚══════════════════════════════════╝\n")
end

# ── Private formatting helpers ────────────────────────────────────────────────

# Format a value for display: vectors get rounded brackets, scalars sig-figs

function _fmt_value(v)::String
    if v isa Vector
        return "[" * join([@sprintf("%.6g", x) for x in v], ", ") * "]"
    elseif v isa AbstractFloat
        return @sprintf("%.6g", v)
    elseif v isa Bool
        return string(v)
    else
        return string(v)
    end
end

# Wrap text to a given width, splitting on spaces

function _wrap_text(text::String, width::Int)::Vector{String}
    words  = split(text)
    lines  = String[]
    line   = IOBuffer()
    col    = 0
    for (i, word) in enumerate(words)
        w = length(word)
        if col + w + (col > 0 ? 1 : 0) > width
            push!(lines, String(take!(line)))
            write(line, word)
            col = w
        else
            col > 0 && write(line, ' ')
            write(line, word)
            col += w + (col > 0 ? 1 : 0)
        end
    end
    s = String(take!(line))
    isempty(s) || push!(lines, s)
    lines
end

# Printf needed for _fmt_value
using Printf
