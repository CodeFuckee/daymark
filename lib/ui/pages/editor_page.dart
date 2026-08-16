/// 简易编辑器（DESIGN.md §5.7）：等宽 TextField + flutter_markdown 预览分栏。
///
/// - 左右分栏（可拖动分割线）；定稿按钮落盘并归档
/// - 「用系统编辑器打开」外调默认应用
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/markdown_util.dart';
import '../app_controller.dart';

class EditorPage extends ConsumerStatefulWidget {
  final DateTime date;
  final String? initialContent;

  const EditorPage({super.key, required this.date, this.initialContent});

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  late final TextEditingController _controller;
  bool _dirty = false;
  // issue #30：左右分栏同步滚动——左侧源码 / 右侧预览各持一个滚动控制器，
  // 任一侧滚动时按「相对位置比例」同步另一侧（两侧内容高度不同，像素同步
  // 会错位）；_syncing 防止同步跳转触发反向再同步造成回环
  late final ScrollController _leftScrollController;
  late final ScrollController _rightScrollController;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent ?? '');
    _leftScrollController = ScrollController()
      ..addListener(() => _syncScroll(_leftScrollController, _rightScrollController));
    _rightScrollController = ScrollController()
      ..addListener(() => _syncScroll(_rightScrollController, _leftScrollController));
    _loadExisting();
  }

  /// 双向比例同步：source 滚动时按 已滚动比例 = offset / maxScrollExtent
  /// 把 target 跳到相同比例位置。任一侧不可滚动（内容不足一屏，
  /// maxScrollExtent <= 0）时不做同步，避免除零与无意义跳转。
  void _syncScroll(ScrollController source, ScrollController target) {
    if (_syncing) return;
    if (!source.hasClients || !target.hasClients) return;
    final srcMax = source.position.maxScrollExtent;
    final tgtMax = target.position.maxScrollExtent;
    if (srcMax <= 0 || tgtMax <= 0) return;
    _syncing = true;
    try {
      final ratio = source.offset / srcMax;
      target.jumpTo(ratio * tgtMax);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _loadExisting() async {
    final content = await readExistingReport(_logRoot, widget.date);
    if (content != null && _controller.text.isEmpty && mounted) {
      // issue #28：赋值 controller 必须 setState——左侧 TextField 内部监听
      // controller 会自动刷新，右侧 Markdown 取的是构建时的 _controller.text，
      // 不重建就停留在初始空白（定稿后「查看」路径预览空白即此原因）
      setState(() {
        _controller.text = content;
      });
    }
  }

  String get _logRoot =>
      ref.read(appControllerProvider.select((s) => s.settings.logRoot));

  @override
  void dispose() {
    _controller.dispose();
    _leftScrollController.dispose();
    _rightScrollController.dispose();
    super.dispose();
  }

  Future<void> _finalize() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('定稿'),
        content: const Text('定稿后写入正式日报文件，素材变化不会覆盖已定稿内容。确认定稿？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('定稿'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(appControllerProvider.notifier)
        .finalizeDaily(widget.date, text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已定稿')),
      );
    }
  }

  Future<void> _openSystemEditor() async {
    // 写入临时文件后调用系统默认打开
    final dir = Directory('$_logRoot/.daymark/草稿');
    await dir.create(recursive: true);
    final file = File(draftPath(_logRoot, widget.date));
    await file.writeAsString(_controller.text);
    await Process.run(
      Platform.isLinux
          ? 'xdg-open'
          : Platform.isMacOS
              ? 'open'
              : 'start',
      [file.path],
      runInShell: Platform.isWindows,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已用系统编辑器打开（保存后回到此页继续）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportName =
        dailyReportPath(_logRoot, widget.date).split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text(reportName),
        actions: [
          IconButton(
            tooltip: '用系统编辑器打开',
            onPressed: _openSystemEditor,
            icon: const Icon(Icons.open_in_new),
          ),
          FilledButton.icon(
            onPressed: _finalize,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('定稿'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          if (_dirty)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '未保存的修改',
                style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final split = constraints.maxWidth / 2;
                return Row(
                  children: [
                    SizedBox(
                      width: split,
                      // key 供测试定位左侧滚动容器
                      child: SingleChildScrollView(
                        key: const ValueKey('editor-left-scroll'),
                        controller: _leftScrollController,
                        child: TextField(
                          controller: _controller,
                          maxLines: null,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.6,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.all(12),
                          ),
                          onChanged: (_) => setState(() => _dirty = true),
                        ),
                      ),
                    ),
                    VerticalDivider(width: 1, thickness: 1),
                    Expanded(
                      child: Markdown(
                        data: _controller.text,
                        padding: const EdgeInsets.all(12),
                        controller: _rightScrollController,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
