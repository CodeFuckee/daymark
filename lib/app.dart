/// Daymark 根组件：窗口模式切换（主窗口 / 随手记录弹窗）+ 托盘注册。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/app_controller.dart';
import 'ui/main_window.dart';
import 'ui/quick_note_view.dart';
import 'ui/update_restart_dialog.dart';

class DaymarkApp extends ConsumerStatefulWidget {
  /// 窗口物理形态回调（main.dart 注入 window_manager 控制）
  final Future<void> Function(WindowMode mode) onWindowModeChanged;

  const DaymarkApp({super.key, required this.onWindowModeChanged});

  @override
  ConsumerState<DaymarkApp> createState() => _DaymarkAppState();
}

class _DaymarkAppState extends ConsumerState<DaymarkApp>
    with TrayListener, WindowListener {
  @override
  void initState() {
    super.initState();
    TrayManager.instance.addListener(this);
    windowManager.addListener(this);
    // 关窗 → 隐藏到托盘
    windowManager.setPreventClose(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerTray();
      ref.read(appControllerProvider.notifier).onWindowModeChanged = _apply;
    });
  }

  @override
  void dispose() {
    TrayManager.instance.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  void _apply(WindowMode mode) => widget.onWindowModeChanged(mode);

  void _registerTray() {
    final tray = TrayManager.instance;
    tray
      ..setToolTip('Daymark 工作日志')
      ..setIcon('assets/tray_icon.png')
      ..setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: '打开 Daymark'),
        MenuItem(key: 'quickNote', label: '新建记录'),
        MenuItem(key: 'generateDaily', label: '生成今日日报'),
        MenuItem(key: 'checkUpdate', label: '检查更新'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
  }

  // ────────────── TrayListener ──────────────

  @override
  void onTrayIconMouseDown() {
    ref.read(appControllerProvider.notifier).showMainWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    TrayManager.instance.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final controller = ref.read(appControllerProvider.notifier);
    switch (menuItem.key) {
      case 'open':
        controller.showMainWindow();
      case 'quickNote':
        controller.openQuickNote();
      case 'generateDaily':
        controller.generateDaily(DateTime.now());
      case 'checkUpdate':
        controller.showMainWindow();
        controller.checkForUpdates();
      case 'quit':
        windowManager.destroy();
    }
  }

  // ────────────── WindowListener ──────────────

  @override
  void onWindowClose() {
    // 拦截关闭：隐藏到托盘（托盘"退出"才真正退出）
    windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appControllerProvider.select((s) => s.windowMode));
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E64DC)),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'Daymark',
      theme: theme,
      debugShowCheckedModeBanner: false,
      // 外层包更新重启对话框宿主（issue #29）：下载完成自动弹窗提示重启，
      // 主窗口 / 随手记录弹窗两种形态下都保持监听。
      home: UpdateRestartDialogHost(
        child: mode == WindowMode.quickNote
            ? const QuickNoteView()
            : const MainWindow(),
      ),
    );
  }
}
