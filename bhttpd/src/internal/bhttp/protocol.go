// Package bhttp implementa, do zero, o protocolo de transporte BHTTP usado
// pelos apps NETSIMON no modo de conexão SSH_BHTTP: um encapsulamento
// binário de uma sessão SSH dentro de requisições TCP curtas para a porta
// 80/443, com fragmentação em janelas paralelas e uma camada de ofuscação
// própria (XOR contra um keystream derivado de SHA-256).
//
// Especificação do protocolo obtida por engenharia reversa da própria
// infraestrutura/app NETSIMON (ver documentação do projeto). Esta é uma
// implementação NOVA e independente — não deriva de nenhum binário ou
// código-fonte de terceiros.
package bhttp

import (
	"encoding/binary"
	"errors"
)

// Modo da requisição (primeiro byte do frame).
const (
	ModeProbe    = 0
	ModeUpload   = 1
	ModeDownload = 2
	ModeBatch    = 3
	ModeAck      = 4
)

// Status da resposta (primeiro byte da resposta).
const (
	StatusOK   = 0
	StatusData = 2
	StatusErr  = 1
)

const (
	SIDSize        = 16
	BatchCount     = 8
	MaxRequestBody = 2 * 1024 * 1024
	MaxResponseLen = 2 * 1024 * 1024

	// MaxDownloadEnvelope é o teto do envelope de download aceito no modo 2
	// (e na sondagem de download): 131072 bytes. Valor medido no servidor
	// DTunnel v3.2.0 (aceita 131072, recusa 131073). Acima disso o app
	// calibrava para 1399 bytes (lento) — ver diagnóstico BHP1.
	MaxDownloadEnvelope = 131072

	// ProbeMagic abre o payload decifrado do modo 0 (sondagem):
	// "BHP1" + versão(1) + submodo(1) + parâmetro(4) + enchimento.
	ProbeMagic = "BHP1"
)

var (
	ErrFrameTooLarge = errors.New("bhttp: corpo do frame excede o limite")
	ErrShortSID      = errors.New("bhttp: SID com tamanho inválido")
)

// RequestHeader é o cabeçalho de 29 bytes: mode(1) + sid(16) + sequence(8) + length(4).
type RequestHeader struct {
	Mode     byte
	SID      [SIDSize]byte
	Sequence int64
	Length   uint32
}

func EncodeRequestHeader(h RequestHeader) []byte {
	buf := make([]byte, 1+SIDSize+8+4)
	buf[0] = h.Mode
	copy(buf[1:1+SIDSize], h.SID[:])
	binary.BigEndian.PutUint64(buf[1+SIDSize:1+SIDSize+8], uint64(h.Sequence))
	binary.BigEndian.PutUint32(buf[1+SIDSize+8:], h.Length)
	return buf
}

func DecodeRequestHeader(buf []byte) (RequestHeader, error) {
	var h RequestHeader
	if len(buf) != 1+SIDSize+8+4 {
		return h, errors.New("bhttp: cabeçalho de requisição com tamanho inválido")
	}
	h.Mode = buf[0]
	copy(h.SID[:], buf[1:1+SIDSize])
	h.Sequence = int64(binary.BigEndian.Uint64(buf[1+SIDSize : 1+SIDSize+8]))
	h.Length = binary.BigEndian.Uint32(buf[1+SIDSize+8:])
	return h, nil
}

// EncodeResponseFrame monta status(1) + length(4) + body.
func EncodeResponseFrame(status byte, body []byte) []byte {
	out := make([]byte, 1+4+len(body))
	out[0] = status
	binary.BigEndian.PutUint32(out[1:5], uint32(len(body)))
	copy(out[5:], body)
	return out
}
