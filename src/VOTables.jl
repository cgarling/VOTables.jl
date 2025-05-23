module VOTables

using EzXML
using Base64
using StringViews
using UnsafeArrays: UnsafeArray
using Mmap
using StructArrays
using Tables
using Dictionaries
using MetadataArrays
using DataAPI: metadata, colmetadata
using DataPipes
using AccessorsExtra
using AstroAngles
using Dates
using DateFormats: yeardecimal

export metadata, colmetadata

include("stringviews.jl")
include("xml.jl")
include("misc.jl")
include("metadata_piracy.jl")
include("votypes.jl")


"""    VOTables.read([result_type=StructArray], votfile; [postprocess=true], [unitful=false])

Read a VOTable from a file or another `IO` object. By default, the result is a `StructArray`: a Julian collection and table. Alternatively, specify `result_type=StructArray`.

- `postprocess=true`: do further processing of values, other than parsing formal VOTable datatypes. Includes parsing dates and times, and converting units to `Unitful.jl`; set to `false` to disable all of this.
- `unitful=false`: parse units from VOTable metadata to `Unitful.jl` units. Uses units from all loaded `Unitful`-compatible packages, ignores unknown units and shows warnings for them. Requires `postprocess=true`.
"""
function read end

struct VOTableException <: Exception
    message::String
end

# basetype, jltype, nullvalue should probably be type-parametrized to achieve type stability in row processing code
Base.@kwdef struct ColMeta
    attrs::Dictionary{Symbol,String}
    basetype::DataType
    jltype::DataType
    typesize::Int8
    fixwidth::Union{Int32,Nothing}
    nullvalue
end

# support Cols()?
# support <COOSYS> tag

read(votfile; kwargs...) = read(StructArray, votfile; kwargs...)

function read(result_type, votfile; postprocess=true, unitful=false, strict=true)
    tblx = tblxml(votfile; strict)
    colmetas = get_colmetas(tblx)
    colnames = @p colmetas map(Symbol(_.attrs[:name]))
    colarrays = @p colmetas map(Union{_.jltype, Missing}[])
    @p let
        colarrays
        _filltable!(__, tblx)
        @modify(col -> any(ismissing, col) ? col : convert(Vector{nonmissingtype(eltype(col))}, col), __[∗])  # narrow types, removing Missing unless actually present
        postprocess ? modify(__, ∗, colmetas) do col, (;attrs)
            postprocess_col(col, attrs; unitful)
        end : __
        modify(__, ∗, colmetas) do col, (;attrs)
            MetadataArray(
                col,
                _filter(!isnothing, (
                    description=get(attrs, :description, nothing),
                    ucd=get(attrs, :ucd, nothing),
                    unit_vot=get(attrs, :unit, nothing)
                )),
            )
        end
        _container_from_components(result_type, colnames .=> __)
    end
end

write(votfile) = Base.Fix1(write, votfile)
function write(votfile, tbl)
    doc = XMLDocument()

    votablex = ElementNode("VOTABLE")
    votablex["version"] = "1.4"
    votablex["xmlns:xsi"] = "http://www.w3.org/2001/XMLSchema-instance"
    votablex["xmlns"] = "http://www.ivoa.net/xml/VOTable/v1.3"
    votablex["xsi:schemaLocation"] = "http://www.ivoa.net/xml/VOTable/v1.3 http://www.ivoa.net/xml/VOTable/v1.3"
    setroot!(doc, votablex)

    resourcex = addelement!(votablex, "RESOURCE")
    tablex = addelement!(resourcex, "TABLE")
    cols = Tables.columns(tbl)
    for (colname, col) in pairs(cols)
        fieldx = addelement!(tablex, "FIELD")
        fieldx["name"] = colname
        for (k, v) in jl2votype(eltype(col)) |> pairs
            fieldx[String(k)] = v
        end
    end
    tabledatax = addelement!(addelement!(tablex, "DATA"), "TABLEDATA")
    for r in Tables.rowtable(tbl)
        trx = addelement!(tabledatax, "TR")
        for val in r
            addelement!(trx, "TD", _unparse(val))
        end
    end
    EzXML.write(votfile, doc)
end


function _container_from_components(::Type{StructArray}, pairs)
    keys = map(first, pairs)
    vals = map(last, pairs)
    while !allunique(keys)
        renamed_keys = []
        for (i, key) in enumerate(keys)
            if any(==(key), keys[1:i-1])
                push!(renamed_keys, key)
                keys[i] = Symbol(string(key, "_"))
            end
        end
        @warn "Duplicate column names found. Repeating occurrences have `_` appended to them." renamed_keys
    end
    NamedTuple{Tuple(keys)}(Tuple(vals)) |> StructArray
end

function postprocess_col(col, attrs; unitful::Bool)
    ucds = split(get(attrs, :ucd, ""), ";")
    unit = get(attrs, :unit, nothing)
    if "time.epoch" in ucds
        if eltype(col) <: AbstractString && unit == "'Y:M:D'"
            map(x -> parse(Date, x, dateformat"Y-m-d"), col)
        elseif eltype(col) <: Real && unit == "d"
            @warn "assuming julian days" column=attrs[:name] unit first(col)
            map(x -> isnan(x) ? missing : julian2datetime(x), col)
        elseif eltype(col) <: Real && unit == "yr"
            @warn "assuming years AD" column=attrs[:name] unit first(col)
            map(x -> isnan(x) ? missing : yeardecimal(x), col)
        elseif isnothing(unit)
            try
                map(x -> parse(Date, x, dateformat"Y-m-d"), col)
            catch exc
                @warn "unknown time unit" column=attrs[:name] unit eltype(col) first(col) exc
                col
            end
        else
            @warn "unknown time unit" column=attrs[:name] unit eltype(col) first(col)
            col
        end
    elseif "pos.eq.ra" in ucds && unit == "\"h:m:s\""
        hms2rad.(col)
    elseif "pos.eq.dec" in ucds && unit == "\"d:m:s\""
        dms2rad.(col)
    elseif unitful && !isnothing(unit)
        if eltype(col) <: Union{Number,Missing,Nothing}
            unit_vot_to_jl(col, unit)
        else
            @warn "column with a non-numeric eltype has a unit specified; ignoring the unit" column=attrs[:name] unit eltype(col) first(col)
            col
        end
    else
        col
    end
end

unit_vot_to_jl(_, _) = error("Load Unitful.jl to use units")

function _filltable!(cols, tblx)
    datax = @p tblx  _findall("ns:DATA", __, _namespaces(__))  only
    childx = first(eachelement(datax))
    _filltable!(cols, tblx, Val(Symbol(nodename(childx))))
end

_filltable!(cols, tblx, ::Val{F}) where F = error("Unsupported table data element: $F")

function _filltable!(cols, tblx, ::Val{:BINARY2})
    colmetas = get_colmetas(tblx)
    streamx = @p let
        tblx
        _findall("ns:DATA/ns:BINARY2/ns:STREAM", __, _namespaces(__))
        only
    end
    streamx["encoding"] == "base64" || error("Unsupported encoding: $(streamx["encoding"])")
    dataraw = nodecontent_sv(base64decode, streamx)
    nnullbytes = let ncols = length(colmetas)
        cld(ncols, 8)
    end
    i = 1
    while true
        i == length(dataraw) + 1 && break
        @assert i ≤ length(dataraw)
        nullbytes = @view dataraw[i:i+nnullbytes-1]
        i += nnullbytes
        for (icol, (col, colmeta)) in enumerate(zip(cols, colmetas))
            len = @something(
                colmeta.fixwidth,
                let
                    lenarray = @view dataraw[i:i+4-1]
                    i += 4
                    _parse_binary(Int32, lenarray) * colmeta.typesize
                end
            )
            curdata = @view dataraw[i:i+len-1]
            i += len
            if nth_bit(nullbytes[div(icol-1, 8)+1], 8-mod(icol-1, 8))
                push!(col, missing)
            else
                push!(col, _parse_binary(colmeta.jltype, curdata))
            end
        end
    end
    return cols
end

function _filltable!(cols, tblx, ::Val{:BINARY})
    colmetas = get_colmetas(tblx)
    streamx = @p let
        tblx
        _findall("ns:DATA/ns:BINARY/ns:STREAM", __, _namespaces(__))
        only
    end
    streamx["encoding"] == "base64" || error("Unsupported encoding: $(streamx["encoding"])")
    dataraw = nodecontent_sv(base64decode, streamx)
    i = 1
    while true
        i == length(dataraw) + 1 && break
        @assert i ≤ length(dataraw)
        for (icol, (col, colmeta)) in enumerate(zip(cols, colmetas))
            len = @something(
                colmeta.fixwidth,
                let
                    lenarray = @view dataraw[i:i+4-1]
                    i += 4
                    _parse_binary(Int32, lenarray) * colmeta.typesize
                end
            )
            curdata = @view dataraw[i:i+len-1]
            i += len
            rawvalue = _parse_binary(colmeta.jltype, curdata)
            value = @something(if !ismissing(rawvalue)
                if rawvalue == colmeta.nullvalue
                    missing
                elseif rawvalue isa AbstractArray && all(ismissing, rawvalue)
                    missing
                end
            end, rawvalue)
            push!(col, value)
        end
    end
    return cols
end

function _filltable!(cols, tblx, ::Val{:TABLEDATA})
    trs = @p let
        tblx
        @aside ns = _namespaces(__)
        _findall("ns:DATA/ns:TABLEDATA", __, ns)
        only
        _findall("ns:TR", __, ns)
    end
    for col in cols
        sizehint!(col, length(trs))
    end
    foreach(trs) do tr
        for (col, td) in zip(cols, eachelementptr(tr))
            @assert nodename_sv(td) == "TD"
            @multiifs(
                (Bool, UInt8, Char, String, Int16, Int32, Int64, Float32, Float64, ComplexF32, ComplexF64, Vector{Float64}),
                col isa AbstractVector{Union{Missing, _}},
                nodecontent_sv(content -> push!(col, _parse(eltype(col), content)), td),
                let
                    @warn "VOTable parsing can be slow due to runtime dispatch. Got eltype(col) == $(eltype(col)) that isn't handled by the fast path." maxlog=1
                    nodecontent_sv(content -> push!(col, _parse(eltype(col), content)), td)
                end
            )
        end
    end
    return cols
end

function tblxml(votfile; strict::Bool)
    xml = if votfile isa IO
        parsexml(votfile)
    else # filename
        isfile(votfile) || throw(SystemError("""opening file "$votfile": No such file or directory"""))
        # xml = @p Base.read(votfile, String) |> parsexml
        @p StringView(mmap(votfile)) |> parsexml
    end
    tables = @p let 
        xml
        root
        @aside ns = _namespaces(__)
        _findall("ns:RESOURCE/ns:TABLE", __, ns)
    end
    infos = @p xml |> root |> _findall("ns:RESOURCE/ns:INFO", __, _namespaces(__))
    errorinfos = @p infos |> filter(uppercase(_["name"]) == "QUERY_STATUS" && uppercase(_["value"]) == "ERROR")
    if isempty(tables)
        if isempty(errorinfos)
            error("VOTable file has no tables")
        else
            error("VOTable file has no tables, see original errors ($(length(errorinfos))) below.\n$(join(nodecontent.(errorinfos), "\n\n"))")
        end
    end
    if !isempty(errorinfos)
        strict ?
            throw(VOTableException("VOTable file contains data, but errors have occurred. Pass `strict=false` to turn this exception into a warning.\n$(join(nodecontent.(errorinfos), "\n\n"))")) :
            @error "VOTable file contains data, but errors have occurred. Pass `strict=true` to turn this warning into an exception." errors=nodecontent.(errorinfos)
    end
    length(tables) == 1 ?
        only(tables) :
        error("VOTable files with multiple tables not supported yet")
end

description(tblxml) = @p let
    tblxml
    _findall("ns:DESCRIPTION", __, _namespaces(__))
    only
    nodecontent
end

get_colmetas(tblxml) = @p let
    tblxml
    @aside ns = _namespaces(__)
    _findall("ns:FIELD", __, ns)
    map() do fieldxml
        attrs = @p attributes(fieldxml) |> map(Symbol(nodename(_)) => nodecontent(_)) |> dictionary
        basetype = TYPE_VO_TO_JL[attrs[:datatype]]
        jltype = vo2jltype(attrs)
        typesize = TYPE_VO_TO_NBYTES[attrs[:datatype]]
        fixwidth = vo2nbytes_fixwidth(attrs)
        nullvalues = @p let 
            fieldxml
            _findall("ns:VALUES", __, ns)
            filter(haskey(_, "null"))
            map(_["null"])
            map(try parse(basetype, _) catch err nothing end)
        end
        length(nullvalues) > 1 && @warn "Multiple null values found" column=attrs[:name] nullvalues
        nullvalue = @oget first(nullvalues)
        desc = @p fieldxml |> _findall("ns:DESCRIPTION", __, ns) |> maybe(nodecontent ∘ only)(__)
        isnothing(desc) || insert!(attrs, :description, desc)
        return ColMeta(; attrs, basetype, jltype, typesize, fixwidth, nullvalue)
    end
end

using PrecompileTools
@compile_workload begin
    read(joinpath(@__DIR__, "../test/data/alltypes"))
end

end
