#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wss_watchdog.py - NetSimon: health check REAL do WSS (TLS + handshake WebSocket 101)

Por que existe: `systemctl is-active wss@<porta>` só diz que o PROCESSO existe.
Em 16/10/2026 o wss@8443 ficou "ativo" por ~19h sem aceitar conexões (loop de
accept preso num handshake TLS sem timeout) e o painel mostrou "rodando".
Este watchdog testa o MESMO caminho que o app usa — TLS + Upgrade WebSocket +
101 com Sec-WebSocket-Accept correto — em cada wss@<porta> ATIVO. Após
FAIL_LIMIT falhas seguidas ele grava evidências (pra análise de causa raiz) e
reinicia a instância.

Segurança contra "reiniciar à toa":
  - só olha instâncias wss@ ATIVAS (se você parou o serviço pelo painel, ele não mexe);
  - exige FAIL_LIMIT falhas SEGUIDAS (um restart manual rápido não conta);
  - máximo de MAX_RESTARTS_HOUR reinícios por hora por instância (depois disso
    só registra no log e pede verificação manual);
  - se o wss.py roda com WSS_BIND=<ip específico>, testa nesse ip.

Uso:
  wss_watchdog.py                 modo serviço (loop) — netsimon-wss-watchdog.service
  wss_watchdog.py --check PORTA   teste único; imprime OK/FALHOU; exit 0 = OK, 1 = falhou

Ajustes opcionais (Environment= na unit): WSS_WD_INTERVAL (s entre testes, 30),
WSS_WD_FAILS (falhas seguidas, 3), WSS_WD_COOLDOWN (s sem testar após reiniciar, 60),
WSS_WD_MAX_RESTARTS (por hora, 4).

Log: /var/log/netsimon_wss_watchdog.log (só registra falhas, reinícios e evidências).
"""

import argparse
import base64
import hashlib
import os
import shutil
import socket
import ssl
import subprocess
import sys
import time

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WSS_LOG = "/var/log/netsimon_wss.log"

INTERVAL = int(os.environ.get("WSS_WD_INTERVAL", "30"))
FAIL_LIMIT = int(os.environ.get("WSS_WD_FAILS", "3"))
COOLDOWN = int(os.environ.get("WSS_WD_COOLDOWN", "60"))
MAX_RESTARTS_HOUR = int(os.environ.get("WSS_WD_MAX_RESTARTS", "4"))
CHECK_TIMEOUT = 5.0  # s por etapa (conectar, handshake TLS, resposta)


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [wss-watchdog] {msg}", flush=True)


def run(cmd, timeout=15):
    """Executa um comando (lista de args, sem shell). Retorna (rc, saída)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 1, f"{type(e).__name__}: {e}"


def compute_accept(key):
    sha1 = hashlib.sha1((key + WS_MAGIC).encode()).digest()
    return base64.b64encode(sha1).decode()


def check_wss(porta, host="127.0.0.1", timeout=CHECK_TIMEOUT):
    """TLS + Upgrade WebSocket + 101 com Sec-WebSocket-Accept correto.
    Retorna (ok, detalhe). O certificado é autoassinado: não é verificado,
    aqui só importa se o servidor ATENDE."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    try:
        with socket.create_connection((host, porta), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname="localhost") as tls:
                tls.sendall(req.encode())
                resp = tls.recv(4096).decode(errors="ignore")
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"
    if not resp.startswith("HTTP/1.1 101"):
        return False, f"resposta inesperada: {resp[:60]!r}"
    if f"Sec-WebSocket-Accept: {compute_accept(key)}" not in resp:
        return False, "101 sem o Sec-WebSocket-Accept correto"
    return True, "ok"


def main_pid(porta):
    rc, out = run(["systemctl", "show", "-p", "MainPID", "--value", f"wss@{porta}"])
    try:
        return int(out.strip())
    except ValueError:
        return 0


def check_host(pid):
    """127.0.0.1, a menos que o wss.py tenha subido com WSS_BIND=<ip específico>."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            for item in f.read().split(b"\0"):
                if item.startswith(b"WSS_BIND="):
                    v = item[len(b"WSS_BIND="):].decode(errors="ignore").strip()
                    if v and v != "0.0.0.0":
                        return v
    except OSError:
        pass
    return "127.0.0.1"


def active_ports():
    """Portas das instâncias wss@<porta> que estão ATIVAS agora."""
    rc, out = run(["systemctl", "list-units", "wss@*.service", "--state=active",
                   "--no-legend", "--plain", "--no-pager"])
    portas = []
    if rc != 0:
        return portas
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0].startswith("wss@") and parts[0].endswith(".service"):
            p = parts[0][len("wss@"):-len(".service")]
            if p.isdigit():
                portas.append(int(p))
    return portas


def evidencias(porta, pid, detalhe):
    """Foto do estado ANTES do restart — é o que faltou na falha de 16/10/2026."""
    log(f"=== EVIDÊNCIAS wss@{porta} (pid {pid}) — falha: {detalhe}")
    try:
        nfds = len(os.listdir(f"/proc/{pid}/fd"))
        with open(f"/proc/{pid}/status") as f:
            extra = " ".join(l.strip() for l in f if l.startswith(("Threads:", "VmRSS:")))
        log(f"fds abertos={nfds} {extra}")
    except OSError as e:
        log(f"(sem dados de /proc: {e})")
    rc, out = run(["ss", "-tan", "sport", "=", f":{porta}"])
    if rc == 0:
        estados = {}
        for l in out.splitlines()[1:]:
            p = l.split()
            if p:
                estados[p[0]] = estados.get(p[0], 0) + 1
        log(f"conexões na porta {porta} por estado: {estados}")
        for l in out.splitlines():
            if l.startswith("LISTEN"):
                log(f"ss: {l}")
    if shutil.which("py-spy"):
        rc, out = run(["py-spy", "dump", "--pid", str(pid)], timeout=20)
        for l in out.splitlines()[:80]:
            log(f"py-spy: {l}")
    rc, out = run(["tail", "-n", "25", WSS_LOG])
    for l in out.splitlines():
        log(f"wss.log: {l}")
    log("=== FIM DAS EVIDÊNCIAS")


def loop():
    falhas = {}      # porta -> falhas seguidas
    reinicios = {}   # porta -> epoch dos reinícios recentes
    pausa_ate = {}   # porta -> epoch até quando não testar
    log(f"iniciado — teste a cada {INTERVAL}s, reinicia após {FAIL_LIMIT} falhas seguidas")
    while True:
        portas = active_ports()
        for p in list(falhas):
            if p not in portas:
                falhas.pop(p, None)
        for porta in portas:
            if time.time() < pausa_ate.get(porta, 0):
                continue
            pid = main_pid(porta)
            ok, det = check_wss(porta, check_host(pid))
            if ok:
                if falhas.get(porta):
                    log(f"wss@{porta}: voltou ao normal após {falhas[porta]} falha(s)")
                falhas[porta] = 0
                continue
            falhas[porta] = falhas.get(porta, 0) + 1
            log(f"wss@{porta}: health check FALHOU ({falhas[porta]}/{FAIL_LIMIT}) — {det}")
            if falhas[porta] < FAIL_LIMIT:
                continue
            agora = time.time()
            recentes = [t for t in reinicios.get(porta, []) if agora - t < 3600]
            if len(recentes) >= MAX_RESTARTS_HOUR:
                log(f"wss@{porta}: {len(recentes)} reinícios na última hora — NÃO reiniciando "
                    f"de novo, verifique manualmente")
                falhas[porta] = 0
                pausa_ate[porta] = agora + 300
                continue
            evidencias(porta, pid, det)
            rc, out = run(["systemctl", "restart", f"wss@{porta}"], timeout=60)
            log(f"wss@{porta}: reiniciado (rc={rc}) {out.strip()}")
            recentes.append(agora)
            reinicios[porta] = recentes
            falhas[porta] = 0
            pausa_ate[porta] = time.time() + COOLDOWN
        time.sleep(INTERVAL)


def main():
    parser = argparse.ArgumentParser(description="Health check real do WSS (TLS + 101)")
    parser.add_argument("--check", type=int, metavar="PORTA",
                        help="teste único na porta; exit 0 = OK, 1 = falhou")
    args = parser.parse_args()
    if args.check is not None:
        ok, det = check_wss(args.check, check_host(main_pid(args.check)))
        print("OK" if ok else f"FALHOU: {det}")
        sys.exit(0 if ok else 1)
    loop()


if __name__ == "__main__":
    main()
