using Test
using GraphTraffic
using Graphs
using GraphTraffic: JSON

@testset "Simulation metadata round trip" begin
    graph = path_graph(3)
    annotations = JSON.parse("""{
        "experiment": "capacidade — réplica",
        "replicate": 3,
        "graph": {"generator": "path"},
        "values": [true, null, 0.25]
    }""")
    config = SimulationConfig(; graph,
        initial_capacity=uniform_initial_capacity(graph, 1),
        message_rate=0.5, iterations=20, seed=42, metadata=annotations)

    mktempdir() do directory
        output = joinpath(directory, "metadata.hdf5")
        result = only(values(call_graphtraffic_rs([config]; output, num_threads=1)))
        @test metadata(result)["metadata"] == annotations
    end
end
