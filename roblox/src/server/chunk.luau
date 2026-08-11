--!strict

const logging = require(script.Parent.logging)
--[[
current packet structure
II is the current index
| NN is the number of chunks
| | CCCCCCCC is the CRC32
IINNCCCCCCCC...

uniformity!

operating at a max size of 258060bytes/message
(assuming all 256)

II is zero based, so a valid frame has index < total.
NN and II are two hex digits, so total tops out at 255.

TODO: the frame carries no payload length, so a padded final chunk cannot be
distinguished from real trailing bytes -- both sides checksum the padding
identically, so the CRC will not catch it. Decide with the backend whether to
pad or to add a length field before this leaves draft.
]]

const HEADER_SIZE = 12
const FRAME_SIZE = 1024

const POLYNOMIAL = 0xEDB88320
const INITIAL = 0xFFFFFFFF

const chunk = {}

const REMAINDERS: { [number]: number } = {}
for byte = 0, 255 do
    local remainder = byte
    for _ = 1, 8 do
        if bit32.band(remainder, 1) == 1 then
            remainder = bit32.bxor(bit32.rshift(remainder, 1), POLYNOMIAL)
        else
            remainder = bit32.rshift(remainder, 1)
        end
    end
    REMAINDERS[byte] = remainder
end

function chunk._crc32(data: string): number
    local remainder = INITIAL
    for index = 1, #data do
        const byte = string.byte(data, index) :: number
        remainder = bit32.bxor(
            bit32.rshift(remainder, 8),
            REMAINDERS[bit32.band(bit32.bxor(remainder, byte), 0xFF)]
        )
    end
    return bit32.bxor(remainder, INITIAL)
end

function chunk._verifylen(data: string): (number, number, number)
    if #data ~= FRAME_SIZE then
        return -1, -1, -1
    end
    const index = tonumber(string.sub(data, 1, 2), 16)
    const total = tonumber(string.sub(data, 3, 4), 16)
    const crc = tonumber(string.sub(data, 5, HEADER_SIZE), 16)
    if index == nil or total == nil or crc == nil then
        return -1, -1, -1
    end
    if total == 0 or index >= total then
        return -1, -1, -1
    end
    return index, total, crc
end

function chunk._extractData(data: string): string
    return string.sub(data, HEADER_SIZE + 1, FRAME_SIZE)
end

function chunk.dechunk(data: string): string?
    if #data == 0 or #data % FRAME_SIZE ~= 0 then
        logging.log(logging.Error, string.format("payload is not a whole number of frames, %* bytes", #data))
        return nil
    end

    const frames = {}
    for i = 1, #data, FRAME_SIZE do
        table.insert(frames, string.sub(data, i, i + FRAME_SIZE - 1))
    end

    local sourceTotal: number? = nil
    local sourceCrc: number? = nil
    const sorted = table.create(#frames)

    for position, frame in frames do
        const index, total, crc = chunk._verifylen(frame)
        if index < 0 then
            logging.log(logging.Error, string.format("malformed header on frame %*", position))
            return nil
        end
        if sourceTotal == nil then
            sourceTotal = total
            sourceCrc = crc
        elseif total ~= sourceTotal then
            logging.log(logging.Error, string.format("total mismatch, %* != %*", sourceTotal, total))
            return nil
        elseif crc ~= sourceCrc then
            logging.log(logging.Error, string.format("crc mismatch, %* != %*", sourceCrc, crc))
            return nil
        end
        if sorted[index] ~= nil then
            logging.log(logging.Error, string.format("duplicate frame at index %*", index))
            return nil
        end
        sorted[index] = chunk._extractData(frame)
    end

    if #frames ~= sourceTotal then
        logging.log(logging.Error, string.format("expected %* frames, got %*", sourceTotal, #frames))
        return nil
    end

    const ordered = table.create(#frames)
    for index = 0, (sourceTotal :: number) - 1 do
        const payload = sorted[index]
        if payload == nil then
            logging.log(logging.Error, string.format("missing frame at index %*", index))
            return nil
        end
        table.insert(ordered, payload)
    end
    const recomposition = table.concat(ordered)
    const checksum = chunk._crc32(recomposition)
    if checksum ~= sourceCrc then
        logging.log(logging.Error, string.format("checksum mismatch, %* != %*", sourceCrc, checksum))
        return nil
    end
    return recomposition
end

return chunk
