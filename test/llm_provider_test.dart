import 'package:daymark/core/ai/llm_provider.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('供应商工厂', () {
    test('按配置创建三家默认供应商', () {
      final ai = AiSettings(provider: 'claude');
      final claude = LLMProviderFactory.create(ai, 'claude');
      expect(claude.id, 'claude');
      expect(claude.name, 'Claude');

      final deepseek = LLMProviderFactory.create(ai, 'deepseek');
      expect(deepseek.id, 'deepseek');

      final ollama = LLMProviderFactory.create(ai, 'ollama');
      expect(ollama.id, 'ollama');
    });

    test('未知供应商 id 抛错', () {
      final ai = AiSettings();
      expect(
        () => LLMProviderFactory.create(ai, 'unknown'),
        throwsArgumentError,
      );
    });

    test('已删除的供应商 id 抛错（issue #25）', () {
      final ai = AiSettings(provider: 'gone', fallback: ['gone']);
      expect(() => LLMProviderFactory.create(ai, 'gone'), throwsArgumentError);
    });

    test('自定义供应商实例按配置创建（issue #25）', () {
      final ai = AiSettings(
        providers: [
          AiProvider(
            id: 'ds-1',
            type: 'deepseek',
            name: '公司 DeepSeek',
            baseUrl: 'https://api.deepseek.com/v1',
            apiKey: 'sk-1',
            model: 'deepseek-reasoner',
          ),
          AiProvider(
            id: 'groq-1',
            type: 'openai',
            name: 'Groq',
            baseUrl: 'https://api.groq.com/openai/v1',
            apiKey: 'sk-g',
            model: 'llama-3.3-70b-versatile',
          ),
        ],
      );

      final ds = LLMProviderFactory.create(ai, 'ds-1') as DeepSeekProvider;
      expect(ds.baseUrl, 'https://api.deepseek.com/v1');
      expect(ds.apiKey, 'sk-1');
      expect(ds.model, 'deepseek-reasoner');

      // OpenAI 兼容类型（可添加任意兼容服务，不再局限于三家）
      final groq =
          LLMProviderFactory.create(ai, 'groq-1') as OpenAICompatibleProvider;
      expect(groq.id, 'openai');
      expect(groq.name, 'OpenAI 兼容');
      expect(groq.baseUrl, 'https://api.groq.com/openai/v1');
      expect(groq.apiKey, 'sk-g');
      expect(groq.model, 'llama-3.3-70b-versatile');
    });

    test('主备顺序（按 id）', () {
      final ai = AiSettings(provider: 'ds-1', fallback: ['claude', 'groq-1']);
      expect(LLMProviderFactory.order(ai), ['ds-1', 'claude', 'groq-1']);
      // 备选中的重复主供应商去重
      final dup = AiSettings(provider: 'ds-1', fallback: ['ds-1', 'claude']);
      expect(LLMProviderFactory.order(dup), ['ds-1', 'claude']);
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

      final deepseek =
          LLMProviderFactory.create(ai, 'deepseek') as DeepSeekProvider;
      expect(deepseek.baseUrl, 'https://api.deepseek.com/v1');
      expect(deepseek.model, 'deepseek-chat');

      final ollama = LLMProviderFactory.create(ai, 'ollama') as OllamaProvider;
      expect(ollama.model, ai.ollamaModel);
    });

    test('供应商类型默认配置（issue #25）', () {
      expect(AiProviderType.displayName('claude'), 'Claude');
      expect(AiProviderType.displayName('deepseek'), 'DeepSeek');
      expect(AiProviderType.displayName('ollama'), 'Ollama（本地）');
      expect(AiProviderType.displayName('openai'), 'OpenAI 兼容');
      expect(AiProviderType.defaultBaseUrl('openai'), isNotEmpty);
      expect(AiProviderType.defaultModel('claude'), isNotEmpty);
    });
  });
}
