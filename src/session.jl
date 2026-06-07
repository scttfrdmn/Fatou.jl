"""
Session lifecycle management for Fatou.jl.
Implements the 7-step worker lifecycle from ARCHITECTURE.md.
Session ID format: jl-{yyyymmdd}-{random8hex}
"""

using Dates
using Random
using JSON3
using AWS

struct SessionStatus
    session_id::String
    status::String          # "initializing"|"running"|"complete"|"failed"|"partial"
    tasks_total::Int
    tasks_complete::Int
    tasks_failed::Int
    workers_active::Int
    elapsed_seconds::Float64
    cost_actual::Float64
    cost_estimate_per_hour::Float64
end

function generate_session_id() :: String
    date_str = Dates.format(now(UTC), "yyyymmdd")
    rand_hex = bytes2hex(rand(UInt8, 4))
    "jl-$(date_str)-$(rand_hex)"
end

function task_id(index::Int) :: String
    "task-" * lpad(string(index), 4, '0')
end

function chunk_items(items::AbstractVector, n::Int) :: Vector{Vector}
    isempty(items) && return Vector{Vector}()
    n_chunks = min(n, length(items))
    chunk_size = ceil(Int, length(items) / n_chunks)
    chunks = Vector{Vector}()
    i = 1
    while i <= length(items)
        push!(chunks, collect(items[i:min(i + chunk_size - 1, length(items))]))
        i += chunk_size
    end
    chunks
end

function _task_key(session_id::String, index::Int, suffix::String) :: String
    "sessions/$(session_id)/tasks/$(task_id(index)).$(suffix)"
end

function _manifest_key(session_id::String) :: String
    "sessions/$(session_id)/manifest.json"
end

function _s3_put(aws_config, bucket::String, key::String, body) :: Nothing
    body_bytes = body isa AbstractString ? Vector{UInt8}(body) : Vector{UInt8}(body)
    S3.put_object(bucket, key, Dict("body" => body_bytes); aws_config=aws_config)
    nothing
end

function _s3_get(aws_config, bucket::String, key::String) :: Union{Vector{UInt8}, Nothing}
    try
        resp = S3.get_object(bucket, key; aws_config=aws_config)
        return resp.body
    catch e
        return nothing
    end
end

function _s3_get_text(aws_config, bucket::String, key::String) :: Union{String, Nothing}
    data = _s3_get(aws_config, bucket, key)
    data === nothing && return nothing
    strip(String(data))
end

function _s3_delete_objects(aws_config, bucket::String, keys::Vector{String}) :: Nothing
    # TODO: restore batch delete_objects once substrate #318 is fixed
    # (GetObject does not 404 on delete markers after DeleteObjects)
    for key in keys
        try
            S3.delete_object(bucket, key; aws_config=aws_config)
        catch
        end
    end
    nothing
end

# ── Session ───────────────────────────────────────────────────────────────────

mutable struct Session
    cfg::Config
    workers::Int
    cpu::Int
    memory_gb::Int
    backend::String
    spot::Bool
    max_cost::Union{Float64, Nothing}
    cost_alert::Union{Float64, Nothing}
    timeout::Union{Int, Nothing}
    arch::String
end

function Session(;
    cfg::Config,
    workers::Int = 10,
    cpu::Int = 1,
    memory_gb::Int = 2,
    backend::String = "fargate",
    spot::Bool = false,
    max_cost::Union{Float64, Nothing} = nothing,
    cost_alert::Union{Float64, Nothing} = nothing,
    timeout::Union{Int, Nothing} = nothing,
    arch::String = "amd64",
)
    Session(cfg, workers, cpu, memory_gb, backend, spot, max_cost, cost_alert, timeout, arch)
end

function run!(session::Session, items::Vector, fn::Function, image_uri::String;
              on_error=nothing) :: Vector
    isempty(items) && return []

    cfg = session.cfg

    # Cost limit check BEFORE any AWS calls
    rate = estimate_cost_per_hour(session.cpu, session.memory_gb, session.workers)
    if session.max_cost !== nothing
        est = estimate_cost(session.cpu, session.memory_gb, session.workers, 1.0)
        if est > session.max_cost
            throw(BurstCostLimitError(session.max_cost, est, []))
        end
    end

    aws_config = global_aws_config(region=cfg.region)

    actual_workers = min(session.workers, length(items))

    # Quota check
    if cfg.fargate_quota_vcpu > 0
        max_workers = floor(Int, cfg.fargate_quota_vcpu / session.cpu)
        if max_workers < actual_workers
            print_quota_warning(actual_workers, actual_workers * session.cpu,
                                max_workers, max_workers * session.cpu)
            actual_workers = max_workers
        end
    end

    chunks = chunk_items(items, actual_workers)
    chunk_count = length(chunks)
    avg_chunk = length(items) / chunk_count

    print_start(actual_workers)
    print_cost_estimate(rate)
    print_processing(length(items), actual_workers)
    print_chunks(chunk_count, Float64(avg_chunk))

    if session.cost_alert !== nothing && rate > session.cost_alert
        print_cost_alert(session.cost_alert)
    end

    session_id = generate_session_id()
    start_time = time()

    # Write manifest
    manifest = Dict(
        "session_id" => session_id,
        "language" => "julia",
        "library_version" => "0.1.0",
        "status" => "initializing",
        "workers_requested" => session.workers,
        "workers_actual" => actual_workers,
        "cpu" => session.cpu,
        "memory_gb" => session.memory_gb,
        "backend" => session.backend,
        "spot" => session.spot,
        "region" => cfg.region,
        "cost_estimate_per_hour" => rate,
        "task_count" => chunk_count,
        "chunk_count" => chunk_count,
        "tasks_total" => chunk_count,
        "tasks_complete" => 0,
        "tasks_failed" => 0,
        "workers_active" => 0,
        "cost_actual" => 0.0,
        "created_at" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ"),
    )
    _s3_put(aws_config, cfg.s3_bucket, _manifest_key(session_id), JSON3.write(manifest))

    # Upload task files
    for (i, chunk) in enumerate(chunks)
        task_data = serialize_task(fn, chunk)
        _s3_put(aws_config, cfg.s3_bucket, _task_key(session_id, i - 1, "task"), task_data)
    end

    # Launch workers
    _launch_workers!(session, aws_config, session_id, image_uri, chunk_count)
    print_submitted(chunk_count)

    # Poll until done
    deadline = session.timeout !== nothing ? start_time + session.timeout : nothing
    poll_result = _poll_until_done!(session, aws_config, cfg.s3_bucket, session_id, chunk_count,
                                    start_time, deadline; on_error=on_error)

    elapsed = time() - start_time
    print_completed("$(round(elapsed, digits=1))s")
    actual_cost = estimate_cost(session.cpu, session.memory_gb, actual_workers, elapsed / 3600)
    print_actual_cost(actual_cost)

    _cleanup_tasks!(aws_config, cfg.s3_bucket, session_id, chunk_count)

    # Tolerant mode: _poll_until_done! returned assembled results directly
    if poll_result !== nothing
        return vcat(poll_result...)
    end

    # Download results in parallel
    results_chunks = Vector{Vector}(undef, chunk_count)
    @sync for i in 1:chunk_count
        @async begin
            data = _s3_get(aws_config, cfg.s3_bucket, _task_key(session_id, i - 1, "result"))
            results_chunks[i] = data === nothing ? [] : deserialize_result(data)
        end
    end

    vcat(results_chunks...)
end

function _register_task_definition(aws_config, session::Session, cfg, session_id::String,
                                    image_uri::String) :: String
    params = Dict(
        "family" => "burst-$(session_id)",
        "taskRoleArn" => cfg.task_role_arn,
        "executionRoleArn" => cfg.execution_role_arn,
        "networkMode" => "awsvpc",
        "requiresCompatibilities" => ["FARGATE"],
        "cpu" => string(session.cpu * 1024),
        "memory" => string(session.memory_gb * 1024),
        "runtimePlatform" => Dict(
            "cpuArchitecture" => session.arch == "arm64" ? "ARM64" : "X86_64",
            "operatingSystemFamily" => "LINUX",
        ),
        "containerDefinitions" => [Dict(
            "name" => "burst-worker",
            "image" => image_uri,
            "essential" => true,
            "environment" => [
                Dict("name" => "BURST_LANG", "value" => "julia"),
            ],
            "logConfiguration" => Dict(
                "logDriver" => "awslogs",
                "options" => Dict(
                    "awslogs-group" => "/burst/workers",
                    "awslogs-region" => cfg.region,
                    "awslogs-stream-prefix" => "burst",
                    "awslogs-create-group" => "true",
                ),
            ),
        )],
    )
    resp = ECS.register_task_definition(params; aws_config=aws_config)
    return resp["taskDefinition"]["taskDefinitionArn"]
end

function _launch_workers!(session::Session, aws_config, session_id::String,
                           image_uri::String, chunk_count::Int)
    cfg = session.cfg
    task_def_arn = _register_task_definition(aws_config, session, cfg, session_id, image_uri)
    for i in 0:(chunk_count - 1)
        tid = task_id(i)
        overrides = Dict(
            "containerOverrides" => [Dict(
                "name" => "burst-worker",
                "environment" => [
                    Dict("name" => "BURST_SESSION_ID", "value" => session_id),
                    Dict("name" => "BURST_TASK_ID",    "value" => tid),
                    Dict("name" => "BURST_S3_BUCKET",  "value" => cfg.s3_bucket),
                    Dict("name" => "BURST_REGION",     "value" => cfg.region),
                    Dict("name" => "BURST_LANG",       "value" => "julia"),
                    Dict("name" => "BURST_MODE",       "value" => "task"),
                ],
            )],
        )
        params = Dict(
            "cluster" => cfg.ecs_cluster,
            "taskDefinition" => task_def_arn,
            "launchType" => uppercase(session.backend),
            "overrides" => overrides,
        )
        if session.backend == "fargate"
            params["networkConfiguration"] = Dict(
                "awsvpcConfiguration" => Dict(
                    "subnets" => String[],
                    "assignPublicIp" => "ENABLED",
                ),
            )
        end
        ECS.run_task(params; aws_config=aws_config)
    end
end

function _count_statuses(aws_config, bucket::String, session_id::String, chunk_count::Int) :: Tuple{Int,Int}
    done = 0
    failed = 0
    for i in 0:(chunk_count - 1)
        status = _s3_get_text(aws_config, bucket, _task_key(session_id, i, "status"))
        if status == "done"
            done += 1
        elseif status == "failed"
            failed += 1
        end
    end
    done, failed
end

function _poll_until_done!(session::Session, aws_config, bucket::String, session_id::String,
                           chunk_count::Int, start_time::Float64,
                           deadline::Union{Float64, Nothing};
                           on_error=nothing)
    while true
        if deadline !== nothing && time() > deadline
            elapsed = time() - start_time
            status = SessionStatus(session_id, "running", chunk_count, 0, 0, 0,
                                   elapsed, 0.0, estimate_cost_per_hour(session.cpu, session.memory_gb, session.workers))
            throw(BurstTimeoutError(session_id, session.timeout, status))
        end

        done, failed = _count_statuses(aws_config, bucket, session_id, chunk_count)
        elapsed = time() - start_time
        print_progress(done + failed, chunk_count, "$(round(elapsed, digits=1))s")

        if done + failed >= chunk_count
            if failed > 0
                # Partial failure — collect what we have
                results = Vector{Any}(nothing, chunk_count)
                errors  = Vector{Any}(nothing, chunk_count)
                for i in 0:(chunk_count - 1)
                    st = _s3_get_text(aws_config, bucket, _task_key(session_id, i, "status"))
                    if st == "done"
                        data = _s3_get(aws_config, bucket, _task_key(session_id, i, "result"))
                        results[i + 1] = data === nothing ? nothing : deserialize_result(data)
                    else
                        err_msg = _s3_get_text(aws_config, bucket, _task_key(session_id, i, "error"))
                        errors[i + 1] = BurstError(something(err_msg, "unknown error"))
                    end
                end
                if on_error !== nothing
                    # Tolerant mode: map failed chunks through on_error instead of throwing
                    for i in 1:chunk_count
                        if errors[i] !== nothing
                            results[i] = [on_error(ErrorException(errors[i].message))]
                        end
                    end
                    return results
                else
                    throw(BurstPartialError(results, errors))
                end
            end
            return nothing
        end

        sleep(2.0)
    end
end

function _cleanup_tasks!(aws_config, bucket::String, session_id::String, chunk_count::Int)
    keys = String[]
    for i in 0:(chunk_count - 1)
        for suffix in ("task", "result", "status", "error")
            push!(keys, _task_key(session_id, i, suffix))
        end
    end
    _s3_delete_objects(aws_config, bucket, keys)
end

# ── DetachedSession ───────────────────────────────────────────────────────────

struct DetachedSession
    session_id::String
    cfg::Config
end

function status(ds::DetachedSession) :: SessionStatus
    aws_config = global_aws_config(region=ds.cfg.region)
    data = _s3_get(aws_config, ds.cfg.s3_bucket, _manifest_key(ds.session_id))
    data === nothing && throw(BurstError("Session $(ds.session_id) manifest not found"))
    m = JSON3.read(String(data))
    SessionStatus(
        m[:session_id],
        m[:status],
        m[:tasks_total],
        get(m, :tasks_complete, 0),
        get(m, :tasks_failed, 0),
        get(m, :workers_active, 0),
        get(m, :elapsed_seconds, 0.0),
        get(m, :cost_actual, 0.0),
        get(m, :cost_estimate_per_hour, 0.0),
    )
end

function collect!(ds::DetachedSession; timeout::Union{Int, Nothing} = nothing) :: Vector
    aws_config = global_aws_config(region=ds.cfg.region)
    data = _s3_get(aws_config, ds.cfg.s3_bucket, _manifest_key(ds.session_id))
    data === nothing && throw(BurstError("Session $(ds.session_id) manifest not found"))
    m = JSON3.read(String(data))
    chunk_count = m[:chunk_count]
    cpu = get(m, :cpu, 1)
    memory_gb = get(m, :memory_gb, 1)
    workers = get(m, :workers_actual, chunk_count)

    rate = estimate_cost_per_hour(cpu, memory_gb, workers)
    session = Session(cfg=ds.cfg, workers=workers, cpu=cpu, memory_gb=memory_gb, timeout=timeout)

    start_time = time()
    deadline = timeout !== nothing ? start_time + timeout : nothing
    _poll_until_done!(session, aws_config, ds.cfg.s3_bucket, ds.session_id,
                      chunk_count, start_time, deadline)

    results_chunks = Vector{Vector}(undef, chunk_count)
    @sync for i in 1:chunk_count
        @async begin
            rd = _s3_get(aws_config, ds.cfg.s3_bucket,
                         _task_key(ds.session_id, i - 1, "result"))
            results_chunks[i] = rd === nothing ? [] : deserialize_result(rd)
        end
    end
    vcat(results_chunks...)
end

function cleanup!(ds::DetachedSession)
    aws_config = global_aws_config(region=ds.cfg.region)
    bucket = ds.cfg.s3_bucket
    prefix = "sessions/$(ds.session_id)/"

    # List all objects under the session prefix
    keys = String[]
    continuation_token = nothing
    while true
        params = Dict("prefix" => prefix)
        if continuation_token !== nothing
            params["continuation-token"] = continuation_token
        end
        resp = S3.list_objects_v2(bucket, params; aws_config=aws_config)
        for obj in get(resp, :Contents, [])
            push!(keys, obj[:Key])
        end
        if get(resp, :IsTruncated, false)
            continuation_token = resp[:NextContinuationToken]
        else
            break
        end
    end

    isempty(keys) && return
    _s3_delete_objects(aws_config, bucket, keys)
end

function attach(session_id::String; cfg::Union{Config, Nothing} = nothing) :: DetachedSession
    if cfg === nothing
        cfg = load_config()
    end
    DetachedSession(session_id, cfg)
end
