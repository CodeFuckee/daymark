/// AppController.addExcludePattern 单元测试（issue #18：本地文件变更列表
/// 每条记录右侧按钮快捷添加排除项）。
///
/// 契约（修复前不存在该方法）：
/// 1. 正常路径：追加进 excludePatterns、持久化、state 更新，返回成功提示；
/// 2. 已命中现有排除规则（子串匹配，与 Rust is_excluded 一致）的路径
///    不再重复添加，返回"已在排除规则内"提示；
/// 3. 空路径 / 纯空白路径直接忽略，不写设置；
/// 4. 连续添加不同路径互不干扰；重复添加同一路径不产生重复条目；
/// 5. 持久化失败异常冒泡给调用方（UI 显示失败提示）。
library;

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
import 'package:flutter_test/flutter_test.dart';

/// 无 IO 的 SettingsService：save() 只记录，不写盘
class _FakeSettingsService extends SettingsService {
  final List<AppSettings> saved = [];

  _FakeSettingsService({super.initial});

  @override
  Future<void> save() async {
    saved.add(settings);
  }
}

/// 运行时重载环节全部 no-op 的 controller（build 不触 FRB/IO）
class _TestController extends AppController {
  _TestController({AppSettings? initial})
      : _initial = initial ?? AppSettings();

  final AppSettings _initial;

  @override
  AppState build() {
    settingsService = _FakeSettingsService(initial: _initial);
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
    notificationService = NotificationService();
    updateConfig = UpdateConfig.fromEnvironment();
    updateService = UpdateService(config: updateConfig);
    reloadHotkey = () async {};
    reloadWatcher = () async {};
    reloadAutoLaunch = (_) async {};
    return AppState(settings: settingsService.settings, settingsLoaded: true);
  }
}

/// save() 直接抛错的 SettingsService
class _FailingSettingsService extends _FakeSettingsService {
  _FailingSettingsService({super.initial});

  @override
  Future<void> save() async {
    throw Exception('disk full');
  }
}

void main() {
  ProviderContainer makeContainer(AppController Function() create) {
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(create)],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> patternsOf(ProviderContainer container) =>
      container.read(appControllerProvider).settings.excludePatterns;

  test('正常路径：文件路径追加进排除规则并持久化，返回成功提示', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;

    final message = await controller.addExcludePattern('/data/报价.xlsx');

    expect(message, '已添加排除项：/data/报价.xlsx');
    expect(patternsOf(container).contains('/data/报价.xlsx'), isTrue,
        reason: '新路径应追加进排除规则');
    // 默认排除规则保留，不被覆盖
    expect(patternsOf(container).contains('.git'), isTrue);
    // 持久化：fake 记录的最后一次保存包含新规则
    final fake = controller.settingsService as _FakeSettingsService;
    expect(fake.saved.last.excludePatterns.contains('/data/报价.xlsx'), isTrue);
  });

  test('已命中现有排除规则的路径不重复添加（子串匹配语义）', () async {
    final container = makeContainer(
      () => _TestController(
        initial: AppSettings(excludePatterns: ['node_modules']),
      ),
    );
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;
    final fake = controller.settingsService as _FakeSettingsService;

    final message =
        await controller.addExcludePattern('/code/proj/node_modules/pkg/a.js');

    expect(message, '该文件已在排除规则内');
    expect(patternsOf(container), ['node_modules'],
        reason: '已命中的路径不应产生新条目');
    expect(fake.saved, isEmpty, reason: '无需保存');
  });

  test('空路径与纯空白路径直接忽略，不写设置', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;
    final fake = controller.settingsService as _FakeSettingsService;

    expect(await controller.addExcludePattern(''), '路径为空，无法添加排除项');
    expect(await controller.addExcludePattern('   '), '路径为空，无法添加排除项');

    expect(fake.saved, isEmpty);
    expect(patternsOf(container).contains(''), isFalse);
  });

  test('重复添加同一路径不产生重复条目', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;

    await controller.addExcludePattern('/data/a.txt');
    final message = await controller.addExcludePattern('/data/a.txt');

    expect(message, '该文件已在排除规则内',
        reason: '精确重复同样命中子串匹配，提示不重复添加');
    expect(
      patternsOf(container).where((p) => p == '/data/a.txt').length,
      1,
    );
  });

  test('连续添加不同路径互不干扰', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;

    await controller.addExcludePattern('/data/a.txt');
    await controller.addExcludePattern('/data/b.txt');

    final patterns = patternsOf(container);
    expect(patterns.contains('/data/a.txt'), isTrue);
    expect(patterns.contains('/data/b.txt'), isTrue);
  });

  test('超长路径与含特殊字符路径均可正常添加', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;

    final longPath = '/${List.filled(50, 'dir').join('/')}/文件 (副本).txt';
    final message = await controller.addExcludePattern(longPath);

    expect(message, '已添加排除项：$longPath');
    expect(patternsOf(container).contains(longPath), isTrue);
  });

  test('持久化失败异常冒泡给调用方', () async {
    final container = makeContainer(_TestController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _TestController;
    controller.settingsService = _FailingSettingsService(
        initial: settingsOf(container));

    await expectLater(
      controller.addExcludePattern('/data/a.txt'),
      throwsA(isA<Exception>()),
    );
  });
}

/// 当前 state 里的设置（失败用例初始化用）
AppSettings settingsOf(ProviderContainer container) =>
    container.read(appControllerProvider).settings;
