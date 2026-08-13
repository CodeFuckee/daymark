/// 自动更新服务（issue #5）：版本检测 → 后台下载 → sha256 校验 → 待安装 manifest。
///
/// - 检测：逐源查询最新 release（GitLab `/projects/:id/releases`、
///   GitHub `/repos/:repo/releases/latest`），取带本平台资产且版本最高者
/// - 下载：dio 流式下载到 `<支持目录>/update/<资产名>.part`，校验通过后
///   原子 rename 并写 manifest.json（重启时安装的依据）
/// - 容错：单源 API 异常/无平台资产均跳过；校验信息缺失则跳过校验
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'update_config.dart';
import 'update_models.dart';
import 'update_version.dart';

/// 下载文件 sha256 校验失败
class UpdateChecksumException implements Exception {
  final String message;
  UpdateChecksumException(this.message);

  @override
  String toString() => 'UpdateChecksumException: $message';
}

/// 文件 sha256（crypto 包，流式计算避免大文件占内存）
Future<String> sha256File(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

class UpdateService {
  final UpdateConfig config;
  final Dio _dio;
  /// 支持目录（测试注入；应用内默认 getApplicationSupportDirectory）
  final String? supportDir;

  UpdateService({
    required this.config,
    Dio? dio,
    this.supportDir,
  }) : _dio = dio ?? Dio();

  /// 更新目录：`<支持目录>/update/`
  Future<String> updateDir() async {
    final base = supportDir ?? (await getApplicationSupportDirectory()).path;
    return '$base/update';
  }

  // ─────────────────────────── 版本检测 ───────────────────────────

  /// 检查更新：有新版本返回 [UpdateInfo]，否则 null。
  /// 每个源独立容错（网络错误/解析失败跳过），多源取版本最高者。
  Future<UpdateInfo?> check() async {
    if (!config.enabled) return null;
    UpdateInfo? best;
    for (final source in config.sources) {
      try {
        final info = source.type == 'gitlab'
            ? await _checkGitlab(source)
            : await _checkGithub(source);
        if (info != null &&
            (best == null ||
                compareVersions(info.version, best.version) > 0)) {
          best = info;
        }
      } catch (e) {
        debugPrint('[daymark] update check failed (${source.type}): $e');
      }
    }
    if (best == null) return null;
    // 最新版本不高于当前版本 → 无更新
    if (compareVersions(best.version, config.appVersion!) <= 0) return null;
    return best;
  }

  /// GitLab：releases 列表（新→旧）中首个含本平台资产的 release
  Future<UpdateInfo?> _checkGitlab(UpdateSource source) async {
    final resp = await _dio.get<dynamic>(
      '${source.api}/projects/${source.project}/releases',
      queryParameters: {
        'per_page': 5,
        'order_by': 'released_at',
        'sort': 'desc',
      },
      options: Options(headers: {
        if (source.token != null && source.token!.isNotEmpty)
          'PRIVATE-TOKEN': source.token,
      }),
    );
    final releases = resp.data as List? ?? [];
    for (final release in releases) {
      final info = _gitlabReleaseInfo(release as Map<String, dynamic>, source);
      if (info != null) return info;
    }
    return null;
  }

  UpdateInfo? _gitlabReleaseInfo(Map<String, dynamic> release, UpdateSource source) {
    final tag = release['tag_name'] as String?;
    if (tag == null) return null;
    final links = ((release['assets'] as Map?)?['links'] as List?) ?? [];
    for (final link in links) {
      if (link is! Map) continue;
      if (link['name'] == config.assetName) {
        final url = link['url'] as String?;
        if (url == null || url.isEmpty) continue;
        return UpdateInfo(
          version: stripV(tag),
          tag: tag,
          downloadUrl: url,
          // GitLab 包 sha256 可经 <url>.sha256 端点获取，下载后校验前再取
          sha256: null,
          sourceType: 'gitlab',
        );
      }
    }
    return null;
  }

  /// GitHub：/releases/latest（公开仓库匿名可达），资产 digest 转 sha256
  Future<UpdateInfo?> _checkGithub(UpdateSource source) async {
    final resp = await _dio.get<dynamic>(
      'https://api.github.com/repos/${source.repo}/releases/latest',
    );
    final data = resp.data as Map<String, dynamic>? ?? {};
    final tag = data['tag_name'] as String?;
    if (tag == null) return null;
    final assets = data['assets'] as List? ?? [];
    for (final asset in assets) {
      if (asset is! Map) continue;
      if (asset['name'] != config.assetName) continue;
      final url = asset['browser_download_url'] as String?;
      if (url == null || url.isEmpty) continue;
      String? sha256;
      final digest = asset['digest'] as String?;
      if (digest != null && digest.startsWith('sha256:')) {
        sha256 = digest.substring(7);
      }
      return UpdateInfo(
        version: stripV(tag),
        tag: tag,
        downloadUrl: url,
        sha256: sha256,
        sourceType: 'github',
      );
    }
    return null;
  }

  // ─────────────────────────── 后台下载 ───────────────────────────

  /// 下载更新包：.part 临时文件 → sha256 校验（有期望值时）→ 原子改名 →
  /// 写 manifest.json。失败清理临时文件并抛异常，不留半成品状态。
  Future<UpdateManifest> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = Directory(await updateDir());
    await dir.create(recursive: true);
    final target = File('${dir.path}/${config.assetName}');
    final part = File('${target.path}.part');

    await _dio.download(
      info.downloadUrl,
      part.path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );

    try {
      if (info.sha256 != null && info.sha256!.isNotEmpty) {
        final actual = await sha256File(part.path);
        if (actual.toLowerCase() != info.sha256!.toLowerCase()) {
          throw UpdateChecksumException(
            '下载文件 sha256 校验失败：期望 ${info.sha256}，实际 $actual',
          );
        }
      }
      await part.rename(target.path);
      final manifest = UpdateManifest(
        version: info.version,
        assetName: config.assetName,
        sha256: info.sha256,
        sourceType: info.sourceType,
      );
      await File('${dir.path}/manifest.json')
          .writeAsString(jsonEncode(manifest.toJson()));
      return manifest;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  // ─────────────────────────── 待安装检查 ───────────────────────────

  /// 读取待安装 manifest（重启时安装依据）；缺失/损坏/安装包丢失 → null
  Future<UpdateManifest?> loadManifest() async {
    try {
      final dir = Directory(await updateDir());
      final manifestFile = File('${dir.path}/manifest.json');
      if (!await manifestFile.exists()) return null;
      final manifest = UpdateManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
      );
      if (manifest.version.isEmpty || manifest.assetName.isEmpty) return null;
      final asset = File('${dir.path}/${manifest.assetName}');
      if (!await asset.exists()) return null;
      return manifest;
    } catch (_) {
      return null;
    }
  }

  /// 清除待安装包与 manifest（安装完成后调用，避免重复安装）
  Future<void> clearPending() async {
    try {
      final dir = Directory(await updateDir());
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// 去掉版本 tag 的 v 前缀（容错：无前缀原样返回）
String stripV(String tag) =>
    tag.startsWith('v') ? tag.substring(1) : tag;
