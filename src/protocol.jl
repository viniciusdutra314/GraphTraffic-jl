# These are private protocol adapters, deliberately separate from the public
# constructors. A Rust schema change should not leak into experiment code.
wire_routing(::MinimalPaths) = "minimal_paths"
wire_routing(::RandomWalk) = "random_walk"
wire_routing(r::LimitedVisibility) = (; limited_visibility=r.radius)

function read_routing(value)
    value == "minimal_paths" && return MinimalPaths()
    value == "random_walk" && return RandomWalk()
    value isa AbstractDict && haskey(value, "limited_visibility") &&
        return LimitedVisibility(value["limited_visibility"])
    throw(ArgumentError("unsupported routing in simulator output: $value"))
end

function write_edgelist(path::AbstractString, graph::AbstractGraph)
    validate_graph(graph)
    #make rust happy about graph indexing [0,V)
    indices = Dict(v => i - 1 for (i, v) in enumerate(vertices(graph)))
    open(path, "w") do io
        println(io, nv(graph))
        println(io, ne(graph))
        for edge in edges(graph)
            println(io, indices[src(edge)], ' ', indices[dst(edge)])
        end
    end
end

function config_to_schema(config::SimulationConfig, graph_path::AbstractString)
    (; uuid=string(config.id), graph_file_name=abspath(graph_path),
       routing_method=wire_routing(config.routing),
       message_generation=config.message_rate, max_iterations=config.iterations,
       warm_up_iterations=config.warmup, random_seed=config.seed,
       modifiers=wire_modifier.(config.modifiers), observers=wire_observer.(config.observers))
end

wire_observer(::ObserverEdgeQueue) = (; type="ObserverEdgeQueue")
wire_observer(::ObserverEdgeReceivedMessages) = (; type="ObserverEdgeReceivedMessages")
wire_observer(::ObserverTotalMessages) = (; type="ObserverTotalMessages")
wire_observer(o::ObserverEdgeCapacity) = (; type="ObserverEdgeCapacity", update_interval=o.update_interval)
wire_modifier(m::ModifierEdgeCapacity) = (
    ; type="ModifierEdgeCapacity", free_flow_rate=m.free_flow_rate,
    free_flow_sampling_time=m.free_flow_sampling_time)
