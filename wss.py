#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wss.py - NetSimon WebSocket Security (WSS)
Substitui o antigo security.py (nunca abria socket TLS de fato — só o
nome "Security" enganava). Este aqui é TLS real (ssl.SSLContext) por
cima do mesmo modelo de "WebSocket Proxy" do proxy.py: handshake HTTP
RFC 6455 com Sec-WebSocket-Accept calculado de verdade (não fixo),
seguido de passthrough cru pro destino (SSH local, por padrão).

Uso: wss.py <porta> [--dest host:porta] [--cert caminho] [--key caminho]
Rodado via systemd (wss@<porta>.service) — nunca direto em produção.
"""

import argparse
import os
import base64
import hashlib
import logging
import select
import socket
import ssl
import threading

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUFFER_SIZE = 65536
LOG_FILE = "/var/log/netsimon_wss.log"

# FIX (16/10/2026): o handshake TLS (ssl.SSLContext.wrap_socket) era feito
# DENTRO do loop principal de accept(), de forma síncrona e sem timeout.
# Um único cliente lento/malicioso que abrisse a conexão TCP e nunca
# terminasse o handshake TLS travava o accept() pra TODO MUNDO — nenhuma
# conexão nova era aceita enquanto aquele handshake não terminasse ou
# estourasse o timeout do socket (padrão: nunca). Foi isso que causou o
# travamento silencioso do wss@8443 em 16/10/2026 (processo "ativo" no
# systemd, mas sem atender ninguém). Agora: accept() só aceita o socket
# bruto e devolve na hora pro loop — o handshake TLS inteiro (e o connect
# no destino) acontece DENTRO da thread de cada conexão, cada um com seu
# próprio timeout, então um cliente travado nunca mais bloqueia os outros.
HANDSHAKE_TIMEOUT = 10   # segundos pro handshake TLS completar
CONNECT_TIMEOUT = 10     # segundos pro connect() no destino (ex: sshd local)
MAX_CONNS = 4000         # teto de conexões simultâneas em handshake/relay
LISTEN_BACKLOG = 1024    # fila do kernel pra accept() — era 200

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [wss] %(message)s",
)

# Contador de conexões ativas (handshake ou relay) — protegido por lock,
# usado só pra não deixar MAX_CONNS virar um teto decorativo.
_conn_count = 0
_conn_lock = threading.Lock()


def compute_accept(key):
    sha1 = hashlib.sha1((key + WS_MAGIC).encode()).digest()
    return base64.b64encode(sha1).decode()


def extract_ws_key(request):
    for line in request.split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            return line.split(":", 1)[1].strip()
    return None


def handle_client(raw_client, addr, context, dest_host, dest_port):
    """Faz o handshake TLS e todo o resto DENTRO da thread — nunca no
    loop de accept() (ver comentário do FIX acima). Qualquer falha aqui
    (handshake travado, destino fora do ar) só afeta esta conexão."""
    global _conn_count
    target_socket = None
    tls_client = None
    try:
        raw_client.settimeout(HANDSHAKE_TIMEOUT)
        try:
            tls_client = context.wrap_socket(raw_client, server_side=True)
        except Exception as e:
            logging.info(f"{addr}: falha no handshake TLS ({e})")
            raw_client.close()
            return
        tls_client.settimeout(None)

        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

        tls_client.settimeout(10)
        request = tls_client.recv(BUFFER_SIZE).decode(errors="ignore")
        tls_client.settimeout(None)
        if not request:
            return

        ws_key = extract_ws_key(request)
        if ws_key:
            # Handshake real (RFC 6455) — corrige o "Sec-WebSocket-Accept"
            # fixo/"foo" que outros scripts desse nicho usam.
            accept_val = compute_accept(ws_key)
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept_val}\r\n\r\n"
            )
        else:
            # Fallback pra apps que só esperam ver o 101 e já mandar
            # bytes crus, sem validar o handshake WS de verdade.
            response = "HTTP/1.1 101 Switching Protocols\r\n\r\n"

        tls_client.sendall(response.encode())

        target_socket.settimeout(CONNECT_TIMEOUT)
        target_socket.connect((dest_host, dest_port))
        target_socket.settimeout(None)
        target_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        while True:
            r, _, _ = select.select([tls_client, target_socket], [], [], 120)
            if not r:
                break
            if tls_client in r:
                data = tls_client.recv(BUFFER_SIZE)
                if not data:
                    break
                target_socket.sendall(data)
            if target_socket in r:
                data = target_socket.recv(BUFFER_SIZE)
                if not data:
                    break
                tls_client.sendall(data)
    except Exception as e:
        logging.info(f"{addr}: encerrado ({e})")
    finally:
        try:
            (tls_client or raw_client).close()
        except Exception:
            pass
        if target_socket is not None:
            target_socket.close()
        with _conn_lock:
            _conn_count -= 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("--dest", default="127.0.0.1:22")
    parser.add_argument("--cert", default="/etc/painel/wss/cert.pem")
    parser.add_argument("--key", default="/etc/painel/wss/key.pem")
    args = parser.parse_args()

    dest_host, dest_port_str = args.dest.rsplit(":", 1)
    dest_port = int(dest_port_str)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=args.cert, keyfile=args.key)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # v47: WSS_BIND=127.0.0.1 quando roda como backend interno do Multiplex.
    server.bind((os.environ.get("WSS_BIND", "0.0.0.0"), args.port))
    server.listen(LISTEN_BACKLOG)
    logging.info(f"WSS escutando na porta {args.port} -> destino {args.dest} "
                 f"(handshake={HANDSHAKE_TIMEOUT}s, max_conns={MAX_CONNS})")

    global _conn_count
    while True:
        raw_client, addr = server.accept()
        with _conn_lock:
            if _conn_count >= MAX_CONNS:
                logging.info(f"{addr}: recusado — limite de {MAX_CONNS} conexões simultâneas atingido")
                raw_client.close()
                continue
            _conn_count += 1
        # handshake TLS e tudo mais acontece DENTRO da thread — accept()
        # já volta pro topo do loop na mesma hora, pronto pro próximo cliente.
        t = threading.Thread(
            target=handle_client,
            args=(raw_client, addr, context, dest_host, dest_port),
            daemon=True,
        )
        t.start()


if __name__ == "__main__":
    main()
