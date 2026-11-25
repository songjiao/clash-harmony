param(
  [switch]$Console
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DesktopDir = Join-Path $RepoRoot "desktop"
$DistDir = Join-Path $DesktopDir "dist"

$GoExe = $null
if (Get-Command go -ErrorAction SilentlyContinue) {
  $GoExe = (Get-Command go).Source
} elseif (Test-Path "$env:USERPROFILE\.ohos-go-build\bootstrap\go\bin\go.exe") {
  $GoExe = "$env:USERPROFILE\.ohos-go-build\bootstrap\go\bin\go.exe"
  $env:GOROOT = "$env:USERPROFILE\.ohos-go-build\bootstrap\go"
} else {
  throw "Go toolchain not found. Install Go 1.24+ or run scripts/setup-ohos-go.sh first."
}

if (-not $env:GOMODCACHE -and (Test-Path "$env:USERPROFILE\.ohos-go-build\gomodcache")) {
  $env:GOMODCACHE = "$env:USERPROFILE\.ohos-go-build\gomodcache"
}
if (-not $env:GOCACHE -and (Test-Path "$env:USERPROFILE\.ohos-go-build\gocache-host")) {
  $env:GOCACHE = "$env:USERPROFILE\.ohos-go-build\gocache-host"
}
$env:GOTOOLCHAIN = "local"
$env:CGO_ENABLED = "0"
$env:GOOS = "windows"
$env:GOARCH = "amd64"

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$OutExe = Join-Path $DistDir "clash-harmony.exe"
$LdFlags = "-s -w -H=windowsgui"
if ($Console) {
  $OutExe = Join-Path $DistDir "clash-harmony-console.exe"
  $LdFlags = "-s -w"
}

Write-Host "[build-desktop-win] Go: $GoExe"
Write-Host "[build-desktop-win] Running unit tests..."
Push-Location $DesktopDir
try {
  & $GoExe test -tags with_gvisor -p 4 -count=1 -v .
  if ($LASTEXITCODE -ne 0) { throw "go test failed" }

  Write-Host "[build-desktop-win] Building $OutExe ..."
  & $GoExe build -tags with_gvisor -p 4 -trimpath -ldflags $LdFlags -o $OutExe .
  if ($LASTEXITCODE -ne 0) { throw "go build failed" }
} finally {
  Pop-Location
}

$GeoSrc = Join-Path $RepoRoot "app\entry\src\main\resources\rawfile\geoip.metadb"
$GeoDst = Join-Path $DistDir "geoip.metadb"
if (Test-Path $GeoSrc) {
  Copy-Item -Force $GeoSrc $GeoDst
}

$Item = Get-Item $OutExe
Write-Host ("[build-desktop-win] SUCCESS: {0} ({1:N1} MB)" -f $Item.FullName, ($Item.Length / 1MB))
