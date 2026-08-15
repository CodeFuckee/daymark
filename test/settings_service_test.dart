/// SettingsService 持久化测试（issue #10：保存的设置在软件更新之后丢失）。
///
/// 根因分析：设置的唯一"找回线索"（bootstrap 镜像）存放在
/// `getApplicationSupportDirectory()`，该路径是平台元数据派生的不稳定位置：
/// Linux 依赖 GApplication ID（libgio 可用性）或可执行文件名（开发构建
/// `daymark` vs AppImage `daymark-linux-x86_64.AppImage`），macOS 依赖
/// bundle id——软件更新前后解析结果可能漂移。而主配置
/// `<logRoot>/.daymark/settings.json` 位置稳定却"找不回来"：load() 需要先
/// 知道 logRoot 才能定位主配置（鸡生蛋依赖），bootstrap 一丢，logRoot 永久
/// 丢失，设置页"日志根目录"显示为空。
///
/// 契约（修复后）：
/// 1. save() 同时写三处：主配置（logRoot 下）+ 用户主目录稳定镜像 +
///    应用支持目录 bootstrap；
/// 2. load() 按 bootstrap → 稳定镜像 → 主配置顺序兜底，任一存在即可
///    找回全部设置（主配置存在时优先以它为准）；
/// 3. 全部缺失时用默认值，不崩溃。
library;

import 'dart:convert';
import 'dart:io';

import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 应用支持目录可控的 fake：模拟更新前后支持目录解析结果漂移
class _FakePathProvider extends PathProviderPlatform {
  String supportDir;

  _FakePathProvider(this.supportDir);

  @override
  Future<String?> getApplicationSupportPath() async => supportDir;
}

void main() {
  late Directory tmp;
  late Directory logs;
  late Directory supportA;
  late Directory supportB;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daymark_settings_test_');
    logs = Directory('${tmp.path}/logs')..createSync();
    supportA = Directory('${tmp.path}/support-a')..createSync();
    supportB = Directory('${tmp.path}/support-b')..createSync();
    home = Directory('${tmp.path}/home')..createSync();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// 全局替换应用支持目录解析（flutter_test 环境无真实 path_provider 注册；
  /// 每个用例 setUp 都会重新设置，无需恢复）
  void fakeSupportDir(String path) {
    PathProviderPlatform.instance = _FakePathProvider(path);
  }

  SettingsService newService() => SettingsService(
        storage: const FlutterSecureStorage(),
        homeDirProvider: () async => home.path,
      );

  group('软件更新后设置找回（issue #10）', () {
    test('支持目录漂移（bootstrap 丢失）时，load() 必须找回 logRoot', () async {
      // 更新前：支持目录 A 中保存设置
      fakeSupportDir(supportA.path);
      final before = newService();
      before.settings = AppSettings(
        logRoot: logs.path,
        authorName: '张三',
        timezone: '+09:00',
      );
      await before.save();

      // 主配置、主目录稳定镜像、旧 bootstrap 三处均已落盘
      expect(
        File('${logs.path}/.daymark/settings.json').existsSync(),
        isTrue,
        reason: '主配置应写入 <logRoot>/.daymark/settings.json',
      );
      expect(
        File('${home.path}/.daymark/settings.json').existsSync(),
        isTrue,
        reason: '稳定镜像应写入用户主目录 ~/.daymark/settings.json（issue #10）',
      );
      expect(
        File('${supportA.path}/settings.json').existsSync(),
        isTrue,
        reason: 'bootstrap 应写入应用支持目录',
      );

      // 软件更新后：支持目录解析结果漂移到 B（bootstrap"丢失"），
      // 主配置仍在日志根目录下完好无损
      fakeSupportDir(supportB.path);
      final after = newService();
      await after.load();

      expect(
        after.settings.logRoot,
        logs.path,
        reason: '更新后必须找回日志根目录，而不是显示为空要求重新设置（issue #10）',
      );
      expect(after.settings.authorName, '张三');
      expect(after.settings.timezone, '+09:00');
    });

    test('支持目录与主目录镜像都缺失时用默认值（不崩溃）', () async {
      // 三个来源全无：load() 不抛异常，logRoot 为空（首次启动）
      fakeSupportDir(supportB.path);
      final service = newService();
      await service.load();
      expect(service.settings.logRoot, '');
    });

    test('主目录不可得（HOME/USERPROFILE 均为空）时保存加载降级为旧行为，不崩溃', () async {
      fakeSupportDir(supportA.path);
      final service = SettingsService(
        storage: const FlutterSecureStorage(),
        homeDirProvider: () async => '',
      );
      service.settings = AppSettings(logRoot: logs.path, authorName: '赵六');
      await service.save();

      final reloaded = SettingsService(
        storage: const FlutterSecureStorage(),
        homeDirProvider: () async => '',
      );
      await reloaded.load();
      // 支持目录未漂移 → 仍能从 bootstrap 找回
      expect(reloaded.settings.logRoot, logs.path);
      expect(reloaded.settings.authorName, '赵六');
    });
  });

  group('macOS 沙盒与镜像容错（issue #10 第二轮）', () {
    test('镜像写入失败（如 macOS 沙盒禁写主目录）时不阻断保存，bootstrap 仍落盘', () async {
      fakeSupportDir(supportA.path);
      // 主目录"不可写"：home 路径的父级是普通文件 → create(recursive) 必然失败，
      // 等价于 App Sandbox 下 ~/.daymark 被拒写（Operation not permitted）
      final blocker = File('${tmp.path}/home-blocker')..writeAsStringSync('x');
      final service = SettingsService(
        storage: const FlutterSecureStorage(),
        homeDirProvider: () async => '${blocker.path}/fake-home',
      );
      service.settings = AppSettings(logRoot: logs.path, authorName: '沙盒用户');
      // 修复前：镜像写入抛 FileSystemException，保存中断、bootstrap 未落盘
      await service.save();

      expect(File('${logs.path}/.daymark/settings.json').existsSync(), isTrue);
      final bootstrap = File('${supportA.path}/settings.json');
      expect(
        bootstrap.existsSync(),
        isTrue,
        reason: '镜像写失败不应阻断 bootstrap 落盘（macOS 沙盒下唯一可用的找回来源）',
      );
      final json = jsonDecode(bootstrap.readAsStringSync()) as Map<String, dynamic>;
      expect(json['logRoot'], logs.path);
    });

    test('macOS 旧沙盒容器残留 bootstrap 可作为迁移来源找回设置', () async {
      fakeSupportDir(supportB.path); // 新版本的真实支持目录（尚无文件）
      // 旧版本（App Sandbox）的 bootstrap 实际落在容器内：
      final legacy = File(
        '${home.path}/Library/Containers/com.example.daymark/Data/'
        'Library/Application Support/com.example.daymark/settings.json',
      )..createSync(recursive: true);
      legacy.writeAsStringSync(jsonEncode({
        'logRoot': logs.path,
        'authorName': '容器旧数据',
      }));

      final service = newService();
      await service.load();
      expect(
        service.settings.logRoot,
        logs.path,
        reason: '取消沙盒后第一次启动，应从旧容器残留迁移找回 logRoot',
      );
      expect(service.settings.authorName, '容器旧数据');
    });

    test('bootstrap 只含默认值（logRoot 空）时继续尝试镜像，logRoot 非空优先', () async {
      fakeSupportDir(supportA.path);
      // 历史遗留：bootstrap 只存了默认值（用户早期未设 logRoot 时的保存）
      File('${supportA.path}/settings.json').writeAsStringSync(
          jsonEncode(AppSettings().toJson()));
      // 镜像里才有真正的 logRoot
      File('${home.path}/.daymark/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(
            AppSettings(logRoot: logs.path, authorName: '镜像数据').toJson()));

      final service = newService();
      await service.load();
      expect(
        service.settings.logRoot,
        logs.path,
        reason: 'logRoot 为空的来源不应挡住镜像（修复前 bootstrap 存在即不再尝试镜像）',
      );
      expect(service.settings.authorName, '镜像数据');
    });
  });

  group('正常保存/加载', () {
    test('支持目录不变时 save → load 完整往返', () async {
      fakeSupportDir(supportA.path);
      final service = newService();
      service.settings = AppSettings(
        logRoot: logs.path,
        authorName: '李四',
        timezone: '+08:00',
        watchDirs: ['/tmp/watch'],
      );
      await service.save();

      final reloaded = newService();
      await reloaded.load();
      expect(reloaded.settings.logRoot, logs.path);
      expect(reloaded.settings.authorName, '李四');
      expect(reloaded.settings.timezone, '+08:00');
      expect(reloaded.settings.watchDirs, ['/tmp/watch']);
    });

    test('主配置损坏时回退镜像中的值（不丢设置）', () async {
      fakeSupportDir(supportA.path);
      final service = newService();
      service.settings = AppSettings(logRoot: logs.path, authorName: '王五');
      await service.save();
      // 主配置写坏（非 JSON）
      File('${logs.path}/.daymark/settings.json').writeAsStringSync('{broken');

      final reloaded = newService();
      await reloaded.load();
      expect(reloaded.settings.logRoot, logs.path);
      expect(reloaded.settings.authorName, '王五');
    });
  });

  group('token 密钥库/文件对称降级（issue #20 第三轮）', () {
    /// 可控密钥库 fake：读/写/删行为按开关注入，内存 map 模拟密钥库内容。
    /// 修复契约：setToken 两处都写、getToken 密钥库未命中（null 或异常）都
    /// 降级读文件、deleteToken 两处都删——密钥库「读成功但 key 不存在」时
    /// 不再静默丢失文件副本中的 token（「未拉取到任何提交作者」的根因之一）。
    test('密钥库读成功但无该 key（返回 null）→ 降级文件取回 token', () async {
      fakeSupportDir(supportA.path);
      final storage = _FakeSecureStorage();
      final service = SettingsService(
        storage: storage,
        homeDirProvider: () async => home.path,
      );
      service.settings = AppSettings(logRoot: logs.path);
      // 密钥库写入失败 → token 落入文件副本
      storage.writeThrows = true;
      await service.setToken('inst-1', 'glpat-file-fallback');

      // 密钥库恢复可用但 key 不存在（read 返回 null）：修复前直接返回 null、
      // 不降级文件 → token 丢失
      storage.writeThrows = false;
      expect(
        await service.getToken('inst-1'),
        'glpat-file-fallback',
        reason: '密钥库未命中必须降级读文件副本（与 setToken 的降级对称）',
      );
    });

    test('密钥库读抛异常 → 降级文件取回 token（既有行为回归保护）', () async {
      fakeSupportDir(supportA.path);
      final storage = _FakeSecureStorage();
      final service = SettingsService(
        storage: storage,
        homeDirProvider: () async => home.path,
      );
      service.settings = AppSettings(logRoot: logs.path);
      storage.writeThrows = true;
      await service.setToken('inst-1', 'glpat-file-fallback');

      storage.readThrows = true;
      expect(await service.getToken('inst-1'), 'glpat-file-fallback');
    });

    test('setToken 密钥库成功时文件副本同步写入（密钥库后来不可用仍能读到新值）', () async {
      fakeSupportDir(supportA.path);
      final storage = _FakeSecureStorage();
      final service = SettingsService(
        storage: storage,
        homeDirProvider: () async => home.path,
      );
      service.settings = AppSettings(logRoot: logs.path);
      // 第一次：密钥库失败 → 文件副本为旧值
      storage.writeThrows = true;
      await service.setToken('inst-1', 'glpat-old');
      // 第二次：密钥库成功 → 文件副本必须同步为新值
      storage.writeThrows = false;
      await service.setToken('inst-1', 'glpat-new');

      // 密钥库整体不可用 → 降级文件读到的必须是新值而非旧值
      storage.readThrows = true;
      expect(await service.getToken('inst-1'), 'glpat-new');
    });

    test('deleteToken 两处都删：密钥库删成功后降级文件不再读到旧 token', () async {
      fakeSupportDir(supportA.path);
      final storage = _FakeSecureStorage();
      final service = SettingsService(
        storage: storage,
        homeDirProvider: () async => home.path,
      );
      service.settings = AppSettings(logRoot: logs.path);
      // 密钥库失败时写入 → 文件副本有值
      storage.writeThrows = true;
      await service.setToken('inst-1', 'glpat-to-delete');

      // 密钥库恢复后删除：修复前只删密钥库（key 本就不存在），
      // getToken 降级文件仍读到旧 token
      storage.writeThrows = false;
      await service.deleteToken('inst-1');
      expect(await service.getToken('inst-1'), isNull);
    });

    test('密钥库正常时 read/write/delete 走密钥库（有值直接返回不查文件）', () async {
      fakeSupportDir(supportA.path);
      final storage = _FakeSecureStorage();
      final service = SettingsService(
        storage: storage,
        homeDirProvider: () async => home.path,
      );
      service.settings = AppSettings(logRoot: logs.path);
      await service.setToken('inst-1', 'glpat-keystore');
      expect(storage.memory['daymark.token.inst-1'], 'glpat-keystore');
      expect(await service.getToken('inst-1'), 'glpat-keystore');
      await service.deleteToken('inst-1');
      expect(await service.getToken('inst-1'), isNull);
    });
  });
}

/// 可控的密钥库 fake（读/写/删行为可按开关注入，内容存内存 map）
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> memory = {};
  bool readThrows = false;
  bool writeThrows = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (readThrows) throw Exception('keystore unavailable');
    return memory[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (writeThrows) throw Exception('keystore unavailable');
    if (value == null) {
      memory.remove(key);
    } else {
      memory[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (writeThrows) throw Exception('keystore unavailable');
    memory.remove(key);
  }
}
