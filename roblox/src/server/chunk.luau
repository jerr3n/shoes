--!strict

local etc = require(script.Parent.etc)
local function reject(logger: etc.Logger, message: string, ...: any): nil
	logger.sprint(etc.LogLevel.Error, message, ...)
	return nil
end
--[[
Frames arrive one per MessagingService message, so in arbitrary order, and are
variable length -- the Go side backs off to a rune boundary when splitting and
the final frame is short. Every frame is valid UTF-8, because it crosses a JSON
boundary on the way here (see the flagSlotLimit comment in backend/util/header.go).

Byte offsets below are 1-based, for string.byte / string.sub.

first frame (12 byte header)
| 1-4  | message id  | 4 random bytes, valid utf-8, same on every frame
| 5-9  | crc32       | 4-byte big-endian crc-32, base128'd to 5 bytes
| 10-11| count rune  | 2-byte utf-8 rune, value 0x80 + total
| 12   | flags       | bit 0 = base128, bit 1 = compressed
| 13+  | payload     |

every other frame (6 byte header)
| 1-4  | message id  |
| 5-6  | index rune  | 2-byte utf-8 rune, value 0x80 + index, index 2..total
| 7+   | payload     |

Byte 5 tells them apart. On a first frame it opens the base128'd crc, and
base128 output is 7-bit, so it is always <= 0x7F. On any other frame it is the
lead byte of the index rune, always 0xC2..0xDF. The ranges cannot overlap.

Index 1 is deliberately never issued, so a missing first frame is detected
rather than letting the last frame pass for it. Do not "fix" that by accepting
index 1.

Positions are 0-based: the first frame is position 0, any other frame is at
index - 1. total is only known once the first frame arrives, which may be last.
]]

const FRAME_SIZE = 1024
const FIRST_HEADER_SIZE = 12
const HEADER_SIZE = 6
const MAX_CHUNKS = 1919 -- maxChunks - 1 in backend/util/chunk.go

const FLAG_BASE128 = 0x01
const FLAG_COMPRESSED = 0x02

const POLYNOMIAL = 0xEDB88320
const INITIAL = 0xFFFFFFFF

const chunk = {}

export type Frame = {
    messageId: string,
    position: number, -- 0-based
    payload: string,
    total: number?,   -- first frame only
    crc: number?,     -- first frame only
    flags: number?,   -- first frame only
}

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

--- Message IDs are 4 bytes of valid UTF-8, not 4 printable characters, so hex
--- is the only sane way to show one. Wire byte order, unlike a buffer.readu32.
function chunk.formatMessageId(messageId: string): string
    return string.format("%02x%02x%02x%02x", string.byte(messageId, 1, 4))
end

--- Inverse of Encode in backend/util/base128.go, which packs 8-bit input into
--- 7-bit groups most-significant-bit first and zero-pads the last group.
---
--- Not buffer.writebits: that is bit-addressed least-significant-bit first,
--- the opposite order, and mixing the two silently produces garbage.
function chunk._base128decode(data: string): string
    if #data == 0 then
        return "" -- Encode returns nil for empty input
    end
    -- Exact: the encoder's padding is always fewer than 8 bits, so the trailing
    -- nbits remainder is padding by construction. No length field needed.
    const out = buffer.create(math.floor(#data * 7 / 8))
    local acc, nbits, pos = 0, 0, 0
    for i = 1, #data do
        const v = string.byte(data, i) :: number
        acc = bit32.bor(bit32.lshift(acc, 7), bit32.band(v, 0x7F)) -- at most 14 bits
        nbits += 7
        if nbits >= 8 then
            nbits -= 8
            buffer.writeu8(out, pos, bit32.band(bit32.rshift(acc, nbits), 0xFF))
            pos += 1
        end
    end
    return buffer.tostring(out)
end

--- Decodes the 2-byte rune at `offset`, returning its value less the 0x80 bias.
--- nil if the pair is not a well-formed 2-byte sequence.
function chunk._readRune(frame: string, offset: number): number?
    const b1, b2 = string.byte(frame, offset, offset + 1)
    if b1 == nil or b2 == nil then
        return nil
    end
    if b1 < 0xC2 or b1 > 0xDF then
        return nil
    end
    if b2 < 0x80 or b2 > 0xBF then
        return nil
    end
    const value = bit32.bor(
        bit32.lshift(bit32.band(b1, 0x1F), 6),
        bit32.band(b2, 0x3F)
    )
    return value - 0x80
end

function chunk.parseFrame(frame: string, logger: etc.Logger): Frame?
    -- Not an equality check: the last frame is short, and rune-boundary backoff
    -- can shorten the others.
    if #frame > FRAME_SIZE then
        return reject(logger, "frame is %* bytes, over the %* byte limit", #frame, FRAME_SIZE)
    end

    const discriminator = string.byte(frame, 5)
    if discriminator == nil then
        return reject(logger, "frame is %* bytes, too short to hold a header", #frame)
    end

    const messageId = string.sub(frame, 1, 4)

    if discriminator >= 0x80 then
        if #frame < HEADER_SIZE then
            return reject(logger, "continuation frame is %* bytes, under %*", #frame, HEADER_SIZE)
        end
        const index = chunk._readRune(frame, 5)
        if index == nil then
            return reject(logger, "malformed index rune on %*", chunk.formatMessageId(messageId))
        end
        -- Index 1 is never issued; see the header comment.
        if index < 2 or index > MAX_CHUNKS then
            return reject(logger, "index %* out of range on %*", index, chunk.formatMessageId(messageId))
        end
        return {
            messageId = messageId,
            position = index - 1,
            payload = string.sub(frame, HEADER_SIZE + 1),
        }
    end

    if #frame < FIRST_HEADER_SIZE then
        return reject(logger, "first frame is %* bytes, under %*", #frame, FIRST_HEADER_SIZE)
    end

    const total = chunk._readRune(frame, 10)
    if total == nil then
        return reject(logger, "malformed count rune on %*", chunk.formatMessageId(messageId))
    end
    if total < 1 or total > MAX_CHUNKS then
        return reject(logger, "total %* out of range on %*", total, chunk.formatMessageId(messageId))
    end

    const rawCrc = chunk._base128decode(string.sub(frame, 5, 9))
    const c1, c2, c3, c4 = string.byte(rawCrc, 1, 4)
    if c4 == nil then
        return reject(logger, "crc decoded to %* bytes on %*", #rawCrc, chunk.formatMessageId(messageId))
    end
    const crc = bit32.bor(
        bit32.lshift(c1 :: number, 24),
        bit32.lshift(c2 :: number, 16),
        bit32.lshift(c3 :: number, 8),
        c4 :: number
    )

    return {
        messageId = messageId,
        position = 0,
        payload = string.sub(frame, FIRST_HEADER_SIZE + 1),
        total = total,
        crc = crc,
        flags = string.byte(frame, 12) :: number,
    }
end

function chunk._decompress(data: string, logger: etc.Logger): string?
    const found, service = pcall(game.GetService, game, "EncodingService")
    if not found or service == nil then
        return reject(logger, "EncodingService is unavailable, cannot decompress")
    end

    const compressed = buffer.fromstring(data)
    -- The documented way to sanity-check before allocating. Returns nil rather
    -- than throwing, unlike DecompressBuffer.
    const size = (service :: any):GetDecompressedBufferSize(compressed, Enum.CompressionAlgorithm.Zstd)
    if size == nil then
        return reject(logger, "zstd frame is corrupt or oversized")
    end

    const decoded, out = pcall(function()
        return (service :: any):DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)
    end)
    if not decoded then
        return reject(logger, "zstd decompress failed: %*", tostring(out))
    end
    return buffer.tostring(out)
end

--- `payloads` is a dense 1-based array in position order.
---
--- Order matters. The Go side checksums the *encoded* payload
--- (crc32.ChecksumIEEE(active) in chunk.go), so the crc is verified before any
--- decoding happens.
function chunk.assemble(
    payloads: { string },
    crc: number,
    flags: number,
    logger: etc.Logger
): string?
    -- The crc has already passed by the time flags are applied, so nothing
    -- downstream would catch a half-decoded result. Fail loudly instead.
    if bit32.band(flags, bit32.bnot(bit32.bor(FLAG_BASE128, FLAG_COMPRESSED))) ~= 0 then
        return reject(logger, "unknown flag bits set: %02x", flags)
    end
    const base128 = bit32.band(flags, FLAG_BASE128) ~= 0
    const compressed = bit32.band(flags, FLAG_COMPRESSED) ~= 0
    -- Chunk only ever reaches the compressed branch by way of base128.
    if compressed and not base128 then
        return reject(logger, "compressed without base128, flags %02x", flags)
    end

    local joined = table.concat(payloads)

    const checksum = chunk._crc32(joined)
    if checksum ~= crc then
        return reject(logger, "checksum mismatch, %08x != %08x", crc, checksum)
    end

    if base128 then
        joined = chunk._base128decode(joined)
    end

    if compressed then
        return chunk._decompress(joined, logger)
    end

    return joined
end

return chunk
