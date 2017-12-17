__precompile__()

module SASLib

version = "0.1"

using StringEncodings
using DataFrames

export readsas

import Base.show

include("debug.jl")
include("constants.jl")
include("utils.jl")

# store history of handler for debugging purpose
# @debug history = []

struct FileFormatError <: Exception
    message::AbstractString
end 

# NOTE there's no "index" for Julia's DataFrame as compared to Pandas
struct ReaderConfig 
    filename::AbstractString
    encoding::AbstractString
    chunksize::UInt8
    convert_dates::Bool
    convert_empty_string_to_missing::Bool
    convert_text::Bool
    convert_header_text::Bool
    blank_missing::Bool
    ReaderConfig(filename, config = Dict()) = new(filename, 
        get(config, :encoding, default_encoding),
        get(config, :chunksize, default_chunksize),
        get(config, :convert_dates, default_convert_dates), 
        get(config, :convert_empty_string_to_missing, default_convert_empty_string_to_missing),
        get(config, :convert_text, default_convert_text), 
        get(config, :convert_header_text, default_convert_header_text),
        get(config, :blank_missing, default_blank_missing))
end

struct Column
    id::Int64
    name::AbstractString
    label::Vector{UInt8}  # really?
    format::AbstractString
    coltype::UInt8
    length::Int64
end

# technically these fields may have lower precision (need casting?)
struct subheader_pointer
    offset::Int64
    length::Int64
    compression::Int64
    ptype::Int64
end

mutable struct Handler
    io::IOStream
    config::ReaderConfig
    
    compression::Vector{UInt8}
    column_names_strings::Vector{Vector{UInt8}}
    column_names::Vector{AbstractString}
    column_types::Vector{UInt8}
    column_formats::Vector{AbstractString}
    columns::Vector{Column}
    
    current_page_data_subheader_pointers::Vector{subheader_pointer}
    cached_page::Vector{UInt8}
    column_data_lengths::Vector{Int64}
    column_data_offsets::Vector{Int64}
    current_row_in_file_index::UInt64
    current_row_on_page_index::UInt64

    file_endianness::Symbol
    sys_endianness::Symbol
    byte_swap::Bool

    U64::Bool
    int_length::UInt8
    page_bit_offset::UInt8
    subheader_pointer_length::UInt8

    file_encoding::AbstractString
    platform::AbstractString
    name::Union{AbstractString,Vector{UInt8}}
    file_type::Union{AbstractString,Vector{UInt8}}

    date_created::DateTime
    date_modified::DateTime

    header_length::UInt64
    page_length::UInt64
    page_count::UInt64
    sas_release::Union{AbstractString,Vector{UInt8}}
    server_type::Union{AbstractString,Vector{UInt8}}
    os_version::Union{AbstractString,Vector{UInt8}}
    os_name::Union{AbstractString,Vector{UInt8}}

    row_length
    row_count
    col_count_p1
    col_count_p2
    mix_page_row_count
    lcs
    lcp

    current_page_type
    current_page_block_count
    current_page_subheaders_count
    column_count
    creator_proc

    byte_chunk::Array{UInt8, 2}
    string_chunk::Array{String, 2}
    current_row_in_chunk_index

    current_page::Int32
    
    Handler(config::ReaderConfig) = new(
        Base.open(config.filename),
        config)
end

struct SASData
    dataframe::DataFrame
    handler::Handler
end

function show(handler::Handler)
    return "Handler: config=$(handler.config) header_length=$header_length $page_length=page_length $page_count=$page_count"
end

function open(config::ReaderConfig) 
    # @debug("Opening $(config.filename)")
    handler = Handler(config)
    handler.compression = b""
    handler.column_names_strings = []
    handler.column_names = []
    handler.columns = []
    handler.column_formats = []
    handler.current_page_data_subheader_pointers = []
    handler.current_row_in_file_index = 0
    handler.current_row_in_chunk_index = 0
    handler.current_row_on_page_index = 0
    _get_properties(handler)
    _parse_metadata(handler)
    return handler
end

"""
Open a SAS7BDAT data file.  The `config` parameter accepts the same 
settings as described in `SASLib.readsas()` function.  Returns a
handler object.
"""
function open(fname::AbstractString, config=Dict())
    return open(ReaderConfig(fname, config))
end

"""
Read data from the `handler`.  If `nrows` is not specified, read the
entire files content.  When called again, fetch the next `nrows` rows.
"""
function read(handler::Handler, nrows=0) 
    # @debug("Reading $(handler.config.filename)")
    return read_chunk(handler, nrows)
end

"""
Close the `handler` object.  This function effectively closes the
underlying iostream.  It must be called if `open` and `read` 
functions are used instead of the more convenient `readsas` function.
"""
function close(handler::Handler) 
    # @debug("Closing $(handler.config.filename)")
    Base.close(handler.io)
end

"""
Read a SAS7BDAT file.  Optional keyword parameters include:
* `:encoding`: character encoding for strings (default: "UTF-8")
* `:convert_text`: convert text data to strings (default: true)
* `:convert_header_text`: convert header text data to strings (default: true)
"""
function readsas(filename, config=Dict())
    handler = nothing
    try
        handler = open(ReaderConfig(filename, config))
        # @debug(push!(history, handler))
        t1 = time()
        df = read(handler)
        t2 = time()
        elapsed = round(t2 - t1, 3)
        info("Read data set of size $(size(df)) in $elapsed seconds")
        return SASData(df, handler)
    finally
        (handler != nothing) && close(handler)
    end
    return DataFrame()
end

# Read a single float of the given width (4 or 8).
function _read_float(handler, offset, width)
    if !(width in [4, 8])
        throw(ArgumentError("invalid float width $(width)"))
    end
    buf = _read_bytes(handler, offset, width)
    value = reinterpret(width == 4 ? Float32 : Float64, buf)[1]
    if (handler.byte_swap)
        value = bswap(value)
    end
    return value
end

# Read a single signed integer of the given width (1, 2, 4 or 8).
# TODO optimize
function _read_int(handler, offset, width)
    if !(width in [1, 2, 4, 8])
        throw(ArgumentError("invalid int width $(width)"))
    end
    buf = _read_bytes(handler, offset, width)
    value = reinterpret(Dict(1 => Int8, 2 => Int16, 4 => Int32, 8 => Int64)[width], buf)[1]
    if (handler.byte_swap)
        value = bswap(value)
    end
    return value
end

function _read_bytes(handler, offset, len)
    if handler.cached_page == []
        seek(handler.io, offset)
        try
            return Base.read(handler.io, len)
        catch
            throw(FileFormatError("Unable to read $(len) bytes from file position $(offset)"))
        end
    else
        if offset + len > length(handler.cached_page)
            throw(FileFormatError(
                "The cached page $(length(handler.cached_page)) is too small " *
                "to read for range positions $offset to $len"))
        end
        return handler.cached_page[offset+1:offset+len]  #offset is 0-based
    end
end

function _get_properties(handler)

    # read header section
    seekstart(handler.io)
    handler.cached_page = Base.read(handler.io, 288)

    # Check magic number
    if handler.cached_page[1:length(magic)] != magic
        throw(FileFormatError("magic number mismatch (not a SAS file?)"))
    end
    # @debug("good magic number")
    
    # Get alignment debugrmation
    align1, align2 = 0, 0
    buf = _read_bytes(handler, align_1_offset, align_1_length)
    if buf == u64_byte_checker_value
        align2 = align_2_value
        handler.U64 = true
        handler.int_length = 8
        handler.page_bit_offset = page_bit_offset_x64
        handler.subheader_pointer_length = subheader_pointer_length_x64
    else
        handler.U64 = false
        handler.int_length = 4
        handler.page_bit_offset = page_bit_offset_x86
        handler.subheader_pointer_length = subheader_pointer_length_x86
    end
    buf = _read_bytes(handler, align_2_offset, align_2_length)
    if buf == align_1_checker_value
        align1 = align_2_value
    end
    total_align = align1 + align2
    # @debug("successful reading alignment debugrmation")
    # @debug("buf = $buf, align1 = $align1, align2 = $align2, total_align=$total_align")

    # Get endianness information
    buf = _read_bytes(handler, endianness_offset, endianness_length)
    if buf == b"\x01"
        handler.file_endianness = :LittleEndian
    else
        handler.file_endianness = :BigEndian
    end
    # @debug("file_endianness = $(handler.file_endianness)")
    
    # Detect system-endianness and determine if byte swap will be required
    handler.sys_endianness = ENDIAN_BOM == 0x04030201 ? :LittleEndian : :BigEndian
    # @debug("system endianess = $(handler.sys_endianness)")

    handler.byte_swap = handler.sys_endianness != handler.file_endianness
    # @debug("byte_swap = $(handler.byte_swap)")
        
    # Get encoding information
    buf = _read_bytes(handler, encoding_offset, encoding_length)[1]
    if haskey(encoding_names, buf)
        handler.file_encoding = encoding_names[buf]
    else
        handler.file_encoding = "unknown (code=$buf)" 
    end
    # @debug("file_encoding = $(handler.file_encoding)")

    # Get platform information
    buf = _read_bytes(handler, platform_offset, platform_length)
    if buf == b"1"
        handler.platform = "unix"
    elseif buf == b"2"
        handler.platform = "windows"
    else
        handler.platform = "unknown"
    end
    # @debug("platform = $(handler.platform)")

    buf = _read_bytes(handler, dataset_offset, dataset_length)
    handler.name = brstrip(buf, zero_space)
    if handler.config.convert_header_text
        # @debug("before decode: name = $(handler.name)")
        handler.name = decode(handler.name, handler.config.encoding)
        # @debug("after decode:  name = $(handler.name)")
    end

    buf = _read_bytes(handler, file_type_offset, file_type_length)
    handler.file_type = brstrip(buf, zero_space)
    if handler.config.convert_header_text
        # @debug("before decode: file_type = $(handler.file_type)")
        handler.file_type = decode(handler.file_type, handler.config.encoding)
        # @debug("after decode:  file_type = $(handler.file_type)")
    end

    # Timestamp is epoch 01/01/1960
    epoch =DateTime(1960, 1, 1, 0, 0, 0)
    x = _read_float(handler, date_created_offset + align1, date_created_length)
    handler.date_created = epoch + Base.Dates.Millisecond(round(x * 1000))
    # @debug("date created = $(x) => $(handler.date_created)")
    x = _read_float(handler, date_modified_offset + align1, date_modified_length)
    handler.date_modified = epoch + Base.Dates.Millisecond(round(x * 1000))
    # @debug("date modified = $(x) => $(handler.date_modified)")
    
    handler.header_length = _read_int(handler, header_size_offset + align1, header_size_length)

    # Read the rest of the header into cached_page.
    buf = Base.read(handler.io, handler.header_length - 288)
    append!(handler.cached_page, buf)
    if length(handler.cached_page) != handler.header_length
        throw(FileFormatError("The SAS7BDAT file appears to be truncated."))
    end

    handler.page_length = _read_int(handler, page_size_offset + align1, page_size_length)
    # @debug("page_length = $(handler.page_length)")

    handler.page_count = _read_int(handler, page_count_offset + align1, page_count_length)
    # @debug("page_count = $(handler.page_count)")
    
    buf = _read_bytes(handler, sas_release_offset + total_align, sas_release_length)
    handler.sas_release = brstrip(buf, zero_space)
    if handler.config.convert_header_text
        handler.sas_release = decode(handler.sas_release, handler.config.encoding)
    end
    # @debug("SAS Release = $(handler.sas_release)")

    buf = _read_bytes(handler, sas_server_type_offset + total_align, sas_server_type_length)
    handler.server_type = brstrip(buf, zero_space)
    if handler.config.convert_header_text
        handler.server_type = decode(handler.server_type, handler.config.encoding)
    end
    # @debug("server_type = $(handler.server_type)")

    buf = _read_bytes(handler, os_version_number_offset + total_align, os_version_number_length)
    handler.os_version = brstrip(buf, zero_space)
    if handler.config.convert_header_text
        handler.os_version = decode(handler.os_version, handler.config.encoding)
    end
    # @debug("os_version = $(handler.os_version)")
    
    buf = _read_bytes(handler, os_name_offset + total_align, os_name_length)
    buf = brstrip(buf, zero_space)
    if length(buf) > 0
        handler.os_name = decode(buf, handler.config.encoding)
    else
        buf = _read_bytes(handler, os_maker_offset + total_align, os_maker_length)
        handler.os_name = brstrip(buf, zero_space)
        if handler.config.convert_header_text
            handler.os_name = decode(handler.os_name, handler.config.encoding)
        end
    end
    # @debug("os_name = $(handler.os_name)")
end

function _parse_metadata(handler)
    done = false
    while !done
        handler.cached_page = Base.read(handler.io, handler.page_length)
        if length(handler.cached_page) <= 0
            break
        end
        if length(handler.cached_page) != handler.page_length
            throw(FileFormatError("Failed to read a meta data page from the SAS file."))
        end
        done = _process_page_meta(handler)
    end
end

function _process_page_meta(handler)
    # @debug("IN: _process_page_meta")
    _read_page_header(handler)  
    pt = vcat([page_meta_type, page_amd_type], page_mix_types)
    # @debug("  pt=$pt handler.current_page_type=$(handler.current_page_type)")
    if handler.current_page_type in pt
        _process_page_metadata(handler)
    end
    # @debug("  condition var #1: handler.current_page_type=$(handler.current_page_type)")
    # @debug("  condition var #2: page_mix_types=$(page_mix_types)")
    # @debug("  condition var #3: handler.current_page_data_subheader_pointers=$(handler.current_page_data_subheader_pointers)")
    return ((handler.current_page_type in vcat([256], page_mix_types)) ||
            (handler.current_page_data_subheader_pointers != []))
end

function _read_page_header(handler)
    # @debug("IN: _read_page_header")
    bit_offset = handler.page_bit_offset
    tx = page_type_offset + bit_offset
    handler.current_page_type = _read_int(handler, tx, page_type_length)
    # @debug("  bit_offset=$bit_offset tx=$tx handler.current_page_type=$(handler.current_page_type)")
    tx = block_count_offset + bit_offset
    handler.current_page_block_count = _read_int(handler, tx, block_count_length)
    # @debug("  tx=$tx handler.current_page_block_count=$(handler.current_page_block_count)")
    tx = subheader_count_offset + bit_offset
    handler.current_page_subheaders_count = _read_int(handler, tx, subheader_count_length)
    # @debug("  tx=$tx handler.current_page_subheaders_count=$(handler.current_page_subheaders_count)")
end

function _process_page_metadata(handler)
    # @debug("IN: _process_page_metadata")
    bit_offset = handler.page_bit_offset
    # @debug("  bit_offset=$bit_offset")
    # @debug("  loop from 0 to $(handler.current_page_subheaders_count-1)")
    for i in 0:handler.current_page_subheaders_count-1
        pointer = _process_subheader_pointers(handler, subheader_pointers_offset + bit_offset, i)
        if pointer.length == 0
            continue
        end
        if pointer.compression == truncated_subheader_id
            continue
        end
        subheader_signature = _read_subheader_signature(handler, pointer.offset)
        subheader_index = (
            _get_subheader_index(handler, subheader_signature, pointer.compression, pointer.ptype, i))
        _process_subheader(handler, subheader_index, pointer)
    end
end

function _process_subheader_pointers(handler, offset, subheader_pointer_index)
    # @debug("IN: _process_subheader_pointers")
    # @debug("  offset=$offset")
    # @debug("  subheader_pointer_index=$subheader_pointer_index")
    
    total_offset = (offset + handler.subheader_pointer_length * subheader_pointer_index)
    # @debug("  handler.subheader_pointer_length=$(handler.subheader_pointer_length)")
    # @debug("  total_offset=$total_offset")
    
    subheader_offset = _read_int(handler, total_offset, handler.int_length)
    # @debug("  subheader_offset=$subheader_offset")
    total_offset += handler.int_length
    # @debug("  total_offset=$total_offset")
    
    subheader_length = _read_int(handler, total_offset, handler.int_length)
    # @debug("  subheader_length=$subheader_length")
    total_offset += handler.int_length
    # @debug("  total_offset=$total_offset")
    
    subheader_compression = _read_int(handler, total_offset, 1)
    # @debug("  subheader_compression=$subheader_compression")
    total_offset += 1
    # @debug("  total_offset=$total_offset")
    
    subheader_type = _read_int(handler, total_offset, 1)

    # @debug("  returning subheader_offset=$subheader_offset")
    # @debug("  returning subheader_length=$subheader_length")
    # @debug("  returning subheader_compression=$subheader_compression")
    # @debug("  returning subheader_type=$subheader_type")
    
    return subheader_pointer(
                subheader_offset, 
                subheader_length, 
                subheader_compression, 
                subheader_type)

end

function _read_subheader_signature(handler, offset)
    # @debug("IN: _read_subheader_signature (offset=$offset)")
    bytes = _read_bytes(handler, offset, handler.int_length)
    # @debug("  bytes=$(bytes)")
    return bytes
end

function _get_subheader_index(handler, signature, compression, ptype, idx)
    # @debug("IN: _get_subheader_index (idx=$idx)")
    # @debug("  signature=$signature")
    # @debug("  compression=$compression <-> compressed_subheader_id=$compressed_subheader_id")
    # @debug("  ptype=$ptype <-> compressed_subheader_type=$compressed_subheader_type")
    val = get(subheader_signature_to_index, signature, nothing)
    # @debug("  val=$val")
    if val == nothing
        f1 = ((compression == compressed_subheader_id) || (compression == 0))
        # @debug("  f1=$f1")
        f2 = (ptype == compressed_subheader_type)
        # @debug("  f2=$f2")
        if (handler.compression != b"") && f1 && f2
            val = index_dataSubheaderIndex
        else
            throw(FileFormatError("Unknown subheader signature $(signature)"))
        end
    end
    return val
end


function _process_subheader(handler, subheader_index, pointer)
    # @debug("IN: _process_subheader")
    offset = pointer.offset
    length = pointer.length
    # @debug("  offset=$offset")
    # @debug("  length=$length")    

    if subheader_index == index_rowSizeIndex
        processor = _process_rowsize_subheader
    elseif subheader_index == index_columnSizeIndex
        processor = _process_columnsize_subheader
    elseif subheader_index == index_columnTextIndex
        processor = _process_columntext_subheader
    elseif subheader_index == index_columnNameIndex
        processor = _process_columnname_subheader
    elseif subheader_index == index_columnAttributesIndex
        processor = _process_columnattributes_subheader
    elseif subheader_index == index_formatAndLabelIndex
        processor = _process_format_subheader
    elseif subheader_index == index_columnListIndex
        processor = _process_columnlist_subheader
    elseif subheader_index == index_subheaderCountsIndex
        processor = _process_subheader_counts
    elseif subheader_index == index_dataSubheaderIndex
        push!(handler.current_page_data_subheader_pointers, pointer)
        return
    else
        throw(FileFormatError("unknown subheader index"))
    end
    processor(handler, offset, length)
end

function _process_rowsize_subheader(handler, offset, length)
    # @debug("IN: _process_rowsize_subheader")
    int_len = handler.int_length
    lcs_offset = offset
    lcp_offset = offset
    if handler.U64
        lcs_offset += 682
        lcp_offset += 706
    else
        lcs_offset += 354
        lcp_offset += 378
    end
    handler.row_length = _read_int(handler,
        offset + row_length_offset_multiplier * int_len, int_len)
    handler.row_count = _read_int(handler,
        offset + row_count_offset_multiplier * int_len, int_len)
    handler.col_count_p1 = _read_int(handler,
        offset + col_count_p1_multiplier * int_len, int_len)
    handler.col_count_p2 = _read_int(handler,
        offset + col_count_p2_multiplier * int_len, int_len)
    mx = row_count_on_mix_page_offset_multiplier * int_len
    handler.mix_page_row_count = _read_int(handler, offset + mx, int_len)
    handler.lcs = _read_int(handler, lcs_offset, 2)
    handler.lcp = _read_int(handler, lcp_offset, 2)

    # @debug("  int_len=$int_len")
    # @debug("  lcs_offset=$lcs_offset")
    # @debug("  lcp_offset=$lcp_offset")
    # @debug("  handler.row_length=$(handler.row_length)")
    # @debug("  handler.row_count=$(handler.row_count)")
    # @debug("  handler.col_count_p1=$(handler.col_count_p1)")
    # @debug("  handler.col_count_p2=$(handler.col_count_p2)")
    # @debug("  mx=$mx")
    # @debug("  handler.mix_page_row_count=$(handler.mix_page_row_count)")
    # @debug("  handler.lcs=$(handler.lcs)")
    # @debug("  handler.lcp=$(handler.lcp)")
end

function _process_columnsize_subheader(handler, offset, length)
    # @debug("IN: _process_columnsize_subheader")
    int_len = handler.int_length
    offset += int_len
    handler.column_count = _read_int(handler, offset, int_len)
    if (handler.col_count_p1 + handler.col_count_p2 != handler.column_count)
        warn("Warning: column count mismatch ($(handler.col_count_p1) + $(handler.col_count_p2) != $(handler.column_count))")
    end
end

# Unknown purpose
function _process_subheader_counts(handler, offset, length)
    # @debug("IN: _process_subheader_counts")
end

function _process_columntext_subheader(handler, offset, length)
    # @debug("IN: _process_columntext_subheader")
    
    offset += handler.int_length
    text_block_size = _read_int(handler, offset, text_block_size_length)
    # @debug("  before reading buf: text_block_size=$text_block_size")
    # @debug("  before reading buf: offset=$offset")

    buf = _read_bytes(handler, offset, text_block_size)
    cname_raw = brstrip(buf[1:text_block_size], zero_space)
    # @debug("  cname_raw=$cname_raw")
    cname = cname_raw
    # TK: do not decode at this time.... do it after extracting by column
    # if handler.config.convert_header_text
    #     cname = decode(cname, handler.config.encoding)
    # end
    # @debug("  cname=$cname")
    push!(handler.column_names_strings, cname)

    # @debug("  handler.column_names_strings=$(handler.column_names_strings)")
    # @debug("  type=$(typeof(handler.column_names_strings))")
    # @debug("  content=$(handler.column_names_strings)")
    # @debug("  content=$(size(handler.column_names_strings))")

    if size(handler.column_names_strings, 2) == 1
        compression_literal = ""
        for cl in compression_literals
            if contains(cname_raw, cl)
                compression_literal = cl
            end
        end
        handler.compression = compression_literal
        offset -= handler.int_length
        # @debug("  handler.compression=$(handler.compression)")    
        
        offset1 = offset + 16
        if handler.U64
            offset1 += 4
        end

        buf = _read_bytes(handler, offset1, handler.lcp)
        compression_literal = brstrip(buf, b"\x00")
        if compression_literal == ""
            handler.lcs = 0
            offset1 = offset + 32
            if handler.U64
                offset1 += 4
            end
            buf = _read_bytes(handler, offset1, handler.lcp)
            handler.creator_proc = buf[1:handler.lcp]
        elseif compression_literal == rle_compression
            offset1 = offset + 40
            if handler.U64
                offset1 += 4
            end
            buf = _read_bytes(handler, offset1, handler.lcp)
            handler.creator_proc = buf[1:handler.lcp]
        elseif handler.lcs > 0
            handler.lcp = 0
            offset1 = offset + 16
            if handler.U64
                offset1 += 4
            end
            buf = _read_bytes(handler, offset1, handler.lcs)
            handler.creator_proc = buf[1:handler.lcp]
        else
            handler.creator_proc = nothing
        end
        if handler.config.convert_header_text
            if handler.creator_proc != nothing
                handler.creator_proc = decode(handler.creator_proc, handler.config.encoding)
            end
        end
    end
end
        

function _process_columnname_subheader(handler, offset, length)
    # @debug("IN: _process_columnname_subheader")
    int_len = handler.int_length
    # @debug(" int_len=$int_len")
    # @debug(" offset=$offset")    
    offset += int_len
    # @debug(" offset=$offset (after adding int_len)")
    column_name_pointers_count = fld(length - 2 * int_len - 12, 8)
    # @debug(" column_name_pointers_count=$column_name_pointers_count")
    for i in 1:column_name_pointers_count
        text_subheader = offset + column_name_pointer_length * 
            i + column_name_text_subheader_offset
        # @debug(" i=$i text_subheader=$text_subheader")
        col_name_offset = offset + column_name_pointer_length * 
            i + column_name_offset_offset
        # @debug(" i=$i col_name_offset=$col_name_offset")
        col_name_length = offset + column_name_pointer_length * 
            i + column_name_length_offset
        # @debug(" i=$i col_name_length=$col_name_length")
            
        idx = _read_int(handler,
            text_subheader, column_name_text_subheader_length)
        # @debug(" i=$i idx=$idx")
        col_offset = _read_int(handler,
            col_name_offset, column_name_offset_length)
        # @debug(" i=$i col_offset=$col_offset")
        col_len = _read_int(handler,
            col_name_length, column_name_length_length)
        # @debug(" i=$i col_len=$col_len")
            
        name_str = handler.column_names_strings[idx+1]
        # @debug(" i=$i name_str=$name_str")
        
        name = name_str[col_offset+1:col_offset + col_len]
        if handler.config.convert_header_text
            name = decode(name, handler.config.encoding)
        end
        push!(handler.column_names, name)
        # @debug(" i=$i name=$name")
    end
end

function _process_columnattributes_subheader(handler, offset, length)
    # @debug("IN: _process_columnattributes_subheader")
    int_len = handler.int_length
    column_attributes_vectors_count = fld(length - 2 * int_len - 12, int_len + 8)
    handler.column_types = fill(column_type_none, column_attributes_vectors_count)
    handler.column_data_lengths = fill(0::Int64, column_attributes_vectors_count)
    handler.column_data_offsets = fill(0::Int64, column_attributes_vectors_count)
    for i in 0:column_attributes_vectors_count-1
        col_data_offset = (offset + int_len +
                        column_data_offset_offset +
                        i * (int_len + 8))
        col_data_len = (offset + 2 * int_len +
                        column_data_length_offset +
                        i * (int_len + 8))
        col_types = (offset + 2 * int_len +
                    column_type_offset + i * (int_len + 8))

        x = _read_int(handler, col_data_offset, int_len)
        handler.column_data_offsets[i+1] = x

        x = _read_int(handler, col_data_len, column_data_length_length)
        handler.column_data_lengths[i+1] = x

        x = _read_int(handler, col_types, column_type_length)
        if x == 1
            handler.column_types[i+1] = column_type_decimal
        else
            handler.column_types[i+1] = column_type_string
        end
    end
end

function _process_columnlist_subheader(handler, offset, length)
    # @debug("IN: _process_columnlist_subheader")
    # unknown purpose
end

function _process_format_subheader(handler, offset, length)
    # @debug("IN: _process_format_subheader")
    int_len = handler.int_length
    text_subheader_format = (
        offset +
        column_format_text_subheader_index_offset +
        3 * int_len)
    col_format_offset = (offset +
                        column_format_offset_offset +
                        3 * int_len)
    col_format_len = (offset +
                    column_format_length_offset +
                    3 * int_len)
    text_subheader_label = (
        offset +
        column_label_text_subheader_index_offset +
        3 * int_len)
    col_label_offset = (offset +
                        column_label_offset_offset +
                        3 * int_len)
    col_label_len = offset + column_label_length_offset + 3 * int_len

    x = _read_int(handler, text_subheader_format,
                    column_format_text_subheader_index_length)
    # TODO length() didn't work => ERROR: MethodError: objects of type Int32 are not callable
    format_idx = min(x, size(handler.column_names_strings)[1] - 1)

    format_start = _read_int(handler, 
        col_format_offset, column_format_offset_length)
    format_len = _read_int(handler, 
        col_format_len, column_format_length_length)

    label_idx = _read_int(handler, 
        text_subheader_label,
        column_label_text_subheader_index_length)
    # TODO length() didn't work => ERROR: MethodError: objects of type Int32 are not callable
    label_idx = min(label_idx, size(handler.column_names_strings)[1] - 1)

    label_start = _read_int(handler, 
        col_label_offset, column_label_offset_length)
    label_len = _read_int(handler, col_label_len,
                            column_label_length_length)

    label_names = handler.column_names_strings[label_idx+1]
    column_label = label_names[label_start+1: label_start + label_len]
    format_names = handler.column_names_strings[format_idx+1]
    column_format = format_names[format_start+1: format_start + format_len]
    if handler.config.convert_header_text
        column_format = decode(column_format, handler.config.encoding)
    end
    current_column_number = size(handler.columns, 2) + 1

    col = Column(
        current_column_number,
        handler.column_names[current_column_number],
        column_label,
        column_format,
        handler.column_types[current_column_number],
        handler.column_data_lengths[current_column_number])

    push!(handler.column_formats, column_format)
    push!(handler.columns, col)
end

function read_chunk(handler, nrows=0)

    # @debug("IN: read_chunk")
    println(handler.config)
    if (nrows == 0) && (handler.config.chunksize > 0)
        nrows = handler.config.chunksize
    elseif nrows == 0
        nrows = handler.row_count
    end
    # @debug("nrows = $nrows")

    if !isdefined(handler, :column_types)
        warn("No columns to parse from file")
        return DataFrame()
    end
    # @debug("column_types = $(handler.column_types)")
    
    # @debug("current_row_in_file_index = $(handler.current_row_in_file_index)")    
    if handler.current_row_in_file_index >= handler.row_count
        return DataFrame()
    end

    # @debug("row_count = $(handler.row_count)")    
    m = handler.row_count - handler.current_row_in_file_index
    if nrows > m
        nrows = m
    end
    # @debug("nrows = $(nrows)")   
    #info("Reading $nrows x $(length(handler.column_types)) data set") 
    
    # TODO not the most efficient but normally it should be ok for non-wide tables
    nd = count(x -> x == column_type_decimal, handler.column_types)
    ns = count(x -> x == column_type_string,  handler.column_types)
    
    # @debug("nd = $nd (number of decimal columns)")
    # @debug("ns = $ns (number of string columns)")
    handler.string_chunk = fill("", (Int64(ns), Int64(nrows)))
    handler.byte_chunk = fill(UInt8(0), (Int64(nd), Int64(8 * nrows))) # 8-byte values

    handler.current_row_in_chunk_index = 0
    handler.current_page = 0
    
    tic()
    read_data(handler, nrows)
    perf_read_data = toq()

    tic()
    rslt = _chunk_to_dataframe(handler)
    perf_chunk_to_data_frame = toq()

    # summary
    @printf "INFO: Number of pages           = %7d\n" handler.current_page
    @printf "INFO: Page length               = %7d\n" handler.page_length
    @printf "INFO: Number of decimal columns = %7d\n" nd
    @printf "INFO: Number of string columns  = %7d\n" ns
    @printf "PERF: read_data                 = %7.3f seconds\n" perf_read_data
    @printf "PERF: _chunk_to_dataframe       = %7.3f seconds\n" perf_chunk_to_data_frame
    
    return rslt
end

function _read_next_page(handler)
    # @debug("IN: _read_next_page")
    handler.current_page += 1
    handler.current_page_data_subheader_pointers = []
    handler.cached_page = Base.read(handler.io, handler.page_length)
    if length(handler.cached_page) <= 0
        return true
    elseif length(handler.cached_page) != handler.page_length
        throw(FileFormatError("Failed to read complete page from file ($(length(handler.cached_page)) of $(handler.page_length) bytes"))
    end
    _read_page_header(handler)
    if handler.current_page_type == page_meta_type
        _process_page_metadata(handler)
    end
    # @debug("  page_meta_type=$page_meta_type")
    # @debug("  page_data_type=$page_data_type")
    # @debug("  page_mix_types=$page_mix_types")
    pt = [page_meta_type, page_data_type]
    append!(pt, page_mix_types)
    # @debug("  pt=$pt")
    if ! (handler.current_page_type in pt)
        println("page type not found $(handler.current_page_type)... reading next one")
        return _read_next_page(handler)
    end
    return false
end

function _chunk_to_dataframe(handler)
    # @debug("IN: _chunk_to_dataframe")
    
    n = handler.current_row_in_chunk_index
    m = handler.current_row_in_file_index
    #ix = range(m - n, m)
    #TODO rslt = pd.DataFrame(index=ix)
    rslt = DataFrame()

    origin = Date(1960, 1, 1)
    js, jb = 1, 1
    # @debug("handler.column_names=$(handler.column_names)")
    for j in 1:handler.column_count

        name = Symbol(handler.column_names[j])

        if handler.column_types[j] == column_type_decimal  # number, date, or datetime
            # @debug("  String: size=$(size(handler.byte_chunk))")
            # @debug("  Decimal: column $j, name $name, size=$(size(handler.byte_chunk[jb, :]))")
            bytes = handler.byte_chunk[jb, :]
            #if j == 1  && length(bytes) < 100  #debug only
                # @debug("  bytes=$bytes")
            #end
            #values = convertfloat64a(bytes, handler.byte_swap)
            values = convertfloat64b(bytes, handler.file_endianness)
            #println(length(bytes))
            #rslt[name] = bswap(rslt[name])
            rslt[name] = values
            if handler.config.convert_dates
                if handler.column_formats[j] in sas_date_formats
                    # TODO had to convert to Array... refactor?
                    rslt[name] = origin + Dates.Day.(Array(round.(Integer, rslt[name])))
                elseif handler.column_formats[j] in sas_datetime_formats
                    # TODO probably have to deal with timezone somehow
                    rslt[name] = DateTime(origin) + Dates.Second.(Array(round.(Integer, rslt[name])))
                end
            end
            jb += 1
        elseif handler.column_types[j] == column_type_string
            # @debug("  String: size=$(size(handler.string_chunk))")
            # @debug("  String: column $j, name $name, size=$(size(handler.string_chunk[js, :]))")
            rslt[name] = handler.string_chunk[js, :]
            # TODO don't we always want to convert?  seems unnecessary.
            # if handler.config.convert_text 
            #     rslt[name] = decode.(rslt[name], handler.config.encoding)
            #     #rslt[name] = map(x -> decode(x, handler.config.encoding), rslt[name])
            # end
            # TODO need to convert "" to missing?
            # if handler.config.blank_missing
            #     ii = length(rslt[name]) == 0
            #     rslt.loc[ii, name] = np.nan  #TODO what is this?
            # end
            js += 1
        else
            throw(FileFormatError("Unknown column type $(handler.column_types[j])"))
        end
        #if length(rslt[name]) < 100  #don't kill the screen with too much data
            # @debug("  rslt[name] = $(rslt[name])")
        #end
    end
    return rslt
end

# from sas.pyx 
function read_data(handler, nrows)
    # @debug("IN: read_data, nrows=$nrows")
    for i in 1:nrows
        done = readline(handler)
        if done
            break
        end
    end
end

# consider renaming this function to avoid confusion
function read_next_page(handler)
    done = _read_next_page(handler)
    if done
        handler.cached_page = []
    else
        update_next_page(handler)
    end
    return done
end

function update_next_page(handler)
    handler.current_row_on_page_index = 0
end

# Return `true` when there is nothing else to read
function readline(handler)
    # @debug("IN: readline")

    subheader_pointer_length = handler.subheader_pointer_length
    
    # If there is no page, go to the end of the header and read a page.
    # TODO commented out for performance reasons... do we really need this?
    # if handler.cached_page == []
    #     @debug("  no cached page... seeking past header")
    #     seek(handler.io, handler.header_length)
    #     @debug("  reading next page")
    #     done = read_next_page(handler)
    #     if done
    #         @debug("  no page! returning")
    #         return true
    #     end
    # end

    # Loop until a data row is read
    # @debug("  start loop")
    while true
        if handler.current_page_type == page_meta_type
            #println("    page type == page_meta_type")
            flag = handler.current_row_on_page_index >= length(handler.current_page_data_subheader_pointers)
            if flag
                # @debug("    reading next page")
                done = read_next_page(handler)
                if done
                    # @debug("    all done, returning #1")
                    return true
                end
                continue
            end
            current_subheader_pointer = 
                handler.current_page_data_subheader_pointers[handler.current_row_on_page_index+1]
                # @debug("    current_subheader_pointer = $(current_subheader_pointer)")
                process_byte_array_with_data(handler,
                    current_subheader_pointer.offset,
                    current_subheader_pointer.length)
            return false
        elseif (handler.current_page_type == page_mix_types[1] ||
                handler.current_page_type == page_mix_types[2])
            #println("    page type == page_mix_types_1/2")
            align_correction = (handler.page_bit_offset + subheader_pointers_offset +
                                handler.current_page_subheaders_count *
                                subheader_pointer_length)
            # @debug("    align_correction = $align_correction")
            align_correction = align_correction % 8
            # @debug("    align_correction = $align_correction")
            offset = handler.page_bit_offset + align_correction
            # @debug("    offset = $offset")
            offset += subheader_pointers_offset
            # @debug("    offset = $offset")
            offset += (handler.current_page_subheaders_count *
                    subheader_pointer_length)
            # @debug("    offset = $offset")
            # @debug("    handler.current_row_on_page_index = $(handler.current_row_on_page_index)")
            # @debug("    handler.row_length = $(handler.row_length)")
            offset += handler.current_row_on_page_index * handler.row_length
            # @debug("    offset = $offset")
            process_byte_array_with_data(handler, offset, handler.row_length)
            mn = min(handler.row_count, handler.mix_page_row_count)
            # @debug("    handler.current_row_on_page_index=$(handler.current_row_on_page_index)")
            # @debug("    mn = $mn")
            if handler.current_row_on_page_index == mn
                # @debug("    reading next page")
                done = read_next_page(handler)
                if done
                    # @debug("    all done, returning #2")
                    return true
                end
            end
            return false
        elseif handler.current_page_type == page_data_type
            #println("    page type == page_data_type")
            process_byte_array_with_data(handler,
                handler.page_bit_offset + subheader_pointers_offset +
                handler.current_row_on_page_index * handler.row_length,
                handler.row_length)
            # @debug("    handler.current_row_on_page_index=$(handler.current_row_on_page_index)")
            # @debug("    handler.current_page_block_count=$(handler.current_page_block_count)")
            flag = (handler.current_row_on_page_index == handler.current_page_block_count)
            #println("$(handler.current_row_on_page_index) $(handler.current_page_block_count)")
            if flag
                # @debug("    reading next page")
                done = read_next_page(handler)
                if done
                    # @debug("    all done, returning #3")
                    return true
                end
            end
            return false
        else
            throw(FileFormatError("unknown page type: $(handler.current_page_type)"))
        end
    end
end

function process_byte_array_with_data(handler, offset, length)

    # @debug("IN: process_byte_array_with_data, offset=$offset, length=$length")

    # Original code below.  Julia type is already Vector{UInt8}
    # source = np.frombuffer(
    #     handler.cached_page[offset:offset + length], dtype=np.uint8)
    source = handler.cached_page[offset+1:offset+length]

    # TODO decompression 
    # if handler.decompress != NULL and (length < handler.row_length)
    # @debug("  length=$length")
    # @debug("  handler.row_length=$(handler.row_length)")
    if length < handler.row_length
        if handler.compression == rle_compression
            println("decompress using rle_compression method, length=$length, row_length=$(handler.row_length)")
            source = rle_decompress(handler.row_length, source)
        elseif handler.compression == rdc_compression
            println("decompress using rdc_compression method, length=$length, row_length=$(handler.row_length)")
            source = rdc_decompress(handler.row_length, source)
        else
            throw(FileFormatError("Unknown compression method: $(handler.compression)"))
        end
    end

    current_row = handler.current_row_in_chunk_index
    column_types = handler.column_types
    lengths = handler.column_data_lengths
    offsets = handler.column_data_offsets
    byte_chunk = handler.byte_chunk
    string_chunk = handler.string_chunk
    s = 8 * current_row
    js = 1
    jb = 1

    # if current_row == 1
    #     println("  current_row = $current_row")
    #     println("  column_types = $column_types")
    #     println("  lengths = $lengths")
    #     println("  offsets = $offsets")
    # end
    # @debug("  s = $s")
    # @debug("  handler.file_endianness = $(handler.file_endianness)")
        
    for j in 1:handler.column_count
        lngt = lengths[j]
        # TODO commented out for perf reason. do we need this?
        # if lngt == 0
        #     break
        # end
        #if j == 1
            # @debug("  lngt = $lngt")
        #end
        #println(lngt)
        start = offsets[j]
        ct = column_types[j]
        if ct == column_type_decimal
            # The data may have 3,4,5,6,7, or 8 bytes (lngt)
            # and we need to copy into an 8-byte destination.
            # Hence endianness matters - for Little Endian file
            # copy it to the right side, else left side.
            if handler.file_endianness == :LittleEndian
                m = s + 8 - lngt
            else
                m = s
            end
            # for k in 1:lngt
            #     byte_chunk[jb, m + k] = source[start + k]
            # end
            @inbounds byte_chunk[jb, m+1:m+lngt] = source[start+1:start+lngt]
            jb += 1
        elseif ct == column_type_string
            @inbounds string_chunk[js, current_row+1] = strip(decode(source[start + 1:(
                start + lngt)], handler.config.encoding), ' ')
            js += 1
        end
    end

    handler.current_row_on_page_index += 1
    handler.current_row_in_chunk_index += 1
    handler.current_row_in_file_index += 1
end

# rle_decompress decompresses data using a Run Length Encoding
# algorithm.  It is partially documented here:
#
# https://cran.r-project.org/web/packages/sas7bdat/vignettes/sas7bdat.pdf
function rle_decompress(result_length,  inbuff::Vector{UInt8})

    #control_byte::UInt8
    #x::UInt8
    result = zeros(UInt8, result_length)
    rpos = 1
    ipos = 1
    len = length(inbuff)
    #i, nbytes, end_of_first_byte

    while ipos < len
        control_byte = inbuff[ipos] & 0xF0
        end_of_first_byte = inbuff[ipos] & 0x0F
        ipos += 1

        if control_byte == 0x00
            if end_of_first_byte != 0
                throw(FileFormatError("Unexpected non-zero end_of_first_byte"))
            end
            nbytes = inbuff[ipos] + 64
            ipos += 1
            for i in 1:nbytes
                result[rpos] = inbuff[ipos]
                rpos += 1
                ipos += 1
            end
        elseif control_byte == 0x40
            # not documented
            nbytes = end_of_first_byte * 16
            nbytes += inbuff[ipos]
            ipos += 1
            for i in 1:nbytes
                result[rpos] = inbuff[ipos]
                rpos += 1
            end
            ipos += 1
        elseif control_byte == 0x60
            nbytes = end_of_first_byte * 256 + inbuff[ipos] + 17
            ipos += 1
            for i in 1:nbytes
                result[rpos] = 0x20
                rpos += 1
            end
        elseif control_byte == 0x70
            nbytes = end_of_first_byte * 256 + inbuff[ipos] + 17
            ipos += 1
            for i in 1:nbytes
                result[rpos] = 0x00
                rpos += 1
            end
        elseif control_byte == 0x80
            nbytes = end_of_first_byte + 1
            for i in 1:nbytes
                result[rpos] = inbuff[ipos + i - 1]
                rpos += 1
            end
            ipos += nbytes
        elseif control_byte == 0x90
            nbytes = end_of_first_byte + 17
            for i in 1:nbytes
                result[rpos] = inbuff[ipos + i - 1]
                rpos += 1
            end
            ipos += nbytes
        elseif control_byte == 0xA0
            nbytes = end_of_first_byte + 33
            for i in 1:nbytes
                result[rpos] = inbuff[ipos + i - 1]
                rpos += 1
            end
            ipos += nbytes
        elseif control_byte == 0xB0
            nbytes = end_of_first_byte + 49
            for i in 1:nbytes
                result[rpos] = inbuff[ipos + i - 1]
                rpos += 1
            end
            ipos += nbytes
        elseif control_byte == 0xC0
            nbytes = end_of_first_byte + 3
            x = inbuff[ipos]
            ipos += 1
            for i in 1:nbytes
                result[rpos] = x
                rpos += 1
            end
        elseif control_byte == 0xD0
            nbytes = end_of_first_byte + 2
            for i in 1:nbytes
                result[rpos] = 0x40
                rpos += 1
            end
        elseif control_byte == 0xE0
            nbytes = end_of_first_byte + 2
            for i in 1:nbytes
                result[rpos] = 0x20
                rpos += 1
            end
        elseif control_byte == 0xF0
            nbytes = end_of_first_byte + 2
            for i in 1:nbytes
                result[rpos] = 0x00
                rpos += 1
            end
        else
            throw(FileFormatError("unknown control byte: $control_byte"))
        end
    end

    if length(result) != result_length
        throw(FileFormatError("RLE: $(length(result)) != $result_length"))
    end

    return result
end


# rdc_decompress decompresses data using the Ross Data Compression algorithm:
#
# http://collaboration.cmc.ec.gc.ca/science/rpn/biblio/ddj/Website/articles/CUJ/1992/9210/ross/ross.htm
function rdc_decompress(result_length, inbuff::Vector{UInt8})

    #uint8_t cmd
    #uint16_t ctrl_bits, ofs, cnt
    ctrl_mask = UInt16(0)
    ipos = 1
    rpos = 1
    #k
    #uint8_t [:] outbuff = np.zeros(result_length, dtype=np.uint8)
    outbuff = zeros(UInt8, result_length)

    while ipos <= length(inbuff)

        ctrl_mask = ctrl_mask >> 1
        if ctrl_mask == 0
            ctrl_bits = (UInt16(inbuff[ipos]) << 8) + UInt16(inbuff[ipos + 1])
            ipos += 2
            ctrl_mask = 0x8000
        end

        if ctrl_bits & ctrl_mask == 0
            outbuff[rpos] = inbuff[ipos]
            ipos += 1
            rpos += 1
            continue
        end

        cmd = (inbuff[ipos] >> 4) & 0x0F
        cnt = UInt16(inbuff[ipos] & 0x0F)
        ipos += 1

        # short RLE
        if cmd == 0
            cnt += 3
            for k in 0:cnt-1
                outbuff[rpos + k] = inbuff[ipos]
            end
            rpos += cnt
            ipos += 1

        # long RLE
        elseif cmd == 1
            cnt += UInt16(inbuff[ipos]) << 4
            cnt += 19
            ipos += 1
            for k in 0:cnt-1
                outbuff[rpos + k] = inbuff[ipos]
            end
            rpos += cnt
            ipos += 1

        # long pattern
        elseif cmd == 2
            ofs = cnt + 3
            ofs += UInt16(inbuff[ipos]) << 4
            ipos += 1
            cnt = UInt16(inbuff[ipos])
            ipos += 1
            cnt += 16
            for k in 0:cnt-1
                outbuff[rpos + k] = outbuff[rpos - ofs + k]
            end
            rpos += cnt

        # short pattern
        elseif (cmd >= 3) & (cmd <= 15)
            ofs = cnt + 3
            ofs += UInt16(inbuff[ipos]) << 4
            ipos += 1
            for k in 0:cmd-1
                outbuff[rpos + k] = outbuff[rpos - ofs + k]
            end
            rpos += cmd

        else
            throw(FileFormatError("unknown RDC command"))
        end
    end

    if length(outbuff) != result_length
        throw(FileFormatError("RDC: $(length(outbuff)) != $result_length"))
    end

    return outbuff
end

end # module
