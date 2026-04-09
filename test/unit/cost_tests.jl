@testset "cost" begin

    @testset "constants" begin
        @test FARGATE_VCPU_PER_HOUR ≈ 0.04048
        @test FARGATE_GB_PER_HOUR   ≈ 0.004445
    end

    @testset "estimate_cost_per_hour single worker" begin
        rate = estimate_cost_per_hour(1, 2, 1)
        @test rate ≈ FARGATE_VCPU_PER_HOUR + 2 * FARGATE_GB_PER_HOUR
    end

    @testset "estimate_cost_per_hour scales linearly with workers" begin
        single = estimate_cost_per_hour(1, 1, 1)
        ten    = estimate_cost_per_hour(1, 1, 10)
        @test ten ≈ single * 10
    end

    @testset "estimate_cost_per_hour zero workers" begin
        @test estimate_cost_per_hour(1, 2, 0) == 0.0
    end

    @testset "estimate_cost zero hours" begin
        @test estimate_cost(1, 2, 10, 0) == 0.0
    end

    @testset "estimate_cost one hour matches per_hour" begin
        @test estimate_cost(2, 4, 5, 1) ≈ estimate_cost_per_hour(2, 4, 5)
    end

    @testset "estimate_cost half hour" begin
        full = estimate_cost(1, 2, 3, 1)
        half = estimate_cost(1, 2, 3, 0.5)
        @test half ≈ full / 2
    end

    @testset "parse_memory_gb" begin
        @test parse_memory_gb("4GB") == 4
        @test parse_memory_gb("512MB") == 1
        @test parse_memory_gb("2048MB") == 2
        @test parse_memory_gb("4gb") == 4
        @test parse_memory_gb("2") == 2
    end

    @testset "print functions write to stderr" begin
        # Capture stderr via a temp file
        tmpfile = tempname()
        orig_stderr = stderr
        open(tmpfile, "w") do f
            redirect_stderr(f) do
                print_start(5)
                print_cost_estimate(1.2345)
                print_actual_cost(0.1)
            end
        end
        output = read(tmpfile, String)
        rm(tmpfile, force=true)
        @test occursin("5",      output)
        @test occursin("1.2345", output)
        @test occursin("0.1",    output)
    end

end
