/// 报告服务（DESIGN.md §5.6/§7.4）：日报/周报/月报流水线编排。
///
/// - 生成可重入：初稿落 `.daymark/草稿/`，已定稿的日报不覆盖
/// - 定稿：写 `日报/YYYY-MM-DD-工作日报.md` 并删草稿
/// - 周报/月报：聚合期内日报要点 + inbox，已存在不覆盖
library;

import 'dart:io';

import '../models/material.dart';
import '../models/settings.dart';
import '../report/report_engine.dart';
import '../util/date_util.dart';
import '../util/markdown_util.dart';
import 'collect_service.dart';

class ReportService {
  final AppSettings settings;
  final CollectService collector;
  final ReportEngine engine;

  ReportService(this.settings, {CollectService? collector, ReportEngine? engine})
      : collector = collector ?? CollectService(settings),
        engine = engine ?? ReportEngine(settings);

  /// 收集某天素材（含转录，后台执行）
  Future<DailyMaterial> collect(DateTime date, {void Function(String)? onProgress}) =>
      collector.collectForDate(date, includeTranscripts: true, onProgress: onProgress);

  /// 生成日报初稿并落草稿。已定稿时返回 null（不重新生成）。
  Future<String?> generateDaily(
    DateTime date, {
    DailyMaterial? material,
    void Function(String)? onProgress,
  }) async {
    if (isFinalized(settings.logRoot, date)) return null;
    final m = material ?? await collectForDate(date, onProgress: onProgress);
    final draft = await engine.draftDaily(m);
    await writeDraft(settings.logRoot, date, draft);
    return draft;
  }

  Future<DailyMaterial> collectForDate(DateTime date, {void Function(String)? onProgress}) =>
      collector.collectForDate(date, includeTranscripts: false, onProgress: onProgress);

  /// 定稿：写正式日报
  Future<void> finalizeDaily(DateTime date, String content) =>
      finalizeReport(settings.logRoot, date, content);

  /// 生成周报。返回 null 表示已存在或期内无素材。
  Future<String?> generateWeekly(DateTime date) async {
    final start = _mondayOf(date);
    final end = start.add(const Duration(days: 6));
    return _generateAggregate(start: start, end: end, monthly: false);
  }

  /// 生成月报。返回 null 表示已存在或期内无素材。
  Future<String?> generateMonthly(DateTime date) async {
    final start = DateTime(date.year, date.month, 1);
    final end = DateTime(date.year, date.month + 1, 0);
    return _generateAggregate(start: start, end: end, monthly: true);
  }

  Future<String?> _generateAggregate({
    required DateTime start,
    required DateTime end,
    required bool monthly,
  }) async {
    final path = monthly
        ? monthlyReportPath(settings.logRoot, start)
        : weeklyReportPath(settings.logRoot, start);
    if (File(path).existsSync()) return null;

    // 期内日报要点（定稿优先，其次草稿）
    final summaries = <String>[];
    final notes = <QuickNote>[];
    for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      final report = await readExistingReport(settings.logRoot, d);
      if (report != null && report.trim().isNotEmpty) {
        summaries.add(report);
      }
      notes.addAll(await readInbox(settings.logRoot, d));
    }
    if (summaries.isEmpty && notes.isEmpty) return null;

    final draft = await engine.draftAggregate(
      start: start,
      end: end,
      dailySummaries: summaries,
      notes: notes,
      monthly: monthly,
    );
    final created = await writeAggregateReport(path, draft);
    return created ? draft : null;
  }

  static DateTime _mondayOf(DateTime date) {
    final d = dayStart(date);
    return d.subtract(Duration(days: d.weekday - 1));
  }
}
