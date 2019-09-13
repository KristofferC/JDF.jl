__precompile__(true)
module JDF

using Blosc: Blosc
using DataFrames
using JLSO: JLSO
using CSV:CSV
using Missings:Missings
using StatsBase:rle, inverse_rle
using BufferedStreams
#using RLEVectors
using WeakRefStrings
using Blosc
using Serialization:serialize, deserialize

import Base:size, show, getindex, setindex!, eltype
import Base.Threads.@spawn

export savejdf, loadjdf, nonmissingtype, gf, iow, ior, compress_then_write
export column_loader!, gf2, psavejdf, type_compress!, type_compress

include("type_compress.jl")

Blosc.set_num_threads(6)

gf() = begin
	CSV.read("c:/data/AirOnTimeCSV/airOT198710.csv")
end

gf2() = begin
	p = "c:/data/AirOnTimeCSV/"
	f = joinpath.(p, readdir(p))
	sort!(f, by = x->filesize(x), rev=true)
	reduce(vcat, CSV.read.(f[1:100]))
end

iow() = begin
	open("c:/data/bin.bin", "w")
end

ior() = begin
	open("c:/data/bin.bin", "r")
end

some_elm(x) = zero(x)
some_elm(::Type{Missing}) = missing
some_elm(::Type{String}) = ""

compress_then_write(b, io) = compress_then_write(eltype(b), b, io)

compress_then_write(::Type{Missing}, b, io) = (len=0, type=Missing)

compress_then_write(T, b, io) = begin
	bbc = Blosc.compress(b)
	res = length(bbc)
	write(io, bbc)
	return (len=res, type=T)
end

psavejdf(outdir, df) = begin
	"""
		save a DataFrames to the outdir
	"""
	#io  = open(outdir, "w")
    pmetadatas = Any[missing for i in 1:length(names(df))]
    #for (name, b) in zip(names(df), eachcol(df))
	if !isdir(outdir)
		mkpath(outdir)
	end
	ios = BufferedOutputStream.(open.(joinpath.(outdir, string.(names(df))), Ref("w")))

	for i in 1:length(names(df))
        #el = @elapsed push!(metadatas, compress_then_write(Array(b), io))
		#println("Start: "*string(Threads.threadid()))
		pmetadatas[i] = Threads.@spawn compress_then_write(Array(df[!,i]), ios[i])
		#pmetadatas[i] = compress_then_write(Array(df[!,i]), ios[i])
		#println("End: "*string(Threads.threadid()))
        #println("saving $name took $el. Type: $(eltype(Array(b)))")
    end
	#close(io)
	metadatas = fetch.(pmetadatas)
	close.(ios)

	fnl_metadata = (names = names(df), rows = size(df,1), metadatas = metadatas, pmetadatas = pmetadatas)

	serialize(joinpath(outdir,"metadata.jls"), fnl_metadata)
	fnl_metadata
end

savejdf(outdir, df) = begin
	"""
		serially save a DataFrames to the outdir
	"""
	#io  = open(outdir, "w")
    metadatas = Any[missing for i in 1:length(names(df))]
    #for (name, b) in zip(names(df), eachcol(df))
	if !isdir(outdir)
		mkpath(outdir)
	end
	ios = BufferedOutputStream.(open.(joinpath.(outdir, string.(names(df))), Ref("w")))

	for i in 1:length(names(df))
        #el = @elapsed push!(metadatas, compress_then_write(Array(b), io))
		#println("Start: "*string(Threads.threadid()))
		metadatas[i] = compress_then_write(Array(df[!,i]), ios[i])
		#pmetadatas[i] = compress_then_write(Array(df[!,i]), ios[i])
		#println("End: "*string(Threads.threadid()))
        #println("saving $name took $el. Type: $(eltype(Array(b)))")
    end
	close.(ios)
	fnl_metadata = (names = names(df), rows = size(df,1), metadatas = metadatas)

	serialize(joinpath(outdir,"metadata.jls"), fnl_metadata)
	fnl_metadata
end



# figure out from metadata how much space is allocated
get_bytes(metadata) = begin
    if metadata.type == String
        return max(metadata.string_compressed_bytes, metadata.string_len_bytes)
    elseif metadata.type == Missing
        return 0
    elseif metadata.type >: Missing
        return max(get_bytes(metadata.Tmeta), get_bytes(metadata.missingmeta))
    else
        return metadata.len
    end
end

# load the data from file with a schema
loadjdf(indir) = begin
	metadatas = deserialize(joinpath(indir,"metadata.jls"))

    df = DataFrame()

	# get the maximum number of bytes needs to read
	bytes_needed = maximum(get_bytes.(metadatas.metadatas))

	# preallocate once
	read_buffer = Vector{UInt8}(undef, bytes_needed)

    for (name, metadata) in zip(metadatas.names, metadatas.metadatas)
		# println(name)
		# println(metadata)
		io = BufferedInputStream(open(joinpath(indir,string(name)), "r"))
		if metadata.type == Missing
			df[!,name] = Vector{Missing}(missing, metadatas.rows)
		else
			el = @elapsed res = column_loader!(read_buffer, metadata.type, io, metadata)
    		df[!,name] = res
			# println("$el | loading $name | Type: $(metadata.type)")
    	end
		close(io)
    end
 	df
end

ploadjdf(indir) = begin
	metadatas = deserialize(joinpath(indir,"metadata.jls"))

    df = DataFrame()

	# get the maximum number of bytes needs to read
	bytes_needed = maximum(get_bytes.(metadatas.metadatas))

	# preallocate once
	read_buffer = Vector{UInt8}(undef, bytes_needed)

    for (name, metadata) in zip(metadatas.names, metadatas.metadatas)
		# println(name)
		# println(metadata)
		io = BufferedInputStream(open(joinpath(indir,string(name)), "r"))
		if metadata.type == Missing
			df[!,name] = Vector{Missing}(missing, metadatas.rows)
		else
			#el = @elapsed res = column_loader!(read_buffer, metadata.type, io, metadata)
    		df[!,name] = column_loader!(read_buffer, metadata.type, io, metadata)
			# println("$el | loading $name | Type: $(metadata.type)")
    	end
		close(io)
    end
 	df
end

# load bytes bytes from io decompress into type
column_loader!(buffer, ::Type{T}, io, metadata) where T = begin
	readbytes!(io, buffer, metadata.len)
    return Blosc.decompress(T, buffer)
end

compress_then_write(::Type{Bool}, b, io) = begin
	b8 = UInt8.(b)
	bbc = Blosc.compress(b8)
	write(io, bbc)
	return (len=length(bbc), type=Bool)
end

column_loader(T::Type{Bool}, io, metadata) = begin
	# Bool are saved as UInt8
	buffer = Vector{UInt8}(undef, metadata.len)
	readbytes!(io, buffer, metadata.len)
	Bool.(Blosc.decompress(UInt8, buffer))
end

column_loader!(buffer, T::Type{Bool}, io, metadata) = begin
	# Bool are saved as UInt8
	read!(io, buffer)
	res = Blosc.decompress(UInt8, buffer)
	Bool.(res)
end


compress_then_write(::Type{T}, b, io) where T >: Missing = begin
	S = nonmissingtype(eltype(b))
	b_S = coalesce.(b, some_elm(S))

	metadata = compress_then_write(S, b_S, io)

	b_m = ismissing.(b)
	metadata2 = compress_then_write(eltype(b_m), b_m, io)

	(Tmeta = metadata, missingmeta = metadata2, type = eltype(b))
end

column_loader!(buffer, ::Type{Union{Missing, T}}, io, metadata) where T = begin
	# read the content
	Tmeta = metadata.Tmeta

	t_pre = column_loader!(buffer, Tmeta.type, io, Tmeta) |> allowmissing
	#t = t_pre
	# read the missings as bool
	m = column_loader(
		Bool,
		io,
		metadata.missingmeta)
	#return t_pre
	t_pre[m] .= missing
	t_pre
end

# perform a RLE
compress_then_write(::Type{String}, b::Array{String}, io) = begin

	# write the string one by one
	# do a Run-length encoding (RLE)
	previous_b = b[1]
	cnt = 1
	lens = Int[]
	str_lens = Int[]
	for i = 2:length(b)
		if b[i] != previous_b
			push!(str_lens, write(io, previous_b))
			push!(lens, cnt)
			#push!(str_lens, sizeof(previous_b))
			cnt = 0
			previous_b = b[i]
		end
		cnt += 1
	end

	# reach the end: two situation
	# 1) it's a new element, so write it
	# 2) it's an existing element. Also write it
	push!(str_lens, write(io, previous_b))
	push!(lens, cnt)
	#push!(str_lens, sizeof(previous_b))


	@assert sum(lens) == length(b)

	str_lens_compressed = Blosc.compress(Vector{UInt32}(str_lens))
	str_lens_bytes = write(io, str_lens_compressed)

	lens_compressed = Blosc.compress(Vector{UInt64}(lens))
	rle_bytes = write(io, lens_compressed)

	# return metadata
	return (string_compressed_bytes = sum(str_lens),
		string_len_bytes = str_lens_bytes,
		rle_bytes = rle_bytes,
		rle_len = length(str_lens),
		type = String)
end


# load a string column
"""
	metadata should consists of length, compressed byte size of string-lengths,
	string content lengths
"""
column_loader!(_, ::Type{String}, io, metadata) = begin
	buffer = Vector{UInt8}(undef, metadata.string_compressed_bytes)
	readbytes!(io, buffer, metadata.string_compressed_bytes)
	#return String(buffer)

	# read the string-lengths
	buffer2 = Vector{UInt8}(undef, metadata.string_len_bytes)
	readbytes!(io, buffer2, metadata.string_len_bytes)

	buffer3 = Vector{UInt8}(undef, metadata.rle_bytes)
	readbytes!(io, buffer3, metadata.rle_bytes)

	counts = Blosc.decompress(UInt64, buffer3)

	str_lens = Blosc.decompress(UInt32, buffer2)

	#return (String(buffer), str_lens, counts)

	lengths = inverse_rle(str_lens, counts)
	offsets = inverse_rle(vcat(0, cumsum(str_lens[1:end-1])), counts)

	#res = StringArray{String, 1}(buffer, vcat(1, cumsum(Blosc.decompress(UInt64, buffer3))[1:end-1]) .-1,  )
	res = StringArray{String, 1}(buffer, offsets, lengths)
end

column_loader!(buffer, ::Type{Missing}, io, metadata) = nothing

end # module
