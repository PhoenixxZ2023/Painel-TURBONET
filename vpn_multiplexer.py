#!/usr/bin/env python3
"""
vpn_multiplexer.py  (Painel Netsimon v47)
-----------------------------------------
Multiplexer de protocolos de tunelamento VPN/SSH: escuta em uma ou mais
portas públicas (por padrão 80 e 443) e, para cada conexão nova, decide
o protocolo pelo CONTEÚDO dos primeiros bytes e encaminha para o backend
interno correspondente (relay TCP bidirecional transparente).

Mudanças da v47 em relação ao standalone original (auditoria M1-M6):
  * M2  método HTTP genérico (regex ^[A-Z]{3,10} ) em vez de lista de 7.
  * M3  lê o cabeçalho HTTP até \\r\\n\\r\\n (limite 8 KB) antes de decidir —
        payload dividido em vários pacotes deixa de ser roteado errado.
  * M4  cliente que espera o servidor falar primeiro: no timeout do peek
        cai em `on_timeout_backend` (padrão ssh_direct), padrão SSLH.
  * M5  detector BHTTP (cabeçalho de 29 bytes: mode 0-4 + sid + seq + len)
        -> backend `bhttp`.
  * M6  `Connection: Upgrade` sem header `Upgrade:` também é WebSocket
        (mesmo critério do proxy.py do painel).
  * SO_KEEPALIVE (15/10/3) + TCP_NODELAY nos dois sockets (evita usuário
    SSH "online fantasma", igual ao _harden_socket do proxy.py).
  * Limite de conexões simultâneas por IP + timeout de handshake.
  * Falha de bind vira erro claro e código de saída != 0 (o gerenciador
    do painel mostra o motivo em vez de ficar num loop silencioso).

Requer Python 3.8+ (asyncio). Sem dependências externas.
"""

import argparse
import asyncio
import json
import logging
import re
import signal
import socket
import struct
import sys
import time
from typing import Any, Dict, Optional, Tuple

# --------------------------------------------------------------------------
# Constantes de detecção
# --------------------------------------------------------------------------

MAX_HTTP_HEADER = 8192          # limite para esperar o fim do cabeçalho HTTP
MAX_TLS_RECORD = 16384 + 5      # maior registro TLS possível
BHTTP_HEADER_LEN = 29           # mode(1) + sid(16) + sequence(8) + length(4)
BHTTP_MAX_BODY = 2 * 1024 * 1024
BHTTP_MODES = (0, 1, 2, 3, 4)   # probe / upload / download / batch / ack

_HTTP_REQ_RE = re.compile(rb"^[A-Z]{3,10} ")
_HTTP_PARTIAL_RE = re.compile(rb"^[A-Z]{1,10}$")
_WS_UPGRADE_RE = re.compile(rb"upgrade:\s*websocket")
_CONN_UPGRADE_RE = re.compile(rb"connection:[^\r\n]*upgrade")


# --------------------------------------------------------------------------
# Configuração / Logging
# --------------------------------------------------------------------------

def load_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def setup_logging(cfg: Dict[str, Any]) -> logging.Logger:
    log_cfg = cfg.get("logging", {})
    level_name = str(log_cfg.get("level", "INFO")).upper()
    level = getattr(logging, level_name, logging.INFO)

    logger = logging.getLogger("vpn_multiplexer")
    logger.setLevel(level)
    logger.propagate = False

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(fmt)
    logger.addHandler(console_handler)

    log_file = log_cfg.get("file")
    if log_file:
        try:
            file_handler = logging.FileHandler(log_file)
            file_handler.setFormatter(fmt)
            logger.addHandler(file_handler)
        except OSError as e:
            logger.warning("Não foi possível abrir arquivo de log %s: %s", log_file, e)
    return logger


# --------------------------------------------------------------------------
# Parser de SNI dentro de um ClientHello TLS (RFC 8446 / 5246)
# --------------------------------------------------------------------------

def extract_sni(data: bytes) -> Optional[str]:
    """Extrai o hostname da extensão SNI de um ClientHello (best-effort)."""
    try:
        if len(data) < 5 or data[0] != 0x16:
            return None
        pos = 5
        if len(data) < pos + 4 or data[pos] != 0x01:  # ClientHello
            return None
        pos += 4
        pos += 2 + 32                                  # version + random
        if len(data) < pos + 1:
            return None
        pos += 1 + data[pos]                           # session id
        if len(data) < pos + 2:
            return None
        pos += 2 + struct.unpack(">H", data[pos:pos + 2])[0]   # cipher suites
        if len(data) < pos + 1:
            return None
        pos += 1 + data[pos]                           # compression
        if len(data) < pos + 2:
            return None
        ext_len = struct.unpack(">H", data[pos:pos + 2])[0]
        pos += 2
        ext_end = pos + ext_len
        while pos + 4 <= min(len(data), ext_end):
            ext_type = struct.unpack(">H", data[pos:pos + 2])[0]
            elen = struct.unpack(">H", data[pos + 2:pos + 4])[0]
            start = pos + 4
            if ext_type == 0x00:                       # server_name
                list_len = struct.unpack(">H", data[start:start + 2])[0]
                sp = start + 2
                end = sp + list_len
                while sp + 3 <= end:
                    name_type = data[sp]
                    name_len = struct.unpack(">H", data[sp + 1:sp + 3])[0]
                    if name_type == 0x00:
                        return data[sp + 3:sp + 3 + name_len].decode("ascii", errors="ignore")
                    sp += 3 + name_len
            pos = start + elen
        return None
    except (struct.error, IndexError, UnicodeError):
        return None


# --------------------------------------------------------------------------
# Detecção de protocolo
# --------------------------------------------------------------------------

def looks_like_bhttp(data: bytes) -> Optional[bool]:
    """True/False quando dá pra decidir; None se faltam bytes (<29).

    Assinatura estrutural do cabeçalho BHTTP cliente->servidor (ver
    internal/bhttp/protocol.go do netsimon-bhttp): primeiro byte = modo
    (0..4) e os 4 últimos bytes = tamanho do corpo (<= 2 MiB). Os modos
    0..4 não colidem com SSH ('S'=0x53), TLS (0x16), HTTP (letras ASCII)
    nem SOCKS5 (0x05)."""
    if not data or data[0] not in BHTTP_MODES:
        return False
    if len(data) < BHTTP_HEADER_LEN:
        return None
    length = struct.unpack(">I", data[25:29])[0]
    return length <= BHTTP_MAX_BODY


def classify(data: bytes, cfg: Dict[str, Any], final: bool = False
             ) -> Optional[Tuple[str, str]]:
    """Retorna (backend, motivo) ou None quando ainda faltam bytes pra
    decidir. Com final=True (estourou o tempo do peek) sempre decide."""
    unknown = cfg.get("default_unknown_action", "drop")
    if not data:
        return None if not final else (cfg.get("on_timeout_backend", "ssh_direct"),
                                       "cliente mudo até o timeout (espera o servidor falar)")

    # --- SSH direto: banner "SSH-x.y-..." ---
    if data.startswith(b"SSH-"):
        return "ssh_direct", "banner SSH detectado"
    if len(data) < 4 and b"SSH-".startswith(data) and not final:
        return None

    # --- TLS ClientHello (precisa do registro inteiro pra achar o SNI) ---
    if data[0] == 0x16:
        if len(data) < 5 and not final:
            return None
        if len(data) >= 2 and data[1] == 0x03:
            need = MAX_TLS_RECORD
            if len(data) >= 5:
                need = min(5 + struct.unpack(">H", data[3:5])[0], MAX_TLS_RECORD)
            if len(data) < need and not final:
                return None
            sni = extract_sni(data)
            routing = cfg.get("sni_routing", {})
            if sni and sni in routing:
                return routing[sni], f"SNI TLS = {sni}"
            return (cfg.get("default_tls_backend", "websocket_security"),
                    f"TLS sem SNI mapeado (sni={sni!r}), usando default")

    # --- BHTTP do app NETSIMON (frame de 29 bytes) ---
    b = looks_like_bhttp(data)
    if b is None and not final:
        return None
    if b:
        return cfg.get("bhttp_backend", "bhttp"), "cabeçalho BHTTP (29 bytes) detectado"

    # --- SOCKS5: primeiro byte 0x05 ---
    if data[0] == 0x05:
        return "socks_proxy", "assinatura SOCKS5 detectada"

    # --- HTTP: qualquer método (M2) ---
    if _HTTP_REQ_RE.match(data):
        end = data.find(b"\r\n\r\n")
        if end < 0 and len(data) < MAX_HTTP_HEADER and not final:
            return None                                  # M3: espera o fim do header
        blob = data[:MAX_HTTP_HEADER if end < 0 else end].lower()
        if (_WS_UPGRADE_RE.search(blob) or _CONN_UPGRADE_RE.search(blob)
                or b"sec-websocket-key" in blob):        # M6
            return "websocket", "HTTP Upgrade/WebSocket detectado"
        if data.startswith(b"CONNECT "):
            return "open_proxy", "método CONNECT (proxy HTTP) detectado"
        return "open_proxy", "requisição HTTP genérica, tratando como proxy"
    if _HTTP_PARTIAL_RE.match(data) and len(data) <= 10 and not final:
        return None                                      # ainda chegando o método

    reason = f"nenhuma assinatura reconhecida | {len(data)} bytes"
    return unknown, reason


# --------------------------------------------------------------------------
# Sockets / relay
# --------------------------------------------------------------------------

def harden_socket(sock: Optional[socket.socket], idle: int = 15,
                  interval: int = 10, count: int = 3) -> None:
    """Mesmo endurecimento do proxy.py: keepalive agressivo + NODELAY."""
    if sock is None:
        return
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, idle)
        if hasattr(socket, "TCP_KEEPINTVL"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, interval)
        if hasattr(socket, "TCP_KEEPCNT"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, count)
    except OSError:
        pass


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def relay(cr, cw, br, bw) -> None:
    await asyncio.gather(pipe(cr, bw), pipe(br, cw), return_exceptions=True)


# --------------------------------------------------------------------------
# Handler de conexão
# --------------------------------------------------------------------------

class IPLimiter:
    """Conta conexões simultâneas por IP (anti-abuso simples)."""

    def __init__(self, limit: int):
        self.limit = limit
        self.counts: Dict[str, int] = {}

    def acquire(self, ip: str) -> bool:
        if self.limit <= 0:
            return True
        n = self.counts.get(ip, 0)
        if n >= self.limit:
            return False
        self.counts[ip] = n + 1
        return True

    def release(self, ip: str) -> None:
        if self.limit <= 0:
            return
        n = self.counts.get(ip, 0) - 1
        if n <= 0:
            self.counts.pop(ip, None)
        else:
            self.counts[ip] = n


async def read_and_classify(reader: asyncio.StreamReader, cfg: Dict[str, Any]
                            ) -> Tuple[bytes, Optional[Tuple[str, str]]]:
    """Lê em loop (com prazo total) até classify() conseguir decidir."""
    lcfg = cfg.get("listen", {})
    peek_bytes = int(lcfg.get("peek_bytes", 4096))
    # tempo que um cliente "mudo" espera antes de cair em on_timeout_backend
    silent_timeout = float(cfg.get("fallback_timeout_seconds",
                                   lcfg.get("peek_timeout_seconds", 2)))
    # prazo total do handshake (anti-slowloris)
    total_timeout = float(cfg.get("handshake_timeout_seconds", 10))
    limit = max(peek_bytes, MAX_HTTP_HEADER, MAX_TLS_RECORD)

    buf = b""
    start = time.monotonic()
    while True:
        decision = classify(buf, cfg)
        if decision is not None:
            return buf, decision
        elapsed = time.monotonic() - start
        remaining_total = total_timeout - elapsed
        # cliente que nunca mandou nada usa o timeout curto; quem já mandou
        # algo parcial pode levar até o prazo total
        wait = min(silent_timeout if not buf else remaining_total, remaining_total)
        if wait <= 0 or len(buf) >= limit:
            return buf, classify(buf, cfg, final=True)
        try:
            chunk = await asyncio.wait_for(reader.read(limit - len(buf)), timeout=wait)
        except asyncio.TimeoutError:
            return buf, classify(buf, cfg, final=True)
        if not chunk:                       # cliente fechou
            return buf, None
        buf += chunk


async def handle_connection(client_reader, client_writer, cfg, logger, limiter) -> None:
    peer = client_writer.get_extra_info("peername")
    ip = peer[0] if peer else "?"
    if not limiter.acquire(ip):
        logger.info("[%s] limite de conexões simultâneas por IP atingido — recusando", peer)
        client_writer.close()
        return
    backend_writer = None
    try:
        harden_socket(client_writer.get_extra_info("socket"))
        try:
            initial_data, decision = await read_and_classify(client_reader, cfg)
        except (ConnectionResetError, BrokenPipeError, OSError):
            return
        if decision is None:
            client_writer.close()
            return
        backend_name, reason = decision

        backends = cfg.get("backends", {})
        if backend_name == "drop" or backend_name not in backends:
            if logger.isEnabledFor(logging.DEBUG) and initial_data:
                reason += f" | hex={initial_data[:80].hex()} | repr={initial_data[:80]!r}"
            logger.info("[%s] conexão rejeitada (%s) — backend='%s'", peer, reason, backend_name)
            client_writer.close()
            return

        b = backends[backend_name]
        logger.info("[%s] -> backend='%s' (%s:%s) | motivo: %s",
                    peer, backend_name, b["host"], b["port"], reason)
        try:
            backend_reader, backend_writer = await asyncio.wait_for(
                asyncio.open_connection(b["host"], b["port"]), timeout=8)
        except (OSError, asyncio.TimeoutError) as e:
            logger.warning("[%s] falha ao conectar no backend '%s' (%s:%s): %s",
                           peer, backend_name, b["host"], b["port"], e)
            client_writer.close()
            return
        harden_socket(backend_writer.get_extra_info("socket"))

        # Reinjeta os bytes já lidos antes do relay
        if initial_data:
            backend_writer.write(initial_data)
            await backend_writer.drain()
        await relay(client_reader, client_writer, backend_reader, backend_writer)
    finally:
        limiter.release(ip)
        for w in (client_writer, backend_writer):
            try:
                if w is not None:
                    w.close()
            except Exception:
                pass


# --------------------------------------------------------------------------
# Bootstrap dos listeners
# --------------------------------------------------------------------------

async def run_server(cfg: Dict[str, Any], logger: logging.Logger) -> None:
    listen_cfg = cfg.get("listen", {})
    bind_address = listen_cfg.get("bind_address", "0.0.0.0")
    ports = listen_cfg.get("public_ports", [443])
    limiter = IPLimiter(int(cfg.get("max_conn_per_ip", 0)))

    servers = []
    for port in ports:
        try:
            server = await asyncio.start_server(
                lambda r, w: handle_connection(r, w, cfg, logger, limiter),
                host=bind_address, port=int(port), backlog=1024, reuse_address=True)
        except OSError as e:
            logger.error("Não foi possível escutar em %s:%s — %s", bind_address, port, e)
            for s in servers:
                s.close()
            raise SystemExit(2)
        servers.append(server)
        logger.info("Escutando em %s:%s", bind_address, port)
    await asyncio.gather(*(s.serve_forever() for s in servers))


def main() -> None:
    parser = argparse.ArgumentParser(description="VPN Multiplexer (Painel Netsimon v47)")
    parser.add_argument("--config", default="multiplexer_config.json",
                        help="Caminho do arquivo de config JSON")
    parser.add_argument("--check", action="store_true",
                        help="só valida o config e sai (código 0 = ok)")
    args = parser.parse_args()

    cfg = load_config(args.config)
    if args.check:
        assert isinstance(cfg.get("listen", {}).get("public_ports", []), list)
        print("config OK")
        return
    logger = setup_logging(cfg)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def shutdown(*_):
        logger.info("Encerrando multiplexer...")
        loop.stop()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, shutdown)
        except NotImplementedError:
            pass

    try:
        loop.run_until_complete(run_server(cfg, logger))
    except (KeyboardInterrupt, RuntimeError):
        pass
    finally:
        loop.close()


if __name__ == "__main__":
    main()
