package util

import (
	"bytes"
	"crypto/rand"
	"unicode/utf8"
)

// Quad I stor e data in what i like to call a quad
// a quad is 4 bytes of VALID utf-8
type Quad [4]byte

func pack(bits [8]bool) byte {
	var b byte
	for i, v := range bits {
		if v {
			b |= 1 << (7 - i)
		}
	}
	return b
}

// we have 383,270,912 possible VALID random utf-8 message IDs
// we have 1920 packets that are able to be sent
// we have from 0x0080 to 0x07FF

type Flags struct {
	Compressed bool
	Base128    bool
	Result     byte
}

func (f *Flags) ProduceResult() {
	var byteArray [8]bool
	byteArray[6] = f.Compressed
	byteArray[7] = f.Base128
	f.Result = pack(byteArray)
}

type Header struct {
	Crc32     []byte
	MessageID *Quad
	Flags     Flags
}

// the go documentation did not consider the complexity this is for.

func (h *Header) ProduceMessageID() error {
	b := make([]byte, 4)
	for {
		if _, err := rand.Read(b); err != nil {
			return err
		}
		if utf8.Valid(b) {
			ptr := Quad(b)
			h.MessageID = &ptr
			return nil
		}
	}
}

func (h Header) ProduceFirstHeader(total int) []byte {
	h.Flags.ProduceResult()
	var buf bytes.Buffer
	buf.Grow(initalHeaderSize)
	buf.Write(h.MessageID[:])
	buf.Write(h.Crc32[:])
	buf.WriteRune(rune(0x0080 + total))
	buf.WriteByte(h.Flags.Result)
	return buf.Bytes()
}

func (h Header) ProduceHeader(num int) []byte {
	h.Flags.ProduceResult()

	var buf bytes.Buffer
	buf.Grow(headerSize)
	buf.Write(h.MessageID[:])
	buf.WriteRune(rune(0x0080 + num))
	return buf.Bytes()
}
