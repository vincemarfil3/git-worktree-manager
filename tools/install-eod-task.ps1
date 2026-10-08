#requires -Version 5.1
<#
  install-eod-task.ps1 - register (or remove) the nightly EOD status reminder.

  TWO scheduled tasks, one per tier, weekdays (task name prefix is stg-config.json's
  taskNamePrefix, default 'Ganesha EOD status reminder' - see -TaskName/-EarlyName/-FinalName):
    '<prefix> (early)'  01:00 local  -Tier early
    '<prefix> (final)'  04:30 local  -Tier final

  Two tasks, not one task with two triggers: Task Scheduler runs EVERY action on EVERY trigger, so
  a combined task fired both tiers at 01:00 (the later action overwriting the earlier draft) and
  both again at 04:30. A time can only select a tier if each tier is its own task.

  Plain PowerShell, NOT Claude Code, so it fires whether or not a session is open. It delivers a
  Slack self-DM when %USERPROFILE%\.ganesha is configured, and otherwise degrades to
  notes\eod-draft.md plus a toast. It never posts to #eng-status-input.

  The three settings that actually matter at these hours:
    - run only when logged on   -> a toast needs an interactive session
    - wake the computer         -> 01:00 and 04:30 are usually asleep hours
    - start when available      -> recovers a fire that was slept through

  story-status.ps1 notify stays quiet when tonight's report has already been marked posted, so the
  04:30 trigger costs nothing if the 01:00 one was acted on.

  Usage:
    install-eod-task.ps1            # register / update
    install-eod-task.ps1 -Uninstall # remove
    install-eod-task.ps1 -WhatIf    # show what it would do
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$Uninstall,
  # $TaskName is the superseded single combined task - kept only so -Uninstall can still clean it up.
  [string]$TaskName,
  [string]$EarlyName,
  [string]$FinalName,
  [string]$EarlyAt = '01:00',
  [string]$FinalAt = '04:30',
  [string]$Root,  # override (blank = auto-resolve); also baked into each task's -Root argument
  [string]$Project  # resolved project id (native-host\host.ps1); blank = active project / legacy resolution
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root -Project $Project
if ($Paths.NeedsSetup) { throw $Paths.Error }
$Root   = $Paths.Root
$Script = Join-Path $PSScriptRoot 'story-status.ps1'

# Task names default to the configured prefix (Get-StgOrgDefaults.TaskNamePrefix, today
# 'Ganesha EOD status reminder') so an existing install's tasks keep matching for -Uninstall /
# re-registration unless the prefix is explicitly changed in Settings.
$prefix = (Get-StgOrgDefaults).TaskNamePrefix
if (-not $TaskName)  { $TaskName  = $prefix }
if (-not $EarlyName) { $EarlyName = "$prefix (early)" }
if (-not $FinalName) { $FinalName = "$prefix (final)" }

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
  Write-Host "The ScheduledTasks module is unavailable. Register it by hand in taskschd.msc:" -ForegroundColor Yellow
  Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" notify -Tier final"
  return
}

if ($Uninstall) {
  $found = $false
  # Includes the superseded combined name, so an old install is cleaned up too.
  foreach ($n in @($EarlyName, $FinalName, $TaskName)) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
      $found = $true
      if ($PSCmdlet.ShouldProcess($n, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false
        Write-Host "removed scheduled task '$n'" -ForegroundColor Green
      }
    }
  }
  if (-not $found) { Write-Host "no EOD reminder tasks registered - nothing to remove" }
  return
}

if (-not (Test-Path -LiteralPath $Script)) { throw "story-status.ps1 not found at $Script" }

$days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')

$settings = New-ScheduledTaskSettingsSet `
  -WakeToRun `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) `
  -MultipleInstances IgnoreNew

# Interactive token: a toast needs a desktop session, and this must never prompt for a password.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

# ONE TASK PER TIER, deliberately. Task Scheduler runs EVERY action on EVERY trigger - triggers and
# actions are not paired - so a single task holding both tiers fired 'early' AND 'final' at 01:00
# (the second overwriting the first) and both again at 04:30. Two tasks is the only way to make a
# time actually select a tier.
function Register-Tier([string]$Name, [string]$Tier, [string]$At, [string]$What) {
  # -Root is baked in explicitly (not left to $env:STG_ROOT at trigger time) so the task keeps
  # working even if the user-level env var is changed or a scheduled task's environment snapshot
  # is stale - the same reasoning as passing -Root through every other child script call here.
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`" notify -Tier $Tier -Root `"$Root`"" `
    -WorkingDirectory $Root
  $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At ([datetime]::Parse($At))
  $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "EOD status reminder ($Tier, $At weekdays): $What Never posts to #eng-status-input."
  if ($PSCmdlet.ShouldProcess($Name, "Register scheduled task ($At weekdays, -Tier $Tier)")) {
    Register-ScheduledTask -TaskName $Name -InputObject $task -Force | Out-Null
    Write-Host "registered '$Name'  ->  $At weekdays, notify -Tier $Tier" -ForegroundColor Green
  }
}

# Supersedes the old single combined task, if it is still registered.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister superseded combined task')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "removed the old combined task '$TaskName' (it ran both tiers on every trigger)" -ForegroundColor Yellow
  }
}

Register-Tier $EarlyName 'early' $EarlyAt 'draft so far, send now and be done or let it ride.'
Register-Tier $FinalName 'final' $FinalAt 'last call before the 05:45 cutoff.'

Write-Host ""
Write-Host "test it now:  powershell -NoProfile -ExecutionPolicy Bypass -File `"$Script`" notify -Tier final"
Write-Host "remove it:    powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"
