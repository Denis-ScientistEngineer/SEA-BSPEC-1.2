#!/usr/bin/env julia
# ================================================================
# install.jl  —  Run this ONCE to install all required packages
#                into Julia's global environment.
#
# Usage:
#   julia install.jl
#
# After this succeeds, run the web GUI with:
#   julia gui_web.jl
# ================================================================

using Pkg

println("\n  B-SPEC — Installing required packages")
println("  " * "─"^42)

# Update registry first so packages can be found
println("\n  [1/3] Updating package registry...")
try
    Pkg.Registry.update()
    println("        ✓ Registry updated")
catch e
    println("        ⚠ Registry update failed (no internet?), trying anyway...")
end

# Install into GLOBAL environment (no Project.toml needed)
println("\n  [2/3] Installing HTTP.jl...")
Pkg.add("HTTP")
println("        ✓ HTTP installed")

println("\n  [3/3] Installing Revise.jl...")
Pkg.add("Revise")
println("        ✓ Revise installed")

println("\n  " * "─"^42)
println("  ✓ All packages installed.")
println("\n  Now run:  julia gui_web.jl")
println("  Then open: http://localhost:8050\n")
