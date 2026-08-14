/// 日报页日期切换测试（issue #16：左右箭头切换日期后，下面本地文件变更
/// 的文件列表内容不跟着变化）。
///
/// 根因：左右箭头 onPressed 只 setState 更新 _date，不调用 _refresh()
/// 重新收集素材；日历选择器 _pickDate() 则正常刷新。
///
/// 契约（修复后）：
/// 1. 点击左右箭头切换日期 → 重新收集素材（collectForDate 再次调用且
///    传入新日期）；
/// 2. 「本地文件变更」列表随之更新：旧日期文件路径消失、新日期文件
///    路径出现。
library;

import 'dart:async';

import 'package:daymark/core/models/material.dart';
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
import 'package:daymark/ui/pages/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：collectForDate 记录每次调用传入的日期
/// （build 不触 FRB/IO）；默认按日期返回带日期标记的文件变更，
/// 也可注入 [onCollect]（如挂起 Future 模拟慢收集）。
class _FakeController extends AppController {
  _FakeController({this.onCollect});

  final Future<DailyMaterial> Function(DateTime date)? onCollect;
  final List<DateTime> collectedDates = [];

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
    collectedDates.add(dayStart(date));
    if (onCollect != null) return onCollect!(date);
    return DailyMaterial(
      date: date,
      fileChanges: [
        FileChange(
          path: '${dateKey(date)}_file.txt',
          mtime: date,
          size: 1,
          kind: 'modify',
        ),
      ],
    );
  }
}

Widget _wrap(_FakeController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: const MaterialApp(home: HomePage()),
  );
}

void main() {
  testWidgets('点击右箭头切换日期后重新收集素材并更新文件变更列表', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(_wrap(controller));
    // 初始刷新（initState → 今天）
    await tester.pump();
    await tester.pump();

    expect(controller.collectedDates.length, 1);
    final firstDate = controller.collectedDates.first;
    expect(find.textContaining('${dateKey(firstDate)}_file.txt'), findsOneWidget);

    // 点击右箭头（下一天）
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    await tester.pump();

    // 契约 1：必须重新收集素材且传入新日期（修复前此处只有 1 次调用）
    expect(controller.collectedDates.length, 2,
        reason: '切换日期后应重新收集素材');
    final secondDate = controller.collectedDates[1];
    expect(secondDate, firstDate.add(const Duration(days: 1)));

    // 契约 2：文件变更列表跟随日期更新
    expect(find.textContaining('${dateKey(secondDate)}_file.txt'), findsOneWidget);
    expect(find.textContaining('${dateKey(firstDate)}_file.txt'), findsNothing);
  });

  testWidgets('点击左箭头切换日期后重新收集素材并更新文件变更列表', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();

    expect(controller.collectedDates.length, 1);
    final firstDate = controller.collectedDates.first;
    expect(find.textContaining('${dateKey(firstDate)}_file.txt'), findsOneWidget);

    // 点击左箭头（前一天）
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    await tester.pump();

    expect(controller.collectedDates.length, 2,
        reason: '切换日期后应重新收集素材');
    final secondDate = controller.collectedDates[1];
    expect(secondDate, firstDate.subtract(const Duration(days: 1)));

    expect(find.textContaining('${dateKey(secondDate)}_file.txt'), findsOneWidget);
    expect(find.textContaining('${dateKey(firstDate)}_file.txt'), findsNothing);
  });

  testWidgets('快速连续切换日期：旧日期的响应不覆盖新日期素材', (tester) async {
    // 每次收集都挂起，由测试控制完成顺序（模拟慢收集下的并发刷新）
    final pending = <DateTime, Completer<DailyMaterial>>{};
    final controller = _FakeController(
      onCollect: (date) {
        final completer = Completer<DailyMaterial>();
        pending[dayStart(date)] = completer;
        return completer.future;
      },
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pump();
    await tester.pump();
    final date0 = controller.collectedDates[0];

    // 连点两次右箭头：date1、date2 的收集都挂起
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    final date1 = controller.collectedDates[1];
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    final date2 = controller.collectedDates[2];

    // 响应乱序返回：新日期先回，旧日期后回
    DailyMaterial materialOf(DateTime d) => DailyMaterial(
          date: d,
          fileChanges: [
            FileChange(
              path: '${dateKey(d)}_file.txt',
              mtime: d,
              size: 1,
              kind: 'modify',
            ),
          ],
        );
    pending[date2]!.complete(materialOf(date2));
    await tester.pump();
    await tester.pump();
    pending[date1]!.complete(materialOf(date1));
    await tester.pump();
    await tester.pump();
    pending[date0]!.complete(materialOf(date0));
    await tester.pump();
    await tester.pump();

    // 当前日期是 date2，最终展示的必须是 date2 的素材
    expect(find.text(dateKey(date2)), findsOneWidget);
    expect(find.textContaining('${dateKey(date2)}_file.txt'), findsOneWidget);
    expect(find.textContaining('${dateKey(date1)}_file.txt'), findsNothing);
    expect(find.textContaining('${dateKey(date0)}_file.txt'), findsNothing);
  });
}
