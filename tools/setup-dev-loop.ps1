#requires -Version 5.1
<#
  setup-dev-loop.ps1 - retrofits a TRACKING-MODE project that was added before the planning/
  brainstorming feature existed (main_workspace/dev_workspace, DESIGN.md/ROADMAP.md, the
  .gitignore entries for the hybrid commit model). A brand-new tracking-mode project already gets
  all of this automatically from New-StgProject - this script exists only for one already added
  earlier, where none of it has ever been created.

  Read-only by default ('check'): reports exactly what's missing, writes nothing. 'apply' is the
  only action that writes, and it's meant to run only after a human has seen the check output and
  said yes - matching dev-cycle's own bootstrap rule (propose, one confirmation, then write), not
  an unattended write. Both actions are safe to re-run any number of times: every file this touches
  is guarded by its own already-present check (New-StgTrackingScaffold, shared with
  New-StgProject's own auto-create - one implementation, not two copies to keep in sync), so
  running 'apply' on a project that already has some or all of these pieces only creates what's
  still missing.

  Worktree-mode projects don't need this at all - main_workspace there is regenerated fresh on
  every 'openmain' call, and there's no dev_workspace/DESIGN.md/ROADMAP.md/.gitignore concept in
  that mode - so this script refuses with a clear message rather than silently no-op'ing.

  Usage:
    setup-dev-loop.ps1 check -Project <id> -Json   # what's missing - changes nothing
    setup-dev-loop.ps1 apply -Project <id> -Json   # creates whatever check reported missing

  Always exits 0; success is carried in the 'ok' field, matching every other tool here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'check',
  [string]$Project,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
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

$AllowedActions = @('check', 'apply')

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  else { Write-Host $o.summary }
}

if ($Action -notin $AllowedActions) {
  Out-Result @{ ok = $false; error = "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  exit 0
}
if ($Extra) {
  Out-Result @{ ok = $false; error = ("unexpected extra argument(s): " + (@($Extra) -join ' ')) }
  exit 0
}
if ($Paths.Mode -ne 'tracking') {
  Out-Result @{ ok = $false; error = "project '$($Paths.ProjectId)' is worktree mode - there's nothing for setup-dev-loop to bootstrap here. main_workspace regenerates on its own via the 'openmain' action; DESIGN.md/ROADMAP.md/dev_workspace/the .gitignore entries are tracking-mode-only concepts." }
  exit 0
}

try {
  if ($Action -eq 'check') {
    # Read-only: ask New-StgTrackingScaffold's own already-present checks what's missing, without
    # actually calling it (calling it would write) - so this literally cannot have a side effect,
    # not just "shouldn't".
    $docsDir = if ($Paths.DocsDir) { [string]$Paths.DocsDir } else { '.claude\stories' }
    $items = @(
      @{ name = 'stories.json'; path = (Join-Path (Join-Path $Paths.Root $docsDir) 'stories.json') }
      @{ name = '.gitignore entries'; path = (Join-Path $Paths.Root '.gitignore') }
      @{ name = 'DESIGN.md'; path = (Join-Path $Paths.Root 'DESIGN.md') }
      @{ name = 'ROADMAP.md'; path = (Join-Path $Paths.Root 'ROADMAP.md') }
      @{ name = 'main_workspace.code-workspace'; path = (Join-Path $Paths.Root 'main_workspace.code-workspace') }
      @{ name = 'dev_workspace.code-workspace'; path = (Join-Path $Paths.Root 'dev_workspace.code-workspace') }
      @{ name = 'worktree folder'; path = (Join-Path $Paths.Root 'worktree') }
      @{ name = 'workspace folder'; path = (Join-Path $Paths.Root 'workspace') }
    )
    $docsDirFwd = $docsDir.Replace('\', '/')
    $ignoreLines = @("$docsDirFwd/*.story-ship-state.json", "$docsDirFwd/*.lock")
    $existingIgnore = if (Test-Path $items[1].path) { [System.IO.File]::ReadAllText($items[1].path) } else { '' }
    $existingIgnoreLines = @($existingIgnore -split "`r?`n" | ForEach-Object { $_.Trim() })
    $gitignoreComplete = -not @($ignoreLines | Where-Object { $existingIgnoreLines -notcontains $_ }).Count

    $report = foreach ($it in $items) {
      $present = if ($it.name -eq '.gitignore entries') { (Test-Path $it.path) -and $gitignoreComplete } else { Test-Path $it.path }
      [pscustomobject]@{ name = $it.name; path = $it.path; present = [bool]$present }
    }
    $missing = @($report | Where-Object { -not $_.present })
    # ForEach-Object, not member-enumeration (.name) - dot-notation property access on an EMPTY
    # array returns bare $null (not an empty array), and @($null) is CLAUDE.md's own documented
    # trap: a one-element array HOLDING null, not an empty one. Piping through ForEach-Object
    # instead means @() wraps the pipeline's actual emitted-object count (zero when $missing is
    # empty), which is what @() was always meant to guarantee. Found live testing this exact
    # branch: an all-present check reported "missing":[null] instead of "missing":[].
    $missingNames = @($missing | ForEach-Object { $_.name })
    Out-Result @{
      ok      = $true
      action  = 'check'
      project = $Paths.ProjectId
      root    = $Paths.Root
      items   = $report
      missing = $missingNames
      summary = if ($missing.Count -eq 0) { "$($Paths.ProjectId): everything already set up, nothing to do" }
                else { "$($Paths.ProjectId): missing $($missing.Count) item(s) - $($missingNames -join ', '). Re-run with 'apply' to create them." }
    }
  }
  else {
    # apply - meant to run only after a human has seen 'check' and agreed; this script itself
    # doesn't gate that (no interactive prompt under -Json, same reasoning every other -Json
    # script in this codebase follows) - the calling skill's own instructions are what get the
    # human's one confirmation first.
    $before = New-StgTrackingScaffold -Root $Paths.Root -DocsDir $(if ($Paths.DocsDir) { [string]$Paths.DocsDir } else { '.claude\stories' }) -ProjectName $Paths.ProjectName
    $created = @($before | Where-Object { $_.created })
    # Same ForEach-Object fix as 'check' above - see its comment for why .name alone isn't safe here.
    $createdNames = @($created | ForEach-Object { $_.name })
    Out-Result @{
      ok      = $true
      action  = 'apply'
      project = $Paths.ProjectId
      root    = $Paths.Root
      items   = $before
      created = $createdNames
      summary = if ($created.Count -eq 0) { "$($Paths.ProjectId): already fully set up, nothing to create" }
                else { "$($Paths.ProjectId): created $($created.Count) item(s) - $($createdNames -join ', ')" }
    }
  }
}
catch {
  Out-Result @{ ok = $false; error = "setup-dev-loop error: $($_.Exception.Message)" }
}
