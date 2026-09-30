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
struct TestExperiment <: Experiment
    stages::Vector{Symbol}
    requested_threads::Vector{Int}
end
function simulation(experiment::TestExperiment)
    push!(experiment.stages, :simulation)
    [SimulationConfig(graph=cycle_graph(4), message_rate=rate,
                      iterations=40, warmup=5, seed=7) for rate in (0.1, 0.2)]
end
function analysis(experiment::TestExperiment, results; num_threads)
    push!(experiment.requested_threads, num_threads)
    push!(experiment.stages, :analysis)
    DataFrame([(; simulation_id=string(result.id), message_rate=result.message_rate,
                average_delay=result.average_delay) for result in values(results)])
end
function visualization(experiment::TestExperiment, table::AbstractDataFrame; directory, num_threads)
    push!(experiment.requested_threads, num_threads)
    mkpath(directory)
    push!(experiment.stages, :visualization)
    write(joinpath(directory, "plot-input.txt"), join(sort(table.message_rate), ","))
    nothing
end


@testset "Orchestrator stages and artifacts" begin
    for cascade in (false, true)
        mktempdir() do directory
            experiment = TestExperiment(Symbol[], Int[])
            run_simulation(experiment; directory, num_threads=2, cascate_pipeline=cascade)
            if !cascade
                @test experiment.stages == [:simulation]
                @test !isfile(joinpath(directory, "analysis.csv"))
                run_analysis(experiment; directory, num_threads=2)
                @test experiment.stages == [:simulation, :analysis]
                @test !isfile(joinpath(directory, "figures", "plot-input.txt"))
                @test run_visualization(experiment; directory, num_threads=2) === nothing
            end
            @test experiment.stages == [:simulation, :analysis, :visualization]
            results = load_results(joinpath(directory, "results.hdf5"))
            table = CSV.read(joinpath(directory, "analysis.csv"), DataFrame)
            @test Set(keys(results)) == Set(UUID.(table.simulation_id))
            @test Set(table.message_rate) == Set((0.1, 0.2))
            @test read(joinpath(directory, "figures", "plot-input.txt"), String) == "0.1,0.2"
            @test experiment.requested_threads == [2, 2]
            empty!(experiment.stages)
            run_analysis(experiment; directory, num_threads=3, cascate_pipeline=true, overwrite=true)
            @test experiment.stages == [:analysis, :visualization]
            @test experiment.requested_threads == [2, 2, 3, 3]
        end
    end
end

@testset "Explicit overwrite policy" begin
    mktempdir() do directory
        experiment = TestExperiment(Symbol[], Int[])
        run_simulation(experiment; directory, num_threads=1, cascate_pipeline=true)
        paths = [joinpath(directory, "results.hdf5"), joinpath(directory, "analysis.csv"),
                 joinpath(directory, "figures", "plot-input.txt")]
        original = read.(paths)
        for runner in (run_simulation, run_analysis, run_visualization)
            empty!(experiment.stages)
            @test_throws ArgumentError runner(experiment; directory, num_threads=1)
            @test isempty(experiment.stages)
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
        empty!(experiment.stages)
        @test run_simulation(experiment; directory, num_threads=1,
                             cascate_pipeline=true, overwrite=true) === nothing
        @test experiment.stages == [:simulation, :analysis, :visualization]
        @test Set(UUID.(CSV.read(paths[2], DataFrame).simulation_id)) == Set(keys(load_results(paths[1])))
    end

    # A downstream collision must be detected before an earlier stage writes.
    for existing in ("analysis.csv", joinpath("figures", "old.svg"))
        mktempdir() do directory
            path = joinpath(directory, existing)
            mkpath(dirname(path))
            write(path, "keep")
            experiment = TestExperiment(Symbol[], Int[])
            @test_throws ArgumentError run_simulation(experiment; directory,
                num_threads=1, cascate_pipeline=true)
            @test isempty(experiment.stages)
            @test !isfile(joinpath(directory, "results.hdf5"))
            @test read(path, String) == "keep"
            if startswith(existing, "figures")
                run_simulation(experiment; directory, num_threads=1)
                empty!(experiment.stages)
                @test_throws ArgumentError run_analysis(experiment; directory,
                    num_threads=1, cascate_pipeline=true)
                @test isempty(experiment.stages)
                @test !isfile(joinpath(directory, "analysis.csv"))
                @test read(path, String) == "keep"
            end
        end
    end
    mktempdir() do directory
        mkpath(joinpath(directory, "figures"))
        experiment = TestExperiment(Symbol[], Int[])
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
        @test result.average_traveling_time == 3.5 #mean(4,3)= 3.5
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
