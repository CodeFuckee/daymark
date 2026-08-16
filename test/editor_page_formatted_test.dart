/// 编辑器「所见即所得」测试（issue #30 第三轮人工确认方案 A：引入
/// flutter_smooth_markdown 0.8.1，formatted 渲染块点击即编辑，类 Typora，
/// 单视图天然无「左右分栏同步滚动」问题，替代原 TextField + 预览分栏）。
///
/// 契约：
/// 1. 正常：formatted 模式渲染 initialContent 内容；
/// 2. 正常：编辑内容后 controller 同步更新，且出现「未保存的修改」提示；
/// 3. 正常：formatted 模式下点击渲染块可激活块内编辑（Text 变 TextField）；
/// 4. 正常：一键切换 source 模式显示原始 Markdown 源码；
/// 5. 重复：连续切换 formatted ↔ source 无异常、内容不丢；
/// 6. 边界：空内容（无 initialContent 且无定稿文件）无异常，显示占位提示；
/// 7. 边界：短内容正常渲染；
/// 8. 边界：特殊 Markdown（代码块 / 表格 / 引用）正常渲染；
/// 9. 边界：长内容（300 行）正常渲染且可滚动。
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
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/pages/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smooth_markdown/flutter_smooth_markdown_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：把日志根目录指向临时目录，build 不触 FRB/IO
/// （EditorPage 只读 settings.logRoot）。
class FakeFormattedController extends AppController {
  FakeFormattedController({required this.logRoot});

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
Future<void> pumpEditor(
  WidgetTester tester, {
  required String logRoot,
  DateTime? date,
  String? initialContent,
}) async {
  final controller = FakeFormattedController(logRoot: logRoot);
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
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  // 回到 fake zone 渲染
  await tester.pump();
  await tester.pump();
}

/// 当前编辑器的 MarkdownEditorController（EditorPage 传入的同一实例）。
MarkdownEditorController editorController(WidgetTester tester) => tester
    .widget<SmoothMarkdownEditor>(
      find.byKey(const ValueKey('editor-smooth-markdown')),
    )
    .controller!;

/// 点击工具栏模式按钮（Formatted / Source / Preview / Split）。
Future<void> switchMode(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump();
}

void main() {
  late Directory tmp;
  late String logRoot;
  final date = DateTime(2026, 8, 16);
  // 300 行要点：内容远超视口，验证长内容渲染与滚动
  final longContent = List.generate(300, (i) => '- 要点 ${i + 1}').join('\n');
  // 特殊 Markdown：代码块、表格、引用
  final specialContent = [
    '# 特殊内容',
    '',
    '```dart',
    'void main() {}',
    '```',
    '',
    '| 列A | 列B |',
    '| --- | --- |',
    '| 1 | 2 |',
    '',
    '> 这是一段引用',
  ].join('\n');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daymark_editor_formatted_');
    logRoot = tmp.path;
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  testWidgets('正常：formatted 模式渲染 initialContent 内容', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    // 渲染块文本出现（列表项以富文本渲染）
    expect(
      find.textContaining('要点 1', findRichText: true),
      findsWidgets,
      reason: 'formatted 模式应渲染出 initialContent 中的内容',
    );
    expect(
      find.textContaining('要点 300', findRichText: true),
      findsWidgets,
      reason: '长内容末尾也应渲染',
    );
    expect(
      editorController(tester).text,
      longContent,
      reason: 'controller 持有完整源码',
    );
  });

  testWidgets('正常：编辑内容后 controller 同步更新并出现未保存提示', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: '# 日报\n\n- 原始要点',
    );

    // source 模式下输入新内容
    await switchMode(tester, 'Source');
    await tester.enterText(
      find.byKey(const ValueKey('smooth_markdown_editor_source')),
      '# 日报\n\n- 原始要点\n- 新增要点',
    );
    await tester.pump();

    expect(
      editorController(tester).text,
      contains('新增要点'),
      reason: '编辑后 controller 源码应同步更新',
    );
    expect(find.text('未保存的修改'), findsOneWidget, reason: '编辑后应出现未保存修改提示');
  });

  testWidgets('正常：formatted 模式点击渲染块可激活块内编辑', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: '# 标题\n\n这是第一段。',
    );

    // 段落块（第一个块是标题，起点 0；第二块段落起点为标题行 + 换行）
    final paragraphBlock = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('smooth_markdown_editor_formatted_block_') &&
          key.value != 'smooth_markdown_editor_formatted_block_0';
    });
    expect(paragraphBlock, findsWidgets, reason: '应存在可点击的渲染块');

    await tester.tap(paragraphBlock.first);
    await tester.pump();
    await tester.pump();

    // 激活后块内变为可编辑 TextField
    final activeField = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('smooth_markdown_editor_formatted_active_');
    });
    expect(activeField, findsOneWidget, reason: '点击渲染块后应出现块内编辑框');

    await tester.enterText(activeField, '这是修改后的段落。');
    await tester.pump();
    await tester.pump();

    expect(
      editorController(tester).text,
      contains('修改后的段落'),
      reason: '块内编辑应回写源码',
    );
  });

  testWidgets('正常：一键切换 source 模式显示原始 Markdown 源码', (tester) async {
    const content = '# 今日日报\n\n- 完成需求 A\n- 修复缺陷 B';
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: content,
    );

    await switchMode(tester, 'Source');

    final sourceField = tester.widget<TextField>(
      find.byKey(const ValueKey('smooth_markdown_editor_source')),
    );
    expect(
      sourceField.controller!.text,
      content,
      reason: 'source 模式应展示原始 Markdown 源码（含 # 与 - 标记）',
    );
    expect(
      sourceField.controller!.text,
      contains('# 今日日报'),
      reason: '原始源码应保留标题标记',
    );
  });

  testWidgets('重复：连续切换 formatted ↔ source 无异常且内容不丢', (tester) async {
    const content = '# 标题\n\n正文内容。';
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: content,
    );

    for (var i = 0; i < 3; i++) {
      await switchMode(tester, 'Source');
      expect(
        editorController(tester).text,
        content,
        reason: '切到 source 第 ${i + 1} 次内容不丢',
      );
      await switchMode(tester, 'Formatted');
      expect(
        find.textContaining('正文内容', findRichText: true),
        findsWidgets,
        reason: '切回 formatted 第 ${i + 1} 次仍渲染内容',
      );
    }
  });

  testWidgets('边界：空内容（无 initialContent 且无定稿文件）无异常', (tester) async {
    await pumpEditor(tester, logRoot: logRoot, date: date);

    expect(tester.takeException(), isNull, reason: '空内容渲染不应抛异常');
    expect(editorController(tester).text, isEmpty);
    expect(find.text('未保存的修改'), findsNothing, reason: '空内容初始不应有未保存提示');
    // 空内容 formatted 视图提供占位输入框（hint 为我们的 placeholder）
    expect(
      find.text('开始撰写日报…（Markdown 渲染块点击即可编辑）'),
      findsOneWidget,
      reason: '空内容应显示占位提示',
    );
  });

  testWidgets('边界：短内容正常渲染', (tester) async {
    const shortContent = '# 短标题\n\n- 只有一行';
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: shortContent,
    );

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('短标题', findRichText: true),
      findsWidgets,
      reason: '短内容标题应渲染',
    );
  });

  testWidgets('边界：特殊 Markdown（代码块 / 表格 / 引用）正常渲染', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: specialContent,
    );

    expect(tester.takeException(), isNull, reason: '特殊 Markdown 不应抛异常');
    expect(
      find.textContaining('void main() {}', findRichText: true),
      findsWidgets,
      reason: '代码块内容应渲染',
    );
    expect(
      find.textContaining('这是一段引用', findRichText: true),
      findsWidgets,
      reason: '引用内容应渲染',
    );
    expect(editorController(tester).text, specialContent, reason: '源码保持不变');
  });

  testWidgets('边界：长内容（300 行）正常渲染且可滚动', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    expect(tester.takeException(), isNull, reason: '长内容不应抛异常');

    // 拖动编辑器区域向上滚动，内容可滚动且不崩
    await tester.drag(
      find.byKey(const ValueKey('editor-smooth-markdown')),
      const Offset(0, -600),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '滚动后不应抛异常');
  });
}
