/// 应用状态中枢（Riverpod Notifier）：服务装配 + 热键/托盘事件 → UI。
///
/// 单窗口方案：热键弹窗 = 主窗口变形为无边框置顶小窗（window_manager 控制），
/// 输入完成恢复主窗口形态（避免 Linux 多窗口复杂度和系统托盘兼容问题）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../core/models/material.dart';
import '../core/models/settings.dart';
import '../core/providers/code_provider.dart';
import '../core/providers/github_provider.dart';
import '../core/providers/gitlab_provider.dart';
import '../core/services/collect_service.dart';
import '../core/services/notification_service.dart';
import '../core/services/record_service.dart';
import '../core/services/report_service.dart';
import '../core/services/settings_service.dart';
import '../core/update/update_config.dart';
import '../core/update/update_installer.dart';
import '../core/update/update_models.dart';
import '../core/update/update_service.dart';
import '../core/util/date_util.dart';
import '../src/rust/api/hotkey.dart' as frb_hotkey;

/// 窗口模式：主窗口 / 随手记录弹窗
enum WindowMode { main, quickNote }

/// 更新阶段（设置页展示）
enum UpdatePhase { idle, checking, available, downloading, ready, error }

/// 更新状态（issue #5）
class UpdateStatus {
  final UpdatePhase phase;
  /// 新版本 tag（available/downloading/ready 时非空）
  final String? version;
  /// 下载进度 0~1
  final double? progress;
  /// 错误/提示信息
  final String? message;

  const UpdateStatus({
    this.phase = UpdatePhase.idle,
    this.version,
    this.progress,
    this.message,
  });

  const UpdateStatus.checking()
      : this(phase: UpdatePhase.checking);
  const UpdateStatus.available(String tag)
      : this(phase: UpdatePhase.available, version: tag);
  const UpdateStatus.downloading(String tag, double progress)
      : this(phase: UpdatePhase.downloading, version: tag, progress: progress);
  const UpdateStatus.ready(String tag)
      : this(phase: UpdatePhase.ready, version: tag);
  const UpdateStatus.error(String msg)
      : this(phase: UpdatePhase.error, message: msg);
}

class AppState {
  final AppSettings settings;
  final bool settingsLoaded;
  final WindowMode windowMode;
  final String? hotkeyError;
  final String? lastNotification;
  final UpdateStatus updateStatus;

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
    this.updateStatus = const UpdateStatus(),
    this.quickNoteInput = '',
    this.tags = const [],
  }) : settings = settings ?? AppSettings();

  AppState copyWith({
    AppSettings? settings,
    bool? settingsLoaded,
    WindowMode? windowMode,
    String? hotkeyError,
    String? lastNotification,
    UpdateStatus? updateStatus,
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
        updateStatus: updateStatus ?? this.updateStatus,
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
  /// 更新配置（构建期注入；未注入 → 禁用）
  late UpdateConfig updateConfig;
  late UpdateService updateService;

  /// 运行时重载注入点（测试注入可控 Future；真实实现 = 热键/监控/自启）。
  /// 抽象出来是为了让 saveSettings 的后台重载可测试（issue #6）。
  @visibleForTesting
  late Future<void> Function() reloadHotkey;
  @visibleForTesting
  late Future<void> Function() reloadWatcher;
  @visibleForTesting
  late Future<void> Function(bool enable) reloadAutoLaunch;

  /// 测试注入点：按 providerType 构造 CodeProvider；null 时按类型 new
  /// 真实 provider（GitLab/GitHub）。
  @visibleForTesting
  CodeProvider Function(String providerType)? providerFactory;

  StreamSubscription<int>? _hotkeySub;
  bool _updateChecking = false;
  /// 后台重载串行链：连续两次保存时后一次的重载等前一次完成，
  /// 避免 stop/start 监控与热键注销/注册交错。
  Future<void> _reloadChain = Future.value();

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
    // 更新服务（构建期 dart-define 注入源与版本）
    updateConfig = UpdateConfig.fromEnvironment();
    updateService = UpdateService(config: updateConfig);
    // 运行时重载默认走真实实现
    reloadHotkey = _applyHotkey;
    reloadWatcher = _startWatching;
    reloadAutoLaunch = _applyAutoLaunch;
    // 注入 token 读取
    collectService.tokenProvider = (id) => settingsService.getToken(id);

    _init();
    return AppState();
  }

  /// 测试辅助：以真实启动流程初始化（等同 build() 内的 _init 调用）
  @visibleForTesting
  void initForTest() => _init();

  Future<void> _init() async {
    await settingsService.load();
    // 运行时环节独立容错（issue #12）：通知 / 热键 / 监控 / 自启任一环失败
    // （无显示环境、通知插件缺失等）都不能挡住 settingsLoaded 置位，否则
    // 设置页永远停留在初始默认值；load 完成后必须把磁盘读回的设置同步进
    // state.settings——UI 全部经 state.settings 读取设置，漏同步即"重启后
    // 保存的设置丢失"。
    try {
      await notificationService.init();
    } catch (e) {
      debugPrint('[daymark] notification init error: $e');
    }
    _rebuildServices();
    try {
      await reloadHotkey();
    } catch (e) {
      debugPrint('[daymark] hotkey init error: $e');
    }
    try {
      await reloadWatcher();
    } catch (e) {
      debugPrint('[daymark] watcher init error: $e');
    }
    try {
      await _syncAutoLaunch();
    } catch (e) {
      debugPrint('[daymark] auto launch sync error: $e');
    }
    state = state.copyWith(
      settings: settingsService.settings,
      settingsLoaded: true,
      tags: [],
    );
    // 启动时自动检查更新（构建期注入了更新源且用户开启自动检查）
    if (updateConfig.enabled && state.settings.update.autoCheck) {
      checkForUpdates();
    }
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
    // 被移除的监控目录：配置移除不产生文件系统 remove 事件，后台按目录
    // 前缀清掉这些目录的素材缓存记录（issue #14 第二轮：删除监控目录后
    // 刷新素材仍显示被删目录的文件变更）
    final removedDirs = settingsService.settings.watchDirs
        .where((d) => !next.watchDirs.contains(d))
        .toList();
    // 1. 持久化：必须同步等待——写失败要立即反馈给设置页
    settingsService.settings = next;
    await settingsService.save();
    _rebuildServices();
    state = state.copyWith(settings: next);
    // 2. 运行时重载放后台：热键注册 / 目录监控（大目录递归 watch 可极慢）/
    //    开机自启任一环节阻塞都会让设置页永远停在"保存中…"（issue #6），
    //    因此不再同步等待；各环节独立容错，失败只写日志。
    _reloadChain = _reloadChain.then((_) => _reloadRuntimeAfterSave(removedDirs));
  }

  /// 测试辅助：等待后台重载链执行完毕
  @visibleForTesting
  Future<void> reloadDoneForTest() => _reloadChain;

  /// 保存后的运行时重载（后台串行执行，各环节独立容错、互不拖累）
  Future<void> _reloadRuntimeAfterSave(List<String> removedDirs) async {
    final autoLaunch = settingsService.settings.hotkey.autoLaunch;
    try {
      await reloadHotkey();
    } catch (e) {
      debugPrint('[daymark] hotkey reload error: $e');
    }
    // 先清掉被移除监控目录的缓存残留，再按新目录重建监控（顺序不可倒：
    // 否则重建后的初始扫描可能把残留记录与新增记录混在一起）
    try {
      await collectService.pruneCacheForDirs(removedDirs);
    } catch (e) {
      debugPrint('[daymark] prune cache error: $e');
    }
    try {
      await reloadWatcher();
    } catch (e) {
      debugPrint('[daymark] watcher reload error: $e');
    }
    try {
      await reloadAutoLaunch(autoLaunch);
    } catch (e) {
      debugPrint('[daymark] auto launch reload error: $e');
    }
  }

  /// 拉取全部启用代码实例的提交作者（去重排序，issue #20 第二轮）：
  /// 设置页「从代码仓库拉取提交作者」对话框的数据源。
  ///
  /// [instances] 未传时取已持久化设置的启用实例；设置页传入草稿实例列表
  /// ——新增实例尚未点「保存设置」也能拉取（issue #20 第三轮：修复前读
  /// 已持久化 settings，草稿实例被忽略 → 空列表 → 「未拉取到任何提交作者」）。
  ///
  /// 实例级失败不再静默吞掉：无任何作者且存在失败时抛
  /// [CodeProviderException]，消息按实例列出原因（Token 缺失/401/网络等），
  /// 用户在对话框直接看到可排障的提示。
  Future<List<CommitAuthor>> fetchCommitAuthors({List<CodeInstance>? instances}) async {
    final list = instances ??
        settingsService.settings.codeInstances
            .where((i) => i.enabled && i.baseUrl.isNotEmpty)
            .toList();
    final failures = <String>[];
    final results = await Future.wait(list.map((instance) async {
      final label = instance.name.isEmpty ? instance.baseUrl : instance.name;
      try {
        final token = await settingsService.getToken(instance.id);
        if (token == null || token.isEmpty) {
          failures.add('$label：未配置 Token');
          return const <CommitAuthor>[];
        }
        final CodeProvider provider = providerFactory?.call(instance.providerType) ??
            (instance.providerType == 'github'
                ? GitHubProvider()
                : GitLabProvider());
        return await provider.fetchCommitAuthors(
          instance: instance,
          token: token,
        );
      } catch (e) {
        final reason = e is DioException ? friendlyDioMessage(e) : '$e';
        failures.add('$label：$reason');
        debugPrint('[daymark] fetch commit authors failed for ${instance.name}: $e');
        return const <CommitAuthor>[];
      }
    }));
    final seen = <String>{};
    final authors = results
        .expand((e) => e)
        .where((a) => seen.add(a.key.toLowerCase()))
        .toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (authors.isEmpty && failures.isNotEmpty) {
      throw CodeProviderException(
        '未拉取到任何提交作者：\n- ${failures.join('\n- ')}',
      );
    }
    return authors;
  }

  /// 快捷添加文件排除项（issue #18）：把 [path] 追加进 excludePatterns 并
  /// 持久化。排除规则是子串匹配（与 Rust 侧 is_excluded 一致），已命中现有
  /// 规则的路径不再重复添加。保存走 [saveSettings]，watcher 会在后台按新
  /// 规则重建；读侧 `collectForDate` 的排除过滤在下次刷新时立即隐藏该文件。
  /// 返回提示消息（UI SnackBar 展示）；持久化失败异常冒泡给调用方。
  Future<String> addExcludePattern(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '路径为空，无法添加排除项';
    final patterns = settingsService.settings.excludePatterns;
    if (patterns.any((p) => p.isNotEmpty && trimmed.contains(p))) {
      return '该文件已在排除规则内';
    }
    final next = AppSettings.fromJson(settingsService.settings.toJson());
    next.excludePatterns = [...patterns, trimmed];
    await saveSettings(next);
    return '已添加排除项：$trimmed';
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
    // 读服务层设置（issue #12：启动时 state.settings 尚未同步，读 state
    // 会拿到默认值，配置了自启也永远不补启用）
    final want = settingsService.settings.hotkey.autoLaunch;
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

  // ─────────────────────────── 自动更新（issue #5） ───────────────────────────

  /// 检查更新；发现新版自动后台下载，完成后通知并置为 ready（重启时自动安装）
  Future<void> checkForUpdates() async {
    if (_updateChecking) return;
    if (!updateConfig.enabled) {
      state = state.copyWith(
        updateStatus: const UpdateStatus.error('当前构建未包含更新源（本地开发构建）'),
      );
      return;
    }
    _updateChecking = true;
    state = state.copyWith(updateStatus: const UpdateStatus.checking());
    try {
      final info = await updateService.check();
      if (info == null) {
        state = state.copyWith(
          updateStatus: UpdateStatus.error(
            '已是最新版本（v${updateConfig.appVersion}）',
          ),
        );
        return;
      }
      state = state.copyWith(updateStatus: UpdateStatus.available(info.tag));
      await _downloadUpdate(info);
    } catch (e) {
      debugPrint('[daymark] update check error: $e');
      state = state.copyWith(
        updateStatus: UpdateStatus.error('检查更新失败：$e'),
      );
    } finally {
      _updateChecking = false;
    }
  }

  /// 后台下载更新包（下载完成才提示用户——issue 要求）
  Future<void> _downloadUpdate(UpdateInfo info) async {
    state = state.copyWith(
      updateStatus: UpdateStatus.downloading(info.tag, 0),
    );
    try {
      final manifest = await updateService.download(
        info,
        onProgress: (progress) {
          state = state.copyWith(
            updateStatus: UpdateStatus.downloading(info.tag, progress),
          );
        },
      );
      state = state.copyWith(
        updateStatus: UpdateStatus.ready(manifest.version),
      );
      await notificationService.show(
        title: '发现新版本 ${info.tag}',
        body: '已在后台下载完成，重启软件后自动完成更新。',
      );
    } catch (e) {
      debugPrint('[daymark] update download error: $e');
      state = state.copyWith(
        updateStatus: UpdateStatus.error('下载更新失败：$e'),
      );
    }
  }

  /// 重启并安装更新（Linux/macOS 安装后自动重启进入新版；Windows 启动安装器）
  Future<void> restartToUpdate() async {
    final manifest = await updateService.loadManifest();
    if (manifest == null) {
      state = state.copyWith(
        updateStatus: const UpdateStatus.error('未找到已下载的更新包，请重新检查更新'),
      );
      return;
    }
    final installer = UpdateInstaller();
    final ok = await installer.install(
      manifest,
      await updateService.updateDir(),
    );
    if (!ok) {
      // unsupported（如非 AppImage 环境）：提示手动更新
      final plan = installer.plan();
      state = state.copyWith(
        updateStatus: UpdateStatus.error(plan.reason ?? '当前环境不支持自动安装，请手动下载新版本'),
      );
    }
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
