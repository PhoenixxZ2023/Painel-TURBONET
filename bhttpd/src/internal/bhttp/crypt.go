package bhttp

import (
	"crypto/sha256"
	"encoding/binary"
)

// Crypt aplica/remove a ofuscação BHTTP: XOR contra um keystream de blocos
// de 32 bytes, cada bloco = SHA-256(sid[16] || mode(1) || sequence(8, BE) ||
// responseFlag(1) || blockCounter(4, BE)). Simétrico: a mesma função cifra e
// decifra (mesmos parâmetros nos dois lados produzem o mesmo keystream).
func Crypt(input []byte, sid [SIDSize]byte, mode byte, sequence int64, response bool) []byte {
	out := make([]byte, len(input))
	seed := make([]byte, 30)
	copy(seed[0:16], sid[:])
	seed[16] = mode
	binary.BigEndian.PutUint64(seed[17:25], uint64(sequence))
	if response {
		seed[25] = 1
	} else {
		seed[25] = 0
	}

	block := uint32(0)
	offset := 0
	for offset < len(input) {
		binary.BigEndian.PutUint32(seed[26:30], block)
		block++
		key := sha256.Sum256(seed)
		count := len(input) - offset
		if count > 32 {
			count = 32
		}
		for i := 0; i < count; i++ {
			out[offset+i] = input[offset+i] ^ key[i]
		}
		offset += count
	}
	return out
}
