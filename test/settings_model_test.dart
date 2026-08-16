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

  test('extraCommitAuthors 序列化往返（issue #20）', () {
    final original = AppSettings(extraCommitAuthors: const ['agent', 'code01']);
    final roundtrip = AppSettings.fromJson(original.toJson());
    expect(roundtrip.extraCommitAuthors, ['agent', 'code01']);
  });

  test('extraCommitAuthors 键缺失时为空列表且可修改（issue #20）', () {
    final parsed = AppSettings.fromJson(const {});
    expect(parsed.extraCommitAuthors, isEmpty,
        reason: '老版本 settings.json 无该字段，升级后应为空（不并入额外账户）');
    parsed.extraCommitAuthors.add('agent');
    expect(parsed.extraCommitAuthors, ['agent']);
  });

    aiProviderGroup();
}

// ─────────────────────────── AI 供应商（issue #25） ───────────────────────────

void aiProviderGroup() {
  group('AI 供应商动态列表（issue #25）', () {
    test('AiProvider 序列化往返', () {
      final p = AiProvider(
        id: 'deepseek-1',
        type: 'deepseek',
        name: '公司 DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-xxx',
        model: 'deepseek-reasoner',
      );
      final roundtrip = AiProvider.fromJson(p.toJson());
      expect(roundtrip.id, 'deepseek-1');
      expect(roundtrip.type, 'deepseek');
      expect(roundtrip.name, '公司 DeepSeek');
      expect(roundtrip.baseUrl, 'https://api.deepseek.com/v1');
      expect(roundtrip.apiKey, 'sk-xxx');
      expect(roundtrip.model, 'deepseek-reasoner');
    });

    test('默认设置自带三家供应商，主/备为空', () {
      final ai = AiSettings();
      expect(ai.providers.map((p) => p.id), ['claude', 'deepseek', 'ollama'],
          reason: '默认仍预置三家，保证开箱即用');
      expect(ai.provider, isEmpty);
      expect(ai.fallback, isEmpty);
    });

    test('providers 列表序列化往返（含自定义 id 与 openai 类型）', () {
      final ai = AiSettings(
        provider: 'deepseek-1',
        fallback: ['claude'],
        conferenceBlocked: ['claude'],
        providers: [
          AiProvider(
              id: 'claude', type: 'claude', name: 'Claude',
              baseUrl: 'https://api.anthropic.com', model: 'claude-sonnet-5'),
          AiProvider(
              id: 'deepseek-1', type: 'deepseek', name: '公司 DeepSeek',
              baseUrl: 'https://api.deepseek.com/v1', apiKey: 'sk-1',
              model: 'deepseek-reasoner'),
          AiProvider(
              id: 'groq-1', type: 'openai', name: 'Groq',
              baseUrl: 'https://api.groq.com/openai/v1', apiKey: 'sk-g',
              model: 'llama-3.3-70b-versatile'),
        ],
      );
      final roundtrip = AiSettings.fromJson(ai.toJson());
      expect(roundtrip.provider, 'deepseek-1');
      expect(roundtrip.fallback, ['claude']);
      expect(roundtrip.conferenceBlocked, ['claude']);
      expect(roundtrip.providers, hasLength(3));
      expect(roundtrip.providers[1].name, '公司 DeepSeek');
      expect(roundtrip.providers[1].apiKey, 'sk-1');
      expect(roundtrip.providers[2].type, 'openai');
      expect(roundtrip.providers[2].baseUrl, 'https://api.groq.com/openai/v1');
    });

    test('旧版扁平字段 JSON 迁移为 providers（id=类型名，主/备引用不变）', () {
      final parsed = AiSettings.fromJson(const {
        'provider': 'deepseek',
        'fallback': ['claude'],
        'claudeBaseUrl': 'https://api.anthropic.com',
        'deepseekBaseUrl': 'https://api.deepseek.com/v1',
        'deepseekApiKey': 'sk-1',
        'ollamaModel': 'qwen2.5:7b',
      });
      expect(parsed.provider, 'deepseek');
      expect(parsed.fallback, ['claude']);
      expect(parsed.providers.map((p) => p.id), ['claude', 'deepseek', 'ollama']);
      final ds = parsed.providers.firstWhere((p) => p.id == 'deepseek');
      expect(ds.baseUrl, 'https://api.deepseek.com/v1');
      expect(ds.apiKey, 'sk-1');
      final ollama = parsed.providers.firstWhere((p) => p.id == 'ollama');
      expect(ollama.model, 'qwen2.5:7b');
    });

    test('providers 键存在但为空列表时不回填默认供应商', () {
      final parsed = AiSettings.fromJson(const {
        'providers': <dynamic>[],
        'provider': '',
      });
      expect(parsed.providers, isEmpty,
          reason: '用户清空全部供应商后升级/保存不应被重新塞回默认三家');
    });

    test('providerById 按 id 查找供应商', () {
      final ai = AiSettings(providers: [
        AiProvider(id: 'p1', type: 'openai', name: 'X'),
      ]);
      expect(ai.providerById('p1')?.name, 'X');
      expect(ai.providerById('missing'), isNull);
    });

    test('removeProvider 同步清理主/备/会议禁用引用（issue #25）', () {
      final ai = AiSettings(
        provider: 'deepseek-1',
        fallback: ['deepseek-1', 'claude'],
        conferenceBlocked: ['deepseek-1'],
        providers: [
          AiProvider(id: 'deepseek-1', type: 'deepseek', name: 'DS'),
          AiProvider(id: 'claude', type: 'claude', name: 'Claude'),
        ],
      );
      ai.removeProvider('deepseek-1');
      expect(ai.providers.map((p) => p.id), ['claude']);
      expect(ai.provider, isEmpty, reason: '删除主供应商后主供应商应清空');
      expect(ai.fallback, ['claude'], reason: '备选中对被删供应商的引用应移除');
      expect(ai.conferenceBlocked, isEmpty,
          reason: '会议禁用列表中对被删供应商的引用应移除');
    });
  });
}
