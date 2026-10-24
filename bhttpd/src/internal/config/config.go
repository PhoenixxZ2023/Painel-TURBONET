// Package config carrega e valida a configuração do netsimon-bhttpd.
//
// Projeto 100% autoral (Netsimon-bhttp): implementação própria, do zero, do
// protocolo BHTTP-sobre-SSH usado pelos apps da infraestrutura NETSIMON.
// Nenhum código de terceiros foi copiado ou vendorizado — apenas a
// biblioteca padrão do Go.
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

type ListenConfig struct {
	Host string `json:"host"`
	Port int    `json:"port"`
	TLS  bool   `json:"tls"`
}

type TLSConfig struct {
	CertFile string `json:"cert_file"`
	KeyFile  string `json:"key_file"`
}

type BackendConfig struct {
	// Host/porta do SSH real do próprio servidor (sshd do sistema). O
	// netsimon-bhttpd NÃO implementa autenticação/handshake SSH — apenas
	// encapsula/desencapsula o protocolo BHTTP e encaminha os bytes já
	// prontos para o sshd local, que faz a autenticação de verdade contra
	// os usuários do sistema operacional.
	Host string `json:"host"`
	Port int    `json:"port"`
}

type SessionConfig struct {
	// Tempo máximo (segundos) sem nenhuma atividade de upload/download
	// antes de encerrar a sessão e liberar a conexão com o backend.
	IdleTimeoutSeconds int `json:"idle_timeout_seconds"`
	// Quantos chunks de download ainda não confirmados (ACK) por sessão
	// ficam retidos em memória, no máximo, antes de começar a descartar
	// os mais antigos (proteção básica de memória por sessão travada).
	MaxBufferedChunks int `json:"max_buffered_chunks"`
	// Quanto tempo (ms) um download (modo 2) sem dados disponíveis espera
	// antes de responder "vazio" (status 0, corpo vazio). 0 = responde
	// na hora. Se o app estiver fazendo timeout de leitura antes de 8 s,
	// reduza (ex.: 1000). Padrão: 8000.
	DownloadWaitMS int `json:"download_wait_ms"`
	// v1.3.0: quantos chunks de download já entregues ficam retidos para
	// retransmissão caso a resposta se perca no caminho (NAT/operadora).
	// O ACK do app libera antes; este valor é só o teto de segurança.
	// Padrão: 256 (antes era fixo em 32 e descartava chunk ainda pedido).
	RetainChunks int `json:"retain_chunks"`
	// v1.3.0: conexão persistente. 0 = desligado (comportamento antigo: uma
	// requisição por conexão). >0 = segundos que a conexão fica aberta
	// esperando a próxima requisição antes de ser fechada.
	KeepAliveIdleSeconds int `json:"keepalive_idle_seconds"`
	// v1.4.0: download por crédito (padrão true). O seq do pedido vira uma
	// posição no fluxo e nenhum dado se perde quando um pedido expira vazio.
	// false = comportamento antigo (índice absoluto por ordem de produção).
	SlotCredit bool `json:"slot_credit"`
}

type LogConfig struct {
	Level string `json:"level"` // "info" | "debug"
}

type Config struct {
	Listen  []ListenConfig `json:"listen"`
	TLS     TLSConfig      `json:"tls"`
	Backend BackendConfig  `json:"backend"`
	Session SessionConfig  `json:"session"`
	Log     LogConfig      `json:"log"`
}

func Default() Config {
	return Config{
		Listen: []ListenConfig{
			{Host: "0.0.0.0", Port: 80, TLS: false},
		},
		TLS: TLSConfig{
			CertFile: "/etc/netsimon-bhttp/tls/fullchain.pem",
			KeyFile:  "/etc/netsimon-bhttp/tls/privkey.pem",
		},
		Backend: BackendConfig{
			Host: "127.0.0.1",
			Port: 22,
		},
		Session: SessionConfig{
			IdleTimeoutSeconds:   300,
			MaxBufferedChunks:    4096,
			DownloadWaitMS:       8000,
			RetainChunks:         256,
			KeepAliveIdleSeconds: 0,
			SlotCredit:           true,
		},
		Log: LogConfig{Level: "info"},
	}
}

// Load lê o config.json do disco; se não existir, grava o padrão nesse
// caminho e retorna o padrão (primeira execução após instalação).
func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			cfg := Default()
			if writeErr := Save(path, cfg); writeErr != nil {
				return cfg, fmt.Errorf("config padrão não pôde ser gravada em %s: %w", path, writeErr)
			}
			return cfg, nil
		}
		return Config{}, fmt.Errorf("lendo %s: %w", path, err)
	}
	cfg := Default()
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parseando %s: %w", path, err)
	}
	return cfg, nil
}

func Save(path string, cfg Config) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o640)
}
