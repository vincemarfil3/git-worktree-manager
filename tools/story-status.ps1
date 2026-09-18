#requires -Version 5.1
<#
  story-status.ps1 - the EOD status report, derived instead of remembered.

  Engineering wants one line per workstream in #eng-status-input before 21:45 UTC. Nearly all of
  that is already on disk: stories.json (title, env, apps, REL/CHG, dated log[]), each story's
  .story-ship-state.json ledger (phase ended_at + artifacts[]), and the git worktrees. This turns
  those three streams into the literal block to paste, diffed against the last thing that was sent.

  What it deliberately does NOT do: post to #eng-status-input. Delivery is a DM/toast reminder to
  Vince; sending the real message is always a human action.

  Cutoff maths: local tz is UTC+8 and neither it nor UTC observes DST, so the 21:45 UTC cutoff is
  always 05:45 local. A "report period" therefore runs from one 05:45 to the next.

  Usage:
    story-status.ps1 collect [-Since "yyyy-MM-dd HH:mm"] [-Json]
    story-status.ps1 draft   [-Since ...] [-Json]
    story-status.ps1 set     -Story K [-Workstream w] [-Status s] [-NextDate d] [-BlockedBy b] [-Json]
    story-status.ps1 note    "<text>" [-Story K] [-Json]
    story-status.ps1 mark    -Text "<the block that was sent>" [-Json]
    story-status.ps1 notify  [-Tier early|final] [-Json]
    story-status.ps1 slack-test [-Json]

  Always exits 0; success is carried in the 'ok' field.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'draft',
  [Parameter(Position = 1)] [string]$Arg1,
  [string]$Story,
  [string]$Since,
  [string]$Workstream,
  [string]$Status,
  [string]$NextDate,
  [string]$BlockedBy,
  [string]$Text,
  [string]$PostedAt,
  [ValidateSet('early', 'final')] [string]$Tier = 'final',
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
$OrgDefaults    = Get-StgOrgDefaults
$Root           = $Paths.Root
$LedgerName     = '.story-ship-state.json'
$NotesDir       = Join-Path $Root 'notes'
$LogPath        = Join-Path $NotesDir 'status-log.json'
$DraftPath      = Join-Path $NotesDir 'eod-draft.md'
# Falls back to the legacy ~\.ganesha if that's what already exists, so an existing Slack
# token/config is never orphaned by the rename to ~\.story-tab-groups.
$CfgDir         = Get-StgOwnerConfigDir
$TokenPath      = Join-Path $CfgDir 'slack-token.xml'
$SlackCfgPath   = Join-Path $CfgDir 'slack.json'
$Owner          = $OrgDefaults.Owner
$CutoffHour     = 5
$CutoffMinute   = 45
# The report PERIOD boundary is noon, deliberately NOT the 05:45 cutoff. The working day runs
# evening -> early morning, so a session and the post that closes it straddle midnight. Anchoring
# the period at the cutoff meant a post at 05:47 (two minutes late) counted against the NEXT day
# and silenced the following night's reminders. Noon is the one hour nobody is posting.
$PeriodBoundaryHour = 12
$AllowedActions = @('collect', 'draft', 'set', 'note', 'mark', 'notify', 'slack-test')

Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 10 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  elseif ($o.block) { Write-Host $o.block }
  else { Write-Host $o.summary }
}

function ConvertTo-Stamp([string]$s) {
  if (-not $s) { return $null }
  $dt = [datetime]::MinValue
  $ci = [Globalization.CultureInfo]::InvariantCulture
  if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm', $ci, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
  if ([datetime]::TryParse($s, [ref]$dt)) { return $dt }
  return $null
}

# Start of the current report period: the most recent noon. One work session (evening through the
# next early morning) plus the post that closes it always land in the same window.
function Get-PeriodStart {
  $now = Get-Date
  $b = Get-Date -Hour $PeriodBoundaryHour -Minute 0 -Second 0 -Millisecond 0
  if ($now -ge $b) { return $b }
  return $b.AddDays(-1)
}

function Read-StatusLog {
  $o = $null
  if (Test-Path -LiteralPath $LogPath) { try { $o = Read-JsonFile -Path $LogPath } catch {} }
  if (-not $o) { $o = [pscustomobject]@{ last_posted = ''; posts = @(); notes = @() } }
  foreach ($f in @('last_posted', 'posts', 'notes')) {
    if (@($o.PSObject.Properties.Name) -notcontains $f) {
      $v = if ($f -eq 'last_posted') { '' } else { @() }
      $o | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
    }
  }
  return $o
}

function Write-StatusLog($o) {
  if (-not (Test-Path -LiteralPath $NotesDir)) { New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null }
  Write-JsonFile -Path $LogPath -Obj $o -Depth 10
}

function Get-NodeField($Node, [string]$Name) {
  if (@($Node.PSObject.Properties.Name) -contains $Name) { return [string]$Node.$Name }
  return ''
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

# Reuse the ledger's own resume-pointer rule rather than writing a third copy of it. A child
# powershell.exe on purpose: story-ledger writes JSON with [Console]::Out.Write, which bypasses the
# pipeline and would otherwise land in this script's stdout.
function Get-LedgerNext([string]$S) {
  $lscript = Join-Path $PSScriptRoot 'story-ledger.ps1'
  if (-not (Test-Path -LiteralPath $lscript)) { return $null }
  try {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lscript next -Story $S -Root $Root -Json
    $global:LASTEXITCODE = 0
    $txt = ($out | Out-String).Trim()
    if (-not $txt) { return $null }
    $o = $txt | ConvertFrom-Json
    if ($o -and $o.ok) { return [string]$o.next }
  }
  catch {}
  return $null
}

# ---- evidence: the three streams, all filtered to >= $since ------------------------------------
function Get-LedgerDeltas([string]$S, [datetime]$since) {
  $out = @()
  $p = Join-Path (Join-Path $Root $S) $LedgerName
  if (-not (Test-Path -LiteralPath $p)) { return @($out) }
  try { $led = Read-JsonFile -Path $p } catch { return @($out) }
  foreach ($pn in @($led.phases)) {
    $ended = ConvertTo-Stamp ([string]$pn.ended_at)
    if (-not $ended -or $ended -lt $since) { continue }
    if ($pn.status -notin @('done', 'skipped', 'failed')) { continue }
    $arts = @(@($pn.artifacts) | Where-Object { $_ })
    $out += [pscustomobject]@{
      phase = [string]$pn.name; status = [string]$pn.status; ended_at = [string]$pn.ended_at
      artifacts = $arts; last_error = [string]$pn.last_error
    }
  }
  return @($out)
}

function Get-LogDeltas($Node, [datetime]$since) {
  $out = @()
  foreach ($e in @($Node.log)) {
    $ts = ConvertTo-Stamp ([string]$e.ts)
    if (-not $ts -or $ts -lt $since) { continue }
    $out += [pscustomobject]@{ ts = [string]$e.ts; type = [string]$e.type; message = [string]$e.message }
  }
  return @($out)
}

function Get-CommitDeltas([string]$S, $Node, [datetime]$since) {
  $out = @()
  $iso = $since.ToString('yyyy-MM-dd HH:mm:ss')
  foreach ($app in @($Node.apps)) {
    if (-not $app) { continue }
    $wt = Get-WtPath -Root $Root -Story $S -App ([string]$app)
    if (-not (Test-GitWorktree -Dir $wt)) { continue }
    $email = (Invoke-GitCap -Dir $wt -GitArgs @('config', 'user.email')).out
    $gargs = @('log', "--since=$iso", '--no-merges', '--pretty=format:%h%x09%s')
    if ($email) { $gargs += "--author=$email" }
    $r = Invoke-GitCap -Dir $wt -GitArgs $gargs
    if ($r.code -ne 0 -or -not $r.out) { continue }
    foreach ($line in ($r.out -split "`r?`n")) {
      if (-not $line.Trim()) { continue }
      $parts = $line -split "`t", 2
      $out += [pscustomobject]@{ app = [string]$app; sha = $parts[0]; subject = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
    }
  }
  return @($out)
}

# ---- collect -----------------------------------------------------------------------------------
function Invoke-Collect([datetime]$since) {
  $reg = Read-Registry -Root $Root
  $rows = @()
  foreach ($k in @($reg.stories.PSObject.Properties.Name)) {
    $node = $reg.stories.$k
    $ledger  = Get-LedgerDeltas $k $since
    $logs    = Get-LogDeltas $node $since
    $commits = Get-CommitDeltas $k $node $since
    $rows += [pscustomobject]@{
      key              = $k
      workstream       = (Get-NodeField $node 'workstream')
      title            = (Get-NodeField $node 'title')
      env              = (Get-NodeField $node 'env')
      status           = (Get-NodeField $node 'status')
      next_date        = (Get-NodeField $node 'next_date')
      blocked_by       = (Get-NodeField $node 'blocked_by')
      released         = (Get-NodeField $node 'released')
      released_posted  = (Get-NodeField $node 'released_posted')
      workstream_added = (Get-NodeField $node 'workstream_added')
      rel              = (Get-NodeField $node 'rel')
      next             = (Get-LedgerNext $k)
      present          = (Test-Path -LiteralPath (Join-Path $Root $k))
      ledger           = @($ledger)
      logs             = @($logs)
      commits          = @($commits)
      hasChanges       = (@($ledger).Count + @($logs).Count + @($commits).Count) -gt 0
    }
  }
  $slog = Read-StatusLog
  $adhoc = @()
  foreach ($n in @($slog.notes)) {
    $ts = ConvertTo-Stamp ([string]$n.ts)
    if ($ts -and $ts -ge $since) { $adhoc += [string]$n.text }
  }
  return [pscustomobject]@{ since = $since.ToString('yyyy-MM-dd HH:mm'); stories = @($rows); adhoc = @($adhoc) }
}

# ---- draft: collect rendered into the literal block --------------------------------------------
function Get-WorkstreamName($row) {
  if ($row.workstream) { return $row.workstream }
  if ($row.title) { return $row.title }
  return $row.key
}

# One clause, not a changelog. Ledger artifacts read best (they were written as prose), then log
# messages, then commit subjects as the last resort. Artifacts are flattened INDIVIDUALLY - joining
# a phase's whole artifact list into one "bit" made a single phase eat the entire clause.
function Get-ChangeClause($row) {
  $bits = @()
  foreach ($d in @($row.ledger)) {
    # bring-up is local environment noise (ports answered 200). Never status-report material.
    if ($d.phase -eq 'bring-up') { continue }
    $a = @($d.artifacts)
    if ($a.Count) { $bits += $a } else { $bits += "$($d.phase) $($d.status)" }
  }
  foreach ($l in @($row.logs)) {
    if ($l.type -in @('released', 'unreleased', 'note')) { $bits += [string]$l.message }
  }
  if (-not $bits.Count) { $bits += @(@($row.commits) | ForEach-Object { $_.subject }) }
  $bits = @($bits | Where-Object { $_ } | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Select-Object -Unique)
  if (-not $bits.Count) { return 'no change' }
  $show = @($bits | Select-Object -First 2 | ForEach-Object {
    if ($_.Length -gt 70) { $_.Substring(0, 67).TrimEnd() + '...' } else { $_ }
  })
  $clause = $show -join '; '
  if ($bits.Count -gt 2) { $clause += " (+$($bits.Count - 2) more)" }
  return $clause
}

function Get-StatusWord($row) {
  if ($row.status) { return $row.status }
  if ($row.blocked_by) { return 'blocked' }
  if (-not $row.hasChanges) { return 'no change' }
  return 'on track'
}

function Get-NextClause($row) {
  $n = if ($row.next) { $row.next } else { 'wrap up' }
  $d = if ($row.next_date) { $row.next_date } else { '<date?>' }
  return "$n by $d"
}

function Invoke-Draft($collected) {
  $lines = @()
  foreach ($row in @($collected.stories)) {
    $ws = Get-WorkstreamName $row
    # Done wins: a shipped story is announced once, then stops appearing.
    if ($row.released -and -not $row.released_posted) { $lines += "Done:    - $ws | done"; continue }
    if ($row.released) { continue }
    if (-not $row.workstream_added) {
      # Do not repeat the workstream name back as its own description: when 'workstream' has not
      # been set it already falls back to the title, and "X | Vince | X" reads as a bug.
      $what = if ($row.workstream -and $row.title) { $row.title } else { "$($row.key) on $($row.env)" }
      $lines += "Add:     + $ws | $Owner | $what"
      continue
    }
    $blocked = if ($row.blocked_by) { $row.blocked_by } else { '-' }
    $lines += "Update:  $ws | $(Get-StatusWord $row) | $(Get-ChangeClause $row) | $(Get-NextClause $row) | $blocked"
  }
  if (@($collected.adhoc).Count) {
    $c = (@($collected.adhoc) | Select-Object -First 3) -join '; '
    $lines += "Update:  Ad-hoc / support | on track | $c | ongoing | -"
  }
  if (-not $lines.Count) { $lines += 'No change.' }
  return ($lines -join "`n")
}

# ---- delivery ----------------------------------------------------------------------------------
function Get-SlackConfig {
  if (-not (Test-Path -LiteralPath $TokenPath) -or -not (Test-Path -LiteralPath $SlackCfgPath)) { return $null }
  try {
    $cfg = Read-JsonFile -Path $SlackCfgPath
    $member = [string]$cfg.member_id
    if (-not $member) { return $null }
    $sec = Import-CliXml -Path $TokenPath
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $tok) { return $null }
    return [pscustomobject]@{ token = $tok; member = $member }
  }
  catch { return $null }
}

function Send-SlackDm([string]$Body) {
  $cfg = Get-SlackConfig
  if (-not $cfg) { return [pscustomobject]@{ ok = $false; error = 'slack not configured' } }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $payload = @{ channel = $cfg.member; text = $Body } | ConvertTo-Json -Depth 4
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $res = Invoke-RestMethod -Uri 'https://slack.com/api/chat.postMessage' -Method Post `
      -Headers @{ Authorization = "Bearer $($cfg.token)" } `
      -ContentType 'application/json; charset=utf-8' -Body $bytes
    if ($res.ok) { return [pscustomobject]@{ ok = $true } }
    return [pscustomobject]@{ ok = $false; error = "slack: $($res.error)" }
  }
  catch { return [pscustomobject]@{ ok = $false; error = "slack: $($_.Exception.Message)" } }
}

function Show-Toast([string]$Title, [string]$Body) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.ShowBalloonTip(20000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 6
    $ni.Visible = $false
    $ni.Dispose()
    return $true
  }
  catch { return $false }
}

# ---- main ---------------------------------------------------------------------------------------
$result = [ordered]@{ ok = $true; action = $Action; since = $null; block = $null
  delivered = $null; skipped = $false; warning = $null; data = $null; summary = '' }

try {
  if ($Action -notin $AllowedActions) { throw "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  if ($Extra) { throw ("unexpected extra argument(s): " + (@($Extra) -join ' ')) }

  switch ($Action) {

    'set' {
      if (-not $Story) { $Story = Resolve-StoryFromPath -Root $Root -Registry (Read-Registry -Root $Root) }
      if (-not $Story) { throw "pass -Story <KEY> (could not infer it from cwd)" }
      $reg = Read-Registry -Root $Root
      $k = Resolve-RegistryKey -Registry $reg -Key $Story
      if (-not $k) { throw (Get-MissingStoryHint -Root $Root -Key $Story) }
      # Decide WHAT changes out here. A scriptblock passed to Invoke-RegistryUpdate gets its own
      # copy of any variable it assigns to, so accumulating the list inside it would silently
      # report 'nothing to set' on a write that did happen. -BlockedBy is read via
      # $PSBoundParameters here too: inside the scriptblock that would bind its own param($r).
      # Bound-but-empty is meaningful for ALL of these: passing -NextDate "" is how a date that has
      # gone stale gets cleared, exactly as -BlockedBy "" clears a blocker. Testing truthiness
      # instead would make a field settable but never clearable.
      $edits = [ordered]@{}
      if ($PSBoundParameters.ContainsKey('Workstream')) { $edits['workstream'] = $Workstream }
      if ($PSBoundParameters.ContainsKey('Status'))     { $edits['status']     = $Status }
      if ($PSBoundParameters.ContainsKey('NextDate'))   { $edits['next_date']  = $NextDate }
      if ($PSBoundParameters.ContainsKey('BlockedBy'))  { $edits['blocked_by'] = $BlockedBy }
      if ($edits.Count) {
        Invoke-RegistryUpdate -Root $Root -Mutate {
          param($r)
          $node = $r.stories.$k
          if (-not $node) { return $false }
          foreach ($f in @($edits.Keys)) { Set-NodeField $node $f $edits[$f] }
          return $true
        } | Out-Null
      }
      $result.summary = if ($edits.Count) { "$k : set $(@($edits.Keys) -join ', ')" } else { "$k : nothing to set" }
    }

    'note' {
      $body = if ($Text) { $Text } else { $Arg1 }
      if (-not $body) { throw "nothing to note. Usage: story-status.ps1 note ""<text>""" }
      $reg = Read-Registry -Root $Root
      $k = $Story
      if (-not $k) { $k = Resolve-StoryFromPath -Root $Root -Registry $reg }
      if ($k) { $k = Resolve-RegistryKey -Registry $reg -Key $k }
      if ($k) {
        # Story-scoped: reuse the node's existing changelog rather than a second store.
        $key = $k
        Invoke-RegistryUpdate -Root $Root -Mutate {
          param($r)
          $node = $r.stories.$key
          if (-not $node) { return $false }
          Add-NodeLog $node 'note' $body
          return $true
        } | Out-Null
        $result.summary = "$k : note recorded"
      }
      else {
        $slog = Read-StatusLog
        $slog.notes = @(@($slog.notes) + [pscustomobject]@{ ts = (Get-Stamp); story = $null; text = $body })
        Write-StatusLog $slog
        $result.summary = "ad-hoc note recorded (no story in cwd)"
      }
    }

    'mark' {
      # The watermark must land on the boundary of what was actually DRAFTED (the -Since used to
      # produce the sent text), never on "now": confirmation always lags the real send by however
      # long the chat round-trip takes, and in that gap real work keeps landing (a ledger phase, a
      # commit). Stamping "now" silently walks the watermark past that work, and it can never be
      # recovered - the next collect starts strictly after the new watermark. Pass -PostedAt with
      # the SAME value collect/draft used for this post; only fall back to now with no better anchor.
      $body = if ($Text) { $Text } else { $Arg1 }
      $stamp = if ($PostedAt) {
        $p = ConvertTo-Stamp $PostedAt
        if ($p) { $p.ToString('yyyy-MM-dd HH:mm') } else { Get-Stamp }
      } else { Get-Stamp }
      $slog = Read-StatusLog
      $slog.last_posted = $stamp
      if ($body) { $slog.posts = @(@($slog.posts) + [pscustomobject]@{ ts = $stamp; text = $body }) }
      Write-StatusLog $slog
      # Stamp the announcement flags ONLY for workstreams the post actually contained. Stamping
      # every story would silently swallow the Add/Done line of anything trimmed out of tonight's
      # message - it would be marked announced without ever having been announced.
      # Track name AND line type. A story mentioned in a plain Update: line has been ANNOUNCED
      # (workstream_added should stamp), but that is NOT the same as having been reported as
      # shipped - only an actual "Done:" line means that. The two used to share one $posted list,
      # which meant an Update: line for an already-released story silently pre-stamped
      # released_posted, so the real Done line (sent the next day) then rendered as already
      # announced and got suppressed before the channel ever saw it.
      $posted = @()
      $postedDone = @()
      foreach ($line in ($body -split "`r?`n")) {
        if ($line -match '^\s*(Add|Update|Done):\s*[+\-]?\s*(.+?)\s*\|') {
          $name = $Matches[2].Trim()
          $posted += $name
          if ($Matches[1] -eq 'Done') { $postedDone += $name }
        }
      }
      $posted = @($posted | Select-Object -Unique)
      $postedDone = @($postedDone | Select-Object -Unique)
      $reg = Read-Registry -Root $Root
      # Work out membership out here: a Mutate scriptblock gets its own copy of any variable it
      # assigns to, so accumulating these inside it reports an empty list on a write that happened.
      $stamped = @(); $skipped = @()
      foreach ($kk in @($reg.stories.PSObject.Properties.Name)) {
        $node = $reg.stories.$kk
        # Match on whatever name the post would have used for this story.
        $names = @((Get-NodeField $node 'workstream'), (Get-NodeField $node 'title'), $kk) | Where-Object { $_ }
        if (@($names | Where-Object { $posted -contains $_ }).Count) { $stamped += $kk } else { $skipped += $kk }
      }
      if ($stamped.Count) {
        Invoke-RegistryUpdate -Root $Root -Mutate {
          param($r)
          foreach ($kk in $stamped) {
            $node = $r.stories.$kk
            if (-not $node) { continue }
            if (-not (Get-NodeField $node 'workstream_added')) { Set-NodeField $node 'workstream_added' $stamp }
            $names = @((Get-NodeField $node 'workstream'), (Get-NodeField $node 'title'), $kk) | Where-Object { $_ }
            $wasDoneLine = @($names | Where-Object { $postedDone -contains $_ }).Count -gt 0
            if ($wasDoneLine -and (Get-NodeField $node 'released') -and -not (Get-NodeField $node 'released_posted')) {
              Set-NodeField $node 'released_posted' $stamp
            }
          }
          return $true
        } | Out-Null
      }
      $result.summary = "marked posted at $stamp"
      if ($stamped.Count) { $result.summary += "; announced: $($stamped -join ', ')" }
      if ($skipped.Count) { $result.summary += "; NOT in the post, still unannounced: $($skipped -join ', ')" }
      if (-not $posted.Count) { $result.warning = 'no -Text given, so no story was stamped as announced (watermark moved only)' }
    }

    'slack-test' {
      $r = Send-SlackDm "EOD notifier online ($(Get-Stamp))."
      $result.ok = $r.ok
      if (-not $r.ok) { $result.error = $r.error; $result.summary = $r.error }
      else { $result.summary = 'slack DM sent' }
    }

    default {
      # collect / draft / notify all start from the same window.
      $sinceDt = ConvertTo-Stamp $Since
      if (-not $sinceDt) {
        $slog = Read-StatusLog
        $sinceDt = ConvertTo-Stamp ([string]$slog.last_posted)
      }
      if (-not $sinceDt) { $sinceDt = (Get-Date).AddHours(-24) }
      $result.since = $sinceDt.ToString('yyyy-MM-dd HH:mm')

      if ($Action -eq 'notify') {
        # Quiet if tonight's report already went out - no nagging after you have posted.
        $slog = Read-StatusLog
        $lp = ConvertTo-Stamp ([string]$slog.last_posted)
        if ($lp -and $lp -ge (Get-PeriodStart)) {
          $result.skipped = $true
          $result.summary = "already posted at $($slog.last_posted) - staying quiet"
          Out-Result $result
          return
        }
      }

      $collected = Invoke-Collect $sinceDt
      $block = Invoke-Draft $collected
      $result.block = $block
      if ($Action -eq 'collect') { $result.data = $collected; $result.summary = "collected $(@($collected.stories).Count) stories since $($result.since)" }

      if ($Action -eq 'notify') {
        $head = if ($Tier -eq 'early') {
          "EOD draft so far (cutoff 05:45). Send now and be done, or let it ride."
        } else {
          "EOD status - cutoff 05:45, about 75 min. Paste into #eng-status-input:"
        }
        $msg = "$head`n`n$block"
        $sent = Send-SlackDm $msg
        if ($sent.ok) { $result.delivered = 'slack-dm' }
        else {
          # Degrade to local and still exit 0: a missing token must never mean a missed reminder.
          $result.warning = $sent.error
          if (-not (Test-Path -LiteralPath $NotesDir)) { New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null }
          Write-Utf8NoBom -Path $DraftPath -Text "# EOD draft ($(Get-Stamp))`n`n$head`n`n``````text`n$block`n```````n"
          [void](Show-Toast 'EOD status draft ready' 'Slack not configured - draft written to notes\eod-draft.md')
          $result.delivered = 'local'
        }
        $result.summary = "notify ($Tier) delivered via $($result.delivered)"
      }
      elseif ($Action -eq 'draft') { $result.summary = 'draft rendered' }
    }
  }

  Out-Result $result
}
catch {
  $result.ok = $false
  $result.error = "story-status error: $($_.Exception.Message)"
  Out-Result $result
}
