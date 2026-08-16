/// 编辑器「查看已定稿日报」预览测试（issue #28：日报定稿后，顶部点击
/// 「查看」，右侧预览页面空白；定稿之前预览正常）。
///
/// 根因：EditorPage 以无 initialContent 打开（定稿后「查看」路径）时，
/// initState 里 _loadExisting() 异步读取已定稿日报并赋值
/// `_controller.text = content`，但**没有 setState**。左侧 TextField 内部
/// 监听 controller 会自动刷新，右侧 Markdown 是普通 widget，构建时取
/// `_controller.text` 后不会因 controller 变化重建 → 预览停留在初始空白。
/// 定稿前「生成今日日报」路径 _openEditor(draft) 直接传入 initialContent，
/// Markdown 首次构建即有内容，所以预览正常。
///
/// 契约（修复后）：
/// 1. 定稿后点「查看」（无 initialContent）→ 异步加载完成后，右侧
///    Markdown 预览必须渲染出定稿内容（修复前 data 为空）；
/// 2. 左侧编辑器文本同步显示定稿内容；
/// 3. 带 initialContent 打开（生成初稿路径）→ 预览内容与 initialContent
///    一致（回归保障，该路径修复前后均正常）。
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
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/pages/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：把日志根目录指向临时目录，
/// build 不触 FRB/IO（EditorPage 只读 settings.logRoot）。
class _FakeController extends AppController {
  _FakeController({required this.logRoot});

  final String logRoot;

  @override
  AppState build() {
    settingsService = SettingsService(initial: AppSettings(logRoot: logRoot));
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

/// 渲染 EditorPage（可带 initialContent）并等待异步 _loadExisting 完成。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required String logRoot,
  DateTime? date,
  String? initialContent,
}) async {
  final controller = _FakeController(logRoot: logRoot);
  final d = date ?? dayStart(DateTime(2026, 8, 16));
  // initState 里 _loadExisting 启动真实文件 IO future，fake async zone 中
  // 不会完成；把 pumpWidget 与等待一并放入 runAsync 真实异步区域执行
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => controller)],
        child: MaterialApp(
          home: EditorPage(date: d, initialContent: initialContent),
        ),
      ),
    );
    // 等待异步 _loadExisting 完成（含真实文件读取）
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  // 回到 fake zone 渲染
  await tester.pump();
  await tester.pump();
}

void main() {
  late Directory tmp;
  late String logRoot;
  final date = DateTime(2026, 8, 16);
  const finalizedContent = '# 2026-08-16 工作日报\n\n- 完成需求 A\n- 修复缺陷 B';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daymark_editor_preview_');
    logRoot = tmp.path;
    // 预置定稿日报文件（isFinalized/readExistingReport 的数据源）
    final reportFile = File(dailyReportPath(logRoot, date));
    reportFile.parent.createSync(recursive: true);
    reportFile.writeAsStringSync(finalizedContent);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  testWidgets('定稿后点「查看」（无 initialContent）：右侧预览渲染定稿内容', (tester) async {
    await _pumpEditor(tester, logRoot: logRoot, date: date);

    // 契约 1：右侧 Markdown 预览必须有内容（修复前 data 为空 → 空白）
    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.data, contains('完成需求 A'),
        reason: '定稿后查看，右侧预览必须渲染已定稿日报内容');

    // 契约 2：左侧编辑器同步显示定稿内容
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, contains('修复缺陷 B'),
        reason: '左侧编辑器应显示定稿日报内容');
  });

  testWidgets('生成初稿路径（带 initialContent）：预览直接渲染传入内容', (tester) async {
    const draft = '# 初稿标题\n\n- 草稿要点一';
    await _pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: draft,
    );

    // 契约 3：该路径（定稿前正常）必须保持正常
    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.data, contains('草稿要点一'),
        reason: '带 initialContent 打开时预览应立即渲染内容');
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, contains('初稿标题'));
  });
}
