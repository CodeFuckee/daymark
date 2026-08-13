/// 提示词模板（DESIGN.md §7.2/§4.3）：日报四段式 + 周报/月报聚合。
///
/// 硬规则（沿用 daily-work-report 提炼原则）：
/// - 不编造素材中没有的内容；素材不足时如实写明"当日无提交"等
/// - 代码按项目分组、会议只留与作者相关、随手记录按主题归类
library;

import '../models/material.dart';
import '../models/settings.dart';
import '../providers/code_provider.dart';
import '../util/date_util.dart';

/// 日报系统提示
String dailySystemPrompt(AppSettings s) {
  final tone = s.ai.tone.isNotEmpty ? '\n语气偏好：${s.ai.tone}。' : '';
  return '''
你是一名工作日志助手。根据提供的"当日素材"，生成一份 Markdown 工作日报。

输出格式（严格按此结构）：

# 工作日报 {日期}

## 一、代码提交
（按项目分组；把 commit message 润色为自然语言，说明做了什么）

## 二、本地文件工作
（按目录/类型分组；引用文档提取要点；用"今日检测到变更"措辞，不做绝对断言）

## 三、会议记录
（每个音频一行：文件名 + 与本人相关的内容要点；无关会议只列主题并注明"与本人关系不大"）

## 四、随手记录汇总
（inbox 条目按主题归类，归纳表述，不逐条罗列）

## 五、补充说明
（仅当素材中有额外信息需要说明时写入，否则省略整个章节）

硬规则：
1. 只使用素材中出现的内容，不编造、不脑补细节
2. 某类素材为空时，如实写"当日无提交""当日无会议"等，不得虚构
3. 保持客观平实，不用营销性词汇
4. 全文使用简体中文$tone
''';
}

/// 日报素材序列化为用户提示
String dailyUserPrompt(DailyMaterial m, AppSettings s) {
  // 作者名可配置多个匹配值（逗号分隔），署名取第一个非空值（issue #9）
  final authorValues = splitAuthorValues(s.authorName);
  final displayName = authorValues.isEmpty ? '（未设置）' : authorValues.first;
  final buf = StringBuffer()
    ..writeln('日期：${dateKey(m.date)}（${s.timezone} 自然日）')
    ..writeln('作者：$displayName')
    ..writeln();

  // 一、代码提交
  buf.writeln('【代码提交】${m.commits.isEmpty ? "（无）" : ""}');
  for (final c in m.commits) {
    buf.writeln('- [$c.provider/${c.project}] ${c.message}（${hhmm(c.date)}，作者 ${c.author}）');
  }
  buf.writeln();

  // 二、本地文件工作
  buf.writeln('【本地文件变更】${m.fileChanges.isEmpty ? "（无）" : ""}');
  for (final f in m.fileChanges) {
    buf.writeln('- [${f.kind}] ${f.path}（mtime ${hhmm(f.mtime)}）');
  }
  if (m.extractedDocs.isNotEmpty) {
    buf.writeln('【文档提取要点】');
    for (final e in m.extractedDocs) {
      buf.writeln('- ${e.kind.toUpperCase()} ${e.title}：${_excerpt(e.textExcerpt)}');
    }
  }
  buf.writeln();

  // 三、会议
  buf.writeln('【会议转录】${m.transcripts.isEmpty ? "（无）" : ""}');
  for (final t in m.transcripts) {
    buf.writeln('- 音频：${t.audioPath}');
    buf.writeln('  转写要点：${_excerpt(t.text)}');
  }
  buf.writeln();

  // 四、随手记录
  buf.writeln('【随手记录】${m.notes.isEmpty ? "（无）" : ""}');
  for (final n in m.notes) {
    final tags = n.tags.isEmpty ? '' : ' ${n.tags.map((t) => '#$t').join(' ')}';
    buf.writeln('- [${hhmm(n.time)}] ${n.content}$tags');
  }
  return buf.toString();
}

String _excerpt(String text, {int max = 800}) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// 周报/月报系统提示（聚合期内素材）
String weeklySystemPrompt(AppSettings s, {required String periodLabel}) {
  final tone = s.ai.tone.isNotEmpty ? '\n语气偏好：${s.ai.tone}。' : '';
  return '''
你是一名工作日志助手。根据 $periodLabel 期内的日报要点与随手记录，生成一份 Markdown 聚合报告。

输出格式（严格按此结构）：

# $periodLabel 工作${periodLabel.contains('周') ? '周报' : '月报'}

## 一、本期完成
（归纳主题，说明完成了什么）

## 二、进行中
（仍在推进的事项）

## 三、问题与阻塞
（没有则写"无"）

## 四、下期计划
（没有则写"无"）

硬规则：
1. 只使用素材中出现的内容，不编造
2. 按主题归纳，不逐条罗列
3. 全文使用简体中文$tone
''';
}

/// 周报素材：期内各日报初稿/定稿 + inbox
String weeklyUserPrompt({
  required DateTime start,
  required DateTime end,
  required List<String> dailySummaries,
  required List<QuickNote> notes,
}) {
  final buf = StringBuffer()
    ..writeln('统计区间：${dateKey(start)} ~ ${dateKey(end)}')
    ..writeln();
  buf.writeln('【期内日报要点】');
  if (dailySummaries.isEmpty) {
    buf.writeln('（无日报记录）');
  } else {
    for (final d in dailySummaries) {
      buf.writeln('---');
      buf.writeln(d.trim());
    }
  }
  buf.writeln();
  buf.writeln('【期内随手记录】${notes.isEmpty ? "（无）" : ""}');
  for (final n in notes) {
    final tags = n.tags.isEmpty ? '' : ' ${n.tags.map((t) => '#$t').join(' ')}';
    buf.writeln('- [${dateKey(n.time)} ${hhmm(n.time)}] ${n.content}$tags');
  }
  return buf.toString();
}
