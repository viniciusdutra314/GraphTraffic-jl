abstract type Routing end
struct MinimalPaths <: Routing end
struct RandomWalk <: Routing end
struct LimitedVisibility <: Routing
    radius::UInt64
    function LimitedVisibility(radius::Integer)
        radius >= 0 || throw(ArgumentError("visibility must be nonnegative"))
        new(radius)
    end
end

function validate_graph(graph::AbstractGraph)
    is_directed(graph) && throw(ArgumentError("the simulator requires an undirected graph"))
    !is_connected(graph) && throw(ArgumentError("the simulator requires a connected graph"))
    any(e -> src(e) == dst(e), edges(graph)) &&
        throw(ArgumentError("self loops are unsupported"))
    graph_weights = weights(graph)
    all(edge -> graph_weights[src(edge), dst(edge)] == 1, edges(graph)) ||
        throw(ArgumentError("weighted edges are unsupported"))
end

struct SimulationConfig{G<:AbstractGraph,R<:Routing}
    id::SimulationID
    graph::G
    routing::R
    message_rate::Float64
    iterations::UInt64
    warmup::UInt64
    seed::UInt64
    function SimulationConfig(; graph::AbstractGraph, routing::Routing=MinimalPaths(),
                              message_rate::Real, iterations::Integer,
                              warmup::Integer=0, seed::Integer=0,
                              id::SimulationID=uuid4())
        validate_graph(graph)
        rate = Float64(message_rate)
        0 < rate <= 1 || throw(ArgumentError("message_rate must be in (0, 1]"))
        iterations > 0 || throw(ArgumentError("iterations must be positive"))
        0 <= warmup < iterations || throw(ArgumentError("warmup must be in [0, iterations)"))
        seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
        snapshot = copy(graph)
        new{typeof(snapshot),typeof(routing)}(id, snapshot, routing, rate,
                                              iterations, warmup, seed)
    end
end
