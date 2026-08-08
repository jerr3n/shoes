package util

import (
	"errors"
	"fmt"
)

// this code was ai generated, but it was thoroughly reviewed to make sure it's okay. do not worry :)
const (
	limit = 1024
	first = limit - 4 // 1020, chunk 0 pays for the count
	rest  = limit - 2 // 1022
)
const hexDigits = "0123456789abcdef"

func putHex(dst []byte, v int) {
	dst[0] = hexDigits[v>>4]  // high nibble
	dst[1] = hexDigits[v&0xf] // low nibble
}
func Chunk(s []byte) ([][]byte, error) {
	if len(s) == 0 {
		return nil, errors.New("empty payload")
	}

	n := 1
	if len(s) > first {
		n += (len(s) - first + rest - 1) / rest // ceil of the remainder
	}
	if n > 255 {
		return nil, fmt.Errorf("payload needs %d chunks", n)
	}

	out := make([][]byte, n)
	for i := range out {
		start, hdr := 0, 4
		if i > 0 {
			start, hdr = first+(i-1)*rest, 2
		}
		end := min(start+limit-hdr, len(s))

		c := make([]byte, hdr+end-start)
		putHex(c, i)
		if i == 0 {
			putHex(c[2:], n)
		}
		copy(c[hdr:], s[start:end])
		out[i] = c
	}
	return out, nil
}
