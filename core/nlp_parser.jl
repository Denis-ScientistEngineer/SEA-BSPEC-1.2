# ================================================================
# FILE: core/nlp_parser.jl
#
# Natural Language Physics Parser  (B-SPEC v2.3)
#
# PURPOSE:
#   Accept raw physics problem text exactly as written in a textbook
#   or typed by a user, and convert it into a structured PhysicalQuery
#   that can be dispatched to the correct solver.
#
# SUPPORTED INPUT STYLES:
#   1. Textbook problem text (copy-paste from PDF/book)
#   2. Manually typed prose ("A 5 nC charge is at the origin...")
#   3. Mixed metric notation ("3 cm", "−10 nC", "at (1, 0, 0)")
#
# PIPELINE:
#   raw text
#     │
#     ▼ normalize_text()       — fix Unicode, dashes, spaces
#     ▼ extract_quantities()   — find all number+unit pairs, convert SI
#     ▼ extract_positions()    — find all coordinate/point specs
#     ▼ detect_problem_type()  — what kind of physics is this?
#     ▼ detect_intent()        — what does the problem want computed?
#     ▼ assemble_params()      — build the params dict for the solver
#     ▼ NLPParseResult         — structured result with parse log
#
# IMPORTANT:
#   The NLP parser NEVER calls solvers directly.
#   It returns an NLPParseResult which the engine uses to build
#   a PhysicalQuery and hand it to the Dispatcher.
# ================================================================

using Printf

# ── Types ────────────────────────────────────────────────────────

"""
One physical quantity extracted from the problem text.
Carries both raw and SI values for transparency.
"""
struct ExtractedQuantity
    raw_value :: Float64   # as written in the text
    raw_unit  :: String    # as written in the text (e.g. "nC", "cm")
    si_value  :: Float64   # converted to SI
    si_unit   :: String    # SI unit (e.g. "C", "m")
    kind      :: Symbol    # :charge, :distance, :force, :mass, :velocity,
                           # :energy, :angle, :voltage, :spring_k, :unknown
    context   :: String    # surrounding text snippet (for disambiguation)
end

"""
One spatial position extracted from the problem text.
Always stored as a 3-element Float64 vector in SI (meters).
"""
struct ExtractedPosition
    coords :: Vector{Float64}   # [x, y, z] in metres
    raw    :: String             # original text e.g. "(0, 0, 0)" or "y = 5 cm"
    label  :: Union{String, Nothing}  # named point label e.g. "A", "B"
end

"""
Full result of the NLP parsing stage.
Returned to the engine which uses it to build a PhysicalQuery.
"""
struct NLPParseResult
    success        :: Bool
    solver         :: Symbol              # best matching solver command
    params         :: Dict{Symbol, Any}   # assembled parameters ready for dispatch
    parse_log      :: Vector{String}      # step-by-step extraction transcript
    problem_type   :: String              # human-readable problem description
    intent         :: String              # what is being asked
    partial        :: Bool                # true if not fully mappable to a solver
    partial_reason :: String              # explanation if partial
end

# ── SI Unit conversion table ──────────────────────────────────────
# Maps lowercase(unit_string) → (SI_unit, multiplier)
# SI_value = raw_value × multiplier

const NLP_UNITS = Dict{String, Tuple{String, Float64, Symbol}}(
    # col 3 = quantity kind

    # ── Charge ────────────────────────────────────
    "pc"     => ("C",       1e-12,  :charge),
    "nc"     => ("C",       1e-9,   :charge),
    "uc"     => ("C",       1e-6,   :charge),
    "μc"     => ("C",       1e-6,   :charge),
    "mc"     => ("C",       1e-3,   :charge),
    "c"      => ("C",       1.0,    :charge),
    "kc"     => ("C",       1e3,    :charge),

    # ── Distance ──────────────────────────────────
    "pm"     => ("m",       1e-12,  :distance),
    "nm"     => ("m",       1e-9,   :distance),
    "μm"     => ("m",       1e-6,   :distance),
    "um"     => ("m",       1e-6,   :distance),
    "mm"     => ("m",       1e-3,   :distance),
    "cm"     => ("m",       1e-2,   :distance),
    "dm"     => ("m",       0.1,    :distance),
    "m"      => ("m",       1.0,    :distance),
    "km"     => ("m",       1e3,    :distance),

    # ── Force ─────────────────────────────────────
    "pn"     => ("N",       1e-12,  :force),
    "nn"     => ("N",       1e-9,   :force),
    "μn"     => ("N",       1e-6,   :force),
    "un"     => ("N",       1e-6,   :force),
    "mn"     => ("N",       1e-3,   :force),
    "n"      => ("N",       1.0,    :force),
    "kn"     => ("N",       1e3,    :force),

    # ── Voltage / Potential ───────────────────────
    "μv"     => ("V",       1e-6,   :voltage),
    "uv"     => ("V",       1e-6,   :voltage),
    "mv"     => ("V",       1e-3,   :voltage),
    "v"      => ("V",       1.0,    :voltage),
    "kv"     => ("V",       1e3,    :voltage),
    "megav"  => ("V",       1e6,    :voltage),

    # ── Energy / Work ─────────────────────────────
    "nj"     => ("J",       1e-9,   :energy),
    "μj"     => ("J",       1e-6,   :energy),
    "uj"     => ("J",       1e-6,   :energy),
    "mj"     => ("J",       1e-3,   :energy),
    "j"      => ("J",       1.0,    :energy),
    "kj"     => ("J",       1e3,    :energy),

    # ── Capacitance ───────────────────────────────
    "pf"     => ("F",       1e-12,  :capacitance),
    "nf"     => ("F",       1e-9,   :capacitance),
    "μf"     => ("F",       1e-6,   :capacitance),
    "uf"     => ("F",       1e-6,   :capacitance),
    "mf"     => ("F",       1e-3,   :capacitance),
    "f"      => ("F",       1.0,    :capacitance),

    # ── Mass ──────────────────────────────────────
    "μg"     => ("kg",      1e-9,   :mass),
    "ug"     => ("kg",      1e-9,   :mass),
    "mg"     => ("kg",      1e-6,   :mass),
    "g"      => ("kg",      1e-3,   :mass),
    "kg"     => ("kg",      1.0,    :mass),
    "tonnes" => ("kg",      1e3,    :mass),

    # ── Velocity ──────────────────────────────────
    "m/s"    => ("m/s",     1.0,    :velocity),
    "km/s"   => ("m/s",     1e3,    :velocity),
    "cm/s"   => ("m/s",     0.01,   :velocity),
    "km/h"   => ("m/s",     1.0/3.6, :velocity),
    "mph"    => ("m/s",     0.44704, :velocity),

    # ── Acceleration ──────────────────────────────
    "m/s2"   => ("m/s²",   1.0,    :acceleration),
    "m/s²"   => ("m/s²",   1.0,    :acceleration),
    "cm/s2"  => ("m/s²",   0.01,   :acceleration),

    # ── Angle ─────────────────────────────────────
    "deg"    => ("°",       1.0,    :angle),
    "°"      => ("°",       1.0,    :angle),
    "rad"    => ("rad",     1.0,    :angle),

    # ── Frequency ─────────────────────────────────
    "hz"     => ("Hz",      1.0,    :frequency),
    "khz"    => ("Hz",      1e3,    :frequency),
    "mhz"    => ("Hz",      1e6,    :frequency),
    "ghz"    => ("Hz",      1e9,    :frequency),

    # ── Spring constant ───────────────────────────
    "n/m"    => ("N/m",     1.0,    :spring_k),
    "kn/m"   => ("N/m",     1e3,    :spring_k),
    "mn/m"   => ("N/m",     1e-3,   :spring_k),

    # ── Electric field ────────────────────────────
    "n/c"    => ("N/C",     1.0,    :e_field),
    "v/m"    => ("N/C",     1.0,    :e_field),
    "kv/m"   => ("N/C",     1e3,    :e_field),
    "mv/m"   => ("N/C",     1e6,    :e_field),
)

# Units that must NOT be consumed as standalone letters
# (prevent matching "a" in "at" or "m" in "mass")
const UNIT_BOUNDARY_REQUIRED = ("m", "n", "v", "j", "f", "c")

# ── Text normalisation ────────────────────────────────────────────

"""
Normalise raw input text:
  - Replace Unicode minus/dash variants with ASCII -
  - Replace Unicode μ/micro with u
  - Normalise whitespace
  - Lowercase for parsing (return both original and normalised)
"""
function _normalise(raw::AbstractString)::Tuple{String, String}
    s = String(raw)
    # Unicode dash variants → ASCII minus
    s = replace(s,
        "\u2212" => "-",   # −  MINUS SIGN
        "\u2013" => "-",   # –  EN DASH
        "\u2014" => "-",   # —  EM DASH
        "\u00B7" => ".",   # ·  MIDDLE DOT (used in some unit notations)
        "\u00D7" => "*",   # ×  MULTIPLICATION SIGN
    )
    # Unicode micro/mu → u (for μC, μF, μm etc.)
    s = replace(s, "μ" => "u", "µ" => "u")
    # Degree symbol variants
    s = replace(s, "\u00B0" => "°")
    # Normalise whitespace
    s = replace(s, r"\s+" => " ")
    orig = strip(s)
    return (orig, lowercase(orig))
end

# ── Number extraction ─────────────────────────────────────────────

# Matches: optional sign, integer or decimal, optional exponent
# Examples: -2.5, 1e-9, 3.14, +50, 0.05
const NUM_RE = r"(?<![a-zA-Z])(-?\s*(?:\d+\.?\d*|\d*\.\d+)(?:[eE][+-]?\d+)?)"

"""Extract all numeric values from text, returning (value, start_idx, end_idx)."""
function _extract_numbers(s::String)::Vector{Tuple{Float64, Int, Int}}
    results = Tuple{Float64, Int, Int}[]
    for m in eachmatch(NUM_RE, s)
        val_str = replace(m.captures[1], " " => "")
        v = tryparse(Float64, val_str)
        !isnothing(v) && push!(results, (v, m.offset, m.offset + length(m.match) - 1))
    end
    return results
end

# ── Unit matching ─────────────────────────────────────────────────

"""
Given text starting right after a number (at `pos`), look ahead for a unit.
Returns (unit_str, SI_unit, multiplier, kind, consumed_length) or nothing.
Units must be preceded by optional whitespace and followed by a word boundary.
"""
function _match_unit(text_lc::String, pos::Int)::Union{Tuple{String,String,Float64,Symbol,Int}, Nothing}
    # Skip leading whitespace (but not too much — max 2 spaces)
    i = pos
    spaces = 0
    while i <= length(text_lc) && text_lc[i] == ' ' && spaces < 2
        i += 1; spaces += 1
    end
    i > length(text_lc) && return nothing

    # Try longest units first to avoid "n" matching before "nc"
    candidate_units = sort(collect(keys(NLP_UNITS)), by = length, rev = true)

    for unit in candidate_units
        ulen = length(unit)
        i + ulen - 1 > length(text_lc) && continue
        substr = text_lc[i:i+ulen-1]
        substr != unit && continue

        # Check word boundary after unit (not followed by another letter/digit)
        after = i + ulen
        if after <= length(text_lc)
            next_ch = text_lc[after]
            # Allow °, ², /, space, comma, period, ), \n after unit
            isalpha = isletter(next_ch) || isdigit(next_ch)
            # Exception: compound units like m/s, N/m, N/C
            if isalpha && next_ch != '/'
                continue
            end
        end

        si_unit, mult, kind = NLP_UNITS[unit]
        consumed = (i - pos) + ulen   # spaces + unit
        return (unit, si_unit, mult, kind, consumed)
    end
    return nothing
end

# ── Quantity extraction ───────────────────────────────────────────

"""
Extract all physical quantities from normalised text.
Returns a list of ExtractedQuantity structs.
"""
function extract_quantities(orig::String, lc::String)::Vector{ExtractedQuantity}
    results    = ExtractedQuantity[]
    numbers    = _extract_numbers(lc)
    used_spans = Set{Tuple{Int,Int}}()  # prevent double-counting

    for (val, n_start, n_end) in numbers
        # Skip if this span overlaps with an already-extracted one
        any(s -> s[1] <= n_start <= s[2], used_spans) && continue

        # Look for unit right after number
        result = _match_unit(lc, n_end + 1)
        isnothing(result) && continue

        unit_raw, si_unit, mult, kind, consumed = result
        si_val  = val * mult

        # Context snippet: 20 chars either side
        ctx_start = max(1, n_start - 20)
        ctx_end   = min(length(orig), n_end + consumed + 20)
        context   = strip(orig[ctx_start:ctx_end])

        push!(results, ExtractedQuantity(val, unit_raw, si_val, si_unit, kind, context))
        push!(used_spans, (n_start, n_end + consumed))
    end

    return results
end

# ── Position extraction ───────────────────────────────────────────

"""
Extract all spatial positions from text. Handles:
  1. Tuple notation:        (0, 0, 0) or (1, 1, 1)
  2. Named point:           A(1, 0, 0) or A (1,0,0)
  3. Component form:        x = 1 m, y = -5 cm
  4. "at the origin"        → [0, 0, 0]
  5. "at x = 5 cm"          → [0.05, 0, 0]
  6. "at y = -5 cm"         → [0, -0.05, 0]
  7. "free space at origin" → [0, 0, 0]
"""
function extract_positions(orig::String, lc::String)::Vector{ExtractedPosition}
    positions = ExtractedPosition[]

    # ── Pattern 1 & 2: tuple (x, y, z) or (x, y) with optional label ──
    # Captures optional label like "A", numbers with optional units inside parens
    tuple_re = r"([A-Za-z])?\s*\(\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*,\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*(?:,\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*)?\)"

    for m in eachmatch(tuple_re, orig)
        label  = isnothing(m.captures[1]) ? nothing : String(m.captures[1])
        xv     = tryparse(Float64, replace(String(m.captures[2]), " " => ""))
        yv     = tryparse(Float64, replace(String(m.captures[3]), " " => ""))
        zv     = isnothing(m.captures[4]) ? 0.0 :
                 something(tryparse(Float64, replace(String(m.captures[4]), " " => "")), 0.0)

        (isnothing(xv) || isnothing(yv)) && continue

        coords = [xv, yv, zv]
        push!(positions, ExtractedPosition(coords, m.match, label))
    end

    # ── Pattern 3: "at the origin" ────────────────────────────────
    if occursin(r"\b(at\s+the\s+origin|at\s+origin|the\s+origin)\b", lc)
        push!(positions, ExtractedPosition([0.0, 0.0, 0.0], "at the origin", nothing))
    end

    # ── Pattern 4: component form "at x = -5 cm" / "at y = 5 cm" ──
    comp_re = r"at\s+([xyz])\s*=\s*(-?[\d.]+(?:[eE][+-]?\d+)?)\s*(cm|mm|m|km|μm|um|nm)?"
    component_positions = Dict{String, Tuple{Float64, String}}()

    for m in eachmatch(comp_re, lc)
        axis     = String(m.captures[1])
        val      = tryparse(Float64, replace(String(m.captures[2]), " " => ""))
        isnothing(val) && continue
        unit_str = isnothing(m.captures[3]) ? "m" : String(m.captures[3])
        mult     = haskey(NLP_UNITS, unit_str) ? NLP_UNITS[unit_str][2] : 1.0
        component_positions[axis] = (val * mult, m.match)
    end

    # Build positions from components (each axis found becomes a separate position)
    if !isempty(component_positions)
        for (axis, (si_val, raw)) in component_positions
            x = axis == "x" ? si_val : 0.0
            y = axis == "y" ? si_val : 0.0
            z = axis == "z" ? si_val : 0.0
            push!(positions, ExtractedPosition([x, y, z], raw, nothing))
        end
    end

    return positions
end

# ── Problem type detection ────────────────────────────────────────

"""
Detect the physics domain and what the problem is about.
Returns (domain, intent_description, solver_command).
"""
function detect_problem_type(lc::String, quantities::Vector{ExtractedQuantity},
                              positions::Vector{ExtractedPosition})::Tuple{Symbol, String, Symbol}

    charges   = [q for q in quantities if q.kind == :charge]
    masses    = [q for q in quantities if q.kind == :mass]
    n_charges = length(charges)
    n_pos     = length(positions)

    # ── Electromagnetics ──────────────────────────────────────────
    if n_charges > 0
        # Force between charges
        if occursin(r"\b(force|forces)\b", lc) && !occursin(r"(gravitational|spring|centripetal)", lc)
            if n_charges >= 2
                return (:electromagnetics, "Coulomb force between point charges", :coulomb_force)
            end
        end

        # Electric field
        if occursin(r"\belectric\s+field\b", lc)
            if n_charges >= 2 || n_pos >= 2
                return (:electromagnetics, "Electric field from multiple point charges (superposition)", :electric_field_superposition)
            end
            return (:electromagnetics, "Electric field of a point charge", :electric_field)
        end

        # Electric potential / voltage
        if occursin(r"\b(potential|voltage)\b", lc)
            return (:electromagnetics, "Electric potential of a point charge", :electric_potential)
        end

        # Flux
        if occursin(r"\b(flux)\b", lc)
            return (:electromagnetics, "Electric flux through a surface", :electric_flux)
        end

        # Capacitor
        if occursin(r"\bcapacitor\b", lc)
            return (:electromagnetics, "Capacitor energy / charge", :capacitor_energy)
        end

        # Default: if only one charge + one position → electric field
        if n_charges == 1 && n_pos >= 2
            return (:electromagnetics, "Electric field of a point charge", :electric_field)
        end

        # Two charges, positions given → Coulomb force
        if n_charges == 2 && n_pos == 2
            return (:electromagnetics, "Coulomb force between two point charges", :coulomb_force)
        end

        # Multiple charges → superposition
        if n_charges >= 2 && n_pos >= n_charges
            if occursin(r"\bforce\b", lc)
                return (:electromagnetics, "Superposition of Coulomb forces", :coulomb_force_superposition)
            end
            return (:electromagnetics, "Electric field superposition", :electric_field_superposition)
        end
    end

    # ── Classical mechanics ───────────────────────────────────────
    if occursin(r"\bspring\b|\boscillat", lc)
        return (:classical_mechanics, "Harmonic oscillator", :harmonic_oscillator)
    end

    if occursin(r"\bcircular\b|\bcentripetal\b", lc)
        return (:classical_mechanics, "Circular motion", :circular_motion)
    end

    if occursin(r"\bprojectile\b|\blaunch\b|\bthrow\b|\bangle\b", lc) &&
       !occursin(r"\bcharge\b|\belectric\b", lc)
        return (:classical_mechanics, "Projectile motion", :projectile_motion)
    end

    if occursin(r"\bcollision\b|\belastic\b", lc)
        return (:classical_mechanics, "Elastic collision", :elastic_collision)
    end

    if occursin(r"\bgravitation\b|\bnewton.s law of gravit\b", lc)
        return (:classical_mechanics, "Gravitational force", :gravitational_force)
    end

    if !isempty(masses) && occursin(r"\baccelerat", lc)
        return (:classical_mechanics, "Newton's second law", :newtons_second_law)
    end

    if !isempty(masses) && occursin(r"\bvelocity\b|\bspeed\b|\bkinetic\b", lc)
        return (:classical_mechanics, "Kinetic energy", :kinetic_energy)
    end

    return (:unknown, "Could not determine problem type", :unknown)
end

# ── Intent extraction ────────────────────────────────────────────

"""
Extract what the problem is asking us to compute.
"""
function detect_intent(lc::String)::String
    if occursin(r"\b(find|determine|calculate|compute|what is|evaluate)\b", lc)
        # Look at what follows the find keyword
        m = match(r"\b(?:find|determine|calculate|compute|evaluate)\b\s+(?:the\s+)?(.{3,60}?)(?:\.|$|\n|at\s+)", lc)
        if !isnothing(m)
            target = strip(m.captures[1])
            target = replace(target, r"\s+" => " ")
            return "Find: " * target
        end
        return "Find the requested quantity"
    end
    return "Compute the relevant physics"
end

# ── Parameter assembly ────────────────────────────────────────────

"""
Assemble params dict for the detected solver.
Returns (params, partial, partial_reason).
"""
function assemble_params(
    solver       :: Symbol,
    quantities   :: Vector{ExtractedQuantity},
    positions    :: Vector{ExtractedPosition},
    lc           :: String
)::Tuple{Dict{Symbol,Any}, Bool, String}

    params = Dict{Symbol, Any}()
    charges  = [q for q in quantities if q.kind == :charge]
    masses   = [q for q in quantities if q.kind == :mass]
    forces   = [q for q in quantities if q.kind == :force]
    vels     = [q for q in quantities if q.kind == :velocity]
    energies = [q for q in quantities if q.kind == :energy]
    angles   = [q for q in quantities if q.kind == :angle]
    dists    = [q for q in quantities if q.kind == :distance]
    springks = [q for q in quantities if q.kind == :spring_k]
    caps     = [q for q in quantities if q.kind == :capacitance]
    volts    = [q for q in quantities if q.kind == :voltage]

    # ── coulomb_force ─────────────────────────────────────────────
    if solver == :coulomb_force
        length(charges) >= 2 || return (params, true,
            "Need exactly 2 charges for Coulomb force. Found: $(length(charges))")
        length(positions) >= 2 || return (params, true,
            "Need 2 position vectors. Found: $(length(positions)) positions.")
        params[:q1] = charges[1].si_value
        params[:q2] = charges[2].si_value
        params[:r1] = positions[1].coords
        params[:r2] = positions[2].coords
        return (params, false, "")
    end

    # ── electric_field (single charge) ────────────────────────────
    if solver == :electric_field
        isempty(charges) && return (params, true, "No charge found in problem text.")
        params[:charge] = charges[1].si_value

        # Find source and field_point from positions
        if length(positions) >= 2
            params[:source]      = positions[1].coords
            params[:field_point] = positions[2].coords
        elseif length(positions) == 1
            # If only one position, assume source at origin and given pos is field point
            params[:source]      = [0.0, 0.0, 0.0]
            params[:field_point] = positions[1].coords
        else
            return (params, true,
                "Need source position and field point. No positions found.")
        end
        return (params, false, "")
    end

    # ── electric_field_superposition ──────────────────────────────
    if solver == :electric_field_superposition
        length(charges) < 2 && return (params, true,
            "Need at least 2 charges for superposition. Found $(length(charges)).")

        # Determine if one charge value applies to all (e.g. "50 nC each")
        # Heuristic: if unique charge count < position count, it's "each"
        unique_charges = unique(c.si_value for c in charges)
        all_charge_vals = if length(unique_charges) == 1 && length(positions) > 1 && length(positions) > length(charges)
            # "each" pattern — one charge value for multiple positions
            fill(charges[1].si_value, length(positions))
        else
            [c.si_value for c in charges]
        end

        n = min(length(all_charge_vals), length(positions))
        n < 2 && return (params, true,
            "Could not match charges to positions. Charges: $(length(charges)), Positions: $(length(positions))")

        # Identify field point (usually the last position or "at the origin")
        origin_pos = findfirst(p -> p.coords ≈ [0.0, 0.0, 0.0] && p.raw == "at the origin", positions)

        if !isnothing(origin_pos)
            fp = positions[origin_pos].coords
            src_idxs = setdiff(1:length(positions), [origin_pos])
        else
            # Last position is field point, rest are sources
            fp = positions[end].coords
            src_idxs = 1:length(positions)-1
        end

        n_src = min(length(src_idxs), length(all_charge_vals))
        params[:charges]     = all_charge_vals[1:n_src]
        params[:sources]     = [positions[i].coords for i in src_idxs[1:n_src]]
        params[:field_point] = fp
        return (params, false, "")
    end

    # ── coulomb_force_superposition ────────────────────────────────
    if solver == :coulomb_force_superposition
        isempty(charges) && return (params, true, "No charges found.")
        isempty(positions) && return (params, true, "No positions found.")

        # "each" pattern: one charge value, multiple positions
        unique_ch = unique(c.si_value for c in charges)
        n_pos = length(positions)

        all_ch = if length(unique_ch) == 1 && n_pos > length(charges)
            fill(charges[1].si_value, n_pos)
        else
            [c.si_value for c in charges]
        end

        n = min(length(all_ch), n_pos)
        n < 2 && return (params, true, "Need at least 2 charges and positions.")

        # Determine which is the target charge
        # Look for "force on the charge at A" or "force on the charge at (x,y,z)"
        target_label = nothing
        m = match(r"force\s+on\s+(?:the\s+)?(?:charge\s+)?(?:at\s+)?([A-Z])\b", orig_stored[])
        if !isnothing(m)
            target_label = String(m.captures[1])
        end

        target_idx = if !isnothing(target_label)
            findfirst(p -> !isnothing(p.label) && p.label == target_label, positions[1:n])
        else
            1  # default: first charge
        end
        isnothing(target_idx) && (target_idx = 1)

        params[:target_charge]   = all_ch[target_idx]
        params[:target_position] = positions[target_idx].coords
        params[:other_charges]   = [all_ch[i] for i in 1:n if i != target_idx]
        params[:other_positions] = [positions[i].coords for i in 1:n if i != target_idx]
        return (params, false, "")
    end

    # ── electric_potential ────────────────────────────────────────
    if solver == :electric_potential
        isempty(charges) && return (params, true, "No charge found.")
        params[:charge] = charges[1].si_value
        if length(positions) >= 2
            params[:source]      = positions[1].coords
            params[:field_point] = positions[2].coords
        elseif length(positions) == 1
            params[:source]      = [0.0, 0.0, 0.0]
            params[:field_point] = positions[1].coords
        else
            return (params, true, "Need at least one position.")
        end
        return (params, false, "")
    end

    # ── capacitor_energy ──────────────────────────────────────────
    if solver == :capacitor_energy
        !isempty(caps) && (params[:capacitance] = caps[1].si_value)
        !isempty(volts) && (params[:voltage]     = volts[1].si_value)
        !isempty(energies) && (params[:energy]   = energies[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need at least 2 of: capacitance, voltage, energy.")
    end

    # ── projectile_motion ─────────────────────────────────────────
    if solver == :projectile_motion
        !isempty(vels)   && (params[:initial_velocity] = vels[1].si_value)
        !isempty(angles) && (params[:angle_deg]        = angles[1].si_value)
        !isempty(dists)  && (params[:initial_height]   = dists[1].si_value)
        haskey(params, :initial_height) || (params[:initial_height] = 0.0)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need initial velocity and launch angle.")
    end

    # ── harmonic_oscillator ───────────────────────────────────────
    if solver == :harmonic_oscillator
        !isempty(masses)   && (params[:mass]            = masses[1].si_value)
        !isempty(springks) && (params[:spring_constant] = springks[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need mass and spring constant.")
    end

    # ── newtons_second_law ────────────────────────────────────────
    if solver == :newtons_second_law
        !isempty(masses) && (params[:mass] = masses[1].si_value)
        !isempty(forces) && (params[:force] = forces[1].si_value)
        # Check for acceleration in text
        m = match(r"(\d+\.?\d*)\s*m/s[²2]", lc)
        if !isnothing(m)
            a = tryparse(Float64, m.captures[1])
            !isnothing(a) && (params[:acceleration] = a)
        end
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need at least 2 of: force, mass, acceleration.")
    end

    # ── kinetic_energy ────────────────────────────────────────────
    if solver == :kinetic_energy
        !isempty(masses) && (params[:mass]     = masses[1].si_value)
        !isempty(vels)   && (params[:velocity] = vels[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need mass and velocity.")
    end

    # ── elastic_collision ─────────────────────────────────────────
    if solver == :elastic_collision
        length(masses) >= 2 && (params[:m1] = masses[1].si_value; params[:m2] = masses[2].si_value)
        length(vels)   >= 2 && (params[:v1] = vels[1].si_value;   params[:v2] = vels[2].si_value)
        length(vels)   == 1 && (params[:v1] = vels[1].si_value;   params[:v2] = 0.0)
        length(params) >= 4 && return (params, false, "")
        return (params, true, "Need m1, v1, m2, v2.")
    end

    # ── gravitational_force ───────────────────────────────────────
    if solver == :gravitational_force
        length(masses) >= 2 && (params[:m1] = masses[1].si_value; params[:m2] = masses[2].si_value)
        !isempty(dists) && (params[:distance] = dists[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need at least 2 of: m1, m2, distance.")
    end

    return (params, true, "Solver '$(solver)' not handled by assembler.")
end

# Global to pass original text into assembler (hack-free approach via closure)
const _nlp_orig = Ref{String}("")

# ── Main entry point ─────────────────────────────────────────────

"""
    parse_natural_language(raw::AbstractString) :: NLPParseResult

Parse a raw physics problem text into a structured NLPParseResult.
This is the main public API of this module.

The result contains:
  .success        — whether a solver could be fully determined
  .solver         — the solver command to dispatch
  .params         — parameters ready for the dispatcher
  .parse_log      — step-by-step extraction transcript
  .problem_type   — human-readable description
  .intent         — what the problem asks for
  .partial        — true if params are incomplete
  .partial_reason — why, if partial
"""
function parse_natural_language(raw::AbstractString)::NLPParseResult
    log = String[]
    push!(log, "── NLP Parser  ────────────────────────────────────────")
    push!(log, "Input: $(length(raw)) chars")

    orig, lc = _normalise(raw)
    _nlp_orig[] = orig

    # ── Step 1: Extract quantities ───────────────────────────────
    quantities = extract_quantities(orig, lc)
    if isempty(quantities)
        push!(log, "⚠  No physical quantities with units found.")
    else
        push!(log, "Quantities extracted ($(length(quantities))):")
        for q in quantities
            push!(log, @sprintf("  %.6g %s  →  %.6g %s  [%s]  | ctx: \"%s\"",
                q.raw_value, q.raw_unit, q.si_value, q.si_unit,
                string(q.kind), q.context))
        end
    end

    # ── Step 2: Extract positions ────────────────────────────────
    positions = extract_positions(orig, lc)
    if isempty(positions)
        push!(log, "⚠  No spatial positions found.")
    else
        push!(log, "Positions extracted ($(length(positions))):")
        for p in positions
            lbl = isnothing(p.label) ? "" : " [$(p.label)]"
            push!(log, @sprintf("  [%.4g, %.4g, %.4g]%s  | raw: \"%s\"",
                p.coords[1], p.coords[2], p.coords[3], lbl, p.raw))
        end
    end

    # ── Step 3: Detect problem type ──────────────────────────────
    domain, prob_type, solver = detect_problem_type(lc, quantities, positions)
    push!(log, "Problem type: $(prob_type)")
    push!(log, "Solver: :$(solver)  |  Domain: :$(domain)")

    # ── Step 4: Detect intent ────────────────────────────────────
    intent = detect_intent(lc)
    push!(log, "Intent: $(intent)")

    if solver == :unknown
        push!(log, "✗  Could not determine problem type.")
        return NLPParseResult(false, :unknown, Dict{Symbol,Any}(),
            log, prob_type, intent, true,
            "Could not determine the physics problem type from the text. " *
            "Try the command format: get <solver> param=value ...")
    end

    # ── Step 5: Assemble parameters ──────────────────────────────
    params, partial, partial_reason = assemble_params(solver, quantities, positions, lc)

    push!(log, "Parameters assembled ($(length(params))):")
    for (k, v) in params
        push!(log, "  $(k) = $(v isa Vector ? string(v) : @sprintf("%.6g", Float64(v isa AbstractFloat ? v : Float64(v))))")
    end

    if partial
        push!(log, "⚠  Partial parse: $(partial_reason)")
    else
        push!(log, "✓  Parameters complete — ready for dispatch.")
    end
    push!(log, "──────────────────────────────────────────────────────")

    return NLPParseResult(
        !partial,
        solver,
        params,
        log,
        prob_type,
        intent,
        partial,
        partial_reason
    )
end

# ── Detect if input looks like natural language ───────────────────

"""
    is_natural_language(s::AbstractString) :: Bool

Return true if the input looks like natural language prose
(textbook problem) rather than a structured command.

Heuristics:
  1. Contains sentences (multiple words before any = sign)
  2. Contains physics keywords as prose words
  3. Does NOT follow key=value format throughout
"""
function is_natural_language(s::AbstractString)::Bool
    s = strip(s)
    isempty(s) && return false

    # If it matches our command format exactly, it's structured
    # Command format: optional_verb command key=value key=value ...
    is_cmd_re = r"^(?:get|find|compute|calculate|solve|determine|evaluate|derive)?\s*\w+(?:\s+\w+=[^\s]+)+\s*$"
    occursin(is_cmd_re, lowercase(s)) && return false

    # Key=value with no spaces around key: structured
    kv_count = length(collect(eachmatch(r"\b\w+=[\[\d\-]", s)))
    kv_count >= 2 && return false

    # Contains multiple words before any =: likely prose
    words_before_eq = match(r"^([^=]+)=", s)
    if !isnothing(words_before_eq)
        word_count = length(split(strip(words_before_eq.captures[1])))
        word_count >= 4 && return true
    end

    # Contains physics prose markers
    physics_prose = [
        r"\bcharge[sd]?\b", r"\belectric\b", r"\bfield\b",
        r"\bforce[sd]?\b", r"\bpotential\b", r"\blocated\s+at\b",
        r"\bpositioned\b", r"\bprojectile\b", r"\bspring\b",
        r"\boscillat", r"\bcollision\b", r"\bvelocity\b",
        r"\bfree\s+space\b", r"\bin\s+the\s+[xy]-?[yz]?\s+plane\b",
    ]
    matches = sum(1 for re in physics_prose if occursin(re, lowercase(s)))
    matches >= 2 && return true

    # Contains unit in prose context (not key=value)
    unit_in_prose = occursin(r"\d+\s*(nC|μC|pC|mC|cm|mm|km|nN|kN|nJ|kJ|pF|nF)", s)
    unit_in_prose && return true

    return false
end
