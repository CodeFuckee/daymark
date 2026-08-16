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
    List<String> extraAuthors = const [],
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
    // 并入日报的仓库白名单（issue #31）：配置了 selectedRepos 时只拉
    // 勾选的仓库；空列表 = 全部仓库（老配置向后兼容）
    final selected = filterReposBySelection(
      repos,
      instance.selectedRepos,
      (r) => r['full_name'] as String? ?? '',
    );

    // 2. 并行拉每仓库 commit
    // 主作者 + 额外账户合并为过滤串（issue #20）
    final authorFilter = mergeAuthorFilter(author, extraAuthors);
    final results = await Future.wait(
      selected.map(
          (r) => _fetchRepoCommits(r, base, token, date, instance, authorFilter)),
    );
    return results.expand((e) => e).toList();
  }

  Future<List<Commit>> _fetchRepoCommits(
    Map<String, dynamic> repo,
    String base,
    String token,
    DateTime date,
    CodeInstance instance,
    String authorFilter,
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
      Commit? toCommit(Map<String, dynamic> c, {String? authorFilter}) {
        final commit = c['commit'] as Map<String, dynamic>? ?? {};
        final authorObj = commit['author'] as Map<String, dynamic>? ?? {};
        final commitAuthor = c['author'] as Map<String, dynamic>?;
        final authDate = DateTime.tryParse(authorObj['date'] as String? ?? '');
        if (authDate == null || !inNaturalDay(authDate, date)) return null;
        final name = authorObj['name'] as String? ?? '';
        final email = authorObj['email'] as String? ?? '';
        final login = commitAuthor?['login'] as String? ?? '';
        if (authorFilter != null &&
            !authorMatches(authorFilter, [name, email, login])) {
          return null;
        }
        return buildCommit(
          sha: c['sha'] as String? ?? '',
          message: commit['message'] as String? ?? '',
          project: fullName,
          author: name.isEmpty ? login : name,
          date: authDate,
          providerType: providerType,
        );
      }

      final maps = list.whereType<Map<String, dynamic>>().toList();
      final all = maps
          .map((c) => toCommit(c))
          .whereType<Commit>()
          .where((c) => c.sha.isNotEmpty)
          .toList();
      final filtered = maps
          .map((c) => toCommit(c, authorFilter: authorFilter))
          .whereType<Commit>()
          .where((c) => c.sha.isNotEmpty)
          .toList();
      // 作者过滤无命中 → 放行全部：配置署名（如中文名）与 git 用户名
      // 不一致时不应让"当日有提交"变成"当日无提交"（issue #9）；
      // 有命中时仅保留主作者 + 额外账户（issue #20）的提交
      if (filtered.isEmpty && all.isNotEmpty) return all;
      return filtered;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403 || status == 404) {
        return const [];
      }
      rethrow;
    }
  }

  @override
  Future<List<CommitAuthor>> fetchCommitAuthors({
    required CodeInstance instance,
    required String token,
    int maxCommitsPerRepo = 100,
  }) async {
    final base = instance.baseUrl.trim().isEmpty
        ? 'https://api.github.com'
        : instance.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    String auth() => 'Bearer $token';

    // 1. 我的仓库列表（与 fetchCommits 同源）
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
    // 并入日报的仓库白名单（issue #31）：作者拉取与采集同源——用户限定
    // 了并入仓库范围后，作者也只从这些仓库拉取
    final selected = filterReposBySelection(
      repos,
      instance.selectedRepos,
      (r) => r['full_name'] as String? ?? '',
    );

    // 2. 并行拉每仓库提交作者
    final results = await Future.wait(selected.map(
        (r) => _fetchRepoAuthors(r, base, token, instance, maxCommitsPerRepo)));
    final seen = <String>{};
    return results
        .expand((e) => e)
        .where((a) => seen.add(a.key.toLowerCase()))
        .toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  }

  /// 拉取单个仓库最近提交的作者（issue #20 第二轮）：
  /// 逐页回看最多 [maxCommitsPerRepo] 条提交，收集 commit.author 的
  /// name/email（name 为空回退 GitHub 登录名）。
  Future<List<CommitAuthor>> _fetchRepoAuthors(
    Map<String, dynamic> repo,
    String base,
    String token,
    CodeInstance instance,
    int maxCommitsPerRepo,
  ) async {
    final fullName = repo['full_name'] as String? ?? '';
    if (fullName.isEmpty) return const [];
    // 可见性过滤（与 fetchCommits 一致）
    if (instance.visibilityFilter.isNotEmpty) {
      final visibility = repo['visibility'] as String? ?? '';
      if (visibility.isNotEmpty && visibility != instance.visibilityFilter) {
        return const [];
      }
    }

    try {
      final commits = <Map<String, dynamic>>[];
      for (var page = 1; commits.length < maxCommitsPerRepo && page <= 20; page++) {
        final resp = await _dio.get(
          '$base/repos/$fullName/commits',
          queryParameters: {'per_page': 100, 'page': page},
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        final list = resp.data as List? ?? [];
        if (list.isEmpty) break;
        commits.addAll(list.whereType<Map<String, dynamic>>());
        if (list.length < 100) break;
      }
      return commits
          .take(maxCommitsPerRepo)
          .map((c) {
        final commit = c['commit'] as Map<String, dynamic>? ?? {};
        final authorObj = commit['author'] as Map<String, dynamic>? ?? {};
        final login = (c['author'] as Map<String, dynamic>?)?['login'] as String? ?? '';
        final name = authorObj['name'] as String? ?? '';
        return CommitAuthor(
          // name 为空（含空串）回退 GitHub 登录名
          name: name.trim().isEmpty ? login : name,
          email: authorObj['email'] as String? ?? '',
        );
      })
          .where((a) => a.key.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403 || status == 404) {
        return const [];
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> fetchRepositories({
    required CodeInstance instance,
    required String token,
  }) async {
    final base = instance.baseUrl.trim().isEmpty
        ? 'https://api.github.com'
        : instance.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    // 我的仓库列表（分页，与 fetchCommits 同源）：返回 full_name 作为
    // 勾选值——与采集时 Commit.project 的取值一致，保证勾选必然命中采集过滤。
    final repos = await paginate(
      _dio,
      '$base/user/repos',
      query: (page) => {
        'per_page': 100,
        'page': page,
        'affiliation': 'owner,collaborator',
        'sort': 'updated',
      },
      authHeader: () => 'Bearer $token',
    );
    final names = <String>{};
    for (final r in repos) {
      final fullName = r['full_name'] as String? ?? '';
      if (fullName.trim().isNotEmpty) names.add(fullName.trim());
    }
    final list = names.toList()..sort();
    return list;
  }
}
