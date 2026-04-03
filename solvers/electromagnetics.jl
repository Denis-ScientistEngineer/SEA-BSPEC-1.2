# ================================================================
# FILE: solvers/electromagnetics.jl
#
# Electromagnetics Solver Module
#
# Responsibility: contain ALL electromagnetic physical laws and
# their numerical implementations. This file is a self-contained
# physics library. It knows nothing about the engine pipeline —
# it only receives a Dict of parameters and returns a SolverResult.
#
# Registers itself with the Dispatcher via register_electromagnetics!()
# which is called once by main.jl during engine startup.
#
# Physical laws implemented:
#   - Coulomb's law                  (electric force)
#   - Gauss's law (point charge)     (electric field)
#   - Electric potential             (scalar field)
#   - Superposition principle        (multi-charge fields)
#   - Electric flux (planar)         (Gauss surface)
#   - Energy stored in E-field       (capacitor)
# ================================================================

# ── Physical constants ────────────────────────────────────────────────────────

const EM_k     = 8.9875517923e9    # N·m²/C²  Coulomb's constant
const EM_ε₀    = 8.854187817e-12   # F/m      vacuum permittivity
const EM_μ₀    = 4π * 1e-7         # H/m      vacuum permeability
const EM_e     = 1.602176634e-19   # C        elementary charge

# ── Self-registration ─────────────────────────────────────────────────────────

"""
    register_electromagnetics!()

Register all EM solvers with the Dispatcher.
Call this once from main.jl after the Dispatcher is initialized.
"""
function register_electromagnetics!()
    register_solver!(SolverEntry(
        :electric_field,
        [:charge, :source, :field_point],
        [],
        _em_electric_field,
        "Electric field vector E⃗ of a point charge at a field point. (Gauss/Coulomb)",
        :electromagnetics
    ))

    register_solver!(SolverEntry(
        :coulomb_force,
        [:q1, :q2, :r1, :r2],
        [],
        _em_coulomb_force,
        "Coulomb force F⃗ between two point charges, with direction.",
        :electromagnetics
    ))

    register_solver!(SolverEntry(
        :electric_potential,
        [:charge, :source, :field_point],
        [],
        _em_electric_potential,
        "Scalar electric potential V at a point due to a point charge.",
        :electromagnetics
    ))

    register_solver!(SolverEntry(
        :electric_field_superposition,
        [:charges, :sources, :field_point],
        [],
        _em_superposition,
        "Net E⃗ at a field point due to N point charges (superposition).",
        :electromagnetics
    ))

    register_solver!(SolverEntry(
        :electric_flux,
        [:E_field, :area, :normal],
        [],
        _em_flux,
        "Electric flux Φ = E⃗ · A⃗ through a planar surface.",
        :electromagnetics
    ))

    register_solver!(SolverEntry(
        :capacitor_energy,
        [:capacitance, :voltage],
        [],
        _em_capacitor_energy,
        "Energy stored in a capacitor: U = ½CV². Also computes charge Q.",
        :electromagnetics
    ))
end

# ── Solver implementations ────────────────────────────────────────────────────

"""
Electric field of a single point charge.
Law: E⃗ = (1/4πε₀) · q/r² · r̂    [Gauss's law / Coulomb's law]
"""
function _em_electric_field(params::Dict{Symbol,Any}) :: SolverResult
    q           = _to_f64(params[:charge])
    source      = _to_vec3(params[:source])
    field_point = _to_vec3(params[:field_point])

    r⃗ = field_point .- source
    r  = norm(r⃗)

    r ≈ 0.0 && throw(DomainError(0.0,
        "Field point coincides with source charge — E-field diverges at source."))

    r̂  = r⃗ ./ r
    E⃗  = EM_k * q / r^2 .* r̂
    E  = norm(E⃗)

    SolverResult(
        :electric_field,
        Dict{Symbol,Any}(
            :E_vector        => E⃗,
            :E_magnitude     => E,
            :r_vector        => r⃗,
            :r_magnitude     => r,
            :unit_vector_r̂   => r̂,
            :charge          => q,
            :field_direction => q >= 0 ? "away from charge" : "toward charge"
        ),
        Dict{Symbol,String}(
            :E_vector        => "N/C",
            :E_magnitude     => "N/C",
            :r_vector        => "m",
            :r_magnitude     => "m",
            :unit_vector_r̂   => "dimensionless",
            :charge          => "C",
            :field_direction => "text"
        ),
        :electromagnetics,
        true,
        "E-field at distance $(round(r, sigdigits=4)) m = $(round(E, sigdigits=5)) N/C"
    )
end

"""
Coulomb force between two point charges.
Law: F⃗₁₂ = (1/4πε₀) · q₁q₂/r² · r̂₁₂
"""
function _em_coulomb_force(params::Dict{Symbol,Any}) :: SolverResult
    q1 = _to_f64(params[:q1])
    q2 = _to_f64(params[:q2])
    r1 = _to_vec3(params[:r1])
    r2 = _to_vec3(params[:r2])

    r⃗  = r2 .- r1      # displacement from q1 to q2
    r   = norm(r⃗)

    r ≈ 0.0 && throw(DomainError(0.0,
        "Charges occupy the same position — Coulomb force is undefined."))

    r̂   = r⃗ ./ r
    # Force on q2 due to q1 (positive = repulsive along r̂)
    F⃗   = EM_k * q1 * q2 / r^2 .* r̂
    F   = norm(F⃗)
    attractive = (q1 * q2 < 0.0)

    SolverResult(
        :coulomb_force,
        Dict{Symbol,Any}(
            :F_vector    => F⃗,
            :F_magnitude => F,
            :r_magnitude => r,
            :attractive  => attractive,
            :q1          => q1,
            :q2          => q2
        ),
        Dict{Symbol,String}(
            :F_vector    => "N",
            :F_magnitude => "N",
            :r_magnitude => "m",
            :attractive  => "boolean",
            :q1          => "C",
            :q2          => "C"
        ),
        :electromagnetics,
        true,
        "Coulomb force = $(round(F, sigdigits=5)) N  " *
        "($(attractive ? "attractive" : "repulsive"))  r = $(round(r, sigdigits=4)) m"
    )
end

"""
Electric potential due to a point charge.
Law: V = (1/4πε₀) · q/r
"""
function _em_electric_potential(params::Dict{Symbol,Any}) :: SolverResult
    q           = _to_f64(params[:charge])
    source      = _to_vec3(params[:source])
    field_point = _to_vec3(params[:field_point])

    r⃗ = field_point .- source
    r  = norm(r⃗)

    r ≈ 0.0 && throw(DomainError(0.0,
        "Field point coincides with source — potential diverges."))

    V = EM_k * q / r

    SolverResult(
        :electric_potential,
        Dict{Symbol,Any}(:V => V, :r_magnitude => r, :charge => q),
        Dict{Symbol,String}(:V => "V", :r_magnitude => "m", :charge => "C"),
        :electromagnetics,
        true,
        "Electric potential V = $(round(V, sigdigits=5)) V  at r = $(round(r, sigdigits=4)) m"
    )
end

"""
Net electric field via superposition of N point charges.
Law: E⃗_net = Σ (1/4πε₀) · qᵢ/rᵢ² · r̂ᵢ
"""
function _em_superposition(params::Dict{Symbol,Any}) :: SolverResult
    charges     = Vector{Float64}(params[:charges])
    raw_sources = params[:sources]     # expected: Vector of 3-vectors
    field_point = _to_vec3(params[:field_point])

    n = length(charges)
    length(raw_sources) == n || throw(ArgumentError(
        "Number of charges ($(n)) must match number of source positions ($(length(raw_sources)))."))

    E⃗_net     = zeros(Float64, 3)
    skipped   = 0

    for i in 1:n
        src = _to_vec3(raw_sources[i])
        r⃗  = field_point .- src
        r   = norm(r⃗)
        if r < 1e-15
            @warn "Superposition: charge $i is at the field point — contribution skipped."
            skipped += 1
            continue
        end
        E⃗_net .+= EM_k * charges[i] / r^2 .* (r⃗ ./ r)
    end

    E_mag = norm(E⃗_net)

    SolverResult(
        :electric_field_superposition,
        Dict{Symbol,Any}(
            :E_vector    => E⃗_net,
            :E_magnitude => E_mag,
            :n_charges   => n,
            :n_skipped   => skipped
        ),
        Dict{Symbol,String}(
            :E_vector    => "N/C",
            :E_magnitude => "N/C",
            :n_charges   => "count",
            :n_skipped   => "count"
        ),
        :electromagnetics,
        true,
        "Superposition of $n charges → |E⃗| = $(round(E_mag, sigdigits=5)) N/C" *
        (skipped > 0 ? "  ($skipped source(s) skipped)" : "")
    )
end

"""
Electric flux through a flat surface.
Law: Φ = E⃗ · A⃗ = E · A · cos(θ)
"""
function _em_flux(params::Dict{Symbol,Any}) :: SolverResult
    E⃗ = _to_vec3(params[:E_field])
    A  = _to_f64(params[:area])
    n̂  = _to_vec3(params[:normal])

    # Ensure unit normal
    n_mag = norm(n̂)
    n_mag ≈ 0.0 && throw(ArgumentError("Normal vector has zero magnitude."))
    n̂_unit = n̂ ./ n_mag

    A⃗  = A .* n̂_unit
    Φ   = dot(E⃗, A⃗)
    θ   = acos(clamp(dot(E⃗, n̂_unit) / max(norm(E⃗), 1e-30), -1.0, 1.0))

    SolverResult(
        :electric_flux,
        Dict{Symbol,Any}(:flux => Φ, :angle_rad => θ, :angle_deg => rad2deg(θ), :area => A),
        Dict{Symbol,String}(:flux => "N·m²/C", :angle_rad => "rad",
                            :angle_deg => "°", :area => "m²"),
        :electromagnetics,
        true,
        "Electric flux Φ = $(round(Φ, sigdigits=5)) N·m²/C  (θ = $(round(rad2deg(θ), digits=2))°)"
    )
end

"""
Energy stored in a charged capacitor.
Law: U = ½CV²    Q = CV
"""
function _em_capacitor_energy(params::Dict{Symbol,Any}) :: SolverResult
    C = _to_f64(params[:capacitance])
    V = _to_f64(params[:voltage])

    U = 0.5 * C * V^2
    Q = C * V

    SolverResult(
        :capacitor_energy,
        Dict{Symbol,Any}(:energy => U, :charge => Q, :capacitance => C, :voltage => V),
        Dict{Symbol,String}(:energy => "J", :charge => "C", :capacitance => "F", :voltage => "V"),
        :electromagnetics,
        true,
        "Stored energy U = $(round(U, sigdigits=5)) J,  charge Q = $(round(Q, sigdigits=5)) C"
    )
end

# ── Internal utilities (private to this file) ─────────────────────────────────

"""Convert any numeric or vector input to a Float64 scalar."""
_to_f64(x) :: Float64 = Float64(x)

"""
Convert input to a 3-element Float64 vector.
Accepts Vector, Tuple, or any iterable of length 3.
"""
function _to_vec3(v) :: Vector{Float64}
    vec = collect(Float64, v)
    length(vec) == 3 || throw(ArgumentError(
        "Expected 3D position vector [x, y, z], got length $(length(vec))."))
    vec
end
