module Topology
using Graphs
using Random
using IGraphs
using Colors

export make_graph_connected!,graph_type_to_colors,watts_strogatz_given_m,random_geometric_graph,avg_distance,edge_betweeness_normalized

const graph_type_to_colors=Dict{String,RGB}(
    "barabasi" => RGB(1.0,0.0,0.0),
    "erdos" => RGB(0.0,0.0,1.0),
    "geometrico" => RGB(0.0,1.0,0.0),
    "watts" => RGB(0.569, 0.255, 0.675)
)


"""
    make_graph_connected!(g::SimpleGraph; rng=Random.default_rng())

Connect a nonempty graph in place and return `g`. Prefer degree-preserving
edge swaps; add an edge only when no swap between components is possible.
"""
function make_graph_connected!(g::SimpleGraph; rng::AbstractRNG=Random.default_rng())
    nv(g) > 0 || throw(ArgumentError("graph must contain at least one vertex"))

    # A connected component is a tree exactly when m == n - 1.
    function has_cycle(g::SimpleGraph, component::Vector)::Bool
        m = sum(degree(g, v) for v in component) ÷ 2
        return m >= length(component)
    end

    function cycle_edges(g::SimpleGraph, component::Vector)
        sub, vmap = induced_subgraph(g, component)
        bridge_set = Set(bridges(sub))
        return [
            Edge(vmap[src(e)], vmap[dst(e)])
            for e in edges(sub)
            if e ∉ bridge_set
        ]
    end

    old_nv = nv(g)
    old_ne = ne(g)
    comps = connected_components(g)
    while length(comps) > 1
        comps_with_cycles = filter(c -> has_cycle(g, c), comps)
        # Isolated vertices cannot supply an edge for a swap :(
        trees_with_edges = filter(c -> length(c) > 1 && !has_cycle(g, c), comps)
        if !isempty(comps_with_cycles) &&
           (!isempty(trees_with_edges) || length(comps_with_cycles) > 1)
            comp_a = rand(rng, comps_with_cycles)
            # Prefer trees, otherwise choose a different cyclic component.
            # Sampling eligible candidates directly avoids rejection loops.
            candidates_b = isempty(trees_with_edges) ?
                filter(c -> c != comp_a, comps_with_cycles) : trees_with_edges
            comp_b = rand(rng, candidates_b)
            edge_a = rand(rng, cycle_edges(g, comp_a))
            sub_b, vmap_b = induced_subgraph(g, comp_b)
            edge_b = rand(rng, collect(edges(sub_b)))
            u, v = src(edge_a), dst(edge_a)
            x, y = vmap_b[src(edge_b)], vmap_b[dst(edge_b)]
            # Removing a non-bridge keeps A connected. Even if removing B's
            # edge splits B, both pieces reconnect through A. 
            rem_edge!(g, u, v)
            rem_edge!(g, x, y)
            add_edge!(g, u, x)
            add_edge!(g, y, v)
        else
            comp_a = rand(rng, comps)
            comp_b = rand(rng, filter(c -> c != comp_a, comps))
            # No eligible swap remains: forests and isolated vertices need
            # an addition.
            add_edge!(g, rand(rng, comp_a), rand(rng, comp_b))
           @warn "Added 1 edge (degree sequence altered)."
        end
        new_comps = connected_components(g)
        @assert length(new_comps) == length(comps) - 1 "Each operation must join exactly two components"
        comps = new_comps
    end

    @assert old_nv == nv(g) "Graph should preserve the number of nodes"
    @assert old_ne <= ne(g) "Graph should preserve or add new edges"
    @assert is_connected(g) "Graph should be connected"
    return g
end

function random_geometric_graph(n::Integer, m_expected::Integer;
    r::AbstractFloat=sqrt(2 * m_expected / (pi * n * (n - 1)))
)::SimpleGraph
    g, _ = Graphs.euclidean_graph(n, 2, cutoff=r)
    return g
end

function watts_strogatz_given_m(n::Integer, m::Integer, β::AbstractFloat)::SimpleGraph
    k = div(2m, n)
    if !iseven(k)
        k += 1
    end
    return Graphs.watts_strogatz(n, k, β)
end


function avg_distance(g::SimpleGraph)::Float64
    converted_graph::IGraphs.IGraph = IGraphs.IGraph(g)
    IGraphs.LibIGraph.average_path_length(
        converted_graph, IGraphs.IGNull(),
        false, false)[1]
end

function edge_betweeness_normalized(g::SimpleGraph)::Vector{Float64}
    result = Ref{IGraphs.LibIGraph.igraph_vector_t}()
    IGraphs.LibIGraph.igraph_vector_init(result, Graphs.ne(g))
    converted_graph::IGraphs.IGraph = IGraphs.IGraph(g)
    IGraphs.LibIGraph.igraph_edge_betweenness(converted_graph.objref, C_NULL, result,
        IGraphs.LibIGraph.igraph_ess_all(IGraphs.LibIGraph.IGRAPH_EDGEORDER_ID),
        false, true)
    result_vec = Vector{Float64}(undef, Graphs.ne(g))
    for i in 1:Graphs.ne(g)
        result_vec[i] = IGraphs.LibIGraph.igraph_vector_get(result, i - 1)
    end
    return result_vec
end
end 