# Fatou.jl

Cloud bursting for Julia — run `pmap()` on AWS ECS Fargate workers with one line of code.

Named after Pierre Fatou (1878–1929). The Fatou set is the complement of the Julia set in complex dynamics — latent potential, activated on demand.

Part of the [burst](https://github.com/scttfrdmn/burst-core) family alongside [adder](https://github.com/scttfrdmn/adder) (Python) and [stet](https://github.com/scttfrdmn/stet) (TypeScript/Node.js).

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/scttfrdmn/Fatou.jl")
```

## Quick Start

### Task mode — `cloud_pmap`

Drop-in replacement for `pmap()`. Workers run in ephemeral ECS Fargate containers:

```julia
using Fatou

# Exactly like pmap(), but runs on 50 Fargate workers:
results = cloud_pmap(simulate, seeds, workers=50)

# With resource and cost options:
results = cloud_pmap(
    simulate, seeds,
    workers    = 50,
    cpu        = 4,       # vCPUs per worker
    memory     = "16GB",  # RAM per worker
    max_cost   = 5.00,    # abort if estimated cost > $5
    cost_alert = 2.00,    # warn if cost rate > $2/hr
    timeout    = 300,     # seconds
)
```

### Worker mode — `addcloudprocs`

Launch Julia distributed workers on ECS that connect back to your process. All standard Julia distributed primitives work:

```julia
using Fatou, Distributed

# Launch 20 workers — returns Julia process IDs
pids = addcloudprocs(20, cpu=2, memory="8GB")

# Now use any Julia distributed primitive:
results = pmap(simulate, seeds)
result  = @distributed (+) for x in data; f(x); end
fut     = @spawnat pids[1] heavy_computation()

# Clean up
rmprocs(pids)
```

### `@cloud` macro

```julia
using Fatou

results = @cloud workers=20 cpu=4 memory="16GB" begin
    pmap(simulate, seeds)
end
# Workers are automatically launched and cleaned up
```

## Cold Start Performance

Julia's JIT means fresh containers take 30–90 seconds to load packages. Fatou solves this with a mandatory `PackageCompiler.jl` sysimage baked into the Docker image:

- **First build**: 5–15 minutes (one-time per environment)
- **Subsequent cold starts**: ~2–3 seconds
- **Sysimage**: rebuilt automatically when your `Manifest.toml` changes

```
📦 Building worker image with precompiled sysimage...
   This takes 5-15 minutes for the first environment.
   Subsequent runs with the same packages will be instant.
```

## Configuration

```bash
burst-core setup  # interactive wizard writes ~/.burst/config.json
```

Or set `BURST_CONFIG_PATH` to point to a JSON config file:

```json
{
  "region": "us-east-1",
  "s3_bucket": "my-burst-bucket",
  "ecs_cluster": "burst-cluster",
  "ecr_base_uri": "123456789012.dkr.ecr.us-east-1.amazonaws.com",
  "execution_role_arn": "arn:aws:iam::123456789012:role/burst-execution-role",
  "task_role_arn": "arn:aws:iam::123456789012:role/burst-task-role",
  "default_workers": 10,
  "default_cpu": 1,
  "default_memory_gb": 2,
  "fargate_quota_vcpu": 256.0
}
```

## Detached Sessions

For long-running jobs that outlive your Julia process:

```julia
# Submit and detach
session = cloud_pmap(simulate, seeds, workers=100, detach=true)
println("Session ID: $(session.session_id)")  # save this

# From another process, poll and collect:
ds = attach("jl-20260408-3f8a1b2c")
status(ds)    # check progress
results = collect!(ds, timeout=600)
cleanup!(ds)  # delete S3 task files
```

## Session Lifecycle

```
1. Cost estimate check (before any AWS calls)
2. Quota check (reduce workers if Fargate vCPU limit would be exceeded)
3. Write manifest.json to S3
4. Upload serialized task files to S3
5. Launch ECS Fargate tasks (one per chunk)
6. Poll S3 for .status files every 2 seconds
7. Download results, cleanup task files, return ordered results
```

## Cost Estimation

```julia
using Fatou: estimate_cost_per_hour, estimate_cost

# 50 workers × 4 vCPU × 16 GB for 10 minutes:
rate = estimate_cost_per_hour(4, 16, 50)   # $/hr
cost = estimate_cost(4, 16, 50, 10/60)     # $ for 10 min
```

Fargate pricing: `$0.04048/vCPU-hour + $0.004445/GB-hour`

## Error Handling

```julia
try
    results = cloud_pmap(f, items, max_cost=1.0)
catch e
    if e isa BurstCostLimitError
        println("Too expensive: estimated \$$(e.estimated_cost)")
    elseif e isa BurstPartialError
        println("$(e.failed_count) of $(e.failed_count+e.success_count) tasks failed")
        good = filter(!isnothing, e.results)
    elseif e isa BurstTimeoutError
        println("Timed out after $(e.timeout_seconds)s")
    end
end
```

## Testing

```bash
# Unit tests (no AWS required):
julia --project test/runtests.jl

# Integration tests (requires substrate binary):
BURST_INTEGRATION_TEST=1 julia --project test/runtests.jl
```

## Requirements

- Julia 1.10+
- AWS credentials with ECS, ECR, S3, and IAM permissions
- `burst-core` CLI installed (for `setup`, image build, and substrate)

## License

MIT
