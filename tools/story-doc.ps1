#requires -Version 5.1
<#
  story-doc.ps1 - tracking mode's per-story markdown doc: one file per story, Claude's work-log
  for it, living inside the repo it's about.

  Not an extension of switch-story.ps1 note: that file is already 52KB, and a multi-line log entry
  through a positional arg hits the same -File child-process quote-stripping problem -LinksB64
  exists for in switch-story.ps1 - so this mirrors that fix with -TextB64 (base64 of UTF-8 text).

  Store: <root>\<docsDir>\<STORY>.md (docsDir defaults to .claude\stories - Get-StgStoryDocPath in
  stg-paths.psm1 is the single implementation of this path, shared with Resolve-StgPaths' own
  tracking-mode StoriesPath/HistoryPath computation).

  Usage:
    story-doc.ps1 <action> <STORY> [-TextB64 <b64>] [-TitleB64 <b64>] [-Root R] [-Project P] [-Json]

  actions:
    init      create <STORY>.md if it doesn't exist yet (idempotent - never overwrites)
    append    add a timestamped entry under the last '## Work log' heading (created if absent)
    path      report the resolved path and whether it currently exists - no write
    show      print the doc's current content (default)

  Append is deliberately dumb: ensure a '## Work log' heading exists SOMEWHERE in the file (add one
  at EOF if not), then always append the new entry at the very end - never inserted mid-document,
  so anything written above (by hand or by Claude, in an earlier session) is never disturbed.

  Always exits 0; success is carried in the 'ok' field, matching every other tool here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'show',
  [Parameter(Position = 1)] [string]$StoryPositional,
  [string]$Story,
  [string]$TextB64,
  [string]$TitleB64,
  [switch]$Json,
  [string]$Root,     # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  [string]$Project,  # resolved project id (native-host\host.ps1); blank = active project / legacy resolution
  # Swallow stray positionals instead of dying with a PositionalParameterNotFound binding error
  # before the try block can produce a JSON frame. Reported as ok:false below.
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

if (-not $Story) { $Story = $StoryPositional }
$AllowedActions = @('init', 'append', 'path', 'show')

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  else { Write-Host $o.summary }
}

if ($Action -notin $AllowedActions) {
  Out-Result @{ ok = $false; error = "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  exit 0
}
if (-not $Story) {
  Out-Result @{ ok = $false; error = 'Usage: story-doc.ps1 <action> <STORY> [-TextB64 ...] [-Json]' }
  exit 0
}
if ($Extra) {
  Out-Result @{ ok = $false; error = ("unexpected extra argument(s): " + (@($Extra) -join ' ')) }
  exit 0
}

# BOM-less, matching every other JSON/text file this tool writes (stg-paths.psm1's Set-StgConfig,
# StoryLib.psm1's Write-Utf8NoBom convention).
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Write-DocFile([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}
function Get-DecodedB64([string]$B64) {
  if (-not $B64) { return $null }
  try { return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($B64)) }
  catch { throw "invalid base64 payload: $($_.Exception.Message)" }
}

$DocPath = Get-StgStoryDocPath -Paths $Paths -Story $Story

switch ($Action) {
  'path' {
    Out-Result @{ ok = $true; story = $Story; path = $DocPath; exists = (Test-Path $DocPath); summary = $DocPath }
  }

  'init' {
    if (Test-Path $DocPath) {
      Out-Result @{ ok = $true; story = $Story; path = $DocPath; created = $false; summary = "doc already exists: $DocPath" }
      break
    }
    try {
      $dir = Split-Path $DocPath -Parent
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $title = Get-DecodedB64 $TitleB64
      $heading = if ($title) { "# $Story - $title" } else { "# $Story" }
      Write-DocFile $DocPath "$heading`n`n## Work log`n"
      Out-Result @{ ok = $true; story = $Story; path = $DocPath; created = $true; summary = "created $DocPath" }
    }
    catch {
      Out-Result @{ ok = $false; story = $Story; path = $DocPath; error = $_.Exception.Message }
    }
  }

  'append' {
    $text = Get-DecodedB64 $TextB64
    if (-not $text) {
      Out-Result @{ ok = $false; story = $Story; error = 'append needs -TextB64 (base64 of the UTF-8 note text)' }
      break
    }
    try {
      $dir = Split-Path $DocPath -Parent
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      # [System.IO.File]::ReadAllText, not Get-Content -Raw: Get-Content decorates its return string
      # with PSPath/PSDrive/PSProvider ETS members that ConvertTo-Json (Out-Result, downstream of
      # $existing via $final) would recurse into at -Depth 8 - see the 'show' case below for the
      # full story on how that turns into an effective hang, not just noisy output.
      $existing = if (Test-Path $DocPath) { [System.IO.File]::ReadAllText($DocPath) } else { "# $Story`n`n" }
      # Deliberately dumb append - see the file header comment. Only ever adds a heading if truly
      # absent, and only ever appends at the very end.
      if ($existing -notmatch '(?m)^## Work log\s*$') {
        $sep = if ($existing -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
        $existing = "$existing$sep`n## Work log`n"
      }
      $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm')
      $sep2 = if (-not $existing.EndsWith("`n")) { "`n" } else { '' }
      $final = "$existing$sep2`n### $ts`n$text`n"
      Write-DocFile $DocPath $final
      Out-Result @{ ok = $true; story = $Story; path = $DocPath; summary = "appended to $DocPath" }
    }
    catch {
      Out-Result @{ ok = $false; story = $Story; path = $DocPath; error = $_.Exception.Message }
    }
  }

  'show' {
    if (-not (Test-Path $DocPath)) {
      Out-Result @{ ok = $false; story = $Story; path = $DocPath; error = "no doc yet for $Story at $DocPath" }
      break
    }
    # [System.IO.File]::ReadAllText, not Get-Content -Raw: Get-Content's return value carries
    # PowerShell's extended type-system members (PSPath/PSParentPath/PSChildName/PSDrive/PSProvider)
    # even though its declared .NET type is a plain System.String. ConvertTo-Json -Depth 8 doesn't
    # see a string then - it sees an object with those properties and recurses INTO them, including
    # PSDrive/PSProvider's own large, framework-internal object graphs. Not an infinite loop, but
    # slow enough (confirmed via isolated testing: the identical hashtable serializes instantly with
    # ReadAllText's plain string, but never returned within 30s with Get-Content -Raw's decorated
    # one) to be indistinguishable from a hang in practice - this bit the very first live test of
    # this action. ReadAllText returns a genuinely plain .NET string with no ETS decoration.
    $content = [System.IO.File]::ReadAllText($DocPath)
    if ($Json) { Out-Result @{ ok = $true; story = $Story; path = $DocPath; content = $content } }
    else { Write-Host $content }
  }
}
