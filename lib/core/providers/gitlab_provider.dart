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
    List<String> extraAuthors = const [],
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
    // 并入日报的仓库白名单（issue #31）：配置了 selectedRepos 时只拉
    // 勾选的仓库；空列表 = 全部仓库（老配置向后兼容）
    final selected = filterReposBySelection(
      projects,
      instance.selectedRepos,
      (p) => (p['path_with_namespace'] as String? ?? p['path'] as String? ?? ''),
    );

    // 2. 多项目并行拉 commit
    // 主作者 + 额外账户合并为过滤串（issue #20）
    final authorFilter = mergeAuthorFilter(author, extraAuthors);
    final results = await Future.wait(
      selected.map(
          (p) => _fetchProjectCommits(p, base, token, date, instance, authorFilter)),
    );
    return results.expand((e) => e).toList();
  }

  Future<List<Commit>> _fetchProjectCommits(
    Map<String, dynamic> project,
    String base,
    String token,
    DateTime date,
    CodeInstance instance,
    String authorFilter,
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
      Commit? toCommit(Map<String, dynamic> c, {String? authorFilter}) {
        final authDate = DateTime.tryParse(c['authored_date'] as String? ?? '');
        if (authDate == null || !inNaturalDay(authDate, date)) return null;
        final authorName = c['author_name'] as String? ?? '';
        final authorEmail = c['author_email'] as String? ?? '';
        if (authorFilter != null &&
            !authorMatches(authorFilter, [authorName, authorEmail])) {
          return null;
        }
        return buildCommit(
          sha: c['id'] as String? ?? '',
          message: c['message'] as String? ?? c['title'] as String? ?? '',
          project: path,
          author: authorName,
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

  @override
  Future<List<CommitAuthor>> fetchCommitAuthors({
    required CodeInstance instance,
    required String token,
    int maxCommitsPerRepo = 100,
  }) async {
    final base = _apiBase(instance.baseUrl);
    String auth() => 'Bearer $token';

    // 1. 项目列表（分页，与 fetchCommits 同源）
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
    // 并入日报的仓库白名单（issue #31）：作者拉取与采集同源——用户限定
    // 了并入仓库范围后，作者也只从这些仓库拉取
    final selected = filterReposBySelection(
      projects,
      instance.selectedRepos,
      (p) => (p['path_with_namespace'] as String? ?? p['path'] as String? ?? ''),
    );

    // 2. 多项目并行拉提交作者
    final results = await Future.wait(selected.map(
        (p) => _fetchProjectAuthors(p, base, token, instance, maxCommitsPerRepo)));
    final seen = <String>{};
    return results
        .expand((e) => e)
        .where((a) => seen.add(a.key.toLowerCase()))
        .toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  }

  /// 拉取单个项目最近提交的作者（issue #20 第二轮）：
  /// 逐页回看最多 [maxCommitsPerRepo] 条提交，收集 author_name/author_email。
  Future<List<CommitAuthor>> _fetchProjectAuthors(
    Map<String, dynamic> project,
    String base,
    String token,
    CodeInstance instance,
    int maxCommitsPerRepo,
  ) async {
    final path = project['path_with_namespace'] as String? ?? project['path'] as String? ?? '';
    if (path.isEmpty) return const [];
    // 可见性过滤（与 fetchCommits 一致）
    final visibility = project['visibility'] as String?;
    if (instance.visibilityFilter.isNotEmpty &&
        visibility != null &&
        visibility != instance.visibilityFilter) {
      return const [];
    }

    try {
      final commits = <Map<String, dynamic>>[];
      for (var page = 1; commits.length < maxCommitsPerRepo && page <= 20; page++) {
        final resp = await _dio.get(
          '$base/projects/${Uri.encodeComponent(path)}/repository/commits',
          queryParameters: {
            'per_page': 100,
            'page': page,
            if (instance.defaultBranch.isNotEmpty) 'ref_name': instance.defaultBranch,
          },
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        final list = resp.data as List? ?? [];
        if (list.isEmpty) break;
        commits.addAll(list.whereType<Map<String, dynamic>>());
        if (list.length < 100) break;
      }
      return commits
          .take(maxCommitsPerRepo)
          .map((c) => CommitAuthor(
                name: c['author_name'] as String? ?? '',
                email: c['author_email'] as String? ?? '',
              ))
          .where((a) => a.key.isNotEmpty)
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

  @override
  Future<List<String>> fetchRepositories({
    required CodeInstance instance,
    required String token,
  }) async {
    final base = _apiBase(instance.baseUrl);
    // 项目列表（分页，与 fetchCommits 同源）：membership=true 拉我参与的
    // 项目，返回 path_with_namespace（回退 path）作为勾选值——与采集时
    // Commit.project 的取值一致，保证勾选必然命中采集过滤。
    final projects = await paginate(
      _dio,
      '$base/projects',
      query: (page) => {
        'membership': true,
        'simple': true,
        'per_page': 100,
        'page': page,
      },
      authHeader: () => 'Bearer $token',
    );
    final names = <String>{};
    for (final p in projects) {
      final path = p['path_with_namespace'] as String? ??
          p['path'] as String? ??
          '';
      if (path.trim().isNotEmpty) names.add(path.trim());
    }
    final list = names.toList()..sort();
    return list;
  }
}
