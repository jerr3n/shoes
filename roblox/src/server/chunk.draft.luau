local logging = require(script.Parent.logging)
--[[
current packet structure
II is the current index
| NN is the number of chunks
| | CCCCCCCC is the CRC32
IINNCCCCCCCC...

uniformity!

operating at a max size of 258060bytes/message
(assuming all 256)
]]

local chunk = {}

-- the gist of it is that if theres a negative something went wrong
function chunk._verifylen(data: string): (number, number)
    if #data ~= 1024 then
        return -1, -1
    end
    local index = string.sub(data, 1, 2)
    local total = string.sub(data, 3, 4)
    local crc = string.sub(data, 5, 13)
    if index > total then
        return 0-tonumber(total, 16), tonumber(crc, 16) -- TRUST me thats a number
    end
    return tonumber(total, 16), tonumber(crc, 16)
end

function chunk._extractData(data: string)
    return 
end

function chunk.dechunk(data: string): string?
    local chunks = {}
    for i = 1, #data, 1024 do
        local chunk = string.sub(data, i, i + 1024 - 1)
        table.insert(chunks, chunk)
    end
    local sourceTotal, sourceCrc = nil
    local exit = false
    for index, v in chunks do
        local total, crc = chunk._verifylen(v)
        if  index == 1 then
            sourceTotal = total
            sourceCrc = crc
        else
            if total ~= sourceTotal then
                logging.log(logging.Error, string.format("total mismatch, %* != %*", sourceTotal, total))
                exit = true
            end
            if sourceCrc ~= crc then
                logging.log(logging.Error, string.format("crc mismatch, %* != %*", sourceCrc, crc))
                exit = true
            end
            if exit then
                return
            end
        end
    end
    local sum = sourceCrc
    local sorted = table.create(256)
    for _, v in chunks do
        local position = tonumber(string.sub(v, 1, 2), 16)
        sorted[position] = string.sub(v, 13, 1024)
    end
    local recomposition = "" 
    for _, v in sorted do
        recomposition += v
    end
    local raw = buffer.fromstring(recomposition)
    local poly = 0xEDB88320
    local crc = 0xFFFFFFFF
    for i = 1, buffer.len(raw) - 1 do
        crc = bit32.bxor(crc, buffer.readu8(raw, i))
        for _ = 1, 8 do
            if bit32.band(crc, 1) == 1 then
                crc = bit32.bxor(bit32.rshift(crc, 1), poly)
            else
                crc = bit32.rshift(crc, 1)
            end
        end
    end
    local crc32 = bit32.bxor(crc, 0xFFFFFFFF)
    if sourceCrc == crc32 then
        return recomposition
    end
end

return chunk