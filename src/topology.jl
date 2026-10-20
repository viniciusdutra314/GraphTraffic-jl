using Graphs
using StatsBase

function make_graph_connected!(g::SimpleGraph)
    #efficient way to check if a component is not a tree
    #without creating a subgraph
    function has_cycle(g::SimpleGraph, component::Vector)::Bool
        m = sum(degree(g, v) for v in component) ÷ 2
        n = length(component)
        return m >= n
    end

    function cycle_edges(g::SimpleGraph, component::Vector)::Vector{Edge}
        sub, vmap = induced_subgraph(g, component)
        bridge_set = Set(bridges(sub))
        return [
            Edge(vmap[src(e)], vmap[dst(e)])
            for e in edges(sub)
            if e ∉ bridge_set
        ]
    end

    old_nv=nv(g)
    old_ne=ne(g)
    comps=connected_components(g)
    while length(comps)>1
        comps_with_cycles=filter(has_cycle,comps)
        comps_without_cycles=filter(!has_cycle,comps)
        if !isempty(comps_with_cycles)
            while true
                comp_a=sample(comps_with_cycles)
                comp_b=sample(isempty(comps_without_cycles) ? comps : comps_without_cycles) 
                comp_a != comp_b && break
            end
            edge_a=sample(cycle_edges(g,comp_a))
            edge_b=sample(edges(comp_b))
            u, v = src(edge_a), dst(edge_a)
            x, y = src(edge_b), dst(edge_b)
            #let's do a edge swap of comp_a that has x -> y
            # and comp_b has u -> v
            # creating x -> u , y -> v
            rem_edge!(g,u,v)
            rem_edge!(g,x,y)
            add_edge!(g,u,x)
            add_edge!(g,y,v)
        else
           while true
                comp_a=sample(comps)
                comp_b=sample(comps)
                comp_a != comp_b && break
           end
           #all components have no cycles so the entire graph is a forest
           #we need to add new edges
           add_edge!(g,sample(comp_a),sample(comp_b))
           @warn "Added 1 edge (degree sequence altered)."
        end
        comps=connected_components(g)
    end


    @assert old_nv == nv(g) "Graph should preserve the number of nodes"
    @assert old_ne <= ne(g) "Graph should preserve or add new edges"
    @assert is_connected(g) "Graph should be make it connected"
end