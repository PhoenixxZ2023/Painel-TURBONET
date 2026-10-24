package bhttp

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

const tChunk = 1000

// backend: aceita 1 conexão e despeja 100 blocos de exatamente tChunk bytes (byte = índice do bloco)
func startBackend(t *testing.T) (BackendDialer, func()) {
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
		for i := 0; i < 100; i++ {
			b := make([]byte, tChunk)
			for j := range b {
				b[j] = byte(i)
			}
			c.Write(b)
			time.Sleep(20 * time.Millisecond)
		}
	}()
	return func() (net.Conn, error) { return net.Dial("tcp", ln.Addr().String()) }, func() { ln.Close() }
}

func startServer(t *testing.T, dial BackendDialer) string { return startServerMode(t, dial, true) }

func startServerMode(t *testing.T, dial BackendDialer, credit bool) string {
	srv := NewServer(dial, 4096, 300*time.Second, 400*time.Millisecond, false)
	srv.SetSlotCredit(credit)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go srv.HandleConn(c)
		}
	}()
	return ln.Addr().String()
}

func doReq(t *testing.T, addr string, h RequestHeader, payload []byte) (byte, []byte) {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write(EncodeRequestHeader(h))
	if len(payload) > 0 {
		c.Write(payload)
	}
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(c, hdr); err != nil {
		t.Fatalf("lendo resposta: %v", err)
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	body := make([]byte, n)
	io.ReadFull(c, body)
	return hdr[0], body
}

func dl(t *testing.T, addr string, sid [16]byte, seq int64) []byte {
	st, body := doReq(t, addr, RequestHeader{Mode: ModeDownload, SID: sid, Sequence: seq, Length: tChunk}, nil)
	if st != 0 {
		t.Fatalf("seq %d status %d %s", seq, st, body)
	}
	if len(body) == 0 {
		return nil
	}
	return Crypt(body, sid, ModeDownload, seq, true)
}

// Resposta do seq 5 "se perde"; o app avança até seq 45 e depois repete o 5.
func TestLegacyRetryAfterLostResponse(t *testing.T) {
	dial, stop := startBackend(t)
	defer stop()
	addr := startServerMode(t, dial, false) // esquema legado (índice absoluto)
	sid := [16]byte{9, 9, 9}
	doReq(t, addr, RequestHeader{Mode: ModeUpload, SID: sid, Sequence: 0}, nil) // cria sessão
	dl(t, addr, sid, 0)
	time.Sleep(2500 * time.Millisecond) // backend termina de produzir
	for s := int64(1); s <= 45; s++ {
		if s == 5 {
			continue
		}
		if d := dl(t, addr, sid, s); len(d) != tChunk || d[0] != byte(s) {
			t.Fatalf("seq %d veio errado (len=%d)", s, len(d))
		}
	}
	d := dl(t, addr, sid, 5)
	if len(d) != tChunk || d[0] != 5 {
		t.Fatalf("RETRY seq 5 perdeu dado (len=%d) — chunk já foi descartado", len(d))
	}
}

// ---- v1.3.0: keep-alive e integridade ponta a ponta com backend "eco"
func startEcho(t *testing.T) BackendDialer {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go io.Copy(c, c)
		}
	}()
	return func() (net.Conn, error) { return net.Dial("tcp", ln.Addr().String()) }
}

func startServerKA(t *testing.T, dial BackendDialer, ka time.Duration) string {
	srv := NewServer(dial, 4096, 300*time.Second, 400*time.Millisecond, false)
	srv.SetKeepAlive(ka)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go srv.HandleConn(c)
		}
	}()
	return ln.Addr().String()
}

func reqOn(c net.Conn, h RequestHeader, payload []byte) (byte, []byte, error) {
	c.SetDeadline(time.Now().Add(3 * time.Second))
	c.Write(EncodeRequestHeader(h))
	if len(payload) > 0 {
		c.Write(payload)
	}
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(c, hdr); err != nil {
		return 0, nil, err
	}
	body := make([]byte, binary.BigEndian.Uint32(hdr[1:]))
	_, err := io.ReadFull(c, body)
	return hdr[0], body, err
}

func TestKeepAliveManyRequestsOneConn(t *testing.T) {
	addr := startServerKA(t, startEcho(t), 5*time.Second)
	c, _ := net.Dial("tcp", addr)
	defer c.Close()
	sid := [16]byte{7}
	msg := []byte("SSH-2.0-teste\r\n")
	st, _, err := reqOn(c, RequestHeader{Mode: ModeUpload, SID: sid, Sequence: 0, Length: uint32(len(msg))}, Crypt(msg, sid, ModeUpload, 0, false))
	if err != nil || st != 0 {
		t.Fatalf("upload: st=%d err=%v", st, err)
	}
	var got []byte
	for i := 0; i < 20 && len(got) == 0; i++ { // mesma conexão, vários pedidos
		st, body, err := reqOn(c, RequestHeader{Mode: ModeDownload, SID: sid, Sequence: 0, Length: 4096}, nil)
		if err != nil || st != 0 {
			t.Fatalf("download %d: st=%d err=%v", i, st, err)
		}
		if len(body) > 0 {
			got = Crypt(body, sid, ModeDownload, 0, true)
		}
	}
	if string(got) != string(msg) {
		t.Fatalf("eco diferente: %q", got)
	}
	if st, _, err := reqOn(c, RequestHeader{Mode: ModeAck, SID: sid, Sequence: 1}, nil); err != nil || st != 0 {
		t.Fatalf("ack na mesma conexão: st=%d err=%v", st, err)
	}
}

func TestKeepAliveOffClosesAfterOne(t *testing.T) {
	addr := startServerKA(t, startEcho(t), 0)
	c, _ := net.Dial("tcp", addr)
	defer c.Close()
	sid := [16]byte{8}
	if _, _, err := reqOn(c, RequestHeader{Mode: ModeUpload, SID: sid, Sequence: 0}, nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := reqOn(c, RequestHeader{Mode: ModeAck, SID: sid, Sequence: 1}, nil); err == nil {
		t.Fatal("com keep-alive desligado a conexão deveria fechar após 1 requisição")
	}
}
