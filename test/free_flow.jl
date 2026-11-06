@testset "Free-flow observer configuration" begin
    observer = ObserverFreeFlowRate()
    @test observer isa Observer
    @test GraphTraffic.wire_observer(observer) == (; type="ObserverFreeFlowRate")
    graph = cycle_graph(4)
    config = SimulationConfig(; graph, initial_capacity=uniform_initial_capacity(graph, 1),
        message_rate=0.2, iterations=7, warmup=2, observers=[observer])
    schema = GraphTraffic.config_to_schema(config, "graph.edgelist"; capacity_path="capacity.txt")
    @test JSON.parse(JSON.json(schema))["observers"] ==
          [JSON.parse("{\"type\":\"ObserverFreeFlowRate\"}")]
end

@testset "Exact free-flow HDF5 counts" begin
    mktempdir() do directory
        path = joinpath(directory, "free_flow.hdf5")
        id, missing_id = uuid4(), uuid4()
        # Non-monotonic rows detect reordering; >2^53 and UInt64's maximum detect
        # intermediate floating-point or signed-integer conversions.
        expected = [(num_samples=UInt64(2)^53 + 1, free_flow_times=UInt64(2)^53 - 1),
                    (num_samples=typemax(UInt64), free_flow_times=typemax(UInt64)),
                    (num_samples=UInt64(0), free_flow_times=UInt64(0))]
        h5open(path, "w") do file
            create_group(file, "simulations_results/$id")["ObserverFreeFlowRate"] = expected
            create_group(file, "simulations_results/$missing_id")
        end
        rows = free_flow_counts(SimulationResult(path, id))
        @test rows == expected
        @test rows isa Vector{NamedTuple{(:num_samples, :free_flow_times),Tuple{UInt64,UInt64}}}
        @test_throws ArgumentError("ObserverFreeFlowRate was not recorded") free_flow_counts(SimulationResult(path, missing_id))
    end
end

@testset "Free-flow Rust ↔ Julia integration" begin
    mktempdir() do directory
        graph = cycle_graph(4)
        modifier = ModifierEdgeCapacity(free_flow_rate=0.8, free_flow_sampling_time=2)
        configs = [SimulationConfig(; graph, initial_capacity=uniform_initial_capacity(graph, 1),
            message_rate=0.4, iterations=7, warmup=2, seed=42,
            observers=[ObserverFreeFlowRate()], modifier=rule)
            for rule in (nothing, modifier)]
        results = call_graphtraffic_rs(configs;
            output=joinpath(directory, "observed.hdf5"), num_threads=1)
        for config in configs
            rows = free_flow_counts(results[config.id])
            @test length(rows) == ne(graph)
            @test all(row.num_samples == 7 - config.warmup for row in rows)
            @test all(0 <= row.free_flow_times <= row.num_samples for row in rows)
            meta = original_json_config(results[config.id])
            @test only(meta["observers"])["type"] == "ObserverFreeFlowRate"
        end
    end
end
