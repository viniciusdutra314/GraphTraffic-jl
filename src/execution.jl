struct Simulator
    executable_path::String
    function Simulator(executable_path::AbstractString)
        resolved = isfile(executable_path) ? abspath(executable_path) : Sys.which(executable_path)
        isnothing(resolved) && throw(ArgumentError("simulator executable not found: $executable_path"))
        new(resolved)
    end
end

function simulate(simulator::Simulator, configs::AbstractVector{<:SimulationConfig};
                  output::AbstractString, threads::Integer=max(1,Sys.CPU_THREADS ÷ 2 ), overwrite::Bool=false)
    isempty(configs) && throw(ArgumentError("configs must contain at least one simulation"))
    threads > 0 || throw(ArgumentError("threads must be positive"))
    ids = Set(config.id for config in configs)
    length(ids) == length(configs) || throw(ArgumentError("duplicate simulation IDs"))
    destination = abspath(output)
    endswith(lowercase(destination), ".hdf5") || throw(ArgumentError("output must end in .hdf5"))
    ispath(destination) && !overwrite && throw(ArgumentError("output already exists: $destination"))
    mkpath(dirname(destination))
    mktempdir(dirname(destination)) do directory
        jsons_values = map(configs) do config
            graph_path = joinpath(directory, "$(config.id).edgelist")
            write_edgelist(graph_path, config.graph)
            config_to_schema(config, graph_path)
        end
        json_path = joinpath(directory, "config.json")
        open(json_path, "w") do io
            JSON.json(io, jsons_values)
        end
        temporary_output = joinpath(directory, "results.hdf5")
        run(`$(simulator.executable_path) $json_path --output-file-hdf5 $temporary_output --threads $threads`)
        mv(temporary_output, destination; force=overwrite)
    end
    load_results(destination)
end

