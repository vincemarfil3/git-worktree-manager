// Shared between popup and options: build rules from stories.json + remember the file handle.
// Exposes window.RB. Loaded via <script src="rules-core.js"> then <script src="rules-lib.js">
// before popup.js / options.js - rules-core.js (window.RBCore / self.RBCore) now owns the actual
// buildRules() implementation, shared with background.js via importScripts(), so the two no
// longer risk drifting out of sync (the old comment here used to warn "must stay mirror images").
window.RB = (() => {
  const { COLOR_HEX, buildRules: buildRulesCore, jiraKey } = window.RBCore;

  // opts (jiraBaseUrl/githubOrg/repoAliases) are read from a cached copy of the native host's
  // effective config when available (see readAndApply below), else RBCore's own built-in
  // defaults - identical to this project's original hardcoded values either way.
  let _orgOpts = null;
  function buildRules(data) { return buildRulesCore(data, _orgOpts); }

  // ---- remembered file handle (IndexedDB, shared across popup + options same-origin) ----
  const DB = 'stg-settings', STORE = 'handles';
  const idb = () => new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  const idbSet = async (k, v) => {
    const db = await idb();
    return new Promise((res, rej) => {
      const tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).put(v, k);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  };
  const idbGet = async (k) => {
    const db = await idb();
    return new Promise((res, rej) => {
      const tx = db.transaction(STORE, 'readonly');
      const rq = tx.objectStore(STORE).get(k);
      rq.onsuccess = () => res(rq.result);
      rq.onerror = () => rej(rq.error);
    });
  };

  const getHandle = () => idbGet('storiesJson').catch(() => null);
  const send = (m) => new Promise((r) => chrome.runtime.sendMessage(m, r));

  // Pull the effective org settings (Jira base URL / GitHub org / repo aliases) from the native
  // host via the SW, same source background.js's own getRules() host-fallback path uses, so a
  // file picked here and a stories.json read straight off disk produce identical rules. Best-
  // effort: no host / no config -> RBCore's built-in defaults (today's exact hardcoded values).
  async function loadOrgOpts() {
    try {
      const res = await send({ type: 'getStgConfig' });
      if (res && res.ok) {
        _orgOpts = {
          jiraBaseUrl: res.effectiveJiraBaseUrl,
          githubOrg: res.effectiveGithubOrg,
          repoAliases: res.repoAliases,
        };
      }
    } catch (_) { /* keep defaults */ }
  }

  async function readAndApply(handle) {
    await loadOrgOpts();
    const file = await handle.getFile();
    const text = (await file.text()).replace(/^﻿/, ''); // strip UTF-8 BOM
    const rules = buildRules(JSON.parse(text));
    await send({ type: 'saveRulesOverride', rules });
    return { count: rules.stories.length, name: handle.name };
  }

  // Full sync with file picker (use on the Options page — it survives the dialog).
  async function sync() {
    let handle = await getHandle();
    if (handle && (await handle.queryPermission({ mode: 'read' })) === 'granted') {
      try { return await readAndApply(handle); } catch (_) { /* moved — repick */ }
    }
    if (handle) {
      if ((await handle.requestPermission({ mode: 'read' })) === 'granted') {
        try { return await readAndApply(handle); } catch (_) { /* repick */ }
      }
    }
    [handle] = await window.showOpenFilePicker({
      types: [{ description: 'stories.json', accept: { 'application/json': ['.json'] } }],
      multiple: false,
    });
    await idbSet('storiesJson', handle);
    return readAndApply(handle);
  }

  // syncSilently() (no dialog, popup-safe) used to live here, called only by the popup's own
  // "Load stories.json" button. Removed with that button: it silently pinned a permanent rules
  // override for whichever project was active, and nothing about normal tool use (creating a
  // story) ever cleared it - confirmed live as a real bug. sync() (the file-picker version, used
  // by Settings' Advanced section) is unaffected - that's a deliberate, explicit action from a
  // page framed as a native-host-unreachable fallback, not an ambient one-click control.

  // jiraKey exported so popup.js's "+ New story" form can auto-fill the key from a pasted Jira
  // URL with the same regex buildRules() already uses - one definition, not two.
  return { COLOR_HEX, buildRules, getHandle, sync, jiraKey };
})();
