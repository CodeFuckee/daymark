/// 日报页（DESIGN.md §5.6）：选日期 → 素材概览 → 生成初稿 → 编辑器定稿。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/material.dart';
import '../../core/report/report_engine.dart';
import '../../core/util/date_util.dart';
import '../../core/util/markdown_util.dart';
import '../app_controller.dart';
import 'editor_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  DateTime _date = dayStart(DateTime.now());
  DailyMaterial? _material;
  String? _error;
  String? _progress;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final controller = ref.read(appControllerProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final material = await controller.collectForDate(
        _date,
        onProgress: (p) => setState(() => _progress = p),
      );
      if (mounted) {
        setState(() {
          _material = material;
          _progress = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    final controller = ref.read(appControllerProvider.notifier);
    setState(() {
      _busy = true;
      _progress = '正在收集素材并生成日报…';
    });
    try {
      // 含转录的完整收集
      final material = await controller.collectDay(
        _date,
        onProgress: (p) => setState(() => _progress = p),
      );
      final draft = await controller.generateDaily(_date, material: material);
      if (!mounted) return;
      if (draft == null) {
        setState(() {
          _busy = false;
          _progress = null;
          _error = '今日日报已定稿，可在编辑器查看；如需重新生成请先删除定稿文件。';
        });
        return;
      }
      _openEditor(draft);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '生成失败：$e';
        });
      }
    }
  }

  void _openEditor([String? content]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(date: _date, initialContent: content),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final notConfigured = settings.logRoot.isEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 日期选择
          Row(
            children: [
              IconButton(
                onPressed: () =>
                    setState(() => _date = _date.subtract(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_left),
              ),
              TextButton.icon(
                onPressed: () => _pickDate(),
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  dateKey(_date),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _date = _date.add(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_right),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新素材'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (_busy || notConfigured) ? null : _generate,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('生成今日日报'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_progress != null)
            LinearProgressIndicator(value: null, minHeight: 2),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(child: _buildContent(notConfigured)),
        ],
      ),
    );
  }

  Widget _buildContent(bool notConfigured) {
    if (notConfigured) {
      return const _EmptyHint(
        icon: Icons.settings,
        text: '尚未配置日志根目录，请先到「设置」完成基础配置。',
      );
    }
    final material = _material;
    if (material == null && _busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (material == null) {
      return const _EmptyHint(icon: Icons.inbox, text: '点击「刷新素材」收集当天素材。');
    }
    // 判断是否已有定稿/草稿（用设置里的 logRoot）
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final finalized = isFinalized(settings.logRoot, _date);
    final draft = File(draftPath(settings.logRoot, _date)).existsSync();

    return ListView(
      children: [
        if (finalized)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.check_circle),
              title: const Text('今日日报已定稿'),
              trailing: FilledButton(
                onPressed: () => _openEditor(),
                child: const Text('查看'),
              ),
            ),
          )
        else if (draft)
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.edit_document),
              title: const Text('存在日报初稿（未定稿）'),
              subtitle: const Text('素材变化后可重新生成，定稿后写入正式文件'),
              trailing: FilledButton(
                onPressed: () => _openEditor(),
                child: const Text('继续编辑'),
              ),
            ),
          ),
        const SizedBox(height: 8),
        _MaterialCard(
          title: '随手记录',
          icon: Icons.edit_note,
          items: material.notes.map((n) => '${hhmm(n.time)}  ${n.content}').toList(),
          emptyText: '今日无随手记录',
        ),
        _MaterialCard(
          title: '代码提交',
          icon: Icons.code,
          items: material.commits
              .map((c) => '${c.provider}/${c.project} — ${_firstLine(c.message)}')
              .toList(),
          emptyText: '当日无提交',
        ),
        _MaterialCard(
          title: '本地文件变更',
          icon: Icons.folder_open,
          items: material.fileChanges
              .map((f) => '[${f.kind}] ${f.path}')
              .toList(),
          emptyText: '当日无文件变更',
        ),
        _MaterialCard(
          title: '文档提取',
          icon: Icons.description,
          items: material.extractedDocs
              .map((e) => '${e.kind.toUpperCase()} ${e.title}')
              .toList(),
          emptyText: '无文档要点',
        ),
        _MaterialCard(
          title: '会议转录',
          icon: Icons.mic,
          items: material.transcripts
              .map((t) => t.audioPath.split('/').last)
              .toList(),
          emptyText: '当日无会议转录',
        ),
        const SizedBox(height: 8),
        Text(
          '素材合计：${materialSummary(material)}',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Text(
          '提示：生成会收集素材 → AI 起草 → 编辑器润色 → 定稿落盘。'
          '转录与提交拉取较慢时请留意进度条。',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
      ],
    );
  }

  static String _firstLine(String s) {
    final line = s.split('\n').first.trim();
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() => _date = dayStart(picked));
      _refresh();
    }
  }
}

class _MaterialCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> items;
  final String emptyText;

  const _MaterialCard({
    required this.title,
    required this.icon,
    required this.items,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '$title（${items.length}）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(emptyText, style: TextStyle(color: Colors.grey.shade500)),
              )
            else
              ...items.take(8).map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(item, style: const TextStyle(fontSize: 13)),
                    ),
                  ),
            if (items.length > 8)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '… 共 ${items.length} 条',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
