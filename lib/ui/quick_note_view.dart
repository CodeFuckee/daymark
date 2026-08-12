/// 随手记录弹窗（DESIGN.md §5.1）：单行输入 + 时间戳前缀 + 标签自动补全。
///
/// - 回车即存（append 到 inbox/<今天>.md），窗口隐藏
/// - Esc / Ctrl+Q 丢弃
/// - 输入 `#` 开头时按历史标签补全
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/date_util.dart';
import 'app_controller.dart';

class QuickNoteView extends ConsumerStatefulWidget {
  const QuickNoteView({super.key});

  @override
  ConsumerState<QuickNoteView> createState() => _QuickNoteViewState();
}

class _QuickNoteViewState extends ConsumerState<QuickNoteView> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 打开即聚焦
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    await ref.read(appControllerProvider.notifier).saveQuickNote();
    _saving = false;
  }

  void _dismiss() {
    ref.read(appControllerProvider.notifier).dismissQuickNote();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final now = DateTime.now();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.escape ||
                  (event.logicalKey == LogicalKeyboardKey.keyQ &&
                      HardwareKeyboard.instance.isControlPressed)) {
                _dismiss();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter) {
                _save();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Row(
            children: [
              // 时间戳前缀
              Text(
                '[${hhmm(now)}] ',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Colors.grey[600], fontFamily: 'monospace'),
              ),
              Expanded(
                child: Autocomplete<String>(
                  optionsBuilder: (TextEditingValue value) {
                    final input = value.text;
                    final hashIdx = input.lastIndexOf('#');
                    if (hashIdx < 0 || hashIdx == input.length - 1) {
                      return const Iterable<String>.empty();
                    }
                    final prefix = input.substring(hashIdx + 1).toLowerCase();
                    return state.tags.where((t) => t.toLowerCase().startsWith(prefix));
                  },
                  onSelected: (tag) {
                    final text = _controller.text;
                    final hashIdx = text.lastIndexOf('#');
                    final keep = hashIdx >= 0 ? text.substring(0, hashIdx) : text;
                    _controller.text = '$keep#$tag ';
                    _controller.selection =
                        TextSelection.collapsed(offset: _controller.text.length);
                  },
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    return TextField(
                      controller: controller,
                      focusNode: _focusNode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '记一条（回车保存，Esc 丢弃）…',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontFamily: 'monospace'),
                      onSubmitted: (_) => _save(),
                      onChanged: (text) {
                        ref
                            .read(appControllerProvider.notifier)
                            .updateQuickNoteInput(text);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
