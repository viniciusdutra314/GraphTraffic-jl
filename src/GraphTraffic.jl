module GraphTraffic

using Graphs
using HDF5: h5open
using JSON
using Statistics: mean
using UUIDs: UUID, uuid4

export SimulationID, SimulationConfig, SimulationResult,
       MinimalPaths, RandomWalk, LimitedVisibility, call_graphtraffic_rs, load_results

const SimulationID = UUID

include("config.jl")
include("protocol.jl")
include("results.jl")
include("execution.jl")
include("orchestrator.jl")

end
