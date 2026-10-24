#!/bin/bash
# ==========================================
#   PAINEL NETSIMON - MULTIPLEX MANAGER (v47)
#   Liga/desliga o Netsimon Multiplex: UMA porta pública (80/443) que
#   escolhe o protocolo pelo CONTEÚDO dos primeiros bytes (SSH, TLS+SNI,
#   WebSocket, BHTTP...) e entrega ao backend certo, que roda numa porta
#   INTERNA (127.0.0.1).
#
#   Mesmo espírito do bhttp.sh: instalado != ativado. Ativação sempre
#   manual (CLI daqui, menu websocket.sh ou tela WebSocket do painel).
#
#   ATIVAR  = "assume o controle": tira um snapshot do que estava
#             ligado, para/desabilita TUDO isso, libera 80/443 (mata
#             processo do painel que ainda esteja segurando a porta) e
#             sobe o mux + os backends internos.
#   DESATIVAR = desliga o mux e os backends internos e devolve o painel
#             ao funcionamento padrão (um serviço por porta), religando
#             o que estava ativo antes (a menos que use --no-restore).
#
#   Códigos de saída: 0 ok | 1 erro | 3 porta presa por processo que o
#   painel NÃO reconhece (nada foi alterado; rode de novo com --force).
# ==========================================

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'
else
    G=""; R=""; Y=""; W=""; C=""; NC=""
fi

BASE="/etc/painel"
MUX_DIR="$BASE/mux"
MUX_PY="$BASE/vpn_multiplexer.py"
MUX_CONF="$MUX_DIR/multiplexer_config.json"
MUX_SETTINGS="$MUX_DIR/mux.conf"
MUX_SNAPSHOT="$MUX_DIR/snapshot.list"
MUX_BACKENDS="$MUX_DIR/backends.list"
MUX_UNIT="netsimon-mux"
MUX_LOG="/var/log/netsimon_mux.log"

# portas INTERNAS dos backends (só 127.0.0.1)
P_WS=10080; P_WSS=10081; P_BHTTP=10083; P_BHTTPD=10084; P_BHTTPD_TLS=10085; P_XRAY=10443; P_STUNNEL=10453

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_MUX_CONF="$MUX_DIR/xray_config.mux.json"
XRAY_DROPIN_DIR="/etc/systemd/system/xray.service.d"
XRAY_DROPIN="$XRAY_DROPIN_DIR/netsimon-mux.conf"

WSS_DIR="$BASE/wss"
STUNNEL_DIR="$BASE/stunnel"
STUNNEL_CONF="$STUNNEL_DIR/stunnel.conf"
STUNNEL_CONF_BACKUP="$MUX_DIR/stunnel.conf.orig"
BHTTP_BIN="/usr/local/bin/netsimon-bhttp"
BHTTP_CONF="/etc/netsimon-bhttp/config.json"
BHTTP_MUX_CONF="/etc/netsimon-bhttp/config.mux.json"
BHTTPD_BIN="/usr/local/bin/netsimon-bhttpd"
BHTTPD_CONF="/etc/netsimon-bhttpd/config.json"
BHTTPD_MUX_CONF="/etc/netsimon-bhttpd/config.mux.json"

BACKEND_UNITS="netsimon-mux-ws netsimon-mux-wss netsimon-mux-bhttp netsimon-mux-bhttpd"

# ── settings (KEY=VALUE em $MUX_SETTINGS) ────────────────────────
get_setting() {
    local key=$1 def=$2 val
    val=$(grep -m1 -oP "^${key}=\K.*" "$MUX_SETTINGS" 2>/dev/null)
    echo "${val:-$def}"
}

set_setting() {
    local key=$1 val=$2
    mkdir -p "$MUX_DIR"
    touch "$MUX_SETTINGS"
    grep -v "^${key}=" "$MUX_SETTINGS" > "$MUX_SETTINGS.tmp" 2>/dev/null
    echo "${key}=${val}" >> "$MUX_SETTINGS.tmp"
    mv -f "$MUX_SETTINGS.tmp" "$MUX_SETTINGS"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ── instalação (units systemd + arquivos; NÃO liga nada) ────────
mux_installed() {
    [ -f "$MUX_PY" ] && [ -f "/etc/systemd/system/${MUX_UNIT}.service" ]
}

mux_install() {
    if [ ! -f "$MUX_PY" ]; then
        echo -e "${R}[ERRO] $MUX_PY não encontrado — reinstale o painel.${NC}"
        return 1
    fi
    if ! python3 -m py_compile "$MUX_PY" 2>/dev/null; then
        echo -e "${R}[ERRO] $MUX_PY com erro de sintaxe.${NC}"
        return 1
    fi
    mkdir -p "$MUX_DIR"
    chmod +x "$BASE/multiplex.sh" 2>/dev/null

    cat > /etc/systemd/system/${MUX_UNIT}.service << EOF
[Unit]
Description=Netsimon Multiplex - porta unica com roteamento por conteudo
After=network.target sshd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $MUX_PY --config $MUX_CONF
Restart=on-failure
RestartSec=3
# código 2 = bind falhou (porta ocupada): não adianta ficar tentando em loop
RestartPreventExitStatus=2
LimitNOFILE=65535
StandardOutput=append:$MUX_LOG
StandardError=append:$MUX_LOG

[Install]
WantedBy=multi-user.target
EOF

    # backend WS (proxy.py) preso em 127.0.0.1
    cat > /etc/systemd/system/netsimon-mux-ws.service << EOF
[Unit]
Description=Netsimon Multiplex - backend WebSocket (proxy.py, interno)
After=network.target
PartOf=${MUX_UNIT}.service

[Service]
Type=simple
Environment=PROXY_BIND=127.0.0.1
ExecStart=/usr/bin/python3 $BASE/proxy.py $P_WS
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=append:/var/log/netsimon_proxy.log
StandardError=append:/var/log/netsimon_proxy.log

[Install]
WantedBy=multi-user.target
EOF

    # backend WSS TLS (wss.py) preso em 127.0.0.1
    cat > /etc/systemd/system/netsimon-mux-wss.service << EOF
[Unit]
Description=Netsimon Multiplex - backend WSS TLS (wss.py, interno)
After=network.target
PartOf=${MUX_UNIT}.service

[Service]
Type=simple
Environment=WSS_BIND=127.0.0.1
EnvironmentFile=-$WSS_DIR/wss.conf
ExecStart=/usr/bin/python3 $BASE/wss.py $P_WSS --dest \${WSS_DEST} --cert $WSS_DIR/cert.pem --key $WSS_DIR/key.pem
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=append:/var/log/netsimon_wss.log
StandardError=append:/var/log/netsimon_wss.log

[Install]
WantedBy=multi-user.target
EOF

    # backend BHTTP antigo (binário fechado) — config própria do modo mux
    cat > /etc/systemd/system/netsimon-mux-bhttp.service << EOF
[Unit]
Description=Netsimon Multiplex - backend BHTTP (binario antigo, interno)
After=network.target
PartOf=${MUX_UNIT}.service

[Service]
Type=simple
ExecStart=$BHTTP_BIN --config $BHTTP_MUX_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # backend BHTTPD novo (Go) — config própria do modo mux
    cat > /etc/systemd/system/netsimon-mux-bhttpd.service << EOF
[Unit]
Description=Netsimon Multiplex - backend BHTTPD (binario novo, interno)
After=network.target sshd.service
PartOf=${MUX_UNIT}.service

[Service]
Type=simple
ExecStart=$BHTTPD_BIN -config $BHTTPD_MUX_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # instalado != ativado
    for u in $MUX_UNIT $BACKEND_UNITS; do
        systemctl disable "$u" &>/dev/null
        systemctl stop "$u" &>/dev/null
    done
    [ -f "$MUX_SETTINGS" ] || printf 'MUX_HTTP_PORT=80\nMUX_HTTPS_PORT=443\nMUX_TLS_DEFAULT=wss\nMUX_BHTTP_IMPL=bhttpd\nMUX_SNI_MAP=\nMUX_MAX_CONN_IP=200\nMUX_FALLBACK_SEC=2\n' > "$MUX_SETTINGS"
    echo -e "${G}[OK] Multiplex instalado (não ativado).${NC}"
    return 0
}

# ── helpers de estado ────────────────────────────────────────────
mux_active() { systemctl is-active --quiet "$MUX_UNIT"; }

unit_active()  { systemctl is-active  --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# Quem está em LISTEN numa porta TCP: "pid|linha de comando" (vazio se livre)
port_holder() {
    local port=$1 pid cmd
    pid=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1)
    [ -z "$pid" ] && return
    cmd=$(ps -p "$pid" -o args= 2>/dev/null)
    echo "${pid}|${cmd}"
}

# Processos que o painel reconhece como SEUS (podem ser mortos sem medo)
is_known_proc() {
    case "$1" in
        *proxy.py*|*wss.py*|*wss_security.py*|*netsimon-bhttp*|*stunnel*|*xray*|*vpn_multiplexer.py*|*dnstt*) return 0 ;;
    esac
    return 1
}

# ── snapshot do que estava ligado ────────────────────────────────
# linha: unit|ativo(1/0)|habilitado(1/0)
mux_take_snapshot() {
    local units u
    units="xray.service netsimon-stunnel.service netsimon-bhttp.service netsimon-bhttpd.service"
    units="$units $(systemctl list-units --type=service --all --no-legend 'proxy@*.service' 'wss@*.service' 'wss-security@*.service' 2>/dev/null | awk '{print $1}' | grep -E '@[0-9]+\.service$')"
    units="$units $(ls /etc/systemd/system/multi-user.target.wants/ 2>/dev/null | grep -E '^(proxy|wss|wss-security)@[0-9]+\.service$')"
    : > "$MUX_SNAPSHOT.tmp"
    for u in $(echo $units | tr ' ' '\n' | sort -u); do
        local a=0 e=0
        unit_active "$u" && a=1
        unit_enabled "$u" && e=1
        [ "$a" = "1" ] || [ "$e" = "1" ] && echo "${u}|${a}|${e}" >> "$MUX_SNAPSHOT.tmp"
    done
    mv -f "$MUX_SNAPSHOT.tmp" "$MUX_SNAPSHOT"
}

snap_has() {   # snap_has <regex-da-unit> -> 0 se estava ativo OU habilitado
    grep -Eq "^($1)\|" "$MUX_SNAPSHOT" 2>/dev/null
}

# ── xray: config DERIVADO (o config.json real nunca é alterado) ──
# Assim os links VLESS, o cadastro de usuários e o resto do painel
# (que assumem a porta 443) continuam certos; só o processo do Xray
# sobe numa porta interna. Regerado a cada (re)início do Xray.
mux_xray_derive() {
    [ -f "$XRAY_CONF" ] || exit 1
    mkdir -p "$MUX_DIR"
    local tmp; tmp=$(mktemp)
    if jq --argjson p "$P_XRAY" \
        '(.inbounds[]? | select(.protocol != "dokodemo-door")) |= (.port = $p | .listen = "127.0.0.1")' \
        "$XRAY_CONF" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && jq . "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$XRAY_MUX_CONF"
        chmod 600 "$XRAY_MUX_CONF"
        exit 0
    fi
    rm -f "$tmp"
    exit 1
}

mux_xray_dropin_on() {
    mkdir -p "$XRAY_DROPIN_DIR"
    cat > "$XRAY_DROPIN" << EOF
# Gerado pelo Netsimon Multiplex — removido ao desativar o mux.
[Service]
ExecStartPre=/bin/bash $BASE/multiplex.sh xray-derive
ExecStart=
ExecStart=$XRAY_BIN run -config $XRAY_MUX_CONF
EOF
    systemctl daemon-reload
}

mux_xray_dropin_off() {
    if [ -f "$XRAY_DROPIN" ]; then
        rm -f "$XRAY_DROPIN"
        rmdir "$XRAY_DROPIN_DIR" 2>/dev/null
        systemctl daemon-reload
    fi
}

# ── stunnel: reescreve a porta de escuta pra interna (127.0.0.1) ────
# O painel é dono do stunnel.conf (gerado por painel_api.py), então em vez
# de drop-in a gente guarda uma cópia do arquivo original e troca a linha
# "accept = <porta>" por "accept = 127.0.0.1:<porta interna>". Restaura a
# cópia ao desativar — o admin pode reconfigurar o Stunnel normalmente pela
# tela dele (isso invalida a cópia; o mux detecta e refaz na próxima ativação).
mux_stunnel_apply() {
    [ -f "$STUNNEL_CONF" ] || return 1
    if [ ! -f "$STUNNEL_CONF_BACKUP" ]; then
        cp -f "$STUNNEL_CONF" "$STUNNEL_CONF_BACKUP"
    fi
    sed -E "s/^accept[[:space:]]*=.*/accept = 127.0.0.1:${P_STUNNEL}/" "$STUNNEL_CONF_BACKUP" > "$STUNNEL_CONF.tmp" \
        && mv -f "$STUNNEL_CONF.tmp" "$STUNNEL_CONF"
}

mux_stunnel_restore() {
    if [ -f "$STUNNEL_CONF_BACKUP" ]; then
        mv -f "$STUNNEL_CONF_BACKUP" "$STUNNEL_CONF"
    fi
}

# ── monta config do mux + configs internos dos backends ─────────
# Decide QUAIS backends sobem e grava $MUX_CONF + $MUX_BACKENDS.
mux_build_config() {
    local have_xray=0 have_wss=0 have_bhttpd=0 have_bhttp=0 have_cert=0 have_stunnel=0
    [ -x "$XRAY_BIN" ] && [ -f "$XRAY_CONF" ] && have_xray=1
    [ -f "$BASE/wss.py" ] && [ -f "$WSS_DIR/cert.pem" ] && [ -f "$WSS_DIR/key.pem" ] && have_wss=1
    [ -x "$BHTTPD_BIN" ] && have_bhttpd=1
    [ -x "$BHTTP_BIN" ] && [ -f "$BHTTP_CONF" ] && have_bhttp=1
    [ -f "$WSS_DIR/cert.pem" ] && [ -f "$WSS_DIR/key.pem" ] && have_cert=1
    [ -f "$STUNNEL_CONF" ] && have_stunnel=1

    local snap_xray=0 snap_wss=0 snap_stunnel=0
    snap_has 'xray\.service' && snap_xray=1
    snap_has 'wss@[0-9]+\.service' && snap_wss=1
    snap_has 'netsimon-stunnel\.service' && snap_stunnel=1

    python3 - "$MUX_SETTINGS" "$MUX_CONF" "$MUX_BACKENDS" "$BHTTP_CONF" "$BHTTP_MUX_CONF" \
        "$BHTTPD_CONF" "$BHTTPD_MUX_CONF" "$WSS_DIR" \
        "$have_xray" "$have_wss" "$have_bhttpd" "$have_bhttp" "$have_cert" "$snap_xray" "$snap_wss" \
        "$P_WS" "$P_WSS" "$P_BHTTP" "$P_BHTTPD" "$P_BHTTPD_TLS" "$P_XRAY" \
        "$have_stunnel" "$snap_stunnel" "$P_STUNNEL" << 'PYEOF'
import json, os, sys

(settings_path, conf_out, backends_out, bhttp_conf, bhttp_mux, bhttpd_conf, bhttpd_mux,
 wss_dir, have_xray, have_wss, have_bhttpd, have_bhttp, have_cert, snap_xray, snap_wss,
 p_ws, p_wss, p_bhttp, p_bhttpd, p_bhttpd_tls, p_xray,
 have_stunnel, snap_stunnel, p_stunnel) = sys.argv[1:]
have_xray, have_wss, have_bhttpd, have_bhttp, have_cert, snap_xray, snap_wss, have_stunnel, snap_stunnel = (
    x == "1" for x in (have_xray, have_wss, have_bhttpd, have_bhttp, have_cert, snap_xray, snap_wss, have_stunnel, snap_stunnel))
p_ws, p_wss, p_bhttp, p_bhttpd, p_bhttpd_tls, p_xray, p_stunnel = map(int, (p_ws, p_wss, p_bhttp, p_bhttpd, p_bhttpd_tls, p_xray, p_stunnel))

st = {}
if os.path.exists(settings_path):
    for line in open(settings_path):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            st[k] = v
http_port = int(st.get("MUX_HTTP_PORT", "80") or 80)
https_port = int(st.get("MUX_HTTPS_PORT", "443") or 443)
tls_default = st.get("MUX_TLS_DEFAULT", "auto") or "auto"
bhttp_impl = st.get("MUX_BHTTP_IMPL", "bhttpd") or "bhttpd"
max_ip = int(st.get("MUX_MAX_CONN_IP", "200") or 200)
fallback = float(st.get("MUX_FALLBACK_SEC", "2") or 2)

sni_map = {}
for item in (st.get("MUX_SNI_MAP", "") or "").split(","):
    item = item.strip()
    if "=" in item:
        h, b = item.split("=", 1)
        h, b = h.strip().lower(), b.strip()
        if h and b in ("xray", "wss", "bhttpd_tls"):
            sni_map[h] = b

wanted_tls = set(sni_map.values())
if tls_default in ("xray", "wss", "bhttpd", "stunnel"):
    wanted_tls.add("bhttpd_tls" if tls_default == "bhttpd" else tls_default)

backends = {"ssh_direct": {"host": "127.0.0.1", "port": 22}}
units = []

# WS (proxy.py): sempre — atende WebSocket e HTTP genérico
backends["websocket"] = {"host": "127.0.0.1", "port": p_ws}
backends["open_proxy"] = {"host": "127.0.0.1", "port": p_ws}
units.append("netsimon-mux-ws")

# Correção 17/10/2026: antes, Xray/WSS/Stunnel só entravam no mux se já
# estivessem rodando no momento da ativação (snapshot) ou fossem o destino
# TLS/SNI explícito. Isso deixava backends instalados (ex.: wss.py com
# cert/key prontos) de fora da config SEM AVISO — foi a causa raiz do WSS
# não atender via Multiplex em 16/10/2026. Agora: todo protocolo que está
# de fato INSTALADO no servidor (have_xray/have_wss/have_stunnel) sobe
# junto com o mux, independente do que estava ligado antes. "instalado !=
# ativado" continua valendo pro painel em geral (ninguém liga Xray/Stunnel
# sozinho fora do mux); dentro do mux, o próprio ato de ativá-lo agora É o
# "ativado" de todos os protocolos que ele sabe gerenciar.

# Xray: sobe sempre que estiver instalado (binário + config.json)
use_xray = have_xray
if use_xray:
    backends["xray"] = {"host": "127.0.0.1", "port": p_xray}
    units.append("xray")

# WSS TLS (wss.py): sobe sempre que estiver instalado (wss.py + cert/key)
use_wss = have_wss
if use_wss:
    backends["wss"] = {"host": "127.0.0.1", "port": p_wss}
    units.append("netsimon-mux-wss")

# Stunnel (SSH sobre TLS "cru"): sobe sempre que estiver instalado
# (stunnel.conf existente). Diferente dos outros backends, a unit é a
# própria netsimon-stunnel (não tem versão "mux-" dela: é o mesmo Stunnel
# do painel, só que escutando internamente enquanto o mux estiver no
# comando).
use_stunnel = have_stunnel
if use_stunnel:
    backends["stunnel"] = {"host": "127.0.0.1", "port": p_stunnel}
    units.append("netsimon-stunnel")

# BHTTP: só a implementação escolhida sobe (ambas escutam o mesmo tipo de frame)
if bhttp_impl == "bhttpd" and have_bhttpd:
    ssh = {"host": "127.0.0.1", "port": 22}
    base = {}
    if os.path.exists(bhttpd_conf):
        try:
            base = json.load(open(bhttpd_conf))
            ssh = base.get("backend", ssh)
        except Exception:
            base = {}
    listen = [{"host": "127.0.0.1", "port": p_bhttpd, "tls": False}]
    use_bhttpd_tls = have_cert and "bhttpd_tls" in wanted_tls
    if use_bhttpd_tls:
        listen.append({"host": "127.0.0.1", "port": p_bhttpd_tls, "tls": True})
        backends["bhttpd_tls"] = {"host": "127.0.0.1", "port": p_bhttpd_tls}
    cfg = {
        "listen": listen,
        "tls": {"cert_file": os.path.join(wss_dir, "cert.pem"), "key_file": os.path.join(wss_dir, "key.pem")},
        "backend": ssh,
        "session": base.get("session", {"idle_timeout_seconds": 300, "max_buffered_chunks": 4096}),
        "log": base.get("log", {"level": "info"}),
    }
    os.makedirs(os.path.dirname(bhttpd_mux), exist_ok=True)
    json.dump(cfg, open(bhttpd_mux, "w"), indent=2)
    backends["bhttp"] = {"host": "127.0.0.1", "port": p_bhttpd}
    units.append("netsimon-mux-bhttpd")
elif bhttp_impl == "bhttp" and have_bhttp:
    try:
        cfg = json.load(open(bhttp_conf))
    except Exception:
        cfg = {}
    cfg.setdefault("proxy", {})["enabled"] = True
    cfg["proxy"]["listen"] = [{"host": "127.0.0.1", "port": p_bhttp, "ssl": False}]
    json.dump(cfg, open(bhttp_mux, "w"), indent=2)
    backends["bhttp"] = {"host": "127.0.0.1", "port": p_bhttp}
    units.append("netsimon-mux-bhttp")

# destino TLS padrão
if tls_default == "auto":
    default_tls = next((n for n in ("xray", "wss", "stunnel", "bhttpd_tls") if n in backends), "drop")
else:
    default_tls = {"bhttpd": "bhttpd_tls"}.get(tls_default, tls_default)  # "stunnel" já bate com a chave do backend
    if default_tls not in backends:
        default_tls = "drop"
# SNI apontando pra backend que não subiu vira "drop" no lugar de erro
sni_map = {h: b for h, b in sni_map.items() if b in backends}

conf = {
    "listen": {
        "public_ports": sorted({http_port, https_port}),
        "bind_address": "0.0.0.0",
        "peek_bytes": 4096,
        "peek_timeout_seconds": fallback,
    },
    "backends": backends,
    "sni_routing": sni_map,
    "default_tls_backend": default_tls,
    "default_unknown_action": "drop",
    "on_timeout_backend": "ssh_direct",
    "bhttp_backend": "bhttp",
    "fallback_timeout_seconds": fallback,
    "handshake_timeout_seconds": 10,
    "max_conn_per_ip": max_ip,
    "logging": {"level": "INFO", "file": "/var/log/netsimon_mux.log"},
}
json.dump(conf, open(conf_out, "w"), indent=2)
open(backends_out, "w").write("\n".join(units) + "\n")
print("backends: " + ", ".join(sorted(backends)) + " | tls padrão: " + default_tls)
PYEOF
}

wait_listen() {   # wait_listen <porta> [segundos]
    local port=$1 n=${2:-8} i
    for ((i=0; i<n*2; i++)); do
        ss -ltnH "sport = :$port" 2>/dev/null | grep -q . && return 0
        sleep 0.5
    done
    return 1
}

# ── liberar as portas públicas ───────────────────────────────────
# retorna 0 = livres | 3 = presas por processo desconhecido (sem --force)
mux_free_ports() {
    local force=$1; shift
    local port holder pid cmd blocked=0
    for port in "$@"; do
        holder=$(port_holder "$port")
        [ -z "$holder" ] && continue
        pid=${holder%%|*}; cmd=${holder#*|}
        if is_known_proc "$cmd" || [ "$force" = "1" ]; then
            echo -e "${Y}[!] Porta $port presa por PID $pid ($cmd) — encerrando.${NC}"
            kill "$pid" 2>/dev/null; sleep 1
            [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
            sleep 0.5
        else
            echo "BLOCKED_BY=${port}|${pid}|${cmd}"
            echo -e "${R}[ERRO] Porta $port está com um processo que o painel não reconhece (PID $pid: $cmd).${NC}"
            blocked=1
        fi
    done
    [ "$blocked" = "1" ] && return 3
    return 0
}

# ── ATIVAR ───────────────────────────────────────────────────────
mux_start() {
    local force=0 a
    for a in "$@"; do [ "$a" = "--force" ] && force=1; done

    mux_installed || { echo -e "${Y}[+] Multiplex ainda não instalado — instalando agora...${NC}"; mux_install || return 1; }
    for a in vpn_multiplexer.py proxy.py; do
        [ -f "$BASE/$a" ] || { echo -e "${R}[ERRO] $BASE/$a ausente — reinstale o painel.${NC}"; return 1; }
    done

    local http_port https_port
    http_port=$(get_setting MUX_HTTP_PORT 80); https_port=$(get_setting MUX_HTTPS_PORT 443)
    valid_port "$http_port" && valid_port "$https_port" || { echo -e "${R}[ERRO] Portas inválidas nas configurações do mux.${NC}"; return 1; }

    # Se já está ativo, é um "aplicar configuração": mantém o snapshot original
    local already=0
    mux_active && already=1
    if [ "$already" = "0" ]; then
        mux_take_snapshot
    fi

    # 1) checa ANTES se dá pra liberar as portas (não desliga nada se não der)
    if [ "$already" = "0" ]; then
        local p holder cmd
        for p in $(echo "$http_port $https_port" | tr ' ' '\n' | sort -u); do
            holder=$(port_holder "$p")
            [ -z "$holder" ] && continue
            cmd=${holder#*|}
            if ! is_known_proc "$cmd" && [ "$force" != "1" ]; then
                echo "BLOCKED_BY=${p}|${holder%%|*}|${cmd}"
                echo -e "${R}[ERRO] Porta $p está com um processo que o painel não reconhece (PID ${holder%%|*}: $cmd). Nada foi alterado.${NC}"
                rm -f "$MUX_SNAPSHOT"
                return 3
            fi
        done
    fi

    echo -e "${Y}[+] Assumindo o controle das portas $http_port/$https_port...${NC}"

    # 2) para e desabilita tudo que estava ligado (snapshot) + qualquer resíduo do mux
    if [ "$already" = "0" ]; then
        local line unit
        while IFS='|' read -r unit _ _; do
            [ -z "$unit" ] && continue
            systemctl disable "$unit" &>/dev/null
            systemctl stop "$unit" &>/dev/null
        done < "$MUX_SNAPSHOT"
    fi
    for unit in $MUX_UNIT $BACKEND_UNITS; do systemctl stop "$unit" &>/dev/null; done
    sleep 1

    # 3) mata o que ainda estiver segurando as portas públicas
    mux_free_ports "$force" $(echo "$http_port $https_port" | tr ' ' '\n' | sort -u)
    local rc=$?
    if [ $rc -ne 0 ]; then
        mux_rollback
        return $rc
    fi

    # 4) monta o config e sobe os backends internos
    local info; info=$(mux_build_config) || { echo -e "${R}[ERRO] Falha ao montar o config do mux.${NC}"; mux_rollback; return 1; }
    echo -e "${C}    $info${NC}"

    local b started_xray=0 started_stunnel=0
    while read -r b; do
        [ -z "$b" ] && continue
        if [ "$b" = "xray" ]; then
            mux_xray_dropin_on
            bash "$BASE/multiplex.sh" xray-derive || { echo -e "${R}[ERRO] Não consegui gerar o config interno do Xray.${NC}"; mux_rollback; return 1; }
            systemctl enable "$b" &>/dev/null; systemctl restart "$b" &>/dev/null
            started_xray=1
        elif [ "$b" = "netsimon-stunnel" ]; then
            mux_stunnel_apply || { echo -e "${R}[ERRO] Não consegui reescrever o stunnel.conf.${NC}"; mux_rollback; return 1; }
            systemctl enable "$b" &>/dev/null; systemctl restart "$b" &>/dev/null
            started_stunnel=1
        else
            systemctl enable "$b" &>/dev/null; systemctl restart "$b" &>/dev/null
        fi
    done < "$MUX_BACKENDS"
    # Xray/Stunnel não são mais backend (ex.: mudou o destino TLS ao reaplicar):
    # para o processo que ainda estava na porta interna e desfaz a alteração.
    if [ "$started_xray" = "0" ] && [ -f "$XRAY_DROPIN" ]; then
        systemctl disable xray &>/dev/null
        systemctl stop xray &>/dev/null
        mux_xray_dropin_off
    fi
    if [ "$started_stunnel" = "0" ] && [ -f "$STUNNEL_CONF_BACKUP" ]; then
        systemctl disable netsimon-stunnel &>/dev/null
        systemctl stop netsimon-stunnel &>/dev/null
        mux_stunnel_restore
    fi

    # confere que cada backend interno realmente abriu sua porta
    local name host port
    while read -r name host port; do
        [ -z "$name" ] && continue
        [ "$name" = "ssh_direct" ] && continue
        if ! wait_listen "$port" 10; then
            echo -e "${R}[ERRO] Backend '$name' não abriu a porta interna $port.${NC}"
            mux_rollback
            return 1
        fi
    done < <(python3 -c "
import json
for n,b in json.load(open('$MUX_CONF'))['backends'].items(): print(n,b['host'],b['port'])")

    # 5) sobe o mux nas portas públicas
    python3 "$MUX_PY" --config "$MUX_CONF" --check >/dev/null 2>&1 || { echo -e "${R}[ERRO] Config do mux inválido.${NC}"; mux_rollback; return 1; }
    systemctl enable "$MUX_UNIT" &>/dev/null
    systemctl restart "$MUX_UNIT" &>/dev/null
    local p ok=1
    for p in $(echo "$http_port $https_port" | tr ' ' '\n' | sort -u); do
        wait_listen "$p" 8 || ok=0
    done
    if [ "$ok" = "1" ] && mux_active; then
        echo -e "${G}[OK] Netsimon Multiplex ATIVO nas portas $http_port/$https_port.${NC}"
        return 0
    fi
    echo -e "${R}[ERRO] O mux não subiu. Últimas linhas do log:${NC}"
    tail -n 8 "$MUX_LOG" 2>/dev/null
    mux_rollback
    return 1
}

# desliga só as peças do mux (sem restaurar nada)
mux_teardown() {
    local u
    for u in $MUX_UNIT $BACKEND_UNITS; do
        systemctl disable "$u" &>/dev/null
        systemctl stop "$u" &>/dev/null
    done
    if [ -f "$XRAY_DROPIN" ]; then
        # o mux habilitou o xray como backend: desfaz (o snapshot religa se
        # ele já estava habilitado antes) — senão voltaria no boot na 443.
        systemctl disable xray &>/dev/null
        systemctl stop xray &>/dev/null
        mux_xray_dropin_off
    fi
    rm -f "$XRAY_MUX_CONF"
    if [ -f "$STUNNEL_CONF_BACKUP" ]; then
        systemctl disable netsimon-stunnel &>/dev/null
        systemctl stop netsimon-stunnel &>/dev/null
        mux_stunnel_restore
    fi
}

# devolve ao estado do snapshot (o que estava ativo/habilitado volta)
mux_restore_snapshot() {
    [ -f "$MUX_SNAPSHOT" ] || return 0
    local unit a e
    while IFS='|' read -r unit a e; do
        [ -z "$unit" ] && continue
        [ "$e" = "1" ] && systemctl enable "$unit" &>/dev/null
        [ "$a" = "1" ] && systemctl start "$unit" &>/dev/null
    done < "$MUX_SNAPSHOT"
    rm -f "$MUX_SNAPSHOT"
}

mux_rollback() {
    echo -e "${Y}[!] Desfazendo: devolvendo os serviços ao estado anterior...${NC}"
    mux_teardown
    mux_restore_snapshot
}

# ── DESATIVAR ────────────────────────────────────────────────────
mux_stop() {
    local restore=1 a
    for a in "$@"; do [ "$a" = "--no-restore" ] && restore=0; done
    mux_teardown
    if [ "$restore" = "1" ]; then
        mux_restore_snapshot
        echo -e "${G}[OK] Multiplex desativado — painel voltou ao funcionamento padrão (serviços de antes religados).${NC}"
    else
        rm -f "$MUX_SNAPSHOT"
        echo -e "${G}[OK] Multiplex desativado (sem religar os serviços de antes).${NC}"
    fi
    return 0
}

mux_status() {
    if ! mux_installed; then echo -e "${Y}NÃO INSTALADO${NC}"; return; fi
    if mux_active; then echo -e "${G}ATIVO ●${NC}"; else echo -e "${R}INATIVO${NC}"; fi
}

# ── configuração ─────────────────────────────────────────────────
mux_configure() {
    local http="" https="" tlsdef="" impl="" sni="__keep__" maxip="" fb=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --http)        http=$2; shift 2 ;;
            --https)       https=$2; shift 2 ;;
            --tls-default) tlsdef=$2; shift 2 ;;
            --bhttp)       impl=$2; shift 2 ;;
            --sni)         sni=$2; shift 2 ;;
            --max-ip)      maxip=$2; shift 2 ;;
            --fallback)    fb=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "$MUX_DIR"
    [ -f "$MUX_SETTINGS" ] || printf 'MUX_HTTP_PORT=80\nMUX_HTTPS_PORT=443\nMUX_TLS_DEFAULT=wss\nMUX_BHTTP_IMPL=bhttpd\nMUX_SNI_MAP=\nMUX_MAX_CONN_IP=200\nMUX_FALLBACK_SEC=2\n' > "$MUX_SETTINGS"
    if [ -n "$http" ];  then valid_port "$http"  || { echo "porta HTTP inválida"; return 1; }; set_setting MUX_HTTP_PORT "$http"; fi
    if [ -n "$https" ]; then valid_port "$https" || { echo "porta HTTPS inválida"; return 1; }; set_setting MUX_HTTPS_PORT "$https"; fi
    if [ -n "$tlsdef" ]; then
        [[ "$tlsdef" =~ ^(auto|xray|wss|bhttpd|stunnel)$ ]] || { echo "destino TLS inválido"; return 1; }
        set_setting MUX_TLS_DEFAULT "$tlsdef"
    fi
    if [ -n "$impl" ]; then
        [[ "$impl" =~ ^(bhttpd|bhttp)$ ]] || { echo "implementação BHTTP inválida"; return 1; }
        set_setting MUX_BHTTP_IMPL "$impl"
    fi
    if [ "$sni" != "__keep__" ]; then
        [[ "$sni" =~ ^([A-Za-z0-9._-]+=(xray|wss|bhttpd_tls|stunnel))?(,[A-Za-z0-9._-]+=(xray|wss|bhttpd_tls|stunnel))*$ ]] || { echo "mapa SNI inválido (use host=xray,host2=wss,host3=stunnel)"; return 1; }
        set_setting MUX_SNI_MAP "$sni"
    fi
    if [ -n "$maxip" ]; then [[ "$maxip" =~ ^[0-9]+$ ]] || { echo "limite por IP inválido"; return 1; }; set_setting MUX_MAX_CONN_IP "$maxip"; fi
    if [ -n "$fb" ];    then [[ "$fb" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "timeout inválido"; return 1; }; set_setting MUX_FALLBACK_SEC "$fb"; fi
    echo -e "${G}[OK] Configuração do Multiplex salva.${NC}"
}

case "$1" in
    install)     mux_install ;;
    start)       shift; mux_start "$@" ;;
    stop)        shift; mux_stop "$@" ;;
    restart)     shift; mux_start "$@" ;;
    status)      mux_status ;;
    configure)   shift; mux_configure "$@" ;;
    xray-derive) mux_xray_derive ;;
    *)
        echo "Uso: $0 {install|start [--force]|stop [--no-restore]|restart|status|configure [--http N] [--https N] [--tls-default auto|xray|wss|bhttpd] [--bhttp bhttpd|bhttp] [--sni host=xray,...]}"
        ;;
esac
