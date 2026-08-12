# Changelog

本项目改动记录（GitLab issue #1 起）。

## Unreleased

### 修复

- linux-build 锁定 code01 runner（tags: linux+deploy）：NAS runner 实为 shell
  executor 且 gitlab-runner 用户无 apt 权限，libsecret-1-dev 装不上致 CMake 构建
  失败（流水线 #582），锁定后回到 #560 成功路径
- Rust core 全局热键：Windows 平台 `GlobalHotKeyManager` 含 HWND 裸指针为
  `!Send`，`Mutex` 静态存储编译失败（E0277，仅 Windows target）→
  `unsafe impl Send + Sync` 包装（附安全性论证）

### 新增

- GitLab CI 三平台构建：`linux-build` 改出 AppImage 安装包，新增 `macos-build`
  （arm64 dmg，runner tag: mac）与 `windows-build`（exe 安装包，NSIS，runner
  tag: windows），每次 push 全量触发（issue #1）
- 新增打包脚本：
  - `scripts/build_appimage.sh`：Linux AppImage（手写 AppDir + ldd 收集依赖 + gh-proxy 代理下载 appimagetool，GitHub 被墙环境可用）
  - `scripts/build_windows_installer.ps1` + `scripts/daymark.nsi`：Windows NSIS 安装包
  - `scripts/macos_env.sh` / `scripts/windows_env.ps1`：macOS/Windows runner 环境自检与补齐
- 新增 `macos/` `windows/` 平台目录（flutter create 生成，含 CocoaPods/CMake 工程）
- GitLab CI 新增 `push-to-github` deploy 阶段（issue #2）：main 每次 push 时把
  源码快照同步到 GitHub 公开仓库 CodeFuckee/daymark（`scripts/sync_github.py`）；
  脱敏排除 `.gitlab-ci.yml`（GitHub 侧用自己的 Actions workflow `build.yml`）；
  认证走 GitLab CI variable `GITHUB_TOKEN`（需 API 写权限）
- GitLab CI 新增 `publish-release` deploy 阶段（issue #3）：全部 job 成功后发布
  三端 release（`scripts/publish_release.py`）——GitLab Releases 全量存档（generic
  packages 永久存储）+ GitHub Releases 对外分发（滚动保留最近 5 个，旧 release
  自动删除）；版本 vX.Y.Z 自动递增（以 GitLab 最新 tag 为准），release 描述含
  构建时间（UTC+8）与三端下载说明
- `scripts/sync_github.py` 走 GitHub REST API（git database API，api.github.com
  稳定可达）而非 git push——github.com git 端点在国内网络间歇性被 SNI 干扰
  （TCP 通但 TLS 握手被丢弃）；diff 对比远程 tree 只上传变化文件，首次推送
  建根提交（无历史），后续基于 GitHub 现有历史追加同步提交
