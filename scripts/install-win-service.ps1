param(
  [string]$SourceExe = "",
  [string]$DataDir = "$env:APPDATA\ClashHarmony",
  [string]$DesktopDir = "",
  [string]$InstallDir = "C:\Program Files\ClashHarmony",
  [string]$ServiceName = "ClashHarmony",
  [string]$UIAddr = "127.0.0.1:9091"
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
  $DesktopDir = [Environment]::GetFolderPath('Desktop')
}

# Auto-elevate via standard Windows UAC prompt if not running as Administrator
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $repoRoot = Split-Path -Parent $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($SourceExe)) {
    $candidates = @(
      "$repoRoot\desktop\dist\clash-harmony-v2.4.4.exe",
      "$repoRoot\desktop\dist\clash-harmony-v2.4.3.exe",
      "$repoRoot\desktop\dist\clash-harmony.exe"
    )
    foreach ($c in $candidates) {
      if (Test-Path $c) { $SourceExe = $c; break }
    }
  }
  $argList = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`"",
    "-SourceExe", "`"$SourceExe`"",
    "-DataDir", "`"$DataDir`"",
    "-DesktopDir", "`"$DesktopDir`"",
    "-InstallDir", "`"$InstallDir`"",
    "-ServiceName", "`"$ServiceName`"",
    "-UIAddr", "`"$UIAddr`""
  )
  Write-Host "Requesting Administrator privileges (UAC) to install Windows Service '$ServiceName'..."
  Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait
  exit 0
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceExe)) {
  $candidates = @(
    "$repoRoot\desktop\dist\clash-harmony-v2.4.4.exe",
    "$repoRoot\desktop\dist\clash-harmony-v2.4.3.exe",
    "$repoRoot\desktop\dist\clash-harmony.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { $SourceExe = $c; break }
  }
}
if (-not (Test-Path $SourceExe)) {
  throw "Executable not found: $SourceExe. Please build desktop/dist/clash-harmony-v2.4.4.exe first."
}

Write-Host "[1/6] Stopping any existing ClashHarmony service or desktop process..."
$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
  if ($existingSvc.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  & sc.exe delete $ServiceName | Out-Null
  Start-Sleep -Seconds 1
}

Get-Process | Where-Object { $_.ProcessName -like 'clash-harmony*' } | ForEach-Object {
  Write-Host "  Stopping running process $($_.ProcessName) (PID $($_.Id))..."
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 1200

# Clear legacy HKCU Run autostart entry so Windows logon doesn't launch a duplicate tray process
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
  Remove-ItemProperty -Path $runKey -Name "ClashHarmony" -ErrorAction SilentlyContinue
}

Write-Host "[2/6] Copying executable and geoip.metadb to $InstallDir..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$targetExe = Join-Path $InstallDir "clash-harmony.exe"
Copy-Item -Path $SourceExe -Destination $targetExe -Force

$geoipCandidates = @(
  "$repoRoot\app\entry\src\main\resources\rawfile\geoip.metadb",
  "$repoRoot\desktop\dist\geoip.metadb",
  "$DataDir\runtime\geoip.metadb"
)
foreach ($g in $geoipCandidates) {
  if (Test-Path $g) {
    if ((Get-Item $g).Length -gt 2000000) {
      Copy-Item -Path $g -Destination (Join-Path $InstallDir "geoip.metadb") -Force
      break
    }
  }
}

Write-Host "[3/6] Registering Windows Service '$ServiceName' (Auto-Start on boot)..."
$binPath = "`"$targetExe`" -data `"$DataDir`" -ui `"$UIAddr`" -headless -no-browser -enable-tun"
New-Service `
  -Name $ServiceName `
  -BinaryPathName $binPath `
  -DisplayName "Clash Harmony (Mihomo + Tailscale)" `
  -Description "Unified Mihomo + Tailscale VPN routing service (Web Console: http://$UIAddr)" `
  -StartupType Automatic | Out-Null
# Configure automatic restart on unexpected failure
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Write-Host "[4/6] Starting Windows Service '$ServiceName'..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3

Write-Host "[5/6] Creating Web Console shortcut on Desktop and registering Tray Companion..."
if (-not [string]::IsNullOrWhiteSpace($DesktopDir) -and (Test-Path $DesktopDir)) {
  $shortcutPath = Join-Path $DesktopDir "Clash Harmony 控制台.url"
  Set-Content -Path $shortcutPath -Value "[InternetShortcut]`r`nURL=http://$UIAddr`r`n" -Encoding ASCII
  Write-Host "  Desktop shortcut created: $shortcutPath"
}
# Register lightweight Session-1 tray icon companion on logon (no UAC needed)
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
  Set-ItemProperty -Path $runKey -Name "ClashHarmonyTray" -Value "`"$targetExe`" -tray-only -ui `"$UIAddr`""
}

Write-Host "[6/6] Verifying service status and Web Console..."
$svcObj = Get-Service -Name $ServiceName
Write-Host "Service Status: $($svcObj.Name) -> $($svcObj.Status) (StartType: $($svcObj.StartType))"
try {
  $resp = curl.exe -s --noproxy "*" "http://$UIAddr/api/state"
  Write-Host "API /api/state: $resp"
} catch {
  Write-Warning "Web console did not respond yet; check $DataDir\runtime\mihomo-core.log"
}
Write-Host "WINDOWS_SERVICE_INSTALLED_OK"
