using Test
using GraphTraffic
using GraphTraffic.orchestrator: Experiment, run_simulation, run_analysis, run_visualization
import GraphTraffic.orchestrator: simulation, analysis, visualization
using Graphs
using HDF5
using DataFrames: AbstractDataFrame, DataFrame
using CSV
using GraphTraffic: JSON
using UUIDs
using Random

unit_capacity(graph) = uniform_initial_capacity(graph, 1)
unit_config(; graph, kwargs...) = SimulationConfig(; graph, initial_capacity=unit_capacity(graph), kwargs...)

@testset "Limited-visibility expected routes" begin
    @testset "Triangle: geometric waiting time without visibility" begin
        # Every vertex is adjacent to the other two:
        #     1
        #    / \
        #   2---3
        # With radius 0, every step from a non-target vertex has probability
        # 1/2 of reaching the target. Failure leaves us at another non-target
        # vertex with the same probability on the next step.
        # Thus E = 1 + (1/2)E, or E = 1 / (1/2) = 2 steps.
        graph = complete_graph(3)
        success_probability = 1 / 2
        expected_random_walk_steps = 1 / success_probability
        for target in vertices(graph)
            expected_without_visibility = fill(expected_random_walk_steps, nv(graph))
            expected_without_visibility[target] = 0
            @test expected_limited_visibility_route_length(graph; target, visibility_radius=0) ≈
                  expected_without_visibility

            # Radius 1 makes every source see the target: one edge, no waiting.
            expected_with_visibility = ones(nv(graph))
            expected_with_visibility[target] = 0
            @test expected_limited_visibility_route_length(graph; target, visibility_radius=1) ≈
                  expected_with_visibility
        end
        # All distinct source-target pairs have the same expectation.
        @test average_expected_limited_visibility_route_length(graph; visibility_radius=0, num_threads=2) ≈
              expected_random_walk_steps
        @test average_expected_limited_visibility_route_length(graph; visibility_radius=1, num_threads=2) ≈ 1
    end

    @testset "Two steps remain after entering the visible region" begin
        # 1 (target) -- 2 -- 3 -- 4 (outside radius 2)
        # Source 4 must step to 3, then follow 3 -> 2 -> 1 inside visibility.
        graph = path_graph(4)
        @test GraphTraffic.expected_visibility_region_hitting_time(graph; target=1, visibility_radius=2) ≈ [1]
        routes = expected_limited_visibility_route_length(graph; target=1, visibility_radius=2)
        @test routes[4] ≈ 1 + 2 # One step to visibility, plus the full radius.
        @test routes[3] ≈ 2     # Already visible: 3 -> 2 -> 1.
    end

    @testset "Visibility at the diameter equals shortest-path distances" begin
        # At this radius, every source sees the target, so routing is entirely
        # along shortest paths. Compare exactly with Graphs.jl for every target.
        for graph in (path_graph(5), cycle_graph(6), complete_graph(4),
                      star_graph(6), complete_bipartite_graph(2, 3), grid([2, 3]))
            visibility_radius = diameter(graph)
            for target in vertices(graph)
                @test expected_limited_visibility_route_length(
                    graph; target, visibility_radius) == gdistances(graph, target)
            end
        end
    end

    @testset "Visibility expectation input errors" begin
        graph = complete_graph(3)
        @test_throws r"^UndefKeywordError: keyword argument `target` not assigned$" expected_limited_visibility_route_length(graph; visibility_radius=1)
        @test_throws r"^UndefKeywordError: keyword argument `visibility_radius` not assigned$" expected_limited_visibility_route_length(graph; target=1)
        @test_throws r"^UndefKeywordError: keyword argument `visibility_radius` not assigned$" average_expected_limited_visibility_route_length(graph)
        @test_throws ArgumentError("visibility_radius must be nonnegative") expected_limited_visibility_route_length(graph; target=1, visibility_radius=-1)
        @test_throws ArgumentError("visibility_radius must be nonnegative") average_expected_limited_visibility_route_length(graph; visibility_radius=-1)
        @test_throws ArgumentError("graph must have at least two vertices") average_expected_limited_visibility_route_length(SimpleGraph(1); visibility_radius=0)
        @test_throws ArgumentError("num_threads must be positive") average_expected_limited_visibility_route_length(graph; visibility_radius=0, num_threads=0)
    end
end

struct WeightedTestGraph <: AbstractGraph{Int}
    inner::SimpleGraph{Int}
    weight::Int
end

@testset "Uniform initial capacity" begin
    # 1 -- 2 -- 3: both edges receive exactly the requested capacity.
    graph = path_graph(3)
    capacities = uniform_initial_capacity(graph, 3)
    @test capacities == Dict(Edge(1, 2) => UInt(3), Edge(2, 3) => UInt(3))
    config = SimulationConfig(; graph, initial_capacity=capacities,
                              message_rate=0.1, iterations=10)
    @test config.initial_capacity == capacities
    @test uniform_initial_capacity(graph, UInt128(3)) == capacities
    @test uniform_initial_capacity(graph, typemax(UInt)) ==
          Dict(Edge(1, 2) => typemax(UInt), Edge(2, 3) => typemax(UInt))
    for capacity in (0, -1, big(typemax(UInt)) + 1)
        @test_throws ArgumentError("capacity_per_edge must be positive and fit UInt") uniform_initial_capacity(graph, capacity)
    end
end

@testset "Initial capacity maps" begin
    graph = path_graph(4)
    manual = Dict(Edge(2, 1) => UInt(7), Edge(2, 3) => UInt(2), Edge(4, 3) => UInt(9))
    config = SimulationConfig(; graph, initial_capacity=manual, message_rate=0.2, iterations=1)
    @test config.initial_capacity[Edge(1, 2)] == 7
    manual[Edge(2, 1)] = UInt(100)
    @test config.initial_capacity[Edge(1, 2)] == 7
    @test_throws ArgumentError("initial_capacity edges must match graph edges") SimulationConfig(; graph, initial_capacity=Dict(Edge(1, 2) => UInt(1)), message_rate=0.2, iterations=1)
    @test_throws ArgumentError("initial_capacity edges must match graph edges") SimulationConfig(; graph, initial_capacity=merge(manual, Dict(Edge(1, 4) => UInt(1))), message_rate=0.2, iterations=1)
    @test_throws ArgumentError("initial_capacity contains duplicate undirected edges") SimulationConfig(; graph, initial_capacity=merge(manual, Dict(Edge(1, 2) => UInt(1))), message_rate=0.2, iterations=1)
    @test_throws ArgumentError("initial_capacity values must be positive and fit UInt") SimulationConfig(; graph, initial_capacity=merge(manual, Dict(Edge(2, 3) => UInt(0))), message_rate=0.2, iterations=1)
    too_large = Dict(edge => UInt128(value) for (edge, value) in manual)
    too_large[Edge(2, 3)] = UInt128(typemax(UInt)) + 1
    @test_throws ArgumentError("initial_capacity values must be positive and fit UInt") SimulationConfig(; graph, initial_capacity=too_large, message_rate=0.2, iterations=1)
    for total in (3, 4, 8, 20)
        capacities = balanced_initial_capacity(graph, total; rng=MersenneTwister(42))
        @test sum(values(capacities)) == total
        @test maximum(values(capacities)) - minimum(values(capacities)) <= 1
        @test capacities == balanced_initial_capacity(graph, total; rng=MersenneTwister(42))
    end
    @test_throws ArgumentError("total_capacity must be at least the number of edges") balanced_initial_capacity(graph, 2)
    @test_throws ArgumentError("total_capacity must be positive") balanced_initial_capacity(graph, 0)
    @test_throws ArgumentError("graph must contain an edge") balanced_initial_capacity(SimpleGraph(1), 1)
    mktempdir() do dir
        graph_path = joinpath(dir, "graph.edgelist")
        capacity_path = joinpath(dir, "capacity.txt")
        GraphTraffic.write_edgelist(graph_path, config.graph;
            capacity_path, initial_capacity=config.initial_capacity)
        edge_lines = readlines(graph_path)[3:end]
        capacity_lines = parse.(Int, readlines(capacity_path))
        expected = Dict("0 1" => 7, "1 2" => 2, "2 3" => 9)
        @test Dict(zip(edge_lines, capacity_lines)) == expected
        @test GraphTraffic.config_to_schema(config, graph_path; capacity_path).initial_capacity == capacity_path
    end
end
Graphs.nv(graph::WeightedTestGraph) = nv(graph.inner)
Graphs.ne(graph::WeightedTestGraph) = ne(graph.inner)
Graphs.is_directed(::WeightedTestGraph) = false
Graphs.is_connected(graph::WeightedTestGraph) = is_connected(graph.inner)
Graphs.edges(graph::WeightedTestGraph) = edges(graph.inner)
Graphs.vertices(graph::WeightedTestGraph) = vertices(graph.inner)
Graphs.weights(graph::WeightedTestGraph) = fill(graph.weight, nv(graph), nv(graph))
Base.copy(graph::WeightedTestGraph) = WeightedTestGraph(copy(graph.inner), graph.weight)


@testset "Configuration Validation" begin
    graph = path_graph(4)
    config = unit_config(; graph, message_rate=0.2, iterations=20)
    @test config.seed === nothing
    @test_throws r"^UndefKeywordError: keyword argument `initial_capacity` not assigned$" SimulationConfig(; graph, message_rate=0.2, iterations=20)
    @test !haskey(GraphTraffic.config_to_schema(config, "graph.edgelist"; capacity_path="capacity.txt"), :random_seed)
    seeded = unit_config(graph=path_graph(3), message_rate=0.1, iterations=10, seed=42)
    @test seeded.seed === UInt64(42)
    @test GraphTraffic.config_to_schema(seeded, "graph.edgelist"; capacity_path="capacity.txt").random_seed === UInt64(42)
    rem_edge!(graph, 1, 2)
    @test ne(config.graph) == 3
    @test_throws ArgumentError("weighted edges are unsupported") SimulationConfig(
        graph=WeightedTestGraph(path_graph(3), 2), initial_capacity=Dict{Edge{Int},UInt}(), message_rate=0.1, iterations=10)
    wrapped = unit_config(graph=WeightedTestGraph(path_graph(3), 1), message_rate=0.1, iterations=10)
    @test wrapped.graph isa WeightedTestGraph
    for rate in (0, -0.1, 1.1, NaN, Inf)
        @test_throws ArgumentError("message_rate must be in (0, 1]") unit_config(
            graph=path_graph(3), message_rate=rate, iterations=10)
    end
    @test_throws ArgumentError("the simulator requires an undirected graph") SimulationConfig(
        graph=SimpleDiGraph(3), initial_capacity=Dict{Edge{Int},UInt}(), message_rate=0.1, iterations=10)
    @test_throws ArgumentError("the simulator requires a connected graph") SimulationConfig(
        graph=SimpleGraph(3), initial_capacity=Dict{Edge{Int},UInt}(), message_rate=0.1, iterations=10)
    @test_throws ArgumentError("iterations must be positive") unit_config(
        graph=path_graph(3), message_rate=0.1, iterations=0)
    @test_throws ArgumentError("warmup must be in [0, iterations)") unit_config(
        graph=path_graph(3), message_rate=0.1, iterations=10, warmup=10)
    @test_throws ArgumentError("seed must be nonnegative") unit_config(
        graph=path_graph(3), message_rate=0.1, iterations=10, seed=-1)
    @test_throws ArgumentError("visibility must be nonnegative") LimitedVisibility(-1)
    @test LimitedVisibility(0).radius == 0
    mktempdir() do dir
        path = joinpath(dir, "graph.edgelist")
        GraphTraffic.write_edgelist(path, config.graph;
            capacity_path=joinpath(dir, "capacity.txt"), initial_capacity=config.initial_capacity)
        @test readlines(path) == ["4", "3", "0 1", "1 2", "2 3"]
        @test readlines(joinpath(dir, "capacity.txt")) == ["1", "1", "1"]
    end
end

# Record stage calls to verify the wrappers and optional cascading independently.
struct TestExperiment <: Experiment
    TestExperiment() = error("experiment markers must not be instantiated")
end

# Mutable call records belong to the test fixture, never to the marker type.
const test_stages = Symbol[]
const test_requested_threads = Int[]
function reset_test_experiment()
    empty!(test_stages)
    empty!(test_requested_threads)
    TestExperiment
end
function simulation(experiment::Type{TestExperiment};
                    output::AbstractString, num_threads::Integer, overwrite::Bool=false)
    push!(test_stages, :simulation)
    push!(test_requested_threads, num_threads)
    configs = [unit_config(graph=cycle_graph(4), message_rate=rate,
                           iterations=40, warmup=5, seed=7) for rate in (0.1, 0.2)]
    call_graphtraffic_rs(configs; output, threads=num_threads, overwrite)
    nothing
end
function analysis(experiment::Type{TestExperiment}, results; num_threads)
    push!(test_requested_threads, num_threads)
    push!(test_stages, :analysis)
    DataFrame([(; simulation_id=string(result.id), message_rate=result.message_rate,
                average_delay=result.average_delay) for result in values(results)])
end
function visualization(experiment::Type{TestExperiment}, table::AbstractDataFrame; directory, num_threads)
    push!(test_requested_threads, num_threads)
    mkpath(directory)
    push!(test_stages, :visualization)
    write(joinpath(directory, "plot-input.txt"), join(sort(table.message_rate), ","))
    nothing
end


@testset "Orchestrator stages and artifacts" begin
    for cascade in (false, true)
        mktempdir() do directory
            experiment = reset_test_experiment()
            run_simulation(experiment; directory, num_threads=2, cascate_pipeline=cascade)
            if !cascade
                @test test_stages == [:simulation]
                @test !isfile(joinpath(directory, "analysis.csv"))
                run_analysis(experiment; directory, num_threads=2)
                @test test_stages == [:simulation, :analysis]
                @test !isfile(joinpath(directory, "figures", "plot-input.txt"))
                @test run_visualization(experiment; directory, num_threads=2) === nothing
            end
            @test test_stages == [:simulation, :analysis, :visualization]
            results = load_results(joinpath(directory, "results.hdf5"))
            table = CSV.read(joinpath(directory, "analysis.csv"), DataFrame)
            @test Set(keys(results)) == Set(UUID.(table.simulation_id))
            @test Set(table.message_rate) == Set((0.1, 0.2))
            @test read(joinpath(directory, "figures", "plot-input.txt"), String) == "0.1,0.2"
            @test test_requested_threads == [2, 2, 2]
            empty!(test_stages)
            run_analysis(experiment; directory, num_threads=3, cascate_pipeline=true, overwrite=true)
            @test test_stages == [:analysis, :visualization]
            @test test_requested_threads == [2, 2, 2, 3, 3]
        end
    end
end

@testset "Explicit overwrite policy" begin
    mktempdir() do directory
        experiment = reset_test_experiment()
        run_simulation(experiment; directory, num_threads=1, cascate_pipeline=true)
        paths = [joinpath(directory, "results.hdf5"), joinpath(directory, "analysis.csv"),
                 joinpath(directory, "figures", "plot-input.txt")]
        original = read.(paths)
        for (runner, output) in zip((run_simulation, run_analysis, run_visualization),
                                    (paths[1], paths[2], joinpath(directory, "figures")))
            empty!(test_stages)
            @test_throws ArgumentError("output already exists: $output; pass overwrite=true to overwrite") runner(experiment; directory, num_threads=1)
            @test isempty(test_stages)
            @test read.(paths) == original
        end
        old_ids = Set(keys(load_results(paths[1])))
        @test run_simulation(experiment; directory, num_threads=1, overwrite=true) === nothing
        @test Set(keys(load_results(paths[1]))) != old_ids
        @test read.(paths[2:3]) == original[2:3]
        write(paths[2], "old table")
        @test run_analysis(experiment; directory, num_threads=1, overwrite=true) === nothing
        @test Set(UUID.(CSV.read(paths[2], DataFrame).simulation_id)) == Set(keys(load_results(paths[1])))
        write(paths[3], "old figure")
        @test run_visualization(experiment; directory, num_threads=1, overwrite=true) === nothing
        @test read(paths[3], String) == "0.1,0.2"
        empty!(test_stages)
        @test run_simulation(experiment; directory, num_threads=1,
                             cascate_pipeline=true, overwrite=true) === nothing
        @test test_stages == [:simulation, :analysis, :visualization]
        @test Set(UUID.(CSV.read(paths[2], DataFrame).simulation_id)) == Set(keys(load_results(paths[1])))
    end

    # A downstream collision must be detected before an earlier stage writes.
    for existing in ("analysis.csv", joinpath("figures", "old.svg"))
        mktempdir() do directory
            path = joinpath(directory, existing)
            mkpath(dirname(path))
            write(path, "keep")
            experiment = reset_test_experiment()
            output = existing == "analysis.csv" ? path : joinpath(directory, "figures")
            @test_throws ArgumentError("output already exists: $output; pass overwrite=true to overwrite") run_simulation(experiment; directory,
                num_threads=1, cascate_pipeline=true)
            @test isempty(test_stages)
            @test !isfile(joinpath(directory, "results.hdf5"))
            @test read(path, String) == "keep"
            if startswith(existing, "figures")
                run_simulation(experiment; directory, num_threads=1)
                empty!(test_stages)
                output = joinpath(directory, "figures")
                @test_throws ArgumentError("output already exists: $output; pass overwrite=true to overwrite") run_analysis(experiment; directory,
                    num_threads=1, cascate_pipeline=true)
                @test isempty(test_stages)
                @test !isfile(joinpath(directory, "analysis.csv"))
                @test read(path, String) == "keep"
            end
        end
    end
    mktempdir() do directory
        mkpath(joinpath(directory, "figures"))
        experiment = reset_test_experiment()
        @test run_simulation(experiment; directory, num_threads=1,
                             cascate_pipeline=true) === nothing
        @test isfile(joinpath(directory, "figures", "plot-input.txt"))
    end
end

@testset "Lazy metrics and missing observations" begin
    mktempdir() do dir
        path = joinpath(dir, "fixture.hdf5")
        id = uuid4()
        result = SimulationResult(path, id) # The file does not exist yet.
        @test result.id == id
        rows = [(total_traveling_time=UInt64(8), total_distance=UInt64(4),
                 num_arrived_msgs=UInt64(2), num_messages_generated=UInt64(4)),
                (total_traveling_time=UInt64(9), total_distance=UInt64(3),
                 num_arrived_msgs=UInt64(3), num_messages_generated=UInt64(5)),
                (total_traveling_time=UInt64(0), total_distance=UInt64(0),
                 num_arrived_msgs=UInt64(0), num_messages_generated=UInt64(1))]
        h5open(path, "w") do file
            group = create_group(file, "simulations_results/$id")
            group["vertices_attributes"] = rows
            group["json_string"] = collect(codeunits(JSON.json((message_generation=0.2, random_seed=42, routing_method="minimal_paths"))))
        end
        @test result.average_delay == 1.5  # mean(8/4, 9/3) - 1 = 1.5.
        @test result.average_traveling_time == 17 / 5 # Packet-weighted, not a mean of vertex means.
        @test result.arrived_messages == 5     # 2 + 3 + 0.
        @test result.generated_messages == 10 # 4 + 5 + 1, including the vertex without arrivals.
        @test hasproperty(result, :arrived_messages)
        @test hasproperty(result, :generated_messages)
        @test result.message_rate == 0.2
        @test result.routing isa MinimalPaths
        @test load_results(path)[id].average_delay == 1.5

        # Lazy properties read the current file rather than caching previous totals.
        rows[3] = merge(rows[3], (; num_arrived_msgs=UInt64(1), num_messages_generated=UInt64(2)))
        h5open(path, "r+") do file
            dataset = file["simulations_results/$id/vertices_attributes"]
            write(dataset, rows)
            close(dataset)
        end
        @test result.arrived_messages == 6
        @test result.generated_messages == 11
    end
end


@testset "Real simulator process and HDF5 contract" begin
    mktempdir() do dir
        configs = [unit_config(graph=cycle_graph(6), routing=routing,
                    message_rate=rate, iterations=120, warmup=10, seed=42)
                for (routing, rate) in ((MinimalPaths(), 0.1), (RandomWalk(), 0.2), (LimitedVisibility(1), 0.3))]
        output = joinpath(dir, "results.hdf5")
        results = call_graphtraffic_rs(configs; output, threads=2)
        @test Set(keys(results)) == Set(config.id for config in configs)
        for config in configs
            result = results[config.id]
            @test result.message_rate == config.message_rate
            @test typeof(result.routing) == typeof(config.routing)
            @test result.seed == config.seed
        end
        @test_throws ArgumentError("output already exists: $output") call_graphtraffic_rs(
            configs; output)
        @test_throws ArgumentError("duplicate simulation IDs") call_graphtraffic_rs(
            [configs[1], configs[1]]; output=joinpath(dir, "duplicate.hdf5"))
        @test_throws ArgumentError("threads must be positive") call_graphtraffic_rs(
            configs; output=joinpath(dir, "threads.hdf5"), threads=0)
        appended_config = unit_config(graph=cycle_graph(6), routing=LimitedVisibility(2),
                                      message_rate=0.2, iterations=120, warmup=10, seed=42)
        appended = call_graphtraffic_rs([appended_config]; output, threads=1, append=true)
        @test Set(keys(appended)) == union(Set(keys(results)), Set([appended_config.id]))
        @test appended[appended_config.id].routing.radius == 2
        @test all(appended[id].seed == results[id].seed for id in keys(results))
        @test_throws ArgumentError("simulation IDs already exist in output") call_graphtraffic_rs(
            [configs[1]]; output, append=true)
        @test_throws ArgumentError("overwrite and append are mutually exclusive") call_graphtraffic_rs(
            [appended_config]; output, overwrite=true, append=true)
        absent = joinpath(dir, "absent.hdf5")
        @test_throws ArgumentError("append output does not exist: $absent") call_graphtraffic_rs(
            [appended_config]; output=absent, append=true)
        repeated = call_graphtraffic_rs(reverse(configs); output=joinpath(dir, "repeat.hdf5"), threads=1)
        @test all(results[id].average_delay == repeated[id].average_delay for id in keys(results))
        unseeded = unit_config(graph=cycle_graph(6), message_rate=0.1,
                                    iterations=120, warmup=10)
        unseeded_result = only(values(call_graphtraffic_rs([unseeded];
            output=joinpath(dir, "unseeded.hdf5"), threads=1)))
        @test unseeded_result.seed === nothing
    end
end

@testset "Initial capacities reach the Rust simulation" begin
    graph = path_graph(4)
    manual = Dict(Edge(2, 1) => UInt(7), Edge(2, 3) => UInt(2), Edge(4, 3) => UInt(9))
    balanced = balanced_initial_capacity(graph, 11; rng=MersenneTwister(19))
    configs = [SimulationConfig(; graph, initial_capacity=capacities,
        message_rate=0.2, iterations=1, observers=[ObserverEdgeCapacity()])
        for capacities in (manual, balanced)]
    mktempdir() do dir
        results = call_graphtraffic_rs(configs; output=joinpath(dir, "capacities.hdf5"), threads=1)
        for (config, supplied) in zip(configs, (manual, balanced))
            result = results[config.id]
            @test haskey(GraphTraffic.metadata(result), "initial_capacity")
            sample = only(capacity_samples(result))
            @test sample.iteration == 1
            h5open(result.path, "r") do file
                rows = read(file, "graphs/$(config.id)/edgelist")
                for row in rows
                    edge = Edge(Int(row.source) + 1, Int(row.target) + 1)
                    expected = get(supplied, edge, get(supplied, Edge(dst(edge), src(edge)), nothing))
                    @test sample.capacities[Int(row.edge_id) + 1] == expected
                end
            end
        end
    end
end

@testset "Typed observers and modifiers" begin
    for interval in (0, -1)
        @test_throws ArgumentError("update_interval must be positive") ObserverEdgeCapacity(update_interval=interval)
        @test_throws ArgumentError("free_flow_sampling_time must be positive") ModifierEdgeCapacity(free_flow_rate=0.8, free_flow_sampling_time=interval)
    end
    for rate in (0, -1, 1.1, NaN, Inf)
        @test_throws ArgumentError("free_flow_rate must be in (0, 1]") ModifierEdgeCapacity(free_flow_rate=rate, free_flow_sampling_time=5)
    end
    observers = Observer[ObserverEdgeQueue(), ObserverEdgeReceivedMessages(),
                         ObserverEdgeCapacity(update_interval=5), ObserverTotalMessages()]
    modifiers = [ModifierEdgeCapacity(free_flow_rate=0.9, free_flow_sampling_time=5)]
    config = unit_config(graph=cycle_graph(4), message_rate=0.2,
        iterations=40, warmup=10, observers=observers, modifiers=modifiers)
    empty!(observers)
    empty!(modifiers)
    @test length(config.observers) == 4
    @test length(config.modifiers) == 1
    plain = unit_config(graph=cycle_graph(4), message_rate=0.2, iterations=40, warmup=10)
    @test isempty(plain.observers) && isempty(plain.modifiers)
    schema = GraphTraffic.config_to_schema(config, "graph.edgelist"; capacity_path="capacity.txt")
    @test schema.observers == [(type="ObserverEdgeQueue",),
        (type="ObserverEdgeReceivedMessages",),
        (type="ObserverEdgeCapacity", update_interval=UInt64(5)), (type="ObserverTotalMessages",)]
    @test schema.modifiers == [(type="ModifierEdgeCapacity", free_flow_rate=0.9,
        free_flow_sampling_time=UInt64(5))]
    mktempdir() do directory
        results = call_graphtraffic_rs([config, plain]; output=joinpath(directory, "observed.hdf5"), threads=1)
        observed = results[config.id]
        samples = capacity_samples(observed)
        @test getproperty.(samples, :iteration) == collect(15:5:40)
        @test all(length(sample.capacities) == 4 for sample in samples)
        @test average_edge_capacity(observed) >= 1
        @test average_edge_capacity(observed; over=:final) >= 1
        @test average_edge_capacity(results[plain.id]; over=:final) == 1
        @test_throws ArgumentError("ObserverEdgeCapacity was not recorded") capacity_samples(results[plain.id])
        meta = GraphTraffic.metadata(observed)
        @test meta["observers"] == JSON.parse(JSON.json(schema.observers))
        @test meta["modifiers"] == JSON.parse(JSON.json(schema.modifiers))
        h5open(observed.path, "r") do file
            group = file["simulations_results/$(observed.id)"]
            @test length(read(group, "ObserverTotalMessages")) == 30
            for observer in ("ObserverEdgeQueue", "ObserverEdgeReceivedMessages")
                @test length(keys(group[observer])) == 4
                @test sum(read(group, "$observer/0/values")) == 30
            end
        end
    end
end

@testset "Capacity aggregation and missing samples" begin
    mktempdir() do directory
        path = joinpath(directory, "capacity.hdf5")
        id = uuid4()
        h5open(path, "w") do file
            group = create_group(file, "simulations_results/$id")
            group["edges_attributes"] = [(capacity=UInt64(9),), (capacity=UInt64(11),)]
            observer = create_group(group, "ObserverEdgeCapacity")
            for (iteration, values) in ((2, UInt64[1, 3]), (10, UInt64[5, 7]))
                create_group(observer, string(iteration))["capacities"] = values
            end
        end
        result = SimulationResult(path, id)
        @test getproperty.(capacity_samples(result), :iteration) == [2, 10]
        @test average_edge_capacity(result) == 4
        @test average_edge_capacity(result; over=:final) == 10
        @test total_edge_capacity(result) == UInt(20)
        overflow_id = uuid4()
        h5open(path, "r+") do file
            group = create_group(file, "simulations_results/$overflow_id")
            group["edges_attributes"] = [(capacity=typemax(UInt64),), (capacity=UInt64(1),)]
        end
        @test_throws ArgumentError("total edge capacity does not fit UInt") total_edge_capacity(SimulationResult(path, overflow_id))
        empty_id = uuid4()
        h5open(path, "r+") do file
            group = create_group(file, "simulations_results/$empty_id")
            create_group(group, "ObserverEdgeCapacity")
            group["vertices_attributes"] = [(total_traveling_time=UInt64(0), num_arrived_msgs=UInt64(0))]
        end
        @test isempty(capacity_samples(SimulationResult(path, empty_id)))
        @test_throws ArgumentError("no capacity samples after warmup") average_edge_capacity(SimulationResult(path, empty_id))
        @test_throws ArgumentError("no arrived packets to average") SimulationResult(path, empty_id).average_traveling_time
    end
end
