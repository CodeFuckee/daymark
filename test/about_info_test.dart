/// 关于板块诊断信息测试（issue #7）：
/// - 全字段注入：条目完整、无占位文案；
/// - 版本号 / 构建时间未注入（本地开发构建）：显示占位文案；
/// - 平台字段空值：显示「未知」而不是空行；
/// - 一键复制文本格式：首行标题 + 每行「标签: 值」，行数与条目一致；
/// - collect 幂等：重复调用结果一致。
library;

import 'package:daymark/core/about/about_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AboutInfo.collect：正常路径', () {
    test('全字段注入：条目完整、值正确、无占位文案', () {
      final info = AboutInfo.collect(
        appVersion: '1.2.3',
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'linux',
        osVersion: '7.0.0-28-generic',
        hostname: 'dev-machine',
        dartVersion: 'Dart 3.9.2',
        processors: 8,
        locale: 'zh_CN',
      );

      final values = info.entries.map((e) => e.value).toList();
      expect(info.entries.length, 8);
      expect(values, contains('1.2.3'));
      expect(values, contains('2026-08-15T10:00:00Z'));
      expect(values, contains('linux 7.0.0-28-generic'));
      expect(values, contains('dev-machine'));
      expect(values, contains('8'));
      expect(values, contains('zh_CN'));
      // 全字段注入时不出现任何占位文案
      expect(values.every((v) => !v.contains('未注入')), isTrue);
      expect(values.every((v) => v != '未知'), isTrue);
    });

    test('条目标签非空且不重复', () {
      final info = AboutInfo.collect(
        appVersion: '1.0.0',
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'macos',
        osVersion: '15.0',
        hostname: 'mac',
        dartVersion: 'Dart 3.9.2',
        processors: 4,
        locale: 'en_US',
      );
      final keys = info.entries.map((e) => e.key).toList();
      expect(keys.every((k) => k.isNotEmpty), isTrue);
      expect(keys.toSet().length, keys.length, reason: '标签应互不重复');
    });

    test('collect 幂等：相同输入重复调用结果一致', () {
      AboutInfo call() => AboutInfo.collect(
            appVersion: '1.0.0',
            buildTime: '2026-08-15T10:00:00Z',
            osName: 'windows',
            osVersion: '11',
            hostname: 'pc',
            dartVersion: 'Dart 3.9.2',
            processors: 16,
            locale: 'zh_CN',
          );
      final a = call();
      final b = call();
      expect(a.toCopyText(), b.toCopyText());
      expect(a.entries.map((e) => e.value), b.entries.map((e) => e.value));
    });
  });

  group('AboutInfo.collect：未注入 / 空值边界', () {
    test('版本号未注入（本地开发构建）：显示占位文案', () {
      final info = AboutInfo.collect(
        appVersion: null,
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'linux',
        osVersion: 'x',
        hostname: 'h',
        dartVersion: 'd',
        processors: 1,
        locale: 'zh',
      );
      expect(
        info.entries.map((e) => e.value),
        contains('开发构建（未注入版本号）'),
      );
    });

    test('构建时间未注入：显示占位文案（显式 null 与空字符串都算未注入）', () {
      for (final buildTime in [null, '']) {
        final info = AboutInfo.collect(
          appVersion: '1.0.0',
          buildTime: buildTime,
          osName: 'linux',
          osVersion: 'x',
          hostname: 'h',
          dartVersion: 'd',
          processors: 1,
          locale: 'zh',
        );
        expect(
          info.entries.map((e) => e.value),
          contains('开发构建（未注入构建时间）'),
          reason: 'buildTime=$buildTime 应显示占位',
        );
      }
    });

    test('操作系统名称为空：显示「未知」而不是空行', () {
      final info = AboutInfo.collect(
        appVersion: '1.0.0',
        buildTime: '2026-08-15T10:00:00Z',
        osName: '',
        osVersion: '',
        hostname: '',
        dartVersion: '',
        processors: 1,
        locale: '',
      );
      final values = info.entries.map((e) => e.value).toList();
      expect(values, contains('未知'));
      expect(values.every((v) => v.isNotEmpty), isTrue,
          reason: '条目值不得为空字符串（复制出去的信息应完整可读）');
    });

    test('版本号为空字符串：同样视为未注入', () {
      final info = AboutInfo.collect(
        appVersion: '',
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'linux',
        osVersion: 'x',
        hostname: 'h',
        dartVersion: 'd',
        processors: 1,
        locale: 'zh',
      );
      expect(
        info.entries.map((e) => e.value),
        contains('开发构建（未注入版本号）'),
      );
    });
  });

  group('AboutInfo.toCopyText：一键复制文本格式', () {
    test('首行为标题，其余每行「标签: 值」，行数 = 条目数 + 1', () {
      final info = AboutInfo.collect(
        appVersion: '1.2.3',
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'linux',
        osVersion: '7.0.0',
        hostname: 'dev',
        dartVersion: 'Dart 3.9.2',
        processors: 8,
        locale: 'zh_CN',
      );
      final lines = info.toCopyText().split('\n');
      expect(lines.first, 'Daymark 诊断信息');
      expect(lines.length, info.entries.length + 1);
      for (final line in lines.skip(1)) {
        expect(line, matches(RegExp(r'^[^:]+: .+$')), reason: '行格式应为「标签: 值」');
      }
    });

    test('复制文本包含关键调试字段（版本号/构建时间/操作系统）', () {
      final info = AboutInfo.collect(
        appVersion: '1.2.3',
        buildTime: '2026-08-15T10:00:00Z',
        osName: 'linux',
        osVersion: '7.0.0',
        hostname: 'dev',
        dartVersion: 'Dart 3.9.2',
        processors: 8,
        locale: 'zh_CN',
      );
      final text = info.toCopyText();
      expect(text, contains('版本号: 1.2.3'));
      expect(text, contains('构建时间: 2026-08-15T10:00:00Z'));
      expect(text, contains('操作系统: linux 7.0.0'));
    });

    test('未注入字段的复制文本同样包含占位文案（不丢信息）', () {
      final info = AboutInfo.collect(
        appVersion: null,
        buildTime: null,
        osName: 'linux',
        osVersion: 'x',
        hostname: 'h',
        dartVersion: 'd',
        processors: 1,
        locale: 'zh',
      );
      final text = info.toCopyText();
      expect(text, contains('版本号: 开发构建（未注入版本号）'));
      expect(text, contains('构建时间: 开发构建（未注入构建时间）'));
    });
  });
}
