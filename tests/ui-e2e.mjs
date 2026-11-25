// End-to-end test of the provisioning UI: drives headless Chrome/Edge through the
// DevTools protocol (no npm packages). Run via:  pwsh ./tests/Test-Provisioning.ps1 -UI
// Usage: node tests/ui-e2e.mjs <base-url> <temp-profile-dir> [browser-path]
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
const [,, base, profile, browserArg] = process.argv;
const candidates = [browserArg, process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium'].filter(Boolean);
const browser = candidates.find((p) => existsSync(p));
if (!browser) { console.log('skip: no Chrome/Edge found (set CHROME_PATH)'); process.exit(0); }
const chrome = spawn(browser,
  ['--headless=new', '--disable-gpu', '--no-first-run', `--user-data-dir=${profile}`, '--remote-debugging-port=9333', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0; const pending = new Map(); const problems = []; let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ok  ', m); } else { fail++; console.log('  FAIL', m); } };
try {
  let targets;
  for (let i = 0; i < 40; i++) { try { targets = await (await fetch('http://127.0.0.1:9333/json')).json(); if (targets.length) break; } catch {} await sleep(250); }
  const page = targets.find((t) => t.type === 'page');
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    if (msg.method === 'Runtime.exceptionThrown') problems.push(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
    if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') problems.push(msg.params.args.map((a) => a.value || a.description).join(' '));
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const js = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); return r.result?.result?.value; };
  const waitFor = async (expr, ms = 8000) => { for (let t = 0; t < ms; t += 150) { if (await js(expr)) return true; await sleep(150); } return false; };
  const type = (sel, val) => js(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); el.value = ${JSON.stringify(val)}; el.dispatchEvent(new Event(el.tagName==='SELECT'?'change':'input', {bubbles:true})); return true; })()`);
  const click = (sel) => js(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return false; el.click(); return true; })()`);

  await send('Runtime.enable'); await send('Page.enable');
  await send('Page.navigate', { url: `${base}/#/clients` });
  ok(await waitFor(`document.querySelectorAll('tr[data-go]').length >= 1`), 'clients list renders');

  // New client
  await click('#new-client');
  await type('#new-form input[name=name]', 'beta');
  await js(`document.querySelector('#new-form').requestSubmit()`);
  ok(await waitFor(`location.hash === '#/client/beta' && !!document.querySelector('#save')`), 'new client created and opened');

  // Fill required fields
  await type('[data-path="client.organization"]', 'BETA CORP');
  await type('[data-path="client.computerNamePattern"]', 'BETA-PC-##');
  ok(await waitFor(`document.querySelector('#pattern-preview').textContent.includes('BETA-PC-01')`), 'pattern preview updates');
  await type('[data-path="secrets.itAdminPassword"]', 'Adm1n-Pass!');
  await type('[data-path="client.endUser.username"]', 'staff');
  await type('[data-path="secrets.endUserPassword"]', 'Welcome-2026');
  ok(await waitFor(`document.querySelector('#save-status').textContent.includes('Unsaved')`), 'unsaved indicator');

  // winget search + add
  await type('#winget-search', 'zoom workplace');
  ok(await waitFor(`document.querySelectorAll('#winget-results [data-id]').length > 0`), 'winget search shows results');
  const added = await js(`(() => { const d = document.querySelector('#winget-results [data-id]'); const id = d.dataset.id; d.click(); return id; })()`);
  ok(await waitFor(`document.querySelector('#winget-list').textContent.includes(${JSON.stringify(added)})`), `added ${added} from search`);

  // Installer row
  await click('#installers [data-add]');
  await type('[data-path="client.apps.installers.0.name"]', 'Tool');
  await type('[data-path="client.apps.installers.0.url"]', 'https://example.com/tool.exe');

  // Save
  await click('#save');
  ok(await waitFor(`document.querySelector('#save-status').textContent.includes('Ready to build') || document.querySelector('#save-status').textContent.includes('warning')`), 'saved without errors');
  const saved = await js(`fetch('/api/clients/beta').then(r => r.json())`);
  ok(saved.client.organization === 'BETA CORP' && saved.secrets.itAdminPassword === 'Adm1n-Pass!' && saved.client.apps.winget.includes(added) && saved.client.apps.installers[0].name === 'Tool', 'saved values on disk');

  // Batch
  await send('Page.navigate', { url: `${base}/#/client/beta/batches` });
  ok(await waitFor(`!!document.querySelector('#new-batch')`), 'batches tab');
  await click('#new-batch');
  ok(await waitFor(`!!document.querySelector('#batch-form')`), 'batch form');
  await type('[data-b="name"]', 'First 4');
  await sleep(9500);   // longer than the 8 s auto-refresh of the batch list
  ok(await js(`!!document.querySelector('#batch-form') && document.querySelector('[data-b="name"]').value === 'First 4'`), 'batch form survives the auto-refresh');
  await type('[data-b="start"]', '1');
  await type('[data-b="end"]', '4');
  await click('#batch-save');
  ok(await waitFor(`document.querySelectorAll('.machine').length === 4`), 'batch saved with 4 PCs');
  await js(`(() => { const s = document.querySelector('[data-machine]'); s.value = 'used'; s.dispatchEvent(new Event('change')); })()`);
  ok(await waitFor(`!!document.querySelector('.machine.used')`), 'manual status saved');

  // A PC reports its progress: plain-language tile, details window with steps + log
  const report = (extra) => js(`fetch('/api/clients/beta').then(r => r.json()).then(d => fetch('/api/report', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(Object.assign({ token: d.batches.batches[0].token, computerName: 'BETA-PC-02', ipAddress: '10.0.0.42', anydeskId: '987654321',
      hardware: { cpu: 'Intel N100', ram: '16 GB (1 x 16 GB)', storage: '512 GB NVMe SSD (A)', gpu: 'Intel UHD', windows: 'Windows 11 Pro 24H2', windowsBuild: '26100.1' },
      results: [{ step: 'WiFi', status: 'ok', detail: 'Internet connection available' }, { step: 'Custom script', status: 'fail', detail: 'exit code 1' }] }, ${JSON.stringify(extra)})) }).then(r => r.status))`);
  ok(await report({ state: 'running', currentStep: 'Apps (winget)', stepIndex: 5, stepTotal: 19, stepStartedAt: new Date().toISOString(), log: 'Installing Google.Chrome...\nLOG-MARKER' }) === 200, 'progress report accepted');
  await send('Page.navigate', { url: `${base}/#/client/beta/batches` });
  ok(await waitFor(`[...document.querySelectorAll('.machine .state')].some(e => e.textContent.includes('Step 5 of 19: Apps (winget)'))`), 'tile shows the current step');
  await click('[data-open-machine]');
  ok(await waitFor(`!!document.querySelector('.modal .log') && document.querySelector('.modal .log').textContent.includes('LOG-MARKER')`), 'details window shows the PC log');
  ok(await js(`document.querySelector('.modal').innerText.includes('10.0.0.42') && document.querySelector('.modal').innerText.includes('987654321') && document.querySelectorAll('.modal .steps-table tr').length === 3`), 'details window shows IP, AnyDesk ID and steps');
  ok(await js(`document.querySelector('.modal .hw-table').innerText.includes('512 GB NVMe SSD') && document.querySelector('.modal .hw-table').innerText.includes('build 26100.1')`), 'details window shows the hardware');
  await click('#m-close');
  ok(await waitFor(`!document.querySelector('.modal-back')`), 'details window closes');
  // A second PC with less memory: the batch's hardware table highlights only what differs
  await report({ state: 'running', computerName: 'BETA-PC-03', hardware: { cpu: 'Intel N100', ram: '8 GB (1 x 8 GB)', storage: '512 GB NVMe SSD (B)', gpu: 'Intel UHD', windows: 'Windows 11 Pro 24H2', windowsBuild: '26100.2' } });
  await send('Page.navigate', { url: `${base}/#/client/beta` });
  await send('Page.navigate', { url: `${base}/#/client/beta/batches` });
  ok(await waitFor(`!!document.querySelector('[data-hardware]')`), 'batch has a Hardware button');
  await click('[data-hardware]');
  ok(await waitFor(`document.querySelectorAll('.modal .hw-table tbody tr').length === 2`), 'hardware table lists the PCs that reported');
  ok(await js(`[...new Set([...document.querySelectorAll('.modal td.differs')].map(e => e.dataset.hw))].join() === 'ram'`), 'only the memory differs (disk model and Windows build are ignored)');
  await click('#m-close');
  ok(await report({ state: 'done', failures: 1, finishedAt: new Date().toISOString(), log: 'PROVISIONING FINISHED' }) === 200, 'final report accepted');
  await send('Page.navigate', { url: `${base}/#/client/beta` });
  await send('Page.navigate', { url: `${base}/#/client/beta/batches` });
  ok(await waitFor(`!!document.querySelector('.machine.done-issues') && document.querySelector('.machine.done-issues').innerText.includes('Finished · 1 step failed')`), 'PC that finished with a failed step shows as finished, not failed');

  // "← Clients" goes back to the list
  await click('.page-head a[href="#/clients"]');
  ok(await waitFor(`location.hash === '#/clients' && document.querySelectorAll('tr[data-go]').length >= 1`), '"← Clients" returns to the list');
  await send('Page.navigate', { url: `${base}/#/client/beta/batches` });
  await waitFor(`!!document.querySelector('[data-build-batch]')`);

  // Build from batch
  await click('[data-build-batch]');
  ok(await waitFor(`location.hash === '#/build' && !!document.querySelector('#b-go')`), 'build page opened from batch');
  await js(`(() => { const r = document.querySelector('input[name=media][value=usb]'); r.checked = true; r.dispatchEvent(new Event('change')); })()`);
  await waitFor(`document.querySelector('.media-option.selected input').value === 'usb'`);
  await click('#b-go');
  ok(await waitFor(`document.querySelector('#job') && /Done|failed/.test(document.querySelector('#job h2').textContent)`, 30000), 'build finished');
  const jobText = await js(`document.querySelector('#job').innerText`);
  ok(/Done/.test(jobText) && /usb/.test(jobText), 'build succeeded with output path');

  // Unsaved-changes guard
  await send('Page.navigate', { url: `${base}/#/client/beta` });
  await waitFor(`!!document.querySelector('#save')`);
  await type('[data-path="client.notes"]', 'changed');
  await js(`window.confirm = () => false; location.hash = '#/clients'`);
  await sleep(400);
  ok(await js(`location.hash`) === '#/client/beta', 'unsaved changes guard keeps you on the page');

  ok(problems.length === 0, `no JavaScript errors${problems.length ? ': ' + problems.join(' | ') : ''}`);
} catch (e) { fail++; console.log('  FAIL', e.message); }
finally { try { ws?.close(); } catch {} chrome.kill(); console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0); }
