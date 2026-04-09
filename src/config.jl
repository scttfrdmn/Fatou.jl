"""
Configuration for the Fatou.jl burst family library.
Reads/writes ~/.burst/config.json (shared with burst-core, adder, stet).
JSON on disk uses snake_case. Julia struct uses snake_case (Julia convention).
"""

using JSON3

Base.@kwdef struct Config
    region::String = "us-east-1"
    s3_bucket::String = ""
    ecs_cluster::String = "burst-cluster"
    ecr_base_uri::String = ""
    execution_role_arn::String = ""
    task_role_arn::String = ""
    default_cpu::Int = 1
    default_memory_gb::Int = 2
    default_workers::Int = 10
    max_cost_per_job::Float64 = 0.0
    cost_alert_threshold::Float64 = 0.0
    backend::String = "fargate"
    spot::Bool = false
    fargate_quota_vcpu::Float64 = 256.0
end

# Allow creating Config with overrides via keyword syntax from existing config
function Config(base::Config; kwargs...)
    d = Dict{Symbol,Any}(
        :region => base.region,
        :s3_bucket => base.s3_bucket,
        :ecs_cluster => base.ecs_cluster,
        :ecr_base_uri => base.ecr_base_uri,
        :execution_role_arn => base.execution_role_arn,
        :task_role_arn => base.task_role_arn,
        :default_cpu => base.default_cpu,
        :default_memory_gb => base.default_memory_gb,
        :default_workers => base.default_workers,
        :max_cost_per_job => base.max_cost_per_job,
        :cost_alert_threshold => base.cost_alert_threshold,
        :backend => base.backend,
        :spot => base.spot,
        :fargate_quota_vcpu => base.fargate_quota_vcpu,
    )
    for (k, v) in kwargs
        d[k] = v
    end
    Config(; d...)
end

function _config_path() :: String
    env = get(ENV, "BURST_CONFIG_PATH", "")
    if !isempty(env)
        return env
    end
    return joinpath(homedir(), ".burst", "config.json")
end

function load_config() :: Config
    path = _config_path()
    if !isfile(path)
        return Config()
    end
    raw = JSON3.read(read(path, String))
    Config(
        region            = get(raw, :region, "us-east-1"),
        s3_bucket         = get(raw, :s3_bucket, ""),
        ecs_cluster       = get(raw, :ecs_cluster, "burst-cluster"),
        ecr_base_uri      = get(raw, :ecr_base_uri, ""),
        execution_role_arn = get(raw, :execution_role_arn, ""),
        task_role_arn     = get(raw, :task_role_arn, ""),
        default_cpu       = get(raw, :default_cpu, 1),
        default_memory_gb = get(raw, :default_memory_gb, 2),
        default_workers   = get(raw, :default_workers, 10),
        max_cost_per_job  = get(raw, :max_cost_per_job, 0.0),
        cost_alert_threshold = get(raw, :cost_alert_threshold, 0.0),
        backend           = get(raw, :backend, "fargate"),
        spot              = get(raw, :spot, false),
        fargate_quota_vcpu = get(raw, :fargate_quota_vcpu, 256.0),
    )
end

function save_config(cfg::Config)
    path = _config_path()
    mkpath(dirname(path))
    d = Dict(
        "region"            => cfg.region,
        "s3_bucket"         => cfg.s3_bucket,
        "ecs_cluster"       => cfg.ecs_cluster,
        "ecr_base_uri"      => cfg.ecr_base_uri,
        "execution_role_arn" => cfg.execution_role_arn,
        "task_role_arn"     => cfg.task_role_arn,
        "default_cpu"       => cfg.default_cpu,
        "default_memory_gb" => cfg.default_memory_gb,
        "default_workers"   => cfg.default_workers,
        "max_cost_per_job"  => cfg.max_cost_per_job,
        "cost_alert_threshold" => cfg.cost_alert_threshold,
        "backend"           => cfg.backend,
        "spot"              => cfg.spot,
        "fargate_quota_vcpu" => cfg.fargate_quota_vcpu,
    )
    content = JSON3.write(d)
    open(path, "w") do f
        write(f, content)
        write(f, "\n")
    end
    chmod(path, 0o600)
end

function validate_config(cfg::Config)
    for (field, val) in [
        ("s3_bucket", cfg.s3_bucket),
        ("ecr_base_uri", cfg.ecr_base_uri),
        ("execution_role_arn", cfg.execution_role_arn),
        ("task_role_arn", cfg.task_role_arn),
    ]
        if isempty(val)
            throw(BurstSetupError(
                "config",
                "Missing required field: $field",
                "Run 'burst-core setup' to configure the burst environment",
            ))
        end
    end
end
