/// 日报页「本地文件变更」列表悬停高亮测试（issue #24：鼠标悬停到
/// 某一行时该行高亮显示，移出后恢复——桌面端便于跟随鼠标定位当前行）。
///
/// 契约（实现前无高亮）：
/// 1. 鼠标悬停到某条文件变更记录 → 该行出现高亮背景；
/// 2. 鼠标移出 → 高亮恢复（透明背景）；
/// 3. 多行场景只高亮当前悬停行，其他行保持透明；连续切换只高亮最后一行；
/// 4. 悬停在行内「添加为排除项」按钮区域同样视为悬停该行（按钮位于行内）；
/// 5. 高亮不扩散到其他卡片：随手记录等卡片行不出现高亮容器；
/// 6. 空列表正常显示空态，悬停逻辑不崩溃。
library;

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/pages/home_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：collectForDate 返回 [files] 生成的记录
/// （build 不触 FRB/IO，与 issue #16/#18/#19 测试约定一致）。
class _FakeController extends AppController {
  _FakeController({required this.files, this.notes = const []});

  final List<String> files;
  final List<String> notes;

  @override
  AppState build() {
    settingsService = SettingsService(
      initial: AppSettings(logRoot: '/tmp/daymark_test'),
    );
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
  Future<DailyMaterial> collectForDate(
    DateTime date, {
    void Function(String)? onProgress,
  }) async {
    final now = DateTime.now();
    return DailyMaterial(
      date: date,
      notes: notes
          .map((n) => QuickNote(time: now, content: n, tags: const []))
          .toList(),
      fileChanges: files
          .map((p) => FileChange(path: p, mtime: now, size: 1, kind: 'modify'))
          .toList(),
    );
  }
}

Widget _wrap(_FakeController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: MaterialApp(home: Scaffold(body: HomePage())),
  );
}

/// 悬停行高亮容器 key（与 _MaterialCard 实现约定一致）
Key _rowKey(int index) => ValueKey('hover-row-$index');

/// 读取第 [index] 行高亮容器的背景色（未实现时容器不存在，返回 null）
Color? _rowColor(WidgetTester tester, int index) {
  final finder = find.byKey(_rowKey(index));
  if (finder.evaluate().isEmpty) return null;
  final box = tester.widget<AnimatedContainer>(finder);
  return (box.decoration as BoxDecoration?)?.color;
}

bool _highlighted(Color? c) => c != null && c != Colors.transparent;

/// 创建一个鼠标指针（整个测试复用一个 gesture 移动，避免同测试多鼠标
/// 指针触发 MouseTracker「PointerAdded == PointerRemoved」断言）
Future<TestGesture> _createMouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

/// 把 [gesture] 移动到 [finder] 中心触发悬停
Future<void> _hoverAt(
  TestGesture gesture,
  WidgetTester tester,
  Finder finder,
) async {
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
}

/// 放大视口让全部条目落入可视区（真实场景中列表可滚动查看全部）
void _enlargeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('悬停文件变更行出现高亮背景，移出后恢复', (tester) async {
    _enlargeView(tester);
    final controller = _FakeController(files: ['/watch/a.txt', '/watch/b.txt']);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    final row = find.textContaining('[modify] /watch/a.txt');
    expect(row, findsOneWidget);

    // 初始未悬停：透明背景
    expect(_highlighted(_rowColor(tester, 0)), isFalse);

    // 悬停 → 高亮
    final mouse = await _createMouse(tester);
    await _hoverAt(mouse, tester, row);
    expect(_highlighted(_rowColor(tester, 0)), isTrue,
        reason: '悬停该行后应出现高亮背景');

    // 移出 → 恢复透明
    await mouse.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(_highlighted(_rowColor(tester, 0)), isFalse,
        reason: '鼠标移出后高亮应恢复');
  });

  testWidgets('多行场景只高亮悬停行，连续切换只高亮最后一行', (tester) async {
    _enlargeView(tester);
    final controller = _FakeController(
      files: ['/watch/a.txt', '/watch/b.txt', '/watch/c.txt'],
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    final mouse = await _createMouse(tester);

    // 悬停第 0 行 → 仅第 0 行高亮
    await _hoverAt(mouse, tester, find.textContaining('/watch/a.txt'));
    expect(_highlighted(_rowColor(tester, 0)), isTrue);
    expect(_highlighted(_rowColor(tester, 1)), isFalse);
    expect(_highlighted(_rowColor(tester, 2)), isFalse);

    // 移到第 2 行 → 仅第 2 行高亮，第 0 行恢复
    await _hoverAt(mouse, tester, find.textContaining('/watch/c.txt'));
    expect(_highlighted(_rowColor(tester, 2)), isTrue);
    expect(_highlighted(_rowColor(tester, 0)), isFalse);
    expect(_highlighted(_rowColor(tester, 1)), isFalse);
  });

  testWidgets('悬停行内排除按钮区域同样高亮该行', (tester) async {
    _enlargeView(tester);
    final controller = _FakeController(files: ['/watch/a.txt', '/watch/b.txt']);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    final mouse = await _createMouse(tester);

    // 悬停第 0 行的「添加为排除项」按钮（按钮位于行内 MouseRegion 中）
    await _hoverAt(mouse, tester, find.byTooltip('添加为排除项').first);
    expect(_highlighted(_rowColor(tester, 0)), isTrue,
        reason: '悬停行内按钮区域应视为悬停该行');
  });

  testWidgets('高亮不扩散到其他卡片（随手记录行无高亮容器）', (tester) async {
    _enlargeView(tester);
    // 随手记录 2 条 + 文件变更 1 条：若随手记录行也挂高亮容器，
    // 树中容器总数应为 3；实现仅文件变更卡片开启 → 恒为 1
    final controller = _FakeController(
      files: ['/watch/a.txt'],
      notes: ['随手记录一', '随手记录二'],
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    final mouse = await _createMouse(tester);

    // 悬停「随手记录」行 → 树中仅 1 个高亮容器（文件变更行），且全透明
    await _hoverAt(mouse, tester, find.textContaining('随手记录一'));
    final containers = find.byType(AnimatedContainer);
    expect(containers, findsOneWidget,
        reason: '未开启高亮的卡片行不应生成悬停高亮容器');
    for (final e in containers.evaluate()) {
      final box = e.widget as AnimatedContainer;
      final color = (box.decoration as BoxDecoration?)?.color;
      expect(color == null || color == Colors.transparent, isTrue,
          reason: '悬停其他卡片不应触发文件变更行高亮');
    }

    // 悬停文件变更行 → 该行高亮
    await _hoverAt(mouse, tester, find.textContaining('/watch/a.txt'));
    expect(_highlighted(_rowColor(tester, 0)), isTrue,
        reason: '悬停文件变更行应高亮');
  });

  testWidgets('空文件变更列表正常显示空态，悬停逻辑不崩溃', (tester) async {
    _enlargeView(tester);
    final controller = _FakeController(files: []);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    expect(find.text('当日无文件变更'), findsOneWidget);
    expect(find.textContaining('本地文件变更（0）'), findsOneWidget);
    // 空列表下无高亮容器
    expect(find.byType(AnimatedContainer), findsNothing);
  });
}
