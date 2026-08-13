import 'package:daymark/core/providers/code_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitAuthorValues', () {
    test('中英文逗号/分号/空白分隔', () {
      expect(splitAuthorValues('陈凯迪,chenkaidi'), ['陈凯迪', 'chenkaidi']);
      expect(splitAuthorValues('陈凯迪，chenkaidi'), ['陈凯迪', 'chenkaidi']);
      expect(splitAuthorValues('陈凯迪; chenkaidi'), ['陈凯迪', 'chenkaidi']);
      expect(splitAuthorValues('  chenkaidi   '), ['chenkaidi']);
    });

    test('空段与空串', () {
      expect(splitAuthorValues(''), isEmpty);
      expect(splitAuthorValues(' ,，; '), isEmpty);
      expect(splitAuthorValues('陈凯迪,,chenkaidi'), ['陈凯迪', 'chenkaidi']);
    });
  });

  group('authorMatches（issue #9：中文署名过滤掉英文 git 提交）', () {
    // 用户实际配置：署名"陈凯迪"，git 提交作者 "chenkaidi" / 邮箱 935637782@qq.com
    const userFields = ['chenkaidi', '935637782@qq.com'];

    test('作者名为空时不过滤', () {
      expect(authorMatches('', userFields), isTrue);
    });

    test('字段包含作者名时匹配（原有行为保持）', () {
      expect(authorMatches('chenkaidi', userFields), isTrue);
    });

    test('复现 #9：署名 + git 用户名逗号分隔，能匹配英文提交', () {
      expect(authorMatches('陈凯迪,chenkaidi', userFields), isTrue);
    });

    test('复现 #9：署名 + 邮箱逗号分隔，能匹配英文提交', () {
      expect(authorMatches('陈凯迪,935637782@qq.com', userFields), isTrue);
    });

    test('大小写不敏感', () {
      expect(authorMatches('ChenKaidi', userFields), isTrue);
    });

    test('配置值短于字段时双向匹配（值包含于字段）', () {
      expect(authorMatches('陈凯', ['陈凯迪', '935637782@qq.com']), isTrue);
    });

    test('多值中任一命中即匹配', () {
      expect(authorMatches('张三,chenkaidi', userFields), isTrue);
    });

    test('均不命中时过滤', () {
      expect(authorMatches('张三', userFields), isFalse);
      expect(authorMatches('张三,李四', userFields), isFalse);
    });
  });
}
