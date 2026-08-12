/// 报告引擎（DESIGN.md §5.6/§7.1）：日报/周报/月报初稿生成。
///
/// - 提示词模板与供应商解耦
/// - 失败降级：主供应商不可用 → 按配置顺序切备选
/// - 会议合规：素材含会议转录时跳过 settings 中禁用的供应商
/// - 生成可重入：只产出初稿文本，落盘与定稿由 ReportService 负责
library;

import '../ai/llm_provider.dart';
import '../ai/prompts.dart';
import '../models/material.dart';
import '../models/settings.dart';
import '../util/date_util.dart';

class ReportGenerationException implements Exception {
  final String message;
  ReportGenerationException(this.message);
  @override
  String toString() => message;
}

class ReportEngine {
  final AppSettings settings;

  ReportEngine(this.settings);

  /// 生成日报初稿（Markdown）
  Future<String> draftDaily(DailyMaterial material) async {
    final providers = _providersFor(material);
    if (providers.isEmpty) {
      throw ReportGenerationException('没有可用的 AI 供应商（检查设置 → AI）');
    }
    final system = dailySystemPrompt(settings);
    final user = ChatMessage('user', dailyUserPrompt(material, settings));
    return _chatWithFallback(providers, system, user);
  }

  /// 生成周报/月报初稿
  Future<String> draftAggregate({
    required DateTime start,
    required DateTime end,
    required List<String> dailySummaries,
    required List<QuickNote> notes,
    required bool monthly,
  }) async {
    final providers = _providersFor(null);
    if (providers.isEmpty) {
      throw ReportGenerationException('没有可用的 AI 供应商（检查设置 → AI）');
    }
    final label = monthly ? monthKey(start) : weekKey(start);
    final system = weeklySystemPrompt(settings, periodLabel: label);
    final user = ChatMessage(
      'user',
      weeklyUserPrompt(start: start, end: end, dailySummaries: dailySummaries, notes: notes),
    );
    return _chatWithFallback(providers, system, user);
  }

  /// 按合规规则选出可用供应商（含会议素材时过滤禁用项）
  List<LLMProvider> _providersFor(DailyMaterial? material) {
    final hasMeeting =
        material != null && material.transcripts.isNotEmpty && material.transcripts.any((t) => t.text.isNotEmpty);
    final ordered = LLMProviderFactory.order(settings.ai);
    final out = <LLMProvider>[];
    for (final id in ordered) {
      if (hasMeeting && !settings.ai.allowsMeeting(id)) {
        continue;
      }
      try {
        out.add(LLMProviderFactory.create(settings.ai, id));
      } catch (_) {
        // 配置了但参数缺失的供应商跳过
      }
    }
    return out;
  }

  /// 顺序尝试，全部失败抛出带原因的错误
  Future<String> _chatWithFallback(
    List<LLMProvider> providers,
    String system,
    ChatMessage user,
  ) async {
    final errors = <String>[];
    for (final p in providers) {
      try {
        return await p.chat(system, [user]);
      } catch (e) {
        errors.add('${p.name}: $e');
      }
    }
    throw ReportGenerationException('所有 AI 供应商均失败：${errors.join('；')}');
  }
}

/// 生成当日素材的人读摘要（供 UI 展示素材计数）
String materialSummary(DailyMaterial m) {
  final parts = <String>[
    if (m.notes.isNotEmpty) '随手记录 ${m.notes.length} 条',
    if (m.commits.isNotEmpty) '提交 ${m.commits.length} 条',
    if (m.fileChanges.isNotEmpty) '文件变更 ${m.fileChanges.length} 个',
    if (m.extractedDocs.isNotEmpty) '文档提取 ${m.extractedDocs.length} 个',
    if (m.transcripts.isNotEmpty) '会议转录 ${m.transcripts.length} 个',
  ];
  return parts.isEmpty ? '无素材' : parts.join('、');
}
