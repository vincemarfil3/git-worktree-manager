<#
  setup.ps1 - one-command bootstrap for a fresh machine, and (optionally) migration off an
  existing pre-standalone install.

  FRESH-MACHINE BOOTSTRAP (always runs):
    1. Install + verify the native-messaging host (native-host\install-native-host.ps1, then an
       end-to-end ping - actually running host.ps1 the same way Chrome would, not just checking
       that files exist).
    2. Find or ask for the data root (stories.json's folder) - auto-detects first, prompts once
       if nothing is found, writes %LOCALAPPDATA%\story-tab-groups\stg-config.json.
    3. Publishes STG_ROOT / STG_TOOLS as user-level environment variables, so docs/skills can stop
       hardcoding an absolute path.
    4. Preflight: git / code / every required tools\*.ps1 / StoryLib.psm1 / app-map.json /
       stories.json readability - a pass/fail table naming the fix for each failure. The exact
       same checks the Settings page's "Paths & diagnostics" card re-runs (host action
       'preflight'), so a terminal and the browser never disagree.

  MIGRATION OFF AN EXISTING INSTALL (only what applies; each step confirms individually unless
  -Force):
    5. Migrate an old deployment's native-host\stg-config.json (root/worktreeRoot) into
       %LOCALAPPDATA%, if -OldExtensionDir points at one.
    6. Retire <root>\tools\ -> <root>\tools.old\, <root>\switch-story.ps1 -> .ps1.old,
       <root>\remove-worktree.ps1 -> .ps1.old - closes the two-copies trap for good. If the old
       tools\ has a real app-map.json (with actual per-app entries) it is copied over this
       folder's empty template rather than being left behind un-migrated.
    7. Re-registers the two EOD scheduled tasks at the new tools\ path (they bake an absolute
       -File path into Task Scheduler, so a move without this silently breaks them).
    8. Unregisters the old 'com.vesta.worktree' native-messaging host (HKCU key + manifest) so a
       stale registration can't shadow the new 'com.storytabgroups.worktree' one.
    9. Warns (never removes - Chrome has no API for it) about any OTHER loaded copy of this
       extension, so two service workers don't fight over the same tab groups.

  Usage:
    .\setup.ps1                                   # fresh-machine bootstrap only
    .\setup.ps1 -OldExtensionDir 'C:\...\story-tab-groups'   # + full migration
    .\setup.ps1 -WhatIf                           # show every change, touch nothing
    .\setup.ps1 -Force                            # migration steps proceed without asking
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Root,               # data root override; blank = auto-detect / prompt
  [string]$OldExtensionDir,    # a previous deployment's story-tab-groups folder, for migration
  [switch]$Force,              # skip the per-step confirmation on migration steps 5-9
  [switch]$SkipMigration       # bootstrap only (1-4), never touch an existing install
)

$ErrorActionPreference = 'Stop'
$ExtDir = $PSScriptRoot
$ToolsDir = Join-Path $ExtDir 'tools'
$NativeHostDir = Join-Path $ExtDir 'native-host'

function Section([string]$n) { Write-Host "`n== $n ==" -ForegroundColor Cyan }
function Ok([string]$s)   { Write-Host "  [ok] $s" -ForegroundColor Green }
function Bad([string]$s)  { Write-Host "  [!!] $s" -ForegroundColor Red }
function Info([string]$s) { Write-Host "  $s" -ForegroundColor DarkGray }
function Confirm([string]$prompt) {
  # -WhatIf never prompts - it's a preview, and the ShouldProcess() calls each Confirm-gated
  # action is wrapped in already print "What if: ..." for every step this lets through.
  if ($Force -or $WhatIfPreference) { return $true }
  $ans = Read-Host "$prompt [y/N]"
  return ($ans -match '^(y|yes)$')
}

Import-Module (Join-Path $ToolsDir 'stg-paths.psm1') -Force -DisableNameChecking

# ------------------------------------------------------------------------------------------------
# 1. Native-messaging host
# ------------------------------------------------------------------------------------------------
Section '1. Native-messaging host'
& (Join-Path $NativeHostDir 'install-native-host.ps1') -WhatIf:$WhatIfPreference
# install-native-host.ps1 exits 1 when it can't auto-detect the extension id (e.g. not loaded in
# Chrome yet) - a legitimate, already-reported condition, not a reason for setup.ps1's OWN final
# exit code to reflect a child script that ran minutes ago. Reset it (same pattern used by
# story-release.ps1's Invoke-Ledger for the same reason) so the exit code reflects setup.ps1 itself.
$global:LASTEXITCODE = 0

if (-not $WhatIfPreference) {
  # End-to-end verify: actually run host.ps1 the way Chrome would (a framed stdin message, a
  # framed stdout reply) rather than just checking the manifest/registry key exist - this is what
  # catches "the manifest is fine but host.bat/host.ps1 itself errors out".
  #
  # File-redirected Start-Process, NOT [Diagnostics.Process]::Start + .BaseStream pipes: verified
  # directly that the pipe-based approach unreliably returns zero bytes from host.ps1's reply even
  # though host.ps1 itself is working correctly (Windows PowerShell 5.1's [Console]::OpenStandardInput/
  # Output do not reliably observe .NET Process-class anonymous pipes the way Chrome's own native-
  # messaging launch, and Start-Process's file-based redirection, both do) - so this uses the same
  # file-redirection mechanism host.bat/Chrome effectively goes through instead of the flakier one.
  function Invoke-HostPing {
    $hostPs1 = Join-Path $NativeHostDir 'host.ps1'
    $msg = '{"action":"ping"}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $inFile = [IO.Path]::GetTempFileName()
    $outFile = [IO.Path]::GetTempFileName()
    try {
      $fs = [IO.File]::Open($inFile, 'Create')
      $fs.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
      $fs.Write($bytes, 0, $bytes.Length)
      $fs.Close()
      $proc = Start-Process powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$hostPs1`"" `
        -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -NoNewWindow -PassThru -Wait
      $buf = [IO.File]::ReadAllBytes($outFile)
    } finally {
      Remove-Item -LiteralPath $inFile, $outFile -Force -ErrorAction SilentlyContinue
    }
    if ($buf.Length -lt 4) { return $false }
    $len = [BitConverter]::ToInt32($buf, 0)
    if ($buf.Length -lt 4 + $len) { return $false }
    $reply = [System.Text.Encoding]::UTF8.GetString($buf, 4, $len)
    try { return (($reply | ConvertFrom-Json).pong -eq $true) } catch { return $false }
  }
  try {
    if (Invoke-HostPing) { Ok 'host.ps1 responds to a framed ping (same protocol Chrome uses)' }
    else { Bad 'host.ps1 did not reply as expected - see native-host\README.md' }
  } catch { Bad "could not run host.ps1: $($_.Exception.Message)" }
} else {
  Info 'skipped end-to-end ping under -WhatIf'
}

# ------------------------------------------------------------------------------------------------
# 2. Data root
# ------------------------------------------------------------------------------------------------
Section '2. Data root (stories.json)'
$paths = Resolve-StgPaths -Root $Root
if ($paths.NeedsSetup) {
  Info $paths.Error
  if (-not $WhatIfPreference) {
    $typed = Read-Host 'Enter the folder that contains (or should contain) stories.json'
    if ($typed -and (Test-Path -LiteralPath $typed -PathType Container)) {
      $cfg = @{}
      $existing = Get-StgConfig
      foreach ($p in $existing.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
      $cfg['root'] = (Resolve-Path $typed).Path
      Set-StgConfig -Config $cfg
      $paths = Resolve-StgPaths
      Ok "root set to $($paths.Root)"
    } else {
      Bad 'no valid folder given - re-run setup.ps1 once stories.json exists, or set it later in Settings.'
    }
  } else {
    Info 'would prompt for a root (skipped under -WhatIf)'
  }
} elseif ($Root -and $paths.Source -eq 'parameter') {
  # -Root was passed explicitly on this run - persist it to stg-config.json too, not just the
  # user-env-var side channel (step 3), so it's still found even before a browser/shell restart
  # picks up the new environment variable.
  if ($PSCmdlet.ShouldProcess((Get-StgConfigPath), "Save root=$($paths.Root)")) {
    $cfg = @{}
    foreach ($p in (Get-StgConfig).PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    $cfg['root'] = $paths.Root
    Set-StgConfig -Config $cfg
    Ok "root: $($paths.Root)  (given via -Root, saved to $(Get-StgConfigPath))"
  } else {
    Info "would save root=$($paths.Root) to $(Get-StgConfigPath)"
  }
} else {
  Ok "root: $($paths.Root)  (source: $($paths.Source))"
}

# ------------------------------------------------------------------------------------------------
# 3. Environment variables
# ------------------------------------------------------------------------------------------------
Section '3. Environment variables'
if ($PSCmdlet.ShouldProcess('STG_ROOT / STG_TOOLS (user environment)', 'Set')) {
  if ($paths.Root) { [Environment]::SetEnvironmentVariable('STG_ROOT', $paths.Root, 'User') }
  [Environment]::SetEnvironmentVariable('STG_TOOLS', $ToolsDir, 'User')
  Ok "STG_TOOLS = $ToolsDir"
  if ($paths.Root) { Ok "STG_ROOT = $($paths.Root)" } else { Info 'STG_ROOT not set (no root resolved yet)' }
  Info 'New terminals/processes pick these up automatically; already-open ones need a restart.'
} else {
  $extra = if ($paths.Root) { " and STG_ROOT=$($paths.Root)" } else { '' }
  Info "would set STG_TOOLS=$ToolsDir$extra"
}

# ------------------------------------------------------------------------------------------------
# 4. Preflight
# ------------------------------------------------------------------------------------------------
Section '4. Preflight'
$paths = Resolve-StgPaths -Root $Root
if ($paths.NeedsSetup) {
  Bad $paths.Error
} else {
  Ok "stories.json: $(if (Test-Path $paths.StoriesPath) { 'found' } else { 'MISSING' }) - $($paths.StoriesPath)"
  Ok "StoryLib.psm1: $(if (Test-Path (Join-Path $ToolsDir 'StoryLib.psm1')) { 'found' } else { 'MISSING' })"
  if (Test-Path $paths.AppMapPath) { Ok "app-map.json: $($paths.AppMapPath)" } else { Info "app-map.json: not found (optional - story-env.ps1 reports apps 'unmapped' without it)" }
}
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) { Ok "git: $($gitCmd.Source)" } else { Bad 'git not found on PATH - install Git for Windows' }
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd) { Ok "code (VS Code CLI): $($codeCmd.Source)" } else { Info "code (VS Code CLI): not on PATH (optional - 'Open workspace' just won't auto-launch VS Code)" }
foreach ($s in @('switch-story.ps1', 'remove-worktree.ps1', 'story-ledger.ps1', 'story-release.ps1', 'story-doctor.ps1', 'story-env.ps1', 'story-handover.ps1', 'story-testplan.ps1', 'vault-status.ps1', 'story-doc.ps1', 'install-agent-skill.ps1')) {
  $p = Join-Path $ToolsDir $s
  if (Test-Path $p) { Ok $s } else { Bad "$s MISSING from tools\ - re-download/re-clone the extension folder" }
}

if ($SkipMigration) {
  Write-Host "`n-SkipMigration given - bootstrap complete, migration steps skipped.`n" -ForegroundColor Cyan
  return
}

# ------------------------------------------------------------------------------------------------
# 5. Migrate an old deployment's config
# ------------------------------------------------------------------------------------------------
Section '5. Migrate old config'
if (-not $OldExtensionDir) {
  Info 'no -OldExtensionDir given - skipping (pass the previous story-tab-groups folder to migrate its config).'
} else {
  $oldCfgPath = Join-Path $OldExtensionDir 'native-host\stg-config.json'
  if (-not (Test-Path -LiteralPath $oldCfgPath)) {
    Info "no stg-config.json found at $oldCfgPath - nothing to migrate."
  } else {
    try {
      $oldCfg = Get-Content -LiteralPath $oldCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $merged = @{}
      foreach ($p in (Get-StgConfig).PSObject.Properties) { $merged[$p.Name] = $p.Value }
      foreach ($k in @('root', 'worktreeRoot', 'branchFormat')) {
        if ($oldCfg.$k) { $merged[$k] = $oldCfg.$k }
      }
      if (Confirm "Migrate root='$($merged.root)' worktreeRoot='$($merged.worktreeRoot)' from $oldCfgPath into $(Get-StgConfigPath)?") {
        if ($PSCmdlet.ShouldProcess((Get-StgConfigPath), 'Write migrated config')) {
          Set-StgConfig -Config $merged
          Ok "migrated into $(Get-StgConfigPath)"
        }
        if ($PSCmdlet.ShouldProcess($oldCfgPath, 'Rename to .old')) {
          Rename-Item -LiteralPath $oldCfgPath -NewName 'stg-config.json.old' -Force
          Ok "renamed old file to stg-config.json.old"
        }
        $paths = Resolve-StgPaths -Root $Root
      } else { Info 'skipped by user.' }
    } catch { Bad "could not read/migrate $oldCfgPath : $($_.Exception.Message)" }
  }
}

# ------------------------------------------------------------------------------------------------
# 6. Retire old root-level script copies (the two-copies trap)
# ------------------------------------------------------------------------------------------------
Section '6. Retire old script copies at the data root'
if (-not $paths.Root) {
  Info 'no data root resolved - skipping.'
} else {
  $oldToolsDir = Join-Path $paths.Root 'tools'
  if ((Test-Path -LiteralPath $oldToolsDir) -and ((Resolve-Path $oldToolsDir).Path -ne (Resolve-Path $ToolsDir).Path)) {
    if (Confirm "Rename $oldToolsDir -> tools.old (the extension's own tools\ becomes the only copy)?") {
      # A real, populated app-map.json at the old location is worth more than this folder's empty
      # template - carry it forward before the old folder is retired, rather than leaving actual
      # per-app port/start/health data stranded in a renamed-away directory.
      $oldMap = Join-Path $oldToolsDir 'app-map.json'
      $newMap = Join-Path $ToolsDir 'app-map.json'
      if (Test-Path -LiteralPath $oldMap) {
        try {
          $oldMapContent = Get-Content -LiteralPath $oldMap -Raw -Encoding UTF8 | ConvertFrom-Json
          if ($oldMapContent.apps -and @($oldMapContent.apps.PSObject.Properties).Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($newMap, 'Overwrite with the old (populated) app-map.json')) {
              Copy-Item -LiteralPath $oldMap -Destination $newMap -Force
              Ok 'carried forward the populated app-map.json'
            }
          }
        } catch { Info "could not inspect old app-map.json ($($_.Exception.Message)) - not carried forward automatically; copy it by hand if it has real entries." }
      }
      if ($PSCmdlet.ShouldProcess($oldToolsDir, 'Rename to tools.old')) {
        Rename-Item -LiteralPath $oldToolsDir -NewName 'tools.old' -Force
        Ok "renamed $oldToolsDir -> $(Join-Path $paths.Root 'tools.old')"
      }
    } else { Info 'skipped by user.' }
  } else {
    Info "no separate tools\ folder at the data root (or it's already this extension's own) - nothing to do."
  }

  foreach ($s in @('switch-story.ps1', 'remove-worktree.ps1')) {
    $oldScript = Join-Path $paths.Root $s
    if (Test-Path -LiteralPath $oldScript) {
      if (Confirm "Rename $oldScript -> $s.old?") {
        if ($PSCmdlet.ShouldProcess($oldScript, 'Rename to .old')) {
          Rename-Item -LiteralPath $oldScript -NewName "$s.old" -Force
          Ok "renamed $s -> $s.old"
        }
      } else { Info 'skipped by user.' }
    }
  }
}

# ------------------------------------------------------------------------------------------------
# 7. Re-register EOD scheduled tasks at the new path
# ------------------------------------------------------------------------------------------------
Section '7. EOD scheduled tasks'
$installEod = Join-Path $ToolsDir 'install-eod-task.ps1'
# The configured prefix (Get-StgOrgDefaults.TaskNamePrefix), not a hardcoded 'EOD status reminder'
# wildcard - install-eod-task.ps1 itself names the two tasks "<prefix> (early)"/"<prefix> (final)"
# (same default value, 'Ganesha EOD status reminder', so this is a no-op change for anyone who
# hasn't customized it in Settings), and the hardcoded wildcard would never match a task registered
# under a customized prefix, silently skipping the re-register offer for it.
$eodPrefix = (Get-StgOrgDefaults).TaskNamePrefix
$existingTask = Get-ScheduledTask -TaskName "*$eodPrefix*" -ErrorAction SilentlyContinue
if ($existingTask) {
  if (Confirm 'Re-register the EOD scheduled tasks at the new tools\ path?') {
    if ($PSCmdlet.ShouldProcess('EOD scheduled tasks', 'Re-register')) {
      & $installEod -Root $paths.Root
      Ok 're-registered EOD tasks'
    }
  } else { Info 'skipped by user - existing tasks may still point at an old script path.' }
} else {
  Info 'no EOD scheduled tasks found - nothing to migrate. Run .\tools\install-eod-task.ps1 to set them up fresh.'
}

# ------------------------------------------------------------------------------------------------
# 8. Unregister the old native host
# ------------------------------------------------------------------------------------------------
Section '8. Old native-messaging host (com.vesta.worktree)'
$oldHostName = 'com.vesta.worktree'
$foundOld = $false
foreach ($vendor in @('Google\Chrome', 'Microsoft\Edge', 'BraveSoftware\Brave-Browser')) {
  $key = "HKCU:\Software\$vendor\NativeMessagingHosts\$oldHostName"
  if (Test-Path $key) {
    $foundOld = $true
    $manifestPath = (Get-Item -Path $key -ErrorAction SilentlyContinue).GetValue('')
    if (Confirm "Remove stale registry key $key (and its manifest, if present)?") {
      if ($PSCmdlet.ShouldProcess($key, 'Remove registry key')) {
        Remove-Item -Path $key -Force -ErrorAction SilentlyContinue
        Ok "removed $key"
      }
      if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
        if ($PSCmdlet.ShouldProcess($manifestPath, 'Delete stale manifest')) {
          Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
          Ok "deleted stale manifest $manifestPath"
        }
      }
    } else { Info 'skipped by user.' }
  }
}
if (-not $foundOld) { Info 'no old com.vesta.worktree registration found - nothing to do.' }

# ------------------------------------------------------------------------------------------------
# 9. Warn about a second loaded copy of this extension
# ------------------------------------------------------------------------------------------------
Section '9. Other loaded copies of this extension'
$roots = @(
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
  (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data')
)
$others = @()
foreach ($r in $roots) {
  if (-not (Test-Path $r)) { continue }
  $files = @()
  $files += Get-ChildItem -Path $r -Recurse -Depth 1 -Filter 'Secure Preferences' -ErrorAction SilentlyContinue
  $files += Get-ChildItem -Path $r -Recurse -Depth 1 -Filter 'Preferences' -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    try {
      $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $settings = $j.extensions.settings
      if (-not $settings) { continue }
      foreach ($p in $settings.PSObject.Properties) {
        $path = $p.Value.path
        if (-not $path) { continue }
        $manifestPath = Join-Path $path 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        try {
          $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
          if ($m.name -eq 'Worktree manager' -and $path.TrimEnd('\', '/') -ne $ExtDir) {
            $others += [pscustomobject]@{ id = $p.Name; path = $path }
          }
        } catch {}
      }
    } catch {}
  }
}
$others = @($others | Sort-Object path -Unique)
if ($others.Count -gt 0) {
  Bad "found $($others.Count) OTHER loaded copy(ies) of 'Worktree manager' - two service workers will fight over the same tab groups:"
  foreach ($o in $others) { Info "  id $($o.id)  ->  $($o.path)" }
  Info 'Chrome has no API to remove an extension from a script - go to chrome://extensions and remove the other copy by hand.'
} else {
  Ok 'no other loaded copy found.'
}

Write-Host "`nDone.`n" -ForegroundColor Cyan
