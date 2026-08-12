/// 设置服务（DESIGN.md §5.8）：settings.json 读写 + token 密钥库。
///
/// - 主配置存 `<logRoot>/.daymark/settings.json`（设计文档目录结构）
/// - logRoot 未配置时用应用支持目录的引导文件；logRoot 确定后镜像同步，
///   保证下次启动能找回 logRoot
/// - token 一律不落 settings.json：flutter_secure_storage（Keychain/libsecret）
///   不可用时降级到 `<logRoot>/.daymark/.secrets.json`（600 权限）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/settings.dart';
import '../util/markdown_util.dart';

class SettingsService {
  final FlutterSecureStorage _storage;
  AppSettings settings;

  SettingsService({FlutterSecureStorage? storage, AppSettings? initial})
      : _storage = storage ?? const FlutterSecureStorage(),
        settings = initial ?? AppSettings.defaults();

  /// 主配置路径（logRoot 未配置时用应用支持目录）
  Future<String> _mainPath() async {
    if (settings.logRoot.isNotEmpty) {
      return settingsPath(settings.logRoot);
    }
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/settings.json';
  }

  Future<void> load() async {
    // 1. 引导文件：找回上次的 logRoot
    final supportDir = await getApplicationSupportDirectory();
    final bootstrap = File('${supportDir.path}/settings.json');
    if (await bootstrap.exists()) {
      try {
        final json = jsonDecode(await bootstrap.readAsString()) as Map<String, dynamic>;
        settings = AppSettings.fromJson(json);
      } catch (_) {
        // 损坏则用默认值
      }
    }
    // 2. 主配置（logRoot 就绪后）
    final main = File(await _mainPath());
    if (await main.exists()) {
      try {
        final json = jsonDecode(await main.readAsString()) as Map<String, dynamic>;
        settings = AppSettings.fromJson(json);
      } catch (_) {
        // 主配置损坏：保留引导文件读到的值
      }
    }
  }

  Future<void> save() async {
    final json = jsonEncode(settings.toJson());
    // 主位置
    final main = File(await _mainPath());
    await main.parent.create(recursive: true);
    await main.writeAsString(json);
    // 引导镜像（应用目录）
    final supportDir = await getApplicationSupportDirectory();
    final bootstrap = File('${supportDir.path}/settings.json');
    await bootstrap.parent.create(recursive: true);
    await bootstrap.writeAsString(json);
  }

  // ─────────────────────────── token（密钥库） ───────────────────────────

  static const _tokenKeyPrefix = 'daymark.token.';

  /// 读取 token：密钥库优先，失败降级本地文件
  Future<String?> getToken(String instanceId) async {
    try {
      return await _storage.read(key: '$_tokenKeyPrefix$instanceId');
    } catch (_) {
      return _fileTokenFallback().then((map) => map[instanceId]);
    }
  }

  Future<void> setToken(String instanceId, String token) async {
    try {
      await _storage.write(key: '$_tokenKeyPrefix$instanceId', value: token);
    } catch (_) {
      final map = await _fileTokenFallback();
      map[instanceId] = token;
      await _writeFileTokens(map);
    }
  }

  Future<void> deleteToken(String instanceId) async {
    try {
      await _storage.delete(key: '$_tokenKeyPrefix$instanceId');
    } catch (_) {
      final map = await _fileTokenFallback();
      map.remove(instanceId);
      await _writeFileTokens(map);
    }
  }

  Future<Map<String, String>> _fileTokenFallback() async {
    try {
      final file = File('${await _secretsPath()}/.secrets.json');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return json.map((k, v) => MapEntry(k, v as String));
      }
    } catch (_) {}
    return {};
  }

  Future<void> _writeFileTokens(Map<String, String> map) async {
    final dir = await _secretsPath();
    final file = File('$dir/.secrets.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(map));
    // 600 权限
    await Process.run('chmod', ['600', file.path]);
  }

  Future<String> _secretsPath() async {
    if (settings.logRoot.isNotEmpty) {
      return '${settings.logRoot}/.daymark';
    }
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }
}
