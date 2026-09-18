# Native host — the bridge to tools\*.ps1

Lets the **Worktree manager** popup's **+ New story** form, 🗑 button, ready/blocked badges, and
Settings page actually touch git and `stories.json` on this machine. A Chrome extension is
sandboxed and can't run scripts, so it talks to a small local host over Chrome's **Native
Messaging** API; the host runs the scripts in the sibling `..\tools\` folder — `switch-story.ps1
new -Json` (create), the guardrailed `remove-worktree.ps1` (remove), and the rest of `tools\`.

```
popup + New story ✓  ──sendNativeMessage──▶  background.js  ──▶  host.bat → host.ps1
                                                                     └─▶ ..\tools\switch-story.ps1 new <KEY> <env> <apps> -Root <root> -Json
                                                                         (registry node + git worktree add -b per app)
popup 🗑              ──sendNativeMessage──▶  background.js  ──▶  host.bat → host.ps1
                                                                     └─▶ ..\tools\remove-worktree.ps1 -Story <KEY> -Root <root> -Json
                                                                         (git worktree remove + stories.json node + .code-workspace)
```

Scripts always resolve from `..\tools\` (a sibling of this folder — they travel **with the
extension**, never with the data root). `<root>` — where `stories.json` and the per-story
worktrees actually live — is resolved separately by `tools\stg-paths.psm1`'s `Resolve-StgPaths`
(parameter → `%LOCALAPPDATA%\story-tab-groups\stg-config.json` → `$env:STG_ROOT` → auto-detect —
config outranks the env var on purpose: `$env:STG_ROOT` is frozen in a long-lived process's own
environment block at ITS startup, so a browser left open across a `setup.ps1` run would otherwise
silently keep using a stale or absent value forever, overriding the correct, current config file
with no error). This split is what makes the extension folder relocatable: moving it never changes
where your stories live, and moving your story root never changes which scripts run.

Full action list `host.ps1` dispatches on: `ping`, `add`, `addcheck`, `addapps`, `addappscheck`,
`apps`, `openworkspace`, `remove`, `check`, `history`, `stories`, `ledgers`, `envstatus`,
`release`, `released`, `doctor`, `getConfig`, `setConfig`, `preflight`.

## Files

- `host.ps1` — reads one length-prefixed JSON message, dispatches to the right `tools\*.ps1` script
  (or, for `history`/`stories`/`ledgers`/`apps`, reads files directly), replies. Only the framed
  reply ever hits stdout; a child script's stderr, if any, rides along in the `raw` field of an
  error reply instead of vanishing.
- `host.bat` — launches `host.ps1` with `-NoProfile` (Chrome execs this).
- `com.storytabgroups.worktree.json` — **generated** by the installer (never checked in — see
  `.gitignore`); lists the allowed extension id(s) + the host path.
- `install-native-host.ps1` — writes the manifest + the
  `HKCU\...\NativeMessagingHosts\com.storytabgroups.worktree` registry key. Verifies `host.bat`
  exists before writing anything, and matches the extension by comparing a browser profile's
  recorded extension **path** against this script's own resolved parent folder — never a literal
  folder-name string, so renaming the extension folder can't break auto-detect.

## Install (one time)

From the **extension root** (one level up), the easiest path is the bootstrap script:

```powershell
cd ..
.\setup.ps1
```

Or run this installer directly:

```powershell
cd native-host
.\install-native-host.ps1            # auto-detects the unpacked extension id from Chrome/Edge/Brave
# or, if auto-detect can't find it:
.\install-native-host.ps1 -ExtensionId <id from chrome://extensions>
```

Then **fully restart the browser** (all windows) so it picks up the host.

> If you reload the unpacked extension from a *different folder path*, its id changes — re-run the
> installer (or `setup.ps1`).

## Configuring the data root

First run with no `stg-config.json` yet: every host action that needs a root replies
`{ ok:false, needsSetup:true, error:"..." }` rather than guessing. Set it once — via the Settings
page's **Worktree paths & branch format** card, `setup.ps1`, or directly:

```powershell
Import-Module ..\tools\stg-paths.psm1
Set-StgConfig -Config @{ root = 'C:\path\to\your\Ganesha' }
```

## Safety

`remove-worktree.ps1` **aborts and changes nothing** if any of the story's worktrees has
uncommitted (non-`.env`) changes or unpushed commits — the popup shows which app blocked it.
The always-modified local `.env` (dev pointing) never blocks. The local branch is kept
(removal uses no `-DeleteBranch`).

`switch-story.ps1 new -CheckOnly` (the popup's `addcheck` action) previews a creation — key/branch
validity, duplicate check, which apps are actually cloned, new-branch-vs-existing-branch per app —
**changing nothing**. The popup always runs this before the real `add`, and only arms its ✓ confirm
when it comes back clean.

## Test the host directly

The Settings page's **Paths & diagnostics** card does this for you (a `preflight` action), but to
check the wiring itself outside the browser:

```powershell
# framed "ping" -> expect a framed {"ok":true,"pong":true}. setup.ps1 runs exactly this as its
# step-1 end-to-end check.
$msg = '{"action":"ping"}'
$b = [Text.Encoding]::UTF8.GetBytes($msg)
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File host.ps1'
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
$p = [Diagnostics.Process]::Start($psi)
$p.StandardInput.BaseStream.Write([BitConverter]::GetBytes([int]$b.Length), 0, 4)
$p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
$lp = New-Object byte[] 4; $p.StandardOutput.BaseStream.Read($lp, 0, 4) | Out-Null
$len = [BitConverter]::ToInt32($lp, 0)
$buf = New-Object byte[] $len; $p.StandardOutput.BaseStream.Read($buf, 0, $len) | Out-Null
[Text.Encoding]::UTF8.GetString($buf)
```

In practice, just click the popup's 🗑 on a throwaway story — a clean reply (or a clear
"blocked"/"not installed" alert) confirms the wiring.
