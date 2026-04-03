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

# ── Physical constants ────────────────────────────────────────────────────────

const CM_G    = 6.674e-11    # m³/(kg·s²)  gravitational constant
const CM_g₀   = 9.80665      # m/s²        standard gravity (sea level)

# ── Self-registration ─────────────────────────────────────────────────────────

"""
    register_classical!()

Register all classical mechanics solvers with the Dispatcher.
Call once from main.jl during engine initialization.
"""
function register_classical!()
    register_solver!(SolverEntry(
        :projectile_motion,
        [:initial_velocity, :angle_deg, :initial_height],
        [:g],
        _cm_projectile_motion,
        "Full projectile motion: range, max height, time of flight, landing speed.",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :gravitational_force,
        [:m1, :m2, :distance],
        [],
        _cm_gravitational_force,
        "Newton's law of gravitation: F = Gm₁m₂/r².",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :kinetic_energy,
        [:mass, :velocity],
        [],
        _cm_kinetic_energy,
        "Translational KE = ½mv² and momentum p = mv.",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :work_energy,
        [:force, :displacement, :angle_deg],
        [],
        _cm_work_energy,
        "Work done by a constant force: W = F·d·cos(θ).",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :harmonic_oscillator,
        [:mass, :spring_constant],
        [:damping, :amplitude, :initial_position, :initial_velocity],
        _cm_harmonic_oscillator,
        "Spring-mass oscillator: ω, f, T, damping ratio, regime.",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :circular_motion,
        [:mass, :radius, :speed],
        [],
        _cm_circular_motion,
        "Uniform circular motion: centripetal force, acceleration, period, angular velocity.",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :elastic_collision,
        [:m1, :v1, :m2, :v2],
        [],
        _cm_elastic_collision,
        "1D elastic collision: final velocities via conservation of momentum + KE.",
        :classical_mechanics
    ))

    register_solver!(SolverEntry(
        :newtons_second_law,
        [:mass, :acceleration],
        [],
        _cm_f_equals_ma,
        "Newton's 2nd law: net force F = ma (or solve for any one quantity).",
        :classical_mechanics
    ))
end

# ── Solver implementations ────────────────────────────────────────────────────

"""
Projectile motion under uniform gravity.
Kinematics:
  x(t) = v₀cos(θ)·t
  y(t) = h₀ + v₀sin(θ)·t - ½g·t²
"""
function _cm_projectile_motion(params::Dict{Symbol,Any}) :: SolverResult
    v₀ = _to_f64(params[:initial_velocity])
    θ  = deg2rad(_to_f64(params[:angle_deg]))
    h₀ = _to_f64(params[:initial_height])
    g  = _to_f64(get(params, :g, CM_g₀))

    v₀ < 0.0 && throw(ArgumentError("initial_velocity must be non-negative."))
    !(0.0 <= θ <= π) && throw(ArgumentError("angle_deg must be in [0, 180]."))
    g <= 0.0 && throw(ArgumentError("Gravitational acceleration g must be positive."))

    v₀x = v₀ * cos(θ)
    v₀y = v₀ * sin(θ)

    # Time of flight: solve h₀ + v₀y·T - ½g·T² = 0
    discriminant = v₀y^2 + 2.0 * g * h₀
    discriminant < 0.0 && throw(DomainError(discriminant,
        "Projectile never reaches ground level — check initial height and angle."))

    T        = (v₀y + sqrt(discriminant)) / g
    R        = v₀x * T
    H_max    = h₀ + v₀y^2 / (2.0 * g)
    t_apex   = v₀y / g
    v_land_y = v₀y - g * T
    v_land   = sqrt(v₀x^2 + v_land_y^2)

    SolverResult(
        :projectile_motion,
        Dict{Symbol,Any}(
            :range           => R,
            :max_height      => H_max,
            :time_of_flight  => T,
            :time_to_apex    => t_apex,
            :v_x             => v₀x,
            :v_y_initial     => v₀y,
            :landing_speed   => v_land,
            :landing_angle   => rad2deg(atan(abs(v_land_y), v₀x))
        ),
        Dict{Symbol,String}(
            :range           => "m",
            :max_height      => "m",
            :time_of_flight  => "s",
            :time_to_apex    => "s",
            :v_x             => "m/s",
            :v_y_initial     => "m/s",
            :landing_speed   => "m/s",
            :landing_angle   => "°"
        ),
        :classical_mechanics,
        true,
        "Range = $(round(R,sigdigits=5)) m  " *
        "H_max = $(round(H_max,sigdigits=5)) m  " *
        "T = $(round(T,sigdigits=4)) s"
    )
end

"""
Newton's law of universal gravitation.
Law: F = G·m₁·m₂ / r²
"""
function _cm_gravitational_force(params::Dict{Symbol,Any}) :: SolverResult
    m1 = _to_f64(params[:m1])
    m2 = _to_f64(params[:m2])
    r  = _to_f64(params[:distance])

    (m1 <= 0.0 || m2 <= 0.0) && throw(ArgumentError("Masses must be positive."))
    r ≈ 0.0 && throw(DomainError(r, "Distance cannot be zero."))

    F = CM_G * m1 * m2 / r^2
    # Gravitational field at distance r from m1
    g_field = CM_G * m1 / r^2

    SolverResult(
        :gravitational_force,
        Dict{Symbol,Any}(:F => F, :g_field => g_field, :r => r, :m1 => m1, :m2 => m2),
        Dict{Symbol,String}(:F => "N", :g_field => "m/s²", :r => "m", :m1 => "kg", :m2 => "kg"),
        :classical_mechanics,
        true,
        "F = $(round(F, sigdigits=5)) N   g-field of m1 = $(round(g_field, sigdigits=4)) m/s²"
    )
end

"""
Translational kinetic energy and momentum.
Laws: KE = ½mv²    p = mv
"""
function _cm_kinetic_energy(params::Dict{Symbol,Any}) :: SolverResult
    m = _to_f64(params[:mass])
    v = _to_f64(params[:velocity])

    m <= 0.0 && throw(ArgumentError("Mass must be positive."))

    KE = 0.5 * m * v^2
    p  = m * v
    v_abs = abs(v)

    SolverResult(
        :kinetic_energy,
        Dict{Symbol,Any}(:KE => KE, :momentum => p, :mass => m, :speed => v_abs),
        Dict{Symbol,String}(:KE => "J", :momentum => "kg·m/s", :mass => "kg", :speed => "m/s"),
        :classical_mechanics,
        true,
        "KE = $(round(KE, sigdigits=5)) J   p = $(round(p, sigdigits=5)) kg·m/s"
    )
end

"""
Work done by a constant force.
Law: W = F · d · cos(θ)    [Work-energy theorem]
"""
function _cm_work_energy(params::Dict{Symbol,Any}) :: SolverResult
    F = _to_f64(params[:force])
    d = _to_f64(params[:displacement])
    θ = deg2rad(_to_f64(params[:angle_deg]))

    d < 0.0 && throw(ArgumentError("Displacement must be non-negative."))

    W = F * d * cos(θ)

    SolverResult(
        :work_energy,
        Dict{Symbol,Any}(:work => W, :force => F, :displacement => d,
                         :angle_deg => rad2deg(θ)),
        Dict{Symbol,String}(:work => "J", :force => "N",
                            :displacement => "m", :angle_deg => "°"),
        :classical_mechanics,
        true,
        "Work W = $(round(W, sigdigits=5)) J  (F=$(round(F,sigdigits=4)) N, d=$(round(d,sigdigits=4)) m, θ=$(round(rad2deg(θ),digits=1))°)"
    )
end

"""
Spring-mass harmonic oscillator.
Laws: ω₀ = √(k/m)    T = 2π/ω₀    ζ = b/(2√(mk))    ωd = ω₀√(1-ζ²)
"""
function _cm_harmonic_oscillator(params::Dict{Symbol,Any}) :: SolverResult
    m  = _to_f64(params[:mass])
    k  = _to_f64(params[:spring_constant])
    b  = _to_f64(get(params, :damping, 0.0))
    A  = _to_f64(get(params, :amplitude, 1.0))
    x₀ = _to_f64(get(params, :initial_position, A))
    v₀ = _to_f64(get(params, :initial_velocity, 0.0))

    m <= 0.0 && throw(ArgumentError("Mass must be positive."))
    k <= 0.0 && throw(ArgumentError("Spring constant must be positive."))
    b < 0.0  && throw(ArgumentError("Damping coefficient must be non-negative."))

    ω₀  = sqrt(k / m)
    f₀  = ω₀ / (2π)
    T₀  = 1.0 / f₀
    ζ   = b / (2.0 * sqrt(m * k))
    ωd  = ζ < 1.0 ? ω₀ * sqrt(1.0 - ζ^2) : 0.0
    fd  = ωd / (2π)

    regime = if     ζ < 1.0              "underdamped"
             elseif isapprox(ζ, 1.0)     "critically damped"
             else                         "overdamped"
             end

    # Peak kinetic and potential energy
    KE_max = 0.5 * k * A^2
    PE_max = KE_max

    SolverResult(
        :harmonic_oscillator,
        Dict{Symbol,Any}(
            :angular_frequency   => ω₀,
            :frequency_hz        => f₀,
            :period              => T₀,
            :damping_ratio       => ζ,
            :damped_ang_freq     => ωd,
            :damped_freq_hz      => fd,
            :max_KE              => KE_max,
            :max_PE              => PE_max,
            :regime              => regime
        ),
        Dict{Symbol,String}(
            :angular_frequency   => "rad/s",
            :frequency_hz        => "Hz",
            :period              => "s",
            :damping_ratio       => "dimensionless",
            :damped_ang_freq     => "rad/s",
            :damped_freq_hz      => "Hz",
            :max_KE              => "J",
            :max_PE              => "J",
            :regime              => "text"
        ),
        :classical_mechanics,
        true,
        "ω₀=$(round(ω₀,sigdigits=4)) rad/s  T=$(round(T₀,sigdigits=4)) s  " *
        "ζ=$(round(ζ,sigdigits=3))  [$regime]"
    )
end

"""
Uniform circular motion.
Laws: aₓ = v²/r    F_c = mv²/r    ω = v/r    T = 2πr/v
"""
function _cm_circular_motion(params::Dict{Symbol,Any}) :: SolverResult
    m = _to_f64(params[:mass])
    r = _to_f64(params[:radius])
    v = _to_f64(params[:speed])

    m <= 0.0 && throw(ArgumentError("Mass must be positive."))
    r <= 0.0 && throw(ArgumentError("Radius must be positive."))
    v < 0.0  && throw(ArgumentError("Speed must be non-negative."))

    a_c  = v^2 / r
    F_c  = m * a_c
    ω    = v / r
    T    = 2π * r / v
    f    = 1.0 / T

    SolverResult(
        :circular_motion,
        Dict{Symbol,Any}(
            :centripetal_force => F_c,
            :centripetal_accel => a_c,
            :angular_velocity  => ω,
            :period            => T,
            :frequency         => f
        ),
        Dict{Symbol,String}(
            :centripetal_force => "N",
            :centripetal_accel => "m/s²",
            :angular_velocity  => "rad/s",
            :period            => "s",
            :frequency         => "Hz"
        ),
        :classical_mechanics,
        true,
        "F_c = $(round(F_c,sigdigits=5)) N  ω = $(round(ω,sigdigits=4)) rad/s  T = $(round(T,sigdigits=4)) s"
    )
end

"""
1D elastic collision.
Laws: conservation of momentum AND kinetic energy.
  v₁' = ((m₁-m₂)v₁ + 2m₂v₂)/(m₁+m₂)
  v₂' = ((m₂-m₁)v₂ + 2m₁v₁)/(m₁+m₂)
"""
function _cm_elastic_collision(params::Dict{Symbol,Any}) :: SolverResult
    m1 = _to_f64(params[:m1])
    v1 = _to_f64(params[:v1])
    m2 = _to_f64(params[:m2])
    v2 = _to_f64(params[:v2])

    (m1 <= 0.0 || m2 <= 0.0) && throw(ArgumentError("Masses must be positive."))

    M  = m1 + m2
    v1_f = ((m1 - m2) * v1 + 2 * m2 * v2) / M
    v2_f = ((m2 - m1) * v2 + 2 * m1 * v1) / M

    p_before = m1 * v1 + m2 * v2
    p_after  = m1 * v1_f + m2 * v2_f
    KE_before = 0.5 * m1 * v1^2 + 0.5 * m2 * v2^2
    KE_after  = 0.5 * m1 * v1_f^2 + 0.5 * m2 * v2_f^2

    SolverResult(
        :elastic_collision,
        Dict{Symbol,Any}(
            :v1_final        => v1_f,
            :v2_final        => v2_f,
            :momentum_before => p_before,
            :momentum_after  => p_after,
            :KE_before       => KE_before,
            :KE_after        => KE_after,
            :momentum_conserved => isapprox(p_before, p_after, atol=1e-10),
            :KE_conserved       => isapprox(KE_before, KE_after, atol=1e-10)
        ),
        Dict{Symbol,String}(
            :v1_final        => "m/s",
            :v2_final        => "m/s",
            :momentum_before => "kg·m/s",
            :momentum_after  => "kg·m/s",
            :KE_before       => "J",
            :KE_after        => "J",
            :momentum_conserved => "boolean",
            :KE_conserved       => "boolean"
        ),
        :classical_mechanics,
        true,
        "v₁'=$(round(v1_f,sigdigits=4)) m/s  v₂'=$(round(v2_f,sigdigits=4)) m/s  " *
        "(momentum conserved: $(isapprox(p_before,p_after,atol=1e-10)))"
    )
end

"""
Newton's second law.
Law: F_net = m · a
"""
function _cm_f_equals_ma(params::Dict{Symbol,Any}) :: SolverResult
    m = _to_f64(params[:mass])
    a = _to_f64(params[:acceleration])

    m <= 0.0 && throw(ArgumentError("Mass must be positive."))

    F = m * a

    SolverResult(
        :newtons_second_law,
        Dict{Symbol,Any}(:force => F, :mass => m, :acceleration => a),
        Dict{Symbol,String}(:force => "N", :mass => "kg", :acceleration => "m/s²"),
        :classical_mechanics,
        true,
        "F = ma = $(round(m,sigdigits=4)) × $(round(a,sigdigits=4)) = $(round(F,sigdigits=5)) N"
    )
end

# ── Internal utilities ────────────────────────────────────────────────────────

_to_f64(x) :: Float64 = Float64(x)
