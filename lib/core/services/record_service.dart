/// 随手记录服务（DESIGN.md §5.1）：inbox append + 历史标签。
library;

import '../models/material.dart';
import '../models/settings.dart';
import '../util/markdown_util.dart';

class RecordService {
  final AppSettings settings;

  RecordService(this.settings);

  /// 记一条：`- [HH:mm] 内容 #标签` append 到 inbox/<今天>.md
  Future<void> addNote(String content) async {
    if (content.trim().isEmpty) return;
    await appendInbox(settings.logRoot, DateTime.now(), content);
  }

  /// 历史标签（标签自动补全数据源）
  Future<List<String>> tags() => collectTags(settings.logRoot);

  /// 某天的随手记录
  Future<List<QuickNote>> notesFor(DateTime date) =>
      readInbox(settings.logRoot, date);
}
