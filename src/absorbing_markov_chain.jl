using Graphs
using SparseArrays
using LinearAlgebra

function limited_visibility_transition_matrix(
    g::SimpleGraph,
    target::Integer,
    radius::Integer,
)::SparseMatrixCSC{Float64}
    shortest_path_region = Set(neighborhood(g, target, radius))
    random_walk_region = [v for v in vertices(g) if v ∉ shortest_path_region]
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

function expected_hitting_time(
    g::SimpleGraph,
    target::Integer,
    radius::Integer,
)::Vector{Float64}
    P = limited_visibility_transition_matrix(g, target, radius)
    Q = P[1:end-1, 1:end-1]
    return (I - Q) \ ones(size(Q, 1))
end