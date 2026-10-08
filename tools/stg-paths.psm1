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
  # field as optional. ConvertTo-StgConfigV2 runs on every call (in memory only - see its own
  # comment for why this never writes to disk on its own).
  $p = Get-StgConfigPath
  if (-not (Test-Path $p)) { return (ConvertTo-StgConfigV2 ([pscustomobject]@{})) }
  $raw = $null
  try { $raw = (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $raw = [pscustomobject]@{} }
  return (ConvertTo-StgConfigV2 $raw)
}

function ConvertTo-StgHashtable($Obj) {
  # Shallow PSCustomObject -> [ordered] hashtable, so a value read via Get-StgConfig can be
  # mutated and handed back to Set-StgConfig (which requires a real [hashtable], not the
  # PSCustomObject ConvertFrom-Json produces). Nested values (projects[], defaults) are left as
  # whatever they already are - PSCustomObject or array - ConvertTo-Json round-trips a mixed
  # hashtable/PSCustomObject tree fine, so there is no need to recurse.
  $h = [ordered]@{}
  if ($null -eq $Obj) { return $h }
  foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
  return $h
}

function ConvertTo-StgConfigV2 {
  <#
    .SYNOPSIS
      Adds the multi-project shape ({version, activeProject, defaults, projects[]}) to a v1 flat
      config, in memory, without removing or relocating a single existing top-level field.
    .DESCRIPTION
      Pure and idempotent: already-v2 input (has a 'projects' property, even an empty array) is
      returned completely unchanged - never re-synthesizes or reorders an existing project list.
      An empty {} / no-root-yet input is also returned unchanged: there is nothing to synthesize a
      project FROM, and inventing one here would fight whatever flow (setup.ps1's first-run
      prompt, a later Settings "add project" action) is meant to create the first project
      deliberately; NeedsSetup already handles this case downstream.

      Deliberately ADDITIVE, not a move: every v1-era reader (Resolve-StgPaths, Get-StgOrgDefaults,
      host.ps1's getConfig/apps actions) keeps reading root/worktreeRoot/workspaceRoot/
      branchFormat/jiraBaseUrl/githubOrg/repoAliases/taskNamePrefix/owner/hiddenApps at the exact
      same top level it always has - none of them need to change in this phase for a single-project
      install to stay byte-identical, because nothing was taken away from them. projects[0] and
      defaults are a SECOND, parallel view of the same data, built once here and kept in sync by
      Update-StgConfig on every subsequent write, so P2/P3 inherit accurate values once they
      switch to reading THAT structure instead - without this phase having to touch those readers
      at all.
    #>
  param($Cfg)
  if ($null -eq $Cfg) { $Cfg = [pscustomobject]@{} }
  if ($Cfg.PSObject.Properties.Name -contains 'projects') { return $Cfg }
  if (-not $Cfg.root) { return $Cfg }

  $rootLeaf = Split-Path $Cfg.root -Leaf
  $slug = ($rootLeaf.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug) { $slug = 'default' }

  $project = [ordered]@{ id = $slug; name = $rootLeaf; mode = 'worktree'; root = [string]$Cfg.root }
  foreach ($k in @('worktreeRoot', 'workspaceRoot', 'branchFormat')) {
    if ($Cfg.$k) { $project[$k] = [string]$Cfg.$k }
  }
  $hidden = @($Cfg.hiddenApps | Where-Object { $_ })
  if ($hidden.Count) { $project['hiddenApps'] = $hidden }

  $defaults = [ordered]@{}
  foreach ($k in @('jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner')) {
    if ($Cfg.$k) { $defaults[$k] = [string]$Cfg.$k }
  }
  if ($Cfg.repoAliases) { $defaults['repoAliases'] = $Cfg.repoAliases }

  $out = ConvertTo-StgHashtable $Cfg
  $out['version'] = 2
  $out['activeProject'] = $slug
  $out['defaults'] = [pscustomobject]$defaults
  $out['projects'] = @([pscustomobject]$project)
  return [pscustomobject]$out
}

function Get-StgProjects {
  # Every configured project, as a REAL array even with exactly one project.
  #
  # @($cfg.projects | Where-Object { $_ }) alone is not enough: PowerShell enumerates ("unrolls")
  # any IEnumerable a function writes to its output stream, `return` included, regardless of how
  # it was wrapped inside the function - a one-element array collapses to a bare object crossing
  # the return boundary itself, before the @() wrap the caller might add ever gets a chance to
  # matter. That's a distinct trap from the ConvertTo-Json single-element collapse Get-StgNames
  # exists to fix elsewhere in this module (same root cause, different layer: JSON serialization
  # vs. the pipeline) - confirmed live: Get-StgProject's own `$projects = Get-StgProjects` came
  # back as a bare PSCustomObject on a one-project config, `.Count` was $null, and a real active
  # project was silently reported as "not found". Write-Output -NoEnumerate is the actual fix -
  # applied HERE, once, so no future caller (this module or otherwise) has to remember to
  # re-wrap the call site with its own @().
  $cfg = Get-StgConfig
  Write-Output -NoEnumerate @($cfg.projects | Where-Object { $_ })
}

function Get-StgProject {
  # One project record: by -Id, or (no -Id) the configured active project, or (no activeProject
  # set either) the first configured project. $null if none exist yet.
  #
  # PLAIN assignment - $projects = Get-StgProjects, NOT @(Get-StgProjects). That extra @() looked
  # like harmless belt-and-suspenders but is actively wrong once the source already -NoEnumerates:
  # Get-StgProjects puts exactly ONE pipeline item across the return boundary (the whole array,
  # un-enumerated, by design); wrapping THAT call in another @() collects that one item into a
  # NEW one-element array whose single element is the original array - i.e. double-nesting, not
  # double protection. Confirmed live with 2 configured projects: Where-Object's `$_.id -eq
  # $activeId` then ran against the one OUTER (nested) element, whose `.id` auto-projects across
  # BOTH inner projects as an array (@('wtproj','trackproj')); PowerShell's `-eq` against an array
  # LHS acts as a filter, not a scalar comparison, so it returned a non-empty (truthy) array
  # whenever activeId matched ANY project - and Select-Object -First 1 then handed back the
  # entire nested blob as the "one" match, silently returning BOTH projects welded together
  # instead of just the active one.
  param([string]$Id)
  $projects = Get-StgProjects
  if (-not $projects.Count) { return $null }
  if ($Id) { return ($projects | Where-Object { $_.id -eq $Id } | Select-Object -First 1) }
  $cfg = Get-StgConfig
  $activeId = [string]$cfg.activeProject
  if ($activeId) {
    $found = $projects | Where-Object { $_.id -eq $activeId } | Select-Object -First 1
    if ($found) { return $found }
  }
  return ($projects | Select-Object -First 1)
}

# Every git repo a tracking-mode project's dev_workspace should list - direct children of $Root
# with a .git DIRECTORY (a real clone; a git WORKTREE's .git is a file, so this naturally excludes
# one, same ground-truth test Get-HomeBaseApps/host.ps1's 'apps' scan use for worktree mode), plus
# children of $Root\repositories\ if that folder exists (matching worktree mode's own layout
# convention). Falls back to '.' when $Root itself is a git repo with no sub-repos at all - the
# original "root IS the one repo" assumption this whole function replaces, kept working for that
# shape rather than silently returning nothing for it. Returns relative, forward-slash paths
# ('workout-tracker-ui', 'repositories/foo'), suitable for a .code-workspace folder entry.
# Built via ForEach-Object, not member-enumeration off a possibly-empty Get-ChildItem result -
# CLAUDE.md's documented @($null) trap applies here too (an empty collection's dot-notation/member
# access bottoms out at bare $null, and @() around that is a one-element array OF null, not zero).
function Get-StgTrackingRepos {
  param([Parameter(Mandatory)][string]$Root)
  $repos = @()
  $topChildren = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue
  $repos += @($topChildren | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container
  } | ForEach-Object { $_.Name })

  $reposRootPath = Join-Path $Root 'repositories'
  if (Test-Path -LiteralPath $reposRootPath -PathType Container) {
    $nested = Get-ChildItem -LiteralPath $reposRootPath -Directory -Force -ErrorAction SilentlyContinue
    $repos += @($nested | Where-Object {
      Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container
    } | ForEach-Object { "repositories/$($_.Name)" })
  }

  if ($repos.Count -eq 0) {
    if (Test-Path -LiteralPath (Join-Path $Root '.git') -PathType Container) { return @('.') }
    return @()
  }
  return $repos
}

# Writes (always regenerates - this is a GENERATED file, same convention as worktree mode's own
# main_workspace) <Root>\dev_workspace.code-workspace from a fresh Get-StgTrackingRepos scan, so a
# newly-cloned repo shows up the next time it's opened with nothing to click. Throws a clear error
# when the scan finds nothing, rather than writing an empty/useless workspace file. Keeps the
# existing window.title convention ("Dev - <name> ..."). Returns the path written.
function Write-StgDevWorkspace {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ProjectName
  )
  $repos = Get-StgTrackingRepos -Root $Root
  if ($repos.Count -eq 0) {
    throw "No git repositories found under $Root - clone one first."
  }
  $folders = @($repos | ForEach-Object {
    $leaf = if ($_ -eq '.') { $ProjectName } else { Split-Path $_ -Leaf }
    [ordered]@{ name = $leaf; path = $_ }
  })
  $devWs = [ordered]@{
    folders  = $folders
    settings = [ordered]@{ 'window.title' = "Dev - $ProjectName `${separator} `${activeEditorShort}" }
  }
  $devWsPath = Join-Path $Root 'dev_workspace.code-workspace'
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($devWsPath, ($devWs | ConvertTo-Json -Depth 6), $utf8NoBom)
  return $devWsPath
}

# Everything a tracking-mode project needs that isn't the bare stories.json registry: the
# .gitignore entries for the hybrid commit model, DESIGN.md/ROADMAP.md skeletons, and
# main_workspace/dev_workspace. ONE implementation, two callers - New-StgProject (brand-new
# project, called unconditionally) and tools\setup-dev-loop.ps1 (retrofitting a project that was
# added before this feature existed, called only after a human confirms). Every write here is
# guarded by its own Test-Path/already-present check, so calling this on a project that already
# has some or all of these is always a safe no-op for whatever's already there - same "never touch
# a real file" caution the rest of this module follows. Returns an array of
# {item, path, created} so a caller can report exactly what it did (or would do).
function New-StgTrackingScaffold {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$DocsDir = '.claude\stories',
    [Parameter(Mandatory)][string]$ProjectName
  )
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $report = @()

  $docsDirPath = Join-Path $Root $DocsDir
  if (-not (Test-Path $docsDirPath)) { New-Item -ItemType Directory -Path $docsDirPath -Force | Out-Null }
  $storiesPath = Join-Path $docsDirPath 'stories.json'
  $storiesExisted = Test-Path $storiesPath
  if (-not $storiesExisted) {
    $storiesJson = ([ordered]@{ stories = [ordered]@{} }) | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($storiesPath, $storiesJson, $utf8NoBom)
  }
  $report += [pscustomobject]@{ name = 'stories.json'; path = $storiesPath; created = -not $storiesExisted }

  # .gitignore entries (hybrid commit model) - see New-StgProject's own comment for the full
  # reasoning; kept here verbatim since this IS that logic now, just callable a second way.
  # Additive ONLY - append whichever lines are missing, never touch anything else in the file.
  $gitignorePath = Join-Path $Root '.gitignore'
  $docsDirFwd = $DocsDir.Replace('\', '/')
  $ignoreLines = @("$docsDirFwd/*.story-ship-state.json", "$docsDirFwd/*.lock")
  $existingIgnore = if (Test-Path $gitignorePath) { [System.IO.File]::ReadAllText($gitignorePath) } else { '' }
  $existingLines = @($existingIgnore -split "`r?`n" | ForEach-Object { $_.Trim() })
  $missingLines = @($ignoreLines | Where-Object { $existingLines -notcontains $_ })
  if ($missingLines.Count -gt 0) {
    $header = '# story-tab-groups: ephemeral lock/ledger files - the durable docs above them (stories.json, DESIGN.md, ROADMAP.md, each story''s own .md) are committed; these live pointers aren''t'
    $block = "$header`n$($missingLines -join "`n")`n"
    $newIgnoreContent = if ($existingIgnore) { ($existingIgnore.TrimEnd("`r", "`n")) + "`n`n" + $block } else { $block }
    [System.IO.File]::WriteAllText($gitignorePath, $newIgnoreContent, $utf8NoBom)
  }
  $report += [pscustomobject]@{ name = '.gitignore entries'; path = $gitignorePath; created = ($missingLines.Count -gt 0) }

  $designPath = Join-Path $Root 'DESIGN.md'
  $designExisted = Test-Path $designPath
  if (-not $designExisted) {
    $designSkeleton = "# Design`n`nBrainstormed decisions for $ProjectName, grouped by topic. See the story-tab-groups skill's `"Planning discipline`" section for how this gets used.`n`n## LOCKED`n`n## OPEN`n`n## REJECTED`n"
    [System.IO.File]::WriteAllText($designPath, $designSkeleton, $utf8NoBom)
  }
  $report += [pscustomobject]@{ name = 'DESIGN.md'; path = $designPath; created = -not $designExisted }

  $roadmapPath = Join-Path $Root 'ROADMAP.md'
  $roadmapExisted = Test-Path $roadmapPath
  if (-not $roadmapExisted) {
    $roadmapSkeleton = "# Roadmap`n`nOne row per story once its brainstorm topic is LOCKED (see DESIGN.md) and it's been created. Update on real status changes, not every ledger phase tick.`n`n| Story | Status | Notes |`n|---|---|---|`n"
    [System.IO.File]::WriteAllText($roadmapPath, $roadmapSkeleton, $utf8NoBom)
  }
  $report += [pscustomobject]@{ name = 'ROADMAP.md'; path = $roadmapPath; created = -not $roadmapExisted }

  # main_workspace / dev_workspace - see New-StgProject's own comment for why these live at the
  # repo root with a relative '.' path rather than via $Paths.WorkspaceDir (null in tracking mode
  # by design) or an absolute path.
  $mainWsPath = Join-Path $Root 'main_workspace.code-workspace'
  $mainWsExisted = Test-Path $mainWsPath
  if (-not $mainWsExisted) {
    $mainWs = [ordered]@{
      folders  = @([ordered]@{ name = $ProjectName; path = '.' })
      settings = [ordered]@{ 'window.title' = "Planning - $ProjectName `${separator} `${activeEditorShort}" }
    }
    [System.IO.File]::WriteAllText($mainWsPath, ($mainWs | ConvertTo-Json -Depth 6), $utf8NoBom)
  }
  $report += [pscustomobject]@{ name = 'main_workspace.code-workspace'; path = $mainWsPath; created = -not $mainWsExisted }

  # Unlike main_workspace (always '.', since planning needs DESIGN.md/ROADMAP.md at the root),
  # dev_workspace lists only the actual git repos (Get-StgTrackingRepos/Write-StgDevWorkspace) - see
  # CLAUDE.md's main_workspace/dev_workspace section for why. A brand-new project with nothing
  # cloned yet has no repos to list; Write-StgDevWorkspace throws in that case, so this never fails
  # project-add over it - it's reported as not-created and the popup's own "🛠 Dev workspace" button
  # creates it later, once something's actually cloned. Never overwrites an existing file here (this
  # function's own "never touch a real file" rule) - a stale repo list gets refreshed by the button,
  # not by re-running project setup.
  $devWsPath = Join-Path $Root 'dev_workspace.code-workspace'
  $devWsExisted = Test-Path $devWsPath
  $devWsCreated = $false
  if (-not $devWsExisted) {
    try { Write-StgDevWorkspace -Root $Root -ProjectName $ProjectName | Out-Null; $devWsCreated = $true } catch {}
  }
  $report += [pscustomobject]@{ name = 'dev_workspace.code-workspace'; path = $devWsPath; created = $devWsCreated }

  # worktree\ / workspace\ - cosmetic-only, for structural consistency with a worktree-mode
  # project's own root layout (which gets these same two subfolders for real use - see
  # New-StgProject's worktree branch). Tracking mode has no worktree/workspace CONCEPT at all -
  # Resolve-StgPaths still returns WorktreeRoot/WorkspaceDir as $null here, nothing reads or writes
  # into these folders, they just exist so a tracking-mode root doesn't look structurally different
  # from a worktree-mode one for no reason a person looking at the folder would understand.
  $wtFolderPath = Join-Path $Root 'worktree'
  $wtFolderExisted = Test-Path $wtFolderPath
  if (-not $wtFolderExisted) { New-Item -ItemType Directory -Path $wtFolderPath -Force | Out-Null }
  $report += [pscustomobject]@{ name = 'worktree folder'; path = $wtFolderPath; created = -not $wtFolderExisted }

  $wsFolderPath = Join-Path $Root 'workspace'
  $wsFolderExisted = Test-Path $wsFolderPath
  if (-not $wsFolderExisted) { New-Item -ItemType Directory -Path $wsFolderPath -Force | Out-Null }
  $report += [pscustomobject]@{ name = 'workspace folder'; path = $wsFolderPath; created = -not $wsFolderExisted }

  return $report
}

function New-StgProject {
  # Creates a new project: validates the root, auto-slugifies + uniquifies an id from -Name, appends
  # to projects[]. Becomes activeProject only when it's the FIRST project ever configured - adding a
  # second/third project later never silently steals activeProject away from whatever's already
  # being worked in.
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Root,
    [string]$Mode = 'worktree'
  )
  if (-not (Test-StgRootValid $Root)) { throw "root does not exist: $Root" }
  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $cfg = Get-StgConfig
  $merged = ConvertTo-StgHashtable $cfg
  # Plain assignment, NOT @(Get-StgProjects) - Get-StgProjects already -NoEnumerates its own return,
  # so wrapping the CALL in another @() double-nests (confirmed: it silently dropped every
  # previously-existing project when a second one was added, since the corrupted shape propagated
  # into the projects[] write below). See Get-StgProject's comment for the full mechanism.
  $existing = Get-StgProjects

  $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug) { $slug = 'project' }
  $id = $slug
  $n = 1
  while (@($existing | Where-Object { $_.id -eq $id }).Count) { $n++; $id = "$slug-$n" }

  $newProj = [ordered]@{ id = $id; name = $Name; mode = $Mode; root = $resolvedRoot }
  # Worktree mode's new default: a dedicated <root>\worktree\ and <root>\workspace\ subfolder
  # pair, baked into THIS project's own record at creation time - not into Resolve-StgPaths'
  # fallback logic, which stays exactly as it was (Root itself / an external _WorkSpaces sibling)
  # for any EXISTING project that has no worktreeRoot/workspaceRoot field of its own. Changing the
  # fallback would silently move where an already-configured project's future worktrees land;
  # setting the field explicitly here only ever affects a project added from this point on. Found
  # worth doing after noticing a real project's manually-configured worktreeRoot/workspaceRoot
  # already used exactly this <root>\worktree / <root>\workspace shape - tidier than the default,
  # worth making the default rather than something you have to discover and configure by hand.
  if ($Mode -eq 'worktree') {
    $newProj['worktreeRoot'] = Join-Path $resolvedRoot 'worktree'
    $newProj['workspaceRoot'] = Join-Path $resolvedRoot 'workspace'
    # Same reasoning, one folder over: home-base app clones default to a dedicated <root>\
    # repositories\ subfolder now too, not flatly mixed into Root alongside worktree\/workspace\/
    # tools\ etc. Tracking mode gets NO equivalent here (confirmed out of scope) - unlike
    # worktree\/workspace\, "repositories" specifically means clones alongside a container root,
    # which a tracking project's root (already the one tracked repo) has no analog for.
    $newProj['reposRoot'] = Join-Path $resolvedRoot 'repositories'
  }
  $merged['projects'] = @($existing + [pscustomobject]$newProj)
  if (-not $merged.Contains('activeProject') -or -not $merged['activeProject']) {
    $merged['activeProject'] = $id
    # This project just became active - the top-level mirror has to point at it too, or a zero-arg
    # Resolve-StgPaths call reaching step 3's legacy fallback (only possible before ANY project
    # exists) would be the last moment $cfg.root could still be stale/blank on a fresh install.
    $merged['root'] = $resolvedRoot
  }
  Set-StgConfig -Config $merged

  # Auto-create both files a worktree-mode project needs to actually be usable, IN THE PROJECT'S
  # OWN ROOT - never overwriting a real file. Found necessary by live testing, not by design: a
  # project added via this function had NOTHING here until now, and switch-story.ps1's Read-Registry
  # (its own local override) throws "stories.json not found" with no fallback - so "+ Add project"
  # then "+ New story" for the very first story in it would fail immediately, every time, unless the
  # user manually dropped a stories.json into the folder first. Gated on worktree mode specifically:
  # a tracking-mode project's registry lives at a different path entirely (<root>\<docsDir>\
  # stories.json, once P5 ships) and doesn't use app-map.json's port/start/health concept at all.
  if ($Mode -eq 'worktree') {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $newStoriesPath = Join-Path $resolvedRoot 'stories.json'
    if (-not (Test-Path $newStoriesPath)) {
      $storiesJson = ([ordered]@{ stories = [ordered]@{} }) | ConvertTo-Json -Depth 5
      [System.IO.File]::WriteAllText($newStoriesPath, $storiesJson, $utf8NoBom)
    }
    $newAppMapPath = Join-Path $resolvedRoot 'app-map.json'
    if (-not (Test-Path $newAppMapPath)) {
      $appMapJson = ([ordered]@{ pythonSentinel = 'fastapi'; apps = [ordered]@{} }) | ConvertTo-Json -Depth 5
      [System.IO.File]::WriteAllText($newAppMapPath, $appMapJson, $utf8NoBom)
    }
    # The actual folders matching worktreeRoot/workspaceRoot set on $newProj above - without these,
    # Settings' Paths & diagnostics 'Worktree root exists' check would show a false negative from
    # the very first popup load, and Resolve-StgPaths' fallback favors non-existent-but-configured
    # paths over guessing, so nothing else would create these first either.
    if (-not (Test-Path $newProj['worktreeRoot'])) { New-Item -ItemType Directory -Path $newProj['worktreeRoot'] -Force | Out-Null }
    if (-not (Test-Path $newProj['workspaceRoot'])) { New-Item -ItemType Directory -Path $newProj['workspaceRoot'] -Force | Out-Null }
    if (-not (Test-Path $newProj['reposRoot'])) { New-Item -ItemType Directory -Path $newProj['reposRoot'] -Force | Out-Null }
  }
  elseif ($Mode -eq 'tracking') {
    # Same reasoning as worktree mode's auto-create, one path shape over: a tracking project's
    # registry lives at <root>\<docsDir>\stories.json (not <root>\stories.json - Resolve-StgPaths'
    # own tracking branch computes this identically), and nothing should need a manual file-prep
    # step before its first story any more than a worktree-mode project does. No app-map.json here
    # - tracking mode has no worktrees/apps concept to map. Everything else a tracking project
    # needs (the .gitignore entries, DESIGN.md/ROADMAP.md, main_workspace/dev_workspace) is the
    # SAME logic tools\setup-dev-loop.ps1 uses to retrofit a project added before this feature
    # existed - one implementation, not two copies to keep in sync.
    New-StgTrackingScaffold -Root $resolvedRoot -DocsDir '.claude\stories' -ProjectName $Name | Out-Null
  }

  return [pscustomobject]$newProj
}

function Update-StgProject {
  # Patches ONE named project's fields directly, independent of which project is currently active -
  # Update-StgConfig's own dual-write only ever touches the ACTIVE project's slot in projects[], so a
  # Settings page editing a NON-active project needs this separate path. If the patched id happens to
  # BE the active one, also refreshes the top-level mirror + defaults it feeds, same reasoning
  # Update-StgConfig's own dual-write documents - so a caller that still reads the mirror
  # (Resolve-StgPaths' legacy branch, Get-StgOrgDefaults' zero-arg path) never sees a stale value.
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][hashtable]$Patch
  )
  $cfg = Get-StgConfig
  $merged = ConvertTo-StgHashtable $cfg
  # Plain assignment, NOT @(Get-StgProjects) - Get-StgProjects already -NoEnumerates its own return,
  # so wrapping the CALL in another @() double-nests (confirmed: it silently dropped every
  # previously-existing project when a second one was added, since the corrupted shape propagated
  # into the projects[] write below). See Get-StgProject's comment for the full mechanism.
  $existing = Get-StgProjects
  $found = $false
  $newProjects = @($existing | ForEach-Object {
    if ($_.id -eq $Id) {
      $found = $true
      $p = ConvertTo-StgHashtable $_
      foreach ($k in $Patch.Keys) {
        if ($Patch[$k]) { $p[$k] = $Patch[$k] } else { $p.Remove($k) }
      }
      [pscustomobject]$p
    } else { $_ }
  })
  if (-not $found) { throw "unknown project id: $Id" }
  $merged['projects'] = $newProjects

  if ([string]$merged['activeProject'] -eq $Id) {
    foreach ($k in @('root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat')) {
      if ($Patch.ContainsKey($k)) {
        if ($Patch[$k]) { $merged[$k] = $Patch[$k] } else { $merged.Remove($k) }
      }
    }
    # Mirror the EFFECTIVE value into the top-level field - every zero-arg Get-StgOrgDefaults caller
    # (every tools\*.ps1 script that doesn't pass -Project) still reads the top-level field directly,
    # not defaults.<field>, and today has no concept of "this project's own override" at all. Reads
    # defaults as a FALLBACK when the project's own override is being cleared; never WRITES defaults
    # - defaults is the global layer every OTHER project also falls back to, and no UI in this phase
    # edits it directly, so a per-project edit must never leak into it (that would silently change a
    # different project's fallback value out from under it).
    foreach ($k in @('jiraBaseUrl', 'githubOrg', 'repoAliases', 'taskNamePrefix', 'owner')) {
      if (-not $Patch.ContainsKey($k)) { continue }
      if ($Patch[$k]) { $merged[$k] = $Patch[$k]; continue }
      $dVal = if ($merged.Contains('defaults') -and $merged['defaults'] -and ($merged['defaults'].PSObject.Properties.Name -contains $k)) { $merged['defaults'].$k } else { $null }
      if ($dVal) { $merged[$k] = $dVal } else { $merged.Remove($k) }
    }
  }

  Set-StgConfig -Config $merged
  return ($newProjects | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Remove-StgProject {
  # Forgets a project - removes it from projects[] only. Never touches stories.json, worktrees, or
  # the repo itself on disk; this is "unpin", not "delete". If it was the active project, falls back
  # to the first remaining one, or clears activeProject entirely if none remain.
  param([Parameter(Mandatory)][string]$Id)
  $cfg = Get-StgConfig
  $merged = ConvertTo-StgHashtable $cfg
  # Plain assignment, NOT @(Get-StgProjects) - Get-StgProjects already -NoEnumerates its own return,
  # so wrapping the CALL in another @() double-nests (confirmed: it silently dropped every
  # previously-existing project when a second one was added, since the corrupted shape propagated
  # into the projects[] write below). See Get-StgProject's comment for the full mechanism.
  $existing = Get-StgProjects
  $remaining = @($existing | Where-Object { $_.id -ne $Id })
  if ($remaining.Count -eq $existing.Count) { throw "unknown project id: $Id" }
  $merged['projects'] = $remaining
  if ([string]$merged['activeProject'] -eq $Id) {
    if ($remaining.Count) {
      # A different project just became active by fallback (not by an explicit edit) - the
      # top-level mirror has to fully switch to ITS effective values, or every zero-arg
      # Get-StgOrgDefaults/legacy Resolve-StgPaths caller keeps reading the just-removed project's
      # stale settings until something else happens to touch the same fields. Same "own field, else
      # defaults, else absent" resolution Update-StgProject uses for a single field, applied here to
      # every mirrored field since this is a full switch, not a patch.
      $newActive = $remaining[0]
      $merged['activeProject'] = $newActive.id
      foreach ($k in @('root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat')) {
        $v = if ($newActive.PSObject.Properties.Name -contains $k) { $newActive.$k } else { $null }
        if ($v) { $merged[$k] = $v } else { $merged.Remove($k) }
      }
      foreach ($k in @('jiraBaseUrl', 'githubOrg', 'repoAliases', 'taskNamePrefix', 'owner')) {
        $ownVal = if ($newActive.PSObject.Properties.Name -contains $k) { $newActive.$k } else { $null }
        if ($ownVal) { $merged[$k] = $ownVal; continue }
        $dVal = if ($merged.Contains('defaults') -and $merged['defaults'] -and ($merged['defaults'].PSObject.Properties.Name -contains $k)) { $merged['defaults'].$k } else { $null }
        if ($dVal) { $merged[$k] = $dVal } else { $merged.Remove($k) }
      }
    } else {
      $merged.Remove('activeProject')
      foreach ($k in @('root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'repoAliases', 'taskNamePrefix', 'owner')) { $merged.Remove($k) }
    }
  }
  Set-StgConfig -Config $merged
  return $true
}

function Set-StgConfig {
  param([Parameter(Mandatory)][hashtable]$Config)
  $p = Get-StgConfigPath
  # Guard against the #1 data-loss risk this schema introduces: a caller that builds its own
  # hashtable from a field allowlist (exactly what native-host\host.ps1's setConfig action used to
  # do before it was converted to Update-StgConfig, and any future/vendored copy of that pattern
  # would too) and calls this directly would otherwise silently delete the entire project list on
  # write. If the incoming hashtable doesn't mention 'projects' at all but the file on disk
  # already has one, re-attach projects/defaults/version/activeProject from disk before writing.
  # A DELIBERATE removal always goes through Update-StgConfig, which always includes 'projects' in
  # what it writes (even as the unchanged array) - so this guard can never resurrect a delete that
  # was actually intended.
  if (-not $Config.Contains('projects')) {
    $onDisk = Get-StgConfig
    if ($onDisk -and ($onDisk.PSObject.Properties.Name -contains 'projects') -and $onDisk.projects) {
      foreach ($k in @('projects', 'defaults', 'version', 'activeProject')) {
        if ($onDisk.PSObject.Properties.Name -contains $k) { $Config[$k] = $onDisk.$k }
      }
    }
  }
  $json = $Config | ConvertTo-Json -Depth 10
  # BOM-less, matching every other JSON file this tool writes (StoryLib.psm1's Write-Utf8NoBom
  # convention) - a BOM here would double-encode under PS 5.1 the same way the module's own
  # ASCII-only rule exists to avoid.
  [System.IO.File]::WriteAllText($p, $json, [System.Text.UTF8Encoding]::new($false))
}

function Update-StgConfig {
  <#
    .SYNOPSIS
      The write path every setConfig-shaped caller should use from here on.
    .DESCRIPTION
      Read-modify-write: starts from Get-StgConfig's FULL current shape (already v2 in memory),
      then for every key present in -Patch either sets it (a truthy value) or removes it ($null /
      '' / an empty array - one uniform rule, matching the set-or-clear convention
      native-host\host.ps1's setConfig action already applied per-field before this existed). A
      key absent from -Patch is left exactly as it was - including 'projects', 'defaults',
      'version' and 'activeProject', which the caller never has to know about or re-list just to
      change one flat field. This alone is what closes the data-loss trap Set-StgConfig's own
      guard exists to backstop.

      Also keeps the (currently unread outside this module - P2/P3 territory) projects[]/defaults
      copies in sync with whichever top-level field just changed, so a value set today through the
      flat setConfig path is not silently stale by the time a later phase switches to reading
      THOSE instead of the top-level mirror.
    #>
  param([Parameter(Mandatory)][hashtable]$Patch)

  $cfg = Get-StgConfig
  $merged = ConvertTo-StgHashtable $cfg
  foreach ($k in $Patch.Keys) {
    if ($Patch[$k]) { $merged[$k] = $Patch[$k] } else { $merged.Remove($k) }
  }

  # Org fields (jiraBaseUrl etc) are unified into the SAME per-active-project write path/name/
  # fields already use, NOT a separate write into 'defaults'. They used to write into defaults too
  # (P1) - harmless with exactly one project, since the active project's own value and the global
  # fallback were never meaningfully different. Once a SECOND project exists and relies on defaults
  # as ITS OWN fallback, that became a real cross-project leak: editing the active project's Jira
  # URL through this flat legacy path would silently change project B's fallback value too. Fixed
  # by treating org fields exactly like path fields here - write into the active project's OWN
  # projects[] entry only, never into the shared defaults layer. (Update-StgProject, the NEW
  # per-project edit path P4's Settings cards actually use, implements the fuller "clear falls
  # through to defaults" ladder for the top-level mirror; this flat legacy path does not need to -
  # a zero-arg legacy reader never had defaults-awareness to begin with, so simply reverting to the
  # hardcoded default on clear, as it always has, is not a regression for it.)
  $projectFields = @('root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'hiddenApps',
    'jiraBaseUrl', 'githubOrg', 'repoAliases', 'taskNamePrefix', 'owner')
  $touchedProjectFields = @($projectFields | Where-Object { $Patch.ContainsKey($_) })

  if ($touchedProjectFields.Count -and $merged.Contains('projects') -and $merged['projects']) {
    $activeId = [string]$merged['activeProject']
    $merged['projects'] = @(@($merged['projects']) | ForEach-Object {
      if (-not $activeId -or $_.id -eq $activeId) {
        $proj = ConvertTo-StgHashtable $_
        foreach ($f in $touchedProjectFields) {
          if ($merged.Contains($f) -and $merged[$f]) { $proj[$f] = $merged[$f] } else { $proj.Remove($f) }
        }
        [pscustomobject]$proj
      } else { $_ }
    })
  }

  # activeProject switching to a DIFFERENT project: the top-level mirror has to fully switch to the
  # NEWLY active project's own effective values (own field, else defaults, else absent) - the same
  # "full switch, not a patch" resolution Remove-StgProject's fallback uses, needed here because the
  # popup's project dropdown pushes activeProject through this exact function.
  if ($Patch.ContainsKey('activeProject') -and $Patch['activeProject'] -and [string]$cfg.activeProject -ne [string]$Patch['activeProject']) {
    # Plain assignment, NOT @(Get-StgProjects) - see the repeated comment elsewhere in this file for
    # why that extra @() double-nests and silently corrupts the result.
    $allProjects = Get-StgProjects
    $newActive = $allProjects | Where-Object { $_.id -eq [string]$Patch['activeProject'] } | Select-Object -First 1
    if ($newActive) {
      foreach ($k in @('root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat')) {
        $v = if ($newActive.PSObject.Properties.Name -contains $k) { $newActive.$k } else { $null }
        if ($v) { $merged[$k] = $v } else { $merged.Remove($k) }
      }
      foreach ($k in @('jiraBaseUrl', 'githubOrg', 'repoAliases', 'taskNamePrefix', 'owner')) {
        $ownVal = if ($newActive.PSObject.Properties.Name -contains $k) { $newActive.$k } else { $null }
        if ($ownVal) { $merged[$k] = $ownVal; continue }
        $dVal = if ($merged.Contains('defaults') -and $merged['defaults'] -and ($merged['defaults'].PSObject.Properties.Name -contains $k)) { $merged['defaults'].$k } else { $null }
        if ($dVal) { $merged[$k] = $dVal } else { $merged.Remove($k) }
      }
    }
  }

  Set-StgConfig -Config $merged
  return $merged
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
  # Four-rung ladder for a resolved project:
  #   1. <project.root>\app-map.json          - the CANONICAL location as of this ladder version.
  #      New-StgProject creates this (empty) for every project from here on, same folder as its
  #      stories.json - a project is meant to be self-contained, findable/back-up-able as one folder,
  #      not split between its own root and the extension's %LOCALAPPDATA%.
  #   2. %LOCALAPPDATA%\story-tab-groups\projects\<id>\app-map.json - the OLD per-project location
  #      (this ladder's previous top rung). Kept as a READ-ONLY fallback for any project that already
  #      has real data there from before this rung existed (confirmed via live testing: a real
  #      project's saved port/start/health map) - never written to again; native-host\host.ps1's
  #      setappmap action always writes to rung 1 now, so a project sitting on this rung
  #      self-migrates the moment its Apps card is next saved, no separate migration step needed.
  #   3. %LOCALAPPDATA%\story-tab-groups\app-map.json - the shared singleton, ONLY while at most one
  #      project is configured total (see the comment further down - unchanged from the previous
  #      version of this ladder).
  #   4. tools\app-map.json - the shipped template, last resort.
  # An untouched, -Project-less call skips straight to rungs 3-4, exactly as before either rung 1 or
  # today's per-project rungs existed.
  #
  # THE SHARED SINGLETON RUNG (3) ONLY APPLIES WHILE AT MOST ONE PROJECT EXISTS. Found by live
  # testing, not design review: an earlier version of this ladder let ANY project with no
  # per-project file fall back to the shared singleton unconditionally - meaning a brand-new SECOND
  # project silently inherited the FIRST project's entire app-map (shown as "mapped but not cloned"
  # placeholders for apps it never had anything to do with) the instant it was created. That's the
  # exact cross-project leak this whole feature exists to prevent, just on the read side instead of
  # the write side (see native-host\host.ps1's setappmap fix). Once a second project exists, a
  # project with nothing saved anywhere gets a genuinely empty map - moot for any project created
  # after New-StgProject started auto-creating rung 1 unconditionally, since it always has SOMETHING
  # there from the moment it exists; still relevant for a pre-existing install's sole project that
  # hasn't been touched since.
  param([string]$Project)
  # No live caller passed -Project before P3/P4 - the path-traversal guard predates any real
  # caller, cheap insurance since a project id now DOES arrive from an external native-messaging
  # caller: reject anything that could path-traverse out of the projects\ folder rather than
  # silently Join-Path-ing it in.
  if ($Project -and $Project -notmatch '[\\/]' -and $Project -ne '..') {
    $proj = Get-StgProject -Id $Project
    if ($proj -and $proj.root) {
      $rootRung = Join-Path ([string]$proj.root) 'app-map.json'
      if (Test-Path $rootRung) { return $rootRung }
    }
    $perProject = Join-Path (Get-StgUserConfigDir) "projects\$Project\app-map.json"
    if (Test-Path $perProject) { return $perProject }
    # Plain assignment, not @(Get-StgProjects) or a direct pipe - see the module-wide -NoEnumerate
    # rule documented on Get-StgProjects/Get-StgProject.
    $allProjects = Get-StgProjects
    if ($allProjects.Count -gt 1) {
      # Nothing on any rung yet for a project that isn't alone anymore - the caller's own creation
      # path (New-StgProject) should have already written rung 1; this is the "resolve a path to
      # write to" case (a fresh install racing setappmap before New-StgProject's own write lands,
      # or a hand-edited config), so hand back rung 1's path even though nothing is there yet.
      return $rootRung
    }
  }
  $user = Join-Path (Get-StgUserConfigDir) 'app-map.json'
  if (Test-Path $user) { return $user }
  return (Join-Path $PSScriptRoot 'app-map.json')
}

function Get-StgLedgerPath {
  # Resolves one story's ledger file path from a Resolve-StgPaths result and its registry node -
  # the single implementation of the "$effRoot = $node.worktreeRoot ?? $Paths.Root" idiom.
  #
  # That idiom was already correct in remove-worktree.ps1 and story-ledger.ps1 (each computes its
  # own $effRoot inline), but MISSING in vault-status.ps1, story-status.ps1, story-release.ps1 and
  # native-host\host.ps1's 'ledgers' action - all four hardcoded `Join-Path $Root $Story`, so a
  # story created under a worktreeRoot that differs from Root had its ledger silently read from
  # the wrong place by every one of those (released state showing as never-deployed, vault-status's
  # per-story phase checklist always saying "no ledger", the EOD digest missing its phase deltas,
  # the popup's ledger fetch coming back empty) even though story-ledger.ps1 itself - the thing that
  # WROTE the ledger - had gotten this right the whole time.
  param(
    [Parameter(Mandatory)]$Paths,
    [Parameter(Mandatory)][string]$Story,
    $Node
  )
  # Tracking mode: $Paths.Root genuinely IS the tracked git repo (unlike worktree mode, where root
  # is a plain container folder several levels above any actual repo) - a bare <root>\<STORY>\
  # folder here would create untracked clutter inside it, showing up in that repo's own `git
  # status`. Keep every tracking-mode artifact together under docsDir instead, same place its own
  # stories.json/doc file already live, rather than scattering a stray folder into repo root.
  if ($Paths.Mode -eq 'tracking') {
    $docsDir = if ($Paths.DocsDir) { [string]$Paths.DocsDir } else { '.claude\stories' }
    return (Join-Path (Join-Path $Paths.Root $docsDir) "$Story.story-ship-state.json")
  }
  $effRoot = if ($Node -and $Node.worktreeRoot) { [string]$Node.worktreeRoot } else { $Paths.Root }
  Join-Path (Join-Path $effRoot $Story) '.story-ship-state.json'
}

# Tracking mode's counterpart to Get-StgLedgerPath: <root>\<docsDir>\<STORY>.md - one markdown doc
# per story, Claude's work-log for that story, living next to (not nested per-story like
# worktree-mode's ledger) the tracking registry itself. Deferred from P0 (no caller existed until
# P5's story-doc.ps1) to here, where it's actually needed. No $Node/worktreeRoot concept in
# tracking mode - a story's doc always lives at this one path, there is nothing to override.
function Get-StgStoryDocPath {
  param(
    [Parameter(Mandatory)]$Paths,
    [Parameter(Mandatory)][string]$Story
  )
  $docsDir = if ($Paths.DocsDir) { [string]$Paths.DocsDir } else { '.claude\stories' }
  Join-Path (Join-Path $Paths.Root $docsDir) "$Story.md"
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
      Resolves the data root + every derived path, reports which rule decided the root, AND which
      project context applies.
    .DESCRIPTION
      Two questions, resolved in order:

      1. WHICH PROJECT CONTEXT applies (mode, docsDir, org settings, branch format, hiddenApps)?
           a. -Project <id> - looked up by id. A miss is a hard error (NeedsSetup), never a silent
              fallback to something the caller didn't ask for.
           b. -Root <path> alone - reverse lookup: does any configured project's own .root match
              the given path? A hit adopts that project's context; a miss falls through to (3)
              below with NO project context - today's exact synthetic behavior, unchanged.
           c. Neither given - the configured active project (or the sole project, or none on a
              genuinely project-less install).
         Reported via .ProjectSource: 'parameter' / 'parameter (invalid)' / 'root-match' / 'active'
         / 'none'.

      2. IF a project context was found, every path is resolved from THAT PROJECT'S OWN fields
         (root/worktreeRoot/workspaceRoot/branchFormat/mode/docsDir/hiddenApps) - -Root/
         -WorktreeRoot params still override .Root/.WorktreeRoot specifically, layered on the
         PROJECT's fields rather than the top-level mirror, because a NON-active project's own
         settings must never be shadowed by whichever project happens to be active elsewhere. An
         invalid/moved project root is a hard failure here too - it must never fall through to
         Find-StgRootUpward, which could silently auto-detect an unrelated tree.

      3. IF NO project context was found (a genuinely project-less install, or a -Root matching no
         configured project), resolution falls through to the ORIGINAL single-root logic,
         unchanged:
           a. -Root parameter (explicit override, e.g. host.ps1 relaying a Settings-page value)
           b. stg-config.json 'root' field - validated as a real directory (Test-Path -PathType
              Container); a stale/invalid value here is SKIPPED, not silently accepted, unlike the
              old host.ps1 inline resolver.
           c. $env:STG_ROOT
           d. Auto-detect: walk up from this module's own folder looking for stories.json.
           e. None of the above -> NeedsSetup = $true. Callers must check this before touching
              StoriesPath etc. - they will point at a nonexistent location.

      For today's real single-project install with no explicit -Project/-Root, step 1 ALWAYS finds
      that project (P1's migration synthesizes one as soon as 'root' is configured), so step 2
      fires - but Update-StgConfig keeps the project record's fields mirror-synced with the
      top-level fields step 3 would have used, so the two paths produce identical output.
      Byte-identical by construction, not by only ever exercising the common path.

      Config outranks the environment variable in step 3, not the other way around - deliberately,
      and it wasn't always this order. $env:STG_ROOT lives in the OS environment block, which a
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

      Deliberately no $env:STG_PROJECT: that precedence would recreate the exact frozen-environment
      bug documented above for $env:STG_ROOT, inverted - a stale env value in a long-lived Chrome
      would beat whatever the popup's project dropdown actually has selected.
  #>
  param(
    [string]$Root,
    [string]$WorktreeRoot,
    [string]$Project
  )

  # ---- Step 1: identify the project context, independent of Root resolution --------------------
  $projectRecord = $null
  $projectSource = 'none'
  if ($Project) {
    $projectRecord = Get-StgProject -Id $Project
    if ($projectRecord) { $projectSource = 'parameter' }
    else {
      return [pscustomobject]@{
        Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ReposRoot = $null; ScriptDir = $PSScriptRoot
        StoriesPath = $null; HistoryPath = $null; AppMapPath = (Get-StgAppMapPath -Project $Project)
        UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
        Source = 'parameter (invalid)'; NeedsSetup = $true
        Error = "Unknown project id: $Project"
        ProjectId = $null; ProjectName = $null; Mode = $null; ProjectSource = 'parameter (invalid)'
        DocsDir = $null; BranchFormat = $null; JiraBaseUrl = $null; GithubOrg = $null
        RepoAliases = $null; HiddenApps = @(); Project = $null
      }
    }
  } elseif ($Root) {
    # Canonicalize both sides so a trailing backslash or case difference doesn't cause a miss; if
    # the given -Root no longer exists on disk, compare the raw string instead (a since-deleted
    # path can never legitimately match a configured project's still-valid root).
    $rootForMatch = $Root
    try { $rootForMatch = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path } catch {}
    # Capture into a variable FIRST, then pipe the VARIABLE - not `Get-StgProjects | Where-Object`
    # (piping the function call directly). -NoEnumerate (see Get-StgProjects) stops the pipeline
    # from unrolling its array as it crosses the function's own return boundary - which is exactly
    # what fixes plain assignment ($x = Get-StgProjects always a real array, 0/1/N elements alike),
    # but a DIRECT pipe (Get-StgProjects | Where-Object / | ForEach-Object) is itself a pipeline
    # consumer, so -NoEnumerate suppresses ITS unrolling too: Where-Object's $_ was bound to the
    # WHOLE 2-project array as one item, not to each project in turn. `.root` then auto-projected
    # across both elements (an array), and -ieq against an array LHS acts as a filter rather than
    # a scalar comparison - so a match against EITHER project let the entire pair through as if it
    # were a single result. Once the array is captured in $projects, it is an ordinary PowerShell
    # array variable and piping IT enumerates normally - only a function's live pipeline output
    # is subject to -NoEnumerate.
    $projects = Get-StgProjects
    $match = $projects | Where-Object {
      $prRoot = $_.root
      try { $prRoot = (Resolve-Path -LiteralPath $_.root -ErrorAction Stop).Path } catch {}
      $prRoot -and $prRoot.TrimEnd('\') -ieq $rootForMatch.TrimEnd('\')
    } | Select-Object -First 1
    if ($match) { $projectRecord = $match; $projectSource = 'root-match' }
  } else {
    $projectRecord = Get-StgProject
    if ($projectRecord) { $projectSource = 'active' }
  }

  # ---- Step 2: a project context was found - resolve every path from ITS OWN fields -------------
  if ($projectRecord) {
    $projRootInput = if ($Root) { $Root } else { [string]$projectRecord.root }
    if (-not ($projRootInput -and (Test-StgRootValid $projRootInput))) {
      # Hard failure, matching step 3's "-Root passed but doesn't exist" behavior - never falls
      # through to Find-StgRootUpward, which could auto-detect an unrelated, wrong tree for a
      # project the caller explicitly named.
      return [pscustomobject]@{
        Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ReposRoot = $null; ScriptDir = $PSScriptRoot
        StoriesPath = $null; HistoryPath = $null
        AppMapPath = (Get-StgAppMapPath -Project $projectRecord.id)
        UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
        Source = 'parameter (invalid)'; NeedsSetup = $true
        Error = "The root for project '$($projectRecord.id)' does not exist: $projRootInput"
        ProjectId = $projectRecord.id; ProjectName = $projectRecord.name
        Mode = if ($projectRecord.mode) { [string]$projectRecord.mode } else { 'worktree' }
        ProjectSource = $projectSource; DocsDir = $null; BranchFormat = $null
        JiraBaseUrl = $null; GithubOrg = $null; RepoAliases = $null; HiddenApps = @()
        Project = $projectRecord
      }
    }
    $projRoot = (Resolve-Path -LiteralPath $projRootInput).Path
    $mode = if ($projectRecord.mode) { [string]$projectRecord.mode } else { 'worktree' }

    $projWtRootInput = if ($WorktreeRoot) { $WorktreeRoot } elseif ($projectRecord.worktreeRoot) { [string]$projectRecord.worktreeRoot } else { $null }
    $projWtRoot = if ($projWtRootInput -and (Test-StgRootValid $projWtRootInput)) { (Resolve-Path -LiteralPath $projWtRootInput).Path } else { $projRoot }

    # ReposRoot: where home-base app clones live - same optional-override-with-Root-fallback shape
    # as WorktreeRoot just above (including falling back to Root if the configured folder is
    # missing/deleted, for consistency with that established pattern rather than a special case).
    # Tracking mode never sets this (see its return below, mirroring WorktreeRoot/WorkspaceDir's
    # existing $null-in-tracking-mode contract) - a tracking project's root already IS the one repo,
    # there's no separate "clones alongside a container root" concept to point at.
    $projReposRootInput = if ($projectRecord.reposRoot) { [string]$projectRecord.reposRoot } else { $null }
    $projReposRoot = if ($projReposRootInput -and (Test-StgRootValid $projReposRootInput)) { (Resolve-Path -LiteralPath $projReposRootInput).Path } else { $projRoot }

    $rootLeaf = Split-Path $projRoot -Leaf
    $rootParent = Split-Path $projRoot -Parent
    $workspaceDirDefault = if ($rootParent) { Join-Path $rootParent "${rootLeaf}_WorkSpaces" } else { Join-Path $projRoot '_WorkSpaces' }
    $projWorkspaceDir = if ($projectRecord.workspaceRoot -and "$($projectRecord.workspaceRoot)".Trim()) { [string]$projectRecord.workspaceRoot } else { $workspaceDirDefault }
    $projBranchFormat = if ($projectRecord.branchFormat) { [string]$projectRecord.branchFormat } else { 'feature/{env}/{key}' }

    $org = Get-StgOrgDefaults -Project $projectRecord.id
    $hiddenApps = @($projectRecord.hiddenApps | Where-Object { $_ })
    $appMapPath = Get-StgAppMapPath -Project $projectRecord.id

    if ($mode -eq 'tracking') {
      $docsDir = if ($projectRecord.docsDir) { [string]$projectRecord.docsDir } else { '.claude\stories' }
      return [pscustomobject]@{
        Root = $projRoot; WorktreeRoot = $null; WorkspaceDir = $null; ReposRoot = $null; ScriptDir = $PSScriptRoot
        StoriesPath = (Join-Path (Join-Path $projRoot $docsDir) 'stories.json')
        HistoryPath = (Join-Path (Join-Path $projRoot $docsDir) 'stories_history.json')
        AppMapPath = $appMapPath; UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
        Source = 'config'; NeedsSetup = $false; Error = $null
        ProjectId = $projectRecord.id; ProjectName = $projectRecord.name; Mode = $mode
        ProjectSource = $projectSource; DocsDir = $docsDir; BranchFormat = $projBranchFormat
        JiraBaseUrl = $org.JiraBaseUrl; GithubOrg = $org.GithubOrg; RepoAliases = $org.RepoAliases
        HiddenApps = $hiddenApps; Project = $projectRecord
      }
    }

    return [pscustomobject]@{
      Root = $projRoot; WorktreeRoot = $projWtRoot; WorkspaceDir = $projWorkspaceDir; ReposRoot = $projReposRoot; ScriptDir = $PSScriptRoot
      StoriesPath = (Join-Path $projRoot 'stories.json')
      HistoryPath = (Join-Path $projRoot 'stories_history.json')
      AppMapPath = $appMapPath; UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
      Source = 'config'; NeedsSetup = $false; Error = $null
      ProjectId = $projectRecord.id; ProjectName = $projectRecord.name; Mode = $mode
      ProjectSource = $projectSource; DocsDir = $null; BranchFormat = $projBranchFormat
      JiraBaseUrl = $org.JiraBaseUrl; GithubOrg = $org.GithubOrg; RepoAliases = $org.RepoAliases
      HiddenApps = $hiddenApps; Project = $projectRecord
    }
  }

  # ---- Step 3: no project context - ORIGINAL single-root logic, unchanged ------------------------
  $cfg = Get-StgConfig
  $source = $null
  $resolvedRoot = $null

  if ($Root -and (Test-StgRootValid $Root)) {
    $resolvedRoot = $Root; $source = 'parameter'
  } elseif ($Root) {
    # An explicit -Root was passed but doesn't exist - surface that rather than silently falling
    # through to a different root the caller didn't ask for.
    return [pscustomobject]@{
      Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ReposRoot = $null; ScriptDir = $PSScriptRoot
      StoriesPath = $null; HistoryPath = $null; AppMapPath = (Get-StgAppMapPath)
      UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
      Source = 'parameter (invalid)'; NeedsSetup = $true
      Error = "The specified root does not exist: $Root"
      ProjectId = $null; ProjectName = $null; Mode = $null; ProjectSource = 'none'
      DocsDir = $null; BranchFormat = $null; JiraBaseUrl = $null; GithubOrg = $null
      RepoAliases = $null; HiddenApps = @(); Project = $null
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
      Root = $null; WorktreeRoot = $null; WorkspaceDir = $null; ReposRoot = $null; ScriptDir = $PSScriptRoot
      StoriesPath = $null; HistoryPath = $null; AppMapPath = (Get-StgAppMapPath)
      UserConfigDir = (Get-StgUserConfigDir); ConfigPath = (Get-StgConfigPath)
      Source = 'none'; NeedsSetup = $true
      Error = 'No story root configured. Run setup.ps1, set the Root in Settings, or set $env:STG_ROOT.'
      ProjectId = $null; ProjectName = $null; Mode = $null; ProjectSource = 'none'
      DocsDir = $null; BranchFormat = $null; JiraBaseUrl = $null; GithubOrg = $null
      RepoAliases = $null; HiddenApps = @(); Project = $null
    }
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $resolvedRoot).Path

  $resolvedWtRoot = $resolvedRoot
  if ($WorktreeRoot -and (Test-StgRootValid $WorktreeRoot)) {
    $resolvedWtRoot = (Resolve-Path -LiteralPath $WorktreeRoot).Path
  } elseif ($cfg.worktreeRoot -and (Test-StgRootValid $cfg.worktreeRoot)) {
    $resolvedWtRoot = (Resolve-Path -LiteralPath $cfg.worktreeRoot).Path
  }

  # ReposRoot mirror for the legacy/project-less path - same shape as $resolvedWtRoot just above.
  $resolvedReposRoot = $resolvedRoot
  if ($cfg.reposRoot -and (Test-StgRootValid $cfg.reposRoot)) {
    $resolvedReposRoot = (Resolve-Path -LiteralPath $cfg.reposRoot).Path
  }

  # Workspace dir: a sibling of Root, named <rootLeaf>_WorkSpaces - derived so a root named
  # "Ganesha" keeps producing "Ganesha_WorkSpaces" (today's exact behavior) while a root named
  # anything else gets its own matching name instead of a hardcoded "Ganesha_WorkSpaces" literal.
  $rootLeaf = Split-Path $resolvedRoot -Leaf
  $rootParent = Split-Path $resolvedRoot -Parent
  $workspaceDirDefault = if ($rootParent) { Join-Path $rootParent "${rootLeaf}_WorkSpaces" } else { Join-Path $resolvedRoot '_WorkSpaces' }
  $workspaceDir = if ($cfg.workspaceRoot -and $cfg.workspaceRoot.Trim()) { $cfg.workspaceRoot } else { $workspaceDirDefault }

  # Org defaults populated here too (zero-arg Get-StgOrgDefaults) even with no project context, so
  # a caller reading .JiraBaseUrl etc off the result gets a sensible value either way - no live
  # reader depends on this in P2 yet, but there's no reason to make the "no project" branch less
  # useful than the project-aware one now that the fields exist.
  $orgFallback = Get-StgOrgDefaults

  [pscustomobject]@{
    Root          = $resolvedRoot
    WorktreeRoot  = $resolvedWtRoot
    WorkspaceDir  = $workspaceDir
    ReposRoot     = $resolvedReposRoot
    ScriptDir     = $PSScriptRoot
    StoriesPath   = (Join-Path $resolvedRoot 'stories.json')
    HistoryPath   = (Join-Path $resolvedRoot 'stories_history.json')
    AppMapPath    = (Get-StgAppMapPath)
    UserConfigDir = (Get-StgUserConfigDir)
    ConfigPath    = (Get-StgConfigPath)
    Source        = $source
    NeedsSetup    = $false
    Error         = $null
    ProjectId     = $null
    ProjectName   = $null
    Mode          = 'worktree'
    ProjectSource = 'none'
    DocsDir       = $null
    BranchFormat  = 'feature/{env}/{key}'
    JiraBaseUrl   = $orgFallback.JiraBaseUrl
    GithubOrg     = $orgFallback.GithubOrg
    RepoAliases   = $orgFallback.RepoAliases
    HiddenApps    = @($cfg.hiddenApps | Where-Object { $_ })
    Project       = $null
  }
}

function Get-StgOrgDefaults {
  # De-hardcoded org-specific literals. Every one defaults to today's exact value, so an existing
  # tree behaves identically until someone changes Settings.
  #
  # -Project: the schema's effective-value ladder (project.<field> -> defaults.<field> -> today's
  # hardcoded default), for a caller that knows which project it's acting on (Resolve-StgPaths,
  # once it has resolved a project context).
  #
  # No -Project (every call site before this parameter existed): the ORIGINAL code path,
  # byte-for-byte, reading $cfg.<field> at the top level - deliberately NOT consolidated with the
  # -Project branch below even though the two should always agree in practice (defaults and the
  # top-level mirror are populated from the same source in one migration pass, and kept in sync by
  # every Update-StgConfig write). Leaving this path as untouched CODE, not just behavior, is the
  # safer bar after a near-miss in the prior phase: the original migration design would have moved
  # these fields out from under this exact function and silently reverted every configured value
  # to its hardcoded default the moment it shipped, before the additive-migration fix caught it.
  param([string]$Project)
  $cfg = Get-StgConfig
  if ($Project) {
    $proj = Get-StgProject -Id $Project
    $d = $cfg.defaults
    return [pscustomobject]@{
      JiraBaseUrl       = if ($proj -and $proj.jiraBaseUrl) { $proj.jiraBaseUrl } elseif ($d -and $d.jiraBaseUrl) { $d.jiraBaseUrl } else { 'https://vesta.atlassian.net' }
      GithubOrg         = if ($proj -and $proj.githubOrg) { $proj.githubOrg } elseif ($d -and $d.githubOrg) { $d.githubOrg } else { 'vesta-experimental' }
      RepoAliases       = if ($proj -and $proj.repoAliases) { $proj.repoAliases } elseif ($d -and $d.repoAliases) { $d.repoAliases } else { [pscustomobject]@{ 'ganesha-iu-internal-app' = 'ganesha-ui-internal-app' } }
      TaskNamePrefix    = if ($proj -and $proj.taskNamePrefix) { $proj.taskNamePrefix } elseif ($d -and $d.taskNamePrefix) { $d.taskNamePrefix } else { 'Ganesha EOD status reminder' }
      Owner             = if ($proj -and $proj.owner) { $proj.owner } elseif ($d -and $d.owner) { $d.owner } else { $env:USERNAME }
      # Genuinely global (the Slack-token dir), never per-project - same field, same fallback, in
      # both branches.
      UserConfigDirName = if ($cfg.userConfigDirName) { $cfg.userConfigDirName } else { '.story-tab-groups' }
    }
  }
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
  Get-StgNames, Get-StgAppMapPath, Get-StgLedgerPath, Get-StgStoryDocPath, ConvertTo-StgConfigV2, `
  Get-StgProjects, Get-StgProject, Update-StgConfig, New-StgProject, Update-StgProject, Remove-StgProject, `
  Get-StgTrackingRepos, Write-StgDevWorkspace, `
  New-StgTrackingScaffold
