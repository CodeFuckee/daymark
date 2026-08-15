# 贡献指南

感谢你对 Daymark 的关注！本文档说明如何参与本项目的开发与维护。

## 如何报告问题

请通过 [GitLab Issue](https://home.chenkaidi.top:509/chenkaidi/daymark/-/issues) 提交问题，建议包含：

- **Bug**：复现步骤、预期行为、实际行为、异常日志/堆栈、运行环境（操作系统、Flutter/Rust 版本）；
- **功能建议**：需求背景、期望行为、验收标准、边界场景。

Issue 标签约定：

| 标签 | 含义 |
| --- | --- |
| `bug` | 缺陷修复 |
| `feature` | 新功能 |
| `test` | 补充测试 |
| `docs` | 文档完善 |
| `optimize` | 性能/代码优化 |
| `in-progress` | 处理中 |
| `bot-done` | 开发完成，待人工确认 |

## 开发环境

依赖与常用命令详见 [README.md](README.md#开发)。快速检查清单：

- Flutter ≥ 3.24（桌面平台）
- Rust stable（cargo）
- `flutter_rust_bridge_codegen`（修改 `rust/src/api/` 后需重新生成 FFI 绑定）

## 开发流程

本项目在默认主分支（`main`）上直接开发，**不创建功能分支**：

1. 开发前先 `git pull --rebase` 同步远端最新代码；
2. 编写代码前先编写（或补充）测试用例；
3. 本地全量测试通过后方可推送：
   ```bash
   cd rust && cargo test && cd ..
   flutter test
   ```
4. 推送后关注 GitLab CI 流水线，失败需修复直至成功；
5. 所有改动同步更新 [CHANGELOG.md](CHANGELOG.md)。

> 合并冲突时请手工逐条解决，**禁止** `git push --force` 等强制覆盖操作。

## 提交规范

提交信息使用约定式前缀 + 中文描述：

- `fix:` 缺陷修复
- `feat:` 新功能
- `test:` 补充/修正测试
- `docs:` 文档变更
- `chore:` 构建、CI、杂项

示例：`fix: 设置页排除规则保存失败时未提示（issue #18）`

## 测试要求

- 新功能必须配套单元测试与边界用例（空输入、极值、重复调用、异常参数）；
- Bug 修复必须先编写可复现失败的测试用例；
- 推送前本地运行全部测试套件（`cargo test` + `flutter test`），确保无回归。

## 许可证

本项目采用 [MIT License](LICENSE)。提交代码即表示同意在该许可证下发布你的贡献。
