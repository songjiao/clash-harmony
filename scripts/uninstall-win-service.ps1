param(
  [string]$ServiceName = "ClashHarmony",
  [string]$InstallDir = "C:\Program Files\ClashHarmony"
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $argList = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`"",
    "-ServiceName", "`"$ServiceName`"",
    "-InstallDir", "`"$InstallDir`""
  )
  Write-Host "Requesting Administrator privileges (UAC) to uninstall Windows Service '$ServiceName'..."
  Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait
  exit 0
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  if ($svc.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  & sc.exe delete $ServiceName | Out-Null
  Write-Host "Deleted Windows Service '$ServiceName'."
} else {
  Write-Host "Windows Service '$ServiceName' is not installed."
}

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $runKey) {
  Remove-ItemProperty -Path $runKey -Name "ClashHarmonyTray" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $runKey -Name "ClashHarmony" -ErrorAction SilentlyContinue
}
Get-Process | Where-Object { $_.ProcessName -like 'clash-harmony*' } | Stop-Process -Force -ErrorAction SilentlyContinue

if (Test-Path $InstallDir) {
  Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
  Write-Host "Removed $InstallDir."
}
Write-Host "WINDOWS_SERVICE_UNINSTALLED_OK"
