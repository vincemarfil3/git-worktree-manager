// Story History viewer — reads stories_history.json (via the native host) and renders the
// archived nodes of removed stories. Opened in a tab from the popup footer.
console.log('[stg-hist] history build: v4 (native-host-missing hint now points to the Help page)');

const $ = (s) => document.querySelector(s);
const send = (msg) => new Promise((r) => chrome.runtime.sendMessage(msg, r));
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const asArr = (x) => (Array.isArray(x) ? x : x ? [x] : []);

let ENTRIES = []; // [{ key, removed_at, apps, removal, node }]
let JIRA_BASE_URL = 'https://vesta.atlassian.net'; // overwritten from Settings before first paint

// Stable per-story color from the key (so the dot matches a story's identity).
function colorFromKey(key) {
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360}, 55%, 60%)`;
}

// Jira browse URL for a REL/SCERN key (project key REL lives in the same Jira instance).
const relUrl = (rel) => `${JIRA_BASE_URL}/browse/${encodeURIComponent(rel)}`;

function sortDesc(list) {
  return list.slice().sort((a, b) => String(b.removed_at || '').localeCompare(String(a.removed_at || '')));
}

function renderCard(e) {
  const node = e.node || {};
  const key = e.key || node.key || '?';
  const title = node.title || '';
  const apps = asArr(e.apps && e.apps.length ? e.apps : node.apps);
  const removal = asArr(e.removal);
  const log = asArr(node.log);

  const appChips = apps.map((a) => {
    const r = removal.find((x) => x && x.app === a);
    const st = r ? r.status : '';
    const cls = st === 'removed' ? 'removed' : st === 'failed' ? 'failed' : st === 'already-absent' ? 'absent' : 'app';
    return `<span class="chip ${cls}" title="${esc(st || 'app')}">${esc(a)}</span>`;
  }).join('');

  const links = [];
  for (const url of asArr(node.jira_stories)) {
    const m = String(url).match(/([A-Za-z]+-\d+)/);
    links.push(`<a href="${esc(url)}" target="_blank" rel="noopener">${esc(m ? m[1] : 'Jira')}</a>`);
  }
  if (node.rel) links.push(`<a href="${esc(relUrl(node.rel))}" target="_blank" rel="noopener">${esc(node.rel)}</a>`);
  if (node.agiletest_url) links.push(`<a href="${esc(node.agiletest_url)}" target="_blank" rel="noopener">AgileTest</a>`);
  // Custom named links (Abstract, Test plan, ...) - a removed story's node is archived whole
  // (remove-worktree.ps1), so anything added via the popup's ✎ editor survives into history too.
  if (node.links && typeof node.links === 'object' && !Array.isArray(node.links)) {
    for (const [label, url] of Object.entries(node.links)) {
      if (url) links.push(`<a href="${esc(url)}" target="_blank" rel="noopener">${esc(label)}</a>`);
    }
  }

  const logHtml = log.map((l) =>
    `<div class="logentry"><span class="lts">${esc(l.ts)}</span><span class="ltype">${esc(l.type)}</span>
       <div class="lmsg">${esc(l.message)}</div></div>`).join('');

  return `<div class="card">
    <div class="card-head">
      <span class="dot" style="background:${colorFromKey(key)}"></span>
      <div style="min-width:0">
        <div class="key-row"><span class="key">${esc(key)}</span><span class="when">removed ${esc(e.removed_at || '—')}</span></div>
        ${title ? `<div class="ctitle">${esc(title)}</div>` : ''}
      </div>
    </div>
    <div class="meta">
      ${node.env ? `<span class="chip env">${esc(node.env)}</span>` : ''}
      ${node.chg_number ? `<span class="chip">${esc(node.chg_number)}</span>` : ''}
      ${node.planned_release_date ? `<span class="chip">release ${esc(node.planned_release_date)}</span>` : ''}
      ${appChips}
    </div>
    ${links.length ? `<div class="links">${links.join('')}</div>` : ''}
    ${log.length ? `<details class="log"><summary>Work log (${log.length})</summary>${logHtml}</details>` : ''}
  </div>`;
}

function paint(filter) {
  const q = (filter || '').trim().toLowerCase();
  let list = sortDesc(ENTRIES);
  if (q) {
    list = list.filter((e) => {
      const n = e.node || {};
      const hay = [e.key, n.title, n.rel, n.env, n.chg_number].join(' ').toLowerCase();
      return hay.includes(q);
    });
  }
  $('#count').textContent = `${list.length}${q ? ` / ${ENTRIES.length}` : ''} stor${list.length === 1 ? 'y' : 'ies'}`;
  $('#list').innerHTML = list.map(renderCard).join('');
}

async function load() {
  $('#msg').textContent = 'Loading…';
  $('#msg').className = 'msg';
  $('#list').innerHTML = '';

  // Best-effort: pick up the configured Jira base URL before rendering links, so a non-default
  // org's REL links point at the right instance. Falls back to the built-in default silently.
  try {
    const cfg = await send({ type: 'getStgConfig' });
    if (cfg && cfg.ok && cfg.effectiveJiraBaseUrl) JIRA_BASE_URL = cfg.effectiveJiraBaseUrl;
  } catch (_) { /* keep default */ }

  const res = await send({ type: 'getHistory' });
  if (!res || !res.ok) {
    const hint = res && res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help).' : '';
    $('#msg').textContent = `Couldn't read history: ${(res && (res.error || res.message)) || 'unknown error'}${hint}`;
    $('#msg').className = 'msg err';
    return;
  }
  ENTRIES = asArr(res.removed);
  if (!ENTRIES.length) {
    $('#msg').textContent = 'No stories removed yet — the history starts filling once you 🗑 a finished story.';
    $('#msg').className = 'msg';
    return;
  }
  $('#msg').textContent = '';
  paint($('#q').value);
}

$('#q').addEventListener('input', (e) => paint(e.target.value));
$('#reload').addEventListener('click', load);
load();
