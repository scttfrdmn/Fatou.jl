#!/usr/bin/env julia
"""
Standalone ECS worker entrypoint for Fatou.jl.
Self-contained — no Fatou.jl imports. Runs inside the Docker container.

Modes (via BURST_MODE env var):
  "task"   (default) — download task file, execute fn(item) for each item, upload result
  "worker"           — start Julia distributed worker, TCP-connect back to client
"""

using Distributed
using AWS
using AWS: @service
@service S3 use_response_type = true
using JLD2

const SESSION_ID = ENV["BURST_SESSION_ID"]
const TASK_ID    = ENV["BURST_TASK_ID"]
const BUCKET     = ENV["BURST_S3_BUCKET"]
const REGION     = get(ENV, "BURST_REGION", "us-east-1")
const MODE       = get(ENV, "BURST_MODE", "task")

function task_key(suffix::String) :: String
    "sessions/$(SESSION_ID)/tasks/$(TASK_ID).$(suffix)"
end

function s3_put(aws_cfg, key::String, body::Vector{UInt8}) :: Nothing
    S3.put_object(BUCKET, key, Dict("body" => body); aws_config=aws_cfg)
    nothing
end

function s3_get(aws_cfg, key::String) :: Vector{UInt8}
    resp = S3.get_object(BUCKET, key; aws_config=aws_cfg)
    resp.body
end

function deserialize_task(data::Vector{UInt8}) :: Tuple{Function, Vector}
    buf = IOBuffer(data)
    if length(data) > 0 && data[1] == 0xFF
        skip(buf, 1)
        fn, items = Serialization.deserialize(buf)
        return fn, items
    end
    d = load(buf)
    return d["fn"], d["items"]
end

function serialize_result(result) :: Vector{UInt8}
    buf = IOBuffer()
    try
        jldsave(buf; result=result)
    catch
        seekstart(buf)
        truncate(buf, 0)
        write(buf, UInt8(0xFF))
        Serialization.serialize(buf, result)
    end
    take!(buf)
end

function run_task_mode(aws_cfg) :: Nothing
    s3_put(aws_cfg, task_key("status"), Vector{UInt8}("running"))

    try
        task_data = s3_get(aws_cfg, task_key("task"))
        fn, items = deserialize_task(task_data)
        results = [fn(item) for item in items]
        result_data = serialize_result(results)
        s3_put(aws_cfg, task_key("result"), result_data)
        s3_put(aws_cfg, task_key("status"), Vector{UInt8}("done"))
    catch e
        err_msg = sprint(showerror, e, catch_backtrace())
        s3_put(aws_cfg, task_key("error"), Vector{UInt8}(err_msg))
        s3_put(aws_cfg, task_key("status"), Vector{UInt8}("failed"))
        exit(1)
    end
    nothing
end

function run_worker_mode() :: Nothing
    client_host = ENV["BURST_CLIENT_HOST"]
    client_port = parse(Int, ENV["BURST_CLIENT_PORT"])
    cookie = get(ENV, "BURST_CLUSTER_COOKIE", "")
    if !isempty(cookie)
        Distributed.cluster_cookie(cookie)
    end
    # Start Julia worker process that connects back to the client
    Distributed.start_worker(client_host, client_port)
    nothing
end

function main() :: Nothing
    aws_cfg = global_aws_config(region=REGION)

    if MODE == "worker"
        run_worker_mode()
    else
        run_task_mode(aws_cfg)
    end
    nothing
end

main()
