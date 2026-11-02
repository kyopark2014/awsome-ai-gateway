(function () {
  "use strict";

  const cfg = window.PORTAL_CONFIG || {};
  const ADMIN = String(cfg.adminApiUrl || "").replace(/\/$/, "");
  const GATEWAY = String(cfg.gatewayUrl || "").replace(/\/$/, "");
  const TOKEN_KEY = "portalGoogleIdToken";

  const $ = (id) => document.getElementById(id);
  const show = (el, on) => { el.hidden = !on; };

  // 보안: 서버/사용자 데이터는 전부 textContent 로만 넣는다(innerHTML 사용 금지).
  function setText(id, v) { $(id).textContent = v == null || v === "" ? "-" : String(v); }

  // ── ID token 보관: sessionStorage(탭 단위). 만료되면 버린다. ──
  function readToken() {
    try { return sessionStorage.getItem(TOKEN_KEY) || ""; } catch (e) { return ""; }
  }
  function saveToken(t) { try { sessionStorage.setItem(TOKEN_KEY, t); } catch (e) { /* 무시 */ } }
  function clearToken() { try { sessionStorage.removeItem(TOKEN_KEY); } catch (e) { /* 무시 */ } }

  function decodeJwt(t) {
    try {
      const p = t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      return JSON.parse(decodeURIComponent(escape(atob(p))));
    } catch (e) { return null; }
  }
  function tokenValid(t) {
    const c = t && decodeJwt(t);
    return !!(c && c.exp && c.exp * 1000 > Date.now() + 30000);
  }

  // ── API ──
  class ApiError extends Error {
    constructor(status, type, message) { super(message); this.status = status; this.type = type; }
  }
  async function api(path, opts) {
    const token = readToken();
    if (!tokenValid(token)) { onSignedOut("세션이 만료되었습니다. 다시 로그인하세요."); throw new ApiError(401, "expired", "expired"); }
    let res;
    try {
      res = await fetch(ADMIN + path, Object.assign({ headers: { Authorization: "Bearer " + token } }, opts));
    } catch (e) {
      throw new ApiError(0, "network", "서버에 연결할 수 없습니다.");
    }
    let body = null;
    try { body = await res.json(); } catch (e) { /* 본문 없음 */ }
    if (!res.ok) {
      const err = (body && (body.error || (body.detail && body.detail.error))) || {};
      const msg = err.message || (typeof (body && body.detail) === "string" ? body.detail : "") || "요청에 실패했습니다 (" + res.status + ")";
      if (res.status === 401) onSignedOut("로그인이 유효하지 않습니다. 다시 로그인하세요.");
      throw new ApiError(res.status, err.type || "", msg);
    }
    return body;
  }

  // ── 포맷 ──
  const nf = new Intl.NumberFormat("ko-KR");
  const usd = (n) => "$" + Number(n || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 });
  function fmtTime(iso) {
    if (!iso) return "-";
    const d = new Date(iso);
    return isNaN(d) ? "-" : d.toLocaleString("ko-KR", { timeZone: "Asia/Seoul", hour12: false }) + " (KST)";
  }
  function remaining(iso) {
    if (!iso) return "-";
    const ms = new Date(iso) - Date.now();
    if (isNaN(ms)) return "-";
    if (ms <= 0) return "만료됨";
    const m = Math.floor(ms / 60000), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60);
    return d > 0 ? d + "일 " + h + "시간" : h + "시간 " + (m % 60) + "분";
  }

  // ── 화면 ──
  function showError(msg) {
    const el = $("app-error");
    el.textContent = msg || "";
    show(el, !!msg);
  }
  function onSignedOut(msg) {
    clearToken();
    show($("view-app"), false);
    show($("who"), false);
    show($("view-login"), true);
    const el = $("login-error");
    el.textContent = msg || "";
    show(el, !!msg);
    renderGoogleButton();
  }

  function fillRows(tbodyId, rows, cols) {
    const tb = $(tbodyId).querySelector("tbody");
    tb.replaceChildren();
    if (!rows.length) {
      const tr = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = cols.length; td.className = "empty"; td.textContent = "데이터가 없습니다.";
      tr.appendChild(td); tb.appendChild(tr); return;
    }
    rows.forEach((r) => {
      const tr = document.createElement("tr");
      cols.forEach((c) => {
        const td = document.createElement("td");
        if (c.n) td.className = "n";
        td.textContent = c.f(r);
        tr.appendChild(td);
      });
      tb.appendChild(tr);
    });
  }

  async function loadProfile() {
    const me = await api("/portal/me");
    setText("p-name", me.display_name);
    setText("p-email", me.email);
    setText("p-team", me.team ? me.team.name : "미배정");
    setText("p-role", me.role);
    const k = me.key;
    setText("k-prefix", k ? k.key_prefix + "…" : "없음");
    setText("k-issued", k ? fmtTime(k.issued_at) : "-");
    setText("k-expires", k ? fmtTime(k.expires_at) : "-");
    setText("k-remaining", k ? remaining(k.expires_at) : "-");
    setText("who-email", me.email);
  }

  async function loadUsage(period) {
    const q = period ? "?period=" + encodeURIComponent(period) : "";
    const u = await api("/portal/usage" + q);
    const daily = u.daily_usage || [], models = u.by_model || [];
    const sum = (a, f) => a.reduce((s, x) => s + Number(f(x) || 0), 0);
    setText("s-cost", usd(sum(daily, (x) => x.cost_usd)));
    setText("s-req", nf.format(sum(daily, (x) => x.requests)));
    setText("s-tok", nf.format(sum(daily, (x) => x.tokens)));
    const cols = (nameF) => [
      { f: nameF }, { n: 1, f: (r) => usd(r.cost_usd) }, { n: 1, f: (r) => nf.format(r.requests) }, { n: 1, f: (r) => nf.format(r.tokens) },
    ];
    fillRows("t-daily", daily, cols((r) => r.date));
    fillRows("t-model", models, cols((r) => r.model_alias));
  }

  async function loadBudget() {
    const b = await api("/portal/budget");
    const bu = b.budget || {}, team = b.team || {};
    const bar = $("b-bar");
    bar.classList.remove("warn", "over");
    if (!bu.configured) {
      $("b-fill").style.width = "0%";
      setText("b-text", "개인 예산이 설정되지 않았습니다. 이번 달 사용액 " + usd(bu.used_usd) + (team.assigned ? " · 팀 예산이 적용됩니다." : ""));
    } else {
      const pct = Math.max(0, Math.min(100, Number(bu.usage_pct || 0)));
      $("b-fill").style.width = pct + "%";
      bar.setAttribute("aria-valuenow", String(Math.round(pct)));
      if (pct >= 100) bar.classList.add("over"); else if (pct >= 80) bar.classList.add("warn");
      setText("b-text", "한도 " + usd(bu.limit_usd) + " · 사용 " + usd(bu.used_usd) + " (" + pct.toFixed(1) + "%) · 잔여 " + usd(bu.remaining_usd) + " · 정책 " + bu.policy);
    }
    let t;
    if (!team.assigned) t = "소속 팀이 없습니다.";
    else if (!team.budget_configured) t = "팀 예산이 설정되지 않았습니다.";
    else if (team.budget_exhausted) t = "팀 예산이 소진되어 요청이 차단될 수 있습니다.";
    else t = "팀 예산이 설정되어 있고 여유가 있습니다.";
    setText("t-text", t);
  }

  function fillPeriods() {
    const sel = $("period");
    sel.replaceChildren();
    const now = new Date(new Date().toLocaleString("en-US", { timeZone: "Asia/Seoul" }));
    for (let i = 0; i < 6; i++) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const v = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0");
      const o = document.createElement("option");
      o.value = v; o.textContent = v;
      sel.appendChild(o);
    }
  }

  async function loadAll() {
    showError("");
    show($("view-login"), false);
    show($("view-app"), true);
    show($("who"), true);
    try {
      await loadProfile();
    } catch (e) {
      if (e.type === "expired" || e.status === 401) return;
      if (e.status === 403) { onSignedOut(e.message); return; }
      showError(e.message); return;
    }
    // 나머지는 독립적으로 — 한 카드가 실패해도 다른 카드는 보인다.
    const results = await Promise.allSettled([loadUsage($("period").value), loadBudget()]);
    const failed = results.find((r) => r.status === "rejected" && r.reason && r.reason.type !== "expired");
    if (failed) showError(failed.reason.message);
  }

  // ── Google 로그인 ──
  let gisInit = false;
  function renderGoogleButton() {
    if (!cfg.googleClientId) { const e = $("login-error"); e.textContent = "Google 클라이언트가 설정되지 않았습니다."; show(e, true); return; }
    if (!(window.google && google.accounts && google.accounts.id)) { setTimeout(renderGoogleButton, 200); return; }
    if (!gisInit) {
      google.accounts.id.initialize({
        client_id: cfg.googleClientId,
        callback: (resp) => {
          if (!resp || !resp.credential) return;
          saveToken(resp.credential);
          loadAll();
        },
        auto_select: false,
        cancel_on_tap_outside: true,
      });
      gisInit = true;
    }
    const holder = $("g-btn");
    holder.replaceChildren();
    google.accounts.id.renderButton(holder, { theme: "outline", size: "large", text: "signin_with", locale: "ko", width: 260 });
  }

  // ── 이벤트 ──
  $("logout-btn").addEventListener("click", () => {
    if (window.google && google.accounts && google.accounts.id) google.accounts.id.disableAutoSelect();
    $("new-key-val").value = ""; $("try-key").value = "";
    onSignedOut("");
  });
  $("period").addEventListener("change", () => {
    loadUsage($("period").value).catch((e) => { if (e.type !== "expired") showError(e.message); });
  });

  $("issue-btn").addEventListener("click", async () => {
    if (!confirm("새 키를 발급하면 기존 키가 즉시 만료됩니다. 계속할까요?")) return;
    const btn = $("issue-btn");
    btn.disabled = true; showError("");
    try {
      const r = await api("/portal/key", { method: "POST" });
      $("new-key-val").value = r.virtual_key;
      $("try-key").value = r.virtual_key;
      setText("new-key-exp", "만료: " + fmtTime(r.expires_at) + " · 이 값은 다시 볼 수 없습니다.");
      show($("new-key"), true);
      await loadProfile();
    } catch (e) {
      if (e.type !== "expired") showError(e.message);
    } finally { btn.disabled = false; }
  });
  $("copy-btn").addEventListener("click", async () => {
    const v = $("new-key-val").value;
    try { await navigator.clipboard.writeText(v); $("copy-btn").textContent = "복사됨"; }
    catch (e) { $("new-key-val").select(); document.execCommand && document.execCommand("copy"); $("copy-btn").textContent = "복사됨"; }
    setTimeout(() => { $("copy-btn").textContent = "복사"; }, 1500);
  });

  // ── Gateway 시험 ──
  function gwHeaders() {
    const k = $("try-key").value.trim();
    if (!k) throw new Error("API Key를 입력하세요.");
    return { Authorization: "Bearer " + k, "Content-Type": "application/json" };
  }
  function out(text) { $("try-out").textContent = text; }

  $("models-btn").addEventListener("click", async () => {
    out("조회 중…");
    try {
      const res = await fetch(GATEWAY + "/v1/models", { headers: gwHeaders() });
      const j = await res.json().catch(() => ({}));
      if (!res.ok) { out("HTTP " + res.status + "\n" + JSON.stringify(j, null, 2)); return; }
      const sel = $("try-model");
      sel.replaceChildren();
      (j.data || []).forEach((m) => {
        const o = document.createElement("option");
        o.value = m.id; o.textContent = m.id + (m.provider ? "  (" + m.provider + ")" : "");
        sel.appendChild(o);
      });
      out((j.data || []).length + "개 모델을 불러왔습니다. 이 키로 허용된 모델만 표시됩니다.");
    } catch (e) { out("오류: " + e.message); }
  });

  $("chat-btn").addEventListener("click", async () => {
    const model = $("try-model").value;
    if (!model) { out("먼저 '모델 목록 조회'로 모델을 선택하세요."); return; }
    const btn = $("chat-btn");
    btn.disabled = true; out("요청 중…");
    try {
      const res = await fetch(GATEWAY + "/v1/chat/completions", {
        method: "POST",
        headers: gwHeaders(),
        body: JSON.stringify({ model, max_tokens: 256, messages: [{ role: "user", content: $("try-prompt").value }] }),
      });
      const j = await res.json().catch(() => ({}));
      const text = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
      out("HTTP " + res.status + "\n\n" + (text || JSON.stringify(j, null, 2)));
    } catch (e) { out("오류: " + e.message); }
    finally { btn.disabled = false; }
  });

  // ── 시작 ──
  fillPeriods();
  const t = readToken();
  if (tokenValid(t)) loadAll(); else onSignedOut("");
})();
