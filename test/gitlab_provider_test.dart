import 'dart:convert';
import 'dart:typed_data';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/providers/gitlab_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 adapter：按请求 path 返回模拟 GitLab 响应（不发起真实网络）。
class _FakeAdapter implements HttpClientAdapter {
  /// 提交响应内容（单仓库模式，与旧测试兼容）
  List<Map<String, dynamic>>? commits;
  /// 按项目路径区分的提交（多项目/作者拉取测试用）
  Map<String, List<Map<String, dynamic>>> commitsByProject;
  /// 按项目路径注入的 HTTP 状态码（模拟无权限/不存在）
  Map<String, int> statusByProject;
  /// 项目列表响应
  List<Map<String, dynamic>> projects;
  /// 收到的请求（path, queryParameters），供测试断言分页/分支参数
  final List<(String, Map<String, dynamic>)> requests = [];

  _FakeAdapter({
    this.commits,
    this.commitsByProject = const {},
    this.statusByProject = const {},
    List<Map<String, dynamic>>? projects,
  }) : projects = projects ?? [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
        ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((options.uri.path, options.queryParameters));
    if (options.uri.path.contains('/repository/commits')) {
      // 提交接口：项目路径是 /projects/<encodeComponent(path)> 段
      // （编码后无 '/',如 ckd%2Fdaymark），解码后按项目出响应
      final segs = options.uri.path.split('/');
      final projectPath = Uri.decodeComponent(segs[segs.indexOf('projects') + 1]);
      final status = statusByProject[projectPath] ?? 200;
      if (status != 200) {
        return ResponseBody.fromString(
          jsonEncode({'message': 'denied'}),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      final all = commitsByProject[projectPath] ?? commits ?? const [];
      // 分页截取（与 GitLab API 一致）
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
      jsonEncode(projects),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _commit({
  required String id,
  required String authorName,
  String authorEmail = '935637782@qq.com',
  String authoredAt = '2026-08-11T10:00:00.000+08:00',
}) =>
    {
      'id': id,
      'title': '提交 $id',
      'message': '提交 $id',
      'author_name': authorName,
      'author_email': authorEmail,
      'authored_date': authoredAt,
    };

Future<List<dynamic>> _fetch({
  required List<Map<String, dynamic>> commits,
  required String author,
  List<String> extraAuthors = const [],
  List<String> selectedRepos = const [],
}) async {
  final dio = Dio();
  dio.httpClientAdapter = _FakeAdapter(commits: commits);
  final provider = GitLabProvider(dio: dio);
  final result = await provider.fetchCommits(
    date: DateTime(2026, 8, 11),
    instance: CodeInstance(
      id: 'gl1',
      providerType: 'gitlab',
      baseUrl: 'https://home.chenkaidi.top:509',
      selectedRepos: selectedRepos,
    ),
    token: 'test-token',
    author: author,
    extraAuthors: extraAuthors,
  );
  return result;
}

/// 拉取提交作者（issue #20 第二轮）测试入口
Future<List<CommitAuthor>> _fetchAuthors(
  _FakeAdapter adapter, {
  int maxCommitsPerRepo = 100,
  String defaultBranch = '',
}) async {
  final dio = Dio()..httpClientAdapter = adapter;
  final provider = GitLabProvider(dio: dio);
  return provider.fetchCommitAuthors(
    instance: CodeInstance(
      id: 'gl1',
      providerType: 'gitlab',
      baseUrl: 'https://home.chenkaidi.top:509',
      defaultBranch: defaultBranch,
    ),
    token: 'test-token',
    maxCommitsPerRepo: maxCommitsPerRepo,
  );
}

void main() {
  group('GitLabProvider 作者过滤（issue #9）', () {
    final commitsOf8_11 = [
      _commit(id: 'a1', authorName: 'chenkaidi'),
      _commit(id: 'a2', authorName: 'chenkaidi'),
    ];

    test('复现 #9：配置中文署名"陈凯迪"，英文提交全部被过滤 → 应放行全部', () async {
      final result = await _fetch(commits: commitsOf8_11, author: '陈凯迪');
      expect(result.length, 2);
      expect(result.map((c) => c.sha), ['a1', 'a2']);
    });

    test('多值配置（署名,git用户名）精确命中', () async {
      final result = await _fetch(commits: commitsOf8_11, author: '陈凯迪,chenkaidi');
      expect(result.length, 2);
    });

    test('有命中时仅保留命中的提交', () async {
      final mixed = [
        _commit(id: 'a1', authorName: 'chenkaidi'),
        _commit(id: 'a2', authorName: 'lisi', authorEmail: 'lisi@qq.com'),
      ];
      final result = await _fetch(commits: mixed, author: 'chenkaidi');
      expect(result.length, 1);
      expect(result.single.sha, 'a1');
    });

    test('作者名为空不过滤', () async {
      final result = await _fetch(commits: commitsOf8_11, author: '');
      expect(result.length, 2);
    });

    test('当日无提交返回空', () async {
      final result = await _fetch(commits: [], author: 'chenkaidi');
      expect(result, isEmpty);
    });
  });

  group('GitLabProvider 额外提交账户（issue #20）', () {
    // 用户自己的提交 + agent/code01 账户的提交混在同一天
    final mixedWithAgent = [
      _commit(id: 'a1', authorName: 'chenkaidi'),
      _commit(id: 'a2', authorName: 'agent', authorEmail: 'agent@example.com'),
      _commit(id: 'a3', authorName: 'code01', authorEmail: 'code01@example.com'),
    ];

    test('复现 #20：未配置额外账户时 agent/code01 提交被过滤（现状）', () async {
      final result = await _fetch(commits: mixedWithAgent, author: 'chenkaidi');
      expect(result.map((c) => c.sha), ['a1']);
    });

    test('配置额外账户后：主作者与额外账户的提交一并返回', () async {
      final result = await _fetch(
          commits: mixedWithAgent,
          author: 'chenkaidi',
          extraAuthors: ['agent', 'code01']);
      expect(result.map((c) => c.sha), ['a1', 'a2', 'a3']);
    });

    test('当日主作者无提交，仅额外账户有提交 → 返回额外账户提交', () async {
      final onlyAgent = [
        _commit(id: 'b1', authorName: 'agent', authorEmail: 'agent@example.com'),
      ];
      final result = await _fetch(
          commits: onlyAgent, author: 'chenkaidi', extraAuthors: ['agent']);
      expect(result.map((c) => c.sha), ['b1']);
    });

    test('主作者与额外账户都无提交但存在无关提交 → 兜底放行全部（issue #9 语义保持）', () async {
      final onlyOther = [
        _commit(id: 'c1', authorName: 'lisi', authorEmail: 'lisi@qq.com'),
      ];
      final result = await _fetch(
          commits: onlyOther, author: 'chenkaidi', extraAuthors: ['agent']);
      expect(result.map((c) => c.sha), ['c1']);
    });

    test('额外账户名匹配提交人姓名/邮箱任意字段', () async {
      final byEmail = [
        _commit(id: 'd1', authorName: 'Agent Bot', authorEmail: 'agent@example.com'),
      ];
      final result = await _fetch(
          commits: byEmail, author: 'chenkaidi', extraAuthors: ['agent']);
      expect(result.map((c) => c.sha), ['d1']);
    });
  });

  group('GitLabProvider 拉取提交作者（issue #20 第二轮）', () {
    test('复现 #20 第二轮：真实提交作者名与账户名不一致——拉取返回真实作者名', () async {
      // daymark 仓库中 agent 会话的提交 author_name 实为 'chenkaidi'（本地
      // git 身份），用户手动输入 'agent' 必然匹配不上——第一轮「还是没有
      // 显示提交」的根因。拉取真实作者后勾选，保存值与提交 author_name
      // 完全一致，必然命中采集过滤。
      final adapter = _FakeAdapter(commits: [
        _commit(id: 'a1', authorName: 'chenkaidi'),
        _commit(id: 'a2', authorName: 'chenkaidi'),
      ]);
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['chenkaidi'],
          reason: '真实作者名是 chenkaidi 而非 agent——勾选它必然命中提交过滤');
      expect(authors.single.display, 'chenkaidi <935637782@qq.com>');
    });

    test('多项目作者合并去重（作者名不区分大小写）并按名排序', () async {
      final adapter = _FakeAdapter(
        projects: [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
          {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByProject: {
          'ckd/daymark': [
            _commit(id: 'a1', authorName: 'chenkaidi'),
            _commit(id: 'a2', authorName: 'agent', authorEmail: 'agent@example.com'),
          ],
          'ckd/shipyard': [
            _commit(id: 'b1', authorName: 'CHENKAIDI'),
            _commit(id: 'b2', authorName: 'code01', authorEmail: 'code01@example.com'),
          ],
        },
      );
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['agent', 'chenkaidi', 'code01'],
          reason: '跨项目去重（大小写不敏感）并按作者名排序');
    });

    test('author_name 为空时保存值回退邮箱', () async {
      final adapter = _FakeAdapter(commits: [
        _commit(id: 'a1', authorName: '', authorEmail: 'bot@example.com'),
      ]);
      final authors = await _fetchAuthors(adapter);
      expect(authors.single.key, 'bot@example.com');
      expect(authors.single.display, 'bot@example.com');
    });

    test('单项目 401 跳过，其他项目作者正常返回', () async {
      final adapter = _FakeAdapter(
        projects: [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
          {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        ],
        statusByProject: {'ckd/daymark': 401},
        commitsByProject: {
          'ckd/shipyard': [
            _commit(id: 'b1', authorName: 'lisi', authorEmail: 'lisi@qq.com'),
          ],
        },
      );
      final authors = await _fetchAuthors(adapter);
      expect(authors.map((a) => a.key), ['lisi']);
    });

    test('每仓库最多回看 maxCommitsPerRepo 条提交（分页截止）', () async {
      final many = [
        for (var i = 0; i < 150; i++) _commit(id: 'c$i', authorName: 'author$i'),
      ];
      final adapter = _FakeAdapter(commits: many);
      final authors = await _fetchAuthors(adapter, maxCommitsPerRepo: 50);
      expect(authors, hasLength(50));
      expect(authors.map((a) => a.key).toSet(),
          {for (var i = 0; i < 50; i++) 'author$i'},
          reason: '只回看前 50 条提交的作者');
      final commitRequests = adapter.requests
          .where((r) => r.$1.contains('/repository/commits'))
          .toList();
      expect(commitRequests.map((r) => r.$2['page']), [1],
          reason: '已达回看上限，不应继续翻页');
    });

    test('defaultBranch 非空时提交请求携带 ref_name', () async {
      final adapter = _FakeAdapter(commits: [
        _commit(id: 'a1', authorName: 'chenkaidi'),
      ]);
      await _fetchAuthors(adapter, defaultBranch: 'main');
      final commitRequests = adapter.requests
          .where((r) => r.$1.contains('/repository/commits'))
          .toList();
      expect(commitRequests.single.$2['ref_name'], 'main');
    });
  });

  group('GitLabProvider 仓库选择（issue #31）', () {
    test('fetchRepositories 返回 membership 项目列表：path_with_namespace 优先、回退 path、排序', () async {
      final adapter = _FakeAdapter(projects: [
        {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
        {'id': 3, 'path': 'legacy', 'visibility': 'private'},
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitLabProvider(dio: dio);
      final repos = await provider.fetchRepositories(
        instance: CodeInstance(
          id: 'gl1',
          providerType: 'gitlab',
          baseUrl: 'https://git.example.com',
        ),
        token: 'test-token',
      );
      expect(repos, ['ckd/daymark', 'ckd/shipyard', 'legacy'],
          reason: '按名排序，path_with_namespace 缺失时回退 path');
      final projectRequests =
          adapter.requests.where((r) => r.$1.endsWith('/projects')).toList();
      expect(projectRequests, isNotEmpty,
          reason: '与采集同源：membership=true 拉项目列表');
      expect(projectRequests.first.$2['membership'], isTrue);
    });

    test('复现 #31：selectedRepos 为空（老配置）→ 拉取全部项目提交', () async {
      final adapter = _FakeAdapter(
        projects: [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
          {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByProject: {
          'ckd/daymark': [_commit(id: 'a1', authorName: 'chenkaidi')],
          'ckd/shipyard': [_commit(id: 'b1', authorName: 'chenkaidi')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitLabProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gl1',
          providerType: 'gitlab',
          baseUrl: 'https://git.example.com',
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result.map((c) => c.sha), ['a1', 'b1']);
    });

    test('selectedRepos 只拉勾选仓库的提交，未勾选仓库不发请求', () async {
      final adapter = _FakeAdapter(
        projects: [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
          {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByProject: {
          'ckd/daymark': [_commit(id: 'a1', authorName: 'chenkaidi')],
          'ckd/shipyard': [_commit(id: 'b1', authorName: 'chenkaidi')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitLabProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gl1',
          providerType: 'gitlab',
          baseUrl: 'https://git.example.com',
          selectedRepos: const ['ckd/daymark'],
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result.map((c) => c.sha), ['a1'],
          reason: '只并入勾选的 ckd/daymark');
      final commitPaths = adapter.requests
          .where((r) => r.$1.contains('/repository/commits'))
          .map((r) => Uri.decodeComponent(
              r.$1.split('/')[r.$1.split('/').indexOf('projects') + 1]))
          .toList();
      expect(commitPaths, ['ckd/daymark'],
          reason: '未勾选的 ckd/shipyard 不应发起提交请求');
    });

    test('勾选仓库不在项目列表中（无权限/已删除）→ 跳过不报错', () async {
      final adapter = _FakeAdapter(projects: [
        {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitLabProvider(dio: dio);
      final result = await provider.fetchCommits(
        date: DateTime(2026, 8, 11),
        instance: CodeInstance(
          id: 'gl1',
          providerType: 'gitlab',
          baseUrl: 'https://git.example.com',
          selectedRepos: const ['ckd/ghost'],
        ),
        token: 'test-token',
        author: 'chenkaidi',
      );
      expect(result, isEmpty);
    });

    test('fetchCommitAuthors 按 selectedRepos 过滤仓库（与采集同源）', () async {
      final adapter = _FakeAdapter(
        projects: [
          {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
          {'id': 2, 'path_with_namespace': 'ckd/shipyard', 'visibility': 'public'},
        ],
        commitsByProject: {
          'ckd/daymark': [_commit(id: 'a1', authorName: 'chenkaidi')],
          'ckd/shipyard': [_commit(id: 'b1', authorName: 'lisi')],
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = GitLabProvider(dio: dio);
      final authors = await provider.fetchCommitAuthors(
        instance: CodeInstance(
          id: 'gl1',
          providerType: 'gitlab',
          baseUrl: 'https://git.example.com',
          selectedRepos: const ['ckd/shipyard'],
        ),
        token: 'test-token',
      );
      expect(authors.map((a) => a.key), ['lisi'],
          reason: '只从勾选的 ckd/shipyard 拉作者');
    });
  });
}