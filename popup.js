const $ = (s) => document.querySelector(s);
const send = (msg) => new Promise((r) => chrome.runtime.sendMessage(msg, r));
let STATE;
let STATS = {};
let CHECK = {};         // { KEY: { ok, blockers:[{app,dirty,unpushed,noUpstream}], present } } from remove-worktree.ps1 -CheckAll
let NODES = {};         // { KEY: <stories.json node> } — env / rel / chg / links
let LEDGERS = {};       // { KEY: <.story-ship-state.json> } — phase state
let HEALTH = {};        // { KEY: { loading, lines:[], err } } — on-demand only (⚡)
let selectedKey = null; // highlighted row — what the action buttons act on
let activeKey = '';     // the active story — drives auto-route (persisted setting)
let armedKey = null;    // story whose 🗑 is armed (awaiting an inline ✓ confirm) - ready/unknown stories only
let armedDiscardKey = null; // story whose ♻ (discard generated & remove) is armed
let armedForceKey = null;   // story whose 🗑 is armed for a FORCED removal (blocked by real changes
                             // or unpushed commits, not just generated files) - needs typed CONFIRM,
                             // not just a click, since this discards uncommitted work permanently
let forceConfirmText = '';  // survives across repaint() so an unrelated re-render mid-typing doesn't wipe it
let RELEASED = {};      // { KEY: { released, released_posted, deploy, present } } from story-release.ps1 -All
let armedReleaseKey = null; // story whose 🚀 (released toggle) is armed
let armedLinksKey = null;   // story whose ✎ (custom links) editor is open
let linksDraft = [];        // [{label,url}] - the editor's working copy; survives repaint() the same way forceConfirmText does
let linksOriginal = {};     // the links map as it stood when the editor opened, for diffing on Save
let linksErr = '';          // inline validation error shown in the editor (no alert()/prompt())

// Mirror of $DefaultPhases' grouping in tools\story-ledger.ps1 — keep the two in sync. Computing
// this here (instead of shelling out to `story-ledger.ps1 tracker` per story) keeps the popup's
// refresh to pure file reads: no PowerShell process per row.
const PHASE_GROUPS = [
  { name: 'Story Up', phases: ['bring-up'] },
  { name: 'Dev Loop', phases: ['plan', 'implement', 'testplan', 'verify', 'typecheck', 'commit-push'] },
  { name: 'Prep Release', phases: ['release-notes', 'rel-ticket', 'agiletest', 'release-branch', 'release-prs', 'chg', 'deploy'] },
];
const CLOSED = new Set(['done', 'skipped']);
const GLYPH = { done: '✓', skipped: '–', failed: '!', running: '▶', pending: '·' };

// The resume pointer, same rule as story-ledger.ps1's Get-NextInfo: the first open phase AFTER the
// furthest closed one, so an already-released story is never rewound to bring-up.
function nextPhaseOf(phases) {
  let lastClosed = -1;
  phases.forEach((p, i) => { if (CLOSED.has(p.status)) lastClosed = i; });
  for (let i = lastClosed + 1; i < phases.length; i++) if (!CLOSED.has(phases[i].status)) return phases[i].name;
  return null;
}

// One compact chip: which lifecycle group the story is actually in, and how far through it.
function ledgerChip(key) {
  const led = LEDGERS[key];
  if (!led || !Array.isArray(led.phases) || !led.phases.length) return '';
  const phases = led.phases;
  const byName = new Map(phases.map((p) => [p.name, p]));
  const next = nextPhaseOf(phases);
  const groups = PHASE_GROUPS.map((g) => {
    const mine = g.phases.map((n) => byName.get(n)).filter(Boolean);
    const done = mine.filter((p) => CLOSED.has(p.status)).length;
    const failed = mine.some((p) => p.status === 'failed');
    return { name: g.name, total: mine.length, done, failed, hasNext: mine.some((p) => p.name === next) };
  }).filter((g) => g.total);

  const cur = groups.find((g) => g.hasNext);
  const anyFailed = groups.some((g) => g.failed);
  const label = cur ? `${cur.name} ${cur.done}/${cur.total}` : 'all phases done';
  const cls = anyFailed ? 'bad' : cur ? 'run' : 'ok';
  const mark = anyFailed ? GLYPH.failed : cur ? GLYPH.running : GLYPH.done;
  // Tooltip carries the full checklist, so the 328px-wide row stays one line.
  const tip = groups.map((g) => `${g.name} ${g.done}/${g.total}`).join('  ·  ')
    + '\n' + phases.map((p) => `${GLYPH[p.status] || '·'} ${p.name}${p.name === next ? '   <-- next' : ''}`).join('\n');
  return `<span class="chip phase ${cls}" title="${esc(tip)}">${mark} ${esc(label)}</span>`;
}

// Has this story shipped? Read off the already-fetched released payload, so the chip costs no
// extra native round trip on popup open.
const isReleased = (key) => !!(RELEASED[key] && RELEASED[key].released);

// The released chip. Deliberately does NOT hide or reorder the row: a rollback has to stay one
// click away, and 🗑 / ♻ remain available on a shipped story.
function releasedChip(key) {
  const r = RELEASED[key];
  if (!r || !r.released) return '';
  return `<span class="chip rel" title="marked released ${esc(r.released)} — click 🚀 to roll back">✔ released</span>`;
}

// Metadata straight off the stories.json node: env, REL, CHG, and the links worth one click.
function metaChips(key) {
  const n = NODES[key];
  if (!n) return '';
  const chips = [];
  if (n.env) chips.push(`<span class="chip">${esc(n.env)}</span>`);
  if (n.rel) chips.push(`<a class="chip link" target="_blank" title="open ${esc(n.rel)}" href="https://vesta.atlassian.net/browse/${encodeURIComponent(n.rel)}">${esc(n.rel)}</a>`);
  // Singular field plus the plural map are both in use.
  const chg = [n.chg_number, ...(n.chg_numbers && typeof n.chg_numbers === 'object' ? Object.values(n.chg_numbers) : [])].filter(Boolean);
  for (const c of [...new Set(chg)]) chips.push(`<span class="chip">${esc(c)}</span>`);
  const jira = asArr(n.jira_stories).filter(Boolean);
  if (jira.length) chips.push(`<a class="chip link" target="_blank" href="${esc(jira[0])}" title="${esc(jira[0])}">Jira</a>`);
  const doc = n.document || n.document_keycloak_setup;
  if (doc) chips.push(`<a class="chip link" target="_blank" href="${esc(doc)}" title="design note / artifact">Doc</a>`);
  // Custom named links (Abstract, Test plan, ...) - a map, same convention as chg_numbers above.
  if (n.links && typeof n.links === 'object' && !Array.isArray(n.links)) {
    for (const [label, url] of Object.entries(n.links)) {
      if (url) chips.push(`<a class="chip link" target="_blank" href="${esc(url)}" title="${esc(url)}">${esc(label)}</a>`);
    }
  }
  return chips.join('');
}

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Known-generated files always safe to auto-discard. MUST stay in sync with Test-Generated in
// remove-worktree.ps1 — both sides gate the ♻ button on the same allow-list.
// Two things this has to get right to actually agree with the PS side:
//   1. slashes — git emits 'src/pipeline/__pycache__/x.pyc', and the __pycache__ rule has a
//      directory component, so normalize to '/' before matching.
//   2. case — PowerShell -contains/-match are case-INsensitive, so lowercase here or the script
//      would discard 'YARN.LOCK' while ♻ never appeared for it.
// NOTE: the exempt list (.env / logging.ini, see $LocalArtifacts) is deliberately NOT mirrored —
// Get-Blockers strips those before reporting, so popup never sees them.
function isGeneratedFile(p) {
  const s = String(p).replace(/\\/g, '/').toLowerCase();
  const leaf = s.split('/').pop();
  if (leaf === 'yarn.lock' || leaf === 'package-lock.json') return true;
  if (/routetree\.gen\.ts$/.test(s)) return true;
  if (/(^|\/)__pycache__\//.test(s)) return true;   // tracked bytecode; PS restores from HEAD
  if (/\.py[cod]$/.test(s)) return true;
  return false;
}
// ♻ is offered ONLY when every blocker is non-generated-free: no unpushed/no-upstream and ALL
// dirty files are generated. Any real file or unpushed commit → no ♻ (routes to 🗑 / Claude).
function discardableStatus(ck) {
  if (!ck || ck.ok) return false;
  const bl = asArr(ck.blockers);
  if (!bl.length) return false;
  return bl.every((b) => {
    if (b.unpushed || b.noUpstream) return false;
    const files = asArr(b.dirty);
    return files.length > 0 && files.every(isGeneratedFile);
  });
}
function blockerSummary(ck) {
  let changed = 0, unpushed = 0, noUp = false;
  for (const b of asArr(ck.blockers)) { changed += asArr(b.dirty).length; unpushed += (b.unpushed || 0); if (b.noUpstream) noUp = true; }
  const parts = [];
  if (changed) parts.push(`${changed} changed`);
  if (unpushed) parts.push(`${unpushed} unpushed`);
  if (noUp && !unpushed) parts.push('not pushed');
  return parts.join(', ') || 'blocked';
}
function blockerDetail(ck) {
  return asArr(ck.blockers).map((b) => {
    const bits = [];
    const d = asArr(b.dirty);
    if (d.length) bits.push(`${d.length} changed (${d.join(', ')})`);
    if (b.unpushed) bits.push(`${b.unpushed} unpushed`);
    if (b.noUpstream) bits.push('not pushed');
    return `${b.app}: ${bits.join(', ')}`;
  }).join(' | ');
}

const colorOf = (s) => (s && RB.COLOR_HEX[s.color]) || '#888';
const story = (key) => STATE.stories.find((x) => x.key === key);

// Live per-story group state (open? tab count?).
async function computeStats(stories) {
  const stats = {};
  try {
    for (const g of await chrome.tabGroups.query({})) {
      const title = (g.title || '').toLowerCase();
      const s = stories.find((x) => title.includes(x.key.toLowerCase()));
      if (!s) continue;
      const tabs = await chrome.tabs.query({ groupId: g.id });
      const cur = stats[s.key] || { open: true, count: 0 };
      cur.count += tabs.length;
      stats[s.key] = cur;
    }
  } catch (e) {
    console.warn('[story-tab-groups] computeStats failed:', e);
  }
  return stats;
}

async function load() {
  STATE = await send({ type: 'getState' });
  const stories = STATE.stories;
  activeKey = STATE.settings.activeStory || '';

  STATS = await computeStats(stories);
  $('#sectionLbl').textContent = `Story groups · ${Object.keys(STATS).length} open`;

  // Selection (highlight) is just UI: keep last pick → active story → first.
  const valid = new Set(stories.map((s) => s.key));
  if (!(selectedKey && valid.has(selectedKey))) {
    const { selectedStory } = await chrome.storage.local.get('selectedStory');
    if (selectedStory && valid.has(selectedStory)) selectedKey = selectedStory;
    else selectedKey = (valid.has(activeKey) && activeKey) || (stories[0] && stories[0].key) || null;
  }

  repaint();
  // Both async, both silent if the native host is absent: the row paints instantly from the rules,
  // then badges and chips fill in. Health (⚡) is NOT here on purpose — it probes HTTP and can take
  // tens of seconds while an app warms up, and the host is single-shot, so it stays a button.
  refreshChecks();
  refreshMeta();
}

// Ask the native host for per-story blocker status, then repaint badges. Silent if the host is
// absent — badges just don't show and the rest of the popup keeps working.
async function refreshChecks() {
  try {
    const res = await send({ type: 'checkWorktrees' });
    CHECK = (res && res.ok && res.stories) ? res.stories : {};
  } catch (_) { CHECK = {}; }
  repaint();
}

// stories.json nodes + every story's ledger. File reads only (no git, no HTTP), so this is cheap
// enough to run on every popup open.
async function refreshMeta() {
  try {
    const [s, l, r] = await Promise.all([
      send({ type: 'getStories' }), send({ type: 'getLedgers' }), send({ type: 'getReleased' }),
    ]);
    NODES = (s && s.ok && s.stories) ? s.stories : {};
    LEDGERS = (l && l.ok && l.ledgers) ? l.ledgers : {};
    RELEASED = (r && r.ok && r.stories) ? r.stories : {};
  } catch (_) { NODES = {}; LEDGERS = {}; RELEASED = {}; }
  repaint();
}

// ⚡ — ports + health for ONE story, on demand.
async function doHealth(key) {
  HEALTH[key] = { loading: true, lines: [] };
  repaint();
  let res;
  try { res = await send({ type: 'envStatus', story: key }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (!res || (!res.ok && !res.apps)) {
    const hint = res && res.nativeHostMissing ? ' (native host unreachable)' : '';
    HEALTH[key] = { loading: false, lines: [], err: ((res && (res.error || res.message)) || 'no reply') + hint };
  } else {
    const lines = asArr(res.apps).map((a) => {
      const p = a.ports || {};
      const port = p.port ? `:${p.port}` : '(no port)';
      const bits = [`${a.app} ${port} ${p.health || '?'}`];
      if (p.hijack) bits.push(`HIJACKED by ${p.listener}`);
      else if (p.listener && p.listener !== 'free' && !String(p.listener).startsWith('mine')) bits.push(String(p.listener));
      return { text: bits.join(' — '), bad: !!p.hijack || p.health === 'down' };
    });
    HEALTH[key] = { loading: false, lines };
  }
  repaint();
}

function repaint() {
  // Which story the buttons act on is shown by the highlighted row in the list below, so there is
  // no separate 'Selected' chip to paint.

  // Active status line
  const a = story(activeKey);
  const status = $('#activeStatus');
  if (a) { status.innerHTML = `Auto-route <b>ON</b> → ${a.title}`; status.classList.add('on'); }
  else { status.textContent = 'Auto-route off — select a story and Set active'; status.classList.remove('on'); }

  // Buttons
  $('#setActive').disabled = !selectedKey || selectedKey === activeKey;
  $('#clearActive').disabled = !activeKey;
  $('#addAppBtn').disabled = !selectedKey;

  // List
  $('#stories').innerHTML = STATE.stories
    .map((st) => {
      const stat = STATS[st.key];
      const open = !!stat;
      const isSel = st.key === selectedKey;
      const isAct = st.key === activeKey;
      const pill = open ? `<span class="count" title="${stat.count} tab${stat.count === 1 ? '' : 's'} in this group">${stat.count}</span>` : '';
      const tag = isAct ? `<span class="acttag" title="auto-route is routing to this story">active</span>` : '';

      // ready / blocked badge from the -CheckAll status (absent until the native host replies).
      const ck = CHECK[st.key];
      const badge = !ck ? ''
        : ck.ok ? `<span class="rmstat ok" title="clean & pushed — safe to remove">ready</span>`
          : `<span class="rmstat warn" title="${esc(blockerDetail(ck))}">${esc(blockerSummary(ck))}</span>`;

      const h = HEALTH[st.key];
      const healthBtn = `<button class="ico bolt${h && h.loading ? ' busy' : ''}" data-health="${st.key}" title="Check ports + health for this story's apps (probes HTTP — can take a few seconds)">${h && h.loading ? '…' : '⚡'}</button>`;
      const rel = isReleased(st.key);
      const relBtn = `<button class="ico rocket${rel ? ' on' : ''}" data-toggle-release="${st.key}" title="${rel ? 'Marked released — click to roll back (unrelease)' : 'Mark this story released (stamps the ledger deploy phase; does NOT remove the worktree)'}">🚀</button>`;
      const linksBtn = `<button class="ico${st.key === armedLinksKey ? ' on' : ''}" data-toggle-links="${st.key}" title="Add/edit custom links (Abstract, Test plan, or anything else)">✎</button>`;
      const baseBtns = `${healthBtn}${relBtn}${linksBtn}<button class="ico${open ? '' : ' off'}" data-focus="${st.key}" title="${open ? 'Focus this group' : 'No group open'}">↪</button>`;

      let tail;
      if (st.key === armedReleaseKey) {
        tail = `<button class="ico confirm" data-confirmrelease="${st.key}" title="Confirm">✓</button>
                <button class="ico cancel" data-cancelrelease="${st.key}" title="Cancel">✕</button>`;
      } else if (st.key === armedKey) {
        tail = `<button class="ico confirm" data-confirmremove="${st.key}" title="Confirm — remove this worktree now">✓</button>
                <button class="ico cancel" data-cancelremove="${st.key}" title="Cancel">✕</button>`;
      } else if (st.key === armedDiscardKey) {
        tail = `<button class="ico confirm" data-confirmdiscard="${st.key}" title="Confirm — discard generated files & remove">✓</button>
                <button class="ico cancel" data-canceldiscard="${st.key}" title="Cancel">✕</button>`;
      } else if (st.key === armedForceKey) {
        // Delete button lives on the extra line below (sforce) - the row itself just offers a way back out.
        tail = `<button class="ico cancel" data-cancelforce="${st.key}" title="Cancel">✕</button>`;
      } else {
        const blocked = ck && !ck.ok;
        const recycle = discardableStatus(ck)
          ? `<button class="ico recycle" data-discard="${st.key}" title="Only generated files block this — discard them &amp; remove">♻</button>`
          : '';
        const rmTitle = blocked
          ? 'Blocked — click to force-remove (discards uncommitted changes; type CONFIRM)'
          : 'Remove worktree — its folders, stories.json node + .code-workspace (blocked if uncommitted non-.env changes or unpushed commits)';
        tail = `${recycle}<button class="ico danger" data-remove="${st.key}" title="${rmTitle}">🗑</button>`;
      }

      // Second line: lifecycle phase + node metadata. Absent until the native host replies, so the
      // row is never blocked on it.
      const chips = `${releasedChip(st.key)}${ledgerChip(st.key)}${metaChips(st.key)}`;
      const metaLine = chips ? `<div class="smeta">${chips}</div>` : '';

      // Third line: only after ⚡ is clicked.
      let healthLine = '';
      if (h) {
        if (h.loading) healthLine = `<div class="shealth">probing ports + health…</div>`;
        else if (h.err) healthLine = `<div class="shealth bad">${esc(h.err)}</div>`;
        else if (h.lines.length) {
          healthLine = `<div class="shealth">${h.lines.map((l) => `<div class="${l.bad ? 'bad' : ''}">${esc(l.text)}</div>`).join('')}</div>`;
        }
      }

      // Fourth line: only while this row's 🗑 is armed for a FORCED removal. The typed value is
      // re-applied from forceConfirmText on every render so an unrelated repaint mid-typing (e.g.
      // clicking ⚡ on a different row) doesn't silently wipe what you'd already typed.
      let forceLine = '';
      if (st.key === armedForceKey) {
        const detail = ck ? blockerDetail(ck) : '';
        const ready = forceConfirmText === 'CONFIRM';
        forceLine = `<div class="sforce">
          <div class="sforce-warn">⚠ ${esc(detail || (ck ? blockerSummary(ck) : 'blocked'))} — typing CONFIRM discards this permanently. Unpushed commits stay safe (branch is kept).</div>
          <div class="sforce-row">
            <input type="text" class="sforce-input" id="forceConfirmInput" placeholder="type CONFIRM" autocomplete="off" spellcheck="false" value="${esc(forceConfirmText)}" />
            <button class="btn sm danger" id="forceConfirmBtn" data-forceremove="${st.key}" ${ready ? '' : 'disabled'}>Delete</button>
          </div>
        </div>`;
      }

      // Fifth line: only while ✎ is armed on this row. linksDraft is edited in place by the
      // delegated 'input' listener below (no repaint on every keystroke, same reason
      // forceConfirmText survives repaint() untouched — recreating the DOM mid-typing would drop
      // focus), so a row re-added via "+ add link" or removed via ✕ still shows exactly what was
      // already typed in the others.
      let linksLine = '';
      if (st.key === armedLinksKey) {
        const rows = linksDraft.map((p, i) => `
          <div class="slinks-row">
            <input type="text" class="slinks-label" list="linkLabelSuggestions" placeholder="Label" autocomplete="off" spellcheck="false" data-linkfield="label" data-linkidx="${i}" value="${esc(p.label)}" />
            <input type="text" class="slinks-url" placeholder="https://…" autocomplete="off" spellcheck="false" data-linkfield="url" data-linkidx="${i}" value="${esc(p.url)}" />
            <button class="ico danger" data-linkremove="${i}" title="Remove this link">✕</button>
          </div>`).join('');
        linksLine = `<div class="slinks">
          ${rows}
          <div class="slinks-add" data-linkadd="1">+ add link</div>
          ${linksErr ? `<div class="slinks-err">${esc(linksErr)}</div>` : ''}
          <div class="slinks-btns">
            <button class="btn sm" data-linkssave="${st.key}">Save</button>
            <button class="btn ghost sm" data-linkscancel="${st.key}">Cancel</button>
          </div>
        </div>`;
      }

      return `<div class="story${isSel ? ' sel' : ''}${isAct ? ' act' : ''}" data-select="${st.key}" title="${esc(st.storyTitle || '')}">
        <div class="srow">
          <span class="dot${open ? '' : ' off'}" style="background:${colorOf(st)}"></span>
          <span class="stitle">${esc(st.title)}</span>
          ${tag}${pill}${badge}
          ${baseBtns}
          ${tail}
        </div>
        ${metaLine}
        ${healthLine}
        ${forceLine}
        ${linksLine}
      </div>`;
    })
    .join('');
}

async function selectStory(key) {
  selectedKey = key;
  await chrome.storage.local.set({ selectedStory: key });
  repaint();
}
async function setActive() {
  if (!selectedKey) return;
  activeKey = selectedKey;
  await send({ type: 'setSettings', settings: { activeStory: activeKey, autoRoute: true } });
  repaint();
}
async function clearActive() {
  activeKey = '';
  await send({ type: 'setSettings', settings: { activeStory: '', autoRoute: false } });
  repaint();
}

// Row icons act directly; clicking elsewhere on a row selects it.
// Removal is a two-step inline confirm (🗑 arms → ✓ confirms) — native confirm()/alert()
// can't be used here: opening one blurs the popup, which Chrome then auto-closes.
document.addEventListener('click', (e) => {
  const okBtn = e.target.closest('[data-confirmremove]');
  if (okBtn) { e.stopPropagation(); doRemove(okBtn.dataset.confirmremove); return; }
  const noBtn = e.target.closest('[data-cancelremove]');
  if (noBtn) { e.stopPropagation(); armedKey = null; rmMsg('', ''); repaint(); return; }
  const okR = e.target.closest('[data-confirmrelease]');
  if (okR) { e.stopPropagation(); doRelease(okR.dataset.confirmrelease); return; }
  const noR = e.target.closest('[data-cancelrelease]');
  if (noR) { e.stopPropagation(); armedReleaseKey = null; rmMsg('', ''); repaint(); return; }
  const relBtn = e.target.closest('[data-toggle-release]');
  if (relBtn) {
    e.stopPropagation();
    armedKey = null; armedDiscardKey = null; armedForceKey = null; forceConfirmText = '';
    armedLinksKey = null; linksDraft = []; linksErr = '';
    armedReleaseKey = relBtn.dataset.toggleRelease;
    repaint();
    rmMsg(isReleased(armedReleaseKey)
      ? `Click ✓ to roll back ${armedReleaseKey} to not-released`
      : `Click ✓ to mark ${armedReleaseKey} released (worktree is kept)`, 'warn');
    return;
  }
  const linksBtn = e.target.closest('[data-toggle-links]');
  if (linksBtn) {
    e.stopPropagation();
    const key = linksBtn.dataset.toggleLinks;
    armedKey = null; armedDiscardKey = null; armedReleaseKey = null; armedForceKey = null; forceConfirmText = '';
    if (armedLinksKey === key) {
      // Clicking ✎ again on the same row closes it without saving.
      armedLinksKey = null; linksDraft = []; linksOriginal = {}; linksErr = '';
      rmMsg('', '');
    } else {
      armedLinksKey = key;
      const n = NODES[key] || {};
      const existing = (n.links && typeof n.links === 'object' && !Array.isArray(n.links)) ? n.links : {};
      linksOriginal = existing;
      linksDraft = Object.entries(existing).map(([label, url]) => ({ label, url }));
      linksErr = '';
    }
    repaint();
    return;
  }
  const okD = e.target.closest('[data-confirmdiscard]');
  if (okD) { e.stopPropagation(); doRemove(okD.dataset.confirmdiscard, true); return; }
  const noD = e.target.closest('[data-canceldiscard]');
  if (noD) { e.stopPropagation(); armedDiscardKey = null; rmMsg('', ''); repaint(); return; }
  const rmBtn = e.target.closest('[data-remove]');
  if (rmBtn) {
    e.stopPropagation();
    const key = rmBtn.dataset.remove;
    armedDiscardKey = null; armedReleaseKey = null;
    armedLinksKey = null; linksDraft = []; linksErr = '';
    const ck = CHECK[key];
    if (ck && !ck.ok) {
      // Blocked: the automated guardrail would abort this anyway. Arm the typed-CONFIRM force
      // path instead of the quick ✓/✕ - that used to just re-show the same "commit/push or clean
      // up" dead end every time, which was the actual complaint this replaces.
      armedKey = null; forceConfirmText = '';
      armedForceKey = key;
      repaint();
      rmMsg(`${key} is blocked (${blockerSummary(ck)}). Type CONFIRM below to force removal anyway.`, 'warn');
    } else {
      armedForceKey = null; forceConfirmText = '';
      armedKey = key;
      repaint();
      rmMsg(`Click ✓ to confirm removing ${key} (folders + stories.json + workspace)`, 'warn');
    }
    return;
  }
  const noF = e.target.closest('[data-cancelforce]');
  if (noF) { e.stopPropagation(); armedForceKey = null; forceConfirmText = ''; rmMsg('', ''); repaint(); return; }
  const okF = e.target.closest('[data-forceremove]');
  if (okF) { e.stopPropagation(); if (okF.disabled) return; doRemove(okF.dataset.forceremove, false, true); return; }
  const discBtn = e.target.closest('[data-discard]');
  if (discBtn) {
    e.stopPropagation(); armedKey = null; armedReleaseKey = null; armedForceKey = null; forceConfirmText = '';
    armedLinksKey = null; linksDraft = []; linksErr = '';
    armedDiscardKey = discBtn.dataset.discard; repaint();
    const ck = CHECK[armedDiscardKey];
    const files = ck ? asArr(ck.blockers).flatMap((b) => asArr(b.dirty)) : [];
    rmMsg(`Click ✓ to discard ${files.join(', ') || 'generated files'} & remove ${armedDiscardKey}`, 'warn');
    return;
  }
  const healthBtn = e.target.closest('[data-health]');
  if (healthBtn) { e.stopPropagation(); doHealth(healthBtn.dataset.health); return; }
  const focusBtn = e.target.closest('[data-focus]');
  if (focusBtn) { send({ type: 'focusStory', key: focusBtn.dataset.focus }).then(() => window.close()); return; }
  const linkAddBtn = e.target.closest('[data-linkadd]');
  if (linkAddBtn) { e.stopPropagation(); linksDraft.push({ label: '', url: '' }); linksErr = ''; repaint(); return; }
  const linkRmBtn = e.target.closest('[data-linkremove]');
  if (linkRmBtn) {
    e.stopPropagation();
    linksDraft.splice(Number(linkRmBtn.dataset.linkremove), 1);
    linksErr = '';
    repaint();
    return;
  }
  const linksCancelBtn = e.target.closest('[data-linkscancel]');
  if (linksCancelBtn) {
    e.stopPropagation();
    armedLinksKey = null; linksDraft = []; linksOriginal = {}; linksErr = '';
    rmMsg('', '');
    repaint();
    return;
  }
  const linksSaveBtn = e.target.closest('[data-linkssave]');
  if (linksSaveBtn) { e.stopPropagation(); doSaveLinks(linksSaveBtn.dataset.linkssave); return; }
  // A metadata chip that IS a link opens normally — don't let the row's select handler eat it.
  if (e.target.closest('a.chip')) { e.stopPropagation(); return; }
  // Every button inside the ✎ links editor and the 🗑 force-confirm box already stops propagation
  // on its own branch above; the bare <input> fields (Label/URL/CONFIRM textbox) had none, so a
  // click landing directly on one of them fell through all the way to the row-select handler
  // below, which — since armedLinksKey/armedForceKey were truthy — disarmed the editor and
  // repainted it out of existence on the very click meant to focus it. This is a blanket guard on
  // the whole .slinks subtree (not just today's two inputs), so anything added to that editor
  // later is protected too, matching every sibling branch's own stopPropagation().
  if (e.target.closest('.slinks') || e.target.id === 'forceConfirmInput') { e.stopPropagation(); return; }
  const row = e.target.closest('.story');
  if (row && row.dataset.select) {
    if (armedKey || armedDiscardKey || armedReleaseKey || armedForceKey || armedLinksKey) {
      armedKey = null; armedDiscardKey = null; armedReleaseKey = null; armedForceKey = null; forceConfirmText = '';
      armedLinksKey = null; linksDraft = []; linksOriginal = {}; linksErr = '';
      rmMsg('', '');
    }
    selectStory(row.dataset.select);
  }
});

// Delegated because #forceConfirmInput is (re)created by repaint(), not present at page load.
document.addEventListener('input', (e) => {
  if (e.target && e.target.id === 'forceConfirmInput') {
    forceConfirmText = e.target.value;
    const btn = $('#forceConfirmBtn');
    if (btn) btn.disabled = forceConfirmText !== 'CONFIRM';
  }
  // Same reasoning: .slinks-label/.slinks-url are (re)created by repaint(), and updating
  // linksDraft here (WITHOUT repainting) is what lets typing survive an unrelated repaint mid-edit
  // - repainting on every keystroke would recreate the input and drop focus/cursor position.
  if (e.target && e.target.dataset && e.target.dataset.linkfield) {
    const idx = Number(e.target.dataset.linkidx);
    const field = e.target.dataset.linkfield;
    if (linksDraft[idx]) linksDraft[idx][field] = e.target.value;
  }
});
// Enter submits once the typed text is exactly right, same as clicking Delete.
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.target && e.target.id === 'forceConfirmInput' && forceConfirmText === 'CONFIRM' && armedForceKey) {
    e.preventDefault();
    doRemove(armedForceKey, false, true);
  }
});

// PS 5.1's ConvertTo-Json collapses single-element arrays to a bare object — normalize.
const asArr = (x) => (Array.isArray(x) ? x : x ? [x] : []);

// Inline status line (replaces alert(), which is unusable in a popup).
function rmMsg(text, kind) {
  const el = $('#rmMsg');
  if (!el) return;
  el.textContent = text || '';
  el.className = 'rmmsg' + (kind ? ' ' + kind : '');
}

// 🚀 confirmed — flip the released flag. Unlike 🗑 this removes nothing: it stamps the ledger's
// 'deploy' phase and the node's 'released' field, so a shipped story stops looking active while its
// worktree stays put. Toggling back is the rollback path (revert / re-release).
async function doRelease(key) {
  const to = !isReleased(key);
  armedReleaseKey = null;
  rmMsg(`${to ? 'Marking' : 'Rolling back'} ${key}…`, '');
  repaint();
  // No prompt() for the rollback reason — a native dialog blurs the popup and Chrome closes it.
  // /note adds detail when a rollback needs more than this.
  const res = await send({
    type: 'setReleased', key, released: to,
    reason: to ? undefined : 'unreleased from popup',
    note: to ? 'marked released from popup' : undefined,
  });
  if (res && res.ok) {
    await refreshMeta(); // repaints the chip + phase chip from the freshest state
    rmMsg(`✓ ${res.summary || key}`, 'ok');
    return;
  }
  const err = (res && (res.error || res.message)) || 'unknown error';
  const hint = res && res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help)' : '';
  rmMsg(`✕ ${key}: ${err}${hint}`, 'err');
}

// ✎ confirmed — save the links editor's draft. Diffs against the snapshot taken when the editor
// opened (linksOriginal) rather than sending a full replace, matching switch-story.ps1 links'
// -Set/-Remove contract. Client-side validation mirrors the script's own rules exactly (label
// 1-60 chars, url http(s):// only, <=2000 chars, no duplicate labels, <=20 links total) - not a
// substitute for the script re-validating, just a faster no-round-trip error for the common typo.
async function doSaveLinks(key) {
  const draft = linksDraft
    .map((p) => ({ label: (p.label || '').trim(), url: (p.url || '').trim() }))
    .filter((p) => p.label || p.url);

  const seen = new Set();
  for (const p of draft) {
    if (!p.label || p.label.length > 60) { linksErr = `Label must be 1-60 characters: "${p.label}"`; repaint(); return; }
    if (!/^https?:\/\//i.test(p.url) || p.url.length > 2000) { linksErr = `"${p.label}" needs a valid http:// or https:// URL`; repaint(); return; }
    const lk = p.label.toLowerCase();
    if (seen.has(lk)) { linksErr = `Duplicate label "${p.label}" — rename one of them`; repaint(); return; }
    seen.add(lk);
  }
  if (draft.length > 20) { linksErr = 'A story may carry at most 20 links'; repaint(); return; }

  const draftLabels = new Set(draft.map((p) => p.label));
  const set = draft.filter((p) => linksOriginal[p.label] !== p.url);
  const remove = Object.keys(linksOriginal).filter((label) => !draftLabels.has(label));

  if (!set.length && !remove.length) {
    // Nothing actually changed (e.g. opened the editor then hit Save with no edits) - just close it.
    armedLinksKey = null; linksDraft = []; linksOriginal = {}; linksErr = '';
    repaint();
    return;
  }

  linksErr = '';
  rmMsg(`Saving links for ${key}…`, '');
  repaint();
  const res = await send({ type: 'setStoryLinks', key, set, remove });
  if (res && res.ok) {
    armedLinksKey = null; linksDraft = []; linksOriginal = {};
    await refreshMeta(); // repaints the chips from the freshest stories.json read
    rmMsg(`✓ Links updated for ${key}`, 'ok');
    return;
  }
  const err = (res && (res.error || res.message)) || 'unknown error';
  const hint = res && res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help)' : '';
  linksErr = `${err}${hint}`;
  repaint();
}

// 🗑 confirmed — full worktree teardown via the native host (com.storytabgroups.worktree). force:true is
// the typed-CONFIRM path for a blocked story: skips the dirty/unpushed guardrail, discarding
// uncommitted changes permanently (unpushed commits stay safe - the branch is kept regardless).
async function doRemove(key, discard = false, force = false) {
  armedKey = null; armedDiscardKey = null; armedForceKey = null; forceConfirmText = '';
  rmMsg(`${force ? 'Force-removing' : discard ? 'Discarding generated & removing' : 'Removing'} ${key}…`, '');
  repaint();
  const res = await send({ type: 'removeWorktree', key, discardGenerated: !!discard, force: !!force });

  if (res && res.ok) {
    if (selectedKey === key) selectedKey = null;
    // background.js's forceRulesRebuild() (run for every node-mutating action, including this one)
    // already clears + rebuilds both the in-memory rules cache and the persisted
    // chrome.storage.local one, from the host - so it's the single source of truth for
    // post-removal freshness. This used to ALSO call RB.syncSilently() here, which re-reads a
    // remembered file-picker handle completely independent of the configured Root and pushes its
    // content straight into that same persisted cache - a second, uncoordinated writer that could
    // silently overwrite the correct rebuild with a different file's stale contents, and because
    // it lands in storage rather than memory, the wrong result would survive even an extension
    // reload. Confirmed as the actual cause of a removed story staying listed. Removed.
    await load();
    const disc = asArr(res.discarded).flatMap((d) => asArr(d.files));
    rmMsg(`✓ Removed ${key}${disc.length ? ` (discarded ${disc.join(', ')})` : ''}`, 'ok');
    return;
  }
  if (res && res.hasNode === false) {
    // The PS-side fix for the same bug: a key absent from whatever registry got resolved now
    // reports ok:false + hasNode:false instead of a misleading "success". Most likely cause is
    // Settings' Story root pointing somewhere other than where this key actually lives.
    rmMsg(`⚠ ${key} is not in stories.json at the configured root — check Settings → Worktree paths & branch format (see Help)`, 'warn');
    refreshChecks();
    return;
  }
  if (res && res.aborted) {
    const parts = asArr(res.blockers).map((b) => {
      const bits = [];
      const d = asArr(b.dirty);
      if (d.length) bits.push(`${d.length} changed (${d.slice(0, 3).join(', ')}${d.length > 3 ? '…' : ''})`);
      if (b.unpushed) bits.push(`${b.unpushed} unpushed`);
      if (b.noUpstream) bits.push('not pushed');
      return `${b.app}: ${bits.join(', ')}`;
    });
    // Refresh this row's badge + ♻ visibility from the abort payload, which IS the freshest
    // blocker state (no extra native round trip). Without this the badge and ♻ stayed stale
    // until the popup was reopened, so a blocked removal looked unchanged.
    CHECK[key] = { ok: false, blockers: asArr(res.blockers), present: true };
    repaint();
    rmMsg(`⚠ ${key} not removed — ${parts.join(' | ')}. Commit/push or clean up, then retry.`, 'warn');
    return;
  }
  const err = (res && (res.error || res.message)) || 'unknown error';
  const hint = res && res.nativeHostMissing ? ' — install-native-host.ps1 not reachable; run it then fully restart the browser (see Help)' : '';
  rmMsg(`✕ ${key}: ${err}${hint}`, 'err');
  refreshChecks(); // state unknown after an error - re-ask the host rather than show stale badges
}

// ---------- + New story ----------
// Registers a node in stories.json + cuts a worktree per app, via the native host's 'add'/
// 'addcheck'/'apps' actions -> switch-story.ps1 new -Json. No prompt()/confirm() here either
// (same reason as 🗑/🚀): the form is inline, and "Check & create" is itself the two-step confirm
// (check -> ✓/✕) rather than a second dialog.
let addApps = [];              // [{app, repo, origin, onDisk, mapped, used}] from getApps
let addAppsLoaded = false;
let addAppsError = null;       // the host's real res.error when getApps came back ok:false - shown
                                // in the empty-state instead of a generic guess (see renderAddApps)
let addAppsExpanded = false;   // collapsed by default - a long app list otherwise floods the popup
let addAppsFilter = '';        // live search text over app/repo name
let addSelectedApps = new Set();
let addBranchTouched = false;  // stop auto-deriving the branch once the user edits it directly
let addChecking = false;
let addCreating = false;
let addPlan = null;            // last clean addcheck result — armed for the ✓ confirm step
let addMode = 'new';           // 'new' (+ New story) or 'add' (+ Add app to an existing story)
let addTargetKey = null;       // the story being extended in 'add' mode
let addExistingApps = new Set(); // its current apps - shown checked + locked, never re-created

// Same two shapes switch-story.ps1:391 validates - reject client-side before any native round trip.
const isValidStoryKey = (k) => /^[A-Za-z0-9]+-\d+$/.test(k) || /^[a-z][a-z0-9]*(-[a-z0-9]+)+$/.test(k);
// Mirrors Test-ValidBranchName in switch-story.ps1 - not exhaustive vs git-check-ref-format, but
// catches the shapes that actually bite (see that function's comment for the list).
function isValidBranchName(b) {
  if (!b || !b.trim() || b === '@' || b.includes('..') || b.includes('@{')) return false;
  if (/[\x00-\x1F\x7F ~^:?*[\\]/.test(b)) return false;
  if (b.startsWith('/') || b.endsWith('/') || b.includes('//')) return false;
  if (b.endsWith('.') || b.endsWith('.lock')) return false;
  return b.split('/').every((seg) => seg && !seg.startsWith('.'));
}

function afResult(html) { const el = $('#afResult'); if (el) el.innerHTML = html; }

function afButtonsEditing() {
  const verb = addMode === 'add' ? 'add' : 'create';
  $('#afButtons').innerHTML = `<button class="btn sm" id="afCheck" style="flex: 1">Check &amp; ${verb}</button>
    <button class="btn ghost sm" id="afCancel" style="flex: 1">Cancel</button>`;
  wireAddButtons();
}

// onDisk:false apps can't be worktree'd (not cloned) - render but disable, don't just hide them,
// so the form explains why an expected app is missing rather than looking incomplete.
function renderAddApps() {
  const el = $('#afApps');
  if (!el) return;
  if (!addAppsLoaded) { el.innerHTML = '<div class="afhint">loading repos…</div>'; return; }
  if (!addApps.length) {
    // A real host error (a crash, unreachable host, ...) gets its own message with the actual
    // reason - the old text asked you to check two things that could both be perfectly fine
    // (native host installed AND tools\app-map.json present) while silently discarding whatever
    // res.error actually said. A genuine ok:true + zero rows (root really has no clones) points
    // at the new Settings > Apps card instead of repeating the same two guesses.
    const msg = addAppsError
      ? `no repos found — ${esc(addAppsError)}`
      : 'no repos found at your story root — add one in Settings → Apps.';
    el.innerHTML = `<div class="afhint">${msg}</div>`;
    return;
  }
  const filter = addAppsFilter.trim().toLowerCase();
  const sorted = [...addApps]
    .filter((a) => !filter || a.app.toLowerCase().includes(filter) || (a.repo || '').toLowerCase().includes(filter))
    .sort((a, b) => (b.used || 0) - (a.used || 0));
  if (!sorted.length) { el.innerHTML = '<div class="afhint">no apps match that filter</div>'; return; }
  el.innerHTML = sorted.map((a) => {
    // 'add' mode: apps already in the story render checked + locked (not in addSelectedApps).
    const inStory = addMode === 'add' && addExistingApps.has(a.app);
    const disabled = !a.onDisk || inStory;
    const flag = inStory ? '<span class="afflag">in story</span>'
      : !a.onDisk ? '<span class="afflag">not cloned</span>'
        : (!a.mapped ? '<span class="afflag warn">unmapped</span>' : '');
    return `<label class="afapprow${disabled ? ' disabled' : ''}">
      <input type="checkbox" data-afapp="${esc(a.app)}" ${disabled ? 'disabled' : ''} ${inStory || addSelectedApps.has(a.app) ? 'checked' : ''} />
      <span>${esc(a.repo || a.app)}</span> ${flag}
    </label>`;
  }).join('');
}

// Collapsed by default, and always shows the live selection count so it stays useful closed - the
// summary line is the whole point of collapsing (no need to expand just to see "3 selected").
function renderAddAppsSummary() {
  const el = $('#afAppsSummary');
  if (!el) return;
  const n = addSelectedApps.size;
  const what = addMode === 'add' ? 'new app' : 'app';
  const label = n ? `${n} ${what}${n === 1 ? '' : 's'} selected` : 'Select apps';
  el.textContent = `${label} ${addAppsExpanded ? '▾' : '▸'}`;
}

function toggleAddApps() {
  addAppsExpanded = !addAppsExpanded;
  const body = $('#afAppsBody');
  if (body) body.hidden = !addAppsExpanded;
  renderAddAppsSummary();
}

function afDeriveBranch() {
  if (addBranchTouched) return;
  const key = $('#afKey').value.trim();
  const env = $('#afEnv').value.trim();
  $('#afBranch').value = (key && env) ? `feature/${env}/${key}` : '';
}

// The same #addForm serves both '+ New story' and '+ Add app': in 'add' mode the key/env/branch/
// title come from the story's own node and are locked, the Jira field is hidden, and the app
// checklist shows the current apps checked + disabled so only NEW apps can be ticked.
async function openAddForm(mode = 'new', key = null) {
  addMode = mode === 'add' && key ? 'add' : 'new';
  addTargetKey = addMode === 'add' ? key : null;
  addExistingApps = new Set();
  const lockable = ['afKey', 'afEnv', 'afBranch', 'afTitle'];
  if (addMode === 'add') {
    const n = NODES[key] || {};
    const st = story(key) || {};
    // Node apps are the iu-spelled folder names getApps reports; fall back to the rule's repos.
    const apps = asArr(n.apps).length ? asArr(n.apps) : asArr(st.repos).map((r) => (r === 'ganesha-ui-internal-app' ? 'ganesha-iu-internal-app' : r));
    addExistingApps = new Set(apps.filter(Boolean));
    $('#afKey').value = key;
    $('#afEnv').value = n.env || '';
    $('#afBranch').value = n.branch || '';
    $('#afTitle').value = n.title || '';
    lockable.forEach((id) => { $('#' + id).disabled = true; });
    $('#afJira').parentElement.hidden = true;
    $('#afTitleLbl').textContent = `+ Add app to ${key}`;
    const modeEl = $('#afMode');
    modeEl.textContent = `adds a worktree on ${n.branch || 'the story branch'} - current: ${[...addExistingApps].join(', ') || 'none'}`;
    modeEl.hidden = false;
  } else {
    lockable.forEach((id) => { $('#' + id).disabled = false; });
    $('#afJira').parentElement.hidden = false;
    $('#afTitleLbl').textContent = '+ New story';
    $('#afMode').hidden = true;
  }
  $('#mainView').hidden = true;
  $('#addForm').hidden = false;
  addPlan = null;
  afResult('');
  afButtonsEditing();
  renderAddApps();
  renderAddAppsSummary();
  if (addAppsLoaded) return;
  let res;
  try { res = await send({ type: 'getApps' }); } catch (e) { res = { ok: false, error: String(e) }; }
  addApps = (res && res.ok && Array.isArray(res.apps)) ? res.apps : [];
  if (!res || !res.ok) {
    // Keep addAppsLoaded false on failure (unlike the success path) so reopening the form
    // retries instead of staying stuck on a stale failure for the life of the popup - e.g. the
    // host crashing once on an empty stories.json used to poison every later "+ New story" open.
    addAppsError = (res && res.error) || 'native host gave no response';
    const hint = res && res.nativeHostMissing ? ' (native host unreachable)' : '';
    afResult(`<div class="afwarn">! couldn't list repos${hint}: ${esc(addAppsError)}</div>`);
  } else {
    addAppsError = null;
    addAppsLoaded = true;
  }
  renderAddApps();
}

function closeAddForm() {
  $('#addForm').hidden = true;
  $('#mainView').hidden = false;
  addSelectedApps = new Set();
  addBranchTouched = false;
  addAppsExpanded = false;
  addAppsFilter = '';
  addPlan = null;
  afResult('');
  ['afJira', 'afKey', 'afEnv', 'afBranch', 'afTitle', 'afAppsSearch'].forEach((id) => { const el = $('#' + id); if (el) el.value = ''; });
  $('#afOpen').checked = true;
  $('#afAppsBody').hidden = true;
  addMode = 'new'; addTargetKey = null; addExistingApps = new Set();
  ['afKey', 'afEnv', 'afBranch', 'afTitle'].forEach((id) => { $('#' + id).disabled = false; });
  $('#afJira').parentElement.hidden = false;
  $('#afTitleLbl').textContent = '+ New story';
  $('#afMode').hidden = true;
}

function afValidate() {
  if (addMode === 'add') return addSelectedApps.size ? null : 'select at least one new app';
  const key = $('#afKey').value.trim();
  const env = $('#afEnv').value.trim();
  const branch = $('#afBranch').value.trim();
  if (!key) return 'enter a story key';
  if (!isValidStoryKey(key)) return `invalid key '${key}' — use a Jira key (EH7-9550) or an all-lowercase kebab slug`;
  if (!env) return 'enter an env (e.g. mint2)';
  if (!branch) return 'enter a branch name';
  if (!isValidBranchName(branch)) return `invalid branch name '${branch}'`;
  if (!addSelectedApps.size) return 'select at least one app';
  return null;
}

// "Check & create" step 1: a read-only preview (key/branch/duplicate validity, which apps are
// cloned, new-branch vs existing-branch per app) - the native host's 'addcheck' action, which
// changes nothing. Armed into a ✓/✕ confirm only when it comes back clean.
async function doAddCheck() {
  const err = afValidate();
  if (err) { afResult(`<div class="aferr">✕ ${esc(err)}</div>`); return; }
  if (addChecking) return;
  addChecking = true;
  addPlan = null;
  afResult('checking…');
  const key = $('#afKey').value.trim();
  const env = $('#afEnv').value.trim();
  const branch = $('#afBranch').value.trim();
  const apps = [...addSelectedApps];
  const isAdd = addMode === 'add';
  let res;
  try {
    res = isAdd
      ? await send({ type: 'checkAddApps', key: addTargetKey, apps })
      : await send({ type: 'checkAddWorktree', key, env, apps, branch });
  } catch (e) { res = { ok: false, error: String(e) }; }
  addChecking = false;
  if (!res) { afResult('<div class="aferr">✕ no reply from the native host</div>'); return; }
  const rows = asArr(res.apps).map((a) => {
    const tag = !a.onDisk ? 'NOT CLONED' : (a.inStory && a.present) ? 'already in story' : a.branchExisted ? 'existing branch' : 'new branch';
    return `<div${!a.onDisk ? ' class="aferr"' : ''}>${esc(a.app)}: ${tag}</div>`;
  }).join('');
  const warnHtml = asArr(res.warnings).map((w) => `<div class="afwarn">! ${esc(w)}</div>`).join('');
  if (!res.ok) {
    const hint = res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help)' : '';
    afResult(`${rows}${warnHtml}<div class="aferr">✕ ${esc(res.error || 'blocked')}${hint}</div>`);
    return;
  }
  addPlan = isAdd ? { key: addTargetKey, apps, mode: 'add' } : { key, env, branch, apps, mode: 'new' };
  afResult(`${rows}${warnHtml}<div class="afok">clear to ${isAdd ? 'add' : 'create'} — confirm below</div>`);
  const confirmTitle = isAdd ? `Confirm — add ${apps.length} app(s) to ${esc(addTargetKey)}` : `Confirm — create ${esc(key)}`;
  $('#afButtons').innerHTML = `<button class="ico confirm" data-afconfirm title="${confirmTitle}">✓</button>
    <button class="ico cancel" data-afback title="Back to editing">✕</button>`;
  wireAddButtons();
}

// ✓ confirmed - actually create the node + worktrees. -NoInstall always (dep install can take
// minutes; the host is single-shot and blocks), so a successful create is followed by a reminder
// of the install command rather than waiting on yarn/pip here.
async function doAddCreate() {
  if (!addPlan || addCreating) return;
  addCreating = true;
  afResult('creating…');
  const title = $('#afTitle').value.trim();
  const jiraUrl = $('#afJira').value.trim();
  const openWs = $('#afOpen').checked;
  const { key, env, branch, apps } = addPlan;
  const isAdd = addPlan.mode === 'add';
  let res;
  try {
    res = isAdd
      ? await send({ type: 'addApps', key, apps, open: openWs })
      : await send({ type: 'addWorktree', key, env, apps, branch, title, jiraUrl, open: openWs });
  }
  catch (e) { res = { ok: false, error: String(e) }; }
  addCreating = false;
  const failed = asArr(res && res.failed);
  const created = asArr(res && res.created);
  // switch-story.ps1 new writes the stories.json node BEFORE any git runs, and its final -Json
  // frame (the only one carrying created/failed) is emitted only after that write. So any reply
  // with those fields means the story now exists - even when ok is false because some or ALL apps
  // failed. Close the form and show the outcome on the main view either way: keeping the form open
  // would invite a retry that can only fail with "already exists".
  const registered = !!res && (res.ok || created.length > 0 || 'created' in res || 'failed' in res);
  if (registered) {
    closeAddForm();
    try { await load(); } catch (e) { console.warn('[stg] refresh after create failed:', e); }
    selectStory(key);
    const names = failed.map((f) => f.app).join(', ');
    const added = created.map((c) => c.app).join(', ');
    const okMsg = isAdd
      ? `✓ Added ${added || 'app(s)'} to ${key} — deps not installed, run: switch-story.ps1 install ${key}`
      : `✓ Created ${key} — deps not installed, run: switch-story.ps1 install ${key}`;
    rmMsg(failed.length
      ? (created.length
        ? `⚠ ${key} ${isAdd ? 'updated' : 'created'}, but ${failed.length} app(s) failed: ${names}`
        : `⚠ ${key}${isAdd ? '' : ' registered'}, but no worktree was created (${names}) — see console`)
      : okMsg,
    failed.length ? 'warn' : 'ok');
    if (failed.length) console.warn('[stg] create failures:', failed);
    return;
  }
  const err = (res && (res.error || res.message)) || 'unknown error';
  const hint = res && res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help)' : '';
  afResult(`<div class="aferr">✕ ${esc(err)}${hint}</div>`);
  addPlan = null;
  afButtonsEditing(); // back to the editable step so a failed create can be retried without re-typing
}

function wireAddButtons() {
  const c = $('#afCheck'); if (c) c.onclick = doAddCheck;
  const x = $('#afCancel'); if (x) x.onclick = closeAddForm;
  const ok = $('[data-afconfirm]'); if (ok) ok.onclick = doAddCreate;
  const back = $('[data-afback]'); if (back) back.onclick = () => { addPlan = null; afResult(''); afButtonsEditing(); };
}

// A checked-and-armed plan is frozen at check time (key/env/branch/apps); editing any of those
// after arming must drop back to the editable step, or a stale ✓ could create something other
// than what's now on screen.
function invalidatePlan() { if (addPlan) { addPlan = null; afResult(''); afButtonsEditing(); } }

$('#addStoryBtn').onclick = () => openAddForm('new');
$('#addAppBtn').onclick = () => { if (selectedKey) openAddForm('add', selectedKey); };
$('#afKey').addEventListener('input', () => { invalidatePlan(); afDeriveBranch(); });
$('#afEnv').addEventListener('input', () => { invalidatePlan(); afDeriveBranch(); });
$('#afBranch').addEventListener('input', () => { invalidatePlan(); addBranchTouched = true; });
$('#afJira').addEventListener('input', () => {
  const url = $('#afJira').value.trim();
  const k = RB.jiraKey(url);
  if (k && !$('#afKey').value.trim()) { $('#afKey').value = k; invalidatePlan(); afDeriveBranch(); }
});
document.addEventListener('change', (e) => {
  const cb = e.target.closest('[data-afapp]');
  if (cb) {
    if (cb.checked) addSelectedApps.add(cb.dataset.afapp); else addSelectedApps.delete(cb.dataset.afapp);
    renderAddAppsSummary();
    invalidatePlan();
  }
});
$('#afAppsHdr').onclick = toggleAddApps;
$('#afAppsSearch').addEventListener('input', () => {
  addAppsFilter = $('#afAppsSearch').value;
  renderAddApps();
});

$('#setActive').onclick = setActive;
$('#clearActive').onclick = clearActive;
// Add-a-tab lives on the right-click context menu ('Add to story group'); focusing a group lives
// on the per-row ↪ icon. Neither needs a duplicate button up here.
$('#openLinks').onclick = () => { if (selectedKey) send({ type: 'openLinks', key: selectedKey }); };

// Write/refresh the selected story's .code-workspace and open it in VS Code - unlike creation's
// -Open checkbox, this works any time, for a story that already exists.
async function doOpenWorkspace() {
  if (!selectedKey) return;
  const key = selectedKey;
  rmMsg(`Opening ${key}…`, '');
  let res;
  try { res = await send({ type: 'openWorkspace', key }); } catch (e) { res = { ok: false, error: String(e) }; }
  if (res && res.ok) {
    rmMsg(res.opened ? `✓ Opened ${key} in VS Code` : `✓ Workspace ready for ${key} (the 'code' CLI isn't on PATH — open it manually)`, 'ok');
    return;
  }
  const err = (res && (res.error || res.message)) || 'unknown error';
  const hint = res && res.nativeHostMissing ? ' — run native-host\\install-native-host.ps1, then fully restart the browser (see Help)' : '';
  rmMsg(`✕ ${key}: ${err}${hint}`, 'err');
}
$('#openWorkspaceBtn').onclick = doOpenWorkspace;
$('#opt').onclick = (e) => { e.preventDefault(); chrome.runtime.openOptionsPage(); };
$('#hist').onclick = (e) => { e.preventDefault(); chrome.tabs.create({ url: chrome.runtime.getURL('history.html') }); window.close(); };
$('#help').onclick = (e) => { e.preventDefault(); chrome.tabs.create({ url: chrome.runtime.getURL('help.html') }); window.close(); };

$('#loadFile').onclick = async () => {
  const btn = $('#loadFile');
  const orig = btn.textContent;
  btn.disabled = true;
  btn.textContent = '⟳ …';
  try {
    const res = await RB.syncSilently();
    if (res.needSettings) {
      chrome.runtime.openOptionsPage();
      window.close();
      return;
    }
    await load();
    btn.textContent = `✓ ${res.count} stories`;
    setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 1600);
  } catch (e) {
    btn.textContent = '✕ failed';
    setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 1600);
  }
};

// The doctor banner: read-only reconciliation of registry / folders / ledgers. Surfaced here
// because the drift it finds (an archived story whose folder survived, a node whose ledger is
// behind, a bare-string apps field) is otherwise only ever discovered as an incident.
async function refreshDoctor() {
  const el = $('#docMsg');
  if (!el) return;
  let res;
  try { res = await send({ type: 'runDoctor' }); } catch (_) { return; }
  if (!res || (!res.ok && !res.findings)) { el.textContent = ''; el.className = 'docmsg'; return; }
  const f = asArr(res.findings);
  const errs = f.filter((x) => x.severity === 'error');
  const warns = f.filter((x) => x.severity === 'warn');
  if (!errs.length && !warns.length) { el.textContent = ''; el.className = 'docmsg'; return; }
  const tip = [...errs, ...warns].map((x) => `[${x.severity}] ${x.story}: ${x.detail}${x.fix ? `\n    -> ${x.fix}` : ''}`).join('\n');
  el.textContent = `⚑ registry: ${errs.length} error${errs.length === 1 ? '' : 's'}, ${warns.length} warning${warns.length === 1 ? '' : 's'} — hover for detail`;
  el.title = tip;
  el.className = 'docmsg' + (errs.length ? ' err' : ' warn');
}

console.log('[stg] popup build: worktree-manager-v12 (the +New story app checklist\'s empty state now shows the native host\'s real error instead of always asking "native host installed, and tools\\app-map.json present?" - both could be true while the host had actually crashed on an empty stories.json; a failed getApps also retries on next open instead of staying stuck for the popup\'s lifetime)');
load();
refreshDoctor();
