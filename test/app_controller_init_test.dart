/// AppController 启动加载测试（issue #12：关闭软件后重新打开，保存的设置丢失）。
///
/// 根因：SettingsService.load() 磁盘读回设置后，_init() 只做了
/// `state.copyWith(settingsLoaded: true)`，没有把 settingsService.settings
/// 同步进 state.settings。UI 全部经
/// `appControllerProvider.select((s) => s.settings)` 读取，于是重启后
/// 设置页/主页看到的是 AppState() 构造的默认空值——"保存的设置丢失"。
/// 连带隐患：notificationService.init() / 热键 / 监控任一环抛异常（如无
/// 显示环境、通知插件缺失），_init 中断，settingsLoaded 永远不置位。
///
/// 契约（修复后）：
/// 1. load() 完成后 state.settings 必须等于磁盘读回的设置；
/// 2. 运行时环节（通知/热键/监控/自启）任一失败不阻断 settingsLoaded
///    置位与 settings 同步。
library;

import 'dart:io';

import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 应用支持目录可控的 fake（与 settings_service_test.dart 同款）
class _FakePathProvider extends PathProviderPlatform {
  String supportDir;

  _FakePathProvider(this.supportDir);

  @override
  Future<String?> getApplicationSupportPath() async => supportDir;
}

/// 通知初始化可控的 fake：测试环境无插件，init 直接成功
class _NoopNotificationService extends NotificationService {
  @override
  Future<void> init() async {}
}

/// 走真实 _init() 启动流程的 controller：SettingsService 可注入（指向临时
/// 目录），运行时重载 hooks 由测试控制，不触 FRB / 系统插件。
class _InitController extends AppController {
  _InitController(this._injected, {this.failHotkey = false})
      : notificationNoop = true;

  final SettingsService _injected;
  final bool failHotkey;
  final bool notificationNoop;

  @override
  AppState build() {
    settingsService = _injected;
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
    notificationService = _NoopNotificationService();
    updateConfig = UpdateConfig.fromEnvironment();
    updateService = UpdateService(config: updateConfig);
    reloadHotkey = failHotkey
        ? () async => throw StateError('无显示环境：热键注册失败')
        : () async {};
    reloadWatcher = () async {};
    reloadAutoLaunch = (_) async {};
    collectService.tokenProvider = (id) => settingsService.getToken(id);

    initForTest();
    return AppState();
  }
}

/// 等待 predicate 成立（_init 是 fire-and-forget，轮询等它跑完）
Future<void> waitFor(bool Function() predicate, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：$reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;
  late Directory logs;
  late Directory support;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daymark_init_test_');
    logs = Directory('${tmp.path}/logs')..createSync();
    support = Directory('${tmp.path}/support')..createSync();
    home = Directory('${tmp.path}/home')..createSync();
    PathProviderPlatform.instance = _FakePathProvider(support.path);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  SettingsService newService() => SettingsService(
        storage: const FlutterSecureStorage(),
        homeDirProvider: () async => home.path,
      );

  ProviderContainer makeContainer(AppController Function() create) {
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(create)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('启动加载（issue #12）', () {
    test('上次保存的设置重启后必须回到 state.settings（复现：修复前为默认空值）', () async {
      // 上一次会话：用户配置并保存
      final before = newService();
      before.settings = AppSettings(
        logRoot: logs.path,
        authorName: '张三',
        timezone: '+09:00',
        watchDirs: ['/tmp/watch'],
      );
      await before.save();

      // 本次会话：全新 controller 走真实 _init 启动流程
      final container = makeContainer(() => _InitController(newService()));
      await waitFor(
        () => container.read(appControllerProvider).settingsLoaded,
        'settingsLoaded 应置位',
      );

      final state = container.read(appControllerProvider);
      expect(
        state.settings.logRoot,
        logs.path,
        reason: '重启后日志根目录必须恢复（修复前 state.settings 停留在默认空值，'
            '设置页显示为空——"保存的设置丢失"）',
      );
      expect(state.settings.authorName, '张三');
      expect(state.settings.timezone, '+09:00');
      expect(state.settings.watchDirs, ['/tmp/watch']);
    });

    test('运行时环节（热键）失败时，settingsLoaded 仍置位且设置已同步', () async {
      final before = newService();
      before.settings = AppSettings(logRoot: logs.path, authorName: '李四');
      await before.save();

      // 热键注册抛异常（无显示环境），修复前 _init 中断、settingsLoaded 不置位
      final container =
          makeContainer(() => _InitController(newService(), failHotkey: true));
      await waitFor(
        () => container.read(appControllerProvider).settingsLoaded,
        '热键失败不应挡住 settingsLoaded 置位',
      );

      final state = container.read(appControllerProvider);
      expect(state.settings.logRoot, logs.path);
      expect(state.settings.authorName, '李四');
    });
  });
}
