#requires -Version 5.1
<#
  story-handover.ps1 - move a story's worktree FOLDERS from one story key to another.

  Why this exists: work sometimes gets built in the wrong story's worktree (a ticket is retitled,
  split, superseded, or you simply took over a folder whose ticket was already released). The git
  and registry halves of that handover are judgement calls, but the FOLDER half is completely
  mechanical - and it is the half that reliably goes wrong, because VS Code and any running dev
  server hold the directories open, so 'git worktree move' fails with Permission denied.

  That failure used to produce a hand-written one-off script per handover, plus a debugging session
  to work out what was holding the lock. This script is that one-off, generalised.

  It owns ONLY the folder move. Do the git + registry half first (see the ganesha-worktree skill):
  the NEW story must already exist in stories.json with its apps, and its branch must already exist.

  Usage:
    story-handover.ps1 -From <OLD> -To <NEW> [-AddToHistory $true] [-CheckOnly] [-Json]

    -CheckOnly      report what would move and exactly what is holding each folder. Changes nothing.
    -AddToHistory   $true  = archive the OLD story's stories.json node into stories_history.json and
                             drop it, so the retired key shows up in the extension's History viewer.
                    $false = leave the old node alone (DEFAULT). Correct when the old story was
                             already archived by remove-worktree.ps1, or when it stays live.
                    Never archives a node that does not exist, and never archives on a failed move.

  Safe to re-run: every step is skipped when already done. Always exits 0; read the 'ok' field.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$From,
  [Parameter(Mandatory)] [string]$To,
  # A [bool] rather than a switch so the intent is explicit at the call site: -AddToHistory $true.
  [bool]$AddToHistory = $false,
  [switch]$CheckOnly,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  [Parameter(ValueFromRemainingArguments = $true)] $Extra
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root
if ($Paths.NeedsSetup) {
  if ($Json) { [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress)) }
  else { Write-Host $Paths.Error -ForegroundColor Red }
  exit 0
}
$Root       = $Paths.Root
$LedgerName = '.story-ship-state.json'
$WsDir      = $Paths.WorkspaceDir
# Files a retired story folder may keep and still count as empty: both are archived into
# stories_history.json by remove-worktree.ps1 before the node is dropped.
$Disposable = @($LedgerName, 'MANUAL-TEST.md')

Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

$result = [ordered]@{ ok = $true; from = $From; to = $To; checkOnly = [bool]$CheckOnly
  apps = @(); moved = @(); locked = @(); holders = @(); steps = @(); archived = $null
  warning = $null; summary = '' }

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)); return }
  if ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red; return }
  Write-Host ""
  foreach ($s in $o.steps) { Write-Host "  $s" }
  if (@($o.holders).Count) {
    Write-Host ""
    Write-Host "  Holding the folders open:" -ForegroundColor Yellow
    foreach ($h in $o.holders) { Write-Host "    $h" -ForegroundColor Yellow }
  }
  if ($o.warning) { Write-Host "`n  $($o.warning)" -ForegroundColor Yellow }
  Write-Host ""
  Write-Host "  $($o.summary)" -ForegroundColor $(if ($o.ok) { 'Green' } else { 'Red' })
  Write-Host ""
}

# What is actually holding a directory? A rename fails with a bare "used by another process" and
# names nothing, which is the whole reason the first handover cost a debugging session. Command
# lines catch dev servers; window titles catch the VS Code window, whose cmdline does not carry the
# path. Best-effort: an empty list does not prove the folder is free, so the rename probe still rules.
function Get-Holders([string]$Path) {
  $out = @()
  try {
    $me = $PID
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
      if ($p.ProcessId -eq $me) { continue }
      # Tool processes match only because the path appears in their own command line.
      if ($p.Name -in @('bash.exe', 'conhost.exe', 'powershell.exe', 'pwsh.exe', 'WmiPrvSE.exe', 'claude.exe', 'node.exe.tmp')) { continue }
      if ($p.CommandLine -and $p.CommandLine -like "*$Path*") {
        $out += "pid $($p.ProcessId) $($p.Name)"
      }
    }
  }
  catch {}
  # Match window titles on the STORY key only, never the app name: an editor window titled
  # "PIII-10877 - .env" is a real holder, but a browser tab titled "... ganesha-ui-app-v2 ..." is
  # not, and matching the app leaf reported every open GitHub tab as a lock.
  $story = Split-Path (Split-Path $Path -Parent) -Leaf
  try {
    foreach ($w in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle })) {
      if ($w.ProcessName -in @('chrome', 'msedge', 'firefox', 'brave')) { continue }
      if ($w.MainWindowTitle -like "*$story*") {
        $entry = "pid $($w.Id) $($w.ProcessName) [window: $($w.MainWindowTitle)]"
        if ($out -notcontains $entry) { $out += $entry }
      }
    }
  }
  catch {}
  return @($out | Select-Object -Unique)
}

# Append the retired story's whole node to stories_history.json, matching the shape
# remove-worktree.ps1's Archive-Story writes: { removed: [ { key, removed_at, apps, removal, node } ] }.
# Best-effort by design - the folders have already moved by the time this runs, so a failed write
# must never fail the handover.
function Add-HistoryRecord([string]$Key, $Node, [string[]]$Apps, [string]$Why) {
  try {
    $path = Get-HistoryPath -Root $Root
    $hist = $null
    if (Test-Path -LiteralPath $path) { $hist = Read-JsonFile -Path $path }
    if (-not $hist) { $hist = [pscustomobject]@{ removed = @() } }
    if (@($hist.PSObject.Properties.Name) -notcontains 'removed') {
      $hist | Add-Member -NotePropertyName 'removed' -NotePropertyValue @() -Force
    }
    $entry = [pscustomobject]@{
      key = $Key; removed_at = (Get-Stamp); apps = @($Apps)
      removal = @(@($Apps) | ForEach-Object { [pscustomobject]@{ app = $_; status = $Why } })
      node = $Node
    }
    # ConvertTo-Json collapses a one-entry array to a bare object - wrap on write as well as read.
    $hist.removed = @(@($hist.removed) + $entry)
    Write-JsonFile -Path $path -Obj $hist -Depth 20
    return 'archived'
  }
  catch { return "archive-failed: $($_.Exception.Message)" }
}

# The only reliable free/locked test on Windows is to try the rename the move itself will do.
function Test-FolderFree([string]$Path) {
  $leaf = Split-Path $Path -Leaf
  $parent = Split-Path $Path -Parent
  $probe = "$leaf.handover-probe"
  try {
    Rename-Item -LiteralPath $Path -NewName $probe -ErrorAction Stop
    Rename-Item -LiteralPath (Join-Path $parent $probe) -NewName $leaf -ErrorAction Stop
    return $true
  }
  catch { return $false }
}

try {
  if ($Extra) { throw ("unexpected extra argument(s): " + (@($Extra) -join ' ')) }
  if (-not (Test-StoryKey $From)) { throw "'$From' is not a valid story key" }
  if (-not (Test-StoryKey $To)) { throw "'$To' is not a valid story key" }
  if ($From -eq $To) { throw "-From and -To are the same story" }

  $fromDir = Join-Path $Root $From
  $toDir   = Join-Path $Root $To

  # Running from inside either tree would self-lock the rename.
  $cwd = (Get-Location).Path
  if ($cwd -like "$fromDir*" -or $cwd -like "$toDir*") {
    throw "current directory is inside $From or $To - cd out of the story folders first (this would self-lock the move)"
  }

  $reg = Read-Registry -Root $Root
  $toKey = Resolve-RegistryKey -Registry $reg -Key $To
  if (-not $toKey) { throw "'$To' is not in stories.json - do the registry half of the handover first (see the ganesha-worktree skill)" }
  $node = $reg.stories.$toKey

  # The NEW node's app list is the source of truth for what should move.
  $apps = @(@($node.apps) | Where-Object { $_ })
  if (-not $apps.Count) { throw "'$To' declares no apps in stories.json" }
  $result.apps = $apps

  if (-not (Test-Path -LiteralPath $fromDir)) {
    $result.summary = "$From folder is already gone - nothing to move"
    Out-Result $result; return
  }

  # ---- 1. probe every folder before touching anything -------------------------------------------
  $pending = @()
  foreach ($a in $apps) {
    $src = Join-Path $fromDir $a
    $dst = Join-Path $toDir $a
    if (Test-Path -LiteralPath $dst) { $result.steps += "$a : already at $To"; continue }
    if (-not (Test-Path -LiteralPath $src)) { $result.steps += "$a : not under $From (nothing to move)"; continue }
    if (Test-FolderFree $src) { $result.steps += "$a : free"; $pending += $a }
    else {
      $result.steps += "$a : LOCKED"
      $result.locked += $a
      $result.holders += (Get-Holders $src)
    }
  }
  $result.holders = @(@($result.holders) | Select-Object -Unique)

  if (@($result.locked).Count) {
    $result.ok = $false
    $result.summary = "ABORT: $(@($result.locked).Count) folder(s) locked. Close the listed windows / stop the listed processes, then re-run."
    if (-not @($result.holders).Count) {
      $result.warning = "Could not identify the holder. Usual suspects: the VS Code window for $From, a dev server started from inside it, or a terminal sitting in the folder."
    }
    Out-Result $result; return
  }

  if ($CheckOnly) {
    $result.summary = if ($pending.Count) { "ready to move: $($pending -join ', ')" } else { "nothing left to move" }
    Out-Result $result; return
  }

  # ---- 2. move each worktree --------------------------------------------------------------------
  # git rewrites its own gitdir pointers; .env, node_modules and .venv ride along. Run the command
  # from the home-base clone, which is never inside either story folder.
  if ($pending.Count) { New-Item -ItemType Directory -Force -Path $toDir | Out-Null }
  foreach ($a in $pending) {
    $src = Join-Path $fromDir $a
    $dst = Join-Path $toDir $a
    # NOT $home - that's PowerShell's own read-only automatic variable (user profile dir);
    # assigning to it throws "Cannot overwrite variable HOME".
    $homeDir = Join-Path $Root $a
    if (-not (Test-GitWorktree -Dir $homeDir)) { throw "home base clone not found at $homeDir - cannot run 'git worktree move'" }
    $r = Invoke-GitCap -Dir $homeDir -GitArgs @('worktree', 'move', $src, $dst)
    if ($r.code -ne 0) { throw "worktree move failed for ${a}: $($r.out)" }
    $result.moved += $a
    $result.steps += "$a : moved -> $To\$a"
  }

  # ---- 3. HARD RULE - every worktree ends on its feature branch ---------------------------------
  $branch = if ($node.branch) { [string]$node.branch } else { "feature/$($node.env)/$toKey" }
  foreach ($a in $apps) {
    $wt = Join-Path $toDir $a
    if (-not (Test-GitWorktree -Dir $wt)) { continue }
    $cur = (Invoke-GitCap -Dir $wt -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).out
    if ($cur -ne $branch) {
      [void](Invoke-GitCap -Dir $wt -GitArgs @('checkout', $branch))
      $cur = (Invoke-GitCap -Dir $wt -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).out
    }
    $result.steps += "$a : on $cur"
    if ($cur -ne $branch) { $result.warning = "$a is on '$cur', expected '$branch'" }
  }

  # ---- 4. optionally retire the OLD registry node ------------------------------------------------
  # Only after the move actually succeeded: a node dropped on a failed handover would leave the
  # worktrees orphaned with nothing in the registry pointing at them.
  $fromKey = Resolve-RegistryKey -Registry $reg -Key $From
  if ($AddToHistory) {
    if (-not $fromKey) {
      $result.archived = 'skipped: no stories.json node for ' + $From + ' (already retired)'
    }
    else {
      $oldNode = $reg.stories.$fromKey
      $result.archived = Add-HistoryRecord $fromKey $oldNode $apps "handed over to $toKey"
      if ($result.archived -eq 'archived') {
        $fk = $fromKey
        Invoke-RegistryUpdate -Root $Root -Mutate {
          param($r)
          if (@($r.stories.PSObject.Properties.Name) -contains $fk) { $r.stories.PSObject.Properties.Remove($fk); return $true }
          return $false
        } | Out-Null
        $result.steps += "$From : node archived to stories_history.json and dropped"
      }
      else { $result.warning = "history write failed, node left in place: $($result.archived)" }
    }
  }
  elseif ($fromKey) {
    $result.steps += "$From : node left in stories.json (pass -AddToHistory `$true to archive and drop it)"
  }

  # ---- 5. retire the old folder, but never delete anything unexpected ---------------------------
  if (Test-Path -LiteralPath $fromDir) {
    $left = @(Get-ChildItem -LiteralPath $fromDir -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notin $Disposable })
    if ($left.Count) {
      $result.warning = "NOT deleting $From : unexpected leftover content ($(@($left | ForEach-Object { $_.Name }) -join ', ')). Review it, then remove the folder by hand."
    }
    else {
      Remove-Item -LiteralPath $fromDir -Recurse -Force
      $result.steps += "$From folder deleted (only archived files remained)"
    }
  }

  # ---- 6. the old workspace file points at paths that no longer exist ---------------------------
  $oldWs = Join-Path $WsDir "$From.code-workspace"
  if (Test-Path -LiteralPath $oldWs) {
    Remove-Item -LiteralPath $oldWs -Force
    $result.steps += "removed $From.code-workspace"
  }

  $result.summary = if (@($result.moved).Count) {
    "handover complete: $(@($result.moved) -join ', ') now at $Root\$To. Reopen $WsDir\$To.code-workspace, then: tools\story-env.ps1 up"
  }
  else { "nothing to move - $From to $To was already done" }
  Out-Result $result
}
catch {
  $result.ok = $false
  $result.error = "story-handover error: $($_.Exception.Message)"
  Out-Result $result
}
