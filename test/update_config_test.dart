import 'dart:convert';

import 'package:daymark/core/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String b64(String json) => base64Encode(utf8.encode(json));

  group('UpdateConfig.parse（构建期 dart-define 解析）', () {
    test('未注入 → 源列表为空且禁用', () {
      final config = UpdateConfig.parse(null, null, 'daymark-linux-x86_64.AppImage');
      expect(config.sources, isEmpty);
      expect(config.enabled, isFalse);
    });

    test('GitLab 源完整解析（含只读 token）', () {
      final config = UpdateConfig.parse(
        b64('[{"type":"gitlab","api":"https://home.chenkaidi.top:509/api/v4",'
            '"project":"chenkaidi%2Fdaymark","token":"glpat-xxx"}]'),
        '0.1.3',
        'daymark-linux-x86_64.AppImage',
      );
      expect(config.enabled, isTrue);
      expect(config.appVersion, '0.1.3');
      final src = config.sources.single;
      expect(src.type, 'gitlab');
      expect(src.api, 'https://home.chenkaidi.top:509/api/v4');
      expect(src.project, 'chenkaidi%2Fdaymark');
      expect(src.token, 'glpat-xxx');
    });

    test('GitHub 源完整解析', () {
      final config = UpdateConfig.parse(
        b64('[{"type":"github","repo":"CodeFuckee/daymark"}]'),
        '0.1.4',
        'daymark-windows-x64-setup.exe',
      );
      expect(config.sources.single.repo, 'CodeFuckee/daymark');
      expect(config.sources.single.type, 'github');
    });

    test('多源同时注入（GitLab + GitHub 全查取最新）', () {
      final config = UpdateConfig.parse(
        b64('[{"type":"gitlab","api":"https://g/api/v4","project":"a%2Fb"},'
            '{"type":"github","repo":"a/b"}]'),
        '0.1.5',
        'daymark-macos-arm64.dmg',
      );
      expect(config.sources, hasLength(2));
      expect(config.sources[0].type, 'gitlab');
      expect(config.sources[1].type, 'github');
    });

    test('base64 损坏 → 容错为空源（不崩溃）', () {
      final config = UpdateConfig.parse(
        '!!!not-base64!!!', '0.1.3', 'daymark-linux-x86_64.AppImage');
      expect(config.sources, isEmpty);
      expect(config.enabled, isFalse);
    });

    test('JSON 非数组 → 容错为空源', () {
      final config = UpdateConfig.parse(
        b64('{"type":"gitlab"}'), '0.1.3', 'daymark-linux-x86_64.AppImage');
      expect(config.sources, isEmpty);
    });

    test('未知源类型 → 跳过该条', () {
      final config = UpdateConfig.parse(
        b64('[{"type":"bitbucket"},{"type":"github","repo":"a/b"}]'),
        '0.1.3',
        'daymark-linux-x86_64.AppImage',
      );
      expect(config.sources, hasLength(1));
      expect(config.sources.single.type, 'github');
    });

    test('缺字段的源 → 跳过', () {
      // gitlab 缺 api → 不可用
      final config = UpdateConfig.parse(
        b64('[{"type":"gitlab","project":"a%2Fb"}]'),
        '0.1.3',
        'daymark-linux-x86_64.AppImage',
      );
      expect(config.sources, isEmpty);
      // github 缺 repo → 不可用
      final config2 = UpdateConfig.parse(
        b64('[{"type":"github"}]'),
        '0.1.3',
        'daymark-linux-x86_64.AppImage',
      );
      expect(config2.sources, isEmpty);
    });

    test('只有版本无源 / 只有源无版本 → 禁用', () {
      expect(UpdateConfig.parse(null, '0.1.3', 'a.AppImage').enabled, isFalse);
      expect(UpdateConfig.parse(
        b64('[{"type":"github","repo":"a/b"}]'), null, 'a.AppImage').enabled, isFalse);
      expect(UpdateConfig.parse(
        b64('[{"type":"github","repo":"a/b"}]'), '', 'a.AppImage').enabled, isFalse);
    });
  });

  group('UpdateConfig.assetNameFor（平台资产映射）', () {
    test('Linux → AppImage', () {
      expect(UpdateConfig.assetNameFor('linux'), 'daymark-linux-x86_64.AppImage');
    });

    test('macOS → dmg', () {
      expect(UpdateConfig.assetNameFor('macos'), 'daymark-macos-arm64.dmg');
    });

    test('Windows → setup.exe', () {
      expect(UpdateConfig.assetNameFor('windows'), 'daymark-windows-x64-setup.exe');
    });
  });
}
