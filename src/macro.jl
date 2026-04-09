"""
@cloud macro for Fatou.jl.
Wraps arbitrary Julia distributed code with automatic cloud worker provisioning.

Usage:
    results = @cloud workers=50 cpu=4 begin
        pmap(simulate, seeds)
    end

Workers are always cleaned up via try/finally even if the block throws.
"""

macro cloud(args...)
    if isempty(args)
        error("@cloud requires at least a begin...end block")
    end

    expr = args[end]
    kwargs_exprs = args[1:end-1]

    # Parse keyword arguments: workers=N, cpu=N, memory="4GB", etc.
    kw_workers = Expr(:kw, :workers, 10)
    kw_cpu     = Expr(:kw, :cpu, 1)
    kw_memory  = Expr(:kw, :memory, "2GB")
    kw_backend = Expr(:kw, :backend, :(:fargate))
    kw_spot    = Expr(:kw, :spot, false)

    for kwarg in kwargs_exprs
        if kwarg isa Expr && kwarg.head == :(=)
            k, v = kwarg.args
            if k == :workers
                kw_workers = Expr(:kw, :workers, v)
            elseif k == :cpu
                kw_cpu = Expr(:kw, :cpu, v)
            elseif k == :memory
                kw_memory = Expr(:kw, :memory, v)
            elseif k == :backend
                kw_backend = Expr(:kw, :backend, v)
            elseif k == :spot
                kw_spot = Expr(:kw, :spot, v)
            end
        end
    end

    # Generate: pids = addcloudprocs(workers; cpu, memory, ...); try; expr; finally; rmprocs(pids); end
    quote
        local _pids = addcloudprocs($(kw_workers.args[2]);
            $(kw_cpu), $(kw_memory), $(kw_backend), $(kw_spot))
        local _result
        try
            _result = $(esc(expr))
        finally
            rmprocs(_pids)
        end
        _result
    end
end
