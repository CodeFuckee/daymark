# 安全策略

感谢你对 Daymark 安全性的关注。本文档说明如何报告漏洞与本项目对安全的处理方式。

## 支持的版本

本项目滚动发布，仅**最新版本**（GitLab / GitHub 最新 release）接收安全修复。
旧版本请先升级到最新版后再验证问题是否仍存在。

## 报告漏洞

发现安全漏洞请通过 [GitLab Issue](https://home.chenkaidi.top:509/chenkaidi/daymark/-/issues)
提交**机密 Issue**（勾选「This issue is confidential」），并包含：

- 受影响版本与平台（macOS / Linux / Windows）
- 漏洞类型与影响范围（如敏感信息泄露、任意文件读写等）
- 最小复现步骤与验证材料（PoC、日志、堆栈）
- 你的联系与期望的披露时间

## 处理流程

1. 收到机密 Issue 后在 7 天内确认并开始评估；
2. 修复经测试验证后随新版本发布；
3. 确认已修复并经你同意后公开披露（默认在修复版本发布后 30 天）。

## 范围与边界

- 本应用为个人自用工具，本地数据（Markdown 日志、设置）由用户自行保管；
- 自动更新包经 sha256 校验（GitHub release 的 asset digest），仅信任
  GitLab / GitHub 官方 release 渠道；
- 依赖上游（Flutter、Rust crates、LLM 接口服务）的漏洞不在本仓库修复范围内，
  请向对应上游报告。
