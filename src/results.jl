"""
    SimulationResult(path, id)

A lazy reference to a simulation in an HDF5 file. No open file handles or arrays
are retained. Each computed property opens the file, reads what it needs and
closes it. Keep the underlying file available for the lifetime of the result.
"""
struct SimulationResult
    path::String
    id::SimulationID
    SimulationResult(path::AbstractString, id::SimulationID) = new(abspath(path), id)
end

function read_dataset(result::SimulationResult, name::AbstractString)
    h5open(result.path, "r") do file
        read(file, "simulations_results/$(result.id)/$name")
    end
end

function metadata(result::SimulationResult)
    JSON.parse(String(read_dataset(result, "json_string")))
end

function average_ratio(rows, numerator::Symbol, denominator::Symbol)
    ratios = [Float64(getproperty(row, numerator)) / getproperty(row, denominator) 
              for row in rows if getproperty(row, denominator) != 0]
    isempty(ratios) && throw("Empty average ratio") 
    mean(ratios)
end

function Base.getproperty(result::SimulationResult, name::Symbol)
    name === :average_delay && return average_ratio(
        read_dataset(result, "vertices_attributes"), :total_traveling_time,
        :total_distance) .- 1.0
    name === :average_traveling_time && return average_ratio(
        read_dataset(result, "vertices_attributes"), :total_traveling_time,
        :num_arrived_msgs)
    name === :message_rate && return Float64(metadata(result)["message_generation"])
    name === :routing && return read_routing(metadata(result)["routing_method"])
    name === :seed && return UInt64(metadata(result)["random_seed"])
    getfield(result, name)
end

Base.propertynames(::SimulationResult, private::Bool=false) =
    (:path, :id, :average_delay, :average_traveling_time, :message_rate, :routing, :seed)

function load_results(path::AbstractString)::Dict{SimulationID,SimulationResult}
    h5open(path, "r") do file
        Dict(
            SimulationID(name) => SimulationResult(path,SimulationID(name))
            for name in keys(file["simulations_results"])
        )
    end
end
