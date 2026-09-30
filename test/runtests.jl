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

struct WeightedTestGraph <: AbstractGraph{Int}
    inner::SimpleGraph{Int}
    weight::Int
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
    config = SimulationConfig(; graph, message_rate=0.2, iterations=20)
    rem_edge!(graph, 1, 2)
    @test ne(config.graph) == 3
    @test_throws ArgumentError("weighted edges are unsupported") SimulationConfig(
        graph=WeightedTestGraph(path_graph(3), 2), message_rate=0.1, iterations=10)
    wrapped = SimulationConfig(graph=WeightedTestGraph(path_graph(3), 1), message_rate=0.1, iterations=10)
    @test wrapped.graph isa WeightedTestGraph
    for rate in (0, -0.1, 1.1, NaN, Inf)
        @test_throws ArgumentError("message_rate must be in (0, 1]") SimulationConfig(
            graph=path_graph(3), message_rate=rate, iterations=10)
    end
    @test_throws ArgumentError("the simulator requires an undirected graph") SimulationConfig(
        graph=SimpleDiGraph(3), message_rate=0.1, iterations=10)
    @test_throws ArgumentError("the simulator requires a connected graph") SimulationConfig(
        graph=SimpleGraph(3), message_rate=0.1, iterations=10)
    @test_throws ArgumentError("iterations must be positive") SimulationConfig(
        graph=path_graph(3), message_rate=0.1, iterations=0)
    @test_throws ArgumentError("warmup must be in [0, iterations)") SimulationConfig(
        graph=path_graph(3), message_rate=0.1, iterations=10, warmup=10)
    @test_throws ArgumentError("seed must be nonnegative") SimulationConfig(
        graph=path_graph(3), message_rate=0.1, iterations=10, seed=-1)
    @test_throws ArgumentError("visibility must be nonnegative") LimitedVisibility(-1)
    @test LimitedVisibility(0).radius == 0
    mktempdir() do dir
        path = joinpath(dir, "graph.edgelist")
        GraphTraffic.write_edgelist(path, config.graph)
        @test readlines(path) == ["4", "3", "0 1", "1 2", "2 3"]
    end
end

# Record stage calls to verify the wrappers and optional cascading independently.
struct TestExperiment <: Experiment end

# Mutable call records belong to the test fixture, never to the marker type.
const test_stages = Symbol[]
const test_requested_threads = Int[]
function reset_test_experiment()
    empty!(test_stages)
    empty!(test_requested_threads)
    TestExperiment
end
function simulation(experiment::Type{TestExperiment})
    push!(test_stages, :simulation)
    [SimulationConfig(graph=cycle_graph(4), message_rate=rate,
                      iterations=40, warmup=5, seed=7) for rate in (0.1, 0.2)]
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
            @test test_requested_threads == [2, 2]
            empty!(test_stages)
            run_analysis(experiment; directory, num_threads=3, cascate_pipeline=true, overwrite=true)
            @test test_stages == [:analysis, :visualization]
            @test test_requested_threads == [2, 2, 3, 3]
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
        for runner in (run_simulation, run_analysis, run_visualization)
            empty!(test_stages)
            @test_throws ArgumentError runner(experiment; directory, num_threads=1)
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
            @test_throws ArgumentError run_simulation(experiment; directory,
                num_threads=1, cascate_pipeline=true)
            @test isempty(test_stages)
            @test !isfile(joinpath(directory, "results.hdf5"))
            @test read(path, String) == "keep"
            if startswith(existing, "figures")
                run_simulation(experiment; directory, num_threads=1)
                empty!(test_stages)
                @test_throws ArgumentError run_analysis(experiment; directory,
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
        rows = [(total_traveling_time=UInt64(8), total_distance=UInt64(4), num_arrived_msgs=UInt64(2)),
                (total_traveling_time=UInt64(9), total_distance=UInt64(3), num_arrived_msgs=UInt64(3)),
                (total_traveling_time=UInt64(0), total_distance=UInt64(0), num_arrived_msgs=UInt64(0))]
        h5open(path, "w") do file
            group = create_group(file, "simulations_results/$id")
            group["vertices_attributes"] = rows
            group["json_string"] = collect(codeunits(JSON.json((message_generation=0.2, random_seed=42, routing_method="minimal_paths"))))
        end
        @test result.average_delay == 1.5  # mean(8/2 -1,9/3 -1)= mean(3,2)
        @test result.average_traveling_time == 17 / 5 # Packet-weighted, not a mean of vertex means.
        @test result.message_rate == 0.2
        @test result.routing isa MinimalPaths
        @test load_results(path)[id].average_delay == 1.5
    end
end


@testset "Real simulator process and HDF5 contract" begin
    mktempdir() do dir
        configs = [SimulationConfig(graph=cycle_graph(6), routing=routing,
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
        repeated = call_graphtraffic_rs(reverse(configs); output=joinpath(dir, "repeat.hdf5"), threads=1)
        @test all(results[id].average_delay == repeated[id].average_delay for id in keys(results))
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
    config = SimulationConfig(graph=cycle_graph(4), message_rate=0.2,
        iterations=40, warmup=10, observers=observers, modifiers=modifiers)
    empty!(observers)
    empty!(modifiers)
    @test length(config.observers) == 4
    @test length(config.modifiers) == 1
    plain = SimulationConfig(graph=cycle_graph(4), message_rate=0.2, iterations=40, warmup=10)
    @test isempty(plain.observers) && isempty(plain.modifiers)
    schema = GraphTraffic.config_to_schema(config, "graph.edgelist")
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
        empty_id = uuid4()
        h5open(path, "r+") do file
            group = create_group(file, "simulations_results/$empty_id")
            create_group(group, "ObserverEdgeCapacity")
            group["vertices_attributes"] = [(total_traveling_time=UInt64(0), num_arrived_msgs=UInt64(0))]
        end
        @test isempty(capacity_samples(SimulationResult(path, empty_id)))
        @test_throws ArgumentError average_edge_capacity(SimulationResult(path, empty_id))
        @test_throws ArgumentError SimulationResult(path, empty_id).average_traveling_time
    end
end
