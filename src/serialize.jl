"""
JLD2-based task/result serialization for Fatou.jl.
Primary: JLD2.jl (handles full Julia type system including custom structs).
Fallback: Julia Serialization stdlib for closures that JLD2 cannot serialize.
"""

using JLD2
using Serialization

function serialize_task(fn::Function, items::Vector) :: Vector{UInt8}
    buf = IOBuffer()
    try
        jldsave(buf; fn=fn, items=items)
    catch
        # JLD2 cannot serialize this closure — fall back to Serialization stdlib
        seekstart(buf)
        truncate(buf, 0)
        # Prefix with a marker byte to distinguish from JLD2 format
        write(buf, UInt8(0xFF))
        Serialization.serialize(buf, (fn, items))
    end
    take!(buf)
end

function deserialize_task(data::Vector{UInt8}) :: Tuple{Function, Vector}
    buf = IOBuffer(data)
    # Check for Serialization stdlib fallback marker
    if length(data) > 0 && data[1] == 0xFF
        skip(buf, 1)
        fn, items = Serialization.deserialize(buf)
        return fn, items
    end
    d = load(buf)
    return d["fn"], d["items"]
end

function serialize_result(result) :: Vector{UInt8}
    buf = IOBuffer()
    try
        jldsave(buf; result=result)
    catch
        seekstart(buf)
        truncate(buf, 0)
        write(buf, UInt8(0xFF))
        Serialization.serialize(buf, result)
    end
    take!(buf)
end

function deserialize_result(data::Vector{UInt8})
    buf = IOBuffer(data)
    if length(data) > 0 && data[1] == 0xFF
        skip(buf, 1)
        return Serialization.deserialize(buf)
    end
    d = load(buf)
    return d["result"]
end
