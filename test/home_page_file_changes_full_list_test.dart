/// 日报页「本地文件变更」全量展示测试（issue #19：当日修改的文件超过
/// 8 条时，列表只渲染前 8 条，其余文件看不到——用户选择 2026.8.6、
/// 刷新素材后找不到当日修改过的「大干围建筑景观合模.skp」）。
///
/// 根因：_MaterialCard 渲染 items.take(8) 截断，超出部分只显示
/// "… 共 N 条"提示，具体文件名不可见。
///
/// 契约（修复后）：
/// 1. 当日文件变更超过 8 条时全部渲染，第 9 条及之后的文件名可见
///    （修复前无论怎么滚动都找不到）；
/// 2. 不再出现"… 共 N 条"截断提示；
/// 3. 8 条以内正常展示全部（回归）。
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

/// 可控的 fake controller：collectForDate 返回 [files] 生成的记录
/// （build 不触 FRB/IO，与 issue #16/#18 测试约定一致）。
class _FakeController extends AppController {
  _FakeController({required this.files});

  final List<String> files;

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

void main() {
  testWidgets('超过 8 条时全部文件变更可见（第 9 条及之后不再被截断）', (tester) async {
    // 放大视口让全部条目落入可视区（真实场景中列表可滚动查看全部）
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final files = List.generate(12, (i) => '/watch/f$i.txt');
    final controller = _FakeController(files: files);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    // 卡片计数显示 12
    expect(find.text('本地文件变更（12）'), findsOneWidget);

    // 契约 1：修复前 take(8) 截断，f8 及之后的记录不可见
    for (var i = 0; i < 12; i++) {
      expect(find.textContaining('[modify] /watch/f$i.txt'), findsOneWidget,
          reason: '第 ${i + 1} 条文件变更应可见');
    }

    // 契约 2：不再有"… 共 N 条"截断提示
    expect(find.textContaining('… 共'), findsNothing);
  });

  testWidgets('不超过 8 条时全部展示（回归）', (tester) async {
    final files = List.generate(5, (i) => '/watch/f$i.txt');
    final controller = _FakeController(files: files);
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    expect(find.text('本地文件变更（5）'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(find.textContaining('[modify] /watch/f$i.txt'), findsOneWidget);
    }
  });
}
