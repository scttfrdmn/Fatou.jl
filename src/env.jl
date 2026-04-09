"""
Environment snapshot and worker image management for Fatou.jl.
Reads the active Julia project's Manifest.toml to capture the environment.
Builds Docker images with PackageCompiler.jl sysimage for cold-start performance.
"""

using SHA
using TOML
using AWS

function capture_environment() :: Tuple{String, String}
    # Find the active project's Manifest.toml
    project_dir = dirname(something(Base.active_project(), ""))
    manifest_path = joinpath(project_dir, "Manifest.toml")

    if !isfile(manifest_path)
        # No manifest — use empty content, hash of empty string
        return "", bytes2hex(sha256(""))
    end

    manifest_content = read(manifest_path, String)
    env_hash = bytes2hex(sha256(manifest_content))[1:16]
    return manifest_content, env_hash
end

function _julia_version_minor() :: String
    v = VERSION
    "$(v.major).$(v.minor)"
end

function _get_project_packages() :: Vector{String}
    project_file = Base.active_project()
    project_file === nothing && return String[]
    isfile(project_file) || return String[]
    d = TOML.parsefile(project_file)
    collect(keys(get(d, "deps", Dict())))
end

function _generate_dockerfile(julia_version::String, packages::Vector{String}) :: String
    pkg_list = join([":" * p for p in packages], ", ")
    precompile_statements = join(["using $p" for p in packages], "\n")

    """
FROM julia:$(julia_version)
WORKDIR /app
COPY Project.toml Manifest.toml ./
RUN julia --project=/app -e 'using Pkg; Pkg.instantiate()'
COPY precompile.jl ./
RUN julia --project=/app -e '
    using PackageCompiler
    pkgs = Symbol[$(pkg_list)]
    create_sysimage(pkgs,
        sysimage_path="/app/burst.so",
        precompile_execution_file="/app/precompile.jl")
'
COPY worker.jl ./
ENV JULIA_NUM_THREADS=auto
CMD ["julia", "--sysimage=/app/burst.so", "--project=/app", "worker.jl"]
"""
end

function _generate_precompile_jl(packages::Vector{String}) :: String
    join(["using $p" for p in packages], "\n") * "\n"
end

function ensure_image(cfg::Config) :: String
    _, env_hash = capture_environment()
    repo_name = "burst-workers-julia"
    tag = env_hash
    ecr_uri = "$(cfg.ecr_base_uri)/$(repo_name):$(tag)"

    # Check ECR for existing image
    aws_config = global_aws_config(region=cfg.region)
    image_exists = try
        ECR.describe_images(cfg.ecr_base_uri, Dict(
            "repositoryName" => repo_name,
            "imageIds" => [Dict("imageTag" => tag)],
        ); aws_config=aws_config)
        true
    catch
        false
    end

    if image_exists
        return ecr_uri
    end

    # Build via burst-core
    julia_ver = _julia_version_minor()
    packages = _get_project_packages()

    println(stderr, "📦 Building worker image with precompiled sysimage...")
    println(stderr, "   This takes 5-15 minutes for the first environment.")
    println(stderr, "   Subsequent runs with the same packages will be instant.")

    dockerfile = _generate_dockerfile(julia_ver, packages)
    precompile = _generate_precompile_jl(packages)

    mktempdir() do tmp
        write(joinpath(tmp, "Dockerfile"), dockerfile)
        write(joinpath(tmp, "precompile.jl"), precompile)

        # Copy worker.jl
        worker_src = joinpath(@__DIR__, "worker.jl")
        if isfile(worker_src)
            cp(worker_src, joinpath(tmp, "worker.jl"))
        end

        run(`burst-core image build --lang julia --env-hash $env_hash --build-dir $tmp`)
    end

    ecr_uri
end
