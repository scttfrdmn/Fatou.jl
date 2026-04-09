"""
CloudManager <: ClusterManager integration for Fatou.jl.
Allows `addcloudprocs()` to launch Julia distributed workers on AWS ECS/Fargate
that connect back to the client via TCP, enabling pmap(), @distributed, etc.
"""

using Distributed
using ClusterManagers
using AWS
using HTTP

struct CloudManager <: ClusterManager
    session_id::String
    workers_actual::Int
    cpu::Int
    memory_gb::Int
    backend::Symbol
    spot::Bool
    region::String
    cfg::Config
    image_uri::String
    client_host::String
    client_port::Int
end

function ClusterManagers.launch(
    manager::CloudManager,
    params::Dict,
    launched::Array,
    c::Condition,
)
    aws_config = global_aws_config(region=manager.region)

    for i in 1:manager.workers_actual
        overrides = Dict(
            "containerOverrides" => [Dict(
                "name" => "burst-worker",
                "environment" => [
                    Dict("name" => "BURST_SESSION_ID", "value" => manager.session_id),
                    Dict("name" => "BURST_TASK_ID",    "value" => "worker-$(lpad(i, 4, '0'))"),
                    Dict("name" => "BURST_S3_BUCKET",  "value" => manager.cfg.s3_bucket),
                    Dict("name" => "BURST_REGION",     "value" => manager.region),
                    Dict("name" => "BURST_MODE",       "value" => "worker"),
                    Dict("name" => "BURST_CLIENT_HOST","value" => manager.client_host),
                    Dict("name" => "BURST_CLIENT_PORT","value" => string(manager.client_port)),
                    Dict("name" => "BURST_CLUSTER_COOKIE", "value" => string(Distributed.cluster_cookie())),
                ],
            )],
        )
        run_params = Dict(
            "cluster" => manager.cfg.ecs_cluster,
            "taskDefinition" => manager.image_uri,
            "launchType" => uppercase(string(manager.backend)),
            "overrides" => overrides,
            "count" => 1,
        )
        if manager.backend == :fargate
            run_params["networkConfiguration"] = Dict(
                "awsvpcConfiguration" => Dict(
                    "subnets" => String[],
                    "assignPublicIp" => "ENABLED",
                ),
            )
        end
        ECS.run_task(run_params; aws_config=aws_config)

        # Add a WorkerConfig placeholder — the worker will connect back
        wconfig = WorkerConfig()
        wconfig.userdata = Dict(:task_index => i, :session_id => manager.session_id)
        push!(launched, wconfig)
        notify(c)
    end
end

function ClusterManagers.manage(
    manager::CloudManager,
    id::Integer,
    config::WorkerConfig,
    op::Symbol,
)
    if op == :register
        # Worker has connected — nothing extra to do
    elseif op == :interrupt
        # Cannot interrupt Fargate tasks gracefully from here
    elseif op == :finalize
        # ECS tasks terminate themselves when the Julia worker process exits
    end
end

"""
    _get_client_ip() -> String

Determine the client's public IP address for ECS workers to connect back.
Uses checkip.amazonaws.com. Mockable for testing.
"""
function _get_client_ip() :: String
    resp = HTTP.get("https://checkip.amazonaws.com/"; connect_timeout=5, readtimeout=5)
    strip(String(resp.body))
end

"""
    addcloudprocs(n; cpu, memory, backend, spot, region, timeout) -> Vector{Int}

Launch n AWS ECS Fargate workers as Julia distributed worker processes.
Returns worker process IDs — compatible with pmap(), @spawnat, @distributed, etc.

# Example
```julia
pids = addcloudprocs(10, cpu=2, memory="4GB")
results = pmap(simulate, seeds)
rmprocs(pids)
```
"""
function addcloudprocs(
    n::Int;
    cpu::Int = 2,
    memory::String = "4GB",
    backend::Symbol = :fargate,
    spot::Bool = false,
    region::Union{String, Nothing} = nothing,
    timeout::Int = 300,
) :: Vector{Int}
    cfg = load_config()
    if region !== nothing
        cfg = Config(cfg; region=region)
    end

    image_uri = ensure_image(cfg)
    session_id = generate_session_id()
    client_host = _get_client_ip()

    # Julia uses a random port for worker connections; start_master() sets it up
    # We let addprocs handle the port negotiation via the ClusterManager protocol
    manager = CloudManager(
        session_id,
        n,
        cpu,
        parse_memory_gb(memory),
        backend,
        spot,
        cfg.region,
        cfg,
        image_uri,
        client_host,
        0,  # port will be set by Julia's distributed runtime
    )

    print_start(n)
    rate = estimate_cost_per_hour(cpu, parse_memory_gb(memory), n)
    print_cost_estimate(rate)

    worker_pids = addprocs(manager; timeout=timeout)
    worker_pids
end
