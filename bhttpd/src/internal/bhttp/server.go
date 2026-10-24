package bhttp

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

const (
	requestReadTimeout = 10 * time.Second
	slotWaitTimeout    = 8 * time.Second

	// Corpo de texto que acompanha todo status 1 (erro) — o app registra
	// isso no log e o diagnóstico fica muito mais fácil.
	msgSessionExpired = "session expired"
)

type BackendDialer func() (net.Conn, error)

type Server struct {
	dial         BackendDialer
	maxBuffered  int
	idleTimeout  time.Duration
	downloadWait time.Duration
	debug        bool

	// v1.3.0
	retainChunks int           // chunks já entregues mantidos p/ retransmissão
	slotCredit   bool          // v1.4.0: download por crédito (padrão) ou índice absoluto (legado)
	keepAlive    time.Duration // 0 = uma requisição por conexão

	mu       sync.Mutex
	sessions map[[SIDSize]byte]*Session
}

func NewServer(dial BackendDialer, maxBuffered int, idleTimeout time.Duration, downloadWait time.Duration, debug bool) *Server {
	s := &Server{
		dial:         dial,
		maxBuffered:  maxBuffered,
		idleTimeout:  idleTimeout,
		downloadWait: downloadWait,
		debug:        debug,
		sessions:     make(map[[SIDSize]byte]*Session),
		retainChunks: 256,
		slotCredit:   true,
	}
	go s.reapLoop()
	return s
}

// SetRetainChunks define o teto de chunks entregues mantidos para retry.
func (s *Server) SetRetainChunks(n int) {
	if n < 32 {
		n = 32
	}
	s.retainChunks = n
}

// SetSlotCredit escolhe o esquema de download: true (padrão) = crédito por
// pedido, sem perda de dado em pausas; false = índice absoluto (v1.2/v1.3).
func (s *Server) SetSlotCredit(on bool) { s.slotCredit = on }

// SetKeepAlive liga a conexão persistente (d > 0) ou desliga (d == 0).
func (s *Server) SetKeepAlive(d time.Duration) {
	if d < 0 {
		d = 0
	}
	s.keepAlive = d
}

func (s *Server) reapLoop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for range t.C {
		s.mu.Lock()
		for sid, sess := range s.sessions {
			// Sessão fechada fica mais um pouco no mapa (60s) para que os
			// pedidos em voo recebam "session expired" em vez de recriar
			// uma sessão nova por engano.
			if sess.IdleFor() > s.idleTimeout || (sess.Closed() && sess.IdleFor() > 60*time.Second) {
				sess.Close()
				delete(s.sessions, sid)
			}
		}
		s.mu.Unlock()
	}
}

func (s *Server) getSession(sid [SIDSize]byte) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[sid]
}

func (s *Server) getOrCreateSession(sid [SIDSize]byte, addr string) (*Session, error) {
	s.mu.Lock()
	if sess, ok := s.sessions[sid]; ok {
		s.mu.Unlock()
		return sess, nil
	}
	s.mu.Unlock()

	conn, err := s.dial()
	if err != nil {
		return nil, fmt.Errorf("conectando ao backend: %w", err)
	}
	sess := NewSession(sid, addr, s.maxBuffered)
	sess.AttachBackend(conn)

	s.mu.Lock()
	// Corrida rara: outra conexão registrou primeiro. Descarta a nossa.
	if existing, ok := s.sessions[sid]; ok {
		s.mu.Unlock()
		sess.Close()
		return existing, nil
	}
	s.sessions[sid] = sess
	s.mu.Unlock()
	return sess, nil
}

// HandleConn atende a conexão. Com keepAlive desligado (padrão) processa
// exatamente UMA requisição e fecha (comportamento original). Com keepAlive
// ligado, repete o ciclo leitura -> resposta na mesma conexão até o cliente
// fechar ou ficar ocioso por mais de keepAlive. O framing é por tamanho
// (status + length + corpo), então o cliente sabe onde cada resposta termina.
func (s *Server) HandleConn(conn net.Conn) {
	defer conn.Close()
	addr := conn.RemoteAddr().String()
	first := true

	for {
		// Espera ociosa só pelo 1º byte (prazo de keep-alive nas requisições
		// seguintes); depois o corpo tem o prazo normal de requisição, para um
		// upload lento não ser cortado pelo prazo de ociosidade.
		if first {
			conn.SetReadDeadline(time.Now().Add(requestReadTimeout))
		} else {
			conn.SetReadDeadline(time.Now().Add(s.keepAlive))
		}
		var b0 [1]byte
		if _, err := io.ReadFull(conn, b0[:]); err != nil {
			return // sondagem/lixo/ocioso/cliente fechou — descarta sem log
		}
		first = false
		conn.SetReadDeadline(time.Now().Add(requestReadTimeout))
		header, payload, err := readRequest(io.MultiReader(bytes.NewReader(b0[:]), conn))
		if err != nil {
			return
		}
		conn.SetReadDeadline(time.Time{})
		if s.debug {
			log.Printf("bhttp[debug]: %s modo=%d sid=%s seq=%d length=%d payload=%d", addr, header.Mode, hexShort(header.SID), header.Sequence, header.Length, len(payload))
		}

		switch header.Mode {
		case ModeProbe:
			s.handleProbe(conn, header, payload)
		case ModeUpload:
			s.handleUpload(conn, header, payload, addr)
		case ModeDownload:
			s.handleDownload(conn, header, addr)
		case ModeBatch:
			s.handleBatch(conn, header, payload)
		case ModeAck:
			s.handleAck(conn, header)
		default:
			writeError(conn, "unknown mode")
			return
		}
		if s.keepAlive <= 0 {
			return
		}
	}
}

// readRequest lê o cabeçalho de 29 bytes e o payload. No modo 2 (download)
// o campo length NÃO é tamanho de payload — é o tamanho máximo da
// resposta, e o pacote tem só os 29 bytes do cabeçalho.
func readRequest(conn io.Reader) (RequestHeader, []byte, error) {
	headerBuf := make([]byte, 1+SIDSize+8+4)
	if _, err := io.ReadFull(conn, headerBuf); err != nil {
		return RequestHeader{}, nil, err
	}
	header, err := DecodeRequestHeader(headerBuf)
	if err != nil {
		return RequestHeader{}, nil, err
	}
	if header.Mode == ModeDownload || header.Mode == ModeAck {
		// download: length = envelope máximo, sem payload.
		// ack: só cabeçalho (sequence = confirmado até aqui).
		return header, nil, nil
	}
	if header.Length > MaxRequestBody {
		return RequestHeader{}, nil, ErrFrameTooLarge
	}
	payload := make([]byte, header.Length)
	if header.Length > 0 {
		if _, err := io.ReadFull(conn, payload); err != nil {
			return RequestHeader{}, nil, err
		}
	}
	return header, payload, nil
}

func writeResponse(conn net.Conn, status byte, body []byte) {
	_, _ = conn.Write(EncodeResponseFrame(status, body))
}

// writeError: status 1 sempre com um texto no corpo (não cifrado).
func writeError(conn net.Conn, msg string) {
	writeResponse(conn, StatusErr, []byte(msg))
}

// --- PROBE (modo 0). Comportamento medido no servidor antigo (netsimon-bhttp,
// DTunnel) com o app real: payload decifrado = "BHP1" + versão(1) + submodo(1)
// + parâmetro(4), sempre 10 bytes vindos do app.
//   - submodo 2 (download): o servidor responde com EXATAMENTE `parâmetro`
//     bytes: os 10 primeiros = eco do payload, e dali em diante o padrão
//     byte[i] = (i*31) & 0xFF pela posição absoluta i. O app usa isso para
//     calibrar o envelope de download (tenta 17892, 16388, 12292... e desce
//     enquanto a resposta não tiver o tamanho pedido).
//     parâmetro < 10      -> status 1, "invalid BHTTP v1 probe size"
//     parâmetro > 131072  -> status 1, "probe response exceeds server limit"
//     (medido: 131072 aceito, 131076 recusado; os
//     valores 131073..131075 não foram testados)
//   - demais submodos (0 registro, 1 upload, 3 batch, 4 ack): o servidor
//     responde SÓ com os 10 primeiros bytes do payload (o cabeçalho
//     "BHP1"+versão+submodo+parâmetro), NUNCA com o payload inteiro.
//     Medido no antigo com o app real: probes de upload de 4096,
//     8192, 12288 e 16384 bytes recebem resposta de exatamente 10 bytes.
//     Se o servidor devolver o eco completo, o app considera o tamanho
//     recusado e calibra o upload para 10 bytes (lentidão extrema).
//     O antigo recusa ACK (submodo 4) com parâmetro 1 e 373; aqui isso
//     continua NÃO sendo replicado (decisão anterior do projeto: não
//     derrubar apps antigos).
//
// Payload sem o magic "BHP1" (ou curto demais) é ecoado sem validar. ---
const probeMinSize = 10

func probePadding(n int, clear []byte) []byte {
	body := make([]byte, n)
	for i := 0; i < n; i++ {
		if i < probeMinSize && i < len(clear) {
			body[i] = clear[i]
		} else {
			body[i] = byte(i * 31)
		}
	}
	return body
}

func (s *Server) handleProbe(conn net.Conn, header RequestHeader, payload []byte) {
	clear := Crypt(payload, header.SID, ModeProbe, header.Sequence, false)
	result := clear
	if len(clear) >= probeMinSize && string(clear[:4]) == ProbeMagic {
		submode := clear[5]
		param := binary.BigEndian.Uint32(clear[6:10])
		if submode == ModeDownload {
			if param < probeMinSize {
				writeError(conn, "invalid BHTTP v1 probe size")
				return
			}
			if param > MaxDownloadEnvelope {
				writeError(conn, "probe response exceeds server limit")
				return
			}
			result = probePadding(int(param), clear)
		} else {
			// v1.2.3: eco só do cabeçalho de 10 bytes (ver comentário acima).
			result = clear[:probeMinSize]
		}
	}
	encoded := Crypt(result, header.SID, ModeProbe, header.Sequence, true)
	writeResponse(conn, StatusOK, encoded)
}

// --- UPLOAD (modo 1). O registro de sessão (sequence 0 + corpo vazio) é
// aceito mas NÃO é obrigatório: qualquer upload de sessão desconhecida cria a
// sessão (o servidor de referência se comporta assim — upload seq 0 já com
// dados entrega o banner ao sshd). Sequência fora de ordem fica retida
// esperando as anteriores, em silêncio. ---
func (s *Server) handleUpload(conn net.Conn, header RequestHeader, payload []byte, addr string) {
	sess, err := s.getOrCreateSession(header.SID, addr)
	if err != nil {
		log.Printf("bhttp: sessão nova falhou (%s): %v", addr, err)
		writeError(conn, "backend unavailable")
		return
	}
	if sess.Closed() {
		writeError(conn, msgSessionExpired)
		return
	}
	if header.Sequence == 0 && len(payload) == 0 {
		sess.MarkRegistered()
		writeResponse(conn, StatusOK, nil)
		return
	}
	clear := Crypt(payload, header.SID, ModeUpload, header.Sequence, false)
	sess.PushUpload(header.Sequence, clear)
	writeResponse(conn, StatusOK, nil)
}

// --- DOWNLOAD (modo 2): uma resposta por requisição.
// Requisição: só cabeçalho; length = tamanho máximo da resposta.
// Resposta: status 0 + length + corpo cifrado bruto (modo da cifra = 2,
// responseFlag = 1), SEM prefixo de 4 bytes. Corpo vazio = sem dados nesse
// seq ainda. Seq = índice absoluto do chunk na ordem de produção. ---
func (s *Server) handleDownload(conn net.Conn, header RequestHeader, addr string) {
	if header.Length == 0 || header.Length > MaxDownloadEnvelope {
		writeError(conn, "invalid envelope")
		return
	}
	sess := s.getSession(header.SID)
	if sess == nil || sess.Closed() {
		writeError(conn, msgSessionExpired)
		return
	}
	sess.EnsureDownloadReader(int(header.Length), s.slotCredit)
	// v1.3.0: download também conta como atividade (antes só upload/ACK),
	// senão uma sessão só-leitura longa podia ser coletada pelo reaper.
	sess.touch()

	deadline := time.Now().Add(s.downloadWait)
	var data []byte
	var eof bool
	if s.slotCredit {
		data, eof = sess.AwaitSlot(header.Sequence, deadline)
	} else {
		data, eof = sess.AwaitChunk(header.Sequence, deadline)
	}
	if eof {
		// sshd encerrou (ex.: lixo no banner, logout) e esse índice nunca
		// vai existir: o app precisa saber que a sessão acabou.
		writeError(conn, msgSessionExpired)
		return
	}
	if data == nil {
		writeResponse(conn, StatusOK, nil) // nada ainda
		return
	}
	cipher := Crypt(data, header.SID, ModeDownload, header.Sequence, true)
	if _, err := conn.Write(EncodeResponseFrame(StatusOK, cipher)); err != nil {
		return
	}
	// Sem ACK do app a memória cresceria sem limite: mantém uma janela de
	// retransmissão. v1.3.0: era fixa em 32 e, com várias conexões de
	// download em paralelo, descartava chunk cuja resposta tinha se perdido
	// e que o app ainda ia pedir de novo (travava a sessão em "vazio").
	if header.Sequence > int64(s.retainChunks) {
		sess.Ack(header.Sequence - int64(s.retainChunks))
	}
}

// --- BATCH (modo 3, LEGADO): janela de até 64 chunks, um frame status 2
// por slot com prefixo de 4 bytes. Mantido para versões antigas do app. ---
func (s *Server) handleBatch(conn net.Conn, header RequestHeader, payload []byte) {
	sess := s.getSession(header.SID)
	if sess == nil || sess.Closed() {
		writeError(conn, msgSessionExpired)
		return
	}
	clear := Crypt(payload, header.SID, ModeBatch, header.Sequence, false)
	if len(clear) < 6 {
		writeError(conn, "invalid batch")
		return
	}
	chunkSize := int(binary.BigEndian.Uint32(clear[0:4]))
	count := int(clear[4])<<8 | int(clear[5])
	if chunkSize <= 0 || chunkSize > MaxResponseLen || count <= 0 || count > 64 {
		writeError(conn, "invalid batch")
		return
	}
	sess.EnsureDownloadReader(chunkSize, false)

	deadline := time.Now().Add(slotWaitTimeout)
	for offset := 0; offset < count; offset++ {
		idx := header.Sequence + int64(offset)
		data, eof := sess.AwaitChunk(idx, deadline)
		if eof || data == nil {
			// eof: índice nunca vai existir; nil: nada disponível ainda
			// nesta janela. Nos dois casos: slot vazio (length=0).
			if err := writeFrame(conn, StatusData, make([]byte, 4)); err != nil {
				return
			}
			continue
		}
		cipher := Crypt(data, header.SID, ModeBatch, idx, true)
		body := make([]byte, 4+len(cipher))
		binary.BigEndian.PutUint32(body[0:4], uint32(len(cipher)))
		copy(body[4:], cipher)
		if err := writeFrame(conn, StatusData, body); err != nil {
			return
		}
	}
}

func writeFrame(conn net.Conn, status byte, body []byte) error {
	conn.SetWriteDeadline(time.Now().Add(slotWaitTimeout))
	_, err := conn.Write(EncodeResponseFrame(status, body))
	return err
}

// --- ACK (modo 4): libera da memória tudo que já foi confirmado. Nunca
// é recusado por parâmetro; sessão desconhecida devolve "session expired". ---
func (s *Server) handleAck(conn net.Conn, header RequestHeader) {
	sess := s.getSession(header.SID)
	if sess == nil {
		writeError(conn, msgSessionExpired)
		return
	}
	sess.Ack(header.Sequence)
	writeResponse(conn, StatusOK, nil)
}
