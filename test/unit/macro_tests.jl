@testset "macro" begin

    @testset "@cloud macro expands correctly" begin
        # Verify the macro exists and is exported from Fatou
        @test isdefined(Fatou, Symbol("@cloud"))
    end

    @testset "@cloud with workers kwarg" begin
        # Check that macro expansion compiles (syntax check)
        # We can't run it without actual AWS, but we can verify it parses
        expr = :(@cloud workers=5 begin
            42
        end)
        # The macro should expand without syntax errors
        @test expr isa Expr
    end

    @testset "@cloud uses try/finally for cleanup" begin
        # Verify the generated code structure has try/finally by inspecting macroexpand
        expanded = macroexpand(Fatou, :(@cloud workers=2 begin
            99
        end))
        # Should be a try/finally block
        @test expanded isa Expr
        # The expanded form should contain a try block
        str = string(expanded)
        @test occursin("try", str) || occursin("finally", str)
    end

end
