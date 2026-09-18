<#
  install-native-host.ps1 - register the com.storytabgroups.worktree native-messaging host so the
  Worktree manager extension can run the tools\ scripts on this machine.

  Writes com.storytabgroups.worktree.json (next to this script - generated, never checked in) and
  the per-browser registry key
  HKCU\Software\<vendor>\NativeMessagingHosts\com.storytabgroups.worktree -> that manifest.

  The manifest's allowed_origins must list the extension's id. We auto-detect the unpacked
  Worktree manager extension's id from Chrome/Edge/Brave profiles by matching each profile's
  recorded extension PATH against this script's own resolved parent folder (NOT a literal folder
  name) - so renaming the extension's folder can never break auto-detect. Pass
  -ExtensionId <id> to override (chrome://extensions, Developer mode, copy the ID).

    .\install-native-host.ps1
    .\install-native-host.ps1 -ExtensionId abcdefghijklmnopabcdefghijklmnop
    .\install-native-host.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([string[]]$ExtensionId)

$ErrorActionPreference = 'Stop'
$HostName     = 'com.storytabgroups.worktree'
$HostDir      = $PSScriptRoot
$ExtensionDir = (Resolve-Path (Split-Path $HostDir -Parent)).Path   # ...\story-tab-groups (this extension's own folder)
$HostBat      = Join-Path $HostDir 'host.bat'
$ManifestPath = Join-Path $HostDir "$HostName.json"

# host.bat is referenced by the manifest we're about to write; verifying it exists FIRST is what
# stops this installer from ever registering a host Chrome can start talking to but that can't
# actually run (a real failure mode this project hit once: the manifest pointed at a host.bat that
# had never been created, and Chrome's only symptom was "native host not found").
if (-not (Test-Path -LiteralPath $HostBat)) {
  Write-Host "`nhost.bat not found at $HostBat - the manifest would point at a host that can't start." -ForegroundColor Red
  Write-Host "This file should ship with native-host\ - re-download/re-clone the extension folder.`n" -ForegroundColor Red
  exit 1
}

# Scan a browser's User Data root for this extension's unpacked id, matched by PATH (this script's
# own resolved parent), not by folder-name substring - so renaming the extension folder, or a
# different employer/project name, never breaks detection.
function Find-Ids([string]$userDataRoot) {
  $ids = @()
  if (-not (Test-Path $userDataRoot)) { return $ids }
  $files = @()
  $files += Get-ChildItem -Path $userDataRoot -Recurse -Depth 1 -Filter 'Secure Preferences' -ErrorAction SilentlyContinue
  $files += Get-ChildItem -Path $userDataRoot -Recurse -Depth 1 -Filter 'Preferences' -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    try {
      $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $settings = $j.extensions.settings
      if (-not $settings) { continue }
      foreach ($p in $settings.PSObject.Properties) {
        $path = $p.Value.path
        if (-not $path) { continue }
        $normalized = $path.TrimEnd('\', '/')
        if ($normalized -ieq $ExtensionDir) { $ids += $p.Name }
      }
    }
    catch {}
  }
  $ids
}

$roots = @(
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
  (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data')
)

$ids = @()
if ($ExtensionId) { $ids = @($ExtensionId) }
else {
  foreach ($r in $roots) { $ids += Find-Ids $r }
  $ids = @($ids | Where-Object { $_ } | Select-Object -Unique)
}

if (-not $ids -or $ids.Count -eq 0) {
  Write-Host "`nCould not auto-detect the Worktree manager extension id." -ForegroundColor Yellow
  Write-Host "Open chrome://extensions (Developer mode ON), copy the ID under 'Worktree manager', then re-run:" -ForegroundColor Yellow
  Write-Host "  .\install-native-host.ps1 -ExtensionId <that-id>`n" -ForegroundColor Cyan
  exit 1
}

$manifestObj = [ordered]@{
  name             = $HostName
  description      = 'Native messaging bridge for Worktree manager'
  path             = $HostBat
  type             = 'stdio'
  allowed_origins  = @($ids | ForEach-Object { "chrome-extension://$_/" })
}
$manifestJson = $manifestObj | ConvertTo-Json -Depth 4

if ($PSCmdlet.ShouldProcess($ManifestPath, 'Write native-messaging host manifest')) {
  [System.IO.File]::WriteAllText($ManifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "`nWrote manifest: $ManifestPath" -ForegroundColor Green
  Write-Host "  allowed_origins: $($ids -join ', ')" -ForegroundColor DarkGray
} else {
  Write-Host "`nWould write manifest: $ManifestPath" -ForegroundColor Yellow
  Write-Host "  allowed_origins: $($ids -join ', ')" -ForegroundColor DarkGray
}

# Register the manifest for each installed browser.
function Set-Key([string]$vendorPath, [string]$label) {
  $key = "HKCU:\Software\$vendorPath\NativeMessagingHosts\$HostName"
  if (-not $PSCmdlet.ShouldProcess($key, "Register native-messaging host for $label")) {
    Write-Host "  would register for $label" -ForegroundColor Yellow
    return
  }
  try {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-Item -Path $key -Value $ManifestPath
    Write-Host "  registered for $label" -ForegroundColor Green
  }
  catch { Write-Host "  $label registration failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host "Registry:" -ForegroundColor Cyan
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'))               { Set-Key 'Google\Chrome' 'Chrome' }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'))              { Set-Key 'Microsoft\Edge' 'Edge' }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data')) { Set-Key 'BraveSoftware\Brave-Browser' 'Brave' }

if (-not $WhatIfPreference) {
  Write-Host "`nDone. Fully restart the browser (all windows) so it picks up the host, then use the trash button in the popup.`n" -ForegroundColor Cyan
}
