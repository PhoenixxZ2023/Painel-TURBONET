#!/usr/bin/env bash
# ============================================================================
#   PAINEL NETSIMON v53 - FIX: botao "Teste" do revendedor + link do popup
#   "Revendedor criado!" usando o dominio publico configurado
#
#   Formato: modelo_de_fix.sh (patch por diff + SHA-256 + applier Python,
#   backup, restart so do afetado, rollback automatico, resumo final).
#
#   CORRECAO 1 - Botao "Teste" nao aparecia no painel do revendedor
#     Causa raiz: em usuarios.html o botao "⚡ Teste" tinha a classe
#     "admin-only", que o painel.js esconde para qualquer revendedor. O
#     backend (/api/users/test) ja aceitava revendedor (e ja respeita a
#     cota dele) - era so o botao escondido.
#     Arquivo: /var/www/html/usuarios.html  -> PATCH POR DIFF
#
#   CORRECAO 2 - "Link de acesso ao painel" do popup vinha com dominio antigo
#     Causa raiz: em revendedores.html o link era um texto FIXO
#     ("painel.netsimon.fun"), nunca lia o dominio salvo em Configuracoes.
#     Como /api/settings e so de admin, foi criada a rota
#     GET /api/settings/public-domain (qualquer usuario logado, so devolve o
#     dominio) e o popup passa a buscar o dominio atual a cada abertura
#     (sem cache). Sem dominio configurado, usa o endereco do navegador.
#     Arquivos: /var/www/html/revendedores.html -> PATCH POR DIFF
#               /etc/painel/painel_api.py       -> PATCH POR DIFF
#
#   Nenhum arquivo e RESTAURACAO COMPLETA: os 3 sao patch por diff.
#   Se o bloco "antigo" nao bater com o arquivo do servidor, aquele arquivo
#   e PULADO (fica intocado) e aparece no resumo final.
# ============================================================================
set -u

C='\033[0;36m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; W='\033[1;37m'; NC='\033[0m'

echo -e "${C}== Painel Netsimon v53 — fix: botao Teste (revendedor) + dominio no popup ==${NC}"

if [ "$(id -u)" != "0" ]; then
    echo -e "${R}Rode como root (sudo bash NOME_DO_FIX.sh).${NC}"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${R}python3 nao encontrado -- necessario pra aplicar as correcoes com seguranca. Abortando.${NC}"
    exit 1
fi

BASE="/etc/painel"
WEBROOT="/var/www/html"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BASE/backups/correcoes_teste_dominio_v53_$STAMP"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$BACKUP_DIR/etc-painel" "$BACKUP_DIR/var-www-html"
export BASE WEBROOT

# ── Diff embutido (base64) + conferencia de integridade SHA-256 ─────────────
EXPECTED_SHA256="a799be2b803040ebf6c3ab1a590a0d903d268388f8d57527a9a3aef652b39075"

base64 -d > "$TMP_DIR/correcoes.diff" <<'B64_CORRECOES_EOF'
ZGlmZiAtcnUgdjUyL3BhaW5lbF9hcGkucHkgdjUzL3BhaW5lbF9hcGkucHkKLS0tIHY1Mi9wYWlu
ZWxfYXBpLnB5CTIwMjYtMTAtMjEgMDI6Mzc6NTguNzUzMDYzODgxICswMDAwCisrKyB2NTMvcGFp
bmVsX2FwaS5weQkyMDI2LTEwLTIxIDAyOjM3OjU4Ljc1NDMzMzU0NCArMDAwMApAQCAtMTE5ODAs
NiArMTE5ODAsMTYgQEAKICAgICBzYXZlX2NvbmZpZyhjZmcpCiAgICAgcmV0dXJuIGpzb25pZnko
eyJvayI6IFRydWUsICJwdWJsaWNfZG9tYWluIjogY2ZnLmdldCgicHVibGljX2RvbWFpbiIsICIi
KX0pCiAKK0BhcHAucm91dGUoIi9hcGkvc2V0dGluZ3MvcHVibGljLWRvbWFpbiIsIG1ldGhvZHM9
WyJHRVQiXSkKK0BhdXRoX3JlcXVpcmVkKCkKK2RlZiBnZXRfcHVibGljX2RvbWFpbigpOgorICAg
ICIiInY1MzogZGV2b2x2ZSBzw7MgbyBkb23DrW5pbyBww7pibGljbyBjb25maWd1cmFkbyBlbSBD
b25maWd1cmHDp8O1ZXMuCisgICAgTGliZXJhZG8gcGFyYSBRVUFMUVVFUiB1c3XDoXJpbyBsb2dh
ZG8gKGFkbWluIGUgcmV2ZW5kZWRvcikgcG9ycXVlIGEgdGVsYQorICAgIFJldmVuZGVkb3JlcyBw
cmVjaXNhIGRlbGUgcGFyYSBtb250YXIgbyAiTGluayBkZSBhY2Vzc28gYW8gcGFpbmVsIiBkbwor
ICAgIHBvcHVwICJSZXZlbmRlZG9yIGNyaWFkbyEiLiAvYXBpL3NldHRpbmdzIGNvbnRpbnVhIHPD
syBwYXJhIGFkbWluLiIiIgorICAgIGNmZyA9IGxvYWRfY29uZmlnKCkKKyAgICByZXR1cm4ganNv
bmlmeSh7InB1YmxpY19kb21haW4iOiBjZmcuZ2V0KCJwdWJsaWNfZG9tYWluIiwgIiIpfSkKKwog
ZGVmIGJ1aWxkX3B1YmxpY191cmwocGF0aCk6CiAgICAgIiIiTW9udGEgdW1hIFVSTCBhYnNvbHV0
YSBww7pibGljYS4gVXNhIG8gZG9tw61uaW8gY29uZmlndXJhZG8gcXVhbmRvCiAgICAgZXhpc3Rp
ciAoZmljYSBjbGljw6F2ZWwgbm8gV2hhdHNBcHAvVGVsZWdyYW0pOyBjYWkgcGFyYSBvIElQOnBv
cnRhCmRpZmYgLXJ1IHY1Mi9yZXZlbmRlZG9yZXMuaHRtbCB2NTMvcmV2ZW5kZWRvcmVzLmh0bWwK
LS0tIHY1Mi9yZXZlbmRlZG9yZXMuaHRtbAkyMDI2LTEwLTIxIDAyOjM3OjU4Ljc1MTAzOTA5NSAr
MDAwMAorKysgdjUzL3JldmVuZGVkb3Jlcy5odG1sCTIwMjYtMTAtMjEgMDI6Mzc6NTguNzUyMDkw
MzA1ICswMDAwCkBAIC0zMDEsOCArMzAxLDE5IEBACiAgIHNob3dXZWxjb21lKHVzZXJuYW1lLCBw
YXNzd29yZCwgcXVvdGEsIGV4cGlyZXMpOwogfQogCi1mdW5jdGlvbiBzaG93V2VsY29tZSh1c2Vy
bmFtZSwgcGFzc3dvcmQsIHF1b3RhLCBleHBpcmVzKSB7Ci0gIGNvbnN0IGxpbmsgPSAicGFpbmVs
Lm5ldHNpbW9uLmZ1biI7Cithc3luYyBmdW5jdGlvbiBzaG93V2VsY29tZSh1c2VybmFtZSwgcGFz
c3dvcmQsIHF1b3RhLCBleHBpcmVzKSB7CisgIC8vIHY1MzogbyBsaW5rIE7Dg08gw6kgbWFpcyBm
aXhvICgicGFpbmVsLm5ldHNpbW9uLmZ1biIpLiBCdXNjYSBvIGRvbcOtbmlvIHNhbHZvIGVtCisg
IC8vIENvbmZpZ3VyYcOnw7VlcyA+IERvbcOtbmlvIFDDumJsaWNvIGEgY2FkYSBhYmVydHVyYSBk
byBwb3B1cCAoc2VtIGNhY2hlKS4gU2UgbsOjbworICAvLyBob3V2ZXIgZG9tw61uaW8gY29uZmln
dXJhZG8sIGNhaSBwYXJhIG8gZW5kZXJlw6dvIGF0dWFsIGRvIG5hdmVnYWRvci4KKyAgbGV0IGxp
bmsgPSBsb2NhdGlvbi5ob3N0OworICB0cnkgeworICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChB
UElfQkFTRSArICIvc2V0dGluZ3MvcHVibGljLWRvbWFpbiIsIHsgaGVhZGVyczogeyAiWC1Ub2tl
biI6IGdldFRva2VuKCkgfSB9KTsKKyAgICBpZiAoZC5vaykgeworICAgICAgY29uc3QgaiA9IGF3
YWl0IGQuanNvbigpOworICAgICAgY29uc3QgZG9tID0gU3RyaW5nKGoucHVibGljX2RvbWFpbiB8
fCAiIikudHJpbSgpLnJlcGxhY2UoL15odHRwcz86XC9cLy8sICIiKS5yZXBsYWNlKC9cLyskLywg
IiIpOworICAgICAgaWYgKGRvbSkgbGluayA9IGRvbTsKKyAgICB9CisgIH0gY2F0Y2ggKGUpIHsg
LyogbWFudMOpbSBsb2NhdGlvbi5ob3N0ICovIH0KICAgY29uc3QgcXVvdGFUZXh0ID0gcXVvdGEg
PT09IDAgPyAiSWxpbWl0YWRvIiA6IHF1b3RhOwogICBfd2VsY29tZVRleHQgPQogYPCfjokgQmVt
LXZpbmRvIGFvIFBhaW5lbCBOZXRzaW1vbiEKZGlmZiAtcnUgdjUyL3VzdWFyaW9zLmh0bWwgdjUz
L3VzdWFyaW9zLmh0bWwKLS0tIHY1Mi91c3Vhcmlvcy5odG1sCTIwMjYtMTAtMjEgMDI6Mzc6NTgu
NzQ4OTA1NTcyICswMDAwCisrKyB2NTMvdXN1YXJpb3MuaHRtbAkyMDI2LTEwLTIxIDAyOjM3OjU4
Ljc0OTk2NjQxNSArMDAwMApAQCAtOTQsNyArOTQsMTAgQEAKICAgICAgICAgPGgxIGNsYXNzPSJw
YWdlLXRpdGxlIj5Vc3XDoXJpb3M8L2gxPgogICAgICAgPC9kaXY+CiAgICAgICA8ZGl2IGNsYXNz
PSJ0b3BiYXItcmlnaHQiPgotICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0
bi1zbSBhZG1pbi1vbmx5IiBvbmNsaWNrPSJvcGVuTW9kYWwoJ21vZGFsLXRlc3QnKSI+4pqhIFRl
c3RlPC9idXR0b24+CisgICAgICAgIDwhLS0gdjUzOiBib3TDo28gIlRlc3RlIiBsaWJlcmFkbyB0
YW1iw6ltIHBhcmEgcmV2ZW5kZWRvciAoYW50ZXMgdGluaGEgYSBjbGFzc2UKKyAgICAgICAgICAg
ICBhZG1pbi1vbmx5IGUgc3VtaWEpLiBPIGJhY2tlbmQgL2FwaS91c2Vycy90ZXN0IGrDoSBhY2Vp
dGEgcmV2ZW5kZWRvciBlCisgICAgICAgICAgICAgcmVzcGVpdGEgYSBjb3RhIGRlbGUuIC0tPgor
ICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0bi1zbSIgb25jbGljaz0ib3Bl
bk1vZGFsKCdtb2RhbC10ZXN0JykiPuKaoSBUZXN0ZTwvYnV0dG9uPgogICAgICAgICA8YnV0dG9u
IGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0bi1zbSIgb25jbGljaz0iY3JlYXRlQXV0b1Rlc3QoKSI+
8J+kliBUZXN0ZSBBdXRvbcOhdGljbzwvYnV0dG9uPgogICAgICAgICA8YnV0dG9uIGNsYXNzPSJi
dG4gYnRuLXByaW1hcnkgYnRuLXNtIiBvbmNsaWNrPSJvcGVuTW9kYWwoJ21vZGFsLWNyZWF0ZScp
Ij4rIE5vdm8gVXN1w6FyaW88L2J1dHRvbj4KICAgICAgIDwvZGl2Pgo=
B64_CORRECOES_EOF

REAL_SHA256="$(sha256sum "$TMP_DIR/correcoes.diff" | awk '{print $1}')"
if [ "$REAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo -e "${R}Integridade do diff FALHOU (colagem corrompida?).${NC}"
    echo "  esperado: $EXPECTED_SHA256"
    echo "  obtido:   $REAL_SHA256"
    echo -e "${R}Nada foi alterado no servidor.${NC}"
    exit 1
fi
echo -e "${G}[OK]${NC} integridade do diff (SHA-256) conferida"

# ── Applier Python (substituicao exata de bloco + validacao + backup) ───────
cat > "$TMP_DIR/apply.py" <<'PY_APPLIER_EOF'
#!/usr/bin/env python3
# Applier embutido: aplica cada hunk por SUBSTITUICAO EXATA DE BLOCO DE TEXTO
# (nunca por numero de linha). Arquivo cujo bloco "antigo" nao bater 100% fica
# INTOCADO (PULADO) sem abortar os demais.
import sys, os, re, shutil, ast

diff_path, backup_dir, results_path = sys.argv[1:4]
BASE = os.environ.get("BASE", "/etc/painel")
WEBROOT = os.environ.get("WEBROOT", "/var/www/html")

TARGETS = {
    "usuarios.html":     (os.path.join(WEBROOT, "usuarios.html"),     "var-www-html"),
    "revendedores.html": (os.path.join(WEBROOT, "revendedores.html"), "var-www-html"),
    "painel_api.py":     (os.path.join(BASE,    "painel_api.py"),     "etc-painel"),
}

def parse_diff(text):
    files, cur, hunk = {}, None, None
    for ln in text.split("\n"):
        if ln.startswith("diff -ru "):
            cur, hunk = None, None
        elif hunk is None and ln.startswith("+++ "):
            name = ln[4:].split("\t")[0].strip()
            cur = name.split("/", 1)[1] if "/" in name else name
            files[cur] = []
        elif hunk is None and ln.startswith("--- "):
            pass
        elif ln.startswith("@@"):
            hunk = {"old": [], "new": []}
            files[cur].append(hunk)
        elif hunk is not None:
            if ln.startswith(" "):
                hunk["old"].append(ln[1:]); hunk["new"].append(ln[1:])
            elif ln.startswith("-"):
                hunk["old"].append(ln[1:])
            elif ln.startswith("+"):
                hunk["new"].append(ln[1:])
            # "\ No newline at end of file" e linhas vazias finais: ignoradas
    return files

def apply_hunks(content, hunks):
    applied = already = 0
    for h in hunks:
        if not h["old"]:
            return None, "hunk sem contexto (nao suportado)", 0, 0
        old = "\n".join(h["old"]) + "\n"
        new = "\n".join(h["new"]) + "\n"
        n = content.count(old)
        if n == 1:
            content = content.replace(old, new, 1); applied += 1
        elif n == 0:
            if new in content:
                already += 1
            else:
                return None, "bloco antigo nao encontrado (arquivo do servidor difere da v52)", 0, 0
        else:
            return None, "bloco antigo ambiguo (%dx)" % n, 0, 0
    return content, None, applied, already

def validate(name, content):
    if name.endswith(".py"):
        try:
            ast.parse(content, filename=name)
        except SyntaxError as e:
            return "sintaxe Python invalida: %s" % e
    elif name.endswith(".html"):
        low = content.lower()
        if len(re.findall(r"<script\b", low)) != low.count("</script>"):
            return "tags <script>/</script> desbalanceadas"
        if len(re.findall(r"<style\b", low)) != low.count("</style>"):
            return "tags <style>/</style> desbalanceadas"
    return None

text = open(diff_path, encoding="utf-8").read()
files = parse_diff(text)
out = []
for name, hunks in files.items():
    if name not in TARGETS:
        out.append("PULADO|%s|arquivo fora da lista de destinos conhecidos" % name); continue
    dest, sub = TARGETS[name]
    if not os.path.isfile(dest):
        out.append("AUSENTE|%s|%s" % (name, dest)); continue
    with open(dest, encoding="utf-8", newline="") as f:
        original = f.read()
    new_content, err, applied, already = apply_hunks(original, hunks)
    if err:
        out.append("PULADO|%s|%s" % (name, err)); continue
    if applied == 0 and already == len(hunks):
        out.append("JA_APLICADO|%s|" % name); continue
    bad = validate(name, new_content)
    if bad:
        out.append("INVALIDO|%s|%s" % (name, bad)); continue
    bdir = os.path.join(backup_dir, sub)
    os.makedirs(bdir, exist_ok=True)
    bpath = os.path.join(bdir, name)
    if os.path.exists(bpath):
        out.append("PULADO|%s|backup ja existe em %s (nao sobrescrevo backup)" % (name, bpath)); continue
    shutil.copy2(dest, bpath)
    tmp = dest + ".v53.tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(new_content)
    st = os.stat(dest)
    shutil.copymode(dest, tmp)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except Exception:
        pass
    os.replace(tmp, dest)
    out.append("APLICADO|%s|%s|%s" % (name, dest, bpath))

with open(results_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY_APPLIER_EOF

RESULTS="$TMP_DIR/results.txt"
python3 "$TMP_DIR/apply.py" "$TMP_DIR/correcoes.diff" "$BACKUP_DIR" "$RESULTS"
if [ $? -ne 0 ] || [ ! -f "$RESULTS" ]; then
    echo -e "${R}Applier falhou. Nada alem do que consta no backup foi alterado.${NC}"
    exit 1
fi

APPLIED=(); API_APPLIED=0
while IFS='|' read -r st name a b c; do
    [ -z "$st" ] && continue
    case "$st" in
        APLICADO)
            APPLIED+=("$name|$a|$b")
            [ "$name" = "painel_api.py" ] && API_APPLIED=1
            echo -e "${G}[APLICADO]${NC}    $name"
            ;;
        JA_APLICADO) echo -e "${Y}[JA ESTAVA]${NC}   $name (correcao ja presente, nada a fazer)" ;;
        PULADO)      echo -e "${Y}[PULADO]${NC}      $name -> $a" ;;
        AUSENTE)     echo -e "${Y}[AUSENTE]${NC}     $name -> $a nao existe neste servidor" ;;
        INVALIDO)    echo -e "${R}[INVALIDO]${NC}    $name -> $a (arquivo NAO foi alterado)" ;;
    esac
done < "$RESULTS"

# ── Rollback (usado se o servico nao subir) ─────────────────────────────────
rollback_all() {
    echo -e "${R}Restaurando arquivos do backup $BACKUP_DIR ...${NC}"
    for item in "${APPLIED[@]}"; do
        IFS='|' read -r n dest bkp <<< "$item"
        cp -p "$bkp" "$dest" && echo "  restaurado: $dest"
    done
}

# ── Reinicio SO do servico afetado (painel_api.py) + confirmacao ────────────
PAINEL_UNIT=""
detect_unit() {
    if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'netsimon-painel.service'; then
        PAINEL_UNIT="netsimon-painel"; return
    fi
    local u
    for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i painel | grep -vi 'bot\|whatsapp\|telegram'); do
        if systemctl cat "$u" 2>/dev/null | grep -q 'painel_api.py'; then
            PAINEL_UNIT="${u%.service}"; return
        fi
    done
}

SERVICE_OK="n/a (painel_api.py nao foi alterado, nenhum servico reiniciado)"
if [ "$API_APPLIED" = "1" ]; then
    detect_unit
    if [ -z "$PAINEL_UNIT" ]; then
        echo -e "${R}Nao encontrei a unit systemd da API do painel.${NC}"
        rollback_all
        exit 1
    fi
    echo -e "${C}Reiniciando $PAINEL_UNIT ...${NC}"
    systemctl restart "$PAINEL_UNIT"
    ok=0
    for i in $(seq 1 20); do
        sleep 1
        if systemctl is-active --quiet "$PAINEL_UNIT"; then ok=1; break; fi
    done
    if [ "$ok" = "1" ]; then
        # a rota nova responde? 401 (sem token) = rota existe. 404/000/5xx = problema.
        if command -v curl >/dev/null 2>&1; then
            sleep 2
            CODE="$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:5001/api/settings/public-domain)"
            case "$CODE" in
                200|401|402|403) : ;;
                *) ok=0; echo -e "${R}Rota nova respondeu HTTP $CODE (esperado 401 sem token).${NC}" ;;
            esac
        fi
    fi
    if [ "$ok" != "1" ]; then
        echo -e "${R}Servico $PAINEL_UNIT NAO subiu corretamente -> ROLLBACK AUTOMATICO.${NC}"
        rollback_all
        systemctl restart "$PAINEL_UNIT"
        sleep 3
        systemctl is-active --quiet "$PAINEL_UNIT" && echo -e "${Y}Servico voltou com a versao anterior.${NC}" || echo -e "${R}ATENCAO: servico ainda inativo. Veja: journalctl -u $PAINEL_UNIT -n 50${NC}"
        exit 1
    fi
    SERVICE_OK="$PAINEL_UNIT ativo e rota /api/settings/public-domain respondendo"
    echo -e "${G}[OK]${NC} $SERVICE_OK"
fi

# ── Resumo final ────────────────────────────────────────────────────────────
echo ""
echo -e "${W}================ RESUMO ================${NC}"
echo "Aplicados: ${#APPLIED[@]} arquivo(s)  |  Backup: $BACKUP_DIR"
echo "Servico:   $SERVICE_OK"
echo ""
echo -e "${W}O que cada correcao faz:${NC}"
echo "  1) usuarios.html     -> botao '⚡ Teste' passa a aparecer para o revendedor"
echo "                          (abre o formulario de teste; cria via /api/users/test, usando a cota dele)."
echo "  2) painel_api.py     -> nova rota GET /api/settings/public-domain (qualquer usuario logado)."
echo "     revendedores.html -> popup 'Revendedor criado!' mostra/copia o dominio salvo em Configuracoes."
echo ""
echo -e "${W}O que NAO faz / precisa de acao manual:${NC}"
echo "  - Nao altera revendedores ja criados nem mensagens ja enviadas com o link antigo."
echo "  - Sem dominio salvo em Configuracoes, o link mostra o endereco que o navegador esta usando."
echo "  - Cada Teste de revendedor consome 1 da cota dele (mesma regra do Teste Automatico)."
echo "  - Nao mexe no checkuser.py: ele tem PUBLIC_DOMAIN fixo (fotos de usuario) - fora do escopo."
echo "  - Aperte Ctrl+F5 no navegador para recarregar as paginas (.html podem estar em cache)."
echo ""
echo -e "${W}Rollback manual (se precisar):${NC}"
for item in "${APPLIED[@]}"; do
    IFS='|' read -r n dest bkp <<< "$item"
    echo "  cp -p $bkp $dest"
done
[ "$API_APPLIED" = "1" ] && echo "  systemctl restart $PAINEL_UNIT"
echo -e "${G}Fix v53 concluido.${NC}"
