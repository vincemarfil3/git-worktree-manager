#requires -Version 5.1
<#
  story-env.ps1 - deterministic bring-up harness for a Vesta story worktree.

  Replaces the prose in the ganesha-run-apps / ganesha-point-apps skills with assertions a
  script can make, so a model never has to re-derive "is the venv populated" from scratch.

  Usage:
    story-env.ps1 [action] [STORY] [-Json] [-NoStopAll] [-TimeoutSec 120] [-TargetEnv mintN]
                  [-Only R4] [-HealEnv]

  action : check  (default) read-only; six assertion groups + table
           heal   check, then fix what is safely fixable, then re-check
           up     stop-all sweep -> heal -> start apps -> poll health -> table
           down   stop-all sweep only
           status R5+R6 only (ports + health), fast

  STORY  : omitted -> inferred from cwd (<root>\<STORY>\<app>, so the PARENT folder is the key)

  -Only  : restrict check/heal to specific assertion groups. R1 always runs (it resolves the
           story node, so everything else depends on it). Accepts group ids or aliases:
             R2|worktree  R3|deps  R4|env  R5|ports  R6|health   (R5 and R6 are one group)
           'story-env.ps1 heal -Only R4 -HealEnv' is the point-apps path: rewrite .env pointing
           without paying for dep counts or port-ownership evidence. Rejected on up/down, which
           exist to start/stop things and need the full picture.

  -HealEnv : REQUIRED for heal/up to rewrite .env at all. Without it, R4 still reports pointing
           drift (findings + 'suggest VAR=value' + envHealDeferred=true) and changes nothing.
           Rewriting a service URL is only HALF of pointing a worktree at an env - the member-app
           backing infra half (DB / Redis / KeyDB / Bartleby hosts, credentials) is not derivable
           from app-map.json and stays hand-guided. A bring-up that silently did the easy half
           reported all-green while the apps ran against the WRONG infra. The ganesha-point-apps
           flow owns both halves and is the only caller that should pass this. No-op on
           check/status/down, which never heal.

  Cost note: the two expensive primitives on Windows are Get-NetTCPConnection (~1s per port)
  and Get-CimInstance Win32_Process (~0.6s per call). Both are now taken ONCE per run and
  cached - GetActiveTcpListeners() for the 'is anything bound' gate, and a single unfiltered
  Win32_Process query indexed by pid for ownership evidence. Mutating paths refresh both.

  Always exits 0. Success/failure is carried in the 'ok' field, matching remove-worktree.ps1.
  -Json writes one compact frame to stdout and nothing else.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Action = 'check',
  [Parameter(Position = 1)] [string]$Story,
  [string]$TargetEnv,
  [string]$Only,
  [switch]$HealEnv,
  [switch]$Json,
  [switch]$NoStopAll,
  [int]$TimeoutSec = 120,
  [string]$Root  # override (native-host\host.ps1 / a Settings-driven root); blank = auto-resolve
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'stg-paths.psm1') -Force -DisableNameChecking
$Paths = Resolve-StgPaths -Root $Root
if ($Paths.NeedsSetup) {
  $o = @{ ok = $false; error = $Paths.Error; needsSetup = $true }
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)) } else { Write-Host $o.error -ForegroundColor Red }
  return
}
$Root         = $Paths.Root
$RegistryPath = $Paths.StoriesPath
$MapPath      = $Paths.AppMapPath
$AllowedActions = @('check', 'heal', 'up', 'down', 'status')

# Shared helpers: story-key shapes, registry read/lock, BOM-safe IO, worktree-aware folder discovery.
Import-Module (Join-Path $PSScriptRoot 'StoryLib.psm1') -Force -DisableNameChecking

# An env-less action can arrive in the Story slot (e.g. "story-env.ps1 check" from a worktree).
if ($Story -in $AllowedActions) { $Action = $Story; $Story = $null }
if ($Action -notin $AllowedActions) {
  $o = @{ ok = $false; error = "Unknown action '$Action'. One of: $($AllowedActions -join ', ')." }
  if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)) } else { Write-Host $o.error -ForegroundColor Red }
  return
}
$Heal = $Action -in @('heal', 'up')

# R4 is the ONLY group whose fix is not self-contained. Rewriting a service URL is half of
# "point the apps at mintN"; the other half (member-app backing infra - DB / Redis / KeyDB /
# Bartleby hosts and credentials) is not derivable from app-map.json, which carries no infra
# field at all. A bring-up that quietly did the easy half reported all-green while the apps ran
# against the WRONG infra. So .env writes now need an explicit opt-in, and the ganesha-point-apps
# flow is the only caller that passes it - it owns both halves.
# No-op unless the action heals: -HealEnv on check/status/down changes nothing.
$HealR4 = $Heal -and $HealEnv

# ---------- -Only group filter ----------
# R1 is absent on purpose: it resolves the story node, so it is not optional.
$GroupAliases = @{
  'r2' = 'R2'; 'worktree' = 'R2'; 'branch' = 'R2'
  'r3' = 'R3'; 'deps' = 'R3'
  'r4' = 'R4'; 'env' = 'R4'; 'pointing' = 'R4'
  'r5' = 'R5'; 'ports' = 'R5'; 'r6' = 'R5'; 'health' = 'R5'   # R5+R6 are one function, one group
}
$Groups = @{ R2 = $true; R3 = $true; R4 = $true; R5 = $true }
if ($Only) {
  if ($Action -in @('up', 'down')) {
    $o = @{ ok = $false; error = "-Only is not valid with '$Action' - it starts/stops apps and needs every group. Use check or heal." }
    if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)) } else { Write-Host $o.error -ForegroundColor Red }
    return
  }
  $want = @(); $bad = @()
  foreach ($tok in ($Only -split '[,;\s]+' | Where-Object { $_ })) {
    $k = $tok.Trim().ToLower()
    if ($GroupAliases.ContainsKey($k)) { $want += $GroupAliases[$k] } else { $bad += $tok }
  }
  if ($bad.Count -gt 0) {
    $o = @{ ok = $false; error = "Unknown -Only group(s): $($bad -join ', '). One of: R2|worktree, R3|deps, R4|env, R5|ports." }
    if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)) } else { Write-Host $o.error -ForegroundColor Red }
    return
  }
  if ($want.Count -eq 0) {
    $o = @{ ok = $false; error = '-Only was given but named no groups.' }
    if ($Json) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)) } else { Write-Host $o.error -ForegroundColor Red }
    return
  }
  $Groups = @{ R2 = $false; R3 = $false; R4 = $false; R5 = $false }
  foreach ($g in ($want | Select-Object -Unique)) { $Groups[$g] = $true }
}
# 'status' has always meant ports+health only - keep that, and let -Only narrow nothing further.
if ($Action -eq 'status') { $Groups = @{ R2 = $false; R3 = $false; R4 = $false; R5 = $true } }

# ---------- io helpers ----------

# PS 5.1's -Encoding utf8 ALWAYS writes a BOM, which is what corrupts stories.json for the
# JS consumers. Write BOM-less explicitly.
function Write-JsonFile([string]$Path, $Obj, [int]$Depth = 12) {
  $json = $Obj | ConvertTo-Json -Depth $Depth
  [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Test-Bom([string]$Path) {
  if (-not (Test-Path $Path)) { return $false }
  $fs = [IO.File]::OpenRead($Path)
  try {
    $b = New-Object byte[] 3
    $n = $fs.Read($b, 0, 3)
    return ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  }
  finally { $fs.Dispose() }
}

function Read-Json([string]$Path) {
  $raw = [IO.File]::ReadAllText($Path) -replace '^\uFEFF', ''
  return $raw | ConvertFrom-Json
}

# git that tolerates stderr progress output (same reason as remove-worktree.ps1's Git-Cap).
function Git-Cap([string]$Dir, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git -C $Dir @GitArgs 2>&1
    return @{ code = $LASTEXITCODE; out = ($out | Out-String).Trim() }
  }
  finally { $ErrorActionPreference = $prev }
}

# ---------- story + map resolution ----------

# Never .ToUpper() blindly: registry keys are case-sensitive to the JS consumers, and the no-ticket
# slug form ('kuber-partner-date') is lowercase - uppercasing it produced a key that matched nothing.
function Resolve-Story([string]$S) {
  $reg = if (Test-Path $RegistryPath) { Read-JsonFile -Path $RegistryPath } else { $null }
  if ($S) {
    if ($reg) { $k = Resolve-RegistryKey -Registry $reg -Key $S; if ($k) { return $k } }
    return $S
  }
  $inferred = Resolve-StoryFromPath -Root $Root -Registry $reg
  if ($inferred) { return $inferred }
  throw "Could not infer the story from cwd '$((Get-Location).Path)'. Pass it explicitly: story-env.ps1 $Action <STORY>"
}

function Get-WtPath([string]$App, [string]$S) { Join-Path (Join-Path $Root $S) $App }

function Get-MintNumber([string]$EnvName) {
  if ($EnvName -match '^mint(?:ATL)?(\d+)$') { return [int]$Matches[1] }
  return $null
}

# $From is the value being REPLACED; its path suffix is carried onto the new host.
# Callers embed the API version themselves - ganesha-service does f"{KUBER_GATEWAY}/v1/auth/get-access"
# - so the base-path segment lives in the env var, and dropping it turns every call into a 404.
# It is NOT uniform across vars: KUBER/HEIMDALL/FORSETI_GATEWAY carry '/api', CLIENT_CONNECT_GATEWAY
# does not (verified on mint2: client-connect answers 401 at the bare host and 404 under /api). So it
# cannot be derived from the app - only preserved from what was already there.
# Hit 2026-08-07: KUBER_GATEWAY http://localhost:8002/api -> bare ingress host, breaking login with
# a 404 on /v1/auth/get-access that looked like a kuber outage.
function Get-IngressUrl($AppDef, [int]$N, [string]$From) {
  if (-not $AppDef -or -not $AppDef.ingressSvc -or -not $AppDef.ingressToken) { return $null }
  $scheme = if ($AppDef.ingressScheme) { $AppDef.ingressScheme } else { 'https' }
  $base = "{0}://mint{1}-{2}-{3}.vesta.io" -f $scheme, $N, $AppDef.ingressToken, $AppDef.ingressSvc
  $path = ''
  if ($From -and $From -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/]+(/.*)$') { $path = $Matches[1].TrimEnd('/') }
  return "$base$path"
}

# ---------- R5 / R6 primitives ----------

# Two caches, both taken once per run. Measured on this machine: Get-NetTCPConnection is ~993ms
# PER PORT and Get-CimInstance Win32_Process -Filter is ~614ms PER CALL, and the old code paid
# 1 of the former + up to 5 of the latter for every app with a bound port - which is why a
# 4-app story with 2 apps running took ~12s. The bulk equivalents are ~32ms and ~538ms ONCE.
# Both must be refreshed after anything that starts or kills a process (see Reset-ProcCaches).
$script:ListenPortCache = $null
$script:ProcIndexCache = $null
$script:SocketIndexCache = $null

function Reset-ProcCaches {
  $script:ListenPortCache = $null
  $script:ProcIndexCache = $null
  $script:SocketIndexCache = $null
}

# Every listening TCP port in one .NET call. No owning pid - that is Get-PortListeners' job.
# Returns $null if the call fails, which callers MUST treat as 'unknown' and fall back, never
# as 'nothing is bound' (a false 'free' would let R4 repoint a live service).
function Get-ListeningPorts {
  if ($null -eq $script:ListenPortCache) {
    $set = @{}
    try {
      $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
      foreach ($ep in $props.GetActiveTcpListeners()) { $set[[int]$ep.Port] = $true }
    }
    catch { return $null }
    $script:ListenPortCache = $set
  }
  return $script:ListenPortCache
}

# The cheap 'is anything bound to this port' gate. Falls back to the slow-but-authoritative
# path when the bulk snapshot is unavailable.
function Test-PortBound([int]$Port) {
  $set = Get-ListeningPorts
  if ($null -eq $set) { return (@(Get-PortListeners $Port).Count -gt 0) }
  return $set.ContainsKey($Port)
}

# One unfiltered Win32_Process query indexed by pid, replacing N filtered ones. CommandLine is
# the reason this stays CIM: Get-Process does not expose it on PS 5.1.
function Get-ProcIndex {
  if ($null -eq $script:ProcIndexCache) {
    $idx = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $idx[[int]$p.ProcessId] = $p }
    $script:ProcIndexCache = $idx
  }
  return $script:ProcIndexCache
}

function Get-ProcById([int]$ProcId) {
  $idx = Get-ProcIndex
  if ($idx.ContainsKey($ProcId)) { return $idx[$ProcId] }
  return $null
}

# Every listening socket WITH its owning pid, in one query, indexed port -> pid[]. Measured at
# ~972ms for all 44 listeners, which is what ONE -LocalPort call already cost. Returns $null on
# failure so callers fall back rather than concluding 'free'.
# This is the pid-bearing companion to Get-ListeningPorts: that one is 30x cheaper but pidless,
# so it stays the gate and this is only reached once a port is known to be bound.
function Get-SocketIndex {
  if ($null -eq $script:SocketIndexCache) {
    $idx = @{}
    try {
      foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
        $lp = [int]$c.LocalPort
        if (-not $idx.ContainsKey($lp)) { $idx[$lp] = @() }
        $idx[$lp] += [int]$c.OwningProcess
      }
    }
    catch { return $null }
    $script:SocketIndexCache = $idx
  }
  return $script:SocketIndexCache
}

function Get-PortListeners([int]$Port) {
  $rows = @()
  $sock = Get-SocketIndex
  if ($null -ne $sock) {
    if (-not $sock.ContainsKey($Port)) { return $rows }
    $pids = @($sock[$Port] | Select-Object -Unique)
  }
  else {
    # Bulk query unavailable - fall back to the authoritative per-port call.
    try { $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { return $rows }
    $pids = @($conns | Select-Object -ExpandProperty OwningProcess -Unique)
  }
  foreach ($procId in $pids) {
    $p = Get-ProcById ([int]$procId)
    $rows += [pscustomobject]@{
      Pid         = $procId
      Name        = if ($p) { $p.Name } else { '(gone)' }
      CommandLine = if ($p) { "$($p.CommandLine)" } else { '' }
      Proc        = $p
      Alive       = [bool]$p
    }
  }
  return $rows
}

# All path-ish text tied to a process: its own exe + command line, plus up to 3 ancestors'
# command lines. A launcher shell often holds the worktree path the child dropped.
function Get-PathEvidence($Listener) {
  $parts = @("$($Listener.CommandLine)")
  $p = if ($Listener.Proc) { $Listener.Proc } else { Get-ProcById ([int]$Listener.Pid) }
  if ($p) {
    $parts += "$($p.ExecutablePath)"
    $ppid = $p.ParentProcessId
    for ($i = 0; $i -lt 3 -and $ppid; $i++) {
      $par = Get-ProcById ([int]$ppid)
      if (-not $par) { break }
      $parts += "$($par.CommandLine)"; $parts += "$($par.ExecutablePath)"
      $ppid = $par.ParentProcessId
    }
  }
  return ($parts -join ' | ')
}

# HTTP probe, not TCP state: Get-NetTCPConnection keeps reporting a dead parent PID as the
# socket owner after a uvicorn --reload parent is killed (ganesha-run-apps skill).
# Retries on purpose: a cold Vite dev server can time out twice at 5s and then answer 200,
# so a single short-timeout probe reports a false 'down'.
function Test-Health([int]$Port, [string]$Path, [int]$Sec = 6, [int]$Tries = 3) {
  $url = "http://localhost:$Port$Path"
  for ($i = 1; $i -le $Tries; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $url -TimeoutSec $Sec -UseBasicParsing -ErrorAction Stop
      return @{ up = $true; code = [int]$r.StatusCode; tries = $i }
    }
    catch {
      $c = $null
      try { if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode } } catch { }
      # A 4xx still proves something is serving the port.
      if ($c) { return @{ up = $true; code = $c; tries = $i } }
    }
  }
  return @{ up = $false; code = 0; tries = $Tries }
}

function Read-EnvFile([string]$Path) {
  $h = [ordered]@{}
  if (-not (Test-Path $Path)) { return $h }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
  }
  return $h
}

# ---------- assertion groups ----------

# R1 registry: parses, arrays are arrays, no BOM.
function Invoke-R1([string]$S) {
  $f = @(); $fixed = @(); $notes = @()
  # A BOM is a NOTE, not a failure. Verified 2026-08-01: every file-reading consumer strips it
  # (rules-lib.js:75, gen-rules.mjs:33, and all the PS readers use -Encoding UTF8), so nothing
  # actually breaks. Something external keeps re-adding it; failing `check` over a cosmetic
  # condition is just a recurring false alarm. `heal` still removes it.
  $bom = Test-Bom $RegistryPath
  if ($bom) { $notes += 'stories.json has a UTF-8 BOM (harmless - all readers strip it; heal removes it)' }

  $reg = Read-Json $RegistryPath
  # Parens matter: without them PS parses this as (-not $names) -contains $S.
  if (-not ($reg.stories.PSObject.Properties.Name -contains $S)) {
    return @{ ok = $false; findings = @((Get-MissingStoryHint -Root $Root -Key $S)); fixed = @(); node = $null }
  }
  $node = $reg.stories.$S
  $arrayFields = @('apps', 'jira_stories', 'sub_environments', 'previous_rels')
  $needsWrite = $bom
  foreach ($fld in $arrayFields) {
    $p = $node.PSObject.Properties[$fld]
    if (-not $p -or $null -eq $p.Value) { continue }
    if ($p.Value -isnot [Array]) {
      $f += "$fld is a bare $($p.Value.GetType().Name), must be an array"
      if ($Heal) { $node.$fld = @($p.Value); $needsWrite = $true; $fixed += "normalized $fld to an array" }
    }
  }
  if ($Heal -and $needsWrite) {
    Write-JsonFile $RegistryPath $reg 12
    if ($bom) { $fixed += 'rewrote stories.json without a BOM'; $notes = @() }
    $reg = Read-Json $RegistryPath; $node = $reg.stories.$S
  }
  return @{ ok = ($f.Count -eq 0 -or ($Heal -and $fixed.Count -ge $f.Count)); findings = $f; fixed = $fixed; notes = $notes; node = $node }
}

# R2 worktree: exists, live worktree, on the node's branch.
function Invoke-R2([string]$App, [string]$Wt, [string]$Branch) {
  $f = @()
  if (-not (Test-Path $Wt)) { return @{ ok = $false; findings = @('worktree folder missing'); branch = '-' } }
  # Same phantom-blocker guard as remove-worktree.ps1's Get-Blockers: a stale folder is not a worktree.
  $t = Git-Cap $Wt @('rev-parse', '--is-inside-work-tree')
  if ($t.code -ne 0 -or $t.out -ne 'true') { return @{ ok = $false; findings = @('folder is not a live git worktree'); branch = '-' } }
  $b = (Git-Cap $Wt @('rev-parse', '--abbrev-ref', 'HEAD')).out
  $note = $null
  if ($b -eq 'HEAD') { $f += 'detached HEAD' }
  elseif ($Branch -and $b -ne $Branch) {
    # '<branch>-restore' is the documented output of ganesha-branches "restore release"
    # (revert-the-revert recovery). The worktree legitimately sits there while the
    # stories.json 'branch' field still records the base - not drift, so note it.
    if ($b -eq "$Branch-restore") { $note = "on the -restore branch (revert-the-revert recovery)" }
    else { $f += "on '$b', expected '$Branch'" }
  }
  return @{ ok = ($f.Count -eq 0); findings = $f; branch = $b; note = $note }
}

# R3 deps: node_modules populated / venv actually has packages (not just python.exe).
function Invoke-R3([string]$App, [string]$Wt, $Def, [string]$Sentinel) {
  $f = @(); $fixed = @(); $detail = ''
  $isNode = Test-Path (Join-Path $Wt 'package.json')
  if ($isNode) {
    $nm = Join-Path $Wt 'node_modules'
    $n = if (Test-Path $nm) { @(Get-ChildItem $nm -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
    $detail = "node_modules=$n"
    if ($n -le 10) {
      $f += "node_modules missing or near-empty ($n)"
      if ($Heal) {
        $pm = if ($Def -and $Def.pm) { $Def.pm } elseif (Test-Path (Join-Path $Wt 'yarn.lock')) { 'yarn' } else { 'npm' }
        Write-Host "  [$App] $pm install (this can take a few minutes)..." -ForegroundColor Cyan
        Push-Location $Wt
        try {
          $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
          if ($pm -eq 'yarn') { & yarn install } else { & npm install }
          $ErrorActionPreference = $prev
        }
        finally { Pop-Location }
        $n2 = if (Test-Path $nm) { @(Get-ChildItem $nm -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
        if ($n2 -gt 10) { $fixed += "$pm install -> $n2 packages" } else { $f += "$pm install did not populate node_modules" }
        $detail = "node_modules=$n2"
      }
    }
    return @{ ok = ($f.Count -eq 0); findings = $f; fixed = $fixed; detail = $detail }
  }

  $req = $null
  if (Test-Path (Join-Path $Wt 'requirements\dev.txt')) { $req = 'requirements\dev.txt' }
  elseif (Test-Path (Join-Path $Wt 'requirements.txt')) { $req = 'requirements.txt' }
  if (-not $req) { return @{ ok = $true; findings = @(); fixed = @(); detail = 'no deps' } }

  $py = Join-Path $Wt '.venv\Scripts\python.exe'
  $sp = Join-Path $Wt '.venv\Lib\site-packages'
  $hasPy = Test-Path $py
  # The empty-venv case: python.exe exists so it LOOKS fine, but nothing is installed.
  # Parsing requirements for a sentinel does not work (heimdall/forseti dev.txt is just
  # '-r base.txt'), so probe site-packages for a package every app here depends on.
  #
  # The shared sentinel assumes a FastAPI service. A python app that is not one (test-automation is
  # a pytest suite) never installs it, so a populated venv would read as empty and heal would pip
  # install then still fail. Such an app declares its own via app-map 'depsSentinel'.
  if ($Def -and $Def.depsSentinel) { $Sentinel = "$($Def.depsSentinel)" }
  $hasSentinel = $hasPy -and (Test-Path (Join-Path $sp $Sentinel))
  $cnt = if (Test-Path $sp) { @(Get-ChildItem $sp -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
  $detail = "venv=$(if($hasPy){'yes'}else{'no'}) pkgs=$cnt"

  if (-not $hasPy) { $f += '.venv missing' }
  elseif (-not $hasSentinel) { $f += ".venv exists but '$Sentinel' is not installed (empty venv)" }

  if ($Heal -and $f.Count -gt 0) {
    Push-Location $Wt
    try {
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      if (-not $hasPy) { Write-Host "  [$App] creating .venv..." -ForegroundColor Cyan; & python -m venv .venv }
      if (Test-Path $py) {
        Write-Host "  [$App] pip install -r $req (this can take a few minutes)..." -ForegroundColor Cyan
        & $py -m pip install --upgrade pip --quiet
        & $py -m pip install -r $req
      }
      $ErrorActionPreference = $prev
    }
    finally { Pop-Location }
    $cnt2 = if (Test-Path $sp) { @(Get-ChildItem $sp -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
    if (Test-Path (Join-Path $sp $Sentinel)) { $f = @(); $fixed += "pip install -r $req -> $cnt2 packages" }
    else { $f += "pip install did not install '$Sentinel'" }
    $detail = "venv=yes pkgs=$cnt2"
  }
  return @{ ok = ($f.Count -eq 0); findings = $f; fixed = $fixed; detail = $detail }
}

# R4 env: a cross-service URL var pointing at a dead localhost for a NON-member app is the
# classic post-repoint breakage. Member<->member localhost is correct and left alone.
function Invoke-R4([string]$App, [string]$Wt, $Def, [string[]]$Members, [int]$MintN, $Map) {
  $f = @(); $fixed = @(); $flagged = @()
  $envPath = Join-Path $Wt '.env'
  # Order matters: establish that the app consumes cross-service URLs at all BEFORE judging it on
  # .env. An unmapped app, or a mapped one with no 'consumes' (e.g. test-automation, a pytest suite
  # configured by --env/config/<env>_config.json), owns no .env and must not be reported missing one.
  if (-not $Def) { return @{ ok = $true; findings = @(); fixed = @(); flagged = @(); note = 'unmapped' } }
  if (-not $Def.consumes -or -not $Def.consumes.PSObject.Properties.Name) {
    return @{ ok = $true; findings = @(); fixed = @(); flagged = @(); note = 'no consumes' }
  }
  if (-not (Test-Path $envPath)) { return @{ ok = $false; findings = @('.env missing'); fixed = @(); flagged = @() } }

  $vars = Read-EnvFile $envPath
  $ignore = @(); if ($Def._ignoreVars) { $ignore = @($Def._ignoreVars) }
  $rewrites = @()

  foreach ($p in $Def.consumes.PSObject.Properties) {
    $varName = $p.Name; $target = $p.Value
    if ($varName -in $ignore) { continue }
    if (-not $vars.Contains($varName)) { continue }
    $val = "$($vars[$varName])"
    if (-not $val) { continue }
    if ($val -notmatch 'localhost|127\.0\.0\.1') { continue }   # already remote - fine

    # HARD RULE - member<->member wiring stays LOCAL. Anything in the story's own apps list is
    # wired locally on purpose and is never repointed at an ingress. Everything below this
    # block only ever sees NON-member targets.
    #
    # The HOST stays localhost, but the PORT still has to be right, and app-map owns it. A member
    # var on the wrong local port is the single most common reason a locally-wired story starts
    # green yet every call is ERR_CONNECTION_REFUSED - the old short-circuit skipped this check
    # entirely, so it was invisible. Several apps' conventional port differs from their framework
    # default (ganesha-service 8003 vs uvicorn 8000, client-connect 8004, forseti 8001), which is
    # exactly where a stale .env lands. Only the port is ever rewritten.
    if ($target -in $Members) {
      $want = $null
      if ($Map.apps.PSObject.Properties.Name -contains $target) { $want = $Map.apps.$target.port }
      if (-not $want) { continue }                                  # port unknown - nothing to assert
      $have = if ($val -match ':(\d{2,5})') { [int]$Matches[1] } else { $null }
      if ($have -eq [int]$want) { continue }                        # already correct
      $to = $val -replace '((?:localhost|127\.0\.0\.1))(:\d{2,5})?', "`$1:$want"
      $flagged += [pscustomobject]@{ var = $varName; target = $target; value = $val; suggest = $to }
      $f += "$varName -> member '$target' on port $(if ($have) { $have } else { 'none' }), expected $want"
      if ($HealR4) { $rewrites += @{ var = $varName; from = $val; to = $to } }
      continue
    }

    # Non-member pointed at localhost. Only a finding if nothing is bound to that port.
    # Deliberately a LISTENER check, not an HTTP probe: this decision can rewrite .env, and a
    # slow-but-alive service must never be repointed just because it failed to answer in time.
    # Test-PortBound is the bulk-snapshot gate; on snapshot failure it falls back to the
    # authoritative per-port query rather than reporting a false 'free'.
    $tPort = $null
    if ($Map.apps.PSObject.Properties.Name -contains $target) { $tPort = $Map.apps.$target.port }
    if (-not $tPort -and $val -match ':(\d{2,5})') { $tPort = [int]$Matches[1] }
    if ($tPort -and (Test-PortBound ([int]$tPort))) { continue }

    $suggest = if ($MintN) { Get-IngressUrl $Map.apps.$target $MintN $val } else { $null }
    $flagged += [pscustomobject]@{ var = $varName; target = $target; value = $val; suggest = $suggest }
    $f += "$varName -> non-member '$target' at dead $val"
    # $HealR4, not $Heal: only an explicit -HealEnv may write .env. See the note beside $HealR4.
    if ($HealR4 -and $suggest) { $rewrites += @{ var = $varName; from = $val; to = $suggest } }
  }

  if ($rewrites.Count -gt 0) {
    # Timestamped, story-qualified backup before the first write: the old flow rewrote .env in place
    # with no copy anywhere, unlike switch-story's .env-backups\ convention.
    try {
      $bakDir = Join-Path $Root '.env-backups'
      if (-not (Test-Path $bakDir)) { [void](New-Item -ItemType Directory -Path $bakDir -Force) }
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
      $storyTag = Split-Path (Split-Path $Wt -Parent) -Leaf   # <root>\<STORY>\<app> -> STORY
      Copy-Item -LiteralPath $envPath -Destination (Join-Path $bakDir "$App.$storyTag.$stamp.env") -Force
    } catch { $f += "could not back up .env before healing: $($_.Exception.Message)" }

    $lines = [IO.File]::ReadAllLines($envPath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
      foreach ($rw in $rewrites) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($rw.var))\s*=") { $lines[$i] = "$($rw.var)=$($rw.to)" }
      }
    }
    # .env only - never committed, always-dirty local pointing, and remove-worktree.ps1's
    # Get-Blockers explicitly exempts it, so healing it cannot create a removal blocker.
    [IO.File]::WriteAllLines($envPath, $lines, (New-Object System.Text.UTF8Encoding $false))
    foreach ($rw in $rewrites) { $fixed += "$($rw.var): $($rw.from) -> $($rw.to)" }
    # Clear ONLY the findings we actually rewrote. The old blanket '$f = @()' also erased drift that
    # produced no rewrite - e.g. a non-member var whose suggestion was null because the env is stg,
    # or the app has ingressToken null (bartleby / data-collector) - so the caller was told
    # 'ok, nothing deferred' while a dead localhost URL was still in .env.
    $healedVars = @($rewrites | ForEach-Object { $_.var })
    $f = @($f | Where-Object { $line = $_; -not (@($healedVars | Where-Object { $line -like "$_ *" }).Count) })
  }
  # envHealDeferred distinguishes 'drift found and left alone' from 'drift fixed', so a caller can
  # route to the owning flow instead of assuming heal dealt with it.
  return @{
    ok = ($f.Count -eq 0); findings = $f; fixed = $fixed; flagged = $flagged
    envHealDeferred = ($f.Count -gt 0 -and -not $HealR4)
  }
}

# R5 ports + R6 health, combined: is anything on the port, and is it OUR worktree's code?
function Invoke-R56([string]$App, [string]$Wt, $Def, [string]$S) {
  # Two distinct reasons there is no port to inspect, and the table must not blur them: the app is
  # absent from app-map (actionable - add it), or it is mapped with port null on purpose because
  # nothing listens (tokenizer/dvorak have no local convention; test-automation is a test suite).
  if (-not $Def) {
    return @{ ok = $true; findings = @(); port = $null; listener = 'unmapped'; health = 'unmapped'; hijack = $false }
  }
  if (-not $Def.port) {
    return @{ ok = $true; findings = @(); port = $null; listener = 'no port'; health = 'n/a'; hijack = $false }
  }
  $port = [int]$Def.port
  # Gate the ~1s per-port query behind the ~0ms cached snapshot: on the common 'nothing running'
  # path there is no listener to describe, so neither the socket query nor the pid lookups are
  # worth paying for.
  # The @() MUST wrap the whole if-expression, not the inner branch: PS 5.1 unrolls a
  # single-element array out of a statement-expression, leaving $ls a bare object whose .Count
  # is $null - which reads as 'free' and silently defeats the FOREIGN-port check.
  $ls = @(if (Test-PortBound $port) { Get-PortListeners $port } else { @() })
  $hp = if ($Def.health) { $Def.health } else { '/' }
  # Only probe HTTP when something is actually bound. With no listener the probe cannot
  # succeed, and 3 retries x 6s per app is pure dead time on the common 'nothing running' path.
  $h = if ($ls.Count -gt 0) { Test-Health $port $hp } else { @{ up = $false; code = 0; tries = 0 } }
  $f = @(); $hijack = $false; $who = 'free'

  if ($ls.Count -gt 0) {
    $marker = "\$S\$App\".ToLower()
    $owner = $ls | Select-Object -First 1
    # Ownership evidence, best first: the process's own paths, then a shallow parent walk
    # (a 'powershell -Command "Set-Location <wt>; ..."' launcher carries the path even when
    # the child's own command line does not).
    $ev = Get-PathEvidence $owner
    if ($ev.ToLower().Contains($marker)) { $who = "mine (pid $($owner.Pid))" }
    elseif ($ev -match '\\([A-Za-z0-9]+-\d+)\\([a-z0-9\-\.]+)\\') {
      # Definitive: a DIFFERENT story/app path - you would silently be viewing its code.
      $who = "FOREIGN [$($Matches[1])/$($Matches[2])] pid $($owner.Pid)"
      $hijack = $true
      $f += "port $port held by $($Matches[1])/$($Matches[2]) - you would be viewing its code"
    }
    else {
      # Serving, but no path evidence at all (launched relatively, e.g.
      # 'cd <wt>; python -m uvicorn ...' with a global interpreter). Not provably foreign,
      # so do not claim it is - say so and give the pid.
      $who = "unverified pid $($owner.Pid)"
      $f += "port $port is served by pid $($owner.Pid) but its path does not identify a worktree - cannot confirm it is this story's code"
      if ($owner.CommandLine -match 'uvicorn' -and $ev -notmatch '\\\.venv\\') {
        $f += "pid $($owner.Pid) is running from a global interpreter, not the worktree .venv - it is not using this worktree's pinned deps"
      }
    }
  }
  if ($h.up -and $who -eq 'free') { $who = 'serving (no pid match)' }
  # Three states, not two. A bound-but-not-yet-answering port is WARMING, not down:
  # ganesha-ui-app-v2's dev script is 'vite --port=3001 --debug', and debug logging pushes
  # cold-start transforms past 50s per module (observed 54835ms on /src/hooks/useProfile.ts)
  # while Vite already accepts the connection. Calling that 'down' is a false failure.
  $healthCell = if ($h.up) { "up $($h.code)" }
  elseif ($ls.Count -gt 0) { 'warming' }
  else { 'down' }
  return @{
    ok = ($f.Count -eq 0); findings = $f; port = $port; listener = $who
    health = $healthCell; hijack = $hijack
  }
}

# ---------- process control ----------

# Cross-worktree by necessity: every worktree's .env uses the same fixed ports, so a sibling
# story is often holding yours. Kills uvicorn --multiprocessing-fork children too, which
# inherit the listening socket and keep serving after the parent dies.
function Invoke-StopAll([int[]]$Ports) {
  $killed = @()
  $targets = @{}
  $script:StopSkipped = @()

  # Snapshot once, up front: this is the authoritative view we decide kills from.
  Reset-ProcCaches
  foreach ($port in $Ports) {
    if (-not (Test-PortBound $port)) { continue }
    foreach ($l in (Get-PortListeners $port)) { if ($l.Alive) { $targets[$l.Pid] = "port $port ($($l.Name))" } }
  }
  # The second sweep is the dangerous one: it matches on command line alone, so before scoping it
  # killed ANY dev server on the machine - an unrelated project's uvicorn, and (via the bare 'vite'
  # substring) any vitest watcher. A process only qualifies here when its OWN command line or exe
  # path sits under $Root; anything else is recorded as skipped so the omission is visible.
  #
  # Deliberately NOT Get-PathEvidence: that walks up to 3 ancestors, and ancestry is far too loose
  # for a kill decision - any process launched from a shell that merely mentions the workspace path
  # inherits "ownership" and gets killed (verified: a decoy node in %TEMP% was killed through its
  # parent's command line). Own-process evidence is enough, because the things we start really do
  # carry the worktree path themselves: '<wt>\.venv\Scripts\python.exe -m uvicorn ...' for backends
  # and '<wt>\node_modules\...' for the node apps.
  # Port-owning listeners above are exempt from this test on purpose: whoever holds a port we are
  # about to bind has to go regardless of where it lives.
  $rootLc = $Root.TrimEnd('\').ToLower()
  $procs = @((Get-ProcIndex).Values | Where-Object { $_.Name -eq 'node.exe' -or $_.Name -eq 'python.exe' })
  foreach ($p in $procs) {
    $cl = "$($p.CommandLine)"
    if ($cl -notmatch 'uvicorn|next dev|next-server|start-server|\bvite\b') { continue }
    if ($targets.ContainsKey($p.ProcessId)) { continue }
    $own = ($cl + ' | ' + "$($p.ExecutablePath)").ToLower()
    if ($own.Contains($rootLc)) {
      $targets[$p.ProcessId] = "dev server ($($p.Name))"
    }
    else {
      $script:StopSkipped += "pid $($p.ProcessId) - $($p.Name) dev server outside $Root (left running)"
    }
  }

  foreach ($procId in @($targets.Keys)) {
    if ($procId -eq $PID) { continue }   # never kill the shell running this script
    try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed += "pid $procId - $($targets[$procId])" }
    catch { }
  }

  # Orphaned uvicorn workers. A '--multiprocessing-fork' child INHERITS the listening socket,
  # so it keeps serving after its parent dies while Get-NetTCPConnection still reports the
  # dead parent as the socket owner - the port looks stuck. The reliable signal is
  # '--multiprocessing-fork' plus a DEAD parent (a live parent means a legitimately running
  # app). Their own command line contains neither 'uvicorn' nor any path, so it cannot be
  # matched on those. Looped, because killing a parent creates fresh orphans.
  for ($pass = 0; $pass -lt 3; $pass++) {
    $found = $false
    # Re-snapshot every pass: the previous pass killed processes, and orphan detection depends
    # on seeing the CURRENT parent-alive state, not the one we started with.
    Reset-ProcCaches
    foreach ($p in @((Get-ProcIndex).Values | Where-Object { $_.Name -eq 'python.exe' })) {
      if ("$($p.CommandLine)" -notmatch '--multiprocessing-fork') { continue }
      # Deliberately a LIVE check, not the snapshot: 'is the parent dead right now' is the
      # whole signal, and a stale index would resurrect it.
      if (Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue) { continue }  # parent alive
      try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        $killed += "pid $($p.ProcessId) - orphaned worker of dead parent $($p.ParentProcessId)"
        $found = $true
      }
      catch { }
    }
    if (-not $found) { break }
    Start-Sleep -Milliseconds 400
  }
  return $killed
}

function Start-App([string]$App, [string]$Wt, $Def) {
  if (-not $Def -or -not $Def.start) { return @{ started = $false; reason = 'no start command mapped' } }
  $cwd = $Wt
  if ($Def.workdir) { $cwd = Join-Path $Wt $Def.workdir }
  if (-not (Test-Path $cwd)) { return @{ started = $false; reason = "workdir '$($Def.workdir)' missing" } }

  $cmd = $Def.start
  if ($Def.kind -eq 'python') {
    $py = Join-Path $Wt '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { return @{ started = $false; reason = '.venv missing' } }
    # Run uvicorn through the worktree's own interpreter so it cannot pick up a global one.
    $cmd = $cmd -replace '^uvicorn\s+', ''
    $inner = "& '$py' -m uvicorn $cmd"
  }
  else { $inner = "& $cmd" }

  $logDir = Join-Path $Root 'temp\story-env-logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
  $log = Join-Path $logDir "$App.log"
  # Roll instead of truncate: Tee-Object -FilePath overwrites, so a retry destroyed the crash log
  # the previous failure message pointed at. Keep one previous generation, and cap growth.
  try {
    if (Test-Path -LiteralPath $log) {
      $prev = "$log.1"
      if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Force -ErrorAction SilentlyContinue }
      Move-Item -LiteralPath $log -Destination $prev -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  $wrapped = "Set-Location '$cwd'; $inner *>&1 | Tee-Object -FilePath '$log'"
  try {
    $p = Start-Process -FilePath 'powershell.exe' `
      -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $wrapped `
      -WorkingDirectory $cwd -WindowStyle Minimized -PassThru
    return @{ started = $true; pid = $p.Id; log = $log }
  }
  catch { return @{ started = $false; reason = "launch failed: $($_.Exception.Message)" } }
}

# ---------- main ----------

$result = [ordered]@{ ok = $true; action = $Action; story = $null; env = $null; apps = @(); registry = $null; stopped = @(); summary = '' }

try {
  if (-not (Test-Path $RegistryPath)) { throw "stories.json not found at $RegistryPath" }
  if (-not (Test-Path $MapPath)) { throw "app-map.json not found at $MapPath" }
  $Map = Read-Json $MapPath
  $sentinel = if ($Map.pythonSentinel) { $Map.pythonSentinel } else { 'fastapi' }

  $S = Resolve-Story $Story
  $result.story = $S

  # --- R1 (registry) gates everything else: we need a trustworthy node first. ---
  $r1 = Invoke-R1 $S
  $result.registry = @{ ok = $r1.ok; findings = $r1.findings; fixed = $r1.fixed; notes = $r1.notes }
  if (-not $r1.node) { throw (Get-MissingStoryHint -Root $Root -Key $S) }
  $node = $r1.node
  if (-not $r1.ok) { $result.ok = $false }

  $envName = if ($TargetEnv) { $TargetEnv } else { "$($node.env)" }
  $result.env = $envName
  $mintN = Get-MintNumber $envName
  $members = @($node.apps) | ForEach-Object { "$_" }
  $branch = "$($node.branch)"

  # Shared discovery (StoryLib): the registry app list unioned with the folders that really are git
  # worktrees, so orphans are still reported but a hand-made dir like EH7-8934\logs\ is an 'extra'
  # rather than a phantom app that fails every assertion group.
  $discovery = Get-StoryFolders -Root $Root -Story $S -Node $node
  $storyDir  = $discovery.storyDir
  $appList   = @($discovery.apps.Keys | Sort-Object)
  $result.extras = @($discovery.extras)
  if ($appList.Count -eq 0) { throw "story '$S' has no apps in stories.json and no worktrees under $storyDir" }

  # --- down / up: the stop-all sweep ---
  if ($Action -in @('down', 'up') -and -not $NoStopAll) {
    $ports = @()
    foreach ($a in $appList) { if ($Map.apps.PSObject.Properties.Name -contains $a -and $Map.apps.$a.port) { $ports += [int]$Map.apps.$a.port } }
    # Sweep the whole documented port set, not just ours - a sibling story on a shared port
    # is exactly the failure we are preventing.
    foreach ($p in $Map.apps.PSObject.Properties) { if ($p.Value.port) { $ports += [int]$p.Value.port } }
    if (-not $Json) { Write-Host "`nStopping dev servers (all worktrees)..." -ForegroundColor Cyan }
    $result.stopped = @(Invoke-StopAll ($ports | Select-Object -Unique))
    $result.stopSkipped = @($script:StopSkipped)
    if (-not $Json) {
      if ($result.stopped.Count -eq 0) { Write-Host "  nothing was running" -ForegroundColor DarkGray }
      else { foreach ($k in $result.stopped) { Write-Host "  killed $k" -ForegroundColor DarkGray } }
      foreach ($k in $result.stopSkipped) { Write-Host "  skipped $k" -ForegroundColor DarkGray }
    }
    # We just killed things - every cached listener/process fact is now a lie.
    Reset-ProcCaches
    if ($Action -eq 'down') {
      $result.summary = "stopped $($result.stopped.Count) process(es)"
      if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)) }
      else { Write-Host "`n$($result.summary)`n" -ForegroundColor Green }
      return
    }
  }

  # --- per-app assertion groups ---
  $rows = @()
  foreach ($app in $appList) {
    $wt = Get-WtPath $app $S
    $def = if ($Map.apps.PSObject.Properties.Name -contains $app) { $Map.apps.$app } else { $null }
    $row = [ordered]@{
      app = $app; mapped = [bool]$def; inRegistry = ($app -in $members)
      worktree = $null; deps = $null; env = $null; ports = $null; findings = @(); fixed = @()
    }

    if ($Groups.R2) {
      $r2 = Invoke-R2 $app $wt $branch
      $row.worktree = $r2
      $row.findings += $r2.findings
    }
    # Was 'if ($r2.ok -or (Test-Path $wt))'. With R2 skippable, $r2 may not exist, and the real
    # precondition for R3/R4 was always just 'the folder is there to look at'.
    if (Test-Path $wt) {
      if ($Groups.R3) {
        $r3 = Invoke-R3 $app $wt $def $sentinel
        $row.deps = $r3; $row.findings += $r3.findings; $row.fixed += $r3.fixed
      }
      if ($Groups.R4) {
        $r4 = Invoke-R4 $app $wt $def $members $mintN $Map
        $row.env = $r4; $row.findings += $r4.findings; $row.fixed += $r4.fixed
      }
    }
    if ($Groups.R5) {
      $row.ports = Invoke-R56 $app $wt $def $S
      $row.findings += $row.ports.findings
    }
    else {
      # Stub so the table and the JSON shape stay stable when ports are not inspected.
      $row.ports = @{ ok = $true; findings = @(); port = $null; listener = '-'; health = '-'; hijack = $false; skipped = $true }
    }
    $rows += [pscustomobject]$row
  }

  # --- up: start, then poll health ---
  if ($Action -eq 'up') {
    if (-not $Json) { Write-Host "`nStarting this worktree's apps..." -ForegroundColor Cyan }
    $launched = @()
    foreach ($row in $rows) {
      $def = if ($Map.apps.PSObject.Properties.Name -contains $row.app) { $Map.apps.($row.app) } else { $null }
      if (-not $def -or -not $def.port) {
        if (-not $Json) { Write-Host "  [$($row.app)] skipped - no port/start mapped" -ForegroundColor DarkGray }
        continue
      }
      if ($row.deps -and -not $row.deps.ok) {
        if (-not $Json) { Write-Host "  [$($row.app)] skipped - deps not satisfied" -ForegroundColor Yellow }
        continue
      }
      # NOT $s: PowerShell variable names are case-INSENSITIVE, so $s would clobber $S (the
      # story key) and every downstream path/marker built from it.
      $launch = Start-App $row.app (Get-WtPath $row.app $S) $def
      if ($launch.started) {
        $launched += @{ app = $row.app; port = [int]$def.port; health = $(if ($def.health) { $def.health } else { '/' }); pid = $launch.pid; log = $launch.log }
        if (-not $Json) { Write-Host "  [$($row.app)] launched pid $($launch.pid) -> :$($def.port)" -ForegroundColor DarkGray }
      }
      elseif (-not $Json) { Write-Host "  [$($row.app)] not started - $($launch.reason)" -ForegroundColor Yellow }
    }

    if ($launched.Count -gt 0) {
      if (-not $Json) { Write-Host "  polling health (up to ${TimeoutSec}s)..." -ForegroundColor DarkGray }
      $deadline = (Get-Date).AddSeconds($TimeoutSec)
      $pending = @($launched)
      while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $pending = @($pending | Where-Object { -not (Test-Health $_.port $_.health 3).up })
      }
    }
    # Re-run R5/R6 so the final table reflects reality after starting. The snapshots were taken
    # before the apps existed, so they MUST be dropped first or every app reads as 'free'.
    Reset-ProcCaches
    foreach ($row in $rows) {
      $def = if ($Map.apps.PSObject.Properties.Name -contains $row.app) { $Map.apps.($row.app) } else { $null }
      $row.ports = Invoke-R56 $row.app (Get-WtPath $row.app $S) $def $S
      $row.findings = @($row.findings | Where-Object { $_ -notmatch '^port \d+ held' }) + $row.ports.findings
      # 'up' promises apps that are actually serving, so a still-dead port IS a failure here.
      # Under 'check' a down port is expected (nothing is meant to be running) and is not.
      if ($row.app -in @($launched | ForEach-Object { $_.app })) {
        $logHint = ($launched | Where-Object { $_.app -eq $row.app } | Select-Object -First 1).log
        if ($row.ports.health -eq 'down') {
          $row.findings += "nothing bound to :$($row.ports.port) after ${TimeoutSec}s - it failed to start; log: $logHint"
        }
        elseif ($row.ports.health -eq 'warming' -and -not $Json) {
          Write-Host "  [$($row.app)] bound to :$($row.ports.port) but still compiling after ${TimeoutSec}s - give it a moment, then: story-env.ps1 status $S" -ForegroundColor DarkCyan
        }
      }
    }
  }

  foreach ($row in $rows) { if ($row.findings.Count -gt 0) { $result.ok = $false } }
  $result.apps = $rows

  $bad = @($rows | Where-Object { $_.findings.Count -gt 0 })
  # Count only UNRESOLVED registry findings - after a successful heal they are all fixed.
  $regBad = if ($result.registry.ok) { 0 } else { $result.registry.findings.Count }
  if ($result.ok) {
    $result.summary = "$S [$envName]: all checks passed ($($rows.Count) app(s))"
  }
  else {
    $parts = @()
    if ($regBad -gt 0) { $parts += "$regBad registry issue(s)" }
    if ($bad.Count -gt 0) { $parts += "$($bad.Count) of $($rows.Count) app(s) need attention" }
    $result.summary = "$S [$envName]: " + ($parts -join '; ')
  }

  # --- record the bring-up phase on the ledger, since 'up' IS that phase ---
  # The most-forgotten manual step: a command that brought the apps up healthily but never stamped
  # the ledger is why EH7-9170's phase state froze after bring-up. Best-effort - a ledger failure
  # must never turn a healthy bring-up into a failed one.
  if ($Action -eq 'up') {
    try {
      $ledScript = Join-Path $PSScriptRoot 'story-ledger.ps1'
      if (Test-Path -LiteralPath $ledScript) {
        $upRows = @($rows | Where-Object { $_.ports -and $_.ports.health -like 'up*' })
        $arts = @($upRows | ForEach-Object { "$($_.app) :$($_.ports.port) $($_.ports.health)" }) -join '; '
        if ($result.ok -and $upRows.Count -gt 0) {
          [void](& $ledScript done 'bring-up' -Story $S -Artifacts $arts -Root $Root -Json)
          $result.ledger = "bring-up -> done"
        }
        else {
          [void](& $ledScript fail 'bring-up' -Story $S -Message $result.summary -Root $Root -Json)
          $result.ledger = "bring-up -> failed"
        }
      }
    }
    catch { $result.ledger = "not recorded: $($_.Exception.Message)" }
  }

  # ---------- output ----------
  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)); return }

  Write-Host ""
  Write-Host "$S [$envName]  branch $branch" -ForegroundColor Cyan
  Write-Host ("members: " + ($members -join ', ')) -ForegroundColor DarkGray
  if ($Only) {
    $ran = @('R2', 'R3', 'R4', 'R5') | Where-Object { $Groups[$_] }
    Write-Host ("groups:  R1 + " + ($ran -join ', ') + "   (-Only $Only - other groups NOT checked)") -ForegroundColor DarkGray
  }
  # After a successful heal the findings are history - show the fixes, not the complaints.
  if ($result.registry.findings.Count -gt 0 -and -not $result.registry.ok) {
    foreach ($x in $result.registry.findings) { Write-Host "  registry: $x" -ForegroundColor Yellow }
  }
  foreach ($x in $result.registry.notes) { Write-Host "  registry: note - $x" -ForegroundColor DarkGray }
  foreach ($x in $result.registry.fixed) { Write-Host "  registry: FIXED $x" -ForegroundColor Green }
  Write-Host ""

  $fmt = "{0,-26} {1,-9} {2,-20} {3,-6} {4,-22} {5}"
  Write-Host ($fmt -f 'app', 'worktree', 'deps', 'port', 'listener', 'health') -ForegroundColor White
  Write-Host ($fmt -f ('-' * 26), ('-' * 9), ('-' * 20), ('-' * 6), ('-' * 22), ('-' * 8)) -ForegroundColor DarkGray
  foreach ($r in $rows) {
    # A skipped group prints '-', it does not print FAIL. Only an actually-run R2 can fail.
    $wtCell = if (-not $r.worktree) { '-' }
    elseif ($r.worktree.ok) { if ($r.worktree.note) { 'ok*' } else { 'ok' } }
    else { 'FAIL' }
    $dpCell = if ($r.deps) { $r.deps.detail } else { '-' }
    $poCell = if ($r.ports.port) { "$($r.ports.port)" } else { '-' }
    $color = if ($r.findings.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ($fmt -f $r.app, $wtCell, $dpCell, $poCell, $r.ports.listener, $r.ports.health) -ForegroundColor $color
    if (-not $r.mapped) { Write-Host "    (unmapped app - add it to tools\app-map.json for env + health checks)" -ForegroundColor DarkGray }
    if ($r.worktree -and $r.worktree.note) { Write-Host "    * $($r.worktree.note)" -ForegroundColor DarkCyan }
    foreach ($x in $r.fixed) { Write-Host "    FIXED $x" -ForegroundColor Green }
    foreach ($x in $r.findings) { Write-Host "    - $x" -ForegroundColor Yellow }
    # Only suggest what was NOT already applied - after a heal the FIXED line says it all.
    if ($r.env -and $r.env.flagged -and $r.env.findings.Count -gt 0) {
      foreach ($fl in $r.env.flagged) {
        if ($fl.suggest) { Write-Host "      suggest $($fl.var)=$($fl.suggest)" -ForegroundColor DarkCyan }
      }
      # Stay slash-command-agnostic: say what was NOT done and who owns it, not which command to type.
      if ($r.env.envHealDeferred) {
        Write-Host "      (reported only - .env was NOT rewritten; env pointing is owned by the point-apps flow, which also covers backing infra)" -ForegroundColor DarkGray
      }
    }
  }

  Write-Host ""
  if ($result.ok) { Write-Host $result.summary -ForegroundColor Green }
  else {
    Write-Host $result.summary -ForegroundColor Yellow
    if (-not $Heal) { Write-Host "run: story-env.ps1 heal $S   (fixes deps / registry shape; .env pointing needs -HealEnv)" -ForegroundColor DarkCyan }
  }
  Write-Host ""
}
catch {
  $result.ok = $false
  $result.error = "story-env error: $($_.Exception.Message)"
  if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress)) }
  else { Write-Host "`n$($result.error)`n" -ForegroundColor Red }
}
