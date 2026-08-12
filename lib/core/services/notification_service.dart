/// 通知服务（DESIGN.md §5.8）：系统通知封装（flutter_local_notifications）。
library;

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      linux: LinuxInitializationSettings(defaultActionName: '打开 Daymark'),
      macOS: DarwinInitializationSettings(),
      windows: WindowsInitializationSettings(
        appName: 'Daymark',
        appUserModelId: 'com.daymark.daymark',
        guid: '2a11d2a0-7e41-4d0a-9f62-7f3d4a5b6c7d',
      ),
    );
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  /// 发送通知；未初始化或平台失败时静默忽略
  Future<void> show({
    required String title,
    required String body,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        id: 1,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      // Linux 无 DBus 通知服务时静默失败
      stderr.writeln('[daymark] notification failed: $e');
    }
  }
}
