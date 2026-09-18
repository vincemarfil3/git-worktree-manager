# Worktree manager (Chrome extension)

Groups Chrome tabs by story. Each story gets one tab group holding all its URLs (Jira story, REL
ticket, AgileTest, GitHub Actions, …), plus git-worktree creation/removal for the story lifecycle.
Rules are built from your `stories.json` (auto-fetched through the native host — no manual sync
needed on a fresh install), so the story list stays in sync with your worktree registry.

**Standalone**: this folder is fully self-contained — all the PowerShell it needs lives in
[`tools/`](tools/), and `stories.json`/the worktrees it manages can live anywhere (configured, not
hardcoded). Copy this folder to any machine and run `setup.ps1` once.

## Install (one time)

1. `chrome://extensions` → toggle **Developer mode** (top-right).
2. **Load unpacked** → pick this folder (`story-tab-groups`).
3. Pin the extension to the toolbar.
4. Open a terminal in this folder and run:
   ```powershell
   .\setup.ps1
   ```
   This registers the native-messaging host, finds (or asks for) where your `stories.json` lives,
   and runs a preflight check. See [Worktree creation & removal](#worktree-creation--removal---one-time-native-host-setup)
   below for what it's doing and how to do it by hand instead.
5. **Fully restart the browser** (all windows) so it picks up the native host.

## Use

- **Popup** (toolbar icon):
  - *↗ Open all* — opens the selected story's Jira / REL / AgileTest / GH Actions tabs into the group at once.
  - *↪ Focus* (per row) — jump to that story's group (even in another window).
  - *Auto-route new tabs* — when on, any tab whose URL contains the story key, REL, or AgileTest id
    auto-joins the group. GitHub **Actions** URLs (per-run ids, not story-specific) route to the
    **Active story** you pick with **★ Set active**.
- **Right-click** any page or link → **Add to story group ▸ <story>** — this is how a tab joins a group manually.
- **➕ New story** — registers the `stories.json` node and cuts a git worktree per app: pick the
  key/env/branch/title and check off which repos (the checklist is collapsible with a search filter
  once there are a lot of them), hit **Check & create** for a read-only preview (which apps are
  cloned, new branch vs. an existing one), then confirm. Dependency install is skipped
  (`-NoInstall`) since it can take minutes and the button waits on one round trip — the result tells
  you the install command to run afterward. Requires the one-time native-host setup below.
- **📂 Open workspace** — (re-)writes the selected story's `.code-workspace` from its current
  worktrees and opens it in VS Code, any time — not just once at creation like the `-Open` checkbox.
- **🗑 Remove worktree** (per row) — tears down a finished story's local artifacts:
  `git worktree remove` each app under `<root>\<STORY>\<app>` (then the empty `<STORY>` folder),
  drop the `stories.json` node, and delete its `.code-workspace`. **Blocked automatically** (changes
  nothing) if any app has uncommitted (non-`.env`) changes or unpushed commits — the popup shows
  which one. Click 🗑 again on a blocked row and it arms a **type-CONFIRM** box instead of the
  usual quick confirm: typing the word `CONFIRM` and clicking **Delete** forces the removal through
  anyway, permanently discarding those uncommitted changes (unpushed **commits** are safe either
  way — the local branch is always kept). The always-modified local `.env` never blocks. Requires
  the one-time native-host setup below.

## Worktree creation & removal — one-time native-host setup

**+ New story**, **🗑**, and the ready/blocked badges all need a tiny local bridge (a Chrome
extension can't run scripts on its own) that runs the scripts in [`tools/`](tools/). `setup.ps1`
(above) does this for you; to do it by hand:

```
cd story-tab-groups\native-host
.\install-native-host.ps1        # auto-detects this extension's id; pass -ExtensionId <id> to override
```

Then fully restart the browser. See [native-host/README.md](native-host/README.md) for details.
Re-run the installer if you ever load the extension from a different folder path (its id changes).

**Where your stories actually live** (`stories.json`, per-story worktrees) is configured
separately from where the scripts live — Settings' **Worktree paths & branch format** card, or
`tools\stg-paths.psm1`'s `Set-StgConfig`. Nothing here assumes a folder named `Ganesha`; that's
just this project's own convention, fully overridable. The Settings page's **Paths &
diagnostics** card shows every resolved path and where each one came from.

Groups are matched by *title contains the story key*, so renaming a group in Chrome (e.g.
`PIII-12346 Internal UI`) keeps working — the extension reuses it instead of making a duplicate.
It also reaches across windows: adding to a group that lives in another window moves the tab there.

## Updating the story list

Nothing to do — once the native host is installed, the popup fetches `stories.json` through it and
builds the tab-grouping rules automatically on every cold start. No file picker, no
`rules.json` to regenerate, no reload needed after editing `stories.json` by hand or via the CLI
(the popup's ⟳ / Settings' **Load stories.json** just force an immediate refresh instead of
waiting for the next cold start).

If you'd rather load `stories.json` via the browser's file picker instead of through the native
host (e.g. testing without a host installed), Settings' **Sync from stories.json** card still
works exactly as before. `node gen-rules.mjs` also still exists, for a build-time
`rules.json` snapshot — the very last fallback, used only if the native host is unreachable.

## Notes / limits

- Tab groups are a Chrome-only concept — there is no command-line / URL way to target a group, which
  is why this is an extension.
- Works only while Chrome is focused; it cannot pull a URL in from a non-Chrome app (would need an
  OS-level hotkey like AutoHotkey — out of scope here).
- Color per story is deterministic from the key; recoloring a group by hand sticks (color is only set
  when the group is first created).
