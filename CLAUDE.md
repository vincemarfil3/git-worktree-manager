# Worktree manager — Chrome/Edge extension

A local, **standalone, self-contained MV3 browser extension** that does two jobs for the worktree
workflow. It is **not** part of any app repo — it's personal tooling that reads a `stories.json`
registry (the same file the `tools\switch-story.ps1` CLI manages). "Standalone" specifically means:
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
| `background.js` | Service worker. Tab→story matching, auto-route, context menu, and the `onMessage` switch the popup/options talk to (incl. **`removeWorktree`**, **`getHistory`**, **`checkWorktrees`**, **`getReleased`**, **`setReleased`**, **`addWorktree`**, **`checkAddWorktree`**, **`addApps`**, **`checkAddApps`**, **`getApps`**, **`setAppMap`**, **`openWorkspace`**, **`getStgConfig`**, **`setStgConfig`**, **`runPreflight`** → native host). One `NATIVE_HOST` constant (`com.storytabgroups.worktree`) everything sends to — not a literal repeated per call site. `getRules()` auto-builds the story list from the native host's `stories` action when no saved override exists yet (no file picker required on a fresh install) before falling back to the packaged `rules.json`. `importScripts('rules-core.js')` for the shared `buildRules()`. Logs a build marker `[stg-bg] service worker build: …`. |
| `popup.html` / `popup.js` | The toolbar popup UI. Renders the story list + action icons, per-row **ready/blocked badges** (from `checkWorktrees`), the **✔ released chip**, the **+ New story** creation form — its own full-panel view (`#addForm` replaces `#mainView` while open, not shown alongside the list — a long app checklist would flood the 328px popup otherwise), with a **collapsible, searchable app checklist** inside it (collapsed by default, showing a live "N apps selected" summary; a filter box narrows by app/repo name; an empty-state that surfaces the native host's *actual* error, not a generic "is X present?" guess — see the dev gotcha below) — the **inline two-step 🗑→✓/✕ confirm**, the **♻ discard-generated→✓/✕** flow, the **🚀 released→✓/✕ toggle**, **📂 Open workspace**, and an inline `#rmMsg` status line. Footer links to **History** + Settings. Logs `[stg] popup build: …`. |
| `history.html` / `history.js` | **Story history viewer** (opens in a tab from the popup footer). Reads `stories_history.json` via the native host (`getHistory`) and renders newest-first cards of removed stories — env/REL/CHG/date chips, clickable Jira/REL/AgileTest links, collapsible work-log. Jira base URL comes from `getStgConfig`, not a hardcoded org domain. Logs `[stg-hist] history build: …`. |
| `options.html` / `options.js` | Settings page — a **native host status card** (pings `com.storytabgroups.worktree` on load, shows ✓/✕, and when disconnected shows the exact `install-native-host.ps1 -ExtensionId <id>` fix command with a Copy button and a Recheck button — can't run the installer itself, see below), a **Paths & diagnostics card** (every resolved path + which rule decided it + a re-runnable preflight, via `runPreflight` → host `preflight`), "Load stories.json" (file-picker sync, now optional), **worktree paths & branch format** (Story root / worktree root / workspace dir / branch format, see below), **organization settings** (Jira base URL / GitHub org / EOD task name / owner / repo aliases — every org-specific literal, configurable), an **Apps card** (add/edit/remove each app's port/start/health, hide/unhide from the +New story checklist — see [Settings: Apps](#settings-apps)), + advanced rules.json paste/override. Logs `[stg-opt] options build: …`. |
| `rules-core.js` | `globalThis.RBCore` — the actual `buildRules()` implementation and its helpers (color hash, label, Jira/AgileTest id regexes, repo aliasing), loaded by `background.js` via `importScripts()` and by `rules-lib.js`/`gen-rules.mjs` for the popup/options pages and the Node CLI. **One implementation, three consumers** — this is what retired the old "must stay mirror images" duplicated-copy comment. |
| `rules-lib.js` | `window.RB`: thin wrapper over `RBCore.buildRules`, remembers the file handle (IndexedDB), `sync()` (picker) / `syncSilently()` (no dialog, popup-safe). |
| `gen-rules.mjs` | Node CLI alternative: regenerates `rules.json` from `../stories.json`, loading `rules-core.js` via `node:vm` (it's a plain browser/SW script, not an ES module). |
| `rules.json` | Packaged fallback rule set (generated, ships empty). Consulted only when there's no saved `rulesOverride` **and** the native host is unreachable — the last-resort fallback, not the primary path anymore. |
| `native-host/` | The bridge to `tools\*.ps1` — see below. |
| `tools/` | **Every PowerShell script this extension needs, in one folder** — see [Standalone / portability](#standalone--portability). |
| `setup.ps1` | One-command bootstrap: installs + verifies the native host end-to-end, finds/asks for the data root, publishes `STG_ROOT`/`STG_TOOLS` env vars, runs a preflight, and (given `-OldExtensionDir`) migrates a prior non-standalone install. `-WhatIf` previews every change without touching anything. |

## Data flow (stories.json → groups)

`stories.json` (wherever `Resolve-StgPaths` resolves the root to) → the native host's `stories`
action → `RBCore.buildRules()` (`rules-core.js`, shared by `background.js`, `rules-lib.js` and
`gen-rules.mjs`) → per story: `{ key, title:"<KEY> <label>", color (hashed from key),
match:[key, REL, AgileTest issue id, …], repos (apps, `iu`→`ui` quirk, now a configurable alias
map), links (Jira/GitHub URLs built from the configured `jiraBaseUrl`/`githubOrg`) }`. Matching is
**title-contains-key**, so renaming a tab group by hand keeps working. This happens automatically
on cold start — no manual refresh needed. After editing `stories.json` by hand, force an immediate
refresh via the popup's **⟳ Load stories.json** (or options page, or `node gen-rules.mjs` for a
build-time snapshot).

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
- `native-host/` files: `host.ps1` (framed stdin/stdout JSON; actions: `ping` / `remove` / `check` / `history` / `stories` / `ledgers` / `envstatus` / `release` / `released` / `doctor` / `add` / `addcheck` / `addapps` / `addappscheck` / `apps` / `setappmap` / `openworkspace` / `getConfig` / `setConfig` / `preflight`; every script action resolves from `tools\` via one `$ScriptsDir`, so `remove`/`check` can no longer silently run a *different* copy than every other action — the old asymmetry that caused the "returned no JSON" debugging trap), `host.bat` (launcher),
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
              add -b <branch> ... origin/main, or check out <branch> if it already exists → seed
              .env from home base → init the ledger → optionally write + open the .code-workspace)
```

- **Repo discovery** is the `apps` action: it scans `<GRoot>\*` for a **`.git` directory** (a home
  base clone) vs a **`.git` file** (a worktree) vs **neither** (a story folder) — the *configured*
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
  (`<worktreeRoot>\<STORY>\<app>`) move; home-base clones (`<Root>\<app>`, the ones you `git fetch`
  from) always stay under Root. This is the "my worktrees are bloating my main drive" case.
- **Workspace dir** — where `.code-workspace` files are written. Defaults to
  `<parent of Root>\<Root's folder name>_WorkSpaces` (so a root named `Ganesha` still gets
  `Ganesha_WorkSpaces`, unchanged from before this was configurable) — override it directly if you
  want it somewhere else entirely.
- **Organization settings** (Jira base URL, GitHub org, EOD task name prefix, owner, repo
  aliases) — every literal that used to be a hardcoded org-specific string (`vesta.atlassian.net`,
  `vesta-experimental`, `Ganesha EOD status reminder`, the `iu`→`ui` repo alias, `Vince Marfil`) is
  now one of these fields, defaulting to exactly that original value.

**Storage**: `%LOCALAPPDATA%\story-tab-groups\stg-config.json` (`{ root, worktreeRoot,
workspaceRoot, branchFormat, jiraBaseUrl, githubOrg, repoAliases, taskNamePrefix, owner,
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
- **Storage**: always the **`%LOCALAPPDATA%\story-tab-groups\app-map.json`** copy — never the
  shipped `tools\app-map.json` — mirroring why `stg-config.json` itself lives outside the extension
  folder. `tools\stg-paths.psm1`'s `Get-StgAppMapPath` resolves the `%LOCALAPPDATA%` copy first and
  falls back to the `tools\` template only when no user copy exists yet, so an untouched install
  behaves exactly as before this existed. The first Settings save seeds forward whatever
  `pythonSentinel` the currently-effective file has, so it isn't silently reset to `story-env.ps1`'s
  own `'fastapi'` default.
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
  backfills the prep-release phases from node fields that already prove they happened (`rel`,
  `releaseBranch`, `chg_number`, `agiletest_urls`) - that is what stops a shipped story showing a
  half-empty checklist forever. Both directions are **idempotent**.
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
  (the de-hardcoded org literals below), `Get-StgAppMapPath` (the app map — `%LOCALAPPDATA%` copy
  first, `tools\app-map.json` fallback; see [Settings: Apps](#settings-apps)), and `Get-StgNames`
  (a JSON object's property names as a real array, never the `@($null)` one-element-array-of-null
  trap — see the dev gotcha below).
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

- **MV3 service worker goes stale on `⟳` reload.** Editing `background.js` and clicking the card's
  ⟳ often keeps the *old* worker warm — symptom: the popup is new but messages fall through to the
  `default:` case (e.g. a remove returns `error:"unknown"`). **Fix: toggle the extension Off then
  On** (forces a fresh worker, keeps the id). Confirm via the **"service worker"** link → console →
  `[stg-bg] service worker build: …`.
- **No `confirm()` / `alert()` in the popup.** Opening a native dialog blurs the popup, which Chrome
  auto-closes → the call returns/!does nothing. That's why removal uses an **inline** confirm + the
  `#rmMsg` status line. Keep it that way.
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
  sites that *index* with the loop variable need the fix.
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
