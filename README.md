# Daymark 工作日志

个人自用工作日志桌面客户端（Flutter + Rust core，macOS / Linux / Windows）。

基于 [DESIGN.md](DESIGN.md) 设计方案实现。

## 功能

- **随手记录**：全局热键（默认 `Ctrl/Cmd+Shift+L`）随时弹窗记一条，回车即存
- **自动收集**：GitLab/GitHub 提交、目录文件变更、会议音频转录自动采集
- **AI 汇总**：Claude / DeepSeek / Ollama 三家适配，失败自动降级
- **纯 Markdown 存储**：`日报/` `周报/` `月报/` `inbox/` 全部是 .md 文件

## 目录结构

```
<日志根目录>/
├── 日报/2026-08-11-工作日报.md     # 定稿日报
├── 周报/2026-W33-工作周报.md
├── 月报/2026-08-工作月报.md
├── inbox/2026-08-11.md             # 当天随手记录（append）
├── 转写/<会议名>_转写.txt          # 音频转录缓存产物
└── .daymark/
    ├── settings.json               # 配置（token 存系统密钥库）
    ├── 素材缓存/<date>.json        # 按日期的采集缓存
    └── 草稿/<date>.md              # 未定稿初稿
```

## 开发

### 依赖

- Flutter（≥3.24，桌面平台）
- Rust stable（cargo）
- `flutter_rust_bridge_codegen`（`cargo install flutter_rust_bridge_codegen`）
- Linux 额外：`libayatana-appindicator3-dev`（tray_manager）、`libsecret-1-dev`、`ninja-build`、`clang`、`cmake`、`pkg-config`

### 常用命令

```bash
# 生成 FFI 绑定（修改 rust/src/api/ 后执行）
flutter_rust_bridge_codegen generate

# Rust 测试
cd rust && cargo test

# Dart 测试
flutter test

# 构建
flutter build linux --release

# 打包安装包
./scripts/build_appimage.sh                        # Linux AppImage（手写 AppDir + appimagetool）
./scripts/sign_macos.sh                            # macOS 构建 + ad-hoc 签名（dmg 见 CI）
powershell -File scripts/build_windows_installer.ps1 # Windows exe 安装包（NSIS）
```

### 架构

```
UI 层 (Flutter)         主窗口 / 热键弹窗 / 设置页 / 托盘
应用层 (Dart)           SettingsService / RecordService / CollectService / ReportService
领域层 (Dart)           素材模型 / LLM 适配 / 转录引擎 / 报告引擎
基础设施 (Rust core)    文档解析(pptx/xlsx/docx/pdf) / 文件监控(notify) / 全局热键(global-hotkey)
```

Rust core 经 flutter_rust_bridge v2 FFI 与 Dart 双向绑定，事件（热键触发、文件变更）经 Stream 回调 Dart。

## macOS 签名与分发

本机自用（ad-hoc 签名，无需开发者证书）：

```bash
flutter build macos --release
./scripts/sign_macos.sh          # 默认 ad-hoc
open build/macos/Build/Products/Release/daymark.app
```

首次打开需右键 →「打开」（ad-hoc 签名过不了 Gatekeeper，仅本机信任使用）。

对外分发（需 Apple Developer 账号）：用开发者证书签名 + notarization，见
`scripts/sign_macos.sh` 头部注释。

## CI 构建

**GitLab CI（`.gitlab-ci.yml`）**：每次 push 全量触发——

| Job | 产物 |
|---|---|
| `rust-test` / `dart-test` | Rust core 与 Flutter 测试 |
| `linux-build` | Linux **AppImage** 安装包（`scripts/build_appimage.sh`） |
| `macos-build` | macOS **arm64 dmg**（ad-hoc 签名，runner: mac） |
| `windows-build` | Windows **exe 安装包**（NSIS，runner: windows） |
| `push-to-github` | main 每次 push 时同步源码到 GitHub（排除 `.gitlab-ci.yml`，`scripts/sync_github.py`） |
| `publish-release` | 全部 job 成功后发布三端 release（GitLab 全量存档 + GitHub 滚动保留 5 个，`scripts/publish_release.py`） |

产物上传为 GitLab CI artifacts（保留 30 天）。macOS 公证需要开发者证书，
CI 默认只做 ad-hoc 签名（本机信任使用）。

GitHub 源码同步：main 分支每次 push 后自动同步到 GitHub 公开仓库
`CodeFuckee/daymark`，脱敏排除 `.gitlab-ci.yml`（GitHub 侧用自己的 Actions
workflow）。同步走 GitHub REST API（`scripts/sync_github.py`，github.com git
端点在国内网络间歇性被 SNI 干扰，git push 不可靠）。认证需要 GitLab CI
variable `GITHUB_TOKEN`（GitHub PAT，需 Contents: write / repo API 权限）；
该 job 与三平台构建相互独立（`needs: []`），构建失败不阻塞同步，反之亦然。

**GitHub Actions（`.github/workflows/build.yml`）**：push `v*` tag 或手动触发，
矩阵三平台构建（Linux tar.gz / macOS dmg / Windows zip），产物上传 GitHub
Actions artifacts，适合对外分发。

## 已知限制

- Linux 全局热键依赖 X11（Wayland 下可能不可用）
- 转录接口为 OpenAI 兼容协议（Groq / 火山 / 通义均可，配置 base_url）
- 云同步目录 mtime 刷新可能产生误报，日报措辞用"今日检测到变更"
