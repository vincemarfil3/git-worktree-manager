# Native-messaging host for Worktree manager. Reads ONE length-prefixed JSON message from
# Chrome on stdin, dispatches, writes ONE length-prefixed JSON reply, exits. Only writes the
# framed reply to stdout - nothing else - so the message stream stays uncorrupted.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

function Read-Frame {
  $lp = New-Object byte[] 4; $g = 0
  # A genuine 0-byte read here (nothing sent at all before the pipe closed) is the normal
  # "no message, connection already ending" case - stays silent, same as before.
  while ($g -lt 4) { $n = $stdin.Read($lp, $g, 4 - $g); if ($n -le 0) { return $null }; $g += $n }
  $len = [BitConverter]::ToInt32($lp, 0)
  if ($len -le 0 -or $len -gt 1048576) {
    # Unlike a clean EOF above, a length prefix that's negative or over the ~1MB native-messaging
    # cap is unambiguously an anomaly (corruption, or a sender that isn't speaking this protocol) -
    # Chrome used to just see "native host disconnected" with nothing to diagnose. Write-Frame
    # doesn't need the message to have been parsed, so a reply is possible even here; wrapped in its
    # own try/catch since stdout could itself be in a bad state by this point.
    try { Write-Frame (@{ ok = $false; error = "frame too large or invalid (length=$len)" } | ConvertTo-Json -Compress) } catch {}
    return $null
  }
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

# $StgConfig/$OrgDefaults/$PathsInfo/$GRoot/StoryLib used to be computed HERE, at module scope,
# before the incoming message was even read - which meant they could never know which project a
# request was actually for. They're computed instead just after $msg parses, inside the main try
# block below (Resolve-StgPaths -Project ([string]$msg.project)), so $msg.project genuinely drives
# resolution. Strict improvement in passing: a corrupt config used to kill the process with NO
# frame written at all ("native host has exited" in Chrome); now it's inside the try/catch and
# still produces a clean {ok:false} reply. Test-Key/Test-RootReady/Invoke-StoryScript below
# reference $GRoot/$PathsInfo in their bodies but are only ever CALLED from inside that same try
# block, after the reassignment - PowerShell resolves a script-scoped variable at call time, not
# at the function's textual definition point, so this is safe.

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
    # unknownProjectId is always present (true/false), not just on the failure path that set it -
    # so the popup can tell "you asked for a project that no longer exists" (ProjectSource is
    # exactly 'parameter (invalid)' when $msg.project was given but didn't match anything
    # configured) apart from "nothing is configured yet at all" without parsing .error text.
    Reply @{ ok = $false; error = $PathsInfo.Error; needsSetup = $true; unknownProjectId = ($PathsInfo.ProjectSource -eq 'parameter (invalid)') }
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

  # Resolve AFTER the message is known, so $msg.project genuinely drives which project's paths/
  # org settings/mode this request sees - see the comment above Test-Key for why this moved here
  # from module scope. An unknown project id (a project the popup still shows a stale reference to,
  # e.g. deleted from another tab) is a hard NeedsSetup failure via Resolve-StgPaths itself, not a
  # silent fallback to whichever project happens to be active - Test-RootReady surfaces it with
  # unknownProjectId:true for any action that needs a root; root-independent actions (ping,
  # getConfig, setConfig, preflight, setappmap, projects) never call Test-RootReady, so a stale
  # project id in $msg never blocks them.
  $PathsInfo = Resolve-StgPaths -Project ([string]$msg.project)
  $GRoot = $PathsInfo.Root  # $null when NeedsSetup - every action below must check that first
  $StgConfig = Get-StgConfig
  # -Project here too, not the zero-arg call this used to be - otherwise getConfig's
  # repoAliases/effectiveJiraBaseUrl/effectiveGithubOrg and the 'apps' action's repo-alias lookup
  # would keep reflecting the top-level mirror regardless of which project actually resolved.
  $OrgDefaults = Get-StgOrgDefaults -Project $PathsInfo.ProjectId
  # 'add'/'addcheck' forward -WorktreeRoot/-BranchFormat to switch-story.ps1 only when the target
  # actually HAS a custom one (an empty value here means "use switch-story.ps1's own default", not
  # "clear it"). Read from the RESOLVED project's own raw field, not $StgConfig's top-level mirror -
  # the mirror only ever reflects the ACTIVE project, so once -Project can target a non-active
  # project, reading the mirror here would silently apply the active project's override to a
  # DIFFERENT project's worktrees. Falls back to $StgConfig (today's exact legacy behavior) only
  # when no project context resolved at all.
  $rawWtRoot = if ($PathsInfo.Project) { [string]$PathsInfo.Project.worktreeRoot } else { [string]$StgConfig.worktreeRoot }
  $rawBranchFormat = if ($PathsInfo.Project) { [string]$PathsInfo.Project.branchFormat } else { [string]$StgConfig.branchFormat }

  try { if ($GRoot) { Import-Module (Join-Path $ScriptsDir 'StoryLib.psm1') -Force -DisableNameChecking } } catch {}

  switch ([string]$msg.action) {
    'ping' { Reply @{ ok = $true; pong = $true } }
    'remove' {
      if (-not (Test-RootReady)) { break }
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $sargs = @('-Story', $story, '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')
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
      Invoke-StoryScript 'remove-worktree.ps1' @('-CheckAll', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'check'
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
      # [ordered] hashtable + ConvertTo-Json, not string concatenation - the old '{' + parts -join
      # ',' + '}' spliced each ledger file's raw text in unvalidated, so one malformed ledger
      # corrupted the WHOLE payload (background.js's JSON.parse on the combined string would fail
      # for every story, not just the bad one). Each ledger is now parsed independently, so a bad
      # one is simply skipped rather than taking the whole reply down with it.
      $ledgers = [ordered]@{}
      # Get-StgNames, not the bare @($reg.stories.PSObject.Properties.Name) idiom - see the 'apps'
      # action's comment for why an empty {} registry needs this.
      foreach ($k in (Get-StgNames $reg.stories)) {
        $node = $reg.stories.$k
        # Get-StgLedgerPath, not a hardcoded Join-Path $GRoot $k - a story whose worktrees live
        # under a configured worktreeRoot otherwise had its ledger silently skipped here, so
        # getLedgers/the popup's phase chips came back empty for it even though the ledger exists.
        $lp = Get-StgLedgerPath -Paths $PathsInfo -Story $k -Node $node
        if (-not (Test-Path $lp)) { continue }
        try {
          $txt = ([IO.File]::ReadAllText((Resolve-Path $lp).Path)).Trim()
          if ($txt) { $ledgers[$k] = ($txt | ConvertFrom-Json) }
        } catch {}
      }
      Reply @{ ok = $true; json = ($ledgers | ConvertTo-Json -Depth 10 -Compress) }
    }
    'envstatus' {
      if (-not (Test-RootReady)) { break }
      # Ports + health for ONE story. Deliberately on-demand only (a popup button, never the
      # refresh): this shells out to HTTP probes and can take tens of seconds while apps warm up,
      # and the host is single-shot - it blocks until the probe returns.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      Invoke-StoryScript 'story-env.ps1' @('status', $story, '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'envstatus'
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
      Invoke-StoryScript 'story-release.ps1' ($sargs + @('-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')) 'release'
    }
    'released' {
      if (-not (Test-RootReady)) { break }
      # Read-only released state for every story (the popup's released chip). Pure file reads.
      Invoke-StoryScript 'story-release.ps1' @('status', '-All', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'released'
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
      Invoke-StoryScript 'switch-story.ps1' @('links', $story, '-LinksB64', $b64, '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'setLinks'
    }
    'storydoc' {
      if (-not (Test-RootReady)) { break }
      # Tracking mode's per-story markdown doc - init/append/path/show, straight to story-doc.ps1
      # rather than through switch-story.ps1's 'note' (which has no -Json path of its own - see
      # story-doc.ps1's own header comment and switch-story.ps1's Invoke-Note for why this is the
      # extension's real entry point, and 'note' stays CLI-only parity). { story, docAction, text? }
      # - docAction, NOT action: $msg.action is already consumed by the switch that routed the
      # message here in the first place, so reading it again always yields the literal string
      # 'storydoc' regardless of what the caller actually asked for. Caught live: every single
      # call failed with "invalid storydoc action: storydoc" until this was renamed.
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      $docAction = [string]$msg.docAction
      if ($docAction -notin @('init', 'append', 'path', 'show')) { Reply @{ ok = $false; error = "invalid storydoc action: $docAction" }; break }
      $sargs = @($docAction, $story)
      # -TextB64, same reasoning as setLinks' -LinksB64 just above: a raw multi-line/quoted string
      # does not survive this script's own -File child-process invocation of story-doc.ps1.
      if ($msg.text) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$msg.text))
        $sargs += @('-TextB64', $b64)
      }
      if ($msg.title) {
        $tb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$msg.title))
        $sargs += @('-TitleB64', $tb64)
      }
      Invoke-StoryScript 'story-doc.ps1' ($sargs + @('-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')) 'storydoc'
    }
    'doctor' {
      if (-not (Test-RootReady)) { break }
      # Read-only registry/folder/ledger reconciliation (story-doctor.ps1).
      Invoke-StoryScript 'story-doctor.ps1' @('-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'doctor'
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
      $sargs = @('new', $story, [string]$msg.env, $appsCsv, '-NoInstall', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')
      if ($msg.open -ne $false) { $sargs += '-Open' }
      if ($msg.title)   { $sargs += @('-Title', [string]$msg.title) }
      if ($msg.jiraUrl) { $sargs += @('-JiraUrl', [string]$msg.jiraUrl) }
      if ($msg.branch)  { $sargs += @('-Branch', [string]$msg.branch) }
      if ($rawWtRoot) { $sargs += @('-WorktreeRoot', $rawWtRoot) }
      if ($rawBranchFormat) { $sargs += @('-BranchFormat', $rawBranchFormat) }
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
      $sargs = @('new', $story, [string]$msg.env, $appsCsv, '-CheckOnly', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')
      if ($msg.branch) { $sargs += @('-Branch', [string]$msg.branch) }
      if ($rawWtRoot) { $sargs += @('-WorktreeRoot', $rawWtRoot) }
      if ($rawBranchFormat) { $sargs += @('-BranchFormat', $rawBranchFormat) }
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
      $sargs = @('add', $story, $appsCsv, '-NoInstall', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json')
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
      Invoke-StoryScript 'switch-story.ps1' @('add', $story, $appsCsv, '-CheckOnly', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'addappscheck'
    }
    'openworkspace' {
      if (-not (Test-RootReady)) { break }
      # Write/refresh <STORY>.code-workspace from its current worktrees and launch it in VS Code -
      # the popup's "Open workspace" button, for a story that already exists (unlike 'add', which
      # only opens once, at creation, if the checkbox was checked).
      $story = [string]$msg.story
      if (-not (Test-Key $story)) { Reply @{ ok = $false; error = "invalid story key" }; break }
      Invoke-StoryScript 'switch-story.ps1' @('open', $story, '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'openworkspace'
    }
    'openmain' {
      if (-not (Test-RootReady)) { break }
      # No story key at all - the project-wide planning workspace. Worktree mode: every home-base
      # app clone, regenerated fresh on every call. Tracking mode: the single
      # main_workspace.code-workspace New-StgTrackingScaffold wrote once at project-add time
      # (switch-story.ps1's own Invoke-OpenMain branches on mode internally - both modes get
      # main_workspace, see CLAUDE.md's main_workspace/dev_workspace section).
      Invoke-StoryScript 'switch-story.ps1' @('openmain', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'openmain'
    }
    'opendev' {
      if (-not (Test-RootReady)) { break }
      # Tracking-mode only - the single repo's dev workspace, listing just the actual git repos
      # (regenerated fresh on every call, unlike main_workspace above). switch-story.ps1's own
      # Invoke-OpenDev refuses cleanly with ok:false for a worktree-mode project.
      Invoke-StoryScript 'switch-story.ps1' @('opendev', '-Root', $GRoot, '-Project', [string]$PathsInfo.ProjectId, '-Json') 'opendev'
    }
    'projects' {
      # Root-independent (no Test-RootReady) - the project dropdown/picker must render even on a
      # totally broken install (no root configured at all yet). Resolves each configured project's
      # own paths (not just its bare id/name) so the popup can show per-project needsSetup/error
      # rather than treating "listed" and "actually usable" as the same thing.
      #
      # $allProjects = Get-StgProjects FIRST, then `foreach` over the captured variable - NOT
      # `Get-StgProjects | ForEach-Object {...}` piping the function call directly. Get-StgProjects
      # uses -NoEnumerate (stg-paths.psm1) so a one-project result survives crossing its own return
      # boundary as a real array rather than collapsing to a bare object; the sharp edge is that
      # -NoEnumerate suppresses pipeline unrolling for ANY consumer, not just assignment, so piping
      # the call directly binds $_ to the WHOLE array as one item once 2+ projects exist (confirmed
      # exactly this bug, and fixed the same way, in Resolve-StgPaths's -Root reverse lookup).
      $allProjects = Get-StgProjects
      $list = @()
      foreach ($p in $allProjects) {
        $pPaths = Resolve-StgPaths -Project $p.id
        $list += [pscustomobject]@{
          id = $p.id
          name = $p.name
          mode = if ($p.mode) { [string]$p.mode } else { 'worktree' }
          root = [string]$p.root
          needsSetup = [bool]$pPaths.NeedsSetup
          error = $pPaths.Error
        }
      }
      Reply @{ ok = $true; activeProject = [string](Get-StgConfig).activeProject; projects = @($list) }
    }
    'addProject' {
      # Settings' "+ Add project" form. Root-independent by design (no Test-RootReady) - creating
      # the FIRST project is exactly the case where no root is configured yet.
      $name = [string]$msg.name
      $root = [string]$msg.root
      if (-not $name) { Reply @{ ok = $false; error = 'project name required' }; break }
      if (-not $root -or -not (Test-Path $root -PathType Container)) { Reply @{ ok = $false; error = "root path not found: $root" }; break }
      try {
        # P5: the UI now offers 'tracking' as a real, working choice, so mode IS read from $msg -
        # but still validated against an allow-list rather than trusted wholesale (a stale/hand-
        # built caller sending anything else would otherwise create a project New-StgProject's own
        # mode-gated auto-create doesn't know what to do with).
        $mode = [string]$msg.mode
        if ($mode -notin @('worktree', 'tracking')) { $mode = 'worktree' }
        $proj = New-StgProject -Name $name -Root $root -Mode $mode
        Reply @{ ok = $true; project = $proj }
      } catch { Reply @{ ok = $false; error = $_.Exception.Message } }
    }
    'installskill' {
      # Settings' Agent integration card (story-tab-groups/setup-dev-loop, project-templated) AND
      # its separate Optional skills card (nextjs-project-architecture, shadcn-from-mantine, and any
      # future generic, non-project skill) both land here - renders (and, for the Install button,
      # installs) the requested skill for the resolved project. Root-independent (no Test-RootReady): rendering
      # needs a resolved PROJECT (root/tools-dir to bake into a template, or just a destination
      # root for a generic skill's project-scope install), not a live "does this root's data
      # currently check out" gate the way a story-mutating action would.
      # $msg.scope/$msg.skill each validated against an allow-list before being forwarded - same
      # posture as setappmap's host-computed destination and storydoc's docAction validation,
      # never a path or action string trusted wholesale from the caller (install-agent-skill.ps1's
      # own -Skill ValidateSet would also reject an unknown name, but failing fast here keeps the
      # error message host-side and consistent with every other validated field in this switch).
      $scope = [string]$msg.scope
      if ($msg.install -eq $true -and $scope -notin @('user', 'project')) { Reply @{ ok = $false; error = "invalid scope: $scope" }; break }
      $skill = [string]$msg.skill
      if (-not $skill) { $skill = 'story-tab-groups' }
      if ($skill -notin @('story-tab-groups', 'setup-dev-loop', 'nextjs-project-architecture', 'shadcn-from-mantine')) { Reply @{ ok = $false; error = "invalid skill: $skill" }; break }
      $action = if ($msg.install -eq $true) { 'install' } else { 'render' }
      $sargs = @($action, '-Project', [string]$PathsInfo.ProjectId, '-Skill', $skill)
      if ($action -eq 'install') { $sargs += @('-Scope', $scope) }
      Invoke-StoryScript 'install-agent-skill.ps1' ($sargs + '-Json') 'installskill'
    }
    'getProjectConfig' {
      # Read counterpart to setProjectConfig: ONE named project's own raw fields, plus what they
      # resolve to right now (mirrors getConfig's root/effectiveRoot pairing, just scoped to a
      # SPECIFIC project rather than always the active one). getConfig's own raw fields ALWAYS
      # reflect the top-level mirror (the active project) regardless of $msg.project - only its
      # effective* fields honor -Project - so Settings' per-project cards need this instead once a
      # NON-active project is selected in #settingsProjSel; there was previously no way to read a
      # non-active project's own override values at all.
      $id = [string]$msg.id
      if (-not $id) { Reply @{ ok = $false; error = 'project id required' }; break }
      $proj = Get-StgProject -Id $id
      if (-not $proj) { Reply @{ ok = $false; error = "unknown project id: $id" }; break }
      $pPaths = Resolve-StgPaths -Project $id
      $pOrg = Get-StgOrgDefaults -Project $id
      Reply @{
        ok = $true
        id = $proj.id
        name = [string]$proj.name
        mode = if ($proj.mode) { [string]$proj.mode } else { 'worktree' }
        root = [string]$proj.root
        worktreeRoot = [string]$proj.worktreeRoot
        workspaceRoot = [string]$proj.workspaceRoot
        reposRoot = [string]$proj.reposRoot
        branchFormat = [string]$proj.branchFormat
        jiraBaseUrl = [string]$proj.jiraBaseUrl
        githubOrg = [string]$proj.githubOrg
        repoAliases = $pOrg.RepoAliases
        taskNamePrefix = [string]$proj.taskNamePrefix
        owner = [string]$proj.owner
        hiddenApps = @($proj.hiddenApps | Where-Object { $_ })
        effectiveRoot = $pPaths.Root
        effectiveWorktreeRoot = $pPaths.WorktreeRoot
        effectiveWorkspaceRoot = $pPaths.WorkspaceDir
        effectiveReposRoot = $pPaths.ReposRoot
        effectiveBranchFormat = $pPaths.BranchFormat
        effectiveJiraBaseUrl = $pOrg.JiraBaseUrl
        effectiveGithubOrg = $pOrg.GithubOrg
        needsSetup = [bool]$pPaths.NeedsSetup
      }
    }
    'setProjectConfig' {
      # Edits ONE named project's own fields, independent of which project is active - the
      # Settings page's per-project cards use this once a NON-active project is selected in
      # #settingsProjSel. 'mode' and 'id' are deliberately never patchable here: mode is set once at
      # creation (converting an existing project's mode is a real data-migration question, not a
      # field edit - worktrees/ledgers already exist in worktree-mode locations); id is derived and
      # stable, used elsewhere (stories.json's own path, ledger locations) - renaming it out from
      # under those would orphan them.
      $id = [string]$msg.id
      if (-not $id) { Reply @{ ok = $false; error = 'project id required' }; break }
      $patch = @{}
      foreach ($k in @('name', 'root', 'worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner')) {
        if ($msg.PSObject.Properties.Name -contains $k) { $patch[$k] = [string]$msg.$k }
      }
      if ($msg.PSObject.Properties.Name -contains 'repoAliases' -and $msg.repoAliases) { $patch['repoAliases'] = $msg.repoAliases }
      if ($msg.PSObject.Properties.Name -contains 'hiddenApps') { $patch['hiddenApps'] = @($msg.hiddenApps | Where-Object { $_ }) }
      if ($patch.ContainsKey('root') -and $patch['root'] -and -not (Test-Path $patch['root'] -PathType Container)) {
        Reply @{ ok = $false; error = "root path not found: $($patch['root'])" }; break
      }
      try {
        $proj = Update-StgProject -Id $id -Patch $patch
        Reply @{ ok = $true; project = $proj }
      } catch { Reply @{ ok = $false; error = $_.Exception.Message } }
    }
    'removeProject' {
      # "Forget" a project - never touches stories.json/worktrees/the repo on disk, so this needs no
      # typed-CONFIRM the way 🗑 worktree removal does. Settings' Remove button still confirms once
      # client-side, but the host action itself trusts the caller.
      $id = [string]$msg.id
      if (-not $id) { Reply @{ ok = $false; error = 'project id required' }; break }
      try {
        Remove-StgProject -Id $id
        Reply @{ ok = $true }
      } catch { Reply @{ ok = $false; error = $_.Exception.Message } }
    }
    'allstories' {
      # Every project's raw stories.json in ONE frame, so a multi-project popup's cold start is 1
      # round trip, not N (same reasoning 'stories'/'history' already use raw text over
      # ConvertTo-Json for one project - deeply nested per-story logs exceed a reasonable -Depth).
      # A project whose own root doesn't currently resolve still gets a slot (empty json), not
      # silently dropped, so the popup can show *something* for it rather than a story list that's
      # mysteriously short one project. Chrome caps a native-messaging reply at ~1MB; a running
      # byte count skips the largest remaining payloads once the total would approach that,
      # reporting which ids were skipped so the popup can fall back to a per-project 'stories' call
      # for just those.
      $allProjects = Get-StgProjects
      $result = [ordered]@{}
      $truncated = @()
      $totalBytes = 0
      foreach ($proj in $allProjects) {
        $mode = if ($proj.mode) { [string]$proj.mode } else { 'worktree' }
        $pPaths = Resolve-StgPaths -Project $proj.id
        if ($pPaths.NeedsSetup -or -not (Test-Path $pPaths.StoriesPath)) {
          $result[$proj.id] = @{ name = $proj.name; mode = $mode; json = '' }
          continue
        }
        $txt = [string](Get-Content (Resolve-Path $pPaths.StoriesPath).Path -Raw -Encoding UTF8)
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($txt)
        if (($totalBytes + $bytes) -gt 800000) { $truncated += $proj.id; continue }
        $totalBytes += $bytes
        $result[$proj.id] = @{ name = $proj.name; mode = $mode; json = $txt }
      }
      Reply @{ ok = $true; activeProject = [string](Get-StgConfig).activeProject; projects = $result; truncated = @($truncated) }
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
        reposRoot = [string]$StgConfig.reposRoot
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
        effectiveReposRoot = $PathsInfo.ReposRoot
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
      # owner to stg-config.json via stg-paths.psm1's Update-StgConfig - a read-modify-write that
      # starts from the FULL current config and layers only the changed fields on top, so this
      # action only has to build the PATCH (which fields actually arrived on the message) rather
      # than manually seeding every other known field forward first the way the old inline
      # $newCfg allowlist below this comment used to. That old allowlist had never heard of the
      # config's 'projects'/'defaults'/'version'/'activeProject' keys (added once multi-project
      # support landed) and would have silently deleted all of them on every single settings save -
      # the #1 data-loss risk Update-StgConfig exists to close; Set-StgConfig itself also now
      # guards against exactly this as a backstop for any caller that bypasses this action.
      # root, if given, must already exist (it has to contain stories.json to be useful) -
      # worktreeRoot/workspaceRoot do not need to exist yet. An empty string for any field clears
      # just that field rather than requiring every field every time.
      $patch = @{}
      if ($msg.PSObject.Properties.Name -contains 'root') {
        $r = [string]$msg.root
        if ($r -and -not (Test-Path $r -PathType Container)) {
          Reply @{ ok = $false; error = "root path not found: $r" }; break
        }
        $patch['root'] = $r
      }
      # activeProject: the popup's project dropdown pushes this so the CLI agrees with whichever
      # project the UI has selected. A plain top-level field - Update-StgConfig's generic patch loop
      # already handles it correctly (it isn't one of the dual-write-special-cased project/org
      # fields), the only gap was this action never including it in what it forwards.
      foreach ($k in @('worktreeRoot', 'workspaceRoot', 'reposRoot', 'branchFormat', 'jiraBaseUrl', 'githubOrg', 'taskNamePrefix', 'owner', 'activeProject')) {
        if ($msg.PSObject.Properties.Name -contains $k) { $patch[$k] = [string]$msg.$k }
      }
      # Only added to the patch when truthy - matching the old code's "leave the old one alone"
      # semantics for repoAliases: Update-StgConfig never touches a key the patch doesn't mention.
      if ($msg.PSObject.Properties.Name -contains 'repoAliases' -and $msg.repoAliases) {
        $patch['repoAliases'] = $msg.repoAliases
      }
      # hiddenApps: presence-gated on the INCOMING message (unlike repoAliases above), because
      # unhiding the last hidden app sends an empty array and that MUST actually clear the key, not
      # silently keep the previous hidden set. Update-StgConfig's uniform truthy-else-remove rule
      # does the actual clearing once the (possibly empty) array is in the patch.
      if ($msg.PSObject.Properties.Name -contains 'hiddenApps') {
        $patch['hiddenApps'] = @($msg.hiddenApps | Where-Object { $_ })
      }

      try {
        $saved = Update-StgConfig -Patch $patch
        Reply @{ ok = $true; saved = $saved }
      } catch {
        Reply @{ ok = $false; error = ("could not save settings: " + $_.Exception.Message) }
      }
    }
    'apps' {
      if (-not (Test-RootReady)) { break }
      # Tracking mode has no app/worktree concept at all - scanning $GRoot for .git directories
      # would be both wrong (it IS the tracked repo, not a container of app clones) and slow (a
      # real repo can have many more top-level folders than a worktree-mode root ever would).
      # Short-circuit before that scan runs at all.
      if ($PathsInfo.Mode -eq 'tracking') { Reply @{ ok = $true; apps = @(); mode = 'tracking'; appMapFound = $false; appMapPath = $null }; break }
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
      # (Split-Path $PathsInfo.WorktreeRoot -Leaf) / (Split-Path $PathsInfo.ReposRoot -Leaf)
      # alongside the WorkspaceDir entry - must stay in sync with switch-story.ps1's
      # Get-HomeBaseApps, same duplication CLAUDE.md already flags for this skip-list. See that
      # function's comment for why this is belt-and-suspenders, not load-bearing (the .git-directory
      # check below already excludes a worktree\/repositories\ container naturally).
      $skip = @('tools', 'notes', 'temp', '.env-backups', (Split-Path $PathsInfo.WorkspaceDir -Leaf), (Split-Path $PathsInfo.WorktreeRoot -Leaf), (Split-Path $PathsInfo.ReposRoot -Leaf), $ownFolderName)
      # Scan ReposRoot, not $GRoot directly - a dedicated <root>\repositories\ subfolder for a
      # new-enough project, else $GRoot itself (an existing project with no reposRoot field, via
      # Resolve-StgPaths' own fallback) - see switch-story.ps1's Get-HomeBaseApps for the full
      # reasoning behind this split.
      $GReposRoot = $PathsInfo.ReposRoot
      $rows = @()
      foreach ($d in (Get-ChildItem -Path $GReposRoot -Directory -ErrorAction SilentlyContinue)) {
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
      #
      # Bug found wiring up P4d's per-project Apps card, fixed here rather than shipping a card
      # that LOOKS per-project but isn't: this write unconditionally targeted the shared singleton
      # regardless of $PathsInfo.ProjectId. Fixed once already (a per-project %LOCALAPPDATA% rung),
      # then fixed AGAIN one rung further out after live testing showed a project's port/start/
      # health map belongs next to its own stories.json, not split off into the extension's own
      # appdata folder - see Get-StgAppMapPath's own comment for the full ladder. A resolved
      # project's write now always targets its OWN root (created there by New-StgProject at
      # project-creation time, so this is just "open the existing file" in the normal case); the
      # legacy no-project-context path (Resolve-StgPaths's step-3 fallback, e.g. a config with zero
      # projects) keeps writing the shared singleton exactly as before.
      if ($null -eq $msg.apps) {
        Reply @{ ok = $false; error = 'setappmap requires an apps object' }; break
      }
      $targetProjectId = [string]$PathsInfo.ProjectId
      $userMapPath = if ($targetProjectId -and $PathsInfo.Project -and $PathsInfo.Project.root) {
        Join-Path ([string]$PathsInfo.Project.root) 'app-map.json'
      } else {
        Join-Path (Get-StgUserConfigDir) 'app-map.json'
      }
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
      # pythonSentinel survives from whichever file is currently authoritative for THIS project (its
      # own per-project copy if it already has one, else the shared singleton, else the shipped
      # template - same ladder Get-StgAppMapPath's read side always used) so a first Settings save
      # doesn't quietly revert a custom sentinel back to story-env.ps1's own 'fastapi' default.
      $sentinel = 'fastapi'
      $currentPath = Get-StgAppMapPath -Project $targetProjectId
      if (Test-Path $currentPath) {
        try {
          $cur = Get-Content $currentPath -Raw | ConvertFrom-Json
          if ($cur.pythonSentinel) { $sentinel = [string]$cur.pythonSentinel }
        } catch {}
      }
      $out = [ordered]@{ pythonSentinel = $sentinel; apps = $cleanApps }
      try {
        # The per-project rung (…\projects\<id>\) may not exist yet on its first save - the shared
        # singleton's parent (Get-StgUserConfigDir itself) always does by this point, so this is a
        # no-op there.
        $mapParent = Split-Path $userMapPath -Parent
        if (-not (Test-Path $mapParent)) { New-Item -ItemType Directory -Path $mapParent -Force | Out-Null }
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
        # Worktree root / workspace dir: both $null in tracking mode by design (no worktrees, no
        # .code-workspace concept at all), so only checked for a worktree-mode project - a tracking
        # project reporting these as failed would be reporting a non-problem. Previously the
        # Settings diagnostics table showed a checkmark for these rows regardless of whether the
        # path actually existed on disk (there was no real check backing it at all); this closes
        # that gap rather than just fixing how the table reads a check that was never there.
        if ($PathsInfo.Mode -eq 'worktree') {
          & $add 'Worktree root exists' (Test-Path $PathsInfo.WorktreeRoot) $PathsInfo.WorktreeRoot 'Create the folder, or point Worktree root (Settings) at where it lives.'
          & $add 'Workspace dir exists' (Test-Path $PathsInfo.WorkspaceDir) $PathsInfo.WorkspaceDir 'Created automatically on first use (switch-story.ps1 new/open) - only a problem if creation itself failed.'
          & $add 'Repos root exists' (Test-Path $PathsInfo.ReposRoot) $PathsInfo.ReposRoot 'Create the folder, or point Repos root (Settings) at where your app clones actually live.'
        }
      }
      $gitCmd = Get-Command git -ErrorAction SilentlyContinue
      & $add 'git on PATH' ([bool]$gitCmd) ($gitCmd.Source) 'Install Git for Windows and ensure git.exe is on PATH.'
      $codeCmd = Get-Command code -ErrorAction SilentlyContinue
      & $add 'code (VS Code CLI) on PATH' ([bool]$codeCmd) ($codeCmd.Source) 'Optional - VS Code: Shell Command: Install ''code'' command in PATH.'
      # Kept in sync with setup.ps1's own script list by hand (both comments say so - see CLAUDE.md's
      # Dev gotchas for the drift this once had: this list used to be missing 3 of setup.ps1's 9
      # scripts entirely, so a broken/missing story-handover.ps1 or vault-status.ps1 install would
      # pass this check while genuinely failing at runtime).
      foreach ($s in @('switch-story.ps1', 'remove-worktree.ps1', 'story-ledger.ps1', 'story-release.ps1', 'story-doctor.ps1', 'story-env.ps1', 'story-handover.ps1', 'story-testplan.ps1', 'story-doc.ps1', 'vault-status.ps1', 'install-agent-skill.ps1')) {
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
