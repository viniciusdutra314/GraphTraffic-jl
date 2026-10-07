using Graphs
using SparseArrays
using LinearAlgebra

"""Random-walk transition matrix with the target's visible region collapsed into the last, absorbing state."""
function limited_visibility_transition_matrix(
    g::SimpleGraph;
    target::Integer,
    visibility_radius::Integer,
)::SparseMatrixCSC{Float64}
    shortest_path_region = Set(neighborhood(g, target, visibility_radius))
    random_walk_region = [v for v in vertices(g) if v ∉ shortest_path_region]
    limited_visibility_transition_matrix(g, shortest_path_region, random_walk_region)
end

function limited_visibility_transition_matrix(g::SimpleGraph, shortest_path_region::Set,
                                              random_walk_region::Vector)::SparseMatrixCSC{Float64}
    id_old_to_new = Dict(v => i for (i, v) in enumerate(random_walk_region))
    # Collapse the whole shortest-path region into one absorbing state.
    supernode = length(random_walk_region) + 1
    P = spzeros(Float64, supernode, supernode)
    for u in random_walk_region
        i = id_old_to_new[u]
        p = 1.0 / degree(g, u)
        for v in neighbors(g, u)
            j = v ∈ shortest_path_region ? supernode : id_old_to_new[v]
            P[i, j] += p
        end
    end
    P[supernode, supernode] = 1.0
    return P
end

"""Expected random-walk steps until entering the target's visible region.

The region contains vertices within `visibility_radius` of `target`. The result
includes only sources outside that region, ordered by vertex ID; it excludes
the subsequent shortest-path travel to the target.
"""
function expected_visibility_region_hitting_time(
    g::SimpleGraph;
    target::Integer,
    visibility_radius::Integer,
)::Vector{Float64}
    P = limited_visibility_transition_matrix(g; target, visibility_radius)
    expected_hitting_time(P)
end

"""Expected steps to absorption for each transient state; the last state of `P` is absorbing."""
function expected_hitting_time(P::SparseMatrixCSC{Float64})::Vector{Float64}
    Q = P[1:end-1, 1:end-1]
    (I - Q) \ ones(size(Q, 1))
end

"""Expected route length from every source to `target` under limited visibility.

Routing follows a random walk outside `visibility_radius` and shortest paths
inside it. Includes both parts of the route, with zero at the target itself.
`target` and `visibility_radius` are required keyword arguments.
"""
function expected_limited_visibility_route_length(
    g::SimpleGraph; target::Integer, visibility_radius::Integer,
)::Vector{Float64}
    visibility_radius >= 0 || throw(ArgumentError("visibility_radius must be nonnegative"))
    1 <= target <= nv(g) || throw(ArgumentError("target must be a graph vertex"))
    distances = gdistances(g, target)
    all(d -> d < typemax(eltype(distances)), distances) ||
        throw(ArgumentError("graph must be connected"))
    shortest_path_region = Set(v for v in vertices(g) if distances[v] <= visibility_radius)
    random_walk_region = [v for v in vertices(g) if v ∉ shortest_path_region]
    route_lengths = Float64.(distances)
    if !isempty(random_walk_region)
        P = limited_visibility_transition_matrix(g, shortest_path_region, random_walk_region)
        hitting_times = expected_hitting_time(P)
        for (v, hitting_time) in zip(random_walk_region, hitting_times)
            # The first entry into the visible ball is at distance exactly visibility_radius.
            route_lengths[v] = hitting_time + visibility_radius
        end
    end
    route_lengths
end

"""Mean expected limited-visibility route length over all ordered, distinct source–target pairs.

All targets use the same required keyword argument `visibility_radius`.
Targets are split across worker
tasks running on at most `num_threads` Julia threads. Start Julia with
`JULIA_NUM_THREADS` greater than one to enable parallel execution.
"""
function average_expected_limited_visibility_route_length(
    g::SimpleGraph; visibility_radius::Integer,
    num_threads::Integer=Threads.nthreads(),
)::Float64
    nv(g) > 1 || throw(ArgumentError("graph must have at least two vertices"))
    visibility_radius >= 0 || throw(ArgumentError("visibility_radius must be nonnegative"))
    num_threads > 0 || throw(ArgumentError("num_threads must be positive"))
    workers = min(num_threads, Threads.nthreads(), nv(g))
    partial_sums = zeros(Float64, workers)
    @sync for worker in 1:workers
        Threads.@spawn begin
            subtotal = 0.0
            for target in worker:workers:nv(g)
                subtotal += sum(expected_limited_visibility_route_length(g; target, visibility_radius))
            end
            partial_sums[worker] = subtotal
        end
    end
    sum(partial_sums) / (nv(g) * (nv(g) - 1))
end
