/// 设置模型序列化回归测试（issue #11）：
///
/// fromJson 的列表字段必须是可修改的独立拷贝——设置页会直接对
/// `_draft`（fromJson 副本）做 add/removeAt。此前用 `.cast<String>()`
/// 生成的是底层列表的视图：当设置为默认值（`const []`）时列表不可修改，
/// 添加监控目录/切换快捷键修饰键会抛 UnsupportedError（表现为"没有反应"）。
library;

import 'package:daymark/core/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认设置经 toJson/fromJson 往返后，列表字段可修改', () {
    final roundtrip = AppSettings.fromJson(AppSettings().toJson());

    roundtrip.watchDirs.add('/tmp/watch');
    roundtrip.hotkey.modifiers.add('Alt');
    roundtrip.codeInstances
        .add(CodeInstance(id: 'x', providerType: 'gitlab'));

    expect(roundtrip.watchDirs, ['/tmp/watch']);
    expect(roundtrip.hotkey.modifiers.contains('Alt'), isTrue);
    expect(roundtrip.codeInstances, hasLength(1));
  });

  test('不可变列表经 toJson/fromJson 往返后，修改不影响原对象', () {
    final original = AppSettings(watchDirs: const ['/a']);
    final roundtrip = AppSettings.fromJson(original.toJson());

    roundtrip.watchDirs.add('/b');

    expect(roundtrip.watchDirs, ['/a', '/b']);
    expect(original.watchDirs, ['/a'], reason: 'fromJson 应拷贝而不是共享视图');
  });

  test('JSON 缺列表键时字段为空列表且可修改', () {
    final roundtrip = AppSettings.fromJson(const {});

    expect(roundtrip.watchDirs, isEmpty);
    roundtrip.watchDirs.add('/only');
    expect(roundtrip.watchDirs, ['/only']);
  });

  test('默认排除规则包含 .daymark（issue #17 复现）', () {
    expect(AppSettings().excludePatterns, contains('.daymark'),
        reason: '.daymark 是应用自身缓存目录，应默认排除避免混入本地文件变更');
  });

  test('excludePatterns 键缺失时回退默认排除规则（issue #17 复现）', () {
    final parsed = AppSettings.fromJson(const {});
    expect(parsed.excludePatterns, contains('.daymark'),
        reason: '老版本 settings.json 无该字段，升级后应获得默认排除规则');
    expect(parsed.excludePatterns, contains('.git'),
        reason: '回退的是完整默认列表，而不是只补 .daymark');
  });
}
