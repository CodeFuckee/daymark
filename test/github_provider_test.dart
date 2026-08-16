/// GitHub Provider 测试：提交作者拉取（issue #20 第二轮）。
///
/// 契约：
/// - fetchCommitAuthors 遍历 user/repos 仓库，收集 commit.author 的
///   name/email（name 为空回退 GitHub 登录名），跨仓库去重排序；
/// - 单仓库 401/403/404 跳过不阻断整体；
/// - 每仓库最多回看 maxCommitsPerRepo 条提交（分页截止）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/providers/github_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 adapter：按请求 path 返回模拟 GitHub 响应（不发起真实网络）。
class _FakeAdapter implements HttpClientAdapter {
  /// 仓库列表响应
  List<Map<String, dynamic>> repos;
  /// 按仓库 full_name 区分的提交
  Map<String, List<Map<String, dynamic>>> commitsByRepo;
  /// 按仓库 full_name 注入的 HTTP 状态码
  Map<String, int> statusByRepo;
  /// 收到的请求（path, queryParameters）
  final List<(String, Map<String, dynamic>)> requests = [];

  _FakeAdapter({
    this.repos = const [
      {'full_name': 'ckd/daymark', 'visibility': 'public'},
    ],
    this.commitsByRepo = const {},
    this.statusByRepo = const {},
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((options.uri.path, options.queryParameters));
    if (options.uri.path.contains('/commits')) {
      // GitHub 提交路径形如 /repos/{owner}/{repo}/commits，full_name 未编码
      final segs = options.uri.path.split('/');
      final fullName = '${segs[segs.length - 3]}/${segs[segs.length - 2]}';
      final status = statusByRepo[fullName] ?? 200;
      if (status != 200) {
        return ResponseBody.fromString(
          jsonEncode({'message': 'denied'}),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      final all = commitsByRepo[fullName] ?? const [];
      final page = (options.queryParameters['page'] as int?) ?? 1;
      final perPage = (options.queryParameters['per_page'] as int?) ?? 100;
      final slice = all.skip((page - 1) * perPage).take(perPage).toList();
      return ResponseBody.fromString(
        jsonEncode(slice),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(repos),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _ghCommit({
  required String id,
  String name = 'chenkaidi',
  String email = '935637782@qq.com',
  String login = 'gh-user',
}) =>
    {
      'sha': id,
      'commit': {
        'message': '提交 $id',
        'author': {'name': name, 'email': email, 'date': '2026-08-11T10:00:00+08:00'},
      },
      'author': {'login': login},
    };

Future<List<CommitAuthor>> _fetchAuthors(_FakeAdapter adapter,
    {int maxCommitsPerRepo = 100}) async {
  final dio = Dio()..httpClientAdapter = adapter;
  final provider = GitHubProvider(dio: dio);
  return provider.fetchCommitAuthors(
    instance: CodeInstance(
      id: 'gh1',
      providerType: 'github',
      baseUrl: 'https://api.github.com',
    ),
    token: 'test-token',
    maxCommitsPerRepo: maxCommitsPerRepo,
  );
}

void main() {
  group('GitHubProvider 拉取提交作者（issue #20 第二轮）', () {
    test('收集提交作者：name 优先，name 为空回退登录名', () async {
      final adapter = _FakeAdapter(
        commitsByRepo: {
          'ckd/daymark': [
            _ghCommit(id: 'a1', name: 'chenkaidi'),
            _ghCommit(id: 'a2', name: '', email: '', login: 'bot-42'),
          ],
        },
      );
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['bot-42', 'chenkaidi'],
          reason: 'name 为空时用 GitHub 登录名兜底，按名排序');
    });

    test('多仓库合并去重（不区分大小写）', () async {
      final adapter = _FakeAdapter(
        repos: [
          {'full_name': 'ckd/daymark', 'visibility': 'public'},
          {'full_name': 'ckd/shipyard', 'visibility': 'private'},
        ],
        commitsByRepo: {
          'ckd/daymark': [
            _ghCommit(id: 'a1', name: 'chenkaidi'),
            _ghCommit(id: 'a2', name: 'agent', email: 'agent@example.com'),
          ],
          'ckd/shipyard': [
            _ghCommit(id: 'b1', name: 'CHENKAIDI'),
          ],
        },
      );
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['agent', 'chenkaidi']);
    });

    test('单仓库 404 跳过，其他仓库作者正常返回', () async {
      final adapter = _FakeAdapter(
        repos: [
          {'full_name': 'ckd/daymark', 'visibility': 'public'},
          {'full_name': 'ckd/gone', 'visibility': 'public'},
        ],
        statusByRepo: {'ckd/gone': 404},
        commitsByRepo: {
          'ckd/daymark': [
            _ghCommit(id: 'a1', name: 'chenkaidi'),
          ],
        },
      );
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['chenkaidi']);
    });

    test('每仓库最多回看 maxCommitsPerRepo 条提交（分页截止）', () async {
      final many = [
        for (var i = 0; i < 150; i++) _ghCommit(id: 'c$i', name: 'author$i'),
      ];
      final adapter = _FakeAdapter(commitsByRepo: {'ckd/daymark': many});
      final authors = await _fetchAuthors(adapter, maxCommitsPerRepo: 50);
      expect(authors, hasLength(50));
      expect(authors.map((a) => a.key).toSet(),
          {for (var i = 0; i < 50; i++) 'author$i'},
          reason: '只回看前 50 条提交的作者');
      final commitRequests =
          adapter.requests.where((r) => r.$1.contains('/commits')).toList();
      expect(commitRequests.map((r) => r.$2['page']), [1],
          reason: '已达回看上限，不应继续翻页');
    });
  });

  group('GitHubProvider 仓库选择（issue #31）', () {
    test('fetchRepositories 返回 user/repos 的 full_name（排序）', () async {
      final adapter = _FakeAdapter(repos: [
        {'full_name': 'ckd/shipyard', 'visibility': 'public'},
        {'full_name': 'ckd/daymark', 'visibility': 'private'},
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitHubProvider(dio: dio);
      final repos = await provider.fetchRepositories(
        instance: CodeInstance(
          id: 'gh1',
          providerType: 'github',
          baseUrl: 'https://api.github.com',
        ),
        token: 'test-token',
      );
      expect(repos, ['ckd/daymark', 'ckd/shipyard'],
          reason: 'full_name 为勾选值（与 Commit.project 一致），按名排序');
      final repoRequests =
          adapter.requests.where((r) => r.$1.endsWith('/user/repos')).toList();
      expect(repoRequests, isNotEmpty,
          reason: '与采集同源：owner+collaborator 拉仓库列表');
      expect(repoRequests.first.$2['affiliation'], 'owner,collaborator');
    });

    test('selectedRepos 为空（老配置）→ 拉取全部仓库提交', () async {
      final adapter = _FakeAdapter(
        repos: [
          {'full_name': 'ckd/daymark', 'visibility': 'public'},
          {'full_name': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByRepo: {
          'ckd/daymark': [_ghCommit(id: 'a1')],
          'ckd/shipyard': [_ghCommit(id: 'b1')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitHubProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gh1',
          providerType: 'github',
          baseUrl: 'https://api.github.com',
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result.map((c) => c.sha), ['a1', 'b1']);
    });

    test('selectedRepos 只拉勾选仓库的提交，未勾选仓库不发请求', () async {
      final adapter = _FakeAdapter(
        repos: [
          {'full_name': 'ckd/daymark', 'visibility': 'public'},
          {'full_name': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByRepo: {
          'ckd/daymark': [_ghCommit(id: 'a1')],
          'ckd/shipyard': [_ghCommit(id: 'b1')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitHubProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gh1',
          providerType: 'github',
          baseUrl: 'https://api.github.com',
          selectedRepos: const ['ckd/daymark'],
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result.map((c) => c.sha), ['a1'],
          reason: '只并入勾选的 ckd/daymark');
      final commitPaths = adapter.requests
          .where((r) => r.$1.contains('/commits'))
          .map((r) {
        final segs = r.$1.split('/');
        return '${segs[segs.length - 3]}/${segs[segs.length - 2]}';
      }).toList();
      expect(commitPaths, ['ckd/daymark'],
          reason: '未勾选的 ckd/shipyard 不应发起提交请求');
    });

    test('勾选仓库不在仓库列表中（无权限/已删除）→ 跳过不报错', () async {
      final adapter = _FakeAdapter(repos: [
        {'full_name': 'ckd/daymark', 'visibility': 'public'},
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitHubProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gh1',
          providerType: 'github',
          baseUrl: 'https://api.github.com',
          selectedRepos: const ['ckd/ghost'],
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result, isEmpty);
    });

    test('fetchCommitAuthors 按 selectedRepos 过滤仓库（与采集同源）', () async {
      final adapter = _FakeAdapter(
        repos: [
          {'full_name': 'ckd/daymark', 'visibility': 'public'},
          {'full_name': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByRepo: {
          'ckd/daymark': [_ghCommit(id: 'a1', name: 'chenkaidi')],
          'ckd/shipyard': [_ghCommit(id: 'b1', name: 'lisi')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitHubProvider(dio: dio);
      final authors = await provider.fetchCommitAuthors(
        instance: CodeInstance(
          id: 'gh1',
          providerType: 'github',
          baseUrl: 'https://api.github.com',
          selectedRepos: const ['ckd/shipyard'],
        ),
        token: 'test-token',
      );
      expect(authors.map((a) => a.key), ['lisi'],
          reason: '只从勾选的 ckd/shipyard 拉作者');
    });
  });
}