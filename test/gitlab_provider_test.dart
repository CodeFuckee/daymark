import 'dart:convert';
import 'dart:typed_data';

import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/providers/gitlab_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 adapter：按请求 path 返回模拟 GitLab 响应（不发起真实网络）。
class _FakeAdapter implements HttpClientAdapter {
  /// 提交响应内容（按需由测试构造）
  List<Map<String, dynamic>> commits;

  _FakeAdapter({required this.commits});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object data;
    if (options.path.contains('/repository/commits')) {
      data = commits;
    } else {
      // 项目列表
      data = [
        {'id': 1, 'path_with_namespace': 'ckd/daymark', 'visibility': 'public'},
      ];
    }
    return ResponseBody.fromString(
      jsonEncode(data),
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
    ),
    token: 'test-token',
    author: author,
    extraAuthors: extraAuthors,
  );
  return result;
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
}
