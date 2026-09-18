// Generates rules.json for the Worktree manager extension from ../stories.json.
// Run: node gen-rules.mjs   (then reload the extension on chrome://extensions, or paste into Settings)
//
// buildRules() itself now lives in ONE place, rules-core.js (shared with the service worker via
// importScripts() and with the popup/options pages via rules-lib.js's window.RB re-export) -
// this used to be a hand-duplicated copy with a comment warning it "must stay a mirror image".
// rules-core.js is a plain (non-module) browser/SW script, so it's loaded here via node:vm with a
// minimal `self` stand-in rather than duplicated a second time for Node.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const __dir = dirname(fileURLToPath(import.meta.url));
const STORIES = join(__dir, '..', 'stories.json');
const OUT = join(__dir, 'rules.json');
const CORE = join(__dir, 'rules-core.js');

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext('var self = this;', sandbox);
vm.runInContext(readFileSync(CORE, 'utf8'), sandbox, { filename: CORE });
const { buildRules } = sandbox.self.RBCore;

// Optional org-settings override, same shape/location as native-host's stg-config.json (only
// jiraBaseUrl / githubOrg / repoAliases matter here - root/worktreeRoot are irrelevant to a
// build-time rules.json). Absent file = RBCore's built-in defaults (today's exact hardcoded values).
const localAppData = process.env.LOCALAPPDATA;
const cfgPath = localAppData ? join(localAppData, 'story-tab-groups', 'stg-config.json') : null;
let opts;
if (cfgPath && existsSync(cfgPath)) {
  try {
    const cfg = JSON.parse(readFileSync(cfgPath, 'utf8').replace(/^﻿/, ''));
    opts = { jiraBaseUrl: cfg.jiraBaseUrl, githubOrg: cfg.githubOrg, repoAliases: cfg.repoAliases };
  } catch (_) { /* fall through to defaults */ }
}

const data = JSON.parse(readFileSync(STORIES, 'utf8').replace(/^﻿/, ''));
const rules = buildRules(data, opts);
writeFileSync(OUT, JSON.stringify(rules, null, 2));
console.log(`Wrote ${OUT}\n  ${rules.stories.length} stories: ${rules.stories.map((o) => `${o.key} [${o.color}]`).join(', ')}`);
