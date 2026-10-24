# Netsimon-bhttp

Servidor **próprio** do protocolo SSH_BHTTP usado pelo app NETSIMON no modo
de conexão `SSH_BHTTP`. Implementação nova, feita do zero por engenharia
reversa da própria infraestrutura — não contém, não baixa e não depende de
nenhum binário ou código de terceiros. Só usa a biblioteca padrão do Go.

## O que ele faz

`netsimon-bhttpd` escuta em uma ou mais portas (tipicamente 80, e opcionalmente
443 com TLS), fala o protocolo BHTTP (framing próprio de 29/5 bytes + cifra
XOR contra um keystream SHA-256) e encaminha os bytes já desencapsulados para
o **sshd real do sistema operacional** rodando em `127.0.0.1:22`. Ele não
implementa SSH nem autenticação — quem autentica de verdade é o sshd do
servidor, contra os usuários do sistema, exatamente como o app espera.

## Instalação

Nada é baixado da internet — os binários (amd64 e arm64) já vêm dentro deste
pacote, em `bin/`.

```bash
sudo ./install.sh
```

Isso copia o binário certo pra arquitetura do servidor para
`/usr/local/bin/netsimon-bhttpd`, cria `/etc/netsimon-bhttp/config.json` (se
ainda não existir) e sobe o serviço via systemd (`netsimon-bhttp.service`),
com backup automático (com timestamp) de qualquer instalação anterior.

Se a arquitetura do servidor não tiver binário pré-compilado neste pacote,
compile a partir do código-fonte incluso (precisa de Go ≥1.22, só isso — sem
outras dependências):

```bash
cd netsimon-bhttp
go build -o /usr/local/bin/netsimon-bhttpd ./cmd/netsimon-bhttpd
```

## Configuração

`/etc/netsimon-bhttp/config.json`:

```json
{
  "listen": [
    { "host": "0.0.0.0", "port": 80, "tls": false }
  ],
  "tls": {
    "cert_file": "/etc/netsimon-bhttp/tls/fullchain.pem",
    "key_file": "/etc/netsimon-bhttp/tls/privkey.pem"
  },
  "backend": { "host": "127.0.0.1", "port": 22 },
  "session": { "idle_timeout_seconds": 300, "max_buffered_chunks": 4096 },
  "log": { "level": "info" }
}
```

Para habilitar a porta 443 com TLS, coloque `fullchain.pem`/`privkey.pem` em
`/etc/netsimon-bhttp/tls/` e adicione `{ "host": "0.0.0.0", "port": 443, "tls": true }`
na lista `listen`. Se o certificado não existir, o serviço sobe normalmente
só na porta sem TLS e avisa nos logs — não derruba o processo inteiro.

Depois de qualquer alteração:

```bash
systemctl restart netsimon-bhttp.service
```

## Operação

```bash
systemctl status netsimon-bhttp.service
journalctl -u netsimon-bhttp.service -f
ss -tlnp | grep -E ":80|:443"
```

## Desinstalação

```bash
sudo ./uninstall.sh
```

Remove o serviço systemd; o binário e a config ficam preservados (o script
mostra como apagá-los manualmente, se quiser).

## Arquitetura do código

```
cmd/netsimon-bhttpd/   ponto de entrada (config, listeners, TLS)
internal/bhttp/        protocolo: framing, cifra, sessão, dispatcher
internal/config/       carregamento/validação do config.json
systemd/               unit file
install.sh / uninstall.sh
bin/                   binários pré-compilados (amd64, arm64)
```

## Limitação conhecida (a monitorar)

O lado de download usa janelas paralelas com índice absoluto fixo por
conexão (mesmo esquema já validado no cliente). Em uso normal isso é
transparente, mas em sessões com picos de tráfego muito maiores que
`conexões × 8 × tamanho_do_chunk` de uma vez, alguma janela pedida muito à
frente da produção real pode voltar vazia e não ser repetida. Não apareceu
nos testes (handshake SSH + tráfego interativo), mas se notarmos
engasgos em transferências grandes/sustentadas, é o primeiro lugar a
revisar — dá pra evoluir para um esquema de crédito (servidor atribui o
próximo índice disponível em vez de o cliente adivinhar) sem mudar o
formato de fio, só a lógica de qual índice cada janela cobre.

## Protocolo BHP1 (v1.2.0) — o que o servidor entende

Alinhado ao diagnóstico do app NETSIMON Leve (servidor de referência DTunnel v3.2.0):

- **Modo 0 (sondagem):** payload `BHP1 + versão + submodo + parâmetro(4)`.
  - Submodo 2 (download): responde com exatamente `parâmetro` bytes (10 primeiros = eco, depois `byte[i]=(i*31)&0xFF`); recusa parâmetro < 10 e > 131072.
  - Demais submodos (0, 1, 3, 4): responde **só com os 10 primeiros bytes** do payload (nunca o eco completo). Medido no servidor antigo: probes de upload de 4096–16384 bytes recebem 10 bytes; se o servidor devolver o payload inteiro, o app recusa o tamanho e calibra o upload em 10 bytes.
  - ACK **nunca** é recusado por parâmetro.
- **Modo 1 (upload):** o registro vazio em seq 0 é aceito mas **opcional**; upload de sessão desconhecida cria a sessão. Seq fora de ordem fica retido em silêncio. Se o app usar registro vazio + dados a partir do seq 1, o seq 0 é dado como consumido após 1 s.
- **Modo 2 (download):** só cabeçalho (`length` = envelope máximo), resposta `status 0` + corpo cifrado bruto (cifra com modo 2, responseFlag 1), **sem** prefixo de 4 bytes. Corpo vazio = sem dados naquele seq ainda.
- **Modo 3 (batch, legado):** mantido para apps antigos.
- **Modo 4 (ACK):** só cabeçalho; sessão desconhecida devolve `status 1` + `session expired`.
- Todo `status 1` traz texto no corpo (`session expired`, `invalid envelope`, `envelope too large`, `unknown mode`, `backend unavailable`).
- Lixo enviado ao sshd derruba a sessão inteira (comportamento do sshd); o app recebe `session expired`.

### Depuração (app conecta mas não trafega dados)

Em `config.json`: `"log": {"level": "debug"}` registra cada requisição (`modo`, `sid`, `seq`, `length`, `payload`) —
dá para ver se o app está mesmo fazendo upload (modo 1) e download (modo 2) e em que sequência.
`session.download_wait_ms` (padrão 8000) controla quanto o servidor espera antes de devolver "vazio" num download;
se o app tiver timeout de leitura curto, teste 1000 ou 0.

## v1.3.0 — estabilidade

- **Retry de download sem perda:** a janela de retenção de chunks já entregues era fixa em 32 e,
  com várias conexões de download em paralelo, descartava um chunk cuja resposta tinha se perdido
  (NAT/operadora) e que o app ainda ia pedir de novo — o app recebia "vazio" para sempre e a sessão
  parava de gerar dados. Agora é `session.retain_chunks` (padrão 256); o ACK do app continua
  liberando antes.
- **Download conta como atividade da sessão** (antes só upload/ACK), evitando coleta indevida pelo reaper.
- **Conexão persistente (opt-in):** `session.keepalive_idle_seconds` > 0 faz o servidor atender várias
  requisições na mesma conexão TCP (framing por tamanho). 0 (padrão) = comportamento antigo.
  Sugestão para teste: 30.
- O long-poll de download já existia (`download_wait_ms`, padrão 8000).

## v1.4.0 — download por crédito (corrige "para de gerar dados")

**Causa (provada no log de debug do servidor):** o app trata resposta vazia de download como posição
já consumida e avança +N. O servidor antigo numerava os blocos pela ordem de produção e só entregava o
bloco N ao pedido N. Numa pausa de tráfego maior que `download_wait_ms` (8 s), todos os pedidos pendentes
expiravam vazios e o app pulava para posições bem à frente; o próximo dado do sshd saía numa posição que
ninguém mais pedia e se perdia. Sem dado, o watchdog do app (25 s) derrubava a sessão.

**Correção:** o seq do pedido é uma *posição*. Cada bloco lido do sshd vai para o pedido pendurado com o
menor slot acima do último slot que recebeu dado (`hw`), sempre em ordem crescente. Slot que expira vazio é
só um buraco; nenhum dado se perde. Retry de uma resposta perdida devolve o mesmo bloco. Se há blocos demais
sem pedido, o servidor para de ler do sshd (contrapressão) em vez de descartar.

- `session.slot_credit` (padrão `true`); `false` volta ao esquema antigo. No `bhttpd.sh`: `BHTTPD_SLOT_CREDIT=0|1`.
- Testes: `go test ./internal/bhttp/` (fluxo íntegro com pausas, 7/32 threads, respostas perdidas; o mesmo
  cenário no esquema antigo recebe 25 de 60 KB).
