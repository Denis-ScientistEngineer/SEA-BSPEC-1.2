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

# ================================================================
# FILE: solvers/electromagnetics.jl
#
# Electromagnetics Solver Module  (v2.2 — multi-variant)
#
# Every solver now supports ALL algebraic rearrangements of its
# physical equation. The Dispatcher auto-selects which variant to
# run based on what the user provides.
#
# Example — electric_field (E = kQ/r²):
#   • Provide charge + position  → computes E⃗
#   • Provide |E| + r            → computes Q
#   • Provide |E| + Q            → computes r
#   • Provide F_test + q_test    → computes |E| = F/q
#
# Physical laws:
#   Coulomb / Gauss   :  E⃗ = kQ/r² · r̂
#   Coulomb's law     :  F = kq₁q₂/r²
#   Electric potential:  V = kQ/r
#   Superposition     :  E⃗_net = Σ kqᵢ/rᵢ² · r̂ᵢ
#   Electric flux     :  Φ = E⃗ · A⃗
#   Capacitor energy  :  U = ½CV²
# ================================================================

using LinearAlgebra
using Printf

# ── Physical constants ────────────────────────────────────────────
const EM_k  = 8.9875517923e9   # N·m²/C²  (Coulomb's constant)
const EM_ε₀ = 8.854187817e-12  # F/m      (vacuum permittivity)
const EM_e  = 1.602176634e-19  # C        (elementary charge)

# ── Internal utilities ────────────────────────────────────────────
_f64(x)  = Float64(x)
function _vec3(v)::Vector{Float64}
    w = collect(Float64, v)
    length(w) == 3 || throw(ArgumentError(
        "Expected 3D vector [x,y,z], got length $(length(w))."))
    w
end

# ════════════════════════════════════════════════════════════════
# SOLVER: electric_field    E⃗ = kQ/r² · r̂
# ════════════════════════════════════════════════════════════════

function _em_ef_from_charge(p::Dict{Symbol,Any})::SolverResult
    Q   = _f64(p[:charge])
    src = _vec3(p[:source])
    fp  = _vec3(p[:field_point])
    r⃗ = fp .- src; r = norm(r⃗)
    r ≈ 0 && throw(DomainError(0, "Field point coincides with source — E diverges."))
    r̂ = r⃗ ./ r; E⃗ = EM_k * Q / r^2 .* r̂; E = norm(E⃗)
    SolverResult(:electric_field,
        Dict{Symbol,Any}(:E_vector=>E⃗, :E_magnitude=>E, :r_vector=>r⃗,
                         :r_magnitude=>r, :charge=>Q,
                         :field_direction=> Q >= 0 ? "radially outward" : "radially inward"),
        Dict{Symbol,String}(:E_vector=>"N/C", :E_magnitude=>"N/C", :r_vector=>"m",
                            :r_magnitude=>"m", :charge=>"C", :field_direction=>"text"),
        :electromagnetics, true,
        "E = $(round(E,sigdigits=5)) N/C  at r = $(round(r,sigdigits=4)) m  |  $(Q>=0 ? "+" : "")$(round(Q,sigdigits=3)) C")
end

function _em_ef_find_charge(p::Dict{Symbol,Any})::SolverResult
    E = _f64(p[:E_magnitude]); r = _f64(p[:r_magnitude])
    r <= 0 && throw(ArgumentError("r_magnitude must be positive."))
    E < 0  && throw(ArgumentError("E_magnitude must be non-negative."))
    Q = E * r^2 / EM_k
    SolverResult(:electric_field,
        Dict{Symbol,Any}(:charge=>Q, :E_magnitude=>E, :r_magnitude=>r),
        Dict{Symbol,String}(:charge=>"C", :E_magnitude=>"N/C", :r_magnitude=>"m"),
        :electromagnetics, true,
        "Q = $(round(Q,sigdigits=5)) C  produces  E = $(round(E,sigdigits=4)) N/C  at  r = $(round(r,sigdigits=4)) m")
end

function _em_ef_find_r(p::Dict{Symbol,Any})::SolverResult
    E = _f64(p[:E_magnitude]); Q = _f64(p[:charge])
    E <= 0 && throw(ArgumentError("E_magnitude must be positive."))
    Q == 0 && throw(ArgumentError("Charge Q cannot be zero."))
    r = sqrt(EM_k * abs(Q) / E)
    SolverResult(:electric_field,
        Dict{Symbol,Any}(:r_magnitude=>r, :E_magnitude=>E, :charge=>Q),
        Dict{Symbol,String}(:r_magnitude=>"m", :E_magnitude=>"N/C", :charge=>"C"),
        :electromagnetics, true,
        "r = $(round(r,sigdigits=5)) m  for  E = $(round(E,sigdigits=4)) N/C  from  Q = $(round(Q,sigdigits=4)) C")
end

function _em_ef_from_force(p::Dict{Symbol,Any})::SolverResult
    F  = _f64(p[:test_force]); qt = _f64(p[:test_charge])
    qt == 0 && throw(ArgumentError("test_charge cannot be zero."))
    E = F / qt
    SolverResult(:electric_field,
        Dict{Symbol,Any}(:E_magnitude=>E, :test_force=>F, :test_charge=>qt),
        Dict{Symbol,String}(:E_magnitude=>"N/C", :test_force=>"N", :test_charge=>"C"),
        :electromagnetics, true,
        "E = F/q = $(round(F,sigdigits=4)) / $(round(qt,sigdigits=4)) = $(round(E,sigdigits=5)) N/C")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: coulomb_force    F = kq₁q₂/r²
# ════════════════════════════════════════════════════════════════

function _em_cf_from_charges(p::Dict{Symbol,Any})::SolverResult
    q1 = _f64(p[:q1]); q2 = _f64(p[:q2])
    r1 = _vec3(p[:r1]); r2 = _vec3(p[:r2])
    r⃗ = r2 .- r1; r = norm(r⃗)
    r ≈ 0 && throw(DomainError(0, "Charges occupy the same position."))
    r̂ = r⃗ ./ r; F⃗ = EM_k * q1 * q2 / r^2 .* r̂; F = norm(F⃗)
    attractive = q1 * q2 < 0
    SolverResult(:coulomb_force,
        Dict{Symbol,Any}(:F_vector=>F⃗, :F_magnitude=>F, :r_magnitude=>r,
                         :attractive=>attractive, :q1=>q1, :q2=>q2),
        Dict{Symbol,String}(:F_vector=>"N", :F_magnitude=>"N", :r_magnitude=>"m",
                            :attractive=>"bool", :q1=>"C", :q2=>"C"),
        :electromagnetics, true,
        "F = $(round(F,sigdigits=5)) N  ($(attractive ? "attractive" : "repulsive"))  r = $(round(r,sigdigits=4)) m")
end

function _em_cf_find_q1(p::Dict{Symbol,Any})::SolverResult
    F = _f64(p[:F_magnitude]); q2 = _f64(p[:q2]); r = _f64(p[:r_magnitude])
    q2 == 0 && throw(ArgumentError("q2 cannot be zero."))
    r <= 0  && throw(ArgumentError("r_magnitude must be positive."))
    q1 = F * r^2 / (EM_k * q2)
    SolverResult(:coulomb_force,
        Dict{Symbol,Any}(:q1=>q1, :F_magnitude=>F, :q2=>q2, :r_magnitude=>r),
        Dict{Symbol,String}(:q1=>"C", :F_magnitude=>"N", :q2=>"C", :r_magnitude=>"m"),
        :electromagnetics, true,
        "q1 = $(round(q1,sigdigits=5)) C  |  F=$(round(F,sigdigits=4)) N, q2=$(round(q2,sigdigits=4)) C, r=$(round(r,sigdigits=4)) m")
end

function _em_cf_find_q2(p::Dict{Symbol,Any})::SolverResult
    F = _f64(p[:F_magnitude]); q1 = _f64(p[:q1]); r = _f64(p[:r_magnitude])
    q1 == 0 && throw(ArgumentError("q1 cannot be zero."))
    r <= 0  && throw(ArgumentError("r_magnitude must be positive."))
    q2 = F * r^2 / (EM_k * q1)
    SolverResult(:coulomb_force,
        Dict{Symbol,Any}(:q2=>q2, :F_magnitude=>F, :q1=>q1, :r_magnitude=>r),
        Dict{Symbol,String}(:q2=>"C", :F_magnitude=>"N", :q1=>"C", :r_magnitude=>"m"),
        :electromagnetics, true,
        "q2 = $(round(q2,sigdigits=5)) C  |  F=$(round(F,sigdigits=4)) N, q1=$(round(q1,sigdigits=4)) C, r=$(round(r,sigdigits=4)) m")
end

function _em_cf_find_r(p::Dict{Symbol,Any})::SolverResult
    F = _f64(p[:F_magnitude]); q1 = _f64(p[:q1]); q2 = _f64(p[:q2])
    F <= 0 && throw(ArgumentError("F_magnitude must be positive."))
    (q1 == 0 || q2 == 0) && throw(ArgumentError("Neither charge can be zero."))
    r = sqrt(EM_k * abs(q1 * q2) / F)
    SolverResult(:coulomb_force,
        Dict{Symbol,Any}(:r_magnitude=>r, :F_magnitude=>F, :q1=>q1, :q2=>q2),
        Dict{Symbol,String}(:r_magnitude=>"m", :F_magnitude=>"N", :q1=>"C", :q2=>"C"),
        :electromagnetics, true,
        "r = $(round(r,sigdigits=5)) m  for  F=$(round(F,sigdigits=4)) N  between  q1=$(round(q1,sigdigits=4)) C, q2=$(round(q2,sigdigits=4)) C")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: electric_potential    V = kQ/r
# ════════════════════════════════════════════════════════════════

function _em_ep_from_charge(p::Dict{Symbol,Any})::SolverResult
    Q  = _f64(p[:charge]); src = _vec3(p[:source]); fp = _vec3(p[:field_point])
    r  = norm(fp .- src)
    r ≈ 0 && throw(DomainError(0, "Field point at source — potential diverges."))
    V  = EM_k * Q / r
    SolverResult(:electric_potential,
        Dict{Symbol,Any}(:V=>V, :r_magnitude=>r, :charge=>Q),
        Dict{Symbol,String}(:V=>"V", :r_magnitude=>"m", :charge=>"C"),
        :electromagnetics, true,
        "V = $(round(V,sigdigits=5)) V  at  r = $(round(r,sigdigits=4)) m  from  Q = $(round(Q,sigdigits=4)) C")
end

function _em_ep_find_charge(p::Dict{Symbol,Any})::SolverResult
    V = _f64(p[:V]); r = _f64(p[:r_magnitude])
    r <= 0 && throw(ArgumentError("r_magnitude must be positive."))
    Q = V * r / EM_k
    SolverResult(:electric_potential,
        Dict{Symbol,Any}(:charge=>Q, :V=>V, :r_magnitude=>r),
        Dict{Symbol,String}(:charge=>"C", :V=>"V", :r_magnitude=>"m"),
        :electromagnetics, true,
        "Q = $(round(Q,sigdigits=5)) C  produces  V = $(round(V,sigdigits=4)) V  at  r = $(round(r,sigdigits=4)) m")
end

function _em_ep_find_r(p::Dict{Symbol,Any})::SolverResult
    V = _f64(p[:V]); Q = _f64(p[:charge])
    V == 0 && throw(ArgumentError("V cannot be zero."))
    Q == 0 && throw(ArgumentError("Charge Q cannot be zero."))
    r = EM_k * abs(Q) / abs(V)
    SolverResult(:electric_potential,
        Dict{Symbol,Any}(:r_magnitude=>r, :V=>V, :charge=>Q),
        Dict{Symbol,String}(:r_magnitude=>"m", :V=>"V", :charge=>"C"),
        :electromagnetics, true,
        "r = $(round(r,sigdigits=5)) m  where  V = $(round(V,sigdigits=4)) V  from  Q = $(round(Q,sigdigits=4)) C")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: electric_flux    Φ = E⃗ · A⃗ = EA·cos(θ)
# ════════════════════════════════════════════════════════════════

function _em_flux_from_E(p::Dict{Symbol,Any})::SolverResult
    E⃗ = _vec3(p[:E_field]); A = _f64(p[:area]); n̂_raw = _vec3(p[:normal])
    n_mag = norm(n̂_raw); n_mag ≈ 0 && throw(ArgumentError("Normal vector is zero."))
    n̂ = n̂_raw ./ n_mag
    Φ = dot(E⃗, A .* n̂)
    θ = acos(clamp(dot(E⃗, n̂) / max(norm(E⃗), 1e-30), -1.0, 1.0))
    SolverResult(:electric_flux,
        Dict{Symbol,Any}(:flux=>Φ, :angle_rad=>θ, :angle_deg=>rad2deg(θ), :area=>A),
        Dict{Symbol,String}(:flux=>"N·m²/C", :angle_rad=>"rad", :angle_deg=>"°", :area=>"m²"),
        :electromagnetics, true,
        "Φ = $(round(Φ,sigdigits=5)) N·m²/C  (θ = $(round(rad2deg(θ),digits=2))°)")
end

function _em_flux_find_E(p::Dict{Symbol,Any})::SolverResult
    Φ = _f64(p[:flux]); A = _f64(p[:area]); θ = deg2rad(_f64(p[:angle_deg]))
    A <= 0 && throw(ArgumentError("Area must be positive."))
    denom = A * cos(θ)
    abs(denom) < 1e-30 && throw(ArgumentError("cos(θ) ≈ 0: E would be infinite (field parallel to surface)."))
    E = Φ / denom
    SolverResult(:electric_flux,
        Dict{Symbol,Any}(:E_magnitude=>E, :flux=>Φ, :area=>A, :angle_deg=>rad2deg(θ)),
        Dict{Symbol,String}(:E_magnitude=>"N/C", :flux=>"N·m²/C", :area=>"m²", :angle_deg=>"°"),
        :electromagnetics, true,
        "E = $(round(E,sigdigits=5)) N/C  for  Φ = $(round(Φ,sigdigits=4)) N·m²/C  through  A = $(round(A,sigdigits=4)) m²")
end

function _em_flux_find_area(p::Dict{Symbol,Any})::SolverResult
    Φ = _f64(p[:flux]); E = _f64(p[:E_magnitude]); θ = deg2rad(_f64(p[:angle_deg]))
    E <= 0 && throw(ArgumentError("E_magnitude must be positive."))
    denom = E * cos(θ)
    abs(denom) < 1e-30 && throw(ArgumentError("cos(θ) ≈ 0: area would be infinite."))
    A = Φ / denom
    SolverResult(:electric_flux,
        Dict{Symbol,Any}(:area=>A, :flux=>Φ, :E_magnitude=>E, :angle_deg=>rad2deg(θ)),
        Dict{Symbol,String}(:area=>"m²", :flux=>"N·m²/C", :E_magnitude=>"N/C", :angle_deg=>"°"),
        :electromagnetics, true,
        "A = $(round(A,sigdigits=5)) m²  for  Φ = $(round(Φ,sigdigits=4)) N·m²/C  E = $(round(E,sigdigits=4)) N/C")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: capacitor_energy    U = ½CV²    Q = CV
# ════════════════════════════════════════════════════════════════

function _em_cap_from_CV(p::Dict{Symbol,Any})::SolverResult
    C = _f64(p[:capacitance]); V = _f64(p[:voltage])
    C <= 0 && throw(ArgumentError("Capacitance must be positive."))
    U = 0.5 * C * V^2; Q = C * V
    SolverResult(:capacitor_energy,
        Dict{Symbol,Any}(:energy=>U, :charge=>Q, :capacitance=>C, :voltage=>V),
        Dict{Symbol,String}(:energy=>"J", :charge=>"C", :capacitance=>"F", :voltage=>"V"),
        :electromagnetics, true,
        "U = $(round(U,sigdigits=5)) J  Q = $(round(Q,sigdigits=5)) C")
end

function _em_cap_find_voltage(p::Dict{Symbol,Any})::SolverResult
    U = _f64(p[:energy]); C = _f64(p[:capacitance])
    U < 0 && throw(ArgumentError("Energy must be non-negative."))
    C <= 0 && throw(ArgumentError("Capacitance must be positive."))
    V = sqrt(2U / C)
    SolverResult(:capacitor_energy,
        Dict{Symbol,Any}(:voltage=>V, :energy=>U, :capacitance=>C),
        Dict{Symbol,String}(:voltage=>"V", :energy=>"J", :capacitance=>"F"),
        :electromagnetics, true,
        "V = $(round(V,sigdigits=5)) V  for  U = $(round(U,sigdigits=4)) J  C = $(round(C,sigdigits=4)) F")
end

function _em_cap_find_capacitance(p::Dict{Symbol,Any})::SolverResult
    U = _f64(p[:energy]); V = _f64(p[:voltage])
    U < 0 && throw(ArgumentError("Energy must be non-negative."))
    V == 0 && throw(ArgumentError("Voltage cannot be zero."))
    C = 2U / V^2
    SolverResult(:capacitor_energy,
        Dict{Symbol,Any}(:capacitance=>C, :energy=>U, :voltage=>V),
        Dict{Symbol,String}(:capacitance=>"F", :energy=>"J", :voltage=>"V"),
        :electromagnetics, true,
        "C = $(round(C,sigdigits=5)) F  for  U = $(round(U,sigdigits=4)) J  V = $(round(V,sigdigits=4)) V")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: electric_field_superposition    E⃗_net = Σ kqᵢ/rᵢ² r̂ᵢ
# ════════════════════════════════════════════════════════════════

function _em_superposition(p::Dict{Symbol,Any})::SolverResult
    charges    = Vector{Float64}(p[:charges])
    raw_src    = p[:sources]
    fp         = _vec3(p[:field_point])
    n          = length(charges)
    length(raw_src) == n || throw(ArgumentError(
        "Number of charges ($n) ≠ number of source positions ($(length(raw_src)))."))
    E⃗_net = zeros(Float64, 3); skipped = 0
    for i in 1:n
        src = _vec3(raw_src[i]); r⃗ = fp .- src; r = norm(r⃗)
        if r < 1e-15; skipped += 1; continue; end
        E⃗_net .+= EM_k * charges[i] / r^2 .* (r⃗ ./ r)
    end
    E = norm(E⃗_net)
    SolverResult(:electric_field_superposition,
        Dict{Symbol,Any}(:E_vector=>E⃗_net, :E_magnitude=>E, :n_charges=>n, :n_skipped=>skipped),
        Dict{Symbol,String}(:E_vector=>"N/C", :E_magnitude=>"N/C", :n_charges=>"count", :n_skipped=>"count"),
        :electromagnetics, true,
        "Net |E⃗| = $(round(E,sigdigits=5)) N/C  from $n charge$(n==1 ? "" : "s")$(skipped>0 ? " ($skipped skipped)" : "")")
end

# ════════════════════════════════════════════════════════════════
# REGISTRATION
# ════════════════════════════════════════════════════════════════

function register_electromagnetics!()

    register_solver!(SolverEntry(
        :electric_field, :electromagnetics,
        "Electric field of a point charge — compute any variable in E⃗ = kQ/r²",
        "E⃗ = kQ/r²",
        [:charge, :source, :field_point, :E_magnitude, :r_magnitude, :test_force, :test_charge],
        [
            SolverVariant([:charge, :source, :field_point], :E_magnitude,
                _em_ef_from_charge, "Find E⃗  given Q, source position, field point"),
            SolverVariant([:E_magnitude, :r_magnitude], :charge,
                _em_ef_find_charge, "Find Q  given |E| and distance r"),
            SolverVariant([:E_magnitude, :charge], :r_magnitude,
                _em_ef_find_r,      "Find r  given |E| and charge Q"),
            SolverVariant([:test_force, :test_charge], :E_magnitude,
                _em_ef_from_force,  "Find |E|  from force on test charge  (E = F/q)"),
        ]
    ))

    register_solver!(SolverEntry(
        :coulomb_force, :electromagnetics,
        "Coulomb force between two point charges — any variable in F = kq₁q₂/r²",
        "F = kq₁q₂/r²",
        [:q1, :q2, :r1, :r2, :F_magnitude, :r_magnitude],
        [
            SolverVariant([:q1, :q2, :r1, :r2], :F_magnitude,
                _em_cf_from_charges, "Find F⃗  given q₁, q₂ and position vectors"),
            SolverVariant([:F_magnitude, :q2, :r_magnitude], :q1,
                _em_cf_find_q1,      "Find q₁  given F, q₂ and r"),
            SolverVariant([:F_magnitude, :q1, :r_magnitude], :q2,
                _em_cf_find_q2,      "Find q₂  given F, q₁ and r"),
            SolverVariant([:F_magnitude, :q1, :q2], :r_magnitude,
                _em_cf_find_r,       "Find r   given F, q₁ and q₂"),
        ]
    ))

    register_solver!(SolverEntry(
        :electric_potential, :electromagnetics,
        "Scalar electric potential — any variable in V = kQ/r",
        "V = kQ/r",
        [:charge, :source, :field_point, :V, :r_magnitude],
        [
            SolverVariant([:charge, :source, :field_point], :V,
                _em_ep_from_charge, "Find V   given Q and position"),
            SolverVariant([:V, :r_magnitude], :charge,
                _em_ep_find_charge, "Find Q   given V and r"),
            SolverVariant([:V, :charge], :r_magnitude,
                _em_ep_find_r,      "Find r   given V and Q"),
        ]
    ))

    register_solver!(SolverEntry(
        :electric_flux, :electromagnetics,
        "Electric flux through a surface — any variable in Φ = E·A·cos(θ)",
        "Φ = E·A·cos(θ)",
        [:E_field, :area, :normal, :flux, :E_magnitude, :angle_deg],
        [
            SolverVariant([:E_field, :area, :normal], :flux,
                _em_flux_from_E,    "Find Φ   given E⃗, area and surface normal"),
            SolverVariant([:flux, :area, :angle_deg], :E_magnitude,
                _em_flux_find_E,    "Find |E| given Φ, area and angle"),
            SolverVariant([:flux, :E_magnitude, :angle_deg], :area,
                _em_flux_find_area, "Find A   given Φ, |E| and angle"),
        ]
    ))

    register_solver!(SolverEntry(
        :capacitor_energy, :electromagnetics,
        "Energy stored in a capacitor — any variable in U = ½CV²",
        "U = ½CV²,  Q = CV",
        [:capacitance, :voltage, :energy],
        [
            SolverVariant([:capacitance, :voltage], :energy,
                _em_cap_from_CV,         "Find U   given C and V"),
            SolverVariant([:energy, :capacitance], :voltage,
                _em_cap_find_voltage,    "Find V   given U and C"),
            SolverVariant([:energy, :voltage], :capacitance,
                _em_cap_find_capacitance,"Find C   given U and V"),
        ]
    ))

    register_solver!(SolverEntry(
        :electric_field_superposition, :electromagnetics,
        "Net electric field from N point charges via superposition principle",
        "E⃗_net = Σ kqᵢ/rᵢ² r̂ᵢ",
        [:charges, :sources, :field_point],
        [
            SolverVariant([:charges, :sources, :field_point], :E_magnitude,
                _em_superposition, "Find E⃗_net  given array of charges and their positions"),
        ]
    ))
end