<#
  remove-worktree.ps1 - guardrailed teardown of a finished story's local artifacts.
  Implements the core-memory "remove worktree" flow with the guardrail baked in:
    1. git worktree remove each app under <root>\<STORY>\<app> (+ deregister)
    2. archive the node AND the story folder's artifacts (ledger, MANUAL-TEST.md) to
       stories_history.json, then drop the <STORY> node from stories.json
    3. delete the <STORY> folder itself - artifacts and all. It is never empty (the ledger and test
       plan live there on purpose, outside every repo), which is why the old empty-only check never
       fired and left a shell behind for every shipped story. Unrecognized content keeps the folder.
    4. delete Ganesha_WorkSpaces\<STORY>.code-workspace
  ABORTS (changes nothing) if any worktree has real uncommitted changes or unpushed commits -
  unless -Force is given, which the popup's 🗑 now sends once you type "CONFIRM" on a blocked
  story (uncommitted changes are then discarded permanently; unpushed COMMITS stay safe, since
  the branch is kept regardless - see -DeleteBranch below).
  Local dev-run artifacts (.env / logging.ini, at any depth - see $LocalArtifacts) never block
  and are never touched; we force only past those. Branch is KEPT unless -DeleteBranch.
  -Json => machine result on stdout
  (used by the Worktree manager native-messaging host); else a colored summary.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Story,
  [switch]$DeleteBranch,
  [switch]$Force,     # skip the dirty/unpushed guardrail - the popup's 🗑 uses this once a blocked
                      # story's typed "CONFIRM" gate passes; git-level removal is always --force
                      # regardless (see the 'worktree remove --force' call below), so this switch
                      # only controls whether THIS script's own pre-check aborts beforehand
  [switch]$CheckOnly, # report blockers + what would be removed, change nothing
  [switch]$CheckAll,  # read-only: blocker status for EVERY story in stories.json (no $Story needed)
  [switch]$DiscardGenerated, # discard allow-listed generated files (lockfiles / routeTree.gen.ts) before the guardrail
  [switch]$Json,
  [string]$Root  # override for $PSScriptRoot (native-host\host.ps1's Settings-driven root); blank = today's behavior
)

$ErrorActionPreference = 'Stop'

# Terminal output: in -Json mode write ONLY the compact JSON to stdout (so the native host
# gets a clean frame); else a human summary via Write-Host. Defined before root resolution so an
# unresolved root can report through the same clean path as every other error below.
function Emit($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)); return }
  if ($o.error) { Write-Host "`n  ERROR: $($o.error)`n" -ForegroundColor Red; return }
  if ($o.checkAll) {
    Write-Host "`n  Worktree status:" -ForegroundColor Cyan
    foreach ($e in $o.stories.GetEnumerator()) {
      if ($e.Value.ok) { Write-Host ("    [{0}] ready" -f $e.Key) -ForegroundColor Green }
      else { Write-Host ("    [{0}] blocked: {1}" -f $e.Key, (($e.Value.blockers | ForEach-Object { $_.app }) -join ', ')) -ForegroundColor Yellow }
    }
    Write-Host ""
    return
  }
  if ($o.aborted) {
    Write-Host "`n  NOT REMOVED - $Story still has work:`n" -ForegroundColor Yellow
    foreach ($b in $o.blockers) {
      $bits = @()
      if ($b.dirty.Count) { $bits += "$($b.dirty.Count) changed file(s): $($b.dirty -join ', ')" }
      if ($b.unpushed)    { $bits += "$($b.unpushed) unpushed commit(s)" }
      if ($b.noUpstream)  { $bits += "not pushed (no upstream)" }
      Write-Host ("    [{0}] {1}" -f $b.app, ($bits -join '; ')) -ForegroundColor Yellow
    }
    Write-Host "`n  Commit/push or clean up, then retry.`n" -ForegroundColor DarkGray
    return
  }
  Write-Host "`n  Removed worktrees for $Story" -ForegroundColor Cyan
  foreach ($r in $o.removed) {
    $c = switch ($r.status) { 'removed' { 'Green' } 'already-absent' { 'DarkGray' } default { 'Red' } }
    Write-Host ("    [{0}] {1}{2}" -f $r.app, $r.status, $(if ($r.error) { " - $($r.error)" } else { '' })) -ForegroundColor $c
  }
  Write-Host ("    stories.json node: {0}" -f $o.node) -ForegroundColor DarkGray
  Write-Host ("    history archive:   {0}" -f $o.archived) -ForegroundColor DarkGray
  Write-Host ("    story folder:      {0}" -f $o.folder) -ForegroundColor $(if ("$($o.folder)" -like 'kept*') { 'Yellow' } else { 'DarkGray' })
  if ($o.extras -and @($o.extras).Count) {
    Write-Host ("    non-app folders:   {0} (never treated as worktrees)" -f ((@($o.extras)) -join ', ')) -ForegroundColor DarkGray
  }
  if ($o.discarded -and @($o.discarded).Count) {
    Write-Host ("    discarded:         {0}" -f ((@($o.discarded) | ForEach-Object { "$($_.app): $($_.files -join ', ')" }) -join ' | ')) -ForegroundColor DarkGray
  }
  Write-Host ("    .code-workspace:   {0}" -f $o.workspace) -ForegroundColor DarkGray
  if ($o.branchDeleted) { Write-Host "    local branch: deleted" -ForegroundColor Yellow }
  Write-Host ""
}

# Root resolution: shared with switch-story.ps1 and native-host\host.ps1 - see stg-paths.psm1 for
# the full precedence order. This script no longer assumes it physically sits at the data root
# ($PSScriptRoot is now tools\, alongside every other script).
Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root
if ($Paths.NeedsSetup) {
  Emit @{ ok = $false; error = $Paths.Error; needsSetup = $true }
  exit 0
}
$Root = $Paths.Root
$RegistryPath = $Paths.StoriesPath
$WorkspaceDir = $Paths.WorkspaceDir

# Shared helpers (BOM-less writers, registry lock, git capture, story-key shapes, folder discovery).
# Deliberately NOT imported here at top level: unlike switch-story.ps1 (which has local fallbacks
# for most of what StoryLib provides and only loses the registry lock if it's missing), this script
# has no fallback for Get-StoryFolders/Test-StoryKey/etc. - a missing module is fatal either way, so
# the import happens inside the try block below instead, where the existing catch already turns any
# failure into one clean JSON error instead of a raw, empty-stdout PowerShell crash (confirmed: with
# the import at top level, a missing module produced NOTHING on stdout - host.ps1 could only report
# "returned no JSON" with no clue what was actually wrong).
$StoryLibModule = Join-Path $PSScriptRoot 'StoryLib.psm1'

# git that never throws on stderr; returns @{ code; out }. Thin shim over the shared helper.
function Git-Cap([string]$Dir, [string[]]$GitArgs) { Invoke-GitCap -Dir $Dir -GitArgs $GitArgs }

# What (if anything) blocks removal: real dirt (excluding $LocalArtifacts), unpushed, no upstream.
function Get-Blockers([string]$wt) {
  # A stale/empty folder that isn't a live git worktree has nothing to protect - never block on it
  # (otherwise 'git rev-parse @{u}' fails -> a phantom "not pushed (no upstream)" that can never clear).
  $isWt = Git-Cap $wt @('rev-parse', '--is-inside-work-tree')
  if ($isWt.code -ne 0 -or $isWt.out -ne 'true') {
    return [pscustomobject]@{ dirty = @(); unpushed = 0; noUpstream = $false; orphan = $true }
  }
  $dirty = @()
  # Capture porcelain lines WITHOUT trimming the blob - the leading status space is column-significant.
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $lines = @(& git -C $wt status --porcelain 2>$null)
  $ErrorActionPreference = $prev
  foreach ($line in $lines) {
    if (-not $line -or $line.Length -le 3) { continue }
    $p = $line.Substring(3).Trim().Trim('"')
    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1].Trim().Trim('"') }
    # local dev-run artifacts (.env / logging.ini at ANY depth) - expected, never block
    if (Test-LocalArtifact $p) { continue }
    $dirty += $p
  }
  $noUp = $false; $unpushed = 0
  $up = Git-Cap $wt @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
  if ($up.code -ne 0 -or -not $up.out) { $noUp = $true }
  else {
    $c = Git-Cap $wt @('rev-list', '--count', '@{u}..HEAD')
    if ($c.code -eq 0 -and $c.out) { $unpushed = [int]$c.out }
  }
  [pscustomobject]@{ dirty = @($dirty); unpushed = $unpushed; noUpstream = $noUp; orphan = $false }
}

function Add-OrSet($obj, [string]$name, $value) {
  if ($null -eq $value) { return }
  if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
  else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

# Append the full story node to stories_history.json, PLUS the story folder's local artifacts (the
# ledger and MANUAL-TEST.md). Those live in <root>\<STORY> deliberately outside every repo, so they
# are about to be deleted with the folder - and the ledger is the only record of the phase history.
# Best-effort: never throws, never blocks removal (worktrees are already gone when this runs).
function Archive-Story([string]$story, $node, $removed, [string]$storyDir) {
  try {
    $HistoryPath = Get-HistoryPath -Root $Root
    $hist = Read-JsonFile -Path $HistoryPath
    # PS collapses a single-element array to a bare object on round-trip - normalize to an array.
    $items = @(); if ($hist -and $hist.removed) { $items = @($hist.removed) }

    $ledger = $null; $manual = $null
    if ($storyDir -and (Test-Path -LiteralPath $storyDir)) {
      $lp = Join-Path $storyDir '.story-ship-state.json'
      if (Test-Path -LiteralPath $lp) { try { $ledger = Read-JsonFile -Path $lp } catch { $ledger = 'unreadable' } }
      $mp = Join-Path $storyDir 'MANUAL-TEST.md'
      if (Test-Path -LiteralPath $mp) {
        try {
          $t = [IO.File]::ReadAllText($mp)
          # Native messaging caps the host->extension reply at ~1MB; keep one plan well under it.
          $manual = if ($t.Length -gt 200000) { $t.Substring(0, 200000) + "`n...[truncated]" } else { $t }
        } catch { $manual = 'unreadable' }
      }
    }

    # A record for this key can already exist (an earlier partial removal dropped the node but left
    # the folder). Attach to it instead of writing a second record for the same story.
    $existing = @($items | Where-Object { "$($_.key)" -eq $story } | Select-Object -Last 1)[0]
    if ($existing -and -not $node) {
      Add-OrSet $existing 'ledger' $ledger
      Add-OrSet $existing 'manual_test' $manual
      Add-OrSet $existing 'folder_cleaned_at' (Get-Stamp)
      Write-JsonFile -Path $HistoryPath -Obj ([pscustomobject]@{ removed = @($items) }) -Depth 25
      return 'archived (attached to existing record)'
    }

    $items += [pscustomobject]@{
      key         = $story
      removed_at  = (Get-Stamp)
      apps        = @($node.apps)
      removal     = @($removed)
      node        = $node
      ledger      = $ledger
      manual_test = $manual
    }
    Write-JsonFile -Path $HistoryPath -Obj ([pscustomobject]@{ removed = @($items) }) -Depth 25
    return 'archived'
  }
  catch { return ('archive-failed: ' + $_.Exception.Message) }
}

# --- two categories, deliberately distinct ------------------------------------------------
# EXEMPT: local dev-run artifacts. Never block removal, and are NEVER touched or deleted.
# Matched on the LEAF at any depth: every app but one keeps .env at the repo root, but
# bartleby runs 'uvicorn main.main:app' from src/, so it needs src/.env + src/logging.ini
# there. The old exact-match on '.env' is why bartleby could never be removed.
$LocalArtifacts = @('.env', 'logging.ini')
function Test-LocalArtifact([string]$path) {
  $p = ($path -replace '\\', '/')
  return ($LocalArtifacts -contains ($p -split '/')[-1])
}

# DISCARDABLE: known-generated files that are ALWAYS safe to discard (never real work).
# These still BLOCK removal, but the popup's ♻ button can clear them first. Keep in sync with
# isGeneratedFile() in popup.js - both sides gate ♻ on the same allow-list.
# Note __pycache__/*.pyc are TRACKED in bartleby (committed bytecode), so .gitignore cannot
# help; Discard-Generated restores them from HEAD rather than deleting.
$GeneratedAllow = @('yarn.lock', 'package-lock.json')
function Test-Generated([string]$path) {
  # Normalize first: git emits forward slashes, and the __pycache__ pattern has a dir component.
  $p = ($path -replace '\\', '/')
  if ($GeneratedAllow -contains ($p -split '/')[-1]) { return $true }
  if ($p -match 'routeTree\.gen\.ts$') { return $true }
  if ($p -match '(^|/)__pycache__/') { return $true }
  if ($p -match '\.py[cod]$') { return $true }
  return $false
}

# Discard ONLY allow-listed generated files in a worktree (restore tracked from HEAD, delete
# untracked). Returns the paths actually discarded. Never touches .env or any non-generated file.
function Discard-Generated([string]$wt) {
  $discarded = @()
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $lines = @(& git -C $wt status --porcelain 2>$null)
  $ErrorActionPreference = $prev
  foreach ($line in $lines) {
    if (-not $line -or $line.Length -le 3) { continue }
    $code = $line.Substring(0, 2)
    $p = $line.Substring(3).Trim().Trim('"')
    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1].Trim().Trim('"') }
    # never touch an exempt artifact, even though it also never blocks
    if (Test-LocalArtifact $p) { continue }
    if (-not (Test-Generated $p)) { continue }
    if ($code -eq '??') {
      $full = Join-Path $wt $p
      try { if (Test-Path $full) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }; $discarded += $p } catch {}
    }
    else {
      $r = Git-Cap $wt @('checkout', 'HEAD', '--', $p)
      if ($r.code -eq 0) { $discarded += $p }
    }
  }
  return @($discarded)
}

# DELETABLE story-folder artifacts. The story folder holds state written OUTSIDE every repo on
# purpose (the ledger, MANUAL-TEST.md, a logs\ dir), which is exactly why "delete only if empty"
# never fired and every shipped story left a shell behind. These are archived, then removed with
# the folder; anything ELSE keeps the folder alive and is reported, never deleted.
function Test-StoryFolderArtifact($item) {
  if ($item.PSIsContainer) { return ($item.Name -eq 'logs') }
  if ($item.Name -eq '.story-ship-state.json') { return $true }
  if ($item.Extension -eq '.md') { return $true }
  if ($item.Extension -eq '.log') { return $true }
  return $false
}

# Read-only blocker status for ONE story (used by -CheckAll). Mirrors the single-story discovery
# + blocker logic in the main flow, removing nothing.
function Get-StoryStatus([string]$story, $node) {
  $fldrs = (Get-StoryFolders -Root $Root -Story $story -Node $node).apps
  # See the identical override in the main removal flow below - a story created with a custom
  # worktree root (switch-story.ps1 -WorktreeRoot) needs its per-app paths patched here too, or the
  # popup's ready/blocked badge (-CheckAll, which calls this) would look for it in the wrong place.
  if ($node -and $node.worktreeRoot) {
    $wtRoot = $node.worktreeRoot
    $fldrs = @{}
    foreach ($app in @($node.apps)) { $fldrs[$app] = Join-Path (Join-Path $wtRoot $story) $app }
  }
  $exist = @{}
  foreach ($k in $fldrs.Keys) { if (Test-Path $fldrs[$k]) { $exist[$k] = $fldrs[$k] } }
  $bl = @()
  foreach ($app in ($exist.Keys | Sort-Object)) {
    $b = Get-Blockers $exist[$app]
    if ($b.dirty.Count -gt 0 -or $b.unpushed -gt 0 -or $b.noUpstream) {
      $bl += [pscustomobject]@{ app = $app; dirty = @($b.dirty); unpushed = $b.unpushed; noUpstream = $b.noUpstream }
    }
  }
  [pscustomobject]@{ ok = ($bl.Count -eq 0); blockers = @($bl); worktrees = @($exist.Keys | Sort-Object); present = ($exist.Count -gt 0) }
}

try {
  if (-not (Test-Path $StoryLibModule)) { Emit @{ ok = $false; error = "StoryLib.psm1 not found at $StoryLibModule - required for remove/check" }; return }
  Import-Module $StoryLibModule -Force -DisableNameChecking

  # ---- read-only status for every story (popup badges) ----
  if ($CheckAll) {
    $statuses = [ordered]@{}
    if (Test-Path $RegistryPath) {
      $regAll = Read-Registry -Root $Root
      # Get-StgNames, not @($regAll.stories.PSObject.Properties.Name) - an empty {} registry
      # (fresh install, zero stories) makes that expression $null, and @($null) is a one-element
      # array HOLDING $null, so this would run once with $s = $null and $statuses[$null] = ...
      # throws ("Index operation failed; the array index evaluated to null"). Same bug as the
      # native host's 'apps' action, same fix.
      foreach ($s in (Get-StgNames $regAll.stories)) {
        $statuses[$s] = Get-StoryStatus $s $regAll.stories.$s
      }
    }
    Emit @{ ok = $true; checkAll = $true; stories = $statuses }
    return
  }

  # Accepts both key shapes (Jira 'EH7-9550' and the no-ticket slug 'kuber-partner-date'). The old
  # Jira-only regex here is why a slug story switch-story could CREATE could never be removed.
  if (-not (Test-StoryKey $Story)) { Emit @{ ok = $false; error = "invalid story key: $Story" }; return }

  # ---- discover artifacts (node + any <root>\<STORY>\<app> folders on disk) ----
  $reg = $null; $hasNode = $false; $node = $null; $branch = $null
  if (Test-Path $RegistryPath) {
    $reg = Read-Registry -Root $Root
    $resolved = Resolve-RegistryKey -Registry $reg -Key $Story
    if ($resolved) { $Story = $resolved; $hasNode = $true; $node = $reg.stories.$Story; $branch = $node.branch }
  }

  $discovery = Get-StoryFolders -Root $Root -Story $Story -Node $node
  $folders   = $discovery.apps
  $extras    = @($discovery.extras)
  # A story created with a custom worktree root (switch-story.ps1 -WorktreeRoot) has its per-app
  # worktrees somewhere other than <Root>\<STORY>\<app> - Get-StoryFolders (StoryLib.psm1) has no
  # notion of that field, so patch just the per-app paths it returned rather than duplicate its
  # home-base/extras discovery logic here (StoryLib.psm1's source isn't available in every checkout,
  # this override works without needing to touch it).
  if ($node -and $node.worktreeRoot) {
    $wtRoot = $node.worktreeRoot
    $folders = @{}
    foreach ($app in @($node.apps)) { $folders[$app] = Join-Path (Join-Path $wtRoot $Story) $app }
  }

  $existing = @{}
  foreach ($k in $folders.Keys) { if (Test-Path $folders[$k]) { $existing[$k] = $folders[$k] } }

  # ---- optionally discard allow-listed generated files first ("discard generated & remove") ----
  $discarded = @()
  if ($DiscardGenerated -and -not $CheckOnly) {
    foreach ($app in ($existing.Keys | Sort-Object)) {
      $d = Discard-Generated $existing[$app]
      if ($d.Count) { $discarded += [pscustomobject]@{ app = $app; files = @($d) } }
    }
  }

  # ---- compute blockers: non-.env dirt / unpushed / no-upstream per existing worktree ----
  $blockers = @()
  foreach ($app in ($existing.Keys | Sort-Object)) {
    $b = Get-Blockers $existing[$app]
    if ($b.dirty.Count -gt 0 -or $b.unpushed -gt 0 -or $b.noUpstream) {
      $blockers += [pscustomobject]@{ app = $app; dirty = @($b.dirty); unpushed = $b.unpushed; noUpstream = $b.noUpstream }
    }
  }

  if ($CheckOnly) {
    Emit @{ ok = ($blockers.Count -eq 0); checkOnly = $true; story = $Story;
      blockers = @($blockers); worktrees = @($existing.Keys | Sort-Object);
      hasNode = $hasNode; message = if ($blockers.Count) { "Would be BLOCKED." } else { "Clear to remove." } }
    return
  }

  # ---- guardrail: abort (touch nothing) on real dirt or unpushed work ----
  if (-not $Force -and $blockers.Count -gt 0) {
    Emit @{ ok = $false; aborted = $true; story = $Story; blockers = @($blockers); discarded = @($discarded);
      message = "Not removed - uncommitted (non-.env) changes or unpushed commits." }
    return
  }

  # ---- remove worktrees (force only crosses the verified-throwaway $LocalArtifacts) ----
  $removed = @()
  foreach ($app in ($folders.Keys | Sort-Object)) {
    $wt = $folders[$app]
    $baseDir = Join-Path $Root $app
    if (-not (Test-Path $wt)) { $removed += [pscustomobject]@{ app = $app; status = 'already-absent' }; continue }
    $err = $null
    if (Test-Path (Join-Path $baseDir '.git')) {
      $r = Git-Cap $baseDir @('worktree', 'remove', '--force', $wt)
      if ($r.code -ne 0) { $err = $r.out }
    }
    if (Test-Path $wt) {
      try { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction Stop } catch { $err = $_.Exception.Message }
    }
    if (Test-Path (Join-Path $baseDir '.git')) { [void](Git-Cap $baseDir @('worktree', 'prune')) }
    if (Test-Path $wt) {
      $removed += [pscustomobject]@{ app = $app; status = 'failed'; error = $err }
    }
    else {
      if ($DeleteBranch -and $branch) { [void](Git-Cap $baseDir @('branch', '-D', $branch)) }
      $removed += [pscustomobject]@{ app = $app; status = 'removed' }
    }
  }
  $failed = @($removed | Where-Object { $_.status -eq 'failed' })

  $storyWtRoot = if ($node -and $node.worktreeRoot) { $node.worktreeRoot } else { $Root }
  $storyDir = Join-Path $storyWtRoot $Story

  # ---- archive node + local artifacts to stories_history.json, THEN drop the node ---------------
  # Order matters: Archive-Story reads the ledger / MANUAL-TEST.md out of $storyDir, which the next
  # block deletes. Archiving runs even with no registry node so an already-orphaned folder (node
  # dropped by an earlier partial removal) still gets its phase history preserved.
  $nodeStatus = if ($hasNode) { 'present' } else { 'already-absent' }
  $archiveStatus = 'skipped'
  if ($failed.Count -eq 0 -and ($hasNode -or (Test-Path -LiteralPath $storyDir))) {
    $archiveStatus = Archive-Story $Story $node $removed $storyDir
  }
  if ($hasNode -and $failed.Count -eq 0) {
    # Under the registry lock: 5+ writers (switch-story, story-env heal, this, the browser host).
    $key = $Story
    [void](Invoke-RegistryUpdate -Root $Root -Mutate {
      param($r)
      $k = Resolve-RegistryKey -Registry $r -Key $key
      if ($k) { $r.stories.PSObject.Properties.Remove($k) }
      $true
    })
    $nodeStatus = 'removed'
  }
  elseif ($hasNode) { $nodeStatus = 'kept (worktree removal failed)' }

  # ---- drop the <root>\<STORY> parent folder (nested layout) ------------------------------------
  # It is never EMPTY: the ledger, MANUAL-TEST.md and logs\ live here on purpose (outside every
  # repo, so they can't become a git blocker). The old empty-only check therefore never fired and
  # every shipped story leaked a shell. Delete the known artifacts; anything unrecognized keeps the
  # folder and is reported rather than silently removed.
  $folderStatus = if (Test-Path -LiteralPath $storyDir) { 'present' } else { 'already-absent' }
  if ($failed.Count -eq 0 -and (Test-Path -LiteralPath $storyDir)) {
    $leftover = @(Get-ChildItem -LiteralPath $storyDir -Force -ErrorAction SilentlyContinue)
    $unknown  = @($leftover | Where-Object { -not (Test-StoryFolderArtifact $_) })
    if ($unknown.Count) {
      $folderStatus = "kept (unrecognized content: $((@($unknown | ForEach-Object { $_.Name })) -join ', '))"
    }
    else {
      try { Remove-Item -LiteralPath $storyDir -Recurse -Force -ErrorAction Stop; $folderStatus = 'removed' }
      catch { $folderStatus = "kept ($($_.Exception.Message))" }
    }
  }
  elseif (Test-Path -LiteralPath $storyDir) { $folderStatus = 'kept (worktree removal failed)' }

  # ---- delete the .code-workspace (only once all worktrees are gone) ----
  $ws = Join-Path $WorkspaceDir ("{0}.code-workspace" -f $Story)
  $wsStatus = if (Test-Path $ws) { 'present' } else { 'already-absent' }
  if ((Test-Path $ws) -and $failed.Count -eq 0) { Remove-Item -LiteralPath $ws -Force; $wsStatus = 'removed' }
  elseif (Test-Path $ws) { $wsStatus = 'kept (worktree removal failed)' }

  # $ok used to be ($failed.Count -eq 0) alone - true even when $hasNode was $false, because an
  # absent story has nothing to fail removing. That made a story key not found in whatever
  # registry got resolved (e.g. a wrong -Root) look identical to a real, successful removal: the
  # node-drop above is correctly gated on $hasNode (:402), but this reply's own $ok never checked
  # it, so a pure no-op reported ok:true/node:"already-absent" and the caller had no way to tell
  # "nothing to remove" from "removed". Confirmed live: exactly this let a root mismatch go
  # unnoticed through several "✓ Removed" popup messages before the underlying cause was found.
  $ok = $hasNode -and ($failed.Count -eq 0)
  $res = @{ ok = $ok; story = $Story; hasNode = $hasNode; removed = @($removed); node = $nodeStatus; workspace = $wsStatus;
    archived = $archiveStatus; folder = $folderStatus; extras = @($extras);
    discarded = @($discarded); branchDeleted = [bool]($DeleteBranch -and $ok) }
  if (-not $hasNode) { $res.error = "'$Story' is not in stories.json at this root ($Root) - nothing to remove" }
  elseif (-not $ok) { $res.error = "one or more worktrees could not be removed (likely open files / locks - close editors/terminals/dev servers in that folder and retry)" }
  Emit $res
  return
}
catch {
  Emit @{ ok = $false; error = ("remove-worktree error: " + $_.Exception.Message) }
  return
}
