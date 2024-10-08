using Test
using SafeTestsets
using Pkg
using NetworkDynamics
using SciMLBase
using InteractiveUtils
using CUDA
using KernelAbstractions
using Adapt
using NetworkDynamics: iscudacompatible
using Aqua
using ExplicitImports

"""
Test utility, which rebuilds the Network with all different execution styles and compares the
results of the coreloop.
"""
function test_execution_styles(prob)
    styles = [KAExecution{true}(),
              KAExecution{false}(),
              SequentialExecution{true}(),
              SequentialExecution{false}(),
              PolyesterExecution{true}(),
              PolyesterExecution{false}(),
              ThreadedExecution{true}(),
              ThreadedExecution{false}()]
    unmatchedstyles = filter(subtypes(NetworkDynamics.ExecutionStyle)) do abstractstyle
        !any(s -> s isa abstractstyle, styles)
    end
    @assert isempty(unmatchedstyles) "Some ExecutionStyle won't be tested: $unmatchedstyles"

    aggregators = [NaiveAggregator,
                   KAAggregator,
                   SequentialAggregator,
                   PolyesterAggregator,
                   ThreadedAggregator,
                   SparseAggregator]
    unmatchedaggregators = filter(subtypes(NetworkDynamics.Aggregator)) do abstractaggregator
        !any(s -> s <: abstractaggregator, aggregators)
    end
    @assert isempty(unmatchedaggregators) "Some AggrgationStyle won't be tested: $unmatchedaggregators"

    @assert prob isa ODEProblem "test_execution_styles only works for ODEProblems"

    u = copy(prob.u0)
    du = zeros(eltype(u), length(u))
    t = 0.0
    p = copy(prob.p)
    nw = prob.f.f
    nw(du, u, p, t)
    @test u==prob.u0
    @test p==prob.p

    exsaggs = [(ex, agg) for ex in styles for agg in aggregators]

    @testset "Test Execution Styles and Aggregators" begin
        for (execution, aggregator) in exsaggs
            _nw = Network(nw; execution, aggregator=aggregator(nw.layer.aggregator.f))
            _du = zeros(eltype(u), length(u))
            try
                _nw(_du, u, p, t)
            catch e
                # XXX: fix for https://github.com/JuliaLang/julia/issues/55075
                if e isa MethodError && e.f == Base.elsize
                    @test_broken false
                    continue
                end
                println("Error in $execution with $aggregator: $e")
                @test false
                continue
            end
            issame = isapprox(_du, du; atol=1e-10)
            if !issame
                println("$execution with $aggregator lead to different results: extrema(Δ) = $(extrema(_du - du))")
            end
            @test issame
        end

        if CUDA.functional()
            to = CuArray
            u_d = adapt(to, u)
            p_d = adapt(to, p)

            for (execution, aggregator) in exsaggs
                (iscudacompatible(execution) && iscudacompatible(aggregator)) || continue

                _nw = Network(nw; execution, aggregator=aggregator(nw.layer.aggregator.f))
                _nw_d = adapt(to, _nw)
                _du_d = adapt(to, zeros(eltype(u), length(u)))

                _nw_d(_du_d, u_d, p_d, t)
                issame = isapprox(Vector(_du_d), du; atol=1e-10)
                if !issame
                    println("CUDA execution lead to different results: extrema(Δ) = $(extrema(_du - du))")
                end
                @test issame
            end
        end
    end
end

@testset "NetworkDynamics Tests" begin
    @testset "Package Quality Tests" begin
        # print_explicit_imports(NetworkDynamics)
        @test check_no_implicit_imports(NetworkDynamics) === nothing
        @test check_no_stale_explicit_imports(NetworkDynamics) === nothing
        Aqua.test_all(NetworkDynamics;
            ambiguities=false,
            persistent_tasks=false)
        @test_broken isempty(Docs.undocumented_names(NetworkDynamics))
    end

    @safetestset "utils test" begin include("utils_test.jl") end
    @safetestset "construction test" begin include("construction_test.jl") end
    @safetestset "Aggregation Tests" begin include("aggregators_test.jl") end
    @safetestset "Symbolic Indexing Tests" begin include("symbolicindexing_test.jl") end

    @safetestset "Diffusion test" begin include("diffusion_test.jl") end
    @safetestset "inhomogeneous test" begin include("inhomogeneous_test.jl") end
    @safetestset "massmatrix test" begin include("massmatrix_test.jl") end
    @safetestset "doctor test" begin include("doctor_test.jl") end
    @safetestset "initialization test" begin include("initialization_test.jl") end

    @safetestset "AD test" begin include("AD_test.jl") end

    if CUDA.functional()
        @safetestset "GPU test" begin include("GPU_test.jl") end
    end

    @safetestset "MTK extension test" begin include("MTK_test.jl") end
end

@testset "Test Doc Examples" begin
    @info "Activate doc environment and test examples"
    Pkg.activate(joinpath(pkgdir(NetworkDynamics), "docs"))
    Pkg.develop(path=pkgdir(NetworkDynamics))
    Pkg.instantiate()

    examples = joinpath(pkgdir(NetworkDynamics), "docs", "examples")
    for file in readdir(examples; join=true)
        endswith(file, ".jl") || continue
        name = basename(file)

        @info "Test $name"
        if name == "kuramoto_delay.jl"
            @test_broken false
            continue
        end
        eval(:(@safetestset $name begin include($file) end))
    end
end

if !CUDA.functional()
    @test gethostname() != "hw-g14" # on this pc, CUDA *should* be available
    @warn "Skipped all CUDA tests because no device is available."
end
