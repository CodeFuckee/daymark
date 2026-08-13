/// 设置页保存交互测试（issue #6：保存按钮卡在"保存中…"）。
///
/// UI 契约：
/// - 点击"保存设置"→ 等待 saveSettings 完成 → 按钮恢复、显示成功提示；
/// - saveSettings 抛异常 → 按钮恢复、显示"保存失败：…"；
/// - saveSettings 挂起期间按钮显示"保存中…"且禁用（不吞掉进行中状态）。
library;

import 'dart:async';

import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：saveSettings 行为由测试注入，build 不触 FRB/IO
class _FakeController extends AppController {
  _FakeController({this.onSave});

  Future<void> Function(AppSettings next)? onSave;

  @override
  AppState build() {
    settingsService = SettingsService(initial: AppSettings(authorName: '测试'));
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

  @override
  Future<void> saveSettings(AppSettings next) async {
    if (onSave != null) {
      await onSave!(next);
      return;
    }
    await super.saveSettings(next);
  }
}

Widget _wrap(_FakeController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: const MaterialApp(home: SettingsPage()),
  );
}

void main() {
  testWidgets('保存成功：按钮恢复"保存设置"并显示成功提示', (tester) async {
    final controller = _FakeController(onSave: (_) async {});
    await tester.pumpWidget(_wrap(controller));

    expect(find.text('保存设置'), findsOneWidget);
    await tester.tap(find.text('保存设置'));
    await tester.pump();

    expect(find.text('保存设置'), findsOneWidget);
    expect(find.text('设置已保存'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });

  testWidgets('保存失败：按钮恢复并显示错误信息', (tester) async {
    final controller = _FakeController(
      onSave: (_) async => throw Exception('磁盘写入失败'),
    );
    await tester.pumpWidget(_wrap(controller));

    await tester.tap(find.text('保存设置'));
    await tester.pump();
    await tester.pump();

    expect(find.text('保存设置'), findsOneWidget);
    expect(find.textContaining('保存失败：'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });

  testWidgets('保存挂起期间：按钮显示"保存中…"且禁用（进行中状态不丢失）', (tester) async {
    final gate = Completer<void>();
    final controller = _FakeController(onSave: (_) => gate.future);
    await tester.pumpWidget(_wrap(controller));

    await tester.tap(find.text('保存设置'));
    await tester.pump();

    expect(find.text('保存中…'), findsOneWidget);
    // FilledButton.icon 实际类型是 _FilledButtonWithIcon，需用 bySubtype 匹配
    final button = tester.widget<FilledButton>(find.bySubtype<FilledButton>());
    expect(button.onPressed, isNull, reason: '保存中按钮应禁用，防止重复提交');

    // 完成后恢复
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('保存设置'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });
}
