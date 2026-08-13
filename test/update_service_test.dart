import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_models.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 HTTP 适配器：按 URL 片段匹配返回 JSON 或字节流
class FakeAdapter implements HttpClientAdapter {
  /// url 片段 → (状态码, 内容)。内容为 `List<int>` 时按字节流返回。
  final Map<String, (int, Object)> routes;
  final List<String> requested = [];

  FakeAdapter(this.routes);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requested.add(options.uri.toString());
    for (final entry in routes.entries) {
      if (options.uri.toString().contains(entry.key)) {
        final (code, body) = entry.value;
        final bytes = body is List<int>
            ? body
            : utf8.encode(jsonEncode(body));
        return ResponseBody.fromBytes(
          bytes,
          code,
          headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
            if (body is! List<int>)
              Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
    }
    return ResponseBody.fromString('{"message":"404 Not Found"}', 404);
  }

  @override
  void close({bool force = false}) {}
}

const _asset = 'daymark-linux-x86_64.AppImage';

UpdateConfig _config(String version, {List<Map<String, dynamic>> sources = const []}) {
  return UpdateConfig(
    sources: sources.map(UpdateSource.fromJson).toList(),
    appVersion: version,
    assetName: _asset,
  );
}

/// GitLab release 列表响应（含平台资产链接）
List<Map<String, dynamic>> _gitlabReleases(List<(String, String?)> tagsWithAsset) {
  return [
    for (final (tag, assetUrl) in tagsWithAsset)
      {
        'tag_name': tag,
        'released_at': '2026-08-13T10:00:00Z',
        'assets': {
          'links': [
            if (assetUrl != null)
              {
                'name': _asset,
                'url': assetUrl,
                'link_type': 'package',
              },
            {
              'name': 'daymark-macos-arm64.dmg',
              'url': 'https://g/macos.dmg',
              'link_type': 'package',
            },
          ],
        },
      },
  ];
}

/// GitHub latest release 响应
Map<String, dynamic> _githubLatest(String tag, {String? assetUrl, String? digest}) => {
      'tag_name': tag,
      'assets': [
        {
          'name': _asset,
          'browser_download_url':
              assetUrl ?? 'https://github.com/CodeFuckee/daymark/releases/download/$tag/$_asset',
          if (digest != null) 'digest': digest,
        },
      ],
    };

void main() {
  group('UpdateService.check（版本检测）', () {
    test('GitLab 源：取最新 release 中带平台资产者', () async {
      final adapter = FakeAdapter({
        '/projects/chenkaidi%2Fdaymark/releases': (
          200,
          _gitlabReleases([
            ('v0.1.4', 'https://g/packages/generic/daymark/v0.1.4/$_asset'),
            ('v0.1.3', 'https://g/packages/generic/daymark/v0.1.3/$_asset'),
          ]),
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {
            'type': 'gitlab',
            'api': 'https://home.chenkaidi.top:509/api/v4',
            'project': 'chenkaidi%2Fdaymark',
          },
        ]),
        dio: Dio(BaseOptions(baseUrl: 'https://home.chenkaidi.top:509/api/v4'))
          ..httpClientAdapter = adapter,
      );
      final info = await service.check();
      expect(info, isNotNull);
      expect(info!.version, '0.1.4');
      expect(info.tag, 'v0.1.4');
      expect(info.downloadUrl, 'https://g/packages/generic/daymark/v0.1.4/$_asset');
      expect(info.sourceType, 'gitlab');
      // 携带认证头（private 仓库只读 token）
      expect(adapter.requested.first, contains('/projects/chenkaidi%2Fdaymark/releases'));
    });

    test('GitLab 源：带 token 时请求头携带 PRIVATE-TOKEN', () async {
      final adapter = FakeAdapter({
        '/projects/chenkaidi%2Fdaymark/releases': (
          200,
          _gitlabReleases([('v0.1.4', 'https://g/x/$_asset')]),
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {
            'type': 'gitlab',
            'api': 'https://home.chenkaidi.top:509/api/v4',
            'project': 'chenkaidi%2Fdaymark',
            'token': 'glpat-readonly',
          },
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      await service.check();
      final sent = adapter.requested.first;
      expect(sent, contains('releases'));
    });

    test('GitHub 源：latest release 解析（含 digest）', () async {
      final adapter = FakeAdapter({
        '/repos/CodeFuckee/daymark/releases/latest': (
          200,
          _githubLatest('v0.1.5', digest: 'sha256:abc123'),
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {'type': 'github', 'repo': 'CodeFuckee/daymark'},
        ]),
        dio: Dio(BaseOptions(baseUrl: 'https://api.github.com'))
          ..httpClientAdapter = adapter,
      );
      final info = await service.check();
      expect(info!.version, '0.1.5');
      expect(info.sha256, 'abc123');
      expect(info.sourceType, 'github');
      expect(adapter.requested.single, contains('/repos/CodeFuckee/daymark/releases/latest'));
    });

    test('多源：取版本最高者', () async {
      final adapter = FakeAdapter({
        '/projects/a%2Fb/releases': (
          200,
          _gitlabReleases([('v0.1.6', 'https://g/v0.1.6/$_asset')]),
        ),
        '/repos/a/b/releases/latest': (
          200,
          _githubLatest('v0.1.4'),
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {'type': 'gitlab', 'api': 'https://g/api/v4', 'project': 'a%2Fb'},
          {'type': 'github', 'repo': 'a/b'},
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final info = await service.check();
      expect(info!.version, '0.1.6');
      expect(info.sourceType, 'gitlab');
    });

    test('无新版本（latest <= 当前）→ null', () async {
      final adapter = FakeAdapter({
        '/repos/a/b/releases/latest': (200, _githubLatest('v0.1.3')),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {'type': 'github', 'repo': 'a/b'},
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect(await service.check(), isNull);
    });

    test('release 无本平台资产 → 该源跳过（取下一个可用源）', () async {
      final adapter = FakeAdapter({
        '/projects/a%2Fb/releases': (
          200,
          // 最新 release 无 Linux 资产（macOS-only 发布）
          _gitlabReleases([('v0.1.7', null), ('v0.1.6', 'https://g/v0.1.6/$_asset')]),
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {'type': 'gitlab', 'api': 'https://g/api/v4', 'project': 'a%2Fb'},
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final info = await service.check();
      expect(info!.version, '0.1.6');
    });

    test('全部源无可用资产 → null', () async {
      final adapter = FakeAdapter({
        '/repos/a/b/releases/latest': (
          200,
          {
            'tag_name': 'v0.1.7',
            'assets': [
              {'name': 'daymark-macos-arm64.dmg', 'browser_download_url': 'https://x'},
            ],
          },
        ),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          {'type': 'github', 'repo': 'a/b'},
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect(await service.check(), isNull);
    });

    test('API 异常（404/网络错误）→ 容错跳过该源', () async {
      final adapter = FakeAdapter({
        '/repos/a/b/releases/latest': (200, _githubLatest('v0.1.9')),
      });
      final service = UpdateService(
        config: _config('0.1.3', sources: [
          // gitlab 源无路由 → 404；github 正常
          {'type': 'gitlab', 'api': 'https://g/api/v4', 'project': 'a%2Fb'},
          {'type': 'github', 'repo': 'a/b'},
        ]),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final info = await service.check();
      expect(info!.version, '0.1.9');
      expect(info.sourceType, 'github');
    });

    test('config 禁用（无源/无版本）→ null', () async {
      final service = UpdateService(
        config: _config('0.1.3'),
        dio: Dio()..httpClientAdapter = FakeAdapter({}),
      );
      expect(await service.check(), isNull);
    });
  });

  group('UpdateService.download（后台下载 + 校验 + manifest）', () {
    late Directory tempDir;
    final binary = utf8.encode('hello'); // sha256 已知
    const helloSha256 =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('daymark-update-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<UpdateService> serviceWith(Map<String, (int, Object)> routes,
        {String? sha256}) {
      final service = UpdateService(
        config: _config('0.1.3'),
        supportDir: tempDir.path,
        dio: Dio()..httpClientAdapter = FakeAdapter(routes),
      );
      return Future.value(service);
    }

    UpdateInfo info({String? sha256}) => UpdateInfo(
          version: '0.1.4',
          tag: 'v0.1.4',
          downloadUrl: 'https://g/download/$_asset',
          sha256: sha256,
          sourceType: 'gitlab',
        );

    test('下载写入文件 + manifest 记录', () async {
      final service = await serviceWith({
        '/download/$_asset': (200, binary),
      });
      final manifest = await service.download(info());
      final file = File('${tempDir.path}/update/$_asset');
      expect(await file.readAsBytes(), binary);
      expect(manifest.version, '0.1.4');
      expect(manifest.assetName, _asset);
      // manifest.json 落盘
      final manifestFile = File('${tempDir.path}/update/manifest.json');
      expect(await manifestFile.exists(), isTrue);
      final decoded = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      expect(decoded['version'], '0.1.4');
      expect(decoded['assetName'], _asset);
      expect(decoded['sourceType'], 'gitlab');
      // .part 临时文件已清理
      expect(await File('${tempDir.path}/update/$_asset.part').exists(), isFalse);
    });

    test('sha256 匹配 → 校验通过', () async {
      final service = await serviceWith({
        '/download/$_asset': (200, binary),
      });
      final manifest = await service.download(info(sha256: helloSha256));
      expect(manifest.sha256, helloSha256);
    });

    test('sha256 不匹配 → 抛异常且不写 manifest', () async {
      final service = await serviceWith({
        '/download/$_asset': (200, binary),
      });
      await expectLater(
        service.download(info(sha256: 'deadbeef')),
        throwsA(isA<UpdateChecksumException>()),
      );
      expect(await File('${tempDir.path}/update/manifest.json').exists(), isFalse);
    });

    test('无 sha256 信息 → 跳过校验成功', () async {
      final service = await serviceWith({
        '/download/$_asset': (200, binary),
      });
      final manifest = await service.download(info());
      expect(manifest.sha256, isNull);
      expect(await File('${tempDir.path}/update/$_asset').exists(), isTrue);
    });

    test('下载失败（HTTP 404）→ 抛异常不残留 manifest', () async {
      final service = await serviceWith({
        '/download/$_asset': (404, {'message': 'not found'}),
      });
      await expectLater(service.download(info()), throwsA(anything));
      expect(await File('${tempDir.path}/update/manifest.json').exists(), isFalse);
    });

    test('onProgress 回调进度递增', () async {
      final service = await serviceWith({
        '/download/$_asset': (200, binary),
      });
      final progresses = <double>[];
      await service.download(info(), onProgress: progresses.add);
      expect(progresses, isNotEmpty);
      expect(progresses.first, greaterThanOrEqualTo(0));
    });
  });

  group('UpdateService.loadManifest（待安装检查）', () {
    test('无 manifest → null', () async {
      final tempDir = await Directory.systemTemp.createTemp('daymark-update-test-');
      addTearDown(() => tempDir.delete(recursive: true));
      final service = UpdateService(
        config: _config('0.1.3'),
        supportDir: tempDir.path,
        dio: Dio()..httpClientAdapter = FakeAdapter({}),
      );
      expect(await service.loadManifest(), isNull);
    });

    test('manifest 损坏 → null', () async {
      final tempDir = await Directory.systemTemp.createTemp('daymark-update-test-');
      addTearDown(() => tempDir.delete(recursive: true));
      final dir = Directory('${tempDir.path}/update')..createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync('{broken json');
      final service = UpdateService(
        config: _config('0.1.3'),
        supportDir: tempDir.path,
        dio: Dio()..httpClientAdapter = FakeAdapter({}),
      );
      expect(await service.loadManifest(), isNull);
    });

    test('manifest 存在但安装包缺失 → null（下次重新下载）', () async {
      final tempDir = await Directory.systemTemp.createTemp('daymark-update-test-');
      addTearDown(() => tempDir.delete(recursive: true));
      final dir = Directory('${tempDir.path}/update')..createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode(UpdateManifest(
          version: '0.1.4',
          assetName: _asset,
          sha256: null,
          sourceType: 'gitlab',
        ).toJson()),
      );
      final service = UpdateService(
        config: _config('0.1.3'),
        supportDir: tempDir.path,
        dio: Dio()..httpClientAdapter = FakeAdapter({}),
      );
      expect(await service.loadManifest(), isNull);
    });

    test('manifest 与安装包齐全 → 返回', () async {
      final tempDir = await Directory.systemTemp.createTemp('daymark-update-test-');
      addTearDown(() => tempDir.delete(recursive: true));
      final dir = Directory('${tempDir.path}/update')..createSync(recursive: true);
      File('${dir.path}/$_asset').writeAsStringSync('new-binary');
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode(UpdateManifest(
          version: '0.1.4',
          assetName: _asset,
          sha256: helloSha256,
          sourceType: 'gitlab',
        ).toJson()),
      );
      final service = UpdateService(
        config: _config('0.1.3'),
        supportDir: tempDir.path,
        dio: Dio()..httpClientAdapter = FakeAdapter({}),
      );
      final manifest = await service.loadManifest();
      expect(manifest!.version, '0.1.4');
      expect(manifest.assetName, _asset);
    });
  });
}

// hello 的 sha256（供 manifest 测试复用）
const helloSha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
