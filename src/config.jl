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

canonical_edge(edge) = Edge(Int(min(src(edge), dst(edge))), Int(max(src(edge), dst(edge))))

function validate_initial_capacity(graph::AbstractGraph,
                                   capacities::AbstractDict{<:Edge,<:Unsigned})
    graph_edges = Set(canonical_edge(edge) for edge in edges(graph))
    capacity_edges = Set(canonical_edge(edge) for edge in keys(capacities))
    length(capacity_edges) == length(capacities) ||
        throw(ArgumentError("initial_capacity contains duplicate undirected edges"))
    capacity_edges == graph_edges ||
        throw(ArgumentError("initial_capacity edges must match graph edges"))
    all(value -> 0 < value <= typemax(UInt), values(capacities)) ||
        throw(ArgumentError("initial_capacity values must be positive and fit UInt"))
    Dict{Edge{Int},UInt}(canonical_edge(edge) => UInt(value) for (edge, value) in capacities)
end

struct SimulationConfig{G<:AbstractGraph,R<:Routing}
    id::SimulationID
    graph::G
    routing::R
    message_rate::Float64
    iterations::UInt64
    warmup::UInt64
    seed::Union{Nothing,UInt64}
    initial_capacity::Dict{Edge{Int},UInt}
    observers::Vector{Observer}
    modifiers::Vector{Modifier}
    function SimulationConfig(; graph::AbstractGraph, routing::Routing=MinimalPaths(),
                              message_rate::Real, iterations::Integer,
                              warmup::Integer=0, seed::Union{Nothing,Integer}=nothing,
                              initial_capacity::AbstractDict{<:Edge,<:Unsigned},
                              id::SimulationID=uuid4(),
                              observers::AbstractVector{<:Observer}=Observer[],
                              modifiers::AbstractVector{<:Modifier}=Modifier[])
        validate_graph(graph)
        rate = Float64(message_rate)
        0 < rate <= 1 || throw(ArgumentError("message_rate must be in (0, 1]"))
        iterations > 0 || throw(ArgumentError("iterations must be positive"))
        0 <= warmup < iterations || throw(ArgumentError("warmup must be in [0, iterations)"))
        isnothing(seed) || seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
        snapshot = copy(graph)
        capacities = validate_initial_capacity(snapshot, initial_capacity)
        new{typeof(snapshot),typeof(routing)}(id, snapshot, routing, rate,
                                              iterations, warmup, seed, capacities,
                                              Observer[observers...], Modifier[modifiers...])
    end
end

"""Distribute a positive total capacity as evenly as possible across graph edges."""
function balanced_initial_capacity(graph::AbstractGraph, total_capacity::Integer;
                                   rng::Random.AbstractRNG=Random.default_rng())
    total_capacity > 0 || throw(ArgumentError("total_capacity must be positive"))
    edge_list = collect(edges(graph))
    m = length(edge_list)
    m > 0 || throw(ArgumentError("graph must contain an edge"))
    total_capacity >= m || throw(ArgumentError("total_capacity must be at least the number of edges"))
    total_capacity <= typemax(UInt) || throw(ArgumentError("total_capacity must fit UInt"))
    q, r = divrem(UInt(total_capacity), UInt(m))
    capacities = fill(q, m)
    for i in 1:Int(r)
        capacities[i] += 1
    end
    Random.shuffle!(rng, capacities)
    Dict(zip(edge_list, capacities))
end
