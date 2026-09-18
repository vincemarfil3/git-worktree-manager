// Worktree manager — service worker.
// Matches tab URLs to a story and drops them into a per-story Chrome tab group.
console.log('[stg-bg] service worker build: worktree-manager-v11; new setAppMap case (Settings > Apps card writes port/start/health to app-map.json via the host\'s setappmap action) and hiddenApps added to the setStgConfig allowlist; fixed a crash in the host\'s apps/check/released actions on a fresh install with an empty stories.json ("stories": {}) that was surfacing as the popup\'s "no repos found" app-checklist message');
importScripts('rules-core.js'); // classic (non-module) SW - defines self.RBCore, shared with rules-lib.js
const TAB_GROUP_ID_NONE = -1; // chrome.tabGroups.TAB_GROUP_ID_NONE

// Native-messaging host id - ONE constant instead of 19 bare string literals, so a rename (or a
// fresh install picking a different host name) is a one-line change, not a grep-and-replace.
const NATIVE_HOST = 'com.storytabgroups.worktree';

// Effective org settings (Jira base URL / GitHub org / repo aliases), cached like rules - read
// from the native host's getConfig action so match/route/build-rules logic stays consistent with
// whatever's configured in Settings, without a host round trip on every call.
let _orgConfig = null;
async function getOrgConfig() {
  if (_orgConfig) return _orgConfig;
  try {
    const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'getConfig' });
    if (res && res.ok) {
      _orgConfig = {
        jiraBaseUrl: res.effectiveJiraBaseUrl,
        githubOrg: res.effectiveGithubOrg,
        repoAliases: res.repoAliases,
      };
    }
  } catch (_) { /* host unreachable - RBCore's own defaults apply */ }
  if (!_orgConfig) _orgConfig = {};
  return _orgConfig;
}
function invalidateOrgConfig() { _orgConfig = null; }

let _rules = null;
async function getRules() {
  if (_rules) return _rules;
  const { rulesOverride } = await chrome.storage.local.get('rulesOverride');
  if (rulesOverride && Array.isArray(rulesOverride.stories)) {
    _rules = rulesOverride;
    return _rules;
  }
  // No saved override yet - ask the native host for stories.json directly and build rules from
  // it in-process (RBCore.buildRules, the same function options.js/rules-lib.js use for the file
  // picker). This is what lets a fresh install show its story list immediately: no Options visit,
  // no file picker, no packaged rules.json to keep in sync - just "is the host reachable and does
  // stories.json exist at the configured root".
  try {
    const org = await getOrgConfig();
    const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'stories' });
    if (res && res.ok && res.json && res.json.trim()) {
      const data = JSON.parse(res.json);
      const built = self.RBCore.buildRules(data, org);
      if (built && Array.isArray(built.stories)) {
        _rules = built;
        // Cache to storage too, so a later cold-start (host briefly unreachable) still has
        // something rather than falling all the way back to the empty packaged rules.json.
        chrome.storage.local.set({ rulesOverride: built }).catch(() => {});
        return _rules;
      }
    }
  } catch (e) {
    console.warn('[stg-bg] host stories/buildRules unavailable, falling back to packaged rules.json:', e && e.message);
  }
  // Packaged fallback may be missing (never generated) or unreadable - degrade to no stories
  // rather than throw, so the popup/context menu still work until stories.json is loaded.
  try {
    const res = await fetch(chrome.runtime.getURL('rules.json'));
    const json = res.ok ? await res.json() : null;
    _rules = json && Array.isArray(json.stories) ? json : { stories: [], generatedAt: null };
  } catch (e) {
    console.warn('[stg-bg] rules.json unavailable, using empty rule set:', e && e.message);
    _rules = { stories: [], generatedAt: null };
  }
  return _rules;
}
function invalidateRules() { _rules = null; }

// For every action that mutates stories.json on disk (remove/add/addapps/release/links/config) -
// NOT the same as invalidateRules() above. getRules() checks chrome.storage.local's persisted
// 'rulesOverride' BEFORE ever reaching the host rebuild (:35-39) - itself written by getRules()'s
// own host-fallback path as resilience against a momentarily-unreachable host (:53-55). Clearing
// only the in-memory _rules (invalidateRules()) is NOT enough: the very next getRules() call just
// re-populates _rules straight back from that stale persisted blob, never reaching the rebuild.
// Confirmed exactly this way: a removal reported "✓ Removed" (the host succeeded, stories.json on
// disk was correct) while the row stayed listed, because the popup's next getState -> getRules()
// kept being served the pre-removal snapshot from storage. This clears BOTH layers, so the next
// read is forced through the host rebuild - safe to call after any of these actions specifically
// because they only ever run after a successful host round-trip, so the rebuild that immediately
// follows is guaranteed to succeed too (and re-populates the storage cache with fresh data, same
// as any other cold start). Deliberately NOT used by saveRulesOverride/clearRulesOverride below -
// those manage 'rulesOverride' themselves and would have their own write undone by this.
async function forceRulesRebuild() {
  _rules = null;
  try { await chrome.storage.local.remove('rulesOverride'); } catch (_) { /* best-effort */ }
  // Also rebuilds the right-click "Add to story group" submenu, which has this exact same
  // staleness problem for a separate reason: it's only ever regenerated on install/startup or
  // from saveRulesOverride/clearRulesOverride, never after a node mutation - so a removed story
  // would keep showing as a menu option, and a new one wouldn't appear, until the SW restarted.
  // rebuildMenus() calls getRules() itself, so this also eagerly repopulates _rules right here
  // rather than leaving every caller to wait for its own next read to trigger the rebuild.
  try { await rebuildMenus(); } catch (_) { /* best-effort */ }
}

async function getSettings() {
  const { autoRoute = false, activeStory = '' } = await chrome.storage.local.get(['autoRoute', 'activeStory']);
  return { autoRoute, activeStory };
}

const storyByKey = (rules, key) => rules.stories.find((s) => s.key === key);

function matchStory(rules, url, activeStory, githubOrg) {
  const u = (url || '').toLowerCase();
  if (!u || u.startsWith('chrome') || u.startsWith('about')) return null;
  // 1) explicit token (story key / REL / AgileTest issue id)
  for (const s of rules.stories) {
    for (const tok of s.match || []) {
      if (tok && u.includes(tok.toLowerCase())) return s;
    }
  }
  // 2) GitHub Actions for a repo belonging to the *active* story (run ids aren't story-specific)
  if (activeStory) {
    const s = storyByKey(rules, activeStory);
    const org = (githubOrg || self.RBCore.DEFAULT_OPTS.githubOrg).toLowerCase();
    for (const repo of (s && s.repos) || []) {
      if (u.includes(`github.com/${org}/${repo.toLowerCase()}`)) return s;
    }
  }
  return null;
}

// Find an existing group (in any window) whose title contains the story key — survives user renames.
async function findGroup(story) {
  const keyL = story.key.toLowerCase();
  for (const g of await chrome.tabGroups.query({})) {
    if ((g.title || '').toLowerCase().includes(keyL)) return g;
  }
  return null;
}

async function addTabToStory(tabId, story) {
  const tab = await chrome.tabs.get(tabId);
  const found = await findGroup(story);
  if (found) {
    if (tab.windowId !== found.windowId) {
      await chrome.tabs.move(tabId, { windowId: found.windowId, index: -1 });
    }
    return chrome.tabs.group({ tabIds: tabId, groupId: found.id });
  }
  const gid = await chrome.tabs.group({ tabIds: tabId });
  await chrome.tabGroups.update(gid, { title: story.title, color: story.color });
  return gid;
}

async function openUrlInStory(url, story, activate = false) {
  const tab = await chrome.tabs.create({ url, active: activate });
  await addTabToStory(tab.id, story);
  return tab.id;
}

async function focusStory(story) {
  const found = await findGroup(story);
  if (!found) return false;
  const tabs = await chrome.tabs.query({ groupId: found.id });
  if (tabs.length) {
    await chrome.windows.update(found.windowId, { focused: true });
    await chrome.tabs.update(tabs[0].id, { active: true });
  }
  return true;
}

// Live state per story: is a matching group open, how many tabs, is it the focused/active one.
async function groupStats(rules) {
  const stats = {};
  const [act] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const activeGroupId = act ? act.groupId : TAB_GROUP_ID_NONE;
  for (const g of await chrome.tabGroups.query({})) {
    const title = (g.title || '').toLowerCase();
    const story = rules.stories.find((s) => title.includes(s.key.toLowerCase()));
    if (!story) continue;
    const tabs = await chrome.tabs.query({ groupId: g.id });
    const cur = stats[story.key] || { open: true, count: 0, active: false, collapsed: g.collapsed, windowId: g.windowId };
    cur.count += tabs.length;
    if (g.id === activeGroupId) cur.active = true;
    stats[story.key] = cur;
  }
  return stats;
}

// ---------- context menu ----------
async function rebuildMenus() {
  await chrome.contextMenus.removeAll();
  const rules = await getRules();
  chrome.contextMenus.create({ id: 'root', title: 'Add to story group', contexts: ['page', 'link'] });
  for (const s of rules.stories) {
    chrome.contextMenus.create({ id: `add:${s.key}`, parentId: 'root', title: s.title, contexts: ['page', 'link'] });
  }
}
chrome.runtime.onInstalled.addListener(rebuildMenus);
chrome.runtime.onStartup.addListener(rebuildMenus);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (typeof info.menuItemId !== 'string' || !info.menuItemId.startsWith('add:')) return;
  const rules = await getRules();
  const story = storyByKey(rules, info.menuItemId.slice(4));
  if (!story) return;
  if (info.linkUrl) await openUrlInStory(info.linkUrl, story, false);
  else if (tab) await addTabToStory(tab.id, story);
});

// ---------- auto-route ----------
chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url) return; // act once, when the URL is set/changed
  const { autoRoute, activeStory } = await getSettings();
  if (!autoRoute) return;
  if (tab.groupId !== TAB_GROUP_ID_NONE) return; // already grouped — don't fight manual placement
  const org = await getOrgConfig();
  const story = matchStory(await getRules(), changeInfo.url, activeStory, org.githubOrg);
  if (!story) return;
  try { await addTabToStory(tabId, story); } catch (_) { /* tab may have closed */ }
});

// ---------- messaging (popup / options) ----------
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    const rules = await getRules();
    switch (msg.type) {
      case 'getState':
        sendResponse({
          stories: rules.stories,
          settings: await getSettings(),
          generatedAt: rules.generatedAt,
          stats: await groupStats(rules),
        });
        break;
      case 'openLinks': {
        const story = storyByKey(rules, msg.key);
        if (story) for (const l of story.links || []) await openUrlInStory(l.url, story, false);
        sendResponse({ ok: !!story, count: story ? (story.links || []).length : 0 });
        break;
      }
      case 'focusStory': {
        const story = storyByKey(rules, msg.key);
        sendResponse({ ok: story ? await focusStory(story) : false });
        break;
      }
      case 'removeWorktree': {
        // Bridge to the local native host (NATIVE_HOST id, above) which runs remove-worktree.ps1.
        // force:true is the typed-CONFIRM path for a blocked story - skips the dirty/unpushed
        // abort. Uncommitted changes are then discarded permanently; unpushed commits stay safe
        // (the branch is kept regardless).
        console.log('[stg-bg] removeWorktree ->', msg.key, msg.discardGenerated ? '(discard generated)' : '', msg.force ? '(FORCE)' : '');
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'remove', story: msg.key, discardGenerated: !!msg.discardGenerated, force: !!msg.force });
          console.log('[stg-bg] native host replied', res);
          // forceRulesRebuild() (not invalidateRules()) - the persisted chrome.storage.local
          // cache has to go too, or the very next read just re-serves the pre-removal snapshot.
          // popup.js's doRemove() used to also call RB.syncSilently() as a second, uncoordinated
          // way to refresh this - removed there, since it could silently overwrite the correct
          // rebuild below with a different (remembered file-picker) file's stale contents.
          if (res && res.ok) await forceRulesRebuild();
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          console.warn('[stg-bg] native host error', e);
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'checkWorktrees': {
        // Read-only blocker status for every story (popup ready/blocked badges).
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'check' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getHistory': {
        // Read stories_history.json via the native host (the extension can't reach the disk).
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'history' });
          if (!res || !res.ok) { sendResponse({ ok: false, error: (res && res.error) || 'native host gave no response' }); break; }
          let removed = [];
          if (res.json && res.json.trim()) {
            const parsed = JSON.parse(res.json);
            // PS collapses a single-element array to a bare object on write - normalize.
            removed = Array.isArray(parsed.removed) ? parsed.removed : (parsed.removed ? [parsed.removed] : []);
          }
          sendResponse({ ok: true, removed });
        } catch (e) {
          console.warn('[stg-bg] getHistory error', e);
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getStories': {
        // stories.json as raw text via the native host -> parsed here. Feeds the per-row metadata
        // chips (env / REL / CHG / links). Cheap: a single file read, no git, no HTTP.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'stories' });
          if (!res || !res.ok) { sendResponse({ ok: false, error: (res && res.error) || 'native host gave no response' }); break; }
          let stories = {};
          if (res.json && res.json.trim()) {
            const parsed = JSON.parse(res.json);
            stories = (parsed && parsed.stories) ? parsed.stories : {};
          }
          sendResponse({ ok: true, stories });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getLedgers': {
        // Every story's phase state in one shot: { KEY: <ledger> }. Also file reads only.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'ledgers' });
          if (!res || !res.ok) { sendResponse({ ok: false, error: (res && res.error) || 'native host gave no response' }); break; }
          let ledgers = {};
          if (res.json && res.json.trim()) { ledgers = JSON.parse(res.json) || {}; }
          sendResponse({ ok: true, ledgers });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'envStatus': {
        // Ports + health for ONE story. On demand only (the row's health button) - this shells out
        // to HTTP probes and can take tens of seconds while a Vite app is still warming.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'envstatus', story: msg.story });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'runDoctor': {
        // Read-only registry/folder/ledger reconciliation (story-doctor.ps1).
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'doctor' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getReleased': {
        // Released state for every story: { KEY: { released, released_posted, deploy, present } }.
        // Pure file reads on the host side, so it is cheap enough for every popup open.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'released' });
          if (!res || !res.ok) { sendResponse({ ok: false, error: (res && res.error) || 'native host gave no response' }); break; }
          sendResponse({ ok: true, stories: res.stories || {} });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setReleased': {
        // Toggle one story's released state. Mutating but NOT destructive: no worktree, folder or
        // registry node is removed - only the ledger's 'deploy' phase and the node's flag move.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'release', story: msg.key, released: !!msg.released, reason: msg.reason, note: msg.note });
          // Story nodes feed getRules()'s host-fallback build (via 'stories') - a stale cache
          // would keep showing the pre-toggle state until the SW restarts. forceRulesRebuild()
          // clears both the in-memory cache and the persisted storage one (see its own comment) -
          // same reasoning applies to addWorktree/addApps/setStoryLinks below, all mutate a node.
          if (res && res.ok) await forceRulesRebuild();
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getApps': {
        // Which repos are actually cloned on disk (+ port-map / usage-count provenance), for the
        // "+ New story" form's app checklist. Pure file/git reads on the host side.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'apps' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setAppMap': {
        // Settings > Apps card - writes app-map.json's per-app port/start/health map (always to
        // the %LOCALAPPDATA% copy; see stg-paths.psm1's Get-StgAppMapPath). msg.apps is the
        // COMPLETE desired map, name -> {port,start,health}, replacing it wholesale.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'setappmap', apps: msg.apps });
          // A changed app list feeds getRules()'s repo/apps handling the same way a changed root
          // does - same invalidation as setStgConfig, for the same reason.
          if (res && res.ok) {
            invalidateOrgConfig();
            await forceRulesRebuild();
          }
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'openWorkspace': {
        // Write/refresh the story's .code-workspace from its current worktrees and launch it in
        // VS Code - for a story that already exists, unlike the create-time -Open checkbox.
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'openworkspace', story: msg.key });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'checkAddWorktree': {
        // Read-only preview of story creation (key/branch validity, which apps are cloned, would
        // the branch be new-from-main or an existing checkout) - changes nothing.
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'addcheck', story: msg.key, env: msg.env, apps: msg.apps, branch: msg.branch });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'addWorktree': {
        // Create a new story: registry node + per-app worktrees via switch-story.ps1 -Json.
        console.log('[stg-bg] addWorktree ->', msg.key, msg.env, msg.apps);
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, {
            action: 'add', story: msg.key, env: msg.env, apps: msg.apps,
            title: msg.title, jiraUrl: msg.jiraUrl, branch: msg.branch, open: msg.open,
          });
          console.log('[stg-bg] native host replied', res);
          // A newly-created story otherwise wouldn't show up in the right-click "Add to story
          // group" menu or match auto-route until the service worker happened to restart.
          if (res && (res.ok || (res.created && res.created.length))) await forceRulesRebuild();
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          console.warn('[stg-bg] native host error', e);
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'checkAddApps': {
        // Read-only preview of adding apps to an existing story - changes nothing.
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'addappscheck', story: msg.key, apps: msg.apps });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'addApps': {
        // Add apps to an existing story: per-app worktrees + node update via switch-story.ps1 add -Json.
        console.log('[stg-bg] addApps ->', msg.key, msg.apps);
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'addapps', story: msg.key, apps: msg.apps, open: msg.open });
          console.log('[stg-bg] native host replied', res);
          if (res && (res.ok || (res.created && res.created.length))) await forceRulesRebuild();
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          console.warn('[stg-bg] native host error', e);
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setStoryLinks': {
        // Add/update/remove named custom links (Abstract, Test plan, ...) on an existing story -
        // the popup's per-row ✎ editor. { key, set:[{label,url},...], remove:['Label',...] }.
        console.log('[stg-bg] setStoryLinks ->', msg.key, msg.set, msg.remove);
        if (!msg.key) { sendResponse({ ok: false, error: 'no story key' }); break; }
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST,
            { action: 'setLinks', story: msg.key, set: msg.set || [], remove: msg.remove || [] });
          if (res && res.ok) await forceRulesRebuild(); // so ↗ Open all picks up the new/removed links immediately
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'pingNativeHost': {
        // Settings page's "Native host" status card - a bare connectivity check, distinct from
        // every other case here in that a failure IS the expected/normal state on a fresh
        // install, not an error to log loudly about.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'ping' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'runPreflight': {
        // Settings page's "Paths & diagnostics" card - the same checks setup.ps1 runs from the
        // terminal, re-run from the browser with no terminal needed.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'preflight' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getStgConfig': {
        // Current root / worktreeRoot / branchFormat settings (Options page), plus what they
        // resolve to right now even when unset. Pure file read on the host side.
        try {
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'getConfig' });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setStgConfig': {
        // Save root / worktreeRoot / workspaceRoot / branchFormat / jiraBaseUrl / githubOrg /
        // taskNamePrefix / owner / repoAliases / hiddenApps. Any field omitted from msg is left
        // as-is; an empty string (or, for hiddenApps, an empty array) for a field that IS present
        // clears just that one.
        try {
          const payload = { action: 'setConfig' };
          for (const k of ['root', 'worktreeRoot', 'workspaceRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner', 'repoAliases', 'hiddenApps']) {
            if (Object.prototype.hasOwnProperty.call(msg, k)) payload[k] = msg[k];
          }
          const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, payload);
          if (res && res.ok) {
            // root/jiraBaseUrl/githubOrg/repoAliases all feed getRules()'s host-fallback build and
            // matchStory()'s org check - a saved change must take effect on the next call, not
            // whatever happened to be cached from before Settings was opened. A changed root in
            // particular means the persisted rulesOverride may now describe a DIFFERENT tree
            // entirely, so this has to clear that too, not just the in-memory pointer.
            invalidateOrgConfig();
            await forceRulesRebuild();
          }
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setSettings':
        await chrome.storage.local.set(msg.settings || {});
        sendResponse({ ok: true });
        break;
      case 'saveRulesOverride':
        await chrome.storage.local.set({ rulesOverride: msg.rules });
        invalidateRules();
        await rebuildMenus();
        sendResponse({ ok: true });
        break;
      case 'clearRulesOverride':
        await chrome.storage.local.remove('rulesOverride');
        invalidateRules();
        await rebuildMenus();
        sendResponse({ ok: true });
        break;
      default:
        sendResponse({ ok: false, error: 'unknown' });
    }
  })();
  return true; // keep the channel open for the async reply
});
