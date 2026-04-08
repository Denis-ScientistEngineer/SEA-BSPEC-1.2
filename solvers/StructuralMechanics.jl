# FILE: solvers/SolidMechanics

# Responsibility: Contains all solvers in solid nd structural mechanics

# ------------- self-registration ----------------

function register_StructuralMechanics!()
    register_solver!(SolverEntry(
        :stress,
        [:force, :area],
        [],
        sm_stress,
        "Stress due to load acting on a cross-sectional area",
        :StructuralMechanics
    ))
end


# ------------- solver creation -----------------------
"""
STRESS
Resisting force offered by a body aginst deformation per unit area.
Within elastic limit the resisting force offered by material
is equal to applied loads(deformative forces)

Beyond this limit, the resistance offered by the material is less
than applied force and hence deformation continues until failure.

formula: stress = P/A
N/m2 1N/m2 = 1Pascal

1. Newton is a force acting on a mass of one kg and produces an acceleration of 1 m/s2 i.e.,
1 N = 1 (kg) × 1 m /s2.
"""
function sm_stress(params::Dict{Symbol, Any}) :: SolverResult
    P = _to_f64(params[:force])
    A = _to_f64(params[:area])

    stress = P/A

    SolverResult(
        :stress,
        Dict{Symbol, Any}(
            :stress => stress,
            :Load => P,
            :Area => A
        ),
        Dict{Symbol, String}(
            :stress => "N/m²",
            :Load => "N",
            :Area => "m²"
        ),
        :sm_stress,
        true,
        "The stress due load $(P) acting on a surface of area $(A) is $(stress)"
    )
end