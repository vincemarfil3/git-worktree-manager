#requires -Version 5.1
<#
  story-testplan.ps1 - derive WHAT MUST BE VERIFIED for a story from its actual diff.

  This script does the deterministic half only: it classifies every changed file into a layer and
  emits the verification each layer demands, plus the traps that layer combination implies. It does
  NOT write test steps - it cannot know intent. The model (see /story-test) reads this output plus
  the Jira acceptance criteria and turns it into Action / Expected-result pairs.

  Why it exists: the Insights report found the worst reworks were changes that "looked right but
  weren't verified at the layer the bug appeared" - a finance_rate_type_cd fix that only touched the
  UI and never populated reporting.finance_rate, and a Bruno IDOR test that falsely passed because
  victimId was the attacker's own id. Both are detectable from the diff shape alone.

  Usage:
    story-testplan.ps1 [STORY] [-Json] [-Base origin/main] [-Out <path>] [-NoWrite]

  STORY omitted -> inferred from cwd (<root>\<STORY>\<app>, so the PARENT folder is the key).
  Default output: <root>\<STORY>\MANUAL-TEST.md  (the STORY folder, OUTSIDE every repo, so it can
  never become a remove-worktree.ps1 blocker - Get-Blockers only ever exempts .env).

  Always exits 0; success/failure is carried in the 'ok' field, matching the other tools here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Story,
  [string]$Base = 'origin/main',
  [string]$Out,
  [switch]$Json,
  [switch]$NoWrite,
  [switch]$Full,
  [string]$Root  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root
if ($Paths.NeedsSetup) {
  if ($Json) { [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress)) }
  else { Write-Host $Paths.Error -ForegroundColor Red }
  exit 0
}
$Root         = $Paths.Root
$RegistryPath = $Paths.StoriesPath

# Shared helpers: BOM-safe IO, story-key shapes, worktree-aware folder discovery, git capture.
Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

# ---- layer classification: ORDERED, first match wins. Grounded in the real paths of
# ---- EH7-9170 / PIII-10877 / EH7-8278 (2026-08-01), not invented globs. Edit freely.
$LayerRules = @(
  @{ layer = 'generated';   pattern = '(routeTree\.gen\.ts|\.gen\.(ts|py)|yarn\.lock|package-lock\.json)$' }
  # 'test' sits ABOVE the app-layer rules on purpose: it used to be below them, so
  # app/services/tests/test_x.py classified as 'service' and could then trigger the "no test
  # changed" trap while a test WAS changed. pageobject/ belongs here too - those are test
  # infrastructure, and matching their components/ segment against the 'ui' rule is what made a
  # pure pytest change (EH7-8934) emit a bogus "[HIGH] UI-only change" trap.
  @{ layer = 'test';        pattern = '((^|/)tests?/|(^|/)page_?objects?/|(^|/)conftest\.py$|_test\.py$|\.(spec|test)\.(ts|tsx|js|jsx)$)' }
  # Two conventions in the wild: kuber uses db_scripts/, bartleby uses src/database/dbscripts/.
  # The \.sql$ catch-all makes this robust to a third one appearing.
  @{ layer = 'db-script';   pattern = '((^|/)db_?scripts/|\.sql$)' }
  @{ layer = 'env-config';  pattern = '(^|/)devops/environments/' }
  @{ layer = 'pipeline';    pattern = '(^|/)(app|src)/pipelines?/' }
  @{ layer = 'config';      pattern = '((^|/)(app|src)/config/|\.env\.example$)' }
  @{ layer = 'api';         pattern = '(^|/)(app|src)/(routers?|api|endpoints?)/' }
  @{ layer = 'data-shape';  pattern = '(^|/)(app|src)/(dtos?|models|entity|entities|schemas)/' }
  @{ layer = 'data-access'; pattern = '(^|/)(app|src)/repositor(y|ies)/' }
  @{ layer = 'service';     pattern = '(^|/)(app|src)/services/' }
  @{ layer = 'di-wiring';   pattern = '(^|/)(app|src)/containers/' }
  @{ layer = 'bruno';       pattern = '\.bru$' }
  # src/ is optional: the Next.js App Router apps (ganesha-ui-internal-app) keep components/ and
  # utils/ at the repo root, so a src/-only pattern dropped their .ts helpers into 'other'.
  @{ layer = 'ui';          pattern = '((^|/)(src/)?(pages|components|routes)/|\.(tsx|jsx)$)' }
  @{ layer = 'ui-logic';    pattern = '(^|/)(src/)?(hooks|store|context|utils/yup_validations)/' }
  @{ layer = 'style';       pattern = '\.(scss|css|sass|less)$' }
  @{ layer = 'docs';        pattern = '\.(md|txt)$' }
)

# What each layer OBLIGES you to do. This is the report's verification standard, encoded:
# verify at the layer the bug appeared - DB->query, UI->render, API->real request.
$LayerVerification = [ordered]@{
  'db-script'   = 'Run the script on the target env, then prove the effect with a SELECT. A migration that "ran clean" is not verified until a query shows the rows/columns.'
  'env-config'  = 'Confirm the new/changed key is present in the DEPLOYED env (not just the yaml). A committed yaml is not a live value.'
  'config'      = 'Start the app and confirm it reads the new setting; a missing key often fails silently with a default.'
  'api'         = 'Call the endpoint for real (Bruno or curl) and assert the response body, not just a 200.'
  'data-shape'  = 'Check serialization explicitly: datetime in JSON, nulls, and whether a field is an array vs a scalar. This is the class that caused the Bartleby datetime bug.'
  'data-access' = 'Verify the query returns what you expect against real data, including the empty and null-join cases.'
  'service'     = 'Exercise the business rule through its caller, including at least one negative/boundary case.'
  'pipeline'    = 'Run the pipeline end-to-end and confirm the WRITTEN ROWS, not just that it completed without error. A pipeline that logs success while writing nothing is the common failure here.'
  'di-wiring'   = 'Confirm the app still boots and the affected dependency resolves. Wiring errors surface at startup.'
  'bruno'       = 'Read the fixture values BEFORE trusting a pass. A wrong id in the fixture produces a false pass (this is exactly how the IDOR test passed).'
  'ui'          = 'Render it in the browser and confirm the value round-trips - reload the page and confirm it persisted.'
  'ui-logic'    = 'Exercise the hook/state path through the UI, including the loading and error states.'
  'style'       = 'Visual check only; no functional assertion needed.'
  'test'        = 'Run the test and also confirm it FAILS when you deliberately break the thing it covers.'
  'docs'        = 'No runtime verification needed.'
  'other'       = 'Inspect the change and decide what proves it works.'
  'generated'   = 'Generated artifact - do not hand-verify; confirm it was regenerated, not hand-edited.'
}

function Resolve-Story([string]$S) {
  $reg = if (Test-Path $RegistryPath) { Read-JsonFile -Path $RegistryPath } else { $null }
  if ($S) {
    if ($reg) { $k = Resolve-RegistryKey -Registry $reg -Key $S; if ($k) { return $k } }
    return $S
  }
  $inferred = Resolve-StoryFromPath -Root $Root -Registry $reg
  if ($inferred) { return $inferred }
  throw "Could not infer the story from cwd '$((Get-Location).Path)'. Pass it: story-testplan.ps1 <STORY>"
}

function Git-Cap([string]$Dir, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # Keep stdout clean: in PS 5.1, 2>&1 on a native exe wraps each stderr line in an ErrorRecord,
    # so git's warnings ("LF will be replaced by CRLF") would land in the file list. Use
    # Get-GitError for the failure MESSAGE - discarding stderr entirely is what reduced every
    # failure to a bare "diff failed (fetch first?)" with git's actual complaint thrown away.
    $out = & git -C $Dir @GitArgs 2>$null
    return @{ code = $LASTEXITCODE; out = ($out | Out-String) }
  }
  finally { $ErrorActionPreference = $prev }
}

# Re-run a failed git command with stderr captured, purely to explain the failure.
function Get-GitError([string]$Dir, [string[]]$GitArgs) {
  $r = Invoke-GitCap -Dir $Dir -GitArgs $GitArgs
  $msg = "$($r.out)".Trim()
  if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
  return $msg
}

function Get-Layer([string]$Path) {
  foreach ($rule in $LayerRules) { if ($Path -match $rule.pattern) { return $rule.layer } }
  return 'other'
}

$result = [ordered]@{
  ok = $true; story = $null; env = $null; base = $Base
  apps = @(); layers = @(); flags = @(); output = $null; summary = ''
}

try {
  if (-not (Test-Path $RegistryPath)) { throw "stories.json not found at $RegistryPath" }
  $reg = Read-JsonFile -Path $RegistryPath
  $S = Resolve-Story $Story
  $result.story = $S
  if (-not (Resolve-RegistryKey -Registry $reg -Key $S)) { throw (Get-MissingStoryHint -Root $Root -Key $S) }
  $node = $reg.stories.$S
  $result.env = "$($node.env)"

  # Shared discovery (StoryLib): only real git worktrees count as apps. A hand-made dir such as
  # EH7-8934\logs\ used to be diffed as an app, note 'not a live git worktree', and flip the whole
  # story to ok:false - a healthy story reported as failed.
  $discovery = Get-StoryFolders -Root $Root -Story $S -Node $node
  $storyDir  = $discovery.storyDir
  $appList   = @($discovery.apps.Keys | Sort-Object)
  $result.extras = @($discovery.extras)
  if ($appList.Count -eq 0) { throw "story '$S' has no apps and no worktrees under $storyDir" }

  $allLayers = @{}
  foreach ($app in $appList) {
    $wt = Join-Path $storyDir $app
    $row = [ordered]@{ app = $app; branch = $null; changed = 0; layers = @(); files = @(); note = $null }

    if (-not (Test-Path $wt)) { $row.note = 'no worktree on disk'; $result.apps += [pscustomobject]$row; continue }
    $t = Git-Cap $wt @('rev-parse', '--is-inside-work-tree')
    if ($t.code -ne 0 -or $t.out.Trim() -ne 'true') { $row.note = 'not a live git worktree'; $result.apps += [pscustomobject]$row; continue }

    # Use the ACTUAL checked-out branch, not the registry's 'branch' field - EH7-8278 legitimately
    # sits on <branch>-restore after a revert-the-revert recovery.
    $row.branch = (Git-Cap $wt @('rev-parse', '--abbrev-ref', 'HEAD')).out.Trim()

    # Diff from the MERGE BASE and include the working tree + untracked files: testplan runs BEFORE
    # commit-push, so a "$Base...HEAD" range diff is blind to work that is still uncommitted.
    $mb = Git-Cap $wt @('merge-base', $Base, 'HEAD')
    if ($mb.code -ne 0) {
      $row.note = "merge-base against $Base failed (fetch first?): $(Get-GitError $wt @('merge-base', $Base, 'HEAD'))"
      $result.apps += [pscustomobject]$row; continue
    }
    $mbSha = $mb.out.Trim()
    # Nothing here fetches (a network call would make the tool fail offline), so $Base can be
    # stale and silently widen the diff with other people's changes. Surface the base's age instead
    # of hiding it: an old baseDate is the tell that 'git fetch origin' is overdue.
    $row.baseSha  = $mbSha.Substring(0, [Math]::Min(8, $mbSha.Length))
    $row.baseDate = (Git-Cap $wt @('show', '-s', '--format=%ci', $mbSha)).out.Trim()
    $d = Git-Cap $wt @('diff', '--name-only', $mbSha)               # committed + uncommitted, vs merge base
    if ($d.code -ne 0) {
      $row.note = "diff against $Base failed: $(Get-GitError $wt @('diff', '--name-only', $mbSha))"
      $result.apps += [pscustomobject]$row; continue
    }
    $u = Git-Cap $wt @('ls-files', '--others', '--exclude-standard') # new files not yet added
    $raw = @(($d.out -split "`r?`n") + ($u.out -split "`r?`n"))
    # .env is local dev pointing, never committed - it must not drive the test plan
    $files = @($raw | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '.env' } | Sort-Object -Unique)
    $row.changed = $files.Count
    if ($files.Count -eq 0) {
      # Real and common: the app's work is already merged into main (released), so there is
      # nothing left in this branch to verify for it.
      $row.note = "no diff vs $Base - already merged, or no work in this app"
      $result.apps += [pscustomobject]$row; continue
    }

    $byLayer = @{}
    foreach ($f in $files) {
      $l = Get-Layer $f
      if (-not $byLayer.ContainsKey($l)) { $byLayer[$l] = @() }
      $byLayer[$l] += $f
      if ($l -ne 'generated') { $allLayers[$l] = $true }
    }
    $row.layers = @($byLayer.Keys | Sort-Object)
    $row.files = $byLayer
    $result.apps += [pscustomobject]$row
  }

  $result.layers = @($allLayers.Keys | Sort-Object)
  $L = { param($x) $allLayers.ContainsKey($x) }

  # ---- traps: what this COMBINATION of layers implies. The whole point of the script.
  $behaviourLayers = @('api', 'data-access', 'service', 'db-script', 'data-shape', 'pipeline')
  $touchedBehaviour = @($behaviourLayers | Where-Object { $allLayers.ContainsKey($_) })

  if (($allLayers.ContainsKey('ui') -or $allLayers.ContainsKey('ui-logic')) -and $touchedBehaviour.Count -eq 0) {
    $result.flags += @{
      severity = 'high'
      flag     = 'UI-only change'
      detail   = 'UI/UI-logic changed but no API, service, repository, model or db_script did. If this change is supposed to STORE or CHANGE data, rendering it correctly proves nothing. Verify at the data layer: reload the page, and query the table. This is the exact shape of the finance_rate_type_cd rework (UI updated, reporting.finance_rate never populated).'
    }
  }
  if ($allLayers.ContainsKey('db-script') -and -not ($allLayers.ContainsKey('api') -or $allLayers.ContainsKey('data-access') -or $allLayers.ContainsKey('pipeline'))) {
    $result.flags += @{
      severity = 'medium'; flag = 'DB script with no reader'
      detail   = 'A db_script changed but no repository/API code reads it. Confirm something actually consumes the new schema/rows, or that the script is intentionally standalone (seed/backfill).'
    }
  }
  if ($allLayers.ContainsKey('data-shape')) {
    $result.flags += @{
      severity = 'medium'; flag = 'Serialization risk'
      detail   = 'DTO/model/entity changed. Check the wire format explicitly - datetime rendering, nulls, and array-vs-scalar. The report notes real causes were "datetime serialization, a BOM, and a bare-string apps field", none of which a happy-path click would catch.'
    }
  }
  if ($allLayers.ContainsKey('bruno')) {
    $result.flags += @{
      severity = 'high'; flag = 'Bruno fixture changed'
      detail   = 'Read the fixture ids/values before trusting a pass. A wrong id yields a FALSE PASS - the IDOR test passed only because victimId was set to the attacker own id.'
    }
  }
  if ($allLayers.ContainsKey('env-config')) {
    $result.flags += @{
      severity = 'medium'; flag = 'Env config changed'
      detail   = 'A committed devops/environments yaml is not a live value. Confirm the key exists in the DEPLOYED target env (and in k8s secrets if it is marked InSecrets) before calling this verified.'
    }
  }
  if ($allLayers.ContainsKey('di-wiring')) {
    $result.flags += @{
      severity = 'low'; flag = 'DI wiring changed'
      detail   = 'Containers changed - confirm the app boots. Note the report warns against ASSUMING DI is the root cause of a bug; here it is simply a startup check.'
    }
  }
  if ($result.layers.Count -gt 0 -and -not $allLayers.ContainsKey('test')) {
    $result.flags += @{
      severity = 'low'; flag = 'No test changed'
      detail   = 'No test file changed anywhere in this story. If a bug was fixed, consider a reproduction test that fails without the fix.'
    }
  }

  # ---- render
  $lines = @()
  $lines += "# Manual test plan - $S"
  $lines += ""
  $lines += "> Generated by ``tools\story-testplan.ps1`` from the real diff vs ``$Base``. It lists what"
  $lines += "> MUST be verified and where. The Action / Expected-result steps are written on top of this"
  $lines += "> (see ``/story-test``), because intent cannot be derived from a diff."
  $lines += ""
  $lines += "- **Story:** $S - $($node.title)"
  $lines += "- **Env:** $($node.env)   **Registry branch:** $($node.branch)"
  if ($node.rel) { $lines += "- **REL:** $($node.rel)" }
  $lines += "- **Layers touched:** $(if($result.layers.Count){ ($result.layers -join ', ') } else { 'none' })"
  $lines += ""

  $lines += "## Changed surface per app"
  $lines += ""
  $lines += "| app | branch | files | layers |"
  $lines += "|---|---|---|---|"
  foreach ($a in $result.apps) {
    $lay = if ($a.layers.Count) { ($a.layers -join ', ') } else { '-' }
    $br = if ($a.branch) { $a.branch } else { '-' }
    $lines += "| $($a.app) | $br | $($a.changed) | $lay |"
  }
  $lines += ""
  foreach ($a in $result.apps) {
    if ($a.note) { $lines += "- **$($a.app)**: $($a.note)" }
  }
  $lines += ""

  if ($result.flags.Count) {
    $lines += "## Traps this diff implies"
    $lines += ""
    foreach ($f in ($result.flags | Sort-Object { switch ($_.severity) { 'high' { 0 } 'medium' { 1 } default { 2 } } })) {
      $lines += "- **[$($f.severity.ToUpper())] $($f.flag)** - $($f.detail)"
    }
    $lines += ""
  }

  if ($result.layers.Count) {
    $lines += "## Required verification, by layer"
    $lines += ""
    foreach ($l in $result.layers) {
      $v = if ($LayerVerification.Contains($l)) { $LayerVerification[$l] } else { $LayerVerification['other'] }
      $lines += "### $l"
      $lines += "$v"
      $ex = @()
      foreach ($a in $result.apps) {
        if ($a.files -and $a.files.ContainsKey($l)) {
          foreach ($f in ($a.files[$l] | Select-Object -First 4)) { $ex += "``$($a.app)/$f``" }
        }
      }
      if ($ex.Count) { $lines += "" ; $lines += "Changed here: $($ex -join ', ')" }
      $lines += ""
    }
  }

  $lines += "## Steps"
  $lines += ""
  $lines += "<!-- Filled in by /story-test from the Jira acceptance criteria + the sections above."
  $lines += "     Format is deliberately AgileTest-shaped: one Action + one Expected result per step,"
  $lines += "     so the list can be used verbatim at ganesha-release Gate B. -->"
  $lines += ""
  $lines += "| # | Action | Expected result |"
  $lines += "|---|---|---|"
  $lines += "| 1 | _pending_ | _pending_ |"
  $lines += ""
  $lines += "## Re-break check"
  $lines += ""
  $lines += "After everything passes, deliberately break the thing this story fixed and confirm the"
  $lines += "failure reappears. A test or check that cannot fail has not proven anything."
  $lines += ""

  $md = ($lines -join "`r`n")
  $outPath = if ($Out) { $Out } else { Join-Path $storyDir 'MANUAL-TEST.md' }
  $result.output = $outPath

  # Only a BROKEN READ fails the run. 'already merged' and 'no worktree on disk' are both normal
  # states (a released app; an app listed in the node whose worktree was already torn down) - they
  # used to flip ok:false and make /story-test look like it had failed on a healthy story.
  $bad = @($result.apps | Where-Object { $_.note -and $_.note -match 'failed|unreadable|not a live git worktree' })
  if ($bad.Count) { $result.ok = $false }
  $totalChanged = ($result.apps | Measure-Object -Property changed -Sum).Sum
  $result.summary = "$S : $totalChanged changed file(s) across $(@($result.apps | Where-Object { $_.changed -gt 0 }).Count) app(s); $($result.layers.Count) layer(s); $($result.flags.Count) trap(s)"

  if (-not $NoWrite) {
    if (-not (Test-Path $storyDir)) { throw "story folder not found: $storyDir" }
    [IO.File]::WriteAllText($outPath, $md, (New-Object System.Text.UTF8Encoding $false))
    # This script IS the testplan phase - stamp it rather than relying on the caller to remember.
    try {
      $ledScript = Join-Path $PSScriptRoot 'story-ledger.ps1'
      if (Test-Path -LiteralPath $ledScript) {
        [void](& $ledScript done 'testplan' -Story $S -Artifacts $outPath -Root $Root -Json)
        $result.ledger = 'testplan -> done'
      }
    }
    catch { $result.ledger = "not recorded: $($_.Exception.Message)" }
  }

  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)); return }

  # Default console output is a digest, not the whole document - the file already holds that.
  # Use -Full to dump the markdown (e.g. when not writing it anywhere).
  Write-Host ""
  if ($Full -or $NoWrite) { Write-Host $md; Write-Host "" }
  else {
    Write-Host "$S [$($node.env)]  $($node.title)" -ForegroundColor Cyan
    Write-Host ""
    $fmt = "{0,-26} {1,-34} {2,-6} {3}"
    Write-Host ($fmt -f 'app', 'branch', 'files', 'layers') -ForegroundColor White
    Write-Host ($fmt -f ('-' * 26), ('-' * 34), ('-' * 6), ('-' * 30)) -ForegroundColor DarkGray
    foreach ($a in $result.apps) {
      $lay = if ($a.layers.Count) { ($a.layers | Where-Object { $_ -ne 'generated' }) -join ',' } else { '-' }
      $br = if ($a.branch) { $a.branch } else { '-' }
      $col = if ($a.changed -gt 0) { 'Green' } else { 'DarkGray' }
      Write-Host ($fmt -f $a.app, $br, $a.changed, $lay) -ForegroundColor $col
      if ($a.note) { Write-Host "    $($a.note)" -ForegroundColor DarkGray }
    }
    if ($result.flags.Count) {
      Write-Host ""
      foreach ($f in ($result.flags | Sort-Object { switch ($_.severity) { 'high' { 0 } 'medium' { 1 } default { 2 } } })) {
        $c = switch ($f.severity) { 'high' { 'Yellow' } 'medium' { 'DarkYellow' } default { 'DarkGray' } }
        Write-Host "  [$($f.severity)] $($f.flag)" -ForegroundColor $c
      }
    }
    Write-Host ""
    Write-Host "written: $outPath" -ForegroundColor Green
    Write-Host "next: /story-test  (fills the Steps table from the Jira acceptance criteria)" -ForegroundColor DarkCyan
  }
  Write-Host $result.summary -ForegroundColor Cyan
  Write-Host ""
}
catch {
  $result.ok = $false
  $result.error = "story-testplan error: $($_.Exception.Message)"
  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)) }
  else { Write-Host "`n$($result.error)`n" -ForegroundColor Red }
}
