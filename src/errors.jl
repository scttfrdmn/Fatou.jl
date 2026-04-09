"""
Exception types for the Fatou.jl burst family library.
"""

struct BurstError <: Exception
    message::String
end

struct BurstPartialError <: Exception
    results::Vector          # Union{T, Nothing} per item
    errors::Vector           # Union{Exception, Nothing} per item
    failed_count::Int
    success_count::Int
end

function BurstPartialError(results::Vector, errors::Vector)
    failed  = sum(1 for e in errors  if e !== nothing; init=0)
    success = sum(1 for r in results if r !== nothing; init=0)
    BurstPartialError(results, errors, failed, success)
end

struct BurstQuotaError <: Exception
    requested_workers::Int
    actual_workers::Int
    quota_name::String
    quota_value::Float64
end

struct BurstCostLimitError <: Exception
    limit::Float64
    estimated_cost::Float64
    partial_results::Vector
end

BurstCostLimitError(limit, estimated_cost) = BurstCostLimitError(limit, estimated_cost, [])

struct BurstTimeoutError <: Exception
    session_id::String
    timeout_seconds::Int
    status  # SessionStatus — forward reference
end

struct BurstSetupError <: Exception
    step::String
    cause::String
    remediation::String
end

# ── showerror ─────────────────────────────────────────────────────────────────

function Base.showerror(io::IO, e::BurstError)
    print(io, "BurstError: ", e.message)
end

function Base.showerror(io::IO, e::BurstPartialError)
    print(io, "BurstPartialError: $(e.failed_count) of $(e.failed_count + e.success_count) tasks failed")
end

function Base.showerror(io::IO, e::BurstQuotaError)
    print(io, "BurstQuotaError: requested $(e.requested_workers) workers but quota $(e.quota_name) allows $(e.quota_value) (using $(e.actual_workers))")
end

function Base.showerror(io::IO, e::BurstCostLimitError)
    print(io, "BurstCostLimitError: estimated cost \$$(round(e.estimated_cost, digits=4)) exceeds limit \$$(round(e.limit, digits=4))")
end

function Base.showerror(io::IO, e::BurstTimeoutError)
    print(io, "BurstTimeoutError: session $(e.session_id) timed out after $(e.timeout_seconds)s")
end

function Base.showerror(io::IO, e::BurstSetupError)
    print(io, "BurstSetupError at $(e.step): $(e.cause)\nRemediation: $(e.remediation)")
end
