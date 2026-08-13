/// 更新源配置（构建期注入，issue #5）：打包时经 --dart-define 写入软件。
///
/// - `DAYMARK_UPDATE_SOURCES_B64`：base64(JSON 源数组)，如
///   [{"type":"gitlab","api":"https://host/api/v4","project":"ns%2Fproj","token":"..."},
///    {"type":"github","repo":"owner/repo"}]
/// - `DAYMARK_APP_VERSION`：产物版本 X.Y.Z（与 release tag 一致，CI 构建时注入）
///
/// GitLab 打包只注入 GitLab 源，GitHub 打包只注入 GitHub 源（issue 要求：
/// 打包源决定更新检测地址）；两个都注入时全查取版本最高者。
/// 未注入（本地开发构建）→ 更新功能整体禁用，不打扰开发。
library;

import 'dart:convert';
import 'dart:io';

/// 单个更新源（GitLab / GitHub 二选一类型）
class UpdateSource {
  /// 'gitlab' | 'github'
  final String type;
  /// GitLab API 基址（含 /api/v4）
  final String? api;
  /// GitLab 项目路径（URL 编码，如 chenkaidi%2Fdaymark）
  final String? project;
  /// GitLab 只读 token（private 仓库 release API 需要；构建时内置，仅 read 权限）
  final String? token;
  /// GitHub 仓库 owner/repo
  final String? repo;

  const UpdateSource._({
    required this.type,
    this.api,
    this.project,
    this.token,
    this.repo,
  });

  const UpdateSource.gitlab({
    required String api,
    required String project,
    String? token,
  }) : this._(type: 'gitlab', api: api, project: project, token: token);

  const UpdateSource.github({required String repo})
      : this._(type: 'github', repo: repo);

  /// 解析 JSON 条目；类型未知或必填字段缺失 → 抛 [FormatException]（调用方跳过）
  factory UpdateSource.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'gitlab':
        final api = json['api'] as String? ?? '';
        final project = json['project'] as String? ?? '';
        if (api.isEmpty || project.isEmpty) {
          throw const FormatException('gitlab 源缺 api/project');
        }
        return UpdateSource.gitlab(
          api: api,
          project: project,
          token: json['token'] as String?,
        );
      case 'github':
        final repo = json['repo'] as String? ?? '';
        if (repo.isEmpty) {
          throw const FormatException('github 源缺 repo');
        }
        return UpdateSource.github(repo: repo);
      default:
        throw FormatException('未知更新源类型: ${json['type']}');
    }
  }
}

/// 构建期注入的更新配置（不可变；运行时只读）
class UpdateConfig {
  final List<UpdateSource> sources;
  /// 产物版本（无 v 前缀的 X.Y.Z；未注入为 null）
  final String? appVersion;
  /// 本平台 release 资产名（如 daymark-linux-x86_64.AppImage）
  final String assetName;

  const UpdateConfig({
    required this.sources,
    required this.appVersion,
    required this.assetName,
  });

  /// 是否有能力做更新检测（源与版本均已注入）
  bool get enabled =>
      sources.isNotEmpty && appVersion != null && appVersion!.isNotEmpty;

  /// 平台 → release 资产名（与 scripts/publish_release.py ASSETS 一致）
  static String assetNameFor(String osName) => switch (osName) {
        'linux' => 'daymark-linux-x86_64.AppImage',
        'macos' => 'daymark-macos-arm64.dmg',
        'windows' => 'daymark-windows-x64-setup.exe',
        _ => 'daymark-linux-x86_64.AppImage',
      };

  /// 解析 dart-define；任何损坏输入容错为空源（更新功能静默禁用，不影响主流程）
  static UpdateConfig parse(
    String? sourcesB64,
    String? appVersion,
    String assetName,
  ) {
    final sources = <UpdateSource>[];
    if (sourcesB64 != null && sourcesB64.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(base64Decode(sourcesB64)));
        if (decoded is List) {
          for (final entry in decoded) {
            try {
              sources.add(UpdateSource.fromJson(
                (entry as Map).cast<String, dynamic>(),
              ));
            } on FormatException {
              // 跳过不可用条目（未知类型 / 缺字段）
            }
          }
        }
      } catch (_) {
        // base64/JSON 损坏 → 空源
      }
    }
    return UpdateConfig(
      sources: sources,
      appVersion:
          (appVersion != null && appVersion.isNotEmpty) ? appVersion : null,
      assetName: assetName,
    );
  }

  /// 从编译期环境读取（--dart-define 注入）
  factory UpdateConfig.fromEnvironment() {
    const sourcesB64 = String.fromEnvironment('DAYMARK_UPDATE_SOURCES_B64');
    const version = String.fromEnvironment('DAYMARK_APP_VERSION');
    return UpdateConfig.parse(
      sourcesB64,
      version,
      UpdateConfig.assetNameFor(Platform.operatingSystem),
    );
  }
}
