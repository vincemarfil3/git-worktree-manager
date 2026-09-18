#requires -Version 5.1
<#
  set-slack-dm.ps1 - configure the Slack self-DM used by the EOD reminder.

  Run this yourself, interactively. The bot token is read with -AsSecureString and stored via
  Export-CliXml, which encrypts it with DPAPI scoped to THIS Windows account on THIS machine: no
  other user can read the file, and it never appears in a transcript, a repo or a chat window.

  %USERPROFILE%\.ganesha\ is outside every repo, so it can never become a remove-worktree.ps1
  blocker.

  Prerequisites (do these in Slack first):
    1. api.slack.com/apps -> Create New App -> From scratch, in the Vesta workspace.
       This is the step that may need workspace-admin approval.
    2. OAuth & Permissions -> Bot Token Scopes: chat:write AND im:write -> Install to Workspace.
    3. Copy the Bot User OAuth Token (starts with xoxb-).
    4. Your Slack member ID: profile -> More -> Copy member ID (starts with U).

  Usage:
    set-slack-dm.ps1                    # prompts for both
    set-slack-dm.ps1 -MemberId U123ABC  # prompts for the token only
    set-slack-dm.ps1 -Show              # report what is configured (never prints the token)
    set-slack-dm.ps1 -Clear             # delete both files
#>
[CmdletBinding()]
param(
  [string]$MemberId,
  [switch]$Show,
  [switch]$Clear
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
# Falls back to the legacy ~\.ganesha if that's what already exists, so an existing Slack
# token/config is never orphaned by the rename to ~\.story-tab-groups.
$CfgDir     = Get-StgOwnerConfigDir
$TokenPath  = Join-Path $CfgDir 'slack-token.xml'
$CfgPath    = Join-Path $CfgDir 'slack.json'
$StatusPath = Join-Path $PSScriptRoot 'story-status.ps1'

if ($Show) {
  Write-Host ""
  Write-Host "config dir : $CfgDir"
  Write-Host "token      : $(if (Test-Path $TokenPath) { 'present (DPAPI-encrypted)' } else { 'MISSING' })"
  if (Test-Path $CfgPath) {
    $c = Get-Content $CfgPath -Raw | ConvertFrom-Json
    Write-Host "member id  : $($c.member_id)"
  }
  else { Write-Host "member id  : MISSING" }
  Write-Host ""
  Write-Host "Both must be present or story-status.ps1 notify falls back to notes\eod-draft.md + a toast."
  Write-Host ""
  return
}

if ($Clear) {
  foreach ($p in @($TokenPath, $CfgPath)) {
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "removed $p" }
  }
  Write-Host "slack DM disabled - notify now falls back to the local draft + toast." -ForegroundColor Yellow
  return
}

if (-not (Test-Path -LiteralPath $CfgDir)) { New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null }

if (-not $MemberId) {
  $MemberId = (Read-Host "Slack member ID (profile -> More -> Copy member ID, starts with U)").Trim()
}
if ($MemberId -notmatch '^[UW][A-Z0-9]{6,}$') {
  throw "'$MemberId' does not look like a Slack member ID (expected something like U01AB2CD3EF)."
}

$sec = Read-Host "Slack bot token (xoxb-...)" -AsSecureString
if (-not $sec -or $sec.Length -eq 0) { throw "no token entered" }

# Sanity-check the prefix without ever echoing the value.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ($plain -notlike 'xoxb-*') {
  Write-Host "warning: that does not start with 'xoxb-'. A user token (xoxp-) will not DM as a bot." -ForegroundColor Yellow
}
$plain = $null

$sec | Export-CliXml -Path $TokenPath
@{ member_id = $MemberId } | ConvertTo-Json | Set-Content -Path $CfgPath -Encoding ascii

Write-Host ""
Write-Host "saved:" -ForegroundColor Green
Write-Host "  $TokenPath  (DPAPI-encrypted, this Windows account only)"
Write-Host "  $CfgPath"
Write-Host ""
Write-Host "now prove it works before it matters at 04:30:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$StatusPath`" slack-test"
Write-Host ""
