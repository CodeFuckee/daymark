/// 日报页「本地文件变更」排除项快捷按钮 UI 测试（issue #18：列表每条
/// 记录右侧添加按钮，一键把该文件加入排除项）。
///
/// 契约（修复前无按钮）：
/// 1. 每条文件变更记录右侧都有「添加为排除项」按钮；
/// 2. 点击按钮：对应路径传给 addExcludePattern，列表刷新后该文件消失，
///    其余文件保留，SnackBar 提示已添加；
/// 3. 全部排除后列表显示「当日无文件变更」；
/// 4. 超过 8 条时只展示前 8 条（与现有截断一致），按钮随行展示；
/// 5. 保存失败时 SnackBar 提示失败，列表不崩溃。
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：
/// - collectForDate 返回 [files] 生成的记录，并模拟真实读侧排除过滤
///   （排除规则命中的记录不展示，与 CollectService.collectForDate 一致）；
/// - addExcludePattern 只改内存设置、不写盘（磁盘 IO 由单元测试覆盖）；
/// - [failExclude] 置 true 时模拟持久化失败。
class _FakeController extends AppController {
  _FakeController({required this.files, this.failExclude = false});

  final List<String> files;
  final bool failExclude;
  /// addExcludePattern 收到的路径（按调用顺序）
  final List<String> excluded = [];

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

  /// 与真实读侧过滤一致的子串匹配
  bool _excluded(String path) => settingsService.settings.excludePatterns
      .any((p) => p.isNotEmpty && path.contains(p));

  @override
  Future<DailyMaterial> collectForDate(
    DateTime date, {
    void Function(String)? onProgress,
  }) async {
    final now = DateTime.now();
    return DailyMaterial(
      date: date,
      fileChanges: files
          .where((p) => !_excluded(p))
          .map((p) => FileChange(path: p, mtime: now, size: 1, kind: 'modify'))
          .toList(),
    );
  }

  @override
  Future<String> addExcludePattern(String path) async {
    if (failExclude) throw Exception('disk full');
    excluded.add(path);
    final patterns = settingsService.settings.excludePatterns;
    final next = AppSettings.fromJson(settingsService.settings.toJson());
    next.excludePatterns = [...patterns, path];
    settingsService.settings = next;
    state = state.copyWith(settings: next);
    return '已添加排除项：$path';
  }
}

Widget _wrap(_FakeController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: MaterialApp(home: Scaffold(body: HomePage())),
  );
}

void main() {
  testWidgets('每条文件变更右侧都有排除按钮，点击后文件消失并提示', (tester) async {
    final controller = _FakeController(
      files: ['/watch/a.txt', '/watch/b.txt'],
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    // 两条记录都展示，且每条右侧都有按钮
    expect(find.textContaining('/watch/a.txt'), findsOneWidget);
    expect(find.textContaining('/watch/b.txt'), findsOneWidget);
    expect(find.byTooltip('添加为排除项'), findsNWidgets(2));

    // 点击第一条（a.txt）的按钮
    await tester.tap(find.byTooltip('添加为排除项').first);
    await tester.pump();
    await tester.pump();

    // 路径传给 controller，列表刷新后该文件消失、其余保留
    // （用带 [modify] 前缀的完整行文本定位行，避免匹配到含路径的 SnackBar）
    expect(controller.excluded, ['/watch/a.txt']);
    expect(find.textContaining('[modify] /watch/a.txt'), findsNothing,
        reason: '被排除的文件应立即从列表消失（读侧过滤）');
    expect(find.textContaining('[modify] /watch/b.txt'), findsOneWidget);
    // SnackBar 提示
    expect(find.text('已添加排除项：/watch/a.txt'), findsOneWidget);
  });

  testWidgets('全部文件排除后显示「当日无文件变更」空态', (tester) async {
    final controller = _FakeController(files: ['/watch/a.txt']);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('添加为排除项'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('[modify] /watch/a.txt'), findsNothing);
    expect(find.text('当日无文件变更'), findsOneWidget);
    expect(find.byTooltip('添加为排除项'), findsNothing,
        reason: '空列表不再有按钮');
  });

  testWidgets('超过 8 条时只展示前 8 条，按钮随行展示', (tester) async {
    final files = List.generate(10, (i) => '/watch/f$i.txt');
    final controller = _FakeController(files: files);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('添加为排除项'), findsNWidgets(8),
        reason: '与现有截断一致，只展示前 8 条');
    expect(find.textContaining('… 共 10 条'), findsOneWidget);
  });

  testWidgets('保存失败时 SnackBar 提示失败，列表不崩溃', (tester) async {
    final controller = _FakeController(
      files: ['/watch/a.txt'],
      failExclude: true,
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('添加为排除项'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('添加排除项失败'), findsOneWidget);
    // 失败不改变列表（文件仍在）
    expect(find.textContaining('[modify] /watch/a.txt'), findsOneWidget);
  });
}
