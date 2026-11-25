'use strict';

// =====================================================================
// Helpers
// =====================================================================

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const clone = (o) => JSON.parse(JSON.stringify(o));

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Prov': '1' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let data = {};
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

function toast(msg, bad = false) {
  const el = document.createElement('div');
  el.textContent = msg;
  if (bad) el.className = 'bad';
  $('#toast').appendChild(el);
  setTimeout(() => el.remove(), bad ? 7000 : 3500);
}

function getPath(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}
function setPath(obj, path, value) {
  const keys = path.split('.');
  let o = obj;
  for (let i = 0; i < keys.length - 1; i++) {
    if (o[keys[i]] == null) o[keys[i]] = /^\d+$/.test(keys[i + 1]) ? [] : {};
    o = o[keys[i]];
  }
  o[keys[keys.length - 1]] = value;
}
function debounce(fn, ms) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}
function formatName(pattern, n) {
  const m = /#+/.exec(pattern || '');
  if (!m) return (pattern || '').toUpperCase();
  return pattern.replace(m[0], String(n).padStart(m[0].length, '0')).toUpperCase();
}
function when(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString();
}

// =====================================================================
// State
// =====================================================================

const state = {
  meta: null,
  system: null,
  clients: [],
  editor: null,      // { name, client, secrets, customScript, batches, validation, dirty }
  wingetStatus: {},  // id -> { found, name }
  build: { client: '', batch: '', media: 'provision', stockIso: '', report: false, reportIp: '', jobId: null, job: null },
  timers: [],
};

function clearTimers() {
  state.timers.forEach((t) => clearInterval(t));
  state.timers = [];
}

// =====================================================================
// Router
// =====================================================================

let lastHash = location.hash;
let ignoreHash = false;

window.addEventListener('hashchange', () => {
  if (ignoreHash) { ignoreHash = false; return; }
  const leavingEditor = state.editor && state.editor.dirty && !location.hash.startsWith(`#/client/${state.editor.name}`);
  if (leavingEditor && !confirm('You have unsaved changes. Leave without saving?')) {
    ignoreHash = true;
    location.hash = lastHash;
    return;
  }
  if (leavingEditor) state.editor.dirty = false;
  lastHash = location.hash;
  route();
});
window.addEventListener('beforeunload', (e) => {
  if (state.editor && state.editor.dirty) { e.preventDefault(); e.returnValue = ''; }
});

async function route() {
  clearTimers();
  const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean);
  const page = parts[0] || 'clients';
  $$('.topbar nav a').forEach((a) => a.classList.toggle('active', a.dataset.nav === (page === 'client' ? 'clients' : page)));
  try {
    if (page === 'clients') await renderClients();
    else if (page === 'client') await renderClient(parts[1], parts[2] || 'settings');
    else if (page === 'build') await renderBuild();
    else if (page === 'system') await renderSystem();
    else location.hash = '#/clients';
  } catch (err) {
    $('#app').innerHTML = `<div class="panel"><h2>Something went wrong</h2><p class="muted">${esc(err.message)}</p></div>`;
  }
}

// =====================================================================
// Clients list
// =====================================================================

async function renderClients() {
  const { clients } = await api('GET', '/api/clients');
  state.clients = clients;
  const rows = clients.map((c) => {
    let status = '<span class="badge ok">Ready</span>';
    if (c.legacy) status = '<span class="badge bad">Old format - convert</span>';
    else if (c.errors) status = `<span class="badge bad">${c.errors} to fix</span>`;
    else if (c.warnings) status = `<span class="badge warn">${c.warnings} warning${c.warnings > 1 ? 's' : ''}</span>`;
    return `<tr class="clickable" data-go="#/client/${esc(c.name)}">
      <td><b>${esc(c.organization || c.name)}</b><div class="muted mono">${esc(c.name)}</div></td>
      <td class="mono">${esc(c.pattern)}</td>
      <td>${c.apps}</td>
      <td>${c.batches}</td>
      <td>${status}</td></tr>`;
  }).join('');

  $('#app').innerHTML = `
    <div class="page-head">
      <div><h1>Clients</h1><div class="muted">Each client has its settings, apps, passwords and batches of PCs.</div></div>
      <button class="primary" id="new-client">New client</button>
    </div>
    <div class="panel" style="padding:0">
      ${clients.length ? `<table><thead><tr><th>Client</th><th>Computer names</th><th>Apps</th><th>Batches</th><th>Status</th></tr></thead><tbody>${rows}</tbody></table>`
        : '<p class="pad muted">No clients yet. Click <b>New client</b>.</p>'}
    </div>
    <dialog id="new-dialog">
      <form method="dialog" id="new-form">
        <h2>New client</h2>
        <label class="field">Short name (folder)
          <input type="text" name="name" required pattern="[a-z0-9][a-z0-9-]{0,39}" placeholder="acme">
          <span class="hint">Lowercase letters, numbers, hyphens. Used for folders and file names.</span>
        </label>
        <label class="field" style="margin-top:12px">Start from
          <select name="from">
            <option value="">Template (clients/_example)</option>
            ${clients.filter((c) => !c.legacy).map((c) => `<option value="${esc(c.name)}">Copy of ${esc(c.organization || c.name)} (settings only, no passwords)</option>`).join('')}
          </select>
        </label>
        <div class="row" style="margin-top:18px"><span class="spacer"></span>
          <button type="button" id="new-cancel">Cancel</button><button class="primary" value="ok">Create</button></div>
      </form>
    </dialog>`;

  $$('tr[data-go]').forEach((tr) => tr.addEventListener('click', () => { location.hash = tr.dataset.go; }));
  const dlg = $('#new-dialog');
  $('#new-client').onclick = () => dlg.showModal();
  $('#new-cancel').onclick = () => dlg.close();
  $('#new-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      const r = await api('POST', '/api/clients', { name: f.get('name').trim(), from: f.get('from') });
      dlg.close();
      toast(`Client ${r.name} created`);
      location.hash = `#/client/${r.name}`;
    } catch (err) { toast(err.message, true); }
  };
}

// =====================================================================
// Client editor
// =====================================================================

async function loadEditor(name) {
  if (state.editor && state.editor.name === name) return state.editor;
  const d = await api('GET', `/api/clients/${encodeURIComponent(name)}`);
  state.editor = { name, client: d.client, secrets: d.secrets, customScript: d.customScript || '', batches: d.batches.batches || [], validation: d.validation, dirty: false };
  state.wingetStatus = {};
  return state.editor;
}

async function renderClient(name, tab) {
  if (state.editor && state.editor.name !== name) state.editor = null;
  const ed = await loadEditor(name);
  const c = ed.client;
  $('#app').innerHTML = `
    <div class="page-head">
      <div><a href="#/clients" class="muted">← Clients</a><h1>${esc(c.organization || name)}</h1><div class="muted mono">clients/${esc(name)}</div></div>
      <div class="row">
        <a class="btn" href="#/client/${esc(name)}" ${tab === 'settings' ? 'style="border-color:var(--accent)"' : ''}>Settings</a>
        <a class="btn" href="#/client/${esc(name)}/batches" ${tab === 'batches' ? 'style="border-color:var(--accent)"' : ''}>Batches (${ed.batches.length})</a>
        <button class="primary" id="go-build">Build media…</button>
      </div>
    </div>
    <div id="tab"></div>`;
  $('#go-build').onclick = () => { state.build.client = name; state.build.batch = ''; location.hash = '#/build'; };
  if (tab === 'batches') renderBatches();
  else renderSettings();
}

// ---------- form building blocks ----------

function vKey(path) { return path.startsWith('client.') ? path.slice(7) : path; }

function field({ label, path, type = 'text', hint = '', options = null, placeholder = '', list = '', v = null, cls = '' }) {
  const ed = state.editor;
  const value = getPath(ed, path) ?? '';
  const key = v || vKey(path);
  let input;
  if (options) {
    input = `<select data-path="${esc(path)}">${options.map((o) => {
      const [val, text] = Array.isArray(o) ? o : [o, o];
      return `<option value="${esc(val)}" ${String(val) === String(value) ? 'selected' : ''}>${esc(text)}</option>`;
    }).join('')}</select>`;
  } else if (type === 'password') {
    input = `<div class="pw"><input type="password" data-path="${esc(path)}" value="${esc(value)}" autocomplete="new-password" placeholder="${esc(placeholder)}">
      <button type="button" class="small" data-reveal>Show</button></div>`;
  } else {
    input = `<input type="${type}" data-path="${esc(path)}" value="${esc(value)}" placeholder="${esc(placeholder)}" ${list ? `list="${list}"` : ''} spellcheck="false">`;
  }
  return `<label class="field ${cls}" data-field="${esc(key)}">${esc(label)}${input}
    ${hint ? `<span class="hint">${hint}</span>` : ''}<span class="field-msg" data-msg="${esc(key)}"></span></label>`;
}

function toggle(path, title, desc) {
  const checked = !!getPath(state.editor, path);
  return `<label class="toggle"><input type="checkbox" data-path="${esc(path)}" ${checked ? 'checked' : ''}>
    <span><b>${esc(title)}</b><small>${esc(desc || '')}</small></span></label>`;
}

// ---------- settings tab ----------

function renderSettings() {
  const ed = state.editor;
  const c = ed.client;
  const meta = state.meta;
  const sections = [
    ['company', 'Company'], ['accounts', 'Accounts'], ['network', 'Network'], ['remote', 'Remote management'],
    ['apps', 'Apps'], ['features', 'Security & features'], ['custom', 'Custom script'], ['notes', 'Notes'],
  ];
  const tzList = `<datalist id="tz-list">${meta.timezones.map((t) => `<option value="${esc(t)}">`).join('')}</datalist>`;
  const locList = `<datalist id="loc-list">${meta.locales.map((t) => `<option value="${esc(t)}">`).join('')}</datalist>`;

  $('#tab').innerHTML = `
    ${tzList}${locList}
    <div class="layout">
      <nav class="sidenav">${sections.map(([id, t]) => `<a href="javascript:void 0" data-jump="${id}">${t}<span data-count="${id}"></span></a>`).join('')}</nav>
      <div>
        <section class="panel" id="sec-company"><h2>Company</h2>
          <div class="grid">
            ${field({ label: 'Organization', path: 'client.organization' })}
            ${field({ label: 'Computer name pattern', path: 'client.computerNamePattern', hint: '<span id="pattern-preview"></span>', placeholder: 'ACME-PC-##' })}
            ${field({ label: 'Timezone', path: 'client.timezone', list: 'tz-list', hint: 'Windows timezone ID' })}
            ${field({ label: 'Windows edition', path: 'client.windowsEdition', options: meta.windowsEditions, hint: 'Clean install only' })}
          </div>
          <h3>Language &amp; keyboard</h3>
          <div class="grid">
            ${field({ label: 'Windows language', path: 'client.locale.ui', list: 'loc-list', hint: 'Must be installed in the image (usually en-US)' })}
            ${field({ label: 'Keyboard', path: 'client.locale.input', list: 'loc-list', hint: 'e.g. en-US, fr-FR, or 040c:0000040c' })}
            ${field({ label: 'System locale', path: 'client.locale.system', list: 'loc-list' })}
            ${field({ label: 'Formats (dates, numbers)', path: 'client.locale.user', list: 'loc-list' })}
          </div>
        </section>

        <section class="panel" id="sec-accounts"><h2>Accounts</h2>
          <h3>IT admin (always created, stays visible on the sign-in screen)</h3>
          <div class="grid">
            ${field({ label: 'Username', path: 'client.itAdmin.username' })}
            ${field({ label: 'Display name', path: 'client.itAdmin.displayName' })}
            ${field({ label: 'Password', path: 'secrets.itAdminPassword', type: 'password' })}
          </div>
          <h3>End user</h3>
          ${toggle('client.endUser.create', 'Create an end-user account', 'Standard local account for the employee')}
          <div class="grid" id="enduser-fields">
            ${field({ label: 'Username', path: 'client.endUser.username' })}
            ${field({ label: 'Full name', path: 'client.endUser.fullName' })}
            ${field({ label: 'Default password', path: 'secrets.endUserPassword', type: 'password' })}
          </div>
          ${toggle('client.endUser.mustChangePassword', 'Must change password at first sign-in', 'Recommended: the default password is shared across the batch')}
          ${toggle('client.endUser.isAdmin', 'Make the end user an administrator', 'Not recommended')}
        </section>

        <section class="panel" id="sec-network"><h2>Network</h2>
          <div class="grid">
            ${field({ label: 'WiFi name (SSID)', path: 'client.wifi.ssid', hint: 'Leave empty if the PCs use Ethernet' })}
            ${field({ label: 'Security', path: 'client.wifi.security', options: [['WPA2PSK', 'WPA2-Personal'], ['WPA3SAE', 'WPA3-Personal'], ['open', 'Open (no password)']] })}
            ${field({ label: 'WiFi password', path: 'secrets.wifiPassword', type: 'password' })}
          </div>
          ${toggle('client.wifi.hidden', 'Hidden network', 'The SSID is not broadcast')}
          <p class="muted">Enterprise (802.1X) WiFi needs per-user credentials and is not set up automatically.</p>
        </section>

        <section class="panel" id="sec-remote"><h2>Remote management</h2>
          ${toggle('client.features.action1', 'Action1 agent', meta.features.action1)}
          ${field({ label: 'Action1 agent URL', path: 'secrets.action1AgentUrl', type: 'password', hint: 'Action1 console → Endpoints → Deploy agent → copy the MSI link' })}
          ${toggle('client.features.anydesk', 'AnyDesk unattended access', meta.features.anydesk)}
          ${field({ label: 'AnyDesk unattended-access password', path: 'secrets.anydeskPassword', type: 'password', hint: 'At least 8 characters, no spaces. Same password on every PC of this client; each PC\'s AnyDesk ID shows on the Batches screen' })}
          ${toggle('client.features.tailscale', 'Tailscale', meta.features.tailscale)}
          ${field({ label: 'Tailscale auth key', path: 'secrets.tailscaleAuthKey', type: 'password', hint: 'Reusable, pre-approved key from the Tailscale admin console' })}
        </section>

        <section class="panel" id="sec-apps"><h2>Apps</h2>
          <h3>From winget</h3>
          <div class="search-wrap">
            <input type="text" id="winget-search" placeholder="Search the winget catalog (e.g. chrome, zoom, anydesk)…" autocomplete="off" spellcheck="false">
            <div class="results" id="winget-results" hidden></div>
          </div>
          <div id="winget-list" style="margin-top:10px"></div>
          <h3>Direct-download installers <span class="muted">(not in winget; run as admin, installed for all users)</span></h3>
          <div id="installers"></div>
          <h3>Web apps <span class="muted">(Chrome app shortcut on every user's desktop and Start menu)</span></h3>
          <div id="webapps"></div>
          <p class="muted">No Microsoft Store apps: they only install for one user.</p>
        </section>

        <section class="panel" id="sec-features"><h2>Security &amp; features</h2>
          ${['automaticUpdates', 'firewall', 'screenLockOnWake', 'remoteDesktop', 'disableSmb1', 'dellCommandUpdate', 'windowsUpdate']
            .map((k) => toggle(`client.features.${k}`, labelFor(k), meta.features[k])).join('')}
          <p class="muted">Auto sign-in is always turned off at the end of setup.</p>
        </section>

        <section class="panel" id="sec-custom"><h2>Custom script</h2>
          ${toggle('client.features.customScript', 'Run a custom script', meta.features.customScript)}
          <p class="muted">PowerShell 5.1, runs elevated on the PC near the end of setup. <code>$Client</code> and <code>$Secrets</code> are available. A Command Prompt (batch) script also works: start it with <code>@echo off</code>. A failure is reported but setup continues.</p>
          <textarea data-path="customScript" spellcheck="false" placeholder="param($Client, $Secrets)&#10;# e.g. Add-Printer -ConnectionName '\\\\printserver\\Reception'">${esc(ed.customScript)}</textarea>
          <span class="field-msg" data-msg="customScript"></span>
        </section>

        <section class="panel" id="sec-notes"><h2>Notes</h2>
          <textarea data-path="client.notes" style="min-height:90px;font-family:inherit">${esc(c.notes || '')}</textarea>
        </section>

        <div class="savebar">
          <div id="save-status" class="spacer"></div>
          <button class="primary" id="save">Save</button>
        </div>
      </div>
    </div>`;

  $$('[data-jump]').forEach((a) => a.onclick = () => $(`#sec-${a.dataset.jump}`).scrollIntoView({ behavior: 'smooth', block: 'start' }));
  bindInputs($('#tab'));
  renderWingetList();
  renderRows('installers', 'client.apps.installers', [['name', 'Name'], ['url', 'Download URL (https)'], ['args', 'Silent switch, e.g. /S']], { name: '', url: '', args: '' });
  renderRows('webapps', 'client.apps.webApps', [['name', 'Name'], ['url', 'URL'], ['icon', 'Icon URL (.ico, optional)']], { name: '', url: '', icon: '' });
  setupWingetSearch();
  updatePatternPreview();
  updateEndUserFields();
  showValidation(ed.validation);
  $('#save').onclick = saveClient;
  checkWingetIds();
}

function labelFor(k) {
  return ({
    automaticUpdates: 'Automatic Windows updates', firewall: 'Firewall on', screenLockOnWake: 'Password on wake',
    remoteDesktop: 'Remote Desktop', disableSmb1: 'Disable SMBv1', dellCommandUpdate: 'Dell Command Update', windowsUpdate: 'Install Windows updates during setup',
  })[k] || k;
}

function bindInputs(root) {
  $$('[data-path]', root).forEach((el) => {
    const evt = el.type === 'checkbox' || el.tagName === 'SELECT' ? 'change' : 'input';
    el.addEventListener(evt, () => {
      const v = el.type === 'checkbox' ? el.checked : el.value;
      setPath(state.editor, el.dataset.path, v);
      markDirty();
      if (el.dataset.path === 'client.computerNamePattern') updatePatternPreview();
      if (el.dataset.path === 'client.endUser.create') updateEndUserFields();
    });
  });
  $$('[data-reveal]', root).forEach((b) => b.onclick = () => {
    const i = b.previousElementSibling;
    i.type = i.type === 'password' ? 'text' : 'password';
    b.textContent = i.type === 'password' ? 'Show' : 'Hide';
  });
}

function markDirty() {
  state.editor.dirty = true;
  $('#save-status').innerHTML = '<span class="badge warn">Unsaved changes</span>';
  validateSoon();
}

const validateSoon = debounce(async () => {
  const ed = state.editor;
  if (!ed) return;
  try {
    const v = await api('POST', `/api/clients/${ed.name}/validate`, { client: ed.client, secrets: ed.secrets, customScript: ed.customScript });
    ed.validation = v;
    showValidation(v);
  } catch { /* ignore while typing */ }
}, 400);

function showValidation(v) {
  $$('[data-msg]').forEach((m) => { m.textContent = ''; m.className = 'field-msg'; });
  $$('[data-field]').forEach((f) => f.classList.remove('has-error'));
  const counts = {};
  const sectionOf = (field) => {
    const f = field.replace(/^secrets\./, '');
    if (/^(organization|computerNamePattern|timezone|windowsEdition|locale)/.test(f)) return 'company';
    if (/^(itAdmin|endUser|itAdminPassword|endUserPassword)/.test(f)) return 'accounts';
    if (/^(wifi)/.test(f)) return 'network';
    if (/^(action1|anydesk|tailscale)/.test(f)) return 'remote';
    if (/^apps/.test(f)) return 'apps';
    if (/^customScript/.test(f)) return 'custom';
    return 'features';
  };
  const apply = (list, kind) => (list || []).forEach((i) => {
    const sec = sectionOf(i.field);
    counts[sec] = counts[sec] || { error: 0, warn: 0 };
    counts[sec][kind]++;
    const base = i.field.replace(/\[\d+\]$/, '');
    const msg = $(`[data-msg="${CSS.escape(i.field)}"]`) || $(`[data-msg="${CSS.escape(base)}"]`);
    if (msg && !msg.textContent) { msg.textContent = i.message; msg.className = `field-msg ${kind}`; }
    if (kind === 'error') { const f = $(`[data-field="${CSS.escape(i.field)}"]`); if (f) f.classList.add('has-error'); }
  });
  apply(v.errors, 'error');
  apply(v.warnings, 'warn');
  $$('[data-count]').forEach((s) => {
    const c = counts[s.dataset.count];
    s.innerHTML = !c ? '' : c.error ? `<span class="badge bad">${c.error}</span>` : `<span class="badge warn">${c.warn}</span>`;
  });
  const status = $('#save-status');
  if (status && !state.editor.dirty) {
    status.innerHTML = v.errors.length ? `<span class="badge bad">${v.errors.length} to fix before building</span>`
      : v.warnings.length ? `<span class="badge warn">${v.warnings.length} warning${v.warnings.length > 1 ? 's' : ''}</span>` : '<span class="badge ok">Ready to build</span>';
  }
  // issues that have no field on screen (e.g. installer rows) show in the apps section counts
}

async function saveClient() {
  const ed = state.editor;
  try {
    const r = await api('PUT', `/api/clients/${ed.name}`, { client: ed.client, secrets: ed.secrets, customScript: ed.customScript });
    ed.dirty = false;
    ed.validation = r.validation;
    showValidation(r.validation);
    toast('Saved');
  } catch (err) { toast(err.message, true); }
}

function updatePatternPreview() {
  const p = state.editor.client.computerNamePattern || '';
  const el = $('#pattern-preview');
  if (el) el.innerHTML = `# = PC number. Example: <code>${esc(formatName(p, 1))}</code>, <code>${esc(formatName(p, 12))}</code> (max 15 characters)`;
}

function updateEndUserFields() {
  const on = !!state.editor.client.endUser.create;
  const box = $('#enduser-fields');
  if (box) box.style.opacity = on ? 1 : 0.45;
}

// ---------- repeatable rows (installers, web apps) ----------

function renderRows(containerId, listPath, cols, blank) {
  const ed = state.editor;
  const list = getPath(ed, listPath) || [];
  const box = $(`#${containerId}`);
  box.innerHTML = `
    ${list.length ? `<table><thead><tr>${cols.map(([, t]) => `<th>${esc(t)}</th>`).join('')}<th></th></tr></thead><tbody>
      ${list.map((row, i) => `<tr>${cols.map(([k]) => `<td><input type="text" data-path="${esc(`${listPath}.${i}.${k}`)}" value="${esc(row[k] || '')}" spellcheck="false"></td>`).join('')}
        <td><button class="small danger" data-remove="${i}">Remove</button></td></tr>
        <tr><td colspan="${cols.length + 1}" style="border:0;padding-top:0"><span class="field-msg" data-msg="${esc(`${vKey(listPath)}[${i}]`)}"></span></td></tr>`).join('')}
    </tbody></table>` : '<p class="muted">None.</p>'}
    <button class="small" data-add>Add</button>`;
  bindInputs(box);
  $$('[data-remove]', box).forEach((b) => b.onclick = () => {
    list.splice(Number(b.dataset.remove), 1);
    markDirty();
    renderRows(containerId, listPath, cols, blank);
  });
  $('[data-add]', box).onclick = () => {
    if (!getPath(ed, listPath)) setPath(ed, listPath, []);
    getPath(ed, listPath).push(clone(blank));
    markDirty();
    renderRows(containerId, listPath, cols, blank);
  };
}

// ---------- winget ----------

function renderWingetList() {
  const ids = state.editor.client.apps.winget || [];
  const box = $('#winget-list');
  if (!ids.length) { box.innerHTML = '<p class="muted">No winget apps yet. Search above to add some.</p>'; return; }
  box.innerHTML = `<table><thead><tr><th>Package ID</th><th>Name</th><th>Catalog</th><th></th></tr></thead><tbody>
    ${ids.map((id, i) => {
      const s = state.wingetStatus[id.toLowerCase()];
      const badge = !s ? '<span class="badge">checking…</span>' : s.found ? '<span class="badge ok">found</span>' : '<span class="badge bad">not in winget</span>';
      return `<tr><td class="mono">${esc(id)}</td><td>${esc(s && s.name)}</td><td>${badge}</td>
        <td><button class="small danger" data-rm-winget="${i}">Remove</button></td></tr>`;
    }).join('')}
  </tbody></table><span class="field-msg" data-msg="apps.winget"></span>`;
  $$('[data-rm-winget]', box).forEach((b) => b.onclick = () => {
    ids.splice(Number(b.dataset.rmWinget), 1);
    markDirty();
    renderWingetList();
  });
}

async function checkWingetIds() {
  const ids = state.editor.client.apps.winget || [];
  if (!ids.length) return;
  try {
    const { results } = await api('POST', '/api/winget/check', { ids });
    results.forEach((r) => { state.wingetStatus[r.id.toLowerCase()] = r; });
    renderWingetList();
  } catch (err) {
    toast(`winget catalog: ${err.message}`, true);
  }
}

function setupWingetSearch() {
  const input = $('#winget-search');
  const box = $('#winget-results');
  const search = debounce(async () => {
    const q = input.value.trim();
    if (q.length < 2) { box.hidden = true; return; }
    box.hidden = false;
    box.innerHTML = '<div class="muted">Searching… (the first search downloads the catalog)</div>';
    try {
      const { results } = await api('GET', `/api/winget/search?q=${encodeURIComponent(q)}`);
      if (!results.length) { box.innerHTML = '<div class="muted">No match in winget. Use a direct installer or a web app instead.</div>'; return; }
      box.innerHTML = results.map((r) => `<div data-id="${esc(r.id)}" data-name="${esc(r.name)}"><b>${esc(r.name)}</b><small class="mono">${esc(r.id)}</small><span class="spacer"></span><small>${esc(r.version)}</small></div>`).join('');
      $$('[data-id]', box).forEach((d) => d.onclick = () => {
        const ids = state.editor.client.apps.winget;
        if (!ids.some((x) => x.toLowerCase() === d.dataset.id.toLowerCase())) {
          ids.push(d.dataset.id);
          state.wingetStatus[d.dataset.id.toLowerCase()] = { id: d.dataset.id, found: true, name: d.dataset.name };
          markDirty();
          renderWingetList();
        }
        input.value = '';
        box.hidden = true;
      });
    } catch (err) { box.innerHTML = `<div class="muted">${esc(err.message)}</div>`; }
  }, 250);
  input.addEventListener('input', search);
  document.addEventListener('click', (e) => { if (!e.target.closest('.search-wrap')) box.hidden = true; });
}

// ---------- batches tab ----------

const STATUSES = [['', 'not used yet'], ['used', 'used (by hand)'], ['in-progress', 'in progress'], ['done', 'done'], ['failed', 'failed'], ['skipped', 'skipped']];

async function refreshBatches() {
  const d = await api('GET', `/api/clients/${state.editor.name}`);
  state.editor.batches = d.batches.batches || [];
}

function renderBatches(editId = null) {
  clearTimers();   // the list auto-refreshes; never while a form is open
  const ed = state.editor;
  const editing = editId === 'new' ? { name: '', computerNamePattern: ed.client.computerNamePattern, start: 1, end: 10, overrides: {}, notes: '' }
    : editId ? clone(ed.batches.find((b) => b.id === editId)) : null;

  const cards = ed.batches.slice().reverse().map((b) => {
    const pattern = b.computerNamePattern || ed.client.computerNamePattern;
    const machines = b.machines || {};
    const tally = { done: 0, failed: 0, 'in-progress': 0, used: 0 };
    const tiles = [];
    for (let n = b.start; n <= b.end; n++) {
      const m = machines[String(n)] || {};
      const st = m.status || '';
      if (tally[st] !== undefined) tally[st]++;
      const detail = [m.model, m.serial && `S/N ${m.serial}`, m.failures ? `${m.failures} failed step(s)` : '', m.warnings ? `${m.warnings} warning(s)` : '', m.updated && when(m.updated)].filter(Boolean).join(' · ');
      tiles.push(`<div class="machine ${esc(st)}" title="${esc(detail)}">
        <div class="name">${esc(formatName(pattern, n))}</div>
        <div class="muted">#${n}${m.source === 'report' ? ' · reported' : ''}</div>
        ${m.ipAddress ? `<div class="mono copy" title="IP address">IP ${esc(m.ipAddress)}</div>` : ''}
        ${m.anydeskId ? `<div class="mono copy" title="AnyDesk ID">AnyDesk ${esc(m.anydeskId)}</div>` : ''}
        <select data-machine="${esc(b.id)}:${n}">${STATUSES.map(([v, t]) => `<option value="${v}" ${v === st ? 'selected' : ''}>${t}</option>`).join('')}</select>
      </div>`);
    }
    const o = b.overrides || {};
    const ov = [o.wifiSsid && `WiFi ${o.wifiSsid}`, o.endUserUsername && `end user ${o.endUserUsername}`].filter(Boolean).join(', ');
    return `<section class="panel">
      <div class="row"><div><h2 style="margin:0">${esc(b.name)}</h2>
        <div class="muted"><span class="mono">${esc(formatName(pattern, b.start))} → ${esc(formatName(pattern, b.end))}</span> · created ${esc(when(b.created))}${ov ? ` · overrides: ${esc(ov)}` : ''}</div></div>
        <span class="spacer"></span>
        <span class="badge ok">${tally.done} done</span><span class="badge info">${tally['in-progress']} in progress</span>
        <span class="badge bad">${tally.failed} failed</span><span class="badge warn">${tally.used} used</span>
        <button class="small" data-edit-batch="${esc(b.id)}">Edit</button>
        <button class="small primary" data-build-batch="${esc(b.id)}">Build media</button>
      </div>
      ${b.notes ? `<p class="muted">${esc(b.notes)}</p>` : ''}
      <div class="machines" style="margin-top:12px">${tiles.join('')}</div>
    </section>`;
  }).join('');

  $('#tab').innerHTML = `
    <div class="row" style="margin-bottom:12px">
      <p class="muted" style="margin:0">A batch is a group of PCs with a numbered name. PCs report their progress here when the UI runs with <code>-Lan</code>; you can also set a status by hand.</p>
      <span class="spacer"></span><button class="primary" id="new-batch">New batch</button>
    </div>
    ${editing ? batchForm(editing) : ''}
    ${cards || (editing ? '' : '<div class="panel muted">No batches yet.</div>')}`;

  if (editing) bindBatchForm(editing);
  $('#new-batch').onclick = () => renderBatches('new');
  $$('[data-edit-batch]').forEach((b) => b.onclick = () => renderBatches(b.dataset.editBatch));
  $$('[data-build-batch]').forEach((b) => b.onclick = () => { state.build.client = ed.name; state.build.batch = b.dataset.buildBatch; location.hash = '#/build'; });
  $$('[data-machine]').forEach((s) => s.onchange = async () => {
    const [bid, n] = s.dataset.machine.split(':');
    try {
      await api('PUT', `/api/clients/${ed.name}/batches/${bid}/machines/${n}`, { status: s.value, note: '' });
      await refreshBatches();
      renderBatches();
    } catch (err) { toast(err.message, true); }
  });

  if (!editing) {
    state.timers.push(setInterval(async () => {
      const a = document.activeElement;
      if (a && ['SELECT', 'INPUT', 'TEXTAREA'].includes(a.tagName)) return;
      if (!location.hash.endsWith('/batches') || $('#batch-form')) return;
      try { await refreshBatches(); renderBatches(); } catch { /* keep last view */ }
    }, 8000));
  }
}

function batchForm(b) {
  const o = b.overrides || {};
  const f = (label, key, val, type = 'text', hint = '') => `<label class="field">${label}<input type="${type}" data-b="${key}" value="${esc(val ?? '')}" spellcheck="false">${hint ? `<span class="hint">${hint}</span>` : ''}</label>`;
  return `<section class="panel" id="batch-form">
    <h2>${b.id ? 'Edit batch' : 'New batch'}</h2>
    <div class="grid">
      ${f('Batch name', 'name', b.name, 'text', 'e.g. Customer service desks - Nov 2026')}
      ${f('Computer name pattern', 'computerNamePattern', b.computerNamePattern, 'text', '<span id="bpreview"></span>')}
      ${f('First PC number', 'start', b.start, 'number')}
      ${f('Last PC number', 'end', b.end, 'number')}
    </div>
    <h3>Overrides for this batch <span class="muted">(optional - empty = client setting)</span></h3>
    <div class="grid">
      ${f('WiFi name', 'o.wifiSsid', o.wifiSsid)}
      <label class="field">WiFi security<select data-b="o.wifiSecurity">${[['', '(client setting)'], ['WPA2PSK', 'WPA2-Personal'], ['WPA3SAE', 'WPA3-Personal'], ['open', 'Open']].map(([v, t]) => `<option value="${v}" ${v === (o.wifiSecurity || '') ? 'selected' : ''}>${t}</option>`).join('')}</select></label>
      ${f('WiFi password', 'o.wifiPassword', o.wifiPassword, 'password')}
      ${f('End user username', 'o.endUserUsername', o.endUserUsername)}
      ${f('End user full name', 'o.endUserFullName', o.endUserFullName)}
      ${f('End user default password', 'o.endUserPassword', o.endUserPassword, 'password')}
    </div>
    <label class="field" style="margin-top:12px">Notes<input type="text" data-b="notes" value="${esc(b.notes || '')}"></label>
    <div class="row" style="margin-top:16px"><span class="spacer"></span>
      <button id="batch-cancel">Cancel</button><button class="primary" id="batch-save">Save batch</button></div>
  </section>`;
}

function bindBatchForm(b) {
  const preview = () => {
    const p = b.computerNamePattern || state.editor.client.computerNamePattern;
    $('#bpreview').innerHTML = `<code>${esc(formatName(p, Number(b.start) || 0))}</code> → <code>${esc(formatName(p, Number(b.end) || 0))}</code>`;
  };
  $$('[data-b]').forEach((el) => el.addEventListener(el.tagName === 'SELECT' ? 'change' : 'input', () => {
    const k = el.dataset.b;
    if (!b.overrides) b.overrides = {};
    if (k.startsWith('o.')) b.overrides[k.slice(2)] = el.value;
    else b[k] = el.type === 'number' ? Number(el.value) : el.value;
    preview();
  }));
  preview();
  $('#batch-cancel').onclick = () => renderBatches();
  $('#batch-save').onclick = async () => {
    try {
      Object.keys(b.overrides).forEach((k) => { if (!b.overrides[k]) delete b.overrides[k]; });
      const payload = { name: b.name, computerNamePattern: b.computerNamePattern, start: b.start, end: b.end, overrides: b.overrides, notes: b.notes };
      if (b.id) await api('PUT', `/api/clients/${state.editor.name}/batches/${b.id}`, payload);
      else await api('POST', `/api/clients/${state.editor.name}/batches`, payload);
      await refreshBatches();
      toast('Batch saved');
      renderBatches();
    } catch (err) { toast(err.message, true); }
  };
}

// =====================================================================
// Build
// =====================================================================

async function renderBuild() {
  const [{ clients }, system] = await Promise.all([api('GET', '/api/clients'), api('GET', '/api/system')]);
  state.system = system;
  const usable = clients.filter((c) => !c.legacy);
  const b = state.build;
  if (!b.client && usable.length) b.client = usable[0].name;
  let batches = [];
  if (b.client) {
    const d = await api('GET', `/api/clients/${b.client}`);
    batches = d.batches.batches || [];
    if (b.batch && !batches.some((x) => x.id === b.batch)) b.batch = '';
  }
  if (!system.cleanIsoPossible && b.media === 'iso') b.media = 'provision';
  if (!b.reportIp && system.lanAddresses.length) b.reportIp = system.lanAddresses[0];
  const current = usable.find((c) => c.name === b.client);

  const media = [
    ['provision', 'Provisioning ISO', 'PCs already have Windows 11 and sit at the setup (OOBE) screen. Nothing is erased. Mount as CD-ROM, then Shift+F10 → D:\\RUN <number>.', true],
    ['usb', 'Clean-install USB folder', 'Wipes the disk. Copy the folder onto a Windows 11 USB stick. Names increment automatically.', true],
    ['iso', 'Clean-install ISO (bootable)', system.cleanIsoPossible ? 'Wipes the disk. Needs a stock Windows 11 ISO; the UI must run as Administrator.' : 'Windows only - build the USB folder on macOS instead.', system.cleanIsoPossible],
  ];

  $('#app').innerHTML = `
    <div class="page-head"><div><h1>Build media</h1><div class="muted">Pick a client and a batch, then the kind of media.</div></div></div>
    <section class="panel">
      <div class="grid">
        <label class="field">Client<select id="b-client">${usable.map((c) => `<option value="${esc(c.name)}" ${c.name === b.client ? 'selected' : ''}>${esc(c.organization || c.name)}</option>`).join('')}</select></label>
        <label class="field">Batch<select id="b-batch"><option value="">No batch (client pattern, starting at 1)</option>
          ${batches.slice().reverse().map((x) => `<option value="${esc(x.id)}" ${x.id === b.batch ? 'selected' : ''}>${esc(x.name)} (${x.start}-${x.end})</option>`).join('')}</select>
          <span class="hint"><a href="#/client/${esc(b.client)}/batches">Manage batches</a> - a batch tracks which PC got which number.</span></label>
      </div>
      ${current && current.errors ? `<p><span class="badge bad">${current.errors} to fix</span> <a href="#/client/${esc(b.client)}">Open the client settings</a> before building.</p>` : ''}
      <h3>Media</h3>
      <div class="media-options">${media.map(([k, t, d, ok]) => `<label class="media-option ${b.media === k ? 'selected' : ''} ${ok ? '' : 'disabled'}">
        <input type="radio" name="media" value="${k}" ${b.media === k ? 'checked' : ''} ${ok ? '' : 'disabled'}><span><b>${t}</b><span class="muted">${esc(d)}</span></span></label>`).join('')}</div>
      <div id="iso-path" ${b.media === 'iso' ? '' : 'hidden'} style="margin-top:12px">
        <label class="field">Stock Windows 11 ISO (full path on this computer)<input type="text" id="b-stock" value="${esc(b.stockIso)}" placeholder="C:\\ISO\\Win11_24H2_English_x64.iso"></label>
      </div>
      <h3>Progress reports</h3>
      <label class="toggle"><input type="checkbox" id="b-report" ${b.report && system.lan && b.batch ? 'checked' : ''} ${b.batch ? '' : 'disabled'}>
        <span><b>PCs report their progress to this computer</b>
        <small>${!b.batch ? 'Choose a batch first.' : !system.lan ? 'Ticking this lets PCs on the local network reach this computer (only for progress reports).' : 'The PCs must be able to reach this computer on the network during setup.'}</small></span></label>
      ${system.lan && system.lanAddresses.length > 1 ? `<label class="field" style="max-width:260px">This computer's address<select id="b-ip">${system.lanAddresses.map((ip) => `<option ${ip === b.reportIp ? 'selected' : ''}>${esc(ip)}</option>`).join('')}</select></label>` : ''}
      <div class="row" style="margin-top:18px"><span class="spacer"></span><button class="primary" id="b-go" ${usable.length ? '' : 'disabled'}>Build</button></div>
    </section>
    <section class="panel" id="job" ${b.jobId ? '' : 'hidden'}></section>`;

  $('#b-client').onchange = (e) => { b.client = e.target.value; b.batch = ''; renderBuild(); };
  $('#b-batch').onchange = (e) => { b.batch = e.target.value; renderBuild(); };
  $$('input[name=media]').forEach((r) => r.onchange = () => { b.media = r.value; renderBuild(); });
  if ($('#b-stock')) $('#b-stock').oninput = (e) => { b.stockIso = e.target.value; };
  if ($('#b-report')) $('#b-report').onchange = async (e) => {
    b.report = e.target.checked;
    if (b.report && !state.system.lan) {
      if (!(await setLan(true))) { b.report = false; e.target.checked = false; return; }
      renderBuild();
    }
  };
  if ($('#b-ip')) $('#b-ip').onchange = (e) => { b.reportIp = e.target.value; };
  $('#b-go').onclick = startBuild;
  if (b.jobId) pollJob();
}

async function startBuild() {
  const b = state.build;
  try {
    const r = await api('POST', '/api/build', { client: b.client, batch: b.batch, media: b.media, stockIso: b.stockIso, report: b.report && !!b.batch, reportIp: b.reportIp });
    b.jobId = r.jobId;
    b.job = null;
    $('#job').hidden = false;
    pollJob();
  } catch (err) { toast(err.message, true); }
}

function pollJob() {
  const b = state.build;
  const tick = async () => {
    try {
      const j = await api('GET', `/api/jobs/${b.jobId}`);
      b.job = j;
      renderJob(j);
      if (!['Running', 'NotStarted'].includes(j.state)) clearTimers();
    } catch (err) { clearTimers(); toast(err.message, true); }
  };
  clearTimers();
  tick();
  state.timers.push(setInterval(tick, 1000));
}

function renderJob(j) {
  const box = $('#job');
  if (!box) return;
  const running = ['Running', 'NotStarted'].includes(j.state);
  const ok = j.state === 'Completed' && !j.error;
  const r = j.result || {};
  box.hidden = false;
  box.innerHTML = `
    <div class="row"><h2 style="margin:0">${running ? 'Building…' : ok ? 'Done' : 'Build failed'}</h2>
      ${running ? '<span class="badge info">running</span>' : ok ? '<span class="badge ok">done</span>' : '<span class="badge bad">failed</span>'}</div>
    ${j.error ? `<p style="color:var(--bad)">${esc(j.error)}</p>` : ''}
    ${ok && r.outputs ? `<h3>Output</h3>${r.outputs.map((p) => `<div class="row"><code>${esc(p)}</code><button class="small" data-open="${esc(p)}">Show</button></div>`).join('')}` : ''}
    ${ok && r.instructions ? `<h3>Next steps</h3><ol class="steps">${r.instructions.map((s) => `<li>${esc(s)}</li>`).join('')}</ol>` : ''}
    ${ok && r.warnings && r.warnings.length ? `<h3>Warnings</h3><ul class="issues">${r.warnings.map((w) => `<li class="warn">${esc(w)}</li>`).join('')}</ul>` : ''}
    ${ok ? '<p class="muted">The media contains plain-text passwords: keep it private and delete it when the batch is done.</p>' : ''}
    <h3>Log</h3><div class="log">${esc((j.log || []).join('\n')) || '…'}</div>`;
  $$('[data-open]', box).forEach((btn) => btn.onclick = async () => {
    try { await api('POST', '/api/open', { path: btn.dataset.open }); } catch (err) { toast(err.message, true); }
  });
}

// =====================================================================
// System
// =====================================================================

async function renderSystem() {
  const s = await api('GET', '/api/system');
  state.system = s;
  const cat = s.wingetCatalog;
  $('#app').innerHTML = `
    <div class="page-head"><div><h1>System</h1><div class="muted">This computer and the tools the builds use.</div></div></div>
    <section class="panel"><table>
      <tr><th>Operating system</th><td>${esc(s.os)}${s.os === 'Windows' ? (s.isAdmin ? ' (Administrator)' : ' (not Administrator)') : ''}</td></tr>
      <tr><th>PowerShell</th><td>${esc(s.pwsh)}</td></tr>
      <tr><th>Provisioning ISO</th><td>${s.isoTool ? `<span class="badge ok">${esc(s.isoTool)}</span>` : '<span class="badge bad">no ISO tool</span>'}</td></tr>
      <tr><th>Clean-install ISO</th><td>${s.cleanIsoPossible ? `<span class="badge ok">available</span> ${s.oscdimg ? 'using oscdimg (ADK)' : 'using built-in IMAPI2 (no ADK)'}${s.isAdmin ? '' : ' - start the UI as Administrator to build it'}` : '<span class="badge">Windows only</span> - use the clean-install USB folder on this computer'}</td></tr>
      <tr><th>Progress reports</th><td>${s.lan ? `<span class="badge ok">on</span> PCs report to ${s.lanAddresses.map((ip) => `<code>http://${esc(ip)}:${s.port}/api/report</code>`).join(' or ')}` : '<span class="badge">off</span> only this computer can reach the UI'}
        <button class="small" id="toggle-lan">${s.lan ? 'Turn off' : 'Turn on'}</button></td></tr>
      <tr><th>winget catalog</th><td>${cat.available ? `${cat.count.toLocaleString()} packages, updated ${esc(when(cat.updated))}` : 'not downloaded yet'} <button class="small" id="refresh-cat">Update now</button></td></tr>
      <tr><th>Project folder</th><td><code>${esc(s.repo)}</code></td></tr>
    </table></section>`;
  $('#toggle-lan').onclick = async () => { if (await setLan(!s.lan)) renderSystem(); };
  $('#refresh-cat').onclick = async (e) => {
    e.target.disabled = true; e.target.textContent = 'Downloading…';
    try { await api('POST', '/api/winget/refresh'); toast('winget catalog updated'); renderSystem(); } catch (err) { toast(err.message, true); e.target.disabled = false; }
  };
}

// =====================================================================
// Progress reports (network mode)
// =====================================================================

function updateLanBadge() {
  const lan = $('#lan-badge');
  lan.hidden = false;
  lan.textContent = state.system.lan ? 'Receiving PC reports' : 'Local only';
  lan.className = `badge ${state.system.lan ? 'ok' : 'muted'}`;
}

async function setLan(enabled) {
  if (enabled && !confirm('Let PCs on the local network send progress reports to this computer?\n\nOnly the report address is reachable from the network; settings and passwords stay on this computer. Your Mac or Windows may ask to allow PowerShell through the firewall - allow it.')) return false;
  try {
    await api('POST', '/api/lan', { enabled });
    // the server re-opens its listener right after answering
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 250));
      try { state.system = await api('GET', '/api/system'); if (state.system.lan === enabled) break; } catch { /* restarting */ }
    }
    updateLanBadge();
    toast(enabled ? 'Receiving progress reports from PCs' : 'Progress reports turned off');
    return state.system.lan === enabled;
  } catch (err) { toast(err.message, true); return false; }
}

// =====================================================================
// Start
// =====================================================================

(async function init() {
  try {
    [state.meta, state.system] = await Promise.all([api('GET', '/api/meta'), api('GET', '/api/system')]);
    updateLanBadge();
  } catch (err) {
    $('#app').innerHTML = `<div class="panel">Cannot reach the provisioning server: ${esc(err.message)}</div>`;
    return;
  }
  route();
})();
