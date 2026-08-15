# Daymark Work Log

A personal desktop work-log client (Flutter + Rust core, macOS / Linux / Windows).

[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)]()
[![build](https://github.com/CodeFuckee/daymark/actions/workflows/build.yml/badge.svg)](https://github.com/CodeFuckee/daymark/actions/workflows/build.yml)

> 中文文档：[README_cn.md](README_cn.md)

Implemented based on the design in [DESIGN.md](DESIGN.md).

## Features

- **Quick notes**: global hotkey (default `Ctrl/Cmd+Shift+L`) pops up a small window anytime; press Enter to save
- **Auto collection**: GitLab/GitHub commits, directory file changes, and meeting audio transcripts collected automatically
- **AI summarization**: adapters for Claude / DeepSeek / Ollama with automatic fallback
- **Auto update**: checks for new releases at startup, downloads in the background and notifies; the update completes automatically on app restart
- **About section**: settings page shows version, build time, OS and other diagnostics with one-click copy for bug reports
- **Pure Markdown storage**: `日报/` `周报/` `月报/` `inbox/` are all `.md` files

## Directory Layout

```
<log root directory>/
├── 日报/2026-08-11-工作日报.md     # finalized daily report
├── 周报/2026-W33-工作周报.md
├── 月报/2026-08-工作月报.md
├── inbox/2026-08-11.md             # today's quick notes (append)
├── 转写/<meeting>_转写.txt          # audio transcript cache
└── .daymark/
    ├── settings.json               # config (tokens stored in system keychain)
    ├── 素材缓存/<date>.json        # per-date collection cache
    └── 草稿/<date>.md              # unfinalized drafts
```

## Development

### Dependencies

- Flutter (≥3.24, desktop platforms)
- Rust stable (cargo)
- `flutter_rust_bridge_codegen` (`cargo install flutter_rust_bridge_codegen`)
- Linux extras: `libayatana-appindicator3-dev` (tray_manager), `libsecret-1-dev`, `ninja-build`, `clang`, `cmake`, `pkg-config`

### Common Commands

```bash
# Generate FFI bindings (run after modifying rust/src/api/)
flutter_rust_bridge_codegen generate

# Rust tests
cd rust && cargo test

# Dart tests
flutter test

# Build
flutter build linux --release

# Package installers
./scripts/build_appimage.sh                        # Linux AppImage (hand-written AppDir + appimagetool)
./scripts/sign_macos.sh                            # macOS build + ad-hoc signing (dmg via CI)
powershell -File scripts/build_windows_installer.ps1 # Windows exe installer (NSIS)
```

### Architecture

```
UI layer (Flutter)          main window / hotkey popup / settings page / tray
Application layer (Dart)    SettingsService / RecordService / CollectService / ReportService
Domain layer (Dart)         material models / LLM adapters / transcription engine / report engine
Infrastructure (Rust core)  document parsing (pptx/xlsx/docx/pdf) / file watching (notify) / global hotkey (global-hotkey)
```

The Rust core is bound to Dart bidirectionally via flutter_rust_bridge v2 FFI; events (hotkey triggers, file changes) are delivered to Dart via Stream callbacks.

## macOS Signing & Distribution

For personal use (ad-hoc signing, no developer certificate needed):

```bash
flutter build macos --release
./scripts/sign_macos.sh          # ad-hoc by default
open build/macos/Build/Products/Release/daymark.app
```

First launch requires right-click → "Open" (ad-hoc signatures do not pass Gatekeeper; trusted locally only).

For external distribution (requires an Apple Developer account): sign with a developer certificate + notarization, see the header comments in `scripts/sign_macos.sh`.

## CI Builds

**GitLab CI (`.gitlab-ci.yml`)**: runs fully on every push —

| Job | Artifact |
|---|---|
| `rust-test` / `dart-test` | Rust core and Flutter tests |
| `prepare-version` | computes release version (latest GitLab releases tag patch+1) and generates auto-update dart-defines (passed to build jobs via dotenv) |
| `linux-build` | Linux **AppImage** installer (`scripts/build_appimage.sh`) |
| `macos-build` | macOS **arm64 dmg** (ad-hoc signed, runner: mac) |
| `windows-build` | Windows **exe installer** (NSIS, runner: windows) |
| `push-to-github` | syncs source to GitHub on every main push (excludes `.gitlab-ci.yml`, `scripts/sync_github.py`) |
| `publish-release` | publishes three-platform releases after all jobs succeed (full archive on GitLab + rolling 5 on GitHub, `scripts/publish_release.py`) |

Artifacts are uploaded as GitLab CI artifacts (retained 30 days). macOS notarization requires a developer certificate; CI only does ad-hoc signing by default (trusted locally).

GitHub source sync: after every push to main, the source is synced automatically to the public GitHub repository `CodeFuckee/daymark`, with `.gitlab-ci.yml` redacted (GitHub uses its own Actions workflow). The sync goes through the GitHub REST API (`scripts/sync_github.py`; the github.com git endpoint suffers intermittent SNI interference in mainland networks, making git push unreliable). Authentication requires the GitLab CI variable `GITHUB_TOKEN` (GitHub PAT with Contents: write / repo API permissions); this job is independent of the three platform builds (`needs: []`), so a build failure does not block the sync and vice versa.

**GitHub Actions (`.github/workflows/build.yml`)**: triggered on `v*` tags or manually; matrix builds on three platforms (Linux tar.gz / macOS dmg / Windows zip); artifacts uploaded to GitHub Actions artifacts, suitable for external distribution. Tag-triggered runs inject the version (tag minus `v`) and the GitHub update source (detection URL = GitHub releases of `CodeFuckee/daymark`).

## Auto Update (issue #5)

**Mechanism**: update source addresses are baked into the app at packaging time via `--dart-define` (build-time injection, read-only at runtime). GitLab CI packaging → checks GitLab repository releases (`prepare-version` job generates `DAYMARK_UPDATE_SOURCES_B64`, `scripts/update_defines.py`); GitHub Actions packaging → checks GitHub repository releases. When both are injected, the highest version wins.

**Flow**: background check at startup → auto download (sha256 verification, asset digest for GitHub releases) → system notification + settings page hint when done → update completes automatically when the user restarts the app:

- **Linux**: new AppImage atomically replaces the file `$APPIMAGE` points to → launches the new version
- **macOS**: mounts the dmg → `ditto` overwrites `Daymark.app` → clears quarantine → launches the new version
- **Windows**: launches the NSIS installer with `/S /UPDATE` for silent overwrite install and auto-start of the new version

Update packages are cached in `<app support dir>/update/` (manifest.json + installer) and installed by `main()` on restart. The settings page has "Check for updates / Restart & update" buttons, the tray menu has "Check for updates", and the "check at startup" toggle can be disabled in settings. Local dev builds (no update source injected) have the whole update feature disabled.

**Version consistency**: release versions are computed by `scripts/next_version.py` (latest GitLab releases tag patch+1); build artifacts embed the same version via `--build-name`, and `publish-release` publishes the same tag — artifact versions strictly match release tags, and update detection compares semver.

**Public repository anonymous access**: daymark's GitLab repository is public (confirmed by the user in issue #5); update detection (releases API) and artifact downloads (generic packages) are all anonymous, and no token is embedded in artifacts. The historically configured CI variable `GITLAB_READ_API_TOKEN` is no longer read and can be deleted. If the repository ever goes back to private, the token injection mechanism must be restored.

## Known Limitations

- Linux global hotkey depends on X11 (may not work under Wayland)
- The transcription endpoint is OpenAI-compatible (Groq / Volcano / Qwen all work; configure base_url)
- Cloud-synced directory mtime refreshes can cause false positives; daily reports use the wording "changes detected today"
- Auto update only applies to installer-form artifacts (AppImage / dmg install / NSIS install);
  GitHub Actions tar.gz / zip artifacts are not auto-installable — download them manually after a new version is detected

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for issue reporting, the development workflow, commit conventions, and test requirements.

## License

This project is licensed under the [MIT License](LICENSE).
