package bhttp

import (
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// Session representa uma sessão SSH_BHTTP em andamento: uma conexão TCP já
// aberta para o sshd real do sistema (backend), mais os buffers de
// reordenação de upload (cliente -> servidor -> sshd) e de produção de
// download (sshd -> servidor -> cliente).
//
// O netsimon-bhttpd NÃO fala SSH: ele só entrega bytes, em ordem, nos dois
// sentidos. Quem autentica e criptografa a sessão SSH de verdade são o
// cliente (biblioteca SSH do app) e o sshd do sistema operacional — exatamente
// como "auth.system" já documentava.
type Session struct {
	SID  [SIDSize]byte
	Addr string // origem da primeira requisição, só para log

	backend net.Conn

	mu           sync.Mutex
	closed       bool
	lastActivity time.Time
	maxBuffered  int

	// --- upload (cliente -> backend) ---
	uploadNext    int64
	uploadPending map[int64][]byte
	uploadCond    *sync.Cond
	registered    bool      // recebeu o registro vazio (seq 0)
	regSince      time.Time // quando o registro chegou (p/ pular seq 0 vazio)

	// --- download (backend -> cliente) ---
	downloadChunkSize int
	readerStarted     bool
	nextProduce       int64
	backendEOF        bool
	backendErr        error
	chunks            map[int64][]byte
	chunkCond         *sync.Cond

	// --- v1.4.0: modo "crédito por pedido" (ver AwaitSlot) ---
	// credit: o número (seq) de um pedido de download é uma POSIÇÃO ("slot")
	// no fluxo, não o índice do bloco produzido. Cada bloco lido do sshd vai
	// para o pedido que estiver esperando com o menor slot acima de hw (o
	// último slot que recebeu dado), sempre em ordem crescente. Slot que
	// expira vazio é um "buraco" e nunca perde dado, porque o dado seguinte
	// vai para outro slot. Era o oposto antes: bloco N só saía para o slot N.
	credit  bool
	hw      int64         // maior slot que já recebeu dado (-1 = nenhum)
	queue   [][]byte      // blocos lidos do sshd ainda sem slot
	waiting map[int64]int // slots com pedido de download pendurado
}

func NewSession(sid [SIDSize]byte, addr string, maxBuffered int) *Session {
	s := &Session{
		SID:           sid,
		Addr:          addr,
		lastActivity:  time.Now(),
		maxBuffered:   maxBuffered,
		uploadPending: make(map[int64][]byte),
		chunks:        make(map[int64][]byte),
		hw:            -1,
		waiting:       make(map[int64]int),
	}
	s.uploadCond = sync.NewCond(&s.mu)
	s.chunkCond = sync.NewCond(&s.mu)
	return s
}

func (s *Session) touch() {
	s.mu.Lock()
	s.lastActivity = time.Now()
	s.mu.Unlock()
}

func (s *Session) IdleFor() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.lastActivity)
}

// AttachBackend conecta ao sshd real e sobe o writer de upload (o reader de
// download só sobe quando soubermos o tamanho de chunk, no primeiro BATCH).
func (s *Session) AttachBackend(conn net.Conn) {
	s.backend = conn
	go s.uploadWriterLoop()
}

// PushUpload entrega um frame de upload já decifrado, na sequência
// informada; frames fora de ordem ficam retidos até o(s) anterior(es)
// chegar(em) — mesma técnica de reordenação usada no lado download do
// cliente, espelhada aqui para o sentido contrário.
func (s *Session) PushUpload(sequence int64, clear []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastActivity = time.Now()
	if sequence < s.uploadNext {
		return // já processado (retransmissão/duplicata) — ignora
	}
	s.uploadPending[sequence] = clear
	s.uploadCond.Broadcast()
}

// MarkRegistered: o cliente mandou o registro (seq 0, corpo vazio).
func (s *Session) MarkRegistered() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastActivity = time.Now()
	if !s.registered {
		s.registered = true
		s.regSince = time.Now()
	}
	// acorda o writer: ele pode estar esperando um seq 0 que não vem
	s.uploadCond.Broadcast()
	go func() {
		time.Sleep(uploadSkipGrace + 50*time.Millisecond)
		s.mu.Lock()
		s.uploadCond.Broadcast()
		s.mu.Unlock()
	}()
}

// uploadSkipGrace: versões do app que usam o registro vazio em seq 0 e
// mandam os dados a partir do seq 1 deixariam o writer esperando um seq 0
// que nunca chega. Se o registro chegou, existem dados pendentes com seq>=1
// e nenhum seq 0 apareceu dentro dessa janela, o seq 0 é dado como
// consumido pelo registro. (Se o app mandar dados JÁ no seq 0, eles chegam
// em milissegundos e essa regra nunca dispara.)
const uploadSkipGrace = 1 * time.Second

func (s *Session) uploadWriterLoop() {
	s.mu.Lock()
	for {
		if s.closed {
			s.mu.Unlock()
			return
		}
		chunk, ok := s.uploadPending[s.uploadNext]
		if !ok {
			if s.uploadNext == 0 && s.registered && len(s.uploadPending) > 0 &&
				time.Since(s.regSince) >= uploadSkipGrace {
				log.Printf("bhttp: sessão %s: seq 0 só existiu como registro vazio — dados começam no seq 1", hexShort(s.SID))
				s.uploadNext = 1
				continue
			}
			s.uploadCond.Wait()
			continue
		}
		delete(s.uploadPending, s.uploadNext)
		s.uploadNext++
		s.mu.Unlock()

		if len(chunk) > 0 {
			if _, err := s.backend.Write(chunk); err != nil {
				log.Printf("bhttp: sessão %s: erro escrevendo no backend: %v", hexShort(s.SID), err)
				s.Close()
				return
			}
		}
		s.mu.Lock()
	}
}

// EnsureDownloadReader inicia (uma única vez por sessão) a goroutine que lê
// do backend e vai fatiando o stream em chunks de chunkSize bytes, na ordem
// real de produção — é o valor que o cliente informa no primeiro BATCH após
// a calibração, e vale para o resto da sessão.
func (s *Session) EnsureDownloadReader(chunkSize int, credit bool) {
	s.mu.Lock()
	if s.readerStarted {
		s.mu.Unlock()
		return
	}
	s.readerStarted = true
	s.credit = credit
	s.downloadChunkSize = chunkSize
	s.mu.Unlock()
	go s.downloadReaderLoop(chunkSize)
}

func (s *Session) downloadReaderLoop(chunkSize int) {
	buf := make([]byte, chunkSize)
	for {
		// Bloqueia até pelo menos 1 byte chegar (sem prazo — sessão
		// interativa pode ficar ociosa por bastante tempo entre pacotes).
		s.backend.SetReadDeadline(time.Time{})
		n, err := s.backend.Read(buf)
		if n > 0 {
			// Pequena janela de coalescência: junta bytes que cheguem logo
			// em seguida antes de fechar o chunk, reduzindo overhead sem
			// segurar demais um pacote pequeno e interativo.
			s.backend.SetReadDeadline(time.Now().Add(5 * time.Millisecond))
			total := n
			for total < len(buf) {
				more, err2 := s.backend.Read(buf[total:])
				if more > 0 {
					total += more
					continue
				}
				if err2 != nil {
					break
				}
			}
			chunk := make([]byte, total)
			copy(chunk, buf[:total])

			if s.credit {
				if !s.produceCredit(chunk) {
					return
				}
			} else {
				s.produceLegacy(chunk)
			}
		}
		if err != nil {
			s.mu.Lock()
			s.backendEOF = true
			s.backendErr = err
			s.chunkCond.Broadcast()
			s.mu.Unlock()
			return
		}
	}
}

// produceLegacy: esquema antigo — bloco N sai para o pedido de seq N.
func (s *Session) produceLegacy(chunk []byte) {
	s.mu.Lock()
	idx := s.nextProduce
	s.nextProduce++
	if len(s.chunks) >= s.maxBuffered {
		// Sessão travada / cliente muito atrasado no ACK — descarta
		// o mais antigo em vez de crescer sem limite. Proteção
		// básica de memória; em uso normal o ACK periódico do
		// cliente já libera isso bem antes de chegar aqui.
		var oldest int64 = -1
		for k := range s.chunks {
			if oldest == -1 || k < oldest {
				oldest = k
			}
		}
		if oldest != -1 {
			delete(s.chunks, oldest)
		}
	}
	s.chunks[idx] = chunk
	s.chunkCond.Broadcast()
	s.mu.Unlock()
}

// produceCredit: esquema v1.4.0 — enfileira o bloco e entrega ao menor slot
// esperando acima de hw. Retorna false se a sessão foi encerrada.
func (s *Session) produceCredit(chunk []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Contrapressão: blocos demais sem pedido para levá-los -> para de ler do
	// sshd (o TCP do sshd segura o resto). Nunca descarta dado neste modo.
	for !s.closed && len(s.queue) >= s.maxBuffered {
		s.chunkCond.Wait()
	}
	if s.closed {
		return false
	}
	s.queue = append(s.queue, chunk)
	s.assignLocked()
	return true
}

// AwaitChunk espera (até deadline) o chunk de índice absoluto idx ficar
// disponível. Retorna (dados, true) se disponível, (nil, false) se o prazo
// expirou sem dado ainda, ou (nil, false) com eof=true se o backend já
// encerrou e esse índice nunca vai existir.
func (s *Session) AwaitChunk(idx int64, deadline time.Time) (data []byte, eof bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		if chunk, ok := s.chunks[idx]; ok {
			return chunk, false
		}
		if (s.backendEOF || s.closed) && idx >= s.nextProduce {
			return nil, true
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, false
		}
		waitCh := make(chan struct{})
		timer := time.AfterFunc(remaining, func() {
			s.mu.Lock()
			s.chunkCond.Broadcast()
			s.mu.Unlock()
			close(waitCh)
		})
		s.chunkCond.Wait()
		timer.Stop()
		select {
		case <-waitCh:
		default:
		}
	}
}

// assignLocked entrega blocos da fila aos pedidos pendurados: cada bloco vai
// para o menor slot esperando que seja maior que hw. Chamar com s.mu preso.
func (s *Session) assignLocked() {
	assigned := false
	for len(s.queue) > 0 {
		best := int64(-1)
		for w := range s.waiting {
			if w > s.hw && (best < 0 || w < best) {
				best = w
			}
		}
		if best < 0 {
			break
		}
		s.chunks[best] = s.queue[0]
		s.queue[0] = nil
		s.queue = s.queue[1:]
		s.hw = best
		assigned = true
	}
	if assigned {
		s.chunkCond.Broadcast()
	}
}

// AwaitSlot (modo crédito) responde ao pedido de download do slot informado:
//   - slot que já tem bloco atribuído (retransmissão de resposta perdida):
//     devolve o MESMO bloco;
//   - slot <= hw sem bloco: buraco, devolve vazio na hora (o dado seguinte já
//     foi para um slot maior; nada se perde);
//   - slot > hw: espera até deadline por um bloco; se vier, é o próximo do
//     fluxo; se expirar, vazio (buraco) sem perder nada.
//
// eof=true só quando o sshd encerrou, não resta bloco na fila e o slot ainda
// poderia receber dado.
func (s *Session) AwaitSlot(slot int64, deadline time.Time) (data []byte, eof bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	registered := false
	var timer *time.Timer
	defer func() {
		if registered {
			if s.waiting[slot]--; s.waiting[slot] <= 0 {
				delete(s.waiting, slot)
			}
		}
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		if c, ok := s.chunks[slot]; ok {
			return c, false
		}
		if s.closed {
			return nil, true
		}
		if slot <= s.hw {
			return nil, false
		}
		if s.backendEOF && len(s.queue) == 0 {
			return nil, true
		}
		if !registered {
			s.waiting[slot]++
			registered = true
			s.assignLocked()
			continue
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, false
		}
		if timer == nil {
			timer = time.AfterFunc(remaining, func() {
				s.mu.Lock()
				s.chunkCond.Broadcast()
				s.mu.Unlock()
			})
		}
		s.chunkCond.Wait()
	}
}

// Ack libera da memória todos os chunks com índice < seq (o cliente já
// confirmou tê-los recebido e reordenado do lado dele).
func (s *Session) Ack(seq int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastActivity = time.Now()
	for k := range s.chunks {
		if k < seq {
			delete(s.chunks, k)
		}
	}
}

func (s *Session) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()
	if s.backend != nil {
		s.backend.Close()
	}
	s.uploadCond.Broadcast()
	s.chunkCond.Broadcast()
}

func (s *Session) Closed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

var errSessionClosed = errors.New("bhttp: sessão encerrada")

func hexShort(sid [SIDSize]byte) string {
	const hextable = "0123456789abcdef"
	out := make([]byte, 8)
	for i := 0; i < 4; i++ {
		out[i*2] = hextable[sid[i]>>4]
		out[i*2+1] = hextable[sid[i]&0xf]
	}
	return string(out)
}

var _ = io.EOF // mantém import io usado mesmo se o uso direto mudar
