// Worktree manager — service worker.
// Matches tab URLs to a story and drops them into a per-story Chrome tab group.
console.log('[stg-bg] service worker build: worktree-manager-v22 (tracking-mode dev_workspace now lists only actual git repos, not the whole project folder - new openDevWorkspace message -> host "opendev" action)');
importScripts('rules-core.js'); // classic (non-module) SW - defines self.RBCore, shared with rules-lib.js
const TAB_GROUP_ID_NONE = -1; // chrome.tabGroups.TAB_GROUP_ID_NONE

// Same one-liner popup.js/history.js already each have their own copy of - PowerShell's
// ConvertTo-Json collapses a single-element array to a bare scalar, so anything read back from a
// native-host reply needs this before .length/.map/etc.
const asArr = (x) => (Array.isArray(x) ? x : x ? [x] : []);

// Native-messaging host id - ONE constant instead of 19 bare string literals, so a rename (or a
// fresh install picking a different host name) is a one-line change, not a grep-and-replace.
const NATIVE_HOST = 'com.storytabgroups.worktree';

// Effective org settings (Jira base URL / GitHub org / repo aliases), cached PER PROJECT - each
// project can have its own Jira/GitHub org override, read from the native host's getConfig
// -Project action. Keyed by project id ('' for "no project context", the legacy single-root case).
const _orgConfigByProject = new Map();
async function getOrgConfig(projectId) {
  const key = projectId || '';
  if (_orgConfigByProject.has(key)) return _orgConfigByProject.get(key);
  let cfg = {};
  try {
    const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'getConfig', project: projectId });
    if (res && res.ok) {
      // Fallbacks, not a bare pass-through: rules-core.js's Object.assign(DEFAULT_OPTS, opts) copies
      // an `undefined` property straight over the default (Object.assign doesn't skip undefined
      // values), so a host reply missing either field would silently null out the built-in default
      // instead of falling back to it - crashing hasOwnProperty.call(undefined,...) for repoAliases,
      // or producing 'undefined/browse/REL-x' links for jiraBaseUrl. Latent today only because
      // host.ps1 always sends both fields.
      cfg = {
        jiraBaseUrl: res.effectiveJiraBaseUrl || '',
        githubOrg: res.effectiveGithubOrg || '',
        repoAliases: res.repoAliases || {},
      };
    }
  } catch (_) { /* host unreachable - RBCore's own defaults apply */ }
  _orgConfigByProject.set(key, cfg);
  return cfg;
}
function invalidateOrgConfig(projectId) {
  if (projectId) _orgConfigByProject.delete(projectId);
  else _orgConfigByProject.clear();
}

// ---------- per-project rules cache ----------
// rulesCache: { version: 2, builtAt, activeProject, projects: { id: { name, mode, generatedAt, stories:[...] } } }
// rulesOverrides: { id: { stories:[...], generatedAt, source } } - a manually-saved override (the
// Options page's paste-JSON box, or the file-picker sync), keyed by the project it was saved FOR.
// A project's slice prefers its own entry here over its own auto-build when present. Replaces the
// old flat 'rulesOverride' key, which conflated the auto-build's own resilience cache with a
// genuine user override indistinguishably, and had no notion of which root/project either one
// described at all - the actual blocker to supporting more than one project.
let _rulesCache = null;

async function buildProjectRules(id, meta, rawJson, overridesMap) {
  const override = overridesMap && overridesMap[id];
  if (override && Array.isArray(override.stories)) {
    // Still stamp project/projectName - a saved override predates multi-project and its stories
    // won't carry these yet, and every consumer (matchStory, storyByKey, the context menu) relies
    // on them being present regardless of which path produced the story list. overridden:true lets
    // the popup show a "you're viewing a saved snapshot, not live data" notice instead of leaving
    // it silently unclear why a real change doesn't appear - the actual gap that let this go
    // undiagnosed for two real story creations in a row before clearProjectOverride() existed.
    const stories = override.stories.map((s) => ({ ...s, project: id, projectName: meta.name }));
    return { name: meta.name, mode: meta.mode, generatedAt: override.generatedAt, stories, overridden: true };
  }
  let data = { stories: {} };
  if (rawJson && rawJson.trim()) { try { data = JSON.parse(rawJson); } catch (_) { /* leave empty */ } }
  const org = await getOrgConfig(id);
  const built = self.RBCore.buildRules(data, org);
  const stories = built.stories.map((s) => ({ ...s, project: id, projectName: meta.name }));
  return { name: meta.name, mode: meta.mode, generatedAt: built.generatedAt, stories, overridden: false };
}

// One host round trip for every project's raw stories.json (native-host\host.ps1's 'allstories'
// action, P3), one local buildRules() per project - not N host round trips on cold start.
async function buildAllRules() {
  const out = { version: 2, builtAt: Date.now(), activeProject: null, projects: {} };
  const { rulesOverrides } = await chrome.storage.local.get('rulesOverrides');
  try {
    const res = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: 'allstories' });
    if (res && res.ok && res.projects) {
      out.activeProject = res.activeProject || null;
      for (const [id, p] of Object.entries(res.projects)) {
        out.projects[id] = await buildProjectRules(id, p, p.json, rulesOverrides);
      }
      return out;
    }
  } catch (e) {
    console.warn('[stg-bg] allstories unavailable, falling back to packaged rules.json:', e && e.message);
  }
  // Host fully unreachable (or replied ok:false) - degrade to the packaged rules.json as an
  // UNNAMED single project, today's exact fallback behaviour, unchanged from before this existed.
  try {
    const res = await fetch(chrome.runtime.getURL('rules.json'));
    const json = res.ok ? await res.json() : null;
    const stories = (json && Array.isArray(json.stories)) ? json.stories : [];
    out.projects[''] = { name: '', mode: 'worktree', generatedAt: json && json.generatedAt, stories };
  } catch (e) {
    console.warn('[stg-bg] rules.json unavailable, using empty rule set:', e && e.message);
  }
  return out;
}

async function getRulesCache() {
  if (_rulesCache) return _rulesCache;
  const { rulesCache } = await chrome.storage.local.get('rulesCache');
  if (rulesCache && rulesCache.version === 2 && rulesCache.projects) {
    _rulesCache = rulesCache;
    return _rulesCache;
  }
  _rulesCache = await buildAllRules();
  chrome.storage.local.set({ rulesCache: _rulesCache }).catch(() => {});
  return _rulesCache;
}

// ALL stories across every project, flattened - for auto-route matching, which must never be
// scoped to just whichever project the popup happens to have selected (flip the dropdown, your
// Jira tabs would stop grouping), and for the context menu / story-by-key lookups that need to
// find a story regardless of which project it lives in.
async function getAllStories() {
  const cache = await getRulesCache();
  return Object.values(cache.projects).flatMap((p) => p.stories || []);
}

// Just ONE project's stories (the requested one, or the cache's own activeProject) - for the
// popup's displayed list, which only ever shows one project at a time.
async function getProjectRules(projectId) {
  const cache = await getRulesCache();
  const id = projectId || cache.activeProject;
  const p = id != null && cache.projects[id];
  return {
    stories: (p && p.stories) || [],
    generatedAt: p && p.generatedAt,
    projectId: id || null,
    projectName: (p && p.name) || '',
    mode: (p && p.mode) || 'worktree',
    overridden: !!(p && p.overridden),
  };
}

// One story by key, preferring a specific project on a collision - two projects can legitimately
// hold the same Jira key, and the caller (the popup, the context menu) usually knows which one it
// actually means.
const storyByKey = (allStories, key, preferProject) => {
  const matches = allStories.filter((s) => s.key === key);
  if (!matches.length) return null;
  if (preferProject) {
    const preferred = matches.find((s) => s.project === preferProject);
    if (preferred) return preferred;
  }
  return matches[0];
};

// Clears the whole cache and forces a full rebuild on the next read. Simpler and safer than a
// true per-project partial rebuild: buildAllRules() is already one cheap host round trip
// (allstories) regardless of how many projects exist, and a full rebuild can never leave one
// project's slice stale relative to another's - which a partial-rebuild implementation could get
// wrong in its own new way. Matches the original single-project version's own behaviour (always a
// full clear + rebuild), just operating on the new per-project cache internally.
async function forceRulesRebuild() {
  _rulesCache = null;
  try { await chrome.storage.local.remove('rulesCache'); } catch (_) { /* best-effort */ }
  // Also rebuilds the right-click "Add to story group" submenu, which has this exact same
  // staleness problem for a separate reason: it's only ever regenerated on install/startup or
  // from saveRulesOverride/clearRulesOverride, never after a node mutation - so a removed story
  // would keep showing as a menu option, and a new one wouldn't appear, until the SW restarted.
  try { await rebuildMenus(); } catch (_) { /* best-effort */ }
}

// A saved rulesOverride (Settings' Advanced paste/picker box) is deliberately given priority over
// live data in buildProjectRules() - a "trust my curation" escape hatch, by original pre-multi-
// project design. But nothing about that design accounted for a story mutation happening THROUGH
// this tool after the override was saved: forceRulesRebuild() only ever cleared the auto-built
// cache, never rulesOverrides (a separate storage key), so an override silently outlived every
// real change made through the extension itself - confirmed live: two real, host-confirmed story
// creations in a row, neither ever showing in the popup, because an override saved earlier (via
// the file-picker "Load stories.json" button) was still pinned for that project. Once ANY real
// mutation happens to a project's stories via this tool, its override is guaranteed stale (missing
// at minimum whatever just changed), so it's cleared here - called from every case that actually
// mutates a story node for a specific project (addWorktree/addApps/removeWorktree/setReleased/
// setStoryLinks), never from a settings/app-map/project-CRUD case, which don't touch story data and
// shouldn't nuke an override kept for an unrelated reason (custom colors, a curated snapshot).
async function clearProjectOverride(projectId) {
  if (!projectId) return;
  try {
    const { rulesOverrides = {} } = await chrome.storage.local.get('rulesOverrides');
    if (Object.prototype.hasOwnProperty.call(rulesOverrides, projectId)) {
      delete rulesOverrides[projectId];
      await chrome.storage.local.set({ rulesOverrides });
    }
  } catch (_) { /* best-effort, matching forceRulesRebuild's own error handling */ }
}

async function getSettings() {
  const { autoRoute = false, activeStory = '' } = await chrome.storage.local.get(['autoRoute', 'activeStory']);
  return { autoRoute, activeStory };
}

// activeStory's OWN project's GitHub org (org settings are per-project now) is needed for the
// GitHub-Actions match below, so this is async and resolves it internally rather than taking it
// as a parameter the way the single-project version did.
async function matchStory(allStories, url, activeStory) {
  const u = (url || '').toLowerCase();
  if (!u || u.startsWith('chrome') || u.startsWith('about')) return null;
  // 1) explicit token (story key / REL / AgileTest issue id)
  for (const s of allStories) {
    for (const tok of s.match || []) {
      if (tok && u.includes(tok.toLowerCase())) return s;
    }
  }
  // 2) GitHub Actions for a repo belonging to the *active* story (run ids aren't story-specific)
  if (activeStory) {
    const s = allStories.find((x) => x.key === activeStory);
    if (s) {
      const org = await getOrgConfig(s.project);
      const githubOrg = (org.githubOrg || self.RBCore.DEFAULT_OPTS.githubOrg).toLowerCase();
      for (const repo of s.repos || []) {
        if (u.includes(`github.com/${githubOrg}/${repo.toLowerCase()}`)) return s;
      }
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

// ---------- context menu ----------
// Lists stories from EVERY project (you may want to route a tab to a story in a project the popup
// isn't currently showing) - prefixed by project name once 2+ projects exist, to disambiguate a
// key that more than one project happens to share. Menu item ids carry the project id too, so the
// click handler can resolve back to the exact right story rather than guessing via preferProject.
//
// Three independent triggers call this (onInstalled, onStartup, and forceRulesRebuild() after
// every story mutation) with no coordination between them, so two calls can genuinely overlap -
// e.g. a story mutation landing right as the extension reloads. chrome.contextMenus.create() has
// no promise/throw on error, only an optional callback + chrome.runtime.lastError, so an
// overlapping create({id:'root'}) before the first call's own removeAll() has caught up produces
// exactly "Unchecked runtime.lastError: Cannot create item with duplicate id root" - confirmed
// live. _rebuildMenusChain serializes every call through one promise chain so a second call always
// waits for the first to fully finish (its own removeAll() included) before starting its own,
// closing the race rather than just silencing the error it produces.
let _rebuildMenusChain = Promise.resolve();
function rebuildMenus() {
  _rebuildMenusChain = _rebuildMenusChain.then(rebuildMenusNow, rebuildMenusNow);
  return _rebuildMenusChain;
}
// create()'s callback checks lastError as defense-in-depth, not the primary fix - even with the
// chain above, a menu item another queued call already created underneath us is harmless to
// report and swallow, never worth surfacing as console noise.
function createMenuItem(props) {
  chrome.contextMenus.create(props, () => { void chrome.runtime.lastError; });
}
async function rebuildMenusNow() {
  await chrome.contextMenus.removeAll();
  const allStories = await getAllStories();
  const projectCount = new Set(allStories.map((s) => s.project)).size;
  createMenuItem({ id: 'root', title: 'Add to story group', contexts: ['page', 'link'] });
  for (const s of allStories) {
    const title = (projectCount > 1 && s.projectName) ? `${s.projectName}: ${s.title}` : s.title;
    createMenuItem({ id: `add:${s.project || ''}:${s.key}`, parentId: 'root', title, contexts: ['page', 'link'] });
  }
}
chrome.runtime.onInstalled.addListener(rebuildMenus);
chrome.runtime.onStartup.addListener(rebuildMenus);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  // Whole body wrapped, not just the final action: an MV3 service worker can be mid-respawn when
  // any of these chrome.* calls fire (e.g. "Error: No SW"), and an uncaught rejection in a top-level
  // listener callback surfaces as raw, alarming "Uncaught (in promise)" console noise with nothing
  // the user can act on - swallow it, matching the existing "tab may have closed" precedent below.
  try {
    if (typeof info.menuItemId !== 'string' || !info.menuItemId.startsWith('add:')) return;
    const rest = info.menuItemId.slice(4);
    const sep = rest.indexOf(':');
    const projectId = rest.slice(0, sep);
    const key = rest.slice(sep + 1);
    const allStories = await getAllStories();
    const story = storyByKey(allStories, key, projectId);
    if (!story) return;
    if (info.linkUrl) await openUrlInStory(info.linkUrl, story, false);
    else if (tab) await addTabToStory(tab.id, story);
  } catch (_) { /* transient MV3/SW error - nothing actionable, don't spam the console */ }
});

// ---------- auto-route ----------
chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  // Whole body wrapped - see the identical comment on contextMenus.onClicked just above. Previously
  // only addTabToStory was guarded; getSettings()/getAllStories()/matchStory() were not, and a
  // transient "No SW" rejection from any of them (confirmed live in chrome://extensions) surfaced as
  // an uncaught rejection here.
  try {
    if (!changeInfo.url) return; // act once, when the URL is set/changed
    const { autoRoute, activeStory } = await getSettings();
    if (!autoRoute) return;
    if (tab.groupId !== TAB_GROUP_ID_NONE) return; // already grouped — don't fight manual placement
    const story = await matchStory(await getAllStories(), changeInfo.url, activeStory);
    if (!story) return;
    await addTabToStory(tabId, story);
  } catch (_) { /* tab may have closed, or a transient MV3/SW error - nothing actionable */ }
});

// ---------- messaging (popup / options) ----------
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    // Every native-host call threads msg.project through automatically - replaces manually adding
    // `project: msg.project` to ~25 individual sendNativeMessage payloads below. A message that
    // doesn't carry a project (or carries '') sends project:'' through, which host.ps1's
    // Resolve-StgPaths treats identically to "not given" (falls back to the active project / the
    // legacy single-root chain) - no special-casing needed here for that transition.
    //
    // Race against a timeout: the 'apps' action's disk scan can shell out to git, and a hung
    // credential prompt (a rare but real failure mode - a stale/expired credential-manager entry)
    // blocks that single-shot host process indefinitely. Chrome's own native-messaging port has no
    // built-in timeout, so without this the popup just sits there with no feedback. This doesn't
    // kill the underlying host process (there's no API for that here) - it only stops the JS side
    // from waiting on it forever, so the failure is at least visible instead of silent.
    const sendHost = (action, extra = {}) => Promise.race([
      chrome.runtime.sendNativeMessage(NATIVE_HOST, { action, project: msg.project, ...extra }),
      new Promise((_, reject) => setTimeout(
        () => reject(new Error('native host timed out - a git prompt may be waiting for input')), 25000)),
    ]);

    switch (msg.type) {
      case 'getState': {
        const { stories, generatedAt, overridden } = await getProjectRules(msg.project);
        // jiraBaseUrl/repoAliases: same per-project org config buildProjectRules() already fetches
        // to build each story's own (correct) links - the popup needs its own copy too, for the REL
        // chip (which used to hardcode vesta.atlassian.net) and the iu/ui repo-alias fallback (which
        // used to hardcode that one pair instead of reading the project's configured aliases).
        const org = await getOrgConfig(msg.project);
        sendResponse({
          stories,
          settings: await getSettings(),
          generatedAt,
          overridden,
          jiraBaseUrl: org.jiraBaseUrl || '',
          repoAliases: org.repoAliases || {},
        });
        break;
      }
      case 'getProjects': {
        // Forwards to host.ps1's 'projects' action (P3) - root-independent, so the popup's project
        // dropdown / Settings' Projects card can render even on a totally broken install.
        try {
          const res = await sendHost('projects');
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'addProject': {
        try {
          // mode: 'worktree' (default) or 'tracking' - P5's Settings mode selector; host.ps1's own
          // action validates against the same allow-list rather than trusting this wholesale.
          const res = await sendHost('addProject', { name: msg.name, root: msg.root, mode: msg.mode });
          if (res && res.ok) await forceRulesRebuild();
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'installSkill': {
        // Settings' Agent integration card (story-tab-groups/setup-dev-loop) AND its Optional
        // skills card (nextjs-project-architecture, shadcn-from-mantine - generic/non-project skills) share this one
        // case - msg.skill picks which (background.js never defaults it; host.ps1's own
        // 'installskill' action falls back to 'story-tab-groups' when omitted, so every existing
        // caller that doesn't pass skill keeps working unchanged). install:true also writes the
        // file/folder (the Install button); install:false (or omitted) only renders the content,
        // for the Codex/ChatGPT copy buttons - one rendering path on the host side
        // (install-agent-skill.ps1), reused by every consumer here too, so none of them can drift
        // out of sync with each other.
        try {
          const res = await sendHost('installskill', { scope: msg.scope, install: msg.install, skill: msg.skill });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getProjectConfig': {
        // Read counterpart to setProjectConfig - ONE named project's own raw fields, addressed
        // directly by id rather than via getStgConfig's active-project top-level mirror. Settings'
        // "Worktree paths"/"Organization settings"/"Apps" cards use this for the active project
        // (options.js's ACTIVE_PROJECT) so a Save can't race a mirror that's mid-refresh from a
        // just-fired Set active click.
        try {
          const res = await sendHost('getProjectConfig', { id: msg.id });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setProjectConfig': {
        try {
          const payload = { id: msg.id };
          for (const k of ['name', 'root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner', 'repoAliases', 'hiddenApps']) {
            if (Object.prototype.hasOwnProperty.call(msg, k)) payload[k] = msg[k];
          }
          const res = await sendHost('setProjectConfig', payload);
          if (res && res.ok) { invalidateOrgConfig(msg.id); await forceRulesRebuild(); }
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'removeProject': {
        try {
          const res = await sendHost('removeProject', { id: msg.id });
          if (res && res.ok) { invalidateOrgConfig(msg.id); await forceRulesRebuild(); }
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'openLinks': {
        const story = storyByKey(await getAllStories(), msg.key, msg.project);
        if (story) for (const l of story.links || []) await openUrlInStory(l.url, story, false);
        sendResponse({ ok: !!story, count: story ? (story.links || []).length : 0 });
        break;
      }
      case 'focusStory': {
        const story = storyByKey(await getAllStories(), msg.key, msg.project);
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
          const res = await sendHost('remove', { story: msg.key, discardGenerated: !!msg.discardGenerated, force: !!msg.force });
          console.log('[stg-bg] native host replied', res);
          // forceRulesRebuild() (not just clearing an in-memory pointer) - the persisted
          // chrome.storage.local cache has to go too, or the very next read just re-serves the
          // pre-removal snapshot. popup.js's doRemove() used to also call RB.syncSilently() as a
          // second, uncoordinated way to refresh this - removed there, since it could silently
          // overwrite the correct rebuild below with a different (remembered file-picker) file's
          // stale contents. clearProjectOverride() closes the same class of bug one layer up: a
          // SAVED override (not just the auto-built cache) would otherwise keep masking this
          // removal indefinitely too.
          if (res && res.ok) { await forceRulesRebuild(); await clearProjectOverride(msg.project); }
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
          const res = await sendHost('check');
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'getHistory': {
        // Read stories_history.json via the native host (the extension can't reach the disk).
        try {
          const res = await sendHost('history');
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
          const res = await sendHost('stories');
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
        //
        // Two genuinely different failure modes here, kept separate rather than one catch
        // conflating both as nativeHostMissing - the host being unreachable (real "not installed /
        // not registered" case) vs. the host replying fine but with JSON that won't parse (used to
        // mean one malformed ledger file corrupted host.ps1's string-concatenated payload; that
        // string-concatenation itself is also fixed, in host.ps1's 'ledgers' action, so this parse
        // failure should be rare now, but the reply shape still deserves an accurate label).
        let res;
        try {
          res = await sendHost('ledgers');
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
          break;
        }
        if (!res || !res.ok) { sendResponse({ ok: false, error: (res && res.error) || 'native host gave no response' }); break; }
        try {
          const ledgers = (res.json && res.json.trim()) ? (JSON.parse(res.json) || {}) : {};
          sendResponse({ ok: true, ledgers });
        } catch (e) {
          sendResponse({ ok: false, error: 'ledgers reply was not valid JSON: ' + ((e && e.message) ? e.message : String(e)) });
        }
        break;
      }
      case 'envStatus': {
        // Ports + health for ONE story. On demand only (the row's health button) - this shells out
        // to HTTP probes and can take tens of seconds while a Vite app is still warming.
        try {
          const res = await sendHost('envstatus', { story: msg.story });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'runDoctor': {
        // Read-only registry/folder/ledger reconciliation (story-doctor.ps1).
        try {
          const res = await sendHost('doctor');
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
          const res = await sendHost('released');
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
          const res = await sendHost('release', { story: msg.key, released: !!msg.released, reason: msg.reason, note: msg.note });
          // Story nodes feed getRules()'s host-fallback build (via 'stories') - a stale cache
          // would keep showing the pre-toggle state until the SW restarts. forceRulesRebuild()
          // clears both the in-memory cache and the persisted storage one (see its own comment) -
          // same reasoning applies to addWorktree/addApps/setStoryLinks below, all mutate a node.
          // clearProjectOverride() alongside it for the same reason it's needed at every other
          // node-mutating case - see its own comment.
          if (res && res.ok) { await forceRulesRebuild(); await clearProjectOverride(msg.project); }
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
          const res = await sendHost('apps');
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
          const res = await sendHost('setappmap', { apps: msg.apps });
          // A changed app list feeds getRules()'s repo/apps handling the same way a changed root
          // does - same invalidation as setStgConfig, for the same reason.
          if (res && res.ok) {
            invalidateOrgConfig(msg.project);
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
          const res = await sendHost('openworkspace', { story: msg.key });
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'openMainWorkspace': {
        // Project-wide (not per-story) planning workspace - regenerated fresh every open in
        // worktree mode (picks up newly-cloned apps), written once at project-add time in tracking
        // mode. No story key involved; sendHost already injects msg.project.
        try {
          const res = await sendHost('openmain');
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'openDevWorkspace': {
        // Tracking-mode only - dev_workspace lists just the actual git repos under the project
        // root (not the root itself), regenerated fresh on every open same as main_workspace in
        // worktree mode. host's 'opendev' action -> switch-story.ps1's Invoke-OpenDev, which
        // returns ok:false cleanly if the active project is worktree mode.
        try {
          const res = await sendHost('opendev');
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
          const res = await sendHost('addcheck', { story: msg.key, env: msg.env, apps: msg.apps, branch: msg.branch });
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
          const res = await sendHost('add', {
            story: msg.key, env: msg.env, apps: msg.apps,
            title: msg.title, jiraUrl: msg.jiraUrl, branch: msg.branch, open: msg.open,
          });
          console.log('[stg-bg] native host replied', res);
          // A newly-created story otherwise wouldn't show up in the right-click "Add to story
          // group" menu or match auto-route until the service worker happened to restart.
          // clearProjectOverride() closes the other half of this: without it, a story genuinely
          // created here (confirmed on disk, confirmed by the native host) could still never show
          // in the popup at all if a saved override for this project was pinned earlier - the
          // exact bug a live smoke test hit, twice, before this fix existed.
          if (res && (res.ok || asArr(res.created).length)) {
            await forceRulesRebuild();
            await clearProjectOverride(msg.project);
          }
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
          const res = await sendHost('addappscheck', { story: msg.key, apps: msg.apps });
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
          const res = await sendHost('addapps', { story: msg.key, apps: msg.apps, open: msg.open });
          console.log('[stg-bg] native host replied', res);
          if (res && (res.ok || asArr(res.created).length)) {
            await forceRulesRebuild();
            await clearProjectOverride(msg.project);
          }
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
          const res = await sendHost('setLinks', { story: msg.key, set: msg.set || [], remove: msg.remove || [] });
          // so ↗ Open all picks up the new/removed links immediately; clearProjectOverride for the
          // same reason it's needed at every other node-mutating case.
          if (res && res.ok) { await forceRulesRebuild(); await clearProjectOverride(msg.project); }
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
          const res = await sendHost('ping');
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
          const res = await sendHost('preflight');
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
          const res = await sendHost('getConfig');
          sendResponse(res || { ok: false, error: 'native host gave no response' });
        } catch (e) {
          sendResponse({ ok: false, nativeHostMissing: true, error: (e && e.message) ? e.message : String(e) });
        }
        break;
      }
      case 'setStgConfig': {
        // Save root / worktreeRoot / workspaceRoot / branchFormat / jiraBaseUrl / githubOrg /
        // taskNamePrefix / owner / repoAliases / hiddenApps / activeProject. Any field omitted
        // from msg is left as-is; an empty string (or, for hiddenApps, an empty array) for a field
        // that IS present clears just that one. This is the LEGACY flat-active-project path - the
        // popup's project dropdown uses it (activeProject) to switch which project is active;
        // Settings' per-project cards use setProjectConfig instead once a NON-active project is
        // selected there.
        try {
          const extra = {};
          for (const k of ['root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner', 'repoAliases', 'hiddenApps', 'activeProject']) {
            if (Object.prototype.hasOwnProperty.call(msg, k)) extra[k] = msg[k];
          }
          const res = await sendHost('setConfig', extra);
          if (res && res.ok) {
            // root/jiraBaseUrl/githubOrg/repoAliases/activeProject all feed getRulesCache()'s
            // host-fallback build and matchStory()'s org check - a saved change must take effect
            // on the next call, not whatever happened to be cached from before. A changed root or
            // active project in particular means the persisted cache may now describe a DIFFERENT
            // tree entirely, so this has to clear the whole cache, not just one project's slice.
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
      case 'saveRulesOverride': {
        // Keyed by the project it was saved FOR - defaults to whichever project is currently
        // active if the caller doesn't say (options.js / rules-lib.js not yet updated to pass one
        // explicitly still behave exactly as a single-project install always has). Never applies
        // to any OTHER project, closing the exact cross-project leak an untagged override would
        // otherwise create.
        const cache = await getRulesCache();
        const id = msg.project || cache.activeProject || '';
        const { rulesOverrides = {} } = await chrome.storage.local.get('rulesOverrides');
        rulesOverrides[id] = msg.rules;
        await chrome.storage.local.set({ rulesOverrides });
        await forceRulesRebuild();
        sendResponse({ ok: true });
        break;
      }
      case 'clearRulesOverride': {
        const cache = await getRulesCache();
        const id = msg.project || cache.activeProject || '';
        const { rulesOverrides = {} } = await chrome.storage.local.get('rulesOverrides');
        delete rulesOverrides[id];
        await chrome.storage.local.set({ rulesOverrides });
        await forceRulesRebuild();
        sendResponse({ ok: true });
        break;
      }
      default:
        sendResponse({ ok: false, error: 'unknown' });
    }
  })().catch((e) => {
    // Most cases already catch their own native-host errors, but a throw outside any of those
    // (e.g. a transient MV3 "No SW" rejection - see the identical comment on the two listeners
    // above) would otherwise both spam the console AND leave the caller's sendMessage promise
    // hanging forever with no reply at all. sendResponse itself can throw if the channel already
    // closed (e.g. the popup was dismissed mid-call) - swallow that too, nothing to do about it.
    try { sendResponse({ ok: false, error: (e && e.message) ? e.message : String(e) }); } catch (_) {}
  });
  return true; // keep the channel open for the async reply
});
