<#
  switch-story.ps1  -  Multi-story git-worktree manager
  ---------------------------------------------------------------
  Lives at the Ganesha workspace root. Reads/writes stories.json beside it.

  Each story gets ONE folder holding all its apps:   <worktreeRoot>\<STORY>\<app>
  The plain <root>\<app> folder is "home base", always parked on main.

  COMMANDS
    list
        Show every registered story, its apps, and whether each worktree exists.

    go <STORY>
        Make sure a worktree folder exists for every app in the story
        (creating any that are missing, on the story's existing branch),
        then print the folder paths to open.

    new <STORY> <env> <app1,app2,...>
        Cut a branch  feature/<env>/<STORY>  (or -Branch / -BranchFormat, see
        FLAGS) from a freshly fetched origin/main - unless that branch already
        exists in a given app's repo (locally or on origin), in which case it
        is checked out instead of re-cut. Copies .env from home base.
        Registers the story.

    add <STORY> <app1,app2,...>
        Add more apps to an existing story (same branch, same worktree root
        the story was created with).

    install <STORY>
        (Re)install dependencies in the story's existing worktrees:
        npm/yarn for frontends, .venv + pip for python apps.

    note <STORY> "message"
        Append a freeform entry to the story's changelog (decisions,
        what changed, pending items) so it survives across sessions.

    log <STORY>
        Print the story's changelog timeline. created/opened/added-app/
        installed/removed events are logged automatically; notes are manual.

    links <STORY> [-Set "Label=url",...] [-Remove "Label",...]
        Add/update/remove named custom links on the story (Abstract, Test
        plan, Design doc, or anything else) - comma-separate multiple pairs
        in one -Set/-Remove. Also the popup's per-row ✎ editor.

    remove <STORY> [-DeleteBranch]
        Remove the story's worktree folders. Branch is KEPT unless
        -DeleteBranch is given. Never deletes home base.

    open <STORY>
        Generate (or refresh) <STORY>.code-workspace listing the story's
        worktree folders as roots, and open it in VS Code as a single
        multi-root window. The .code-workspace files live in the sibling
        folder  ..\Ganesha_WorkSpaces  (worktrees are referenced relatively
        when they share $Root, absolutely when a custom worktree root moved
        them elsewhere).

  FLAGS
    -NoInstall   With go/new/add: create worktrees but skip dependency install.
    -Open        With go/new/add: open the story as a VS Code workspace when done.

  FLAGS (native-host\host.ps1 / the extension's Settings + "+ New story" form)
    -Root          Override for $PSScriptRoot - where stories.json, tools\ and
                   the home-base app clones actually live. Blank (the CLI
                   default) means "wherever this script physically sits",
                   unchanged from before this flag existed.
    -WorktreeRoot  Where <STORY>\<app> worktrees are created. Blank = same as
                   -Root (today's behavior: worktrees nested under the same
                   tree as everything else). Recorded on the story's node
                   (only when it differs from -Root) so a later change to this
                   setting never strands an already-created story - every
                   command that acts on an EXISTING story reads the node's own
                   worktreeRoot instead of trusting whatever's configured now.
    -BranchFormat  Template for the DERIVED default branch name, e.g.
                   'feature/{env}/{key}' (the built-in default, if omitted).
                   {env} and {key} are replaced literally - no other tokens.
                   -Branch (an exact name) still overrides this entirely.
    -Json          Emit ONE machine-readable JSON object on stdout instead of
                   console output. Wired for 'new', 'add' and 'open' only
                   today - other commands ignore it.
    -CheckOnly     Report what 'new' / 'add' would do (cloned? branch already
                   exists? already in the story?) and change nothing. Works
                   with or without -Json.
    -Title         Story title. Left blank ("") if omitted, same as before -
                   the extension's form fills this in since it can't reach Jira.
    -JiraUrl       Saved as jira_stories[0] on the node, same field the
                   ganesha-worktree skill writes by hand today.
    -Branch        Override the derived branch name entirely. A non-
                   conventional name still works but won't be found by
                   `gh pr list/create --head <branch>` or the ganesha-branches
                   skill - a warning says so.

  DEPENDENCY INSTALL (automatic on go/new/add unless -NoInstall)
    Frontend  : yarn install if yarn.lock present, else npm install.
    Python    : python -m venv .venv, then pip install -r requirements\dev.txt
                if present (it pulls in base.txt), else root requirements.txt.

  EXAMPLES
    .\switch-story.ps1 list
    .\switch-story.ps1 go EH7-3479
    .\switch-story.ps1 new EH7-3500 mint2 ganesha-iu-internal-app,ganesha-service-app
    .\switch-story.ps1 add EH7-3500 kuber-service-app
    .\switch-story.ps1 open EH7-3500
    .\switch-story.ps1 new EH7-3500 mint2 ganesha-iu-internal-app,ganesha-service-app -Open
    .\switch-story.ps1 new EH7-3500 mint2 ganesha-service-app -CheckOnly -Json
    .\switch-story.ps1 new EH7-3500 mint2 ganesha-service-app -WorktreeRoot D:\Worktrees
    .\switch-story.ps1 remove EH7-3500
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('list', 'go', 'new', 'add', 'remove', 'install', 'note', 'log', 'open', 'links')]
  [string]$Command,

  [Parameter(Position = 1)] [string]$Story,
  [Parameter(Position = 2)] [string]$A2,
  [Parameter(Position = 3)] [string]$A3,

  [switch]$DeleteBranch,
  [switch]$NoInstall,  # skip npm/yarn/pip install when creating worktrees
  [switch]$Open,       # on go/new/add: open the story's worktrees in VS Code when done

  # Settings-page overrides (see FLAGS above). All optional; unset = today's exact behavior.
  [string]$Root,
  [string]$WorktreeRoot,
  [string]$BranchFormat,

  # 'new' / 'add' - the extension's "+ New story" and "+ Add app" buttons.
  [switch]$Json,
  [switch]$CheckOnly,
  [string]$Title,
  [string]$JiraUrl,
  [string]$Branch,

  # 'links' - usable directly from the terminal via comma-array syntax (PowerShell's own parser
  # handles this correctly: `-Set "Abstract=https://...","Test plan=https://..."`, one -Set flag).
  # -Set upserts (add or overwrite) each "Label=url" pair; -Remove drops each named label.
  [string[]]$Set,
  [string[]]$Remove,
  # native-host\host.ps1 uses THIS instead of -Set/-Remove: base64 of a UTF-8 JSON blob
  # {"set":[{"label":..,"url":..}, ...], "remove":["Label", ...]}. Required because host.ps1
  # invokes every script via `powershell.exe -File` in a child process - confirmed empirically
  # that neither repeated `-Set X -Set Y` flags (PowerShell refuses: "parameter is specified more
  # than once") nor multiple bare tokens after one `-Set` (silently drops all but the first) bind
  # correctly through that path, and even a raw (unencoded) JSON string arrives with its quotes
  # stripped by -File's own re-tokenization. Base64 has no characters either layer reinterprets,
  # so it survives intact - the same reasoning PowerShell's own -EncodedCommand exists for.
  [string]$LinksB64
)

$ErrorActionPreference = 'Stop'

# Root resolution: this script now lives in tools\ alongside every other script, so it can no
# longer assume "wherever I physically sit" is the data root (that assumption broke the moment
# scripts stopped living at the Ganesha root). stg-paths.psm1's Resolve-StgPaths is the single
# resolver shared with every other script AND native-host\host.ps1 - see that file for the full
# precedence order (-Root param > stg-config.json > $env:STG_ROOT > auto-detect - config beats the
# env var so a long-lived process's frozen environment can never silently outrank Settings).
Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root -WorktreeRoot $WorktreeRoot
if ($Paths.NeedsSetup) {
  if ($Json) {
    [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress))
    exit 0
  }
  Write-Error $Paths.Error
  exit 1
}
$Root = $Paths.Root
$WorktreeRoot = $Paths.WorktreeRoot
$DefaultBranchFormat = 'feature/{env}/{key}'
$RegistryPath = $Paths.StoriesPath

# .code-workspace files live OUTSIDE the repo root, in a sibling folder, so they
# don't clutter the Ganesha workspace. Worktrees stay under $WorktreeRoot; the workspace
# files reference them with ..\<rootLeaf>\<STORY>\<app> relative paths when $WorktreeRoot
# is the default (same tree as $Root), or an absolute path otherwise (see Write-StoryWorkspace).
# Derived from $Paths.WorkspaceDir - <rootLeaf>_WorkSpaces by default (same "Ganesha_WorkSpaces"
# result as before for a root named Ganesha), overridable via stg-config.json's workspaceRoot.
$WorkspaceDir = $Paths.WorkspaceDir

# Under -Json, human-readable progress must NOT reach stdout - powershell.exe -File's child-process
# stdout is exactly what native-host\host.ps1 captures and feeds to ConvertFrom-Json, so a stray
# Write-Host/Write-Warning would corrupt the single JSON frame (confirmed: both land in the captured
# stream, not a separate one, when this script runs as a nested `powershell.exe -File` child).
# Outside -Json these behave exactly like Write-Host / Write-Warning always did, so no existing
# (non-JSON) command's output changes at all. Defined FIRST - before the StoryLib import below,
# which is the earliest point something could otherwise warn straight past this gate.
$script:JsonNotes = @()
$script:JsonWarnings = @()
function Say([string]$msg, [string]$color = 'White') {
  if ($Json) { $script:JsonNotes += $msg } else { Write-Host $msg -ForegroundColor $color }
}
function Warn2([string]$msg) {
  if ($Json) { $script:JsonWarnings += $msg } else { Write-Warning $msg }
}

# Shared helpers (registry lock, BOM-less writers, story-key shapes). Best-effort: this script must
# still work if the module is missing, so every use is guarded.
$StoryLibLoaded = $false
try {
  Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking
  $StoryLibLoaded = $true
}
catch { Warn2 "StoryLib.psm1 not loaded ($($_.Exception.Message)); continuing without the registry lock." }

# ---------- helpers ----------
# Local override of the module's Read-Registry: this script calls it with no arguments.
function Read-Registry {
  if (-not (Test-Path $RegistryPath)) {
    throw "stories.json not found at $RegistryPath"
  }
  Get-Content $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# PS 5.1's -Encoding utf8 ALWAYS writes a BOM, which breaks the JS consumers of stories.json
# (rules-lib.js / gen-rules.mjs). Write BOM-less UTF-8 explicitly.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# stories.json has five-plus writers (this script twice per command, story-env heal,
# remove-worktree, and the browser extension's native host) and no coordination, so an overlap
# silently discarded a node. Serialize the write behind the shared lock.
function Write-Registry($reg) {
  $lock = $null
  if ($StoryLibLoaded) { try { $lock = Enter-RegistryLock -Root $Root } catch { Warn2 $_.Exception.Message } }
  # Depth 12, matching remove-worktree.ps1 and story-env.ps1. The three writers of this one file
  # used to disagree (10 / 12 / 20); the lowest wins any race to truncate a deep node.
  try { Write-Utf8NoBom $RegistryPath ($reg | ConvertTo-Json -Depth 12) }
  finally { if ($lock) { Exit-RegistryLock $lock } }
}

# story-ledger.ps1 writes its -Json result with [Console]::Out.Write, which bypasses the
# PowerShell pipeline entirely - calling it IN-PROCESS (a bare `& $ledScript ... -Json`) would
# write that raw JSON text straight onto THIS script's own stdout, landing right next to (and
# corrupting) this script's own -Json reply. [void](...) cannot prevent this - it only discards
# PIPELINE output, and a direct console write never enters the pipeline in the first place. A
# genuinely separate child powershell.exe keeps the two streams apart, exactly like
# story-release.ps1's Invoke-Ledger and story-status.ps1's Get-LedgerNext already do for the same
# reason - this is that same fix, for the one caller (Invoke-New) that didn't have it yet.
function Invoke-LedgerJson([string[]]$LedgerArgs) {
  $lscript = Join-Path $PSScriptRoot 'story-ledger.ps1'
  if (-not (Test-Path -LiteralPath $lscript)) { return $null }
  $pargs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $lscript) + $LedgerArgs + @('-Json', '-Root', $Root)
  $out = & powershell.exe @pargs
  $global:LASTEXITCODE = 0
  $txt = ($out | Out-String).Trim()
  if (-not $txt) { return $null }
  try { return ($txt | ConvertFrom-Json) } catch { return $null }
}

# Terminal output for 'new': in -Json mode write ONLY the compact JSON to stdout (mirrors
# remove-worktree.ps1's Emit, so the native host gets a clean frame); else a human summary.
function Emit($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 10 -Compress)); return }
  if ($o.error) { Write-Host "`n  ERROR: $($o.error)`n" -ForegroundColor Red; return }
  if ($o.checkOnly) {
    if ($o.ok) { Write-Host "`n  $($o.story): clear to create $($o.branch) from origin/main." -ForegroundColor Green }
    else { Write-Host "`n  $($o.story): $($o.error)" -ForegroundColor Yellow }
    foreach ($a in $o.apps) {
      $tag = if (-not $a.onDisk) { 'NOT CLONED' } elseif ($a.inStory -and $a.present) { 'already in story' } elseif ($a.branchExisted) { 'existing branch' } else { 'new branch' }
      Write-Host ("    [{0}] {1}" -f $a.app, $tag) -ForegroundColor $(if (-not $a.onDisk) { 'Red' } else { 'DarkGray' })
    }
    foreach ($w in $o.warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
    Write-Host ""
    return
  }
  Write-Host "`n  Created $($o.story)" -ForegroundColor Cyan
  foreach ($c in $o.created) {
    $how = if ($c.branchExisted) { 'checked out existing branch' } else { 'branched from origin/main' }
    Write-Host ("    [{0}] {1} -> {2}" -f $c.app, $how, $c.path) -ForegroundColor Green
  }
  foreach ($f in $o.failed) { Write-Host ("    [{0}] FAILED - {1}" -f $f.app, $f.error) -ForegroundColor Red }
  foreach ($w in $o.warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
  Write-Host ("    ledger:    {0}" -f $o.ledger) -ForegroundColor DarkGray
  Write-Host ("    workspace: {0}" -f $o.workspace) -ForegroundColor DarkGray
  Write-Host ""
}

# Fail a 'new' precondition. Under -Json or -CheckOnly, report structured output instead of
# throwing, so the popup / a preview run gets a clean result instead of an unhandled-exception
# dump. The plain CLI path (neither flag) keeps throwing exactly as it always has.
function New-Bail([string]$msg) {
  if ($Json -or $CheckOnly) { Emit @{ ok = $false; story = $Story; checkOnly = [bool]$CheckOnly; error = $msg } }
  else { throw $msg }
}

# Worktrees are nested per story: <worktreeRoot>\<STORY>\<app>. $wtRootOverride lets a caller pin
# an EXISTING story to whatever root it was actually created under (the stories.json node's own
# 'worktreeRoot' field, when set) rather than today's global -WorktreeRoot - which may since have
# been reconfigured to somewhere the story was never physically created. Falls back to $Root, the
# behavior every story had before per-story worktree roots existed.
function Get-WtPath([string]$app, [string]$story, [string]$wtRootOverride = $null) {
  $wtRoot = if ($wtRootOverride) { $wtRootOverride } else { $Root }
  Join-Path (Join-Path $wtRoot $story) $app
}

# Path to a story's multi-root VS Code workspace file (lives in $WorkspaceDir).
function Get-WorkspacePath([string]$story) {
  Join-Path $WorkspaceDir ("{0}.code-workspace" -f $story)
}

# Generate/refresh the story's .code-workspace listing every existing worktree folder as a root.
# The file lives in $WorkspaceDir (a sibling of $Root). When the story's worktrees share $Root
# (the default - no custom worktree root), folders are referenced as ..\<rootLeaf>\<STORY>\<app>,
# same as always; a custom worktree root elsewhere (a different drive, even) can't be expressed as
# a '..' relative path from $WorkspaceDir, so those use an absolute path instead. Returns the path.
function Write-StoryWorkspace($s, [string]$story) {
  if (-not (Test-Path $WorkspaceDir)) { New-Item -ItemType Directory -Path $WorkspaceDir | Out-Null }
  $rootLeaf = Split-Path $Root -Leaf
  $wtRoot = if ($s.worktreeRoot) { $s.worktreeRoot } else { $Root }
  $sameRoot = ($wtRoot -eq $Root)
  $folders = @()
  foreach ($app in $s.apps) {
    $wt = Get-WtPath $app $story $s.worktreeRoot
    if (Test-Path $wt) {
      $entryPath = if ($sameRoot) { '..\{0}\{1}\{2}' -f $rootLeaf, $story, $app } else { $wt }
      $folders += [pscustomobject]@{ name = $app; path = $entryPath }
    }
    else {
      Warn2 "  [$app] no worktree yet - skipped (run: go $story)"
    }
  }
  if (-not $folders) { throw "No worktrees exist for $story yet. Run: go $story" }
  $wsObj = [pscustomobject]@{
    folders  = @($folders)
    settings = [pscustomobject]@{ 'window.title' = "$story `${separator} `${activeEditorShort}" }
  }
  $wsPath = Get-WorkspacePath $story
  Write-Utf8NoBom $wsPath ($wsObj | ConvertTo-Json -Depth 6)
  return $wsPath
}

# Build (or refresh) the story workspace file and open it in VS Code.
# Returns { workspace; opened } rather than staying void, so 'open -Json' (the popup's "Open
# workspace" button) can report what actually happened. Existing callers (Invoke-Go, Invoke-Open)
# must wrap the call in [void](...) - an uncaptured return value here would otherwise leak into
# their own output stream and print as a stray object for a plain CLI run.
function Open-StoryWorkspace($s, [string]$story) {
  $wsPath = Write-StoryWorkspace $s $story
  $code = Get-Command code -ErrorAction SilentlyContinue
  if ($code) {
    & $code.Source $wsPath
    Say "`nOpened $story in VS Code: $wsPath" 'Green'
  }
  else {
    Say "`nWorkspace ready (the 'code' CLI is not on PATH - open it manually):" 'Yellow'
    Say "  $wsPath" 'White'
  }
  [pscustomobject]@{ workspace = $wsPath; opened = [bool]$code }
}

# Append a timestamped entry to a story's log[] in stories.json. Reloads + saves
# on its own so it's safe to call after a command has already written the registry.
function Add-StoryLog([string]$story, [string]$type, [string]$message) {
  if (-not (Test-Path $RegistryPath)) { return }
  $reg = Get-Content $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not ($reg.stories.PSObject.Properties.Name -contains $story)) { return }
  $node = $reg.stories.$story
  if (-not ($node.PSObject.Properties.Name -contains 'log')) {
    $node | Add-Member -NotePropertyName 'log' -NotePropertyValue @()
  }
  $entry = [pscustomobject]@{
    ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    type    = $type
    message = $message
  }
  $node.log = @($node.log) + $entry
  # Through the shared lock (Write-Registry), not a direct write: this used to bypass
  # Enter-RegistryLock even though switch-story.ps1's own Invoke-New calls it seconds after
  # Write-Registry, which is exactly the kind of overlap the lock exists to serialize.
  Write-Registry $reg
}

# Run a mutating git command safely. git writes normal progress to stderr, which
# under ErrorActionPreference=Stop would otherwise become a fatal error. We relax
# the preference for the call and judge success by the real exit code.
function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments)] $GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE): $out"
    }
  }
  finally { $ErrorActionPreference = $prev }
}

function Get-StoryNode($reg, [string]$story) {
  if (-not ($reg.stories.PSObject.Properties.Name -contains $story)) {
    throw "Story '$story' is not in stories.json. Use 'new' to create it."
  }
  $reg.stories.$story
}

# Does $branch already exist in $baseDir, locally or on origin? Shared by 'add' (always has to ask
# this) and 'new' (only needs to ask when a branch was cut/kept by a prior create+remove, or an
# explicit -Branch collides with something).
function Test-BranchExists([string]$baseDir, [string]$branch) {
  return [bool]((git -C $baseDir branch --list $branch) -or (git -C $baseDir ls-remote --heads origin $branch))
}

# Reject anything `git worktree add -b <name>` would choke on, so a bad name is one clear error
# here instead of a cryptic per-app git failure. Not exhaustive vs git-check-ref-format, but covers
# the shapes that actually bite: whitespace/control chars, '..', the reserved punctuation, leading/
# trailing or doubled '/', a segment starting with '.', and a trailing '.'/'.lock'.
function Test-ValidBranchName([string]$b) {
  if ([string]::IsNullOrWhiteSpace($b)) { return $false }
  if ($b -eq '@') { return $false }
  if ($b -match '\.\.' -or $b -match '@\{' ) { return $false }
  if ($b -match '[\x00-\x1F\x7F ~^:?*\[\\]') { return $false }
  if ($b.StartsWith('/') -or $b.EndsWith('/') -or $b -match '//') { return $false }
  if ($b.EndsWith('.') -or $b.EndsWith('.lock')) { return $false }
  foreach ($seg in $b.Split('/')) { if (-not $seg -or $seg.StartsWith('.')) { return $false } }
  return $true
}

# If $branch is currently checked out in home base, park home base on main first
# (preserving any local .env edits) so the branch is free to move into a worktree.
# Returns the path to a saved .env backup if one was made, else $null.
function Free-BranchFromHome([string]$baseDir, [string]$app, [string]$branch) {
  $current = (git -C $baseDir rev-parse --abbrev-ref HEAD).Trim()
  if ($current -ne $branch) { return $null }

  $backup = $null
  $dirtyEnv = git -C $baseDir status --porcelain -- .env
  if ($dirtyEnv) {
    $backupDir = Join-Path $Root '.env-backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    # Timestamped: the old fixed '<app>.env' name was a single slot, so the second story to park the
    # same app's .env silently overwrote the first story's backup.
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path $backupDir ("{0}.{1}.env" -f $app, $stamp)
    Copy-Item (Join-Path $baseDir '.env') $backup -Force
    Invoke-Git -C $baseDir stash push -m "switch-story: park .env for $branch" -- .env
    # The stash is never popped automatically, so record where the copy went - otherwise home base's
    # pointing sits stashed indefinitely with nothing saying it happened.
    Say "  [$app] local .env copied to $backup + stashed before parking home base" 'Yellow'
    Say "         (restore with: Copy-Item '$backup' '$(Join-Path $baseDir '.env')')" 'DarkGray'
  }
  Invoke-Git -C $baseDir checkout main
  Say "  [$app] home base parked on main" 'DarkGray'
  return $backup
}

# Create a worktree for $app on an EXISTING $branch (used by go / add-existing / new-when-the-
# branch-already-exists). $wtRoot: see Get-WtPath - pass the story's OWN worktreeRoot when acting
# on an existing story, or the current -WorktreeRoot when creating a new one.
function New-WorktreeExisting([string]$app, [string]$story, [string]$branch, [string]$wtRoot = $null) {
  $baseDir = Join-Path $Root $app
  $wt = Get-WtPath $app $story $wtRoot
  if (Test-Path $wt) { Say "  [$app] already at $wt" 'DarkGray'; return }
  if (-not (Test-Path (Join-Path $baseDir '.git'))) { Warn2 "  [$app] no repo at $baseDir - skipping"; return }

  Invoke-Git -C $baseDir fetch origin --quiet
  $envBackup = Free-BranchFromHome $baseDir $app $branch
  New-Item -ItemType Directory -Force -Path (Split-Path $wt -Parent) | Out-Null  # ensure <worktreeRoot>\<STORY> exists
  Invoke-Git -C $baseDir worktree add $wt $branch
  if ($envBackup) {
    # Carry the local .env edits we parked into the new story folder.
    Copy-Item $envBackup (Join-Path $wt '.env') -Force
    Say "  [$app] parked .env restored into story folder" 'Yellow'
  }
  else {
    Copy-EnvInto $baseDir $wt $app
  }
  Say "  [$app] worktree created -> $wt" 'Green'
  if (-not $NoInstall) { Install-Deps $app $wt }
}

# Cut a NEW branch from origin/main as a worktree (used by new / add-new). $wtRoot: see above.
function New-WorktreeFromMain([string]$app, [string]$story, [string]$branch, [string]$wtRoot = $null) {
  $baseDir = Join-Path $Root $app
  $wt = Get-WtPath $app $story $wtRoot
  if (Test-Path $wt) { Say "  [$app] already at $wt" 'DarkGray'; return }
  if (-not (Test-Path (Join-Path $baseDir '.git'))) { Warn2 "  [$app] no repo at $baseDir - skipping"; return }

  Invoke-Git -C $baseDir fetch origin --quiet
  New-Item -ItemType Directory -Force -Path (Split-Path $wt -Parent) | Out-Null  # ensure <worktreeRoot>\<STORY> exists
  # Branch ALWAYS from freshly-fetched origin/main, never from whatever is checked out.
  Invoke-Git -C $baseDir worktree add -b $branch $wt origin/main
  Copy-EnvInto $baseDir $wt $app
  Say "  [$app] branched $branch from origin/main -> $wt" 'Green'
  if (-not $NoInstall) { Install-Deps $app $wt }
}

# Seed a worktree's .env from home base if the worktree doesn't already have local edits.
function Copy-EnvInto([string]$baseDir, [string]$wt, [string]$app) {
  $srcEnv = Join-Path $baseDir '.env'
  $dstEnv = Join-Path $wt '.env'
  if (Test-Path $srcEnv) {
    Copy-Item $srcEnv $dstEnv -Force
    Say "  [$app] .env seeded from home base (verify URLs/ports for this story's env)" 'Yellow'
  }
}

# Install dependencies for a worktree. Frontend (package.json): yarn if yarn.lock
# else npm. Python: create .venv and pip install requirements/dev.txt (which pulls
# in base.txt) or root requirements.txt. Best-effort: warns on failure, never aborts.
function Install-Deps([string]$app, [string]$wt) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # npm/pip write normal progress to stderr
  try {
    if (Test-Path (Join-Path $wt 'package.json')) {
      Push-Location $wt
      try {
        if (Test-Path (Join-Path $wt 'yarn.lock')) {
          Say "  [$app] yarn install (frontend) - this can take a few minutes..." 'Cyan'
          & yarn install
        }
        else {
          Say "  [$app] npm install (frontend) - this can take a few minutes..." 'Cyan'
          & npm install
        }
        if ($LASTEXITCODE -ne 0) { Warn2 "  [$app] frontend install exited $LASTEXITCODE" }
        else { Say "  [$app] frontend deps installed" 'Green' }
      }
      finally { Pop-Location }
      return
    }

    $req = $null
    if (Test-Path (Join-Path $wt 'requirements\dev.txt')) { $req = 'requirements\dev.txt' }
    elseif (Test-Path (Join-Path $wt 'requirements.txt')) { $req = 'requirements.txt' }
    if ($req) {
      Push-Location $wt
      try {
        $py = Join-Path $wt '.venv\Scripts\python.exe'
        Say "  [$app] creating .venv ..." 'Cyan'
        & python -m venv .venv
        if (-not (Test-Path $py)) { Warn2 "  [$app] .venv creation failed - is 'python' on PATH?"; return }
        Say "  [$app] pip install -r $req - this can take a few minutes..." 'Cyan'
        & $py -m pip install --upgrade pip --quiet
        & $py -m pip install -r $req
        if ($LASTEXITCODE -ne 0) { Warn2 "  [$app] pip install exited $LASTEXITCODE" }
        else { Say "  [$app] python deps installed in .venv" 'Green' }
      }
      finally { Pop-Location }
      return
    }
    Say "  [$app] no package.json / requirements*.txt - nothing to install" 'DarkGray'
  }
  finally { $ErrorActionPreference = $prev }
}

# ---------- commands ----------
function Invoke-List {
  $reg = Read-Registry
  Write-Host ""
  Write-Host "Stories" -ForegroundColor Cyan
  foreach ($name in $reg.stories.PSObject.Properties.Name) {
    $s = $reg.stories.$name
    Write-Host ("`n  {0}  [{1}]  {2}" -f $name, $s.env, $s.title) -ForegroundColor White
    Write-Host ("    branch: {0}" -f $s.branch) -ForegroundColor DarkGray
    foreach ($app in $s.apps) {
      $wt = Get-WtPath $app $name $s.worktreeRoot
      $mark = if (Test-Path $wt) { "OK " } else { "--  (run: go $name)" }
      Write-Host ("    [{0}] {1}" -f $mark, $app)
    }
  }
  Write-Host ""
}

function Invoke-Go {
  if (-not $Story) { throw "Usage: go <STORY>" }
  $reg = Read-Registry
  $s = Get-StoryNode $reg $Story
  Write-Host "`nStory $Story [$($s.env)] - $($s.title)" -ForegroundColor Cyan
  Write-Host "Branch: $($s.branch)`n" -ForegroundColor DarkGray
  foreach ($app in $s.apps) { New-WorktreeExisting $app $Story $s.branch $s.worktreeRoot }
  Add-StoryLog $Story 'opened' "switched to story (worktrees ensured)"
  if ($Open) { [void](Open-StoryWorkspace $s $Story) }
  else {
    Write-Host "`nOpen these folders:" -ForegroundColor Cyan
    foreach ($app in $s.apps) { Write-Host "  $(Get-WtPath $app $Story $s.worktreeRoot)" }
    Write-Host "`n(tip: re-run with -Open, or 'open $Story', to launch them as one VS Code workspace)" -ForegroundColor DarkGray
  }
  Write-Host ""
}

function Invoke-New {
  if (-not $Story -or -not $A2 -or -not $A3) {
    throw "Usage: new <STORY> <env> <app1,app2,...>"
  }
  $env = $A2
  $apps = @($A3.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $fmt = if ($BranchFormat) { $BranchFormat } else { $DefaultBranchFormat }
  $derivedBranch = $fmt.Replace('{env}', $env).Replace('{key}', $Story)
  $branchDerived = -not [bool]$Branch
  $branch = if ($Branch) { $Branch } else { $derivedBranch }

  # Validate the key BEFORE creating anything. 'new' used to accept any string, so a key the other
  # tools reject could be created and then never torn down: remove-worktree.ps1 and the extension's
  # 🗑 both answered "invalid story key" forever. Same shapes as StoryLib's Test-StoryKey.
  if ($Story -notmatch '^[A-Za-z0-9]+-\d+$' -and $Story -notmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)+$') {
    New-Bail "Invalid story key '$Story'. Use a Jira key (EH7-9550) or an all-lowercase kebab slug (kuber-partner-date) - other shapes cannot be removed by remove-worktree.ps1."
    return
  }

  # Branch is normally derived from -BranchFormat (or the built-in default), but -Branch (the
  # popup's editable field) can override it outright. Validate the shape either way - better one
  # clear error here than a cryptic per-app git failure.
  if (-not (Test-ValidBranchName $branch)) {
    New-Bail "Invalid branch name '$branch'."
    return
  }
  if (-not $branchDerived -and $branch -ne $derivedBranch) {
    Warn2 "branch '$branch' does not match the '$fmt' convention ($derivedBranch) - gh pr list/create --head and the ganesha-branches skill won't find it automatically."
  }

  $reg = Read-Registry
  if ($reg.stories.PSObject.Properties.Name -contains $Story) {
    New-Bail "Story '$Story' already exists. Use 'add' to add apps, or 'go' to open it."
    return
  }

  # Warn on unmapped apps up front: an app absent from app-map.json has no port, start command or
  # health path, so story-env can never bring it up - it just reports 'unmapped' forever.
  $mapPath = $Paths.AppMapPath
  if (Test-Path $mapPath) {
    $known = @((Get-Content $mapPath -Raw | ConvertFrom-Json).apps.PSObject.Properties.Name)
    foreach ($app in $apps) {
      if ($known -notcontains $app) { Warn2 "  [$app] not in app-map.json - story-env will report it 'unmapped' (no port/start/health). Add it there." }
    }
  }

  # Per-app plan: is it cloned at all, and does the branch already exist (locally or on origin)?
  # The second question used to matter only to 'add' (see Test-BranchExists / Invoke-Add) - 'new'
  # always cut -b from main and would hard-fail if the branch happened to exist, e.g. recreating a
  # story whose branch survived a prior remove-worktree.ps1 (which keeps branches by default unless
  # -DeleteBranch). Checking here fixes that case and lets an explicit -Branch collide safely too.
  $plan = @(foreach ($app in $apps) {
    $baseDir = Join-Path $Root $app
    $onDisk = Test-Path (Join-Path $baseDir '.git')
    $branchExisted = $onDisk -and (Test-BranchExists $baseDir $branch)
    [pscustomobject]@{ app = $app; onDisk = $onDisk; branchExisted = [bool]$branchExisted }
  })
  $missing = @($plan | Where-Object { -not $_.onDisk })

  if ($CheckOnly) {
    $ok = ($missing.Count -eq 0)
    $res = @{ ok = $ok; checkOnly = $true; story = $Story; env = $env; branch = $branch;
      branchDerived = $branchDerived; worktreeRoot = $WorktreeRoot; apps = @($plan);
      warnings = @($script:JsonWarnings) }
    if (-not $ok) { $res.error = "not cloned: $((@($missing | ForEach-Object { $_.app })) -join ', ')" }
    Emit $res
    return
  }

  Say "`nNew story $Story [$env] - branch $branch$(if (-not $branchDerived) { ' (custom)' }) (from origin/main)`n" 'Cyan'

  # Register the node FIRST. Worktree creation is not transactional: if 'git worktree add' failed on
  # app 3 of 4 under $ErrorActionPreference='Stop', the earlier worktrees existed with no registry
  # node at all - invisible to list / go / the extension.
  # @() matters: with a SINGLE app the Split|ForEach|Where pipeline above yields a scalar
  # string, which serializes as "apps": "one-app" and throws
  # 'TypeError: .map is not a function' in the extension's rules-lib.js buildRules().
  $node = [pscustomobject]@{ env = $env; branch = $branch; title = [string]$Title; apps = @($apps) }
  if ($JiraUrl) { $node | Add-Member -NotePropertyName 'jira_stories' -NotePropertyValue @($JiraUrl) }
  # Recorded ONLY when it differs from $Root, so a plain/default setup's nodes stay exactly as
  # before. This is what lets a LATER change to -WorktreeRoot never strand an already-created story:
  # every command that acts on an existing story reads this field instead of the current setting.
  if ($WorktreeRoot -ne $Root) { $node | Add-Member -NotePropertyName 'worktreeRoot' -NotePropertyValue $WorktreeRoot }
  $reg.stories | Add-Member -NotePropertyName $Story -NotePropertyValue $node
  Write-Registry $reg
  Add-StoryLog $Story 'created' ("branch {0} from origin/main; apps: {1}" -f $branch, ($apps -join ', '))

  # Per-app creation. Each app is independent: one failing no longer aborts the rest (they used to,
  # under $ErrorActionPreference='Stop' with no per-app try/catch) - a partial result is reported
  # instead, matching how remove-worktree.ps1 already reports per-app removal outcomes.
  $created = @(); $failed = @()
  foreach ($p in $plan) {
    $app = $p.app
    try {
      if (-not $p.onDisk) { throw "no repo at $(Join-Path $Root $app)" }
      if ($p.branchExisted) { New-WorktreeExisting $app $Story $branch $WorktreeRoot }
      else { New-WorktreeFromMain $app $Story $branch $WorktreeRoot }
      $wt = Get-WtPath $app $Story $WorktreeRoot
      if (Test-Path $wt) { $created += [pscustomobject]@{ app = $app; path = $wt; status = 'created'; branchExisted = $p.branchExisted } }
      else { $failed += [pscustomobject]@{ app = $app; error = 'worktree not created (see warnings)' } }
    }
    catch { $failed += [pscustomobject]@{ app = $app; error = $_.Exception.Message } }
  }

  # Create the ledger immediately, so phase state exists from the start rather than only when
  # someone remembers to run the ledger by hand (which is why some stories have none at all).
  # Invoke-LedgerJson (child powershell.exe, not an in-process `&`) - see its own comment for why:
  # story-ledger.ps1's -Json output bypasses the pipeline entirely, so an in-process call used to
  # corrupt THIS script's own -Json reply with two concatenated JSON documents (the reported cause
  # of the popup's "add returned no JSON").
  $ledgerStatus = 'skipped (story-ledger.ps1 not found)'
  try {
    $ledRes = Invoke-LedgerJson @('init', '-Story', $Story)
    if ($null -eq $ledRes) { $ledgerStatus = 'skipped (story-ledger.ps1 not found)' }
    elseif ($ledRes.ok) { $ledgerStatus = 'initialized' }
    else {
      $ledgerStatus = "not initialized: $($ledRes.error)"
      Warn2 "  ledger not initialized: $($ledRes.error)"
    }
  }
  catch {
    $ledgerStatus = "not initialized: $($_.Exception.Message)"
    Warn2 "  ledger not initialized: $($_.Exception.Message)"
  }

  Say "`nRegistered $Story in stories.json$(if (-not $Title) { ' (title is blank - fill it in if you like)' }).`n" 'Green'

  # Open-StoryWorkspace (matching Invoke-Add, line ~802), not the raw Write-StoryWorkspace + bare
  # `& $code.Source` this used to do - that bare, unassigned external-command call let any stdout
  # `code.cmd` happened to print flow straight through to this script's own -Json reply.
  # Open-StoryWorkspace's entire output (including its own nested `& $code.Source` call) is
  # captured here because it's assigned to $r, which - unlike story-ledger.ps1's
  # [Console]::Out.Write - works fine for ordinary pipeline/external-command output.
  $workspaceStatus = 'not requested'
  if ($Open) {
    try {
      $r = Open-StoryWorkspace $reg.stories.$Story $Story
      $workspaceStatus = $r.workspace
    }
    catch {
      $workspaceStatus = "failed: $($_.Exception.Message)"
      Warn2 "  workspace: $($_.Exception.Message)"
    }
  }

  if ($Json) {
    Emit @{ ok = ($failed.Count -eq 0); story = $Story; env = $env; branch = $branch; branchDerived = $branchDerived;
      title = [string]$Title; apps = @($apps); worktreeRoot = $WorktreeRoot; created = @($created); failed = @($failed);
      workspace = $workspaceStatus; ledger = $ledgerStatus; warnings = @($script:JsonWarnings); notes = @($script:JsonNotes) }
  }
}

# Add apps to an EXISTING story. Same -Json / -CheckOnly contract as 'new' (the popup's "+ Add app"
# button): per-app plan, read-only preview, per-app try/catch, structured result.
function Invoke-Add {
  if (-not $Story -or -not $A2) { throw "Usage: add <STORY> <app1,app2,...>" }
  $newApps = @($A2.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $reg = Read-Registry
  if (-not ($reg.stories.PSObject.Properties.Name -contains $Story)) {
    New-Bail "Story '$Story' is not in stories.json. Use 'new' to create it."
    return
  }
  $s = $reg.stories.$Story
  $existing = @($s.apps | Where-Object { $_ })

  $mapPath = $Paths.AppMapPath
  if (Test-Path $mapPath) {
    $known = @((Get-Content $mapPath -Raw | ConvertFrom-Json).apps.PSObject.Properties.Name)
    foreach ($app in $newApps) {
      if ($known -notcontains $app) { Warn2 "  [$app] not in app-map.json - story-env will report it 'unmapped' (no port/start/health). Add it there." }
    }
  }

  # Per-app plan: cloned? branch already exists? already in this story / already on disk?
  $plan = @(foreach ($app in $newApps) {
    $baseDir = Join-Path $Root $app
    $onDisk = Test-Path (Join-Path $baseDir '.git')
    $branchExisted = $onDisk -and (Test-BranchExists $baseDir $s.branch)
    $present = Test-Path (Get-WtPath $app $Story $s.worktreeRoot)
    [pscustomobject]@{ app = $app; onDisk = $onDisk; branchExisted = [bool]$branchExisted
      inStory = ($existing -contains $app); present = [bool]$present }
  })
  $missing = @($plan | Where-Object { -not $_.onDisk })
  $todo = @($plan | Where-Object { -not ($_.inStory -and $_.present) })

  if ($CheckOnly) {
    $ok = ($missing.Count -eq 0) -and ($todo.Count -gt 0)
    $res = @{ ok = $ok; checkOnly = $true; story = $Story; env = $s.env; branch = $s.branch;
      worktreeRoot = $s.worktreeRoot; apps = @($plan); warnings = @($script:JsonWarnings) }
    if ($missing.Count) { $res.error = "not cloned: $((@($missing | ForEach-Object { $_.app })) -join ', ')" }
    elseif (-not $todo.Count) { $res.error = "already in story: $((@($plan | ForEach-Object { $_.app })) -join ', ')" }
    Emit $res
    return
  }

  Say "`nAdding apps to $Story (branch $($s.branch))`n" 'Cyan'
  $created = @(); $failed = @()
  foreach ($p in $todo) {
    $app = $p.app
    try {
      if (-not $p.onDisk) { throw "no repo at $(Join-Path $Root $app)" }
      # New apps join the story's EXISTING worktree root (s.worktreeRoot), not today's -WorktreeRoot.
      if ($p.branchExisted) { New-WorktreeExisting $app $Story $s.branch $s.worktreeRoot }
      else { New-WorktreeFromMain $app $Story $s.branch $s.worktreeRoot }
      $wt = Get-WtPath $app $Story $s.worktreeRoot
      if (Test-Path $wt) { $created += [pscustomobject]@{ app = $app; path = $wt; status = 'created'; branchExisted = $p.branchExisted } }
      else { $failed += [pscustomobject]@{ app = $app; error = 'worktree not created (see warnings)' } }
    }
    catch { $failed += [pscustomobject]@{ app = $app; error = $_.Exception.Message } }
  }

  # Register only what is actually on disk now. @() so a one-app story stays a JSON array.
  $onDiskNow = @($plan | Where-Object { Test-Path (Get-WtPath $_.app $Story $s.worktreeRoot) } | ForEach-Object { $_.app })
  $s.apps = @($existing + $onDiskNow | Select-Object -Unique)
  Write-Registry $reg
  if ($created.Count) { Add-StoryLog $Story 'added-app' ("added: {0}" -f (@($created | ForEach-Object { $_.app }) -join ', ')) }
  Say "`nUpdated app list for $Story.`n" 'Green'

  $workspaceStatus = 'not requested'
  if ($Open) {
    try {
      $r = Open-StoryWorkspace $reg.stories.$Story $Story
      $workspaceStatus = $r.workspace
    }
    catch {
      $workspaceStatus = "failed: $($_.Exception.Message)"
      Warn2 "  workspace: $($_.Exception.Message)"
    }
  }

  if ($Json) {
    Emit @{ ok = ($failed.Count -eq 0); story = $Story; env = $s.env; branch = $s.branch; apps = @($s.apps);
      created = @($created); failed = @($failed); workspace = $workspaceStatus;
      warnings = @($script:JsonWarnings); notes = @($script:JsonNotes) }
  }
  elseif ($failed.Count) {
    foreach ($f in $failed) { Write-Host ("    [{0}] FAILED - {1}" -f $f.app, $f.error) -ForegroundColor Red }
  }
}

function Invoke-Note {
  if (-not $Story -or -not $A2) { throw 'Usage: note <STORY> "what changed / decision / pending item"' }
  $reg = Read-Registry
  [void](Get-StoryNode $reg $Story)   # validate story exists
  Add-StoryLog $Story 'note' $A2
  Write-Host "`nLogged note on $Story.`n" -ForegroundColor Green
}

function Invoke-Log {
  if (-not $Story) { throw "Usage: log <STORY>" }
  $reg = Read-Registry
  $s = Get-StoryNode $reg $Story
  Write-Host "`nHistory for $Story [$($s.env)] - $($s.title)" -ForegroundColor Cyan
  Write-Host "Branch: $($s.branch)`n" -ForegroundColor DarkGray
  if (-not $s.PSObject.Properties.Name.Contains('log') -or -not $s.log) {
    Write-Host "  (no log entries yet - add one with: note $Story `"...`")" -ForegroundColor DarkGray
  }
  else {
    foreach ($e in $s.log) {
      Write-Host ("  {0}  [{1,-9}] {2}" -f $e.ts, $e.type, $e.message)
    }
  }
  Write-Host ""
}

# Add / update / remove named custom links on an EXISTING story - the popup's per-row ✎ editor,
# and directly usable from the terminal:
#   switch-story.ps1 links EH7-1234 -Set "Abstract=https://...","Test plan=https://..."
#   switch-story.ps1 links EH7-1234 -Remove "Old label"
# native-host\host.ps1 uses -LinksB64 instead (see the param block comment for why -Set/-Remove
# don't survive its -File child-process invocation). Goes through StoryLib's
# Invoke-RegistryUpdate (read + mutate + write under ONE lock acquisition) rather than this
# script's own Read-Registry/Write-Registry pair - those read the node OUTSIDE the lock (see
# Invoke-New/Invoke-Add), a real lost-update race a links write must not risk. No local fallback
# if StoryLib failed to load: an unlocked links write is worse than refusing to run.
function Invoke-Links {
  if (-not $Story) { throw "Usage: links <STORY> [-Set `"Label=url`",...] [-Remove `"Label`",...]" }
  if (-not $StoryLibLoaded -or -not (Get-Command Invoke-RegistryUpdate -ErrorAction SilentlyContinue)) {
    $m = "StoryLib.psm1 not loaded - required for 'links' (registry-lock safety)."
    if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
    throw $m
  }

  $rawSetEntries = @($Set)
  $rawRemoveEntries = @($Remove)
  if ($LinksB64) {
    try {
      $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($LinksB64))
      $payload = $decoded | ConvertFrom-Json
    }
    catch {
      $m = "invalid -LinksB64 payload: $($_.Exception.Message)"
      if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
      throw $m
    }
    foreach ($p in @($payload.set)) { if ($p.label -and $p.url) { $rawSetEntries += "$($p.label)=$($p.url)" } }
    foreach ($r in @($payload.remove)) { if ($r) { $rawRemoveEntries += "$r" } }
  }

  $setPairs = @()
  foreach ($rawEntry in $rawSetEntries) {
    if (-not $rawEntry) { continue }
    $parts = $rawEntry.Split('=', 2)  # split on the FIRST '=' only - a url's own query string may contain '='
    if ($parts.Count -ne 2) {
      $m = "invalid -Set value (expected 'Label=url'): $rawEntry"
      if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
      throw $m
    }
    $label = $parts[0].Trim()
    $url   = $parts[1].Trim()
    if (-not $label -or $label.Length -gt 60) {
      $m = "link label must be 1-60 chars: '$label'"
      if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
      throw $m
    }
    if (-not $url -or $url.Length -gt 2000 -or $url -notmatch '(?i)^https?://') {
      $m = "link url must start with http:// or https:// and be <=2000 chars: '$label' = '$url'"
      if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
      throw $m
    }
    $setPairs += [pscustomobject]@{ label = $label; url = $url }
  }
  $removeLabels = @($rawRemoveEntries | Where-Object { $_ } | ForEach-Object { $_.Trim() })

  if ($setPairs.Count -eq 0 -and $removeLabels.Count -eq 0) {
    $m = 'links: nothing to do (pass -Set and/or -Remove)'
    if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
    throw $m
  }

  try {
    $reg = Invoke-RegistryUpdate -Root $Root -Mutate {
      param($r)
      if (-not ($r.stories.PSObject.Properties.Name -contains $Story)) { return $false }
      $node = $r.stories.$Story
      if (-not ($node.PSObject.Properties.Name -contains 'links') -or -not $node.links) {
        $node | Add-Member -NotePropertyName 'links' -NotePropertyValue ([pscustomobject]@{}) -Force
      }
      foreach ($p in $setPairs) {
        if ($node.links.PSObject.Properties.Name -contains $p.label) { $node.links.$($p.label) = $p.url }
        else { $node.links | Add-Member -NotePropertyName $p.label -NotePropertyValue $p.url }
      }
      foreach ($lbl in $removeLabels) {
        if ($node.links.PSObject.Properties.Name -contains $lbl) { $node.links.PSObject.Properties.Remove($lbl) }
      }
      if (@($node.links.PSObject.Properties).Count -gt 20) { throw 'a story may carry at most 20 links' }
      $logEntry = [pscustomobject]@{
        ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        type    = 'links'
        message = (@($setPairs | ForEach-Object { "+$($_.label)" }) + @($removeLabels | ForEach-Object { "-$_" })) -join ', '
      }
      if (-not ($node.PSObject.Properties.Name -contains 'log')) { $node | Add-Member -NotePropertyName 'log' -NotePropertyValue @() }
      $node.log = @($node.log) + $logEntry
      return $true
    }
  }
  catch {
    $m = "links: $($_.Exception.Message)"
    if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
    throw $m
  }

  if (-not ($reg.stories.PSObject.Properties.Name -contains $Story)) {
    $m = "Story '$Story' is not in stories.json."
    if ($Json) { [Console]::Out.Write((@{ ok = $false; story = $Story; error = $m } | ConvertTo-Json -Compress)); return }
    throw $m
  }

  $resultLinks = $reg.stories.$Story.links
  $summary = @(@($setPairs | ForEach-Object { "+$($_.label)" }) + @($removeLabels | ForEach-Object { "-$_" }))
  if ($Json) {
    [Console]::Out.Write((@{ ok = $true; story = $Story; links = $resultLinks; changed = $summary } | ConvertTo-Json -Depth 6 -Compress))
  }
  else {
    Write-Host "`nLinks updated on $Story ($($summary -join ', ')).`n" -ForegroundColor Green
  }
}

function Invoke-Open {
  if (-not $Story) { throw "Usage: open <STORY>" }
  $reg = Read-Registry
  $s = Get-StoryNode $reg $Story
  Say "`nOpening $Story [$($s.env)] - $($s.title)" 'Cyan'
  $r = Open-StoryWorkspace $s $Story
  Say ""
  if ($Json) { Emit @{ ok = $true; story = $Story; workspace = $r.workspace; opened = $r.opened } }
}

function Invoke-Install {
  if (-not $Story) { throw "Usage: install <STORY>" }
  $reg = Read-Registry
  $s = Get-StoryNode $reg $Story
  Write-Host "`nInstalling deps for $Story`n" -ForegroundColor Cyan
  foreach ($app in $s.apps) {
    $wt = Get-WtPath $app $Story $s.worktreeRoot
    if (Test-Path $wt) { Install-Deps $app $wt }
    else { Write-Warning "  [$app] no worktree yet - run: go $Story" }
  }
  Add-StoryLog $Story 'installed' ("deps installed for: {0}" -f ($s.apps -join ', '))
  Write-Host ""
}

function Invoke-Remove {
  if (-not $Story) { throw "Usage: remove <STORY> [-DeleteBranch]" }
  $reg = Read-Registry
  $s = Get-StoryNode $reg $Story

  Write-Host "`nRemoving worktrees for $Story`n" -ForegroundColor Cyan
  foreach ($app in $s.apps) {
    $baseDir = Join-Path $Root $app
    $wt = Get-WtPath $app $Story $s.worktreeRoot
    if (Test-Path $wt) {
      try { Invoke-Git -C $baseDir worktree remove $wt } catch {}
      if (Test-Path $wt) { Write-Warning "  [$app] worktree has uncommitted changes - not removed. Commit/push first, or remove with --force." }
      else { Write-Host "  [$app] worktree removed" -ForegroundColor Green }
    }
    else { Write-Host "  [$app] no worktree" -ForegroundColor DarkGray }
    if ($DeleteBranch -and -not (Test-Path $wt)) {
      try { Invoke-Git -C $baseDir branch -D $s.branch } catch {}
      Write-Host "  [$app] local branch deleted" -ForegroundColor Yellow
    }
  }
  # Drop the now-empty <worktreeRoot>\<STORY> parent folder (nested layout).
  $storyWtRoot = if ($s.worktreeRoot) { $s.worktreeRoot } else { $Root }
  $storyDir = Join-Path $storyWtRoot $Story
  if ((Test-Path $storyDir) -and -not (Get-ChildItem -Path $storyDir -Force -ErrorAction SilentlyContinue)) {
    try { Remove-Item -LiteralPath $storyDir -Force -ErrorAction Stop } catch {}
  }
  Add-StoryLog $Story 'removed' ("worktrees removed{0}" -f $(if ($DeleteBranch) { ' + local branch deleted' } else { '' }))
  Write-Host "`n(Story kept in stories.json. Edit by hand to drop it.)`n" -ForegroundColor DarkGray
}

# 'new', 'add' and 'open' are the only commands wired to -Json today (the popup's "+ New story",
# "+ Add app" and "Open workspace" buttons). Wrapping just their dispatch in try/catch means any exception that
# escapes their own guards (a missing/unreadable stories.json, a registry-lock failure, no
# worktrees yet for 'open') still comes back as one clean JSON object instead of a raw PowerShell
# error dump that would break the native host's ConvertFrom-Json. Every other command's dispatch
# is untouched.
if ($Json) {
  try {
    switch ($Command) {
      'new'   { Invoke-New }
      'add'   { Invoke-Add }
      'open'  { Invoke-Open }
      'links' { Invoke-Links }
      default { [Console]::Out.Write((@{ ok = $false; error = "command '$Command' does not support -Json yet" } | ConvertTo-Json -Compress)) }
    }
  }
  catch {
    [Console]::Out.Write((@{ ok = $false; error = ("switch-story error: " + $_.Exception.Message) } | ConvertTo-Json -Compress))
  }
}
else {
  switch ($Command) {
    'list'    { Invoke-List }
    'go'      { Invoke-Go }
    'new'     { Invoke-New }
    'add'     { Invoke-Add }
    'remove'  { Invoke-Remove }
    'install' { Invoke-Install }
    'note'    { Invoke-Note }
    'log'     { Invoke-Log }
    'open'    { Invoke-Open }
    'links'   { Invoke-Links }
  }
}
