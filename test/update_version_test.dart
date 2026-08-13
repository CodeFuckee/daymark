import 'package:daymark/core/update/update_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compareVersions（semver 比较）', () {
    test('v 前缀等价比较', () {
      expect(compareVersions('v0.1.2', 'v0.1.3'), -1);
      expect(compareVersions('v0.1.3', 'v0.1.2'), 1);
      expect(compareVersions('v0.1.3', 'v0.1.3'), 0);
      // 前缀有无不影响结果
      expect(compareVersions('0.1.3', 'v0.1.3'), 0);
    });

    test('不等长版本按缺省 0 补位', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1', '1.0.1'), -1);
      expect(compareVersions('2', '1.9.9'), 1);
    });

    test('数字比较而非字符串比较', () {
      expect(compareVersions('1.2.0', '1.10.0'), -1);
      expect(compareVersions('1.10.0', '1.2.0'), 1);
    });

    test('prerelease 与 build 后缀忽略', () {
      expect(compareVersions('1.0.0-beta', '1.0.0'), 0);
      expect(compareVersions('1.0.0+1', '1.0.0'), 0);
      expect(compareVersions('v1.0.0-beta.1', '1.0.0'), 0);
    });

    test('非法数字段按 0 兜底', () {
      expect(compareVersions('1.x.0', '1.0.0'), 0);
      expect(compareVersions('1.x.0', '1.1.0'), -1);
      expect(compareVersions('a.b.c', '0.0.1'), -1);
    });

    test('大版本号段不溢出', () {
      // 8 位大数段：20260813 < 99999999，按数值语义而非字符串截断
      expect(compareVersions('20260813.0.0', '99999999.0.0'), -1);
      expect(compareVersions('99999999.0.0', '20260813.0.0'), 1);
      // 超 int 范围段（20 位）也能正确比较
      expect(compareVersions('99999999999999999999.0.0', '1.0.0'), 1);
      expect(compareVersions('1.0.0', '99999999999999999999.0.0'), -1);
    });

    test('空串按 0.0.0 处理', () {
      expect(compareVersions('', '0.0.0'), 0);
      expect(compareVersions('', '0.0.1'), -1);
    });
  });
}
