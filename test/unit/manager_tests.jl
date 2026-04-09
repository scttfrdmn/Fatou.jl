@testset "manager" begin

    function make_config()
        Config(
            region="us-east-1",
            s3_bucket="burst-us-east-1",
            ecs_cluster="burst-cluster",
            ecr_base_uri="123.dkr.ecr.us-east-1.amazonaws.com",
            execution_role_arn="arn:aws:iam::123:role/exec",
            task_role_arn="arn:aws:iam::123:role/task",
        )
    end

    @testset "CloudManager struct fields" begin
        cfg = make_config()
        mgr = CloudManager(
            "jl-20260315-aabbccdd",  # session_id
            10,                       # workers_actual
            2,                        # cpu
            4,                        # memory_gb
            :fargate,                 # backend
            false,                    # spot
            "us-east-1",              # region
            cfg,                      # cfg
            "123.dkr.ecr.us-east-1.amazonaws.com/burst-workers-julia:abc123", # image_uri
            "1.2.3.4",               # client_host
            9009,                    # client_port
        )
        @test mgr.session_id == "jl-20260315-aabbccdd"
        @test mgr.workers_actual == 10
        @test mgr.cpu == 2
        @test mgr.memory_gb == 4
        @test mgr.backend == :fargate
        @test mgr.client_host == "1.2.3.4"
        @test mgr.client_port == 9009
    end

    @testset "CloudManager is a ClusterManager" begin
        cfg = make_config()
        mgr = CloudManager("id", 1, 1, 2, :fargate, false, "us-east-1", cfg,
                           "img:tag", "1.2.3.4", 9009)
        @test mgr isa ClusterManager
    end

    @testset "parse_memory_gb in cost module" begin
        @test parse_memory_gb("2GB") == 2
        @test parse_memory_gb("4gb") == 4
        @test parse_memory_gb("1024MB") == 1
    end

end
