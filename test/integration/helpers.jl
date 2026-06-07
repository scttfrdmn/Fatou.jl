"""
Integration test helpers for Fatou.jl.

Substrate (default): BURST_INTEGRATION_TEST=1
Real AWS:            BURST_INTEGRATION_TEST=1  (with real AWS credentials, no AWS_ENDPOINT_URL)
"""

using HTTP
using Sockets
using AWS
using AWS: @service
@service S3 use_response_type = true

using_real_aws() = get(ENV, "BURST_USE_REAL_AWS", "") != ""

# AWS.jl does not support AWS_ENDPOINT_URL. When using substrate, override
# generate_service_url to redirect all API calls to the emulator.
struct SubstrateAWSConfig <: AWS.AbstractAWSConfig
    endpoint::String
    region::String
    creds::AWS.AWSCredentials
end

AWS.region(c::SubstrateAWSConfig) = c.region
AWS.credentials(c::SubstrateAWSConfig) = c.creds

function AWS.generate_service_url(c::SubstrateAWSConfig, service::String, resource::String)
    return string(c.endpoint, resource)
end

function require_integration()
    if !haskey(ENV, "BURST_INTEGRATION_TEST")
        error("Set BURST_INTEGRATION_TEST=1 to run integration tests")
    end
end

function _free_port() :: Int
    server = Sockets.listen(Sockets.localhost, 0)
    port = Sockets.getsockname(server)[2]
    close(server)
    port
end

struct SubstrateServer
    url::Union{String, Nothing}
    process::Union{Base.Process, Nothing}
    aws_config::AWS.AbstractAWSConfig
end

function start_substrate() :: SubstrateServer
    if using_real_aws()
        cfg = Fatou.load_config()
        aws_config = global_aws_config(region=cfg.region)
        return SubstrateServer(nothing, nothing, aws_config)
    end

    port = _free_port()
    proc = run(`substrate server --address :$port`; wait=false)
    url = "http://localhost:$port"

    deadline = time() + 30.0
    while time() < deadline
        try
            resp = HTTP.get("$url/health"; connect_timeout=1, readtimeout=1)
            if resp.status == 200
                aws_config = SubstrateAWSConfig(
                    url, "us-east-1",
                    AWS.AWSCredentials("test", "test"),
                )
                return SubstrateServer(url, proc, aws_config)
            end
        catch
        end
        sleep(0.2)
    end

    kill(proc)
    error("substrate server did not start within 30s on port $port")
end

function stop_substrate(srv::SubstrateServer)
    if srv.process !== nothing
        kill(srv.process)
        wait(srv.process)
    end
end

function reset_substrate(srv::SubstrateServer)
    if srv.url !== nothing
        HTTP.post("$(srv.url)/v1/state/reset")
    end
    nothing
end

function write_test_config(srv::SubstrateServer) :: Fatou.Config
    if using_real_aws()
        return Fatou.load_config()
    end

    dir = mktempdir()
    path = joinpath(dir, "config.json")
    cfg_data = Dict(
        "region" => "us-east-1",
        "s3_bucket" => "burst-us-east-1",
        "ecs_cluster" => "burst-cluster",
        "ecr_base_uri" => "123456789012.dkr.ecr.us-east-1.amazonaws.com",
        "execution_role_arn" => "arn:aws:iam::123456789012:role/burst-execution-role",
        "task_role_arn" => "arn:aws:iam::123456789012:role/burst-task-role",
        "default_workers" => 3,
        "default_cpu" => 1,
        "default_memory_gb" => 2,
        "fargate_quota_vcpu" => 256.0,
    )
    open(path, "w") do f
        write(f, JSON3.write(cfg_data))
    end
    ENV["BURST_CONFIG_PATH"] = path
    ENV["AWS_ENDPOINT_URL"] = srv.url
    ENV["AWS_ACCESS_KEY_ID"] = "test"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test"
    ENV["AWS_DEFAULT_REGION"] = "us-east-1"
    Fatou.load_config()
end

function create_bucket(aws_config::AWS.AbstractAWSConfig, bucket::String)
    try
        S3.create_bucket(bucket; aws_config=aws_config)
    catch
        # Already exists
    end
end

function simulate_workers(aws_config::AWS.AbstractAWSConfig, bucket::String,
                          session_id::String, items::Vector, fn::Function, n_workers::Int)
    chunks = Fatou.chunk_items(items, n_workers)
    for (i, chunk) in enumerate(chunks)
        results = [fn(item) for item in chunk]
        result_data = Fatou.serialize_result(results)
        idx = i - 1
        tid = Fatou.task_id(idx)

        S3.put_object(bucket, "sessions/$session_id/tasks/$tid.result",
            Dict("body" => result_data); aws_config=aws_config)
        S3.put_object(bucket, "sessions/$session_id/tasks/$tid.status",
            Dict("body" => Vector{UInt8}("done")); aws_config=aws_config)
    end
end
