/// Daymark 入口：FRB 初始化 → 待安装更新检查 → 窗口管理 → ProviderScope。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/update/update_config.dart';
import 'core/update/update_installer.dart';
import 'core/update/update_service.dart';
import 'core/update/update_version.dart';
import 'src/rust/frb_generated.dart';
import 'ui/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RustLib.init();
  // 重启时自动完成更新（issue #5）：上次下载的更新包 → 安装并进入新版。
  // Linux/macOS 安装后重启进程；Windows 启动安装器后退出（安装器完成自动启动新版）。
  await _installPendingUpdateIfAny();
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

/// 启动时处理待安装更新：安装包齐全且版本高于当前 → 平台化安装（内部重启/退出）；
/// 版本不高于当前（上次安装成功但未清理）→ 清理 pending 目录。
Future<void> _installPendingUpdateIfAny() async {
  final config = UpdateConfig.fromEnvironment();
  if (!config.enabled) return;
  final service = UpdateService(config: config);
  final manifest = await service.loadManifest();
  if (manifest == null) return;
  if (compareVersions(manifest.version, config.appVersion!) <= 0) {
    await service.clearPending();
    return;
  }
  final installer = UpdateInstaller();
  await installer.install(manifest, await service.updateDir());
  // 走到这里 = 环境不支持自动安装（如非 AppImage 产物），静默保留 pending，
  // 用户可在设置页看到"重启并更新"入口；若连入口也不可用则需手动下载。
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
