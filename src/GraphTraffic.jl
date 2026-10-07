module GraphTraffic

using Graphs
using Random
using HDF5: h5open
using JSON
using Statistics: mean
using UUIDs: UUID, uuid4

export SimulationID, SimulationConfig, SimulationResult,
       MinimalPaths, RandomWalk, LimitedVisibility, call_graphtraffic_rs, load_results,
       uniform_initial_capacity, balanced_initial_capacity,
       expected_limited_visibility_route_length,
       average_expected_limited_visibility_route_length

export Observer, ObserverEdgeQueue, ObserverEdgeReceivedMessages,
       ObserverEdgeCapacity, ObserverTotalMessages, Modifier, ModifierEdgeCapacity,
       capacity_samples, average_edge_capacity, total_edge_capacity

const SimulationID = UUID

include("instrumentation.jl")
include("config.jl")
include("protocol.jl")
include("results.jl")
include("execution.jl")
include("orchestrator.jl")
include("absorbing_markov_chain.jl")

end
