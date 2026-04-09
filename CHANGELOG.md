# Changelog

All notable changes to Fatou.jl are documented here.

## [0.1.0] — 2026-04-08

Initial release of Fatou.jl — the Julia member of the burst cloud-bursting library family.

### Added

**Task mode (`cloud_pmap` / `Session.run!`)**
- `cloud_pmap(f, items; workers, cpu, memory, backend, spot, max_cost, cost_alert, timeout, region)` — drop-in replacement for `pmap()` that runs on AWS ECS Fargate
- `Session` struct with 7-step AWS lifecycle (upload tasks → launch workers → poll S3 → download results → cleanup)
- `DetachedSession` / `attach()` for fire-and-forget workflows
- `SessionStatus` for polling long-running jobs

**Worker mode (`addcloudprocs` / `@cloud`)**
- `addcloudprocs(n; cpu, memory, backend, spot, region, timeout)` — launch Julia distributed workers on ECS that TCP-connect back to the client; compatible with `pmap()`, `@spawnat`, `@distributed`, Dagger.jl
- `CloudManager <: ClusterManager` — integrates with Julia's native distributed computing
- `@cloud workers=N cpu=2 begin ... end` — macro that wraps any distributed code with automatic worker lifecycle

**Serialization**
- JLD2.jl primary serialization for tasks and results (handles full Julia type system)
- `Serialization` stdlib fallback for closures that JLD2 cannot handle
- Automatic format detection via `0xFF` marker byte

**Cost management**
- Fargate pricing constants: `FARGATE_VCPU_PER_HOUR = 0.04048`, `FARGATE_GB_PER_HOUR = 0.004445`
- `estimate_cost_per_hour / estimate_cost` — pre-flight cost estimates
- `max_cost` / `cost_alert` options to abort or warn before incurring costs
- `BurstCostLimitError` thrown before any AWS calls when estimated cost exceeds limit

**Error types** — all `<: Exception` with `Base.showerror`:
- `BurstError` — general burst error
- `BurstPartialError` — some tasks failed (partial results returned)
- `BurstQuotaError` — Fargate vCPU quota reduced worker count
- `BurstCostLimitError` — job aborted due to cost limit
- `BurstTimeoutError` — polling timeout exceeded
- `BurstSetupError` — configuration / environment setup failed

**Configuration**
- `Config` struct with all AWS and cluster settings
- `load_config()` — reads `BURST_CONFIG_PATH` or `~/.burst/config.json`
- `save_config(cfg)` — writes with `0o600` permissions
- `validate_config(cfg)` — throws `BurstSetupError` for missing required fields

**Environment / image management**
- `capture_environment()` — reads active Julia project's `Manifest.toml`, computes SHA-256 hash
- `ensure_image(cfg)` — checks ECR for existing image; delegates to `burst-core image build` if not found
- `_generate_dockerfile()` — emits Dockerfile with `PackageCompiler.jl` sysimage step
- `_generate_precompile_jl()` — generates precompile script for `create_sysimage()`

**Infrastructure**
- `Dockerfile.worker` with `PackageCompiler.jl` sysimage build
- 118 unit tests (errors, config, cost, serialize, session, manager, macro)
- Substrate-based integration tests (`BURST_INTEGRATION_TEST=1`)
- Compatible with Julia 1.10+

### Session ID format
`jl-{yyyymmdd}-{random8hex}` — e.g. `jl-20260408-3f8a1b2c`

### S3 key schema
```
sessions/{session_id}/manifest.json
sessions/{session_id}/tasks/{task_id}.task
sessions/{session_id}/tasks/{task_id}.result
sessions/{session_id}/tasks/{task_id}.status
sessions/{session_id}/tasks/{task_id}.error
```

[0.1.0]: https://github.com/scttfrdmn/Fatou.jl/releases/tag/v0.1.0
