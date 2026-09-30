module orchestrator

import CSV
using DataFrames: DataFrame
using ..GraphTraffic: SimulationID, SimulationResult, call_graphtraffic_rs, SimulationConfig, load_results

export ExperimentSpec, Experiment, simulation, analysis, visualization,
       run_simulation, run_analysis, run_visualization

abstract type ExperimentSpec end


struct Experiment{S<:ExperimentSpec}
    spec::S
    directory::String
    num_threads::Int
end


"""
    simulation(experiment::Experiment) -> Vector{SimulationConfig}

Generate the simulation configurations for an experiment.
Each `ExperimentSpec` must provide an implementation.
"""
function simulation end

"""
    analysis(experiment::Experiment,
             results::Dict{SimulationID,SimulationResult}) -> DataFrame

Analyze the simulation results for an experiment.
"""
function analysis end

"""
    visualization(experiment::Experiment, df::DataFrame) -> Nothing

Generate the figures for an experiment.
"""
function visualization end

results_file(experiment::Experiment)::String = joinpath(experiment.directory, "results.hdf5")
analysis_file(experiment::Experiment)::String = joinpath(experiment.directory, "analysis.csv")
figures_dir(experiment::Experiment)::String = joinpath(experiment.directory, "figures")


function run_simulation(experiment::Experiment, cascate_pipeline::Bool=false)
    configs = simulation(experiment)
    call_graphtraffic_rs(configs; output=results_file(experiment), threads=experiment.num_threads)
    if cascate_pipeline
        run_analysis(experiment)
        run_visualization(experiment)
    end
end

function run_analysis(experiment::Experiment; cascate_pipeline::Bool=false)
    df = analysis(experiment, load_results(results_file(experiment)))
    CSV.write(analysis_file(experiment), df)
    if cascate_pipeline
        run_visualization(experiment)
    end
end

function run_visualization(experiment::Experiment)
    visualization(experiment, CSV.read(analysis_file(experiment), DataFrame))
end
end
