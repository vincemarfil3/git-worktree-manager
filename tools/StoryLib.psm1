#requires -Version 5.1
<#
  StoryLib.psm1 - the helpers every story tool needs, in one place.

  These were copy-pasted across story-env / story-ledger / story-testplan / switch-story /
  remove-worktree and drifted: the BOM-less writer existed 4 times with three different -Depth
  values on the SAME file, Read-Json had three strategies (two embedding a raw BOM byte-triple in
  a string literal inside a BOM-less .ps1), Git-Cap swallowed stderr in one copy and captured it
  in the others, and the story-key regex disagreed hard enough that 'kuber-partner-date' could be
  created by switch-story and then never removed by remove-worktree.

  Module scope cannot see caller variables - every function takes $Root/$Story explicitly.
#>

Set-StrictMode -Off

# ---- story keys -------------------------------------------------------------------------------
# Two accepted shapes. Jira keys are what switch-story/ganesha-worktree create; the kebab slug is
# the escape hatch for cross-story work with no ticket (e.g. 'kuber-partner-date'). Every tool
# validates through here so a key that can be CREATED can always be REMOVED.
$script:JiraKeyPattern = '^[A-Za-z0-9]+-\d+$'
$script:SlugKeyPattern = '^[a-z][a-z0-9]*(-[a-z0-9]+)+$'

function Test-StoryKey {
  param([string]$Key, [switch]$JiraOnly)
  if (-not $Key) { return $false }
  if ($Key -match $script:JiraKeyPattern) { return $true }
  if (-not $JiraOnly -and $Key -match $script:SlugKeyPattern) { return $true }
  return $false
}

function Get-StoryKeyPattern { param([switch]$JiraOnly)
  if ($JiraOnly) { return $script:JiraKeyPattern }
  return "($script:JiraKeyPattern)|($script:SlugKeyPattern)"
}

# ---- file IO ----------------------------------------------------------------------------------
# PS 5.1's -Encoding utf8 ALWAYS writes a BOM, which breaks every JS consumer in this family
# (rules-lib.js / gen-rules.mjs / history.js). One writer, one depth per file kind.
function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Write-JsonFile {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Obj, [int]$Depth = 20)
  Write-Utf8NoBom -Path $Path -Text ($Obj | ConvertTo-Json -Depth $Depth)
}

# ReadAllText already strips a UTF-8 BOM; the extra -replace is belt-and-braces for files written
# by something else. Never embed a literal BOM here - this file is itself BOM-less.
function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $raw = [IO.File]::ReadAllText($Path)
  $raw = $raw -replace "^$([char]0xFEFF)", ''
  if (-not $raw.Trim()) { return $null }
  return ($raw | ConvertFrom-Json)
}

# ---- registry (stories.json) ------------------------------------------------------------------
# -DocsDir (optional, added for P5 tracking mode): when given, resolves under <Root>\<DocsDir>\
# instead of bare <Root>\ - a tracking-mode project's registry/history live at
# <root>\<docsDir>\stories.json (Resolve-StgPaths' own tracking branch, mirrored here), not
# <root>\stories.json. Every existing caller that never passes it keeps today's exact behavior -
# found necessary by live testing, not design review: switch-story.ps1 has its own LOCAL
# Read-Registry/Write-Registry override that already reads $Paths.StoriesPath correctly, but every
# OTHER script here (story-ledger, story-doctor, story-status, story-release, story-handover,
# vault-status, remove-worktree's own tracking-mode branch) calls straight through to THIS
# module's Read-Registry/Invoke-RegistryUpdate/Enter-RegistryLock, which were completely blind to
# tracking mode until now - confirmed live: story-ledger.ps1 threw "stories.json not found"
# creating the very first tracking-mode story's ledger, even though the story itself had
# registered correctly (through switch-story.ps1's own already-correct path).
function Get-RegistryPath { param([Parameter(Mandatory)][string]$Root, [string]$DocsDir) if ($DocsDir) { Join-Path (Join-Path $Root $DocsDir) 'stories.json' } else { Join-Path $Root 'stories.json' } }
function Get-HistoryPath  { param([Parameter(Mandatory)][string]$Root, [string]$DocsDir) if ($DocsDir) { Join-Path (Join-Path $Root $DocsDir) 'stories_history.json' } else { Join-Path $Root 'stories_history.json' } }

# stories.json has 5+ writers (switch-story new/log, story-env heal, remove-worktree, and the
# browser extension's native host) with no coordination - an overlap silently discards a node.
# Every mutation goes through this: exclusive lock, read UNDER the lock, mutate, write, release.
function Enter-RegistryLock {
  param([Parameter(Mandatory)][string]$Root, [string]$DocsDir, [int]$TimeoutMs = 4000)
  $lockPath = (Get-RegistryPath -Root $Root -DocsDir $DocsDir) + '.lock'
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    try {
      return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch { Start-Sleep -Milliseconds 120 }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "stories.json is locked by another story tool (waited $([int]($TimeoutMs/1000))s). Retry in a moment."
}

function Exit-RegistryLock {
  param($Handle)
  if ($Handle) { try { $Handle.Close(); $Handle.Dispose() } catch {} }
}

function Read-Registry {
  param([Parameter(Mandatory)][string]$Root, [string]$DocsDir)
  $p = Get-RegistryPath -Root $Root -DocsDir $DocsDir
  if (-not (Test-Path -LiteralPath $p)) { throw "stories.json not found at $p" }
  return Read-JsonFile -Path $p
}

# Read-modify-write under one lock. $Mutate gets the parsed registry; return $true to write.
function Invoke-RegistryUpdate {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$DocsDir,
    [Parameter(Mandatory)][scriptblock]$Mutate,
    [int]$Depth = 12
  )
  $lock = Enter-RegistryLock -Root $Root -DocsDir $DocsDir
  try {
    $reg = Read-Registry -Root $Root -DocsDir $DocsDir
    $write = & $Mutate $reg
    if ($write -ne $false) { Write-JsonFile -Path (Get-RegistryPath -Root $Root -DocsDir $DocsDir) -Obj $reg -Depth $Depth }
    return $reg
  }
  finally { Exit-RegistryLock $lock }
}

# Registry keys are case-sensitive to the JS consumers, so never .ToUpper() blindly - resolve the
# caller's spelling against what is actually in the file.
function Resolve-RegistryKey {
  param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$Key)
  $names = @($Registry.stories.PSObject.Properties.Name)
  $exact = $names | Where-Object { $_ -ceq $Key } | Select-Object -First 1
  if ($exact) { return $exact }
  $ci = $names | Where-Object { $_ -eq $Key } | Select-Object -First 1
  if ($ci) { return $ci }
  return $null
}

# ---- story / path resolution ------------------------------------------------------------------
# cwd inside a worktree is <root>\<STORY>\<app>, so the FIRST path segment under the root is the
# story key and the leaf is the app (the pre-2026-07-11 flat '<app>--<STORY>' form is gone).
#
# The slug key form is deliberately NOT trusted by pattern here: the root is also home base, so
# 'bartleby-db' / 'ganesha-service-app' / most app folders match the slug shape. A Jira-form
# segment is unambiguous; a slug-form one counts only when the registry actually has that node.
function Resolve-StoryFromPath {
  param([Parameter(Mandatory)][string]$Root, [string]$Path, $Registry)
  if (-not $Path) { $Path = (Get-Location).Path }
  $rootTrim = $Root.TrimEnd('\')
  if (-not $Path.ToLower().StartsWith($rootTrim.ToLower() + '\')) { return $null }
  $rest = $Path.Substring($rootTrim.Length + 1).Split('\')
  if ($rest.Count -lt 1 -or -not $rest[0]) { return $null }
  $seg = $rest[0]
  if ($Registry) {
    $k = Resolve-RegistryKey -Registry $Registry -Key $seg
    if ($k) { return $k }
  }
  if (Test-StoryKey $seg -JiraOnly) { return $seg }
  return $null
}

# Story folders under the root, excluding the ~45 home-base app folders that share the slug shape.
# A folder counts as a story folder when it is Jira-shaped OR named by the registry/history.
function Get-StoryFolderNames {
  param([Parameter(Mandatory)][string]$Root, $Registry, $History)
  $known = @{}
  # Inline null-filter, not stg-paths.psm1's Get-StgNames - this module deliberately imports
  # nothing (see header), so it doesn't gain a new dependency just for this. Same underlying bug
  # as everywhere else this pattern appears: @($Registry.stories.PSObject.Properties.Name) is
  # $null -> a one-element array HOLDING $null on an empty {} registry, and $known[$null] = ...
  # throws ("Index operation failed; the array index evaluated to null"). Filtering nulls out of
  # the pipeline keeps the @() wrapper's real job (stop a one-property object collapsing to a
  # bare scalar) while dropping the null it manufactures on an empty object.
  if ($Registry) { foreach ($n in @($Registry.stories.PSObject.Properties.Name | Where-Object { $_ })) { $known[$n] = $true } }
  if ($History)  { foreach ($e in @($History.removed))  { if ($e.key) { $known[[string]$e.key] = $true } } }
  $out = @()
  foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
    if ($known.ContainsKey($d.Name) -or (Test-StoryKey $d.Name -JiraOnly)) { $out += $d.Name }
  }
  return @($out)
}

function Get-WtPath {
  param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Story, [Parameter(Mandatory)][string]$App)
  Join-Path (Join-Path $Root $Story) $App
}

# ---- git ---------------------------------------------------------------------------------------
# git that never throws on stderr and never DISCARDS it - the swallowed copy is why a failed
# merge-base only ever surfaced as "diff failed (fetch first?)" with the real message gone.
function Invoke-GitCap {
  param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$GitArgs)
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $out = & git -C $Dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    # Don't leak git's exit code: these tools promise "always exit 0, read the ok field", and a
    # probe that legitimately fails (git in a non-worktree dir returns 128) would otherwise become
    # the script's own exit status.
    $global:LASTEXITCODE = 0
    [pscustomobject]@{ code = $code; out = (($out | Out-String).Trim()) }
  }
  finally { $ErrorActionPreference = $prev }
}

function Test-GitWorktree {
  param([Parameter(Mandatory)][string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir)) { return $false }
  $r = Invoke-GitCap -Dir $Dir -GitArgs @('rev-parse', '--is-inside-work-tree')
  return ($r.code -eq 0 -and $r.out -eq 'true')
}

# ---- story folder discovery --------------------------------------------------------------------
# A child dir of <root>\<STORY> is an APP only when the registry node declares it or it really is a
# live git worktree. Everything else is an EXTRA: hand-made folders like EH7-8934\logs\ used to be
# treated as apps, which made story-testplan report a healthy story as failed and would have had
# remove-worktree recursively delete them while reporting 'removed'.
function Get-StoryFolders {
  param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Story, $Node)
  $storyDir = Join-Path $Root $Story
  $apps = [ordered]@{}
  $extras = @()

  if ($Node -and $Node.apps) {
    foreach ($a in @($Node.apps)) { if ($a) { $apps[[string]$a] = (Join-Path $storyDir ([string]$a)) } }
  }
  foreach ($d in (Get-ChildItem -LiteralPath $storyDir -Directory -ErrorAction SilentlyContinue)) {
    if ($apps.Contains($d.Name)) { continue }
    if (Test-GitWorktree -Dir $d.FullName) { $apps[$d.Name] = $d.FullName }
    else { $extras += $d.Name }
  }
  [pscustomobject]@{ apps = $apps; extras = @($extras); storyDir = $storyDir }
}

# A key that resolves from cwd but is absent from stories.json is almost always an ARCHIVED story
# whose worktree folder was never moved (a handover: the folder still says PIII-10877 while the
# branches inside it now belong to EH7-9725). "not in stories.json" is true but tells the operator
# nothing, so name the archive record and, by reading each worktree's branch, the story that
# actually owns the code sitting there.
function Get-MissingStoryHint {
  param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Key)
  $msg = "story '$Key' is not in stories.json"
  try {
    $hist = Read-JsonFile -Path (Get-HistoryPath -Root $Root)
    $rec = @($hist.removed) | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if ($rec) { $msg += " (archived $($rec.removed_at))" }
  }
  catch {}
  $owners = @()
  foreach ($d in (Get-ChildItem -LiteralPath (Join-Path $Root $Key) -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-GitWorktree -Dir $d.FullName)) { continue }
    $b = (Invoke-GitCap -Dir $d.FullName -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).out
    if ($b -match '^feature/[^/]+/(.+)$') { $owners += $Matches[1] }
  }
  $owners = @($owners | Select-Object -Unique | Where-Object { $_ -ne $Key })
  if ($owners.Count) {
    $msg += ". The folder $Root\$Key still holds worktrees on branches owned by: $($owners -join ', ')"
    $msg += " - the folder move was never finished. Move them to $Root\<KEY>\<app>, or pass -Story <KEY> explicitly"
  }
  return $msg
}

# ---- misc --------------------------------------------------------------------------------------
function Get-Stamp { (Get-Date).ToString('yyyy-MM-dd HH:mm') }

function Split-DelimitedList {
  param([string]$Value)
  if (-not $Value) { return @() }
  return @($Value -split '[;|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Export-ModuleMember -Function `
  Test-StoryKey, Get-StoryKeyPattern, `
  Write-Utf8NoBom, Write-JsonFile, Read-JsonFile, `
  Get-RegistryPath, Get-HistoryPath, Enter-RegistryLock, Exit-RegistryLock, `
  Read-Registry, Invoke-RegistryUpdate, Resolve-RegistryKey, `
  Resolve-StoryFromPath, Get-StoryFolderNames, Get-WtPath, `
  Invoke-GitCap, Test-GitWorktree, Get-StoryFolders, Get-MissingStoryHint, `
  Get-Stamp, Split-DelimitedList
