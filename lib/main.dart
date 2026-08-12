/// Daymark 入口：FRB 初始化 → 窗口管理 → ProviderScope。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';
import 'ui/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RustLib.init();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1120, 760),
    minimumSize: Size(880, 600),
    center: true,
    title: 'Daymark 工作日志',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      child: DaymarkApp(onWindowModeChanged: applyWindowMode),
    ),
  );
}

/// 窗口物理形态切换：主窗口 ⇄ 随手记录弹窗（单窗口变形方案）
Future<void> applyWindowMode(WindowMode mode) async {
  if (mode == WindowMode.quickNote) {
    if (Platform.isLinux) {
      // Linux 窗口边框由 WM 管理，仅做尺寸/置顶
      await windowManager.setSize(const Size(560, 150));
    } else {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(const Size(560, 150));
    }
    await windowManager.center();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
  } else {
    await windowManager.setAlwaysOnTop(false);
    if (!Platform.isLinux) {
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
    await windowManager.setSize(const Size(1120, 760));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }
}
