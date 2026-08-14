/// AppController.saveSettings 行为测试（issue #6：保存设置卡在"保存中…"）。
///
/// 根因：saveSettings 曾同步等待「热键重载 + 目录监控重启 + 自启应用」整条
/// 链路；任一环节挂起（大目录递归 watch、无显示环境、网络盘 IO 等），UI 就
/// 永远停在"保存中…"。修复后契约：
/// 1. saveSettings 只同步等待持久化（写 settings.json），完成后立即返回；
/// 2. 运行时重载（热键/监控/自启）在后台串行执行，挂起或异常都不影响保存；
/// 3. 持久化失败必须抛给调用方（设置页显示"保存失败"）。
library;

import 'dart:async';
import 'dart:io';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
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

/// 重载环节全部可挂起的 controller：saveSettings 用真实实现，
/// 仅把运行时重载 hooks 换成 Completer 控制（build 不触 FRB/IO）
class _GateController extends AppController {
  final hotkeyGate = Completer<void>();
  final watcherGate = Completer<void>();
  final autoLaunchGate = Completer<void>();

  _GateController({AppSettings? initial})
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
    reloadHotkey = () => hotkeyGate.future;
    reloadWatcher = () => watcherGate.future;
    reloadAutoLaunch = (_) => autoLaunchGate.future;
    return AppState(settings: settingsService.settings, settingsLoaded: true);
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

  test('重载环节全部挂起时，saveSettings 也必须在超时内完成（issue #6 复现）', () async {
    final container = makeContainer(_GateController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _GateController;

    final next = AppSettings(authorName: '张三');
    // 修复前：saveSettings 串行 await 重载 → 这里永远等不到 → 超时失败
    await controller.saveSettings(next).timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('保存被运行时重载阻塞：一直卡在"保存中…"（issue #6）'),
        );

    // 持久化已完成、状态已更新，即使重载仍挂起
    final fake = controller.settingsService as _FakeSettingsService;
    expect(fake.saved, [next]);
    expect(container.read(appControllerProvider).settings.authorName, '张三');
    expect(controller.reloadHotkey, isNotNull);
    expect(controller.hotkeyGate.isCompleted, isFalse);
    expect(controller.watcherGate.isCompleted, isFalse);
    expect(controller.autoLaunchGate.isCompleted, isFalse);
  });

  test('后台重载异常被吞掉，不影响保存结果', () async {
    final container = makeContainer(_GateController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _GateController;
    // 三个重载环节全部抛异常
    controller.reloadHotkey = () async => throw StateError('hotkey boom');
    controller.reloadWatcher = () async => throw StateError('watcher boom');
    controller.reloadAutoLaunch =
        (_) async => throw StateError('autolaunch boom');

    final next = AppSettings(authorName: '李四');
    await controller.saveSettings(next).timeout(const Duration(seconds: 2));
    // 等后台链跑完，确认异常不外泄
    await controller.reloadDoneForTest().timeout(const Duration(seconds: 2));

    final fake = controller.settingsService as _FakeSettingsService;
    expect(fake.saved, [next]);
    expect(container.read(appControllerProvider).settings.authorName, '李四');
  });

  test('移除监控目录时，该目录的文件变更记录从全部日期缓存清除（issue #14 第二轮）',
      () async {
    final tmp = await Directory.systemTemp.createTemp('daymark_save_');
    addTearDown(() => tmp.delete(recursive: true));
    final logRoot = '${tmp.path}/logs';
    final dirA = '${tmp.path}/A';
    final dirB = '${tmp.path}/B';

    final container = makeContainer(
      () => _GateController(
        initial: AppSettings(logRoot: logRoot, watchDirs: [dirA, dirB]),
      ),
    );
    final controller =
        container.read(appControllerProvider.notifier) as _GateController;
    // 放行三个重载 gate，让后台链顺畅跑完
    controller.hotkeyGate.complete();
    controller.watcherGate.complete();
    controller.autoLaunchGate.complete();

    // 预置：当日缓存里有目录 A（将被移除）与目录 B 的记录
    final a = FileChange(
        path: '$dirA/a.txt', mtime: DateTime.now(), size: 1, kind: 'modify');
    final b = FileChange(
        path: '$dirB/b.txt', mtime: DateTime.now(), size: 1, kind: 'modify');
    await saveMaterialCache(logRoot,
        DailyMaterial(date: dayStart(DateTime.now()), fileChanges: [a, b]));

    // 用户在设置里删除监控目录 A 并保存
    await controller
        .saveSettings(AppSettings(logRoot: logRoot, watchDirs: [dirB]));
    await controller.reloadDoneForTest().timeout(const Duration(seconds: 2));

    final cached = await loadMaterialCache(logRoot, dayStart(DateTime.now()));
    expect(cached!.fileChanges.map((f) => f.path), ['$dirB/b.txt'],
        reason: '移除的监控目录 A 的记录应被清除，仍监控的目录 B 记录保留（issue #14 第二轮）');
  });

  test('持久化失败必须抛给调用方（设置页显示"保存失败"）', () async {
    final container = makeContainer(_GateController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _GateController;
    (controller.settingsService as _FakeSettingsService).saved.clear();
    // 覆写 save 抛错
    final failing = _FailingSettingsService();
    controller.settingsService = failing;
    await expectLater(
      controller.saveSettings(AppSettings(authorName: '王五')),
      throwsA(isA<Exception>()),
    );
  });

  test('连续两次保存的重载串行执行（先 save 的重载先跑完）', () async {
    final container = makeContainer(_GateController.new);
    final controller =
        container.read(appControllerProvider.notifier) as _GateController;
    final order = <String>[];
    controller.reloadHotkey = () async {
      order.add('h1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      order.add('h1done');
    };
    controller.reloadWatcher = () async {
      order.add('w1');
    };
    controller.reloadAutoLaunch = (_) async {
      order.add('a1');
    };

    await controller.saveSettings(AppSettings(authorName: 'A'));
    await controller.saveSettings(AppSettings(authorName: 'B'));
    await controller.reloadDoneForTest().timeout(const Duration(seconds: 2));

    expect(order, ['h1', 'h1done', 'w1', 'a1', 'h1', 'h1done', 'w1', 'a1']);
  });
}

/// save() 直接抛错的 SettingsService
class _FailingSettingsService extends _FakeSettingsService {
  @override
  Future<void> save() async {
    throw Exception('disk full');
  }
}
