#requires -Version 5.1
<#
  install-agent-skill.ps1 - renders (and optionally installs) an agent skill. Two different shapes
  share this one script:

  - PROJECT skills (story-tab-groups, setup-dev-loop): a single SKILL.md template with
    {{PROJECT_ID}}/{{PROJECT_ROOT}}/{{TOOLS_DIR}} substituted so every command the skill teaches is
    concrete and runnable, not a template. -Project is MANDATORY for these, unlike every other tool
    in this folder (which falls back to the currently-active project when omitted) - a skill
    silently bound to "whichever project happens to be active in the popup right now" would be
    actively wrong the moment a second project exists or the active one changes later. Baking in
    the wrong id is worse than refusing to guess.
  - GENERIC skills (nextjs-project-architecture, shadcn-from-mantine, and any future one added to
    $GenericSkills below):
    not bound to any project at all - no placeholders, and typically more than one file
    (references/, assets/ alongside SKILL.md). Rendering is a no-op passthrough of SKILL.md's own
    text; installing copies the skill's WHOLE folder, not just one file. -Project is only consulted
    here to resolve a `project`-scope destination root - it plays no part in the skill's content.

  ONE rendering/install implementation shared by every skill of a given shape (and ONE script
  shared by both shapes) - not several copies to keep in sync. Settings' "Agent integration" card
  (project skills: Claude Code install button, Codex "Copy AGENTS.md snippet", ChatGPT "Copy
  instructions") and its separate "Optional skills" card (generic skills: Install only - a generic
  skill has no per-project rendering, so there's nothing for a Codex/ChatGPT snippet button to copy
  that `cat`-ing the installed SKILL.md wouldn't already give you) both call this same script, so
  none of those surfaces can drift out of sync with each other.

  Usage:
    install-agent-skill.ps1 render  -Project <id> [-Skill <name>] [-Json]
    install-agent-skill.ps1 install -Project <id> -Scope user|project [-Skill <name>] -Json
    (a GENERIC skill with -Scope user doesn't actually need a resolvable -Project at all, but the
    parameter stays mandatory for a uniform call shape across both skill kinds - callers always
    have an active project in context anyway, per native-host\host.ps1's $PathsInfo.)

  Security posture (matches setappmap/storydoc in native-host\host.ps1): the CALLER never supplies
  a path. -Skill and -Scope each pick from a fixed, script-validated allow-list, never an arbitrary
  caller-supplied path:
    user     %USERPROFILE%\.claude\skills\<skill>\...
    project  <project root>\.claude\skills\<skill>\...
  matching the real ~\.claude\skills\<name>\SKILL.md shape Claude Code itself already uses.

  Always exits 0; success is carried in the 'ok' field, matching every other tool here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'render',
  [Parameter(Mandatory)] [string]$Project,
  [ValidateSet('story-tab-groups', 'setup-dev-loop', 'nextjs-project-architecture', 'shadcn-from-mantine')] [string]$Skill = 'story-tab-groups',
  [ValidateSet('user', 'project')] [string]$Scope,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
  [Parameter(ValueFromRemainingArguments = $true)] $Extra
)

$ErrorActionPreference = 'Stop'

# Generic skills are self-contained and project-agnostic - no {{...}} placeholders, no mode
# blocks, often more than one file. Add a skill's name here (and to the -Skill ValidateSet above)
# once it ships as a plain skills\<name>\ folder with no templating needs; everything else (a
# project skill, substituted/mode-stripped from its template) falls through to the existing path.
$GenericSkills = @('nextjs-project-architecture', 'shadcn-from-mantine')
$IsGeneric = $Skill -in $GenericSkills

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root -Project $Project
if ($Paths.NeedsSetup) {
  if ($Json) { [Console]::Out.Write((@{ ok = $false; error = $Paths.Error; needsSetup = $true } | ConvertTo-Json -Compress)) }
  else { Write-Host $Paths.Error -ForegroundColor Red }
  exit 0
}

$AllowedActions = @('render', 'install')

function Out-Result($o) {
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 8 -Compress)) }
  elseif ($o.error) { Write-Host "`n$($o.error)`n" -ForegroundColor Red }
  else { Write-Host $o.summary }
}

if ($Action -notin $AllowedActions) {
  Out-Result @{ ok = $false; error = "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  exit 0
}
if ($Action -eq 'install' -and -not $Scope) {
  Out-Result @{ ok = $false; error = "install needs -Scope user|project" }
  exit 0
}
if ($Extra) {
  Out-Result @{ ok = $false; error = ("unexpected extra argument(s): " + (@($Extra) -join ' ')) }
  exit 0
}

try {
  $skillDir = Join-Path $PSScriptRoot "..\skills\$Skill"
  $templatePath = Join-Path $skillDir 'SKILL.md'
  if (-not (Test-Path -LiteralPath $templatePath)) { throw "skill template missing at $templatePath - should ship with the extension" }

  # [System.IO.File]::ReadAllText, not Get-Content -Raw - see CLAUDE.md's Dev gotchas for why a
  # Get-Content -Raw result can silently turn a later ConvertTo-Json call into an effective hang
  # (it carries PowerShell's extended type-system members even though it looks like a plain
  # string). $content below flows straight into the JSON reply, so this isn't optional here.
  $template = [System.IO.File]::ReadAllText($templatePath)

  if ($IsGeneric) {
    # No placeholders, no mode blocks - the rendered content IS the file, verbatim.
    $content = $template
    $result = [ordered]@{ ok = $true; action = $Action; skill = $Skill; generic = $true; content = $content }
  }
  else {
    # Mode-aware rendering: the template carries BOTH modes' content, delimited by
    # <!-- MODE:tracking -->...<!-- /MODE:tracking --> / <!-- MODE:worktree -->...<!-- /MODE:worktree -->
    # blocks (can appear inline mid-bullet or as whole paragraphs - the regex below doesn't care
    # which). Drop the OTHER mode's blocks entirely (markers + content), then strip THIS mode's own
    # markers so only its content remains, unwrapped. Fixes a real, previously-shipped bug: before
    # this existed, every installed skill unconditionally said "this project tracks stories, it
    # doesn't cut git worktrees" even when rendered for a worktree-mode project.
    $otherMode = if ($Paths.Mode -eq 'tracking') { 'worktree' } else { 'tracking' }
    $dropPattern = "(?s)\s*<!-- MODE:$otherMode -->.*?<!-- /MODE:$otherMode -->"
    $content = [regex]::Replace($template, $dropPattern, '')
    $content = $content -replace "<!-- MODE:$($Paths.Mode) -->\r?\n?", ''
    $content = $content -replace "\r?\n?<!-- /MODE:$($Paths.Mode) -->", ''

    # Plain .Replace(), not regex -replace - same reasoning as -BranchFormat's templating elsewhere
    # in this codebase: a project id or root path containing '$' or '&' must never be misread as a
    # regex backreference.
    $content = $content.Replace('{{PROJECT_ID}}', $Paths.ProjectId).Replace('{{PROJECT_ROOT}}', $Paths.Root).Replace('{{TOOLS_DIR}}', $PSScriptRoot)

    $devCycleJsonPath = Join-Path $Paths.Root '.claude\dev-cycle.json'
    $devCycleDetected = Test-Path -LiteralPath $devCycleJsonPath

    $result = [ordered]@{ ok = $true; action = $Action; skill = $Skill; project = $Paths.ProjectId; content = $content; devCycleDetected = $devCycleDetected }
  }

  if ($Action -eq 'install') {
    $destDir = if ($Scope -eq 'user') { Join-Path $env:USERPROFILE ".claude\skills\$Skill" }
               else { Join-Path $Paths.Root ".claude\skills\$Skill" }

    if ($IsGeneric) {
      # Copy the WHOLE skill folder (SKILL.md + references\ + assets\, whatever it has), not just
      # one file - a generic skill's own content isn't limited to SKILL.md the way a rendered
      # project skill's is. Remove a stale prior copy first so a skill version that dropped a file
      # doesn't leave that file behind forever.
      #
      # Copy-Item -LiteralPath does NOT expand a trailing '*' (that's -Path's job; -LiteralPath
      # takes it as a literal, nonexistent filename) - confirmed live: `-LiteralPath "...\*"`
      # copied nothing, with NO error, even under -ErrorAction Stop (the copy is simply a no-op
      # for a source that doesn't exist, not a failure). So this copies $skillDir ITSELF
      # (preserving its own leaf name, which already equals $Skill) into $destDir's PARENT,
      # rather than copying $skillDir's contents into an already-created $destDir.
      $destParent = Split-Path -Parent $destDir
      if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
      if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force }
      Copy-Item -LiteralPath $skillDir -Destination $destParent -Recurse -Force
    }
    else {
      if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      $destPath = Join-Path $destDir 'SKILL.md'
      [System.IO.File]::WriteAllText($destPath, $content, [System.Text.UTF8Encoding]::new($false))
    }

    $result['installed'] = $true
    $result['scope'] = $Scope
    $result['path'] = Join-Path $destDir 'SKILL.md'
    $result['summary'] = "installed $Skill to $destDir"
  }
  else {
    $result['summary'] = "rendered $($content.Length) chars ($Skill)"
  }

  Out-Result $result
}
catch {
  Out-Result @{ ok = $false; error = "install-agent-skill error: $($_.Exception.Message)" }
}
