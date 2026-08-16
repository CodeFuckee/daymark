#!/usr/bin/env bash
# 本地 ohos Flutter SDK 兼容补丁（issue #30 方案 A 引入 flutter_smooth_markdown 后新增）：
# 本项目开发机使用 OpenHarmony fork 的 Flutter（TargetPlatform 多出 ohos 枚举值），
# 而 flutter_smooth_markdown 0.8.1 / flutter_math_fork 0.7.4 内部对 TargetPlatform
# 做了穷尽 switch，未被 ohos SDK 编译（flutter test）时直接报编译错误。
# CI 使用标准 Flutter stable（ghcr.io/cirruslabs/flutter:stable），无 ohos 枚举，
# 无需本补丁；本脚本仅修复本地开发环境，幂等可重复执行。
#
# 用法：bash scripts/patch_ohos_pub_cache.sh [pub-cache-hosted-dir]
# 默认 PUB_CACHE_HOSTED=$HOME/.pub-cache/hosted
set -euo pipefail

HOSTED_DIR="${1:-$HOME/.pub-cache/hosted}"

python3 - "$HOSTED_DIR" <<'PYEOF'
import sys, pathlib, re

hosted = pathlib.Path(sys.argv[1])
targets = [
    hosted / "pub.flutter-io.cn/flutter_smooth_markdown-0.8.1/lib/widgets/smooth_selection_region.dart",
    hosted / "pub.flutter-io.cn/flutter_math_fork-0.7.4/lib/src/widgets/selectable.dart",
    hosted / "pub.flutter-io.cn/flutter_math_fork-0.7.4/lib/src/render/layout/line_editable.dart",
    hosted / "pub.flutter-io.cn/flutter_math_fork-0.7.4/lib/src/widgets/selection/gesture_detector_builder_selectable.dart",
    hosted / "pub.dev/flutter_smooth_markdown-0.8.1/lib/widgets/smooth_selection_region.dart",
    hosted / "pub.dev/flutter_math_fork-0.7.4/lib/src/widgets/selectable.dart",
    hosted / "pub.dev/flutter_math_fork-0.7.4/lib/src/render/layout/line_editable.dart",
    hosted / "pub.dev/flutter_math_fork-0.7.4/lib/src/widgets/selection/gesture_detector_builder_selectable.dart",
]

patched = 0
for path in targets:
    if not path.exists():
        continue
    src = path.read_text(encoding="utf-8")
    if "TargetPlatform.ohos" in src:
        print(f"skip(already patched): {path.relative_to(hosted)}")
        continue
    # 1) 表达式 switch（smooth_selection_region）：linux/windows 组追加 ohos
    src = src.replace(
        "      TargetPlatform.linux ||\n      TargetPlatform.windows =>\n        desktopTextSelectionHandleControls,",
        "      TargetPlatform.linux ||\n      TargetPlatform.windows ||\n      TargetPlatform.ohos =>\n        desktopTextSelectionHandleControls,",
        1,
    )
    # 2) 语句 switch：android/fuchsia/linux/windows 组统一追加 ohos case
    src = src.replace(
        "      case TargetPlatform.android:\n      case TargetPlatform.fuchsia:\n      case TargetPlatform.linux:\n      case TargetPlatform.windows:",
        "      case TargetPlatform.android:\n      case TargetPlatform.fuchsia:\n      case TargetPlatform.linux:\n      case TargetPlatform.windows:\n      case TargetPlatform.ohos:",
    )
    src = src.replace(
        "        case TargetPlatform.android:\n        case TargetPlatform.fuchsia:\n        case TargetPlatform.linux:\n        case TargetPlatform.windows:",
        "        case TargetPlatform.android:\n        case TargetPlatform.fuchsia:\n        case TargetPlatform.linux:\n        case TargetPlatform.windows:\n        case TargetPlatform.ohos:",
    )
    path.write_text(src, encoding="utf-8")
    patched += 1
    print(f"patched: {path.relative_to(hosted)}")

print(f"done, patched {patched} file(s)")
PYEOF
