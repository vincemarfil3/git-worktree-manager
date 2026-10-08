#requires -Version 5.1
<#
  install-agent-skill.ps1 - renders (and optionally installs) an agent skill for ONE project, with
  {{PROJECT_ID}}/{{PROJECT_ROOT}}/{{TOOLS_DIR}} substituted so every command the skill teaches is
  concrete and runnable, not a template. -Skill picks which template (default: story-tab-groups,
  the ongoing day-to-day one; setup-dev-loop is the separate one-time bootstrap skill - see
  skills\setup-dev-loop\SKILL.md) - ONE rendering/mode-stripping/install implementation shared by
  both, not two copies to keep in sync, the same reasoning this docstring already gave for sharing
  one path across the Claude Code / Codex / ChatGPT consumers below.

  ONE rendering path for every consumer (Settings' Agent integration card calls this for all
  three: the Claude Code install button, the Codex "Copy AGENTS.md snippet" button, and the
  ChatGPT "Copy instructions" button) - so the installed file and both clipboard copies can never
  drift out of sync with each other the way three independently-maintained copies would.

  -Project is MANDATORY here, unlike every other tool in this folder (which falls back to the
  currently-active project when omitted) - a skill silently bound to "whichever project happens
  to be active in the popup right now" would be actively wrong the moment a second project exists
  or the active one changes later. Baking in the wrong id is worse than refusing to guess.

  Usage:
    install-agent-skill.ps1 render  -Project <id> [-Skill story-tab-groups|setup-dev-loop] [-Json]
    install-agent-skill.ps1 install -Project <id> -Scope user|project [-Skill ...] -Json

  Security posture (matches setappmap/storydoc in native-host\host.ps1): the CALLER never supplies
  a path. -Skill and -Scope each pick from a fixed, script-validated allow-list, never an arbitrary
  caller-supplied path:
    user     %USERPROFILE%\.claude\skills\<skill>\SKILL.md
    project  <project root>\.claude\skills\<skill>\SKILL.md
  matching the real ~\.claude\skills\<name>\SKILL.md shape Claude Code itself already uses.

  Always exits 0; success is carried in the 'ok' field, matching every other tool here.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'render',
  [Parameter(Mandatory)] [string]$Project,
  [ValidateSet('story-tab-groups', 'setup-dev-loop')] [string]$Skill = 'story-tab-groups',
  [ValidateSet('user', 'project')] [string]$Scope,
  [switch]$Json,
  [string]$Root,  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
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
  $templatePath = Join-Path $PSScriptRoot "..\skills\$Skill\SKILL.md"
  if (-not (Test-Path -LiteralPath $templatePath)) { throw "skill template missing at $templatePath - should ship with the extension" }

  # [System.IO.File]::ReadAllText, not Get-Content -Raw - see CLAUDE.md's Dev gotchas for why a
  # Get-Content -Raw result can silently turn a later ConvertTo-Json call into an effective hang
  # (it carries PowerShell's extended type-system members even though it looks like a plain
  # string). $content below flows straight into the JSON reply, so this isn't optional here.
  $template = [System.IO.File]::ReadAllText($templatePath)

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

  if ($Action -eq 'install') {
    $destDir = if ($Scope -eq 'user') { Join-Path $env:USERPROFILE ".claude\skills\$Skill" }
               else { Join-Path $Paths.Root ".claude\skills\$Skill" }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $destPath = Join-Path $destDir 'SKILL.md'
    [System.IO.File]::WriteAllText($destPath, $content, [System.Text.UTF8Encoding]::new($false))
    $result['installed'] = $true
    $result['scope'] = $Scope
    $result['path'] = $destPath
    $result['summary'] = "installed $Skill to $destPath"
  }
  else {
    $result['summary'] = "rendered $($content.Length) chars for project $($Paths.ProjectId) ($Skill)"
  }

  Out-Result $result
}
catch {
  Out-Result @{ ok = $false; error = "install-agent-skill error: $($_.Exception.Message)" }
}
