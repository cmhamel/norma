# Norma: Copyright 2025 National Technology & Engineering Solutions of
# Sandia, LLC (NTESS). Under the terms of Contract DE-NA0003525 with NTESS,
# the U.S. Government retains certain rights in this software. This software
# is released under the BSD license detailed in the file license.txt in the
# top-level Norma.jl directory.

using Printf
using YAML

include("interpolation_types.jl")
include("simulation_types.jl")
include("minitensor.jl")
include("model.jl")
include("time_integrator.jl")
include("solver.jl")
include("schwarz.jl")

function create_simulation(input_file::String)
    println("📐 Norma.jl")
    println("📝 Simulation ", input_file)
    params = YAML.load_file(input_file; dicttype=Parameters)
    params["name"] = input_file
    return create_simulation(params)
end

function create_simulation(params::Parameters)
    sim_type = params["type"]
    if sim_type == "single"
        sim = SingleDomainSimulation(params)
        create_bcs(sim)
        return sim
    elseif sim_type == "multi"
        sim = MultiDomainSimulation(params)
        create_bcs(sim)
        return sim
    else
        error("Unknown type of simulation: ", sim_type)
    end
end

function create_bcs(sim::SingleDomainSimulation)
    boundary_conditions = create_bcs(sim.params)
    for bc in boundary_conditions
        if bc isa SMDirichletInclined || bc isa SMContactSchwarzBC
            sim.model.inclined_support = true
            break
        end
    end
    return sim.model.boundary_conditions = boundary_conditions
end

function create_bcs(sim::MultiDomainSimulation)
    for subsim in sim.subsims
        create_bcs(subsim)
    end
    return pair_schwarz_bcs(sim)
end

function SingleDomainSimulation(params::Parameters)
    name = params["name"]
    input_mesh_file = params["input mesh file"]
    output_mesh_file = params["output mesh file"]
    rm(output_mesh_file; force=true)
    input_mesh = Exodus.ExodusDatabase(input_mesh_file, "r")
    Exodus.copy(input_mesh, output_mesh_file)
    output_mesh = Exodus.ExodusDatabase(output_mesh_file, "rw")
    params["output_mesh"] = output_mesh
    params["input_mesh"] = input_mesh
    controller = SolidSingleController(
        0.0, 0.0, 0, Vector{Float64}(), Vector{Float64}(), Vector{Float64}(), Vector{Float64}()
    )
    model = create_model(params)
    integrator = create_time_integrator(params, model)
    solver = create_solver(params, model)
    failed = false
    return SingleDomainSimulation(name, params, controller, integrator, solver, model, failed)
end

function MultiDomainSimulation(params::Parameters)
    name = params["name"]
    domain_names = params["domains"]
    subsims = Vector{SingleDomainSimulation}()
    controller = create_controller(params)
    initial_time = controller.initial_time
    final_time = controller.final_time
    time_step = controller.time_step
    same_step = true
    exodus_interval = get(params, "Exodus output interval", 1)
    csv_interval = get(params, "CSV output interval", 0)
    subsim_name_index_map = Dict{String,Int64}()
    subsim_index = 1
    println("  🟩 Subdomains:")
    for domain_name in domain_names
        @printf("  🧩 %s\n", domain_name)
        subparams = YAML.load_file(domain_name; dicttype=Parameters)
        subparams["name"] = domain_name
        ti_params = subparams["time integrator"]
        subsim_time_step = get(ti_params, "time step", time_step)
        subsim_time_step = min(subsim_time_step, time_step)
        ti_params["initial time"] = initial_time
        ti_params["final time"] = final_time
        ti_params["time step"] = subsim_time_step
        subparams["Exodus output interval"] = exodus_interval
        subparams["CSV output interval"] = csv_interval
        subsim = SingleDomainSimulation(subparams)
        if subsim.integrator.time_step ≠ time_step
            same_step = false
        end
        params[domain_name] = subsim.params
        push!(subsims, subsim)
        subsim_name_index_map[domain_name] = subsim_index
        subsim_index += 1
    end
    controller.same_step = same_step
    failed = false
    sim = MultiDomainSimulation(name, params, controller, subsims, subsim_name_index_map, failed)
    for subsim in sim.subsims
        subsim.params["global_simulation"] = sim
    end
    return sim
end

function get_block_connectivity(mesh::ExodusDatabase, blk_id::Integer)
    _, num_elems, num_nodes, _, _, _ = Exodus.read_block_parameters(mesh, Int32(blk_id))
    conn = Exodus.read_block_connectivity(mesh, Int32(blk_id), num_elems * num_nodes)
    return reshape(conn, (num_elems, num_nodes))
end
