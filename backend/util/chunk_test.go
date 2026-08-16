package util

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	mathrand "math/rand/v2"
	"testing"
	"unicode/utf8"
)

// isHeaderFrame reports whether a frame carries the first-frame header.
//
// Byte 4 is the discriminator. On the first frame it is the leading byte of
// Encode(crc32sum), and base128 output is 7-bit, so it is always <= 0x7F. On
// every other frame it is the lead byte of the 2-byte UTF-8 count rune; total is
// capped at maxChunks so that rune is 0x81..0x7FF and its lead byte is always
// 0xC2..0xDF. The two ranges cannot overlap.
func isHeaderFrame(frame []byte) bool {
	return len(frame) > 4 && frame[4] < 0x80
}

// parsed is a message rebuilt from its frames.
type parsed struct {
	messageID []byte
	crc32     []byte
	total     int
	flags     byte
	position  []int  // position each frame was placed at, indexed as given
	payload   []byte // every frame's payload concatenated back in order
}

// dechunk rebuilds a message from frames in arbitrary order, using only what a
// receiver can see in the headers. Roblox delivers every frame as its own
// MessagingService message (see SendMessage in roblox.go), so nothing guarantees
// they arrive in the order Chunk produced them.
func dechunk(frames [][]byte) (parsed, error) {
	var out parsed
	if len(frames) == 0 {
		return out, errors.New("no frames")
	}

	head := -1
	for i, frame := range frames {
		if !isHeaderFrame(frame) {
			continue
		}
		if head >= 0 {
			return out, fmt.Errorf("frames %d and %d both look like the header frame", head, i)
		}
		head = i
	}
	if head < 0 {
		return out, errors.New("no header frame")
	}

	first := frames[head]
	if len(first) < initalHeaderSize {
		return out, fmt.Errorf("header frame is %d bytes, shorter than its %d byte header", len(first), initalHeaderSize)
	}
	countRune, size := utf8.DecodeRune(first[9:11])
	if countRune == utf8.RuneError || size != 2 {
		return out, fmt.Errorf("header frame count rune is not a 2 byte rune: % x", first[9:11])
	}

	out.messageID = first[0:4]
	out.crc32 = first[4:9]
	out.total = int(countRune - 0x0080)
	out.flags = first[11]
	out.position = make([]int, len(frames))

	if out.total != len(frames) {
		return out, fmt.Errorf("header declares %d frames, got %d", out.total, len(frames))
	}

	ordered := make([][]byte, out.total)
	ordered[0] = first[initalHeaderSize:]
	out.position[head] = 0

	for i, frame := range frames {
		if i == head {
			continue
		}
		if len(frame) < headerSize {
			return out, fmt.Errorf("frame %d is %d bytes, shorter than its %d byte header", i, len(frame), headerSize)
		}
		if !bytes.Equal(frame[0:4], out.messageID) {
			return out, fmt.Errorf("frame %d message id % x, want % x", i, frame[0:4], out.messageID)
		}
		r, n := utf8.DecodeRune(frame[4:6])
		if r == utf8.RuneError || n != 2 {
			return out, fmt.Errorf("frame %d sequence rune is not a 2 byte rune: % x", i, frame[4:6])
		}
		// Markers run 2..total, so position is marker-1. Marker 1 is never
		// issued; position 0 belongs to the header frame.
		pos := int(r-0x0080) - 1
		if pos < 1 || pos >= out.total {
			return out, fmt.Errorf("frame %d claims position %d, outside 1..%d", i, pos, out.total-1)
		}
		if ordered[pos] != nil {
			return out, fmt.Errorf("two frames claim position %d", pos)
		}
		ordered[pos] = frame[headerSize:]
		out.position[i] = pos
	}

	for pos, payload := range ordered {
		if payload == nil {
			return out, fmt.Errorf("no frame for position %d", pos)
		}
		out.payload = append(out.payload, payload...)
	}
	return out, nil
}

func mustDechunk(t *testing.T, frames [][]byte) parsed {
	t.Helper()
	p, err := dechunk(frames)
	if err != nil {
		t.Fatalf("dechunk: %v", err)
	}
	return p
}

// shuffled returns a copy of frames in a reproducible scrambled order.
func shuffled(frames [][]byte, seed uint64) [][]byte {
	out := make([][]byte, len(frames))
	copy(out, frames)
	r := mathrand.New(mathrand.NewPCG(seed, seed*2+1))
	r.Shuffle(len(out), func(i, j int) { out[i], out[j] = out[j], out[i] })
	return out
}

// compressible data: zstd crushes it, so both flags should end up set.
func compressible(n int) []byte {
	return bytes.Repeat([]byte("shoes shoes shoes "), n/18+1)[:n]
}

func randomBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}
	return b
}

// multibyteText builds valid UTF-8 that is mostly multi-byte runes and does not
// compress, so Chunk takes the raw path and the rune-boundary logic is live.
func multibyteText(t *testing.T, runes int) []byte {
	t.Helper()
	seed := randomBytes(t, runes*2)
	var buf bytes.Buffer
	for i := range runes {
		// 0x0800..0x0FFF and 0x4E00..0x4EFF give 3-byte runes off random bits.
		r := rune(0x4E00 + int(seed[i*2])<<8 + int(seed[i*2+1]))
		buf.WriteRune(r)
	}
	return buf.Bytes()
}

func TestChunkFramesFitFrameSize(t *testing.T) {
	cases := []struct {
		name string
		data []byte
	}{
		{"empty", nil},
		{"tiny ascii", []byte("shoes")},
		{"exactly one first payload", compressible(firstPayloadSize)},
		{"one byte past first payload", randomBytes(t, firstPayloadSize+1)},
		{"many frames", randomBytes(t, 64*1024)},
		{"compressible", compressible(512 * 1024)},
		{"multibyte utf-8", multibyteText(t, 20000)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frames, err := Chunk(tc.data)
			if err != nil {
				t.Fatalf("Chunk: %v", err)
			}
			for i, frame := range frames {
				if len(frame) > frameSize {
					t.Errorf("frame %d is %d bytes, over the %d byte frame size", i, len(frame), frameSize)
				}
			}
		})
	}
}

func TestChunkHeaderIsConsistentAcrossFrames(t *testing.T) {
	data := randomBytes(t, 32*1024)
	frames, err := Chunk(data)
	if err != nil {
		t.Fatalf("Chunk: %v", err)
	}
	p := mustDechunk(t, frames)

	if p.total != len(frames) {
		t.Errorf("first frame declares %d frames, Chunk returned %d", p.total, len(frames))
	}
	if !utf8.Valid(p.messageID) {
		t.Errorf("message id % x is not valid utf-8", p.messageID)
	}
	if len(p.crc32) != initalHeaderSize-headerSize-1 {
		t.Errorf("encoded crc32 is %d bytes, header layout assumes %d", len(p.crc32), initalHeaderSize-headerSize-1)
	}
}

func TestChunkChecksumCoversReassembledPayload(t *testing.T) {
	cases := map[string][]byte{
		"random":    randomBytes(t, 40*1024),
		"ascii":     compressible(40 * 1024),
		"multibyte": multibyteText(t, 5000),
		"tiny":      []byte("shoes"),
		"empty":     nil,
	}

	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			frames, err := Chunk(data)
			if err != nil {
				t.Fatalf("Chunk: %v", err)
			}
			p := mustDechunk(t, frames)

			sum := make([]byte, 4)
			binary.BigEndian.PutUint32(sum, crc32.ChecksumIEEE(p.payload))
			want := Encode(sum)
			if !bytes.Equal(p.crc32, want) {
				t.Errorf("header crc32 % x does not match reassembled payload crc32 % x", p.crc32, want)
			}
		})
	}
}

// The invariant that matters: frames arrive in any order and must still
// reassemble from their headers alone.
//
// The count rune slot is deliberately ambiguous on its own -- the header frame
// carries total where the others carry their own 1-based index, so the last
// frame's marker equals the header frame's. Frame 0 is told apart by byte 4
// instead (see isHeaderFrame), which is why marker 1 is never issued.
func TestChunkRoundTripsThroughShuffledFrames(t *testing.T) {
	cases := []struct {
		name string
		data []byte
	}{
		{"tiny ascii", []byte("shoes")},
		{"single frame", compressible(200)},
		{"two frames", randomBytes(t, firstPayloadSize+10)},
		{"incompressible binary", randomBytes(t, 64*1024)},
		{"compressible ascii", compressible(512 * 1024)},
		{"multibyte utf-8", multibyteText(t, 20000)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frames, err := Chunk(tc.data)
			if err != nil {
				t.Fatalf("Chunk: %v", err)
			}
			want := mustDechunk(t, frames).payload

			for seed := uint64(1); seed <= 5; seed++ {
				got, err := dechunk(shuffled(frames, seed))
				if err != nil {
					t.Fatalf("seed %d: dechunk: %v", seed, err)
				}
				if !bytes.Equal(got.payload, want) {
					t.Errorf("seed %d: reassembled %d bytes, want %d", seed, len(got.payload), len(want))
				}
				sum := make([]byte, 4)
				binary.BigEndian.PutUint32(sum, crc32.ChecksumIEEE(got.payload))
				if !bytes.Equal(got.crc32, Encode(sum)) {
					t.Errorf("seed %d: crc32 mismatch after reassembly", seed)
				}
			}
		})
	}
}

// The round trip leans entirely on byte 4 separating the two header shapes, so
// guard it directly. Changing the base128 alphabet or the rune base breaks this.
func TestChunkHeaderFrameIsIdentifiable(t *testing.T) {
	frames, err := Chunk(randomBytes(t, 32*1024))
	if err != nil {
		t.Fatalf("Chunk: %v", err)
	}
	if len(frames) < 2 {
		t.Fatalf("want a multi-frame message, got %d frames", len(frames))
	}

	for i, frame := range frames {
		header := isHeaderFrame(frame)
		if i == 0 && !header {
			t.Errorf("frame 0 byte 4 is %#02x, want < 0x80 so it reads as the header frame", frame[4])
		}
		if i > 0 {
			if header {
				t.Errorf("frame %d byte 4 is %#02x, colliding with the header frame's range", i, frame[4])
			}
			if frame[4] < 0xC2 || frame[4] > 0xDF {
				t.Errorf("frame %d byte 4 is %#02x, outside the 0xC2..0xDF utf-8 lead byte range", i, frame[4])
			}
		}
	}
}

// Marker 1 is never issued, so a lost header frame is detected rather than
// letting the last frame be mistaken for it.
func TestDechunkRejectsMissingHeaderFrame(t *testing.T) {
	frames, err := Chunk(randomBytes(t, 32*1024))
	if err != nil {
		t.Fatalf("Chunk: %v", err)
	}
	if len(frames) < 2 {
		t.Fatalf("want a multi-frame message, got %d frames", len(frames))
	}

	if _, err := dechunk(frames[1:]); err == nil {
		t.Error("dechunk accepted a message with no header frame")
	}
}

// Chunk emits frames already in order, so an unshuffled set must map each frame
// straight to its own index.
func TestChunkEmitsFramesInPositionOrder(t *testing.T) {
	frames, err := Chunk(randomBytes(t, 32*1024))
	if err != nil {
		t.Fatalf("Chunk: %v", err)
	}
	p := mustDechunk(t, frames)

	for i, pos := range p.position {
		if pos != i {
			t.Errorf("frame %d resolved to position %d", i, pos)
		}
	}
}

func TestChunkFlags(t *testing.T) {
	const (
		flagCompressed = 1 << 1
		flagBase128    = 1 << 0
	)

	cases := []struct {
		name string
		data []byte
		want byte
	}{
		{"compressible utf-8 is compressed and encoded", compressible(64 * 1024), flagCompressed | flagBase128},
		{"incompressible binary is encoded only", randomBytes(t, 64*1024), flagBase128},
		{"short utf-8 is sent raw", []byte("shoes"), 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frames, err := Chunk(tc.data)
			if err != nil {
				t.Fatalf("Chunk: %v", err)
			}
			if got := mustDechunk(t, frames).flags; got != tc.want {
				t.Errorf("flags = %#02x, want %#02x", got, tc.want)
			}
		})
	}
}

func TestChunkPayloadIsUtf8Safe(t *testing.T) {
	cases := map[string][]byte{
		"multibyte raw":  multibyteText(t, 20000),
		"encoded binary": randomBytes(t, 64*1024),
		"compressible":   compressible(256 * 1024),
	}

	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			frames, err := Chunk(data)
			if err != nil {
				t.Fatalf("Chunk: %v", err)
			}
			for i, frame := range frames {
				payload := frame[headerSize:]
				if i == 0 {
					payload = frame[initalHeaderSize:]
				}
				if len(payload) > 0 && !utf8.RuneStart(payload[0]) {
					t.Errorf("frame %d payload starts mid-rune (% x)", i, payload[0])
				}
				if !utf8.Valid(frame) {
					t.Errorf("frame %d is not valid utf-8, so it cannot survive the Roblox transport", i)
				}
			}
		})
	}
}

func TestChunkRejectsOversizedMessages(t *testing.T) {
	// Incompressible, so base128 expansion pushes it past maxChunks frames.
	data := randomBytes(t, maxChunks*payloadSize)
	if _, err := Chunk(data); err == nil {
		t.Fatalf("Chunk accepted a message needing more than %d frames", maxChunks)
	}
}

func TestChunkMessageIDsDiffer(t *testing.T) {
	seen := make(map[string]bool, 32)
	for range 32 {
		frames, err := Chunk([]byte("shoes"))
		if err != nil {
			t.Fatalf("Chunk: %v", err)
		}
		id := string(mustDechunk(t, frames).messageID)
		if seen[id] {
			t.Errorf("message id % x reused across messages", id)
		}
		seen[id] = true
	}
}
