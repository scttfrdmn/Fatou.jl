"""
    Fatou

Cloud bursting for Julia — AWS parallel map via pmap() and @distributed.

The Fatou set is the complement of the Julia set in complex dynamics.
Named after Pierre Fatou (1878–1929) — latent potential, activated on demand.

# Quick Start

```julia
using Fatou

# Drop-in replacement for pmap():
results = cloud_pmap(simulate, seeds, workers=50)

# Or use addcloudprocs() for full Julia distributed ecosystem:
pids = addcloudprocs(50)
results = pmap(simulate, seeds)
rmprocs(pids)

# @cloud macro:
results = @cloud workers=50 cpu=4 begin
    pmap(simulate, seeds)
end
```
"""
module Fatou

# Standard library
using Distributed
using Serialization
using SHA
using TOML
using Dates
using Random

# Third-party
using AWS
using AWS: @service
using ClusterManagers
using HTTP
using JLD2
using JSON3
using ProgressMeter

# AWS service clients (declared once here; all included files share this namespace)
@service S3  use_response_type = true
@service ECS use_response_type = true
@service ECR use_response_type = true

include("errors.jl")
include("config.jl")
include("cost.jl")
include("serialize.jl")
include("session.jl")
include("env.jl")
include("manager.jl")
include("macro.jl")

# ── Exports ───────────────────────────────────────────────────────────────────

export cloud_pmap
export addcloudprocs
export @cloud
export attach
export status
export collect!
export cleanup!
export run!

export FARGATE_VCPU_PER_HOUR
export FARGATE_GB_PER_HOUR
export print_start, print_cost_estimate, print_actual_cost

export BurstError
export BurstPartialError
export BurstQuotaError
export BurstCostLimitError
export BurstTimeoutError
export BurstSetupError

export SessionStatus
export DetachedSession

export VERSION

const VERSION = "0.1.0"

# ── cloud_pmap ────────────────────────────────────────────────────────────────

"""
    cloud_pmap(f, items; workers, cpu, memory, backend, spot,
               max_cost, cost_alert, timeout, region) -> Vector

Cloud-burst `f` over `items` using AWS ECS Fargate workers.
Drop-in replacement for `pmap(f, items)`.

# Arguments
- `f`: function to apply to each item
- `items`: collection of inputs
- `workers=10`: number of Fargate workers
- `cpu=1`: vCPUs per worker
- `memory="2GB"`: memory per worker
- `backend=:fargate`: `:fargate` or `:ec2`
- `spot=false`: use Spot capacity
- `max_cost=nothing`: abort if estimated cost exceeds limit (USD)
- `cost_alert=nothing`: warn when cost approaches threshold (USD/hr)
- `timeout=nothing`: timeout in seconds
- `region=nothing`: AWS region override

# Example
```julia
results = cloud_pmap(x -> x^2, 1:1000, workers=50)
```
"""
function cloud_pmap(
    f::Function,
    items;
    workers::Int = 10,
    cpu::Int = 1,
    memory::String = "2GB",
    backend::Symbol = :fargate,
    spot::Bool = false,
    max_cost::Union{Float64, Nothing} = nothing,
    cost_alert::Union{Float64, Nothing} = nothing,
    timeout::Union{Int, Nothing} = nothing,
    region::Union{String, Nothing} = nothing,
) :: Vector
    cfg = load_config()
    if region !== nothing
        cfg = Config(cfg; region=region)
    end

    image_uri = ensure_image(cfg)

    session = Session(
        cfg       = cfg,
        workers   = workers,
        cpu       = cpu,
        memory_gb = parse_memory_gb(memory),
        backend   = string(backend),
        spot      = spot,
        max_cost  = max_cost,
        cost_alert = cost_alert,
        timeout   = timeout,
    )

    run!(session, collect(items), f, image_uri)
end

end # module Fatou
