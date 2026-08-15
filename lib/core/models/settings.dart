/// 应用配置模型（DESIGN.md §5.8）。
///
/// 序列化到 `.daymark/settings.json`；**token 一律不落盘**，
/// 由 SettingsService 经 flutter_secure_storage 单独存取。
library;

class AppSettings {
  // ── 日志 ──
  /// 日志根目录（App 在其下自建 日报/ 周报/ 月报/ inbox/ 转写/ .daymark/）
  String logRoot;
  /// 作者名（commit 过滤与日报署名）
  String authorName;
  /// 自然日时区，默认 +08:00
  String timezone;

  // ── 代码 ──
  List<CodeInstance> codeInstances;
  /// 并入代码提交的账户（issue #20）：agent/code01 等辅助账户的提交
  /// 也计入素材——刷新素材时这些账户的提交不再被作者过滤丢弃。
  List<String> extraCommitAuthors;

  // ── 目录监控 ──
  List<String> watchDirs;
  List<String> excludePatterns;

  /// 默认排除规则（子串匹配，与 Rust 侧 is_excluded 一致）。
  /// `.daymark` 为应用自身缓存/配置目录（issue #17），默认排除避免
  /// 混入「本地文件变更」素材。
  static const List<String> defaultExcludePatterns = [
    '.git', 'node_modules', '@eaDir', 'Thumbs.db', '.DS_Store', '.daymark',
  ];

  // ── 音频 ──
  String audioDir;
  TranscriptSettings transcript;

  // ── AI ──
  AiSettings ai;

  // ── 快捷键 ──
  HotkeySettings hotkey;

  // ── 通知 ──
  NotificationSettings notification;

  // ── 更新 ──
  UpdateSettings update;

  AppSettings({
    this.logRoot = '',
    this.authorName = '',
    this.timezone = '+08:00',
    this.codeInstances = const [],
    this.extraCommitAuthors = const [],
    this.watchDirs = const [],
    this.excludePatterns = defaultExcludePatterns,
    this.audioDir = '',
    TranscriptSettings? transcript,
    AiSettings? ai,
    HotkeySettings? hotkey,
    NotificationSettings? notification,
    UpdateSettings? update,
  })  : transcript = transcript ?? TranscriptSettings(),
        ai = ai ?? AiSettings(),
        hotkey = hotkey ?? HotkeySettings(),
        notification = notification ?? NotificationSettings(),
        update = update ?? UpdateSettings();

  factory AppSettings.defaults() => AppSettings();

  /// 是否已配置完整（能跑通日报流水线的最小集）
  bool get isConfigured => logRoot.isNotEmpty && ai.provider.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'logRoot': logRoot,
        'authorName': authorName,
        'timezone': timezone,
        'codeInstances': codeInstances.map((e) => e.toJson()).toList(),
        'extraCommitAuthors': extraCommitAuthors,
        'watchDirs': watchDirs,
        'excludePatterns': excludePatterns,
        'audioDir': audioDir,
        'transcript': transcript.toJson(),
        'ai': ai.toJson(),
        'hotkey': hotkey.toJson(),
        'notification': notification.toJson(),
        'update': update.toJson(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        logRoot: json['logRoot'] as String? ?? '',
        authorName: json['authorName'] as String? ?? '',
        timezone: json['timezone'] as String? ?? '+08:00',
        codeInstances: (json['codeInstances'] as List? ?? [])
            .map((e) => CodeInstance.fromJson(e as Map<String, dynamic>))
            .toList(),
        // 键缺失（老版本配置）回退空列表，与 watchDirs 等列表字段语义一致
        extraCommitAuthors:
            List<String>.from(json['extraCommitAuthors'] as List? ?? const []),
        watchDirs: List<String>.from(json['watchDirs'] as List? ?? const []),
        // 键缺失（老版本配置）回退默认排除规则；键存在但为空列表是用户
        // 主动清空，保留用户意图（issue #17）
        excludePatterns:
            List<String>.from(json['excludePatterns'] as List? ?? defaultExcludePatterns),
        audioDir: json['audioDir'] as String? ?? '',
        transcript: TranscriptSettings.fromJson(
            json['transcript'] as Map<String, dynamic>? ?? {}),
        ai: AiSettings.fromJson(json['ai'] as Map<String, dynamic>? ?? {}),
        hotkey: HotkeySettings.fromJson(json['hotkey'] as Map<String, dynamic>? ?? {}),
        notification: NotificationSettings.fromJson(
            json['notification'] as Map<String, dynamic>? ?? {}),
        update: UpdateSettings.fromJson(json['update'] as Map<String, dynamic>? ?? {}),
      );
}

/// 代码实例（GitLab / GitHub 多实例）
class CodeInstance {
  final String id;
  /// gitlab | github
  final String providerType;
  /// 实例名（如 "公司 GitLab"）
  String name;
  String baseUrl;
  String defaultBranch;
  /// 是否启用
  bool enabled;

  /// GitHub 按登录名过滤；GitLab 通过 API 拉项目
  String visibilityFilter;

  CodeInstance({
    required this.id,
    required this.providerType,
    this.name = '',
    this.baseUrl = '',
    this.defaultBranch = '',
    this.enabled = true,
    this.visibilityFilter = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'providerType': providerType,
        'name': name,
        'baseUrl': baseUrl,
        'defaultBranch': defaultBranch,
        'enabled': enabled,
        'visibilityFilter': visibilityFilter,
      };

  factory CodeInstance.fromJson(Map<String, dynamic> json) => CodeInstance(
        id: json['id'] as String,
        providerType: json['providerType'] as String,
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        defaultBranch: json['defaultBranch'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        visibilityFilter: json['visibilityFilter'] as String? ?? '',
      );
}

/// 转录接口（OpenAI 兼容）
class TranscriptSettings {
  String baseUrl;
  String apiKey;
  String model;
  /// 支持的后缀（默认音频格式）
  List<String> extensions;

  TranscriptSettings({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = 'whisper-1',
    this.extensions = const ['.mp3', '.m4a', '.wav', '.ogg', '.flac', '.mp4'],
  });

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'extensions': extensions,
      };

  factory TranscriptSettings.fromJson(Map<String, dynamic> json) => TranscriptSettings(
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'whisper-1',
        extensions:
            List<String>.from(json['extensions'] as List? ?? const []),
      );
}

/// AI 供应商配置
class AiSettings {
  /// 主供应商：claude | deepseek | ollama
  String provider;
  /// 备选供应商（失败降级，按顺序）
  List<String> fallback;
  /// 生成语气偏好（自由文本，如 "简洁、突出成果"）
  String tone;
  /// 会议素材禁用的供应商（合规，越秀会议内容不上传第三方）
  List<String> conferenceBlocked;

  // 各供应商参数
  String claudeBaseUrl;
  String claudeApiKey;
  String claudeModel;
  String deepseekBaseUrl;
  String deepseekApiKey;
  String deepseekModel;
  String ollamaBaseUrl;
  String ollamaModel;

  AiSettings({
    this.provider = '',
    this.fallback = const [],
    this.tone = '',
    this.conferenceBlocked = const ['claude'],
    this.claudeBaseUrl = 'https://api.anthropic.com',
    this.claudeApiKey = '',
    this.claudeModel = 'claude-sonnet-5',
    this.deepseekBaseUrl = 'https://api.deepseek.com',
    this.deepseekApiKey = '',
    this.deepseekModel = 'deepseek-chat',
    this.ollamaBaseUrl = 'http://localhost:11434',
    this.ollamaModel = 'qwen2.5',
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'fallback': fallback,
        'tone': tone,
        'conferenceBlocked': conferenceBlocked,
        'claudeBaseUrl': claudeBaseUrl,
        'claudeApiKey': claudeApiKey,
        'claudeModel': claudeModel,
        'deepseekBaseUrl': deepseekBaseUrl,
        'deepseekApiKey': deepseekApiKey,
        'deepseekModel': deepseekModel,
        'ollamaBaseUrl': ollamaBaseUrl,
        'ollamaModel': ollamaModel,
      };

  factory AiSettings.fromJson(Map<String, dynamic> json) => AiSettings(
        provider: json['provider'] as String? ?? '',
        fallback: List<String>.from(json['fallback'] as List? ?? const []),
        tone: json['tone'] as String? ?? '',
        conferenceBlocked: List<String>.from(
            json['conferenceBlocked'] as List? ?? const ['claude']),
        claudeBaseUrl: json['claudeBaseUrl'] as String? ?? 'https://api.anthropic.com',
        claudeApiKey: json['claudeApiKey'] as String? ?? '',
        claudeModel: json['claudeModel'] as String? ?? 'claude-sonnet-5',
        deepseekBaseUrl: json['deepseekBaseUrl'] as String? ?? 'https://api.deepseek.com',
        deepseekApiKey: json['deepseekApiKey'] as String? ?? '',
        deepseekModel: json['deepseekModel'] as String? ?? 'deepseek-chat',
        ollamaBaseUrl: json['ollamaBaseUrl'] as String? ?? 'http://localhost:11434',
        ollamaModel: json['ollamaModel'] as String? ?? 'qwen2.5',
      );

  /// 该供应商是否允许用于会议素材
  bool allowsMeeting(String providerId) => !conferenceBlocked.contains(providerId);
}

/// 全局热键
class HotkeySettings {
  /// Ctrl / Shift / Alt / Meta（Cmd/Super）
  List<String> modifiers;
  /// 键码名（Rust global-hotkey Code 枚举），如 KeyL
  String key;
  bool autoLaunch;

  HotkeySettings({
    this.modifiers = const ['Ctrl', 'Shift'],
    this.key = 'KeyL',
    this.autoLaunch = false,
  });

  Map<String, dynamic> toJson() => {
        'modifiers': modifiers,
        'key': key,
        'autoLaunch': autoLaunch,
      };

  factory HotkeySettings.fromJson(Map<String, dynamic> json) => HotkeySettings(
        modifiers:
            List<String>.from(json['modifiers'] as List? ?? const ['Ctrl', 'Shift']),
        key: json['key'] as String? ?? 'KeyL',
        autoLaunch: json['autoLaunch'] as bool? ?? false,
      );
}

/// 通知
class NotificationSettings {
  /// 每日生成提醒时间（HH:mm，空则不提醒）
  String reminderTime;
  bool completionNotification;

  NotificationSettings({
    this.reminderTime = '18:30',
    this.completionNotification = true,
  });

  Map<String, dynamic> toJson() => {
        'reminderTime': reminderTime,
        'completionNotification': completionNotification,
      };

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        reminderTime: json['reminderTime'] as String? ?? '18:30',
        completionNotification: json['completionNotification'] as bool? ?? true,
      );
}

/// 自动更新设置（issue #5）。
/// 更新源与版本是构建期注入的（只读），运行时仅此一个开关。
class UpdateSettings {
  /// 启动时自动检查更新（检测到新版自动后台下载）
  bool autoCheck;

  UpdateSettings({this.autoCheck = true});

  Map<String, dynamic> toJson() => {'autoCheck': autoCheck};

  factory UpdateSettings.fromJson(Map<String, dynamic> json) =>
      UpdateSettings(autoCheck: json['autoCheck'] as bool? ?? true);
}
