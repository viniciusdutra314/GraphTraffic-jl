@testset "Connect graph by swaps and additions" begin
    function topology_graph(n, edge_pairs)
        g = SimpleGraph(n)
        for (u, v) in edge_pairs
            add_edge!(g, u, v)
        end
        return g
    end

    triangle = [(1, 2), (2, 3), (1, 3)]
    cases = [
        ("triangle + edge", 5, [triangle; [(4, 5)]], 0),
        ("two cycles", 6, [triangle; [(4, 5), (5, 6), (4, 6)]], 0),
        ("cycle + path", 7, [triangle; [(4, 5), (5, 6), (6, 7)]], 0),
        ("cycle with bridge + edge", 6, [triangle; [(3, 4), (5, 6)]], 0),
        # Both subgraphs renumber their vertices; swaps must use original IDs.
        ("nonconsecutive vertex IDs", 7,
         [(2, 5), (5, 7), (2, 7), (1, 3), (3, 4), (4, 6)], 0),
        ("two edges", 4, [(1, 2), (3, 4)], 1),
        ("path + star + isolate", 8,
         [(1, 2), (2, 3), (4, 5), (4, 6), (4, 7)], 2),
        ("only isolates", 4, Tuple{Int,Int}[], 3),
        ("cycle + isolate", 4, triangle, 1),
        ("tree + isolates", 5, [(1, 2), (2, 3)], 2),
        ("two cycles + isolate", 7,
         [triangle; [(4, 5), (5, 6), (4, 6)]], 1),
        ("mixed components", 10,
         [triangle; [(4, 5), (6, 7), (7, 8)]], 3),
    ]

    for (name, n, edge_pairs, additions) in cases
        @testset "$name" begin
            for seed in 1:20
                g = topology_graph(n, edge_pairs)
                old_degrees = degree(g)
                old_edges = ne(g)
                expected_logs = fill((:warn, "Added 1 edge (degree sequence altered)."), additions)
                result = @test_logs expected_logs... GraphTraffic.Topology.make_graph_connected!(
                    g; rng=MersenneTwister(seed))
                @test result === g
                @test nv(g) == n
                @test is_connected(g)
                @test ne(g) == old_edges + additions
                @test all(degree(g) .>= old_degrees)
                @test sum(degree(g) .- old_degrees) == 2 * additions
                @test all(e -> src(e) != dst(e), edges(g))
                if additions == 0
                    @test degree(g) == old_degrees
                end
            end
        end
    end

    @testset "Connected inputs are unchanged and consume no randomness" begin
        for g in (SimpleGraph(1), path_graph(4), cycle_graph(4))
            before = copy(g)
            rng = MersenneTwister(42)
            untouched_rng = copy(rng)
            @test GraphTraffic.Topology.make_graph_connected!(g; rng) === g
            @test g == before
            @test rand(rng, UInt64) == rand(untouched_rng, UInt64)
        end
    end

    @testset "Caller controls random choices" begin
        a = topology_graph(6, [triangle; [(4, 5), (5, 6), (4, 6)]])
        b = copy(a)
        rng_a, rng_b = MersenneTwister(19), MersenneTwister(19)
        GraphTraffic.Topology.make_graph_connected!(a; rng=rng_a)
        GraphTraffic.Topology.make_graph_connected!(b; rng=rng_b)
        @test a == b
        @test rand(rng_a, UInt64) == rand(rng_b, UInt64)
        # The existing call without a keyword must remain usable.
        @test GraphTraffic.Topology.make_graph_connected!(b) === b
    end

    @testset "Empty graph is rejected before mutation" begin
        g = SimpleGraph(0)
        rng = MersenneTwister(42)
        untouched_rng = copy(rng)
        @test_throws ArgumentError("graph must contain at least one vertex") GraphTraffic.Topology.make_graph_connected!(g; rng)
        @test nv(g) == ne(g) == 0
        @test rand(rng, UInt64) == rand(untouched_rng, UInt64)
    end
end
