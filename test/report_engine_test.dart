/// 报告引擎测试（issue #26）：
/// 用户「添加供应商」后未手动选择主供应商时，生成日报仍报
/// 「没有可用的 AI 供应商」——根因是主/备列表为空时没有回退到
/// 已配置的供应商实例列表。
library;

import 'package:daymark/core/ai/llm_provider.dart';
import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/report/report_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('供应商选择（issue #26）：主供应商未配置时回退已配置实例', () {
    test('主供应商为空但有已配置实例：按列表顺序使用已配置实例', () {
      final ai = AiSettings(
        providers: [
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
      // 主供应商/备选均为空（用户仅通过「添加供应商」配置了实例）
      expect(ai.provider, isEmpty);
      expect(ai.fallback, isEmpty);
      expect(LLMProviderFactory.order(ai), ['groq-1']);
    });

    test('默认预置实例（空 key / 默认 ollama）不算已配置，不参与回退', () {
      // 全新安装默认预置三家：claude/deepseek 无 key，ollama 保持默认
      // 地址/模型（未主动配置）——都不参与回退，保留
      // 「没有可用的 AI 供应商（检查设置 → AI）」引导
      final ai = AiSettings();
      expect(LLMProviderFactory.order(ai), isEmpty);

      // 用户主动改过地址/模型的 ollama 算已配置
      final localAi = AiSettings(
        providers: [
          AiProvider(
            id: 'ollama',
            type: 'ollama',
            name: 'Ollama（本地）',
            baseUrl: 'http://10.0.0.8:11434',
            model: 'qwen3',
          ),
        ],
      );
      expect(LLMProviderFactory.order(localAi), ['ollama']);
    });

    test('已配置实例缺 baseUrl 或 key 时不算可用，不参与回退', () {
      final ai = AiSettings(
        providers: [
          AiProvider(
            id: 'no-key',
            type: 'openai',
            name: '无 Key',
            baseUrl: 'https://api.example.com/v1',
            apiKey: '',
            model: 'x',
          ),
          AiProvider(
            id: 'no-url',
            type: 'deepseek',
            name: '无地址',
            baseUrl: '',
            apiKey: 'sk-1',
            model: 'x',
          ),
        ],
      );
      expect(LLMProviderFactory.order(ai), isEmpty);
    });

    test('主供应商未配置：生成日报实际尝试调用已配置实例，而非报「没有可用」', () async {
      final ai = AiSettings(
        providers: [
          AiProvider(
            id: 'ds-1',
            type: 'deepseek',
            name: '本地代理',
            baseUrl: 'http://127.0.0.1:1', // 连接必失败，快速返回
            apiKey: 'sk-test',
            model: 'deepseek-chat',
          ),
        ],
      );
      final engine = ReportEngine(AppSettings(authorName: '测试', ai: ai));
      final material = DailyMaterial(
        date: DateTime(2026, 8, 16),
        notes: [QuickNote(time: DateTime(2026, 8, 16, 9), content: '晨会', tags: const [])],
      );
      await expectLater(
        engine.draftDaily(material),
        throwsA(
          isA<ReportGenerationException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('所有 AI 供应商均失败'),
              isNot(contains('没有可用的 AI 供应商')),
            ),
          ),
        ),
        reason: '已配置实例应被实际尝试调用（连接失败是另一层错误），'
            '而不是误报「没有可用的 AI 供应商」',
      );
    });
  });
}
