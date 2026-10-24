#!/bin/bash
# ==========================================
#   PAINEL NETSIMON - BHTTPD (v47)
#   Gerenciador do NOVO servidor BHTTP (netsimon-bhttpd, Go, código
#   próprio, protocolo BHP1 com download modo 2). É independente do
#   "BHTTP" antigo (binário fechado, bhttp.sh): unit, config e binário
#   próprios — dá para ligar um OU outro para testar e desligar se der bug.
#
#   Instalado != ativado: nada sobe sozinho. Ativar = liberar as portas
#   (portlock.sh: para+desabilita quem estiver nelas, inclusive o
#   Multiplex) e subir. Só é dado como ATIVO se a porta realmente abriu.
#
#   Uso: bhttpd.sh install | build | start [--http N] [--https N|0] | stop |
#                  status | set-ports <http> <https|0> | debug on|off | log
#   Saída: 0 ok | 1 erro | 3 porta presa por processo desconhecido
# ==========================================

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; NC=$'\033[0m'
else
    G=""; R=""; Y=""; C=""; NC=""
fi

BASE="/etc/painel"
SRC_DIR="$BASE/bhttpd/bin"
BIN="/usr/local/bin/netsimon-bhttpd"
CONF_DIR="/etc/netsimon-bhttpd"
CONF="$CONF_DIR/config.json"
SETTINGS="$CONF_DIR/ports.conf"
UNIT="netsimon-bhttpd"
UNIT_FILE="/etc/systemd/system/${UNIT}.service"
CERT="$BASE/wss/cert.pem"
KEY="$BASE/wss/key.pem"

get_setting() { local v; v=$(grep -m1 -oP "^$1=\K.*" "$SETTINGS" 2>/dev/null); echo "${v:-$2}"; }
set_setting() {
    mkdir -p "$CONF_DIR"; touch "$SETTINGS"
    grep -v "^$1=" "$SETTINGS" > "$SETTINGS.tmp" 2>/dev/null
    echo "$1=$2" >> "$SETTINGS.tmp"; mv -f "$SETTINGS.tmp" "$SETTINGS"
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_active()  { systemctl is-active --quiet "$UNIT"; }

pick_binary() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "$SRC_DIR/netsimon-bhttpd-amd64" ;;
        aarch64|arm64) echo "$SRC_DIR/netsimon-bhttpd-arm64" ;;
        *) echo "" ;;
    esac
}

# v47.1: versão esperada do binário (arquivo bhttpd/bin/VERSION, versionado
# junto com o código) e compilação local a partir de bhttpd/src quando o
# binário pré-compilado da arquitetura está desatualizado (ex.: arm64).
SRC_GO="$BASE/bhttpd/src"
expected_version() { tr -d ' \r\n' < "$SRC_DIR/VERSION" 2>/dev/null; }
bin_version()      { "$1" -version 2>/dev/null | awk '{print $2}'; }
find_go() {
    local g; g=$(command -v go 2>/dev/null)
    [ -z "$g" ] && [ -x /usr/local/go/bin/go ] && g=/usr/local/go/bin/go
    echo "$g"
}
build_from_source() {   # build_from_source <arquivo-destino>
    local gobin; gobin=$(find_go)
    [ -n "$gobin" ] || { echo -e "${Y}[!] Go não instalado — não dá para compilar a partir de $SRC_GO.${NC}"; return 1; }
    [ -f "$SRC_GO/go.mod" ] || { echo -e "${Y}[!] Código-fonte ausente em $SRC_GO.${NC}"; return 1; }
    echo -e "${Y}[+] Compilando netsimon-bhttpd a partir do código-fonte...${NC}"
    ( cd "$SRC_GO" && CGO_ENABLED=0 "$gobin" build -trimpath -ldflags="-s -w" -o "$1" ./cmd/netsimon-bhttpd ) 2>&1 | tail -5
    [ -s "$1" ] && chmod 755 "$1"
}

wait_listen() {   # wait_listen <porta> [seg]
    local i; for ((i=0; i<${2:-8}*2; i++)); do
        ss -ltnH "sport = :$1" 2>/dev/null | grep -q . && return 0; sleep 0.5
    done; return 1
}

do_install() {
    local src; src=$(pick_binary)
    if [ -z "$src" ] || [ ! -s "$src" ]; then
        echo -e "${R}[ERRO] Binário BHTTPD não encontrado (ou vazio) para $(uname -m) em $SRC_DIR.${NC}"; return 1
    fi
    # confere integridade contra o SHA256SUMS que acompanha o painel
    if [ -s "$SRC_DIR/SHA256SUMS" ]; then
        ( cd "$SRC_DIR" && grep " $(basename "$src")\$" SHA256SUMS | sha256sum -c --quiet - ) \
            || { echo -e "${R}[ERRO] SHA256 do binário não confere — reinstale o painel.${NC}"; return 1; }
    else
        echo -e "${Y}[!] SHA256SUMS ausente/vazio — integridade do binário não verificada.${NC}"
    fi
    # v47.1: o binário precisa ser da versão do código (corrige o probe de
    # upload). Se não for, tenta compilar; sem Go, instala mesmo assim e avisa.
    local want have tmpbin=""
    want=$(expected_version); have=$(bin_version "$src")
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
        echo -e "${Y}[!] Binário pré-compilado é ${have:-desconhecido}; esperado $want.${NC}"
        tmpbin=$(mktemp /tmp/netsimon-bhttpd.XXXXXX)
        if build_from_source "$tmpbin" && [ "$(bin_version "$tmpbin")" = "$want" ]; then
            src="$tmpbin"
        else
            rm -f "$tmpbin"; tmpbin=""
            echo -e "${R}[AVISO] Usando binário DESATUALIZADO ($have): o app pode calibrar upload em 10 bytes (lento).${NC}"
            echo -e "${R}        Correção: instale Go >= 1.22 e rode: bash $BASE/bhttpd.sh build${NC}"
        fi
    fi
    mkdir -p "$CONF_DIR"
    # troca do binário sem "text file busy" mesmo com o serviço rodando
    cp -f "$src" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN" || return 1
    [ -n "$tmpbin" ] && rm -f "$tmpbin"
    [ -f "$SETTINGS" ] || printf 'BHTTPD_HTTP_PORT=80\nBHTTPD_HTTPS_PORT=443\nBHTTPD_BACKEND=127.0.0.1:22\nBHTTPD_LOG=info\nBHTTPD_WAIT_MS=8000\n' > "$SETTINGS"
    cat > "$UNIT_FILE" << EOF
[Unit]
Description=Netsimon BHTTPD - servidor BHTTP (BHP1) novo
After=network.target sshd.service

[Service]
Type=simple
ExecStart=$BIN -config $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # instalado != ativado: garante desligado e desabilitado
    if ! is_active; then systemctl disable "$UNIT" &>/dev/null; fi
    write_config >/dev/null 2>&1
    echo -e "${G}[OK] BHTTPD $("$BIN" -version 2>/dev/null | awk '{print $2}') instalado (não ativado).${NC}"
}

# Recompila do código-fonte e instala por cima de $BIN (reinicia se estiver ativo)
do_build() {
    local tmp; tmp=$(mktemp /tmp/netsimon-bhttpd.XXXXXX)
    if ! build_from_source "$tmp" || [ ! -s "$tmp" ]; then rm -f "$tmp"; echo -e "${R}[ERRO] Compilação falhou.${NC}"; return 1; fi
    mkdir -p "$CONF_DIR"
    cp -f "$tmp" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN"; rm -f "$tmp"
    is_active && systemctl restart "$UNIT"
    echo -e "${G}[OK] BHTTPD $(bin_version "$BIN") compilado e instalado.${NC}"
}

# Gera $CONF a partir de $SETTINGS
write_config() {
    local http https backend bh bp lvl wait ka sc
    http=$(get_setting BHTTPD_HTTP_PORT 80); https=$(get_setting BHTTPD_HTTPS_PORT 443)
    backend=$(get_setting BHTTPD_BACKEND 127.0.0.1:22); lvl=$(get_setting BHTTPD_LOG info)
    wait=$(get_setting BHTTPD_WAIT_MS 8000)
    ka=$(get_setting BHTTPD_KEEPALIVE_S 0)   # v1.3.0: 0 = desligado; teste com 30
    sc=$(get_setting BHTTPD_SLOT_CREDIT 1)   # v1.4.0: 1 = download por crédito (padrão); 0 = esquema antigo
    bh=${backend%:*}; bp=${backend##*:}
    mkdir -p "$CONF_DIR"
    python3 - "$CONF" "$http" "$https" "$bh" "$bp" "$lvl" "$wait" "$CERT" "$KEY" "$ka" "$sc" << 'PYEOF'
import json, os, sys
conf, http, https, bh, bp, lvl, wait, cert, key, ka, sc = sys.argv[1:]
listen = []
if int(http) > 0:
    listen.append({"host": "0.0.0.0", "port": int(http), "tls": False})
# HTTPS só entra se houver certificado (senão o binário ignoraria a porta sem avisar o painel)
if int(https) > 0 and os.path.exists(cert) and os.path.exists(key):
    listen.append({"host": "0.0.0.0", "port": int(https), "tls": True})
cfg = {
    "listen": listen,
    "tls": {"cert_file": cert, "key_file": key},
    "backend": {"host": bh, "port": int(bp)},
    "session": {"idle_timeout_seconds": 300, "max_buffered_chunks": 4096, "download_wait_ms": int(wait), "retain_chunks": 256, "keepalive_idle_seconds": int(ka) if ka.isdigit() else 0, "slot_credit": sc != "0"},
    "log": {"level": lvl if lvl in ("info", "debug") else "info"},
}
tmp = conf + ".tmp"
json.dump(cfg, open(tmp, "w"), indent=2)
os.replace(tmp, conf)
print(" ".join(str(l["port"]) for l in listen))
PYEOF
}

do_start() {
    local a http="" https=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --http)  http=$2;  shift 2 ;;
            --https) https=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -x "$BIN" ] && [ -f "$UNIT_FILE" ] || { echo -e "${Y}[+] BHTTPD ainda não instalado — instalando...${NC}"; do_install || return 1; }
    if [ -n "$http" ];  then { [ "$http" = "0" ] || valid_port "$http"; }  || { echo "porta HTTP inválida"; return 1; }; set_setting BHTTPD_HTTP_PORT "$http"; fi
    if [ -n "$https" ]; then { [ "$https" = "0" ] || valid_port "$https"; } || { echo "porta HTTPS inválida"; return 1; }; set_setting BHTTPD_HTTPS_PORT "$https"; fi

    local ports; ports=$(write_config) || { echo -e "${R}[ERRO] Falha ao gerar o config.${NC}"; return 1; }
    [ -n "$ports" ] || { echo -e "${R}[ERRO] Nenhuma porta configurada (HTTP=0 e sem HTTPS).${NC}"; return 1; }

    # já ativo: só reaplica a config (portlock não pode matar a si mesmo)
    systemctl stop "$UNIT" &>/dev/null
    local p rc
    for p in $ports; do
        bash "$BASE/portlock.sh" free "$p" "$UNIT"; rc=$?
        if [ $rc -ne 0 ]; then
            echo -e "${R}[ERRO] Porta $p presa por processo que o painel não reconhece. Nada foi ligado.${NC}"
            return $rc
        fi
    done
    systemctl enable "$UNIT" &>/dev/null
    systemctl restart "$UNIT" &>/dev/null
    for p in $ports; do
        if ! wait_listen "$p" 8; then
            echo -e "${R}[ERRO] BHTTPD não abriu a porta $p. Últimas linhas do log:${NC}"
            journalctl -u "$UNIT" -n 8 --no-pager 2>/dev/null
            systemctl disable "$UNIT" &>/dev/null; systemctl stop "$UNIT" &>/dev/null
            return 1
        fi
    done
    echo -e "${G}[OK] BHTTPD ATIVO nas portas: $ports${NC}"
}

do_stop() {
    systemctl disable "$UNIT" &>/dev/null
    systemctl stop "$UNIT" &>/dev/null
    echo -e "${G}[OK] BHTTPD desativado.${NC}"
}

do_status() {
    if [ ! -x "$BIN" ] || [ ! -f "$UNIT_FILE" ]; then echo -e "${Y}NÃO INSTALADO${NC}"; return; fi
    if is_active; then echo -e "${G}ATIVO ●${NC}  portas: $(python3 -c "import json;print(' '.join(str(l['port']) for l in json.load(open('$CONF'))['listen']))" 2>/dev/null)"
    else echo -e "${R}INATIVO${NC}"; fi
}

case "$1" in
    install)   do_install ;;
    build)     do_build ;;
    start)     shift; do_start "$@" ;;
    restart)   shift; do_start "$@" ;;
    stop)      do_stop ;;
    status)    do_status ;;
    set-ports)
        valid_port "$2" || [ "$2" = "0" ] || { echo "porta HTTP inválida"; exit 1; }
        valid_port "$3" || [ "$3" = "0" ] || { echo "porta HTTPS inválida"; exit 1; }
        set_setting BHTTPD_HTTP_PORT "$2"; set_setting BHTTPD_HTTPS_PORT "$3"; write_config >/dev/null
        is_active && do_start
        ;;
    debug)
        [ "$2" = "on" ] && set_setting BHTTPD_LOG debug || set_setting BHTTPD_LOG info
        write_config >/dev/null; is_active && systemctl restart "$UNIT"
        echo "log: $(get_setting BHTTPD_LOG info)" ;;
    log)       journalctl -u "$UNIT" -n 60 --no-pager ;;
    *) echo "Uso: $0 {install|build|start [--http N] [--https N|0]|stop|status|set-ports <http> <https|0>|debug on|off|log}" ;;
esac
