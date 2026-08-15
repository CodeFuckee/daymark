# Contributing Guide

Thanks for your interest in Daymark! This document explains how to participate in the development and maintenance of this project.

> 中文文档：[CONTRIBUTING_cn.md](CONTRIBUTING_cn.md)

## Reporting Issues

Please report problems via [GitLab Issues](https://home.chenkaidi.top:509/chenkaidi/daymark/-/issues), ideally including:

- **Bug**: reproduction steps, expected behavior, actual behavior, error logs/stack traces, runtime environment (OS, Flutter/Rust versions);
- **Feature request**: requirement background, expected behavior, acceptance criteria, edge cases.

Issue label conventions:

| Label | Meaning |
| --- | --- |
| `bug` | Bug fix |
| `feature` | New feature |
| `test` | Test supplementation |
| `docs` | Documentation improvement |
| `optimize` | Performance/code optimization |
| `in-progress` | In progress |
| `bot-done` | Development done, awaiting human confirmation |

## Development Environment

See [README.md](README.md#development) for dependencies and common commands. Quick checklist:

- Flutter ≥ 3.24 (desktop platforms)
- Rust stable (cargo)
- `flutter_rust_bridge_codegen` (regenerate FFI bindings after modifying `rust/src/api/`)

## Development Workflow

This project develops directly on the default main branch (`main`) — **no feature branches**:

1. Run `git pull --rebase` to sync the latest remote code before developing;
2. Write (or supplement) test cases before writing code;
3. Push only after the full local test suite passes:
   ```bash
   cd rust && cargo test && cd ..
   flutter test
   ```
4. Watch the GitLab CI pipeline after pushing; keep fixing until it succeeds;
5. Update [CHANGELOG.md](CHANGELOG.md) and [CHANGELOG_cn.md](CHANGELOG_cn.md) with every change (both the English and Chinese versions are maintained in sync).

> Resolve merge conflicts by hand, one by one. Force pushes (`git push --force`) are **forbidden**.

## Commit Conventions

Commit messages use a conventional prefix + Chinese description:

- `fix:` bug fixes
- `feat:` new features
- `test:` test supplementation/correction
- `docs:` documentation changes
- `chore:` build, CI, misc

Example: `fix: 设置页排除规则保存失败时未提示（issue #18）`

## Documentation Conventions

All documentation files are maintained in two copies, one English and one Chinese; the Chinese version adds a `cn` suffix to the filename (e.g. `README.md` / `README_cn.md`). When changing one, update both. GitHub issue/PR templates follow the same rule (Chinese templates carry the `cn` suffix). `LICENSE` stays single-copy (standard MIT legal text).

## Test Requirements

- New features must ship with unit tests and edge cases (empty input, extremes, repeated calls, invalid arguments);
- Bug fixes must first include a test case that reproduces the failure;
- Run the full local test suites (`cargo test` + `flutter test`) before pushing, ensuring no regressions.

## License

This project is licensed under the [MIT License](LICENSE). Submitting code means you agree to release your contribution under that license.
