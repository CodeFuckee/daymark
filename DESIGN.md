# Daymark Work-Log Client — Design

> Status: design finalized, pending review
> Date: 2026-08-11
> Positioning: personal tool, three-platform desktop client for macOS / Linux / Windows

> 中文文档：[DESIGN_cn.md](DESIGN_cn.md)

---

## 1. Project Overview

### 1.1 Background

The existing daily-report workflow relies on the `daily-work-report` skill: manually run `collect.py` to gather GitLab commits + SynologyDrive directory changes + meeting audio transcripts, then polish via LLM into a Markdown report. Three pain points with that flow:

1. **After-the-fact collection**: logs are only written in the evening; the day's work has to be reconstructed from Git commits
2. **CLI-dependent**: collection, transcription, and generation all require manually running scripts
3. **Environment-bound**: GitLab instance, SynologyDrive paths, and the Python stack are hardcoded

### 1.2 Goals

Productize into a three-platform desktop client:

- **Quick notes**: a global hotkey pops up a window anytime, solving the core "forgetting to log" pain point
- **Auto collection**: GitLab/GitHub commits, directory file changes, and meeting audio transcripts collected automatically
- **AI summarization**: LLM drafts daily/weekly/monthly reports from the materials; humans polish before finalizing
- **Pure Markdown storage**: keeps the existing convention of one `.md` file per log in a cloud-synced directory

### 1.3 Non-Goals (out of scope for v1)

- Multi-user, accounts, server side
- Built-in rich-text Markdown editor (only a simple editor + external system editor)
- Calendar integration (automatic iCal/Outlook meeting pull) — audio relies on directory scanning
- Mobile

---

## 2. Requirements Summary (grill-me conclusions)

| Decision | Conclusion |
|---|---|
| Tech stack | Flutter Desktop + **Rust core** (flutter_rust_bridge FFI) |
| Product positioning | Personal tool, no accounts, no server |
| Work mode | Hybrid: quick notes (global hotkey) + auto collection + AI summarization |
| Storage form | Pure Markdown files, user-specified directory |
| Output dimensions | Daily report + weekly/monthly aggregation |
| Code data sources | GitLab + GitHub, both supporting multiple instances/accounts, fully configurable |
| File watching | Real-time events (Rust `notify` crate, cross-platform) |
| Document extraction | Rust parsers (pdf-extract + quick-xml + zip) |
| Audio transcription | OpenAI-compatible transcription endpoint (Groq/Volcano/Qwen etc., base_url configurable) |
| LLM | Native adapters for Claude + DeepSeek + Ollama |
| Editor | Built-in WYSIWYG Markdown editor (flutter_smooth_markdown, formatted blocks click-to-edit, Typora-like) + external system editor |
| Quick-note trigger | Global hotkey popup (Rust `global-hotkey` crate) |

**Core architectural decision**: since document parsing is done in Rust anyway, put file watching (`notify`) and the global hotkey (`global-hotkey`) into the Rust core as well, exposed to Dart uniformly via `flutter_rust_bridge` — avoiding writing separate Swift/Kotlin/C++ platform channels for each of the three platforms.

---

## 3. Overall Architecture

### 3.1 Layered View

```
┌─────────────────────────────────────────────────────────────┐
│  UI layer (Flutter)                                         │
│  Main window: calendar/list + editor + settings   Tray      │
│  Hotkey popup window                                        │
├─────────────────────────────────────────────────────────────┤
│  Application layer (Dart)                                   │
│  Service orchestration: RecordService  CollectService       │
│  ReportService  SettingsService  ProviderRegistry           │
│  NotificationService                                        │
├─────────────────────────────────────────────────────────────┤
│  Domain layer (Dart)                                        │
│  Material models (Commit/FileChange/Transcript/QuickNote/   │
│  Extracted)                                                 │
│  AI engine: LLMProvider adapters + prompt templates         │
│  Transcription engine: Transcriber (compatible-endpoint     │
│  adapters)                                                  │
│  Report engine: daily/weekly/monthly generation pipeline    │
├─────────────────────────────────────────────────────────────┤
│  Infrastructure (Rust core + Dart)                          │
│  Rust: document parsing (pptx/xlsx/docx/pdf)  file watching │
│        (notify)  global hotkey (global-hotkey)              │
│  Dart: network (http/oauth)  key storage                    │
│        (flutter_secure_storage)  Markdown rendering         │
│        (flutter_smooth_markdown)  local file IO                    │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Process Model

Single process: the Flutter main process loads the Rust core as a dynamic library via in-process FFI. No sidecar, no extra processes.

### 3.3 Key Dependency Selection

| Layer | Dependency | Notes |
|---|---|---|
| FFI | flutter_rust_bridge v2 | auto-generates bidirectional Dart/Rust bindings |
| Rust doc parsing | `pdf-extract` / `quick-xml` / `zip` | pptx/xlsx/docx are zip+xml; pdf via pdf-extract |
| Rust file watching | `notify` | unified wrapper over FSEvents / inotify / ReadDirectoryChangesW |
| Rust global hotkey | `global-hotkey` | registers system-level shortcuts on three platforms |
| State management | Riverpod | personal project, lightweight and testable |
| Key storage | flutter_secure_storage | Keychain / libsecret / Credential Manager |
| Markdown render/edit | flutter_smooth_markdown | WYSIWYG editor + render |
| Tray | tray_manager | resident + tray menu |
| Notifications | flutter_local_notifications | generation-complete reminders |
| Network | dio + OAuth2 packages | GitLab/GitHub API |
| LLM SDK | claude_dart + DeepSeek (OpenAI protocol) + Ollama (local) | see §8 |

---

## 4. Data Design (pure Markdown)

### 4.1 Directory Structure

The user specifies a "log root directory" in settings (defaults to the existing SynologyDrive Yuexiu work-record directory); the app creates the following structure underneath:

```
<log root>/
├── 日报/
│   ├── 2026-08-11-工作日报.md          # finalized daily report
│   └── 2026-08-12-工作日报.md
├── 周报/
│   └── 2026-W33-工作周报.md
├── 月报/
│   └── 2026-08-工作月报.md
├── inbox/
│   ├── 2026-08-11.md                   # today's quick notes (append mode)
│   └── 2026-08-12.md
├── 转写/
│   └── <meeting>_转写.txt               # audio transcript cache artifacts
└── .daymark/
    ├── settings.json                    # all config (tokens only in keychain)
    ├── 素材缓存/                        # per-date collection cache (commits, file changes, etc.)
    │   └── 2026-08-11.json
    └── 索引.json                        # file→date acceleration index (optional, pure speedup)
```

### 4.2 Quick-Note Format (inbox)

Each note is a `- [HH:mm] content #tag` list item, appended:

```markdown
# 2026-08-11 随手记录
- [09:12] 和产品确认了审批流改版需求 #会议
- [11:30] 修复 shipyard 流水线缓存失效 bug #开发
- [15:40] 输出越秀月度汇报材料初稿 #文档
```

- Plain-text lines; multiple `#xxx` tags allowed at the end of the line
- The note window saves on Enter, closes on Ctrl+Q, no editing UI (edit notes directly in the md file)

### 4.3 Daily Report Format (four-section style inherited from daily-work-report)

```markdown
# 工作日报 2026-08-11

## 一、代码提交
（grouped by GitLab/GitHub project; commit messages polished into natural language）

## 二、本地文件工作
（grouped by directory/type, including document points extracted by the Rust parser）

## 三、会议记录
（one line per audio: filename + points relevant to the author; note if irrelevant）

## 四、随手记录汇总
（inbox entries grouped by topic; original lines stay in inbox after AI summarization）

## 五、补充说明
（written only when extra input exists at generation time; omitted otherwise）
```

> Inherited pitfall: cloud-sync mtime gets refreshed by sync → use "changes detected today" wording instead of absolute assertions.

### 4.4 Weekly / Monthly Reports

Aggregate the period's daily-report points + quick notes, summarized by topic. Files go under `周报/` and `月报/`; AI drafts, humans finalize, same logic as daily reports (§7.4).

### 4.5 Indexing Strategy

Pure Markdown storage, no SQLite. `索引.json` is an optional acceleration cache: file path → first-line title/date. Rebuilt on invalidation (full scan is cheap at personal-data scale of up to a few thousand files).

---

## 5. Feature Module Design

### 5.1 Quick-Note Module (core selling point)

**Interaction**:
- Global hotkey (default `Ctrl/Cmd+Shift+L`, configurable in settings) → always-on-top popup window
- Popup = single-line input + automatic timestamp prefix + tag autocomplete (historical tags)
- Enter saves into `inbox/<today>.md`, window hides; `Esc` discards
- Tray icon resident; clicking the tray → main window / new note / generate today's report

**Implementation**: Rust `global-hotkey` registers the hotkey → event callback notifies Dart via FFI → Dart opens the frameless popup window.

### 5.2 Data Source Management

Provider abstraction (`CodeProvider` interface):

```
CodeProvider
├── GitLabProvider   # REST API v4, multiple instances and tokens
└── GitHubProvider   # REST API v3, multiple accounts
```

- **Config** (settings page): instance name, base_url, token (in keychain), default branch, visibility filter, repository selection (issue #31: per-instance pick of which repositories' commits are merged into the daily report; empty = all repositories, backward compatible)
- **Fetching**: pulls commits by natural day with `since=YYYY-MM-DD+08:00` / `until`, multiple projects in parallel, deduplicated by sha (same logic as collect.py)
- **Time zone**: fixed +08:00 natural days (inherits the existing pitfall note)
- Provides per-date query: `List<Commit> forDate(date)`

### 5.3 File Watching Module

**Rust `notify`** recursively watches the user-configured directory list (defaults to the SynologyDrive work directory; multiple directories supported).

- Events (Create/Modify/Remove) → throttled aggregation (e.g. 5s batches) → record changes: path, mtime, size, operation type
- Attributed to natural days by mtime, consistent with existing collect.py semantics
- Exclusion rules: hidden files, `@eaDir`, `node_modules`, .git, etc. (configurable on the settings page);
  on the daily-report page each "local file changes" row has a button to quickly add that file to the exclusion rules (issue #18);
  hovering over a row highlights it with a soft rounded background and restores on mouse-out (issue #24) so the current row is easy to track
- Change records are written to `.daymark/素材缓存/<date>.json` for the report pipeline to consume
- Cloud-sync mtime false positives: dedupe Modify events whose "content hash unchanged" during aggregation (optional; v1 just records)

### 5.4 Audio Transcription Module

- Scans the configured audio directory for new audio from today (inherits the "only scan the specified directory, not excluding the work-record directory" semantics)
- Calls an OpenAI-compatible transcription endpoint (base_url + key + model name, default `whisper-1`), uploads → text
- **Cache reuse** (inherits existing rule): a `<audio name>_转写.txt` with the same name exists and its mtime is not earlier than the audio's → reuse directly, no re-upload
- Output written to `<audio dir>/<audio name>_转写.txt`, fully consistent with the existing convention (the daily-work-report skill can keep reusing them)
- Transcription is slow: background task + progress notification

### 5.5 Document Extraction Module (Rust core)

| Format | Approach | Extracted content |
|---|---|---|
| pptx | `zip` unpack + `quick-xml` traversal of `<a:t>` | all text + per-slide title text |
| xlsx | same traversal of `<v>`/`<t>` | cell text (row cap to avoid explosion, e.g. first 500 rows) |
| docx | same traversal of `<w:t>` | body text |
| pdf | `pdf-extract` | full text (truncation threshold, e.g. 5000 chars) |

- Outputs `Extracted { path, kind, title, text_excerpt, text_hash }`
- Supplies content points for the daily report's "local file work" section
- Large/encrypted/garbled files → degrade to "filename only", never block the flow

### 5.6 Daily Report Generation Pipeline

```
Trigger: manual (main page button) / scheduled (optional in settings, e.g. 18:30 reminder)
  │
  ├─ 1. Collect materials
  │     ├─ inbox/<today>.md (quick notes)
  │     ├─ CodeProvider.forDate(today) (GitLab+GitHub)
  │     ├─ 素材缓存/<today>.json (file changes) + document extraction
  │     └─ today's audio in the audio dir → transcription (cache reuse)
  │
  ├─ 2. AI draft (§8 prompt templates; material priority: quick notes > commits > files > meetings)
  │
  ├─ 3. Built-in editor shows the draft → human polish (external system editor available)
  │
  └─ 4. Finalize: write 日报/2026-08-11-工作日报.md
```

Generation is **re-entrant**: the draft can be regenerated after materials change, but finalized content is never overwritten (finalization check: file exists and the user marked "finalized").

### 5.7 Editor

- Built-in WYSIWYG Markdown editor: `flutter_smooth_markdown` 0.8.1, default
  formatted mode (rendered blocks click-to-edit, Typora-like) — editing and
  rendering unified in a single view, so there is inherently no
  "split-pane synchronized scrolling" problem (issue #30, plan A confirmed by
  the user; replaces the previous `TextField` + flutter_markdown preview split,
  and eliminates the flicker / bottom-scroll deadlock reported in the first two
  rounds); the toolbar has built-in Formatted / Source / Preview / Split mode
  buttons for one-key switching to source mode to view raw Markdown
- Built-in formatting commands in the toolbar (headings/lists/quotes/code
  blocks/tables, etc.)
- "Open with system editor" button → writes a draft file + opens it in the
  system default app
- Finalize button → write to disk + archive (from "draft" to "finalized")

### 5.8 Settings Module

| Group | Items |
|---|---|
| Log | root directory picker, author name, accounts merged into code commits (supports pulling real commit authors from code repositories for selection, issue #20; the pull uses the settings draft instance list, so newly added unsaved instances can also be pulled, issue #20 round 3), time zone |
| Code | GitLab/GitHub instance list (add/remove/edit), tokens, branches, filters, repository selection (issue #31: per-instance pick of which repositories' commits are merged into the daily report; empty = all) |
| Directory watching | watch directory list, exclusion rules |
| Audio | audio directory, transcription base_url/key/model |
| AI | dynamic provider list (add/edit/delete, cc-switch style: "Add provider" pops a page to pick the type — Claude / DeepSeek / Ollama / OpenAI-compatible; issue #25) + main/fallback/meeting-blocked selection, tone preference |
| Hotkeys | global hotkey, launch at login |
| Notifications | generation reminder time, completion notification toggle |
| About | app name, version, build time, OS, hostname, Dart version, CPU cores, system language + one-click copy diagnostics |

---

## 6. Rust Core Design

### 6.1 FFI Surface (auto-generated by flutter_rust_bridge)

```rust
// Document parsing
fn extract_document(path: String) -> Result<Extracted, ExtractError>;

// File watching
fn watch_directories(paths: Vec<String>, exclude: Vec<String>) -> Result<WatcherHandle>;
// events delivered to Dart via stream (flutter_rust_bridge StreamSink)

// Global hotkey
fn register_hotkey(id: HotkeyId, modifiers: HotkeyModifiers, key: HotkeyKey) -> Result<()>;
fn unregister_hotkey(id: HotkeyId) -> Result<()>;
// triggers delivered to Dart via stream
```

### 6.2 Build & Distribution

- Three-platform artifacts: macOS `.dylib` / Linux `.so` / Windows `.dll`
- **macOS caveat**: the Rust dylib must be placed in the .app's Frameworks directory and signed; Linux needs `ldd` checks for clean dynamic linkage (staticize glibc dependencies where possible, or provide build instructions); Windows MSVC toolchain
- CI: GitHub Actions matrix builds Flutter + Rust + packaging on three platforms

---

## 7. AI Engine Design

### 7.1 Provider Adapter Layer

```dart
abstract class LLMProvider {
  Future<String> chat(String systemPrompt, List<Message> messages, {temperature});
  String get id; String get name;
}

class ClaudeProvider             // Anthropic Messages API, model e.g. claude-sonnet-5
class DeepSeekProvider           // OpenAI protocol + base_url, model e.g. deepseek-chat
class OllamaProvider             // http://localhost:11434, local models
class OpenAICompatibleProvider   // any OpenAI-compatible service (Groq/Volcano/Qwen etc.)
```

- Providers are an **add/edit/delete instance list** (`AiSettings.providers`, issue #25):
  each instance has a unique id, type, name, base_url, API key and model; the main
  provider / fallback ordering / meeting-blocked lists all reference instance ids.
  Legacy flat fields (claudeBaseUrl etc.) migrate into instances automatically, and
  serialization still writes the legacy fields for downgrade compatibility
- Settings page "Add provider" follows cc-switch: first a provider-type selection page
  (Claude / DeepSeek / Ollama / OpenAI-compatible), then a configuration form; the
  three defaults are pre-seeded and users can add any number of providers
- The configuration form has a "Fetch models" button (issue #27): clicking it
  pulls the model list from the provider's official models endpoint (Claude
  `GET /v1/models`, DeepSeek / OpenAI-compatible `GET /v1/models`, Ollama
  `GET /api/tags`); on success the model field becomes a dropdown, with a manual
  input toggle; the button is disabled while fetching, and missing base_url/API
  key, API failures and empty results all show a hint
- Unified interface, prompt templates decoupled from providers
- Failure fallback: main provider unavailable → automatically switch to fallbacks (priority configured in settings)
- Sensitive-content policy: meeting material defaults to Ollama/DeepSeek and can be locked in settings (Yuexiu meeting content is company data; uploading to third-party APIs is a compliance risk; the settings page offers a "disable Claude for meeting content" option)

- Unified interface; prompt templates decoupled from providers
- Failure fallback: primary unavailable → automatic switch to backup (priority configurable in settings)
- Sensitive-content policy: meeting materials can be locked to Ollama/DeepSeek in settings by default (Yuexiu meeting content is company data; uploading to third-party APIs carries compliance risk; the settings page provides a "disable Claude for meeting content" option)

### 7.2 Prompt Templates (daily report)

Inherits the daily-work-report distillation principles, solidified into templates:

- **Code commits**: grouped by project; commit messages polished into natural language explaining what was done
- **Local files**: grouped by directory/type, with document extraction points
- **Meetings**: keep only content relevant to the author (discussions participated in, questions/opinions raised, tasks assigned to self); irrelevant meetings list the topic only with a note
- **Quick notes**: summarized by topic, not listed one by one
- **Hard rules**: never fabricate content absent from the materials; when materials are insufficient, write plainly ("no commits today", etc.)

### 7.3 Transcription Endpoint Adapter

OpenAI-compatible `POST {base}/audio/transcriptions`, `multipart` upload. Groq, Volcano Engine, Alibaba Qwen, etc. all speak this protocol — only base_url and key need configuring.

### 7.4 Weekly / Monthly Report Templates

Input: the period's daily-report points + the period's inbox entries. Output: a topic-summarized aggregate report (completed this week / in progress / issues & blockers / next-week plan).

---

## 8. Technical Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Rust FFI cross-compilation/signing on three platforms | High | CI matrix builds on three platforms; macOS signing & notarization pre-research (personal use can do ad-hoc + local trust; no developer certificate for now) |
| Global hotkey conflicts (occupied by system/other apps) | Medium | registration-failure prompt + remap in settings; system event listening optional |
| Transcription endpoint protocol differences | Medium | OpenAI standard protocol first; verify against Groq then adapt Volcano/Qwen |
| xlsx/pptx parsing quality (merged cells, formulas, charts) | Medium | extract visible text only (`<t>`/`<v>`/`<w:t>`); graphic content skipped; extraction failures never block |
| Cloud-sync mtime false positives | Low | inherit "changes detected today" wording; content-hash dedupe |
| Large-file transcription time | Low | background task + progress notification; chunking/transcoding (direct m4a upload works with most endpoints) |
| Flutter desktop ecosystem maturity (tray/hotkey/editor) | Medium | hotkey & watching already pushed down to Rust; tray via tray_manager; editor built in-house (simple version) |
| Meeting data privacy | Medium | provider locked per content type (§7.1); local transcript cache deletable |

---

## 9. Milestones

### M1 — MVP (2–3 weeks): quick notes + daily-report loop

- Project scaffolding: Flutter + flutter_rust_bridge working builds on three platforms
- Rust core v0: `global-hotkey` + `notify` integration
- Quick notes: hotkey popup + inbox persistence
- GitLab provider + daily report generation pipeline (AI starts with DeepSeek; Claude configurable later)
- WYSIWYG Markdown editor + finalize-to-disk
- **Acceptance**: user records a note via hotkey on a Mac → generates today's daily report → finalizes

### M2 — Data source expansion (1–2 weeks)

- GitHub provider + multi-instance configuration
- Rust document parser (pptx/xlsx/docx/pdf)
- File changes enter the daily report's "local file work" section
- Settings page completion + keychain integration

### M3 — Transcription + aggregation (1–2 weeks)

- Audio directory scanning + compatible-endpoint transcription + cache reuse
- Weekly/monthly aggregate generation
- Tray/notification polish, launch-at-login, three-platform installers and distribution (GitHub Releases)

---

## 10. Open Questions & Next Steps

1. **Project naming**: tentatively "Daymark"; may be formally named with the project-naming skill
2. Repository initialization (GitHub private repo + Actions CI matrix suggested)
3. The existing daily-work-report skill coexists with the client: the client's finalized output format matches the skill's output, so both are interchangeable
4. Before M1, prototype three risk points: flutter_rust_bridge three-platform builds, global-hotkey behavior across platforms, notify recursive-watch performance

---

*This design is based on the grill-me session (2026-08-11) conclusions; all key decisions were confirmed by the user.*
