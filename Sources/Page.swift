// The routing page served at "/". Plain HTML + JS, no external files (works without internet).

let pageHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AVB Routing</title>
<style>
  :root {
    --bg: #f6f6f4; --panel: #ffffff; --text: #1d1d1b; --muted: #6b6b66; --line: #e3e3de;
    --ok: #1f8a4c; --ok-bg: #e6f4ec; --bad: #c0362c; --bad-bg: #fbe9e7; --warn: #9a6400; --warn-bg: #fdf3dc;
    --accent: #2f5bd3; --lock: #7a4fd1; --lock-bg: #f0eafb;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #151514; --panel: #1f1f1d; --text: #ecece8; --muted: #9b9b94; --line: #33332f;
      --ok: #4cc382; --ok-bg: #173324; --bad: #ff7a6e; --bad-bg: #3a1c19; --warn: #f0b84a; --warn-bg: #352a12;
      --accent: #7c9cff; --lock: #b394ff; --lock-bg: #2a2140;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between;
           padding: 16px; border-bottom: 1px solid var(--line); background: var(--panel); position: sticky; top: 0; z-index: 2; }
  h1 { font-size: 18px; margin: 0; display: flex; align-items: center; gap: 10px; }
  main { max-width: 1100px; margin: 0 auto; padding: 16px; }
  .pill { font-size: 13px; font-weight: 600; padding: 3px 10px; border-radius: 999px; }
  .pill.ok { color: var(--ok); background: var(--ok-bg); }
  .pill.bad { color: var(--bad); background: var(--bad-bg); }
  .banner { padding: 12px 14px; border-radius: 8px; margin-bottom: 14px; font-weight: 500; }
  .banner.warn { background: var(--warn-bg); color: var(--warn); }
  .banner.bad { background: var(--bad-bg); color: var(--bad); }
  .admin { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  input[type=password] { padding: 7px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--text); width: 170px; }
  button { padding: 7px 12px; border-radius: 6px; border: 1px solid var(--line); background: var(--panel); color: var(--text); cursor: pointer; font: inherit; font-size: 14px; }
  button:hover { border-color: var(--accent); }
  button.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
  button.lock { color: var(--lock); }
  button:disabled { opacity: .5; cursor: default; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; margin-bottom: 16px; overflow: hidden; }
  .card h2 { font-size: 15px; margin: 0; padding: 12px 14px; border-bottom: 1px solid var(--line); display: flex; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
  .card h2 small { color: var(--muted); font-weight: 400; }
  table { width: 100%; border-collapse: collapse; }
  td, th { padding: 8px 14px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: middle; }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); font-weight: 600; }
  tr:last-child td { border-bottom: 0; }
  tr.locked td { background: var(--lock-bg); }
  select { width: 100%; max-width: 360px; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg); color: var(--text); font: inherit; font-size: 14px; }
  .st { font-size: 13px; }
  .st.ok { color: var(--ok); } .st.bad { color: var(--bad); font-weight: 600; } .st.muted { color: var(--muted); }
  .lk { color: var(--lock); font-weight: 600; font-size: 13px; white-space: nowrap; }
  .events { max-height: 360px; overflow: auto; }
  .ev { display: flex; gap: 10px; padding: 6px 14px; border-bottom: 1px solid var(--line); font-size: 13px; }
  .ev time { color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }
  .ev.revert span, .ev.problem span { color: var(--bad); font-weight: 600; }
  .ev.lock span { color: var(--lock); } .ev.ok span { color: var(--ok); }
  #toast { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); background: var(--text); color: var(--bg);
           padding: 10px 16px; border-radius: 8px; font-size: 14px; opacity: 0; transition: opacity .2s; pointer-events: none; max-width: calc(100% - 32px); }
  #toast.show { opacity: 1; }
  .muted { color: var(--muted); }
  @media (max-width: 640px) {
    td, th { padding: 8px 10px; }
    th.hide-sm, td.hide-sm { display: none; }
    input[type=password] { width: 130px; }
  }
</style>
</head>
<body>
<header>
  <h1>AVB Routing <span id="health" class="pill">…</span></h1>
  <div class="admin" id="admin"></div>
</header>
<main>
  <div id="banners"></div>
  <div id="devices"><p class="muted">Loading…</p></div>
  <div class="card">
    <h2>Activity <small>connections made anywhere on the network, and what the manager did</small></h2>
    <div class="events" id="events"></div>
  </div>
</main>
<div id="toast"></div>
<script>
let pw = ""; try { pw = sessionStorage.getItem("avbpw") || ""; } catch (e) {}
let isAdmin = false, state = null, busy = false;

const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
function toast(msg) { const t = $("#toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 3500); }

async function api(path, body) {
  const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-Admin-Password": isAdmin || body?._login ? pw : "" }, body: JSON.stringify(body || {}) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

async function login() {
  pw = $("#pw").value;
  try { await api("/api/login", { _login: true }); isAdmin = true; try { sessionStorage.setItem("avbpw", pw); } catch (e) {} toast("Signed in as admin"); }
  catch (e) { isAdmin = false; toast(e.message); }
  render();
}
function logout() { isAdmin = false; pw = ""; try { sessionStorage.removeItem("avbpw"); } catch (e) {} render(); }

async function act(fn, ...args) {
  if (busy) return; busy = true; document.body.style.cursor = "progress";
  try { const j = await fn(...args); if (j?.message) toast(j.message); } catch (e) { toast(e.message); }
  busy = false; document.body.style.cursor = ""; await load();
}

const patch = (listener, luid, value) => {
  const [talker, tuid] = value ? value.split("|") : [null, null];
  return api("/api/patch", { listener, luid, talker, tuid: tuid == null ? null : Number(tuid) });
};
const lock = (listener, luid) => api("/api/lock", { listener, luid });
const unlock = (listener, luid) => api("/api/unlock", { listener, luid });
const rename = (id, cur) => { const n = prompt("Name for this device (leave empty to reset):", cur); return n === null ? null : api("/api/rename", { id, name: n }); };
const lockAll = () => confirm("Lock every route that is connected right now?") ? api("/api/lockall") : null;

function srcLabel(id, uid) {
  const d = state.devices.find(d => d.id === id);
  if (!d) return `device …${id.slice(-6)} / out ${uid + 1}`;
  const s = d.sources.find(s => s.uid === uid);
  return `${d.name} / ${s ? s.name : "out " + (uid + 1)}`;
}

function render() {
  if (!state) return;
  // header
  const lockedSinks = state.devices.flatMap(d => d.sinks.filter(s => s.locked));
  const bad = lockedSinks.filter(s => !s.ok).length;
  const h = $("#health");
  if (!state.link) { h.className = "pill bad"; h.textContent = "No AVB link"; }
  else if (bad) { h.className = "pill bad"; h.textContent = `${bad} locked route${bad > 1 ? "s" : ""} failing`; }
  else { h.className = "pill ok"; h.textContent = lockedSinks.length ? `All ${lockedSinks.length} locked routes OK` : "Connected"; }

  $("#admin").innerHTML = isAdmin
    ? `<span class="lk">Admin</span><button class="lock" onclick="act(lockAll)">Lock all current routes</button><button onclick="logout()">Sign out</button>`
    : state.adminConfigured
      ? `<input type="password" id="pw" placeholder="Admin password" onkeydown="if(event.key==='Enter')login()"><button class="primary" onclick="login()">Sign in</button>`
      : `<span class="muted">No admin password set. On the iMac run <code>avbwatch passwd</code></span>`;

  let banners = "";
  if (!state.link) banners += `<div class="banner bad">The AVB Ethernet link on the manager iMac is down. Check the cable and the MOTU switch.</div>`;
  if (state.engineWarning) banners += `<div class="banner warn">${esc(state.engineWarning)}</div>`;
  if (!state.sniffing) banners += `<div class="banner warn">Change tracking is off (no packet access), so the activity list can't show who changed a route. Locks are still enforced.</div>`;
  $("#banners").innerHTML = banners;

  // don't redraw the routing tables while someone is choosing in a dropdown
  if (document.activeElement && document.activeElement.tagName === "SELECT") { renderEvents(); return; }

  const talkers = state.devices.filter(d => d.sources.length);
  $("#devices").innerHTML = state.devices.filter(d => d.sinks.length).map(d => {
    const rows = d.sinks.map(s => {
      const cur = s.talker ? `${s.talker}|${s.talkerUID}` : "";
      const canChange = !s.locked || isAdmin;
      const opts = [`<option value="">— nothing —</option>`].concat(
        talkers.filter(t => t.id !== d.id).map(t =>
          `<optgroup label="${esc(t.name)}">` + t.sources.map(o =>
            `<option value="${t.id}|${o.uid}" ${cur === `${t.id}|${o.uid}` ? "selected" : ""}>${esc(o.name)}</option>`).join("") + `</optgroup>`)
      );
      if (cur && !talkers.some(t => t.id === s.talker)) opts.push(`<option value="${cur}" selected>${esc(srcLabel(s.talker, s.talkerUID))}</option>`);
      const status = s.locked
        ? `<span class="st ${s.ok ? "ok" : "bad"}">${s.ok ? "Locked · OK" : esc(s.state)}</span>`
        : `<span class="st muted">${s.talker ? "connected" : "—"}</span>`;
      const lockCell = s.locked
        ? (isAdmin ? `<button class="lock" onclick="act(unlock,'${d.id}',${s.uid})">Unlock</button>` : `<span class="lk">🔒 Locked</span>`)
        : (isAdmin ? `<button class="lock" ${s.talker ? "" : "disabled"} onclick="act(lock,'${d.id}',${s.uid})">Lock</button>` : "");
      const lockedTo = s.locked && (s.lockTalker !== s.talker || s.lockTalkerUID !== s.talkerUID)
        ? `<div class="st muted">locked to ${esc(srcLabel(s.lockTalker, s.lockTalkerUID))}</div>` : "";
      return `<tr class="${s.locked ? "locked" : ""}">
        <td>${esc(s.name)}</td>
        <td><select ${canChange ? "" : "disabled"} onchange="act(patch,'${d.id}',${s.uid},this.value)">${opts.join("")}</select>${lockedTo}</td>
        <td class="hide-sm">${status}</td>
        <td>${lockCell}</td></tr>`;
    }).join("");
    const ren = isAdmin ? ` <button onclick="act(rename,'${d.id}',${esc(JSON.stringify(d.name))})">Rename</button>` : "";
    return `<div class="card"><h2><span>${esc(d.name)} <small>inputs · ${esc(d.mac)}</small></span>${ren}</h2>
      <table><thead><tr><th>Input</th><th>Receives from</th><th class="hide-sm">Status</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }).join("") || `<p class="muted">No AVB devices found.</p>`;
  renderEvents();
}

function renderEvents() {
  $("#events").innerHTML = (state.events || []).slice(0, 100).map(e =>
    `<div class="ev ${esc(e.kind)}"><time>${esc(e.time.slice(5))}</time><span>${esc(e.text)}</span></div>`).join("") || `<div class="ev"><span class="muted">Nothing yet.</span></div>`;
}

async function load() {
  try { const r = await fetch("/api/state"); if (r.ok) { state = await r.json(); render(); } } catch (e) {}
}

(async () => {
  if (pw) { try { await api("/api/login", { _login: true }); isAdmin = true; } catch (e) { pw = ""; } }
  await load();
  setInterval(() => { if (!busy) load(); }, 2000);
})();
</script>
</body>
</html>
"""#
