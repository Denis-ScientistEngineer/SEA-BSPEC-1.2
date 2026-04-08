# ================================================================
# FILE: solvers/classical_mechanics.jl
#
# Classical Mechanics Solver Module
#
# Responsibility: implement the physical laws of classical mechanics.
# Self-contained physics library — receives a Dict, returns SolverResult.
#
# Physical laws implemented:
#   - Newton's second law            (F = ma)
#   - Gravitational force            (Newton's law of gravitation)
#   - Projectile motion              (kinematics under gravity)
#   - Kinetic energy + momentum      (½mv², p=mv)
#   - Work-energy theorem            (W = F·d·cosθ)
#   - Harmonic oscillator            (spring system dynamics)
#   - Circular motion                (centripetal force/acceleration)
#   - Conservation of momentum       (elastic/inelastic collision)
# ================================================================

# ================================================================
# FILE: solvers/classical_mechanics.jl
#
# Classical Mechanics Solver Module  (v2.2 — multi-variant)
#
# Every solver supports ALL algebraic rearrangements of its law.
# The Dispatcher auto-selects which variant to run.
#
# Example — Newton's second law (F = ma):
#   • Provide mass + acceleration  → computes F
#   • Provide force + mass         → computes acceleration
#   • Provide force + acceleration → computes mass
#
# Physical laws:
#   Newton 2nd  : F = ma
#   Gravitation : F = Gm₁m₂/r²
#   Projectile  : kinematics under constant gravity
#   Kinetic E   : KE = ½mv²,  p = mv
#   Work-energy : W = Fd·cos(θ)
#   Oscillator  : ω = √(k/m), damping ratio ζ
#   Circular    : Fc = mv²/r
#   Elastic col : momentum + KE conservation
# ================================================================

using Printf

# ── Physical constants ────────────────────────────────────────────
const CM_G  = 6.674e-11   # m³/(kg·s²)  gravitational constant
const CM_g₀ = 9.80665     # m/s²         standard gravity

_f(x) = Float64(x)

# ════════════════════════════════════════════════════════════════
# SOLVER: newtons_second_law    F = ma
# ════════════════════════════════════════════════════════════════

function _cm_fma_find_force(p::Dict{Symbol,Any})::SolverResult
    m = _f(p[:mass]); a = _f(p[:acceleration])
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    F = m * a
    SolverResult(:newtons_second_law,
        Dict{Symbol,Any}(:force=>F, :mass=>m, :acceleration=>a),
        Dict{Symbol,String}(:force=>"N", :mass=>"kg", :acceleration=>"m/s²"),
        :classical_mechanics, true,
        "F = ma = $(round(m,sigdigits=4)) × $(round(a,sigdigits=4)) = $(round(F,sigdigits=5)) N")
end

function _cm_fma_find_acceleration(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); m = _f(p[:mass])
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    a = F / m
    SolverResult(:newtons_second_law,
        Dict{Symbol,Any}(:acceleration=>a, :force=>F, :mass=>m),
        Dict{Symbol,String}(:acceleration=>"m/s²", :force=>"N", :mass=>"kg"),
        :classical_mechanics, true,
        "a = F/m = $(round(F,sigdigits=4)) / $(round(m,sigdigits=4)) = $(round(a,sigdigits=5)) m/s²")
end

function _cm_fma_find_mass(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); a = _f(p[:acceleration])
    a ≈ 0 && throw(ArgumentError("Acceleration cannot be zero (mass would be infinite)."))
    m = F / a
    SolverResult(:newtons_second_law,
        Dict{Symbol,Any}(:mass=>m, :force=>F, :acceleration=>a),
        Dict{Symbol,String}(:mass=>"kg", :force=>"N", :acceleration=>"m/s²"),
        :classical_mechanics, true,
        "m = F/a = $(round(F,sigdigits=4)) / $(round(a,sigdigits=4)) = $(round(m,sigdigits=5)) kg")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: kinetic_energy    KE = ½mv²,  p = mv
# ════════════════════════════════════════════════════════════════

function _cm_ke_from_mv(p::Dict{Symbol,Any})::SolverResult
    m = _f(p[:mass]); v = _f(p[:velocity])
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    KE = 0.5 * m * v^2; mom = m * v
    SolverResult(:kinetic_energy,
        Dict{Symbol,Any}(:KE=>KE, :momentum=>mom, :mass=>m, :speed=>abs(v)),
        Dict{Symbol,String}(:KE=>"J", :momentum=>"kg·m/s", :mass=>"kg", :speed=>"m/s"),
        :classical_mechanics, true,
        "KE = $(round(KE,sigdigits=5)) J   p = $(round(mom,sigdigits=5)) kg·m/s")
end

function _cm_ke_find_velocity(p::Dict{Symbol,Any})::SolverResult
    KE = _f(p[:KE]); m = _f(p[:mass])
    KE < 0 && throw(ArgumentError("Kinetic energy cannot be negative."))
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    v = sqrt(2KE / m)
    SolverResult(:kinetic_energy,
        Dict{Symbol,Any}(:velocity=>v, :KE=>KE, :mass=>m),
        Dict{Symbol,String}(:velocity=>"m/s", :KE=>"J", :mass=>"kg"),
        :classical_mechanics, true,
        "v = √(2KE/m) = $(round(v,sigdigits=5)) m/s   for  KE=$(round(KE,sigdigits=4)) J, m=$(round(m,sigdigits=4)) kg")
end

function _cm_ke_find_mass(p::Dict{Symbol,Any})::SolverResult
    KE = _f(p[:KE]); v = _f(p[:velocity])
    KE < 0 && throw(ArgumentError("Kinetic energy cannot be negative."))
    v ≈ 0 && throw(ArgumentError("Velocity cannot be zero."))
    m = 2KE / v^2
    SolverResult(:kinetic_energy,
        Dict{Symbol,Any}(:mass=>m, :KE=>KE, :velocity=>v),
        Dict{Symbol,String}(:mass=>"kg", :KE=>"J", :velocity=>"m/s"),
        :classical_mechanics, true,
        "m = 2KE/v² = $(round(m,sigdigits=5)) kg   for  KE=$(round(KE,sigdigits=4)) J, v=$(round(v,sigdigits=4)) m/s")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: gravitational_force    F = Gm₁m₂/r²
# ════════════════════════════════════════════════════════════════

function _cm_grav_find_F(p::Dict{Symbol,Any})::SolverResult
    m1 = _f(p[:m1]); m2 = _f(p[:m2]); r = _f(p[:distance])
    (m1 <= 0 || m2 <= 0) && throw(ArgumentError("Masses must be positive."))
    r ≈ 0 && throw(DomainError(r, "Distance cannot be zero."))
    F = CM_G * m1 * m2 / r^2; g_field = CM_G * m1 / r^2
    SolverResult(:gravitational_force,
        Dict{Symbol,Any}(:force=>F, :g_field=>g_field, :r=>r, :m1=>m1, :m2=>m2),
        Dict{Symbol,String}(:force=>"N", :g_field=>"m/s²", :r=>"m", :m1=>"kg", :m2=>"kg"),
        :classical_mechanics, true,
        "F = $(round(F,sigdigits=5)) N   g-field from m₁ = $(round(g_field,sigdigits=4)) m/s²")
end

function _cm_grav_find_m1(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); m2 = _f(p[:m2]); r = _f(p[:distance])
    F <= 0 && throw(ArgumentError("Force must be positive."))
    m2 <= 0 && throw(ArgumentError("m2 must be positive."))
    r ≈ 0  && throw(ArgumentError("Distance cannot be zero."))
    m1 = F * r^2 / (CM_G * m2)
    SolverResult(:gravitational_force,
        Dict{Symbol,Any}(:m1=>m1, :force=>F, :m2=>m2, :distance=>r),
        Dict{Symbol,String}(:m1=>"kg", :force=>"N", :m2=>"kg", :distance=>"m"),
        :classical_mechanics, true,
        "m₁ = $(round(m1,sigdigits=5)) kg")
end

function _cm_grav_find_m2(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); m1 = _f(p[:m1]); r = _f(p[:distance])
    F <= 0 && throw(ArgumentError("Force must be positive."))
    m1 <= 0 && throw(ArgumentError("m1 must be positive."))
    r ≈ 0  && throw(ArgumentError("Distance cannot be zero."))
    m2 = F * r^2 / (CM_G * m1)
    SolverResult(:gravitational_force,
        Dict{Symbol,Any}(:m2=>m2, :force=>F, :m1=>m1, :distance=>r),
        Dict{Symbol,String}(:m2=>"kg", :force=>"N", :m1=>"kg", :distance=>"m"),
        :classical_mechanics, true,
        "m₂ = $(round(m2,sigdigits=5)) kg")
end

function _cm_grav_find_r(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); m1 = _f(p[:m1]); m2 = _f(p[:m2])
    F <= 0 && throw(ArgumentError("Force must be positive."))
    (m1 <= 0 || m2 <= 0) && throw(ArgumentError("Masses must be positive."))
    r = sqrt(CM_G * m1 * m2 / F)
    SolverResult(:gravitational_force,
        Dict{Symbol,Any}(:distance=>r, :force=>F, :m1=>m1, :m2=>m2),
        Dict{Symbol,String}(:distance=>"m", :force=>"N", :m1=>"kg", :m2=>"kg"),
        :classical_mechanics, true,
        "r = $(round(r,sigdigits=5)) m")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: work_energy    W = F·d·cos(θ)
# ════════════════════════════════════════════════════════════════

function _cm_work_find_W(p::Dict{Symbol,Any})::SolverResult
    F = _f(p[:force]); d = _f(p[:displacement]); θ = deg2rad(_f(p[:angle_deg]))
    d < 0 && throw(ArgumentError("Displacement must be non-negative."))
    W = F * d * cos(θ)
    SolverResult(:work_energy,
        Dict{Symbol,Any}(:work=>W, :force=>F, :displacement=>d, :angle_deg=>rad2deg(θ)),
        Dict{Symbol,String}(:work=>"J", :force=>"N", :displacement=>"m", :angle_deg=>"°"),
        :classical_mechanics, true,
        "W = Fd·cos(θ) = $(round(F,sigdigits=4))×$(round(d,sigdigits=4))×cos($(round(rad2deg(θ),digits=1))°) = $(round(W,sigdigits=5)) J")
end

function _cm_work_find_force(p::Dict{Symbol,Any})::SolverResult
    W = _f(p[:work]); d = _f(p[:displacement]); θ = deg2rad(_f(p[:angle_deg]))
    d ≈ 0 && throw(ArgumentError("Displacement cannot be zero."))
    denom = d * cos(θ)
    abs(denom) < 1e-30 && throw(ArgumentError("cos(θ) ≈ 0 — force perpendicular to displacement."))
    F = W / denom
    SolverResult(:work_energy,
        Dict{Symbol,Any}(:force=>F, :work=>W, :displacement=>d, :angle_deg=>rad2deg(θ)),
        Dict{Symbol,String}(:force=>"N", :work=>"J", :displacement=>"m", :angle_deg=>"°"),
        :classical_mechanics, true,
        "F = W/(d·cos(θ)) = $(round(F,sigdigits=5)) N")
end

function _cm_work_find_disp(p::Dict{Symbol,Any})::SolverResult
    W = _f(p[:work]); F = _f(p[:force]); θ = deg2rad(_f(p[:angle_deg]))
    F ≈ 0 && throw(ArgumentError("Force cannot be zero."))
    denom = F * cos(θ)
    abs(denom) < 1e-30 && throw(ArgumentError("cos(θ) ≈ 0 — force perpendicular to displacement."))
    d = W / denom
    SolverResult(:work_energy,
        Dict{Symbol,Any}(:displacement=>d, :work=>W, :force=>F, :angle_deg=>rad2deg(θ)),
        Dict{Symbol,String}(:displacement=>"m", :work=>"J", :force=>"N", :angle_deg=>"°"),
        :classical_mechanics, true,
        "d = W/(F·cos(θ)) = $(round(d,sigdigits=5)) m")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: harmonic_oscillator    ω₀ = √(k/m)
# ════════════════════════════════════════════════════════════════

function _cm_hosc_from_mk(p::Dict{Symbol,Any})::SolverResult
    m = _f(p[:mass]); k = _f(p[:spring_constant])
    b = _f(get(p, :damping, 0.0)); A = _f(get(p, :amplitude, 1.0))
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    k <= 0 && throw(ArgumentError("Spring constant must be positive."))
    b < 0  && throw(ArgumentError("Damping must be non-negative."))
    ω₀ = sqrt(k/m); f₀ = ω₀/(2π); T₀ = 1/f₀
    ζ  = b / (2*sqrt(m*k))
    ωd = ζ < 1 ? ω₀*sqrt(1 - ζ^2) : 0.0; fd = ωd/(2π)
    regime = ζ < 1 ? "underdamped" : isapprox(ζ,1.0) ? "critically damped" : "overdamped"
    KE_max = 0.5*k*A^2
    SolverResult(:harmonic_oscillator,
        Dict{Symbol,Any}(:angular_frequency=>ω₀, :frequency_hz=>f₀, :period=>T₀,
                         :damping_ratio=>ζ, :damped_freq=>ωd, :max_KE=>KE_max, :regime=>regime),
        Dict{Symbol,String}(:angular_frequency=>"rad/s", :frequency_hz=>"Hz", :period=>"s",
                            :damping_ratio=>"—", :damped_freq=>"rad/s", :max_KE=>"J", :regime=>"text"),
        :classical_mechanics, true,
        "ω₀=$(round(ω₀,sigdigits=4)) rad/s  f=$(round(f₀,sigdigits=4)) Hz  T=$(round(T₀,sigdigits=4)) s  [$regime]")
end

function _cm_hosc_find_k(p::Dict{Symbol,Any})::SolverResult
    m = _f(p[:mass]); ω₀ = _f(p[:angular_frequency])
    m <= 0  && throw(ArgumentError("Mass must be positive."))
    ω₀ <= 0 && throw(ArgumentError("Angular frequency must be positive."))
    k = m * ω₀^2
    SolverResult(:harmonic_oscillator,
        Dict{Symbol,Any}(:spring_constant=>k, :mass=>m, :angular_frequency=>ω₀),
        Dict{Symbol,String}(:spring_constant=>"N/m", :mass=>"kg", :angular_frequency=>"rad/s"),
        :classical_mechanics, true,
        "k = mω² = $(round(m,sigdigits=4)) × $(round(ω₀,sigdigits=4))² = $(round(k,sigdigits=5)) N/m")
end

function _cm_hosc_find_mass(p::Dict{Symbol,Any})::SolverResult
    k = _f(p[:spring_constant]); ω₀ = _f(p[:angular_frequency])
    k  <= 0 && throw(ArgumentError("Spring constant must be positive."))
    ω₀ <= 0 && throw(ArgumentError("Angular frequency must be positive."))
    m = k / ω₀^2
    SolverResult(:harmonic_oscillator,
        Dict{Symbol,Any}(:mass=>m, :spring_constant=>k, :angular_frequency=>ω₀),
        Dict{Symbol,String}(:mass=>"kg", :spring_constant=>"N/m", :angular_frequency=>"rad/s"),
        :classical_mechanics, true,
        "m = k/ω² = $(round(k,sigdigits=4)) / $(round(ω₀,sigdigits=4))² = $(round(m,sigdigits=5)) kg")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: circular_motion    Fc = mv²/r
# ════════════════════════════════════════════════════════════════

function _cm_circ_find_Fc(p::Dict{Symbol,Any})::SolverResult
    m = _f(p[:mass]); r = _f(p[:radius]); v = _f(p[:speed])
    m <= 0 && throw(ArgumentError("Mass must be positive."))
    r <= 0 && throw(ArgumentError("Radius must be positive."))
    Fc = m*v^2/r; ac = v^2/r; ω = v/r; T = 2π*r/v; f = 1/T
    SolverResult(:circular_motion,
        Dict{Symbol,Any}(:centripetal_force=>Fc, :centripetal_accel=>ac,
                         :angular_velocity=>ω, :period=>T, :frequency=>f),
        Dict{Symbol,String}(:centripetal_force=>"N", :centripetal_accel=>"m/s²",
                            :angular_velocity=>"rad/s", :period=>"s", :frequency=>"Hz"),
        :classical_mechanics, true,
        "Fc = $(round(Fc,sigdigits=5)) N  ω = $(round(ω,sigdigits=4)) rad/s  T = $(round(T,sigdigits=4)) s")
end

function _cm_circ_find_speed(p::Dict{Symbol,Any})::SolverResult
    Fc = _f(p[:centripetal_force]); m = _f(p[:mass]); r = _f(p[:radius])
    Fc <= 0 && throw(ArgumentError("Centripetal force must be positive."))
    m <= 0  && throw(ArgumentError("Mass must be positive."))
    r <= 0  && throw(ArgumentError("Radius must be positive."))
    v = sqrt(Fc * r / m)
    SolverResult(:circular_motion,
        Dict{Symbol,Any}(:speed=>v, :centripetal_force=>Fc, :mass=>m, :radius=>r),
        Dict{Symbol,String}(:speed=>"m/s", :centripetal_force=>"N", :mass=>"kg", :radius=>"m"),
        :classical_mechanics, true,
        "v = √(Fc·r/m) = $(round(v,sigdigits=5)) m/s")
end

function _cm_circ_find_radius(p::Dict{Symbol,Any})::SolverResult
    Fc = _f(p[:centripetal_force]); m = _f(p[:mass]); v = _f(p[:speed])
    Fc <= 0 && throw(ArgumentError("Centripetal force must be positive."))
    m <= 0  && throw(ArgumentError("Mass must be positive."))
    v ≈ 0   && throw(ArgumentError("Speed cannot be zero."))
    r = m * v^2 / Fc
    SolverResult(:circular_motion,
        Dict{Symbol,Any}(:radius=>r, :centripetal_force=>Fc, :mass=>m, :speed=>v),
        Dict{Symbol,String}(:radius=>"m", :centripetal_force=>"N", :mass=>"kg", :speed=>"m/s"),
        :classical_mechanics, true,
        "r = mv²/Fc = $(round(r,sigdigits=5)) m")
end

function _cm_circ_find_mass(p::Dict{Symbol,Any})::SolverResult
    Fc = _f(p[:centripetal_force]); r = _f(p[:radius]); v = _f(p[:speed])
    Fc <= 0 && throw(ArgumentError("Centripetal force must be positive."))
    r  <= 0 && throw(ArgumentError("Radius must be positive."))
    v  ≈ 0  && throw(ArgumentError("Speed cannot be zero."))
    m = Fc * r / v^2
    SolverResult(:circular_motion,
        Dict{Symbol,Any}(:mass=>m, :centripetal_force=>Fc, :radius=>r, :speed=>v),
        Dict{Symbol,String}(:mass=>"kg", :centripetal_force=>"N", :radius=>"m", :speed=>"m/s"),
        :classical_mechanics, true,
        "m = Fc·r/v² = $(round(m,sigdigits=5)) kg")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: projectile_motion    kinematics under gravity
# ════════════════════════════════════════════════════════════════

function _cm_proj_full(p::Dict{Symbol,Any})::SolverResult
    v₀ = _f(p[:initial_velocity]); θ = deg2rad(_f(p[:angle_deg]))
    h₀ = _f(p[:initial_height]);   g = _f(get(p, :g, CM_g₀))
    v₀ < 0 && throw(ArgumentError("initial_velocity must be non-negative."))
    g <= 0  && throw(ArgumentError("g must be positive."))
    v₀x = v₀*cos(θ); v₀y = v₀*sin(θ)
    disc = v₀y^2 + 2g*h₀
    disc < 0 && throw(DomainError(disc, "Projectile never reaches ground — check angle and height."))
    T  = (v₀y + sqrt(disc)) / g
    R  = v₀x * T
    Hm = h₀ + v₀y^2/(2g)
    ta = v₀y / g
    vl = sqrt(v₀x^2 + (v₀y - g*T)^2)
    SolverResult(:projectile_motion,
        Dict{Symbol,Any}(:range=>R, :max_height=>Hm, :time_of_flight=>T,
                         :time_to_apex=>ta, :v_x=>v₀x, :v_y_initial=>v₀y, :landing_speed=>vl),
        Dict{Symbol,String}(:range=>"m", :max_height=>"m", :time_of_flight=>"s",
                            :time_to_apex=>"s", :v_x=>"m/s", :v_y_initial=>"m/s", :landing_speed=>"m/s"),
        :classical_mechanics, true,
        "Range=$(round(R,sigdigits=5)) m  H_max=$(round(Hm,sigdigits=5)) m  T=$(round(T,sigdigits=4)) s")
end

function _cm_proj_find_v0(p::Dict{Symbol,Any})::SolverResult
    R = _f(p[:range]); θ = deg2rad(_f(p[:angle_deg])); h₀ = _f(p[:initial_height])
    g = _f(get(p, :g, CM_g₀))
    # R = v₀cos(θ)·T  and  T = (v₀sin(θ) + √(v₀²sin²(θ)+2gh₀)) / g
    # For h₀=0: v₀ = √(Rg/sin(2θ)); for h₀≠0 solve numerically (bisection)
    sin2θ = sin(2θ)
    abs(sin2θ) < 1e-10 && throw(ArgumentError("Angle too close to 0° or 90° — degenerate trajectory."))
    if h₀ ≈ 0
        v₀ = sqrt(R * g / abs(sin2θ))
    else
        # Bisect to find v₀
        f(v) = begin
            vx = v*cos(θ); vy = v*sin(θ)
            disc = vy^2 + 2g*h₀
            disc < 0 && return -R
            T = (vy + sqrt(disc)) / g
            vx*T - R
        end
        lo, hi = 1e-3, 1e6
        for _ in 1:60
            mid = (lo+hi)/2
            f(mid) < 0 ? lo = mid : hi = mid
        end
        v₀ = (lo+hi)/2
    end
    SolverResult(:projectile_motion,
        Dict{Symbol,Any}(:initial_velocity=>v₀, :range=>R, :angle_deg=>rad2deg(θ), :initial_height=>h₀),
        Dict{Symbol,String}(:initial_velocity=>"m/s", :range=>"m", :angle_deg=>"°", :initial_height=>"m"),
        :classical_mechanics, true,
        "v₀ = $(round(v₀,sigdigits=5)) m/s  for  R=$(round(R,sigdigits=4)) m at θ=$(round(rad2deg(θ),digits=1))°")
end

# ════════════════════════════════════════════════════════════════
# SOLVER: elastic_collision    1D — p + KE conservation
# ════════════════════════════════════════════════════════════════

function _cm_elastic(p::Dict{Symbol,Any})::SolverResult
    m1 = _f(p[:m1]); v1 = _f(p[:v1]); m2 = _f(p[:m2]); v2 = _f(p[:v2])
    (m1 <= 0 || m2 <= 0) && throw(ArgumentError("Masses must be positive."))
    M = m1 + m2
    v1f = ((m1-m2)*v1 + 2m2*v2) / M
    v2f = ((m2-m1)*v2 + 2m1*v1) / M
    pb = m1*v1 + m2*v2; pa = m1*v1f + m2*v2f
    KE_b = 0.5m1*v1^2 + 0.5m2*v2^2; KE_a = 0.5m1*v1f^2 + 0.5m2*v2f^2
    SolverResult(:elastic_collision,
        Dict{Symbol,Any}(:v1_final=>v1f, :v2_final=>v2f,
                         :momentum_before=>pb, :momentum_after=>pa,
                         :KE_before=>KE_b, :KE_after=>KE_a,
                         :momentum_conserved=>isapprox(pb,pa,atol=1e-10),
                         :KE_conserved=>isapprox(KE_b,KE_a,atol=1e-10)),
        Dict{Symbol,String}(:v1_final=>"m/s", :v2_final=>"m/s",
                            :momentum_before=>"kg·m/s", :momentum_after=>"kg·m/s",
                            :KE_before=>"J", :KE_after=>"J",
                            :momentum_conserved=>"bool", :KE_conserved=>"bool"),
        :classical_mechanics, true,
        "v₁'=$(round(v1f,sigdigits=4)) m/s  v₂'=$(round(v2f,sigdigits=4)) m/s")
end

# ════════════════════════════════════════════════════════════════
# REGISTRATION
# ════════════════════════════════════════════════════════════════

function register_classical!()

    register_solver!(SolverEntry(
        :newtons_second_law, :classical_mechanics,
        "Newton's second law — any variable in F = ma",
        "F = ma",
        [:force, :mass, :acceleration],
        [
            SolverVariant([:mass, :acceleration], :force,
                _cm_fma_find_force,        "Find F  given mass and acceleration"),
            SolverVariant([:force, :mass], :acceleration,
                _cm_fma_find_acceleration, "Find a  given force and mass"),
            SolverVariant([:force, :acceleration], :mass,
                _cm_fma_find_mass,         "Find m  given force and acceleration"),
        ]
    ))

    register_solver!(SolverEntry(
        :kinetic_energy, :classical_mechanics,
        "Translational kinetic energy — any variable in KE = ½mv²",
        "KE = ½mv²,  p = mv",
        [:mass, :velocity, :KE],
        [
            SolverVariant([:mass, :velocity], :KE,
                _cm_ke_from_mv,       "Find KE  given mass and velocity"),
            SolverVariant([:KE, :mass], :velocity,
                _cm_ke_find_velocity, "Find v   given KE and mass"),
            SolverVariant([:KE, :velocity], :mass,
                _cm_ke_find_mass,     "Find m   given KE and velocity"),
        ]
    ))

    register_solver!(SolverEntry(
        :gravitational_force, :classical_mechanics,
        "Newton's universal gravitation — any variable in F = Gm₁m₂/r²",
        "F = Gm₁m₂/r²",
        [:m1, :m2, :distance, :force],
        [
            SolverVariant([:m1, :m2, :distance], :force,
                _cm_grav_find_F,  "Find F   given m₁, m₂ and r"),
            SolverVariant([:force, :m2, :distance], :m1,
                _cm_grav_find_m1, "Find m₁  given F, m₂ and r"),
            SolverVariant([:force, :m1, :distance], :m2,
                _cm_grav_find_m2, "Find m₂  given F, m₁ and r"),
            SolverVariant([:force, :m1, :m2], :distance,
                _cm_grav_find_r,  "Find r   given F, m₁ and m₂"),
        ]
    ))

    register_solver!(SolverEntry(
        :work_energy, :classical_mechanics,
        "Work done by a constant force — any variable in W = Fd·cos(θ)",
        "W = F·d·cos(θ)",
        [:force, :displacement, :angle_deg, :work],
        [
            SolverVariant([:force, :displacement, :angle_deg], :work,
                _cm_work_find_W,    "Find W  given F, d and θ"),
            SolverVariant([:work, :displacement, :angle_deg], :force,
                _cm_work_find_force,"Find F  given W, d and θ"),
            SolverVariant([:work, :force, :angle_deg], :displacement,
                _cm_work_find_disp, "Find d  given W, F and θ"),
        ]
    ))

    register_solver!(SolverEntry(
        :harmonic_oscillator, :classical_mechanics,
        "Spring-mass oscillator — any variable in ω₀ = √(k/m)",
        "ω₀ = √(k/m),  ζ = b/(2√mk)",
        [:mass, :spring_constant, :angular_frequency, :damping, :amplitude],
        [
            SolverVariant([:mass, :spring_constant], :angular_frequency,
                _cm_hosc_from_mk,  "Find ω₀, f, T, ζ  given m and k"),
            SolverVariant([:mass, :angular_frequency], :spring_constant,
                _cm_hosc_find_k,   "Find k   given m and ω₀"),
            SolverVariant([:spring_constant, :angular_frequency], :mass,
                _cm_hosc_find_mass,"Find m   given k and ω₀"),
        ]
    ))

    register_solver!(SolverEntry(
        :circular_motion, :classical_mechanics,
        "Uniform circular motion — any variable in Fc = mv²/r",
        "Fc = mv²/r,  ω = v/r",
        [:mass, :radius, :speed, :centripetal_force],
        [
            SolverVariant([:mass, :radius, :speed], :centripetal_force,
                _cm_circ_find_Fc,    "Find Fc  given m, r and v"),
            SolverVariant([:centripetal_force, :mass, :radius], :speed,
                _cm_circ_find_speed, "Find v   given Fc, m and r"),
            SolverVariant([:centripetal_force, :mass, :speed], :radius,
                _cm_circ_find_radius,"Find r   given Fc, m and v"),
            SolverVariant([:centripetal_force, :radius, :speed], :mass,
                _cm_circ_find_mass,  "Find m   given Fc, r and v"),
        ]
    ))

    register_solver!(SolverEntry(
        :projectile_motion, :classical_mechanics,
        "Projectile motion under gravity — kinematics",
        "y = h₀ + v₀sin(θ)t - ½gt²,  x = v₀cos(θ)t",
        [:initial_velocity, :angle_deg, :initial_height, :range, :g],
        [
            SolverVariant([:initial_velocity, :angle_deg, :initial_height], :range,
                _cm_proj_full,     "Find R, H_max, T  given v₀, θ and h₀"),
            SolverVariant([:range, :angle_deg, :initial_height], :initial_velocity,
                _cm_proj_find_v0,  "Find v₀  given range R, θ and h₀"),
        ]
    ))

    register_solver!(SolverEntry(
        :elastic_collision, :classical_mechanics,
        "1D elastic collision — conservation of momentum and kinetic energy",
        "v₁' = ((m₁-m₂)v₁ + 2m₂v₂)/(m₁+m₂)",
        [:m1, :v1, :m2, :v2],
        [
            SolverVariant([:m1, :v1, :m2, :v2], :v1_final,
                _cm_elastic, "Find v₁', v₂'  given m₁, v₁, m₂, v₂"),
        ]
    ))
end