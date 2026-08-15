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
    /// 并入采集的额外账户（issue #20）：agent/code01 等辅助账户的提交
    /// 与主作者的提交一并保留
    List<String> extraAuthors = const [],
  });

  /// 拉取实例内所有仓库的提交作者（跨仓库去重，issue #20 第二轮）：
  /// 供设置页展示真实作者列表，用户勾选「并入代码提交的账户」。
  /// [maxCommitsPerRepo] 限制每个仓库回看的最近提交条数（防大仓库超时）。
  Future<List<CommitAuthor>> fetchCommitAuthors({
    required CodeInstance instance,
    required String token,
    int maxCommitsPerRepo = 100,
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

/// 配置的作者名拆分为多个匹配值：中英文逗号、分号分隔，忽略空段。
/// 第一个非空值用于日报署名，全部值用于 commit 过滤。
List<String> splitAuthorValues(String author) => author
    .split(RegExp(r'[,，;；]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// 主作者与额外账户合并为作者过滤串（issue #20）：agent/code01 等辅助
/// 账户的提交并入采集。两者逗号连接后交给 [authorMatches] 的多值匹配。
String mergeAuthorFilter(String author, List<String> extraAuthors) =>
    [author, ...extraAuthors]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(',');

/// 作者匹配（issue #9）：配置值与 commit 作者字段（姓名/邮箱/登录名）做
/// 双向子串匹配、不区分大小写；配置多个值时任一命中即匹配。
/// 配置为空 → 不过滤。
bool authorMatches(String author, List<String?> fields) {
  final values = splitAuthorValues(author);
  if (values.isEmpty) return true;
  return fields.whereType<String>().any((f) {
    final lf = f.toLowerCase();
    return values.any((v) {
      final lv = v.toLowerCase();
      return lf.contains(lv) || lv.contains(lf);
    });
  });
}

/// 通用 Dio 实例
Dio defaultDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ));
