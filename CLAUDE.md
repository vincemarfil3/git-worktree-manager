# Worktree manager — Chrome/Edge extension

A local, **standalone, self-contained MV3 browser extension** that does two jobs for the worktree
workflow. It is **not** part of any app repo — it's personal tooling that reads one or more
**projects**, each its own independent `stories.json` registry (the same file the
`tools\switch-story.ps1` CLI manages) with its own worktree root, apps and Jira/GitHub org settings
— added in Settings, switched via **Set active** there, with the popup always reflecting whichever
one is currently active. See [Projects (multi-project support)](#projects-multi-project-support)
below. "Standalone" specifically means:
every PowerShell script it needs lives in this extension's own [`tools/`](tools/) folder (nothing
at a fixed sibling path like a `Ganesha\tools\`), and *where your data actually lives* — the
`stories.json` root, the worktree root, the workspace dir — is resolved by `tools\stg-paths.psm1`
(parameter → `%LOCALAPPDATA%\story-tab-groups\stg-config.json` → `$env:STG_ROOT` → auto-detect —
config outranks the env var precisely so a long-lived browser's frozen environment can never
silently override what Settings actually has configured; see the "Standalone / portability"
section below for why that order bit once),
never hardcoded. Copy this whole folder to a different machine, run `.\setup.ps1` once, and it
works — see [Standalone / portability](#standalone--portability) below.

1. **Tab grouping** — groups Chrome/Edge tabs into one per-story tab group (Jira / REL / AgileTest /
   GitHub Actions, …), with manual add, right-click menu, and auto-route.
2. **➕ New story** — a form that registers the `stories.json` node and cuts a git worktree per app,
   the creation counterpart to 🗑, bridged out of the sandbox the same way.
3. **🗑 Remove worktree** — a per-row button that runs the full guardrailed "remove worktree"
   teardown on the local machine (folders + `stories.json` node + `.code-workspace`), bridged out
   of the sandbox via a Chrome **Native Messaging** host.
4. **🚀 Released toggle** — marks a story shipped *without* removing anything, so finished work
   stops looking active while its worktree stays on disk. Toggles back for a revert/rollback.

> Load it unpacked: `chrome://extensions` → Developer mode → **Load unpacked** → this folder.
> Pin it. Per-row icons: **⚡** ports/health · **🚀** released toggle · **↪** focus group · **♻** discard generated & remove (only when generated files are the sole blocker) · **🗑** remove worktree.
> Above the list: **+ New story** (creation form), **↗ Open all**, **📂 Open workspace** (write/
> refresh the selected story's `.code-workspace` from its current worktrees and launch it — for a
> story that already exists, unlike creation's one-time `-Open` checkbox), and the **★ Set active /
> Clear active** pair. The Current-tab line, the Selected chip, the paste-a-URL row, **+ Add tab** and the
> duplicate **↪ Focus** button were removed as redundant: adding a tab is the right-click **Add to
> story group** menu, focusing is the per-row ↪, and the selected story is shown by the highlighted
> row. (`addCurrentTab` / `openUrl` were the last vestiges of that and have since been deleted from
> `background.js` — they had no caller.)
> Each row also shows a **ready / blocked** badge (clean-to-remove vs the blocker summary) and, once shipped, a **✔ released** chip.

---

## File map

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest. Permissions: `tabs`, `tabGroups`, `contextMenus`, `storage`, **`nativeMessaging`**. Declares `icons` + `action.default_icon` (16/32/48/128px, `icons/`). |
| `icons/` | Toolbar/extensions-page icon, generated from `..\tree.svg` (a 512×512 vtracer-traced SVG — regenerate by re-rendering it at each size if it ever needs to change; the SVG originally had no `viewBox`, which must stay fixed or re-scaling crops instead of scaling). |
| `background.js` | Service worker. Tab→story matching, auto-route, context menu, and the `onMessage` switch the popup/options talk to (incl. **`removeWorktree`**, **`getHistory`**, **`checkWorktrees`**, **`getReleased`**, **`setReleased`**, **`addWorktree`**, **`checkAddWorktree`**, **`addApps`**, **`checkAddApps`**, **`getApps`**, **`setAppMap`**, **`openWorkspace`**, **`openMainWorkspace`**, **`openDevWorkspace`**, **`getStgConfig`**, **`setStgConfig`**, **`runPreflight`**, **`getProjects`**, **`addProject`**, **`getProjectConfig`**, **`setProjectConfig`**, **`removeProject`**, **`installSkill`** → native host). One `NATIVE_HOST` constant (`com.storytabgroups.worktree`) everything sends to — not a literal repeated per call site. A `sendHost(action, extra)` closure auto-injects `project: msg.project` into every forwarded native message. The rules cache is **per-project** (`rulesCache.projects[id]`, built in one `allstories` round trip; `rulesOverrides` keyed by project id) — tab matching spans every project, only `getState`'s reply scopes to one. `importScripts('rules-core.js')` for the shared `buildRules()`. Logs a build marker `[stg-bg] service worker build: …`. |
| `popup.html` / `popup.js` | The toolbar popup UI. An always-visible **`#projLabel`** above the controls names whichever project is currently active (with a **Switch project** link to Settings — see [Projects](#projects-multi-project-support)). Renders the story list + action icons, per-row **ready/blocked badges** (from `checkWorktrees`), the **✔ released chip**, the **+ New story** creation form — its own full-panel view (`#addForm` replaces `#mainView` while open, not shown alongside the list — a long app checklist would flood the 328px popup otherwise), with a **collapsible, searchable app checklist** inside it (collapsed by default, showing a live "N apps selected" summary; a filter box narrows by app/repo name; an empty-state that surfaces the native host's *actual* error, not a generic "is X present?" guess — see the dev gotcha below) — the **inline two-step 🗑→✓/✕ confirm**, the **♻ discard-generated→✓/✕** flow, the **🚀 released→✓/✕ toggle**, **📂 Open workspace**, a project-wide **🧭 Open main workspace** button (no story selection needed — see [main_workspace / dev_workspace](#-main_workspace--dev_workspace--planning-discipline)), and an inline `#rmMsg` status line. Footer links to **History** + Settings. Logs `[stg] popup build: …`. |
| `history.html` / `history.js` | **Story history viewer** (opens in a tab from the popup footer). Reads `stories_history.json` via the native host (`getHistory`) and renders newest-first cards of removed stories — env/REL/CHG/date chips, clickable Jira/REL/AgileTest links, collapsible work-log. Jira base URL comes from `getStgConfig`, not a hardcoded org domain. Logs `[stg-hist] history build: …`. |
| `options.html` / `options.js` | Settings page — a **Projects card** (list/rename/Set active/Remove/+ Add project) and a read-only **`#settingsProjLabel`** ("Editing settings for") naming whichever project the cards below it act on — always the *active* one; **Set active** on the Projects card is the only way to change it (see [Projects](#projects-multi-project-support)); a **native host status card** (pings `com.storytabgroups.worktree` on load, shows ✓/✕, and when disconnected shows the exact `install-native-host.ps1 -ExtensionId <id>` fix command with a Copy button and a Recheck button — can't run the installer itself, see below), a **collapsible Paths & diagnostics card** (a `<details>`, reusing the same styling as the Advanced section below rather than a plain `.card` — its `<summary>` carries an at-a-glance roll-up, `✓ <project> · all checks passed` or `✕ <project> · N problems: …`, auto-expanding itself when there's a real problem so an error is never one extra click away from being noticed; every resolved path + which rule decided it + a re-runnable preflight, via `runPreflight` → host `preflight` — stays scoped to the *active* project; the Worktree root / Workspace dir rows read a **real** existence check from the host now, not a proxy — see the P6 dev gotcha below), **worktree paths & branch format** (Story root / worktree root / workspace dir / branch format, see below), **organization settings** (Jira base URL / GitHub org / EOD task name / owner / repo aliases — every org-specific literal, configurable), an **Apps card** (add/edit/remove each app's port/start/health, hide/unhide from the +New story checklist — see [Settings: Apps](#settings-apps)), an **Agent integration card** (Install for Claude Code with a user/project scope choice, Copy AGENTS.md snippet for Codex, Copy instructions for ChatGPT — all three share one `installSkill` render call so they can never drift out of sync; read-only dev-cycle harness detection — see [Agent skill](#agent-skill-claude-code--codex--chatgpt)), + an **Advanced** `<details>` (the "Sync from stories.json" file-picker — a native-host-unreachable fallback now that `stories.json` is auto-created per project, no longer the primary flow — plus `node gen-rules.mjs` guidance and the rules.json paste/override). Logs `[stg-opt] options build: …`. |
| `rules-core.js` | `globalThis.RBCore` — the actual `buildRules()` implementation and its helpers (color hash, label, Jira/AgileTest id regexes, repo aliasing), loaded by `background.js` via `importScripts()` and by `rules-lib.js`/`gen-rules.mjs` for the popup/options pages and the Node CLI. **One implementation, three consumers** — this is what retired the old "must stay mirror images" duplicated-copy comment. |
| `rules-lib.js` | `window.RB`: thin wrapper over `RBCore.buildRules`, remembers the file handle (IndexedDB), `sync()` (picker) / `syncSilently()` (no dialog, popup-safe). |
| `gen-rules.mjs` | Node CLI alternative: regenerates `rules.json` from `../stories.json`, loading `rules-core.js` via `node:vm` (it's a plain browser/SW script, not an ES module). |
| `rules.json` | Packaged fallback rule set (generated, ships empty). Consulted only when there's no saved `rulesOverride` **and** the native host is unreachable — the last-resort fallback, not the primary path anymore. |
| `native-host/` | The bridge to `tools\*.ps1` — see below. |
| `tools/` | **Every PowerShell script this extension needs, in one folder** — see [Standalone / portability](#standalone--portability). |
| `skills/story-tab-groups/SKILL.md` | The day-to-day agent skill source, a template (`{{PROJECT_ID}}`/`{{PROJECT_ROOT}}`/`{{TOOLS_DIR}}` placeholders, plus mode-aware `<!-- MODE:tracking -->`/`<!-- MODE:worktree -->` blocks) rendered/installed by `tools\install-agent-skill.ps1 -Skill story-tab-groups` (the default) — see [Agent skill](#agent-skill-claude-code--codex--chatgpt). |
| `skills/setup-dev-loop/SKILL.md` | The separate **one-time bootstrap** skill template, rendered/installed the same way via `-Skill setup-dev-loop` — see [main_workspace / dev_workspace](#-main_workspace--dev_workspace--planning-discipline). |
| `skills/nextjs-project-architecture/` | A **generic** (non-project, non-templated) skill — SKILL.md + `references/` + `assets/templates/` — installed via Settings' separate **Optional skills** card, not the Agent integration one. See [Agent skill](#agent-skill-claude-code--codex--chatgpt). |
| `skills/shadcn-from-mantine/` | A second **generic** skill — SKILL.md + one `references/translation-table.md` — a conceptual shadcn/ui primer anchored purely in Mantine vocabulary (ownership model, Tailwind + CSS-variable theming, `cva` variants); deliberately defers all CLI/registry/`components.json` mechanics to shadcn's own official MCP server rather than duplicating them. Installed via the same **Optional skills** card. See [Agent skill](#agent-skill-claude-code--codex--chatgpt). |
| `setup.ps1` | One-command bootstrap: installs + verifies the native host end-to-end, finds/asks for the data root, publishes `STG_ROOT`/`STG_TOOLS` env vars, runs a preflight, and (given `-OldExtensionDir`) migrates a prior non-standalone install. `-WhatIf` previews every change without touching anything. |

## Data flow (stories.json → groups)

`stories.json` (wherever `Resolve-StgPaths` resolves the root to) → the native host's `stories`
action → `RBCore.buildRules()` (`rules-core.js`, shared by `background.js`, `rules-lib.js` and
`gen-rules.mjs`) → per story: `{ key, title:"<KEY> <label>", color (hashed from key),
match:[key, REL, AgileTest issue id, …], repos (apps, `iu`→`ui` quirk, now a configurable alias
map), links (Jira/GitHub URLs built from the configured `jiraBaseUrl`/`githubOrg`) }`. Matching is
**title-contains-key**, so renaming a tab group by hand keeps working. This happens automatically
on cold start — no manual refresh needed; the native host is read live on every popup open, so
editing `stories.json` by hand shows up on the very next open with nothing to click. If the native
host is ever unreachable, Settings' Advanced section has a file-picker fallback (or
`node gen-rules.mjs` for a build-time snapshot) — see the dev gotcha below for why this isn't in
the popup itself anymore.

---

## Projects (multi-project support)

The tool originally assumed **one data root** containing many app clones for a single codebase. Everything
below this section — worktree removal, story creation, the app checklist, the ready/blocked badges — is now
**per-project**: one project per codebase, each with its own root, worktree root, workspace dir, branch
format, apps, and Jira/GitHub org settings, switched via **Set active** on Settings' Projects card instead
of hand-editing Settings back and forth and losing the other codebase's rules cache every time. The popup
and Settings' own per-project cards always reflect whichever project is currently active — see below for
why an earlier design with independent "which project am I looking at" selectors in both places was
replaced with that single, unified active-project concept after live testing showed it confusing.

- **Schema v2** (`%LOCALAPPDATA%\story-tab-groups\stg-config.json`): `{ version, activeProject,
  defaults:{...org fields...}, projects:[{id, name, mode, root, worktreeRoot?, workspaceRoot?,
  branchFormat?, jiraBaseUrl?, githubOrg?, repoAliases?, taskNamePrefix?, owner?, hiddenApps?}], root,
  worktreeRoot }`. The trailing top-level `root`/`worktreeRoot` are a **derived mirror of the active
  project**, rewritten on every config write — this is what keeps every legacy/zero-arg reader
  (`Get-StgOrgDefaults`'s zero-arg path, `Resolve-StgPaths`'s legacy fallback, `getConfig`'s raw fields)
  working unmodified. A v1 (single-root, no `projects` key) config migrates to v2 **additively** the moment
  it's read (`ConvertTo-StgConfigV2`, called from every `Get-StgConfig`) — it synthesizes one project from
  the existing top-level fields without moving or deleting anything, so every pre-multi-project reader keeps
  working byte-for-byte even before the file is ever rewritten to disk.
- **Effective value** = `project.<field>` → `defaults.<field>` → the tool's original hardcoded default.
  `defaults` is a **global fallback layer only, never written by a per-project edit** — `Update-StgProject`/
  `Update-StgConfig` both write org-field changes into the *active* project's own `projects[]` entry, never
  into `defaults`, so editing one project's Jira URL can never silently change a different project's
  fallback value.
- **`Resolve-StgPaths -Project <id>`** (the resolver every `tools\*.ps1` script and `native-host\host.ps1`
  call through): explicit `-Project <id>` → that project by id, hard-failing on an unknown id rather than
  silently falling through → else `-Root <path>` reverse-matched against every project's own root → else the
  configured active project → else, for a genuinely project-less install, the original single-root chain
  (`-Root` → config → `$env:STG_ROOT` → auto-detect), completely unchanged. Every script takes `-Project`
  and threads it through, including six places that forward to a *child* script process (e.g.
  `story-release.ps1`'s ledger-sync call), so `release -Story X -Project acme` while a *different* project
  is active still writes to `acme`'s own ledger, not the active project's.
- **Popup**: an always-visible **`#projLabel`** above the controls names whichever project is currently
  active, plus a **Switch project** link that opens Settings. There is deliberately no live dropdown here —
  an earlier version used a `<select>` that doubled as both display and switcher, but selecting an option
  silently changed the *globally* active project too (the only concept of "active" that exists — a bare CLI
  run, the EOD digest, and every other non-popup consumer all key off it, so the popup can't have its own
  independent "just looking" state without that meaning something different depending on which surface you
  last touched). **Confirmed confusing in real use**, not just in theory — it looked like a browsable
  dropdown but committed on click with no way to preview another project. Replaced with a plain label; every
  load re-derives `CURRENT_PROJECT` fresh from the host's current active project (`getProjects`'
  `activeProject` field), and every async refresh (`refreshChecks`/`refreshMeta`/`doHealth`/`refreshDoctor`)
  still captures it before its own `await` and discards a stale result if it's changed since — two different
  projects can legitimately share a Jira key, so this guards against active changing elsewhere (Settings)
  while the popup happens to be open, painting the wrong project's badges. **Tab matching spans every
  project** (a project that isn't currently active still auto-routes its own tabs); only the popup's display
  and actions scope to the active one. The right-click **Add to story group** menu lists every project's
  stories, prefixed by project name once 2+ projects exist, to disambiguate a shared key.
- **Settings**: a **Projects card** (above "Native host") lists every project with a rename field, **Set
  active**, **Remove**, and a **+ Add project** mini-form (name + root + a **mode** selector,
  `worktree`/`tracking` — see [Tracking mode](#tracking-mode) below for what the second option actually
  does and why it's a separate section, not just another field). `New-StgProject` also creates the new
  project's registry (`stories.json` + `app-map.json` for `worktree`, `<docsDir>\stories.json` only for
  `tracking`) in the project's own root at this point — closing a real, previously-undiscovered gap: a
  project with no `stories.json` couldn't create its first story at all (`switch-story.ps1`'s
  `Read-Registry` throws with no fallback), and nothing used to create one for a freshly-added project.
  **Remove is
  "unpin," not delete** — it only forgets the config's own reference; `stories.json`, worktrees and the repo
  itself are never touched. A read-only `#settingsProjLabel` ("Editing settings for") names whichever
  project the existing **Worktree paths & branch format**, **Organization settings** and **Apps** cards
  read/write (`getProjectConfig`/`setProjectConfig`, scoped to that project's own id) — always the
  **active** one; **Paths & diagnostics** is scoped to the same active project, so the whole page edits one
  consistent project at a time. To edit a *different* project, **Set active** it on the Projects card first.
  An earlier version had this as an independent `<select>`, decoupled from active, so you could edit a
  project without switching to it — **removed at the user's request after live testing**, for the same
  reason the popup's own project `<select>` (above) was replaced with a plain label: two different notions
  of "which project" on one page, only one of which the popup or a bare CLI run can ever see, tested as
  genuinely confusing rather than merely inconsistent in theory.
- **A saved manual rules override** (Options' Advanced paste/picker box — the only place it's reachable
  from; see the dev gotcha below for why the popup's own copy of this was removed) is **tagged to the
  project it was saved for** and applies only when that project is selected — it never leaks onto a
  different one. It's also **automatically cleared the moment a real story mutation happens for that
  project** (create/add-app/remove/release-toggle/set-links — `background.js`'s `clearProjectOverride()`,
  called alongside `forceRulesRebuild()` at each of those five cases) — an override is meant as "trust my
  snapshot," not "stay frozen even through changes I make with this very tool." **Found by live-testing,
  not design review**: two real, host-confirmed story creations in a row never appeared in the popup,
  because an override saved earlier (via the popup's now-removed "Load stories.json" button) was still
  pinned for that project — `forceRulesRebuild()` only ever cleared the *auto-built* cache, a completely
  separate `chrome.storage.local` key from `rulesOverrides`, so nothing about normal tool use had ever
  invalidated it. The one remaining legitimate case (a deliberate Settings-side paste, or the host being
  genuinely unreachable) is surfaced with a small notice in the popup itself (`#overrideNote`, "Showing a
  saved snapshot, not live data" + an inline Clear button) rather than left for someone to discover by
  finding "Clear override" buried in Settings.
- **New `native-host\host.ps1` actions**: `projects` (root-independent listing — renders even on a totally
  broken install), `allstories` (every project's raw `stories.json` in one native-messaging round trip, so
  cold start is one call, not N), `addProject` (now reads `mode` from the message, validated against
  `worktree`/`tracking` rather than trusted wholesale), `getProjectConfig`/`setProjectConfig` (read/write one
  named project directly, independent of which is active), `removeProject`, `storydoc` (tracking mode's
  per-story doc — see [Tracking mode](#tracking-mode)). Full list folded into the action inventory below.

## Tracking mode

A second project **mode**, for a repo you work in a single VS Code window with no worktrees at all — the
"Claude vault" case: Claude records progress on a story as it works, the popup just makes that visible to a
human. Set via the mode selector on Settings' **+ Add project** form (`worktree` is still the default and
the only mode an existing project can have without deliberately picking `tracking` at creation time — an
existing project's mode is **not** editable after creation, since worktrees/ledgers already exist in
worktree-mode locations for one and converting is a real migration question, not a field edit).

- **No git at all.** No fetch, no branch, no `git worktree add`, no `.code-workspace`. A tracking project's
  `$Paths.Root` genuinely **is** the tracked repo (`src\`, `node_modules\`, etc. live there), not a container
  of per-story folders the way a worktree project's root is — so every generated artifact (registry, story
  doc, ledger, `vault-status.ps1` notes) lives under `<root>\<docsDir>\` (`docsDir` defaults to
  `.claude\stories`), never scattered loose into the tracked repo's own root where it would pollute `git
  status`. `Resolve-StgPaths`'s tracking-mode record sets `WorktreeRoot`/`WorkspaceDir` to `$null` — every
  consumer of either needs a null guard, not just a mode branch (`story-doctor.ps1`'s stale-workspace scan is
  the one place this actually bit: `Get-ChildItem -LiteralPath $null` throws under `$ErrorActionPreference =
  'Stop'` regardless of `-ErrorAction`, so it's wrapped in `if ($WorkspaceDir) { ... }`).
- **`tools\story-doc.ps1`** (`init|append|path|show`) is tracking mode's whole write surface for the
  per-story markdown doc (`<root>\<docsDir>\<KEY>.md`) — a new file, not an extension of `switch-story.ps1
  note`: that file is already 50KB+, and a multi-line log entry through a positional arg hits the same
  `-File` child-process quote-stripping problem `-LinksB64`/`-TextB64` exist for elsewhere in this codebase,
  so it mirrors that fix (`-TextB64`, base64 of UTF-8 text). `append` is deliberately dumb: ensure a
  `## Work log` heading exists *somewhere* in the file (add one at EOF if absent), then always append the
  new timestamped entry at the very end — never inserted mid-document, so anything written above (by hand or
  by Claude, in an earlier session) survives untouched. `native-host\host.ps1`'s **`storydoc`** action is the
  extension's real entry point to it (`switch-story.ps1 note`, which has no `-Json` path of its own, stays
  CLI-only parity, calling `story-doc.ps1` as a child process the same way `Invoke-LedgerJson` already does).
- **Mode branch points**, everywhere `switch-story.ps1`/`remove-worktree.ps1` have one: `new` skips branch
  derivation, the app-map warning, the per-app git loop and the workspace write entirely, keeping only the
  node write, `Add-StoryLog`, the doc init and the ledger init (env/apps are optional positionals in this
  mode — the popup's tracking-mode "+ New story" form hides env/branch/the app checklist to match); `add`/
  `go`/`install` all refuse with a clear pointer to what to use instead (`open`, for `go`); `open` opens the
  markdown doc (`Open-StoryDoc`) instead of the `.code-workspace`. `remove-worktree.ps1` has one short-circuit
  between key validation and worktree discovery: archive the node + ledger + doc text into
  `stories_history.json` exactly as worktree mode does, drop the registry node, delete the `.md` file — no
  folders, no branch, nothing else on disk to touch. `-CheckAll` returns `{na:true}` per tracking-mode story
  so the popup shows **no** ready/blocked badge rather than a misleadingly-🟢 one (there's no "clean and
  pushed" concept without git). `story-doctor.ps1` gates every worktree-only finding kind
  (`node-without-folder`/`app-without-worktree`/`extra-folders`/`no-ledger`/`no-workspace`/etc.) behind
  `$Paths.Mode -eq 'worktree'`, with a tracking-mode `else` branch checking `no-story-doc` (new finding kind)
  plus the ledger presence/failed-phase checks (shared with worktree mode, just at the docsDir-based path).
  `vault-status.ps1` forces `-NoCheck` and renders `-` for the Clean/Apps columns. `host.ps1`'s `apps` action
  short-circuits to `{apps:[], mode:'tracking'}` **before** its `Get-ChildItem $GRoot` scan — scanning a real
  repo root for app clones is both meaningless and slow. `story-handover.ps1` (moves artifacts between two
  story *keys*) is deliberately **not** mode-branched — its actual functionality doesn't make sense without
  worktrees to move, so it stays worktree-only and out of scope rather than growing a tracking-mode path
  nothing would ever exercise.
- **Three real bugs found live-testing this mode, none of them hypothetical:**
  1. **`Get-Content -Raw`'s return value carries PowerShell's extended type-system members** (`PSPath`,
     `PSParentPath`, `PSChildName`, `PSDrive`, `PSProvider`, `ReadCount`) even though its declared .NET type
     is a plain `System.String` — a well-known but easy-to-forget PowerShell quirk. `ConvertTo-Json -Depth 8`
     doesn't see a string then; it sees an object with those properties and recurses *into* them, including
     `PSDrive`/`PSProvider`'s own large framework-internal object graphs. Not an infinite loop, but slow
     enough to be indistinguishable from a hang in practice — confirmed by isolated testing: the identical
     hashtable serialized instantly once the content came from `[System.IO.File]::ReadAllText` instead (a
     genuinely plain .NET string with no ETS decoration), but never returned within 30s from `Get-Content
     -Raw`'s decorated one. This is exactly what `story-doc.ps1`'s `show` action hit on its first live test —
     fixed there (and in `append`, for consistency, though `append`'s own string-interpolation into `$final`
     happened to already dodge it). **The standing rule this leaves**: never pass a `Get-Content -Raw` result
     directly into `ConvertTo-Json` — either reinterpolate it into a new string (`"$x"`, which forces a
     genuinely new String with no ETS wrapper) or read the file with `[System.IO.File]::ReadAllText` in the
     first place. An explicit `[string](...)` cast *also* works (confirmed empirically — `host.ps1`'s
     `getHistory`/`ledgers`-adjacent actions were already doing this correctly, apparently by convention
     rather than by accident), but a bare `Get-Content -Raw` assignment does not, even though
     `.GetType().FullName` on the result reports `System.String` — the ETS wrapper survives a `.GetType()`
     check because `ConvertTo-Json` walks `PSObject.Properties`, not the declared CLR type.
  2. **`host.ps1`'s `storydoc` case read `$msg.action` for the doc sub-action** (`init`/`append`/`path`/
     `show`) — but `$msg.action` is already consumed by the outer `switch ($msg.action)` that routed the
     message to this case in the first place, so it always evaluated to the literal string `"storydoc"`,
     never what the caller actually asked for. Every single call was guaranteed to fail with `"invalid
     storydoc action: storydoc"` regardless of input — this shipped broken and was never callable until
     caught here. Fixed by renaming the field to **`docAction`**, distinct from the dispatch-level `action`.
  3. **The `@($null)`-on-empty-array trap (documented below) recurred inside `story-doctor.ps1`,
     independently, twice**, in code that predates tracking mode and affects every project regardless of
     mode: (a) the whole-registry `thin-history-record` check does `foreach ($e in @($hist.removed))` with
     no `if (-not $e) { continue }` guard — unlike the *sibling* `log-shape` loop two blocks up, which
     already has exactly that guard — so any project whose `stories_history.json` doesn't exist yet or has
     no `removed` key (i.e. every project before its first-ever removal) got a phantom `info`-level
     `thin-history-record` finding with an empty story key, every single run. (b) the `no-apps` finding
     (`error` severity) was never gated behind `$Paths.Mode -eq 'worktree'` the way every *other*
     worktree-only finding in the same function is — so it fired as a permanent, unfixable `error` on every
     tracking-mode story ever created (there is no "app list" to add in a mode with no apps at all). Both
     fixed; `story-doctor.ps1` now reports `ok:true, findings:[]` for a clean tracking-mode project with no
     history, instead of `ok:false` with one spurious error and one spurious info finding.

Verified end-to-end via a short-path scratch fixture (`C:\temp\stg-p5\...` — the session scratchpad's own
deep nesting hit Windows' 260-character `MAX_PATH` limit on the ledger's full path, a test-environment
artifact confirmed by reproducing cleanly at a shorter path, not a code bug): `New-StgProject -Mode
tracking` auto-creates `<root>\.claude\stories\stories.json`; `switch-story.ps1 new`/`story-ledger.ps1 init`
both succeed and produce a correctly-shaped node/ledger; `story-doc.ps1`'s all four actions (`path`/`show`/
`append`/`init`) round-trip correctly, including a real append landing under `## Work log` at EOF;
`host.ps1`'s `storydoc`/`apps`/`projects`/`allstories` actions all verified through the actual framed
native-messaging protocol (not just direct PowerShell calls); `remove-worktree.ps1`'s `-CheckAll` returns
`na:true` and its real removal archives the full node+ledger into `stories_history.json`, drops the registry
node, and deletes the `.md` doc; `story-doctor.ps1` verified clean both before and after a real removal
(confirming the history-loop fix doesn't just suppress the phantom finding but still correctly leaves a
*legitimate* thin-history check possible for a record that genuinely lacks a node/ledger); the full
`addProject` flow (mode selector → `background.js` → `host.ps1` → `New-StgProject -Mode tracking`) verified
through the real host action end to end, not just the underlying PowerShell function. **Not yet verified**:
the popup/Settings UI in an actual browser (native-messaging host registration is a system-modifying step
not taken without asking first — the same standing limitation as every other phase since P4b).

---

## 🧭 main_workspace / dev_workspace + planning discipline

A no-story, project-wide workspace for planning/brainstorming, plus (tracking mode only) a real gate
before implementation starts — the fix for a concrete problem: a Claude Code session left to just start
coding from a request, with no settled direction, produces messy, undirected changes. Both modes get
`main_workspace`; only tracking mode gets the rest, since worktree-mode tickets already arrive pre-planned
(e.g. from Jira) and don't need a brainstorm-first gate.

- **Worktree mode**: `main_workspace.code-workspace` (`<workspace dir>\main_workspace.code-workspace`) is
  every home-base app clone, no story attached — regenerated **fresh on every open** (`switch-story.ps1`'s
  `Write-MainWorkspace`/`Open-MainWorkspace`/`Invoke-OpenMain`, scanning `<Root>\*` for `.git` directories
  the same way `host.ps1`'s `apps` action does, absolute paths — the workspace/root split means a relative
  path can't be assumed), so it always reflects whichever apps are actually cloned right now. Never touches
  any app's git branch or working tree — app list only, no checkout behavior. Reached via the popup's
  project-wide **🧭 Open main workspace** button (next to ↗ Open all — `openMainWorkspace` message →
  `openmain` host action → `switch-story.ps1 openmain -Json`) or the `story-tab-groups` skill's own
  "Workspaces" section. `story-doctor.ps1`'s stale-workspace scan allow-lists `main_workspace`/
  `dev_workspace`/the legacy `full_ui_workspace` name, so none of these ever get flagged as an orphaned
  `.code-workspace` with no registry node.
- **Tracking mode**: `main_workspace.code-workspace` and `dev_workspace.code-workspace` both sit directly
  at `<root>\` (the repo root itself, next to `.gitignore`) — **not** via `$Paths.WorkspaceDir` (that's
  `$null` for tracking mode by design; repurposing it would mean touching `Resolve-StgPaths`' own
  tracking-mode null-means-"no workspace concept" contract) — but they are **not** the same folder list.
  `main_workspace` is a relative `"."` folder entry (the whole project root, so the file stays portable
  if committed) — planning needs `DESIGN.md`/`ROADMAP.md`, which live at the root, so the whole folder is
  the point. `dev_workspace` lists **only the actual git repos** found under the root (one `.git`-directory
  child folder per entry, plus anything under `<root>\repositories\` — `Get-StgTrackingRepos`,
  `stg-paths.psm1`), so `DESIGN.md`/`ROADMAP.md`/`stories.json`/`.claude\` never show up in the window
  you actually write code from. **Found worth splitting after the fact**: a real tracking-mode project
  (`WorkoutTrackerProject`, a container of `workout-tracker-service`/`workout-tracker-ui` clones, not a
  git repo itself) made the original "both point at the same single repo" design visibly wrong —
  `dev_workspace`'s old `"."` entry opened the whole container, generated files and all, not the two repos
  you'd actually edit. The window *title* ("Planning - ..." vs "Dev - ...") is still the only signal for
  which one a session is in — there's no way to introspect which literal file launched it — so **the real
  gate a session follows is ledger state** (the `plan` phase — see below), never which workspace is open.
  `main_workspace` is still written **once**, at project-add time (`New-StgTrackingScaffold`, called from
  `New-StgProject`) and never touched again — tracking mode's root itself never changes, so there's
  nothing about *that* file that can go stale. `dev_workspace` is the opposite: `New-StgTrackingScaffold`
  only writes it once too (and skips it if the project has no repos cloned yet, rather than failing
  project-add over it), but it's also **regenerated fresh every time it's opened** via the popup's
  **🛠 Dev workspace** button (next to 🧭 Open main workspace — `openDevWorkspace` message → `opendev` host
  action → `switch-story.ps1 opendev -Json` → `Invoke-OpenDev`/`Write-StgDevWorkspace`), the same
  "always reflects what's actually cloned right now" reasoning worktree mode's own `main_workspace`
  already follows — a newly-cloned repo shows up the very next open with nothing to click. `Invoke-OpenDev`
  refuses cleanly (`ok:false`) for a worktree-mode project; the popup hides the button there entirely.
- **Planning discipline (tracking mode only)**: the `story-tab-groups` skill's "Planning discipline"
  section (mode-gated — see [Agent skill](#agent-skill-claude-code--codex--chatgpt) below) teaches: don't
  mark the ledger's `plan` phase done, and don't start `implement`, until a real design conversation
  actually happened. Brainstorm a topic first, tracked in `<root>\DESIGN.md` under three headings —
  `## LOCKED` (settled; don't silently contradict later), `## OPEN` (still being decided), `## REJECTED`
  (ruled out, with a one-line reason so it doesn't get re-litigated) — adapted from KibaWolfSpirit's real,
  working `/brainstorm` → design-doc → `wave-planner` → `plan.md` → `ROADMAP.md` chain (used as a reference,
  confirmed by reading it directly). Only once a topic is LOCKED does it become a story, seeded via one
  `switch-story.ps1 note` call into the *same* per-story `.md` doc `story-doc.ps1` already writes work-log
  entries into (Context / Locked decisions / an Acceptance-criteria table, every row starting unmet /
  Out of scope) — **one artifact per story**, not Kiba's separate `plan.md`/`development.md`/`testing.md`
  split. Sequencing lives in `<root>\ROADMAP.md`, one row per story.
- **The hybrid commit model**: `stories.json` / `DESIGN.md` / `ROADMAP.md` / each story's own `.md` doc are
  the durable planning record and are meant to be **committed** — matching Kiba's own "commit the plan
  alongside the code" discipline. Only two kinds of ephemera get excluded via a `.gitignore` entry
  `New-StgTrackingScaffold` adds **additively** (append-if-missing, never touching anything else already in
  the file) the moment a tracking project is added: the live per-story ledger
  (`<docsDir>\*.story-ship-state.json`) and `StoryLib.psm1`'s `Enter-RegistryLock` lock file
  (`<docsDir>\*.lock`, a 0-byte OS-lock handle opened next to the registry and never deleted — found live
  while verifying this very feature: it showed up as an untracked, non-ignored file after the very first
  story creation, exactly the "not clean when committing" mess this whole feature exists to avoid).
  Verified end to end: `git status --ignored` on a real fixture shows both as `!!` while `stories.json`/
  `.gitignore`/`DESIGN.md`/`ROADMAP.md`/both workspace files/the story's own `.md` all stage normally: a
  pre-existing `.gitignore`'s own unrelated lines (confirmed with `node_modules/`/`dist/`/`*.log`) survive
  untouched.
- **`New-StgTrackingScaffold`** (`stg-paths.psm1`) is the **one implementation** behind all of this —
  `stories.json`, the `.gitignore` entries, `DESIGN.md`/`ROADMAP.md`, both workspace files, and (purely
  cosmetic, no functional wiring) empty `worktree\`/`workspace\` placeholder folders matching worktree
  mode's own root layout — each guarded by its own already-present check, returning what it created vs.
  what it found. `New-StgProject` calls it
  unconditionally for a brand-new tracking project; **`tools\setup-dev-loop.ps1`** (`check`/`apply`, refuses
  outright on a worktree-mode project) calls the exact same function to **retrofit** a tracking project that
  was added *before* this feature existed — one implementation, not two copies to keep in sync. `check` is
  read-only (a hand-rolled presence check, calling nothing that writes); `apply` is the only action that
  writes, meant to run only after a human has seen `check`'s `missing` list and said yes, matching
  dev-cycle's own bootstrap rule (propose, one confirmation, then write). The companion
  **`skills/setup-dev-loop/SKILL.md`** teaches an agent exactly that check-then-confirm-then-apply sequence;
  installed the same way as the main skill (`install-agent-skill.ps1 install -Project <id> -Scope
  user|project -Skill setup-dev-loop`).

---

## Agent skill (Claude Code / Codex / ChatGPT)

Settings' **Agent integration** card teaches an AI coding agent to drive a tracking-mode project's story
registry directly from the CLI — list stories, create one, append a work-log entry, advance a ledger
phase, mark released — instead of a human handing it each command by hand. One skill source,
[`skills\story-tab-groups\SKILL.md`](skills/story-tab-groups/SKILL.md), a template with
`{{PROJECT_ID}}`/`{{PROJECT_ROOT}}`/`{{TOOLS_DIR}}` placeholders.

- **`tools\install-agent-skill.ps1`** renders (`-Action render`) or installs (`-Action install -Scope
  user|project`) a template for ONE resolved project — `-Project` is **mandatory** here, unlike every
  other script in `tools\` (which falls back to whichever project is currently active): a skill silently
  bound to "whichever project happens to be active right now" would be actively wrong the moment a second
  project exists or the active one later changes. `-Skill` picks which template — `story-tab-groups`
  (default, the day-to-day skill) or `setup-dev-loop` (the one-time bootstrap skill, see [main_workspace /
  dev_workspace](#-main_workspace--dev_workspace--planning-discipline)) — from a `[ValidateSet]`, never an
  arbitrary caller-supplied path. **One rendering path, reused by every consumer** — the Claude-installed
  file, the Codex "Copy AGENTS.md snippet" button and the ChatGPT "Copy instructions" button all call the
  same action, so none of the three can drift out of sync with each other the way three
  independently-maintained copies would. `render` writes nothing at all; only `install` does. `-Scope user`
  writes to `%USERPROFILE%\.claude\skills\<skill>\SKILL.md` (every project), `-Scope project` to
  `<project root>\.claude\skills\<skill>\SKILL.md` (this project only) — the **script** decides the
  destination from `-Scope`/`-Skill`, never a path the caller supplies, matching `setappmap`'s and
  `storydoc`'s existing security posture (see [Standalone / portability](#standalone--portability) and
  [🗑 Worktree removal](#-worktree-removal-the-native-host-bridge) below for those precedents).
- **Mode-aware rendering** (`story-tab-groups` template only): the template carries both modes' content,
  delimited by `<!-- MODE:tracking -->...<!-- /MODE:tracking -->` / `<!-- MODE:worktree -->...
  <!-- /MODE:worktree -->` blocks (inline mid-bullet or whole paragraphs — the stripping regex doesn't
  care which). The script drops the *other* mode's blocks entirely, then strips the current mode's own
  markers so only its content remains, unwrapped — a no-op for `setup-dev-loop`'s template, which has no
  markers at all. **Fixes a real, previously-shipped bug**: before this existed, every installed skill
  unconditionally said "this project tracks stories, it doesn't cut git worktrees," even when rendered for
  a worktree-mode project (confirmed live against the real, already-installed `workouttrackerapp` skill —
  re-installing it after this fix now correctly reads "cuts a real git worktree per app").
- **`native-host\host.ps1`'s `installskill` action**: `$msg.scope`/`$msg.skill` each validated against an
  allow-list before being forwarded, `$msg.install` picks `render`/`install`. Root-independent (no
  `Test-RootReady`) — rendering needs a *resolved project* to bake into the template, not a live
  "does this root's data currently check out" gate. Always resolves to the **active** project (no
  `-Project`/`id` override reachable from the UI — this card, like Paths & diagnostics, has no
  "editing a non-active project" concept).
- **Optional skills (generic, non-project skills)** — Settings has a *second*, separate card below Agent
  integration for installing a skill that has nothing to do with story tracking (today:
  `nextjs-project-architecture`, a Next.js App Router architecture skill, and `shadcn-from-mantine`, a
  conceptual shadcn/ui-for-Mantine-developers bridge that points at shadcn's own MCP server for anything
  mechanical instead of teaching CLI syntax that would go stale). It deliberately isn't folded into
  the Agent integration card above: that card's whole framing ("teaches an agent to drive the active
  project's story registry") and its `devCycleDetected` status line are specific to the story-tracking
  skill and don't apply to a generic one, and a generic skill has no per-project render step worth
  showing before you commit to installing (there's nothing a preview would tell you that the skill's own
  one-line description in the dropdown doesn't already). `tools\install-agent-skill.ps1` treats a skill
  named in its own `$GenericSkills` array (and added to the `-Skill` `[ValidateSet]` alongside it)
  differently from a project skill: no `{{...}}` substitution, no mode-block stripping — the rendered
  `content` is just SKILL.md's own text verbatim — and `install` copies the skill's **whole folder**
  (`SKILL.md` + `references\` + `assets\`, whatever it has), not just one file, removing a stale prior copy
  first so a version that dropped a file doesn't leave it behind forever. `-Project` stays mandatory for a
  uniform call shape across both skill kinds even though a generic skill's content never uses it — it's
  only consulted to resolve a `project`-scope destination root, and every real caller already has an active
  project in context via `host.ps1`'s `$PathsInfo` regardless. Adding a future generic skill is: drop its
  folder under `skills\<name>\`, add `<name>` to both `$GenericSkills` and the `-Skill` ValidateSet in
  `install-agent-skill.ps1`, add `<name>` to `host.ps1`'s own `installskill` allow-list, and add an
  `<option>` to Settings' `#extraSkillSelect` — four small, symmetric edits, not a new code path.
  **Copy-Item gotcha caught while building this** (see Dev gotchas below for the full mechanism):
  `-LiteralPath` with a trailing `\*` does not expand as a wildcard and silently copies nothing, with no
  error even under `-ErrorAction Stop` — the fix copies the skill folder itself (already named `$Skill`)
  into its destination's *parent*, never into an already-created, empty destination directory. Verified
  live both ways: direct script invocation (`render`/`install` to both scopes) and the real framed
  native-messaging protocol (a hand-built length-prefixed JSON frame piped to `host.ps1`, the same
  mechanism `background.js`/`chrome.runtime.sendNativeMessage` actually uses) — including confirming the
  existing `story-tab-groups`/`setup-dev-loop` project-skill path is byte-for-byte unaffected by any of
  this branching. Repeated identically for `shadcn-from-mantine` when it was added (full folder copy
  verified by hash against the source, stale-file removal re-confirmed, host.ps1's own allow-list
  re-confirmed as the thing rejecting an unknown `-Skill` rather than the PS script's ValidateSet alone)
  — the four-edit pattern held with no code-path changes.
- **Every command the skill teaches bakes in `-Project {{PROJECT_ID}}` explicitly** — confirmed necessary
  by reading `Resolve-StgPaths`: with no `-Project`, these scripts fall back to whichever project is
  currently active in the *popup*, which the skill must never silently ride along with.
  `switch-story.ps1 note <KEY> "text" -Project <id>` is the taught "append a work-log entry" command, not
  a raw `story-doc.ps1 append` call — `story-doc.ps1 append` only accepts `-TextB64` (base64), and `note`
  already does that encoding internally for a tracking-mode story, so the skill never has to teach Claude
  an encoding step it could get wrong.
- **dev-cycle sync is instruction-level, not a technical hook** — confirmed by reading
  `~\.claude\skills\dev-cycle\`'s actual `SKILL.md`/`references\bindings.md` directly: dev-cycle has no
  extension point for another skill to observe its phase transitions. Its only phase-transition signal is
  its own standing rule to rewrite `.claude\state\cycle.md` at each transition — a file that's gitignored
  under `state_mode: local` and current only because dev-cycle's *own* instructions say to, not anything
  code-enforced. So the skill's own text carries a best-effort mapping table (dev-cycle's 0–8 phases →
  the ledger's 8 phases — they don't line up 1:1, and the skill says so) and an instruction: *if this repo
  also has `.claude\dev-cycle.json`, mirror a dev-cycle phase transition into the mapped
  `story-ledger.ps1 done <phase>` call too, best-effort, skip if the mapping doesn't clearly apply*.
  dev-cycle's own state stays authoritative regardless — this is honestly consistent with how dev-cycle
  enforces its *own* rules (by an agent following written instructions), not a step down from some
  sturdier mechanism that doesn't exist to step down from.
- **Harness detection, not creation.** `devCycleDetected` is a pure `Test-Path <project root>\.claude\
  dev-cycle.json` check, matching dev-cycle's own bootstrap check exactly — real bound `dev-cycle.json`
  files extend the schema with extra, undocumented per-repo keys (confirmed against two real examples on
  the machine this was built on), so JSON-shape validation would be actively wrong; existence is the only
  thing that means anything. The card surfaces *"dev-cycle harness: found / not found"* read-only, never
  writes one — dev-cycle's own bootstrap needs one human confirmation of the proposed JSON before writing
  anything, and an unattended write here risks clobbering hand-maintained sequencing notes with no git
  safety net under `state_mode: local` (`.claude\state\` is gitignored in every real bound repo checked).

---

## 🗑 Worktree removal (the native-host bridge)

A sandboxed extension can't run scripts, so the button talks to a local host over Native Messaging:

```
popup 🗑 → ✓  ──sendMessage('removeWorktree')──▶  background.js
   └─ sendNativeMessage(NATIVE_HOST, {action:'remove', story, force?})   // NATIVE_HOST = 'com.storytabgroups.worktree'
        ──▶  native-host\host.bat → host.ps1  ──▶  ..\tools\remove-worktree.ps1 -Story <KEY> -Root <root> [-Force] -Json
             (archive node to stories_history.json → git worktree remove each app under
              <root>\<KEY>\<app> + drop the empty <KEY> folder → drop stories.json node → delete .code-workspace)

popup 🗑 (blocked) → type CONFIRM → Delete  ──sendMessage('removeWorktree', {force:true})──▶ same path, -Force added
```

`remove-worktree.ps1` now lives in `tools\` (a sibling of `native-host\`, not `..\..` two levels up
from it) and resolves `<root>` itself via `tools\stg-paths.psm1`'s `Resolve-StgPaths` — see
[Standalone / portability](#standalone--portability).

- **Guardrail** (`remove-worktree.ps1`): **aborts and changes nothing** if any of the story's
  worktrees has uncommitted **non-`.env`** changes or **unpushed** commits — *unless* `-Force` is
  given (see below). The always-modified local `.env` (dev pointing) never blocks — removal
  `--force`s only past that. Local branch is **kept** (no `-DeleteBranch`). Has a read-only
  `-CheckOnly` (one story) and `-CheckAll` (every story in `stories.json`) preview mode, plus
  `-DiscardGenerated` (see the ready/blocked section below).
- **Blocked result, and the way past it.** The popup shows the blocker inline
  (`⚠ <STORY> not removed — <app>: N changed (<files>). Commit/push or clean up, then retry.`), and
  clicking 🗑 again on that same (now-known-blocked) row arms a **typed-CONFIRM force path**
  instead of the quick ✓/✕: an inline text box + a disabled **Delete** button that only enables once
  you type the literal word `CONFIRM`. Confirming sends `removeWorktree` with `force:true` →
  host `remove` action adds `-Force` → the guardrail is skipped entirely. **What "discard" actually
  means**: uncommitted working-tree changes are gone permanently (`git worktree remove --force`);
  unpushed **commits** are not at risk — the local branch is kept regardless (no `-DeleteBranch`
  here either), so anything already committed survives on that branch. Verified directly against a
  real dirty+unpushed worktree: without `-Force` it aborts exactly as before (no code path
  changed there); with `-Force` the uncommitted file is gone but `git log` on the kept branch still
  shows the unpushed commit afterward. ♻ (below) is unaffected and stays the safe, non-typed
  fast path for the *purely-generated-files* case — CONFIRM is specifically for when there's real
  work or unpushed commits in the way, which ♻ was never able to touch anyway.
- `native-host/` files: `host.ps1` (framed stdin/stdout JSON; actions: `ping` / `remove` / `check` / `history` / `stories` / `ledgers` / `envstatus` / `release` / `released` / `doctor` / `add` / `addcheck` / `addapps` / `addappscheck` / `apps` / `setappmap` / `openworkspace` / `openmain` / `opendev` / `getConfig` / `setConfig` / `preflight` / `projects` / `allstories` / `addProject` / `getProjectConfig` / `setProjectConfig` / `removeProject` / `storydoc` / `installskill` — the six `*Project`/`projects`/`allstories` actions are the multi-project CRUD/listing surface, see
  [Projects (multi-project support)](#projects-multi-project-support); `storydoc` is tracking mode's per-story doc bridge, see [Tracking mode](#tracking-mode); `installskill` renders/installs the agent skill, see [Agent skill](#agent-skill-claude-code--codex--chatgpt); every script action resolves from `tools\` via one `$ScriptsDir`, so `remove`/`check` can no longer silently run a *different* copy than every other action — the old asymmetry that caused the "returned no JSON" debugging trap), `host.bat` (launcher),
  `install-native-host.ps1` (writes `com.storytabgroups.worktree.json` + the
  `HKCU\Software\<vendor>\NativeMessagingHosts\com.storytabgroups.worktree` reg key; auto-detects
  the extension id from Chrome/Edge/Brave profiles **by matching each profile's recorded extension
  path against this script's own resolved parent folder** — not a `'*story-tab-groups*'` literal,
  so renaming the extension folder can't break detection; also refuses to write a manifest if
  `host.bat` doesn't exist, closing the "registered a host that can't start" failure mode),
  `com.storytabgroups.worktree.json` (**generated**, git-ignored — never checked in, always
  machine-specific). See `native-host/README.md`.

### One-time setup
```powershell
.\setup.ps1                        # from the extension root — does this + the data-root + env-var + preflight steps
# or, just the native host:
cd native-host
.\install-native-host.ps1          # or -ExtensionId <id from chrome://extensions>
```
Then **fully restart the browser** (native hosts are only re-read on a cold start).

**Why Settings can only diagnose this, never fix it with one click**: running the installer
*from the extension* would mean sending a message through `sendNativeMessage` — the exact bridge
that doesn't exist yet, or doesn't list this extension's id, which is the whole problem. Chrome
will not let an extension reach a native host unless a manifest already whitelists its origin, no
exceptions — that's the security boundary the API exists to enforce, not a gap to work around. So
the Settings page's **Native host** card (`options.js`'s `checkHostStatus()`) does the next best
thing: pings on load via a `pingNativeHost` message (→ `background.js` → `{action:'ping'}`,
already a no-op, side-effect-free action `host.ps1` has always had), shows ✓/✕, and on failure
shows the exact fix command with **this extension's real id pre-filled**
(`chrome.runtime.id` — the one thing about its own installation an extension can always know for
certain; there is no API for its own on-disk path, which is why the `cd` step stays a plain
instruction rather than a fake copy-paste path). **Recheck** re-pings without reloading the page.

---

## ➕ New story (git worktree creation — no terminal, no Claude Code)

Until this, creating a story meant a terminal (`switch-story.ps1 new <KEY> <env> <apps>`) or Claude
Code (`/ganesha-worktree "create story <jira url> <mint> <apps>"`, which parses the key, fetches
the title over the Atlassian MCP, then runs the same two script calls). The script side of that was
already 100% deterministic — branch name is `"feature/$env/$Story"`, key validation is two regexes
— so the only thing standing between the popup and creating a story on its own was a `-Json` mode
and a bridge action. The popup's **title field is a manual substitute for the Jira fetch**, a
deliberate trade for zero new auth: the skill's MCP-based title lookup needs a live Claude Code
session, and no Jira credential exists anywhere in this codebase to replace it with. Fill it in by
hand, or leave it — `switch-story.ps1` has always left it blank otherwise.

```
popup + New story → Check & create  ──sendMessage('checkAddWorktree')──▶  background.js
   └─ sendNativeMessage(NATIVE_HOST, {action:'addcheck', story, env, apps, branch})
        ──▶  host.ps1  ──▶  ..\tools\switch-story.ps1 new <KEY> <env> <apps> -Root <root> -Branch <b> -CheckOnly -Json
             (validates key/branch shape, duplicate, which apps are cloned, new-vs-existing branch
              per app — changes nothing)
popup ✓ confirm  ──sendMessage('addWorktree')──▶  background.js
   └─ sendNativeMessage(NATIVE_HOST, {action:'add', story, env, apps, branch, title, jiraUrl, open})
        ──▶  host.ps1  ──▶  ..\tools\switch-story.ps1 new <KEY> <env> <apps> -Root <root> -Title <t> -JiraUrl <u>
             -Branch <b> -NoInstall [-Open] -Json
             (registers the stories.json node FIRST, then per app: git fetch origin → git worktree
              add --no-track -b <branch> ... origin/<app's own detected default branch>, or check
              out <branch> if it already exists → seed .env from home base → init the ledger →
              optionally write + open the .code-workspace)
```

- **Repo discovery** is the `apps` action: it scans `<ReposRoot>\*` (`<root>\repositories\` for a
  new-enough project, else `<GRoot>\*` itself via `Resolve-StgPaths`' fallback — see **Worktree
  paths & branch format** below) for a **`.git` directory** (a home base clone) vs a **`.git` file**
  (a worktree) vs **neither** (a story folder) — the *configured*
  app map (see **Settings: Apps** below) is not the ground truth for what's actually cloned, it's
  cross-referenced against the scan. Returns `{app, repo, origin, onDisk, mapped, used, def,
  hidden}` per app (`def` is the app map's port/start/health entry, `$null` when unmapped); an
  app hidden from Settings still comes back with `hidden:true` rather than being silently dropped,
  so the checklist can filter it out while Settings can still offer "unhide". `onDisk:false` rows
  are shown disabled ("not cloned") rather than hidden, so the form explains a missing app instead
  of looking incomplete. `repo` is the canonical `ui` spelling for `ganesha-iu-internal-app` (global
  `CLAUDE.md`'s iu→ui rule) — the checklist displays `repo`, submission still sends the `iu`
  directory name.
- **Branch is editable, not just derived.** The field pre-fills `feature/<env>/<KEY>` and re-derives
  live as key/env change, until the user types into it directly. A non-conventional name still
  works but a warning says `gh pr list/create --head feature/<env>/<STORY>` and the
  `ganesha-branches` skill won't find it automatically. Either way, `new` now checks whether the
  branch **already exists** (locally or on origin) per app — the same probe `add` already used
  (`Test-BranchExists` in `switch-story.ps1`) — and checks it out instead of `-b`-ing it again. This
  also fixes a latent bug: recreating a story whose branch survived a prior `remove-worktree.ps1`
  (branch is kept by default) used to hard-fail with `fatal: a branch named '...' already exists`.
- **`-NoInstall` always.** `Install-Deps` can run for minutes (yarn/pip); native messaging is one
  message → one blocking reply, so the popup creates the node + worktrees in seconds and reports
  `deps not installed — run: switch-story.ps1 install <KEY>` rather than risk the host hanging past
  Chrome's native-messaging timeout. Backgrounding it would need a detached job + a poll action —
  not done.
- **`-Open` follows the popup's checkbox** (default on, matching `ganesha-worktree/SKILL.md`'s
  "always also open the workspace" convention) — `msg.open === false` is the only way to skip it.
- **A partial creation still refreshes the list.** The registry node is written *before* any git
  runs (same non-transactional reasoning as `remove-worktree.ps1`'s node-then-folders ordering), so
  if one app's `git worktree add` fails, the story still exists with the apps that succeeded —
  `res.ok` is `false` but `res.created` is non-empty, and the popup treats that as "refresh and show
  a warning," not a generic failure the user has to reload the popup to discover.
- **`switch-story.ps1 new -Json` contract**: `{ ok, story, env, branch, branchDerived, title, apps,
  created:[{app,path,status,branchExisted}], failed:[{app,error}], workspace, ledger, warnings,
  notes }`. `-CheckOnly` shape: `{ ok, checkOnly:true, story, env, branch, branchDerived,
  apps:[{app,onDisk,branchExisted}], warnings, error? }`. Like `remove-worktree.ps1`, every
  `Write-Host`/`Write-Warning` on the code paths `new -Json` can reach is routed through `Say`/
  `Warn2` collectors instead of the console — confirmed necessary, not theoretical: even the
  `StoryLib.psm1 not loaded` warning at the top of the script reaches a nested
  `powershell.exe -File`'s captured stdout and corrupts the JSON frame if left as a raw
  `Write-Warning`.
- **Single-element arrays still collapse.** `ConvertTo-Json` serializes a one-item PowerShell array
  as a bare scalar regardless of the `@()` wrapping at the source (that wrapping matters for a
  different reason — see the `apps` field comment in `switch-story.ps1`'s `Invoke-New`). Every array
  field this flow reads back in JS (`apps`, `created`, `failed`, `warnings`, `notes`) goes through
  the existing `asArr()` normalizer, the same one `rules-lib.js` already needed for `stories.json`
  itself.
- **Its own full-panel popup view.** Clicking **+ New story** hides `#mainView` (controls + list)
  and shows only `#addForm` — not an inline panel above the list. A long app checklist in a 328px
  popup would otherwise push the whole story list off-screen. `Cancel` or a successful create
  restores `#mainView`; `repaint()` keeps updating the (hidden) list underneath regardless, so it's
  current the moment you return to it. **This didn't actually work for a while** — see the
  `[hidden]`-vs-`display` gotcha below; `.addform`/`.afapps-body` needed an explicit
  `.addform[hidden] { display: none }` override before the toggle had any visible effect at all.
- **The app checklist is collapsible + searchable**, for the same "flooding the UI" reason: it
  opens collapsed (`#afAppsHdr`/`addAppsExpanded`) behind a live `"N apps selected"` summary — the
  count stays visible without expanding — and `#afAppsSearch` filters `renderAddApps()`'s rows by
  app/repo name before the existing used-count sort runs. Filtering never touches
  `addSelectedApps`; a checked app that scrolls out of view under a filter stays checked.

### + Add app (extend an EXISTING story with another app)

A one-app story that later needs a second app used to require the CLI (`switch-story.ps1 add
<KEY> <apps>`). **+ Add app** (top bar, acts on the highlighted row, same pattern as 📂) opens the
**same `#addForm` in `add` mode** (`openAddForm('add', key)`): key/env/branch/title are pre-filled
from the story's `stories.json` node and **locked**, the Jira row is hidden, `#afMode` says which
branch the worktree will be cut on, and the app checklist renders the story's current apps
**checked + disabled** (`in story` flag) so only new apps can be ticked - they never enter
`addSelectedApps`, so the summary reads "N new apps selected". `Check & add` ->
`checkAddApps` -> host `addappscheck` -> `switch-story.ps1 add <KEY> <apps> -CheckOnly -Root -Json`;
✓ -> `addApps` -> host `addapps` -> `... add <KEY> <apps> -NoInstall [-Open] -Root -Json`. `-Open`
follows the same "open in VS Code when done" checkbox and regenerates the `.code-workspace` so the
new app shows up. `Invoke-Add` now mirrors `Invoke-New`: per-app plan `{app, onDisk,
branchExisted, inStory, present}`, `-CheckOnly` returns `ok:false` with `not cloned: ...` or
`already in story: ...`, per-app try/catch -> `created[]` / `failed[]`, and only apps actually on
disk afterwards are merged into the node's `apps` (array-wrapped). Success handling in the popup is
the shared `registered` block in `doAddCreate()` with add-flavoured messages. `closeAddForm()`
resets the mode, so the next **+ New story** gets an unlocked, empty form.

### 📂 Open workspace (re-open an existing story, not just at creation)

Creation's `-Open` checkbox only ever fires once. Re-opening later — after a browser restart, or
just because you closed the window — had no path back except the CLI. **📂 Open workspace**, next
to **↗ Open all**, calls the same machinery `-Open` does, on demand: `switch-story.ps1 open <STORY>`
→ `Write-StoryWorkspace` (regenerates `<STORY>.code-workspace` from whichever worktrees currently
exist) → launches `code` if it's on PATH. Required `open` to join `new` in the `-Json` dispatch
switch (`Invoke-Open`'s two `Write-Host` calls became `Say` for the same reason every other
`-Json`-reachable function needed it — the console/JSON corruption risk described above) and
`Open-StoryWorkspace` to start **returning** `{workspace, opened}` instead of staying void — its
other caller, `Invoke-Go`, wraps the call in `[void](...)` so nothing leaks into a plain CLI run's
output. No worktrees yet for that story → the existing `"No worktrees exist..."` throw surfaces as
a normal `#rmMsg` error, same as any other bridge failure.

### Settings: configurable root / worktree root / workspace dir / branch format

`stories.json`, the home-base app clones, per-story worktrees, the generated `.code-workspace`
files and the derived branch name are **data** — where they live is entirely separate from where
the extension's own scripts (`tools\`) live. The Options page's **Worktree paths & branch format**
card and **Organization settings** card make every one of these overridable (see [Standalone /
portability](#standalone--portability) for the full precedence order):

- **Root** — where `stories.json` lives, resolved fresh on every host call
  (`Resolve-StgPaths`), never assumed to be "wherever the scripts physically sit". Relocating your
  data tree, or moving the *extension folder* itself, no longer requires re-running anything
  except when the extension's id changes (see the id-drift gotcha below) — the two moves are
  independent.
- **Worktree root** — genuinely different from Root: only *per-story* worktree folders
  (`<worktreeRoot>\<STORY>\<app>`) move; home-base clones (see **Repos root** below) don't move with
  it. This is the "my worktrees are bloating my main drive" case.
- **Workspace dir** — where `.code-workspace` files are written.
- **Repos root** — where home-base app clones (`git fetch`/`git worktree add`'s source) actually
  live. Genuinely different from both Root and Worktree root: this is *where you `git clone` your
  apps*, not where per-story copies of them go.
- **A brand-new worktree-mode project's default**: `New-StgProject` now bakes `worktreeRoot`/
  `workspaceRoot`/`reposRoot` explicitly into the new project's own record, pointing at
  `<root>\worktree\`, `<root>\workspace\` and `<root>\repositories\` respectively (all three created
  on disk immediately, alongside `stories.json`/`app-map.json`) — a tidier shape than the tool's own
  OLD fallback defaults (worktrees landing flatly at `<Root>\<STORY>\<app>`, workspace files in an
  *external sibling* folder `<parent of Root>\<Root's folder name>_WorkSpaces`, app clones flatly
  mixed into Root itself), found worth making the default after noticing a real project's
  *manually*-configured worktree/workspace paths already used exactly this `<root>\worktree` /
  `<root>\workspace` shape (`reposRoot`/`<root>\repositories\` extends the same idea to app clones,
  a distinct follow-on ask, verified against **13 call sites across 5 files** that all assumed a
  clone lived at `<Root>\<app>` directly, none through a shared helper — `Get-HomeBaseApps` and
  `Write-MainWorkspace` in `switch-story.ps1`, `New-WorktreeExisting`/`New-WorktreeFromMain`,
  `Invoke-New`/`Invoke-Add`/`Invoke-Remove`'s per-app `$baseDir`, `remove-worktree.ps1`'s removal
  loop, `story-handover.ps1`'s worktree-move step, and `host.ps1`'s `apps` scan — each redirected to
  read `$ReposRoot`/`$PathsInfo.ReposRoot` instead). **This only ever affects a project added from
  this point on** — an existing project with no `worktreeRoot`/`workspaceRoot`/`reposRoot` field of
  its own still resolves through the unchanged old fallback (`Resolve-StgPaths`'s own defaulting
  logic was deliberately left untouched, specifically so this couldn't silently move where an
  existing project's future worktrees/workspace files/app clones are looked for — confirmed live
  against PortfolioApp's real resolved paths). Blank fields in Settings still show the OLD defaults
  as their placeholder text — that's the fallback's own default, not this feature's. Clearing a
  field in Settings reverts to that same fallback (`Root` itself for Repos root), **not** to
  whatever the auto-created folder happened to contain — confirmed live: clearing `reposRoot` after
  a real clone existed under `<root>\repositories\` made resolution fall back to `Root`, not
  silently remember the folder.
- **Tracking mode gets `worktree\`/`workspace\` too, empty** (`New-StgTrackingScaffold`) — cosmetic
  structural consistency only (a tracking-mode root doesn't look different from a worktree-mode
  one for no reason a person browsing it would understand); `Resolve-StgPaths` still returns
  `WorktreeRoot`/`WorkspaceDir` as `$null` for tracking mode, unchanged, and nothing reads or
  writes into these two folders there. **Repos root deliberately does NOT get a tracking-mode
  placeholder** — unlike `worktree\`/`workspace\`, "repositories" specifically means clones
  alongside a *container* root, which a tracking project's root (already the one tracked repo) has
  no analog for; `ReposRoot` is `$null` there too, but no folder is ever created.
- **Kept out of the home-base app-clone scan**: `Get-HomeBaseApps` (`switch-story.ps1`) and
  `host.ps1`'s `apps` action both skip-list the worktree-root and repos-root folders' own names now,
  alongside the workspace-dir entry already skip-listed there — belt-and-suspenders, since a
  dedicated `worktree\`/`repositories\` container has no `.git` *directory* directly inside it
  anyway (nested worktrees sit two levels down, and a worktree's own `.git` is a *file*, not a
  directory), so the existing `.git`-directory check already excluded it naturally even before this
  was added. The scan itself now targets `$ReposRoot`, not `$Root` directly — for an existing
  project (`ReposRoot` falling back to `Root`) this is byte-for-byte the same scan as before.
- **Organization settings** (Jira base URL, GitHub org, EOD task name prefix, owner, repo
  aliases) — every literal that used to be a hardcoded org-specific string (`vesta.atlassian.net`,
  `vesta-experimental`, `Ganesha EOD status reminder`, the `iu`→`ui` repo alias, `Vince Marfil`) is
  now one of these fields, defaulting to exactly that original value.

**Storage**: `%LOCALAPPDATA%\story-tab-groups\stg-config.json` (`{ root, worktreeRoot,
workspaceRoot, reposRoot, branchFormat, jiraBaseUrl, githubOrg, repoAliases, taskNamePrefix, owner,
hiddenApps }`, all optional), written by `tools\stg-paths.psm1`'s `Set-StgConfig` (called from both
the host's `setConfig` action and every `tools\*.ps1` script directly) and read by `Get-StgConfig` /
the host's `getConfig` action — **outside** the extension folder on purpose, so replacing or
relocating the extension folder itself never wipes settings, and a file (not browser-only storage)
because `tools\switch-story.ps1` is also a CLI tool per this file's own conventions — a file keeps
the CLI and the extension reading the same source of truth. Absent file/fields = every default
exactly as before any of this existed. `hiddenApps` is gated on **key presence**, not truthiness,
unlike `repoAliases` (see below) — sending an empty array must actually clear the key so unhiding
the last hidden app works, not silently keep the old hidden set.

### Settings: Apps

The Options page's **Apps** card manages `tools\app-map.json`'s per-app `port`/`start`/`health`
entries and a `hiddenApps` list, closing two gaps that otherwise made the checklist and the ⚡
ports/health button unreliable on a fresh install:

- **Every app the disk scan finds, plus anything mapped-but-not-cloned, in one list.** Backed by
  the same `apps` action the "+ New story" checklist uses (`getApps` → `host.ps1`'s `apps`), which
  now also returns each app's `def` (its port/start/health, `null` if unmapped) and `hidden` flag —
  no second round trip for the card to render.
- **Add / edit / remove a mapping.** Editing an on-disk app's port/start/health, or mapping an app
  that isn't cloned yet (e.g. one you plan to worktree later), all write through **`setappmap`**
  (host) / **`setAppMap`** (background.js case) — the map is replaced wholesale each Save, since
  the card always sends its full current state. **Remove** only appears for a not-cloned app (you
  can't "remove" a real clone); for a cloned app, clearing its fields to blank and saving un-maps
  it instead.
- **Hide / unhide.** A hidden app is excluded from the "+ New story" checklist but **stays listed
  in Settings** with an "unhide" option — it is a real, still-scanned repo, not something dropped
  from the scan (`native-host/host.ps1`'s `$skip` list is a different, structural thing: folders
  that are never candidate apps at all, like this extension's own folder or `tools\`). Persisted as
  `hiddenApps` in `stg-config.json`.
- **Storage lives in the project's own folder, next to its `stories.json`.** `setappmap` writes to
  **`<project root>\app-map.json`** — never the shipped `tools\app-map.json` template. A project is
  meant to be self-contained: everything about it (`stories.json`, `stories_history.json`,
  `app-map.json`) sits in one folder you can find or back up as a unit, rather than split between
  its own root and the extension's own `%LOCALAPPDATA%`. `New-StgProject` creates an empty
  `app-map.json` there (alongside an empty `stories.json`) the moment a project is added — see
  [Projects](#projects-multi-project-support) for why this auto-create exists at all (a real,
  previously-undiscovered gap: a project with no `stories.json` couldn't create its first story).
  **This moved here from an earlier, `%LOCALAPPDATA%`-centric design** — `Get-StgAppMapPath -Project
  <id>` still checks the *old* `%LOCALAPPDATA%\story-tab-groups\projects\<id>\app-map.json` location
  as a read-only fallback for any project with real data still sitting there from before the move
  (never written to again; the next Settings save "completes" that project's migration on its own,
  no separate step needed), then the shared `%LOCALAPPDATA%\story-tab-groups\app-map.json` singleton
  **only while at most one project is configured total**, then the shipped template. **Both moves
  were found by live-testing, not design review**: first, an unconditional shared-singleton fallback
  let a brand-new second project silently inherit the first project's entire app list as "not
  cloned" placeholders (fixed by the "≤1 project" gate); then, once that was fixed, the user pointed
  out the surviving per-project `%LOCALAPPDATA%` rung itself was still the wrong place for project
  data to live at all — moving it into the project's own folder is what actually resolved that.
  The first Settings save on any given project still seeds forward whatever `pythonSentinel` that
  project's currently-effective file has, so it isn't silently reset to `story-env.ps1`'s own
  `'fastapi'` default.
- **Validation happens before, not during, the write.** A non-numeric port or a name containing a
  path separator gets a clean `ok:false` from `setappmap`, both client-side (immediate feedback) and
  host-side (`[int]::TryParse`, not a bare `[int]` cast — a bad string on the bare cast throws under
  this script's `$ErrorActionPreference = 'Stop'` and would otherwise crash the whole action, the
  same failure mode described in the dev gotcha below, one field over).

**Migration safety (why an existing story never gets stranded)**: `switch-story.ps1 new` records
`worktreeRoot` on a story's `stories.json` node **only when it differs from Root** at creation time.
Every command that acts on an *existing* story (`go`, `add`, `install`, `remove`, `list`,
`open`) reads the node's own field — never the current global setting — so changing Worktree Root
later can't make an older story's files "disappear" from the tool's perspective. `Get-WtPath` (and
`New-WorktreeExisting`/`New-WorktreeFromMain`) take an explicit `$wtRootOverride`, falling back to
`$Root` (not the current global default) when a node predates this feature entirely.
`remove-worktree.ps1` needs the identical override (`Get-StoryStatus`, the main removal flow, and
the `$storyDir` parent-folder cleanup) but **doesn't touch `Get-StoryFolders` itself** — that lives
in `tools\StoryLib.psm1` and is shared by every script that needs worktree-aware folder discovery,
so it patches just the per-app paths `Get-StoryFolders` returned, after the fact, whenever
`$node.worktreeRoot` is set, rather than forking the function.

**Repos root deliberately gets NO equivalent per-story pinning.** A home-base clone's location is a
*project*-level fact (where you `git clone`d it), not a per-story one the way a worktree's location
is — every story that touches the same app always resolves the SAME clone, so there's nothing to
strand: `$ReposRoot` is read fresh from the CURRENT project config on every git operation, with no
node field recording where it "used to be." Confirmed by tracing all 13 call sites before building
this (see **Worktree paths & branch format** above) — none of them read a per-story override for
this, unlike every `worktreeRoot`/`Get-WtPath` call site.

**Branch format**: `-BranchFormat` templates the *derived* default (`feature/{env}/{key}` built in;
only `{env}`/`{key}` are recognized, substituted with plain `.Replace()` — not regex `-replace`, so
a key or env containing `$` or `&` can't be misread as a backreference). `-Branch` (an exact name,
already existed) still overrides the derived value outright either way. The "doesn't match
convention" warning compares against the *configured* format's own rendering, not the hardcoded
string, so setting a custom global default never warns about matching yourself.

---

## 🟢 Ready/blocked badges + ♻ discard-generated (popup at-a-glance)

Each popup row carries a status badge so you can see which finished stories are safe to tear down
without clicking 🗑 one at a time:

- **How it's computed:** on every popup open, `popup.js` → `checkWorktrees` → native host `check`
  action → `remove-worktree.ps1 -CheckAll -Json` → one PowerShell run that loops every story in
  `stories.json` and reports per-app blockers (`Get-StoryStatus`, read-only, reuses `Get-Blockers`).
  Returns `{ stories: { KEY: { ok, blockers:[{app,dirty,unpushed,noUpstream}], present } } }`.
- **Badges:** 🟢 **ready** (clean & pushed) / 🟡 **`N changed, M unpushed`** (hover = per-app detail).
  Silent no-op if the native host is absent — badges just don't render, rest of the popup works.
- **♻ discard-generated & remove:** shown **only** when every blocker is *purely* allow-listed
  generated files (`yarn.lock`, `package-lock.json`, `*routeTree.gen.ts`) with **no** unpushed/
  no-upstream commits — i.e. the routine "generated files are the only thing blocking" case. Clicking
  it → inline ✓/✕ confirm → `removeWorktree` with `discardGenerated:true` → `remove-worktree.ps1
  -DiscardGenerated`, which `Discard-Generated`s those files first (restore tracked from HEAD, delete
  untracked — **never** `.env` or any non-generated file), then proceeds through the normal guardrail.
  If any real file or unpushed commit is present, ♻ does **not** appear → 🗑 stays blocked and routes
  to you, exactly as before. This is the only place removal discards anything beyond `.env`.
- **Allow-list lives in two places that MUST stay in sync:** `Test-Generated` (PS) and
  `isGeneratedFile()` (popup.js). Edit both together. It's deliberately conservative — when unsure
  whether a file is generated, it's NOT on the list, so it blocks (safe default).

---

## 🚀 Released toggle (shipped != torn down)

Releasing a ticket used to leave no local trace. The only terminal action was 🗑, which is
guardrailed and too final, so shipped stories sat in the popup looking active, `vault-status.ps1`
showed a stale phase, and nothing could tell `/eod` to emit its "done" line.

- **"Released" is not a new concept.** It is the ledger's existing last phase, **`deploy`**. The 🚀
  button stamps that phase, so the row's phase chip, `vault-status.ps1` and `story-doctor.ps1` all
  update for free with no parallel state to keep in sync. The `released` field on the
  `stories.json` node is just a cheap denormalised read for the chip and `/eod`, and it rides into
  `stories_history.json` on removal because the whole node is archived.
- **Write side** is `..	ools\story-release.ps1` (`release` / `unrelease` / `status -All`), so the
  CLI and the button share one implementation. `release` first runs `story-ledger.ps1 sync`, which
  backfills the `plan` phase from a node field that already proves it happened (`document` /
  `document_keycloak_setup`) - that is what stops a shipped story showing a stale pending checklist
  item forever. (The ledger's phase list used to include six org-specific prep-release gates -
  release-notes/rel-ticket/agiletest/release-branch/release-prs/chg - each backfilled from its own
  node field the same way; they were dropped when the org's deployment process changed, leaving
  `deploy` as the sole phase in its own **Release** group, renamed from "Prep Release". See
  `tools/story-ledger.ps1`'s `$DefaultPhases` for the current list.) Both directions are
  **idempotent**.
- **Toggle, not a one-way door.** Clicking 🚀 on a released story rolls it back (revert / rollback),
  resetting `deploy` to pending and clearing `released`. It also clears `released_posted`, so a
  later re-release announces "done" again in the EOD post.
- **Nothing is removed.** 🗑 and ♻ stay available on a released row, and the row keeps its place -
  it just gains a **✔ released** chip. A rollback must never be more than one click away.
- **Chip data is free**: it comes from the `released` action fetched alongside `getStories` /
  `getLedgers` in `refreshMeta()`, so there is no extra native round trip on popup open.
- **No `prompt()` for the rollback reason** (same rule as `confirm()`): the popup sends a fixed
  `"unreleased from popup"`. Use `/note` when a rollback needs real detail.
- **Cleanup nag**: because released stories now accumulate on disk deliberately,
  `story-doctor.ps1` reports `released-not-removed` as an **info** once one has sat there
  `$ReleasedGraceDays` (7) days.

## 📜 Story history (`stories_history.json` + the History viewer)

Removal is no longer purely destructive — the full story node is **archived before it's dropped**.

- **Write side** lives in `remove-worktree.ps1`, NOT the extension — so *every* path that removes a
  node (the 🗑 button, the native host, or a direct CLI run) gets archived, and a blocked/aborted
  removal never logs (those paths `return` early). The `Archive-Story` helper runs right before the
  `stories.json` node is dropped, only when all worktrees were removed successfully. It appends to
  `..\stories_history.json` (sibling of `stories.json`, **outside** the repos):
  `{ "removed": [ { key, removed_at, apps, removal:[per-app status], node:<the entire original node> } ] }`.
  It's **best-effort**: a failed write returns `archived:"archive-failed: …"` in the result but never
  blocks removal (the worktrees are already gone). The result JSON gains an `archived` field.
- **Read side**: the extension can't touch the disk, so `history.html`/`history.js` ask the SW
  (`getHistory`) → native host `history` action → returns the raw file text → JS parses it. Open it
  from the popup footer's **History** link.
- **Gotcha — PS single-element array:** `ConvertTo-Json` collapses a one-entry `removed` array to a
  bare object; both `host.ps1`/`Archive-Story` and the JS reader normalize with `@(...)` / `asArr`.
- Native messaging caps the host→extension reply at ~1MB; the verbose per-story logs make the file
  grow, but it's nowhere near that at human scale. No pruning today.

---

## Standalone / portability

The whole point of this section: **copy `story-tab-groups\` anywhere, run `.\setup.ps1` once, and
it works — no hand-editing, no second folder full of scripts, no other machine's paths baked in.**

- **One script location.** Every `.ps1`/`.psm1` this extension needs lives in `tools\`, a sibling
  of `native-host\` inside the extension folder itself — not at a fixed path like `Ganesha\tools\`,
  not split across a second "reference copies" folder. `native-host\host.ps1` always resolves
  scripts from `tools\` (`$ScriptsDir = ..\tools`, relative to *itself*), never from the data root.
- **`tools\stg-paths.psm1` is the single root resolver**, imported by every script in `tools\` and
  by `native-host\host.ps1`. `Resolve-StgPaths [-Root] [-WorktreeRoot]` returns the data root, the
  worktree root, the workspace dir, and — critically — `.Source` (which rule decided it:
  `parameter` / `config` / `env:STG_ROOT` / `auto-detect`) and `.NeedsSetup` (true with a named
  `.Error` when nothing resolved, never a silent wrong guess). Precedence: an explicit `-Root` →
  `%LOCALAPPDATA%\story-tab-groups\stg-config.json` → `$env:STG_ROOT` → auto-detect (walk up from
  the scripts looking for a folder containing `stories.json`). **Config outranks the env var, not
  the other way around** — `$env:STG_ROOT` lives in a process's OS environment block, which a
  long-lived process (a browser, concretely) has frozen at its own startup, completely independent
  of whenever `stg-config.json` was last written; a user who runs `setup.ps1` (writes the config
  file *and* publishes `STG_ROOT`) while Chrome is already open ends up with an already-running
  Chrome whose native-host children keep inheriting whatever `STG_ROOT` existed when Chrome itself
  started, stale or absent, while the config file sitting right there is completely correct.
  Confirmed as a real, reproduced cause of a story that had genuinely been removed still reporting
  "not in stories.json" on the next click — the fix was this precedence swap, not another cache
  invalidation. `$env:STG_ROOT` keeps its purpose (a bare terminal/skill invocation with no config
  file yet) by still beating blind auto-detect. The module also exposes
  `Get-StgConfig`/`Set-StgConfig` (the config file), `Get-StgOrgDefaults`/`Get-StgOwnerConfigDir`
  (the de-hardcoded org literals below), `Get-StgAppMapPath [-Project]` (a four-rung ladder:
  `<project root>\app-map.json` (canonical, auto-created by `New-StgProject`) → the *old*
  per-project `%LOCALAPPDATA%\...\projects\<id>\app-map.json` rung (read-only fallback for a
  project with real data still there from before app-map.json moved into the project's own folder)
  → the shared `%LOCALAPPDATA%` singleton (only while ≤1 project exists) → the `tools\app-map.json`
  template; see [Settings: Apps](#settings-apps) and [Projects](#projects-multi-project-support) —
  `native-host\host.ps1`'s `setappmap` action always writes to the project-root rung once a project
  context resolves, so two projects' app maps never collide, and a project on the old rung
  self-migrates the moment its Apps card is next saved), and `Get-StgNames` (a JSON object's property names
  as a real array, never the `@($null)` one-element-array-of-null trap — see the dev gotcha below).
- **Every org-specific literal is config, defaulting to this project's original values**: the
  `Ganesha_WorkSpaces` folder name (now derived: `<rootLeaf>_WorkSpaces`, overridable via
  `workspaceRoot`), `%USERPROFILE%\.ganesha` (now `.story-tab-groups`, falling back to the legacy
  name if it already exists so an existing Slack token isn't orphaned), the EOD scheduled-task name
  prefix, the `Vince Marfil` owner string (now `$env:USERNAME`), the Jira base URL, the GitHub org,
  and the `ganesha-iu-internal-app`→`ganesha-ui-internal-app` repo alias. All editable from
  Settings' **Organization settings** card.
- **`setup.ps1`** (extension root) does the whole first-run dance: registers + end-to-end pings the
  native host, finds or prompts for the data root, publishes `STG_ROOT`/`STG_TOOLS` as user
  environment variables, and runs a preflight (git/code/every required script/`StoryLib.psm1`/
  `app-map.json`/`stories.json` readability — the same checks Settings' **Paths & diagnostics**
  card re-runs via the host's `preflight` action). Given `-OldExtensionDir <path>`, it also migrates
  a prior non-standalone install: carries that install's `stg-config.json` root into
  `%LOCALAPPDATA%`, renames an old root-level `tools\`/`switch-story.ps1`/`remove-worktree.ps1` to
  `.old` (closing the two-copies trap for good — and carries forward a *populated* old
  `app-map.json` first, if the fresh template hasn't been filled in yet), re-registers the EOD
  scheduled tasks at the new script path, unregisters the stale `com.vesta.worktree` native host,
  and warns (never silently fixes — Chrome has no API for it) about any other loaded copy of this
  extension. `-WhatIf` previews every step without changing anything; each migration step also
  confirms individually unless `-Force`.
- **Host id**: `com.storytabgroups.worktree`, one constant (`NATIVE_HOST` in `background.js`,
  `$HostName` in `install-native-host.ps1`) — not 19 repeated string literals. The generated
  manifest (`native-host\com.storytabgroups.worktree.json`) and the per-machine config
  (`stg-config.json`) are both git-ignored; nothing machine-specific ships in the repo.
- **Rules build automatically.** `background.js`'s `getRules()` tries, in order: a saved override →
  the native host's `stories` action (raw `stories.json`) run through `RBCore.buildRules()` → the
  packaged `rules.json` (an empty stub, last resort only) → an empty rule set. A fresh install with
  the native host working needs **no Options visit, no file picker, no `node gen-rules.mjs` run** —
  this is the fix for "rules.json / ruleset.json can't be found".

---

## Dev gotchas (these cost real debugging time)

- **`Copy-Item -LiteralPath` with a trailing `\*` does not expand it as a wildcard — and silently
  copies nothing, with no error, even under `-ErrorAction Stop`.** Wildcard expansion (`a\*` meaning
  "everything in `a`") is `-Path`'s behavior; `-LiteralPath` exists specifically to turn that off, so
  it looks for a file literally named `*`, finds none, and — confirmed live, isolated in a scratch
  folder — the whole `Copy-Item` call is just a silent no-op rather than a thrown "path not found."
  This hit `install-agent-skill.ps1`'s first draft of copying a generic (non-templated) skill's whole
  folder tree: `Copy-Item -LiteralPath (Join-Path $skillDir '*') -Destination $destDir -Recurse -Force`
  against an already-created empty `$destDir` reported `ok:true, installed:true` with a
  perfectly plausible-looking path, while the destination folder stayed completely empty — the kind
  of bug that announces nothing is wrong unless you actually `Get-ChildItem` the result. **Fix: don't
  create the destination first and try to copy *into* it — copy the SOURCE folder itself (which
  already carries the right leaf name) into the destination's *parent* instead**
  (`Copy-Item -LiteralPath $skillDir -Destination $destParent -Recurse -Force`, after removing any
  stale `$destDir` so a version that dropped a file doesn't leave it behind) — no wildcard needed at
  all. See [Agent skill](#agent-skill-claude-code--codex--chatgpt)'s Optional skills entry for the
  full context this was caught in.
- **MV3 service worker goes stale on `⟳` reload.** Editing `background.js` and clicking the card's
  ⟳ often keeps the *old* worker warm — symptom: the popup is new but messages fall through to the
  `default:` case (e.g. a remove returns `error:"unknown"`). **Fix: toggle the extension Off then
  On** (forces a fresh worker, keeps the id). Confirm via the **"service worker"** link → console →
  `[stg-bg] service worker build: …`.
- **No `confirm()` / `alert()` in the popup.** Opening a native dialog blurs the popup, which Chrome
  auto-closes → the call returns/!does nothing. That's why removal uses an **inline** confirm + the
  `#rmMsg` status line. Keep it that way.
- **A saved rules override can silently outlive every real change you make.** `rulesOverrides[projectId]`
  (Settings' Advanced paste/picker box) is checked *first* in `buildProjectRules()`, by original,
  deliberate design — a "trust my curation" escape hatch that's meant to beat live data. The trap:
  `forceRulesRebuild()` (called after every story mutation) only ever cleared the *auto-built* cache, a
  completely different `chrome.storage.local` key from `rulesOverrides` — so once an override existed for
  a project, it stayed authoritative **forever**, through any number of real, host-confirmed story
  creations/removals, until someone found "Clear override" in Settings. **Confirmed live**, the hard way:
  two story creations in a row, both fully successful (real worktrees, real log entries, confirmed via
  direct native-host queries), neither ever appeared in the popup — because an override had been pinned
  earlier via the popup's own "Load stories.json" button (`RB.syncSilently()`), and nothing had ever
  cleared it. **That popup button is gone now** — the identical capability still exists in Settings'
  Advanced section, deliberately framed as a native-host-unreachable fallback rather than an ambient
  one-click control anyone could trip on the primary surface. **Fix, and the standing rule**:
  `background.js`'s `clearProjectOverride(projectId)` runs alongside `forceRulesRebuild()` at every case
  that mutates a story node for a specific project (`addWorktree`/`addApps`/`removeWorktree`/
  `setReleased`/`setStoryLinks`) — any future case that writes to a project's `stories.json` needs the
  same pairing, or it'll reopen this exact trap. The one legitimate remaining case (a deliberate override
  that hasn't been superseded by a real change yet) is surfaced via the popup's `#overrideNote`, not left
  silent.
- **`[hidden]` silently loses to a same-specificity `display` rule.** The browser's own
  `[hidden] { display: none }` is an attribute selector; a class selector like `.addform { display:
  flex }` has *identical* specificity, and on a tie the later stylesheet wins — which is always the
  page's own `<style>` block, since it loads after the UA default. Net effect: toggling
  `el.hidden = true/false` in JS does **nothing visible** and the element just renders
  unconditionally, with no error anywhere to point at it. This bit `#addForm`/`.addform` and
  `#afAppsBody`/`.afapps-body` for a while (the "+ New story" form and the app checklist both
  showed regardless of state). **Fix: whenever a class/id rule sets `display` on something you also
  toggle via `hidden`, add `.thatClass[hidden] { display: none }`** — compounding the attribute onto
  the class selector raises its specificity above the plain class rule, so `hidden` wins again
  once it's actually applied. `#mainView` never had this problem only because it carries no
  explicit CSS of its own.
- **`@($obj.PSObject.Properties.Name)` throws on an EMPTY object, silently.** This idiom (iterate a
  JSON object's keys as an array, used all over `tools\*.ps1`/`native-host\host.ps1` for
  `stories.json`) is only safe once the object has at least one property. On an empty one (a fresh
  install's `"stories": {}`) the bare `.Properties.Name` expression is `$null`, and `@($null)` is a
  **one-element array holding `$null`** — not an empty array, because `@()` exists specifically to
  stop PowerShell collapsing a *one*-property object to a bare scalar, and it can't tell "empty"
  from "one null" apart from the wrapped value itself. The `foreach` then runs once with a `$null`
  key, and any `$hashtable[$key] = ...` in the loop body throws `"Index operation failed; the array
  index evaluated to null"` under this project's `$ErrorActionPreference = 'Stop'` — with no error
  at the point that actually reads the JSON, only deep inside the loop body, on a fresh install with
  zero stories, in code that works fine the moment a first story exists. This was the real cause of
  the "no repos found — native host installed, and tools\app-map.json present?" bug: `host.ps1`'s
  `apps` action crashed on `stories.json`'s empty `stories: {}`, and the popup discarded the host's
  actual error before showing anything. **Fix: `tools\stg-paths.psm1`'s `Get-StgNames $obj`** —
  filters nulls out of the pipeline before the `@()` wrap, so it returns 0 names on empty, 1 on a
  single property, N on N, without reintroducing the scalar-collapse bug `@()` was there to prevent
  in the first place. Bare foreach-over-properties reads (no hashtable/array index in the body) are
  unaffected — `Join-Path $x $null` and property access on `$null` both degrade harmlessly, so only
  sites that *index* with the loop variable need the fix. **Recurred independently in
  `story-doctor.ps1`'s `thin-history-record` check** (`foreach ($e in @($hist.removed))`, missing the
  `if (-not $e) { continue }` guard its own sibling `log-shape` loop two blocks up already has) — a
  phantom `info` finding with an empty story key on every project before its first-ever removal, found
  while verifying [Tracking mode](#tracking-mode) but pre-existing and affecting worktree-mode projects
  too. Same idiom, same fix, different call site — worth grepping for `@($` + a property access +
  no adjacent null-guard if this class of bug ever needs auditing again. **Recurred a third and fourth
  time in the same file** during the P6 bug sweep — `$regKeys`/`$mapApps` in `story-doctor.ps1`'s own
  setup block, both still the bare `@($obj.PSObject.Properties.Name)` idiom rather than `Get-StgNames`.
  `$regKeys` was the more consequential of the two: on a genuinely empty registry it produced a
  phantom `bad-key-shape` error (plus, in worktree mode, phantom `no-apps`/`no-jira` findings) —
  confirmed live via a fresh worktree-mode project with zero stories, `ok:true, findings:[]` after the
  fix vs. spurious errors before it. At this point the pattern is: **any new `@($x.PSObject.Properties
  .Name)` written in this codebase is very likely a bug on day one**, not something that degrades later
  — reach for `Get-StgNames` by default rather than the bare idiom, full stop.
- **`Write-Output -NoEnumerate` suppresses pipeline unrolling for *any* consumer, not just plain
  assignment — a different, easy-to-reintroduce PowerShell collapse trap from the one above.**
  `Get-StgProjects` (`stg-paths.psm1`) uses `-NoEnumerate` so a *one*-project result survives
  crossing its own `return` boundary as a real array instead of collapsing to a bare object
  (PowerShell unrolls any enumerable that crosses a function's return boundary, regardless of
  `@()`-wrapping *inside* the function — unrelated to `ConvertTo-Json`'s separate JSON-serialization
  collapse trap above). The sharp edge: piping the function call directly
  (`Get-StgProjects | Where-Object {...}`) or wrapping the *call* in `@()`
  (`@(Get-StgProjects)`) both silently fuse every project into one corrupted blob the moment a
  *second* project exists — `-eq`/`-ieq` against an array left-hand side degrades to a filter, not a
  scalar comparison, so a match against *either* project lets **both** through fused together (e.g.
  `Get-StgProject -Id 'acme'` returning a value whose `.id` prints as `"ganesha acme"`). This hit at
  least five separate call sites while building multi-project support — `Get-StgProject`'s own
  defensive `@(Get-StgProjects)`, `Resolve-StgPaths`'s `-Root` reverse lookup, and all three of
  `New-StgProject`/`Update-StgProject`/`Remove-StgProject` — each one looked like careful,
  even extra-careful code, and each was wrong, invisible in single-project testing every time.
  **Fix, and the standing rule for any future caller: capture into a plain variable first
  (`$x = Get-StgProjects`), then operate on that variable — never pipe or `@()`-wrap the live
  function call.** A captured variable enumerates normally regardless of how it was produced; only a
  function's *live* pipeline output is subject to `-NoEnumerate`.
- **A `Get-Content -Raw` result passed directly into `ConvertTo-Json` isn't the plain string it looks
  like.** Its declared .NET type is `System.String` (`.GetType().FullName` says so), but the PSObject
  wrapper still carries PowerShell's extended type-system members (`PSPath`/`PSParentPath`/
  `PSChildName`/`PSDrive`/`PSProvider`/`ReadCount`) that the provider infrastructure attaches to
  *every* `Get-Content` result. `ConvertTo-Json` walks `PSObject.Properties`, not the declared CLR
  type, so it sees an object with those properties and recurses into them at whatever `-Depth` was
  given — including `PSDrive`/`PSProvider`'s own large, framework-internal object graphs. Not an
  infinite loop, but slow enough to be indistinguishable from a hang in practice: confirmed by
  isolated testing, an identical hashtable serialized instantly with `[System.IO.File]::ReadAllText`'s
  plain string but never returned within 30s with `Get-Content -Raw`'s decorated one. This is exactly
  what `story-doc.ps1`'s `show` action hit on its very first live test (see
  [Tracking mode](#tracking-mode) for the full story). **Fix, and the standing rule: never pass a
  `Get-Content -Raw` result directly into `ConvertTo-Json`.** Either read the file with
  `[System.IO.File]::ReadAllText` in the first place (this file's existing convention for writes via
  `[System.IO.File]::WriteAllText` — same API family, same reasoning), or reinterpolate the string
  first (`"$x"` forces a genuinely new String with no ETS wrapper). An explicit `[string](...)` cast
  also works — `host.ps1`'s history/registry-reading actions already do this, apparently by
  convention rather than by having hit this trap — but a bare assignment does not, and the type-check
  that would normally catch a "wrong type" bug (`.GetType().FullName`) reports `System.String` right
  up until `ConvertTo-Json` blows up anyway, so this one doesn't announce itself the way most type
  bugs do.
- **A JSON message field can't share its name with the dispatch key that routed to it.**
  `host.ps1`'s `storydoc` case read `$msg.action` for its own sub-action (`init`/`append`/`path`/
  `show`) — but `$msg.action` was already consumed by the outer `switch ($msg.action)` to route the
  message to this case in the first place, so it always evaluated to the literal string `"storydoc"`,
  never what the caller actually asked for. Every call was guaranteed to fail with `"invalid storydoc
  action: storydoc"` regardless of input — this shipped uncallable and was only caught by a live test
  the very first time anything actually invoked it (nothing else in this codebase had a reason to
  reuse `action` for a nested sub-action, which is exactly why this pattern hadn't bitten before).
  **Fix: name a sub-action field something other than `action`** (`docAction`, here) — obvious once
  stated, easy to not notice when writing the message shape and the case body in the same sitting.
- **Build markers** (`[stg]…build:` in popup console, `[stg-bg]…build:` in the SW console,
  `[stg-hist]…build:` in the History tab console, `[stg-opt]…build:` in the Settings tab console)
  are the fast way to verify a reload actually took — bump them when you change behavior.
- **Removing + re-adding** (vs toggling) the unpacked extension changes its **id** → the native host
  `allowed_origins` no longer matches → 🗑 errors with "native host not found". Re-run
  `.\setup.ps1` or `native-host\install-native-host.ps1` (auto-detects the new id) and restart the
  browser. This is a *different* problem from relocating data (below) — a changed extension id
  always needs the installer re-run regardless of the `root` setting, since `allowed_origins` is
  about the extension's identity, not where any files live.
- **Relocated the extension folder itself** (moved this whole `story-tab-groups\` somewhere else,
  same Chrome load — *not* remove+re-add)? Nothing to configure — `tools\` and `native-host\` are
  both self-locating via `$PSScriptRoot`, and the extension's id doesn't change just from moving
  files on disk. Only re-run the installer if you *also* removed+re-added the unpacked extension in
  Chrome (the bullet above).
- **Relocated the data tree** (`stories.json` + the worktrees, independent of where the extension
  folder lives)? Set **root** in Settings → Worktree paths & branch format instead of touching
  anything on disk — `tools\stg-paths.psm1`'s `Resolve-StgPaths` re-reads that setting on every
  call. No browser restart needed; it takes effect on the very next popup action.
- **`.env` never blocks** removal; **generated files** commonly do (e.g. `src/routeTree.gen.ts`,
  `yarn.lock`) — they show up in the blocked message.
- **An MV3 service worker's own lifecycle can produce `Uncaught (in promise) Error: No SW`** in
  `chrome://extensions`'s error console, with no application bug behind it at all — the worker
  respawning/tearing down mid-call is a normal, expected MV3 event, and a `chrome.*` API call that
  happens to land during that window rejects. **Caught live**, reported by the user during a P6 plan
  review: `chrome.tabs.onUpdated`'s auto-route handler only wrapped its final `addTabToStory` call in
  try/catch, leaving `getSettings()`/`getAllStories()`/`matchStory()` unguarded — any of the three
  rejecting during a worker respawn surfaced as this exact uncaught error, attributed to the
  listener's closing brace rather than anything that looked like a real bug. The same gap existed in
  `chrome.contextMenus.onClicked` (no error handling anywhere in its body) and
  `chrome.runtime.onMessage`'s IIFE (ended with no `.catch()`, so a case whose logic threw outside
  its own local try/catch both spammed the console *and* left the caller's `sendMessage` promise
  hanging forever with no reply). **Fix, and the standing rule: every top-level
  `chrome.*.addListener(async (...) => {...})` callback in `background.js` needs its *entire* body
  wrapped**, not just whichever call happens to be last or looks riskiest — `tabs.onUpdated`/
  `contextMenus.onClicked` swallow (fire-and-forget listeners, nothing for a human to act on), while
  `onMessage`'s IIFE gets a trailing `.catch()` that still calls `sendResponse` so the caller isn't
  left hanging.
- **`chrome.contextMenus.create()` has no promise/throw on error — only an optional callback plus
  `chrome.runtime.lastError`** — and three independent, uncoordinated triggers all rebuild the
  right-click "Add to story group" menu (`chrome.runtime.onInstalled`, `chrome.runtime.onStartup`,
  and `forceRulesRebuild()` after every story mutation). **Caught live** as `Unchecked
  runtime.lastError: Cannot create item with duplicate id root` in `chrome://extensions`'s error
  console — a story mutation landing right as the extension reloads (exactly what happens if you
  toggle the extension Off/On while testing, since that's precisely when `onInstalled` fires) is
  enough to run two `rebuildMenus()` calls concurrently: the second call's `create({id:'root'})`
  can land before the first call's own `removeAll()` has caught up, or before the first call's
  `create({id:'root'})` has landed — either way, a duplicate id. **Fix: `rebuildMenus()` no longer
  runs directly — every call is queued through one module-level promise chain
  (`_rebuildMenusChain = _rebuildMenusChain.then(rebuildMenusNow, rebuildMenusNow)`), so a second
  call always waits for the first to fully finish (its own `removeAll()` included) before starting
  its own.** Using the same handler for both the resolve and reject branch of `.then()` is what
  keeps one failed run from wedging every future call behind a permanently-rejected chain — confirmed
  with a standalone simulation before trusting it, not just reasoned about. `create()` calls also
  now pass a callback that reads (and discards) `chrome.runtime.lastError`, as defense-in-depth
  against any duplicate the chain doesn't anticipate — cheap insurance, not the actual fix. **The
  standing rule this leaves**: any `chrome.*` API with an uncoordinated set of triggers and no
  native serialization of its own (menus, and anything else that mutates shared browser-side state
  rather than just reading it) needs an explicit call-chain lock like this one, not just individual
  error handling at each call site.
- **`ConvertTo-Json` can turn a genuinely one-line fix into a payload-corrupting one if built by
  string concatenation instead.** `host.ps1`'s `ledgers` action used to build its JSON reply as
  `'{' + ($parts -join ',') + '}'`, splicing each ledger file's raw text in unvalidated — one
  malformed ledger file (a bad manual edit, a write interrupted mid-flush) broke `JSON.parse` for
  the *entire* combined payload on the JS side, not just that one story's ledger, since the whole
  point of string concatenation is that PowerShell never gets a chance to validate what it's
  splicing in. **Fix: parse each ledger independently (`ConvertFrom-Json`, its own try/catch — skip
  and move on, don't abort), assemble a real `[ordered]` hashtable, and let `ConvertTo-Json`
  serialize the whole thing once at the end.** A single bad ledger is now just... missing from the
  reply, the way a missing file already was, instead of taking every other story down with it.
- **`switch-story.ps1` used to hardcode `origin/main` as every new worktree's base branch** —
  `New-WorktreeFromMain`'s `git worktree add -b <branch> ... origin/main`. Any repo whose default
  branch is actually `master` (or anything else) made this fail outright, 100% reproducibly, on
  *every single story* that touched that app — the popup's only symptom was "`<KEY>` registered,
  but no worktree was created (`<app>`) — see console", with the actual git error visible only in
  the popup's own isolated DevTools context (right-click the popup → Inspect → Console →
  `[stg] create failures:`), not anywhere a first glance would find it. **Caught live**: `git
  branch -a` on the affected repo showed `remotes/origin/HEAD -> origin/master`, no `origin/main`
  at all — confirmed as the actual cause by reproducing the identical failure in a scratch repo
  with the same shape, then confirming the fix resolves it there. **Fix: `Get-DefaultBranch`**
  (`switch-story.ps1`, next to `Test-BranchExists`) resolves the repo's *real* default branch
  instead of assuming one — `git symbolic-ref -q --short refs/remotes/origin/HEAD` first (the
  authoritative source, set by git itself at clone time, correct for *any* naming convention, not
  just the two common ones), falling back to directly probing for `origin/main` then
  `origin/master` only if a clone never got `origin/HEAD` set at all. Verified against three real
  shapes: `main` (the common case, unchanged behavior), `master` (the exact bug — confirmed fixed
  via the fallback probe), and a deliberately unusual `trunk` with `origin/HEAD` properly set
  (confirmed fixed via the primary symref path) — so this isn't just "detect master too," it's a
  genuine "ask the repo what it actually calls its default branch" fix.
- **A new branch cut from a remote-tracking ref inherits that ref as its own upstream, even though
  the two have different names** — `git worktree add -b <branch> ... origin/main` (or any base
  branch) makes `branch.autoSetupMerge`'s default behavior set `<branch>`'s upstream to
  `origin/main` itself, not a same-named remote branch that doesn't exist yet. A bare `git push`
  on that brand-new branch then refuses with `"the upstream branch of your current branch does not
  match the name of your current branch"` — reported live, and confirmed 100% reproducible by
  git's own design (verified directly: creating a branch the same way with and without `--no-track`
  in a scratch repo, only the latter avoids the error). **Fix: `--no-track` on the `worktree add`
  call** — skips setting any upstream at all, so the first `git push` on a new story branch asks
  for `--set-upstream` once (the normal, expected new-branch prompt) instead of the confusing
  mismatch error, and every push after that first one works bare. For existing repos already hit by
  this, `git config --global push.default current` (push the current branch to a same-named remote
  branch regardless of configured upstream) fixes it globally with no code change, including on
  branches that already exist with the wrong tracking.
- **Dot-notation property access on a PowerShell ARRAY checks the array type's own real members
  BEFORE enumerating each element** — a naming collision, not the already-documented `@($null)` trap
  (though it produces a similar-looking failure). `setup-dev-loop.ps1`'s first draft built a report
  array of `[pscustomobject]@{ item = '...'; path = ...; created = ... }` and then read the names
  back with `$missing.item` / `$created.item`. Since `System.Object[]` (any array) has its own real
  `Item[int]` indexer property, and PowerShell property lookup is case-insensitive, `.item` resolved
  to *that* — reflection metadata for the indexer itself — instead of member-enumerating each
  element's custom `item` key. The JSON reply came back with `OverloadDefinitions`/`MemberType`/
  `IsSettable` garbage where a plain string list should have been. **Confirmed via the exact
  mechanism**: the same property name on a `Hashtable` (not an array) works fine, because Hashtable
  has its own special ETS adapter mapping `.key` to `$hash['key']` that takes priority for
  Hashtables specifically — arrays have no such adapter, so they fall through to their real .NET
  members first. **Fix, and the standing rule: never name a custom object property `item` (or
  anything else that collides with a real member name — `length`, `count`) if code anywhere will
  read it back via dot-notation off an array of those objects.** Renamed to `name` throughout
  `New-StgTrackingScaffold` and `setup-dev-loop.ps1`.
- **`@($null)`'s one-element-array-of-null trap (documented above for `.PSObject.Properties.Name`)
  recurs through a second, easy-to-miss pathway: dot-notation property access on an EMPTY array also
  collapses to bare `$null`, not an empty array** — `$missing = @($report | Where-Object {...})`
  correctly gives a genuinely empty array when nothing matches (wrapping a *pipeline* in `@()`
  captures its real emitted-object count, zero included), but the very next line's
  `@($missing.name)` does not: member-enumeration on zero elements returns `$null` as a bare
  expression, and `@()` around an already-`$null` value can't tell "zero" from "one null" apart any
  more than it could for `.PSObject.Properties.Name` on an empty object. Caught live: an all-present
  `setup-dev-loop.ps1 check` on a fully-set-up project reported `"missing":[null]` instead of
  `"missing":[]`. **Fix: pipe through `ForEach-Object` instead of using dot-notation**
  (`@($missing | ForEach-Object { $_.name })`) — a pipeline's `@()`-wrap reflects the actual number
  of emitted objects (zero stays zero), where a scalar-`$null`'s `@()`-wrap never can. Same standing
  rule as the original trap, extended: it's not just `.PSObject.Properties.Name` that needs
  `Get-StgNames`-style care — *any* expression that can bottom out at a bare `$null` (property
  enumeration on an empty collection included) needs a pipeline form before `@()`-wrapping it, not
  direct member access.
- **`[Console]::Out.Write()` (this codebase's `-Json` output convention, used by every script with an
  `Out-Result` helper) bypasses ALL of PowerShell's own redirection when a script is invoked
  in-process** — `& $scriptPath.ps1 -Json`, `.\$scriptPath.ps1 -Json`, or dot-sourcing all run the
  script *within the current PowerShell session*, and `[Console]::Out` there is bound to the real,
  inherited OS console handle, not whatever stream PowerShell's own `|`, `>`, or `$x = ...` capture
  mechanisms redirect (those only capture the internal "success output" object stream — raw
  `Console` writes never touch it). The text still prints to the actual terminal (so it's easy to
  *see* and mistake for a successful capture), but `$x` ends up empty/`$null` and a file redirect
  (`> out.json`) writes a genuine **zero-byte** file — confirmed directly: `wc -c` on such a file
  showed 0 bytes even though the JSON had clearly printed to screen moments before. **This is not a
  codebase bug** — the real, production call path (`native-host\host.ps1`'s `Invoke-StoryScript`)
  always calls `& powershell.exe -File $script ...`, spawning a genuinely separate OS process, and
  `[Console]::Out` *there* correctly binds to whatever real stdout handle that child process
  inherited, which PowerShell's own external-process redirection sets up correctly (this is regular
  OS-level pipe/handle redirection, unlike the in-process scriptblock case). **The standing rule for
  testing any `-Json` script here directly** (not through the extension): invoke it the same way
  `Invoke-StoryScript` does — `& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
  -File <script> <args> -Json` — not a bare `& $path` or `.\path`, or `ConvertFrom-Json`/`$x =`
  against its output will silently look empty with no error to explain why.
