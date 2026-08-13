/// 设置页交互测试：
/// - 保存交互（issue #6：保存按钮卡在"保存中…"）；
/// - 目录监控添加（issue #11：+ 号无反应，改为目录选择器）。
///
/// UI 契约：
/// - 点击"保存设置"→ 等待 saveSettings 完成 → 按钮恢复、显示成功提示；
/// - saveSettings 抛异常 → 按钮恢复、显示"保存失败：…"；
/// - saveSettings 挂起期间按钮显示"保存中…"且禁用（不吞掉进行中状态）；
/// - 点击"添加监控目录"右侧按钮 → 弹出系统目录选择器 → 选中目录加入监控列表；
/// - 选择器取消 → 不添加条目；输入框回车仍可手动添加路径。
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
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：saveSettings 行为由测试注入，build 不触 FRB/IO
class _FakeController extends AppController {
  _FakeController({this.onSave, AppSettings? initial})
      : _initial = initial ?? AppSettings(authorName: '测试');

  Future<void> Function(AppSettings next)? onSave;
  final AppSettings _initial;

  @override
  AppState build() {
    settingsService = SettingsService(initial: _initial);
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

  group('目录监控（issue #11）：添加监控目录改为目录选择器', () {
    late FileSelectorPlatform original;

    setUp(() {
      original = FileSelectorPlatform.instance;
    });

    tearDown(() {
      FileSelectorPlatform.instance = original;
    });

    testWidgets('点击添加按钮弹出选择器，选中目录加入监控列表并保存', (tester) async {
      final selector = _FakeFileSelector('/picked/dir');
      FileSelectorPlatform.instance = selector;
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      // 修复前：按钮是"添加"文本按钮，找不到"选择目录"tooltip → 测试失败
      await tester.tap(find.byTooltip('选择目录'));
      await tester.pumpAndSettle();

      expect(selector.calls, 1, reason: '点击按钮应调用系统目录选择器');
      expect(find.text('/picked/dir'), findsOneWidget, reason: '选中目录应出现在监控列表');

      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, ['/picked/dir']);
    });

    testWidgets('取消选择不添加条目：保存后 watchDirs 为空', (tester) async {
      final selector = _FakeFileSelector(null);
      FileSelectorPlatform.instance = selector;
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      await tester.tap(find.byTooltip('选择目录'));
      await tester.pumpAndSettle();

      expect(selector.calls, 1);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, isEmpty);
    });

    testWidgets('输入框手动输入路径并回车：加入监控列表（空白输入不添加）', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      // 空白输入回车 → 不添加
      final field = find.widgetWithText(TextField, '添加监控目录');
      await tester.enterText(field, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // 手动输入路径回车 → 添加
      await tester.enterText(field, '/manual/dir');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('/manual/dir'), findsOneWidget);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, ['/manual/dir']);
    });
  });
}

/// 目录监控选择器 fake（issue #11）：拦截系统目录选择对话框
class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector(this.directory);

  /// getDirectoryPath 返回值（null 表示用户取消）
  String? directory;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return directory;
  }
}
