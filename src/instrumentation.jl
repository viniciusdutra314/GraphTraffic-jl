"""An optional measurement collected by the Rust simulator after warmup."""
abstract type Observer end
struct ObserverEdgeQueue <: Observer end
struct ObserverEdgeReceivedMessages <: Observer end
struct ObserverTotalMessages <: Observer end

struct ObserverEdgeCapacity <: Observer
    update_interval::UInt64
    function ObserverEdgeCapacity(; update_interval::Integer=1)
        update_interval > 0 || throw(ArgumentError("update_interval must be positive"))
        new(update_interval)
    end
end

"""An optional rule that changes the simulated network during execution."""
abstract type Modifier end

struct ModifierEdgeCapacity <: Modifier
    free_flow_rate::Float64
    free_flow_sampling_time::UInt64
    function ModifierEdgeCapacity(; free_flow_rate::Real,
                                  free_flow_sampling_time::Integer)
        rate = Float64(free_flow_rate)
        0 < rate <= 1 || throw(ArgumentError("free_flow_rate must be in (0, 1]"))
        # Rust uses this interval as a divisor, despite the schema allowing zero.
        free_flow_sampling_time > 0 || throw(ArgumentError("free_flow_sampling_time must be positive"))
        new(rate, free_flow_sampling_time)
    end
end
