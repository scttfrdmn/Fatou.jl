@testset "config" begin

    function with_temp_config(f; content=nothing)
        dir = mktempdir()
        path = joinpath(dir, "config.json")
        if content !== nothing
            write(path, content)
        end
        old = get(ENV, "BURST_CONFIG_PATH", nothing)
        ENV["BURST_CONFIG_PATH"] = path
        try
            f(path)
        finally
            if old === nothing
                delete!(ENV, "BURST_CONFIG_PATH")
            else
                ENV["BURST_CONFIG_PATH"] = old
            end
            rm(dir, recursive=true, force=true)
        end
    end

    @testset "returns defaults when file missing" begin
        with_temp_config() do path
            cfg = load_config()
            @test cfg.region == "us-east-1"
            @test cfg.ecs_cluster == "burst-cluster"
            @test cfg.default_workers == 10
        end
    end

    @testset "reads snake_case JSON" begin
        content = """
        {
            "region": "eu-west-1",
            "s3_bucket": "my-bucket",
            "ecs_cluster": "my-cluster",
            "ecr_base_uri": "123.dkr.ecr.eu-west-1.amazonaws.com",
            "execution_role_arn": "arn:aws:iam::123:role/exec",
            "task_role_arn": "arn:aws:iam::123:role/task"
        }
        """
        with_temp_config(content=content) do path
            cfg = load_config()
            @test cfg.region == "eu-west-1"
            @test cfg.s3_bucket == "my-bucket"
            @test cfg.ecs_cluster == "my-cluster"
            @test cfg.ecr_base_uri == "123.dkr.ecr.eu-west-1.amazonaws.com"
            @test cfg.execution_role_arn == "arn:aws:iam::123:role/exec"
            @test cfg.task_role_arn == "arn:aws:iam::123:role/task"
        end
    end

    @testset "save/load roundtrip" begin
        with_temp_config() do path
            cfg = Config(
                region="us-west-2",
                s3_bucket="burst-us-west-2",
                ecr_base_uri="123.dkr.ecr.us-west-2.amazonaws.com",
                execution_role_arn="arn:aws:iam::123:role/exec",
                task_role_arn="arn:aws:iam::123:role/task",
                default_cpu=2,
            )
            save_config(cfg)
            loaded = load_config()
            @test loaded.region == "us-west-2"
            @test loaded.s3_bucket == "burst-us-west-2"
            @test loaded.default_cpu == 2
        end
    end

    @testset "saved file has 0o600 permissions" begin
        with_temp_config() do path
            save_config(Config())
            mode = filemode(path) & 0o777
            @test mode == 0o600
        end
    end

    @testset "Config override constructor" begin
        base = Config(region="us-east-1")
        updated = Config(base; region="ap-southeast-1")
        @test updated.region == "ap-southeast-1"
        @test updated.ecs_cluster == base.ecs_cluster
    end

    @testset "validate_config passes for valid config" begin
        cfg = Config(
            region="us-east-1",
            s3_bucket="my-bucket",
            ecr_base_uri="123.dkr.ecr.us-east-1.amazonaws.com",
            execution_role_arn="arn:aws:iam::123:role/exec",
            task_role_arn="arn:aws:iam::123:role/task",
        )
        @test_nowarn validate_config(cfg)
    end

    @testset "validate_config throws for missing s3_bucket" begin
        cfg = Config(s3_bucket="")
        @test_throws BurstSetupError validate_config(cfg)
    end

    @testset "validate_config throws for missing ecr_base_uri" begin
        cfg = Config(s3_bucket="x", ecr_base_uri="")
        @test_throws BurstSetupError validate_config(cfg)
    end

end
