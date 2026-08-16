# patch_ohos_pub_cache.ps1 - patch flutter_smooth_markdown / flutter_math_fork in
# the pub cache so they compile with the OHOS Flutter fork (TargetPlatform gains an
# ohos enum member that the packages' exhaustive switches do not cover).
# Idempotent: files already containing TargetPlatform.ohos are skipped.
# Counterpart of scripts/patch_ohos_pub_cache.sh for the Windows CI runner (pwsh).
# NOTE: keep this file ASCII-only (PowerShell 5.1 parses UTF-8 w/o BOM as GBK).
$ErrorActionPreference = "Stop"

function Test-OhosSdk {
  # Only patch when the active Flutter SDK is the OHOS fork (standard stable
  # compiles the unpatched packages and would fail on the added ohos cases).
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $cmd -or -not $cmd.Source) { return $true }  # SDK unknown -> patch anyway
  $flutterExe = $cmd.Source
  $sdkRoot = Split-Path (Split-Path $flutterExe -Parent) -Parent
  $platformFile = Join-Path $sdkRoot "packages\flutter\lib\src\foundation\platform.dart"
  if (Test-Path $platformFile) {
    $content = Get-Content $platformFile -Raw -Encoding UTF8
    return ($content -match "ohos")
  }
  return $true
}

if (-not (Test-OhosSdk)) {
  Write-Host "Current Flutter SDK has no TargetPlatform.ohos (standard stable), skip patch"
  return
}

# Locate the pub cache hosted dir (PUB_CACHE override -> LOCALAPPDATA\Pub\Cache -> USERPROFILE\.pub-cache)
$hosted = $null
if ($env:PUB_CACHE) {
  $hosted = Join-Path $env:PUB_CACHE "hosted"
}
if (-not $hosted -and $env:LOCALAPPDATA) {
  $c = Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted"
  if (Test-Path $c) { $hosted = $c }
}
if (-not $hosted) {
  $hosted = Join-Path $env:USERPROFILE ".pub-cache\hosted"
}
if (-not (Test-Path $hosted)) {
  Write-Host "pub cache hosted dir not found: $hosted (skip patch)"
  return
}
Write-Host "==> pub cache hosted: $hosted"

$relTargets = @(
  "flutter_smooth_markdown-0.8.1\lib\widgets\smooth_selection_region.dart",
  "flutter_math_fork-0.7.4\lib\src\widgets\selectable.dart",
  "flutter_math_fork-0.7.4\lib\src\render\layout\line_editable.dart",
  "flutter_math_fork-0.7.4\lib\src\widgets\selection\gesture_detector_builder_selectable.dart"
)

$patched = 0
foreach ($hostDir in @(Get-ChildItem -Path $hosted -Directory -ErrorAction SilentlyContinue)) {
  foreach ($rel in $relTargets) {
    $path = Join-Path $hostDir.FullName $rel
    if (-not (Test-Path $path)) { continue }
    $src = [System.IO.File]::ReadAllText($path)
    if ($src -match "TargetPlatform\.ohos") {
      Write-Host "skip(already patched): $path"
      continue
    }
    # Detect EOL so the inserted lines match the file (CRLF on Windows).
    $nl = "`r`n"
    if ($src -notmatch "`r`n") { $nl = "`n" }
    $before = $src
    # 1) expression switch (smooth_selection_region.dart): linux/windows group gets ohos
    $src = $src.Replace(
      "      TargetPlatform.linux ||$nl      TargetPlatform.windows =>",
      "      TargetPlatform.linux ||$nl      TargetPlatform.windows ||$nl      TargetPlatform.ohos =>")
    # 2) statement switch, 6-space indent (selectable.dart / line_editable.dart)
    $src = $src.Replace(
      "      case TargetPlatform.android:$nl      case TargetPlatform.fuchsia:$nl      case TargetPlatform.linux:$nl      case TargetPlatform.windows:",
      "      case TargetPlatform.android:$nl      case TargetPlatform.fuchsia:$nl      case TargetPlatform.linux:$nl      case TargetPlatform.windows:$nl      case TargetPlatform.ohos:")
    # 3) statement switch, 8-space indent (gesture_detector_builder_selectable.dart)
    $src = $src.Replace(
      "        case TargetPlatform.android:$nl        case TargetPlatform.fuchsia:$nl        case TargetPlatform.linux:$nl        case TargetPlatform.windows:",
      "        case TargetPlatform.android:$nl        case TargetPlatform.fuchsia:$nl        case TargetPlatform.linux:$nl        case TargetPlatform.windows:$nl        case TargetPlatform.ohos:")
    if ($src -ne $before) {
      [System.IO.File]::WriteAllText($path, $src)
      $patched++
      Write-Host "patched: $path"
    } else {
      Write-Host "warn: no pattern matched, no change: $path"
    }
  }
}
Write-Host "done, patched $patched file(s)"
