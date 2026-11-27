param(
  [string]$AndroidSdkRoot = "C:\Users\34480\.android-sdk-minimal",
  [string]$JavaHome = "D:\DevEco Studio\jbr",
  [string]$BuildToolsVersion = "35.0.0",
  [string]$PlatformVersion = "android-34",
  [switch]$SkipGoBuild,
  [switch]$Install
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$androidDir = "$repoRoot\android"
$buildDir = "$androidDir\build"
$distDir = "$androidDir\dist"
$btDir = "$AndroidSdkRoot\build-tools\$BuildToolsVersion"
$androidJar = "$AndroidSdkRoot\platforms\$PlatformVersion\android.jar"
$adbExe = "$AndroidSdkRoot\platform-tools\adb.exe"
$env:JAVA_HOME = $JavaHome
$javac = "$JavaHome\bin\javac.exe"
$keytool = "$JavaHome\bin\keytool.exe"

if (-not (Test-Path "$btDir\aapt2.exe")) { throw "aapt2 not found in $btDir" }
if (-not (Test-Path $androidJar)) { throw "android.jar not found at $androidJar" }

if (-not $SkipGoBuild) {
  Write-Host "[1/6] Cross-compiling Go Android arm64 core (libclashcore.so)..."
  $env:GOROOT = "C:\Users\34480\.ohos-go-build\bootstrap\go"
  $env:GOMODCACHE = "C:\Users\34480\.ohos-go-build\gomodcache"
  $env:GOCACHE = "C:\Users\34480\.ohos-go-build\gocache-android"
  $env:GOTOOLCHAIN = "local"
  $env:GOOS = "android"
  $env:GOARCH = "arm64"
  $env:CGO_ENABLED = "0"
  New-Item -ItemType Directory -Force -Path "$androidDir\libs\arm64-v8a" | Out-Null
  Push-Location "$repoRoot\desktop"
  & "$env:GOROOT\bin\go.exe" build -p 4 -tags with_gvisor -ldflags "-s -w" -o "$androidDir\libs\arm64-v8a\libclashcore.so" .
  Pop-Location
  if ($LASTEXITCODE -ne 0) { throw "Go android build failed" }
}

if (-not (Test-Path "$androidDir\libs\arm64-v8a\libclashcore.so")) {
  throw "Missing $androidDir\libs\arm64-v8a\libclashcore.so"
}

Write-Host "[2/6] Preparing resources & assets..."
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
New-Item -ItemType Directory -Force -Path "$buildDir\gen", "$buildDir\classes", "$buildDir\dex", "$buildDir\res_compiled", "$distDir" | Out-Null
New-Item -ItemType Directory -Force -Path "$androidDir\res\mipmap-xxxhdpi", "$androidDir\assets" | Out-Null

$iconSrc = "$repoRoot\app\build\outputs\default\agc-icon-216x216.png"
if (-not (Test-Path $iconSrc)) { $iconSrc = "$repoRoot\app\AppScope\resources\base\media\app_icon.png" }
Copy-Item -Force $iconSrc "$androidDir\res\mipmap-xxxhdpi\ic_launcher.png"

$geoSrc = "$repoRoot\app\entry\src\main\resources\rawfile\geoip.metadb"
if (Test-Path $geoSrc) {
  Copy-Item -Force $geoSrc "$androidDir\assets\geoip.metadb"
}

Write-Host "[3/6] Compiling resources & linking base APK with aapt2..."
& "$btDir\aapt2.exe" compile --dir "$androidDir\res" -o "$buildDir\res_compiled\res.zip"
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

& "$btDir\aapt2.exe" link `
  -I $androidJar `
  --manifest "$androidDir\AndroidManifest.xml" `
  -A "$androidDir\assets" `
  -R "$buildDir\res_compiled\res.zip" `
  --java "$buildDir\gen" `
  -o "$buildDir\base-unaligned.apk"
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

Write-Host "[4/6] Compiling Java sources & converting to DEX with d8..."
$zxingJar = "$androidDir\third_party\zxing-core-3.5.3.jar"
$javaFiles = @(Get-ChildItem "$androidDir\src" -Recurse -Filter "*.java" | ForEach-Object { $_.FullName }) +
             @(Get-ChildItem "$buildDir\gen" -Recurse -Filter "*.java" | ForEach-Object { $_.FullName })
& $javac --release 8 -encoding UTF-8 -cp "$androidJar;$zxingJar" -d "$buildDir\classes" @javaFiles
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

$classFiles = Get-ChildItem "$buildDir\classes" -Recurse -Filter "*.class" | ForEach-Object { $_.FullName }
& "$btDir\d8.bat" --release --min-api 26 --lib $androidJar --output "$buildDir\dex" @classFiles $zxingJar
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

Write-Host "[5/6] Packaging classes.dex & lib/arm64-v8a/libclashcore.so into APK..."
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$buildDir\base-unaligned.apk", [System.IO.Compression.ZipArchiveMode]::Update)
try {
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$buildDir\dex\classes.dex", "classes.dex", [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$androidDir\libs\arm64-v8a\libclashcore.so", "lib/arm64-v8a/libclashcore.so", [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally {
  $zip.Dispose()
}

& "$btDir\zipalign.exe" -f -p 4 "$buildDir\base-unaligned.apk" "$buildDir\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

Write-Host "[6/6] Signing APK with debug keystore..."
$ksPath = "$AndroidSdkRoot\clash-harmony-debug.jks"
if (-not (Test-Path $ksPath)) {
  & $keytool -genkeypair -v -keystore $ksPath -storepass android -keypass android -alias clashharmony -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=ClashHarmony,O=SJFarm,C=CN" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
}

$outApk = "$distDir\clash-harmony-android-v2.4.5.apk"
& "$btDir\apksigner.bat" sign --ks $ksPath --ks-pass pass:android --ks-key-alias clashharmony --key-pass pass:android --out $outApk "$buildDir\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

& "$btDir\apksigner.bat" verify --verbose $outApk | Select-String -Pattern "Verifies|Verified"
Get-Item $outApk | Format-Table Name, Length, LastWriteTime -AutoSize | Out-String

if ($Install) {
  Write-Host "Installing APK onto connected Android device..."
  & $adbExe -s 2KE0219A18060649 install -r $outApk
  if ($LASTEXITCODE -eq 0) {
    & $adbExe -s 2KE0219A18060649 shell am start -n com.sjfarmltd.clashharmony/.MainActivity
  }
}
