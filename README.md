# 🚀 Painel Netsimon — v53

**Versão 1** — Sistema completo e **100% autossuficiente** para gerenciamento de VPS SSH/VLESS (Xray) — instala tudo em **um único comando**: base SSH/Xray/WebSocket/SlowDNS, painel web administrativo, sistema de revendedores, bot de vendas via Telegram (PIX), bloqueio por dispositivo local e gerenciador de versões do aplicativo cliente.

> Não depende de nenhuma instalação prévia, nenhum outro repositório, nem de painéis externos (Atlas/Dragon Core). Tudo roda localmente no seu próprio servidor.

> ℹ️ Este projeto se chamava **Painel Netsimon 10**. O nome foi simplificado para **Painel Netsimon** (repositório, identificadores internos, logs e serviços já refletem isso) — a numeração de versão recomeça em **1** a partir desta reorganização.

---

## 🖥️ Requisitos do sistema

- **Ubuntu 22.04 LTS (Jammy)** — sistema operacional recomendado/de referência para instalação. É o ambiente em que o painel é testado e mantido (inclusive scripts de fix pontuais assumem esse ambiente).
- Acesso **root** (ou `sudo`) na VPS — o `install.sh` roda comandos de sistema (`apt`, `systemctl`, criação de usuários Linux, etc.) que exigem privilégio de root.
- VPS com **IPv4 próprio**, acesso à internet de saída liberado (o instalador baixa pacotes via `apt`, Node.js via NodeSource, Xray, etc.) e portas livres para os serviços do painel — 81 para o painel web sempre ativo, e 80/443/8443/8888/2053 disponíveis para os protocolos de conexão opcionais (instalados mas desligados por padrão — ver seção "🌐 Portas utilizadas" abaixo para a lista completa).
- Outras distros/versões baseadas em Debian (ex: Ubuntu 20.04/24.04) **não são oficialmente suportadas** — podem funcionar parcialmente, mas não há garantia, já que o instalador e os scripts assumem os pacotes e comportamentos do Ubuntu 22.04 (por exemplo, o comentário sobre o algoritmo `ssh-rsa` do OpenSSH 8.8+, presente a partir do Ubuntu 22.04, referenciado em `install.sh`).

---

## ⚡ Instalação (um comando só)

```bash
bash <(curl -sSL "https://raw.githubusercontent.com/miau4/Painel-Netsimon/main/install.sh?t=$(date +%s)")
```

> **v53 — botão "Teste" para revendedor e domínio correto no popup.** O botão "⚡ Teste" da tela
> Usuários agora aparece também no painel do revendedor (usa a cota dele). O "Link de acesso ao
> painel" do popup "Revendedor criado!" passou a usar o domínio salvo em Configurações > Domínio
> Público (antes era um texto fixo). Nova rota `GET /api/settings/public-domain`. Detalhes em
> `CHANGELOG-v53.txt`.
>
> **v51 — listas de transmissão, ranking de uso completo e backup com telefone.** Mensagens em massa
> para usuários marcados na lista de Usuários (com lista salva, editável e reutilizável), ranking de
> 7 dias cobrindo todos os usuários e ordenável, telefone dos clientes e validade dos revendedores
> dentro do backup SQL, e menu IA/Bot WhatsApp logo abaixo de Dispositivos. Detalhes em
> `CHANGELOG-v51.txt`.
>
> **v50 — conntrack e limite de arquivos do sshd.** O `install.sh` agora eleva o limite do conntrack
> (o padrão de VPS pequena, ~7 mil entradas, enchia e o kernel descartava conexões novas, travando o
> BHTTP em períodos) e o limite de arquivos abertos do sshd. Só o `install.sh` mudou. Detalhes em
> `CHANGELOG-v50.txt`.
>
> **v49 — BHTTPD 1.4.0: túnel BHTTP estável.** O servidor novo entrega o download "por crédito":
> uma pausa de tráfego não faz mais o app perder dados e cair pelo watchdog. Só o BHTTPD mudou
> (código, binários e `bhttpd.sh`). Detalhes em `CHANGELOG-v49.txt`.
>
> **v48 — exclusividade de porta corrigida no BHTTP antigo.** `bhttp.sh` (binário antigo)
> agora usa o mesmo `portlock.sh` que o `bhttpd.sh` já usava — antes, ativar o BHTTP antigo
> direto pelo terminal não derrubava o BHTTPD novo, podendo deixar os dois disputando a
> porta 80/443. Detalhes em `CHANGELOG-v48.txt`.
>
> **v47.1 — GitHub pronto / BHTTPD corrigido.** O repositório tem a mesma árvore do zip
> (`bhttpd/bin`, `bhttpd/src` etc.) e o `install.sh` baixa o BHTTPD novo desse caminho. O
> instalador confere a versão do binário (`bhttpd/bin/VERSION`), mostra os erros do BHTTPD/Multiplex
> em vez de escondê-los e avisa se o binário da arquitetura estiver desatualizado. Detalhes em
> `CHANGELOG-v47.1.txt`. Para instalar de um fork/outro repositório:
> `PAINEL_REPO=https://raw.githubusercontent.com/SEU_USER/SEU_REPO/main bash install.sh`.
> Instalação alternativa, sem depender do CDN do `raw.githubusercontent` (clona e roda local):
> `git clone --depth 1 https://github.com/miau4/Painel-Netsimon && bash Painel-Netsimon/install.sh`

Ao final, o admin já pode entrar no painel e criar usuários. **Nenhum protocolo de conexão fica
ativo sozinho após a instalação** — Xray, WS Proxy, WSS TLS, WSS SSH, Stunnel, Netsimon-BHTTP
(antigo), Netsimon-BHTTPD (novo) e o Netsimon Multiplex ficam **instalados, mas desligados**, com
as portas **80/8080/443/8443/8888 sempre livres logo após instalar** — a ativação de cada um é
sempre manual, feita pelo admin na tela **WebSocket** (ou **Xray**) do painel, de acordo com a
necessidade. Isso vale tanto para uma instalação nova quanto para reinstalar/atualizar por cima:
nenhum script do painel (instalador, correção de usuário, autodiagnóstico, boot) liga um desses
serviços sozinho — o máximo que fazem é *reiniciar* um que o admin já deixou ativo. Device Check,
Limiter, BadVPN, CheckUser API, o watchdog de monitoramento e os bots/IA sobem ativos normalmente,
pois não ocupam nenhuma dessas 5 portas.

Acesse:
```
http://SEU-IP:81
```
- Usuário: `admin`
- Senha: `netsimon` (troque imediatamente em *Configurações*)

---
```bash
OBTER pinnedPeerCertSha256

echo | openssl s_client -connect 179.191.168.73:443 -servername www.tim.com.br 2>/dev/null \
  | openssl x509 -outform der \
  | openssl dgst -sha256 -r \
  | awk '{print $1}'
```
---

## 📦 O que a instalação já deixa pronto

- **Xray** instalado (VLESS + XHTTP + TLS) — *desligado*, ativação manual pela tela **Xray**
- **WS Proxy, WSS TLS, WSS SSH, Stunnel, Netsimon-BHTTP (antigo) e Netsimon-BHTTPD (novo)**
  instalados — todos *desligados*, ativação manual pela tela **WebSocket**, um por vez ou vários
  juntos em portas diferentes (ativar qualquer um deles libera sozinho a porta escolhida de quem
  estiver nela, sem precisar desativar nada manualmente antes)
- **Netsimon Multiplex** instalado — *desligado*. Uma porta pública única (80/443) que escolhe o
  protocolo pelo conteúdo dos primeiros bytes (SSH, TLS+SNI, WebSocket, BHTTP) e entrega para o
  serviço certo, rodando internamente. Ativar assume as portas (para e desabilita tudo que estiver
  nelas); desativar devolve o painel ao modo padrão (um serviço por porta) e religa o que já estava
  ativo antes
- **Nginx** (porta 81, com PHP-FPM legado) rodando
- **BadVPN UDPGW** compilado da fonte oficial e rodando na porta **7300**
- **Limitador de conexões** ativo
- **Painel Web** completo (porta 81, via Nginx → API Flask na 5001)
- **Device Check local** (bloqueio por dispositivo, sem depender de painel externo)
- **CheckUser API** (porta 5000, consulta de status por login/UUID)
- Autodiagnóstico ativo (a cada 10 min) para os serviços de infraestrutura (Xray, SlowDNS,
  CheckUser, BadVPN, Stunnel) — reativa sozinho um serviço que **o admin já tinha ligado** e caiu
  por conta de uma falha; nunca ativa algo que nunca foi ligado manualmente antes

> ℹ️ Protocolos de conexão (WS Proxy, WSS TLS, WSS SSH, Stunnel, BHTTP) ficam **de fora** do
> autodiagnóstico de propósito — "desligado" é o estado normal deles até o admin decidir usar, não
> uma falha a corrigir sozinho.

---

## 🖥️ Painel Web — Menu principal

```
📊 Dashboard        — status de todos os serviços, CPU/RAM/disco, online agora (cards clicáveis)
👤 Usuários         — criar, remover, listar, testes temporários
📵 Dispositivos     — bloqueio por dispositivo, resetar aparelhos de um usuário
🛰️ Xray             — status, reiniciar, mudar host/porta (admin)
🔌 WebSocket        — WS Proxy, WSS TLS, WSS SSH, Stunnel e Netsimon-BHTTP: ativar/desativar cada
                       um em qualquer porta, ver qual serviço está em cada porta (admin)
🤝 Revendedores     — contas com cota própria de usuários (admin)
🖧 Servidores       — registra outros servidores Painel Netsimon e gerencia todos em paralelo (admin)
📱 Aplicativo       — upload/download de versões do APK, link direto
💾 Backup           — exportar/importar SQL ou backup completo, agendamento via Telegram (admin)
🤖 Bot Telegram     — venda automática via PIX/Mercado Pago (admin)
📋 Logs             — Xray, Limiter, Device Check, Painel (admin)
⚙️ Configurações    — trocar senha, ver bloqueios do limiter (admin)
```

Os cards do Dashboard (Usuários, Online, Expirados, Bloqueados) são clicáveis — levam direto pra
aba Usuários já com o filtro correspondente aplicado.

O `menu.sh` (terminal) continua funcionando normalmente — digite `menu` a qualquer momento via SSH.

---

## 🎨 Identidade visual

A tela de login usa o vídeo `painel_bg.mp4` como fundo animado (mudo, em loop) com o logo
`logo.png` como marca d'água — ambos incluídos no repositório e baixados automaticamente pelo
`install.sh` para `/var/www/html/img/`. O logo também substitui o ícone no topo da barra lateral
em todas as páginas do painel.

---

## 🏗️ Arquitetura

```
┌────────────────────────────────────────────────────────────────┐
│                        VPS Painel Netsimon                          │
│                                                                  │
│  Nginx (porta 81)                                                │
│    ├─ /              → /var/www/html/*.html (painel web)         │
│    ├─ /api/           → proxy_pass → 127.0.0.1:5001 (Flask)      │
│    └─ /downloads/     → alias /etc/painel/app_releases/ (APKs)   │
│                                                                  │
│  Serviços systemd sempre ativos:                                  │
│    ├─ netsimon-painel    (porta 5001 — API do painel)             │
│    ├─ badvpn              (porta 7300 — UDP gateway)              │
│    ├─ limiter             (controle de conexões simultâneas)      │
│    ├─ checkuser           (porta 5000 — status por login/UUID)    │
│    └─ nginx               (porta 81)                              │
│                                                                  │
│  Protocolos de conexão — instalados, DESLIGADOS por padrão,        │
│  ativação manual pela tela WebSocket/Xray do painel, um ou         │
│  vários juntos em portas diferentes (livre escolha):                │
│    ├─ xray                (padrão 443 — VLESS/XHTTP)              │
│    ├─ proxy@<porta>       (WS Proxy — padrão 80)                  │
│    ├─ wss@<porta>         (WSS TLS real — padrão 8443)            │
│    ├─ wss-security@<porta> (WSS sem TLS — padrão 8888)            │
│    ├─ netsimon-stunnel    (SSH sobre TLS — padrão 2053)           │
│    └─ netsimon-bhttp      (BHTTP/DTunnel — padrão 80 + 443)       │
│                                                                  │
│  /etc/painel/  — todos os scripts + usuarios.db + configs         │
│  /var/www/html/ — frontend do painel web                          │
└────────────────────────────────────────────────────────────────┘
```

> Ativar qualquer um dos protocolos acima libera sozinho a porta escolhida de quem estiver
> ocupando ela no momento (outro protocolo do painel, ou o Xray) — nunca é preciso desativar um
> manualmente antes de ativar outro na mesma porta.

---

## 🛡️ Migração SSH → XHTTP (anti-DPI total, OPCIONAL)

Se o WS Proxy estiver ativado (tela WebSocket), o SSH fica acessível por ele em texto puro — mais fácil de identificar por DPI de operadora. Para blindar totalmente, movendo o SSH para dentro do mesmo túnel TLS que o VLESS já usa:

```bash
bash /etc/painel/migrate_ssh_xhttp.sh
```

⚠️ **Só rode isso depois de configurar o app cliente para port-forward via Xray** (o app precisa abrir uma porta local e redirecioná-la para `127.0.0.1:22` através do perfil VLESS) — senão os usuários perdem acesso SSH imediatamente. Detalhes completos de como isso funciona estão dentro do próprio script.

O que o script faz:
1. Backup do `config.json` do Xray
2. Adiciona uma exceção de roteamento (`127.0.0.1:22` liberado via outbound dedicado, mantendo bloqueio de outros IPs privados)
3. Bloqueia as portas 22/80/8080 externamente no firewall (mantém 22 só via loopback)
4. Encerra o `proxy.py`, que deixa de ser necessário

---

## 🌐 Painel via domínio, sem porta na URL (via Cloudflare)

O painel já vem pronto para acesso via domínio **sem precisar digitar porta nenhuma** e com
**HTTPS de graça**, usando o Cloudflare como intermediário — nenhuma configuração adicional no
servidor é necessária além do próprio `install.sh`.

### Como funciona

O Nginx do painel escuta na porta **8880** (interna, nunca usada por mais nada). O visitante
acessa `https://painel.seudominio.com` normalmente, sem porta, e o Cloudflare entrega TLS pro
visitante enquanto fala HTTP puro com o servidor na 8880 nos bastidores.

> ⚠️ **Atenção:** por padrão, com o proxy (nuvem laranja) ligado, a Cloudflare tenta falar com a
> origem nas portas **80** (modo Flexible) ou **443** (modo Full/Full strict) — **não** na 8880
> automaticamente, mesmo 8880 sendo uma porta HTTP alternativa suportada pela Cloudflare. Sem o
> passo 3 abaixo (**Origin Rule**), o acesso via domínio retorna **erro 520 (Web server is
> returning an unknown error)**, porque a Cloudflare não encontra nada escutando em 80/443.

**Nada muda nas portas que você já usa:**

| Porta | Serviço | Alterado? |
|---|---|---|
| 22 | SSH direto | Não |
| 80 | WS Proxy (WebSocket, se ativado) | **Não** |
| 81 | Painel via IP direto | Não |
| 443 | Xray VLESS/XHTTP, ou BHTTP (se ativados) | Não |
| 2053 | Stunnel — SSH sobre TLS (se ativado) | Não |
| 8443 | WSS TLS real (se ativado) | Não |
| 8880 | Painel via Cloudflare (novo) | — |

### Configuração no Cloudflare (uma única vez)

1. **DNS → Registros (Records):**
   - Tipo: `A`
   - Nome: `painel` (ou o subdomínio que preferir)
   - IPv4: o IP desta VPS
   - Proxy: **🟠 Ligado** (ícone laranja — proxy ativo)
2. **SSL/TLS → Visão geral (Overview):** selecione **Flexible**
3. **Regras → Regras de Origem (Rules → Origin Rules):**
   - Clique em **Criar regra** (Create rule)
   - Nome da regra: `Painel porta 8880`
   - Em **Quando as solicitações recebidas corresponderem** (When incoming requests match):
     campo **Nome do host** (Hostname), operador **é igual a** (equals),
     valor `painel.seudominio.com`
   - Em **Então** (Then): marque **Porta de destino** (Destination Port) e defina `8880`
   - Clique em **Implantar** (Deploy)
4. Aguarde 1-5 minutos de propagação e acesse `https://painel.seudominio.com`

Sem o passo 3, a Cloudflare nunca chega até o Nginx do painel — ela bate na porta errada e você
verá o erro 520. Não é preciso desligar o proxy nem mexer em mais nada — o Xray fica na 443
**direto**, fora do alcance do proxy do Cloudflare, então não há conflito algum.

### HTTPS próprio no servidor (opcional, avançado)

Se você preferir não depender do modo "Flexible" do Cloudflare (por exemplo, para usar
"Full (strict)"), rode:

```bash
bash /etc/painel/setup_https_domain.sh
```

Isso emite um certificado Let's Encrypt de verdade e o Nginx passa a terminar TLS ele mesmo na
porta 8880, em vez de depender do certificado do Cloudflare.

---

## 📵 Bloqueio por Dispositivo — 100% local

Endpoint chamado pelo app cliente a cada conexão:

```
POST /api/device/check
Header: X-Device-Token: <gerado na instalação, em /etc/painel/device_check.token>
Body (form-data):
  username: joao123        (login OU uuid)
  device_hash: <hash único do aparelho>
  phone: <opcional>
```

Resolve o usuário direto no `usuarios.db` local, usa o campo `limite` como limite de aparelhos, e mantém histórico completo em `/etc/painel/netsimon_devices.db` (SQLite). Gerenciável pela aba **Dispositivos** do painel.

---

## 📱 Gerenciador de Aplicativo

- Admin envia o APK pelo painel (*Aplicativo → Enviar Nova Versão*)
- Revendedores veem a mesma lista, só com botão de download
- Cada versão gera um link direto (`http://SEU-IP:81/downloads/netsimon-X.Y.Z.apk`) para enviar ao cliente final, sem necessidade de login
- Endpoint público `GET /api/app/latest` — o app cliente já consulta este endpoint automaticamente para checar atualizações

---

## 📲 App Cliente Android

O app cliente (fork do v2rayNG com SSH via JSch) já vem preparado para conversar com este painel,
mas a configuração **não fica em `AppConfig.kt`** — está hardcoded direto em
`WebUiActivity.kt` (`app/ui/web/`), em duas constantes separadas. Antes de compilar o APK, edite:

```kotlin
// CheckUser (status da conta) — porta 5000
private val CHECKUSER_BASE_URL = "http://SEU-IP-OU-DOMINIO:5000"
private val CHECKUSER_TOKEN    = "<conteúdo de /etc/painel/checkuser.token do seu servidor>"

// Bloqueio por dispositivo — porta 81
private val DEVICE_CHECK_URL   = "http://SEU-IP-OU-DOMINIO:81/api/device/check"
private val DEVICE_CHECK_TOKEN = "<conteúdo de /etc/painel/device_check.token do seu servidor>"
```

Com isso, duas funções do app passam a falar direto com o seu painel, sem nenhum sistema externo:

| Função no app | Endpoint do painel |
|---|---|
| CheckUser (status da conta) | `GET /check/<login>` ou `GET /check/uuid/<uuid>` (porta 5000, header `X-Token`) |
| Bloqueio por dispositivo | `POST /api/device/check` (porta 81, header `X-Device-Token`) |

> ⚠️ **Os dois tokens são valores fixos, compilados no APK — não há sincronização automática
> com o servidor.** Se o painel for reinstalado (ou migrado para outro servidor) e um novo
> `checkuser.token`/`device_check.token` for gerado, o app precisa ser **recompilado** com os
> novos valores, senão passa a receber erro de autenticação. A única sincronização automática
> que existe é a de **chaves de revendedor** (campo `api_keys` retornado pelo próprio
> `/api/device/check`), salva localmente no app a cada resposta — isso não substitui nem
> atualiza o `CHECKUSER_TOKEN`/`DEVICE_CHECK_TOKEN` em si.
>
> A verificação de atualização (`GET /api/app/latest`) é documentada como endpoint público no
> painel, mas seu uso não foi confirmado no trecho de `WebUiActivity.kt` analisado — vale
> conferir a Activity de update (`CheckUpdateActivity`) antes de confiar nessa integração.

---

## 🖧 Gerenciamento Multi-Servidor

Registre outros servidores Painel Netsimon na aba **Servidores** e gerencie todos em paralelo a
partir de um único painel:

1. Em cada servidor, copie o **Token de Sincronização** (gerado na instalação, visível na própria aba Servidores)
2. No painel "principal", vá em **Servidores → Registrar Servidor** e informe nome, host, porta e o token copiado
3. A partir daí, toda ação de usuário (criar, remover, testar, desbloquear) feita no painel principal é replicada automaticamente para todos os servidores registrados, em paralelo e em background — sem travar a resposta e sem derrubar a ação local se um servidor estiver fora do ar

---

## 💾 Backup

Aba **Backup**, com 4 ações diretas:

- **Exportar SQL** — dump `.sql` portável (usuários, senha do admin, revendedores, dispositivos), gerado com o próprio motor SQLite (`iterdump()`), leve e rápido
- **Importar SQL** — restaura esses dados a partir de um `.sql` exportado anteriormente
- **Exportar Tudo** — `.tar.gz` com scripts, configs, `config.json` do Xray e certificados SSL (não inclui os APKs de Aplicativo, que podem ser reenviados)
- **Importar Tudo** — restaura o backup completo e reinicia os serviços automaticamente

**Backup automático via Telegram:** ative na própria aba Backup (Chat ID, intervalo em horas, tipo
SQL ou Completo). Usa o mesmo bot já configurado em Bot Telegram — o arquivo é enviado
automaticamente como documento no chat informado, no intervalo escolhido.

---

## 🤝 Revendedores

Admin cria em **Revendedores → Novo Revendedor** (usuário, senha, cota de usuários). O revendedor loga com essas credenciais e só enxerga/gerencia os usuários que ele mesmo criou — incluindo os dispositivos deles e o download do app (sem permissão de upload).

---

## 🤖 Bot de Telegram (venda automática via PIX)

1. Crie um bot com **@BotFather**, copie o token
2. **Bot Telegram → Geral**: cole o token e seu Chat ID (pegue com **@userinfobot**)
3. **Pagamento (PIX)**: cole seu Access Token do Mercado Pago
4. Configure os **Planos** e ative o bot

Fluxo: `/start` → escolhe plano → define usuário/senha → recebe PIX → bot confirma pagamento automaticamente (polling a cada 15s) → cria a conta → entrega usuário/senha/link VLESS.

---

## 🌐 Portas utilizadas

| Porta | Serviço | Ativa por padrão? |
|---|---|---|
| 22 | SSH direto | Sim |
| 80 | WS Proxy, Netsimon-BHTTP(D), ou Multiplex | **Não** — manual, tela WebSocket |
| 81 | Painel Web via IP direto (Nginx) | Sim |
| 443 | Xray, WSS TLS, Netsimon-BHTTP(D), ou Multiplex | **Não** — manual (Xray na tela Xray, resto na tela WebSocket) |
| 2000 | API interna do Xray (uso interno, 127.0.0.1) | Sim (só quando o Xray está ativo) |
| 2053 | Stunnel (SSH sobre TLS "cru") | **Não** — manual, tela WebSocket |
| 5000 | CheckUser API | Sim |
| 5001 | API do Painel (uso interno, via proxy do Nginx) | Sim |
| 5353 | SlowDNS | Só se configurado (domínio/chaves gerados) |
| 7300 | BadVPN UDPGW (uso interno, 127.0.0.1) | Sim |
| 7681 | Terminal Web / ttyd (uso interno, 127.0.0.1, protegido por sessão) | Sim |
| 8443 | WSS TLS real | **Não** — manual, tela WebSocket |
| 8880 | Painel Web via Cloudflare/domínio (Nginx) | Sim |
| 8888 | WSS SSH (Websocket Security, sem TLS) | **Não** — manual, tela WebSocket |
| 80 + 443 (configurável) | Netsimon-BHTTP (antigo) | **Não** — manual, tela WebSocket |
| 80 + 443 (configurável) | Netsimon-BHTTPD (novo, Go, protocolo BHP1) | **Não** — manual, tela WebSocket |
| 80 + 443 (configurável) | Netsimon Multiplex (porta única por conteúdo) | **Não** — manual, tela WebSocket |

Qualquer protocolo marcado "manual" pode ser ativado em **qualquer porta livre** pela tela
WebSocket/Xray, não só na porta padrão listada acima — e ativá-lo libera sozinho a porta escolhida
de quem estiver nela no momento (inclusive desligando o Multiplex, se for ele quem está com a
porta). Se a porta estiver com um processo que o painel **não reconhece**, nada é alterado e o
painel avisa qual PID/comando está segurando ela — é preciso liberar manualmente ou usar a opção
"forçar" (só existe no Multiplex, pois é o único cenário em que isso é esperado).

### 🆕 Netsimon-BHTTPD e Netsimon Multiplex (v47)

- **Netsimon-BHTTPD**: reimplementação própria (Go) do protocolo BHTTP/BHP1, para substituir aos
  poucos o binário fechado antigo. Suporta os modos 0 (sondagem), 1 (upload), 2 (download —
  1 resposta por requisição, o formato usado pelo app atual), 3 (batch, legado) e 4 (ACK). Roda em
  paralelo ao BHTTP antigo (unit, config e binário próprios) para poder ativar/testar/desativar sem
  afetar quem já usa o antigo. Tem modo `debug` (log de cada requisição: modo/sid/seq/tamanho) para
  diagnosticar "app conecta mas não troca dados" — ver `bhttpd/src/README.md`.
- **Netsimon Multiplex**: escuta uma porta pública (padrão 80/443) e decide o protocolo pelo
  **conteúdo** da conexão — sem precisar de portas diferentes por protocolo. Ativar assume o
  controle (para e desabilita o que estiver rodando, mata processo órfão que o painel reconheça
  como seu, e sobe os backends internos automaticamente conforme o que estava ativo/configurado);
  desativar devolve tudo ao padrão. Ver `multiplex.sh` e `MULTIPLEX-NETSIMON/README.md` original
  para detalhes do roteamento por SNI/TLS.

---

## 📝 Observação — ajuste do BadVPN UDPGW e do UDP no app NetSimon Leve (30/09/2026)

Registro do que foi alterado durante a correção de lentidão/travamento do app **NetSimon Leve**
(modo BHTTP sobre SSH) e do porquê de cada mudança.

### O problema

Com o app conectado, o WhatsApp funcionava, mas apps de vídeo (YouTube etc.) carregavam a lista e
não tocavam, e os navegadores não abriam páginas. Pelos logs do app (`SocksBridge`), dois defeitos:

1. **UDP sem resposta.** O app mandava o UDP (DNS, QUIC) **direto pela rede do celular**, fora do
   túnel, e nenhuma resposta voltava (0 respostas em ~155 associações UDP medidas). Sem DNS, os apps
   do Google não achavam os servidores de vídeo. O SSH (sshj) só carrega TCP (`direct-tcpip`), por
   isso o UDP direto tinha sido um atalho no passado.
2. **IPv6 sem saída.** O túnel do celular anunciava IPv6, mas o servidor não tem saída IPv6. Os
   navegadores tentavam IPv6 primeiro, eram recusados e quase não caíam para o IPv4.

### O que foi feito

**No app (NetSimon Leve, Android):**
- `SocksBridgeServer.kt`: o UDP passa a ir **por dentro do túnel** usando o `badvpn-udpgw` do
  servidor — um canal SSH `direct-tcpip` para `127.0.0.1:7300` (protocolo udpgw), compartilhado por
  todas as associações UDP. Se o udpgw estiver indisponível, o app volta ao UDP direto por 10 s e
  tenta de novo. UDP para destinos IPv6 é descartado (o servidor não tem IPv6).
- `SocksBridgeServer.kt`: CONNECT para IPv6 falha rápido com "network unreachable" (SOCKS `0x03`);
  depois de uma falha real, o app recusa IPv6 por 5 minutos e reavalia sozinho (se o servidor passar
  a ter IPv6, volta a funcionar).
- `RaceConnector.kt` / `V2RayProxyOnlyService.kt`: o `VpnService.protect()` agora é repassado ao
  `SocksBridgeServer` (antes chegava `null`, e o socket UDP de saída não era protegido).
- `V2RayProxyOnlyService.kt`: o tun fica **só IPv4** (flag `ipv6InTunnel = false`), para os
  navegadores não tentarem IPv6.
- `BLOCK_QUIC` continua `false` — descartar UDP/443 sem responder fez os apps travarem.

**No servidor (servidor 2):** como todos os fluxos UDP do app passam por **um único canal SSH**, o
udpgw os enxerga como **um só cliente**. O limite original `--max-connections-for-client 10`
derrubava as conexões UDP mais antigas quando o app abria muitos fluxos, perdendo respostas. Foi
criada uma sobreposição do systemd (o `badvpn.service` original **não foi editado**):

```ini
# /etc/systemd/system/badvpn.service.d/override.conf
[Service]
LimitNOFILE=65535
ExecStart=
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 1000
```

Cada conexão UDP usa um socket, por isso o `LimitNOFILE` sobe junto com o limite de conexões.
Backup do arquivo original: `/root/badvpn.service.bak-2026-09-30-0453`.

### Verificar

```bash
ps -o args= -p $(systemctl show -p MainPID --value badvpn)
grep 'open files' /proc/$(systemctl show -p MainPID --value badvpn)/limits
```

Esperado: `--max-connections-for-client 1000` e `Max open files 65535`.

### Desfazer

```bash
rm -r /etc/systemd/system/badvpn.service.d && systemctl daemon-reload && systemctl restart badvpn
```

### Pontos de atenção

- O `painel_api.py` só executa `restart`, `stop` e `start` do `badvpn` — não reescreve o arquivo do
  serviço, então a sobreposição sobrevive a esses comandos.
- O `limpar_servidor.sh` (linha 34) **apaga** o `badvpn.service`; se for executado, a sobreposição
  deixa de valer e o serviço volta a precisar ser recriado.
- O `badvpn@.service` (modelo separado, com limite 10) **não está em uso** na porta 7300 e não foi
  alterado.
- **Não verificado:** se o `install.sh` recria o `badvpn.service` ou remove a pasta `.d` ao
  reinstalar/atualizar por cima. Depois de reinstalar, rode os comandos de "Verificar" acima.
- Ao reiniciar o `badvpn`, o UDP de quem estiver conectado cai por um instante.
- O IPv6 fora do túnel pode vazar pela operadora no celular; se isso for um requisito, é preciso
  uma solução própria (não tratada aqui).

---

## 🔄 Atualização

```bash
bash <(curl -sSL "https://raw.githubusercontent.com/miau4/Painel-Netsimon/main/install.sh?t=$(date +%s)")
```

O instalador é idempotente — pode ser rodado de novo sem apagar usuários, dispositivos ou configurações já existentes. Ou, pelo painel/menu, use **Reparar Sistema** para restaurar só os arquivos sem tocar nos dados.

---

## 🗑️ Desinstalação

```bash
bash <(curl -sSL "https://raw.githubusercontent.com/miau4/Painel-Netsimon/main/uninstall.sh?t=$(date +%s)")
```

Pergunta antes de remover cada componente (dados, frontend, Xray-core) — nada é apagado sem confirmação.

---

## 📁 Estrutura do repositório

Quase todos os arquivos ficam soltos na **raiz** do repositório (sem subpastas), para que o
`install.sh` baixe cada um individualmente via `raw.githubusercontent.com` e o organize no
diretório correto do servidor (`/etc/painel/` para backend/scripts, `/var/www/html/` para
frontend) — a disposição dos arquivos no repositório é só uma questão de conveniência de upload,
não afeta onde eles acabam instalados.

As **duas únicas exceções** são pastas de propósito, mantidas como subpastas porque são
**sistemas complementares, instalados e usados separadamente** — nenhuma das duas é baixada ou
tocada pelo `install.sh` do painel:

- **`licenciamento/`** — servidor de licenças (Ed25519) opcional, para quem for distribuir o
  painel para terceiros com controle de plano/ativação. Roda numa máquina separada da VPS do
  painel. Ver `licenciamento/INSTRUCOES.md`.
- **`ferramentas_pc/`** — utilitários que rodam no computador do administrador (não na VPS),
  hoje contendo `capturar_historico_whatsapp.py`.

### Arquivos na raiz

```
install.sh, uninstall.sh, cleanup.sh, repair.sh        — controle geral da instalação
modelo_de_fix.sh                                         — modelo/template do formato padrão (a partir da v31) para gerar fixes pontuais: patch por diff (base64 + SHA-256 + applier Python, substituição exata de bloco) ou restauração completa quando não dá pra gerar diff seguro — sempre com validação, backup, restart só do serviço afetado e rollback automático. Ver formato completo dentro do arquivo.
fixes_aplicados/                                         — fixes pontuais já gerados nesse formato, mantidos como referência/histórico
migrate_ssh_xhttp.sh                                     — migração anti-DPI (SSH → XHTTP)
setup_https_domain.sh                                    — painel via domínio próprio + HTTPS

menu.sh, adduser.sh, addtest.sh, deluser.sh,            — base SSH/Xray
online.sh, limit.sh, unblock.sh, websocket.sh,            (scripts de terminal, ficam em /etc/painel)
xray.sh, xray_lib.sh, slowdns-server.sh, monitor.sh,
boot_check.sh, checkuser.sh, proxy.py, checkuser.py,
wss.py, wss_security.py, bhttp.sh, netsimon-bhttp        — wss.py/wss_security.py/bhttp.sh são os
                                                            outros 3 protocolos do menu WebSocket;
                                                            netsimon-bhttp é o binário compilado
                                                            (~20MB), embutido aqui pra instalação
                                                            nunca depender de download externo

painel_api.py, bot_telegram.py, requirements.txt,       — backend do painel web (Flask + bot)
whatsapp_bot.js, whatsapp-bot.service, package.json      — microserviço de notificação via WhatsApp (Node.js)

index.html, login.html, dashboard.html, usuarios.html,   — frontend do painel web (vai para /var/www/html)
todos-usuarios.html, dispositivos.html, xray.html,
websocket.html, slowdns.html, revendedores.html,
servidores.html, diagnostico.html, whatsapp.html,
app.html, backup.html, campanhas.html, bot.html,
logs.html, configuracoes.html, ia.html, material.html,
painel.css, painel.js

logo.png, painel_bg.mp4, favicon-32.png,                — identidade visual / ícones do PWA
apple-touch-icon.png, icon-home.png, icon-whatsapp.png
```

O `install.sh` baixa exatamente essa lista (menos os arquivos de controle geral, que já são o
próprio instalador rodando) — qualquer arquivo novo adicionado à raiz do repositório também
precisa ser adicionado a um dos arrays (`arquivos_base`, `arquivos_painel_backend` ou
`arquivos_frontend`) dentro do `install.sh`, senão ele fica no repositório mas nunca chega no
servidor.

**Exceção:** `bhttp.sh` e `netsimon-bhttp` **não** entram em nenhum desses arrays — como o binário
é grande (~20MB) e não pode depender de já estar commitado no repositório remoto pra a instalação
funcionar, o `install.sh` primeiro procura os dois na própria pasta de onde ele está sendo
executado (`SCRIPT_DIR`, ou seja, a pasta que resulta de baixar/clonar este repositório inteiro
antes de instalar) e só tenta baixar do `$REPO` como último recurso, caso o instalador esteja
rodando via `curl ... | bash` sem nenhum arquivo local em disco.

---

## 🛠️ Solução de problemas

```bash
# API do painel não inicia
journalctl -u netsimon-painel -n 50 --no-pager

# BadVPN não inicia
journalctl -u badvpn -n 50 --no-pager

# Nginx
nginx -t && systemctl status nginx

# Bot Telegram
tail -f /var/log/netsimon_bot.log

# Device Check recusando tudo
cat /etc/painel/device_check.token
tail -f /var/log/netsimon_device.log

# Reiniciar tudo
systemctl restart xray netsimon-painel badvpn nginx
```

---

## ⚠️ Segurança

- Troque a senha padrão do admin **imediatamente**
- O token do Device Check e o Access Token do Mercado Pago são sensíveis — nunca compartilhe
- Recomenda-se HTTPS (Let's Encrypt) na porta 81 se o painel for exposto com domínio próprio
- Endpoints públicos sem autenticação: `/api/auth/login`, `/api/app/latest`, `/ping` — todo o resto exige token válido

---

## 📜 Licença privada.
