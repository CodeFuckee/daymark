import 'package:daymark/core/ai/llm_provider.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('供应商工厂', () {
    test('按配置创建三家供应商', () {
      final ai = AiSettings(provider: 'claude');
      final claude = LLMProviderFactory.create(ai, 'claude');
      expect(claude.id, 'claude');
      expect(claude.name, 'Claude');

      final deepseek = LLMProviderFactory.create(ai, 'deepseek');
      expect(deepseek.id, 'deepseek');

      final ollama = LLMProviderFactory.create(ai, 'ollama');
      expect(ollama.id, 'ollama');
    });

    test('未知供应商抛错', () {
      final ai = AiSettings();
      expect(() => LLMProviderFactory.create(ai, 'unknown'), throwsArgumentError);
    });

    test('主备顺序', () {
      final ai = AiSettings(provider: 'deepseek', fallback: ['claude', 'ollama']);
      expect(LLMProviderFactory.order(ai), ['deepseek', 'claude', 'ollama']);
      // 备选中的重复主供应商去重
      final dup = AiSettings(provider: 'deepseek', fallback: ['deepseek', 'claude']);
      expect(LLMProviderFactory.order(dup), ['deepseek', 'claude']);
    });

    test('会议素材合规：禁用的供应商不允许', () {
      final ai = AiSettings(conferenceBlocked: ['claude']);
      expect(ai.allowsMeeting('claude'), isFalse);
      expect(ai.allowsMeeting('deepseek'), isTrue);
      expect(ai.allowsMeeting('ollama'), isTrue);
    });
  });

  group('URL 拼接', () {
    test('各供应商端点路径', () {
      // 通过工厂创建后验证内部配置传递
      final ai = AiSettings(
        claudeBaseUrl: 'https://api.anthropic.com',
        deepseekBaseUrl: 'https://api.deepseek.com/v1',
        ollamaBaseUrl: 'http://localhost:11434',
      );
      final claude = LLMProviderFactory.create(ai, 'claude') as ClaudeProvider;
      expect(claude.baseUrl, 'https://api.anthropic.com');
      expect(claude.model, ai.claudeModel);

      final deepseek = LLMProviderFactory.create(ai, 'deepseek') as DeepSeekProvider;
      expect(deepseek.baseUrl, 'https://api.deepseek.com/v1');
      expect(deepseek.model, 'deepseek-chat');

      final ollama = LLMProviderFactory.create(ai, 'ollama') as OllamaProvider;
      expect(ollama.model, ai.ollamaModel);
    });
  });
}
