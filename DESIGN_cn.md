# 工作日志客户端（Daymark）设计方案

> 状态：设计定稿，待评审
> 日期：2026-08-11
> 定位：个人自用工具，macOS / Linux / Windows 三平台桌面客户端
> English version: [DESIGN.md](DESIGN.md)

---

## 1. 项目概述

### 1.1 背景

现有工作日报生成依赖 `daily-work-report` 技能：手动运行 `collect.py` 收集 GitLab 提交 + SynologyDrive 目录文件改动 + 会议音频转录，再经 LLM 润色输出 Markdown 日报。该流程有三点不满足需求：

1. **事后收集**：晚上才想起记日志，白天干活的内容全靠翻 Git 提交回忆
2. **依赖命令行**：收集、转录、生成都要手动跑脚本
3. **绑定现有环境**：GitLab 实例、SynologyDrive 路径、Python 栈写死

### 1.2 目标

产品化为三平台桌面客户端：

- **随手记录**：全局热键随时弹窗记一条，解决"记不住"核心痛点
- **自动收集**：GitLab/GitHub 提交、目录文件变更、会议音频转录自动采集
- **AI 汇总**：LLM 把素材汇总成日报/周报/月报初稿，人工润色后定稿
- **纯 Markdown 存储**：延续"每篇日志一个 .md 文件、放云同步目录"的现有惯例

### 1.3 非目标（第一版不做）

- 多用户、账号体系、服务端
- 内置富文本 Markdown 编辑器（只做简易编辑 + 外调系统编辑器）
- 日历集成（iCal/Outlook 会议自动拉取）——音频靠目录扫描
- 移动端

---

## 2. 需求汇总（grill-me 拷问结论）

| 决策点 | 结论 |
|---|---|
| 技术栈 | Flutter Desktop + **Rust core**（flutter_rust_bridge FFI） |
| 产品定位 | 个人自用工具，无账号无服务端 |
| 工作模式 | 混合：随手记录（全局热键）+ 自动收集 + AI 汇总 |
| 存储形态 | 纯 Markdown 文件，用户指定目录 |
| 输出维度 | 日报 + 周报/月报聚合 |
| 代码数据源 | GitLab + GitHub，均支持多实例/多账号，全可配置 |
| 文件监控 | 实时事件监听（Rust `notify` crate，跨平台） |
| 文档提取 | Rust 解析器（pdf-extract + quick-xml + zip） |
| 音频转录 | OpenAI 兼容转录接口（可指 Groq/火山/通义等，base_url 可配） |
| LLM | Claude + DeepSeek + Ollama 三家原生适配 |
| 编辑器 | 简易内置（文本+高亮+预览分栏）+ 可外调系统编辑器 |
| 随手记录触发 | 全局热键弹窗（Rust `global-hotkey` crate） |

**架构核心决策**：既然文档解析用 Rust，则把文件监控（`notify`）与全局热键（`global-hotkey`）一并放进 Rust core，统一通过 `flutter_rust_bridge` 暴露给 Dart——避免为三平台各写一套 Swift/Kotlin/C++ 平台通道。

---

## 3. 总体架构

### 3.1 分层视图

```
┌─────────────────────────────────────────────────────────────┐
│  UI 层 (Flutter)                                            │
│  主窗口：日历/列表 + 编辑器 + 设置    托盘   热键弹窗窗口     │
├─────────────────────────────────────────────────────────────┤
│  应用层 (Dart)                                              │
│  服务编排：RecordService  CollectService  ReportService     │
│  SettingsService  ProviderRegistry  NotificationService      │
├─────────────────────────────────────────────────────────────┤
│  领域层 (Dart)                                              │
│  素材模型(Commit/FileChange/Transcript/QuickNote/Extracted)  │
│  AI 引擎：LLMProvider 适配层 + 提示词模板                     │
│  转录引擎：Transcriber（兼容接口适配）                        │
│  报告引擎：日报/周报/月报生成流水线                           │
├─────────────────────────────────────────────────────────────┤
│  基础设施 (Rust core + Dart)                                │
│  Rust: 文档解析(pptx/xlsx/docx/pdf) 文件监控(notify)         │
│        全局热键(global-hotkey)                               │
│  Dart: 网络(http/oauth) 密钥存储(flutter_secure_storage)     │
│        Markdown 渲染(flutter_markdown) 本地文件 IO          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 进程模型

单进程：Flutter 主进程，Rust core 以动态库形式同进程 FFI 加载。无 sidecar、无额外进程。

### 3.3 关键依赖选型

| 层 | 依赖 | 说明 |
|---|---|---|
| FFI | flutter_rust_bridge v2 | 自动生成 Dart/Rust 双向绑定 |
| Rust 文档解析 | `pdf-extract` / `quick-xml` / `zip` | pptx/xlsx/docx 为 zip+xml，pdf 用 pdf-extract |
| Rust 文件监控 | `notify` | FSEvents / inotify / ReadDirectoryChangesW 统一封装 |
| Rust 全局热键 | `global-hotkey` | 三平台注册系统级快捷键 |
| 状态管理 | Riverpod | 个人项目，轻量且可测 |
| 密钥存储 | flutter_secure_storage | Keychain / libsecret / Credential Manager |
| Markdown 渲染 | flutter_markdown | 预览分栏 |
| 托盘 | tray_manager | 常驻 + 托盘菜单 |
| 通知 | flutter_local_notifications | 生成完成提醒 |
| 网络 | dio + OAuth2 包 | GitLab/GitHub API |
| LLM SDK | claude_dart + DeepSeek(OpenAI 协议) + Ollama(本地) | 见 §8 |

---

## 4. 数据设计（纯 Markdown）

### 4.1 目录结构

用户通过设置指定一个"日志根目录"（默认沿用 SynologyDrive 越秀工作记录目录），App 在其下自建如下结构：

```
<日志根目录>/
├── 日报/
│   ├── 2026-08-11-工作日报.md          # 定稿日报
│   └── 2026-08-12-工作日报.md
├── 周报/
│   └── 2026-W33-工作周报.md
├── 月报/
│   └── 2026-08-工作月报.md
├── inbox/
│   ├── 2026-08-11.md                   # 当天随手记录（append 模式）
│   └── 2026-08-12.md
├── 转写/
│   └── <会议名>_转写.txt                # 音频转录缓存产物
└── .daymark/
    ├── settings.json                    # 全部配置（token 只存密钥库）
    ├── 素材缓存/                        # 按日期的采集缓存（commit、文件变更等）
    │   └── 2026-08-11.json
    └── 索引.json                        # 文件→日期的加速索引（可选，纯加速非必需）
```

### 4.2 随手记录格式（inbox）

每条记录一个 `- [HH:mm] 内容 #标签` 列表项，append 写入：

```markdown
# 2026-08-11 随手记录
- [09:12] 和产品确认了审批流改版需求 #会议
- [11:30] 修复 shipyard 流水线缓存失效 bug #开发
- [15:40] 输出越秀月度汇报材料初稿 #文档
```

- 纯文本行，标签 `#xxx` 可多个，落在行尾
- 记录窗口回车即存，Ctrl+Q 关闭，无编辑 UI（改记录直接在 md 文件里改）

### 4.3 日报格式（沿用 daily-work-report 四段式）

```markdown
# 工作日报 2026-08-11

## 一、代码提交
（按 GitLab/GitHub 项目分组，commit message 润色为自然语言）

## 二、本地文件工作
（按目录/类型分组，含 Rust 解析器提取的文档要点）

## 三、会议记录
（每个音频一行：文件名 + 与本人相关的内容要点；无关则注明）

## 四、随手记录汇总
（inbox 条目按主题归类；AI 归纳后原始行保留在 inbox 不动）

## 五、补充说明
（生成时若有额外输入则写入；无则省略）
```

> 陷阱沿用：云同步 mtime 会被同步刷新 → 措辞用"今日检测到变更"而非绝对断言。

### 4.4 周报/月报

聚合期内的日报要点 + 随手记录，按主题归纳。文件存 `周报/`、`月报/`，AI 生成初稿、人工定稿，逻辑与日报一致（§7.4）。

### 4.5 索引策略

纯 Markdown 存储，无 SQLite。`索引.json` 为可选加速缓存：文件路径 → 首行标题/日期。失效即重建（全量扫描成本低，个人数据量级数千文件以内）。

---

## 5. 功能模块设计

### 5.1 随手记录模块（核心卖点）

**交互**：
- 全局热键（默认 `Ctrl/Cmd+Shift+L`，可在设置改）→ 弹出置顶小窗
- 小窗 = 单行输入框 + 当前时间戳自动前缀 + 标签自动补全（历史标签）
- 回车存入 `inbox/<今天>.md`，窗口隐藏；`Esc` 丢弃
- 托盘图标常驻；点击托盘 → 主窗口/新建记录/生成今日日报

**实现**：Rust `global-hotkey` 注册热键 → 事件回调经 FFI 通知 Dart → Dart 侧开无边框小窗。

### 5.2 数据源管理

Provider 抽象（`CodeProvider` 接口）：

```
CodeProvider
├── GitLabProvider   # REST API v4，支持多实例多 token
└── GitHubProvider   # REST API v3，支持多账号
```

- **配置**（设置页）：实例名、base_url、token（存密钥库）、默认分支、可见性过滤
- **拉取**：按自然日 `since=YYYY-MM-DD+08:00` / `until` 拉 commit，多项目并行，按 sha 去重（沿用 collect.py 逻辑）
- **时区**：固定 +08:00 自然日（沿用现有陷阱说明）
- 提供按日期查询的素材：`List<Commit> forDate(date)`

### 5.3 文件监控模块

**Rust `notify`** 递归监控用户配置的目录列表（默认 SynologyDrive 工作目录，可多目录）。

- 事件（Create/Modify/Remove）→ 节流聚合（如 5s 批处理）→ 记录变更：路径、mtime、大小、操作类型
- 按 mtime 归属自然日，与现有 collect.py 语义一致
- 排除规则：隐藏文件、`@eaDir`、`node_modules`、.git 等（设置页可配）；
  日报页「本地文件变更」每条记录右侧按钮可快捷把该文件加入排除规则（issue #18）；
  鼠标悬停到某一行时该行浅色圆角背景高亮、移出恢复（issue #24），便于定位当前行
- 变更记录写入 `.daymark/素材缓存/<date>.json`，供日报流水线消费
- 云同步目录 mtime 刷新误报：聚合时对"内容 hash 未变"的 Modify 事件去重（可选，v1 先只记录）

### 5.4 音频转录模块

- 扫描配置的音频目录（沿用"只扫指定目录、不排除工作记录目录"语义）当日新增音频
- 调 OpenAI 兼容转录接口（base_url + key + 模型名，默认 `whisper-1`）上传 → 文本
- **缓存复用**（沿用现有规则）：目标音频同名的 `_转写.txt` 存在且 mtime 不早于音频 → 直接复用，不重复上传
- 产物写 `<音频目录>/<音频名>_转写.txt`，保持与现有惯例完全一致（后续可被 daily-work-report 技能继续复用）
- 转录是慢操作：后台任务 + 进度通知

### 5.5 文档提取模块（Rust core）

| 格式 | 方案 | 提取内容 |
|---|---|---|
| pptx | `zip` 解包 + `quick-xml` 遍历 `<a:t>` | 全部文本 + 每页标题文本 |
| xlsx | 同上遍历 `<v>`/`<t>` | 单元格文本（限制行数防爆炸，如前 500 行） |
| docx | 同上遍历 `<w:t>` | 正文文本 |
| pdf | `pdf-extract` | 全文文本（截断阈值，如 5000 字） |

- 输出 `Extracted { path, kind, title, text_excerpt, text_hash }`
- 供日报"本地文件工作"章节做内容要点
- 大文件/加密/乱码 → 降级为"仅记录文件名"，不阻断流程

### 5.6 日报生成流水线

```
触发：手动（主界面按钮）/ 定时（设置中可选，如每天 18:30 通知提醒）
  │
  ├─ 1. 收集素材
  │     ├─ inbox/当天.md（随手记录）
  │     ├─ CodeProvider.forDate(今天)（GitLab+GitHub）
  │     ├─ 素材缓存/当天.json（文件变更）+ 文档提取
  │     └─ 音频目录当日音频 → 转录（缓存复用）
  │
  ├─ 2. AI 起草（§8 提示词模板，按素材优先级：随手记录 > commit > 文件 > 会议）
  │
  ├─ 3. 内置编辑器呈现初稿 → 人工润色（可外调系统编辑器）
  │
  └─ 4. 定稿：写入 日报/2026-08-11-工作日报.md
```

生成是**可重入**的：素材变化后可重新生成初稿，但不会覆盖已定稿内容（定稿判定：文件存在且用户标记"已定稿"）。

### 5.7 编辑器

- 简易内置：`TextField`（等宽字体）+ flutter_markdown 预览分栏（左右 / Tab）；左右分栏滚动同步——按滚动比例对齐源码与预览位置（issue #30）
- 行号、Markdown 语法高亮（简易正则高亮，不引重型编辑器）
- "用系统编辑器打开"按钮 → `OpenFile` 定位 + 系统默认应用打开 md
- 定稿按钮 → 落盘 + 归档（从"草稿"态进入"已定稿"）

### 5.8 设置模块

| 分组 | 项 |
|---|---|
| 日志 | 根目录选择、作者名、并入代码提交的账户（支持从代码仓库拉取提交作者勾选并入，issue #20；拉取走设置草稿实例列表，新增实例未保存也能拉取，issue #20 第三轮）、时区 |
| 代码 | GitLab/GitHub 实例列表（增删改）、token、分支、过滤 |
| 目录监控 | 监控目录列表、排除规则 |
| 音频 | 音频目录、转录接口 base_url/key/模型 |
| AI | 供应商动态列表（可增删改，参考 cc-switch：「添加供应商」弹出页面选择类型，支持 Claude / DeepSeek / Ollama / OpenAI 兼容；issue #25）+ 主供应商/备选降级/会议禁用选择、生成语气偏好 |
| 快捷键 | 全局热键、是否开机自启 |
| 通知 | 生成提醒时间、完成通知开关 |
| 关于 | 应用名、版本号、构建时间、操作系统、主机名、Dart 版本、CPU 核心数、系统语言 + 一键复制诊断信息 |

---

## 6. Rust core 设计

### 6.1 FFI 面（flutter_rust_bridge 自动生成）

```rust
// 文档解析
fn extract_document(path: String) -> Result<Extracted, ExtractError>;

// 文件监控
fn watch_directories(paths: Vec<String>, exclude: Vec<String>) -> Result<WatcherHandle>;
// 事件经 stream 回调 Dart（flutter_rust_bridge 的 StreamSink）

// 全局热键
fn register_hotkey(id: HotkeyId, modifiers: HotkeyModifiers, key: HotkeyKey) -> Result<()>;
fn unregister_hotkey(id: HotkeyId) -> Result<()>;
// 触发经 stream 回调 Dart
```

### 6.2 编译与分发

- 三平台产物：macOS `.dylib` / Linux `.so` / Windows `.dll`
- **macOS 需注意**：Rust dylib 要打进 .app 的 Frameworks 目录并签名；Linux 需 `ldd` 检查动态链接干净（尽量静态化 glibc 依赖或提供构建说明）；Windows MSVC 工具链
- CI：GitHub Actions 矩阵三平台构建 Flutter + Rust + 打包安装包

---

## 7. AI 引擎设计

### 7.1 供应商适配层

```dart
abstract class LLMProvider {
  Future<String> chat(String systemPrompt, List<Message> messages, {temperature});
  String get id; String get name;
}

class ClaudeProvider             // Anthropic Messages API，model 如 claude-sonnet-5
class DeepSeekProvider           // OpenAI 协议 + base_url，model 如 deepseek-chat
class OllamaProvider             // http://localhost:11434，本地模型
class OpenAICompatibleProvider   // 任意 OpenAI 兼容服务（Groq/火山引擎/通义等）
```

- 供应商是**可增删改的实例列表**（`AiSettings.providers`，issue #25）：每个实例有
  唯一 id、类型、名称、base_url、API Key、模型；主供应商/备选降级/会议禁用均按
  实例 id 引用。旧版扁平字段（claudeBaseUrl 等）自动迁移为实例，序列化仍写回
  旧字段兼容降级
- 设置页「添加供应商」参考 cc-switch：先弹出供应商类型选择页（Claude / DeepSeek /
  Ollama / OpenAI 兼容），再进入配置表单；默认预置三家，用户可添加任意数量
- 配置表单内置「获取模型」按钮（issue #27）：点击通过供应商官方模型列表接口
  （Claude `GET /v1/models`、DeepSeek/OpenAI 兼容 `GET /v1/models`、Ollama
  `GET /api/tags`）拉取模型，成功后模型字段变为下拉菜单选择，可切回手动输入；
  拉取中按钮禁用防重复点击，base_url/API Key 缺失、接口失败、空列表均有提示
- 统一接口，提示词模板与供应商解耦
- 失败降级：主供应商不可用 → 自动切换备选（设置里配置优先级）
- 敏感内容策略：会议素材默认走 Ollama/DeepSeek 可在设置中锁定（越秀会议内容属于公司数据，上传第三方 API 存在合规风险，设置页提供"会议内容禁用 Claude"选项）

- 统一接口，提示词模板与供应商解耦
- 失败降级：主供应商不可用 → 自动切换备选（设置里配置优先级）
- 敏感内容策略：会议素材默认走 Ollama/DeepSeek 可在设置中锁定（越秀会议内容属于公司数据，上传第三方 API 存在合规风险，设置页提供"会议内容禁用 Claude"选项）

### 7.2 提示词模板（日报）

沿用 daily-work-report 的提炼原则，固化为模板：

- **代码提交**：按项目分组，commit message 润色成自然语言，说明做了什么
- **本地文件**：按目录/类型分组，附文档提取要点
- **会议**：只保留与作者相关的内容（参与的讨论、提出的问题/观点、分配给自己的任务）；无关会议只列主题并注明
- **随手记录**：按主题归类汇总，不逐条罗列
- **硬规则**：不编造素材中没有的内容；素材不足时如实写明"当日无提交"等

### 7.3 转录接口适配

OpenAI 兼容 `POST {base}/audio/transcriptions`，`multipart` 上传。Groq、火山引擎、阿里通义等均兼容此协议，只需配置 base_url 与 key。

### 7.4 周报/月报模板

输入：期内日报要点 + 期内 inbox 条目。输出按主题归纳的聚合报告（本周完成/进行中/问题与阻塞/下周计划）。

---

## 8. 技术风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Rust FFI 三平台交叉编译/签名 | 高 | CI 矩阵三平台构建；macOS 签名与 notarization 预研（个人自用可用 ad-hoc + 本地信任，暂不购买开发者证书） |
| 全局热键冲突（被系统/其他 App 占用） | 中 | 注册失败提示 + 设置页改键；监听系统事件可选 |
| 转录接口协议差异 | 中 | 先兼容 OpenAI 标准协议；实际接 Groq 验证后适配火山/通义 |
| xlsx/pptx 解析质量（合并单元格、公式、图表） | 中 | 只提取可见文本（`<t>`/`<v>`/`<w:t>`），图形化内容降级跳过；提取失败不阻断 |
| 云同步 mtime 误报 | 低 | 沿用"今日检测到变更"措辞；内容 hash 去重 |
| 大文件转录耗时 | 低 | 后台任务 + 进度通知；分片/压缩转码（m4a 直传多数接口兼容） |
| Flutter 桌面生态成熟度（托盘/热键/编辑器） | 中 | 热键与监控已下沉 Rust；托盘用 tray_manager；编辑器自研简易版 |
| 会议数据隐私 | 中 | 供应商按内容类型锁定（§7.1）；转写产物本地缓存可删 |

---

## 9. 里程碑规划

### M1 — MVP（2~3 周）：随手记录 + 日报闭环

- 项目脚手架：Flutter + flutter_rust_bridge 打通三平台构建
- Rust core v0：`global-hotkey` + `notify` 接入
- 随手记录：热键弹窗 + inbox 落盘
- GitLab provider + 日报生成流水线（AI 用 DeepSeek 起步，Claude 后可配）
- 简易编辑器（文本 + 预览分栏）+ 定稿落盘
- **验收**：用户在 Mac 上热键记一条 → 生成今日日报 → 定稿

### M2 — 数据源扩展（1~2 周）

- GitHub provider + 多实例配置
- Rust 文档解析器（pptx/xlsx/docx/pdf）
- 文件变更进入日报"本地文件工作"章节
- 设置页完善 + 密钥库接入

### M3 — 转录 + 聚合（1~2 周）

- 音频目录扫描 + 兼容接口转录 + 缓存复用
- 周报/月报聚合生成
- 托盘/通知打磨、开机自启、三平台安装包与分发（GitHub Releases）

---

## 10. 待定与下一步

1. **项目命名**：暂定 "Daymark"，可用 project-naming 技能正式定名
2. 仓库初始化（建议 GitHub 私有仓库 + Actions CI 矩阵）
3. 现有 daily-work-report 技能与客户端并存：客户端定稿产物格式与技能输出一致，两套可互用
4. M1 前先用原型验证三个风险点：flutter_rust_bridge 三平台构建、global-hotkey 三平台行为、notify 递归监控表现

---

*本方案基于 grill-me 会话（2026-08-11）拷问结论编写，关键决策均有用户确认。*
