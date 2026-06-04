"""
Fatou.jl test suite.

Unit tests run always.
Integration tests require BURST_INTEGRATION_TEST=1 and a running substrate binary.
"""

using Test
using JSON3
using Fatou
using Fatou: Config, Session, DetachedSession, SessionStatus
using Fatou: generate_session_id, task_id, chunk_items
using Fatou: serialize_task, deserialize_task, serialize_result, deserialize_result
using Fatou: estimate_cost_per_hour, estimate_cost, parse_memory_gb
using Fatou: FARGATE_VCPU_PER_HOUR, FARGATE_GB_PER_HOUR
using Fatou: print_start, print_cost_estimate, print_actual_cost
using Fatou: load_config, save_config, validate_config
using Fatou: CloudManager
using Fatou: BurstError, BurstPartialError, BurstQuotaError
using Fatou: BurstCostLimitError, BurstTimeoutError, BurstSetupError
using Fatou: run!, _count_statuses, _cleanup_tasks!
using Distributed: ClusterManager

# ── Unit tests ────────────────────────────────────────────────────────────────

@testset "Fatou.jl" begin
    include("unit/errors_tests.jl")
    include("unit/config_tests.jl")
    include("unit/cost_tests.jl")
    include("unit/serialize_tests.jl")
    include("unit/session_tests.jl")
    include("unit/manager_tests.jl")
    include("unit/macro_tests.jl")
end

# ── Integration tests (substrate required) ────────────────────────────────────
# These are at the top level (not inside @testset) so that @service macro
# declarations in helpers.jl are at the appropriate top-level scope.

if haskey(ENV, "BURST_INTEGRATION_TEST")
    using AWS
    using AWS

    include("integration/helpers.jl")
    include("integration/cloud_pmap_tests.jl")
else
    @info "Skipping integration tests (set BURST_INTEGRATION_TEST=1 to enable)"
end
