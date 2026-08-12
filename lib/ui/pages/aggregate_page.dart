/// 周报/月报页（DESIGN.md §7.4）：生成聚合报告，已存在不覆盖。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/date_util.dart';
import '../app_controller.dart';
import 'editor_page.dart';

class AggregatePage extends ConsumerStatefulWidget {
  const AggregatePage({super.key});

  @override
  ConsumerState<AggregatePage> createState() => _AggregatePageState();
}

class _AggregatePageState extends ConsumerState<AggregatePage> {
  bool _busy = false;
  String? _message;
  String? _error;

  Future<void> _generate({required bool monthly}) async {
    final controller = ref.read(appControllerProvider.notifier);
    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });
    try {
      final (created, content) = monthly
          ? await controller.generateMonthly(DateTime.now())
          : await controller.generateWeekly(DateTime.now());
      if (!mounted) return;
      if (!created) {
        setState(() {
          _busy = false;
          _message = monthly ? '本月月报已存在' : '本周周报已存在';
        });
        return;
      }
      // 跳转编辑器查看
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditorPage(
            date: DateTime.now(),
            initialContent: content,
          ),
        ),
      );
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '生成失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final notConfigured = settings.logRoot.isEmpty;
    final now = DateTime.now();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('聚合报告', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '按期内日报要点与随手记录，由 AI 归纳生成。已存在时不覆盖。',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          if (_message != null)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(_message!),
              ),
            ),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.weekend_outlined),
                    title: const Text('本周周报'),
                    subtitle: Text('${weekKey(now)}（${_weekRange(now)}）'),
                    trailing: FilledButton(
                      onPressed: (_busy || notConfigured) ? null : () => _generate(monthly: false),
                      child: const Text('生成'),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: const Text('本月月报'),
                    subtitle: Text(monthKey(now)),
                    trailing: FilledButton(
                      onPressed: (_busy || notConfigured) ? null : () => _generate(monthly: true),
                      child: const Text('生成'),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('已归档文件', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(child: _ArchiveList(logRoot: settings.logRoot)),
        ],
      ),
    );
  }

  static String _weekRange(DateTime now) {
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    return '${dateKey(monday)} ~ ${dateKey(sunday)}';
  }
}

/// 已归档的周报/月报列表
class _ArchiveList extends ConsumerWidget {
  final String logRoot;
  const _ArchiveList({required this.logRoot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<FileInfo>>(
      future: _listArchives(logRoot),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final files = snapshot.data!;
        if (files.isEmpty) {
          return Text(
            '暂无归档',
            style: TextStyle(color: Colors.grey.shade500),
          );
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) {
            final f = files[i];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined),
              title: Text(f.path.split('/').last),
              subtitle: Text(f.modified.toString().split('.')[0]),
              onTap: () async {
                // 归档文件用系统默认应用打开
                final cmd = Platform.isLinux
                    ? 'xdg-open'
                    : Platform.isMacOS
                        ? 'open'
                        : 'start';
                await Process.run(cmd, [f.path], runInShell: Platform.isWindows);
              },
            );
          },
        );
      },
    );
  }

  Future<List<FileInfo>> _listArchives(String logRoot) async {
    final out = <FileInfo>[];
    for (final sub in ['周报', '月报']) {
      final dir = Directory('$logRoot/$sub');
      if (!await dir.exists()) continue;
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File) files.add(e);
      }
      for (final f in files) {
        out.add(FileInfo(f.path, (await f.stat()).modified));
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }
}

class FileInfo {
  final String path;
  final DateTime modified;
  FileInfo(this.path, this.modified);
}
