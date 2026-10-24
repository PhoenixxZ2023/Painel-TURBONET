#!/bin/bash
# ==============================================================
#  testar-link.sh - Diagnóstico do link CloudFront -> sua VPS
#  Painel Netsimon (Multiplex na porta 80/443)
#
#  Uso:
#    bash testar-link.sh
#    bash testar-link.sh <dominio_cloudfront> <dominio_origem> [caminho]
#    bash testar-link.sh <dominio_cloudfront> - [caminho]   ("-" = sem origem: pula o teste 5)
#  Exemplo:
#    bash testar-link.sh d2onx628d70s0h.cloudfront.net front1.netsimon.online /
#
#  Variáveis opcionais (ex.: VERBOSE=1 bash testar-link.sh):
#    ORIGIN_PORT, STATUS_ESPERADO, MUX_UNIT, MUX_LOG, TIMEOUT, VERBOSE
# ==============================================================
set -u

# ---------- CONFIGURAÇÃO (edite aqui ou passe por argumento) ----------
CF_PADRAO="d2onx628d70s0h.cloudfront.net"    # domínio da distribuição CloudFront
ORIGEM_PADRAO="front1.netsimon.online"       # domínio configurado como ORIGEM no CloudFront
WS_PATH_PADRAO="/"                           # caminho do teste (o mux não roteia por path)
ORIGIN_PORT="${ORIGIN_PORT:-80}"             # porta HTTP da origem
STATUS_ESPERADO="${STATUS_ESPERADO:-netsimon}"   # texto do "101 xxx" que o proxy.py devolve
MUX_UNIT="${MUX_UNIT:-netsimon-mux}"         # serviço do multiplex
MUX_LOG="${MUX_LOG:-/var/log/netsimon_mux.log}"
TIMEOUT="${TIMEOUT:-8}"                      # segundos de espera por teste
VERBOSE="${VERBOSE:-0}"                      # 1 = mostra os cabeçalhos brutos do CloudFront

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,16p' "$0"
    exit 0
fi

for cmd in curl awk sed grep getent; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Falta o comando: $cmd"; exit 2; }
done

# ---------- cores (desligadas se não for terminal) ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; C=""; W=""; N=""
fi

titulo() { echo; echo "${W}${C}[$1] $2${N}"; }
ok()     { echo "  ${G}✔ $*${N}"; }
warn()   { echo "  ${Y}⚠ $*${N}"; }
bad()    { echo "  ${R}✘ $*${N}"; }
info()   { echo "      $*"; }

# tira http://, https://, caminho e porta de um domínio digitado
limpa() {
    local d="$1"
    d="${d#*://}"; d="${d%%/*}"; d="${d%%:*}"
    printf '%s' "$d"
}

CF_DOMAIN=$(limpa "${1:-$CF_PADRAO}")
ORIGEM_DOMAIN=$(limpa "${2:-$ORIGEM_PADRAO}")
# "-" = origem não informada (é o que o painel web usa): o teste 5 é pulado
SEM_ORIGEM=0
if [ "$ORIGEM_DOMAIN" = "-" ]; then
    SEM_ORIGEM=1; ORIGEM_TXT="o domínio da origem"
else
    ORIGEM_TXT="'$ORIGEM_DOMAIN'"
fi
WS_PATH="${3:-$WS_PATH_PADRAO}"
case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac

# ==============================================================
#  Funções de teste e de tradução dos resultados
# ==============================================================

# Faz um handshake WebSocket e guarda o resultado em variáveis P_*
ws_probe() {
    local url="$1" tmp
    tmp=$(mktemp -d)
    P_W=$(curl -sS --http1.1 --connect-timeout 5 -m "$TIMEOUT" -N \
            -D "$tmp/h" -o "$tmp/b" \
            -w '%{time_connect}|%{remote_ip}' \
            -H "Connection: Upgrade" -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Version: 13" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
            "$url" 2>"$tmp/e")
    P_RC=$?
    P_CONNECT="${P_W%%|*}"
    P_IP="${P_W#*|}"
    P_HDR=$(tr -d '\r' < "$tmp/h" 2>/dev/null)
    P_CODE=$(printf '%s\n' "$P_HDR" | awk 'NR==1 && /^HTTP/{print $2; exit}')
    [ -z "$P_CODE" ] && P_CODE="000"
    P_TEXT=$(printf '%s\n' "$P_HDR" | sed -n '1s/^HTTP\/[0-9.]* [0-9]* *//p' | sed 's/[[:space:]]*$//')
    P_BANNER=$(head -c 128 "$tmp/b" 2>/dev/null | tr -d '\0' | grep -a -o 'SSH-[0-9.]*-[^ ]*' | head -n1)
    P_CFID=$(hget "x-amz-cf-id")
    P_POP=$(hget "x-amz-cf-pop")
    P_XCACHE=$(hget "x-cache")
    rm -rf "$tmp"
}

# lê um cabeçalho da última resposta (P_HDR)
hget() {
    printf '%s\n' "$P_HDR" | grep -i "^$1:" | head -n1 | cut -d: -f2- | sed 's/^[[:space:]]*//'
}

# Explica o erro do curl quando NÃO houve resposta HTTP
explica_curl() {   # $1 = código do curl, $2 = tempo de conexão
    case "$1" in
        6)  echo "O nome não foi encontrado (DNS). Domínio escrito errado ou registro DNS inexistente." ;;
        7)  echo "Conexão RECUSADA: nenhum programa escutando nessa porta (serviço parado) ou firewall rejeitando." ;;
        28) if awk -v t="$2" 'BEGIN{exit !(t+0==0)}'; then
                echo "Nem chegou a conectar (tempo esgotado): porta bloqueada por firewall, IP errado ou servidor fora do ar."
            else
                echo "Conectou, mas ficou sem resposta: o serviço aceitou e travou (mux/backend parado ou sobrecarregado)."
            fi ;;
        35|51|58|59|60|77|83)
            echo "Falha de TLS/certificado (HTTPS): o servidor não completou a criptografia ou o certificado é inválido." ;;
        52) echo "O servidor aceitou a conexão e fechou sem responder nada: o mux descartou o pedido (assinatura não reconhecida, limite por IP) ou o backend caiu." ;;
        56) echo "Conexão derrubada no meio (reset): o servidor ou um firewall cortou a conexão." ;;
        *)  echo "Erro de rede do curl (código $1). Rode: curl -v para ver detalhes." ;;
    esac
}

# Explica o código HTTP. Resultado em EX_LVL (ok|warn|bad) e EX_MSG
explica_http() {   # $1 = código, $2 = contexto (cf|origem)
    local c="$1" ctx="$2"
    case "$c" in
        101) EX_LVL=ok;   EX_MSG="Túnel WebSocket aceito." ;;
        200|204) EX_LVL=warn
            EX_MSG="Quem respondeu foi um servidor web comum, e não o seu multiplex. O pedido de túnel foi ignorado: a origem aponta para outro servidor, ou há um site/nginx atendendo essa porta." ;;
        301|302|307|308) EX_LVL=warn
            EX_MSG="Redirecionamento. Ou o CloudFront está forçando outro endereço (Viewer protocol policy), ou a origem é um site que redireciona. O seu mux não redireciona." ;;
        400) EX_LVL=bad
            EX_MSG="Pedido inválido: o CloudFront ou a origem rejeitaram os cabeçalhos. Confira a Origin request policy do behavior (AllViewerExceptHostHeader)." ;;
        403) EX_LVL=bad
            if [ "$ctx" = cf ]; then
                EX_MSG="O CloudFront bloqueou o pedido. Causas comuns: método HTTP não permitido no behavior, política de cache/origem errada, WAF ou restrição geográfica, distribuição desabilitada ou ainda em 'In progress'."
            else
                EX_MSG="O servidor negou o acesso (regra de firewall ou proxy)."
            fi ;;
        404) EX_LVL=bad
            EX_MSG="Caminho não encontrado. Confira se 'Origin path' está vazio na origem; se for um site comum, a origem não é o seu mux." ;;
        405) EX_LVL=bad
            EX_MSG="Método não permitido: no behavior, 'Allowed HTTP methods' deve ser GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE." ;;
        408) EX_LVL=bad
            EX_MSG="Tempo esgotado enviando o pedido (rede lenta ou instável)." ;;
        426) EX_LVL=bad
            EX_MSG="O servidor exige outro protocolo (upgrade) que não foi aceito." ;;
        429) EX_LVL=bad
            EX_MSG="Limite de requisições: muitas conexões do mesmo IP (o mux limita 200 por IP) ou limite do CloudFront." ;;
        500) EX_LVL=bad
            EX_MSG="Erro interno no servidor: o serviço respondeu, mas quebrou ao processar. Veja os logs do serviço." ;;
        502) EX_LVL=bad
            if [ "$ctx" = cf ]; then
                EX_MSG="O CloudFront chegou na origem, mas ela respondeu algo inválido ou fechou a conexão. Em geral: serviço da VPS (mux ou proxy.py) parado/travado, o mux descartou a conexão, ou a origem não é um servidor HTTP/WebSocket."
            else
                EX_MSG="O servidor devolveu uma resposta inválida (serviço interno com problema)."
            fi ;;
        503) EX_LVL=bad
            EX_MSG="Origem indisponível (ou CloudFront sem capacidade). Normalmente o servidor de origem está fora do ar." ;;
        504) EX_LVL=bad
            if [ "$ctx" = cf ]; then
                EX_MSG="O CloudFront não conseguiu falar com a origem a tempo. Causas: porta $ORIGIN_PORT bloqueada para a AWS (firewall/Security List), DNS da origem apontando para IP errado, VPS desligada ou mux parado."
            else
                EX_MSG="O servidor demorou demais para responder."
            fi ;;
        *)
            case "$c" in
                2*) EX_LVL=warn; EX_MSG="Resposta de sucesso (2xx), mas diferente do esperado para um túnel." ;;
                3*) EX_LVL=warn; EX_MSG="Redirecionamento (3xx)." ;;
                4*) EX_LVL=bad;  EX_MSG="Erro no pedido (4xx): algo no pedido ou na configuração do CloudFront foi recusado." ;;
                5*) EX_LVL=bad;  EX_MSG="Erro no servidor (5xx): o lado da origem está com problema." ;;
                *)  EX_LVL=bad;  EX_MSG="Código HTTP fora do comum." ;;
            esac ;;
    esac
}

# Mostra o resultado de um ws_probe já executado
mostra_resultado() {   # $1 = contexto (cf|origem)
    if [ "$P_CODE" = "000" ]; then
        bad "Sem resposta HTTP (curl código $P_RC)"
        info "$(explica_curl "$P_RC" "$P_CONNECT")"
        return
    fi
    explica_http "$P_CODE" "$1"
    local linha="Resposta real: HTTP $P_CODE $P_TEXT"
    case "$EX_LVL" in
        ok)   ok "$linha" ;;
        warn) warn "$linha" ;;
        *)    bad "$linha" ;;
    esac
    info "$EX_MSG"
}

pega_meu_ip() {
    local u ip
    for u in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
        ip=$(curl -s -m 5 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
}

# ==============================================================
#  INÍCIO
# ==============================================================
echo "${W}=== TESTE DO LINK ===${N}"
echo "  CloudFront : $CF_DOMAIN"
if [ "$SEM_ORIGEM" = "1" ]; then
    echo "  Origem     : (não informada)"
else
    echo "  Origem     : $ORIGEM_DOMAIN (porta $ORIGIN_PORT)"
fi
echo "  Caminho    : $WS_PATH"
[ "$(id -u)" -ne 0 ] && warn "Rode como root para ver detalhes dos serviços e do log."

# ---------- 1. DNS do CloudFront ----------
titulo 1 "O nome do CloudFront existe? (DNS)"
CF_IPS=$(getent ahostsv4 "$CF_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
if [ -n "$CF_IPS" ]; then
    ok "Nome resolve: $CF_IPS"
    CF_DNS_OK=1
else
    bad "O nome '$CF_DOMAIN' NÃO resolve."
    info "Domínio digitado errado (confira o '.cloudfront.net' no final) ou esta VPS está sem DNS."
    CF_DNS_OK=0
fi

# ---------- 2. Serviço na VPS ----------
titulo 2 "O multiplex está rodando nesta VPS?"
MUX_ATIVO=0
if systemctl is-active --quiet "$MUX_UNIT" 2>/dev/null; then
    ok "Serviço $MUX_UNIT está ATIVO"
    MUX_ATIVO=1
else
    bad "Serviço $MUX_UNIT está PARADO ou não existe"
    info "Para subir: systemctl restart $MUX_UNIT   (veja o motivo: journalctl -u $MUX_UNIT -n 30)"
fi

LISTEN=$(ss -tlnpH "sport = :${ORIGIN_PORT}" 2>/dev/null)
PROC=$(printf '%s\n' "$LISTEN" | grep -o 'users:(("[^"]*"' | head -n1 | cut -d'"' -f2)
PORTA_OK=0
if [ -z "$LISTEN" ]; then
    bad "Ninguém está escutando na porta $ORIGIN_PORT"
    info "Sem programa na porta, o CloudFront não tem com quem falar (erro 502/504)."
elif [ -z "$PROC" ]; then
    ok "Porta $ORIGIN_PORT está aberta (rode como root para ver qual programa)"
    PORTA_OK=1
elif [ "$PROC" = "python3" ]; then
    ok "Porta $ORIGIN_PORT está aberta (python3, provavelmente o multiplex)"
    PORTA_OK=1
else
    warn "Porta $ORIGIN_PORT está ocupada por '$PROC', e não pelo multiplex"
    info "Se for nginx/apache, ele está tomando a porta do mux."
    PORTA_OK=1
fi

# ---------- 3. Firewall local ----------
titulo 3 "Firewall desta VPS"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status 2>/dev/null | grep -qE "(^|[^0-9])${ORIGIN_PORT}(/tcp)?[[:space:]]+ALLOW"; then
        ok "ufw ativo e a porta $ORIGIN_PORT está liberada"
    else
        warn "ufw ativo e NÃO vi regra liberando a porta $ORIGIN_PORT"
        info "Liberar: ufw allow $ORIGIN_PORT/tcp"
    fi
else
    info "ufw inativo ou ausente (nada a verificar aqui)."
fi
info "Este teste não enxerga o firewall do provedor (se for Oracle: Security List/NSG e iptables da VM)."

# ---------- 4. Origem pelo próprio servidor ----------
titulo 4 "O túnel responde aqui dentro? (127.0.0.1:$ORIGIN_PORT)"
ws_probe "http://127.0.0.1:${ORIGIN_PORT}${WS_PATH}"
L_CODE="$P_CODE"; L_TEXT="$P_TEXT"; L_RC="$P_RC"
mostra_resultado origem
if [ "$L_CODE" = "101" ]; then
    [ -n "$P_BANNER" ] && info "Banner do SSH recebido ($P_BANNER): mux -> proxy.py -> sshd funcionando."
fi

# ---------- 5. DNS da origem x IP desta VPS ----------
titulo 5 "O domínio da origem aponta para ESTA VPS?"
MEU_IP=""
IP_BATE="?"
if [ "$SEM_ORIGEM" = "1" ]; then
    info "Origem não informada: este teste foi pulado."
else
MEU_IP=$(pega_meu_ip)
ORIGEM_IPS=$(getent ahostsv4 "$ORIGEM_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
IP_BATE="?"
if [ -z "$ORIGEM_IPS" ]; then
    bad "O domínio '$ORIGEM_DOMAIN' NÃO resolve (não existe registro DNS)."
    info "Crie um registro A apontando para o IP desta VPS${MEU_IP:+ ($MEU_IP)}."
    IP_BATE=0
else
    info "IP(s) do domínio : $ORIGEM_IPS"
    info "IP desta VPS     : ${MEU_IP:-não consegui descobrir}"
    if [ -z "$MEU_IP" ]; then
        warn "Não consegui descobrir o IP público desta VPS para comparar."
    elif printf '%s\n' "$ORIGEM_IPS" | tr ' ' '\n' | grep -qx "$MEU_IP"; then
        ok "O domínio aponta para esta VPS."
        IP_BATE=1
    else
        bad "O domínio aponta para OUTRO IP, e não para esta VPS."
        info "O CloudFront está falando com outro servidor. Corrija o registro A (sem proxy de outro CDN)."
        IP_BATE=0
    fi
fi

echo "      Teste direto pelo domínio da origem:"
ws_probe "http://${ORIGEM_DOMAIN}:${ORIGIN_PORT}${WS_PATH}"
D_CODE="$P_CODE"; D_TEXT="$P_TEXT"
mostra_resultado origem
if [ "$P_CODE" = "000" ] && [ "$L_CODE" = "101" ]; then
    info "Obs.: testar o próprio IP de dentro da VPS às vezes falha mesmo estando tudo certo. Confie no teste 6."
fi
fi

# ---------- 6. Teste principal: via CloudFront ----------
titulo 6 "TESTE PRINCIPAL: o túnel abre pelo CloudFront?"
if [ "$CF_DNS_OK" = "0" ]; then
    bad "Pulado: o nome do CloudFront não resolve (teste 1)."
    C_CODE="000"; C_TEXT=""; C_RC=6; C_CONNECT="0"
    LOG_LEGIVEL=0; LOG_EXT=0; C_CFID=""
else
    LOG_LEGIVEL=0; LOG_ANTES=0; LOG_EXT=0; LOG_IP=""
    if [ -r "$MUX_LOG" ]; then
        LOG_LEGIVEL=1
        LOG_ANTES=$(wc -l < "$MUX_LOG" 2>/dev/null || echo 0)
    fi

    ws_probe "https://${CF_DOMAIN}${WS_PATH}"
    C_CODE="$P_CODE"; C_TEXT="$P_TEXT"; C_RC="$P_RC"; C_CONNECT="$P_CONNECT"; C_CFID="$P_CFID"
    mostra_resultado cf

    if [ "$C_CODE" != "000" ]; then
        if [ -n "$P_CFID" ]; then
            info "Passou pelo CloudFront (ponto de presença: ${P_POP:-?} | cache: ${P_XCACHE:-?})."
        else
            warn "A resposta veio SEM os cabeçalhos do CloudFront: este endereço não está passando por ele."
        fi
        [ -n "$P_BANNER" ] && info "Banner do SSH recebido ($P_BANNER): caminho completo funcionando."
        if [ "$C_CODE" = "101" ] && [ "$C_TEXT" != "$STATUS_ESPERADO" ]; then
            warn "Mensagem do 101 é '$C_TEXT', esperado '$STATUS_ESPERADO'."
            info "Esse texto não é do seu proxy.py: pode ser outro servidor respondendo no lugar da sua VPS."
        fi
    fi

    # O mux recebeu a conexão? (procura linhas novas que não sejam de 127.0.0.1)
    if [ "$LOG_LEGIVEL" = "1" ]; then
        sleep 1
        NOVAS=$(tail -n +"$((LOG_ANTES + 1))" "$MUX_LOG" 2>/dev/null | grep -v "('127.0.0.1'")
        LOG_EXT=$(printf '%s\n' "$NOVAS" | grep -c "WebSocket")
        LOG_IP=$(printf '%s\n' "$NOVAS" | grep -o "('[0-9.]*'" | head -n1 | tr -d "('")
        if [ "$LOG_EXT" -gt 0 ]; then
            ok "O mux desta VPS RECEBEU a conexão (veio de ${LOG_IP:-?})."
        elif [ -n "$(printf '%s' "$NOVAS" | tr -d '[:space:]')" ]; then
            warn "O mux recebeu conexão externa, mas não como WebSocket:"
            printf '%s\n' "$NOVAS" | tail -n 2 | sed 's/^/        /'
        else
            warn "O mux NÃO registrou nenhuma conexão externa durante o teste."
            info "Se o CloudFront respondeu, ele falou com outro servidor. Se não respondeu, o pedido não chegou aqui."
        fi
    else
        info "Log do mux ($MUX_LOG) não legível: não dá para confirmar se a conexão chegou aqui."
    fi

    if [ "$VERBOSE" = "1" ]; then
        echo "      --- cabeçalhos brutos ---"
        printf '%s\n' "$P_HDR" | sed 's/^/      /'
    fi
fi

# ---------- 7. GET comum ----------
titulo 7 "Pedido comum (o 'verde 200' dos sites de teste)"
if [ "$CF_DNS_OK" = "0" ]; then
    info "Pulado (nome do CloudFront não resolve)."
else
    G_OUT=$(curl -sS --http1.1 --connect-timeout 5 -m 10 -o /dev/null -w '%{http_code}' "https://${CF_DOMAIN}/" 2>/dev/null)
    G_RC=$?
    [ -z "$G_OUT" ] && G_OUT="000"
    if [ "$G_OUT" = "000" ]; then
        bad "Sem resposta (curl código $G_RC)"
        info "$(explica_curl "$G_RC" "1")"
    else
        case "$G_OUT" in
            502) ok "Resposta real: HTTP 502 (isso é NORMAL aqui)"
                 info "A origem é um túnel SSH, não um site: o CloudFront alcançou a VPS, mas ela não fala HTTP de página. Por isso sites de teste não mostram mais 'verde 200'." ;;
            504) bad "Resposta real: HTTP 504"
                 info "O CloudFront não conseguiu chegar na origem a tempo (porta bloqueada, IP errado ou VPS fora do ar)." ;;
            200|204) warn "Resposta real: HTTP $G_OUT"
                 info "Um servidor web comum respondeu: a origem do CloudFront provavelmente NÃO é esta VPS." ;;
            *)   explica_http "$G_OUT" cf
                 case "$EX_LVL" in ok) ok "Resposta real: HTTP $G_OUT" ;; warn) warn "Resposta real: HTTP $G_OUT" ;; *) bad "Resposta real: HTTP $G_OUT" ;; esac
                 info "$EX_MSG" ;;
        esac
    fi
fi

# ==============================================================
#  RESUMO E ONDE CONSERTAR
# ==============================================================
echo
echo "${W}${C}==================== RESUMO ====================${N}"
STATUS_FINAL=1

if [ "$C_CODE" = "101" ] && [ "$C_TEXT" = "$STATUS_ESPERADO" ]; then
    echo "${G}${W}✔ O LINK ESTÁ OK${N}"
    echo "  O CloudFront abriu o túnel e quem respondeu foi o seu multiplex."
    if [ -z "${C_CFID:-}" ]; then
        warn "Mas a resposta veio sem os cabeçalhos do CloudFront: confirme que o endereço testado é mesmo o da distribuição."
    fi
    if [ "$LOG_LEGIVEL" = "1" ] && [ "$LOG_EXT" -eq 0 ]; then
        warn "Só não achei o registro no log do mux. Confira se o MUX_LOG está certo."
    fi
    STATUS_FINAL=0

elif [ "$C_CODE" = "101" ]; then
    echo "${Y}${W}⚠ RESPONDE, MAS TALVEZ NÃO SEJA A SUA VPS${N}"
    echo "  Veio um 101 com a mensagem '$C_TEXT' (esperado '$STATUS_ESPERADO')."
    if [ "$LOG_LEGIVEL" = "1" ] && [ "$LOG_EXT" -eq 0 ]; then
        echo "  E o mux desta VPS não viu a conexão: o CloudFront está falando com OUTRO servidor."
        echo
        echo "${W}Onde consertar:${N}"
        echo "  1. CloudFront > aba Origins: veja qual domínio está salvo na origem."
        echo "  2. DNS: o domínio da origem tem que apontar para o IP desta VPS (teste 5)."
        echo "  3. Veja se a distribuição está 'Deployed' (e não 'In progress')."
    else
        echo "  A conexão chegou aqui, então só a mensagem de status é diferente da esperada."
        echo "  Se você mudou o texto no painel, rode: STATUS_ESPERADO='$C_TEXT' bash $0"
    fi

else
    echo "${R}${W}✘ O LINK NÃO ESTÁ FUNCIONANDO${N}  (resposta: ${C_CODE}${C_TEXT:+ $C_TEXT})"
    echo
    echo "${W}Onde consertar (nesta ordem):${N}"
    if [ "$CF_DNS_OK" = "0" ]; then
        echo "  1. O nome do CloudFront não resolve: confira se '$CF_DOMAIN' está escrito certinho."
    elif [ "$L_CODE" != "101" ]; then
        echo "  1. O PROBLEMA ESTÁ NA VPS: o multiplex não responde nem aqui dentro (teste 4)."
        echo "     systemctl restart $MUX_UNIT netsimon-mux-ws"
        echo "     journalctl -u $MUX_UNIT -n 30 --no-pager"
        echo "     tail -n 30 $MUX_LOG"
        echo "     Sem isso funcionando, nada do CloudFront vai funcionar."
    elif [ "$IP_BATE" = "0" ]; then
        echo "  1. O DNS da origem está errado: '$ORIGEM_DOMAIN' não aponta para esta VPS (teste 5)."
        echo "     Corrija o registro A para ${MEU_IP:-o IP desta VPS}, sem proxy de outro CDN."
        echo "  2. Depois confirme em CloudFront > Origins que o domínio salvo é esse mesmo."
    else
        echo "  A VPS está boa e o DNS bate. O problema está ENTRE o CloudFront e a VPS:"
        case "$C_CODE" in
            403|400|404|405)
                echo "  1. CloudFront > Behaviors > Default: Cache policy = CachingDisabled,"
                echo "     Origin request policy = AllViewerExceptHostHeader,"
                echo "     Allowed methods = GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE."
                echo "  2. Em Origins: 'Origin path' vazio e protocolo 'HTTP only' na porta $ORIGIN_PORT."
                echo "  3. Veja se a distribuição está habilitada e 'Deployed'." ;;
            *)
                echo "  1. Firewall do provedor: a porta $ORIGIN_PORT precisa estar aberta para a internet"
                echo "     (o CloudFront usa IPs da AWS; não dá para liberar só um IP)."
                echo "  2. CloudFront > Origins: domínio $ORIGEM_TXT, 'HTTP only', porta $ORIGIN_PORT."
                echo "  3. Veja se a distribuição está 'Deployed' (e não 'In progress')."
                echo "  4. Repita este teste em 1 minuto: pode ser instabilidade momentânea." ;;
        esac
    fi
fi

if [ -t 1 ]; then
    echo
    echo "Detalhes dos cabeçalhos do CloudFront: VERBOSE=1 bash $0"
fi
exit "$STATUS_FINAL"
