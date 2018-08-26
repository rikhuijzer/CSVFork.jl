function skiptoheader!(parsinglayers, io, row, header)
    while row < header
        while !eof(io)
            r = Parsers.parse(parsinglayers, io, Tuple{Ptr{UInt8}, Int})
            (r.code & Parsers.DELIMITED) > 0 && break
        end
        row += 1
    end
    return row
end

function countfields(io, parsinglayers)
    rows = 0
    result = Parsers.Result(Tuple{Ptr{UInt8}, Int})
    while !eof(io)
        Parsers.parse!(parsinglayers, io, result)
        Parsers.ok(result.code) || throw(Error(result, rows+1, 1))
        rows += 1
        xor(result.code & DELIM_NEWLINE, Parsers.DELIMITED) == 0 && continue
        ((result.code & Parsers.NEWLINE) > 0 || eof(io)) && break
    end
    return rows
end

function datalayout_transpose(header, parsinglayers, io, datarow, footerskip)
    if isa(header, Integer) && header > 0
        # skip to header column to read column names
        row = skiptoheader!(parsinglayers, io, 1, header)
        # io now at start of 1st header cell
        columnnames = [Symbol(strip(Parsers.parse(parsinglayers, io, String).result::String))]
        columnpositions = [position(io)]
        datapos = position(io)
        rows = countfields(io, parsinglayers)
        
        # we're now done w/ column 1, if EOF we're done, otherwise, parse column 2's column name
        cols = 1
        while !eof(io)
            # skip to header column to read column names
            row = skiptoheader!(parsinglayers, io, 1, header)
            cols += 1
            push!(columnnames, Symbol(strip(Parsers.parse(parsinglayers, io, String).result::String)))
            push!(columnpositions, position(io))
            readline!(parsinglayers, io)
        end
        seek(io, datapos)
    elseif isa(header, AbstractRange)
        # column names span several columns
        throw(ArgumentError("not implemented for transposed csv files"))
    elseif eof(io)
        # emtpy file, use column names if provided
        datapos = position(io)
        columnpositions = Int[]
        columnnames = [Symbol(x) for x in header]
    else
        # column names provided explicitly or should be generated, they don't exist in data
        # skip to datarow
        row = skiptoheader!(parsinglayers, io, 1, datarow)
        # io now at start of 1st data cell
        columnnames = [isa(header, Integer) || isempty(header) ? :Column1 : Symbol(header[1])]
        columnpositions = [position(io)]
        datapos = position(io)
        rows = countfields(io, parsinglayers)
        # we're now done w/ column 1, if EOF we're done, otherwise, parse column 2's column name
        cols = 1
        while !eof(io)
            # skip to datarow column
            row = skiptoheader!(parsinglayers, io, 1, datarow)
            cols += 1
            push!(columnnames, isa(header, Integer) || isempty(header) ? Symbol("Column$cols") : Symbol(header[cols]))
            push!(columnpositions, position(io))
            readline!(parsinglayers, io)
        end
        seek(io, datapos)
    end
    rows = rows - footerskip # rows now equals the actual number of rows in the dataset
    return rows, Tuple(columnnames), columnpositions
end

function datalayout(header::Integer, parsinglayers, io, datarow)
    # default header = 1
    if header <= 0
        # no header row in dataset; skip to data to figure out # of columns
        skipto!(parsinglayers, io, 1, datarow)
        datapos = position(io)
        row_vals = readsplitline(parsinglayers, io)
        seek(io, datapos)
        columnnames = Tuple(Symbol("Column$i") for i = eachindex(row_vals))
    else
        skipto!(parsinglayers, io, 1, header)
        columnnames = Tuple(ismissing(x) ? Symbol("Column$i") : Symbol(strip(x)) for (i, x) in enumerate(readsplitline(parsinglayers, io)))
        datarow != header+1 && skipto!(parsinglayers, io, header+1, datarow)
        datapos = position(io)
    end
    return columnnames, datapos
end

function datalayout(header::AbstractRange, parsinglayers, io, datarow)
    skipto!(parsinglayers, io, 1, first(header))
    columnnames = [x for x in readsplitline(parsinglayers, io)]
    for row = first(header):(last(header)-1)
        for (i,c) in enumerate([x for x in readsplitline(parsinglayers, io)])
            columnnames[i] *= "_" * c
        end
    end
    datarow != last(header)+1 && skipto!(parsinglayers, io, last(header)+1, datarow)
    datapos = position(io)
    return Tuple(Symbol(nm) for nm in columnnames), datapos
end

function datalayout(header::Vector, parsinglayers, io, datarow)
    skipto!(parsinglayers, io, 1, datarow)
    datapos = position(io)
    if eof(io)
        columnnames = Tuple(Symbol(nm) for nm in header)
    else
        row_vals = readsplitline(parsinglayers, io)
        seek(io, datapos)
        if isempty(header)
            columnnames = Tuple(Symbol("Column$i") for i in eachindex(row_vals))
        else
            length(header) == length(row_vals) || throw(ArgumentError("The length of provided header ($(length(header))) doesn't match the number of columns at row $datarow ($(length(row_vals)))"))
            columnnames = Tuple(Symbol(nm) for nm in header)
        end
    end
    return columnnames, datapos
end

const READLINE_RESULT = Parsers.Result(Tuple{Ptr{UInt8}, Int})
# readline! is used for implementation of skipto!
function readline!(layers, io::IO)
    eof(io) && return
    while true
        READLINE_RESULT.code = Parsers.SUCCESS
        res = Parsers.parse!(layers, io, READLINE_RESULT)
        Parsers.ok(res.code) || throw(Parsers.Error(res))
        ((res.code & Parsers.NEWLINE) > 0 || eof(io)) && break
    end
    return
end

function skipto!(layers, io::IO, cur, dest)
    cur >= dest && return
    for _ = 1:(dest-cur)
        readline!(layers, io)
    end
    return
end

#TODO: read Symbols directly
const COMMA_NEWLINES = Parsers.Trie([",", "\n", "\r", "\r\n"], Parsers.DELIMITED)
const READSPLITLINE_RESULT = Parsers.Result(String)
const DELIM_NEWLINE = Parsers.DELIMITED | Parsers.NEWLINE

readsplitline(io::IO) = readsplitline(Parsers.Delimited(Parsers.Quoted(), COMMA_NEWLINES), io)
function readsplitline(layers::Parsers.Delimited, io::IO)
    vals = Union{String, Missing}[]
    eof(io) && return vals
    col = 1
    result = READSPLITLINE_RESULT
    while true
        result.code = Parsers.SUCCESS
        Parsers.parse!(layers, io, result)
        # @debug "readsplitline!: result=$result"
        Parsers.ok(result.code) || throw(Error(Parsers.Error(io, result), 1, col))
        # @show result
        push!(vals, result.result)
        col += 1
        xor(result.code & DELIM_NEWLINE, Parsers.DELIMITED) == 0 && continue
        ((result.code & Parsers.NEWLINE) > 0 || eof(io)) && break
    end
    return vals
end

function rowpositions(io::IO, q::UInt8, e::UInt8)
    nl = Int64[position(io)] # we always start at the beginning of the first data row
    b = 0x00
    while !eof(io)
        b = Parsers.readbyte(io)
        if b === q
            while !eof(io)
                b = Parsers.readbyte(io)
                if b === e
                    if eof(io)
                        break
                    elseif e === q && Parsers.peekbyte(io) !== q
                        break
                    end
                    b = Parsers.readbyte(io)
                elseif b === q
                    break
                end
            end
        elseif b === UInt8('\n')
            !eof(io) && push!(nl, position(io))
        elseif b === UInt8('\r')
            !eof(io) && Parsers.peekbyte(io) === UInt8('\n') && Parsers.readbyte(io)
            !eof(io) && push!(nl, position(io))
        end
    end
    return nl
end
