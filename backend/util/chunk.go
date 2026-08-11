package util

import (
	"errors"
	"fmt"
	"hash/crc32"
)

// Wire format, mirroring roblox/src/server/chunk.luau:
//
//	every frame: II NN CCCCCCCC <payload...>   (12-byte header, 1012 bytes of payload)
//
// II = chunk index (zero based), NN = total chunk count, CCCCCCCC = CRC-32/
// ISO-HDLC of the whole padded payload. All header fields are ASCII hex.
//
// The header is repeated on every frame rather than living on frame 0 alone, so
// the reader can validate any frame it receives in isolation and does not have
// to have seen frame 0 first. Frames are all exactly frameSize bytes; the last
// one is zero padded to fill.
//
// TODO: the frame carries no payload length, so the reader cannot tell the
// padding on the final chunk from real trailing NUL bytes -- the checksum below
// covers the padding, so it agrees with the reader either way and will not
// catch it. Same TODO as the Luau side: pick padding or a length field before
// this leaves draft.
const (
	frameSize   = 1024
	headerSize  = 12
	payloadSize = frameSize - headerSize // 1012
	maxChunks   = 255                    // NN is two hex digits
)

func Chunk(s []byte) ([][]byte, error) {
	if len(s) == 0 {
		return nil, errors.New("empty payload")
	}

	n := (len(s) + payloadSize - 1) / payloadSize // ceil
	if n > maxChunks {
		return nil, fmt.Errorf("payload needs %d chunks, max is %d", n, maxChunks)
	}

	// pad up front so the checksum covers exactly the bytes the reader
	// recomposes, padding included
	padded := make([]byte, n*payloadSize)
	copy(padded, s)
	sum := crc32.ChecksumIEEE(padded)

	out := make([][]byte, n)
	for i := range out {
		c := make([]byte, 0, frameSize)
		c = append(c, fmt.Sprintf("%02x%02x%08x", i, n, sum)...)
		c = append(c, padded[i*payloadSize:(i+1)*payloadSize]...)
		out[i] = c
	}
	return out, nil
}
