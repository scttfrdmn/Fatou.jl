@testset "errors" begin

    @testset "BurstError" begin
        e = BurstError("test message")
        @test e isa Exception
        @test e.message == "test message"
        @test sprint(showerror, e) == "BurstError: test message"
    end

    @testset "BurstPartialError" begin
        results = [1, nothing, 3]
        errors  = [nothing, BurstError("fail"), nothing]
        e = BurstPartialError(results, errors)
        @test e isa Exception
        @test e.failed_count == 1
        @test e.success_count == 2
        @test e.results === results
        @test e.errors === errors
        @test occursin("1 of 3", sprint(showerror, e))
    end

    @testset "BurstPartialError all failed" begin
        e = BurstPartialError([nothing, nothing], [BurstError("a"), BurstError("b")])
        @test e.failed_count == 2
        @test e.success_count == 0
    end

    @testset "BurstQuotaError" begin
        e = BurstQuotaError(100, 50, "fargate_vcpu", 256.0)
        @test e isa Exception
        @test e.requested_workers == 100
        @test e.actual_workers == 50
        @test e.quota_name == "fargate_vcpu"
        @test e.quota_value == 256.0
        @test occursin("100", sprint(showerror, e))
    end

    @testset "BurstCostLimitError" begin
        e = BurstCostLimitError(1.0, 5.0, [1, 2])
        @test e isa Exception
        @test e.limit == 1.0
        @test e.estimated_cost == 5.0
        @test e.partial_results == [1, 2]
        @test occursin("5.0", sprint(showerror, e))
    end

    @testset "BurstCostLimitError default partial_results" begin
        e = BurstCostLimitError(1.0, 2.0)
        @test e.partial_results == []
    end

    @testset "BurstTimeoutError" begin
        # Create a minimal SessionStatus-like object
        status = (session_id="jl-20260315-aabbccdd", status="running")
        e = BurstTimeoutError("jl-20260315-aabbccdd", 60, status)
        @test e isa Exception
        @test e.session_id == "jl-20260315-aabbccdd"
        @test e.timeout_seconds == 60
        @test e.status === status
        @test occursin("60", sprint(showerror, e))
    end

    @testset "BurstSetupError" begin
        e = BurstSetupError("config", "missing field", "run burst-core setup")
        @test e isa Exception
        @test e.step == "config"
        @test e.cause == "missing field"
        @test e.remediation == "run burst-core setup"
        @test occursin("config", sprint(showerror, e))
        @test occursin("missing field", sprint(showerror, e))
    end

end
