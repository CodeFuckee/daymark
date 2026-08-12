# Windows runner env check/setup (cargokit needs Rust; Flutter missing -> clear error)
# Usage: powershell -ExecutionPolicy Bypass -File scripts\windows_env.ps1
# NOTE: keep this file ASCII-only. PowerShell 5.1 parses UTF-8 w/o BOM as GBK,
# non-ASCII chars can swallow quotes and cause ParserError.
# IMPORTANT: this script runs as a CHILD process (gitlab-runner pwsh parent).
# Process-scoped env changes are lost for later job steps, so PATH must be
# written to the Machine registry (SYSTEM account has rights) for cargokit etc.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

function Add-ToMachinePath([string]$dir) {
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if ($m -and $m -notlike "*$dir*") {
    [Environment]::SetEnvironmentVariable('Path', "$m;$dir", 'Machine')
  }
}

# Locate cargo.exe: rustup may install outside $env:USERPROFILE (SYSTEM account
# quirks, custom CARGO_HOME). Scan common locations.
function Find-CargoBin {
  # NOTE: string interpolation, NOT Join-Path - unset env vars are $null and
  # Join-Path throws on null path (CI #601).
  $candidates = @(
    "$env:CARGO_HOME\bin",
    "$env:USERPROFILE\.cargo\bin",
    "C:\Users\*\.cargo\bin"
  )
  foreach ($p in $candidates) {
    if (-not $p) { continue }
    $c = Get-ChildItem -Path $p -Filter cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.DirectoryName }
  }
  return $null
}

# Fix CARGO_HOME/RUSTUP_HOME to a deterministic location: SYSTEM account's
# %USERPROFILE%\.cargo resolution is unreliable (CI #601/#602: rustup reports
# install success but cargo.exe never shows up in the scanned locations).
$env:CARGO_HOME = "D:\Rust\.cargo"
$env:RUSTUP_HOME = "D:\Rust\.rustup"

if (!(Get-Command cargo -ErrorAction SilentlyContinue)) {
  Write-Host "==> Installing Rust (rustup + stable) -> CARGO_HOME=$env:CARGO_HOME"
  $exe = Join-Path $env:TEMP "rustup-init.exe"
  curl.exe -L --fail --retry 5 --retry-delay 3 -o $exe https://win.rustup.rs
  if (!(Test-Path $exe)) { Write-Error "rustup-init.exe download failed" }
  & $exe -y --profile minimal --default-toolchain stable
}

$cargoBin = Find-CargoBin
Write-Host "USERPROFILE=$env:USERPROFILE CARGO_HOME=$env:CARGO_HOME cargoBin=$cargoBin"
if (-not $cargoBin) {
  Write-Error "cargo.exe not found after rustup install (scanned USERPROFILE/CARGO_HOME/Users). Install Rust manually on this runner."
}
Add-ToMachinePath $cargoBin
$env:PATH = "$cargoBin;$env:PATH"

# crates via rsproxy mirror (same as .gitlab-ci.yml rust-setup)
$cargoConf = Join-Path $env:USERPROFILE ".cargo\config.toml"
if (!(Test-Path $cargoConf)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $cargoConf) | Out-Null
  @'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
'@ | Set-Content $cargoConf
}

cargo --version
rustc --version

# Flutter SDK: auto-install when missing (flutter-io mirror, latest stable);
# reuse ~/flutter when present. Also needs Visual Studio C++ toolchain for
# flutter build windows - checked at build time by flutter itself.
$flutterBin = Join-Path $env:USERPROFILE "flutter\bin"
if (!(Get-Command flutter -ErrorAction SilentlyContinue)) {
  if (Test-Path (Join-Path $flutterBin "flutter.bat")) {
    Add-ToMachinePath $flutterBin
    $env:PATH = "$flutterBin;$env:PATH"
  } else {
    Write-Host "==> Installing Flutter SDK (storage.flutter-io.cn mirror)"
    $rel = Invoke-RestMethod "https://storage.flutter-io.cn/flutter_infra_release/releases/releases_windows.json"
    $ver = ($rel.releases | Where-Object { $_.channel -eq 'stable' } | Select-Object -First 1).version
    $zip = Join-Path $env:TEMP "flutter_windows_${ver}-stable.zip"
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $zip `
      "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_${ver}-stable.zip"
    if (!(Test-Path $zip)) { Write-Error "Flutter SDK download failed" }
    Expand-Archive $zip (Join-Path $env:USERPROFILE "flutter-tmp") -Force
    Move-Item (Join-Path $env:USERPROFILE "flutter-tmp\flutter") (Join-Path $env:USERPROFILE "flutter") -Force
    Remove-Item (Join-Path $env:USERPROFILE "flutter-tmp") -Recurse -Force -ErrorAction SilentlyContinue
    Add-ToMachinePath $flutterBin
    $env:PATH = "$flutterBin;$env:PATH"
  }
}
# Verify via PATH lookup, not fixed path: the runner machine may already have
# Flutter installed in PATH at an arbitrary location (CI #603).
if (!(Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error "Flutter not available. Installed to $flutterBin but not on PATH."
}
flutter --version
