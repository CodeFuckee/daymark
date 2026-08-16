/// 编辑器左右分栏同步滚动测试（issue #30：工作日报查看页面，左右两边
/// 同步滚动）。
///
/// 实现采用「相对位置比例」同步：左侧等宽源码与右侧渲染预览内容高度
/// 不同，像素同步会错位；任一侧滚动时另一侧按滚动比例跟随。
///
/// 契约：
/// 1. 内容超出一屏（两侧均可滚动）时，滚动左侧 → 右侧按比例同步跟随；
/// 2. 反向：滚动右侧 → 左侧按比例跟随；
/// 3. 双向同步防回环：一次滚动只触发一轮同步，不产生死循环；
/// 4. 边界：任一侧内容不足一屏（不可滚动）时滚动另一侧，无异常且不动；
/// 5. 边界：空内容（无 initialContent 且无定稿文件）时无异常。
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
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：把日志根目录指向临时目录，build 不触 FRB/IO
/// （EditorPage 只读 settings.logRoot）。
class FakeSyncController extends AppController {
  FakeSyncController({required this.logRoot});

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
  final controller = FakeSyncController(logRoot: logRoot);
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

/// 左侧滚动容器：外层 SingleChildScrollView（key: editor-left-scroll）
/// 内部唯一承担纵向滚动的 Scrollable。
ScrollableState leftScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('editor-left-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

/// 右侧 Markdown 预览内部唯一的 Scrollable（ListView）。
ScrollableState rightScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(Markdown),
            matching: find.byType(Scrollable),
          )
          .first,
    );

void main() {
  late Directory tmp;
  late String logRoot;
  final date = DateTime(2026, 8, 16);
  // 300 行要点：左侧源码与右侧渲染后高度都远超测试视口（800x600）
  final longContent = List.generate(300, (i) => '- 要点 ${i + 1}').join('\n');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daymark_editor_sync_');
    logRoot = tmp.path;
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  testWidgets('滚动左侧：右侧按相对位置比例同步跟随', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);

    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;
    expect(leftMax, greaterThan(0), reason: '长内容下左侧应可滚动');
    expect(rightMax, greaterThan(0), reason: '长内容下右侧预览应可滚动');

    // 左侧滚到 50% → 右侧应同步到其 50%（按比例，非像素）
    left.position.jumpTo(leftMax * 0.5);
    await tester.pump();
    expect(right.position.pixels, closeTo(rightMax * 0.5, 1.0),
        reason: '左侧滚到 50% 时右侧应同步到 50%');

    // 再滚到 25% → 右侧跟随到 25%
    left.position.jumpTo(leftMax * 0.25);
    await tester.pump();
    expect(right.position.pixels, closeTo(rightMax * 0.25, 1.0),
        reason: '左侧滚到 25% 时右侧应同步到 25%');
  });

  testWidgets('滚动右侧：左侧按相对位置比例同步跟随（反向）', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);

    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;

    right.position.jumpTo(rightMax * 0.75);
    await tester.pump();
    expect(left.position.pixels, closeTo(leftMax * 0.75, 1.0),
        reason: '右侧滚到 75% 时左侧应同步到 75%');
  });

  testWidgets('双向同步防回环：连续滚动只做单轮同步，不产生死循环', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);
    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;

    for (var i = 1; i <= 5; i++) {
      final ratio = i / 5;
      left.position.jumpTo(leftMax * ratio);
      await tester.pump();
      expect(right.position.pixels, closeTo(rightMax * ratio, 1.0),
          reason: '第 $i 次滚动后右侧应同步到对应比例');
      // 防回环：同步跳转后目标侧不应反向再驱动源侧（否则位置漂移/死循环）
      expect(left.position.pixels, closeTo(leftMax * ratio, 1.0),
          reason: '同步后左侧位置应保持，不被回环覆盖');
    }
  });

  testWidgets('边界：内容不足一屏（两侧均不可滚动）时滚动无异常', (tester) async {
    const shortContent = '# 短标题\n\n- 只有一行';
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: shortContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);

    expect(left.position.maxScrollExtent, 0, reason: '短内容左侧不可滚动');
    expect(right.position.maxScrollExtent, 0, reason: '短内容右侧不可滚动');

    left.position.jumpTo(0);
    await tester.pump();
    expect(right.position.pixels, 0, reason: '目标不可滚动时保持原位');
  });

  testWidgets('边界：空内容（无 initialContent 且无定稿文件）时无异常', (tester) async {
    await pumpEditor(tester, logRoot: logRoot, date: date);

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);

    expect(left.position.maxScrollExtent, 0, reason: '空内容左侧不可滚动');
    expect(right.position.maxScrollExtent, 0, reason: '空内容右侧不可滚动');

    left.position.jumpTo(0);
    await tester.pump();
    expect(right.position.pixels, 0);
  });

  // ---- issue #30 人工反馈回归（2026-08-16 用户反馈：滚动时右侧一直在闪、
  //      滚动到底部后无法往上滚动）----

  testWidgets('回归：源侧越界回弹时目标始终保持在可视范围内（修复右侧闪烁）',
      (tester) async {
    // macOS 默认 bounce 物理，overscroll 时 offset 可越出 [0, max]，
    // 最容易复现「越界比例传播到另一侧」导致的闪烁
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);
    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;
    expect(leftMax, greaterThan(0));
    expect(rightMax, greaterThan(0));

    // 底部越界：左侧被推到 max 之上（bounce 允许越界像素）
    left.position.jumpTo(leftMax + 120);
    await tester.pump();
    expect(right.position.pixels, inInclusiveRange(0.0, rightMax),
        reason: '左侧底部越界回弹时，右侧不得被推出可视范围（否则闪烁）');

    // 顶部越界：左侧被推到 0 之下
    left.position.jumpTo(-120);
    await tester.pump();
    expect(right.position.pixels, inInclusiveRange(0.0, rightMax),
        reason: '左侧顶部越界回弹时，右侧不得被推出可视范围（否则闪烁）');

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('回归：两侧滚动到底部后仍可向上滚动（修复底部卡死）', (tester) async {
    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);
    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;
    expect(leftMax, greaterThan(0));
    expect(rightMax, greaterThan(0));

    // 左侧到底 → 右侧应同步到底
    left.position.jumpTo(leftMax);
    await tester.pump();
    expect(right.position.pixels, closeTo(rightMax, 1.0),
        reason: '左侧到底时右侧应同步到底');

    // 用户在底部向上拖动右侧（内容向下移动 → dy>0）→ 两侧都应离开底部
    await tester.drag(find.byType(Markdown), const Offset(0, 300));
    await tester.pump();
    expect(right.position.pixels, lessThan(rightMax),
        reason: '底部时向上拖动右侧应可行，不得卡死');
    expect(left.position.pixels, lessThan(leftMax),
        reason: '右侧上滚时左侧应跟随离开底部');

    // 反向：右侧到底后，用户在底部向上拖动左侧 → 两侧都应离开底部
    right.position.jumpTo(rightMax);
    await tester.pump();
    expect(left.position.pixels, closeTo(leftMax, 1.0),
        reason: '右侧到底时左侧应同步到底');

    await tester.drag(
        find.byKey(const ValueKey('editor-left-scroll')), const Offset(0, 300));
    await tester.pump();
    expect(left.position.pixels, lessThan(leftMax),
        reason: '底部时向上拖动左侧应可行，不得卡死');
    expect(right.position.pixels, lessThan(rightMax),
        reason: '左侧上滚时右侧应跟随离开底部');
  });

  testWidgets('回归：目标侧惯性滚动中，源侧滚动不得强行打断目标（防抖动）',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await pumpEditor(
      tester,
      logRoot: logRoot,
      date: date,
      initialContent: longContent,
    );

    final left = leftScrollable(tester);
    final right = rightScrollable(tester);
    final leftMax = left.position.maxScrollExtent;
    final rightMax = right.position.maxScrollExtent;

    // 先把两侧都置顶
    left.position.jumpTo(0);
    await tester.pump();
    expect(right.position.pixels, 0, reason: '左侧置顶后右侧应同步置顶');

    // 右侧产生向上的惯性滚动（fling：快速上滑 → 释放后 ballistic 继续）
    await tester.fling(find.byType(Markdown), const Offset(0, -400), 3000);
    await tester.pump();
    expect(right.position.activity, isNot(isA<IdleScrollActivity>()),
        reason: 'fling 释放后右侧应处于惯性滚动中');

    final rightPixelsDuringBallistic = right.position.pixels;
    expect(rightPixelsDuringBallistic, lessThan(rightMax),
        reason: '惯性刚开始时右侧不应已在底部');

    // 惯性滚动未结束时，左侧程序化跳转到底（模拟另一侧滚动）——
    // 修复后不得把右侧从惯性中强行拽走
    left.position.jumpTo(leftMax);
    await tester.pump();
    expect(right.position.pixels,
        closeTo(rightPixelsDuringBallistic, 1.0),
        reason: '目标侧惯性滚动中不得被源侧同步强行打断');

    debugDefaultTargetPlatformOverride = null;
  });
}
