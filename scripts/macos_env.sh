#!/usr/bin/env bash
# macOS runner 环境自检/补齐（cargokit 需要 Rust；Flutter/Xcode 缺失直接报错）
# 用法: . scripts/macos_env.sh   （必须 source：脚本内 export 的 PATH 需对后续
#        CI 步骤可见；子进程方式（bash scripts/...）的 export 会丢失）
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "==> 安装 Rust（rustup + stable，rsproxy 镜像）"
  curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh |
    sh -s -- -y --profile minimal --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# crates 走 rsproxy 镜像（与 .gitlab-ci.yml rust-setup 一致）。
# 注意：必须无条件覆盖——若 runner 上已有旧 config.toml（默认 crates.io 被墙），
# 跳过写入会导致 cargokit 下载 crate 失败（#601 实测 time-core 下载失败）。
mkdir -p ~/.cargo
printf '%s\n' \
  '[source.crates-io]' \
  'replace-with = "rsproxy-sparse"' \
  '[source.rsproxy-sparse]' \
  'registry = "sparse+https://rsproxy.cn/index/"' \
  '[net]' \
  'git-fetch-with-cli = true' \
  > ~/.cargo/config.toml

cargo --version && rustc --version

# Flutter SDK：缺失时自动安装（storage.flutter-io.cn 镜像，releases JSON 取最新 stable）；
# 已装到 ~/flutter 则复用（避免每次 job 重新下载约 1GB）。
# 注意：arm64 runner 上若缓存的 SDK 是 x86_64 版（Rosetta，之前误装），
# 构建会链接 x86_64 产物且 Rust dylib 架构不匹配（#602 ld symbol not found），
# 须删除重装 arm64 版。
if ! command -v flutter >/dev/null 2>&1; then
  if [ -x "$HOME/flutter/bin/flutter" ]; then
    if [ "$(uname -m)" = "arm64" ] && \
       file "$HOME/flutter/bin/cache/dart-sdk/bin/dart" 2>/dev/null | grep -q "x86_64"; then
      echo "==> 检测到 x86_64 Flutter SDK（arm64 runner 不适用），删除并重装 arm64 版"
      rm -rf "$HOME/flutter"
    else
      export PATH="$HOME/flutter/bin:$PATH"
    fi
  fi
  if [ ! -x "$HOME/flutter/bin/flutter" ]; then
    echo "==> 安装 Flutter SDK（storage.flutter-io.cn 镜像）"
    BASE="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
    # runner 是 darwin/arm64，须取 dart_sdk_arch=arm64 的 release（zip 名带 arm64）
    VER="$(curl -s "$BASE/flutter_infra_release/releases/releases_macos.json" |
      python3 -c "import json,sys; d=json.load(sys.stdin);
for r in d['releases']:
    if r['channel']=='stable' and r.get('dart_sdk_arch')=='arm64':
        print(r['version']); break" 2>/dev/null || echo 3.44.0)"
    echo "==> 下载 Flutter $VER arm64（约 1GB，首次较慢）"
    curl -L --fail --retry 3 --retry-delay 5 -o /tmp/flutter.zip \
      "$BASE/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_${VER}-stable.zip"
    rm -rf /tmp/flutter-sdk
    mkdir -p /tmp/flutter-sdk
    unzip -q /tmp/flutter.zip -d /tmp/flutter-sdk
    mv /tmp/flutter-sdk/flutter "$HOME/flutter"
    rm -rf /tmp/flutter-sdk /tmp/flutter.zip
    export PATH="$HOME/flutter/bin:$PATH"
  fi
fi
flutter --version

# Xcode 必须存在（flutter build macos 需要），缺失报清晰错误
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "错误: macOS runner 上未安装 Xcode。flutter build macos 需要 Xcode（App Store 安装）。" >&2
  exit 1
fi
xcodebuild -version

# CocoaPods（flutter build macos 的插件集成需要）；gem 走清华源（rubygems.org 被墙）
if ! command -v pod >/dev/null 2>&1; then
  echo "==> 安装 CocoaPods（gem，清华镜像源）"
  gem install --user-install cocoapods -s https://mirrors.tuna.tsinghua.edu.cn/rubygems/ --no-document
  export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$PATH"
fi
pod --version
