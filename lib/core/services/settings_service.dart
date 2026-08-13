/// 设置服务（DESIGN.md §5.8）：settings.json 读写 + token 密钥库。
///
/// - 主配置存 `<logRoot>/.daymark/settings.json`（设计文档目录结构）
/// - 镜像两处：应用支持目录的引导文件 + 用户主目录稳定镜像
///   `~/.daymark/settings.json`（issue #10：应用支持目录是平台元数据派生的
///   不稳定路径——Linux 依赖可执行文件名/DBus 应用 ID、macOS 依赖 bundle id，
///   软件更新后解析结果可能漂移，主目录镜像作为找回 logRoot 的兜底）
/// - macOS 兼容（issue #10 第二轮）：App Sandbox 下主目录不可写（镜像写失败
///   不阻断保存），取消沙盒后从旧容器残留 bootstrap 迁移找回设置
/// - token 一律不落 settings.json：flutter_secure_storage（Keychain/libsecret）
///   不可用时降级到 `<logRoot>/.daymark/.secrets.json`（600 权限）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
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
    // 依次尝试各找回来源，取第一个 logRoot 非空的来源——logRoot 是定位主配置的
    // 唯一钥匙，只含默认值的来源若挡住后续来源会再次丢设置（issue #10 第二轮）
    AppSettings? fallback;
    for (final path in await _recoveryCandidates()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final parsed = AppSettings.fromJson(json);
        fallback = parsed;
        if (parsed.logRoot.isNotEmpty) break;
      } catch (_) {
        // 损坏则继续尝试其他来源
      }
    }
    if (fallback != null) settings = fallback;
    // 主配置（logRoot 就绪后）
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

  /// 找回候选路径（按优先级）：
  /// 1. 应用支持目录 bootstrap（macOS 沙盒下实际落在容器内）
  /// 2. 用户主目录稳定镜像 ~/.daymark/settings.json
  /// 3. macOS 旧沙盒容器残留（取消沙盒后首次启动的迁移来源，issue #10 第二轮）
  Future<List<String>> _recoveryCandidates() async {
    final candidates = <String>[];
    try {
      final supportDir = await getApplicationSupportDirectory();
      candidates.add('${supportDir.path}/settings.json');
    } catch (_) {}
    final mirrorPath = await _stableMirrorPath();
    if (mirrorPath != null) candidates.add(mirrorPath);
    final home = await _homeDir();
    if (home.isNotEmpty) {
      candidates.addAll(_legacyContainerPaths(home));
    }
    return candidates;
  }

  /// macOS App Sandbox 旧容器的 bootstrap 残留路径。bundle id 与
  /// macos/Runner/Configs/AppInfo.xcconfig 的 PRODUCT_BUNDLE_IDENTIFIER 一致；
  /// 路径 = 沙盒容器根 + 容器内应用支持目录，path_provider 追加 bundle id
  /// 与否两个版本都试。非 macOS 平台该路径不存在，exists() 检查自然跳过。
  List<String> _legacyContainerPaths(String home) {
    const bundleId = 'com.example.daymark';
    final base =
        '$home/Library/Containers/$bundleId/Data/Library/Application Support';
    return [
      '$base/$bundleId/settings.json',
      '$base/settings.json',
    ];
  }

  Future<void> save() async {
    final json = jsonEncode(settings.toJson());
    // 主位置
    final main = File(await _mainPath());
    await main.parent.create(recursive: true);
    await main.writeAsString(json);
    // 主目录稳定镜像（issue #10）：写失败不阻断保存——macOS App Sandbox 下
    // 主目录不可写（issue #10 第二轮），bootstrap 仍是可用的找回来源
    final mirrorPath = await _stableMirrorPath();
    if (mirrorPath != null) {
      try {
        final mirror = File(mirrorPath);
        await mirror.parent.create(recursive: true);
        await mirror.writeAsString(json);
      } catch (e) {
        debugPrint('[daymark] settings mirror write failed: $e');
      }
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
