--!strict

-- made by Claude (Opus 5 @ Medium)

--[=[
    @class Aes256

    AES-256 in CTR and CBC modes, over [buffer].

    Self-contained: no Roblox API surface and no dependencies, so it is usable
    from anywhere and testable outside the engine.

    Neither mode is authenticated. A tampered ciphertext decrypts to garbage
    rather than raising, and CBC's padding check is not a substitute for a MAC.
    Wrap this in encrypt-then-MAC before it guards anything on the wire.
]=]
const Aes256 = {}
Aes256.__index = Aes256

type Props = {
    encKeys: { number }, -- 60 round-key words, encryption order
    decKeys: { number }, -- 60 words, equivalent inverse cipher order
}

export type Aes256 = setmetatable<Props, typeof(Aes256)>

const KEY_LENGTH = 32
const BLOCK_LENGTH = 16
const ROUNDS = 14
const WORDS = 4 * (ROUNDS + 1) -- 60

const bxor = bit32.bxor
const band = bit32.band
const lshift = bit32.lshift
const rshift = bit32.rshift

--[=[
    @private

    Multiplies by x in GF(2^8), reducing by the AES polynomial 0x11B.
]=]
local function xtime(a: number): number
    const doubled = lshift(a, 1)
    if doubled >= 0x100 then
        return bxor(doubled, 0x11B)
    end
    return doubled
end

--[=[
    @private

    Multiplies two GF(2^8) elements.
]=]
local function gmul(a: number, b: number): number
    local product = 0
    while b ~= 0 do
        if band(b, 1) == 1 then
            product = bxor(product, a)
        end
        a = xtime(a)
        b = rshift(b, 1)
    end
    return product
end

--[=[
    @private

    Rotates an 8-bit value left by `n` bits.
]=]
local function rotl8(value: number, n: number): number
    return band(bxor(lshift(value, n), rshift(value, 8 - n)), 0xFF)
end

-- Tables are derived at load rather than pasted as literals, so they are
-- verifiable by reading the field arithmetic above.
const SBOX = table.create(256, 0)
const INV_SBOX = table.create(256, 0)

do
    -- exp/log over the generator 0x03 give cheap multiplicative inverses.
    const exp = table.create(255, 0)
    const log = table.create(256, 0)
    local x = 1
    for i = 0, 254 do
        exp[i] = x
        log[x] = i
        x = bxor(x, xtime(x)) -- x * 3
    end

    for i = 0, 255 do
        const inverse = if i == 0 then 0 else exp[(255 - log[i]) % 255]
        const substituted = bxor(
            inverse,
            rotl8(inverse, 1),
            rotl8(inverse, 2),
            rotl8(inverse, 3),
            rotl8(inverse, 4),
            0x63
        )
        SBOX[i] = substituted
        INV_SBOX[substituted] = i
    end
end

table.freeze(SBOX)
table.freeze(INV_SBOX)

-- T-tables fold SubBytes, ShiftRows and MixColumns into one lookup per byte.
-- TE0[x] holds the column {2s, s, s, 3s} packed big-endian; TE1..TE3 are the
-- same word rotated right by 8, 16 and 24 bits.
const TE0 = table.create(256, 0)
const TE1 = table.create(256, 0)
const TE2 = table.create(256, 0)
const TE3 = table.create(256, 0)

-- TD0[x] holds {14t, 9t, 13t, 11t} for the inverse direction.
const TD0 = table.create(256, 0)
const TD1 = table.create(256, 0)
const TD2 = table.create(256, 0)
const TD3 = table.create(256, 0)

do
    local function pack(b0: number, b1: number, b2: number, b3: number): number
        return bxor(lshift(b0, 24), lshift(b1, 16), lshift(b2, 8), b3)
    end

    local function rotr32(word: number, n: number): number
        return bxor(rshift(word, n), lshift(word, 32 - n))
    end

    for i = 0, 255 do
        const s = SBOX[i]
        const forward = pack(xtime(s), s, s, bxor(xtime(s), s))
        TE0[i] = forward
        TE1[i] = rotr32(forward, 8)
        TE2[i] = rotr32(forward, 16)
        TE3[i] = rotr32(forward, 24)

        const t = INV_SBOX[i]
        const inverse = pack(gmul(t, 14), gmul(t, 9), gmul(t, 13), gmul(t, 11))
        TD0[i] = inverse
        TD1[i] = rotr32(inverse, 8)
        TD2[i] = rotr32(inverse, 16)
        TD3[i] = rotr32(inverse, 24)
    end
end

table.freeze(TE0)
table.freeze(TE1)
table.freeze(TE2)
table.freeze(TE3)
table.freeze(TD0)
table.freeze(TD1)
table.freeze(TD2)
table.freeze(TD3)

-- Round constants, one per 8-word step of the AES-256 schedule.
const RCON = table.freeze({ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40 })

--[=[
    @private

    Applies the S-box to each byte of a word.
]=]
local function subWord(word: number): number
    return bxor(
        lshift(SBOX[rshift(word, 24)], 24),
        lshift(SBOX[band(rshift(word, 16), 0xFF)], 16),
        lshift(SBOX[band(rshift(word, 8), 0xFF)], 8),
        SBOX[band(word, 0xFF)]
    )
end

--[=[
    @private

    Applies InvMixColumns to a single packed column, used to convert an
    encryption round key into its equivalent-inverse-cipher form.
]=]
local function invMixColumn(word: number): number
    const a0 = rshift(word, 24)
    const a1 = band(rshift(word, 16), 0xFF)
    const a2 = band(rshift(word, 8), 0xFF)
    const a3 = band(word, 0xFF)
    return bxor(
        lshift(bxor(gmul(a0, 14), gmul(a1, 11), gmul(a2, 13), gmul(a3, 9)), 24),
        lshift(bxor(gmul(a0, 9), gmul(a1, 14), gmul(a2, 11), gmul(a3, 13)), 16),
        lshift(bxor(gmul(a0, 13), gmul(a1, 9), gmul(a2, 14), gmul(a3, 11)), 8),
        bxor(gmul(a0, 11), gmul(a1, 13), gmul(a2, 9), gmul(a3, 14))
    )
end

-- AES words are big-endian, while buffer.readu32 is little-endian, so words are
-- assembled a byte at a time rather than read wholesale and swapped.
local function readWord(source: buffer, offset: number): number
    return bxor(
        lshift(buffer.readu8(source, offset), 24),
        lshift(buffer.readu8(source, offset + 1), 16),
        lshift(buffer.readu8(source, offset + 2), 8),
        buffer.readu8(source, offset + 3)
    )
end

local function writeWord(target: buffer, offset: number, word: number): ()
    buffer.writeu8(target, offset, rshift(word, 24))
    buffer.writeu8(target, offset + 1, band(rshift(word, 16), 0xFF))
    buffer.writeu8(target, offset + 2, band(rshift(word, 8), 0xFF))
    buffer.writeu8(target, offset + 3, band(word, 0xFF))
end

--[=[
    @private

    Encrypts one block held as four big-endian state words.
]=]
local function encryptState(
    rk: { number },
    s0: number,
    s1: number,
    s2: number,
    s3: number
): (number, number, number, number)
    s0 = bxor(s0, rk[1])
    s1 = bxor(s1, rk[2])
    s2 = bxor(s2, rk[3])
    s3 = bxor(s3, rk[4])

    local r = 5
    for _ = 1, ROUNDS - 1 do
        s0, s1, s2, s3 =
            bxor(TE0[rshift(s0, 24)], TE1[band(rshift(s1, 16), 0xFF)], TE2[band(rshift(s2, 8), 0xFF)], TE3[band(s3, 0xFF)], rk[r]),
            bxor(TE0[rshift(s1, 24)], TE1[band(rshift(s2, 16), 0xFF)], TE2[band(rshift(s3, 8), 0xFF)], TE3[band(s0, 0xFF)], rk[r + 1]),
            bxor(TE0[rshift(s2, 24)], TE1[band(rshift(s3, 16), 0xFF)], TE2[band(rshift(s0, 8), 0xFF)], TE3[band(s1, 0xFF)], rk[r + 2]),
            -- Parenthesized so the trailing call is truncated to one value
            -- rather than expanding as a variadic tail.
            (bxor(TE0[rshift(s3, 24)], TE1[band(rshift(s0, 16), 0xFF)], TE2[band(rshift(s1, 8), 0xFF)], TE3[band(s2, 0xFF)], rk[r + 3]))
        r += 4
    end

    -- The last round drops MixColumns, so it reads the S-box directly.
    local function lastRound(a: number, b: number, c: number, d: number, key: number): number
        return bxor(
            lshift(SBOX[rshift(a, 24)], 24),
            lshift(SBOX[band(rshift(b, 16), 0xFF)], 16),
            lshift(SBOX[band(rshift(c, 8), 0xFF)], 8),
            SBOX[band(d, 0xFF)],
            key
        )
    end

    -- Indexing an array is `number?` under the new solver; the schedule is
    -- always 60 words, so these four reads are known to be present.
    const k0, k1, k2, k3 = rk[r] :: number, rk[r + 1] :: number, rk[r + 2] :: number, rk[r + 3] :: number
    return lastRound(s0, s1, s2, s3, k0),
        lastRound(s1, s2, s3, s0, k1),
        lastRound(s2, s3, s0, s1, k2),
        lastRound(s3, s0, s1, s2, k3)
end

--[=[
    @private

    Decrypts one block held as four big-endian state words. Byte selection runs
    the opposite way around the state to undo InvShiftRows.
]=]
local function decryptState(
    rk: { number },
    s0: number,
    s1: number,
    s2: number,
    s3: number
): (number, number, number, number)
    s0 = bxor(s0, rk[1])
    s1 = bxor(s1, rk[2])
    s2 = bxor(s2, rk[3])
    s3 = bxor(s3, rk[4])

    local r = 5
    for _ = 1, ROUNDS - 1 do
        s0, s1, s2, s3 =
            bxor(TD0[rshift(s0, 24)], TD1[band(rshift(s3, 16), 0xFF)], TD2[band(rshift(s2, 8), 0xFF)], TD3[band(s1, 0xFF)], rk[r]),
            bxor(TD0[rshift(s1, 24)], TD1[band(rshift(s0, 16), 0xFF)], TD2[band(rshift(s3, 8), 0xFF)], TD3[band(s2, 0xFF)], rk[r + 1]),
            bxor(TD0[rshift(s2, 24)], TD1[band(rshift(s1, 16), 0xFF)], TD2[band(rshift(s0, 8), 0xFF)], TD3[band(s3, 0xFF)], rk[r + 2]),
            (bxor(TD0[rshift(s3, 24)], TD1[band(rshift(s2, 16), 0xFF)], TD2[band(rshift(s1, 8), 0xFF)], TD3[band(s0, 0xFF)], rk[r + 3]))
        r += 4
    end

    local function lastRound(a: number, b: number, c: number, d: number, key: number): number
        return bxor(
            lshift(INV_SBOX[rshift(a, 24)], 24),
            lshift(INV_SBOX[band(rshift(b, 16), 0xFF)], 16),
            lshift(INV_SBOX[band(rshift(c, 8), 0xFF)], 8),
            INV_SBOX[band(d, 0xFF)],
            key
        )
    end

    const k0, k1, k2, k3 = rk[r] :: number, rk[r + 1] :: number, rk[r + 2] :: number, rk[r + 3] :: number
    return lastRound(s0, s3, s2, s1, k0),
        lastRound(s1, s0, s3, s2, k1),
        lastRound(s2, s1, s0, s3, k2),
        lastRound(s3, s2, s1, s0, k3)
end

--[=[
    @private

    Expands a 32-byte key into the 60 encryption round-key words.
]=]
local function expandKey(key: buffer): { number }
    const keys = table.create(WORDS, 0)
    for i = 1, 8 do
        keys[i] = readWord(key, (i - 1) * 4)
    end

    for i = 9, WORDS do
        const step = i - 1 -- zero-based, which is what the schedule is defined over
        local temp = keys[i - 1]
        if step % 8 == 0 then
            const rotated = bxor(lshift(temp, 8), rshift(temp, 24))
            temp = bxor(subWord(rotated), lshift(RCON[step // 8], 24))
        elseif step % 8 == 4 then
            temp = subWord(temp)
        end
        keys[i] = bxor(keys[i - 8], temp)
    end

    return keys
end

--[=[
    @private

    Derives the equivalent inverse cipher schedule: round keys in reverse order,
    with InvMixColumns applied to every key but the first and last.
]=]
local function invertKeys(encKeys: { number }): { number }
    const decKeys = table.create(WORDS, 0)
    for round = 0, ROUNDS do
        for word = 1, 4 do
            decKeys[round * 4 + word] = encKeys[(ROUNDS - round) * 4 + word]
        end
    end

    for round = 1, ROUNDS - 1 do
        for word = 1, 4 do
            const index = round * 4 + word
            decKeys[index] = invMixColumn(decKeys[index])
        end
    end

    return decKeys
end

--[=[
    Creates a cipher from a 32-byte key.

    The key schedule is computed once here, so reuse the returned object across
    calls rather than constructing one per message.

```lua
    const cipher = Aes256.new(key)
    const ciphertext = cipher:ctr(nonce, plaintext)
```

    @param key buffer -- Exactly 32 bytes of key material
    @return Aes256
]=]
function Aes256.new(key: buffer): Aes256
    if buffer.len(key) ~= KEY_LENGTH then
        error(string.format("aes256: key must be %d bytes, got %d", KEY_LENGTH, buffer.len(key)), 2)
    end

    const encKeys = expandKey(key)
    const self = setmetatable({
        encKeys = encKeys,
        decKeys = invertKeys(encKeys),
    }, Aes256)
    return self
end

--[=[
    Encrypts a single 16-byte block.

    `input` and `output` may be the same buffer at the same offset.

    @param input buffer -- Source of the plaintext block
    @param inOffset number -- Byte offset of the block within `input`
    @param output buffer -- Destination for the ciphertext block
    @param outOffset number -- Byte offset to write at within `output`
]=]
function Aes256.encryptBlock(self: Aes256, input: buffer, inOffset: number, output: buffer, outOffset: number): ()
    const s0, s1, s2, s3 = encryptState(
        self.encKeys,
        readWord(input, inOffset),
        readWord(input, inOffset + 4),
        readWord(input, inOffset + 8),
        readWord(input, inOffset + 12)
    )
    writeWord(output, outOffset, s0)
    writeWord(output, outOffset + 4, s1)
    writeWord(output, outOffset + 8, s2)
    writeWord(output, outOffset + 12, s3)
end

--[=[
    Decrypts a single 16-byte block.

    `input` and `output` may be the same buffer at the same offset.

    @param input buffer -- Source of the ciphertext block
    @param inOffset number -- Byte offset of the block within `input`
    @param output buffer -- Destination for the plaintext block
    @param outOffset number -- Byte offset to write at within `output`
]=]
function Aes256.decryptBlock(self: Aes256, input: buffer, inOffset: number, output: buffer, outOffset: number): ()
    const s0, s1, s2, s3 = decryptState(
        self.decKeys,
        readWord(input, inOffset),
        readWord(input, inOffset + 4),
        readWord(input, inOffset + 8),
        readWord(input, inOffset + 12)
    )
    writeWord(output, outOffset, s0)
    writeWord(output, outOffset + 4, s1)
    writeWord(output, outOffset + 8, s2)
    writeWord(output, outOffset + 12, s3)
end

--[=[
    Runs CTR mode over `data`, returning a buffer of the same length.

    CTR is its own inverse, so this both encrypts and decrypts. `nonce` is the
    full initial counter block and the whole 128 bits are incremented per block,
    matching Go's `cipher.NewCTR`.

    Never reuse a counter block with the same key: XORing two such outputs
    cancels the keystream out entirely.

    @param nonce buffer -- Exactly 16 bytes; the initial counter block
    @param data buffer -- Plaintext or ciphertext of any length, including zero
    @return buffer -- Result, `buffer.len(data)` bytes long
]=]
function Aes256.ctr(self: Aes256, nonce: buffer, data: buffer): buffer
    if buffer.len(nonce) ~= BLOCK_LENGTH then
        error(string.format("aes256: nonce must be %d bytes, got %d", BLOCK_LENGTH, buffer.len(nonce)), 2)
    end

    const length = buffer.len(data)
    const output = buffer.create(length)
    local c0, c1, c2, c3 = readWord(nonce, 0), readWord(nonce, 4), readWord(nonce, 8), readWord(nonce, 12)

    local offset = 0
    while offset < length do
        const k0, k1, k2, k3 = encryptState(self.encKeys, c0, c1, c2, c3)
        const remaining = length - offset

        if remaining >= BLOCK_LENGTH then
            writeWord(output, offset, bxor(readWord(data, offset), k0))
            writeWord(output, offset + 4, bxor(readWord(data, offset + 4), k1))
            writeWord(output, offset + 8, bxor(readWord(data, offset + 8), k2))
            writeWord(output, offset + 12, bxor(readWord(data, offset + 12), k3))
        else
            -- Partial final block: the unused keystream bytes are discarded.
            const keystream = { k0, k1, k2, k3 }
            for i = 0, remaining - 1 do
                const word = keystream[i // 4 + 1]
                const byte = band(rshift(word, 24 - (i % 4) * 8), 0xFF)
                buffer.writeu8(output, offset + i, bxor(buffer.readu8(data, offset + i), byte))
            end
        end

        -- Big-endian increment of the full counter block.
        c3 += 1
        if c3 > 0xFFFFFFFF then
            c3 = 0
            c2 += 1
            if c2 > 0xFFFFFFFF then
                c2 = 0
                c1 += 1
                if c1 > 0xFFFFFFFF then
                    c1 = 0
                    c0 = (c0 + 1) % 0x100000000
                end
            end
        end

        offset += BLOCK_LENGTH
    end

    return output
end

--[=[
    Encrypts `plaintext` in CBC mode with PKCS#7 padding.

    Output is always longer than the input: an already block-aligned plaintext
    gains a full block of padding, which is what makes the padding unambiguous.

    `iv` must be unpredictable and must not be reused with the same key.

    @param iv buffer -- Exactly 16 bytes
    @param plaintext buffer -- Data of any length, including zero
    @return buffer -- Ciphertext, padded up to the next block boundary
]=]
function Aes256.cbcEncrypt(self: Aes256, iv: buffer, plaintext: buffer): buffer
    if buffer.len(iv) ~= BLOCK_LENGTH then
        error(string.format("aes256: iv must be %d bytes, got %d", BLOCK_LENGTH, buffer.len(iv)), 2)
    end

    const length = buffer.len(plaintext)
    const padding = BLOCK_LENGTH - length % BLOCK_LENGTH
    const output = buffer.create(length + padding)

    -- Stage the padded plaintext in the output buffer, then encrypt in place.
    buffer.copy(output, 0, plaintext)
    buffer.fill(output, length, padding, padding)

    local p0, p1, p2, p3 = readWord(iv, 0), readWord(iv, 4), readWord(iv, 8), readWord(iv, 12)
    for offset = 0, buffer.len(output) - 1, BLOCK_LENGTH do
        p0, p1, p2, p3 = encryptState(
            self.encKeys,
            bxor(readWord(output, offset), p0),
            bxor(readWord(output, offset + 4), p1),
            bxor(readWord(output, offset + 8), p2),
            bxor(readWord(output, offset + 12), p3)
        )
        writeWord(output, offset, p0)
        writeWord(output, offset + 4, p1)
        writeWord(output, offset + 8, p2)
        writeWord(output, offset + 12, p3)
    end

    return output
end

--[=[
    Decrypts `ciphertext` in CBC mode and strips PKCS#7 padding.

    Raises if the length is not a whole number of blocks or if the padding is
    malformed. A padding failure is not authentication: it only catches
    corruption that happens to land in the final block.

    @param iv buffer -- Exactly 16 bytes; the same IV used to encrypt
    @param ciphertext buffer -- A non-empty multiple of 16 bytes
    @return buffer -- Plaintext with padding removed
]=]
function Aes256.cbcDecrypt(self: Aes256, iv: buffer, ciphertext: buffer): buffer
    if buffer.len(iv) ~= BLOCK_LENGTH then
        error(string.format("aes256: iv must be %d bytes, got %d", BLOCK_LENGTH, buffer.len(iv)), 2)
    end

    const length = buffer.len(ciphertext)
    if length == 0 or length % BLOCK_LENGTH ~= 0 then
        error(string.format("aes256: ciphertext must be a non-zero multiple of %d bytes, got %d", BLOCK_LENGTH, length), 2)
    end

    const padded = buffer.create(length)
    local p0, p1, p2, p3 = readWord(iv, 0), readWord(iv, 4), readWord(iv, 8), readWord(iv, 12)

    for offset = 0, length - 1, BLOCK_LENGTH do
        const c0, c1, c2, c3 =
            readWord(ciphertext, offset),
            readWord(ciphertext, offset + 4),
            readWord(ciphertext, offset + 8),
            readWord(ciphertext, offset + 12)
        const s0, s1, s2, s3 = decryptState(self.decKeys, c0, c1, c2, c3)
        writeWord(padded, offset, bxor(s0, p0))
        writeWord(padded, offset + 4, bxor(s1, p1))
        writeWord(padded, offset + 8, bxor(s2, p2))
        writeWord(padded, offset + 12, bxor(s3, p3))
        p0, p1, p2, p3 = c0, c1, c2, c3
    end

    const padding = buffer.readu8(padded, length - 1)
    if padding == 0 or padding > BLOCK_LENGTH then
        error("aes256: invalid pkcs#7 padding", 2)
    end
    for i = length - padding, length - 1 do
        if buffer.readu8(padded, i) ~= padding then
            error("aes256: invalid pkcs#7 padding", 2)
        end
    end

    const output = buffer.create(length - padding)
    buffer.copy(output, 0, padded, 0, length - padding)
    return output
end

return Aes256
