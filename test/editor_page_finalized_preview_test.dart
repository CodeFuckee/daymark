/// 编辑器「查看已定稿日报」预览测试（issue #28：日报定稿后，顶部点击
/// 「查看」，右侧预览页面空白；定稿之前预览正常）。
///
/// issue #30 方案 A 后：编辑器改为 flutter_smooth_markdown 所见即所得
/// （formatted 模式）单视图，源码与渲染由同一个 MarkdownEditorController
/// 持有——异步加载定稿内容后 controller 变化必须驱动渲染刷新。
///
/// 契约（修复后）：
/// 1. 定稿后点「查看」（无 initialContent）→ 异步加载完成后，编辑器
///    formatted 视图必须渲染出定稿内容（修复前 data 为空 → 空白）；
/// 2. 编辑器 controller 源码同步显示定稿内容；
/// 3. 带 initialContent 打开（生成初稿路径）→ 渲染内容与 initialContent
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smooth_markdown/flutter_smooth_markdown_editor.dart';
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

MarkdownEditorController _editorController(WidgetTester tester) => tester
    .widget<SmoothMarkdownEditor>(
      find.byKey(const ValueKey('editor-smooth-markdown')),
    )
    .controller!;

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

  testWidgets('定稿后点「查看」（无 initialContent）：formatted 视图渲染定稿内容', (tester) async {
    await _pumpEditor(tester, logRoot: logRoot, date: date);

    // 契约 1：formatted 渲染块必须有定稿内容（修复前 data 为空 → 空白）
    expect(
      find.textContaining('完成需求 A', findRichText: true),
      findsWidgets,
      reason: '定稿后查看，编辑器必须渲染已定稿日报内容',
    );

    // 契约 2：编辑器 controller 源码同步显示定稿内容
    expect(
      _editorController(tester).text,
      contains('修复缺陷 B'),
      reason: '编辑器源码应显示定稿日报内容',
    );
    expect(
      _editorController(tester).isDirty,
      isFalse,
      reason: '加载定稿内容不应误报未保存修改',
    );
  });

  testWidgets('生成初稿路径（带 initialContent）：渲染内容与传入一致', (tester) async {
    const draft = '# 初稿标题\n\n- 草稿要点一';
    await _pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: draft,
    );

    // 契约 3：该路径（定稿前正常）必须保持正常
    expect(
      find.textContaining('草稿要点一', findRichText: true),
      findsWidgets,
      reason: '带 initialContent 打开时编辑器应立即渲染内容',
    );
    expect(_editorController(tester).text, contains('初稿标题'));
  });
}
