#!/bin/bash
# ==========================================
#   PAINEL NETSIMON - TRAVA DE PORTA (v47)
#   Uso:  portlock.sh free <porta> [unit-a-manter]
#         portlock.sh holder <porta>
#   Também pode ser carregado com "source" (define portlock_free_port).
#
#   free: libera <porta> parando E desabilitando (senão volta no boot)
#   qualquer serviço do painel que esteja usando ela — proxy@/wss@/
#   wss-security@ na porta, Xray, Stunnel, BHTTP (antigo), BHTTPD (novo)
#   e o Multiplex — exceto <unit-a-manter>. Depois mata processo órfão
#   que o painel reconheça como seu. Processo desconhecido NÃO é morto
#   (retorna 3), para não derrubar algo alheio ao painel.
# ==========================================
PL_BASE="/etc/painel"

_pl_json_ports() {   # _pl_json_ports <arquivo> <py-expr sobre 'c'>  -> portas, uma por linha
    [ -f "$1" ] || return
    python3 - "$1" "$2" 2>/dev/null << 'PYEOF'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    for p in eval(sys.argv[2]):
        print(int(p))
except Exception:
    pass
PYEOF
}

_pl_setting() { grep -m1 -oP "^$2=\K.*" "$1" 2>/dev/null; }

_pl_stop_unit() {   # para + desabilita
    systemctl disable "$1" &>/dev/null
    systemctl stop "$1" &>/dev/null
}

portlock_free_port() {
    local port=$1 keep=$2 u
    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    for u in "proxy@$port" "wss@$port" "wss-security@$port"; do
        [ "$u" = "$keep" ] && continue
        systemctl is-active --quiet "$u" 2>/dev/null || systemctl is-enabled --quiet "$u" 2>/dev/null && _pl_stop_unit "$u"
    done

    # Xray (porta do inbound principal)
    if [ "$keep" != "xray" ] && [ -f /usr/local/etc/xray/config.json ]; then
        local xp
        xp=$(jq -r '[.inbounds[]? | select(.protocol != "dokodemo-door") | .port][0] // empty' /usr/local/etc/xray/config.json 2>/dev/null)
        [ "$xp" = "$port" ] && _pl_stop_unit xray
    fi

    # Stunnel
    if [ "$keep" != "netsimon-stunnel" ]; then
        local sp; sp=$(_pl_setting "$PL_BASE/stunnel/stunnel_settings.conf" STUNNEL_PORT)
        [ -z "$sp" ] && sp=2053
        [ "$sp" = "$port" ] && _pl_stop_unit netsimon-stunnel
    fi

    # BHTTP antigo
    if [ "$keep" != "netsimon-bhttp" ]; then
        if _pl_json_ports /etc/netsimon-bhttp/config.json "[l['port'] for l in c.get('proxy',{}).get('listen',[])]" | grep -qx "$port"; then
            _pl_stop_unit netsimon-bhttp
        fi
    fi

    # BHTTPD novo
    if [ "$keep" != "netsimon-bhttpd" ]; then
        if _pl_json_ports /etc/netsimon-bhttpd/config.json "[l['port'] for l in c.get('listen',[])]" | grep -qx "$port"; then
            _pl_stop_unit netsimon-bhttpd
        fi
    fi

    # Multiplex (porta pública 80/443 configurada). Ele não funciona "pela
    # metade": se alguém pede uma das portas dele, o mux inteiro é desligado
    # (sem religar o que havia antes — quem pediu a porta é quem manda).
    if [ "$keep" != "netsimon-mux" ] && systemctl is-active --quiet netsimon-mux 2>/dev/null; then
        local mh mp
        mh=$(_pl_setting "$PL_BASE/mux/mux.conf" MUX_HTTP_PORT); mp=$(_pl_setting "$PL_BASE/mux/mux.conf" MUX_HTTPS_PORT)
        if [ "$port" = "${mh:-80}" ] || [ "$port" = "${mp:-443}" ]; then
            bash "$PL_BASE/multiplex.sh" stop --no-restore >/dev/null 2>&1
        fi
    fi

    sleep 0.5
    # processo órfão ainda segurando a porta?
    local pid cmd
    pid=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1)
    [ -z "$pid" ] && return 0
    cmd=$(ps -p "$pid" -o args= 2>/dev/null)
    case "$cmd" in
        *proxy.py*|*wss.py*|*wss_security.py*|*netsimon-bhttp*|*stunnel*|*xray*|*vpn_multiplexer.py*)
            kill "$pid" 2>/dev/null; sleep 1
            [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
            sleep 0.5
            return 0 ;;
    esac
    echo "BLOCKED_BY=${port}|${pid}|${cmd}"
    return 3
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "$1" in
        free)   portlock_free_port "$2" "$3"; exit $? ;;
        holder) ss -ltnpH "sport = :$2" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1 ;;
        *) echo "Uso: $0 {free <porta> [unit-a-manter] | holder <porta>}" ;;
    esac
fi
