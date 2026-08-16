/// 自动更新重启对话框测试（issue #29）：
/// 点击检查更新 → 最新版下载完成 → 自动弹出对话框提示用户重启，
/// 用户可选择「立即重启」或「稍后重启」。
///
/// UI 契约（修复后）：
/// 1. 下载完成（phase 转为 ready）→ 自动弹出重启对话框，含「立即重启」
///    「稍后重启」两个按钮；
/// 2. 「稍后重启」→ 对话框关闭，phase 仍为 ready 不重复弹窗（重建也不弹）；
/// 3. 「立即重启」→ 调用 restartToUpdate；失败时给出错误提示；
/// 4. 下载失败 / 检查更新失败 → 不弹重启对话框；
/// 5. 同一版本再次检查并下载完成 → 再次弹窗（每次下载完成都提示一次）；
/// 6. 下载完成时恢复主窗口模式（随手记录弹窗/托盘隐藏场景下对话框可见）；
/// 7. restartToUpdate 无 manifest → 返回 false 且置 error 状态；
/// 8. 检查更新进行中重复触发 → 防重入，只执行一次；
/// 9. 本地开发构建（更新源未注入）→ 不弹对话框。
library;

import 'dart:async';

import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_models.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/update_restart_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 无 IO 的更新服务：check/download/loadManifest 全由测试注入，不触网络与磁盘。
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this._config) : super(config: _config);

  final UpdateConfig _config;

  /// null → check 返回「无更新」；置为 [Completer] 可挂起模拟慢网络
  Future<UpdateInfo?> Function()? checkImpl;
  /// 下载抛出的异常（模拟下载失败）
  Object? downloadError;
  /// loadManifest 返回值（null → 视为无待安装包）
  UpdateManifest? manifest;
  /// check 被调用次数（防重入断言）
  int checkCallCount = 0;
  /// download 是否被调用（下载完成断言）
  bool downloadCalled = false;

  /// 测试用公开访问的更新信息（防重入用例 gate 完成后注入）
  UpdateInfo get infoForTest => _info;

  UpdateInfo get _info => UpdateInfo(
        version: '0.2.0',
        tag: 'v0.2.0',
        downloadUrl: 'https://g/download/$_config.assetName',
        sourceType: 'gitlab',
      );

  @override
  Future<UpdateInfo?> check() async {
    checkCallCount++;
    return checkImpl != null ? checkImpl!() : _info;
  }

  @override
  Future<UpdateManifest> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    downloadCalled = true;
    onProgress?.call(0.5);
    onProgress?.call(1.0);
    final error = downloadError;
    if (error != null) throw error;
    return manifest ??
        UpdateManifest(
          version: info.version,
          assetName: _config.assetName,
          sourceType: info.sourceType,
        );
  }

  @override
  Future<UpdateManifest?> loadManifest() async => manifest;
}

/// 通知初始化可控的 fake：测试环境无插件，init/show 直接成功
class _NoopNotificationService extends NotificationService {
  @override
  Future<void> init() async {}
}

/// 可控的 fake controller：build 不触 FRB / IO，更新服务走 [_FakeUpdateService]
class _DialogController extends AppController {
  _DialogController({
    this.enabled = true,
    Object? downloadError,
    UpdateManifest? manifest,
    this.restartResult,
  }) : _fake = _FakeUpdateService(
         _config(enabled),
       ) {
    _fake.downloadError = downloadError;
    _fake.manifest = manifest;
  }

  final bool enabled;
  final bool? restartResult;
  final _FakeUpdateService _fake;

  /// restartToUpdate 被调用次数（立即重启断言）
  int restartCalled = 0;
  /// 触发下载完成时是否调用了「恢复主窗口」
  bool? restoredMainWindow;

  static UpdateConfig _config(bool enabled) => UpdateConfig(
        sources: enabled
            ? const [
                UpdateSource.gitlab(
                  api: 'https://g/api/v4',
                  project: 'a%2Fb',
                ),
              ]
            : const [],
        appVersion: '0.1.0',
        assetName: 'daymark-linux-x86_64.AppImage',
      );

  @override
  AppState build() {
    settingsService = SettingsService();
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
    notificationService = _NoopNotificationService();
    updateConfig = _config(enabled);
    updateService = _fake;
    reloadHotkey = () async {};
    reloadWatcher = () async {};
    reloadAutoLaunch = (_) async {};
    // 下载完成恢复主窗口（真实实现由 main.dart 注入 applyWindowMode）
    onWindowModeChanged = (mode) async {
      restoredMainWindow = mode == WindowMode.main;
    };
    return AppState(settings: settingsService.settings, settingsLoaded: true);
  }

  @override
  Future<bool> restartToUpdate() async {
    restartCalled++;
    final result = restartResult;
    if (result != null) {
      if (!result) {
        state = state.copyWith(
          updateStatus: const UpdateStatus.error('测试：无法自动重启'),
        );
      }
      return result;
    }
    return super.restartToUpdate();
  }
}

Widget _wrap(_DialogController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: MaterialApp(
      home: UpdateRestartDialogHost(
        child: const Scaffold(body: Center(child: Text('主界面'))),
      ),
    ),
  );
}

void main() {
  group('下载完成自动弹出重启对话框（issue #29）', () {
    testWidgets('下载完成 → 自动弹出对话框，含「立即重启」「稍后重启」', (tester) async {
      final controller = _DialogController();
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();

      expect(find.text('新版本 v0.2.0 已下载完成'), findsOneWidget,
          reason: '下载完成后应自动弹出重启对话框');
      expect(find.text('立即重启'), findsOneWidget);
      expect(find.text('稍后重启'), findsOneWidget);
      expect(controller._fake.downloadCalled, isTrue);
    });

    testWidgets('「稍后重启」→ 对话框关闭，不重复弹窗（重建也不弹）', (tester) async {
      final controller = _DialogController();
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();
      expect(find.text('立即重启'), findsOneWidget);

      await tester.tap(find.text('稍后重启'));
      await tester.pumpAndSettle();
      expect(find.text('立即重启'), findsNothing, reason: '稍后重启后对话框应关闭');
      expect(find.text('主界面'), findsOneWidget);

      // 状态仍是 ready，重建 UI 也不应再次弹窗（同一次下载完成只提示一次）
      await tester.pumpAndSettle();
      expect(find.text('立即重启'), findsNothing);
    });

    testWidgets('「立即重启」→ 调用 restartToUpdate 并关闭对话框', (tester) async {
      final controller = _DialogController(restartResult: true);
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即重启'));
      await tester.pumpAndSettle();

      expect(controller.restartCalled, 1, reason: '点击立即重启应触发 restartToUpdate');
      expect(find.text('立即重启'), findsNothing);
      expect(find.textContaining('无法自动重启'), findsNothing);
    });

    testWidgets('「立即重启」失败（无待安装包）→ 显示错误对话框', (tester) async {
      final controller = _DialogController();
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即重启'));
      await tester.pumpAndSettle();

      // manifest 未落盘 → restartToUpdate 返回 false → 错误提示
      expect(controller.restartCalled, 1);
      expect(find.textContaining('无法自动重启'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法自动重启'), findsNothing);
    });

    testWidgets('下载失败 → 不弹重启对话框，状态为 error', (tester) async {
      final controller = _DialogController(
        downloadError: Exception('网络中断'),
      );
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();

      expect(find.text('立即重启'), findsNothing);
      expect(controller.state.updateStatus.phase, UpdatePhase.error);
    });

    testWidgets('「稍后重启」后同一版本再次检查下载完成 → 再次弹窗', (tester) async {
      final controller = _DialogController();
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后重启'));
      await tester.pumpAndSettle();

      // 用户再次点击检查更新，重新下载完成 → 应再次提示
      controller.checkForUpdates();
      await tester.pumpAndSettle();
      expect(find.text('立即重启'), findsOneWidget,
          reason: '每一次下载完成都应重新提示一次');
    });

    testWidgets('本地开发构建（未注入更新源）→ 不弹对话框', (tester) async {
      final controller = _DialogController(enabled: false);
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      await tester.pumpAndSettle();

      expect(find.text('立即重启'), findsNothing);
      expect(controller.state.updateStatus.phase, UpdatePhase.error);
    });

    testWidgets('检查更新进行中重复触发 → 防重入只执行一次', (tester) async {
      final controller = _DialogController();
      final gate = Completer<UpdateInfo?>();
      controller._fake.checkImpl = () => gate.future;
      await tester.pumpWidget(_wrap(controller));

      controller.checkForUpdates();
      controller.checkForUpdates();
      await tester.pump();
      expect(controller._fake.checkCallCount, 1, reason: '进行中重复触发应被忽略');

      gate.complete(controller._fake.infoForTest);
      await tester.pumpAndSettle();
      expect(controller.state.updateStatus.phase, UpdatePhase.ready);
      expect(find.text('立即重启'), findsOneWidget);
    });
  });

  group('AppController 更新重启链路（issue #29）', () {
    // 非 widget 测试不经过 ProviderScope，需手动触发 build() 初始化
    // updateConfig / updateService 等 late 字段（等价于真实 Provider 装配）
    ProviderContainer _container(_DialogController controller) {
      final container = ProviderContainer(
        overrides: [appControllerProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(appControllerProvider);
      return container;
    }

    test('下载完成 → 恢复主窗口模式（随手记录弹窗/托盘隐藏场景可见）', () async {
      final controller = _DialogController();
      controller.onWindowModeChanged = (mode) async {
        controller.restoredMainWindow = mode == WindowMode.main;
      };
      _container(controller);
      await controller.checkForUpdates();
      expect(controller.restoredMainWindow, isTrue,
          reason: '下载完成后应切回主窗口保证对话框可见');
      expect(controller.state.updateStatus.phase, UpdatePhase.ready);
    });

    test('restartToUpdate：无 manifest → 返回 false 且置 error 状态', () async {
      final controller = _DialogController();
      _container(controller);
      final ok = await controller.restartToUpdate();
      expect(ok, isFalse);
      expect(controller.state.updateStatus.phase, UpdatePhase.error);
      expect(controller.state.updateStatus.message, contains('未找到已下载的更新包'));
    });
  });
}
