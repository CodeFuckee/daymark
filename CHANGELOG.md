# Changelog

本项目改动记录（GitLab issue #1 起）。

## Unreleased

### 修复

- 刷新素材按钮"没有反应"（issue #9）：根因是"作者名"配置为中文署名（如
  "陈凯迪"）时，commit 过滤要求字段包含配置名（单向子串匹配），与 git
  提交的英文用户名（如 "chenkaidi"）永远无法匹配，当天提交被全部过滤成
  "当日无提交"。修复：① 作者过滤支持多值配置（中英文逗号/分号分隔，任一
  命中即匹配）+ 双向子串匹配 + 大小写不敏感，可填"陈凯迪,chenkaidi"或
  附邮箱；② 兜底放行——作者过滤无命中但确有提交时保留全部提交，避免署名
  与 git 用户名不一致时误过滤；③ 日报署名取第一个非空值（多值配置时署名
  不受影响）；设置页"作者名"字段文案同步更新
- 新增回归测试：authorMatches 多值/双向/大小写不敏感匹配、GitLabProvider
  端到端过滤（fake adapter，覆盖中文署名放行、精确命中、混合作者、空配置）
- 设置页保存不再卡在"保存中…"（issue #6）：保存拆为「持久化（同步等待，
  写失败即时提示）+ 运行时重载（后台串行执行、各环节独立容错）」——热键
  注册、目录监控重启、开机自启应用任一环节阻塞（如大目录递归 watch、无
  显示环境、网络盘 IO）都不再拖住保存反馈；Linux 上 notify 递归 watch 移
  到后台线程（inotify 每个子目录一个 watch，大目录树同步遍历可耗时数分钟，
  并阻塞 FRB handler），并用递增 generation 标记防止过期 watcher 覆盖新一轮
  监控；成功提示文案改为"设置已保存"（重载在后台继续）
- 新增保存链路回归测试：AppController.saveSettings 在重载环节全部挂起时也
  必须完成（超时即失败）、后台重载异常不外泄、持久化失败抛给设置页、连续
  保存的重载串行执行；设置页保存成功/失败/进行中的 UI 契约测试

### 新增

- 自动更新功能（issue #5）：打包时经 `--dart-define` 把更新源写入软件
  （GitLab 打包检测 GitLab release，GitHub 打包检测 GitHub release，多源取
  版本最高者）；启动时后台检测新版本 → 自动下载（sha256 校验）→ 下载完成
  系统通知 + 设置页提示 → 重启软件时自动完成更新（Linux 原子替换 AppImage、
  macOS 挂载 dmg 后 ditto 覆盖 .app 并清 quarantine、Windows 启动 NSIS
  `/S /UPDATE` 静默覆盖安装并自动启动新版）。设置页新增更新区块（当前版本 /
  检查更新 / 下载进度 / 重启并更新 / 自动检查开关），托盘菜单新增"检查更新"；
  本地开发构建（未注入更新源）更新功能整体禁用
- 版本一致性（issue #5 配套）：新增 `scripts/next_version.py`（GitLab releases
  最新 tag patch+1）与 `scripts/update_defines.py`（生成更新 dart-define）；
  CI 新增 `prepare-version` job 经 dotenv artifact 把 `APP_VERSION` 与
  `DART_DEFINES` 传给三平台构建 job，产物经 `--build-name` 内嵌与 release tag
  一致的版本；`publish-release` 改用构建阶段算好的版本（`version.txt`），
  不再发布时重复递增（消除产物版本与 release tag 不一致的竞态）
- `scripts/daymark.nsi` 支持 `/S` 静默与 `/UPDATE` 更新模式（安装前等待旧进程
  退出，安装完成后自动启动新版本）；GitHub Actions `build.yml` tag 触发时
  注入版本与 GitHub 更新源
- 更新源改用 public 匿名访问（issue #5 用户反馈）：仓库已公开，不再内置只读
  token——`update_defines.py` 停止注入、`UpdateSource` 移除 token 字段（旧格式
  JSON 容错忽略）、检测请求不再携带认证头；CI variable `GITLAB_READ_API_TOKEN`
  不再使用（可自行删除）

### 修复

- macOS 构建产物仍闪退（issue #4 第二轮，v0.1.1）：v0.1.1 起 app 与全部嵌入
  framework/dylib 均为 ad-hoc 签名且 Team ID 一致，但 `sign_macos.sh` 对 ad-hoc
  签名也加了 `--options runtime`（Hardened Runtime）→ 开启 Library Validation，
  dyld 要求嵌入库与主程序 Team ID 严格一致，而 ad-hoc 无 Team ID（macOS 15+
  判定空与 null 不匹配），加载 `@rpath/daymark_core.framework` 仍报
  "different Team IDs" 闪退 → 现在仅真实证书签名启用 Hardened Runtime，ad-hoc
  签名跳过（OpenClaw/electron-builder 等项目的 ad-hoc 构建同样做法）；Team ID
  一致性校验保留。签名参数用字符串变量承载（CI macOS runner 为 bash 3.2，
  空数组在 `set -u` 下展开报 unbound variable）
- macOS 构建产物启动闪退（issue #4）：`scripts/sign_macos.sh` 此前只签名
  `Contents/Frameworks/*.dylib` 与 `.app`，跳过了 `.framework`（daymark_core.framework
  保留 Xcode 构建期签名，与 .app 的 ad-hoc 签名 Team ID 不一致，dyld 加载
  `@rpath/daymark_core.framework` 报 "different Team IDs" 直接 SIGABRT）→ 现在对
  `.framework` 强制 `--force --deep` 重签，并新增 Team ID 一致性硬校验（app 与
  全部嵌入组件必须一致，ad-hoc 均为空；不一致则构建失败，避免再次发布坏产物）
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
