/// 应用状态中枢（Riverpod Notifier）：服务装配 + 热键/托盘事件 → UI。
///
/// 单窗口方案：热键弹窗 = 主窗口变形为无边框置顶小窗（window_manager 控制），
/// 输入完成恢复主窗口形态（避免 Linux 多窗口复杂度和系统托盘兼容问题）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../core/models/material.dart';
import '../core/models/settings.dart';
import '../core/services/collect_service.dart';
import '../core/services/notification_service.dart';
import '../core/services/record_service.dart';
import '../core/services/report_service.dart';
import '../core/services/settings_service.dart';
import '../core/util/date_util.dart';
import '../src/rust/api/hotkey.dart' as frb_hotkey;

/// 窗口模式：主窗口 / 随手记录弹窗
enum WindowMode { main, quickNote }

class AppState {
  final AppSettings settings;
  final bool settingsLoaded;
  final WindowMode windowMode;
  final String? hotkeyError;
  final String? lastNotification;

  /// 热键弹窗当前输入
  final String quickNoteInput;
  /// 历史标签（补全用）
  final List<String> tags;

  AppState({
    AppSettings? settings,
    this.settingsLoaded = false,
    this.windowMode = WindowMode.main,
    this.hotkeyError,
    this.lastNotification,
    this.quickNoteInput = '',
    this.tags = const [],
  }) : settings = settings ?? AppSettings();

  AppState copyWith({
    AppSettings? settings,
    bool? settingsLoaded,
    WindowMode? windowMode,
    String? hotkeyError,
    String? lastNotification,
    String? quickNoteInput,
    List<String>? tags,
    bool clearHotkeyError = false,
    bool clearNotification = false,
  }) =>
      AppState(
        settings: settings ?? this.settings,
        settingsLoaded: settingsLoaded ?? this.settingsLoaded,
        windowMode: windowMode ?? this.windowMode,
        hotkeyError: clearHotkeyError ? null : (hotkeyError ?? this.hotkeyError),
        lastNotification:
            clearNotification ? null : (lastNotification ?? this.lastNotification),
        quickNoteInput: quickNoteInput ?? this.quickNoteInput,
        tags: tags ?? this.tags,
      );
}

/// 热键 id（Dart 侧生成，Rust 转发）
const int kQuickNoteHotkeyId = 1;
const int kWatchId = 1;

class AppController extends Notifier<AppState> {
  late SettingsService settingsService;
  late RecordService recordService;
  late CollectService collectService;
  late ReportService reportService;
  late NotificationService notificationService;

  StreamSubscription<int>? _hotkeySub;

  /// 窗口控制回调（由 main.dart 注入，避免 ui 层依赖 window_manager 细节）
  void Function(WindowMode mode)? onWindowModeChanged;

  @override
  AppState build() {
    settingsService = SettingsService();
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
    notificationService = NotificationService();
    // 注入 token 读取
    collectService.tokenProvider = (id) => settingsService.getToken(id);

    _init();
    return AppState();
  }

  Future<void> _init() async {
    await settingsService.load();
    await notificationService.init();
    _rebuildServices();
    await _applyHotkey();
    await _startWatching();
    await _syncAutoLaunch();
    state = state.copyWith(settingsLoaded: true, tags: []);
  }

  /// 设置变更后重建服务（服务持有 settings 引用）
  void _rebuildServices() {
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings)
      ..tokenProvider = (id) => settingsService.getToken(id);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
  }

  // ─────────────────────────── 设置 ───────────────────────────

  Future<void> saveSettings(AppSettings next) async {
    settingsService.settings = next;
    await settingsService.save();
    _rebuildServices();
    await _applyHotkey();
    await _startWatching();
    await _applyAutoLaunch(next.hotkey.autoLaunch);
    state = state.copyWith(settings: next);
  }

  // ─────────────────────────── 全局热键 ───────────────────────────

  Future<void> _applyHotkey() async {
    await _hotkeySub?.cancel();
    await frb_hotkey.unregisterHotkey(id: BigInt.from(kQuickNoteHotkeyId));
    final hs = settingsService.settings.hotkey;
    try {
      final stream = frb_hotkey.registerHotkey(
        id: BigInt.from(kQuickNoteHotkeyId),
        modifiers: hs.modifiers,
        key: hs.key,
      );
      _hotkeySub = stream.listen((_) => openQuickNote(), onError: (Object e) {
        state = state.copyWith(
          hotkeyError: '全局热键注册失败：$e（设置 → 快捷键可改键）',
        );
      });
      state = state.copyWith(
        hotkeyError: null,
        clearHotkeyError: true,
      );
    } catch (e) {
      state = state.copyWith(hotkeyError: '全局热键注册失败：$e（设置 → 快捷键可改键）');
    }
  }

  // ─────────────────────────── 文件监控 ───────────────────────────

  Future<void> _startWatching() => collectService.startWatching();

  // ─────────────────────────── 开机自启 ───────────────────────────

  /// 设置变更时应用自启开关
  Future<void> _applyAutoLaunch(bool enable) async {
    try {
      if (enable) {
        final ok = await LaunchAtStartup.instance.enable();
        if (!ok) {
          state = state.copyWith(
            lastNotification: '开机自启启用失败（请检查应用目录权限）',
          );
        }
      } else {
        await LaunchAtStartup.instance.disable();
      }
    } catch (e) {
      debugPrint('[daymark] auto launch error: $e');
    }
  }

  /// 启动时同步：配置要求自启但系统未启用时补一次
  Future<void> _syncAutoLaunch() async {
    final want = state.settings.hotkey.autoLaunch;
    if (!want) return;
    try {
      if (!await LaunchAtStartup.instance.isEnabled()) {
        await _applyAutoLaunch(true);
      }
    } catch (e) {
      debugPrint('[daymark] auto launch sync error: $e');
    }
  }

  // ─────────────────────────── 随手记录 ───────────────────────────

  void openQuickNote() {
    if (!state.settingsLoaded || state.settings.logRoot.isEmpty) {
      state = state.copyWith(
        lastNotification: '请先在设置中配置日志根目录',
        clearNotification: false,
      );
      onWindowModeChanged?.call(WindowMode.main);
      return;
    }
    // 刷新标签补全
    recordService.tags().then((tags) {
      state = state.copyWith(tags: tags);
    });
    state = state.copyWith(windowMode: WindowMode.quickNote, quickNoteInput: '');
    onWindowModeChanged?.call(WindowMode.quickNote);
  }

  void updateQuickNoteInput(String text) {
    state = state.copyWith(quickNoteInput: text);
  }

  /// 回车：保存并关闭弹窗
  Future<void> saveQuickNote() async {
    final text = state.quickNoteInput.trim();
    state = state.copyWith(quickNoteInput: '', windowMode: WindowMode.main);
    onWindowModeChanged?.call(WindowMode.main);
    if (text.isEmpty) return;
    await recordService.addNote(text);
    // 记录新标签
    final tags = await recordService.tags();
    state = state.copyWith(tags: tags);
  }

  /// Esc：丢弃
  void dismissQuickNote() {
    state = state.copyWith(quickNoteInput: '', windowMode: WindowMode.main);
    onWindowModeChanged?.call(WindowMode.main);
  }

  void showMainWindow() {
    state = state.copyWith(windowMode: WindowMode.main);
    onWindowModeChanged?.call(WindowMode.main);
  }

  // ─────────────────────────── 日报生成 ───────────────────────────

  /// 收集某天素材（含转录，慢）
  Future<DailyMaterial> collectDay(DateTime date, {void Function(String)? onProgress}) =>
      reportService.collect(date, onProgress: onProgress);

  /// 收集某天素材（不含转录，快）
  Future<DailyMaterial> collectForDate(DateTime date, {void Function(String)? onProgress}) =>
      reportService.collectForDate(date, onProgress: onProgress);

  /// 生成日报初稿（后台任务，生成完成通知）
  Future<String?> generateDaily(
    DateTime date, {
    DailyMaterial? material,
    void Function(String)? onProgress,
  }) async {
    final draft = await reportService.generateDaily(
      date,
      material: material,
      onProgress: onProgress,
    );
    if (draft != null && state.settings.notification.completionNotification) {
      await notificationService.show(
        title: '日报初稿已生成',
        body: '${dateKey(date)} 日报初稿已生成，请到编辑器中润色。',
      );
    }
    return draft;
  }

  Future<void> finalizeDaily(DateTime date, String content) async {
    await reportService.finalizeDaily(date, content);
    if (state.settings.notification.completionNotification) {
      await notificationService.show(title: '日报已定稿', body: '${dateKey(date)} 日报已写入。');
    }
  }

  /// 生成周报/月报，返回 (是否新创建, 内容)
  Future<(bool, String?)> generateWeekly(DateTime date) async {
    final draft = await reportService.generateWeekly(date);
    if (draft != null && state.settings.notification.completionNotification) {
      await notificationService.show(title: '周报已生成', body: '${weekKey(date)} 周报已写入。');
    }
    return (draft != null, draft);
  }

  Future<(bool, String?)> generateMonthly(DateTime date) async {
    final draft = await reportService.generateMonthly(date);
    if (draft != null && state.settings.notification.completionNotification) {
      await notificationService.show(title: '月报已生成', body: '${monthKey(date)} 月报已写入。');
    }
    return (draft != null, draft);
  }

  // ─────────────────────────── 通知 ───────────────────────────

  void notify(String message) {
    state = state.copyWith(lastNotification: message);
  }

  void clearNotification() {
    state = state.copyWith(clearNotification: true);
  }
}

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

/// 直接访问 SettingsService（token 读写等）
final settingsServiceProvider = Provider<SettingsService>((ref) {
  return ref.watch(appControllerProvider.notifier).settingsService;
});
