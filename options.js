const $ = (s) => document.querySelector(s);
const send = (m) => new Promise((r) => chrome.runtime.sendMessage(m, r));

// Rule-building + file handling live in rules-lib.js (window.RB), shared with the popup.

// Native host status - can't fix the connection with a click (Chrome refuses to let an extension
// reach a host that hasn't already whitelisted its id, which is exactly the problem here, so
// there's no way to bootstrap that from inside the extension). What this CAN do: a real
// connectivity check instead of waiting for some other action to fail, and the exact fix command
// with this extension's actual id pre-filled - chrome.runtime.id is the one thing about "where is
// this installed" an extension can always know for certain; there's no API for its own on-disk
// path, so the folder-navigation part stays a plain instruction rather than a fake copy-paste path.
async function checkHostStatus() {
  const statusEl = $('#hostStatus');
  statusEl.textContent = 'Checking…';
  $('#hostFix').hidden = true;
  $('#hostCopyMsg').textContent = '';
  let res;
  try { res = await send({ type: 'pingNativeHost' }); } catch (e) { res = { ok: false, error: String(e) }; }

  statusEl.innerHTML = '';
  if (res && res.ok && res.pong) {
    const pill = document.createElement('span'); pill.className = 'pill gen'; pill.textContent = '✓ connected';
    const note = document.createElement('span'); note.className = 'note'; note.textContent = 'com.storytabgroups.worktree is reachable.';
    statusEl.append(pill, note);
    return;
  }

  const pill = document.createElement('span'); pill.className = 'pill err'; pill.textContent = '✕ not connected';
  const note = document.createElement('span'); note.className = 'note';
  note.textContent = (res && res.error) || 'no response';
  statusEl.append(pill, note);

  const myId = chrome.runtime.id;
  $('#hostCmd').textContent = `.\\install-native-host.ps1 -ExtensionId ${myId}`;
  $('#hostIdNote').textContent = `(this extension's id: ${myId} — pre-filled above so you don't need to look it up in chrome://extensions)`;
  $('#hostFix').hidden = false;
}

$('#hostRecheck').onclick = checkHostStatus;
$('#hostCopyBtn').onclick = async () => {
  try {
    await navigator.clipboard.writeText($('#hostCmd').textContent);
    $('#hostCopyMsg').textContent = 'Copied ✓';
    setTimeout(() => { $('#hostCopyMsg').textContent = ''; }, 1600);
  } catch (e) {
    $('#hostCopyMsg').textContent = 'Copy failed — select the text and copy manually';
  }
};

// Every "Help" pointer on this page opens the same page, in a new tab — the full step-by-step
// install/troubleshooting guide this page intentionally doesn't repeat inline.
const openHelp = (e) => { e.preventDefault(); chrome.tabs.create({ url: chrome.runtime.getURL('help.html') }); };
for (const id of ['helpLink', 'hostHelpLink', 'diagHelpLink']) {
  const el = $('#' + id);
  if (el) el.onclick = openHelp;
}

checkHostStatus();

$('#loadFile').onclick = async () => {
  $('#loadMsg').textContent = '';
  if (!window.showOpenFilePicker) {
    $('#loadMsg').textContent = 'Your Chrome is too old for the file picker — use Advanced instead.';
    return;
  }
  try {
    const res = await RB.sync(); // picks if needed; safe here (the Options page survives the dialog)
    $('#loadMsg').textContent = `Loaded ${res.count} stories ✓`;
    render();
  } catch (e) {
    if (e.name !== 'AbortError') $('#loadMsg').textContent = 'Error: ' + e.message;
  }
};

async function render() {
  const state = await send({ type: 'getState' });
  const { rulesOverride } = await chrome.storage.local.get('rulesOverride');
  const stories = (state && state.stories) || [];

  $('#source').innerHTML = rulesOverride
    ? `<span class="pill override">saved override</span><span class="note">Running rules loaded in-browser. <b>Clear</b> (Advanced) reverts to the packaged file.</span>`
    : `<span class="pill gen">from stories.json</span><span class="note">Using the packaged <code>rules.json</code>.</span>`;

  const handle = await RB.getHandle();
  $('#fileMeta').textContent = handle
    ? `Remembered file: ${handle.name} — one click re-syncs it.`
    : 'No file remembered yet — first click asks you to pick stories.json.';

  $('#storiesHdr').textContent = `Stories loaded (${stories.length})`;
  $('#stories').innerHTML = stories
    .map(
      (s) => `<div class="story">
        <span class="dot" style="background:${RB.COLOR_HEX[s.color] || '#888'}"></span>
        <div class="s-main">
          <div class="s-title">${s.title}</div>
          <div class="s-sub">${s.storyTitle || ''}</div>
          <div class="s-meta">
            ${(s.match || []).map((m) => `<span class="tag" title="auto-routes tabs whose URL contains this">${m}</span>`).join('')}
            ${(s.repos || []).map((r) => `<span class="tag" title="GitHub repo">${r}</span>`).join('')}
          </div>
        </div>
      </div>`
    )
    .join('');

  if (rulesOverride) $('#rules').value = JSON.stringify(rulesOverride, null, 2);
}

$('#save').onclick = async () => {
  try {
    const r = JSON.parse($('#rules').value);
    if (!Array.isArray(r.stories)) throw new Error('missing "stories" array');
    await send({ type: 'saveRulesOverride', rules: r });
    $('#msg').textContent = 'Saved ✓';
    render();
  } catch (e) {
    $('#msg').textContent = 'Invalid JSON: ' + e.message;
  }
};

$('#clear').onclick = async () => {
  await send({ type: 'clearRulesOverride' });
  $('#rules').value = '';
  $('#msg').textContent = 'Cleared ✓';
  render();
};

// Worktree paths & branch format — root / worktreeRoot / workspaceRoot / branchFormat, persisted
// by the native host next to itself (survives even if the Options page's own chrome.storage were
// ever cleared) - see stg-paths.psm1 for the single resolver both this page and every tools\*.ps1
// script read through.
async function renderConfig() {
  let res;
  try { res = await send({ type: 'getStgConfig' }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    $('#cfgMsg').textContent = (res && res.nativeHostMissing)
      ? 'native host unreachable — install it first (see native-host/README.md)'
      : 'Error: ' + ((res && res.error) || 'could not read settings');
    return res;
  }
  $('#cfgRoot').value = res.root || '';
  $('#cfgRoot').placeholder = res.effectiveRoot || 'C:\\...\\Ganesha';
  $('#cfgWorktreeRoot').value = res.worktreeRoot || '';
  $('#cfgWorktreeRoot').placeholder = res.worktreeRoot ? 'same as Story root' : `currently: ${res.effectiveWorktreeRoot || ''}`;
  $('#cfgWorkspaceRoot').value = res.workspaceRoot || '';
  $('#cfgWorkspaceRoot').placeholder = res.workspaceRoot ? 'auto' : `currently: ${res.effectiveWorkspaceRoot || ''}`;
  $('#cfgBranchFormat').value = res.branchFormat || '';
  $('#cfgBranchFormat').placeholder = res.effectiveBranchFormat || 'feature/{env}/{key}';
  $('#cfgMsg').textContent = '';

  // Organization settings share the same getConfig reply - one round trip for both cards.
  $('#orgJira').value = res.jiraBaseUrl || '';
  $('#orgJira').placeholder = res.effectiveJiraBaseUrl || 'https://your-org.atlassian.net';
  $('#orgGithub').value = res.githubOrg || '';
  $('#orgGithub').placeholder = res.effectiveGithubOrg || 'your-github-org';
  $('#orgTaskPrefix').value = res.taskNamePrefix || '';
  $('#orgTaskPrefix').placeholder = 'Ganesha EOD status reminder';
  $('#orgOwner').value = res.owner || '';
  $('#orgOwner').placeholder = 'your Windows username';
  $('#orgRepoAliases').value = (res.repoAliases && Object.keys(res.repoAliases).length) ? JSON.stringify(res.repoAliases) : '';
  $('#orgRepoAliases').placeholder = '{"ganesha-iu-internal-app":"ganesha-ui-internal-app"}';
  $('#orgMsg').textContent = '';

  return res;
}

$('#cfgSave').onclick = async () => {
  $('#cfgMsg').textContent = 'Saving…';
  const res = await send({
    type: 'setStgConfig',
    root: $('#cfgRoot').value.trim(),
    worktreeRoot: $('#cfgWorktreeRoot').value.trim(),
    workspaceRoot: $('#cfgWorkspaceRoot').value.trim(),
    branchFormat: $('#cfgBranchFormat').value.trim(),
  });
  if (res && res.ok) {
    $('#cfgMsg').textContent = 'Saved ✓';
    renderConfig();
    renderDiagnostics();
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    $('#cfgMsg').textContent = 'Error: ' + ((res && res.error) || 'unknown') + hint;
  }
};

$('#orgSave').onclick = async () => {
  $('#orgMsg').textContent = 'Saving…';
  let repoAliases;
  const raw = $('#orgRepoAliases').value.trim();
  if (raw) {
    try { repoAliases = JSON.parse(raw); } catch (e) {
      $('#orgMsg').textContent = 'Invalid JSON in repo aliases: ' + e.message;
      return;
    }
  } else {
    repoAliases = '';
  }
  const res = await send({
    type: 'setStgConfig',
    jiraBaseUrl: $('#orgJira').value.trim(),
    githubOrg: $('#orgGithub').value.trim(),
    taskNamePrefix: $('#orgTaskPrefix').value.trim(),
    owner: $('#orgOwner').value.trim(),
    repoAliases,
  });
  if (res && res.ok) {
    $('#orgMsg').textContent = 'Saved ✓';
    renderConfig();
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    $('#orgMsg').textContent = 'Error: ' + ((res && res.error) || 'unknown') + hint;
  }
};

// Paths & diagnostics — every path the host resolves to right now, plus a preflight re-check
// (git / code / required scripts / stories.json readable / app-map.json) so a misconfiguration
// shows itself here instead of as an empty popup or a "returned no JSON" error somewhere else.
function diagRow(name, val, ok, src, fix) {
  const statIcon = ok === null ? '' : ok ? '<span class="ok-y">✓</span>' : '<span class="ok-n">✕</span>';
  const srcHtml = src ? `<span class="src">(${esc(src)})</span>` : '';
  // The fix only renders for a row that actually failed - a passing/unknown row never needed one.
  const fixHtml = (ok === false && fix) ? `<span class="fixtext">→ ${esc(fix)}</span>` : '';
  return `<tr><td class="name">${esc(name)}</td><td class="stat">${statIcon}</td><td class="val">${esc(val || '—')}${srcHtml}${fixHtml}</td></tr>`;
}
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

async function renderDiagnostics() {
  $('#diagMsg').textContent = 'Checking…';
  const cfg = await send({ type: 'getStgConfig' });
  const rows = [];
  if (!cfg || !cfg.ok) {
    rows.push(diagRow('Root', null, false, null));
    $('#diagTable').innerHTML = `<tbody>${diagRow('Native host', (cfg && cfg.error) || 'unreachable', false, null)}</tbody>`;
    $('#diagMsg').textContent = cfg && cfg.nativeHostMissing ? 'native host unreachable' : ((cfg && cfg.error) || 'error');
    return;
  }
  rows.push(diagRow('Root', cfg.effectiveRoot, !cfg.needsSetup, cfg.rootSource));
  rows.push(diagRow('Worktree root', cfg.effectiveWorktreeRoot, !cfg.needsSetup, cfg.worktreeRoot ? 'config' : 'same as Root'));
  rows.push(diagRow('Workspace dir', cfg.effectiveWorkspaceRoot, !cfg.needsSetup, cfg.workspaceRoot ? 'config' : 'auto'));
  rows.push(diagRow('Scripts dir (tools\\)', cfg.scriptsDir, true, 'extension folder'));
  rows.push(diagRow('Config file', cfg.configPath, true, '%LOCALAPPDATA%'));

  let pf;
  try { pf = await send({ type: 'runPreflight' }); } catch (e) { pf = { ok: false, error: String(e) }; }
  if (pf && Array.isArray(pf.checks)) {
    for (const c of pf.checks) rows.push(diagRow(c.name, c.detail, c.ok, null, c.fix));
  }
  $('#diagTable').innerHTML = `<tbody>${rows.join('')}</tbody>`;
  $('#diagMsg').textContent = (pf && pf.ok) || (!pf) ? '' : 'some checks failed — the fix for each is shown under it above';
}
$('#diagRecheck').onclick = renderDiagnostics;

// ---------- Apps ----------
// A repo cloned at the story root (from getApps' disk scan), or one the user mapped without
// cloning it. appsMap/appsHidden are the in-memory staged edits; Save commits them in one round
// trip (setAppMap + setStgConfig hiddenApps), same "type into fields, hit Save" pattern as every
// other card here. Hide/Unhide/+Add/Remove mutate state and re-render locally (paintApps) rather
// than re-fetching, so they never discard another row's in-progress, unsaved edit.
let appsRows = [];          // raw getApps() rows: {app, repo, origin, onDisk, mapped, used, def, hidden}
let appsMap = {};           // name -> {port, start, health} - the full desired app-map.json contents
let appsHidden = new Set(); // names currently hidden from the +New story checklist

// Reads every row's live input values back into appsMap before any structural re-render, so a
// Hide/Add/Remove click on ONE row never discards an unsaved edit typed into a DIFFERENT row.
function syncAppFieldsFromDom() {
  document.querySelectorAll('#appsList .approw[data-app]').forEach((row) => {
    const app = row.dataset.app;
    const port = (row.querySelector('.f-port') || {}).value?.trim() || '';
    const start = (row.querySelector('.f-start') || {}).value?.trim() || '';
    const health = (row.querySelector('.f-health') || {}).value?.trim() || '';
    if (port || start || health) appsMap[app] = { port, start, health };
    else delete appsMap[app];
  });
}

function paintApps() {
  const el = $('#appsList');
  const names = new Set(appsRows.map((a) => a.app));
  for (const n of Object.keys(appsMap)) names.add(n);
  if (!names.size) { el.innerHTML = '<div class="note">No repos found at your story root, and nothing added below yet.</div>'; return; }
  const sorted = [...names].sort((a, b) => a.localeCompare(b));
  el.innerHTML = sorted.map((name) => {
    const row = appsRows.find((a) => a.app === name);
    const onDisk = !!(row && row.onDisk);
    const hidden = appsHidden.has(name);
    const def = appsMap[name] || {};
    const usedTag = row && row.used ? `<span class="tag">used ${row.used}×</span>` : '';
    return `<div class="approw" data-app="${esc(name)}">
      <div class="approw-head">
        <span class="approw-name">${esc((row && row.repo) || name)}</span>
        ${onDisk ? '<span class="tag">cloned</span>' : '<span class="tag warn">not cloned</span>'}
        ${hidden ? '<span class="tag hidden-flag">hidden</span>' : ''}
        ${usedTag}
      </div>
      <div class="approw-fields">
        <input type="text" class="f-port" placeholder="port" value="${esc(def.port || '')}" />
        <input type="text" class="f-start" placeholder="start command" value="${esc(def.start || '')}" />
        <input type="text" class="f-health" placeholder="health path (/)" value="${esc(def.health || '')}" />
        <div class="approw-actions">
          <button class="ghost btn-xs" data-hide="${esc(name)}">${hidden ? 'Unhide' : 'Hide'}</button>
          ${!onDisk ? `<button class="ghost btn-xs" data-remove="${esc(name)}">Remove</button>` : ''}
        </div>
      </div>
    </div>`;
  }).join('');
}

async function renderApps() {
  const el = $('#appsList');
  let res;
  try { res = await send({ type: 'getApps' }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    el.innerHTML = `<div class="note">Error: ${esc((res && res.error) || 'could not list apps')}${esc(hint)}</div>`;
    return;
  }
  appsRows = Array.isArray(res.apps) ? res.apps : [];
  appsMap = {};
  for (const a of appsRows) { if (a.def) appsMap[a.app] = { port: a.def.port || '', start: a.def.start || '', health: a.def.health || '' }; }
  appsHidden = new Set(appsRows.filter((a) => a.hidden).map((a) => a.app));
  paintApps();
}

document.addEventListener('click', (e) => {
  const hideBtn = e.target.closest('[data-hide]');
  if (hideBtn) {
    syncAppFieldsFromDom();
    const name = hideBtn.dataset.hide;
    if (appsHidden.has(name)) appsHidden.delete(name); else appsHidden.add(name);
    paintApps();
    return;
  }
  const removeBtn = e.target.closest('[data-remove]');
  if (removeBtn) {
    syncAppFieldsFromDom();
    delete appsMap[removeBtn.dataset.remove];
    appsHidden.delete(removeBtn.dataset.remove);
    paintApps();
  }
});

$('#appAddBtn').onclick = () => {
  const name = $('#appNewName').value.trim();
  $('#appsMsg').textContent = '';
  if (!name) { $('#appsMsg').textContent = 'Enter an app name first'; return; }
  if (/[\\/]/.test(name)) { $('#appsMsg').textContent = "App name can't contain \\ or /"; return; }
  const port = $('#appNewPort').value.trim();
  if (port && !/^\d+$/.test(port)) { $('#appsMsg').textContent = 'Port must be a number'; return; }
  syncAppFieldsFromDom();
  appsMap[name] = { port, start: $('#appNewStart').value.trim(), health: $('#appNewHealth').value.trim() };
  ['appNewName', 'appNewPort', 'appNewStart', 'appNewHealth'].forEach((id) => { $('#' + id).value = ''; });
  paintApps();
};

$('#appsSave').onclick = async () => {
  syncAppFieldsFromDom();
  // Same numeric check the +Add mini-form does, but for every row's (possibly hand-edited) port
  // field - client-side, so a typo shows up here instead of round-tripping to the host's own
  // TryParse guard for an "invalid port for X" error.
  for (const [name, def] of Object.entries(appsMap)) {
    if (def.port && !/^\d+$/.test(def.port)) { $('#appsMsg').textContent = `Port for ${name} must be a number`; return; }
  }
  $('#appsMsg').textContent = 'Saving…';
  const payload = {};
  for (const [name, def] of Object.entries(appsMap)) {
    const entry = {};
    if (def.port) entry.port = def.port;
    if (def.start) entry.start = def.start;
    if (def.health) entry.health = def.health;
    payload[name] = entry;
  }
  const mapRes = await send({ type: 'setAppMap', apps: payload });
  if (!mapRes || !mapRes.ok) {
    const hint = mapRes && mapRes.nativeHostMissing ? ' — native host unreachable' : '';
    $('#appsMsg').textContent = 'Error: ' + ((mapRes && mapRes.error) || 'unknown') + hint;
    return;
  }
  // hiddenApps is a separate config key (setStgConfig), sent alongside on the same Save click -
  // one user action, one commit of everything staged in this card.
  const hideRes = await send({ type: 'setStgConfig', hiddenApps: [...appsHidden] });
  if (!hideRes || !hideRes.ok) {
    const hint = hideRes && hideRes.nativeHostMissing ? ' — native host unreachable' : '';
    $('#appsMsg').textContent = 'Saved apps, but hidden list failed: ' + ((hideRes && hideRes.error) || 'unknown') + hint;
    return;
  }
  $('#appsMsg').textContent = 'Saved ✓';
  await renderApps();
};

console.log('[stg-opt] options build: v3 (Apps card: Hide/Remove sit inline with the port/start/health row; the +Add row now sits flush against the Save button below it, no gap)');

render();
renderConfig();
renderDiagnostics();
renderApps();
