#requires -Version 5.1
<#
  story-ledger.ps1 - per-story phase state, so "where is this story?" is a read, not a re-derivation.

  Implement takes days and spans many sessions, and that is exactly where state gets lost today
  (prep release stalling on "release/REL-XXXX doesn't exist" until you say "try again"; sessions
  ending at a question with work half-finished). This records what each phase produced.

  Store: <root>\<STORY>\.story-ship-state.json
  That is the STORY folder, deliberately OUTSIDE every repo - a state file inside a worktree would
  show up in 'git status --porcelain' and become a remove-worktree.ps1 blocker, since Get-Blockers
  only ever exempts $LocalArtifacts (.env / logging.ini). remove-worktree.ps1 folds this file into
  the stories_history.json record before deleting the story folder, so the history survives.

  Usage:
    story-ledger.ps1 <action> [phase] [STORY] [-Story S] [-Artifacts "a;b"] [-Links "u;v"] [-Message m] [-Json]

  actions:
    init            create the ledger if absent (idempotent - never clobbers existing state)
    start <phase>   status=running, stamp started_at, attempts++
    done  <phase>   status=done,   stamp ended_at, merge -Artifacts / -Links
    fail  <phase>   status=failed, record -Message as last_error
    skip  <phase>   status=skipped (deliberately not applicable to this story)
    reset [<phase>] back to pending (one phase, or all when omitted)
    sync            seed phase status from stories.json node fields (rel -> rel-ticket, etc.)
    next            print the RESUME POINTER (see below)
    tracker         grouped Story Up / Dev Loop / Prep Release checklist (the chat-facing view)
    table           markdown: phase | status | artifacts | links
    show            human digest (default)

  The resume pointer is "first phase that is not done/skipped AFTER the furthest one that IS" -
  not simply the first incomplete phase. A story whose REL phases are done but whose early phases
  were never recorded (common for stories that predate the ledger) must NOT be sent back to
  bring-up; it reports the open earlier phases as a warning instead.

  Retries are NOT handled here: a script cannot retry an MCP call or a gh invocation. This records
  'attempts' and 'last_error'; the 3-attempt exponential-backoff policy lives in the command text.

  Always exits 0; success is carried in the 'ok' field, matching the other tools here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'show',
  [Parameter(Position = 1)] [string]$Phase,
  [Parameter(Position = 2)] [string]$StoryPositional,
  [string]$Story,
  [string]$Artifacts,
  [string]$Links,
  [string]$Message,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  # Swallow stray positionals instead of dying with a PositionalParameterNotFound binding error
  # before the try block can produce a JSON frame. Reported as ok:false below.
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
$Root         = $Paths.Root
$LedgerName   = '.story-ship-state.json'
$AllowedActions = @('init', 'start', 'done', 'fail', 'skip', 'reset', 'sync', 'next', 'tracker', 'table', 'show')

Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

# The lifecycle phases that actually exist today. 'resolve' and 'worktree' are deliberately absent:
# the ledger lives in the story folder, which does not exist until the worktree is created, so
# those two are inherently pre-ledger. 'group' drives the tracker view - keep it on every phase.
$DefaultPhases = @(
  @{ name = 'bring-up';        group = 'Story Up';     hint = '/story-up - deps, .env, apps healthy' }
  @{ name = 'plan';            group = 'Dev Loop';     hint = 'analyze:: / plan:: / artifact (human)' }
  @{ name = 'implement';       group = 'Dev Loop';     hint = 'the actual change (human)' }
  @{ name = 'testplan';        group = 'Dev Loop';     hint = '/story-test - MANUAL-TEST.md + AgileTest steps' }
  @{ name = 'verify';          group = 'Dev Loop';     hint = 'run the manual test plan (human) / /qa' }
  @{ name = 'typecheck';       group = 'Dev Loop';     hint = 'npx tsc --noEmit / python -m py_compile' }
  @{ name = 'commit-push';     group = 'Dev Loop';     hint = 'commit + push the feature branch' }
  @{ name = 'release-notes';   group = 'Prep Release'; hint = 'prep release Gate A - customfield_10217' }
  @{ name = 'rel-ticket';      group = 'Prep Release'; hint = 'SCERN REL + issue links' }
  @{ name = 'agiletest';       group = 'Prep Release'; hint = 'prep release Gate B - TESTLIB TestCase + steps' }
  @{ name = 'release-branch';  group = 'Prep Release'; hint = 'MANUAL - the user creates release/REL-XXXX' }
  @{ name = 'release-prs';     group = 'Prep Release'; hint = 'gh pr create per app into the release branch' }
  @{ name = 'chg';             group = 'Prep Release'; hint = 'ServiceNow CHG raised (chg_number on the node)' }
  @{ name = 'deploy';          group = 'Prep Release'; hint = 'deployed + verified on the target env' }
)
$PhaseNames  = @($DefaultPhases | ForEach-Object { $_.name })
$GroupOrder  = @('Story Up', 'Dev Loop', 'Prep Release')

# A story key can arrive in the third positional slot ('done bring-up EH7-9550'), which is the form
# the story-ship command documents. Prefer an explicit -Story.
if (-not $Story -and $StoryPositional) { $Story = $StoryPositional }

# An action can arrive in the phase slot, or a phase in the action slot for bare reads.
if ($Phase -in $AllowedActions -and $Action -notin $AllowedActions) { $swap = $Action; $Action = $Phase; $Phase = $swap }
# 'init EH7-9170' / 'table kuber-partner-date' - a STORY key in the phase slot is the story, matching
# how story-env.ps1 and story-testplan.ps1 both take the story positionally. Phase names are
# themselves slug-shaped, so a known phase name always wins over the story-key reading.
if ($Phase -and $PhaseNames -notcontains $Phase -and (Test-StoryKey $Phase)) {
  if (-not $Story) { $Story = $Phase }
  $Phase = $null
}

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  else { Write-Host $o.summary }
}

if ($Action -notin $AllowedActions) {
  Out-Result @{ ok = $false; error = "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  return
}
if ($Extra) {
  Out-Result @{ ok = $false; error = ("unexpected extra argument(s): " + (@($Extra) -join ' ') + ". Usage: story-ledger.ps1 <action> [phase] [STORY]") }
  return
}

function Resolve-Story([string]$S, $reg) {
  if ($S) {
    $k = Resolve-RegistryKey -Registry $reg -Key $S
    if ($k) { return $k }
    return $S   # not in the registry - let the caller raise the clearer "not in stories.json"
  }
  $inferred = Resolve-StoryFromPath -Root $Root -Registry $reg
  if ($inferred) { return $inferred }
  throw "Could not infer the story from cwd '$((Get-Location).Path)'. Pass it: story-ledger.ps1 $Action -Story <STORY>"
}

function New-PhaseNode($p) {
  [pscustomobject]@{
    name = $p.name; hint = $p.hint; status = 'pending'
    started_at = $null; ended_at = $null; attempts = 0
    artifacts = @(); links = @(); last_error = $null
  }
}

function New-Ledger([string]$S, $node) {
  $phases = @(); foreach ($p in $DefaultPhases) { $phases += New-PhaseNode $p }
  return [pscustomobject]@{
    story = $S; env = "$($node.env)"; branch = "$($node.branch)"; title = "$($node.title)"
    created_at = (Get-Stamp); updated_at = (Get-Stamp); phases = $phases
  }
}

function Get-PhaseNode($led, [string]$name) {
  return ($led.phases | Where-Object { $_.name -eq $name } | Select-Object -First 1)
}

# The resume pointer. Resume AFTER the furthest done/skipped phase, so a story that is already
# released is never sent back to bring-up just because an early phase was never recorded.
# Phases left open BEFORE that point are reported, not rewound to.
function Get-NextInfo($led) {
  $ph = @($led.phases)
  $closed = @('done', 'skipped')
  $lastClosed = -1
  for ($i = 0; $i -lt $ph.Count; $i++) { if ($ph[$i].status -in $closed) { $lastClosed = $i } }
  $next = $null
  for ($i = $lastClosed + 1; $i -lt $ph.Count; $i++) {
    if ($ph[$i].status -notin $closed) { $next = $ph[$i].name; break }
  }
  $openBefore = @()
  for ($i = 0; $i -lt $lastClosed; $i++) { if ($ph[$i].status -notin $closed) { $openBefore += $ph[$i].name } }
  [pscustomobject]@{ next = $next; openBefore = @($openBefore) }
}

# ---- tracker: the grouped, chat-facing checklist ----------------------------------------------
# ASCII markers on purpose: this block is printed verbatim into chat AND into a PS 5.1 console AND
# travels through the extension's native-messaging host. Emoji would mojibake in at least one.
function Get-Glyph([string]$status, [bool]$isNext) {
  switch ($status) {
    'done'    { '[x]' }
    'failed'  { '[!]' }
    'skipped' { '[-]' }
    'running' { '[>]' }
    default   { if ($isNext) { '[>]' } else { '[ ]' } }
  }
}

function Get-Tracker($led, [string]$next) {
  # Map phase name -> group from $DefaultPhases; a phase this build doesn't know (an older ledger,
  # or one appended later) inherits the group of the previous phase rather than vanishing.
  $groupOf = @{}; foreach ($p in $DefaultPhases) { $groupOf[$p.name] = $p.group }
  $lastGroup = $GroupOrder[0]
  $rows = @()
  foreach ($pn in @($led.phases)) {
    $g = if ($groupOf.ContainsKey($pn.name)) { $groupOf[$pn.name] } else { $lastGroup }
    $lastGroup = $g
    $rows += [pscustomobject]@{ group = $g; name = $pn.name; status = $pn.status; isNext = ($pn.name -eq $next) }
  }

  $groups = @()
  $seen = @($rows | ForEach-Object { $_.group } | Select-Object -Unique)
  $ordered = @(@($GroupOrder | Where-Object { $seen -contains $_ }) + @($seen | Where-Object { $GroupOrder -notcontains $_ }))
  foreach ($g in $ordered) {
    $mine = @($rows | Where-Object { $_.group -eq $g })
    $done = @($mine | Where-Object { $_.status -in @('done', 'skipped') }).Count
    $gs =
      if (@($mine | Where-Object { $_.status -eq 'failed' }).Count) { 'failed' }
      elseif ($done -eq $mine.Count) { 'done' }
      elseif (@($mine | Where-Object { $_.isNext -or $_.status -in @('running', 'done', 'skipped') }).Count) { 'running' }
      else { 'pending' }
    $groups += [pscustomobject]@{
      name = $g; status = $gs; done = $done; total = $mine.Count
      phases = @($mine | ForEach-Object { [pscustomobject]@{ name = $_.name; status = $_.status } })
    }
  }
  return @($groups)
}

function Write-TrackerBlock($led, $groups, [string]$next, $openBefore) {
  $head = "$($led.story)"
  if ($led.env) { $head += " - $($led.env)" }
  if ($led.title) { $head += " - $($led.title)" }
  Write-Host ""
  Write-Host $head
  foreach ($g in $groups) {
    $gGlyph = Get-Glyph $g.status $false
    $label = if ($g.status -eq 'done') { $g.name } else { "$($g.name) $($g.done)/$($g.total)" }
    $detail = @(@($g.phases) | ForEach-Object {
      $isNext = ($_.name -eq $next)
      "$($_.name) $(Get-Glyph $_.status $isNext)"
    }) -join ' . '
    Write-Host ("{0} {1,-18} {2}" -f $gGlyph, $label, $detail)
  }
  Write-Host ""
  if ($next) { Write-Host "next: $next" } else { Write-Host "next: all phases done" }
  if (@($openBefore).Count) {
    Write-Host ("warning: later phases are already done, but these were never recorded: " + (@($openBefore) -join ', '))
  }
  Write-Host ""
}

# ---- sync: seed phases from what the stories.json node already proves happened -----------------
# The node and the ledger drift because most release work is recorded on the node (rel, chg_number,
# releaseBranch, document) by flows that predate the ledger. This makes the ledger the
# reconciliation point instead of a rule the operator has to remember.
function Invoke-Sync($led, $node) {
  $seeded = @()
  $map = @(
    @{ phase = 'plan';            value = @($node.document, $node.document_keycloak_setup) }
    @{ phase = 'rel-ticket';      value = @($node.rel) }
    @{ phase = 'release-branch';  value = @($node.releaseBranch) }
    @{ phase = 'agiletest';       value = @($node.agiletest_url) + @(if ($node.agiletest_urls) { $node.agiletest_urls.PSObject.Properties.Value } else { @() }) }
    @{ phase = 'chg';             value = @($node.chg_number) + @(if ($node.chg_numbers) { $node.chg_numbers.PSObject.Properties.Value } else { @() }) }
  )
  foreach ($m in $map) {
    $vals = @($m.value | Where-Object { $_ -and "$_".Trim() })
    if (-not $vals.Count) { continue }
    $pn = Get-PhaseNode $led $m.phase
    if (-not $pn -or $pn.status -ne 'pending') { continue }   # never clobber recorded progress
    $pn.status = 'done'; $pn.ended_at = (Get-Stamp)
    if (-not $pn.started_at) { $pn.started_at = (Get-Stamp) }
    if ($pn.attempts -lt 1) { $pn.attempts = 1 }
    $links = @($vals | Where-Object { "$_" -match '^https?://' })
    $arts  = @($vals | Where-Object { "$_" -notmatch '^https?://' })
    if ($arts.Count)  { $pn.artifacts = @(@($pn.artifacts) + $arts  | Select-Object -Unique) }
    if ($links.Count) { $pn.links     = @(@($pn.links)     + $links | Select-Object -Unique) }
    $pn.last_error = 'seeded by sync from the stories.json node'
    $seeded += $m.phase
  }
  return @($seeded)
}

$result = [ordered]@{ ok = $true; action = $Action; story = $null; path = $null; next = $null
  warning = $null; groups = @(); phases = @(); summary = '' }

try {
  $reg = Read-Registry -Root $Root
  $S = Resolve-Story $Story $reg
  $result.story = $S
  if (-not (Resolve-RegistryKey -Registry $reg -Key $S)) { throw (Get-MissingStoryHint -Root $Root -Key $S) }
  $node = $reg.stories.$S

  # A story's worktrees live under ITS OWN recorded worktreeRoot (set only when it differs from
  # Root at creation time - see switch-story.ps1's Invoke-New), never the current global setting -
  # same "read the node's own field" rule every other worktree-aware command follows (CLAUDE.md's
  # Migration safety section). Without this, a worktreeRoot-configured install always looked in
  # $Root\$S, found nothing, and threw "story folder not found" here - which, before the caller-side
  # fix, also corrupted whichever script called this one in-process.
  $effRoot = if ($node.worktreeRoot) { [string]$node.worktreeRoot } else { $Root }
  $storyDir = Join-Path $effRoot $S
  if (-not (Test-Path -LiteralPath $storyDir)) { throw "story folder not found: $storyDir (create the worktree first)" }
  $ledPath = Join-Path $storyDir $LedgerName
  $result.path = $ledPath

  $existed = Test-Path -LiteralPath $ledPath
  $led = if ($existed) { Read-JsonFile -Path $ledPath } else { New-Ledger $S $node }

  # Adopt phases added to $DefaultPhases after this ledger was created, without losing state.
  if ($existed) {
    $have = @($led.phases | ForEach-Object { $_.name })
    foreach ($p in $DefaultPhases) {
      if ($have -notcontains $p.name) { $led.phases = @($led.phases) + (New-PhaseNode $p) }
    }
  }

  $mutating = $Action -in @('init', 'start', 'done', 'fail', 'skip', 'reset', 'sync')
  $needsPhase = $Action -in @('start', 'done', 'fail', 'skip')
  if ($needsPhase -and -not $Phase) { throw "action '$Action' needs a phase name. One of: $($PhaseNames -join ', ')" }
  if ($Phase -and $Action -ne 'init') {
    if (-not (Get-PhaseNode $led $Phase)) { throw "unknown phase '$Phase'. One of: $($PhaseNames -join ', ')" }
  }

  switch ($Action) {
    'init' {
      # Idempotent on purpose: never clobber real progress.
      $result.summary = if ($existed) { "$S : ledger already exists, left untouched" } else { "$S : ledger created with $(@($led.phases).Count) phases" }
    }
    'start' {
      $pn = Get-PhaseNode $led $Phase
      $pn.status = 'running'; $pn.started_at = (Get-Stamp); $pn.attempts = [int]$pn.attempts + 1
      $result.summary = "$S : $Phase -> running (attempt $($pn.attempts))"
    }
    'done' {
      $pn = Get-PhaseNode $led $Phase
      $pn.status = 'done'; $pn.ended_at = (Get-Stamp); $pn.last_error = $null
      if (-not $pn.started_at) { $pn.started_at = (Get-Stamp) }
      if ($pn.attempts -lt 1) { $pn.attempts = 1 }
      if ($Artifacts) { $pn.artifacts = @(@($pn.artifacts) + (Split-DelimitedList $Artifacts) | Select-Object -Unique) }
      if ($Links) { $pn.links = @(@($pn.links) + (Split-DelimitedList $Links) | Select-Object -Unique) }
      $result.summary = "$S : $Phase -> done"
    }
    'fail' {
      $pn = Get-PhaseNode $led $Phase
      # 'attempts' counts entries into the phase. A preceding 'start' already counted this one;
      # a bare 'fail' with no start counts itself, so a retry loop that only calls fail still ticks.
      if ($pn.status -ne 'running') { $pn.attempts = [int]$pn.attempts + 1 }
      $pn.status = 'failed'; $pn.ended_at = (Get-Stamp)
      $pn.last_error = if ($Message) { $Message } else { 'unspecified failure' }
      $result.summary = "$S : $Phase -> failed ($($pn.last_error), attempt $($pn.attempts))"
    }
    'skip' {
      $pn = Get-PhaseNode $led $Phase
      $pn.status = 'skipped'; $pn.ended_at = (Get-Stamp)
      if ($Message) { $pn.last_error = $Message }
      $result.summary = "$S : $Phase -> skipped"
    }
    'reset' {
      $targets = if ($Phase) { @(Get-PhaseNode $led $Phase) } else { @($led.phases) }
      foreach ($pn in $targets) {
        $pn.status = 'pending'; $pn.started_at = $null; $pn.ended_at = $null
        $pn.attempts = 0; $pn.artifacts = @(); $pn.links = @(); $pn.last_error = $null
      }
      $result.summary = "$S : reset $(@($targets).Count) phase(s)"
    }
    'sync' {
      $seeded = Invoke-Sync $led $node
      $result.summary = if ($seeded.Count) { "$S : seeded $($seeded.Count) phase(s) from the node - $($seeded -join ', ')" }
                        else { "$S : nothing to seed (node fields already match the ledger)" }
    }
  }

  if ($mutating) {
    $led.updated_at = (Get-Stamp)
    Write-JsonFile -Path $ledPath -Obj $led -Depth 10
  }

  $ni = Get-NextInfo $led
  $result.next = $ni.next
  if (@($ni.openBefore).Count) { $result.warning = "later phases already done; never recorded: $(@($ni.openBefore) -join ', ')" }
  $result.phases = @($led.phases)
  $result.groups = Get-Tracker $led $ni.next

  # ---- output ----
  if ($Action -eq 'next') {
    $result.summary = if ($result.next) { $result.next } else { 'all phases done' }
    if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)); return }
    Write-Host $result.summary
    if ($result.warning) { Write-Host "warning: $($result.warning)" -ForegroundColor Yellow }
    return
  }

  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)); return }

  if ($Action -eq 'tracker') {
    Write-TrackerBlock $led $result.groups $result.next $ni.openBefore
    return
  }

  if ($Action -eq 'table') {
    # The 'phase | status | artifacts | links' table that closes out a story.
    Write-Host ""
    Write-Host "| phase | status | artifacts | links |"
    Write-Host "|---|---|---|---|"
    foreach ($pn in $led.phases) {
      $a = if (@($pn.artifacts).Count) { (@($pn.artifacts) -join '<br>') } else { '-' }
      $l = if (@($pn.links).Count) { (@($pn.links) -join '<br>') } else { '-' }
      Write-Host "| $($pn.name) | $($pn.status) | $a | $l |"
    }
    Write-Host ""
    return
  }

  # show / init / mutations: a compact digest
  Write-Host ""
  Write-Host "$S [$($led.env)]  $($led.title)" -ForegroundColor Cyan
  Write-Host ""
  $fmt = "  {0,-16} {1,-9} {2,-4} {3}"
  Write-Host ($fmt -f 'phase', 'status', 'try', 'artifacts / error') -ForegroundColor White
  Write-Host ($fmt -f ('-' * 16), ('-' * 9), ('-' * 4), ('-' * 40)) -ForegroundColor DarkGray
  foreach ($pn in $led.phases) {
    $extra = @()
    if (@($pn.artifacts).Count) { $extra += (@($pn.artifacts) -join ', ') }
    if (@($pn.links).Count) { $extra += (@($pn.links) -join ', ') }
    if ($pn.last_error -and $pn.status -eq 'failed') { $extra += "ERR: $($pn.last_error)" }
    $col = switch ($pn.status) {
      'done' { 'Green' } 'running' { 'Cyan' } 'failed' { 'Red' } 'skipped' { 'DarkGray' } default { 'DarkGray' }
    }
    Write-Host ($fmt -f $pn.name, $pn.status, $pn.attempts, ($extra -join ' | ')) -ForegroundColor $col
  }
  Write-Host ""
  if ($result.next) { Write-Host "next: $($result.next)" -ForegroundColor DarkCyan }
  else { Write-Host "all phases done" -ForegroundColor Green }
  if ($result.warning) { Write-Host "warning: $($result.warning)" -ForegroundColor Yellow }
  if ($result.summary) { Write-Host $result.summary -ForegroundColor DarkGray }
  Write-Host ""
}
catch {
  $result.ok = $false
  $result.error = "story-ledger error: $($_.Exception.Message)"
  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)) }
  else { Write-Host "`n$($result.error)`n" -ForegroundColor Red }
}
