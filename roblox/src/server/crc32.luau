--!strict
--!optimize 2

-- made by Claude (Opus 5 @ Medium)

--[=[
    @class Crc32

    CRC-32 (IEEE 802.3), the variant used by zip, gzip, and PNG: reflected
    input and output, polynomial 0xEDB88320, initial and final xor of
    0xFFFFFFFF.

    Self-contained: no Roblox API surface and no dependencies, so it is usable
    from anywhere and testable outside the engine.

    This is a checksum, not a hash. It detects accidental corruption and
    nothing else — it is trivially forgeable, so never use it for integrity
    against an adversary or as a key derivation step.
]=]
const Crc32 = {}

const POLYNOMIAL = 0xEDB88320
const INITIAL = 0xFFFFFFFF

const bxor = bit32.bxor
const band = bit32.band
const rshift = bit32.rshift

--[=[
    @private

    Byte-indexed remainder table, built once at require time. Indices are
    0..255, so this is a hash part of the table rather than an array.
]=]
const TABLE: { [number]: number } = {}
for byte = 0, 255 do
    local remainder = byte
    for _ = 1, 8 do
        if band(remainder, 1) == 1 then
            remainder = bxor(rshift(remainder, 1), POLYNOMIAL)
        else
            remainder = rshift(remainder, 1)
        end
    end
    TABLE[byte] = remainder
end

--[=[
    Computes the CRC-32 of `data`, which may be a [string] or a [buffer].

    `previous` continues a running checksum: pass the value returned by an
    earlier call to hash a stream in chunks. Omitting it starts fresh.

    ```luau
    crc32.hash("123456789") --> 0xCBF43926

    local running = crc32.hash("1234")
    running = crc32.hash("56789", running) --> 0xCBF43926
    ```
]=]
function Crc32.hash(data: string | buffer, previous: number?): number
    -- The stored value is the finalized one, so undo the trailing xor before
    -- continuing and reapply it on the way out. That keeps the returned
    -- number directly comparable to any other CRC-32 implementation.
    local remainder = if previous ~= nil then bxor(previous, INITIAL) else INITIAL

    if type(data) == "string" then
        for index = 1, #data do
            const byte = string.byte(data, index) :: number
            remainder = bxor(rshift(remainder, 8), TABLE[band(bxor(remainder, byte), 0xFF)])
        end
    else
        const length = buffer.len(data)
        for offset = 0, length - 1 do
            const byte = buffer.readu8(data, offset)
            remainder = bxor(rshift(remainder, 8), TABLE[band(bxor(remainder, byte), 0xFF)])
        end
    end

    return bxor(remainder, INITIAL)
end

--[=[
    Formats a checksum as eight lowercase hex digits, zero padded.

    ```luau
    crc32.tohex(crc32.hash("123456789")) --> "cbf43926"
    ```
]=]
function Crc32.tohex(checksum: number): string
    return string.format("%08x", checksum)
end

return Crc32
