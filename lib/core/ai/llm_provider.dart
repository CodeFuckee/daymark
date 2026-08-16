/// AI 引擎：LLMProvider 适配层（DESIGN.md §7.1）。
///
/// 三家原生适配，统一接口，提示词模板与供应商解耦：
/// - Claude：Anthropic Messages API（/v1/messages）
/// - DeepSeek：OpenAI 兼容协议（/chat/completions）
/// - Ollama：本地 /api/chat
///
/// 全部经 dio 实现（claude_dart 等 SDK 本质同为 HTTP 封装，直接调用更可控）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/settings.dart';

/// 对话消息
class ChatMessage {
  /// system | user | assistant
  final String role;
  final String content;

  const ChatMessage(this.role, this.content);

  Map<String, dynamic> toOpenAiJson() => {'role': role, 'content': content};
}

/// 供应商统一接口
abstract class LLMProvider {
  String get id;
  String get name;

  /// 单轮对话。systemPrompt 作为系统提示，messages 为对话历史。
  Future<String> chat(
    String systemPrompt,
    List<ChatMessage> messages, {
    double temperature = 0.7,
  });

  /// 连通性检查（设置页测试按钮）
  Future<bool> ping();

  /// 拉取供应商官方模型列表（设置页「获取模型」按钮，issue #27）。
  ///
  /// 各类型官方模型列表接口：
  /// - claude：Anthropic `GET /v1/models`
  /// - deepseek / openai：OpenAI 兼容协议 `GET /v1/models`
  /// - ollama：本地 `GET /api/tags`
  Future<List<String>> listModels();
}

/// 按 baseUrl 拼接路径，兼容"已带 /v1"与"未带"两种配置。
///
/// 只检查**路径段**是否已含 /v1 或 /api（issue #27：'https://api.xxx.com'
/// 这类域名会命中 '/api' 子串导致 /v1 被漏拼——官方接口要求 /v1 前缀）。
String _apiUrl(String baseUrl, String suffix) {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final schemeEnd = base.indexOf('://');
  final hostEnd = schemeEnd < 0 ? -1 : base.indexOf('/', schemeEnd + 3);
  final path = hostEnd < 0 ? '' : base.substring(hostEnd);
  if (path.contains('/v1') || path.contains('/api')) {
    return '$base$suffix';
  }
  return '$base/v1$suffix';
}

/// 去除 baseUrl 尾部斜杠（Ollama /api/tags 拼接避免双斜杠）
String _trimTrailingSlash(String s) => s.replaceAll(RegExp(r'/+$'), '');

/// Claude（Anthropic Messages API）
class ClaudeProvider implements LLMProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Dio _dio;

  ClaudeProvider({
    this.baseUrl = 'https://api.anthropic.com',
    this.apiKey = '',
    this.model = 'claude-sonnet-5',
    Dio? dio,
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  @override
  String get id => 'claude';

  @override
  String get name => 'Claude';

  @override
  Future<String> chat(
    String systemPrompt,
    List<ChatMessage> messages, {
    double temperature = 0.7,
  }) async {
    final resp = await _dio.post(
      _apiUrl(baseUrl, '/messages'),
      options: Options(
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
      ),
      data: {
        'model': model,
        'max_tokens': 4096,
        'system': systemPrompt,
        'messages': [
          for (final m in messages)
            if (m.role != 'system') {'role': m.role, 'content': m.content},
        ],
        'temperature': temperature,
      },
    );
    final data = resp.data as Map<String, dynamic>;
    final blocks = data['content'] as List? ?? [];
    return blocks
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String)
        .join();
  }

  @override
  Future<bool> ping() async {
    try {
      await chat('Reply with "ok".', const []);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 官方模型列表接口：GET /v1/models（x-api-key 认证）
  @override
  Future<List<String>> listModels() async {
    final resp = await _dio.get(
      _apiUrl(baseUrl, '/models'),
      options: Options(
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      ),
    );
    final data = resp.data as Map<String, dynamic>;
    return [
      for (final m in (data['data'] as List? ?? []))
        (m as Map<String, dynamic>)['id'] as String? ?? '',
    ].where((id) => id.isNotEmpty).toList();
  }
}

/// DeepSeek（OpenAI 兼容协议）
class DeepSeekProvider implements LLMProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Dio _dio;

  DeepSeekProvider({
    this.baseUrl = 'https://api.deepseek.com',
    this.apiKey = '',
    this.model = 'deepseek-chat',
    Dio? dio,
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  @override
  String get id => 'deepseek';

  @override
  String get name => 'DeepSeek';

  @override
  Future<String> chat(
    String systemPrompt,
    List<ChatMessage> messages, {
    double temperature = 0.7,
  }) async {
    final all = [
      if (systemPrompt.isNotEmpty) ChatMessage('system', systemPrompt),
      ...messages,
    ];
    final resp = await _dio.post(
      _apiUrl(baseUrl, '/chat/completions'),
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'content-type': 'application/json',
        },
      ),
      data: {
        'model': model,
        'messages': all.map((e) => e.toOpenAiJson()).toList(),
        'temperature': temperature,
      },
    );
    final data = resp.data as Map<String, dynamic>;
    final choice = (data['choices'] as List? ?? []).firstOrNull;
    final message =
        (choice as Map<String, dynamic>?)?['message'] as Map<String, dynamic>?;
    return message?['content'] as String? ?? '';
  }

  @override
  Future<bool> ping() async {
    try {
      await chat('Reply with "ok".', const []);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 官方模型列表接口：GET /v1/models（Bearer 认证，OpenAI 兼容协议）
  @override
  Future<List<String>> listModels() async {
    final resp = await _dio.get(
      _apiUrl(baseUrl, '/models'),
      options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
    );
    final data = resp.data as Map<String, dynamic>;
    return [
      for (final m in (data['data'] as List? ?? []))
        (m as Map<String, dynamic>)['id'] as String? ?? '',
    ].where((id) => id.isNotEmpty).toList();
  }
}

/// Ollama（本地）
class OllamaProvider implements LLMProvider {
  final String baseUrl;
  final String model;
  final Dio _dio;

  OllamaProvider({
    this.baseUrl = 'http://localhost:11434',
    this.model = 'qwen2.5',
    Dio? dio,
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  @override
  String get id => 'ollama';

  @override
  String get name => 'Ollama';

  @override
  Future<String> chat(
    String systemPrompt,
    List<ChatMessage> messages, {
    double temperature = 0.7,
  }) async {
    final resp = await _dio.post(
      '$baseUrl/api/chat',
      data: {
        'model': model,
        'stream': false,
        'messages': [
          if (systemPrompt.isNotEmpty)
            {'role': 'system', 'content': systemPrompt},
          ...messages.map((e) => e.toOpenAiJson()),
        ],
      },
    );
    final data = resp.data;
    if (data is String) {
      // Ollama 可能返回 JSONL 字符串
      return jsonDecode(data)['message']?['content'] as String? ?? '';
    }
    return (data as Map<String, dynamic>)['message']?['content'] as String? ??
        '';
  }

  @override
  Future<bool> ping() async {
    try {
      await chat('Reply with "ok".', const []);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 官方模型列表接口：GET /api/tags（本地无需认证）
  @override
  Future<List<String>> listModels() async {
    final resp = await _dio.get('${_trimTrailingSlash(baseUrl)}/api/tags');
    final data = resp.data;
    final map = data is String
        ? jsonDecode(data) as Map<String, dynamic>
        : data as Map<String, dynamic>;
    return [
      for (final m in (map['models'] as List? ?? []))
        (m as Map<String, dynamic>)['name'] as String? ?? '',
    ].where((name) => name.isNotEmpty).toList();
  }
}

/// OpenAI 兼容协议（任意兼容服务：Groq / 火山引擎 / 通义等，issue #25）。
class OpenAICompatibleProvider implements LLMProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Dio _dio;

  OpenAICompatibleProvider({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    Dio? dio,
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  @override
  String get id => 'openai';

  @override
  String get name => 'OpenAI 兼容';

  @override
  Future<String> chat(
    String systemPrompt,
    List<ChatMessage> messages, {
    double temperature = 0.7,
  }) async {
    final all = [
      if (systemPrompt.isNotEmpty) ChatMessage('system', systemPrompt),
      ...messages,
    ];
    final resp = await _dio.post(
      _apiUrl(baseUrl, '/chat/completions'),
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'content-type': 'application/json',
        },
      ),
      data: {
        'model': model,
        'messages': all.map((e) => e.toOpenAiJson()).toList(),
        'temperature': temperature,
      },
    );
    final data = resp.data as Map<String, dynamic>;
    final choice = (data['choices'] as List? ?? []).firstOrNull;
    final message =
        (choice as Map<String, dynamic>?)?['message'] as Map<String, dynamic>?;
    return message?['content'] as String? ?? '';
  }

  @override
  Future<bool> ping() async {
    try {
      await chat('Reply with "ok".', const []);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 官方模型列表接口：GET /v1/models（Bearer 认证，OpenAI 兼容协议）
  @override
  Future<List<String>> listModels() async {
    final resp = await _dio.get(
      _apiUrl(baseUrl, '/models'),
      options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
    );
    final data = resp.data as Map<String, dynamic>;
    return [
      for (final m in (data['data'] as List? ?? []))
        (m as Map<String, dynamic>)['id'] as String? ?? '',
    ].where((id) => id.isNotEmpty).toList();
  }
}

/// 按配置创建主/备供应商
class LLMProviderFactory {
  /// 根据 [AiSettings] 中 id 对应的供应商实例创建适配器（issue #25：
  /// 供应商为动态实例列表，按 id 查找后按类型分发）。
  static LLMProvider create(AiSettings ai, String id) {
    final provider = ai.providerById(id);
    if (provider == null) {
      throw ArgumentError('unknown provider: $id');
    }
    switch (provider.type) {
      case 'claude':
        return ClaudeProvider(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
          model: provider.model,
        );
      case 'deepseek':
        return DeepSeekProvider(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
          model: provider.model,
        );
      case 'ollama':
        return OllamaProvider(baseUrl: provider.baseUrl, model: provider.model);
      case 'openai':
        return OpenAICompatibleProvider(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
          model: provider.model,
        );
      default:
        throw ArgumentError('unknown provider type: ${provider.type}');
    }
  }

  /// 主备顺序（主供应商在前，备选按配置顺序）。
  ///
  /// 主供应商与备选均为空（issue #26：用户仅通过「添加供应商」配置了实例，
  /// 未单独选择主供应商）时，回退到全部「已配置」的实例（按列表顺序）——
  /// 否则生成日报会误报「没有可用的 AI 供应商（检查设置 → AI）」。
  static List<String> order(AiSettings ai) {
    final ordered = <String>[
      if (ai.provider.isNotEmpty) ai.provider,
      ...ai.fallback.where((p) => p != ai.provider),
    ];
    if (ordered.isNotEmpty) return ordered;
    return [
      for (final p in ai.providers)
        if (p.isConfigured) p.id,
    ];
  }

  /// 该供应商是否可用于会议素材（合规：设置可禁用第三方）
  static bool allowsMeeting(AiSettings ai, String providerId) =>
      ai.allowsMeeting(providerId);

  /// 按表单原始配置创建实例（「获取模型」按钮用，issue #27：值来自编辑框、
  /// 尚未保存到草稿，不能走 [create] 的 providerById 查找）。
  static LLMProvider createFromConfig({
    required String type,
    required String baseUrl,
    required String apiKey,
    String model = '',
  }) {
    switch (type) {
      case 'claude':
        return ClaudeProvider(baseUrl: baseUrl, apiKey: apiKey, model: model);
      case 'deepseek':
        return DeepSeekProvider(baseUrl: baseUrl, apiKey: apiKey, model: model);
      case 'ollama':
        return OllamaProvider(baseUrl: baseUrl, model: model);
      case 'openai':
        return OpenAICompatibleProvider(
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
        );
      default:
        throw ArgumentError('unknown provider type: $type');
    }
  }
}

/// 通过供应商官方 API 拉取模型列表（设置页「获取模型」按钮，issue #27）。
Future<List<String>> fetchProviderModels({
  required String type,
  required String baseUrl,
  required String apiKey,
}) async {
  final provider = LLMProviderFactory.createFromConfig(
    type: type,
    baseUrl: baseUrl,
    apiKey: apiKey,
  );
  return provider.listModels();
}
