/// GitHub Provider（DESIGN.md §5.2）：REST API v3，支持多账号。
library;

import 'package:dio/dio.dart';

import '../models/material.dart';
import '../models/settings.dart';
import '../util/date_util.dart';
import 'code_provider.dart';

class GitHubProvider implements CodeProvider {
  final Dio _dio;

  GitHubProvider({Dio? dio}) : _dio = dio ?? defaultDio();

  @override
  String get providerType => 'github';

  @override
  Future<List<Commit>> fetchCommits({
    required DateTime date,
    required CodeInstance instance,
    required String token,
    required String author,
  }) async {
    final base = instance.baseUrl.trim().isEmpty
        ? 'https://api.github.com'
        : instance.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    String auth() => 'Bearer $token';

    // 1. 我的仓库列表（owner + collaborator，分页）
    final repos = await paginate(
      _dio,
      '$base/user/repos',
      query: (page) => {
        'per_page': 100,
        'page': page,
        'affiliation': 'owner,collaborator',
        'sort': 'updated',
      },
      authHeader: auth,
    );

    // 2. 并行拉每仓库 commit
    final results = await Future.wait(
      repos.map((r) => _fetchRepoCommits(r, base, token, date, instance, author)),
    );
    return results.expand((e) => e).toList();
  }

  Future<List<Commit>> _fetchRepoCommits(
    Map<String, dynamic> repo,
    String base,
    String token,
    DateTime date,
    CodeInstance instance,
    String author,
  ) async {
    final fullName = repo['full_name'] as String? ?? '';
    if (fullName.isEmpty) return const [];
    // 可见性过滤：GitHub 用 visibility: public/private
    if (instance.visibilityFilter.isNotEmpty) {
      final visibility = repo['visibility'] as String? ?? '';
      if (visibility.isNotEmpty && visibility != instance.visibilityFilter) {
        return const [];
      }
    }

    try {
      final resp = await _dio.get(
        '$base/repos/$fullName/commits',
        queryParameters: {
          'since': isoDay(date),
          'until': isoNextDay(date),
          'per_page': 100,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final list = resp.data as List? ?? [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((c) {
            final commit = c['commit'] as Map<String, dynamic>? ?? {};
            final authorObj = commit['author'] as Map<String, dynamic>? ?? {};
            final commitAuthor = c['author'] as Map<String, dynamic>?;
            final authDate = DateTime.tryParse(authorObj['date'] as String? ?? '');
            if (authDate == null || !inNaturalDay(authDate, date)) return null;
            final name = authorObj['name'] as String? ?? '';
            final email = authorObj['email'] as String? ?? '';
            final login = commitAuthor?['login'] as String? ?? '';
            if (!authorMatches(author, [name, email, login])) return null;
            return buildCommit(
              sha: c['sha'] as String? ?? '',
              message: commit['message'] as String? ?? '',
              project: fullName,
              author: name.isEmpty ? login : name,
              date: authDate,
              providerType: providerType,
            );
          })
          .whereType<Commit>()
          .where((c) => c.sha.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403 || status == 404) {
        return const [];
      }
      rethrow;
    }
  }
}
