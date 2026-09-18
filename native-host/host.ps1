# Native-messaging host for Worktree manager. Reads ONE length-prefixed JSON message from
# Chrome on stdin, dispatches, writes ONE length-prefixed JSON reply, exits. Only writes the
# framed reply to stdout - nothing else - so the message stream stays uncorrupted.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

function Read-Frame {
  $lp = New-Object byte[] 4; $g = 0
  while ($g -lt 4) { $n = $stdin.Read($lp, $g, 4 - $g); if ($n -le 0) { return $null }; $g += $n }
  $len = [BitConverter]::ToInt32($lp, 0)
  if ($len -le 0 -or $len -gt 1048576) { return $null }
  $buf = New-Object byte[] $len; $o = 0
  while ($o -lt $len) { $n = $stdin.Read($buf, $o, $len - $o); if ($n -le 0) { return $null }; $o += $n }
  [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
}

function Write-Frame([string]$json) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($json)
  $stdout.Write([BitConverter]::GetBytes([int]$b.Length), 0, 4)
  $stdout.Write($b, 0, $b.Length)
  $stdout.Flush()
}

function Reply($o) { Write-Frame ($o | ConvertTo-Json -Depth 10 -Compress) }

# Scripts live in tools\, a sibling of this native-host\ folder - they travel WITH the extension,
# not with the data root. This is the fix for the old two-copies trap: every action used to run
# whatever switch-story.ps1/remove-worktree.ps1 happened to sit at $GRoot (which could easily be a
# stale copy), while 'remove'/'check' additionally used a DIFFERENT resolution
# ($PSScriptRoot\..\..) than every other action ($GRoot) - so the two could silently run two
# different script versions. Now every action resolves scripts from the same place.
$ScriptsDir = (Resolve-Path (Join-Path $PSScriptRoot '..\tools')).Path

# stg-paths.psm1 is the single resolver shared with every tools\*.ps1 script - see that file for
# the full root-resolution precedence (stg-config.json > env:STG_ROOT > auto-detect - config
# outranks the env var deliberately, so a long-lived Chrome process's frozen environment can never
# silently beat what Settings actually has configured) and for Get-StgConfig/Set-StgConfig (the
# same %LOCALAPPDATA%\story-tab-groups\stg-config.json this host used to maintain its own private
# copy of the read/write logic for).
Import-Module (Join-Path $ScriptsDir 'stg-paths.psm1') -Force -DisableNameChecking
$StgConfig = Get-StgConfig
$OrgDefaults = Get-StgOrgDefaults
$PathsInfo = Resolve-StgPaths
$GRoot = $PathsInfo.Root  # $null when NeedsSetup - every action below must check that first

try { if ($GRoot) { Import-Module (Join-Path $ScriptsDir 'StoryLib.psm1') -Force -DisableNameChecking } } catch {}

function Test-Key([string]$k) {
  if (Get-Command Test-StoryKey -ErrorAction SilentlyContinue) { return (Test-StoryKey $k) }
  # Fallback (StoryLib missing) accepts both shapes switch-story.ps1's own 'new' validates
  # (:391) - a Jira key or the no-ticket kebab slug. The old Jira-only fallback here meant a
  # kebab-slug story could be created but never removed/added-to/added on a machine without
  # StoryLib.
  return ($k -match '^[A-Za-z0-9]+-\d+$' -or $k -match '^[a-z][a-z0-9]*(-[a-z0-9]+)+$')
}

# Every action that needs a resolved root goes through this first - one place that reports
# "root not configured" instead of each action guessing or silently scanning the wrong tree.
function Test-RootReady {
  if (-not $GRoot) {
    Reply @{ ok = $false; error = $PathsInfo.Error; needsSetup = $true }
    return $false
  }
  return $true
}

# Run one of the tools\ scripts and reply with its JSON frame verbatim. Captures BOTH stdout and
# stderr: stdout-only capture used to turn a child script's "unknown parameter"/exception into a
# blank "returned no JSON" with no clue what actually failed - the single biggest debugging-time
# sink recorded in this project's update notes. stderr (when present) now rides along in `raw`.
function Invoke-StoryScript([string]$RelPath, [string[]]$ScriptArgs, [string]$Label) {
  $script = Join-Path $ScriptsDir $RelPath
  if (-not (Test-Path $script)) { Reply @{ ok = $false; error = "$RelPath not found in tools\ ($ScriptsDir)" }; return }
  $script = (Resolve-Path $script).Path
  $pargs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script) + $ScriptArgs
  $stderrFile = [IO.Path]::GetTempFileName()
  try {
    $out = & powershell.exe @pargs 2>$stderrFile
    $errTxt = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
  } finally {
    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
  }
  $txt = ($out | Out-String).Trim()
  $parsed = $null; try { $parsed = $txt | ConvertFrom-Json } catch {}
  if ($null -ne $parsed) { Reply $parsed }
  else {
    $raw = $txt
    if ($errTxt) { $raw = "$raw`n[stderr] $errTxt".Trim() }
    Reply @{ ok = $false; error = "$Label returned no JSON"; raw = $raw }
  }
}

try {
  $raw = Read-Frame
  if (-not $raw) { exit 0 }
  $msg = $raw | ConvertFrom-Json

  switch ([string]$msg.action) {
    'ping' { Reply @{ ok = $true; pong = $true } }
    'remove' {
      if (-not (Test-RootReady)) { break }
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $sargs = @('-Story', $story, '-Root', $GRoot, '-Json')
      if ($msg.discardGenerated -eq $true) { $sargs += '-DiscardGenerated' }
      # Popup sends this once a blocked story's typed "CONFIRM" gate passes - skips the dirty/
      # unpushed abort. Discards uncommitted changes permanently; unpushed COMMITS stay safe (the
      # branch is kept - no -DeleteBranch here either way).
      if ($msg.force -eq $true) { $sargs += '-Force' }
      Invoke-StoryScript 'remove-worktree.ps1' $sargs 'remove script'
    }
    'check' {
      if (-not (Test-RootReady)) { break }
      # Read-only: blocker status for every story in stories.json (popup "ready/blocked" badges).
      Invoke-StoryScript 'remove-worktree.ps1' @('-CheckAll', '-Root', $GRoot, '-Json') 'check'
    }
    'history' {
      if (-not (Test-RootReady)) { break }
      # Return stories_history.json as a raw string (the extension parses it). Raw avoids
      # ConvertTo-Json's depth limit truncating the deeply-nested story logs.
      $histPath = $PathsInfo.HistoryPath
      if (-not (Test-Path $histPath)) { Reply @{ ok = $true; json = '' }; break }
      $raw = Get-Content (Resolve-Path $histPath).Path -Raw -Encoding UTF8
      Reply @{ ok = $true; json = ([string]$raw) }
    }
    'stories' {
      if (-not (Test-RootReady)) { break }
      # stories.json as raw text, same reasoning as 'history': the nested per-story logs are
      # deeper than ConvertTo-Json -Depth would preserve.
      $p = $PathsInfo.StoriesPath
      if (-not (Test-Path $p)) { Reply @{ ok = $true; json = '' }; break }
      Reply @{ ok = $true; json = ([string](Get-Content (Resolve-Path $p).Path -Raw -Encoding UTF8)) }
    }
    'ledgers' {
      if (-not (Test-RootReady)) { break }
      # Every story's phase state in one reply: { KEY: <ledger>, ... } as raw JSON text. Pure file
      # reads (no git, no HTTP), so this is cheap enough to run on every popup open.
      $regPath = $PathsInfo.StoriesPath
      if (-not (Test-Path $regPath)) { Reply @{ ok = $true; json = '{}' }; break }
      $reg = (Get-Content (Resolve-Path $regPath).Path -Raw -Encoding UTF8) | ConvertFrom-Json
      $parts = @()
      foreach ($k in @($reg.stories.PSObject.Properties.Name)) {
        $lp = Join-Path (Join-Path $GRoot $k) '.story-ship-state.json'
        if (-not (Test-Path $lp)) { continue }
        try {
          $txt = ([IO.File]::ReadAllText((Resolve-Path $lp).Path)).Trim()
          if ($txt) { $parts += ('"' + ($k -replace '"', '\"') + '":' + $txt) }
        } catch {}
      }
      Reply @{ ok = $true; json = ('{' + ($parts -join ',') + '}') }
    }
    'envstatus' {
      if (-not (Test-RootReady)) { break }
      # Ports + health for ONE story. Deliberately on-demand only (a popup button, never the
      # refresh): this shells out to HTTP probes and can take tens of seconds while apps warm up,
      # and the host is single-shot - it blocks until the probe returns.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      Invoke-StoryScript 'story-env.ps1' @('status', $story, '-Root', $GRoot, '-Json') 'envstatus'
    }
    'release' {
      if (-not (Test-RootReady)) { break }
      # Toggle a story's released state: the ledger's 'deploy' phase plus the node's 'released'
      # field. Deliberately decoupled from removal - a shipped story stops looking active without
      # having to clear remove-worktree.ps1's guardrail first.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $act = if ($msg.released -eq $true) { 'release' } else { 'unrelease' }
      $sargs = @($act, '-Story', $story)
      if ($msg.reason) { $sargs += @('-Reason', [string]$msg.reason) }
      if ($msg.note)   { $sargs += @('-Note', [string]$msg.note) }
      Invoke-StoryScript 'story-release.ps1' ($sargs + @('-Root', $GRoot, '-Json')) 'release'
    }
    'released' {
      if (-not (Test-RootReady)) { break }
      # Read-only released state for every story (the popup's released chip). Pure file reads.
      Invoke-StoryScript 'story-release.ps1' @('status', '-All', '-Root', $GRoot, '-Json') 'released'
    }
    'setLinks' {
      if (-not (Test-RootReady)) { break }
      # Add/update/remove named custom links (Abstract, Test plan, ...) - the popup's per-row ✎
      # editor. { story, set:[{label,url},...], remove:['Label',...] }.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      # switch-story.ps1's -Set/-Remove parameters do not survive being passed as repeated flags
      # or multiple bare tokens through THIS script's own -File child-process invocation (verified
      # empirically - PowerShell's parameter binder rejects a repeated named flag, and silently
      # drops all but the first bare token) - so the payload goes through -LinksB64 instead, a
      # base64'd JSON blob, which is immune to both that and to -File's separate quote-stripping
      # issue with a raw (unencoded) JSON argument.
      $payload = @{ set = @($msg.set); remove = @($msg.remove) } | ConvertTo-Json -Compress -Depth 6
      $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
      Invoke-StoryScript 'switch-story.ps1' @('links', $story, '-LinksB64', $b64, '-Root', $GRoot, '-Json') 'setLinks'
    }
    'doctor' {
      if (-not (Test-RootReady)) { break }
      # Read-only registry/folder/ledger reconciliation (story-doctor.ps1).
      Invoke-StoryScript 'story-doctor.ps1' @('-Root', $GRoot, '-Json') 'doctor'
    }
    'add' {
      if (-not (Test-RootReady)) { break }
      # Create a new story: registry node + per-app worktrees, via switch-story.ps1's -Json
      # contract (see switch-story.ps1's Invoke-New). Always -NoInstall - yarn/pip can run for
      # minutes and this host is single-shot, blocking until the child process returns - but
      # -Open follows the popup's checkbox (default on, matching ganesha-worktree/SKILL.md's
      # "always also open the workspace" convention; msg.open === false opts out).
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $appsCsv = (@($msg.apps) -join ',')
      $sargs = @('new', $story, [string]$msg.env, $appsCsv, '-NoInstall', '-Root', $GRoot, '-Json')
      if ($msg.open -ne $false) { $sargs += '-Open' }
      if ($msg.title)   { $sargs += @('-Title', [string]$msg.title) }
      if ($msg.jiraUrl) { $sargs += @('-JiraUrl', [string]$msg.jiraUrl) }
      if ($msg.branch)  { $sargs += @('-Branch', [string]$msg.branch) }
      if ($StgConfig.worktreeRoot) { $sargs += @('-WorktreeRoot', [string]$StgConfig.worktreeRoot) }
      if ($StgConfig.branchFormat) { $sargs += @('-BranchFormat', [string]$StgConfig.branchFormat) }
      Invoke-StoryScript 'switch-story.ps1' $sargs 'add'
    }
    'addcheck' {
      if (-not (Test-RootReady)) { break }
      # Read-only preview of 'add': the same validation switch-story.ps1 new would do (key shape,
      # duplicate, which apps are actually cloned, whether the branch already exists), changing
      # nothing. What the popup's confirm step is built from.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $appsCsv = (@($msg.apps) -join ',')
      $sargs = @('new', $story, [string]$msg.env, $appsCsv, '-CheckOnly', '-Root', $GRoot, '-Json')
      if ($msg.branch) { $sargs += @('-Branch', [string]$msg.branch) }
      if ($StgConfig.worktreeRoot) { $sargs += @('-WorktreeRoot', [string]$StgConfig.worktreeRoot) }
      if ($StgConfig.branchFormat) { $sargs += @('-BranchFormat', [string]$StgConfig.branchFormat) }
      Invoke-StoryScript 'switch-story.ps1' $sargs 'addcheck'
    }
    'addapps' {
      if (-not (Test-RootReady)) { break }
      # Add apps to an EXISTING story (the popup's "+ Add app" button): switch-story.ps1 add -Json.
      # Same -NoInstall / -Open reasoning as 'add' above; the branch + worktree root come from the
      # story's own node, never from the message.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $appsCsv = (@($msg.apps) -join ',')
      if (-not $appsCsv) { Reply @{ ok = $false; error = "no apps given" }; break }
      $sargs = @('add', $story, $appsCsv, '-NoInstall', '-Root', $GRoot, '-Json')
      if ($msg.open -ne $false) { $sargs += '-Open' }
      Invoke-StoryScript 'switch-story.ps1' $sargs 'addapps'
    }
    'addappscheck' {
      if (-not (Test-RootReady)) { break }
      # Read-only preview of 'addapps': cloned? branch exists? already in the story? Changes nothing.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $appsCsv = (@($msg.apps) -join ',')
      if (-not $appsCsv) { Reply @{ ok = $false; error = "no apps given" }; break }
      Invoke-StoryScript 'switch-story.ps1' @('add', $story, $appsCsv, '-CheckOnly', '-Root', $GRoot, '-Json') 'addappscheck'
    }
    'openworkspace' {
      if (-not (Test-RootReady)) { break }
      # Write/refresh <STORY>.code-workspace from its current worktrees and launch it in VS Code -
      # the popup's "Open workspace" button, for a story that already exists (unlike 'add', which
      # only opens once, at creation, if the checkbox was checked).
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      Invoke-StoryScript 'switch-story.ps1' @('open', $story, '-Root', $GRoot, '-Json') 'openworkspace'
    }
    'getConfig' {
      # Current effective settings for the Options page: what's actually configured, PLUS what
      # every path resolves to right now even when unset (and WHICH rule decided it), so the page
      # can show "using: C:\...\Ganesha (auto-detected)" rather than a blank field with no context.
      $effBranchFormat = if ($StgConfig.branchFormat) { [string]$StgConfig.branchFormat } else { 'feature/{env}/{key}' }
      Reply @{
        ok = $true
        root = [string]$StgConfig.root
        worktreeRoot = [string]$StgConfig.worktreeRoot
        workspaceRoot = [string]$StgConfig.workspaceRoot
        branchFormat = [string]$StgConfig.branchFormat
        jiraBaseUrl = [string]$StgConfig.jiraBaseUrl
        githubOrg = [string]$StgConfig.githubOrg
        repoAliases = $OrgDefaults.RepoAliases
        taskNamePrefix = [string]$StgConfig.taskNamePrefix
        owner = [string]$StgConfig.owner
        hiddenApps = @($StgConfig.hiddenApps | Where-Object { $_ })
        effectiveRoot = $GRoot
        effectiveWorktreeRoot = $PathsInfo.WorktreeRoot
        effectiveWorkspaceRoot = $PathsInfo.WorkspaceDir
        effectiveBranchFormat = $effBranchFormat
        effectiveJiraBaseUrl = $OrgDefaults.JiraBaseUrl
        effectiveGithubOrg = $OrgDefaults.GithubOrg
        needsSetup = [bool]$PathsInfo.NeedsSetup
        rootSource = [string]$PathsInfo.Source
        configPath = $PathsInfo.ConfigPath
        scriptsDir = $ScriptsDir
      }
    }
    'setConfig' {
      # Writes root/worktreeRoot/workspaceRoot/branchFormat/jiraBaseUrl/githubOrg/taskNamePrefix/
      # owner to stg-config.json via stg-paths.psm1's Set-StgConfig - one implementation shared by
      # every tools\*.ps1 script and this host, rather than each maintaining its own copy of the
      # read/write logic (the reason a file was chosen over browser storage in the first place:
      # switch-story.ps1 is also a CLI tool, so both need to read the same source of truth).
      # root, if given, must already exist (it has to contain stories.json to be useful) -
      # worktreeRoot/workspaceRoot do not need to exist yet. An empty string for any field clears
      # just that field rather than requiring every field every time.
      $newCfg = [ordered]@{}
      foreach ($k in @('root', 'worktreeRoot', 'workspaceRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner')) {
        if ($StgConfig.$k) { $newCfg[$k] = [string]$StgConfig.$k }
      }
      if ($StgConfig.repoAliases) { $newCfg['repoAliases'] = $StgConfig.repoAliases }
      if (@($StgConfig.hiddenApps | Where-Object { $_ }).Count) { $newCfg['hiddenApps'] = @($StgConfig.hiddenApps | Where-Object { $_ }) }

      if ($msg.PSObject.Properties.Name -contains 'root') {
        $r = [string]$msg.root
        if ($r -and -not (Test-Path $r -PathType Container)) {
          Reply @{ ok = $false; error = "root path not found: $r" }; break
        }
        if ($r) { $newCfg['root'] = $r } else { $newCfg.Remove('root') }
      }
      foreach ($k in @('worktreeRoot', 'workspaceRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner')) {
        if ($msg.PSObject.Properties.Name -contains $k) {
          $v = [string]$msg.$k
          if ($v) { $newCfg[$k] = $v } else { $newCfg.Remove($k) }
        }
      }
      if ($msg.PSObject.Properties.Name -contains 'repoAliases' -and $msg.repoAliases) {
        $newCfg['repoAliases'] = $msg.repoAliases
      }
      # Presence-gated, NOT truthy-gated like repoAliases above: repoAliases treats an empty
      # value as "leave the old one alone", which is wrong for hiddenApps - unhiding the last
      # hidden app sends an empty array and that MUST actually clear the key, not silently keep
      # the previous hidden set.
      if ($msg.PSObject.Properties.Name -contains 'hiddenApps') {
        $newHidden = @($msg.hiddenApps | Where-Object { $_ })
        if ($newHidden.Count) { $newCfg['hiddenApps'] = $newHidden } else { $newCfg.Remove('hiddenApps') }
      }

      try {
        Set-StgConfig -Config $newCfg
        Reply @{ ok = $true; saved = $newCfg }
      } catch {
        Reply @{ ok = $false; error = ("could not save settings: " + $_.Exception.Message) }
      }
    }
    'apps' {
      if (-not (Test-RootReady)) { break }
      # Which repos are actually cloned under $GRoot - the ground truth for "can I worktree this
      # app", which app-map.json (the *configured* list) cannot answer on its own. A home base has
      # a .git DIRECTORY, a worktree has a .git FILE, and a story folder has neither, so scanning
      # $GRoot's top-level dirs for a .git directory finds exactly the home-base clones. Pure
      # file/git reads - no mutation, cheap like 'check'/'stories'/'ledgers'.
      $mapped = $false
      $known = @{}  # app name -> its app-map.json def (port/start/health/...), not just $true -
                    # the Settings Apps card needs the actual values to prefill an edit, not just
                    # a mapped/unmapped bit.
      $mapPath = $PathsInfo.AppMapPath
      if (Test-Path $mapPath) {
        try {
          # Iterate .Properties directly, NOT .Properties.Name wrapped in @() - .Properties
          # itself is a real collection and enumerates zero times on an empty {} apps map; it's
          # only the .Name projection that collapses to a null-holding one-element array (see
          # Get-StgNames). No @() needed here at all.
          foreach ($p in (Get-Content $mapPath -Raw | ConvertFrom-Json).apps.PSObject.Properties) { $known[$p.Name] = $p.Value }
          $mapped = $true
        } catch {}
      }
      $hiddenSet = @{}
      foreach ($h in @($StgConfig.hiddenApps | Where-Object { $_ })) { $hiddenSet[$h] = $true }

      $reg = $null
      $regPath = $PathsInfo.StoriesPath
      if (Test-Path $regPath) { try { $reg = (Get-Content $regPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
      $storyKeys = @{}
      $used = @{}
      if ($reg) {
        # Get-StgNames, not the bare @($reg.stories.PSObject.Properties.Name) idiom - an empty
        # {} registry makes that expression $null, and @($null) is a one-element array HOLDING
        # $null, so this loop would run once with $k = $null and $storyKeys[$null] = $true throws
        # ("Index operation failed; the array index evaluated to null"). This was the actual cause
        # of the "no repos found" app-checklist bug on a fresh install with an empty stories.json.
        foreach ($k in (Get-StgNames $reg.stories)) {
          $storyKeys[$k] = $true
          foreach ($a in @($reg.stories.$k.apps)) { if ($a) { $used[$a] = 1 + [int]$used[$a] } }
        }
      }
      $histPath = $PathsInfo.HistoryPath
      if (Test-Path $histPath) {
        try {
          $h = Get-Content $histPath -Raw -Encoding UTF8 | ConvertFrom-Json
          $items = @(); if ($h -and $h.removed) { $items = @($h.removed) }
          foreach ($it in $items) { foreach ($a in @($it.apps)) { if ($a) { $used[$a] = 1 + [int]$used[$a] } } }
        } catch {}
      }

      # Skip list: folders that are never candidate apps at all (this extension's own folder name
      # is derived - never a 'story-tab-groups' literal - so renaming the extension folder can't
      # break this scan). NOT where hiddenApps lives: a hidden app is a real, still-scanned repo
      # the user chose to hide from the +New story checklist, and it has to keep appearing in
      # $rows (flagged hidden:true) so Settings can list it and offer "unhide" - putting it in
      # $skip instead would make it vanish from $rows entirely and unhide would have nothing to
      # act on.
      $ownFolderName = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf
      $skip = @('tools', 'notes', 'temp', '.env-backups', (Split-Path $PathsInfo.WorkspaceDir -Leaf), $ownFolderName)
      $rows = @()
      foreach ($d in (Get-ChildItem -Path $GRoot -Directory -ErrorAction SilentlyContinue)) {
        $name = $d.Name
        if ($skip -contains $name -or $storyKeys.ContainsKey($name)) { continue }
        if (-not (Test-Path (Join-Path $d.FullName '.git') -PathType Container)) { continue }
        $origin = $null
        try { $origin = (git -C $d.FullName remote get-url origin 2>$null) } catch {}
        $repo = if ($OrgDefaults.RepoAliases.PSObject.Properties.Name -contains $name) { $OrgDefaults.RepoAliases.$name } else { $name }
        $rows += [pscustomobject]@{
          app = $name; repo = $repo; origin = [string]$origin; onDisk = $true
          mapped = [bool]($mapped -and $known.ContainsKey($name)); used = [int]$used[$name]
          def = $known[$name]; hidden = [bool]$hiddenSet.ContainsKey($name)
        }
      }
      # Mapped but not cloned - still listed (the form shows "not cloned" rather than silently
      # omitting an app someone expects to see).
      if ($mapped) {
        foreach ($n in $known.Keys) {
          if (-not (@($rows | Where-Object { $_.app -eq $n }))) {
            $repo = if ($OrgDefaults.RepoAliases.PSObject.Properties.Name -contains $n) { $OrgDefaults.RepoAliases.$n } else { $n }
            $rows += [pscustomobject]@{
              app = $n; repo = $repo; origin = $null; onDisk = $false; mapped = $true; used = [int]$used[$n]
              def = $known[$n]; hidden = [bool]$hiddenSet.ContainsKey($n)
            }
          }
        }
      }
      Reply @{ ok = $true; apps = @($rows); appMapFound = $mapped; appMapPath = $mapPath }
    }
    'setappmap' {
      # Writes app-map.json's per-app port/start/health map, ALWAYS to the %LOCALAPPDATA% copy
      # (Get-StgAppMapPath - see stg-paths.psm1) - never to the shipped tools\ template, so this
      # never fights setup.ps1 re-cloning/updating the extension folder. No Test-RootReady: like
      # getConfig/preflight, the app map isn't root-scoped and must work before a root exists.
      # $msg.apps is the COMPLETE desired app-map contents (name -> {port,start,health,...}),
      # replaced wholesale - the card always sends full state, so there's no merge ambiguity here.
      # $msg.apps reads as $null both when the property is absent and when it's JSON null -
      # stg-paths.psm1's own non-strict-mode convention (missing property -> $null), so a plain
      # null check covers both cases without needing -contains here.
      if ($null -eq $msg.apps) {
        Reply @{ ok = $false; error = 'setappmap requires an apps object' }; break
      }
      $userMapPath = Join-Path (Get-StgUserConfigDir) 'app-map.json'
      $bad = @($msg.apps.PSObject.Properties | Where-Object {
        [string]::IsNullOrWhiteSpace($_.Name) -or $_.Name -match '[\\/]'
      } | ForEach-Object { $_.Name })
      if ($bad.Count) {
        Reply @{ ok = $false; error = ("invalid app name(s): " + ($bad -join ', ')) }; break
      }
      # Coerce port to an int where given, and drop any empty string fields rather than writing
      # port:"" / start:"" - an absent field is what every reader (story-env.ps1, this action's
      # own $known.ContainsKey checks) already treats as "not set". Validate BEFORE casting - a
      # bare [int]$src.port on a non-numeric string throws under this script's own
      # $ErrorActionPreference = 'Stop' ("Cannot convert value ... Input string was not in a
      # correct format"), which would crash this action exactly the way an empty stories.json
      # crashed 'apps' - the whole reason this fix exists. A bad port must be a clean ok:false,
      # not a repeat of that bug one field over.
      $cleanApps = [ordered]@{}
      $badPort = $null
      foreach ($p in $msg.apps.PSObject.Properties) {
        $src = $p.Value
        $entry = [ordered]@{}
        if ($src.PSObject.Properties.Name -contains 'port' -and $src.port) {
          $parsedPort = 0
          if (-not [int]::TryParse([string]$src.port, [ref]$parsedPort)) { $badPort = "$($p.Name): '$($src.port)'"; break }
          $entry['port'] = $parsedPort
        }
        if ($src.PSObject.Properties.Name -contains 'start' -and $src.start) { $entry['start'] = [string]$src.start }
        if ($src.PSObject.Properties.Name -contains 'health' -and $src.health) { $entry['health'] = [string]$src.health }
        $cleanApps[$p.Name] = $entry
      }
      if ($badPort) { Reply @{ ok = $false; error = "invalid port for $badPort - must be a number" }; break }
      # pythonSentinel survives from whichever file is currently authoritative (the %LOCALAPPDATA%
      # copy if it exists, else the shipped template) so a first Settings save doesn't quietly
      # revert a custom sentinel back to story-env.ps1's own 'fastapi' default.
      $sentinel = 'fastapi'
      $currentPath = Get-StgAppMapPath
      if (Test-Path $currentPath) {
        try {
          $cur = Get-Content $currentPath -Raw | ConvertFrom-Json
          if ($cur.pythonSentinel) { $sentinel = [string]$cur.pythonSentinel }
        } catch {}
      }
      $out = [ordered]@{ pythonSentinel = $sentinel; apps = $cleanApps }
      try {
        $json = $out | ConvertTo-Json -Depth 10
        # BOM-less, same convention as Set-StgConfig.
        [System.IO.File]::WriteAllText($userMapPath, $json, [System.Text.UTF8Encoding]::new($false))
        Reply @{ ok = $true; appMapPath = $userMapPath; apps = $cleanApps }
      } catch {
        Reply @{ ok = $false; error = ("could not save app map: " + $_.Exception.Message) }
      }
    }
    'preflight' {
      # Same checks setup.ps1 runs from the terminal, exposed here so the Settings page's
      # diagnostics card can re-run them without one. Read-only; never writes anything.
      $rows = @()
      $add = { param($name, $ok, $detail, $fix) $script:rows += [pscustomobject]@{ name = $name; ok = [bool]$ok; detail = $detail; fix = $fix } }
      # Precompute into a variable rather than passing "(if (...) {...} else {...})" directly as a
      # command argument - a bare `if` statement inside plain "(...)" grouping in argument-parsing
      # mode is not reliably treated as an expression by PowerShell (confirmed: it threw "the term
      # 'if' is not recognized" here), unlike $(...) or a variable.
      $rootDetail = if ($PathsInfo.NeedsSetup) { $PathsInfo.Error } else { "$GRoot (source: $($PathsInfo.Source))" }
      & $add 'Root configured' (-not $PathsInfo.NeedsSetup) $rootDetail 'Set Root in Settings, or run setup.ps1.'
      if ($GRoot) {
        & $add 'stories.json readable' (Test-Path $PathsInfo.StoriesPath) $PathsInfo.StoriesPath 'Create or restore stories.json at the root, or point Root at where it lives.'
        & $add 'StoryLib.psm1' (Test-Path (Join-Path $ScriptsDir 'StoryLib.psm1')) (Join-Path $ScriptsDir 'StoryLib.psm1') 'Should ship with tools\ - re-download/re-clone the extension folder.'
        & $add 'app-map.json' (Test-Path $PathsInfo.AppMapPath) $PathsInfo.AppMapPath 'Optional - without it, story-env.ps1 reports every app "unmapped" (no port/start/health).'
      }
      $gitCmd = Get-Command git -ErrorAction SilentlyContinue
      & $add 'git on PATH' ([bool]$gitCmd) ($gitCmd.Source) 'Install Git for Windows and ensure git.exe is on PATH.'
      $codeCmd = Get-Command code -ErrorAction SilentlyContinue
      & $add 'code (VS Code CLI) on PATH' ([bool]$codeCmd) ($codeCmd.Source) 'Optional - VS Code: Shell Command: Install ''code'' command in PATH.'
      foreach ($s in @('switch-story.ps1', 'remove-worktree.ps1', 'story-ledger.ps1', 'story-release.ps1', 'story-doctor.ps1', 'story-env.ps1')) {
        $p = Join-Path $ScriptsDir $s
        & $add $s (Test-Path $p) $p 'Should ship with tools\ - re-download/re-clone the extension folder.'
      }
      $ok = -not (@($rows | Where-Object { -not $_.ok -and $_.name -ne 'code (VS Code CLI) on PATH' -and $_.name -ne 'app-map.json' }))
      Reply @{ ok = $ok; checks = @($rows) }
    }
    default { Reply @{ ok = $false; error = ("unknown action: " + [string]$msg.action) } }
  }
}
catch {
  try { Reply @{ ok = $false; error = ("host error: " + $_.Exception.Message) } } catch {}
}
