// netsimon-bhttpd — servidor próprio do protocolo SSH_BHTTP da
// infraestrutura NETSIMON.
//
// Implementação nova, independente e sem dependências externas (só a
// biblioteca padrão do Go): não empacota, baixa, nem reexecuta nenhum
// binário ou código de terceiros. O serviço apenas fala o protocolo BHTTP
// (framing próprio + cifra XOR/SHA-256) e encaminha os bytes já
// desencapsulados para o sshd real do sistema operacional, que é quem
// autentica e criptografa a sessão SSH de fato.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"netsimon-bhttp/internal/bhttp"
	"netsimon-bhttp/internal/config"
)

const version = "1.4.0"

func main() {
	configPath := flag.String("config", "/etc/netsimon-bhttp/config.json", "caminho do config.json")
	showVersion := flag.Bool("version", false, "mostra a versão e sai")
	flag.Parse()

	if *showVersion {
		fmt.Println("netsimon-bhttpd " + version)
		return
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("netsimon-bhttpd: %v", err)
	}

	backendAddr := net.JoinHostPort(cfg.Backend.Host, fmt.Sprintf("%d", cfg.Backend.Port))
	// Keepalive agressivo na perna do sshd: se o app sumir "sujo", o kernel
	// derruba a conexão em vez de deixar um usuário SSH "online fantasma".
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 15 * time.Second}
	dial := func() (net.Conn, error) {
		return dialer.Dial("tcp", backendAddr)
	}

	srv := bhttp.NewServer(
		dial,
		cfg.Session.MaxBufferedChunks,
		time.Duration(cfg.Session.IdleTimeoutSeconds)*time.Second,
		time.Duration(cfg.Session.DownloadWaitMS)*time.Millisecond,
		cfg.Log.Level == "debug",
	)
	srv.SetRetainChunks(cfg.Session.RetainChunks)
	srv.SetSlotCredit(cfg.Session.SlotCredit)
	srv.SetKeepAlive(time.Duration(cfg.Session.KeepAliveIdleSeconds) * time.Second)

	var tlsConfig *tls.Config
	needsTLS := false
	for _, l := range cfg.Listen {
		if l.TLS {
			needsTLS = true
			break
		}
	}
	if needsTLS {
		tlsConfig, err = loadTLSConfig(cfg)
		if err != nil {
			log.Printf("netsimon-bhttpd: TLS indisponível (%v) — a(s) porta(s) com tls=true nesta config não vão subir; %d/%d listener(s) seguem normalmente", err, countNonTLS(cfg.Listen), len(cfg.Listen))
			tlsConfig = nil
		}
	}

	activeListeners := 0
	for _, l := range cfg.Listen {
		l := l
		if l.TLS && tlsConfig == nil {
			continue
		}
		activeListeners++
		go func() {
			if err := serveListen(l, tlsConfig, srv); err != nil {
				// v1.2.1: bind que falha (porta ocupada) NÃO pode deixar o processo
				// "vivo e mudo" — o systemd/painel precisam ver a falha de verdade.
				log.Fatalf("netsimon-bhttpd: listener %s:%d falhou: %v", l.Host, l.Port, err)
			}
		}()
	}
	if activeListeners == 0 {
		log.Fatalf("netsimon-bhttpd: nenhum listener pôde subir — verifique %s", *configPath)
	}

	log.Printf("netsimon-bhttpd %s iniciado — backend SSH em %s", version, backendAddr)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("netsimon-bhttpd: encerrando")
}

func serveListen(l config.ListenConfig, tlsConfig *tls.Config, srv *bhttp.Server) error {
	addr := net.JoinHostPort(l.Host, fmt.Sprintf("%d", l.Port))
	var listener net.Listener
	var err error
	if l.TLS {
		if tlsConfig == nil {
			return fmt.Errorf("porta %d marcada como TLS mas certificado não carregado", l.Port)
		}
		listener, err = tls.Listen("tcp", addr, tlsConfig)
	} else {
		listener, err = net.Listen("tcp", addr)
	}
	if err != nil {
		return err
	}
	log.Printf("netsimon-bhttpd: ouvindo em %s (tls=%v)", addr, l.TLS)

	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go srv.HandleConn(conn)
	}
}

func countNonTLS(listeners []config.ListenConfig) int {
	n := 0
	for _, l := range listeners {
		if !l.TLS {
			n++
		}
	}
	return n
}

func loadTLSConfig(cfg config.Config) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(cfg.TLS.CertFile, cfg.TLS.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("carregando certificado (%s / %s): %w", cfg.TLS.CertFile, cfg.TLS.KeyFile, err)
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}}, nil
}
