/// 自动更新重启对话框宿主（issue #29）：
/// 监听更新阶段转为 ready（最新版下载完成）→ 自动弹出对话框提示用户重启，
/// 用户可选「立即重启」或「稍后重启」。
///
/// - 放在根组件（两种窗口形态：主窗口 / 随手记录弹窗下都在树中），下载完成
///   时刻无论用户在哪个页面都能弹出；
/// - 以 phase 的「转换」为触发条件（prev != ready && next == ready），同一
///   次下载完成的 ready 状态不会重复弹窗；用户「稍后重启」后再检查并再次
///   下载完成，会重新弹出提示；
/// - 「立即重启」失败（未找到更新包 / 环境不支持自动安装）→ 再弹一个错误
///   对话框说明原因，避免静默失败。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';

class UpdateRestartDialogHost extends ConsumerStatefulWidget {
  /// 实际内容（主窗口或随手记录弹窗）
  final Widget child;

  const UpdateRestartDialogHost({super.key, required this.child});

  @override
  ConsumerState<UpdateRestartDialogHost> createState() =>
      _UpdateRestartDialogHostState();
}

class _UpdateRestartDialogHostState
    extends ConsumerState<UpdateRestartDialogHost> {
  /// 弹窗打开中标记：防止同一 ready 状态重复弹窗 / 弹窗期间再次触发
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    // phase 转为 ready（下载完成）时自动弹窗
    ref.listen<UpdatePhase>(
      appControllerProvider.select((s) => s.updateStatus.phase),
      (prev, next) {
        if (next == UpdatePhase.ready && prev != UpdatePhase.ready) {
          _showRestartDialog();
        }
      },
    );
    return widget.child;
  }

  Future<void> _showRestartDialog() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    final tag = ref.read(appControllerProvider).updateStatus.version;
    final restartNow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('新版本 ${tag == null ? '' : 'v$tag '}已下载完成'),
        content: const Text('重启软件即可完成更新。\n您可以选择立即重启，或稍后在设置页手动重启。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后重启'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (restartNow != true || !mounted) return;

    final controller = ref.read(appControllerProvider.notifier);
    final ok = await controller.restartToUpdate();
    if (!ok && mounted) {
      final message =
          ref.read(appControllerProvider).updateStatus.message ??
          '无法自动重启，请稍后在设置页手动重启';
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法自动重启'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }
}
