# Security Policy

Thanks for your interest in Daymark's security. This document explains how to report vulnerabilities and how this project handles security.

> 中文文档：[SECURITY_cn.md](SECURITY_cn.md)

## Supported Versions

This project uses rolling releases; only the **latest version** (the newest release on GitLab / GitHub) receives security fixes. For older versions, please upgrade to the latest version first and verify whether the issue still exists.

## Reporting a Vulnerability

If you find a security vulnerability, please submit a **confidential Issue** via [GitLab Issues](https://home.chenkaidi.top:509/chenkaidi/daymark/-/issues) (check "This issue is confidential"), including:

- Affected version and platform (macOS / Linux / Windows)
- Vulnerability type and impact scope (e.g. sensitive information disclosure, arbitrary file read/write)
- Minimal reproduction steps and verification materials (PoC, logs, stack traces)
- Your contact and preferred disclosure timeline

## Handling Process

1. Acknowledge and start assessment within 7 days of receiving the confidential Issue;
2. The fix ships in a new release after being verified by tests;
3. Public disclosure after the fix is confirmed and with your consent (default: 30 days after the fixed release).

## Scope & Boundaries

- This app is a personal tool; local data (Markdown logs, settings) is kept by the user;
- Auto-update packages are sha256-verified (asset digest of GitHub releases), and only official GitLab / GitHub release channels are trusted;
- Vulnerabilities in upstream dependencies (Flutter, Rust crates, LLM endpoint services) are out of scope for this repository — please report them to the respective upstreams.
