"""
Fargate cost estimation and ARCHITECTURE.md-compliant console output.
All print functions write to stderr.
"""

const FARGATE_VCPU_PER_HOUR = 0.04048
const FARGATE_GB_PER_HOUR   = 0.004445

function estimate_cost_per_hour(cpu::Number, memory_gb::Number, workers::Number) :: Float64
    workers * (cpu * FARGATE_VCPU_PER_HOUR + memory_gb * FARGATE_GB_PER_HOUR)
end

function estimate_cost(cpu::Number, memory_gb::Number, workers::Number, hours::Number) :: Float64
    estimate_cost_per_hour(cpu, memory_gb, workers) * hours
end

function print_start(workers::Int)
    println(stderr, "🚀 Starting burst cluster with $workers worker$(workers == 1 ? "" : "s")")
end

function print_cost_estimate(rate::Float64)
    println(stderr, "💰 Estimated cost: ~\$$(round(rate, digits=4))/hour")
end

function print_processing(total::Int, workers::Int)
    println(stderr, "📊 Processing $total item$(total == 1 ? "" : "s") with $workers worker$(workers == 1 ? "" : "s")")
end

function print_chunks(chunks::Int, avg::Float64)
    println(stderr, "📦 Created $chunks chunk$(chunks == 1 ? "" : "s") (avg $(round(avg, digits=1)) items per chunk)")
end

function print_submitted(n::Int)
    println(stderr, "✓ Submitted $n task$(n == 1 ? "" : "s")")
end

function print_progress(done::Int, total::Int, elapsed::String)
    println(stderr, "⏳ Progress: $done/$total tasks ($elapsed elapsed)")
end

function print_completed(elapsed::String)
    println(stderr, "\n✓ Completed in $elapsed")
end

function print_actual_cost(cost::Float64)
    println(stderr, "💰 Actual cost: \$$(round(cost, digits=4))")
end

function print_quota_warning(req::Int, req_vcpu::Int, actual::Int, actual_vcpu::Int)
    println(stderr, "⚠ Requested $req workers ($req_vcpu vCPUs) but quota allows $actual workers ($actual_vcpu vCPUs)")
    println(stderr, "⚠ Using $actual workers instead. Request quota increase: https://console.aws.amazon.com/servicequotas/")
end

function print_cost_alert(threshold::Float64)
    println(stderr, "⚠ Estimated cost exceeds alert threshold of \$$(round(threshold, digits=4))")
end

function parse_memory_gb(memory::String) :: Int
    upper = uppercase(strip(memory))
    if endswith(upper, "GB")
        return round(Int, parse(Float64, upper[1:end-2]))
    elseif endswith(upper, "MB")
        mb = parse(Float64, upper[1:end-2])
        return max(1, ceil(Int, mb / 1024))
    else
        return round(Int, parse(Float64, memory))
    end
end
