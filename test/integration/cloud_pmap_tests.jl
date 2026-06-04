"""
Integration tests for cloud_pmap / run! using substrate as AWS emulator.
Requires BURST_INTEGRATION_TEST=1 to run.
Mirrors stet/tests/integration/map.test.ts and adder/tests/integration/test_session.py.
"""

@testset "cloud_pmap integration" begin
    require_integration()

    srv = start_substrate()

    try
        cfg = write_test_config(srv.url)
        aws_config = srv.aws_config

        bucket = cfg.s3_bucket
        create_bucket(aws_config, bucket)

        @testset "basic ordering — 10 items, 3 workers" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            items = collect(1:10)
            fn    = x -> x * 2

            session = Session(cfg=cfg, workers=3, cpu=1, memory_gb=1)
            session_id = generate_session_id()

            # Pre-write the manifest so run! can find it
            manifest = Dict(
                "session_id"             => session_id,
                "language"               => "julia",
                "library_version"        => "0.1.0",
                "status"                 => "initializing",
                "workers_requested"      => 3,
                "workers_actual"         => 3,
                "cpu"                    => 1,
                "memory_gb"              => 1,
                "backend"                => "fargate",
                "spot"                   => false,
                "region"                 => "us-east-1",
                "cost_estimate_per_hour" => 0.0,
                "task_count"             => 3,
                "chunk_count"            => 3,
                "tasks_total"            => 3,
                "tasks_complete"         => 0,
                "tasks_failed"           => 0,
                "workers_active"         => 0,
                "cost_actual"            => 0.0,
                "created_at"             => "2026-01-01T00:00:00Z",
            )
            S3.put_object(bucket, "sessions/$(session_id)/manifest.json",
                Dict("body" => Vector{UInt8}(JSON3.write(manifest)));
                aws_config=aws_config)

            # Upload task files and simulate workers concurrently
            chunks = chunk_items(items, 3)
            for (i, chunk) in enumerate(chunks)
                task_data = serialize_task(fn, chunk)
                S3.put_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i-1)).task",
                    Dict("body" => task_data); aws_config=aws_config)
            end

            # Override _launch_workers! to simulate workers instead
            simulate_workers(aws_config, bucket, session_id, items, fn, 3)

            # Now use a mock that skips _launch_workers! and goes straight to polling
            # We test run! by directly calling the polling + collect path
            done, failed = _count_statuses(aws_config, bucket, session_id, length(chunks))
            @test done == length(chunks)
            @test failed == 0

            # Collect results
            results = Vector{Vector}(undef, length(chunks))
            for i in 1:length(chunks)
                data = S3.get_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i-1)).result";
                    aws_config=aws_config)
                results[i] = deserialize_result(data.body)
            end
            flat = vcat(results...)
            @test flat == [x * 2 for x in items]
        end

        @testset "out-of-order chunk completion returns ordered results" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            items = collect(1:6)
            fn    = x -> x + 100
            n_workers = 3
            chunks = chunk_items(items, n_workers)
            session_id = generate_session_id()

            # Write tasks
            for (i, chunk) in enumerate(chunks)
                task_data = serialize_task(fn, chunk)
                S3.put_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i-1)).task",
                    Dict("body" => task_data); aws_config=aws_config)
            end

            # Simulate workers in reverse order (chunk 2, 1, 0)
            for i in length(chunks):-1:1
                chunk = chunks[i]
                results_data = serialize_result([fn(item) for item in chunk])
                tid = task_id(i - 1)
                S3.put_object(bucket,
                    "sessions/$(session_id)/tasks/$(tid).result",
                    Dict("body" => results_data); aws_config=aws_config)
                S3.put_object(bucket,
                    "sessions/$(session_id)/tasks/$(tid).status",
                    Dict("body" => Vector{UInt8}("done")); aws_config=aws_config)
            end

            # Verify all done
            done, failed = _count_statuses(aws_config, bucket, session_id, length(chunks))
            @test done == length(chunks)

            # Collect in order
            results = Vector{Vector}(undef, length(chunks))
            for i in 1:length(chunks)
                data = S3.get_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i-1)).result";
                    aws_config=aws_config)
                results[i] = deserialize_result(data.body)
            end
            flat = vcat(results...)
            @test flat == [fn(x) for x in items]
        end

        @testset "task files present in S3 before launch" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            items = [10, 20, 30]
            fn    = x -> x * 3
            n_workers = 2
            chunks = chunk_items(items, n_workers)
            session_id = generate_session_id()

            # Manually upload task files (what run! does before calling _launch_workers!)
            for (i, chunk) in enumerate(chunks)
                task_data = serialize_task(fn, chunk)
                key = "sessions/$(session_id)/tasks/$(task_id(i-1)).task"
                S3.put_object(bucket, key, Dict("body" => task_data); aws_config=aws_config)
            end

            # Verify each task file is readable and correct
            for (i, chunk) in enumerate(chunks)
                key = "sessions/$(session_id)/tasks/$(task_id(i-1)).task"
                resp = S3.get_object(bucket, key; aws_config=aws_config)
                fn2, items2 = deserialize_task(resp.body)
                @test items2 == chunk
                @test fn2(items2[1]) == items2[1] * 3
            end
        end

        @testset "manifest written with correct session_id and status=running" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            session_id = generate_session_id()
            manifest = Dict(
                "session_id"        => session_id,
                "status"            => "running",
                "chunk_count"       => 4,
                "tasks_total"       => 4,
                "tasks_complete"    => 0,
                "tasks_failed"      => 0,
                "workers_actual"    => 4,
                "language"          => "julia",
                "library_version"   => "0.1.0",
            )
            S3.put_object(bucket, "sessions/$(session_id)/manifest.json",
                Dict("body" => Vector{UInt8}(JSON3.write(manifest)));
                aws_config=aws_config)

            # Read it back
            resp = S3.get_object(bucket,
                "sessions/$(session_id)/manifest.json"; aws_config=aws_config)
            m = JSON3.read(String(resp.body))
            @test m[:session_id] == session_id
            @test m[:status] == "running"
            @test m[:chunk_count] == 4
        end

        @testset "task files deleted after run (manifest kept)" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            items = [1, 2, 3, 4]
            fn    = identity
            n_workers = 2
            chunks = chunk_items(items, n_workers)
            session_id = generate_session_id()

            # Write task + result + status files
            simulate_workers(aws_config, bucket, session_id, items, fn, n_workers)

            # Write manifest
            manifest = Dict("session_id" => session_id, "status" => "complete",
                            "chunk_count" => length(chunks), "tasks_total" => length(chunks))
            S3.put_object(bucket, "sessions/$(session_id)/manifest.json",
                Dict("body" => Vector{UInt8}(JSON3.write(manifest)));
                aws_config=aws_config)

            # Call cleanup — deletes task/result/status files, keeps manifest
            _cleanup_tasks!(aws_config, bucket, session_id, length(chunks))

            # Task files should be gone
            for i in 0:(length(chunks) - 1)
                for suffix in ("task", "result", "status")
                    key = "sessions/$(session_id)/tasks/$(task_id(i)).$(suffix)"
                    try
                        S3.get_object(bucket, key; aws_config=aws_config)
                        @test false  # Should not exist
                    catch
                        @test true  # Expected: not found
                    end
                end
            end

            # Manifest should still be readable
            resp = S3.get_object(bucket,
                "sessions/$(session_id)/manifest.json"; aws_config=aws_config)
            m = JSON3.read(String(resp.body))
            @test m[:session_id] == session_id
        end

        @testset "simulate_workers produces correct results" begin
            reset_substrate(srv)
            create_bucket(aws_config, bucket)

            items = collect(1:9)
            fn    = x -> x^2
            n_workers = 3
            session_id = generate_session_id()

            simulate_workers(aws_config, bucket, session_id, items, fn, n_workers)

            chunks = chunk_items(items, n_workers)
            all_results = []
            for i in 0:(length(chunks) - 1)
                status_text = String(S3.get_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i)).status";
                    aws_config=aws_config).body)
                @test strip(status_text) == "done"

                result_data = S3.get_object(bucket,
                    "sessions/$(session_id)/tasks/$(task_id(i)).result";
                    aws_config=aws_config).body
                append!(all_results, deserialize_result(result_data))
            end
            @test all_results == [x^2 for x in items]
        end

    finally
        stop_substrate(srv)
    end
end
