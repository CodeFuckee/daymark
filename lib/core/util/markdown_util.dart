/// Markdown 存储工具（DESIGN.md §4）：inbox 读写、路径规则、定稿判定。
///
/// 目录结构：
/// ```
/// <日志根目录>/
/// ├── 日报/ 周报/ 月报/  inbox/  转写/   .daymark/
/// ├── .daymark/settings.json
/// ├── .daymark/素材缓存/<date>.json
/// └── .daymark/草稿/<date>.md          # 未定稿初稿（防覆盖已定稿）
/// ```
library;

import 'dart:convert';
import 'dart:io';

import '../models/material.dart';
import 'date_util.dart';

// ─────────────────────────── 路径规则 ───────────────────────────

String dailyReportPath(String logRoot, DateTime date) =>
    '$logRoot/日报/${dateKey(date)}-工作日报.md';

String weeklyReportPath(String logRoot, DateTime date) =>
    '$logRoot/周报/${weekKey(date)}-工作周报.md';

String monthlyReportPath(String logRoot, DateTime date) =>
    '$logRoot/月报/${monthKey(date)}-工作月报.md';

String inboxPath(String logRoot, DateTime date) => '$logRoot/inbox/${dateKey(date)}.md';

String draftPath(String logRoot, DateTime date) =>
    '$logRoot/.daymark/草稿/${dateKey(date)}.md';

String materialCachePath(String logRoot, DateTime date) =>
    '$logRoot/.daymark/素材缓存/${dateKey(date)}.json';

String settingsPath(String logRoot) => '$logRoot/.daymark/settings.json';

/// 定稿判定：日报文件存在即已定稿（重生成不覆盖）
bool isFinalized(String logRoot, DateTime date) =>
    File(dailyReportPath(logRoot, date)).existsSync();

/// 已存在的日报（含草稿）内容
Future<String?> readExistingReport(String logRoot, DateTime date) async {
  final finalized = File(dailyReportPath(logRoot, date));
  if (await finalized.exists()) {
    return finalized.readAsString();
  }
  final draft = File(draftPath(logRoot, date));
  if (await draft.exists()) {
    return draft.readAsString();
  }
  return null;
}

// ─────────────────────────── inbox ───────────────────────────

/// inbox 文件头
String inboxHeader(DateTime date) => '# ${dateKey(date)} 随手记录';

/// 追加一条随手记录（append 模式，[HH:mm] 前缀 + 行尾 #标签）
Future<void> appendInbox(
  String logRoot,
  DateTime date,
  String content,
) async {
  final dir = Directory('$logRoot/inbox');
  await dir.create(recursive: true);
  final file = File(inboxPath(logRoot, date));
  final tags = extractTags(content);
  final tagsStr = tags.isEmpty ? '' : ' ${tags.map((t) => '#$t').join(' ')}';
  // 内容剥离标签（用户输入已带 #标签 时避免重复）
  final line = '- [${hhmm(date)}] ${stripTags(content)}$tagsStr';

  if (await file.exists()) {
    await file.writeAsString('\n$line', mode: FileMode.append);
  } else {
    await file.writeAsString('${inboxHeader(date)}\n$line\n');
  }
}

/// 解析 inbox 文件 → 随手记录列表（容忍手工编辑）
Future<List<QuickNote>> readInbox(String logRoot, DateTime date) async {
  final file = File(inboxPath(logRoot, date));
  if (!await file.exists()) return const [];
  final lines = await file.readAsLines();
  final notes = <QuickNote>[];
  for (final line in lines) {
    // `- [09:12] 内容 #标签`
    final m = RegExp(r'^\s*-\s*\[(\d{1,2}:\d{2})\]\s*(.+?)\s*$').firstMatch(line);
    if (m == null) continue;
    final time = parseHhmm(m.group(1)!, date);
    if (time == null) continue;
    final text = m.group(2)!.trim();
    if (text.isEmpty) continue;
    final tags = extractTags(text);
    final content = stripTags(text);
    notes.add(QuickNote(time: time, content: content, tags: tags));
  }
  return notes;
}

/// 扫描历史 inbox 提取历史标签（标签补全数据源）
Future<List<String>> collectTags(String logRoot, {int maxFiles = 30}) async {
  final dir = Directory('$logRoot/inbox');
  if (!await dir.exists()) return const [];
  final files = await dir
      .list()
      .where((e) => e is File && e.path.endsWith('.md'))
      .toList();
  files.sort((a, b) => b.path.compareTo(a.path)); // 最近在前
  final tags = <String>{};
  for (final f in files.take(maxFiles)) {
    final lines = await (f as File).readAsLines();
    for (final line in lines) {
      final m = RegExp(r'^\s*-\s*\[(\d{1,2}:\d{2})\]\s*(.+?)\s*$').firstMatch(line);
      if (m == null) continue;
      tags.addAll(extractTags(m.group(2)!));
    }
  }
  final list = tags.toList();
  list.sort();
  return list;
}

/// 提取行内 #标签（中英文、数字、下划线，忽略纯数字）
List<String> extractTags(String text) {
  final tags = <String>{};
  for (final m in RegExp(r'#([\p{L}\p{N}_]+)', unicode: true).allMatches(text)) {
    final tag = m.group(1)!;
    if (tag.length > 20 || RegExp(r'^\d+$').hasMatch(tag)) continue;
    tags.add(tag);
  }
  return tags.toList();
}

/// 从内容中剥离行尾的 ` #标签` 序列（内容与标签分离存储）
String stripTags(String text) {
  return text.replaceFirst(RegExp(r'\s+#[\p{L}\p{N}_]+\s*$', unicode: true), '').trim();
}

// ─────────────────────────── 素材缓存 ───────────────────────────

Future<void> saveMaterialCache(String logRoot, DailyMaterial material) async {
  final dir = Directory('$logRoot/.daymark/素材缓存');
  await dir.create(recursive: true);
  final file = File(materialCachePath(logRoot, material.date));
  await file.writeAsString(jsonEncode(material.toJson()));
}

Future<DailyMaterial?> loadMaterialCache(String logRoot, DateTime date) async {
  final file = File(materialCachePath(logRoot, date));
  if (!await file.exists()) return null;
  try {
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return DailyMaterial.fromJson(decoded);
  } catch (_) {
    return null; // 缓存损坏视为无缓存，可重建
  }
}

// ─────────────────────────── 写盘 ───────────────────────────

/// 写初稿（草稿目录，不覆盖已定稿）
Future<void> writeDraft(String logRoot, DateTime date, String content) async {
  final file = File(draftPath(logRoot, date));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

/// 定稿：写正式日报文件并删除草稿
Future<void> finalizeReport(String logRoot, DateTime date, String content) async {
  final file = File(dailyReportPath(logRoot, date));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
  final draft = File(draftPath(logRoot, date));
  if (await draft.exists()) {
    await draft.delete();
  }
}

/// 新建周报/月报（存在则返回 false 不覆盖）
Future<bool> writeAggregateReport(String path, String content) async {
  final file = File(path);
  if (await file.exists()) return false;
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
  return true;
}
