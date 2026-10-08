#requires -Version 5.1
<#
  story-doctor.ps1 - read-only reconciliation of everything that describes a story.

  The registry, the folders on disk, the workspace files, the history archive, the per-story
  ledgers and app-map.json all describe the same stories, and nothing checked that they agreed.
  Every drift this reports was previously discovered as an incident: a story folder left behind by
  a removal, a ledger orphaned from its node, a node with a bare-string 'apps' that crashed the
  browser extension, a slug key half the tools refused, a log array with two different shapes.

  Reads only. Never writes, never fixes - it prints (or returns) findings and exits 0.

  Usage:
    story-doctor.ps1 [-Json] [-Story <KEY>]   # -Story narrows to one story

  Severities: error (broken now) | warn (will break, or hides state) | info (worth knowing).
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Story,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  [string]$Project  # resolved project id (native-host\host.ps1); blank = active project / legacy resolution
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root -Project $Project
if ($Paths.NeedsSetup) {
  if ($Json) { [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress)) }
  else { Write-Host $Paths.Error -ForegroundColor Red }
  exit 0
}
$Root         = $Paths.Root
$RegistryPath = $Paths.StoriesPath
$HistoryPath  = $Paths.HistoryPath
$MapPath      = $Paths.AppMapPath
$WorkspaceDir = $Paths.WorkspaceDir
$LedgerName   = '.story-ship-state.json'

Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

# How long a released story may sit on disk before story-doctor mentions it. Deliberately an
# 'info': the whole point of the released flag is that teardown stops being urgent.
$ReleasedGraceDays = 7

$findings = @()
function Add-Finding([string]$sev, [string]$kind, [string]$story, [string]$detail, [string]$fix) {
  $script:findings += [pscustomobject]@{ severity = $sev; kind = $kind; story = $story; detail = $detail; fix = $fix }
}

function Test-Bom([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $b = [byte[]](Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 3 -ErrorAction SilentlyContinue)
  return ($b.Count -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

$result = [ordered]@{ ok = $true; scope = $null; findings = @(); counts = @{}; summary = '' }

try {
  $reg  = Read-Registry -Root $Root -DocsDir $Paths.DocsDir
  $hist = Read-JsonFile -Path $HistoryPath
  $map  = Read-JsonFile -Path $MapPath
  # Get-StgNames, not the bare @($obj.PSObject.Properties.Name) idiom - throws PowerShell's
  # one-element-array-of-null trap on an empty {} object (documented in CLAUDE.md's Dev gotchas).
  # $regKeys empty produced a phantom bad-key-shape error (plus, in worktree mode, phantom no-apps/
  # no-jira findings) on a genuinely empty registry - found live while verifying P5's tracking mode
  # against a fresh project with zero stories.
  $mapApps = if ($map) { Get-StgNames $map.apps } else { @() }

  $regKeys = Get-StgNames $reg.stories
  $histKeys = @(); if ($hist -and $hist.removed) { $histKeys = @(@($hist.removed) | ForEach-Object { "$($_.key)" }) }
  # Scanning $Root for story-shaped folder names is a worktree-mode concept - in tracking mode
  # $Root genuinely IS the tracked repo (src\, node_modules\, etc. live there), not a container of
  # per-story folders, so this scan would be both meaningless and wasted work.
  $folders  = if ($Paths.Mode -eq 'worktree') { @(Get-StoryFolderNames -Root $Root -Registry $reg -History $hist) } else { @() }

  $scope = if ($Story) { @($Story) } else { $regKeys }
  $result.scope = if ($Story) { $Story } else { 'all' }

  # ---- file-level hygiene (BOM breaks every JS consumer of these two files) ----
  if (-not $Story) {
    foreach ($p in @($RegistryPath, $HistoryPath)) {
      if (Test-Bom $p) {
        Add-Finding 'error' 'bom' '-' "$(Split-Path $p -Leaf) starts with a UTF-8 BOM" 'rewrite it BOM-less (StoryLib Write-JsonFile does this)'
      }
    }
  }

  # ---- per-registry-story checks ----
  foreach ($k in $scope) {
    if ($regKeys -notcontains $k) {
      Add-Finding 'error' 'unknown-story' $k 'not present in stories.json' 'check the key spelling'
      continue
    }
    $node = $reg.stories.$k

    if (-not (Test-StoryKey $k)) {
      Add-Finding 'error' 'bad-key-shape' $k "key matches neither the Jira form nor the kebab-slug form" 'rename the node; most tools validate the key shape'
    }

    # Array-shaped fields. A bare string here is the bug that crashed the extension popup with
    # '.map is not a function', and a string jira_stories iterates CHARACTER BY CHARACTER silently.
    foreach ($f in @('apps', 'jira_stories', 'sub_environments', 'previous_rels')) {
      if ($node.PSObject.Properties.Name -notcontains $f) { continue }
      $v = $node.$f
      if ($null -ne $v -and $v -isnot [Array]) {
        Add-Finding 'error' 'not-an-array' $k "'$f' is a $($v.GetType().Name), must be a JSON array" "wrap it: `"$f`": [ ... ]"
      }
    }

    # 'links' (custom named links: Abstract, Test plan, ...) follows the agiletest_urls/
    # chg_numbers convention - a MAP, not an array. switch-story.ps1 links only ever writes an
    # object, so a non-object here means hand-editing went wrong.
    if ($node.PSObject.Properties.Name -contains 'links') {
      $lv = $node.links
      if ($null -ne $lv -and ($lv -is [Array] -or $lv -isnot [PSCustomObject])) {
        Add-Finding 'error' 'links-not-an-object' $k "'links' is a $($lv.GetType().Name), must be a JSON object (e.g. { `"Abstract`": `"https://...`" })" 'switch-story.ps1 links <STORY> -Set "Label=url" rewrites it correctly'
      }
    }

    # NOTE: @($missingProperty).Count is 1 in PowerShell (an array holding one $null), so a
    # missing field looks populated. Always filter the nulls out before counting.
    # 'apps' is a worktree-only concept - a tracking-mode node has no app list by design (no
    # worktrees, no app checklist), so this used to fire as a permanent, unfixable ERROR on every
    # single tracking-mode story ever created. Caught live, the first time story-doctor ran against
    # a real tracking project.
    if ($Paths.Mode -eq 'worktree' -and -not @($node.apps | Where-Object { $_ }).Count) {
      Add-Finding 'error' 'no-apps' $k 'node declares no apps' 'add the app list'
    }
    foreach ($a in @($node.apps | Where-Object { $_ })) {
      if ($mapApps -notcontains "$a") {
        Add-Finding 'warn' 'app-not-mapped' $k "app '$a' is absent from app-map.json (no port / start command / health path)" 'add it to tools\app-map.json'
      }
    }

    if (-not @($node.jira_stories | Where-Object { $_ }).Count) {
      Add-Finding 'warn' 'no-jira' $k 'no jira_stories - release prep has nowhere to write release notes (customfield_10217)' 'link the Jira issue(s) on the node'
    }

    $expected = "feature/$($node.env)/$k"
    if ("$($node.branch)" -and "$($node.branch)" -ne $expected) {
      Add-Finding 'info' 'branch-shape' $k "branch '$($node.branch)' is not the conventional '$expected'" 'fine for -restore / recovery branches; otherwise fix the node'
    }

    # Two log-entry shapes in the wild: {ts,type,message} written by the scripts and {at,type,note}
    # written by hand. A reader keying on one silently drops the other.
    foreach ($e in @($node.log)) {
      if (-not $e) { continue }
      $names = @($e.PSObject.Properties.Name)
      if ($names -notcontains 'ts' -or $names -notcontains 'message') {
        Add-Finding 'info' 'log-shape' $k "a log entry uses {$($names -join ',')} instead of {ts,type,message}" 'normalize to ts/type/message so every reader sees it'
      }
    }

    # Folder + ledger + workspace presence are all worktree-only concepts (a per-story
    # <root>\<KEY>\ folder, a ledger nested inside it, a .code-workspace file) - gated behind mode.
    # Tracking mode's equivalents (doc file + ledger, at their own docsDir-based paths) are checked
    # in the else branch below instead.
    if ($Paths.Mode -eq 'worktree') {
      # A story's worktrees live under ITS OWN recorded worktreeRoot (set only when it differs
      # from Root at creation time), never the current global setting - same "read the node's own
      # field" rule every other worktree-aware command follows (CLAUDE.md's Migration safety
      # section; this is the identical fix already applied to story-ledger.ps1's own story-folder
      # resolution). Without this, a worktreeRoot-configured install always looked in $Root\$k,
      # found nothing, and reported a false 'no story folder' error for every story that actually
      # has a worktreeRoot override - i.e. every story on an install where Worktree Root is
      # configured differently from Story Root.
      $effRoot = if ($node.worktreeRoot) { [string]$node.worktreeRoot } else { $Root }
      $sd = Join-Path $effRoot $k
      if (-not (Test-Path -LiteralPath $sd)) {
        Add-Finding 'error' 'node-without-folder' $k "no story folder at $sd" 'recreate the worktree (switch-story.ps1 new) or drop the node'
        continue
      }
      $disc = Get-StoryFolders -Root $Root -Story $k -Node $node
      foreach ($a in @($node.apps | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath (Join-Path $sd "$a"))) {
          Add-Finding 'warn' 'app-without-worktree' $k "declared app '$a' has no folder under $k" 'create it or remove it from apps'
        }
      }
      if (@($disc.extras).Count) {
        Add-Finding 'info' 'extra-folders' $k "non-worktree folder(s) in the story dir: $(@($disc.extras) -join ', ')" 'harmless - never treated as apps, and removal reports rather than deletes unknown content'
      }

      $lp = Join-Path $sd $LedgerName
      if (-not (Test-Path -LiteralPath $lp)) {
        Add-Finding 'warn' 'no-ledger' $k 'no .story-ship-state.json - phase state is not being tracked' "run: tools\story-ledger.ps1 init -Story $k"
      }
      else {
        $led = $null; try { $led = Read-JsonFile -Path $lp } catch {
          Add-Finding 'error' 'ledger-unreadable' $k "ledger will not parse: $($_.Exception.Message)" 'fix or delete the file'
        }
        if ($led) {
          $failed = @($led.phases | Where-Object { $_.status -eq 'failed' })
          if ($failed.Count) {
            Add-Finding 'warn' 'ledger-failed-phase' $k "phase(s) left failed: $((@($failed | ForEach-Object { $_.name })) -join ', ')" 'resolve or reset them before the story is torn down'
          }
          # Node fields that prove work the ledger still calls pending -> 'sync' would fix it. The
          # rel-ticket/release-branch/chg/agiletest checks that used to live here were removed
          # along with those phases (story-ledger.ps1's Invoke-Sync no longer seeds them either) -
          # leaving them in would just be permanently-dead-but-still-live-looking code.
          $seedable = @()
          if ($node.document -and (@($led.phases | Where-Object { $_.name -eq 'plan' -and $_.status -eq 'pending' }).Count)) { $seedable += 'plan' }
          if ($seedable.Count) {
            Add-Finding 'warn' 'ledger-behind-node' $k "the node proves these happened but the ledger says pending: $($seedable -join ', ')" "run: tools\story-ledger.ps1 sync -Story $k"
          }
        }
      }

      if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceDir "$k.code-workspace"))) {
        Add-Finding 'info' 'no-workspace' $k 'no .code-workspace file' 'switch-story.ps1 open regenerates it'
      }

      # Decoupling 'released' from 'removed' means shipped stories accumulate on disk instead of
      # being torn down. That is the point - but somebody has to say when they have sat there long
      # enough, or the popup slowly fills with finished work again.
      $rel = "$($node.released)".Trim()
      if ($rel -and (Test-Path -LiteralPath $sd)) {
        $relDt = [datetime]::MinValue
        $parsed = [datetime]::TryParseExact($rel, 'yyyy-MM-dd HH:mm',
          [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$relDt)
        if (-not $parsed) { $parsed = [datetime]::TryParse($rel, [ref]$relDt) }
        $days = if ($parsed) { [int]((Get-Date) - $relDt).TotalDays } else { 0 }
        if ($days -ge $ReleasedGraceDays) {
          Add-Finding 'info' 'released-not-removed' $k "released $rel ($days days ago) but the worktree is still on disk" "safe to tear down: remove-worktree.ps1 -Story $k  (preview with -CheckOnly)"
        }
      }
    }
    else {
      # Tracking mode: the doc file is the worktree-mode folder's equivalent - a story without one
      # has nothing for Claude to write progress into. The ledger still applies too (story-doc.ps1/
      # Invoke-New both init one, at its own docsDir-based path - Get-StgLedgerPath handles that),
      # just without the app/workspace/extra-folders checks that have no tracking-mode equivalent.
      $docPath = Get-StgStoryDocPath -Paths $Paths -Story $k
      if (-not (Test-Path -LiteralPath $docPath)) {
        Add-Finding 'warn' 'no-story-doc' $k "no doc at $docPath" "run: tools\story-doc.ps1 init -Story $k"
      }
      $lp = Get-StgLedgerPath -Paths $Paths -Story $k
      if (-not (Test-Path -LiteralPath $lp)) {
        Add-Finding 'warn' 'no-ledger' $k 'no .story-ship-state.json - phase state is not being tracked' "run: tools\story-ledger.ps1 init -Story $k"
      }
      else {
        $led = $null; try { $led = Read-JsonFile -Path $lp } catch {
          Add-Finding 'error' 'ledger-unreadable' $k "ledger will not parse: $($_.Exception.Message)" 'fix or delete the file'
        }
        if ($led) {
          $failed = @($led.phases | Where-Object { $_.status -eq 'failed' })
          if ($failed.Count) {
            Add-Finding 'warn' 'ledger-failed-phase' $k "phase(s) left failed: $((@($failed | ForEach-Object { $_.name })) -join ', ')" 'resolve or reset them before the story is torn down'
          }
        }
      }
    }
  }

  # ---- whole-registry cross-checks (skipped when narrowed to one story) ----
  if (-not $Story) {
    foreach ($f in $folders) {
      if ($regKeys -contains $f) { continue }
      $sd = Join-Path $Root $f
      $inHist = ($histKeys -contains $f)
      $left = @(Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
      if ($inHist) {
        Add-Finding 'warn' 'archived-folder-remains' $f "archived in stories_history.json but the folder still exists ($($left -join ', '))" "run: remove-worktree.ps1 -Story $f  (archives the ledger, then deletes the folder)"
      }
      else {
        Add-Finding 'error' 'folder-without-node' $f "story folder on disk with no registry node and no history record ($($left -join ', '))" 'recreate the node or remove the folder deliberately'
      }
    }

    # $WorkspaceDir is $null in tracking mode (no .code-workspace concept at all) - Get-ChildItem
    # -LiteralPath $null throws on parameter binding regardless of -ErrorAction, so this needs an
    # explicit guard, not just relying on the worktree-only $folders loop above being naturally
    # empty. Every $WorkspaceDir/$WorktreeRoot consumer in this codebase needs the same care.
    if ($WorkspaceDir) {
      # Known non-story workspace files, never flagged as stale regardless of what's in the
      # registry: 'full_ui_workspace' (a dead exclusion from before this repo's initial commit -
      # nothing ever created that file, but something, somewhere, still might), plus the real
      # project-wide workspaces this tool now generates itself (no story key, so they'd otherwise
      # always show up here as "no registry node").
      $knownNonStoryWorkspaces = @('full_ui_workspace', 'main_workspace', 'dev_workspace')
      foreach ($ws in @(Get-ChildItem -LiteralPath $WorkspaceDir -Filter '*.code-workspace' -ErrorAction SilentlyContinue)) {
        $key = [IO.Path]::GetFileNameWithoutExtension($ws.Name)
        if ($knownNonStoryWorkspaces -contains $key) { continue }
        if ($regKeys -notcontains $key) {
          Add-Finding 'warn' 'stale-workspace' $key "workspace file with no registry node: $($ws.FullName)" 'delete it - the story is gone'
        }
      }
    }

    # History integrity: a record with no ledger cannot answer "what happened on that story".
    # $hist.removed is $null whenever stories_history.json doesn't exist yet (every project before
    # its first removal) or has no 'removed' key - @($null) is PowerShell's one-element-array-of-
    # null trap (documented in CLAUDE.md), so without the 'if (-not $e) { continue }' guard already
    # used two loops up for $node.log, this fired a phantom info finding with an empty story key on
    # every single doctor run against a project that has never had a removal. Caught live.
    foreach ($e in @($hist.removed)) {
      if (-not $e) { continue }
      $names = @($e.PSObject.Properties.Name)
      if ($names -notcontains 'ledger' -and $names -notcontains 'node') {
        Add-Finding 'info' 'thin-history-record' "$($e.key)" 'history record carries neither a node nor a ledger' 'pre-dates the archiver; nothing to do'
      }
    }
  }

  $result.findings = @($findings)
  $counts = [ordered]@{ error = 0; warn = 0; info = 0 }
  foreach ($f in $findings) { $counts[$f.severity] = [int]$counts[$f.severity] + 1 }
  $result.counts = $counts
  $result.ok = ($counts.error -eq 0)
  $result.summary = "$($result.scope): $($counts.error) error(s), $($counts.warn) warning(s), $($counts.info) info"

  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)); return }

  Write-Host ""
  Write-Host "story-doctor - $($result.summary)" -ForegroundColor Cyan
  Write-Host ""
  if (-not @($findings).Count) { Write-Host "  everything reconciles." -ForegroundColor Green; Write-Host ""; return }
  foreach ($sev in @('error', 'warn', 'info')) {
    $rows = @($findings | Where-Object { $_.severity -eq $sev })
    if (-not $rows.Count) { continue }
    $col = switch ($sev) { 'error' { 'Red' } 'warn' { 'Yellow' } default { 'DarkGray' } }
    foreach ($r in $rows) {
      Write-Host ("  [{0,-5}] {1,-24} {2}" -f $sev, $r.story, $r.detail) -ForegroundColor $col
      if ($r.fix) { Write-Host ("            -> {0}" -f $r.fix) -ForegroundColor DarkGray }
    }
  }
  Write-Host ""
}
catch {
  $result.ok = $false
  $result.error = "story-doctor error: $($_.Exception.Message)"
  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)) }
  else { Write-Host "`n$($result.error)`n" -ForegroundColor Red }
}
