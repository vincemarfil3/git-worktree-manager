#requires -Version 5.1
<#
  story-release.ps1 - mark a story RELEASED (or roll that back) without removing its worktree.

  The gap this closes: shipping a ticket left no trace locally. The only terminal action was
  remove-worktree.ps1, which is guardrailed and too final, so a shipped story sat in the popup and
  in vault-status looking active forever, and nothing could tell /eod to emit its "done" line.

  'Released' is deliberately NOT a new concept: it is the ledger's existing last phase, 'deploy'.
  Stamping that phase lights up the extension's phase chip, vault-status.ps1 and story-doctor.ps1
  for free, with no parallel state to keep in sync. The 'released' field on the stories.json node
  is a denormalised read for the popup and /eod, and it rides into stories_history.json on removal
  because remove-worktree.ps1 archives the whole node.

  'release' runs the ledger's own 'sync' first, so a story released in the real world gets its
  'plan' phase backfilled from a node field that already proves it happened (document /
  document_keycloak_setup) instead of showing a stale pending checklist item forever. (Prior to
  the org-specific prep-release phases being dropped, sync also backfilled rel-ticket/
  release-branch/agiletest/chg from rel/releaseBranch/agiletest_url(s)/chg_number(s) - those
  phases and this backfill are gone now, along with them.)

  Usage:
    story-release.ps1 release   [STORY] [-Story S] [-Note m]   [-Json]
    story-release.ps1 unrelease [STORY] [-Story S] [-Reason m] [-Json]
    story-release.ps1 status    [STORY] [-Story S] [-All]      [-Json]

  Both mutations are idempotent. Always exits 0; success is carried in the 'ok' field.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'status',
  [Parameter(Position = 1)] [string]$StoryPositional,
  [string]$Story,
  [string]$Note,
  [string]$Reason,
  [switch]$All,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  [string]$Project,  # resolved project id (native-host\host.ps1); blank = active project / legacy resolution
  # Swallow stray positionals rather than dying with a binding error before the try block can
  # produce a JSON frame. Reported as ok:false below.
  [Parameter(ValueFromRemainingArguments = $true)] $Extra
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root -Project $Project
if ($Paths.NeedsSetup) {
  if ($Json) { [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress)) }
  else { Write-Host $Paths.Error -ForegroundColor Red }
  exit 0
}
$Root           = $Paths.Root
$AllowedActions = @('release', 'unrelease', 'status')

Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

if (-not $Story -and $StoryPositional) { $Story = $StoryPositional }
# 'story-release.ps1 EH7-9544' - a story key in the action slot is a bare status read.
if ($Action -notin $AllowedActions -and (Test-StoryKey $Action)) {
  if (-not $Story) { $Story = $Action }
  $Action = 'status'
}

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  else { Write-Host $o.summary }
}

# story-ledger.ps1 writes its JSON with [Console]::Out.Write, which bypasses the PowerShell
# pipeline - calling it in-process would leak that text straight into THIS script's stdout and
# corrupt our own frame. A child powershell.exe keeps the two streams separate.
function Invoke-Ledger([string[]]$LedgerArgs) {
  $lscript = Join-Path $PSScriptRoot 'story-ledger.ps1'
  if (-not (Test-Path -LiteralPath $lscript)) { return $null }
  # Pass our own already-resolved -Root AND -Project through so a child process can't re-resolve
  # to a different root/project (e.g. a different auto-detect result, or -Project unset here
  # falling back to whichever project is currently active) than the one this run is using.
  # [string]$Paths.ProjectId, not the bare value - ProjectId is $null (not '') in the legacy
  # no-project branch, and a $null element is DROPPED when splatted to a native command, leaving a
  # dangling -Project flag with no value that throws a parameter-binding error; casting to
  # [string] gives '' instead, which passes through as a genuine empty argument, same as $Root.
  $pargs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $lscript) + $LedgerArgs + @('-Json', '-Root', $Root, '-Project', [string]$Paths.ProjectId)
  $out = & powershell.exe @pargs
  $global:LASTEXITCODE = 0
  $txt = ($out | Out-String).Trim()
  if (-not $txt) { return $null }
  try { return ($txt | ConvertFrom-Json) } catch { return $null }
}

function Set-NodeField($Node, [string]$Name, $Value) {
  if (@($Node.PSObject.Properties.Name) -contains $Name) { $Node.$Name = $Value }
  else { $Node | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Add-NodeLog($Node, [string]$Type, [string]$Message) {
  $entry = [pscustomobject]@{ ts = (Get-Stamp); type = $Type; message = $Message }
  if (@($Node.PSObject.Properties.Name) -contains 'log') { $Node.log = @(@($Node.log) + $entry) }
  else { $Node | Add-Member -NotePropertyName 'log' -NotePropertyValue @($entry) -Force }
}

function Get-NodeField($Node, [string]$Name) {
  if (@($Node.PSObject.Properties.Name) -contains $Name) { return [string]$Node.$Name }
  return ''
}

# Released state for one story, from the node plus the ledger's 'deploy' phase. Pure file reads.
function Get-ReleasedInfo([string]$S, $Node) {
  $ledPath = Get-StgLedgerPath -Paths $Paths -Story $S -Node $Node
  $deploy = $null
  if (Test-Path -LiteralPath $ledPath) {
    try {
      $led = Read-JsonFile -Path $ledPath
      $pn = @($led.phases) | Where-Object { $_.name -eq 'deploy' } | Select-Object -First 1
      if ($pn) { $deploy = [string]$pn.status }
    }
    catch {}
  }
  # Same worktreeRoot-blind gap Get-StgLedgerPath fixes above - a story whose worktrees live under
  # a configured worktreeRoot always resolved $Root\$S here, found nothing, and reported
  # present:false for a story that is, in fact, on disk.
  $effRoot = if ($Node -and $Node.worktreeRoot) { [string]$Node.worktreeRoot } else { $Paths.Root }
  [pscustomobject]@{
    released        = (Get-NodeField $Node 'released')
    released_posted = (Get-NodeField $Node 'released_posted')
    deploy          = $deploy
    present         = (Test-Path -LiteralPath (Join-Path $effRoot $S))
  }
}

$result = [ordered]@{ ok = $true; action = $Action; story = $null; released = $null
  deploy = $null; seeded = $null; warning = $null; stories = $null; summary = '' }

try {
  if ($Action -notin $AllowedActions) { throw "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  if ($Extra) { throw ("unexpected extra argument(s): " + (@($Extra) -join ' ') + ". Usage: story-release.ps1 <release|unrelease|status> [STORY]") }

  $reg = Read-Registry -Root $Root -DocsDir $Paths.DocsDir

  # ---- status with no resolvable story: every story at once, for the popup's released chip ----
  if ($Action -eq 'status' -and ($All -or (-not $Story -and -not (Resolve-StoryFromPath -Root $Root -Registry $reg)))) {
    $map = [ordered]@{}
    # Get-StgNames, not @($reg.stories.PSObject.Properties.Name) - see remove-worktree.ps1's
    # -CheckAll fix / stg-paths.psm1's Get-StgNames for why the bare @() idiom throws on an
    # empty {} registry.
    foreach ($k in (Get-StgNames $reg.stories)) {
      $map[$k] = Get-ReleasedInfo $k $reg.stories.$k
    }
    $result.stories = $map
    $n = @(@($map.Keys) | Where-Object { $map[$_].released }).Count
    $result.summary = "$n of $(@($map.Keys).Count) stories marked released"
    Out-Result $result
    return
  }

  # ---- everything else needs one story ----
  $S = $Story
  if (-not $S) { $S = Resolve-StoryFromPath -Root $Root -Registry $reg }
  if (-not $S) { throw "Could not infer the story from cwd '$((Get-Location).Path)'. Pass it: story-release.ps1 $Action -Story <STORY>" }
  $resolved = Resolve-RegistryKey -Registry $reg -Key $S
  if (-not $resolved) { throw (Get-MissingStoryHint -Root $Root -Key $S) }
  $S = $resolved
  $result.story = $S

  $info = Get-ReleasedInfo $S $reg.stories.$S
  if (-not $info.present) { $result.warning = "story folder $Root\$S is missing - updating the registry node only, no ledger change" }

  switch ($Action) {
    'status' {
      $result.released = $info.released
      $result.deploy = $info.deploy
      $result.summary = if ($info.released) { "$S : released $($info.released)" } else { "$S : not released (deploy=$($info.deploy))" }
    }

    'release' {
      if ($info.released) {
        $result.released = $info.released
        $result.deploy = $info.deploy
        $result.summary = "$S : already released $($info.released) - nothing to do"
        break
      }

      # Ledger first, outside the registry lock: these spawn a child powershell.exe and there is no
      # reason to make every other story tool wait on that.
      if ($info.present) {
        $sync = Invoke-Ledger @('sync', '-Story', $S)
        if ($sync -and $sync.summary) { $result.seeded = [string]$sync.summary }
        $arts = if ($Note) { "released: $Note" } else { 'released' }
        $done = Invoke-Ledger @('done', 'deploy', '-Story', $S, '-Artifacts', $arts)
        if ($done -and -not $done.ok) { $result.warning = "ledger: $($done.error)" }
        elseif ($done) { $result.deploy = 'done' }
      }

      $stamp = Get-Stamp
      $msg = if ($Note) { $Note } else { 'marked released' }
      $key = $S
      Invoke-RegistryUpdate -Root $Root -DocsDir $Paths.DocsDir -Mutate {
        param($r)
        $node = $r.stories.$key
        if (-not $node) { return $false }
        # Re-check under the lock: another writer may have released it since the unlocked read.
        if (Get-NodeField $node 'released') { return $false }
        Set-NodeField $node 'released' $stamp
        Set-NodeField $node 'released_posted' ''
        Add-NodeLog $node 'released' $msg
        return $true
      } | Out-Null

      $result.released = $stamp
      $result.summary = "$S : released $stamp"
    }

    'unrelease' {
      if (-not $info.released) {
        $result.deploy = $info.deploy
        $result.summary = "$S : not currently released - nothing to do"
        break
      }

      if ($info.present) {
        $reset = Invoke-Ledger @('reset', 'deploy', '-Story', $S)
        if ($reset -and -not $reset.ok) { $result.warning = "ledger: $($reset.error)" }
        elseif ($reset) { $result.deploy = 'pending' }
      }

      $was = $info.released
      $msg = if ($Reason) { $Reason } else { 'unreleased (rollback)' }
      $key = $S
      Invoke-RegistryUpdate -Root $Root -DocsDir $Paths.DocsDir -Mutate {
        param($r)
        $node = $r.stories.$key
        if (-not $node) { return $false }
        Set-NodeField $node 'released' ''
        # Clear the announcement stamp too, so a later re-release announces 'done' again.
        Set-NodeField $node 'released_posted' ''
        Add-NodeLog $node 'unreleased' "$msg (was released $was)"
        return $true
      } | Out-Null

      $result.released = ''
      $result.summary = "$S : unreleased (was $was)"
    }
  }

  Out-Result $result
}
catch {
  $result.ok = $false
  $result.error = "story-release error: $($_.Exception.Message)"
  Out-Result $result
}
