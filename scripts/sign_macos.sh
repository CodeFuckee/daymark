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

echo "==> 构建 macOS release"
flutter build macos --release

APP="build/macos/Build/Products/Release/daymark.app"
IDENTITY="${1:--}"

if [ ! -d "$APP" ]; then
  echo "错误: $APP 不存在" >&2
  exit 1
fi

echo "==> 签名 Frameworks 内的动态库（含 Rust core dylib）"
for f in "$APP"/Contents/Frameworks/*.dylib; do
  [ -f "$f" ] || continue
  codesign --force --sign "$IDENTITY" --options runtime "$f"
done

echo "==> 签名 .app（identity: $IDENTITY）"
codesign --force --sign "$IDENTITY" --options runtime "$APP"

echo "==> 验证签名"
codesign --verify --deep --strict "$APP"

echo "==> 完成: $APP"
