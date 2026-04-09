@testset "serialize" begin

    @testset "serialize_task / deserialize_task roundtrip — anonymous function" begin
        fn = x -> x * 2
        items = [1, 2, 3]
        data = serialize_task(fn, items)
        @test data isa Vector{UInt8}
        fn2, items2 = deserialize_task(data)
        @test items2 == items
        @test fn2(5) == 10
    end

    @testset "serialize_task roundtrip — Vector{String}" begin
        fn = s -> uppercase(s)
        items = ["hello", "world"]
        data = serialize_task(fn, items)
        fn2, items2 = deserialize_task(data)
        @test items2 == items
        @test fn2("foo") == "FOO"
    end

    @testset "serialize_task roundtrip — custom struct" begin
        struct Point; x::Float64; y::Float64; end
        fn = p -> Point(p.x * 2, p.y * 2)
        items = [Point(1.0, 2.0), Point(3.0, 4.0)]
        data = serialize_task(fn, items)
        fn2, items2 = deserialize_task(data)
        @test length(items2) == 2
        r = fn2(items2[1])
        @test r.x ≈ 2.0
    end

    @testset "serialize_task roundtrip — large array" begin
        fn = x -> x + 1
        items = collect(1:1000)
        data = serialize_task(fn, items)
        fn2, items2 = deserialize_task(data)
        @test items2 == items
        @test fn2(1) == 2
    end

    @testset "serialize_result / deserialize_result roundtrip" begin
        results = [1, "two", Dict("three" => 3), nothing]
        data = serialize_result(results)
        @test data isa Vector{UInt8}
        results2 = deserialize_result(data)
        @test results2 == results
    end

    @testset "serialize_result empty array" begin
        data = serialize_result([])
        r = deserialize_result(data)
        @test r == []
    end

    @testset "Serialization fallback for closures" begin
        # Capture a local variable — JLD2 may or may not handle this
        x = 42
        fn = y -> y + x
        items = [1, 2, 3]
        # Should succeed with either JLD2 or Serialization fallback
        data = serialize_task(fn, items)
        fn2, items2 = deserialize_task(data)
        @test fn2(0) == 42
        @test items2 == items
    end

end
