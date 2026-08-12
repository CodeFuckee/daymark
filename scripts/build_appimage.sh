#!/usr/bin/env bash
# Linux AppImage 打包（DESIGN.md §6.2）：flutter build linux → 手动组装 AppDir → appimagetool
#
# 背景：国内网络访问不了 GitHub releases（linuxdeploy 等工具下载被墙），
# 故不依赖 linuxdeploy：手写 AppDir（ldd 递归收集依赖 + gdk-pixbuf loaders +
# glib schemas + 自定义 AppRun），打包器经 gh-proxy 国内代理下载官方 appimagetool。
#
# 依赖（CI 已装）：cmake ninja-build clang pkg-config imagemagick（可选）binutils file
# 用法: ./scripts/build_appimage.sh
# 产物: daymark-x86_64.AppImage（仓库根目录）
set -euo pipefail

cd "$(dirname "$0")/.."

ARCH="x86_64"
OUT="daymark-${ARCH}.AppImage"

echo "==> flutter build linux --release"
flutter build linux --release

BUNDLE="build/linux/x64/release/bundle"
if [ ! -d "$BUNDLE" ]; then
  echo "错误: $BUNDLE 不存在" >&2
  exit 1
fi

# --- 1. AppDir 基础结构 ---
rm -rf AppDir
mkdir -p \
  AppDir/usr/lib \
  AppDir/usr/share/applications \
  AppDir/usr/share/icons/hicolor/256x256/apps
# Flutter bundle 整体复制到 usr/bin（daymark/data/lib 保持同目录布局，
# Flutter 运行时按 /proc/self/exe 定位 data/ 与 lib/，拆散会找不到资源）
cp -r "$BUNDLE"/. AppDir/usr/bin/

# 图标: tray_icon.png 放大到 256x256（ImageMagick 或 Python PIL，均无则用原图）
if command -v convert >/dev/null 2>&1; then
  convert assets/tray_icon.png -resize 256x256 AppDir/usr/share/icons/hicolor/256x256/apps/daymark.png
elif command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" 2>/dev/null; then
  python3 - <<'EOF'
from PIL import Image
im = Image.open('assets/tray_icon.png').convert('RGBA')
im.resize((256, 256), Image.LANCZOS).save('AppDir/usr/share/icons/hicolor/256x256/apps/daymark.png')
EOF
else
  cp assets/tray_icon.png AppDir/usr/share/icons/hicolor/256x256/apps/daymark.png
fi

cat > AppDir/usr/share/applications/daymark.desktop <<'EOF'
[Desktop Entry]
Name=Daymark
Name[zh_CN]=Daymark
Comment=个人工作日报记录
Comment[zh_CN]=个人工作日报记录
Exec=daymark
Icon=daymark
Terminal=false
Type=Application
Categories=Office;Utility;
StartupWMClass=daymark
EOF
# appimagetool 只在 AppDir 根目录找 .desktop 与图标（不递归 usr/share/...）
cp AppDir/usr/share/applications/daymark.desktop AppDir/daymark.desktop
cp AppDir/usr/share/icons/hicolor/256x256/apps/daymark.png AppDir/daymark.png

# --- 2. ldd 递归收集动态库到 AppDir/usr/lib ---
# 注意：不能用 `[ -e ... ] && continue`（set -e 下短路返回非零会静默退出），
# 且管道须整体保证退出码（grep 无匹配返回 1，pipefail 会触发 set -e）。
collect_deps() {  # $1 = ELF 文件
  while read -r lib; do
    name="$(basename "$lib")"
    if [ -e "AppDir/usr/lib/$name" ]; then
      continue
    fi
    cp -L "$lib" "AppDir/usr/lib/" 2>/dev/null || true
    collect_deps "$lib" || true
  done < <(ldd "$1" 2>/dev/null | awk '{print $3}' | grep -E '^/' || true)
}
collect_deps AppDir/usr/bin/daymark
# Flutter 引擎库也是 dlopen 加载（exe 相对路径），其依赖一并收集
[ -e AppDir/usr/bin/lib/libflutter_linux_gtk.so ] && collect_deps AppDir/usr/bin/lib/libflutter_linux_gtk.so
# 插件 dlopen 加载的库不在 ldd 依赖树中，需显式收集（连带递归依赖）：
# tray_manager → libayatana-appindicator3；flutter_secure_storage → libsecret
for lib in /usr/lib/x86_64-linux-gnu/libayatana-appindicator3.so.1 \
           /usr/lib/x86_64-linux-gnu/libsecret-1.so.0; do
  if [ -e "$lib" ]; then
    name="$(basename "$lib")"
    if [ ! -e "AppDir/usr/lib/$name" ]; then
      cp -L "$lib" AppDir/usr/lib/
    fi
    collect_deps "$lib"
  fi
done

# 排除 glibc 基础库（目标系统自带，避免版本冲突）
rm -f AppDir/usr/lib/libc.so.6 AppDir/usr/lib/libm.so.6 AppDir/usr/lib/libdl.so.2 \
  AppDir/usr/lib/libpthread.so.0 AppDir/usr/lib/librt.so.1 AppDir/usr/lib/libresolv.so.2 \
  AppDir/usr/lib/libutil.so.1 AppDir/usr/lib/ld-linux*.so.* AppDir/usr/lib/libnss_*.so.2

# --- 3. GTK 运行时资源（gdk-pixbuf loaders / glib schemas）---
# gdk-pixbuf 运行时按 GDK_PIXBUF_MODULEDIR 找图像解码器（图标必须）
if [ -d /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0 ]; then
  mkdir -p AppDir/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders
  cp /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/*/loaders/*.so AppDir/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/ 2>/dev/null || true
fi
# glib gsettings schemas（GTK 提示/对话框需要）
if [ -f /usr/share/glib-2.0/schemas/gschemas.compiled ]; then
  mkdir -p AppDir/usr/share/glib-2.0/schemas
  cp /usr/share/glib-2.0/schemas/gschemas.compiled AppDir/usr/share/glib-2.0/schemas/
fi

# --- 4. AppRun（设置库路径与运行时资源环境变量）---
cat > AppDir/AppRun <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GDK_PIXBUF_MODULEDIR="$HERE/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
exec "$HERE/usr/bin/daymark" "$@"
EOF
chmod +x AppDir/AppRun

# --- 5. appimagetool：PATH 优先，否则经国内代理下载 release 二进制 ---
# 注：appimagetool 上游 2025-11 起重构为 C/C++ 版，Go 版已无 tag 且 @latest 不可
# go install；GitHub 直连被墙，故经 gh-proxy 类代理下载 release AppImage 自解压。
APPIMAGETOOL="$(command -v appimagetool || true)"
if [ -z "$APPIMAGETOOL" ]; then
  TOOL_APPIMAGE=".cache/appimagetool.AppImage"
  mkdir -p .cache
  if [ ! -s "$TOOL_APPIMAGE" ]; then
    echo "==> 下载 appimagetool（gh-proxy 国内代理）"
    for proxy in "https://ghproxy.net" "https://gh-proxy.com"; do
      if curl -k -fL --retry 3 --connect-timeout 15 -o "$TOOL_APPIMAGE" \
        "$proxy/https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"; then
        break
      fi
    done
    [ -s "$TOOL_APPIMAGE" ] || { echo "错误: appimagetool 下载失败（需要可用的 GitHub 代理）" >&2; exit 1; }
  fi
  # curl 下载默认 644，AppImage 需可执行
  chmod +x "$TOOL_APPIMAGE"
  # 免 FUSE 环境：--appimage-extract-and-run 自解压后直接执行内部 ELF
  APPIMAGETOOL="$PWD/$TOOL_APPIMAGE"
fi
echo "==> appimagetool: $APPIMAGETOOL"

# --- 6. type2 runtime：appimagetool 打包需要 runtime，缺失时它尝试从
# github.com/AppImage/type2-runtime 下载（被墙，#605 实测）→ 预下载并显式传入
mkdir -p .cache
RUNTIME=".cache/runtime-x86_64"
if [ ! -s "$RUNTIME" ]; then
  echo "==> 下载 type2 runtime（gh-proxy 国内代理）"
  for proxy in "https://ghproxy.net" "https://gh-proxy.com"; do
    if curl -k -fL --retry 3 --connect-timeout 15 -o "$RUNTIME" \
      "$proxy/https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"; then
      break
    fi
  done
  [ -s "$RUNTIME" ] || { echo "错误: type2 runtime 下载失败" >&2; exit 1; }
fi

# --- 7. 打包（--appimage-extract-and-run 免 FUSE 运行工具 + 显式 runtime）---
"$APPIMAGETOOL" --appimage-extract-and-run --runtime-file "$PWD/$RUNTIME" AppDir "$PWD/$OUT"

echo "==> 完成: $OUT ($(du -h "$OUT" | cut -f1))"
