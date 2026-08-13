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
}
