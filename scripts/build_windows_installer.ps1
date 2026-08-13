# Windows installer build: flutter build windows -> NSIS compile scripts\daymark.nsi
# Output: daymark-windows-x64-setup.exe (repo root)
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1
# NOTE: keep this file ASCII-only (PowerShell 5.1 GBK parsing issue with UTF-8).
# Env (auto-update injection, issue #5, from prepare-version dotenv in CI):
#   APP_VERSION   product version X.Y.Z (--build-name, same as release tag)
#   DART_DEFINES  dart-define args string
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

# 1. Build Flutter Windows release (with optional version/update-source injection)
$buildArgs = ""
if ($env:APP_VERSION) { $buildArgs += " --build-name $env:APP_VERSION" }
if ($env:DART_DEFINES) { $buildArgs += " $env:DART_DEFINES" }
Write-Host "==> flutter build windows --release$buildArgs"
Invoke-Expression "flutter build windows --release$buildArgs"
$release = Join-Path $PWD "build\windows\x64\runner\Release"
if (!(Test-Path $release)) { Write-Error "$release not found (flutter build failed?)" }

# 2. Version: APP_VERSION env -> pubspec.yaml version: line (1.0.0+1 -> 1.0.0)
$version = $env:APP_VERSION
if (!$version) {
  $version = "1.0.0"
  $pubspec = Get-Content (Join-Path $PWD "pubspec.yaml") -Raw
  if ($pubspec -match '^version:\s*([\d.]+)') { $version = $Matches[1] }
}
Write-Host "==> version: $version"

# 3. Locate makensis: PATH -> choco -> download NSIS 3.10 zip (sourceforge)
function Find-Nsis {
  $cmd = Get-Command makensis.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    Write-Host "==> installing NSIS via choco"
    choco install nsis -y --no-progress | Out-Null
    $cmd = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }

  $nsisDir = Join-Path $env:TEMP "nsis-3.10"
  # zip 根目录也是 nsis-3.10/，Expand-Archive 会产生嵌套目录，
  # 故用递归查找定位 makensis.exe（CI #613 实测固定路径失败）
  $makensisExe = Get-ChildItem -Path $nsisDir -Filter makensis.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $makensisExe) {
    Write-Host "==> downloading NSIS 3.10 (sourceforge)"
    $zip = Join-Path $env:TEMP "nsis-3.10.zip"
    curl.exe -L --fail --retry 5 --retry-delay 3 -o $zip `
      "https://downloads.sourceforge.net/project/nsis/NSIS%203/3.10/nsis-3.10.zip"
    if (!(Test-Path $zip)) { Write-Error "NSIS download failed" }
    Expand-Archive $zip $nsisDir -Force
    $makensisExe = Get-ChildItem -Path $nsisDir -Filter makensis.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if (-not $makensisExe) { Write-Error "makensis.exe not found after extraction" }
  return $makensisExe.FullName
}
$makensis = Find-Nsis
Write-Host "==> makensis: $makensis"

# 4. Compile installer (NSIS script File /r resolves relative to repo root)
Write-Host "==> cwd=$PWD"
Write-Host "==> Release files: $((Get-ChildItem $release | Select-Object -First 5 Name) -join ', ')"
$outfile = Join-Path $PWD "daymark-windows-x64-setup.exe"
& $makensis /V3 /DVERSION=$version "/DRELEASE_DIR=$release" "/DOUTFILE=$outfile" (Join-Path $PWD "scripts\daymark.nsi")
if ($LASTEXITCODE -ne 0) { Write-Error "makensis failed (exit $LASTEXITCODE)" }

$out = Join-Path $PWD "daymark-windows-x64-setup.exe"
if (!(Test-Path $out)) { Write-Error "$out not generated" }
Write-Host "==> done: $out"
