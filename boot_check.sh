#!/bin/bash
# ==========================================
#   PAINEL NETSIMON - AUTO-RECOVERY NO BOOT
# ==========================================

BASE="/etc/painel"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_LOG="/var/log/xray/access.log"

# 9.0: substitui sleep 15 fixo por espera ativa de rede
# — em servidores rápidos sobe mais cedo, em lentos espera o necessário
aguarda_rede() {
    local tentativas=0
    while [ $tentativas -lt 30 ]; do
        if ip route get 8.8.8.8 &>/dev/null; then
            return 0
        fi
        sleep 2
        ((tentativas++))
    done
    return 1  # timeout de 60s — continua mesmo assim
}
aguarda_rede

# Garante que o diretório de log do Xray existe corretamente
mkdir -p /var/log/xray

# 1. Limiter
# FIX (18/10/2026): antes religava o Limiter em TODO boot, mesmo que o admin
# o tivesse desativado de propósito pelo painel (por isso ele "voltava sozinho"
# depois de um reinício). Agora só religa se a intenção registrada pelo painel
# em /etc/painel/limiter_intent for "on" (admin ativou). "off" ou arquivo
# ausente (nunca ativado pelo painel) = não liga nada — mesma regra do Xray/proxy.
LIMITER_INTENT="$(cat "$BASE/limiter_intent" 2>/dev/null | tr -d '[:space:]')"
if [ "$LIMITER_INTENT" = "on" ] && ! pgrep -f "limit.sh" > /dev/null; then
    screen -dmS limitador bash "$BASE/limit.sh"
fi

# 2. Xray
# v45: só religa no boot se o admin JÁ TIVER ATIVADO manualmente pelo
# painel (systemctl enable) — se nunca foi ativado, fica desligado e a
# porta 443 continua livre, mesmo depois de reiniciar o servidor.
if [ -f "/usr/local/bin/xray" ] && [ -f "$XRAY_CONF" ]; then
    if systemctl is-enabled --quiet xray 2>/dev/null && ! systemctl is-active --quiet xray; then
        systemctl start xray
    fi
fi

# 3. WebSocket — agora são serviços systemd de verdade nas 4 portas:
#    proxy@80.service (WS Proxy simples), wss@8443.service (WSS, TLS
#    real) e wss-security@8888.service (Websocket Security, sem TLS,
#    protocolo novo e independente) — Restart=always, igual ao xray.
#    Não sobe mais via screen aqui: isso é só uma rede de segurança
#    extra pro caso de alguém ter parado a unit manualmente e ela não
#    ter religado sozinha por algum motivo. O Stunnel (item 6 abaixo) é
#    o 4º modo, gerenciado à parte por ser um serviço único.
# v45: mesma trava do Xray acima — só religa quem o admin já ativou
#    (systemctl enable) pelo painel; o que nunca foi ativado continua
#    livre na porta, mesmo após reboot.
if systemctl is-enabled --quiet "proxy@80" 2>/dev/null && ! systemctl is-active --quiet "proxy@80"; then
    systemctl start "proxy@80" 2>/dev/null
fi
if systemctl is-enabled --quiet "wss@8443" 2>/dev/null && ! systemctl is-active --quiet "wss@8443"; then
    systemctl start "wss@8443" 2>/dev/null
fi
if systemctl is-enabled --quiet "wss-security@8888" 2>/dev/null && ! systemctl is-active --quiet "wss-security@8888"; then
    systemctl start "wss-security@8888" 2>/dev/null
fi

# 4. CheckUser API
if ! pgrep -f "checkuser.py" > /dev/null; then
    nohup python3 "$BASE/checkuser.py" > /dev/null 2>&1 &
fi

# 5. SlowDNS
if [ -f "/etc/slowdns/priv.key" ] && [ -f "/etc/slowdns/domain" ]; then
    if ! pgrep -f "dnstt-server" > /dev/null; then
        NS=$(cat /etc/slowdns/domain 2>/dev/null || hostname)
        systemctl stop systemd-resolved &>/dev/null
        nohup /etc/slowdns/dnstt-server -udp :5353 \
            -privkey-file /etc/slowdns/priv.key "$NS" 127.0.0.1:22 > /dev/null 2>&1 &
    fi
fi

# 6. Stunnel — SSH sobre TLS "cru" (netsimon-stunnel.service, v41,
#    4º modo do menu WebSocket). Mesma rede de segurança do item 3: só
#    reinicia se já estiver configurado (config gravado por
#    /etc/painel/stunnel/stunnel_settings.conf) e a unit não estiver
#    ativa por algum motivo.
# v45: idem — só religa se o admin já tiver ativado (systemctl enable)
# pelo painel; instalado mas nunca ativado continua livre após reboot.
# 6.1 (v47) BHTTP antigo, BHTTPD novo e Netsimon Multiplex — MESMA regra: só
#     religa se o admin já habilitou (systemctl enable feito pelo painel).
#     Nunca liga nada sozinho; se o Multiplex está habilitado, ele é quem manda
#     em 80/443 (os backends internos dele também estão habilitados).
for u in netsimon-bhttp netsimon-bhttpd netsimon-mux-ws netsimon-mux-wss netsimon-mux-bhttp netsimon-mux-bhttpd netsimon-mux; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null && ! systemctl is-active --quiet "$u"; then
        systemctl start "$u" 2>/dev/null
    fi
done

if [ -f "/etc/painel/stunnel/stunnel_settings.conf" ]; then
    if systemctl is-enabled --quiet "netsimon-stunnel" 2>/dev/null && ! systemctl is-active --quiet "netsimon-stunnel"; then
        systemctl start "netsimon-stunnel" 2>/dev/null
    fi
fi

# 7. Limpeza segura de log do Xray (somente se > 50MB)
#    NÃO apaga logs do sistema — apenas o log de acesso do Xray
if [ -f "$XRAY_LOG" ]; then
    tamanho=$(stat -c%s "$XRAY_LOG" 2>/dev/null || echo 0)
    if [ "$tamanho" -gt 52428800 ]; then
        tail -n 1000 "$XRAY_LOG" > /tmp/xray_access_last.log
        cat /tmp/xray_access_last.log > "$XRAY_LOG"
        rm -f /tmp/xray_access_last.log
    fi
fi

exit 0
