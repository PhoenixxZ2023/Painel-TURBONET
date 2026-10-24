#!/bin/bash
# ==========================================
#   PAINEL NETSIMON - BHTTP MANAGER
#   Instala/ativa/desativa o Netsimon-BHTTP usando o binário JÁ
#   EMBUTIDO no projeto (bhttp/netsimon-bhttp) — nada é baixado de
#   repositórios externos em tempo de instalação ou de ativação.
#   Mesmo espírito do menu WebSocket: instalado != ativado. A ativação
#   é sempre manual, feita pelo admin (CLI aqui ou tela do painel).
# ==========================================

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

BASE="/etc/painel"
BHTTP_SRC_BIN="$BASE/netsimon-bhttp"
BHTTP_INSTALL_DIR="/usr/local/bin"
BHTTP_BIN_NAME="netsimon-bhttp"
BHTTP_BIN="$BHTTP_INSTALL_DIR/$BHTTP_BIN_NAME"
BHTTP_CONFIG_DIR="/etc/netsimon-bhttp"
BHTTP_CONFIG="$BHTTP_CONFIG_DIR/config.json"
BHTTP_UNIT="netsimon-bhttp"

# ── Instala (copia) o binário local pro sistema — NUNCA baixa nada ──
bhttp_install() {
    if [ ! -f "$BHTTP_SRC_BIN" ]; then
        echo -e "${R}[ERRO] Binário não encontrado em $BHTTP_SRC_BIN — reinstale o painel.${NC}"
        return 1
    fi
    cp -f "$BHTTP_SRC_BIN" "$BHTTP_BIN"
    chmod +x "$BHTTP_BIN"

    mkdir -p "$BHTTP_CONFIG_DIR"
    if [ ! -f "$BHTTP_CONFIG" ]; then
        cat > "$BHTTP_CONFIG" << 'EOF'
{
  "server": {
    "virtual_subnet_cidr": "10.10.0.0/16",
    "stats_file": "/etc/netsimon-bhttp/stats.json",
    "auth": {
      "system": true
    },
    "tun": {
      "name": "tun0",
      "buffer_size": 65536
    }
  },
  "proxy": {
    "enabled": true,
    "listen": [
      {
        "host": "0.0.0.0",
        "port": 443,
        "ssl": true
      },
      {
        "host": "0.0.0.0",
        "port": 80,
        "ssl": false
      }
    ]
  }
}
EOF
    fi

    cat > /etc/systemd/system/${BHTTP_UNIT}.service << EOF
[Unit]
Description=Netsimon BHTTP Server
After=network.target

[Service]
Type=simple
ExecStart=$BHTTP_BIN --config $BHTTP_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # v45: só instala — não habilita nem inicia aqui. Ativação é manual
    # (bhttp_start / tela do painel), pra manter 80/443 livres.
    systemctl disable "$BHTTP_UNIT" &>/dev/null
    systemctl stop "$BHTTP_UNIT" &>/dev/null
    return 0
}

bhttp_installed() {
    [ -f "$BHTTP_BIN" ] && [ -f "/etc/systemd/system/${BHTTP_UNIT}.service" ]
}

# ── Configura portas antes de ativar (evita conflito com WS/Xray) ──
bhttp_set_ports() {
    local http_port=${1:-80}
    local https_port=${2:-443}
    [ ! -f "$BHTTP_CONFIG" ] && return 1
    python3 - "$BHTTP_CONFIG" "$http_port" "$https_port" << 'PYEOF'
import json, sys
path, http_port, https_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("proxy", {}).setdefault("listen", [])
cfg["proxy"]["listen"] = [
    {"host": "0.0.0.0", "port": https_port, "ssl": True},
    {"host": "0.0.0.0", "port": http_port, "ssl": False},
]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ── Ativação manual (feita pelo admin, nunca automática no install) ──
bhttp_start() {
    if ! bhttp_installed; then
        echo -e "${Y}[+] BHTTP ainda não instalado — instalando agora (binário local)...${NC}"
        bhttp_install || return 1
    fi
    # Libera as portas que o BHTTP vai usar. v48: chama o portlock.sh
    # (mesma trava usada pelo bhttpd.sh e pela API do painel) em vez da
    # lista manual antiga, que parava proxy@/wss@/wss-security@/xray mas
    # NUNCA o netsimon-bhttpd — rodar este script direto no terminal
    # (fora da API, que já tinha essa proteção via _free_port) subia o
    # BHTTP antigo sem derrubar o novo, recriando o conflito de porta.
    local http_port https_port p rc
    http_port=$(python3 -c "import json;print(next((l['port'] for l in json.load(open('$BHTTP_CONFIG'))['proxy']['listen'] if not l['ssl']),80))" 2>/dev/null)
    https_port=$(python3 -c "import json;print(next((l['port'] for l in json.load(open('$BHTTP_CONFIG'))['proxy']['listen'] if l['ssl']),443))" 2>/dev/null)
    http_port=${http_port:-80}; https_port=${https_port:-443}
    for p in "$http_port" "$https_port"; do
        bash "$BASE/portlock.sh" free "$p" "$BHTTP_UNIT"; rc=$?
        if [ $rc -ne 0 ]; then
            echo -e "${R}[ERRO] Porta $p presa por processo que o painel não reconhece. Nada foi ligado.${NC}"
            return $rc
        fi
    done
    systemctl enable --now "$BHTTP_UNIT" &>/dev/null
    if systemctl is-active --quiet "$BHTTP_UNIT"; then
        echo -e "${G}[OK] Netsimon-BHTTP ativado (porta HTTP $http_port / HTTPS $https_port).${NC}"
    else
        echo -e "${R}[ERRO] Falha ao ativar o BHTTP. Verifique: systemctl status $BHTTP_UNIT${NC}"
        return 1
    fi
}

bhttp_stop() {
    systemctl disable "$BHTTP_UNIT" &>/dev/null
    systemctl stop "$BHTTP_UNIT" &>/dev/null
    echo -e "${G}[OK] Netsimon-BHTTP desativado.${NC}"
}

bhttp_status() {
    if ! bhttp_installed; then
        echo -e "${Y}NÃO INSTALADO${NC}"
        return
    fi
    if systemctl is-active --quiet "$BHTTP_UNIT"; then
        echo -e "${G}ATIVO ●${NC}"
    else
        echo -e "${R}INATIVO${NC}"
    fi
}

case "$1" in
    install) bhttp_install ;;
    start)   bhttp_start ;;
    stop)    bhttp_stop ;;
    status)  bhttp_status ;;
    set-ports) bhttp_set_ports "$2" "$3" ;;
    *)
        echo "Uso: $0 {install|start|stop|status|set-ports <http> <https>}"
        ;;
esac
