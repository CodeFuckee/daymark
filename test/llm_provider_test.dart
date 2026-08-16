import 'dart:convert';
import 'dart:typed_data';

import 'package:daymark/core/ai/llm_provider.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 HTTP adapter：按请求返回模拟的模型列表响应（不发起真实网络）。
class _FakeModelsAdapter implements HttpClientAdapter {
  _FakeModelsAdapter({required this.response, this.statusCode = 200});

  /// 响应体（JSON 编码后返回）
  final Map<String, dynamic> response;

  /// HTTP 状态码（非 200 用于模拟鉴权/网络失败）
  final int statusCode;

  /// 收到的请求（path、method、headers）
  final List<(String, String, Map<String, dynamic>)> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((options.uri.path, options.method, options.headers));
    if (statusCode != 200) {
      return ResponseBody.fromString(
        jsonEncode({'error': {'message': 'denied'}}),
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

  group('获取模型列表（issue #27）', () {
    test('Claude 官方接口 GET /v1/models（x-api-key 认证）', () async {
      final adapter = _FakeModelsAdapter(
        response: {
          'data': [
            {'id': 'claude-opus-4-1', 'type': 'model'},
            {'id': 'claude-sonnet-5', 'type': 'model'},
          ],
        },
      );
      final provider = ClaudeProvider(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-ant-test',
        dio: Dio()..httpClientAdapter = adapter,
      );

      final models = await provider.listModels();

      expect(models, ['claude-opus-4-1', 'claude-sonnet-5']);
      expect(adapter.requests.single.$1, '/v1/models');
      expect(adapter.requests.single.$2, 'GET');
      final headers = adapter.requests.single.$3;
      expect(headers, containsPair('x-api-key', 'sk-ant-test'));
      expect(headers, containsPair('anthropic-version', '2023-06-01'));
    });

    test('DeepSeek 官方接口 GET /v1/models（Bearer 认证）', () async {
      final adapter = _FakeModelsAdapter(
        response: {
          'data': [
            {'id': 'deepseek-chat'},
            {'id': 'deepseek-reasoner'},
          ],
        },
      );
      final provider = DeepSeekProvider(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-ds-test',
        dio: Dio()..httpClientAdapter = adapter,
      );

      final models = await provider.listModels();

      expect(models, ['deepseek-chat', 'deepseek-reasoner']);
      expect(adapter.requests.single.$1, '/v1/models');
      expect(
        adapter.requests.single.$3,
        containsPair('Authorization', 'Bearer sk-ds-test'),
      );
    });

    test('OpenAI 兼容（Groq）接口 GET /openai/v1/models（Bearer 认证）', () async {
      final adapter = _FakeModelsAdapter(
        response: {
          'data': [
            {'id': 'llama-3.3-70b-versatile'},
            {'id': 'mixtral-8x7b-32768'},
          ],
        },
      );
      final provider = OpenAICompatibleProvider(
        baseUrl: 'https://api.groq.com/openai/v1',
        apiKey: 'sk-groq',
        dio: Dio()..httpClientAdapter = adapter,
      );

      final models = await provider.listModels();

      expect(models, ['llama-3.3-70b-versatile', 'mixtral-8x7b-32768']);
      // 已带 /v1 的 base_url 不再重复拼接
      expect(adapter.requests.single.$1, '/openai/v1/models');
    });

    test('Ollama 本地接口 GET /api/tags（无需认证）', () async {
      final adapter = _FakeModelsAdapter(
        response: {
          'models': [
            {'name': 'qwen2.5:latest'},
            {'name': 'llama3.2'},
          ],
        },
      );
      final provider = OllamaProvider(
        baseUrl: 'http://localhost:11434/',
        dio: Dio()..httpClientAdapter = adapter,
      );

      final models = await provider.listModels();

      expect(models, ['qwen2.5:latest', 'llama3.2']);
      // 尾部斜杠被去除，不会出现双斜杠
      expect(adapter.requests.single.$1, '/api/tags');
    });

    test('接口返回空列表时不报错', () async {
      final adapter = _FakeModelsAdapter(response: {'data': []});
      final provider = OpenAICompatibleProvider(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
        dio: Dio()..httpClientAdapter = adapter,
      );

      expect(await provider.listModels(), isEmpty);
    });

    test('鉴权失败（401）时抛出 DioException', () async {
      final adapter = _FakeModelsAdapter(
        response: const {},
        statusCode: 401,
      );
      final provider = ClaudeProvider(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-bad',
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        provider.listModels(),
        throwsA(isA<DioException>()),
      );
    });

    test('createFromConfig 按表单原始配置创建实例（issue #27）', () {
      final claude = LLMProviderFactory.createFromConfig(
        type: 'claude',
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-a',
        model: 'claude-sonnet-5',
      );
      expect(claude, isA<ClaudeProvider>());

      final ds = LLMProviderFactory.createFromConfig(
        type: 'deepseek',
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-d',
      );
      expect(ds, isA<DeepSeekProvider>());

      final ollama = LLMProviderFactory.createFromConfig(
        type: 'ollama',
        baseUrl: 'http://localhost:11434',
        apiKey: '',
      );
      expect(ollama, isA<OllamaProvider>());

      final openai = LLMProviderFactory.createFromConfig(
        type: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-o',
      );
      expect(openai, isA<OpenAICompatibleProvider>());

      expect(
        () => LLMProviderFactory.createFromConfig(
          type: 'unknown',
          baseUrl: '',
          apiKey: '',
        ),
        throwsArgumentError,
      );
    });

  });
}
