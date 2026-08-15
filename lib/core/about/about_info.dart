/// 关于板块诊断信息（issue #7）：版本号、构建时间、操作系统等，
/// 用于帮助调试与问题复现，支持一键复制（粘贴到 Issue / 聊天窗口）。
///
/// 数据来源：
/// - 版本号：UpdateConfig.appVersion（CI 构建经 --dart-define 注入，与更新板块一致）；
/// - 构建时间：DAYMARK_BUILD_TIME dart-define（scripts/update_defines.py 在 CI 注入
///   UTC ISO8601 时间戳，三平台构建脚本共享 DART_DEFINES）；
/// - 操作系统等运行时信息：dart:io Platform。
///
/// 本地开发构建不注入版本号/构建时间 → 显示占位文案，不阻塞展示其他信息。
library;

import 'dart:io';

/// 单条诊断信息（应用名 + 版本 + 构建 + 运行时环境）
class AboutInfo {
  /// 应用名
  final String appName;
  /// 产物版本 X.Y.Z（CI 注入；本地开发构建为 null/空）
  final String? appVersion;
  /// 构建时间（CI 注入 UTC ISO8601；本地开发构建为 null/空）
  final String? buildTime;
  /// 操作系统名（linux / macos / windows）
  final String osName;
  /// 操作系统版本（内核版本等，如 7.0.0-28-generic）
  final String osVersion;
  /// 主机名（区分报告来自哪台机器）
  final String hostname;
  /// Dart 运行时版本（Platform.version，含 VM 与内核信息）
  final String dartVersion;
  /// CPU 逻辑核心数
  final int processors;
  /// 系统语言（如 zh_CN，本地化问题复现用）
  final String locale;

  const AboutInfo({
    required this.appName,
    required this.appVersion,
    required this.buildTime,
    required this.osName,
    required this.osVersion,
    required this.hostname,
    required this.dartVersion,
    required this.processors,
    required this.locale,
  });

  /// 收集运行时诊断信息。
  ///
  /// 平台相关字段默认从 [Platform] 读取，可通过参数注入覆盖（单元测试用）；
  /// [buildTime] 未显式传入时读 DAYMARK_BUILD_TIME dart-define。
  factory AboutInfo.collect({
    String? appVersion,
    String? buildTime,
    String? osName,
    String? osVersion,
    String? hostname,
    String? dartVersion,
    int? processors,
    String? locale,
  }) {
    const injectedBuildTime = String.fromEnvironment('DAYMARK_BUILD_TIME');
    return AboutInfo(
      appName: 'Daymark',
      appVersion: _nonEmpty(appVersion),
      buildTime: _nonEmpty(buildTime) ?? _nonEmpty(injectedBuildTime),
      osName: osName ?? Platform.operatingSystem,
      osVersion: osVersion ?? Platform.operatingSystemVersion,
      hostname: hostname ?? Platform.localHostname,
      dartVersion: dartVersion ?? Platform.version,
      processors: processors ?? Platform.numberOfProcessors,
      locale: locale ?? Platform.localeName,
    );
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// 展示条目（中文标签 + 值）；未注入字段显示占位文案，平台字段空值显示「未知」，
  /// 保证复制出去的信息完整可读、不留空行。
  List<MapEntry<String, String>> get entries => [
        MapEntry('应用名', appName.isEmpty ? '未知' : appName),
        MapEntry('版本号', appVersion ?? '开发构建（未注入版本号）'),
        MapEntry('构建时间', buildTime ?? '开发构建（未注入构建时间）'),
        MapEntry(
          '操作系统',
          osName.isEmpty ? '未知' : [osName, osVersion].where((s) => s.isNotEmpty).join(' '),
        ),
        MapEntry('主机名', hostname.isEmpty ? '未知' : hostname),
        MapEntry('Dart 版本', dartVersion.isEmpty ? '未知' : dartVersion),
        MapEntry('CPU 核心数', processors.toString()),
        MapEntry('系统语言', locale.isEmpty ? '未知' : locale),
      ];

  /// 一键复制文本：首行标题 + 每行「标签: 值」，可直接粘贴到 Issue 描述/评论。
  String toCopyText() =>
      'Daymark 诊断信息\n${entries.map((e) => '${e.key}: ${e.value}').join('\n')}';
}
