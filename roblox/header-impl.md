# Bringing the Luau receiver onto the current wire format

## Context

`5c725c4` reworked the Go wire format around zstd + base128 and `5a04f82`
finished it. The Luau side never moved. `src/server/chunk.luau` still decodes the
old `IINNCCCCCCCC` hex header and cannot read anything `backend/util/chunk.go`
currently emits, so the receive path is dead end to end.

This is a spec for rebuilding the receiver against the format the Go side
actually produces. Read `backend/util/chunk.go` and `backend/util/chunk_test.go`
alongside this — the Go test file contains a working reference decoder
(`dechunk`) that this mirrors.

§6 covers decompression, which needs a one-line change on the Go side to work.
Nothing here is blocked.

---

## 1. The format

Frames are 1024 bytes or fewer, all valid UTF-8, and each one is published as its
own MessagingService message (`SendMessage` in `backend/util/roblox.go`). They
arrive in arbitrary order.

Two header shapes. Byte offsets below are **1-based** for Luau's `string.byte` /
`string.sub`.

**First frame — 12 byte header**

| Bytes | Field | Notes |
|---|---|---|
| 1-4 | message ID | 4 random bytes, valid UTF-8. Identifies the message. |
| 5-9 | crc32 | 4-byte big-endian CRC-32, base128'd to 5 bytes |
| 10-11 | count rune | 2-byte UTF-8 rune, value `0x80 + total` |
| 12 | flags | bit 0 = base128, bit 1 = compressed |
| 13+ | payload | |

**Every other frame — 6 byte header**

| Bytes | Field | Notes |
|---|---|---|
| 1-4 | message ID | same for all frames of a message |
| 5-6 | index rune | 2-byte UTF-8 rune, value `0x80 + index`, index 2..total |
| 7+ | payload | |

### Telling them apart

Byte 5 is the discriminator:

- First frame: byte 5 opens the base128'd CRC. Base128 output is 7-bit, so it is
  always `<= 0x7F`.
- Other frames: byte 5 is the UTF-8 lead byte of the index rune, always
  `0xC2..0xDF`.

The ranges cannot overlap, so **`string.byte(frame, 5) < 0x80` means first
frame**. This is documented in the const block of `chunk.go`.

That is what lets the count rune slot do double duty. Index 1 is deliberately
never issued, so a first frame that goes missing is detected rather than letting
the last frame pass for it — do not "fix" that by accepting index 1.

### Positions

First frame is position 0. Any other frame is at `index - 1`, giving
`1..total-1`. `total` is only known once the first frame arrives, which the
buffering has to tolerate.

### Decoding a 2-byte rune

```luau
const b1, b2 = string.byte(frame, offset, offset + 1)
const value = bit32.bor(
    bit32.lshift(bit32.band(b1, 0x1F), 6),
    bit32.band(b2, 0x3F)
)
-- reject unless b1 is 0xC2..0xDF and b2 is 0x80..0xBF
const n = value - 0x80
```

---

## 2. `chunk.luau` — replace the module

The current shape takes one concatenated blob and re-splits it on fixed 1024-byte
boundaries. That is no longer possible: frames are variable length, because
`Chunk` backs off to rune boundaries when splitting and the final frame is short.
The module has to work on a list of frames instead.

### Keep

`chunk._crc32` is correct as-is. It is CRC-32 with polynomial `0xEDB88320`,
reflected, which is exactly `hash/crc32.ChecksumIEEE` on the Go side. Do not
touch it.

### Delete

`chunk._verifylen`, `chunk._extractData`, and the current `chunk.dechunk`. All
three encode the old format. The block comment above `HEADER_SIZE` describes the
old layout and should be replaced with the tables in §1.

### Add: `chunk.parseFrame`

```luau
export type Frame = {
    messageId: string,
    position: number,   -- 0-based
    payload: string,
    total: number?,     -- first frame only
    crc: number?,       -- first frame only
    flags: number?,     -- first frame only
}

function chunk.parseFrame(frame: string, logger: etc.Logger): Frame?
```

Rules:

- Reject `#frame > FRAME_SIZE`. Do **not** require exactly `FRAME_SIZE` — the
  last frame is short, and rune-boundary backoff can shorten others.
- Branch on `string.byte(frame, 5) < 0x80`.
- First frame: require `#frame >= 12`, decode the count rune at 10-11 into
  `total`, reject `total < 1` or `total > 1919` (`maxChunks - 1` in Go), base128-
  decode bytes 5-9 into 4 bytes and read big-endian into `crc`, take flags from
  byte 12, payload from 13.
- Other frames: require `#frame >= 6`, decode the index rune at 5-6, reject
  index `< 2`, set `position = index - 1`, payload from 7.
- Return `nil` through the existing `reject` helper on any failure.

### Add: `chunk.assemble`

```luau
function chunk.assemble(
    payloads: {string},  -- dense, position order, 1-based Luau array
    crc: number,
    flags: number,
    logger: etc.Logger
): string?
```

Order of operations, and it matters:

1. `table.concat(payloads)`.
2. Verify `chunk._crc32(joined) == crc`. **The Go side checksums the encoded
   payload, not the original data** (`crc32.ChecksumIEEE(active)` in
   `chunk.go`), so this check happens before any decoding.
3. If `bit32.band(flags, 0x01) ~= 0`, base128-decode.
4. If `bit32.band(flags, 0x02) ~= 0`, decompress — see §6.
5. Return the result.

### Add: `chunk._base128decode`

Inverse of `Encode` in `backend/util/base128.go`. That packs 8-bit input into
7-bit output groups, most-significant-bit first, zero-padding the final group.

```luau
function chunk._base128decode(data: string): string
    const out = buffer.create(math.floor(#data * 7 / 8))
    local acc, nbits, pos = 0, 0, 0
    for i = 1, #data do
        const v = string.byte(data, i) :: number
        acc = bit32.bor(bit32.lshift(acc, 7), bit32.band(v, 0x7F))
        nbits += 7
        if nbits >= 8 then
            nbits -= 8
            buffer.writeu8(out, pos, bit32.band(bit32.rshift(acc, nbits), 0xFF))
            pos += 1
        end
    end
    return buffer.tostring(out)
end
```

Notes:

- `acc` holds at most 14 bits, well inside `bit32`'s 32.
- The output length is exactly `floor(#data * 7 / 8)`. The encoder's padding is
  always fewer than 8 bits, so the trailing `nbits` remainder is padding by
  construction and is correctly dropped. No length field is needed.
- Do **not** reach for `buffer.writebits` here. It is bit-addressed
  least-significant-bit-first, which is the opposite order from the Go encoder.
  Mixing the two silently produces garbage.
- Worth a `#data == 0` early return, since `Encode` returns nil for empty input.

---

## 3. `shoes.luau` — rework `_receive`

`Shoes:_receive` (line 155) needs restructuring, not patching.

**Rekey the buffers.** `self.buffers` is currently keyed by CRC. The CRC now
only exists on the first frame, so it is unavailable for the frames that arrive
before it. Key by **message ID** instead — it is on every frame and it is a
plain 4-byte string, fine as a table key.

**Tolerate an unknown total.** A pending entry now looks roughly like:

```luau
{
    total = nil,      -- filled in when the first frame arrives
    crc = nil,        -- ditto
    flags = nil,      -- ditto
    count = 0,
    frames = {},      -- [position] = payload
    stamp = os.clock(),
}
```

Flow: parse the frame, look up or create the pending entry by
`frame.messageId`, ignore it if `frames[frame.position]` is already set, store
the payload and bump `count`. If the frame carries `total`/`crc`/`flags`, record
them. Fire only when `total ~= nil and count == total`.

**Build the ordered list.** Positions are `0..total-1`; walk that range, bail if
any slot is nil, and build a 1-based dense array for `table.concat`. Then call
`chunk.assemble(ordered, pending.crc, pending.flags, self.logger)`.

**Update `_sweep`** (line 141) — it logs `crc` with `%08x`, which is now a
message ID string. Log it as hex instead:

```luau
(string.gsub(messageId, ".", function(c)
    return string.format("%02x", string.byte(c))
end))
```

Note the outer parens: `gsub` returns two values and the second will otherwise
leak into `sprint`'s varargs.

`BUFFER_TIMEOUT` at 30s stays as-is.

---

## 4. Pre-existing bug to fix while you are in there

`chunk.luau:5` calls `logger.sprint(etc.LogLevel.error, ...)` — lowercase. `etc`
exports `Error`, capitalised (`etc.luau:12`). `etc.LogLevel.error` is `nil`, so
every rejection currently logs with a nil level. Change it to
`etc.LogLevel.Error`.

---

## 5. Frame size vs. the MessagingService limit

`Chunk` emits frames of exactly 1024 bytes (the last one short). MessagingService
has a documented per-message size cap that this is clearly sized against, but I
have not verified the current number or whether it counts UTF-8 bytes or
characters, and whether the Open Cloud `publishMessage` path measures it the same
way as `SubscribeAsync` receives it.

Worth confirming before you build on it, because if the cap counts *characters*
then a base128 payload (all single-byte) passes at 1024 while a raw multibyte
UTF-8 payload of 1024 bytes is well under, and a mixed one behaves differently
again. Check `create.roblox.com/docs` rather than trusting this file. If the real
cap is below 1024 the fix is `frameSize` in `chunk.go`, not anything here.

---

## 6. Decompression

Roblox ships zstd natively via `EncodingService`, so step 4 of `chunk.assemble`
is a library call:

```luau
const EncodingService = game:GetService("EncodingService")

const compressed = buffer.fromstring(joined)
const size = EncodingService:GetDecompressedBufferSize(compressed, Enum.CompressionAlgorithm.Zstd)
if size == nil then
    return reject(logger, "zstd frame is corrupt or oversized")
end
const ok, out = pcall(function()
    return EncodingService:DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)
end)
if not ok then
    return reject(logger, "zstd decompress failed: %*", tostring(out))
end
return buffer.tostring(out)
```

`Enum.CompressionAlgorithm.Zstd` is currently the only member. `DecompressBuffer`
throws rather than returning nil, hence the `pcall`; `GetDecompressedBufferSize`
returns nil instead, and calling it first is the documented way to sanity-check
before allocating. Both take and return `buffer`, so convert at the boundary.
The decompressed cap is 1 GB, which is not a concern here.

### One Go-side change is required first

`DecompressBuffer` throws if the frame does not carry its decompressed size, and
`klauspost/compress` omits that field on small inputs. Measured on the encoder
currently in `chunk.go`, against data `Chunk` actually routes down the compressed
branch:

| input | frame descriptor | content size present |
|---|---|---|
| 50 B | `0x04` | no |
| 100 B | `0x04` | no |
| 200 B | `0x04` | no |
| 500 B | `0x44` | yes |
| 1 KB and up | `0x44`/`0x64` | yes |

So every compressed message under roughly 500 bytes would throw on arrival —
and short messages are exactly the common case for a control channel.

The fix is one option at the encoder in `chunk.go`:

```go
enc, err := zstd.NewWriter(nil, zstd.WithSingleSegment(true))
```

The single-segment flag makes `Frame_Content_Size` mandatory in the frame header.
Measured cost: nothing. Output was byte-identical at 50-200 B and one byte
*smaller* at 500 B-1 KB, because the window descriptor is dropped.

Make this change before testing the compressed path, or you will be debugging a
Luau error that has nothing to do with your Luau.

### Regardless

`chunk.assemble` should reject an unknown flag combination loudly rather than
returning a half-decoded string. The CRC has already passed by that point, so
nothing downstream will catch a silent wrong result.

---

## 7. Suggested order

1. `chunk._base128decode` plus the `etc.LogLevel.Error` fix. Self-contained.
2. `chunk.parseFrame`. Self-contained, and testable against captured bytes.
3. `chunk.assemble`, uncompressed paths first.
4. `shoes.luau:_receive` and `_sweep` rekeying.
5. `zstd.WithSingleSegment(true)` in `chunk.go`, then the decompress branch.

Steps 1-4 give a receiver that handles every uncompressed message, which is
already enough to exercise the transport end to end. Step 5 is small but do not
start it before 1-4 work, or a failure could be in either half.

---

## 8. Verifying it

There is no Luau test harness in the repo, so the cheapest real check is a
fixture round trip.

**Generate fixtures from Go.** Add a throwaway test in `backend/util` that calls
`Chunk` on a few known inputs and writes the frames somewhere readable — hex per
line, one file per message. Cover: a short ASCII string that stays raw
(flags 0), incompressible binary that goes base128-only (flags 1), a multi-frame
message so ordering matters, and multibyte UTF-8 so the rune-boundary splits are
exercised. Add compressed fixtures (flags 3) once §6's encoder change is in —
include one small enough to have tripped the content-size problem, around 100
bytes of repetitive text, so the fixture guards against a regression there.

**Drive the Luau side.** Feed the frames to `parseFrame` + `assemble` in a Studio
script, shuffled, and check the output matches the original input. Shuffling is
the important part — in-order reassembly passing proves very little, since the
whole design rests on out-of-order recovery.

**Targeted checks worth writing:**

- Shuffled multi-frame message reassembles byte-identically.
- Dropping the first frame is detected and never completes, rather than the last
  frame being mistaken for it.
- A duplicate frame is ignored, not double-counted.
- A frame with a flipped payload byte fails the CRC.
- Two interleaved messages with different message IDs both reassemble.
- A ~100 byte compressed message decompresses (the content-size case from §6).

**End to end.** With the backend running, call `SendMessage` and confirm
`Shoes.Message` fires with the right payload. Watch for the 30s `_sweep` warning
— if that fires, frames are arriving but not completing, which points at position
mapping or the total never being set.

---

## Reference

- `backend/util/chunk.go` — format, with the discriminator documented in the
  const block
- `backend/util/chunk_test.go` — `dechunk` and `isHeaderFrame` are a working
  reference decoder; port their logic
- `backend/util/base128.go` — the encoder `_base128decode` inverts
- `backend/util/header.go` — `ProduceFirstHeader` / `ProduceHeader` build the
  two header shapes
- `backend/util/roblox.go` — `SendMessage`, one frame per MessagingService
  message
