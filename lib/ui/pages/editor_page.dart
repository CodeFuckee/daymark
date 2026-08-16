/// 简易编辑器（DESIGN.md §5.7）：flutter_smooth_markdown 所见即所得编辑器。
///
/// - 方案 A（issue #30 第三轮人工确认）：引入 flutter_smooth_markdown 0.8.1，
///   默认 formatted 所见即所得模式（渲染块点击即可编辑，类 Typora）——
///   编辑与渲染一体、单视图，天然不存在「左右分栏同步滚动」问题，彻底消除
///   前两轮人工反馈的「右侧闪烁 / 滚到底部无法上滚」；工具栏一键切换
///   source 模式查看 / 编辑原始 Markdown 源码
/// - 「用系统编辑器打开」外调默认应用；定稿按钮落盘并归档
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smooth_markdown/flutter_smooth_markdown_editor.dart';

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
  // 方案 A：内容统一由 SmoothMarkdownEditor 持有（内部按模式渲染），
  // 这里保留 MarkdownEditorController 以便定稿 / 外调系统编辑器时读取源码
  late final MarkdownEditorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MarkdownEditorController(text: widget.initialContent ?? '')
      ..addListener(_onControllerChanged);
    _loadExisting();
  }

  /// controller 文本变化（用户输入 / source 模式编辑 / 程序化赋值）都会
  /// 触发；未保存状态直接取 controller.isDirty（与内部 savedText 对比）。
  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  bool get _dirty => _controller.isDirty;

  Future<void> _loadExisting() async {
    final content = await readExistingReport(_logRoot, widget.date);
    if (content != null && _controller.text.isEmpty && mounted) {
      // issue #28：加载既有日报/草稿后标记为已保存——「查看已定稿日报」
      // 路径（无 initialContent）也能渲染出内容，且不误报未保存修改
      _controller.text = content;
      _controller.markSaved();
      if (mounted) setState(() {});
    }
  }

  String get _logRoot =>
      ref.read(appControllerProvider.select((s) => s.settings.logRoot));

  @override
  void dispose() {
    _controller.dispose();
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
      _controller.markSaved();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已定稿')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已用系统编辑器打开（保存后回到此页继续）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportName = dailyReportPath(_logRoot, widget.date).split('/').last;
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
            // 编辑器内部 Column = 工具栏 + SizedBox(height)，height 需为
            // 具体数值；参照库示例（example/lib/editor_demo.dart）扣减
            // 工具栏等固定高度，避免 RenderFlex 溢出
            child: LayoutBuilder(
              builder: (context, constraints) {
                final editorHeight = constraints.maxHeight > 56
                    ? constraints.maxHeight - 56
                    : constraints.maxHeight;
                return SmoothMarkdownEditor(
                  key: const ValueKey('editor-smooth-markdown'),
                  controller: _controller,
                  // 方案 A 默认 formatted 所见即所得；工具栏内置
                  // Formatted / Source / Preview / Split 切换按钮
                  initialMode: MarkdownEditorMode.formatted,
                  height: editorHeight,
                  placeholder: '开始撰写日报…（Markdown 渲染块点击即可编辑）',
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
