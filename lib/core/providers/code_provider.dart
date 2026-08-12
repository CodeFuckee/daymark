/// 代码数据源抽象（DESIGN.md §5.2）：GitLab / GitHub 多实例。
library;

import 'package:dio/dio.dart';

import '../models/material.dart';
import '../models/settings.dart';
import '../util/date_util.dart';

class CodeProviderException implements Exception {
  final String message;
  CodeProviderException(this.message);
  @override
  String toString() => message;
}

/// 按自然日拉取"我的"提交
abstract class CodeProvider {
  /// gitlab | github
  String get providerType;

  Future<List<Commit>> fetchCommits({
    required DateTime date,
    required CodeInstance instance,
    required String token,
    required String author,
  });
}

/// 共享工具：分页翻页直到结果为空
Future<List<Map<String, dynamic>>> paginate(
  Dio dio,
  String path, {
  required Map<String, dynamic> Function(int page) query,
  required String Function() authHeader,
  int perPage = 100,
}) async {
  final out = <Map<String, dynamic>>[];
  for (var page = 1; page <= 20; page++) {
    final resp = await dio.get(
      path,
      queryParameters: query(page),
      options: Options(headers: {'Authorization': authHeader()}),
    );
    final data = resp.data;
    final list = data is List ? data.cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    if (list.isEmpty) break;
    out.addAll(list);
    if (list.length < perPage) break;
  }
  return out;
}

/// 统一构造 Commit（子类复用）
Commit buildCommit({
  required String sha,
  required String message,
  required String project,
  required String author,
  required DateTime date,
  required String providerType,
}) =>
    Commit(
      sha: sha,
      message: message.trim(),
      project: project,
      author: author,
      date: date,
      provider: providerType,
    );

/// 自然日过滤：commit 时间落在 [dayStart, dayStart+1) 内
bool inNaturalDay(DateTime commitDate, DateTime date) {
  final start = dayStart(date);
  final end = start.add(const Duration(days: 1));
  return !commitDate.isBefore(start) && commitDate.isBefore(end);
}

/// 作者匹配：配置名（姓名/邮箱/登录名）与 commit 作者任一字段包含匹配
bool authorMatches(String author, List<String?> fields) =>
    author.isEmpty || fields.whereType<String>().any((f) => f.contains(author));

/// 通用 Dio 实例
Dio defaultDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ));
