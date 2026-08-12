/// GitLab Provider（DESIGN.md §5.2）：REST API v4，支持多实例多 token。
///
/// 沿用 collect.py 语义：membership=true 拉我参与的项目，多项目并行，
/// 按自然日 since/until 过滤，commit 按 author 匹配。
library;

import 'package:dio/dio.dart';

import '../models/material.dart';
import '../models/settings.dart';
import '../util/date_util.dart';
import 'code_provider.dart';

class GitLabProvider implements CodeProvider {
  final Dio _dio;

  GitLabProvider({Dio? dio}) : _dio = dio ?? defaultDio();

  @override
  String get providerType => 'gitlab';

  @override
  Future<List<Commit>> fetchCommits({
    required DateTime date,
    required CodeInstance instance,
    required String token,
    required String author,
  }) async {
    final base = _apiBase(instance.baseUrl);
    String auth() => 'Bearer $token';

    // 1. 项目列表（分页）
    final projects = await paginate(
      _dio,
      '$base/projects',
      query: (page) => {
        'membership': true,
        'simple': true,
        'per_page': 100,
        'page': page,
      },
      authHeader: auth,
    );

    // 2. 多项目并行拉 commit
    final results = await Future.wait(
      projects.map((p) => _fetchProjectCommits(p, base, token, date, instance, author)),
    );
    return results.expand((e) => e).toList();
  }

  Future<List<Commit>> _fetchProjectCommits(
    Map<String, dynamic> project,
    String base,
    String token,
    DateTime date,
    CodeInstance instance,
    String author,
  ) async {
    final path = project['path_with_namespace'] as String? ?? project['path'] as String? ?? '';
    if (path.isEmpty) return const [];
    // 可见性过滤（配置了才过滤）
    final visibility = project['visibility'] as String?;
    if (instance.visibilityFilter.isNotEmpty &&
        visibility != null &&
        visibility != instance.visibilityFilter) {
      return const [];
    }

    try {
      final resp = await _dio.get(
        '$base/projects/${Uri.encodeComponent(path)}/repository/commits',
        queryParameters: {
          'since': isoDay(date),
          'until': isoNextDay(date),
          'per_page': 100,
          if (instance.defaultBranch.isNotEmpty) 'ref_name': instance.defaultBranch,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final list = resp.data as List? ?? [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((c) {
            final authDate = DateTime.tryParse(c['authored_date'] as String? ?? '');
            if (authDate == null || !inNaturalDay(authDate, date)) return null;
            final authorName = c['author_name'] as String? ?? '';
            final authorEmail = c['author_email'] as String? ?? '';
            if (!authorMatches(author, [authorName, authorEmail])) return null;
            return buildCommit(
              sha: c['id'] as String? ?? '',
              message: c['message'] as String? ?? c['title'] as String? ?? '',
              project: path,
              author: authorName,
              date: authDate,
              providerType: providerType,
            );
          })
          .whereType<Commit>()
          .where((c) => c.sha.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      // 单项目失败（如无权限）不阻断整体
      final detail = e.response?.statusCode;
      if (detail == 401 || detail == 403 || detail == 404) {
        return const [];
      }
      rethrow;
    }
  }

  /// 兼容"已带 /api/v4"与"只给根地址"两种配置
  static String _apiBase(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base.endsWith('/api/v4') ? base : '$base/api/v4';
  }
}
