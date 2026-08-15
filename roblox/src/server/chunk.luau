--!strict

local etc = require(script.Parent.etc)
local function reject(logger: etc.Logger, message: string, ...: any): nil
	logger.sprint(etc.LogLevel.error, message, ...)
	return nil
end
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

function chunk.dechunk(data: string, logger: etc.Logger): string?
	if #data == 0 or #data % FRAME_SIZE ~= 0 then
		return reject(logger, "payload is not a whole number of frames, %* bytes", #data)
	end

	local frames = {}
	for i = 1, #data, FRAME_SIZE do
		table.insert(frames, string.sub(data, i, i + FRAME_SIZE - 1))
	end

	local sourceTotal: number? = nil
	local sourceCrc: number? = nil
	local sorted = table.create(#frames)

	for position, frame in frames do
		local index, total, crc = chunk._verifylen(frame)
		if index < 0 then
			return reject(logger, "malformed header on frame %*", position)
		end
		if sourceTotal == nil then
			sourceTotal = total
			sourceCrc = crc
		elseif total ~= sourceTotal then
			return reject(logger, "total mismatch, %* != %*", sourceTotal, total)
		elseif crc ~= sourceCrc then
			return reject(logger, "crc mismatch, %* != %*", sourceCrc, crc)
		end
		if sorted[index] ~= nil then
			return reject(logger, "duplicate frame at index %*", index)
		end
		sorted[index] = chunk._extractData(frame)
	end

	if #frames ~= sourceTotal then
		return reject(logger, "expected %* frames, got %*", sourceTotal, #frames)
	end

	local ordered = table.create(#frames)
	for index = 0, (sourceTotal :: number) - 1 do
		local payload = sorted[index]
		if payload == nil then
			return reject(logger, "missing frame at index %*", index)
		end
		table.insert(ordered, payload)
	end
	local recomposition = table.concat(ordered)
	local checksum = chunk._crc32(recomposition)
	if checksum ~= sourceCrc then
		return reject(logger, "checksum mismatch, %* != %*", sourceCrc, checksum)
	end
	return recomposition
end

return chunk
