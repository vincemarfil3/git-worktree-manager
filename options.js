const $ = (s) => document.querySelector(s);
const send = (m) => new Promise((r) => chrome.runtime.sendMessage(m, r));

// Every "Saved ✓" / "Error: ..." message span on this page used to render as identical grey text
// (the .note class, no success/error distinction at all) - this is the shared setter that colors
// them via the .note.ok / .note.err CSS added for the visual redesign. Purely a display concern:
// it doesn't change what any handler decides to do, only how the same already-computed text shows.
function setMsg(el, text, kind) {
  if (!el) return;
  el.textContent = text || '';
  el.classList.remove('ok', 'err');
  if (kind === 'ok') el.classList.add('ok');
  else if (kind === 'err') el.classList.add('err');
}

// ---------- Projects ----------
// "Worktree paths & branch format", "Organization settings" and "Apps" below all read/write the
// ACTIVE project (ACTIVE_PROJECT, set from loadProjectsCard()'s getProjects reply) - the same
// project the popup itself shows/acts on. An earlier version had an independent "Editing settings
// for" <select> here, decoupled from active, so you could edit a project without switching to it -
// removed at the user's request after live-testing it alongside the popup's own now-removed
// dropdown: two different notions of "which project" on one page (one here, one everywhere else)
// tested as confusing, the same reason popup.js's #projSel became a plain label. To edit a
// different project now, Set active it on the Projects card first - #settingsProjLabel (read-only)
// just names whichever one that currently is. ACTIVE_PROJECT null means "no project context" -
// either a fresh install with zero projects configured yet, or every project having been removed -
// in which case these three cards fall back to the pre-multi-project getStgConfig/setStgConfig/
// getApps path exactly as before this feature existed (see renderConfig/renderApps/the Save
// handlers below).
let PROJECTS_ROWS = [];

function paintProjectsCard() {
  const el = $('#projectsList');
  if (!PROJECTS_ROWS.length) {
    el.innerHTML = '<div class="note">No projects configured yet — add one below, or run <code>setup.ps1</code> from the extension folder.</div>';
    return;
  }
  el.innerHTML = PROJECTS_ROWS.map((p) => {
    const isActive = p.id === ACTIVE_PROJECT;
    const modeTag = `<span class="tag">${esc(p.mode || 'worktree')}</span>`;
    const activeTag = isActive ? '<span class="tag active-flag">★ active</span>' : '';
    const warnTag = p.needsSetup ? `<span class="tag warn" title="${esc(p.error || '')}">needs setup</span>` : '';
    return `<div class="approw" data-projid="${esc(p.id)}">
      <div class="approw-head">
        <span class="approw-name">${esc(p.name || p.id)}</span>
        ${modeTag}${activeTag}${warnTag}
      </div>
      <div class="approw-fields">
        <input type="text" class="f-start" data-projname-input value="${esc(p.name || '')}" placeholder="project name" />
        <span class="note" style="flex:1; word-break:break-all">${esc(p.root || '')}</span>
        <div class="approw-actions">
          ${!isActive ? `<button class="ghost btn-xs" data-setactive="${esc(p.id)}">Set active</button>` : ''}
          <button class="ghost btn-xs" data-renameproj="${esc(p.id)}">Rename</button>
          <button class="danger btn-xs" data-removeproj="${esc(p.id)}">Remove</button>
        </div>
      </div>
    </div>`;
  }).join('');
}

let ACTIVE_PROJECT = null;

function paintSettingsProjLabel() {
  const label = $('#settingsProjLabel');
  const row = $('#settingsProjRow');
  if (!PROJECTS_ROWS.length) { row.hidden = true; return; }
  row.hidden = false;
  const cur = PROJECTS_ROWS.find((p) => p.id === ACTIVE_PROJECT);
  label.textContent = cur ? (cur.name || cur.id) : '(unknown project)';
}

async function loadProjectsCard() {
  let res;
  try { res = await send({ type: 'getProjects' }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    $('#projectsList').innerHTML = `<div class="note">Error: ${esc((res && res.error) || 'could not list projects')}</div>`;
    return;
  }
  PROJECTS_ROWS = Array.isArray(res.projects) ? res.projects : [];
  ACTIVE_PROJECT = res.activeProject || null;
  paintProjectsCard();
  paintSettingsProjLabel();
}

// Switching the active project invalidates everything the three per-project cards below are
// showing (they now edit whichever project IS active) - refresh all of them together, same
// "full re-fetch on switch" reasoning popup.js's own active-project handling uses.
async function refreshProjectScopedCards() {
  await Promise.all([renderConfig(), renderApps(), renderAgentCard()]);
}

document.addEventListener('click', async (e) => {
  const setActiveBtn = e.target.closest('[data-setactive]');
  if (setActiveBtn) {
    setMsg($('#projectsMsg'), 'Switching…');
    const res = await send({ type: 'setStgConfig', activeProject: setActiveBtn.dataset.setactive });
    setMsg($('#projectsMsg'), (res && res.ok) ? 'Active project switched ✓' : ('Error: ' + ((res && res.error) || 'unknown')), (res && res.ok) ? 'ok' : 'err');
    await loadProjectsCard();
    await refreshProjectScopedCards(); // Worktree paths/Org settings/Apps now edit the NEW active project
    await renderDiagnostics(); // Paths & diagnostics stays scoped to the ACTIVE project too
    return;
  }
  const renameBtn = e.target.closest('[data-renameproj]');
  if (renameBtn) {
    const row = renameBtn.closest('.approw');
    const nameInput = row.querySelector('[data-projname-input]');
    const newName = (nameInput.value || '').trim();
    if (!newName) { setMsg($('#projectsMsg'), 'Project name cannot be blank', 'err'); return; }
    setMsg($('#projectsMsg'), 'Saving…');
    const res = await send({ type: 'setProjectConfig', id: renameBtn.dataset.renameproj, name: newName });
    setMsg($('#projectsMsg'), (res && res.ok) ? 'Renamed ✓' : ('Error: ' + ((res && res.error) || 'unknown')), (res && res.ok) ? 'ok' : 'err');
    await loadProjectsCard();
    return;
  }
  const removeBtn = e.target.closest('[data-removeproj]');
  if (removeBtn) {
    const id = removeBtn.dataset.removeproj;
    const proj = PROJECTS_ROWS.find((p) => p.id === id);
    if (!confirm(`Remove "${(proj && proj.name) || id}" from this extension? stories.json, worktrees and the repo itself are never touched — this only forgets the extension's reference to it.`)) return;
    setMsg($('#projectsMsg'), 'Removing…');
    const res = await send({ type: 'removeProject', id });
    setMsg($('#projectsMsg'), (res && res.ok) ? 'Removed ✓' : ('Error: ' + ((res && res.error) || 'unknown')), (res && res.ok) ? 'ok' : 'err');
    await loadProjectsCard();
    await refreshProjectScopedCards();
    await renderDiagnostics();
    return;
  }
});

$('#projAddBtn').onclick = async () => {
  const name = $('#projNewName').value.trim();
  const root = $('#projNewRoot').value.trim();
  const mode = $('#projNewMode').value || 'worktree';
  setMsg($('#projectsMsg'), '');
  if (!name) { setMsg($('#projectsMsg'), 'Enter a project name first', 'err'); return; }
  if (!root) { setMsg($('#projectsMsg'), 'Enter a root folder first', 'err'); return; }
  setMsg($('#projectsMsg'), 'Adding…');
  const res = await send({ type: 'addProject', name, root, mode });
  if (res && res.ok) {
    $('#projNewName').value = '';
    $('#projNewRoot').value = '';
    $('#projNewMode').value = 'worktree';
    setMsg($('#projectsMsg'), 'Added ✓', 'ok');
    await loadProjectsCard();
    await refreshProjectScopedCards();
    await renderDiagnostics();
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#projectsMsg'), 'Error: ' + ((res && res.error) || 'unknown') + hint, 'err');
  }
};

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

// Shared by every "copy to clipboard" button on this page - the Native host card's fix command,
// and the Agent integration card's AGENTS.md snippet / Copy instructions buttons below. A second
// and third consumer arriving in the same phase is exactly the point where copy-pasting this a
// second time stops being the cheaper option.
async function copyText(text, msgEl) {
  try {
    await navigator.clipboard.writeText(text);
    setMsg(msgEl, 'Copied ✓', 'ok');
    setTimeout(() => { setMsg(msgEl, ''); }, 1600);
  } catch (e) {
    setMsg(msgEl, 'Copy failed — select the text and copy manually', 'err');
  }
}
$('#hostCopyBtn').onclick = () => copyText($('#hostCmd').textContent, $('#hostCopyMsg'));

// ---------- Agent integration ----------
// Renders (installskill install:false) to show devCycleDetected + the current project name -
// read-only, no write, safe to call on every card refresh (project switch, page load). Installing
// (install:true) is a deliberate button click only.
async function renderAgentCard() {
  const cur = PROJECTS_ROWS.find((p) => p.id === ACTIVE_PROJECT);
  $('#agentProjLabel').textContent = cur ? (cur.name || cur.id) : '(no project configured)';
  $('#agentInstallStatus').textContent = '';
  $('#agentDevCycleStatus').textContent = '';
  if (!ACTIVE_PROJECT) return;
  let res;
  try { res = await send({ type: 'installSkill', install: false }); } catch (e) { res = null; }
  if (!res || !res.ok) {
    $('#agentDevCycleStatus').textContent = (res && res.error) ? `Could not check dev-cycle: ${res.error}` : '';
    return;
  }
  if (res.devCycleDetected) {
    $('#agentDevCycleStatus').innerHTML = '<b>dev-cycle harness: found</b> — the skill will mirror its phase transitions into the ledger, best-effort.';
  } else {
    $('#agentDevCycleStatus').innerHTML = '<b>dev-cycle harness: not found</b> — nothing to mirror. '
      + '<span class="src">Run the dev-cycle skill here to bootstrap it, if you want that too.</span>';
  }
}

$('#agentInstallBtn').onclick = async () => {
  const scope = $('#agentScope').value;
  setMsg($('#agentInstallStatus'), 'Installing…');
  let res;
  try { res = await send({ type: 'installSkill', install: true, scope }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (res && res.ok) {
    $('#agentInstallStatus').innerHTML = `<span class="pill gen">✓ installed</span> <span class="note">${esc(res.path || '')}</span>`;
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#agentInstallStatus'), 'Error: ' + ((res && res.error) || 'unknown') + hint, 'err');
  }
  // Same reply also carries devCycleDetected - no separate round trip needed to refresh that line.
  if (res && res.ok) {
    $('#agentDevCycleStatus').innerHTML = res.devCycleDetected
      ? '<b>dev-cycle harness: found</b> — the skill will mirror its phase transitions into the ledger, best-effort.'
      : '<b>dev-cycle harness: not found</b> — nothing to mirror. <span class="src">Run the dev-cycle skill here to bootstrap it, if you want that too.</span>';
  }
};

async function copyRenderedSkill(msgEl) {
  setMsg(msgEl, 'Rendering…');
  let res;
  try { res = await send({ type: 'installSkill', install: false }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    setMsg(msgEl, 'Error: ' + ((res && res.error) || 'unknown'), 'err');
    return;
  }
  await copyText(res.content, msgEl);
}
$('#agentCopyAgentsBtn').onclick = () => copyRenderedSkill($('#agentCopyMsg'));
$('#agentCopyInstructionsBtn').onclick = () => copyRenderedSkill($('#agentCopyMsg'));

// ---------- Optional skills (generic - not bound to the active project) ----------
// Same installSkill message/installskill host action as the Agent integration card above, just
// with an explicit msg.skill naming a generic skill (nextjs-project-architecture and
// shadcn-from-mantine today; add more <option>s here as more ship in skills\) instead of riding
// the default ('story-tab-groups'). No
// render-first step needed here the way the card above has one (that one shows devCycleDetected
// before you commit to installing) - a generic skill has no per-project content to preview, so
// there's nothing that render would show you that the skill's own description doesn't already.
$('#extraSkillInstallBtn').onclick = async () => {
  const skill = $('#extraSkillSelect').value;
  const scope = $('#extraSkillScope').value;
  setMsg($('#extraSkillStatus'), 'Installing…');
  let res;
  try { res = await send({ type: 'installSkill', install: true, scope, skill }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (res && res.ok) {
    $('#extraSkillStatus').innerHTML = `<span class="pill gen">✓ installed</span> <span class="note">${esc(res.path || '')}</span>`;
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#extraSkillStatus'), 'Error: ' + ((res && res.error) || 'unknown') + hint, 'err');
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
  setMsg($('#loadMsg'), '');
  if (!window.showOpenFilePicker) {
    setMsg($('#loadMsg'), 'Your Chrome is too old for the file picker — use the paste-a-rules.json box below instead.', 'err');
    return;
  }
  try {
    const res = await RB.sync(); // picks if needed; safe here (the Options page survives the dialog)
    setMsg($('#loadMsg'), `Loaded ${res.count} stories ✓`, 'ok');
    render();
  } catch (e) {
    if (e.name !== 'AbortError') setMsg($('#loadMsg'), 'Error: ' + e.message, 'err');
  }
};

async function render() {
  const state = await send({ type: 'getState' });
  // rulesOverrides (plural, keyed by project id) - not the legacy flat 'rulesOverride' key, which
  // nothing has written since background.js moved to the per-project map (P4.8). Reading the old
  // key meant this pill always said "from stories.json" regardless of whether a real override was
  // active for the current project.
  const { rulesOverrides = {} } = await chrome.storage.local.get('rulesOverrides');
  const rulesOverride = rulesOverrides[ACTIVE_PROJECT];
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
    setMsg($('#msg'), 'Saved ✓', 'ok');
    render();
  } catch (e) {
    setMsg($('#msg'), 'Invalid JSON: ' + e.message, 'err');
  }
};

$('#clear').onclick = async () => {
  await send({ type: 'clearRulesOverride' });
  $('#rules').value = '';
  setMsg($('#msg'), 'Cleared ✓', 'ok');
  render();
};

// Worktree paths & branch format — root / worktreeRoot / workspaceRoot / branchFormat, persisted
// by the native host next to itself (survives even if the Options page's own chrome.storage were
// ever cleared) - see stg-paths.psm1 for the single resolver both this page and every tools\*.ps1
// script read through. Organization settings share this same reply/round trip.
//
// Project-scoped via getProjectConfig once ACTIVE_PROJECT is set (the normal case - P1's
// migration always synthesizes a project once a root exists) - reads THE ACTIVE project's own
// fields directly by id, rather than relying on getStgConfig's top-level mirror, so a Save here
// can never race a mirror that's mid-refresh from a just-fired Set active click. Falls back to the
// legacy getStgConfig only when there's genuinely no project context at all (zero projects
// configured, e.g. a fresh install or every project removed) - same fallback Resolve-StgPaths
// itself uses server-side.
async function renderConfig() {
  let res;
  try {
    res = ACTIVE_PROJECT
      ? await send({ type: 'getProjectConfig', id: ACTIVE_PROJECT })
      : await send({ type: 'getStgConfig' });
  } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    setMsg($('#cfgMsg'), (res && res.nativeHostMissing)
      ? 'native host unreachable — install it first (see native-host/README.md)'
      : 'Error: ' + ((res && res.error) || 'could not read settings'), 'err');
    return res;
  }
  $('#cfgRoot').value = res.root || '';
  $('#cfgRoot').placeholder = res.effectiveRoot || 'C:\\...\\Ganesha';
  $('#cfgWorktreeRoot').value = res.worktreeRoot || '';
  $('#cfgWorktreeRoot').placeholder = res.worktreeRoot ? 'same as Story root' : `currently: ${res.effectiveWorktreeRoot || ''}`;
  $('#cfgWorkspaceRoot').value = res.workspaceRoot || '';
  $('#cfgWorkspaceRoot').placeholder = res.workspaceRoot ? 'auto' : `currently: ${res.effectiveWorkspaceRoot || ''}`;
  $('#cfgReposRoot').value = res.reposRoot || '';
  $('#cfgReposRoot').placeholder = res.reposRoot ? 'same as Story root' : `currently: ${res.effectiveReposRoot || ''}`;
  $('#cfgBranchFormat').value = res.branchFormat || '';
  $('#cfgBranchFormat').placeholder = res.effectiveBranchFormat || 'feature/{env}/{key}';
  setMsg($('#cfgMsg'), '');

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
  setMsg($('#orgMsg'), '');

  return res;
}

$('#cfgSave').onclick = async () => {
  setMsg($('#cfgMsg'), 'Saving…');
  const fields = {
    root: $('#cfgRoot').value.trim(),
    worktreeRoot: $('#cfgWorktreeRoot').value.trim(),
    workspaceRoot: $('#cfgWorkspaceRoot').value.trim(),
    reposRoot: $('#cfgReposRoot').value.trim(),
    branchFormat: $('#cfgBranchFormat').value.trim(),
  };
  const res = ACTIVE_PROJECT
    ? await send({ type: 'setProjectConfig', id: ACTIVE_PROJECT, ...fields })
    : await send({ type: 'setStgConfig', ...fields });
  if (res && res.ok) {
    setMsg($('#cfgMsg'), 'Saved ✓', 'ok');
    // refreshProjectScopedCards(), not just renderConfig() - a changed Root used to leave the Apps
    // card listing the OLD root's clones until something else happened to repaint it. Root's own
    // 'config' vs 'same as Root' source label above also depends on this, so cfgSave and Root
    // changing are the same event either way.
    await refreshProjectScopedCards();
    await renderDiagnostics();
    await loadProjectsCard(); // root may have changed - the Projects card's own row shows it too
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#cfgMsg'), 'Error: ' + ((res && res.error) || 'unknown') + hint, 'err');
  }
};

$('#orgSave').onclick = async () => {
  setMsg($('#orgMsg'), 'Saving…');
  let repoAliases;
  const raw = $('#orgRepoAliases').value.trim();
  if (raw) {
    try { repoAliases = JSON.parse(raw); } catch (e) {
      setMsg($('#orgMsg'), 'Invalid JSON in repo aliases: ' + e.message, 'err');
      return;
    }
  } else {
    repoAliases = '';
  }
  const fields = {
    jiraBaseUrl: $('#orgJira').value.trim(),
    githubOrg: $('#orgGithub').value.trim(),
    taskNamePrefix: $('#orgTaskPrefix').value.trim(),
    owner: $('#orgOwner').value.trim(),
    repoAliases,
  };
  const res = ACTIVE_PROJECT
    ? await send({ type: 'setProjectConfig', id: ACTIVE_PROJECT, ...fields })
    : await send({ type: 'setStgConfig', ...fields });
  if (res && res.ok) {
    setMsg($('#orgMsg'), 'Saved ✓', 'ok');
    renderConfig();
  } else {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#orgMsg'), 'Error: ' + ((res && res.error) || 'unknown') + hint, 'err');
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

function diagRollup(ok, problems, projName) {
  const el = $('#diagRollup');
  if (!el) return;
  if (ok) {
    el.innerHTML = `<span class="ok-y">✓</span> ${esc(projName || '')} · all checks passed`;
  } else {
    const list = problems.slice(0, 3).join(', ') + (problems.length > 3 ? `, +${problems.length - 3} more` : '');
    el.innerHTML = `<span class="ok-n">✕</span> ${esc(projName || '')} · ${problems.length} problem${problems.length === 1 ? '' : 's'}: ${esc(list)}`;
  }
}

async function renderDiagnostics() {
  setMsg($('#diagMsg'), 'Checking…');
  const cur = PROJECTS_ROWS.find((p) => p.id === ACTIVE_PROJECT);
  const projName = cur ? (cur.name || cur.id) : '';
  const cfg = await send({ type: 'getStgConfig' });
  const rows = [];
  if (!cfg || !cfg.ok) {
    $('#diagTable').innerHTML = `<tbody>${diagRow('Native host', (cfg && cfg.error) || 'unreachable', false, null)}</tbody>`;
    const msg = cfg && cfg.nativeHostMissing ? 'native host unreachable' : ((cfg && cfg.error) || 'error');
    setMsg($('#diagMsg'), msg, 'err');
    diagRollup(false, [msg], projName);
    $('#diagDetails').open = true;
    return;
  }
  rows.push(diagRow('Root', cfg.effectiveRoot, !cfg.needsSetup, cfg.rootSource));
  rows.push(diagRow('Scripts dir (tools\\)', cfg.scriptsDir, true, 'extension folder'));
  rows.push(diagRow('Config file', cfg.configPath, true, '%LOCALAPPDATA%'));

  let pf;
  try { pf = await send({ type: 'runPreflight' }); } catch (e) { pf = { ok: false, error: String(e) }; }

  if (pf && Array.isArray(pf.checks)) {
    // Worktree root / workspace dir now have a REAL existence check behind them (host.ps1's
    // preflight action) instead of the old '!cfg.needsSetup' proxy, which reflected whether Root
    // was configured, not whether these specific paths actually exist. Pulled out of the generic
    // loop below so they render right after Root, in the position they've always had, with the
    // path itself as the value and 'config'/'auto' still shown as their source - the generic loop
    // skips these two by name so they don't render twice. Absent entirely for a tracking-mode
    // project (host.ps1 only emits them for worktree mode, since both paths are null there by
    // design) - nothing to show, not a failed check.
    const wtCheck = pf.checks.find((c) => c.name === 'Worktree root exists');
    if (wtCheck) rows.push(diagRow('Worktree root', wtCheck.detail, wtCheck.ok, cfg.worktreeRoot ? 'config' : 'same as Root', wtCheck.fix));
    const wsCheck = pf.checks.find((c) => c.name === 'Workspace dir exists');
    if (wsCheck) rows.push(diagRow('Workspace dir', wsCheck.detail, wsCheck.ok, cfg.workspaceRoot ? 'config' : 'auto', wsCheck.fix));
    for (const c of pf.checks) {
      if (c.name === 'Worktree root exists' || c.name === 'Workspace dir exists') continue;
      rows.push(diagRow(c.name, c.detail, c.ok, null, c.fix));
    }
  }
  $('#diagTable').innerHTML = `<tbody>${rows.join('')}</tbody>`;

  // Same two checks host.ps1's own preflight action treats as optional (code CLI / app-map.json) -
  // the roll-up must agree, or a machine with no VS Code CLI installed would show a permanent,
  // misleading ✕ every time.
  const OPTIONAL = new Set(['code (VS Code CLI) on PATH', 'app-map.json']);
  if (!pf || !Array.isArray(pf.checks) || !pf.checks.length) {
    const msg = (pf && pf.error) || 'preflight did not return any checks';
    setMsg($('#diagMsg'), msg, 'err');
    diagRollup(false, [msg], projName);
    $('#diagDetails').open = true;
  } else {
    const failed = pf.checks.filter((c) => !c.ok && !OPTIONAL.has(c.name));
    if (failed.length) {
      setMsg($('#diagMsg'), 'some checks failed — the fix for each is shown under it above', 'err');
      diagRollup(false, failed.map((c) => c.name), projName);
      $('#diagDetails').open = true;
    } else {
      setMsg($('#diagMsg'), '');
      diagRollup(true, [], projName);
      // Deliberately does NOT force-collapse an already-open details on a clean re-check - only
      // the initial "everything's fine" render should default to collapsed; a user who opened it
      // themselves to look something up shouldn't have it yanked shut under them by Re-run preflight.
    }
  }
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
  // project: ACTIVE_PROJECT - a repo scan + app-map read is per-project (see host.ps1's 'apps'
  // action, which resolves $GRoot/$PathsInfo.AppMapPath from whichever project msg.project names).
  // null/undefined here means "no project context" and the host falls back to whatever
  // Resolve-StgPaths' legacy chain resolves, same as every other project-scoped call in this file.
  try { res = await send({ type: 'getApps', project: ACTIVE_PROJECT }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || !res.ok) {
    const hint = res && res.nativeHostMissing ? ' — native host unreachable' : '';
    el.innerHTML = `<div class="note">Error: ${esc((res && res.error) || 'could not list apps')}${esc(hint)}</div>`;
    return;
  }
  // Tracking mode has no app/worktree concept at all - host.ps1's 'apps' action already
  // short-circuits before its disk scan and says so via mode:'tracking'. Show that plainly rather
  // than an empty checklist that looks like "nothing found" instead of "not applicable here".
  if (res.mode === 'tracking') {
    el.innerHTML = '<div class="note">This project is in <b>tracking</b> mode - no worktrees or apps to map. (Apps only applies to worktree-mode projects.)</div>';
    appsRows = []; appsMap = {}; appsHidden = new Set();
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
  setMsg($('#appsMsg'), '');
  if (!name) { setMsg($('#appsMsg'), 'Enter an app name first', 'err'); return; }
  if (/[\\/]/.test(name)) { setMsg($('#appsMsg'), "App name can't contain \\ or /", 'err'); return; }
  const port = $('#appNewPort').value.trim();
  if (port && !/^\d+$/.test(port)) { setMsg($('#appsMsg'), 'Port must be a number', 'err'); return; }
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
    if (def.port && !/^\d+$/.test(def.port)) { setMsg($('#appsMsg'), `Port for ${name} must be a number`, 'err'); return; }
  }
  setMsg($('#appsMsg'), 'Saving…');
  const payload = {};
  for (const [name, def] of Object.entries(appsMap)) {
    const entry = {};
    if (def.port) entry.port = def.port;
    if (def.start) entry.start = def.start;
    if (def.health) entry.health = def.health;
    payload[name] = entry;
  }
  const mapRes = await send({ type: 'setAppMap', project: ACTIVE_PROJECT, apps: payload });
  if (!mapRes || !mapRes.ok) {
    const hint = mapRes && mapRes.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#appsMsg'), 'Error: ' + ((mapRes && mapRes.error) || 'unknown') + hint, 'err');
    return;
  }
  // hiddenApps is a separate config key, sent alongside on the same Save click - one user action,
  // one commit of everything staged in this card. Project-scoped via setProjectConfig the same way
  // the two cards above are; falls back to the legacy setStgConfig only with no project context.
  const hideRes = ACTIVE_PROJECT
    ? await send({ type: 'setProjectConfig', id: ACTIVE_PROJECT, hiddenApps: [...appsHidden] })
    : await send({ type: 'setStgConfig', hiddenApps: [...appsHidden] });
  if (!hideRes || !hideRes.ok) {
    const hint = hideRes && hideRes.nativeHostMissing ? ' — native host unreachable' : '';
    setMsg($('#appsMsg'), 'Saved apps, but hidden list failed: ' + ((hideRes && hideRes.error) || 'unknown') + hint, 'err');
    return;
  }
  setMsg($('#appsMsg'), 'Saved ✓', 'ok');
  await renderApps();
};

console.log('[stg-opt] options build: v10 (visual redesign: real color tokens (--success/--warn/--danger) replace scattered hex/an unused --green, a real type scale with sentence-case headers instead of the dim ALL-CAPS eyebrow treatment, hover/focus states and styled links added page-wide, Remove/Clear override now read as destructive, a shared setMsg() helper colors every Saved/Error message instead of them all rendering as identical grey text)');

render();
// loadProjectsCard() first and awaited - it's what sets ACTIVE_PROJECT, which renderConfig()/
// renderApps() both need on their very first call to know which project to read.
(async () => {
  await loadProjectsCard();
  await renderDiagnostics(); // also active-project-scoped, same project as everything else now
  await refreshProjectScopedCards();
})();
