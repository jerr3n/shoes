package util

import (
	"errors"
	"fmt"
	"hash/crc32"
)

// Wire format:
//
//	chunk 0:  II NN CCCCCCCC <payload...>   (12-byte header, <=1012 bytes of payload)
//	chunk i:  II <payload...>               ( 2-byte header, <=1022 bytes of payload)
//
// II = chunk index, NN = total chunk count, CCCCCCCC = CRC-32/ISO-HDLC of the
// whole payload. All header fields are lowercase ASCII hex.
const (
	limit = 1024
	first = limit - 2 - 2 - 8 // 1012, chunk 0 pays for count + crc
	rest  = limit - 2 - 8     // 1022
)

func Chunk(s []byte) ([][]byte, error) {
	if len(s) == 0 {
		return nil, errors.New("empty payload")
	}
	sum := crc32.ChecksumIEEE(s)

	n := 1
	if len(s) > first {
		n += (len(s) - first + rest - 1) / rest // ceil of the remainder
	}
	if n > 255 {
		return nil, fmt.Errorf("payload needs %d chunks, max is 255", n)
	}

	out := make([][]byte, n)
	for i := range out {
		var header string
		start, capacity := 0, first

		if i == 0 {
			header = fmt.Sprintf("%02x%02x%08x", i, n, sum)
		} else {
			start, capacity = first+(i-1)*rest, rest
			header = fmt.Sprintf("%02x", i)
		}

		end := min(start+capacity, len(s))

		c := make([]byte, 0, len(header)+end-start)
		c = append(c, header...)
		c = append(c, s[start:end]...)
		out[i] = c
	}
	return out, nil
}
