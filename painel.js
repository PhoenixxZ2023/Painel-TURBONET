// ==========================================
//   PAINEL NETSIMON - JS Principal
// ==========================================

const API_BASE = "/api";

// ── Auth ──────────────────────────────────────────────────────────
function getToken()    { return localStorage.getItem("ns_token") || ""; }
function getRole()     { return localStorage.getItem("ns_role")  || ""; }
function getUsername() { return localStorage.getItem("ns_user")  || ""; }

// ── Tema (claro/escuro) ───────────────────────────────────────────
// Ícone mostra o tema que você VAI ATIVAR ao clicar (não o atual):
// sol visível = está no escuro agora, clique pra ir pro claro; lua
// visível = está no claro agora, clique pra voltar pro escuro.
function getTheme() { return localStorage.getItem("ns_theme") === "light" ? "light" : "dark"; }

function applyTheme(theme) {
  if (theme === "light") document.documentElement.setAttribute("data-theme", "light");
  else document.documentElement.removeAttribute("data-theme");
  const btn = document.getElementById("btn-theme-toggle");
  if (btn) btn.textContent = theme === "light" ? "🌙" : "☀️";
}

function toggleTheme() {
  const next = getTheme() === "light" ? "dark" : "light";
  localStorage.setItem("ns_theme", next);
  applyTheme(next);
}

async function api(path, method = "GET", body = null) {
  const opts = {
    method,
    headers: { "X-Token": getToken(), "Content-Type": "application/json" }
  };
  if (body) opts.body = JSON.stringify(body);
  try {
    const r = await fetch(API_BASE + path, opts);
    if (r.status === 401) { doLogout(); return null; }
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      toast(err.error || `Erro ${r.status}`, true);
      return null;
    }
    return await r.json();
  } catch (e) {
    toast("Erro de conexão", true);
    return null;
  }
}

async function doLogout() {
  await fetch(API_BASE + "/auth/logout", {
    method: "POST",
    headers: { "X-Token": getToken() }
  }).catch(() => {});
  // Item: antes usava localStorage.clear(), que apagava TODAS as
  // preferências do navegador junto com o login — inclusive o tema e o
  // toggle de "Monitoramento em tempo real (voz)" do Menu > IA. Como as
  // sessões do painel ficam em memória (_sessions, no Flask), reiniciar
  // o serviço netsimon-painel invalida o token de qualquer aba já
  // aberta; a próxima chamada de API cai em 401 e doLogout() era
  // chamado automaticamente — resetando essas preferências mesmo sem o
  // admin nunca ter mexido nelas. Agora só remove as chaves de
  // autenticação: as preferências continuam persistentes e só mudam se
  // o próprio usuário mudar manualmente.
  localStorage.removeItem("ns_token");
  localStorage.removeItem("ns_role");
  localStorage.removeItem("ns_user");
  window.location.href = "/login.html";
}

// ── Toast ─────────────────────────────────────────────────────────
let _toastTimer;
function toast(msg, isErr = false) {
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = msg;
  el.className = "toast show" + (isErr ? " err" : "");
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => { el.className = "toast"; }, 3000);
}

// ── Impersonação (item 14): entrar no painel de um revendedor já
//    autenticado, com um jeito simples de voltar para a sessão original.
function startImpersonation(token, username) {
  const backToken = getToken();
  const backUser  = getUsername();
  const backRole  = getRole();
  if (backToken) {
    sessionStorage.setItem("ns_impersonate_back_token", backToken);
    sessionStorage.setItem("ns_impersonate_back_user", backUser);
    sessionStorage.setItem("ns_impersonate_back_role", backRole);
  }
  localStorage.setItem("ns_token", token);
  localStorage.setItem("ns_role", "reseller");
  localStorage.setItem("ns_user", username);
  window.location.href = "/dashboard.html";
}

function returnFromImpersonation() {
  const backToken = sessionStorage.getItem("ns_impersonate_back_token");
  const backUser  = sessionStorage.getItem("ns_impersonate_back_user");
  const backRole  = sessionStorage.getItem("ns_impersonate_back_role");
  if (!backToken) return;
  sessionStorage.removeItem("ns_impersonate_back_token");
  sessionStorage.removeItem("ns_impersonate_back_user");
  sessionStorage.removeItem("ns_impersonate_back_role");
  localStorage.setItem("ns_token", backToken);
  localStorage.setItem("ns_role", backRole);
  localStorage.setItem("ns_user", backUser);
  window.location.href = backRole === "admin" ? "/dashboard.html" : "/revendedores.html";
}

function injectImpersonationBanner() {
  if (!sessionStorage.getItem("ns_impersonate_back_token")) return;
  if (document.getElementById("impersonate-banner")) return;
  const banner = document.createElement("div");
  banner.id = "impersonate-banner";
  banner.className = "impersonate-banner";
  banner.innerHTML = `Você está visualizando o painel de <strong>${getUsername()}</strong> como convidado.
    <button class="btn btn-sm btn-ghost" onclick="returnFromImpersonation()">↩ Voltar ao meu painel</button>`;
  document.body.prepend(banner);
}

// ── Inicialização de página ───────────────────────────────────────
async function initPage() {
  const token = getToken();
  if (!token) { window.location.href = "/login.html"; return; }

  // Sidebar username/role
  const uEl = document.getElementById("sidebar-username");
  const rEl = document.getElementById("sidebar-role");
  if (uEl) uEl.textContent = getUsername();
  if (rEl) rEl.textContent = getRole() === "admin" ? "Administrador" : "Revendedor";

  // v30: versão do painel, discreta, no rodapé da sidebar — não polui
  // nenhuma tela nova nem exige editar as 19 páginas que compartilham
  // esse rodapé, só injeta o texto pequeno junto do usuário/role.
  // v48: estava parado em "v43" desde aquela versão, dessincronizado do
  // rodapé do login.html (que foi atualizado normalmente) — atualizado
  // manualmente aqui até existir uma fonte única de versão pros dois.
  const sidebarFooter = document.querySelector(".sidebar-footer .user-info div");
  if (sidebarFooter && !document.getElementById("sidebar-version")) {
    const vEl = document.createElement("div");
    vEl.id = "sidebar-version";
    vEl.textContent = "v51";
    vEl.style.cssText = "font-size:10px; opacity:.5; margin-top:2px;";
    sidebarFooter.appendChild(vEl);
  }

  // Oculta itens admin-only para revendedores
  if (getRole() !== "admin") {
    document.querySelectorAll(".admin-only").forEach(el => el.style.display = "none");
  }

  // Item 5: "Revendedores" só aparece para o admin e para revendedores
  // de nível 2 (que podem gerenciar sub-revendedores de nível 3).
  if (getRole() === "reseller") {
    const me = await api("/auth/me");
    if (me && me.can_manage_resellers === false) {
      document.querySelectorAll(".reseller-manage-only").forEach(el => el.style.display = "none");
    }
  }

  injectImpersonationBanner();

  // Marca nav item ativo
  const page = window.location.pathname.split("/").pop().replace(".html","");
  document.querySelectorAll(".nav-item").forEach(a => {
    a.classList.toggle("active", a.dataset.page === page);
  });

  // Item 3: agrupa Xray/WebSocket/SlowDNS num submenu "Gerenciar Conexões"
  injectConnGroup(page);

  // v48.1: menu lateral EXTRAS (só admin)
  injectExtrasMenu(page);

  // Item 6: sino de notificações no topbar
  injectNotifBell();

  // Oculta itens admin-only para revendedores (roda de novo aqui pois
  // o grupo de conexões acima foi injetado depois da primeira checagem)
  if (getRole() !== "admin") {
    document.querySelectorAll(".admin-only").forEach(el => el.style.display = "none");
  }

  // Logout
  const btnL = document.getElementById("btn-logout");
  if (btnL) btnL.addEventListener("click", doLogout);

  // Tema — o <head> já aplicou a cor certa cedo (evita flash), aqui só
  // sincroniza o ícone do botão com o tema atual
  applyTheme(getTheme());

  // Burger (mobile)
  const burger = document.getElementById("burger");
  const sidebar = document.getElementById("sidebar");
  if (burger && sidebar) {
    burger.addEventListener("click", () => sidebar.classList.toggle("open"));
    document.addEventListener("click", e => {
      if (!sidebar.contains(e.target) && !burger.contains(e.target))
        sidebar.classList.remove("open");
    });
  }

  // Item: blocos retráteis — cada card-panel marcado com data-panel-id
  // vira colapsável, lembrando o estado (aberto/fechado) por página.
  initCollapsiblePanels();
}

// ── Blocos retráteis (item pedido: abrir só o bloco de interesse no
// momento, sem a tela ficar poluída com informação que não se usa ali
// — e lembrar o estado de um acesso pro outro) ──────────────────────
// Qualquer .card-panel com data-panel-id="algum-id" vira clicável no
// header pra abrir/fechar. O estado fica salvo no localStorage,
// separado por página (usa o caminho da URL) e por bloco (o
// data-panel-id) — assim cada tela lembra exatamente quais blocos
// você deixou abertos/fechados da última vez, sem misturar com outras
// páginas nem com outros blocos de mesmo nome em telas diferentes.
function initCollapsiblePanels() {
  const panels = document.querySelectorAll(".card-panel[data-panel-id]");
  if (!panels.length) return;

  const storeKey = "ns_panels:" + location.pathname;
  let state = {};
  try { state = JSON.parse(localStorage.getItem(storeKey) || "{}"); } catch {}

  panels.forEach(panel => {
    const id = panel.dataset.panelId;
    const header = panel.querySelector(":scope > .card-panel-header");
    if (!header) return;

    if (state[id] === true) panel.classList.add("panel-collapsed");

    header.addEventListener("click", ev => {
      // Clicar num botão/switch/link/campo dentro do header (ex: "↻
      // Atualizar", o interruptor de ligar a IA) não deve abrir/fechar
      // o bloco — só clicar na área "vazia" do título faz isso.
      if (ev.target.closest("button, a, input, label, select, textarea")) return;
      panel.classList.toggle("panel-collapsed");
      state[id] = panel.classList.contains("panel-collapsed");
      try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch {}
    });
  });
}

// ── Item 3: Protocolos (submenu Xray/WebSocket/SlowDNS) ────────────
// Substitui o item "Xray" da sidebar por um grupo expansível.
function injectConnGroup(page) {
  const xrayLink = document.querySelector('.nav-item[data-page="xray"]');
  if (!xrayLink || xrayLink.closest(".nav-group")) return; // já injetado ou página sem sidebar

  const groupPages = ["xray", "websocket", "slowdns"];
  const isOpen = groupPages.includes(page);
  const highlightPage = page;

  const group = document.createElement("div");
  group.className = "nav-group" + (isOpen ? " open" : "");
  group.innerHTML = `
    <button type="button" class="nav-item nav-group-toggle admin-only" title="Protocolos de conexão do servidor: Xray, WebSocket e SlowDNS">
      <span class="nav-icon nav-icon-img"><img src="/img/icon-protocolos.png" alt="Protocolos"></span><span>Protocolos</span><span class="nav-caret">▸</span>
    </button>
    <div class="nav-submenu">
      <a href="/xray.html" class="nav-item nav-sub admin-only" data-page="xray" title="Xray (VLESS/VMESS): proxy multiplataforma, mais leve e difícil de detectar por DPI"><span class="nav-icon nav-icon-img"><img src="/img/icon-xray.png" alt="Xray"></span><span>Xray</span></a>
      <a href="/websocket.html" class="nav-item nav-sub admin-only" data-page="websocket" title="WebSocket: 4 sistemas de túnel SSH — WS PROXY, WSS TLS, WSS SSH e STUNNEL SSL"><span class="nav-icon">🌐</span><span>WebSocket</span></a>
      <a href="/slowdns.html" class="nav-item nav-sub admin-only" data-page="slowdns" title="SlowDNS: túnel SSH sobre consultas DNS, útil quando só a porta 53 está liberada"><span class="nav-icon">🐌</span><span>SlowDNS</span></a>
    </div>
  `;
  xrayLink.replaceWith(group);

  group.querySelectorAll(".nav-sub").forEach(a => a.classList.toggle("active", a.dataset.page === highlightPage));
  group.querySelector(".nav-group-toggle").addEventListener("click", () => group.classList.toggle("open"));
}

// ── v48.1: menu lateral "EXTRAS" ───────────────────────────────────
// Grupo expansível no mesmo padrão do "Protocolos". Injetado aqui (e não
// nas 19 páginas) porque a sidebar é copiada em cada HTML. Só admin: o
// item leva a classe admin-only, escondida para revendedores em initPage.
function injectExtrasMenu(page) {
  const nav = document.querySelector(".sidebar-nav");
  if (!nav || document.getElementById("nav-extras")) return;

  const group = document.createElement("div");
  group.id = "nav-extras";
  group.className = "nav-group" + (page === "extras" ? " open" : "");
  group.innerHTML = `
    <button type="button" class="nav-item nav-group-toggle admin-only" title="Ferramentas extras do servidor">
      <span class="nav-icon">🧰</span><span>EXTRAS</span><span class="nav-caret">▸</span>
    </button>
    <div class="nav-submenu">
      <a href="/extras.html" class="nav-item nav-sub admin-only" data-page="extras" title="Consultar se um link (CloudFront, domínio ou IP) está ativo e chegando nesta VPS"><span class="nav-icon">🔗</span><span>Consultar link</span></a>
    </div>
  `;
  // Fica logo acima de "Configurações" (último item), se existir
  const cfg = nav.querySelector('.nav-item[data-page="config"]');
  if (cfg) nav.insertBefore(group, cfg); else nav.appendChild(group);

  group.querySelectorAll(".nav-sub").forEach(a => a.classList.toggle("active", a.dataset.page === page));
  group.querySelector(".nav-group-toggle").addEventListener("click", () => group.classList.toggle("open"));
}

// ── Item 6: Sino de notificações ────────────────────────────────────
// Avisa de forma simples e direta sobre o que importa: vencimentos
// próximos, serviços parados, desempenho ruim e servidores fora do ar.
let _lastNotifList = [];
const NOTIF_SEEN_KEY = "netsimon_seen_notif_ids";

function _getSeenNotifIds() {
  try { return new Set(JSON.parse(localStorage.getItem(NOTIF_SEEN_KEY) || "[]")); }
  catch { return new Set(); }
}
function _saveSeenNotifIds(set) {
  try { localStorage.setItem(NOTIF_SEEN_KEY, JSON.stringify([...set])); } catch {}
}

function injectNotifBell() {
  if (document.getElementById("notif-bell")) return;
  let right = document.querySelector(".topbar-right");
  if (!right) {
    const left = document.querySelector(".topbar-left");
    if (!left || !left.parentElement) return;
    right = document.createElement("div");
    right.className = "topbar-right";
    left.parentElement.appendChild(right);
  }

  const wrap = document.createElement("div");
  wrap.className = "notif-wrap";
  wrap.innerHTML = `
    <button class="notif-bell" id="notif-bell" title="Notificações">
      🔔<span class="notif-dot" id="notif-dot" style="display:none"></span>
    </button>
    <div class="notif-panel" id="notif-panel">
      <div class="notif-panel-header">Notificações</div>
      <div class="notif-list" id="notif-list"><div class="text-muted text-sm" style="padding:16px">Carregando…</div></div>
    </div>
  `;
  right.insertBefore(wrap, right.firstChild);

  document.getElementById("notif-bell").addEventListener("click", (e) => {
    e.stopPropagation();
    const panel = document.getElementById("notif-panel");
    const opening = !panel.classList.contains("open");
    panel.classList.toggle("open");
    if (opening) {
      // Ao abrir o sino, essas notificações passam a ser "vistas" — somem
      // do letreiro rolante da tela Início e da bolinha do sino até que
      // surja algo novo.
      const seen = _getSeenNotifIds();
      _lastNotifList.forEach(n => seen.add(n.id));
      _saveSeenNotifIds(seen);
      updateNotifTicker(_lastNotifList);
      updateNotifDot();
    }
  });
  document.addEventListener("click", (e) => {
    const panel = document.getElementById("notif-panel");
    if (panel && !wrap.contains(e.target)) panel.classList.remove("open");
  });

  loadNotifications();
  setInterval(loadNotifications, 45000);
}

async function loadNotifications() {
  const list = await api("/notifications");
  _lastNotifList = list || [];
  const dot = document.getElementById("notif-dot");
  const el = document.getElementById("notif-list");
  updateNotifTicker(_lastNotifList);
  updateNotifDot();
  _voiceMonitorCheck(_lastNotifList);
  if (!el) return;
  if (!list) { return; }

  if (!list.length) {
    el.innerHTML = `<div class="text-muted text-sm" style="padding:16px">Tudo certo por aqui — nenhum aviso no momento. ✅</div>`;
    return;
  }

  el.innerHTML = list.map(n => `
    <div class="notif-item notif-${n.level}">
      <span class="notif-icon">${n.icon || "ℹ️"}</span>
      <div>
        <div class="notif-title">${n.title}</div>
        <div class="notif-msg">${n.message}</div>
      </div>
    </div>
  `).join("");
}

// ── Monitoramento por voz em tempo real (item: "Jarvis" do painel) ──
// Reaproveita os MESMOS avisos que já alimentam o sino 🔔 acima (não
// cria nenhuma requisição nova nem gasta cota da IA configurada) e, se
// o admin tiver ativado o monitoramento em Menu > IA, AVISA EM VOZ ALTA
// (Web Speech API do navegador, só neste dispositivo) quando surge algo
// GENUINAMENTE NOVO — enquanto o painel estiver aberto em qualquer aba.
// Roda dentro do mesmo polling de 45s do sino (ver injectNotifBell).
const VOICE_MONITOR_KEY       = "ns_voice_monitor_enabled";
const VOICE_MONITOR_VOICE_KEY = "ns_voice_monitor_voice";
const VOICE_MONITOR_SPOKEN_KEY = "ns_voice_monitor_spoken";

function voiceMonitorEnabled() {
  return localStorage.getItem(VOICE_MONITOR_KEY) === "1";
}

function _getSpokenNotifIds() {
  try { return new Set(JSON.parse(localStorage.getItem(VOICE_MONITOR_SPOKEN_KEY) || "[]")); }
  catch { return new Set(); }
}
function _saveSpokenNotifIds(set) {
  // guarda só os últimos 300 ids pra não crescer sem limite no localStorage
  try { localStorage.setItem(VOICE_MONITOR_SPOKEN_KEY, JSON.stringify([...set].slice(-300))); } catch {}
}

// Escolhe a voz: usa a salva pelo admin em Menu > IA se existir; senão
// tenta achar automaticamente uma voz em português com nome de mulher
// (a maioria dos navegadores já traz a voz padrão de pt-BR como
// feminina, ex: "Google português do Brasil", "Microsoft Maria",
// "Luciana"); na falta de qualquer voz em pt, usa a primeira disponível.
function pickVoiceMonitorVoice() {
  if (!window.speechSynthesis) return null;
  const voices = window.speechSynthesis.getVoices() || [];
  if (!voices.length) return null;
  const savedName = localStorage.getItem(VOICE_MONITOR_VOICE_KEY);
  if (savedName) {
    const saved = voices.find(v => v.name === savedName);
    if (saved) return saved;
  }
  const ptVoices = voices.filter(v => (v.lang || "").toLowerCase().startsWith("pt"));
  const femininaPt = ptVoices.find(v => /female|mulher|maria|luciana|fernanda|joana|camila|helena/i.test(v.name));
  return femininaPt || ptVoices[0] || voices[0] || null;
}

function speakNotification(text) {
  if (!window.speechSynthesis || !text) return;
  const utter = new SpeechSynthesisUtterance(text);
  const voice = pickVoiceMonitorVoice();
  if (voice) { utter.voice = voice; utter.lang = voice.lang; }
  else { utter.lang = "pt-BR"; }
  utter.rate = 1;
  utter.pitch = 1.05;
  window.speechSynthesis.speak(utter);
}

function _voiceMonitorCheck(list) {
  if (!voiceMonitorEnabled() || !window.speechSynthesis) return;
  const spoken = _getSpokenNotifIds();
  const novos = (list || []).filter(n => !spoken.has(n.id));
  if (!novos.length) return;

  // Primeira vez que o monitor roda neste navegador: não lê em voz alta
  // um histórico inteiro que já existia antes de ativar — só define a
  // linha de base (marca como "já visto") e passa a falar dali em diante.
  if (spoken.size === 0) {
    novos.forEach(n => spoken.add(n.id));
    _saveSpokenNotifIds(spoken);
    return;
  }

  // Urgente (serviço caiu, incidente sem correção) primeiro que o resto
  const criticos = novos.filter(n => n.level === "danger");
  const resto = novos.filter(n => n.level !== "danger");
  const paraFalar = [...criticos, ...resto].slice(0, 4);
  paraFalar.forEach(n => speakNotification(`${n.title}. ${n.message}`));
  if (novos.length > paraFalar.length) {
    speakNotification(`E mais ${novos.length - paraFalar.length} ponto${novos.length - paraFalar.length > 1 ? "s" : ""} de atenção novo${novos.length - paraFalar.length > 1 ? "s" : ""}. Confira o sino de notificações.`);
  }
  novos.forEach(n => spoken.add(n.id));
  _saveSpokenNotifIds(spoken);
}

// A bolinha do sino só deve acender se existir notificação ainda NÃO
// vista — antes ela ficava presa pra sempre enquanto houvesse qualquer
// notificação ativa na API, mesmo depois de abrir o sino e "ler" tudo.
function updateNotifDot() {
  const dot = document.getElementById("notif-dot");
  if (!dot) return;
  const seen = _getSeenNotifIds();
  const hasUnseen = _lastNotifList.some(n => !seen.has(n.id));
  dot.style.display = hasUnseen ? "block" : "none";
}

// ── Letreiro de notificações (tela Início) ──────────────────────────
// Mostra em loop horizontal todas as notificações ainda não vistas (ou
// seja, que a pessoa ainda não abriu no sino) — some assim que o sino é
// aberto, e volta a aparecer se surgir alguma notificação nova depois.
function updateNotifTicker(list) {
  const wrap = document.getElementById("notif-ticker-wrap");
  const track = document.getElementById("notif-ticker-track");
  if (!wrap || !track) return; // container só existe na tela Início

  const seen = _getSeenNotifIds();
  const pending = (list || []).filter(n => !seen.has(n.id));

  if (!pending.length) {
    wrap.classList.add("empty");
    track.style.animation = "none";
    track.innerHTML = "";
    return;
  }

  const itemsHtml = pending.map(n => `
    <span class="notif-ticker-item notif-ticker-${n.level}">
      <span class="notif-ticker-icon">${n.icon || "ℹ️"}</span>
      <strong>${n.title}</strong>&nbsp;— ${n.message}
    </span>
  `).join("");
  // Conteúdo duplicado = loop contínuo sem "salto" visível no fim da volta.
  track.innerHTML = itemsHtml + itemsHtml;
  wrap.classList.remove("empty");

  requestAnimationFrame(() => {
    const singleWidth = track.scrollWidth / 2;
    const pxPerSecond = 55;
    const duration = Math.max(12, Math.round(singleWidth / pxPerSecond));
    track.style.animation = "none";
    void track.offsetWidth; // força reflow pra reiniciar a animação do zero
    track.style.animation = `notif-ticker-scroll ${duration}s linear infinite`;
  });
}


function openModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.add("open");
}

function closeModal(id) {
  const m = document.getElementById(id);
  if (m) { m.classList.remove("open"); }
}

document.addEventListener("click", e => {
  if (e.target.classList.contains("modal-overlay")) {
    e.target.classList.remove("open");
  }
});

// ── Tabs ──────────────────────────────────────────────────────────
function initTabs(containerSel) {
  const container = document.querySelector(containerSel);
  if (!container) return;
  container.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const target = btn.dataset.tab;
      container.querySelectorAll(".tab-btn").forEach(b => b.classList.toggle("active", b === btn));
      container.querySelectorAll(".tab-panel").forEach(p => p.classList.toggle("active", p.id === target));
    });
  });
}

// ── Formatação de data ────────────────────────────────────────────
function fmtDate(str) {
  if (!str) return "–";
  try {
    const d = new Date(str.replace(" ", "T"));
    return d.toLocaleDateString("pt-BR") + " " + d.toLocaleTimeString("pt-BR", {hour:"2-digit",minute:"2-digit"});
  } catch { return str; }
}

function isExpired(str) {
  if (!str) return false;
  return new Date(str.replace(" ", "T")) < new Date();
}

// ── Copy to clipboard ─────────────────────────────────────────────
// navigator.clipboard só existe em contexto seguro (HTTPS ou localhost).
// Como o painel normalmente roda em HTTP puro (http://IP:81), acessar
// navigator.clipboard.writeText direto lança erro SÍNCRONO antes do
// .catch() conseguir capturar — por isso os botões de copiar pareciam
// não fazer nada. Aqui sempre validamos o contexto antes, com fallback
// via textarea+execCommand garantido para HTTP.
// ── Terminal Web (ttyd, protegido por sessão) ──────────────────────
function openTerminal() {
  window.open("/terminal/", "_blank");
}

function copyText(text) {
  try {
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => toast("Copiado!")).catch(() => fallbackCopyText(text));
      return;
    }
  } catch (e) { /* cai no fallback abaixo */ }
  fallbackCopyText(text);
}

function fallbackCopyText(text) {
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    ta.style.top = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    ok ? toast("Copiado!") : toast("Não foi possível copiar. Selecione e copie manualmente.", true);
  } catch (e) {
    toast("Não foi possível copiar. Selecione e copie manualmente.", true);
  }
}

// ── Confirmação simples ───────────────────────────────────────────
function confirm2(msg) {
  return window.confirm(msg);
}

// ══════════════════════════════════════════════════════════════════
//  v51 — LISTAS DE TRANSMISSÃO: janelas compartilhadas
//  Usadas por usuarios.html (usuários marcados) e campanhas.html
//  (membros de uma lista). As janelas são injetadas sob demanda.
// ══════════════════════════════════════════════════════════════════
function _bcEsc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function _bcEnsureModals() {
  if (document.getElementById("modal-bc-send")) return;
  const wrap = document.createElement("div");
  wrap.innerHTML = `
<div class="modal-overlay" id="modal-bc-send">
  <div class="modal" style="max-width:600px; max-height:92vh; overflow:auto">
    <div class="modal-header">
      <span class="modal-title" id="bc-send-title">📣 Enviar mensagem</span>
      <button class="modal-close" onclick="closeModal('modal-bc-send')">×</button>
    </div>
    <div id="bc-send-resumo" class="text-sm" style="padding:0 4px 10px"></div>
    <div class="form-grid" style="padding:0 4px">
      <div class="form-field">
        <label>Nome da transmissão (aparece no histórico de campanhas)</label>
        <input type="text" id="bc-name">
      </div>
      <div class="form-field">
        <label>Mensagem</label>
        <textarea id="bc-message" rows="5" class="ta-mono" placeholder="Ex: Olá! Seu acesso vence em breve. Para renovar, fale com a gente."></textarea>
      </div>
      <div class="form-field">
        <label>Anexo (opcional)</label>
        <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap">
          <select id="bc-media-type">
            <option value="">Sem anexo</option>
            <option value="image">🖼️ Imagem</option>
            <option value="video">🎬 Vídeo</option>
            <option value="document">📄 Arquivo (ex: APK)</option>
          </select>
          <button type="button" class="btn btn-ghost btn-sm" onclick="document.getElementById('bc-media-file').click()">📎 Escolher arquivo</button>
          <span id="bc-media-filename" class="text-sm text-muted"></span>
          <input type="file" id="bc-media-file" style="display:none" onchange="document.getElementById('bc-media-filename').textContent = this.files[0] ? this.files[0].name : ''">
        </div>
      </div>
      <div class="form-row">
        <div class="form-field">
          <label>Pausa entre envios (segundos, mín. 5)</label>
          <input type="number" id="bc-delay" min="5" value="30">
        </div>
        <div class="form-field">
          <label>Limite por dia (0 = sem limite)</label>
          <input type="number" id="bc-maxday" min="0" value="0">
        </div>
      </div>
      <div class="form-field">
        <label style="font-weight:400; display:block; margin-bottom:6px"><input type="checkbox" id="bc-hourly" style="width:auto; margin-right:6px">Espaçar envios em pelo menos 1h entre cada mensagem</label>
        <label style="font-weight:400; display:block"><input type="checkbox" id="bc-business" style="width:auto; margin-right:6px">Enviar somente em dias úteis (seg–sex), das 08:00 às 22:00</label>
      </div>
      <div class="form-field">
        <label>Agendar para (opcional — usado pelo botão "Agendar")</label>
        <input type="datetime-local" id="bc-schedule">
      </div>
      <div id="bc-save-wrap" class="card-panel" style="padding:12px 14px">
        <div style="font-weight:600; margin-bottom:8px">📋 Lista de transmissão</div>
        <label style="font-weight:400; display:block; margin-bottom:6px"><input type="radio" name="bc-save" value="new" checked style="width:auto; margin-right:6px" onchange="_bcSaveModeChanged()">Salvar estes usuários numa lista nova</label>
        <input type="text" id="bc-list-name" placeholder="Nome da lista (ex: Vencidos de outubro)" style="margin:0 0 8px 22px; width:calc(100% - 22px)">
        <label style="font-weight:400; display:block; margin-bottom:6px"><input type="radio" name="bc-save" value="existing" style="width:auto; margin-right:6px" onchange="_bcSaveModeChanged()">Somar a uma lista que já existe</label>
        <select id="bc-list-existing" style="margin:0 0 8px 22px; width:calc(100% - 22px)" disabled></select>
        <label style="font-weight:400; display:block"><input type="radio" name="bc-save" value="none" style="width:auto; margin-right:6px" onchange="_bcSaveModeChanged()">Não salvar lista (só enviar)</label>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="closeModal('modal-bc-send')">Cancelar</button>
      <button class="btn btn-ghost" id="bc-btn-draft" onclick="_bcSubmit('rascunho')">💾 Rascunho</button>
      <button class="btn btn-ghost" id="bc-btn-schedule" onclick="_bcSubmit('agendar')">🗓️ Agendar</button>
      <button class="btn btn-primary" id="bc-btn-now" onclick="_bcSubmit('agora')">🚀 Enviar agora</button>
    </div>
  </div>
</div>

<div class="modal-overlay" id="modal-bc-addlist">
  <div class="modal" style="max-width:460px">
    <div class="modal-header">
      <span class="modal-title">📋 Adicionar à lista de transmissão</span>
      <button class="modal-close" onclick="closeModal('modal-bc-addlist')">×</button>
    </div>
    <div id="bc-add-resumo" class="text-sm" style="padding:0 4px 10px"></div>
    <div class="form-grid" style="padding:0 4px">
      <div class="form-field">
        <label>Lista existente</label>
        <select id="bc-add-existing"></select>
      </div>
      <div class="text-sm text-muted" style="text-align:center">— ou —</div>
      <div class="form-field">
        <label>Criar lista nova</label>
        <input type="text" id="bc-add-newname" placeholder="Nome da nova lista">
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="closeModal('modal-bc-addlist')">Cancelar</button>
      <button class="btn btn-primary" onclick="_bcAddSubmit()">Adicionar</button>
    </div>
  </div>
</div>`;
  while (wrap.firstChild) document.body.appendChild(wrap.firstChild);
}

let _bcCtx = null;   // contexto da janela de envio aberta

function _bcSaveModeChanged() {
  const mode = document.querySelector('input[name="bc-save"]:checked').value;
  document.getElementById("bc-list-name").disabled = mode !== "new";
  document.getElementById("bc-list-existing").disabled = mode !== "existing";
}

function _bcFillListSelect(sel, lists, withHint) {
  sel.innerHTML = lists.length
    ? lists.map(l => `<option value="${_bcEsc(l.id)}">${_bcEsc(l.name)} (${l.count})</option>`).join("")
    : `<option value="">${withHint}</option>`;
}

// opts: { logins:[...] } OU { listId, listName }; onDone: callback após criar
async function openBroadcastModal(opts) {
  _bcEnsureModals();
  const fromList = !!opts.listId;
  const resolved = await api("/broadcast/resolve", "POST", fromList ? { list_id: opts.listId } : { logins: opts.logins });
  if (!resolved) return;
  if (!resolved.com_telefone) {
    toast("Nenhum dos usuários tem WhatsApp vinculado — preencha o telefone no ✏️ do usuário.", true);
    return;
  }
  _bcCtx = { opts, fromList, resolved, busy: false };

  const d = new Date(), pad = n => String(n).padStart(2, "0");
  const stamp = `${pad(d.getDate())}/${pad(d.getMonth() + 1)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  document.getElementById("bc-send-title").textContent = fromList ? `📣 Enviar para a lista "${opts.listName}"` : "📣 Enviar mensagem aos selecionados";
  document.getElementById("bc-name").value = fromList ? `${opts.listName} — ${stamp}` : `Transmissão ${stamp}`;
  ["bc-message", "bc-schedule"].forEach(id => document.getElementById(id).value = "");
  document.getElementById("bc-media-type").value = "";
  document.getElementById("bc-media-file").value = "";
  document.getElementById("bc-media-filename").textContent = "";
  document.getElementById("bc-delay").value = 30;
  document.getElementById("bc-maxday").value = 0;
  document.getElementById("bc-hourly").checked = false;
  document.getElementById("bc-business").checked = false;

  const sem = resolved.sem_telefone || [], rep = resolved.telefone_repetido || [];
  let html = `👥 <strong>${resolved.total}</strong> usuário(s) — <strong style="color:var(--success,#22c55e)">${resolved.com_telefone}</strong> vão receber (com WhatsApp vinculado).`;
  if (sem.length) html += `<br>⚠️ <strong>${sem.length}</strong> sem telefone (não recebem): <span class="text-mono text-muted">${_bcEsc(sem.slice(0, 15).join(", "))}${sem.length > 15 ? "…" : ""}</span>`;
  if (rep.length) html += `<br>ℹ️ ${rep.length} usuário(s) dividem telefone com outro — a mensagem vai uma vez só por número.`;
  document.getElementById("bc-send-resumo").innerHTML = html;

  const saveWrap = document.getElementById("bc-save-wrap");
  saveWrap.style.display = fromList ? "none" : "";
  if (!fromList) {
    const lists = (await api("/broadcast-lists")) || [];
    _bcFillListSelect(document.getElementById("bc-list-existing"), lists, "Nenhuma lista criada ainda");
    document.querySelector('input[name="bc-save"][value="new"]').checked = true;
    document.getElementById("bc-list-name").value = "";
    _bcSaveModeChanged();
  }
  openModal("modal-bc-send");
}

async function _bcSubmit(mode) {
  if (!_bcCtx || _bcCtx.busy) return;
  const name = document.getElementById("bc-name").value.trim();
  const message = document.getElementById("bc-message").value.trim();
  const mediaType = document.getElementById("bc-media-type").value;
  const mediaFile = document.getElementById("bc-media-file").files[0];
  if (!name) { toast("Dê um nome pra transmissão", true); return; }
  if (!message && !mediaFile) { toast("Escreva a mensagem ou anexe uma mídia", true); return; }
  if (mediaFile && !mediaType) { toast("Escolha o tipo do anexo (imagem, vídeo ou arquivo)", true); return; }

  let scheduledAt = "";
  if (mode === "agendar") {
    scheduledAt = document.getElementById("bc-schedule").value;
    if (!scheduledAt) { toast("Escolha a data/hora do agendamento", true); return; }
  }

  const payload = {
    name, message, has_media: Boolean(mediaFile),
    delay_seconds: parseInt(document.getElementById("bc-delay").value) || 30,
    max_per_day: parseInt(document.getElementById("bc-maxday").value) || 0,
    hourly_interval: document.getElementById("bc-hourly").checked,
    business_window: document.getElementById("bc-business").checked,
    scheduled_at: scheduledAt || null,
  };
  if (_bcCtx.fromList) {
    payload.list_id = _bcCtx.opts.listId;
  } else {
    payload.logins = _bcCtx.opts.logins;
    const save = document.querySelector('input[name="bc-save"]:checked').value;
    if (save === "new") {
      const ln = document.getElementById("bc-list-name").value.trim();
      if (!ln) { toast("Dê um nome pra lista (ou escolha \"Não salvar lista\")", true); return; }
      payload.save_list = { mode: "new", name: ln };
    } else if (save === "existing") {
      const lid = document.getElementById("bc-list-existing").value;
      if (!lid) { toast("Nenhuma lista existente — crie uma nova", true); return; }
      payload.save_list = { mode: "existing", list_id: lid };
    }
  }

  _bcCtx.busy = true;
  ["bc-btn-draft", "bc-btn-schedule", "bc-btn-now"].forEach(id => document.getElementById(id).disabled = true);
  try {
    const created = await api("/whatsapp/campaigns/from-users", "POST", payload);
    if (!created) return;

    if (mediaFile) {
      const fd = new FormData();
      fd.append("mediaType", mediaType);
      fd.append("file", mediaFile);
      try {
        const r = await fetch(`/api/whatsapp/campaigns/${created.id}/media`, { method: "POST", headers: { "X-Token": getToken() }, body: fd });
        if (!r.ok) { const e = await r.json().catch(() => ({})); toast(`Transmissão criada, mas o anexo falhou: ${e.error || ""}`, true); }
      } catch (e) { toast("Transmissão criada, mas o anexo falhou ao enviar", true); }
    }

    const n = created.targets.length;
    const listaTxt = created.lista ? ` Lista "${created.lista.name}" salva.` : "";
    if (mode === "agora") {
      const s = await api(`/whatsapp/campaigns/${created.id}/start`, "POST");
      if (s) toast(`Transmissão iniciada! ${n} contato(s) vão receber, aos poucos.${listaTxt}`);
    } else if (mode === "agendar") {
      toast(`Transmissão agendada pra ${new Date(scheduledAt).toLocaleString("pt-BR")} — ${n} contato(s).${listaTxt}`);
    } else {
      toast(`Salva como rascunho em Campanhas — ${n} contato(s).${listaTxt}`);
    }
    closeModal("modal-bc-send");
    const cb = _bcCtx.opts.onDone;
    if (typeof cb === "function") cb(created);
  } finally {
    if (_bcCtx) _bcCtx.busy = false;
    ["bc-btn-draft", "bc-btn-schedule", "bc-btn-now"].forEach(id => { const el = document.getElementById(id); if (el) el.disabled = false; });
  }
}

// ── Adicionar usuários a uma lista (existente ou nova) ──────────────
let _bcAddCtx = null;
async function openAddToListModal(logins, onDone) {
  _bcEnsureModals();
  const lists = (await api("/broadcast-lists")) || [];
  _bcAddCtx = { logins, onDone };
  _bcFillListSelect(document.getElementById("bc-add-existing"), lists, "Nenhuma lista criada ainda");
  document.getElementById("bc-add-newname").value = "";
  document.getElementById("bc-add-resumo").innerHTML = `👥 <strong>${logins.length}</strong> usuário(s) selecionado(s).`;
  openModal("modal-bc-addlist");
}

async function _bcAddSubmit() {
  if (!_bcAddCtx) return;
  const newName = document.getElementById("bc-add-newname").value.trim();
  const existing = document.getElementById("bc-add-existing").value;
  let r;
  if (newName) {
    r = await api("/broadcast-lists", "POST", { name: newName, logins: _bcAddCtx.logins });
    if (r) toast(`Lista "${r.name}" criada com ${r.count} usuário(s).`);
  } else if (existing) {
    r = await api(`/broadcast-lists/${existing}/members`, "POST", { logins: _bcAddCtx.logins });
    if (r) toast(`${r.adicionados} adicionado(s)` + (r.ja_estavam ? `, ${r.ja_estavam} já estavam na lista` : "") + `. Total: ${r.total}.`);
  } else {
    toast("Escolha uma lista ou digite o nome de uma nova", true);
    return;
  }
  if (!r) return;
  closeModal("modal-bc-addlist");
  const cb = _bcAddCtx.onDone;
  if (typeof cb === "function") cb(r);
}
