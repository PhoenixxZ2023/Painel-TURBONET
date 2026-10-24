package bhttp

import (
	"bytes"
	"encoding/binary"
	"io"
	"math/rand"
	"net"
	"sync"
	"testing"
	"time"
)

// Backend que escreve `stream` em rajadas com pausas (inclusive pausas maiores
// que o download_wait do servidor, que nos testes é 400 ms).
func startStreamBackend(t *testing.T, stream []byte, seed int64) BackendDialer {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go io.Copy(io.Discard, c)
		r := rand.New(rand.NewSource(seed))
		for off := 0; off < len(stream); {
			n := 1 + r.Intn(2500)
			if off+n > len(stream) {
				n = len(stream) - off
			}
			c.Write(stream[off : off+n])
			off += n
			switch x := r.Intn(100); {
			case x < 4:
				time.Sleep(900 * time.Millisecond) // pausa > download_wait
			case x < 30:
				time.Sleep(time.Duration(r.Intn(40)) * time.Millisecond)
			}
		}
	}()
	return func() (net.Conn, error) { return net.Dial("tcp", ln.Addr().String()) }
}

// Cliente que imita o BhttpBridge.kt: N threads, thread i pede slots i, i+N...;
// vazio = buraco consumido e a thread avança +N; erro de rede = repete o MESMO
// slot. dropPct simula respostas perdidas (fecha a conexão sem ler).
func runBridgeClient(t *testing.T, addr string, sid [16]byte, n int, want int, dropPct int, limit time.Duration) []byte {
	var mu sync.Mutex
	pending := map[int64][]byte{}
	var nextRead int64
	var got []byte
	done := make(chan struct{})
	var once sync.Once
	stop := time.Now().Add(limit)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(slot int64, seed int64) {
			defer wg.Done()
			r := rand.New(rand.NewSource(seed))
			for time.Now().Before(stop) {
				select {
				case <-done:
					return
				default:
				}
				c, err := net.Dial("tcp", addr)
				if err != nil {
					time.Sleep(10 * time.Millisecond)
					continue
				}
				c.SetDeadline(time.Now().Add(6 * time.Second))
				c.Write(EncodeRequestHeader(RequestHeader{Mode: ModeDownload, SID: sid, Sequence: slot, Length: 1000}))
				if r.Intn(100) < dropPct {
					c.Close() // resposta "perdida": repete o mesmo slot
					time.Sleep(15 * time.Millisecond)
					continue
				}
				hdr := make([]byte, 5)
				if _, err := io.ReadFull(c, hdr); err != nil {
					c.Close()
					continue
				}
				body := make([]byte, binary.BigEndian.Uint32(hdr[1:]))
				if _, err := io.ReadFull(c, body); err != nil {
					c.Close()
					continue
				}
				c.Close()
				if hdr[0] != 0 {
					t.Errorf("status %d: %s", hdr[0], body)
					return
				}
				var chunk []byte
				if len(body) > 0 {
					chunk = Crypt(body, sid, ModeDownload, slot, true)
				}
				mu.Lock()
				pending[slot] = chunk
				for {
					d, ok := pending[nextRead]
					if !ok {
						break
					}
					delete(pending, nextRead)
					got = append(got, d...)
					nextRead++
				}
				if len(got) >= want {
					once.Do(func() { close(done) })
				}
				mu.Unlock()
				if len(chunk) == 0 {
					time.Sleep(time.Duration(25+r.Intn(30)) * time.Millisecond) // atraso após vazio, como o app
				}
				slot += int64(n)
			}
		}(int64(i), int64(i)+100)
	}
	wg.Wait()
	return got
}

func testStream(size int, seed int64) []byte {
	b := make([]byte, size)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

func runCreditScenario(t *testing.T, threads, size, dropPct int, seed int64) {
	stream := testStream(size, seed)
	addr := startServer(t, startStreamBackend(t, stream, seed))
	sid := [16]byte{byte(seed), byte(threads), 3}
	if st, _ := doReq(t, addr, RequestHeader{Mode: ModeUpload, SID: sid, Sequence: 0}, nil); st != 0 {
		t.Fatal("registro")
	}
	got := runBridgeClient(t, addr, sid, threads, len(stream), dropPct, 40*time.Second)
	if !bytes.Equal(got, stream) {
		n := len(got)
		if n > len(stream) {
			n = len(stream)
		}
		first := -1
		for i := 0; i < n; i++ {
			if got[i] != stream[i] {
				first = i
				break
			}
		}
		t.Fatalf("fluxo diferente: recebido=%d esperado=%d primeira divergência=%d", len(got), len(stream), first)
	}
}

func TestCreditStreamIntegrity7Threads(t *testing.T)  { runCreditScenario(t, 7, 60_000, 0, 1) }
func TestCreditStreamIntegrity32Threads(t *testing.T) { runCreditScenario(t, 32, 90_000, 0, 2) }
func TestCreditStreamWithLostResponses(t *testing.T)  { runCreditScenario(t, 16, 80_000, 8, 3) }
func TestCreditStreamManySeeds(t *testing.T) {
	for seed := int64(10); seed < 14; seed++ {
		runCreditScenario(t, 12, 40_000, 5, seed)
	}
}

// Sessão que já passou por buracos: ACK e retenção não podem apagar o que
// ainda vai ser pedido.
func TestCreditRetryReturnsSameChunk(t *testing.T) {
	stream := []byte("0123456789")
	addr := startServer(t, startStreamBackend(t, stream, 1))
	sid := [16]byte{42}
	doReq(t, addr, RequestHeader{Mode: ModeUpload, SID: sid, Sequence: 0}, nil)
	var first []byte
	for i := 0; i < 2; i++ { // duas vezes o mesmo slot (retry) = mesmo dado
		st, body := doReq(t, addr, RequestHeader{Mode: ModeDownload, SID: sid, Sequence: 9, Length: 1000}, nil)
		if st != 0 || len(body) == 0 {
			t.Fatalf("tentativa %d: st=%d len=%d", i, st, len(body))
		}
		d := Crypt(body, sid, ModeDownload, 9, true)
		if i == 0 {
			first = d
		} else if !bytes.Equal(first, d) {
			t.Fatalf("retry devolveu outro dado: %q vs %q", first, d)
		}
	}
}
