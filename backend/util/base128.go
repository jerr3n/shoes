package util

import "slices"

func Encode(data []byte) []byte {
	if len(data) == 0 {
		return nil
	}

	bits := make([]bool, 0, len(data)*8)
	for _, b := range data {
		var evil [8]bool
		for i := 0; i < 8; i++ {
			evil[i] = (b>>(7-i))&1 == 1
		}
		bits = append(bits, evil[:]...)
	}

	var chunks [][]bool
	for chunk := range slices.Chunk(bits, 7) {
		chunks = append(chunks, chunk)
	}
	last := chunks[len(chunks)-1]
	if len(last) < 7 {
		chunks[len(chunks)-1] = append(last, make([]bool, 7-len(last))...)
	}
	out := make([]byte, 0, len(chunks))
	for _, chunk := range chunks {
		var v byte
		for i, bit := range chunk {
			if bit {
				v |= 1 << (6 - i)
			}
		}
		out = append(out, v)
	}
	return out
}
