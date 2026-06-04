"""
Integration test helpers for Fatou.jl.
Uses substrate as an AWS emulator. Set BURST_INTEGRATION_TEST=1 to enable.

Pattern matches adder/tests/conftest.py and stet/tests/integration/helpers.ts.
"""

using HTTP
using Sockets
using AWS
using AWS: @service
@service S3 use_response_type = true

# AWS.jl does not support AWS_ENDPOINT_URL. Override generate_service_url to
# redirect all API calls to the substrate emulator.
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
    url::String
    process::Base.Process
    aws_config::SubstrateAWSConfig
end

function start_substrate() :: SubstrateServer
    port = _free_port()
    proc = run(`substrate server --address :$port`; wait=false)
    url = "http://localhost:$port"

    # Health check
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
    kill(srv.process)
    wait(srv.process)
end

function reset_substrate(srv::SubstrateServer)
    HTTP.post("$(srv.url)/v1/state/reset")
    nothing
end

function write_test_config(substrate_url::String) :: Fatou.Config
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
    Fatou.load_config()
end

function create_bucket(aws_config::AWS.AbstractAWSConfig, bucket::String)
    try
        S3.create_bucket(bucket; aws_config=aws_config)
    catch
        # Already exists
    end
end

"""
    simulate_workers(aws_config, bucket, session_id, items, fn, n_workers)

Simulate ECS workers by writing result + status files directly to S3.
Mirrors the adder test pattern: write what workers would write, let
the polling loop discover the files naturally.
"""
function simulate_workers(aws_config::AWS.AbstractAWSConfig, bucket::String,
                          session_id::String, items::Vector, fn::Function, n_workers::Int)
    chunks = Fatou.chunk_items(items, n_workers)
    for (i, chunk) in enumerate(chunks)
        results = [fn(item) for item in chunk]
        result_data = Fatou.serialize_result(results)
        idx = i - 1
        tid = Fatou.task_id(idx)

        result_key = "sessions/$session_id/tasks/$tid.result"
        status_key = "sessions/$session_id/tasks/$tid.status"

        S3.put_object(bucket, result_key,
            Dict("body" => result_data); aws_config=aws_config)
        S3.put_object(bucket, status_key,
            Dict("body" => Vector{UInt8}("done")); aws_config=aws_config)
    end
end
