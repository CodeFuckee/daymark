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
    '.git',
    'node_modules',
    '@eaDir',
    'Thumbs.db',
    '.DS_Store',
    '.daymark',
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
  }) : transcript = transcript ?? TranscriptSettings(),
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
    extraCommitAuthors: List<String>.from(
      json['extraCommitAuthors'] as List? ?? const [],
    ),
    watchDirs: List<String>.from(json['watchDirs'] as List? ?? const []),
    // 键缺失（老版本配置）回退默认排除规则；键存在但为空列表是用户
    // 主动清空，保留用户意图（issue #17）
    excludePatterns: List<String>.from(
      json['excludePatterns'] as List? ?? defaultExcludePatterns,
    ),
    audioDir: json['audioDir'] as String? ?? '',
    transcript: TranscriptSettings.fromJson(
      json['transcript'] as Map<String, dynamic>? ?? {},
    ),
    ai: AiSettings.fromJson(json['ai'] as Map<String, dynamic>? ?? {}),
    hotkey: HotkeySettings.fromJson(
      json['hotkey'] as Map<String, dynamic>? ?? {},
    ),
    notification: NotificationSettings.fromJson(
      json['notification'] as Map<String, dynamic>? ?? {},
    ),
    update: UpdateSettings.fromJson(
      json['update'] as Map<String, dynamic>? ?? {},
    ),
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

  factory TranscriptSettings.fromJson(Map<String, dynamic> json) =>
      TranscriptSettings(
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'whisper-1',
        extensions: List<String>.from(json['extensions'] as List? ?? const []),
      );
}

/// AI 供应商类型（issue #25：供应商不再固定三家，「添加供应商」先在此
/// 选择类型，可添加任意 OpenAI 兼容服务，如 Groq / 火山引擎 / 通义等）。
class AiProviderType {
  static const String claude = 'claude';
  static const String deepseek = 'deepseek';
  static const String ollama = 'ollama';
  static const String openai = 'openai';

  /// 全部可选类型（「添加供应商」选择页按此顺序展示）
  static const List<String> all = [claude, deepseek, ollama, openai];

  /// 类型显示名
  static String displayName(String type) => switch (type) {
    claude => 'Claude',
    deepseek => 'DeepSeek',
    ollama => 'Ollama（本地）',
    openai => 'OpenAI 兼容',
    _ => type,
  };

  /// 类型一句话说明（选择页副标题）
  static String description(String type) => switch (type) {
    claude => 'Anthropic Messages API',
    deepseek => 'OpenAI 兼容协议',
    ollama => '本地模型，无需 API Key',
    openai => '任意 OpenAI 兼容服务（Groq / 火山引擎 / 通义等）',
    _ => type,
  };

  /// 类型默认 base_url（openai 给官方端点作起点，用户可替换为
  /// Groq / 火山引擎 / 通义等任意兼容服务）
  static String defaultBaseUrl(String type) => switch (type) {
    claude => 'https://api.anthropic.com',
    deepseek => 'https://api.deepseek.com',
    ollama => 'http://localhost:11434',
    openai => 'https://api.openai.com/v1',
    _ => '',
  };
  static String defaultModel(String type) => switch (type) {
    claude => 'claude-sonnet-5',
    deepseek => 'deepseek-chat',
    ollama => 'qwen2.5',
    _ => '',
  };

  /// 该类型是否需要 API Key（Ollama 本地调用无需）
  static bool needsApiKey(String type) => type != ollama;
}

/// AI 供应商实例（issue #25：参考 cc-switch 的供应商列表设计——每个供应商
/// 是一个可增删改的独立实例，不再固定三家）。
class AiProvider {
  /// 唯一 id：旧版迁移时为类型名（claude/deepseek/ollama），新增实例由 UI
  /// 生成「类型-时间戳」保证唯一。
  final String id;

  /// 供应商类型（见 [AiProviderType]）
  final String type;

  /// 显示名称（可自定义，如 "公司 DeepSeek"）
  String name;
  String baseUrl;
  String apiKey;
  String model;

  AiProvider({
    required this.id,
    required this.type,
    this.name = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  /// 展示名：自定义名为空时回退类型名
  String get displayName =>
      name.isEmpty ? AiProviderType.displayName(type) : name;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  factory AiProvider.fromJson(Map<String, dynamic> json) => AiProvider(
    id: json['id'] as String,
    type: json['type'] as String? ?? AiProviderType.openai,
    name: json['name'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    apiKey: json['apiKey'] as String? ?? '',
    model: json['model'] as String? ?? '',
  );
}

/// AI 供应商配置
class AiSettings {
  /// 已配置的供应商实例列表（可增删改；默认预置三家，开箱即用）
  List<AiProvider> providers;

  /// 主供应商 id（空表示未配置）
  String provider;

  /// 备选供应商 id（失败降级，按顺序）
  List<String> fallback;

  /// 生成语气偏好（自由文本，如 "简洁、突出成果"）
  String tone;

  /// 会议素材禁用的供应商 id（合规，越秀会议内容不上传第三方）
  List<String> conferenceBlocked;

  AiSettings({
    this.provider = '',
    this.fallback = const [],
    this.tone = '',
    this.conferenceBlocked = const ['claude'],
    List<AiProvider>? providers,
    // 旧版扁平参数（迁移/兼容）：未传 providers 时用于预置三家默认供应商
    String claudeBaseUrl = 'https://api.anthropic.com',
    String claudeApiKey = '',
    String claudeModel = 'claude-sonnet-5',
    String deepseekBaseUrl = 'https://api.deepseek.com',
    String deepseekApiKey = '',
    String deepseekModel = 'deepseek-chat',
    String ollamaBaseUrl = 'http://localhost:11434',
    String ollamaModel = 'qwen2.5',
  }) : providers =
           providers ??
           [
             AiProvider(
               id: AiProviderType.claude,
               type: AiProviderType.claude,
               name: AiProviderType.displayName(AiProviderType.claude),
               baseUrl: claudeBaseUrl,
               apiKey: claudeApiKey,
               model: claudeModel,
             ),
             AiProvider(
               id: AiProviderType.deepseek,
               type: AiProviderType.deepseek,
               name: AiProviderType.displayName(AiProviderType.deepseek),
               baseUrl: deepseekBaseUrl,
               apiKey: deepseekApiKey,
               model: deepseekModel,
             ),
             AiProvider(
               id: AiProviderType.ollama,
               type: AiProviderType.ollama,
               name: AiProviderType.displayName(AiProviderType.ollama),
               baseUrl: ollamaBaseUrl,
               model: ollamaModel,
             ),
           ];

  /// 按 id 查找供应商实例（不存在返回 null）
  AiProvider? providerById(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 删除供应商并同步清理主/备/会议禁用列表中的引用（issue #25）
  void removeProvider(String id) {
    providers = providers.where((p) => p.id != id).toList();
    if (provider == id) provider = '';
    fallback = fallback.where((p) => p != id).toList();
    conferenceBlocked = conferenceBlocked.where((p) => p != id).toList();
  }

  /// 该供应商是否允许用于会议素材
  bool allowsMeeting(String providerId) =>
      !conferenceBlocked.contains(providerId);

  /// 按类型取第一个实例（旧版兼容读取用，缺失返回 null）
  AiProvider? _byType(String type) {
    for (final p in providers) {
      if (p.type == type) return p;
    }
    return null;
  }

  // ── 旧版扁平字段兼容读取（issue #25：迁移后仍可经 getter 读取） ──

  String get claudeBaseUrl =>
      _byType(AiProviderType.claude)?.baseUrl ?? 'https://api.anthropic.com';
  String get claudeApiKey => _byType(AiProviderType.claude)?.apiKey ?? '';
  String get claudeModel =>
      _byType(AiProviderType.claude)?.model ?? 'claude-sonnet-5';
  String get deepseekBaseUrl =>
      _byType(AiProviderType.deepseek)?.baseUrl ?? 'https://api.deepseek.com';
  String get deepseekApiKey => _byType(AiProviderType.deepseek)?.apiKey ?? '';
  String get deepseekModel =>
      _byType(AiProviderType.deepseek)?.model ?? 'deepseek-chat';
  String get ollamaBaseUrl =>
      _byType(AiProviderType.ollama)?.baseUrl ?? 'http://localhost:11434';
  String get ollamaModel => _byType(AiProviderType.ollama)?.model ?? 'qwen2.5';

  Map<String, dynamic> toJson() => {
    'providers': providers.map((e) => e.toJson()).toList(),
    'provider': provider,
    'fallback': fallback,
    'tone': tone,
    'conferenceBlocked': conferenceBlocked,
    // 旧版兼容字段：写同名 type 第一个实例的参数，缺失用默认值
    'claudeBaseUrl': claudeBaseUrl,
    'claudeApiKey': claudeApiKey,
    'claudeModel': claudeModel,
    'deepseekBaseUrl': deepseekBaseUrl,
    'deepseekApiKey': deepseekApiKey,
    'deepseekModel': deepseekModel,
    'ollamaBaseUrl': ollamaBaseUrl,
    'ollamaModel': ollamaModel,
  };

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    // 新版：providers 键存在（含空列表——用户清空供应商后保留空）→ 直接解析
    if (json.containsKey('providers')) {
      return AiSettings(
        provider: json['provider'] as String? ?? '',
        fallback: List<String>.from(json['fallback'] as List? ?? const []),
        tone: json['tone'] as String? ?? '',
        conferenceBlocked: List<String>.from(
          json['conferenceBlocked'] as List? ?? const ['claude'],
        ),
        providers: (json['providers'] as List? ?? const [])
            .map((e) => AiProvider.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    // 旧版扁平字段迁移：构建三家默认供应商（id=类型名，主/备引用不变）
    return AiSettings(
      provider: json['provider'] as String? ?? '',
      fallback: List<String>.from(json['fallback'] as List? ?? const []),
      tone: json['tone'] as String? ?? '',
      conferenceBlocked: List<String>.from(
        json['conferenceBlocked'] as List? ?? const ['claude'],
      ),
      claudeBaseUrl:
          json['claudeBaseUrl'] as String? ?? 'https://api.anthropic.com',
      claudeApiKey: json['claudeApiKey'] as String? ?? '',
      claudeModel: json['claudeModel'] as String? ?? 'claude-sonnet-5',
      deepseekBaseUrl:
          json['deepseekBaseUrl'] as String? ?? 'https://api.deepseek.com',
      deepseekApiKey: json['deepseekApiKey'] as String? ?? '',
      deepseekModel: json['deepseekModel'] as String? ?? 'deepseek-chat',
      ollamaBaseUrl:
          json['ollamaBaseUrl'] as String? ?? 'http://localhost:11434',
      ollamaModel: json['ollamaModel'] as String? ?? 'qwen2.5',
    );
  }
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
    modifiers: List<String>.from(
      json['modifiers'] as List? ?? const ['Ctrl', 'Shift'],
    ),
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
