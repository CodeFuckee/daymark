#!/usr/bin/env bash
# macOS 签名脚本（DESIGN.md §6.2/§8）
#
# 用法:
#   ./scripts/sign_macos.sh                 # ad-hoc 签名（个人自用，本机信任）
#   ./scripts/sign_macos.sh "Developer ID Application: Your Name (TEAMID)"
#                                          # 开发者证书签名（分发用）
#
# ad-hoc 签名说明（个人自用不购证书）：
#   codesign 用 "-" 做 ad-hoc 签名，首次打开时右键 → 打开（或 xattr -dr com.apple.quarantine）
#   即可运行。不会通过 Gatekeeper，仅本机使用。
#
# 开发者证书 + notarization（分发用，需 Apple Developer 账号）：
#   1. 用上面的 identity 参数签名
#   2. 公证: xcrun notarytool submit daymark.app --wait --key-id KEYID --issuer ISSUER --key authkey.p8
#   3. 打 dmg 后再公证一次 dmg，stapler:
#      xcrun stapler staple daymark.app / daymark.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

# 自动更新注入（issue #5）：CI 由 prepare-version dotenv 提供环境变量
BUILD_ARGS=""
[ -n "${APP_VERSION:-}" ] && BUILD_ARGS="$BUILD_ARGS --build-name $APP_VERSION"
[ -n "${DART_DEFINES:-}" ] && BUILD_ARGS="$BUILD_ARGS $DART_DEFINES"

echo "==> 构建 macOS release$BUILD_ARGS"
# shellcheck disable=SC2086  # $BUILD_ARGS 由环境变量注入，需按词拆分
flutter build macos --release $BUILD_ARGS

APP="build/macos/Build/Products/Release/daymark.app"
IDENTITY="${1:--}"

# Hardened Runtime 仅对真实证书签名启用：ad-hoc（"-"）签名加 --options runtime
# 会开启 Library Validation，dyld 要求所有嵌入库与主程序 Team ID 严格一致，
# 而 ad-hoc 无 Team ID（空 vs null 不匹配），macOS 15+ 直接拒绝加载
# @rpath/daymark_core.framework → 启动闪退（issue #4 第二轮，v0.1.1 签名全一致
# 仍崩即此因）。OpenClaw/electron-builder 等项目的 ad-hoc 构建同样跳过 runtime。
# 注意用字符串而非数组：CI 的 macOS runner 是 bash 3.2，空数组在 set -u 下
# 展开报 "unbound variable"（bash 4.4+ 才修复），字符串变量无此问题。
SIGN_OPTS=""
if [ "$IDENTITY" != "-" ]; then
  SIGN_OPTS="--options runtime"
fi

if [ ! -d "$APP" ]; then
  echo "错误: $APP 不存在" >&2
  exit 1
fi

echo "==> 签名 Frameworks 内的动态库（含 Rust core dylib）"
for f in "$APP"/Contents/Frameworks/*.dylib; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC2086  # $SIGN_OPTS 为空或固定 "--options runtime"，需按词拆分
  codesign --force --sign "$IDENTITY" $SIGN_OPTS "$f"
done

# 关键：签名 .framework（daymark_core.framework 等）。此前只签 .dylib 与 .app，
# framework 保留 Xcode 构建期的签名，与 .app 的 ad-hoc 签名 Team ID 不一致，
# dyld 加载 @rpath/daymark_core.framework 时报 "different Team IDs" → 启动闪退
# （issue #4）。--force --deep 强制重签内部全部二进制（Versions/A/... 等）。
echo "==> 签名 Frameworks 内的 .framework（含 Rust core framework）"
for f in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$f" ] || continue
  # shellcheck disable=SC2086  # $SIGN_OPTS 为空或固定 "--options runtime"，需按词拆分
  codesign --force --deep --sign "$IDENTITY" $SIGN_OPTS "$f"
done

echo "==> 签名 .app（identity: $IDENTITY）"
# shellcheck disable=SC2086  # $SIGN_OPTS 为空或固定 "--options runtime"，需按词拆分
codesign --force --sign "$IDENTITY" $SIGN_OPTS "$APP"

echo "==> 验证签名"
codesign --verify --deep --strict "$APP"

# dyld 要求主程序与嵌入的 framework/dylib Team ID 完全一致（ad-hoc 均为空）——
# --verify 不覆盖此项，缺失校验会重蹈 issue #4：签名无效但 CI 仍绿。
echo "==> 校验 Team ID 一致性（dyld 加载要求主程序与嵌入组件一致）"
APP_TEAM=$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F'=' '/TeamIdentifier/{print $2; exit}')
echo "    app TeamIdentifier: ${APP_TEAM:-<空/ad-hoc>}"
for f in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib; do
  [ -e "$f" ] || continue
  T=$(codesign -dv --verbose=4 "$f" 2>&1 | awk -F'=' '/TeamIdentifier/{print $2; exit}')
  if [ "$T" != "$APP_TEAM" ]; then
    echo "错误: $f TeamIdentifier='${T:-空}' 与 app '${APP_TEAM:-空}' 不一致，dyld 会拒绝加载（issue #4）" >&2
    exit 1
  fi
done
echo "    Team ID 全部一致"

echo "==> 完成: $APP"
