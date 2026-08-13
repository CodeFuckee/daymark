/// 设置服务（DESIGN.md §5.8）：settings.json 读写 + token 密钥库。
///
/// - 主配置存 `<logRoot>/.daymark/settings.json`（设计文档目录结构）
/// - 镜像两处：应用支持目录的引导文件 + 用户主目录稳定镜像
///   `~/.daymark/settings.json`（issue #10：应用支持目录是平台元数据派生的
///   不稳定路径——Linux 依赖可执行文件名/DBus 应用 ID、macOS 依赖 bundle id，
///   软件更新后解析结果可能漂移，主目录镜像作为找回 logRoot 的兜底）
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
  /// 用户主目录提供者（测试注入；null → 环境变量 HOME/USERPROFILE）
  final Future<String> Function()? homeDirProvider;

  SettingsService({
    FlutterSecureStorage? storage,
    AppSettings? initial,
    this.homeDirProvider,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        settings = initial ?? AppSettings.defaults();

  /// 主配置路径（logRoot 未配置时用应用支持目录）
  Future<String> _mainPath() async {
    if (settings.logRoot.isNotEmpty) {
      return settingsPath(settings.logRoot);
    }
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/settings.json';
  }

  /// 用户主目录（账号级稳定路径，不依赖可执行文件名/DBus/bundle id）
  Future<String> _homeDir() async {
    if (homeDirProvider != null) return homeDirProvider!();
    final env = Platform.environment;
    return env['HOME'] ?? env['USERPROFILE'] ?? '';
  }

  /// 稳定镜像路径：`~/.daymark/settings.json`（主目录不可得时为 null）
  Future<String?> _stableMirrorPath() async {
    final home = await _homeDir();
    if (home.isEmpty) return null;
    return '$home/.daymark/settings.json';
  }

  Future<void> load() async {
    // 1. 支持目录引导文件：找回上次的 logRoot
    AppSettings? fallback;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final bootstrap = File('${supportDir.path}/settings.json');
      if (await bootstrap.exists()) {
        try {
          final json =
              jsonDecode(await bootstrap.readAsString()) as Map<String, dynamic>;
          fallback = AppSettings.fromJson(json);
        } catch (_) {
          // 损坏则继续尝试其他来源
        }
      }
    } catch (_) {}
    // 2. 主目录稳定镜像（issue #10）：支持目录漂移时找回设置的兜底
    if (fallback == null) {
      final mirrorPath = await _stableMirrorPath();
      if (mirrorPath != null) {
        final mirror = File(mirrorPath);
        if (await mirror.exists()) {
          try {
            final json =
                jsonDecode(await mirror.readAsString()) as Map<String, dynamic>;
            fallback = AppSettings.fromJson(json);
          } catch (_) {
            // 损坏则用默认值
          }
        }
      }
    }
    if (fallback != null) settings = fallback;
    // 3. 主配置（logRoot 就绪后）
    final main = File(await _mainPath());
    if (await main.exists()) {
      try {
        final json = jsonDecode(await main.readAsString()) as Map<String, dynamic>;
        settings = AppSettings.fromJson(json);
      } catch (_) {
        // 主配置损坏：保留镜像读到的值
      }
    }
  }

  Future<void> save() async {
    final json = jsonEncode(settings.toJson());
    // 主位置
    final main = File(await _mainPath());
    await main.parent.create(recursive: true);
    await main.writeAsString(json);
    // 主目录稳定镜像（issue #10：软件更新后找回设置的兜底）
    final mirrorPath = await _stableMirrorPath();
    if (mirrorPath != null) {
      final mirror = File(mirrorPath);
      await mirror.parent.create(recursive: true);
      await mirror.writeAsString(json);
    }
    // 支持目录引导镜像
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
