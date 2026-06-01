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

struct ExtractedQuantity
    raw_value :: Float64
    raw_unit  :: String
    si_value  :: Float64
    si_unit   :: String
    kind      :: Symbol
    context   :: String
end

struct ExtractedPosition
    coords :: Vector{Float64}
    raw    :: String
    label  :: Union{String, Nothing}
end

struct NLPParseResult
    success        :: Bool
    solver         :: Symbol
    params         :: Dict{Symbol, Any}
    parse_log      :: Vector{String}
    problem_type   :: String
    intent         :: String
    partial        :: Bool
    partial_reason :: String
end

# ── SI unit table ─────────────────────────────────────────────────

const NLP_UNITS = Dict{String, Tuple{String, Float64, Symbol}}(
    "pc" => ("C",1e-12,:charge), "nc" => ("C",1e-9,:charge),
    "uc" => ("C",1e-6,:charge),  "μc" => ("C",1e-6,:charge),
    "mc" => ("C",1e-3,:charge),  "c"  => ("C",1.0,:charge),
    "kc" => ("C",1e3,:charge),
    "pm" => ("m",1e-12,:distance), "nm" => ("m",1e-9,:distance),
    "μm" => ("m",1e-6,:distance),  "um" => ("m",1e-6,:distance),
    "mm" => ("m",1e-3,:distance),  "cm" => ("m",1e-2,:distance),
    "dm" => ("m",0.1,:distance),   "m"  => ("m",1.0,:distance),
    "km" => ("m",1e3,:distance),
    "pn" => ("N",1e-12,:force), "nn" => ("N",1e-9,:force),
    "μn" => ("N",1e-6,:force),  "un" => ("N",1e-6,:force),
    "mn" => ("N",1e-3,:force),  "n"  => ("N",1.0,:force),
    "kn" => ("N",1e3,:force),
    "μv" => ("V",1e-6,:voltage), "uv" => ("V",1e-6,:voltage),
    "mv" => ("V",1e-3,:voltage), "v"  => ("V",1.0,:voltage),
    "kv" => ("V",1e3,:voltage),
    "nj" => ("J",1e-9,:energy),  "μj" => ("J",1e-6,:energy),
    "uj" => ("J",1e-6,:energy),  "mj" => ("J",1e-3,:energy),
    "j"  => ("J",1.0,:energy),   "kj" => ("J",1e3,:energy),
    "pf" => ("F",1e-12,:capacitance), "nf" => ("F",1e-9,:capacitance),
    "μf" => ("F",1e-6,:capacitance),  "uf" => ("F",1e-6,:capacitance),
    "mf" => ("F",1e-3,:capacitance),  "f"  => ("F",1.0,:capacitance),
    "μg" => ("kg",1e-9,:mass), "ug" => ("kg",1e-9,:mass),
    "mg" => ("kg",1e-6,:mass), "g"  => ("kg",1e-3,:mass),
    "kg" => ("kg",1.0,:mass),
    "m/s"  => ("m/s",1.0,:velocity),   "km/s" => ("m/s",1e3,:velocity),
    "cm/s" => ("m/s",0.01,:velocity),   "km/h" => ("m/s",1.0/3.6,:velocity),
    "m/s2" => ("m/s²",1.0,:acceleration), "m/s²" => ("m/s²",1.0,:acceleration),
    "deg"  => ("°",1.0,:angle),  "°"  => ("°",1.0,:angle),
    "rad"  => ("rad",1.0,:angle),
    "hz"   => ("Hz",1.0,:frequency),   "khz" => ("Hz",1e3,:frequency),
    "mhz"  => ("Hz",1e6,:frequency),   "ghz" => ("Hz",1e9,:frequency),
    "n/m"  => ("N/m",1.0,:spring_k),   "kn/m" => ("N/m",1e3,:spring_k),
    "n/c"  => ("N/C",1.0,:e_field),    "v/m"  => ("N/C",1.0,:e_field),
    "kv/m" => ("N/C",1e3,:e_field),    "mv/m" => ("N/C",1e6,:e_field),
)

const _DIST_UNITS = ("pm","nm","μm","um","mm","cm","dm","m","km")

# ── Text normalisation ────────────────────────────────────────────

function _normalise(raw::AbstractString)::Tuple{String, String}
    s = String(raw)
    s = replace(s, "\u2212"=>"-", "\u2013"=>"-", "\u2014"=>"-",
                   "\u00B7"=>".", "\u00D7"=>"*")
    s = replace(s, "μ"=>"u", "µ"=>"u")
    s = replace(s, "\u00B0"=>"°")
    s = replace(s, r"\s+"=>" ")
    orig = strip(s)
    return (orig, lowercase(orig))
end

# ── Number extraction ─────────────────────────────────────────────

const NUM_RE = r"(?<![a-zA-Z])(-?\s*(?:\d+\.?\d*|\d*\.\d+)(?:[eE][+-]?\d+)?)"

function _extract_numbers(s::String)::Vector{Tuple{Float64, Int, Int}}
    res = Tuple{Float64,Int,Int}[]
    for m in eachmatch(NUM_RE, s)
        v = tryparse(Float64, replace(m.captures[1], " "=>""))
        !isnothing(v) && push!(res, (v, m.offset, m.offset+length(m.match)-1))
    end
    res
end

# ── Unit matching ─────────────────────────────────────────────────

function _match_unit(text_lc::String, pos::Int)::Union{Tuple{String,String,Float64,Symbol,Int}, Nothing}
    i = pos; spaces = 0
    while i <= length(text_lc) && text_lc[i] == ' ' && spaces < 2
        i += 1; spaces += 1
    end
    i > length(text_lc) && return nothing
    for unit in sort(collect(keys(NLP_UNITS)), by=length, rev=true)
        ulen = length(unit)
        i+ulen-1 > length(text_lc) && continue
        text_lc[i:i+ulen-1] != unit && continue
        after = i + ulen
        if after <= length(text_lc)
            nc = text_lc[after]
            (isletter(nc) || isdigit(nc)) && nc != '/' && continue
        end
        si_unit, mult, kind = NLP_UNITS[unit]
        return (unit, si_unit, mult, kind, (i-pos)+ulen)
    end
    nothing
end

# ── Quantity extraction ───────────────────────────────────────────

function extract_quantities(orig::String, lc::String)::Vector{ExtractedQuantity}
    results   = ExtractedQuantity[]
    numbers   = _extract_numbers(lc)
    used      = Set{Tuple{Int,Int}}()
    for (val, n_start, n_end) in numbers
        any(s -> s[1] <= n_start <= s[2], used) && continue
        r = _match_unit(lc, n_end+1)
        isnothing(r) && continue
        unit_raw, si_unit, mult, kind, consumed = r
        si_val = val * mult
        ctx_s  = max(1, n_start-20); ctx_e = min(length(orig), n_end+consumed+20)
        ctx    = strip(orig[ctx_s:ctx_e])
        push!(results, ExtractedQuantity(val, unit_raw, si_val, si_unit, kind, ctx))
        push!(used, (n_start, n_end+consumed))
    end
    results
end

# ── Charge-position pairing ───────────────────────────────────────

"""
    pair_charges_positions(lc, quantities) → Vector{Tuple{Float64,Vector{Float64},String}}

For problems with "Q nC at axis = val unit" patterns, explicitly pair
each charge with its 3D position. Returns (charge_SI, [x,y,z], raw_text).
"""
function pair_charges_positions(lc::String, orig::String,
        quantities::Vector{ExtractedQuantity})::Vector{Tuple{Float64,Vector{Float64},String}}

    pairs = Tuple{Float64, Vector{Float64}, String}[]

    # Pattern: "NUMBER CHARGE_UNIT at AXIS = NUMBER DIST_UNIT"
    # Examples: "5 nc at y = 5 cm", "-10 nc at y = -5 cm", "15 nc at x = -5 cm"
    #
    # We scan the text for each charge quantity and look for a following
    # "at AXIS = VALUE UNIT" within 40 characters.

    charges = [q for q in quantities if q.kind == :charge]

    # Find all "at axis = val unit" spans in order
    comp_re = r"at\s+([xyz])\s*=\s*(-?[\d.]+(?:[eE][+-]?\d+)?)\s*(cm|mm|m|km|um|μm|nm)?"
    comp_matches = collect(eachmatch(comp_re, lc))

    if isempty(comp_matches)
        return pairs  # no component-form positions
    end

    # Build a position for each component match
    comp_positions = Tuple{Vector{Float64}, String, Int}[]  # coords, raw, offset
    for m in comp_matches
        axis = String(m.captures[1])
        val  = tryparse(Float64, replace(String(m.captures[2]), " "=>""))
        isnothing(val) && continue
        unit_str = isnothing(m.captures[3]) ? "m" : String(m.captures[3])
        mult = haskey(NLP_UNITS, unit_str) ? NLP_UNITS[unit_str][2] : 1.0
        si_val = val * mult
        x = axis == "x" ? si_val : 0.0
        y = axis == "y" ? si_val : 0.0
        z = axis == "z" ? si_val : 0.0
        push!(comp_positions, ([x,y,z], m.match, m.offset))
    end

    # Now find each charge in lc and pair it with the nearest following component position
    # We locate charges by scanning for "NUMBER CHARGE_UNIT"
    charge_re = r"(-?\s*\d+\.?\d*(?:[eE][+-]?\d+)?)\s*(nc|uc|μc|pc|mc|kc|c)\b"
    ch_matches = collect(eachmatch(charge_re, lc))

    used_comp = Set{Int}()  # track which comp_positions already used

    for ch_m in ch_matches
        q_val = tryparse(Float64, replace(String(ch_m.captures[1]), " "=>""))
        isnothing(q_val) && continue
        u_str = String(ch_m.captures[2])
        !haskey(NLP_UNITS, u_str) && continue
        _, mult_q, _ = NLP_UNITS[u_str]
        q_si = q_val * mult_q

        ch_end = ch_m.offset + length(ch_m.match)

        # Find the nearest comp_position that comes AFTER this charge
        # within 60 characters, and hasn't been used yet
        best_idx = nothing; best_dist = 999
        for (i, (coords, raw, offset)) in enumerate(comp_positions)
            i in used_comp && continue
            dist = offset - ch_end
            if 0 <= dist < 60 && dist < best_dist
                best_dist = dist
                best_idx  = i
            end
        end

        if !isnothing(best_idx)
            coords, raw, _ = comp_positions[best_idx]
            push!(used_comp, best_idx)
            push!(pairs, (q_si, coords, "$(ch_m.match) $(raw)"))
        end
    end

    return pairs
end

# ── Position extraction ───────────────────────────────────────────

"""
Extract all spatial positions from text.

KEY FIX: Uses Vector instead of Dict for component positions,
so multiple positions on the same axis (two y-values) are all preserved.
"""
function extract_positions(orig::String, lc::String)::Vector{ExtractedPosition}
    positions = ExtractedPosition[]

    # ── Tuple notation: (x, y, z) or (x, y) with optional label ──
    tuple_re = r"([A-Z])?\s*\(\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*,\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*(?:,\s*(-?\s*[\d.]+(?:[eE][+-]?\d+)?)\s*)?\)"
    for m in eachmatch(tuple_re, orig)
        label = isnothing(m.captures[1]) ? nothing : String(m.captures[1])
        xv    = tryparse(Float64, replace(String(m.captures[2])," "=>""))
        yv    = tryparse(Float64, replace(String(m.captures[3])," "=>""))
        zv    = isnothing(m.captures[4]) ? 0.0 :
                something(tryparse(Float64, replace(String(m.captures[4])," "=>"")), 0.0)
        (isnothing(xv) || isnothing(yv)) && continue
        push!(positions, ExtractedPosition([xv, yv, zv], m.match, label))
    end

    # ── "at the origin" ───────────────────────────────────────────
    if occursin(r"\b(at\s+the\s+origin|at\s+origin|the\s+origin)\b", lc)
        push!(positions, ExtractedPosition([0.0,0.0,0.0], "at the origin", nothing))
    end

    # ── Component form: "at x = -5 cm", "at y = 5 cm" ────────────
    # FIX: Use Vector — one entry per match, no Dict overwriting
    comp_re = r"at\s+([xyz])\s*=\s*(-?[\d.]+(?:[eE][+-]?\d+)?)\s*(cm|mm|m|km|um|μm|nm)?"
    for m in eachmatch(comp_re, lc)
        axis = String(m.captures[1])
        val  = tryparse(Float64, replace(String(m.captures[2])," "=>""))
        isnothing(val) && continue
        unit_str = isnothing(m.captures[3]) ? "m" : String(m.captures[3])
        mult = haskey(NLP_UNITS, unit_str) ? NLP_UNITS[unit_str][2] : 1.0
        si_val = val * mult
        x = axis == "x" ? si_val : 0.0
        y = axis == "y" ? si_val : 0.0
        z = axis == "z" ? si_val : 0.0
        push!(positions, ExtractedPosition([x,y,z], m.match, nothing))
    end

    return positions
end

# ── Intent classification ─────────────────────────────────────────

"""
Detect if this is a position-finding problem (inverse solve).
These cannot be handled by forward computation and need special treatment.
"""
function is_find_position_problem(lc::String)::Bool
    patterns = [
        r"\bfind\b.{0,40}\bcoordinates\b",
        r"\bdetermine\b.{0,40}\b(?:x-y|xy|position|coordinates|location)\b",
        r"\brequired\b.{0,40}\bcoordinates\b",
        r"\bx-y\s+coordinates\b",
        r"\bwhere\s+(?:should|must|to\s+place)\b",
        r"\bplace\b.{0,30}\bcharge\b",
        r"\bfourth\s+charge\b.{0,50}\bzero\b",
        r"\bzero\b.{0,50}\bcoordinates\b",
    ]
    sum(1 for p in patterns if occursin(p, lc)) >= 1
end

"""
Detect if the problem says "zero field" / "zero force" at a point.
"""
function has_zero_field_intent(lc::String)::Bool
    occursin(r"\bzero\s+(?:electric\s+)?field\b", lc) ||
    occursin(r"\bproduce\s+(?:a\s+)?zero\b", lc) ||
    occursin(r"\bresult\s+in\s+(?:a\s+)?zero\b", lc)
end

"""
Detect "find coordinates of Nth charge" — extract the unknown charge value and ordinal.
Returns (charge_SI, ordinal_string) or nothing.
"""
function detect_unknown_charge(lc::String,
        quantities::Vector{ExtractedQuantity})::Union{Tuple{Float64,String}, Nothing}
    ordinals = ["fourth", "4th", "third", "3rd", "second", "2nd",
                "fifth", "5th", "unknown", "additional", "required"]
    for ord in ordinals
        pat = Regex("\\b$(ord)\\b.{0,40}\\b(\\d+\\.?\\d*)\\s*(nc|uc|μc|pc|mc)")
        m   = match(pat, lc)
        if !isnothing(m)
            v    = tryparse(Float64, m.captures[1])
            u    = String(m.captures[2])
            isnothing(v) && continue
            mult = haskey(NLP_UNITS, u) ? NLP_UNITS[u][2] : 1.0
            return (v * mult, ord)
        end
        # Also try reversed: "5 nC fourth charge"
        pat2 = Regex("\\b(\\d+\\.?\\d*)\\s*(nc|uc|μc|pc|mc)\\b.{0,20}\\b$(ord)\\b")
        m2   = match(pat2, lc)
        if !isnothing(m2)
            v    = tryparse(Float64, m2.captures[1])
            u    = String(m2.captures[2])
            isnothing(v) && continue
            mult = haskey(NLP_UNITS, u) ? NLP_UNITS[u][2] : 1.0
            return (v * mult, ord)
        end
    end
    nothing
end

"""Extract what the problem asks to compute."""
function detect_intent(lc::String)::String
    if is_find_position_problem(lc)
        return "Find position/coordinates of unknown charge"
    end
    if has_zero_field_intent(lc)
        return "Find condition for zero electric field"
    end
    m = match(r"\b(?:find|determine|calculate|compute|evaluate)\b\s+(?:the\s+)?(.{3,60}?)(?:\.|$|\n|at\s+)", lc)
    !isnothing(m) && return "Find: " * strip(m.captures[1])
    occursin(r"\b(find|determine|calculate|compute|what is|evaluate)\b", lc) &&
        return "Find the requested quantity"
    return "Compute the relevant physics"
end

# ── Problem type detection ────────────────────────────────────────

function detect_problem_type(lc::String, quantities::Vector{ExtractedQuantity},
        positions::Vector{ExtractedPosition})::Tuple{Symbol, String, Symbol}

    charges   = [q for q in quantities if q.kind == :charge]
    masses    = [q for q in quantities if q.kind == :mass]
    n_charges = length(charges)
    n_pos     = length(positions)

    if n_charges > 0

        # ── Inverse: find position of unknown charge ───────────────
        if is_find_position_problem(lc)
            return (:electromagnetics,
                    "Find position of unknown charge for zero-field condition",
                    :find_charge_position)
        end

        # ── Electric field ──────────────────────────────────────────
        if occursin(r"\belectric\s+field\b", lc)
            if n_charges >= 2 || n_pos > 2
                return (:electromagnetics, "Electric field superposition", :electric_field_superposition)
            end
            return (:electromagnetics, "Electric field of a point charge", :electric_field)
        end

        # ── Force (not gravitational/spring/centripetal) ────────────
        if occursin(r"\b(force|forces)\b", lc) &&
           !occursin(r"(gravitational|spring|centripetal)", lc)
            if n_charges == 2 && n_pos == 2
                return (:electromagnetics, "Coulomb force between two point charges", :coulomb_force)
            end
            if n_charges >= 2
                return (:electromagnetics, "Net Coulomb force superposition", :coulomb_force_superposition)
            end
        end

        # ── Potential / Voltage ─────────────────────────────────────
        occursin(r"\b(potential|voltage)\b", lc) &&
            return (:electromagnetics, "Electric potential", :electric_potential)

        # ── Flux ────────────────────────────────────────────────────
        occursin(r"\b(flux)\b", lc) &&
            return (:electromagnetics, "Electric flux", :electric_flux)

        # ── Capacitor ───────────────────────────────────────────────
        occursin(r"\bcapacitor\b", lc) &&
            return (:electromagnetics, "Capacitor energy/charge", :capacitor_energy)

        # ── Default rules by counts ──────────────────────────────────
        n_charges == 1 && n_pos >= 1 &&
            return (:electromagnetics, "Electric field of a point charge", :electric_field)

        n_charges == 2 && n_pos == 2 &&
            return (:electromagnetics, "Coulomb force between two point charges", :coulomb_force)

        n_charges >= 2 &&
            return (:electromagnetics, "Electric field superposition", :electric_field_superposition)
    end

    # ── Classical mechanics ────────────────────────────────────────
    occursin(r"\bspring\b|\boscillat", lc) &&
        return (:classical_mechanics, "Harmonic oscillator", :harmonic_oscillator)
    occursin(r"\bcircular\b|\bcentripetal\b", lc) &&
        return (:classical_mechanics, "Circular motion", :circular_motion)
    occursin(r"\bprojectile\b|\blaunch\b|\bthrow\b", lc) &&
        !occursin(r"\bcharge\b|\belectric\b", lc) &&
        return (:classical_mechanics, "Projectile motion", :projectile_motion)
    occursin(r"\bcollision\b|\belastic\b", lc) &&
        return (:classical_mechanics, "Elastic collision", :elastic_collision)
    occursin(r"\bgravitation\b", lc) &&
        return (:classical_mechanics, "Gravitational force", :gravitational_force)
    !isempty(masses) && occursin(r"\baccelerat", lc) &&
        return (:classical_mechanics, "Newton's second law", :newtons_second_law)
    !isempty(masses) && occursin(r"\bvelocity\b|\bspeed\b|\bkinetic\b", lc) &&
        return (:classical_mechanics, "Kinetic energy", :kinetic_energy)
    occursin(r"\bangle\b.{0,20}\bm/s\b|\bm/s.{0,20}\bangle\b", lc) &&
        return (:classical_mechanics, "Projectile motion", :projectile_motion)

    return (:unknown, "Could not determine problem type", :unknown)
end

# ── Parameter assembly ────────────────────────────────────────────

function assemble_params(
    solver     :: Symbol,
    quantities :: Vector{ExtractedQuantity},
    positions  :: Vector{ExtractedPosition},
    lc         :: String,
    orig       :: String
)::Tuple{Dict{Symbol,Any}, Bool, String}

    params   = Dict{Symbol, Any}()
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

    # ── find_charge_position ────────────────────────────────────────
    # This is an inverse problem we can't solve directly yet.
    # We return the known charges and field point so the user gets
    # the field from known sources, plus a clear explanation.
    if solver == :find_charge_position
        unk = detect_unknown_charge(lc, quantities)
        unk_val  = isnothing(unk) ? nothing : unk[1]
        unk_name = isnothing(unk) ? "unknown" : unk[2]

        # Collect source charges (exclude the unknown-position charge)
        src_charges = if !isnothing(unk_val)
            filter(q -> !isapprox(q.si_value, unk_val, rtol=0.01), charges)
        else
            charges
        end

        # Try to get source positions from pairs
        pairs = pair_charges_positions(lc, orig, src_charges)

        n_src = length(pairs)
        if n_src >= 1
            params[:charges]     = [p[1] for p in pairs]
            params[:sources]     = [p[2] for p in pairs]
        elseif length(src_charges) >= 1 && length(positions) > 1
            # Fallback: use component positions
            fp_idx = findfirst(p -> p.coords ≈ [0.0,0.0,0.0] && p.raw == "at the origin", positions)
            src_idxs = isnothing(fp_idx) ? (1:min(length(positions), length(src_charges))) :
                       setdiff(1:length(positions), [fp_idx])[1:min(end, length(src_charges))]
            params[:charges] = [src_charges[i].si_value for i in 1:length(src_idxs)]
            params[:sources] = [positions[i].coords for i in src_idxs]
        end

        # Field point is origin if "zero field at origin"
        if has_zero_field_intent(lc) && occursin(r"\borigin\b", lc)
            params[:field_point] = [0.0, 0.0, 0.0]
        end

        if haskey(params, :charges) && haskey(params, :field_point) &&
           length(params[:charges]) >= 1
            params[:unknown_charge] = isnothing(unk_val) ? 0.0 : unk_val
            return (params, false, "")
        end
        return (params, true,
            "Could not extract source charge positions for inverse solve.\n" *
            "  Found $(length(src_charges)) source charge(s) and $(length(positions)) position(s).")
    end

    # ── coulomb_force ───────────────────────────────────────────────
    if solver == :coulomb_force
        length(charges) >= 2 || return (params, true,
            "Need 2 charges. Found: $(length(charges))")
        length(positions) >= 2 || return (params, true,
            "Need 2 positions. Found: $(length(positions))")
        params[:q1] = charges[1].si_value
        params[:q2] = charges[2].si_value
        params[:r1] = positions[1].coords
        params[:r2] = positions[2].coords
        return (params, false, "")
    end

    # ── electric_field ──────────────────────────────────────────────
    if solver == :electric_field
        isempty(charges) && return (params, true, "No charge found.")
        params[:charge] = charges[1].si_value
        if length(positions) >= 2
            params[:source] = positions[1].coords; params[:field_point] = positions[2].coords
        elseif length(positions) == 1
            params[:source] = [0.0,0.0,0.0]; params[:field_point] = positions[1].coords
        else
            return (params, true, "Need source position and field point.")
        end
        return (params, false, "")
    end

    # ── electric_field_superposition ────────────────────────────────
    if solver == :electric_field_superposition
        # First try charge-position pairing (most robust for "Q nC at axis=val" form)
        pairs = pair_charges_positions(lc, orig, charges)

        if length(pairs) >= 2
            # Identify field point: "at the origin" wins; else last position
            origin_pos = findfirst(p -> p.coords ≈ [0.0,0.0,0.0] && p.raw == "at the origin", positions)
            fp = !isnothing(origin_pos) ? positions[origin_pos].coords : [0.0, 0.0, 0.0]

            params[:charges]     = [p[1] for p in pairs]
            params[:sources]     = [p[2] for p in pairs]
            params[:field_point] = fp
            return (params, false, "")
        end

        # Fallback: positional list matching (tuple-notation problems)
        length(charges) < 2 && return (params, true,
            "Need ≥2 charges for superposition. Found: $(length(charges))")

        # "each" pattern: "50 nC each" at multiple positions
        unique_q   = unique(c.si_value for c in charges)
        all_q_vals = if length(unique_q) == 1 && length(positions) > length(charges)
            fill(charges[1].si_value, length(positions))
        else
            [c.si_value for c in charges]
        end

        # Identify field point vs source positions
        origin_pos = findfirst(p -> p.coords ≈ [0.0,0.0,0.0] && p.raw == "at the origin", positions)
        if !isnothing(origin_pos)
            fp = positions[origin_pos].coords
            src_idxs = setdiff(1:length(positions), [origin_pos])
        else
            fp = [0.0, 0.0, 0.0]  # default field point at origin
            src_idxs = 1:length(positions)
        end

        n_src = min(length(src_idxs), length(all_q_vals))
        n_src < 1 && return (params, true,
            "Charges: $(length(all_q_vals)), Positions: $(length(positions)) — cannot match.")

        params[:charges]     = all_q_vals[1:n_src]
        params[:sources]     = [positions[i].coords for i in src_idxs[1:n_src]]
        params[:field_point] = fp
        return (params, false, "")
    end

    # ── coulomb_force_superposition ─────────────────────────────────
    if solver == :coulomb_force_superposition
        isempty(charges)   && return (params, true, "No charges found.")
        isempty(positions) && return (params, true, "No positions found.")

        unique_ch = unique(c.si_value for c in charges)
        n_pos     = length(positions)
        all_ch    = if length(unique_ch) == 1 && n_pos > length(charges)
            fill(charges[1].si_value, n_pos)
        else
            [c.si_value for c in charges]
        end

        n = min(length(all_ch), n_pos)
        n < 2 && return (params, true, "Need ≥2 charges with positions.")

        # Find target label: "force on the charge at A"
        target_idx = 1
        m = match(r"force\s+on\s+(?:the\s+)?(?:charge\s+)?(?:at\s+)?([A-Z])\b", orig)
        if !isnothing(m)
            lbl = String(m.captures[1])
            found = findfirst(p -> !isnothing(p.label) && p.label == lbl, positions[1:n])
            !isnothing(found) && (target_idx = found)
        end

        params[:target_charge]    = all_ch[target_idx]
        params[:target_position]  = positions[target_idx].coords
        params[:other_charges]    = [all_ch[i] for i in 1:n if i != target_idx]
        params[:other_positions]  = [positions[i].coords for i in 1:n if i != target_idx]
        return (params, false, "")
    end

    # ── electric_potential ──────────────────────────────────────────
    if solver == :electric_potential
        isempty(charges) && return (params, true, "No charge found.")
        params[:charge] = charges[1].si_value
        if length(positions) >= 2
            params[:source] = positions[1].coords; params[:field_point] = positions[2].coords
        elseif length(positions) == 1
            params[:source] = [0.0,0.0,0.0]; params[:field_point] = positions[1].coords
        else
            return (params, true, "Need at least one position.")
        end
        return (params, false, "")
    end

    # ── capacitor_energy ────────────────────────────────────────────
    if solver == :capacitor_energy
        !isempty(caps)     && (params[:capacitance] = caps[1].si_value)
        !isempty(volts)    && (params[:voltage]     = volts[1].si_value)
        !isempty(energies) && (params[:energy]      = energies[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need ≥2 of: capacitance, voltage, energy.")
    end

    # ── projectile_motion ───────────────────────────────────────────
    if solver == :projectile_motion
        !isempty(vels)   && (params[:initial_velocity] = vels[1].si_value)
        !isempty(angles) && (params[:angle_deg]        = angles[1].si_value)
        !isempty(dists)  && (params[:initial_height]   = dists[1].si_value)
        haskey(params, :initial_height) || (params[:initial_height] = 0.0)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need initial velocity and launch angle.")
    end

    # ── harmonic_oscillator ─────────────────────────────────────────
    if solver == :harmonic_oscillator
        !isempty(masses)   && (params[:mass]            = masses[1].si_value)
        !isempty(springks) && (params[:spring_constant] = springks[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need mass and spring constant.")
    end

    # ── newtons_second_law ──────────────────────────────────────────
    if solver == :newtons_second_law
        !isempty(masses) && (params[:mass]  = masses[1].si_value)
        !isempty(forces) && (params[:force] = forces[1].si_value)
        m = match(r"(\d+\.?\d*)\s*m/s[²2]", lc)
        if !isnothing(m)
            a = tryparse(Float64, m.captures[1])
            !isnothing(a) && (params[:acceleration] = a)
        end
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need ≥2 of: force, mass, acceleration.")
    end

    # ── kinetic_energy ──────────────────────────────────────────────
    if solver == :kinetic_energy
        !isempty(masses) && (params[:mass]     = masses[1].si_value)
        !isempty(vels)   && (params[:velocity] = vels[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need mass and velocity.")
    end

    # ── elastic_collision ───────────────────────────────────────────
    if solver == :elastic_collision
        length(masses) >= 2 && (params[:m1]=masses[1].si_value; params[:m2]=masses[2].si_value)
        length(vels)   >= 2 && (params[:v1]=vels[1].si_value;   params[:v2]=vels[2].si_value)
        length(vels)   == 1 && (params[:v1]=vels[1].si_value;   params[:v2]=0.0)
        length(params) >= 4 && return (params, false, "")
        return (params, true, "Need m1, v1, m2, v2.")
    end

    # ── gravitational_force ─────────────────────────────────────────
    if solver == :gravitational_force
        length(masses) >= 2 && (params[:m1]=masses[1].si_value; params[:m2]=masses[2].si_value)
        !isempty(dists) && (params[:distance] = dists[1].si_value)
        length(params) >= 2 && return (params, false, "")
        return (params, true, "Need ≥2 of: m1, m2, distance.")
    end

    return (params, true, "Solver ':$(solver)' not handled by assembler.")
end

# ── Reference storage ─────────────────────────────────────────────
const _nlp_orig = Ref{String}("")

# ── Main public API ───────────────────────────────────────────────

"""
    parse_natural_language(raw::AbstractString) :: NLPParseResult

Parse raw physics problem text into a structured NLPParseResult.
"""
function parse_natural_language(raw::AbstractString)::NLPParseResult
    log = String[]
    push!(log, "── NLP Parser v2.4 ─────────────────────────────────────")
    push!(log, "Input length: $(length(raw)) chars")

    orig, lc = _normalise(raw)
    _nlp_orig[] = orig

    # ── Step 1: Extract quantities ───────────────────────────────
    quantities = extract_quantities(orig, lc)
    if isempty(quantities)
        push!(log, "⚠  No physical quantities with units found.")
    else
        push!(log, "Quantities ($(length(quantities))):")
        for q in quantities
            push!(log, @sprintf("  %.5g %s → %.5g %s [%s]  ctx: \"%s\"",
                q.raw_value, q.raw_unit, q.si_value, q.si_unit, string(q.kind), q.context))
        end
    end

    # ── Step 2: Extract positions ────────────────────────────────
    positions = extract_positions(orig, lc)
    push!(log, "Positions ($(length(positions))):")
    for p in positions
        lbl = isnothing(p.label) ? "" : " [$(p.label)]"
        push!(log, @sprintf("  [%.4g, %.4g, %.4g]%s raw:\"%s\"",
            p.coords[1], p.coords[2], p.coords[3], lbl, p.raw))
    end

    # ── Step 3: Charge-position pairs (diagnostic) ───────────────
    charges = [q for q in quantities if q.kind == :charge]
    pairs   = pair_charges_positions(lc, orig, charges)
    if !isempty(pairs)
        push!(log, "Charge-position pairs ($(length(pairs))):")
        for (q, pos, raw) in pairs
            push!(log, @sprintf("  q=%.5g C  pos=[%.4g, %.4g, %.4g]  raw:\"%s\"",
                q, pos[1], pos[2], pos[3], raw))
        end
    end

    # ── Step 4: Detect problem type ──────────────────────────────
    domain, prob_type, solver = detect_problem_type(lc, quantities, positions)
    push!(log, "Problem type: $(prob_type)")
    push!(log, "Solver: :$(solver)  Domain: :$(domain)")

    # ── Step 5: Detect intent ────────────────────────────────────
    intent = detect_intent(lc)
    push!(log, "Intent: $(intent)")

    # ── Step 6: Unknown solver → clear explanation ───────────────
    if solver == :unknown
        push!(log, "✗  Could not determine problem type.")
        return NLPParseResult(false, :unknown, Dict{Symbol,Any}(), log, prob_type, intent,
            true, "Could not determine the physics problem type from the text.\n" *
                  "  Try the command format: get <solver> param=value ...")
    end

    # ── Step 7: find_charge_position — special inverse message ───
    if solver == :find_charge_position
        push!(log, "ℹ  Inverse problem detected: find position of unknown charge.")
        push!(log, "   This requires iterative/symbolic solving (not yet implemented).")
        push!(log, "   Showing electric field from the known source charges instead.")

        # Fall back to computing the field from known sources
        unk   = detect_unknown_charge(lc, quantities)
        unk_v = isnothing(unk) ? nothing : unk[1]
        src_charges = if !isnothing(unk_v)
            filter(q -> !isapprox(q.si_value, unk_v, rtol=0.01), charges)
        else
            charges
        end

        push!(log, "Source charges (excluding unknown): $(length(src_charges))")
        for c in src_charges
            push!(log, "  q = $(c.si_value) C")
        end

        if length(src_charges) >= 2
            # Re-run with these charges only → electric_field_superposition
            fallback_params, partial, reason = assemble_params(
                :electric_field_superposition, src_charges, positions, lc, orig)

            fallback_partial_reason = if partial
                reason
            else
                "The problem asks to FIND the position of a $(isnothing(unk_v) ? "new" : @sprintf("%.4g C", unk_v)) charge.\n" *
                "  Iterative position finding is not yet implemented.\n" *
                "  Showing below: the electric field at the origin from the $(length(src_charges)) known source charges.\n" *
                "  The unknown charge must be placed such that it cancels this field."
            end

            push!(log, partial ? "⚠  Fallback also partial: $(reason)" :
                        "✓  Showing field from $(length(src_charges)) known source charges.")
            push!(log, "──────────────────────────────────────────────────────")

            return NLPParseResult(!partial,
                :electric_field_superposition,
                fallback_params, log, prob_type, intent, partial,
                fallback_partial_reason)
        end
        return NLPParseResult(false, :electric_field_superposition, Dict{Symbol,Any}(),
            log, prob_type, intent, true,
            "Not enough source charges to compute the partial result.")
    end

    # ── Step 8: Assemble parameters ──────────────────────────────
    params, partial, partial_reason = assemble_params(solver, quantities, positions, lc, orig)
    push!(log, "Parameters assembled ($(length(params))):")
    for (k, v) in params
        vs = v isa Vector ? string(v) : (v isa AbstractFloat ? @sprintf("%.6g", v) : string(v))
        push!(log, "  $(k) = $(vs)")
    end
    partial ? push!(log, "⚠  Partial: $(partial_reason)") :
              push!(log, "✓  Complete — ready for dispatch.")
    push!(log, "──────────────────────────────────────────────────────")

    return NLPParseResult(!partial, solver, params, log, prob_type, intent, partial, partial_reason)
end

# ── Input mode classifier ─────────────────────────────────────────

"""
    is_natural_language(s::AbstractString) :: Bool

Return true if the input looks like prose rather than a command.
"""
function is_natural_language(s::AbstractString)::Bool
    s = strip(s)
    isempty(s) && return false
    lc = lowercase(s)
    kv_tight = length(collect(eachmatch(r"\b\w+=[^\s=]", s)))
    kv_tight >= 2 && return false
    nl_phrases = [r"\b(?:located|positioned|placed|situated)\s+at\b",
                  r"\bfree\s+space\b", r"\brespectively\b",
                  r"\bpoint\s+charge[sd]?\b", r"\bproduces?\s+(?:a\s+)?zero\b"]
    sum(1 for re in nl_phrases if occursin(re, lc)) >= 1 && return true
    occursin(r"\d+\s*(?:nC|μC|pC|mC|cm|mm|nN|kN)", s) && !occursin(r"\w+=\d", s) && return true
    length(collect(eachmatch(r"\(-?\s*[\d.]+\s*,", s))) >= 2 && return true
    false
end