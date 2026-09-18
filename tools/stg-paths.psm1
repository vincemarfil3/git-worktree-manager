# stg-paths.psm1 - the single path/config resolver shared by every script in this folder AND by
# native-host\host.ps1. Two jobs:
#   1. Find the DATA ROOT (stories.json + per-story worktrees) - which almost never lives next to
#      these scripts. Resolution order below, first hit wins, and WHICH rule won is always reported
#      (Resolve-StgPaths.Source) so nothing fails silently the way host.ps1's old inline version did.
#   2. Read/write the per-machine config file at %LOCALAPPDATA%\story-tab-groups\stg-config.json -
#      never shipped, never checked in, survives replacing this whole folder.
#
# Every script that used to do `$Root = Split-Path $PSScriptRoot -Parent` (assuming it lived in
# <root>\tools\) or `$Root = $PSScriptRoot` (assuming it lived at <root>\) now calls
# Resolve-StgPaths instead - both assumptions broke the moment every script shared one folder.
#
# Deliberately NO `Set-StrictMode -Version Latest` here: Get-StgConfig returns a bare
# [pscustomobject]@{} when stg-config.json doesn't exist yet (the normal fresh-machine state this
# whole module exists to support), and under strict mode accessing a property that object doesn't
# have (e.g. $cfg.root) throws PropertyNotFoundException instead of returning $null - which broke
# every single caller on first real dry run. Every `$cfg.<field>` access below relies on plain,
# non-strict PSCustomObject semantics (missing property -> $null).

function Get-StgUserConfigDir {
  # %LOCALAPPDATA%\story-tab-groups - per-machine, outside this folder entirely, so replacing or
  # relocating the extension/tools folder never wipes settings and never ships someone else's paths.
  $dir = Join-Path $env:LOCALAPPDATA 'story-tab-groups'
  if (-not (Test-Path $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
  return $dir
}

function Get-StgConfigPath {
  Join-Path (Get-StgUserConfigDir) 'stg-config.json'
}

function Get-StgConfig {
  # Missing/unreadable/corrupt file -> empty object. Never throws - every caller treats every
  # field as optional.
  $p = Get-StgConfigPath
  if (-not (Test-Path $p)) { return [pscustomobject]@{} }
  try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
}

function Set-StgConfig {
  param([Parameter(Mandatory)][hashtable]$Config)
  $p = Get-StgConfigPath
  $json = $Config | ConvertTo-Json -Depth 10
  # BOM-less, matching every other JSON file this tool writes (StoryLib.psm1's Write-Utf8NoBom
  # convention) - a BOM here would double-encode under PS 5.1 the same way the module's own
  # ASCII-only rule exists to avoid.
  [System.IO.File]::WriteAllText($p, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-StgNames {
  # JSON object -> its property names as a REAL array, never @($null).
  #
  # Why this exists: `@($obj.PSObject.Properties.Name)` is the idiom used throughout these
  # scripts, and it is wrong for an EMPTY object. The property expression yields $null, and
  # @($null) is a one-element array holding $null - so the caller's foreach runs once with a
  # $null key and any `$hashtable[$key] = ...` in the body throws "Index operation failed; the
  # array index evaluated to null". Bare `foreach ($x in $null)` iterates zero times, so it is
  # the @() wrapper itself that manufactures the bug - but that wrapper has to stay, because it
  # is what stops PowerShell collapsing a ONE-property object to a bare scalar. Filtering nulls
  # keeps both properties: zero names -> empty array, one name -> one-element array.
  param($Obj)
  if ($null -eq $Obj) { return @() }
  return @($Obj.PSObject.Properties.Name | Where-Object { $_ })
}

function Get-StgAppMapPath {
  # %LOCALAPPDATA% copy wins when it exists, else the shipped tools\ template. Same reasoning as
  # stg-config.json: replacing or re-cloning the extension folder must not wipe what the user
  # configured. Settings always WRITES the %LOCALAPPDATA% copy; tools\app-map.json stays a
  # read-only fallback, so an untouched install behaves exactly as it does today.
  $user = Join-Path (Get-StgUserConfigDir) 'app-map.json'
  if (Test-Path $user) { return $user }
  return (Join-Path $PSScriptRoot 'app-map.json')
}

function Test-StgRootValid([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $false }
  return (Test-Path -LiteralPath $path -PathType Container)
}

function Find-StgRootUpward([string]$startDir) {
  # Auto-detect: walk up from wherever this module lives looking for a directory that contains
  # stories.json. Stops at the drive root. This is what lets a fresh machine work with zero config
  # when the scripts happen to sit inside (or above) the data tree, and is the last resort before
  # NeedsSetup.
  $dir = $startDir
  for ($i = 0; $i -lt 8 -and $dir; $i++) {
    $candidate = Join-Path $dir 'stories.json'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $dir }
    $parent = Split-Path $dir -Parent
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $null
}

function Resolve-StgPaths {
  <#
    .SYNOPSIS
      Resolves the data root + every derived path, and reports which rule decided the root.
    .DESCRIPTION
      Order (first hit wins):
        1. -Root parameter (explicit override, e.g. host.ps1 relaying a Settings-page value)
        2. stg-config.json 'root' field - validated as a real directory (Test-Path -PathType
           Container); a stale/invalid value here is SKIPPED, not silently accepted, unlike the
           old host.ps1 inline resolver.
        3. $env:STG_ROOT
        4. Auto-detect: walk up from this module's own folder looking for stories.json.
        5. None of the above -> NeedsSetup = $true. Callers must check this before touching
           StoriesPath etc. - they will point at a nonexistent location.

      Config outranks the environment variable, not the other way around - deliberately, and it
      wasn't always this order. $env:STG_ROOT lives in the OS environment block, which a
      long-lived process (a browser, most concretely) has frozen at ITS OWN startup - completely
      independent of whenever stg-config.json was last written. A user who runs setup.ps1 (which
      writes stg-config.json AND publishes STG_ROOT) while Chrome is already open ends up with an
      already-running Chrome whose native-host children keep inheriting whatever STG_ROOT existed
      when Chrome itself started - stale, or entirely absent - while the config file sitting right
      there on disk is completely correct and current. With the old order ($env:STG_ROOT above
      config), that stale/absent env value silently overrode the correct file every single call,
      with no error and no way to tell from the UI - confirmed as a real, reproduced cause of a
      story that had genuinely been removed still showing "not in stories.json" on the next click,
      purely because of when Chrome itself had been launched relative to when setup.ps1 ran.
      stg-config.json is the one source of the three a user can actually see and control from
      Settings without touching a terminal or the registry, so it's now the stronger of the two
      ambient (non-parameter) signals; $env:STG_ROOT keeps its original purpose - a convenience
      default for a bare terminal/skill invocation with no config file yet - by still beating blind
      auto-detect.
  #>
  param(
    [string]$Root,
    [string]$WorktreeRoot
  )

  $cfg = Get-StgConfig
  $source = $null
  $resolvedRoot = $null

  if ($Root -and (Test-StgRootValid $Root)) {
    $resolvedRoot = $Root; $source = 'parameter'
  } elseif ($Root) {
    # An explicit -Root was passed but doesn't exist - surface that rather than silently falling
    # through to a different root the caller didn't ask for.
    return [pscustomobject]@{
      Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ScriptDir = $PSScriptRoot
      StoriesPath = $null; HistoryPath = $null; AppMapPath = (Get-StgAppMapPath)
      UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
      Source = 'parameter (invalid)'; NeedsSetup = $true
      Error = "The specified root does not exist: $Root"
    }
  } elseif ($cfg.root -and (Test-StgRootValid $cfg.root)) {
    $resolvedRoot = $cfg.root; $source = 'config'
  } elseif ($env:STG_ROOT -and (Test-StgRootValid $env:STG_ROOT)) {
    $resolvedRoot = $env:STG_ROOT; $source = 'env:STG_ROOT'
  } else {
    $auto = Find-StgRootUpward $PSScriptRoot
    if ($auto) { $resolvedRoot = $auto; $source = 'auto-detect' }
  }

  if (-not $resolvedRoot) {
    return [pscustomobject]@{
      Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ScriptDir = $PSScriptRoot
      StoriesPath = $null; HistoryPath = $null; AppMapPath = (Get-StgAppMapPath)
      UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
      Source = 'none'; NeedsSetup = $true
      Error = 'No story root configured. Run setup.ps1, set the Root in Settings, or set $env:STG_ROOT.'
    }
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $resolvedRoot).Path

  $resolvedWtRoot = $resolvedRoot
  if ($WorktreeRoot -and (Test-StgRootValid $WorktreeRoot)) {
    $resolvedWtRoot = (Resolve-Path -LiteralPath $WorktreeRoot).Path
  } elseif ($cfg.worktreeRoot -and (Test-StgRootValid $cfg.worktreeRoot)) {
    $resolvedWtRoot = (Resolve-Path -LiteralPath $cfg.worktreeRoot).Path
  }

  # Workspace dir: a sibling of Root, named <rootLeaf>_WorkSpaces - derived so a root named
  # "Ganesha" keeps producing "Ganesha_WorkSpaces" (today's exact behavior) while a root named
  # anything else gets its own matching name instead of a hardcoded "Ganesha_WorkSpaces" literal.
  $rootLeaf = Split-Path $resolvedRoot -Leaf
  $rootParent = Split-Path $resolvedRoot -Parent
  $workspaceDirDefault = if ($rootParent) { Join-Path $rootParent "${rootLeaf}_WorkSpaces" } else { Join-Path $resolvedRoot '_WorkSpaces' }
  $workspaceDir = if ($cfg.workspaceRoot -and $cfg.workspaceRoot.Trim()) { $cfg.workspaceRoot } else { $workspaceDirDefault }

  [pscustomobject]@{
    Root          = $resolvedRoot
    WorktreeRoot  = $resolvedWtRoot
    WorkspaceDir  = $workspaceDir
    ScriptDir     = $PSScriptRoot
    StoriesPath   = (Join-Path $resolvedRoot 'stories.json')
    HistoryPath   = (Join-Path $resolvedRoot 'stories_history.json')
    AppMapPath    = (Get-StgAppMapPath)
    UserConfigDir = (Get-StgUserConfigDir)
    ConfigPath    = (Get-StgConfigPath)
    Source        = $source
    NeedsSetup    = $false
    Error         = $null
  }
}

function Get-StgOrgDefaults {
  # De-hardcoded org-specific literals (Phase 2). Every one defaults to today's exact value, so an
  # existing tree behaves identically until someone changes Settings.
  $cfg = Get-StgConfig
  [pscustomobject]@{
    JiraBaseUrl     = if ($cfg.jiraBaseUrl) { $cfg.jiraBaseUrl } else { 'https://vesta.atlassian.net' }
    GithubOrg       = if ($cfg.githubOrg) { $cfg.githubOrg } else { 'vesta-experimental' }
    RepoAliases     = if ($cfg.repoAliases) { $cfg.repoAliases } else { [pscustomobject]@{ 'ganesha-iu-internal-app' = 'ganesha-ui-internal-app' } }
    TaskNamePrefix  = if ($cfg.taskNamePrefix) { $cfg.taskNamePrefix } else { 'Ganesha EOD status reminder' }
    Owner           = if ($cfg.owner) { $cfg.owner } else { $env:USERNAME }
    UserConfigDirName = if ($cfg.userConfigDirName) { $cfg.userConfigDirName } else { '.story-tab-groups' }
  }
}

function Get-StgOwnerConfigDir {
  # Resolves the per-user settings dir (Slack token, etc). Prefers the new default name but falls
  # back to the legacy ~\.ganesha if that's what already exists on this machine, so an existing
  # Slack token/config is never orphaned by the rename.
  $defaults = Get-StgOrgDefaults
  $newDir = Join-Path $env:USERPROFILE $defaults.UserConfigDirName
  $legacyDir = Join-Path $env:USERPROFILE '.ganesha'
  if ((Test-Path $legacyDir) -and -not (Test-Path $newDir)) { return $legacyDir }
  return $newDir
}

Export-ModuleMember -Function Get-StgConfig, Set-StgConfig, Get-StgConfigPath, Get-StgUserConfigDir, `
  Resolve-StgPaths, Test-StgRootValid, Find-StgRootUpward, Get-StgOrgDefaults, Get-StgOwnerConfigDir, `
  Get-StgNames, Get-StgAppMapPath
