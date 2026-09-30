module orchestrator

import CSV
using DataFrames: DataFrame
using ..GraphTraffic: SimulationID, SimulationResult, call_graphtraffic_rs, SimulationConfig, load_results

export Experiment, simulation, analysis, visualization,
       run_simulation, run_analysis, run_visualization

# Experiments select methods by type; run_* never constructs an instance.
abstract type Experiment end

"""
    simulation(experiment::Type{<:Experiment}) -> Vector{SimulationConfig}

Generate the simulation configurations for an experiment.
"""
function simulation end

"""
    analysis(experiment::Type{<:Experiment}, results; num_threads) -> DataFrame

Analyze results. The implementation decides how to use the requested thread count.
"""
function analysis end

"""
    visualization(experiment::Type{<:Experiment}, df; directory, num_threads) -> Nothing

Write figures into `directory`. The implementation decides how to use the
requested thread count; it need not parallelize plotting.
"""
function visualization end


function default_directory(experiment::Type{<:Experiment})
    project = Base.active_project()
    isnothing(project) && throw(ArgumentError("no active Julia project; pass directory explicitly"))
    joinpath(dirname(project), "results", string(nameof(experiment)))
end

results_file(directory::AbstractString) = joinpath(directory, "results.hdf5")
analysis_file(directory::AbstractString) = joinpath(directory, "analysis.csv")
figures_dir(directory::AbstractString) = joinpath(directory, "figures")
default_num_threads() = max(1, Sys.CPU_THREADS ÷ 2)

function validate_num_threads(num_threads::Integer)
    num_threads > 0 || throw(ArgumentError("num_threads must be positive"))
    nothing
end

function check_output(path::AbstractString, overwrite::Bool; figures::Bool=false)
    occupied = ispath(path) || islink(path)
    if figures && isdir(path) && isempty(readdir(path))
        occupied = false
    end
    occupied && !overwrite && throw(ArgumentError("output already exists: $path; pass overwrite=true to overwrite"))
    nothing
end

function run_simulation(experiment::Type{<:Experiment};
                        directory::AbstractString=default_directory(experiment),
                        num_threads::Integer=default_num_threads(),
                        cascate_pipeline::Bool=false,
                        overwrite::Bool=false)
    validate_num_threads(num_threads)
    check_output(results_file(directory), overwrite)
    if cascate_pipeline
        check_output(analysis_file(directory), overwrite)
        check_output(figures_dir(directory), overwrite; figures=true)
    end
    configs = simulation(experiment)
    call_graphtraffic_rs(configs; output=results_file(directory), threads=num_threads, overwrite)
    if cascate_pipeline
        run_analysis(experiment; directory, num_threads, cascate_pipeline=true, overwrite)
    end
    nothing
end


function run_analysis(experiment::Type{<:Experiment};
                      directory::AbstractString=default_directory(experiment),
                      num_threads::Integer=default_num_threads(),
                      cascate_pipeline::Bool=false,
                      overwrite::Bool=false)
    validate_num_threads(num_threads)
    check_output(analysis_file(directory), overwrite)
    if cascate_pipeline
        check_output(figures_dir(directory), overwrite; figures=true)
    end
    df = analysis(experiment, load_results(results_file(directory)); num_threads)
    CSV.write(analysis_file(directory), df)
    if cascate_pipeline
        run_visualization(experiment; directory, num_threads, overwrite)
    end
    nothing
end


function run_visualization(experiment::Type{<:Experiment};
                           directory::AbstractString=default_directory(experiment),
                           num_threads::Integer=default_num_threads(),
                           overwrite::Bool=false)
    validate_num_threads(num_threads)
    check_output(figures_dir(directory), overwrite; figures=true)
    mkpath(directory)
    visualization(experiment, CSV.read(analysis_file(directory), DataFrame);
                  directory=figures_dir(directory), num_threads)
    nothing
end
end
