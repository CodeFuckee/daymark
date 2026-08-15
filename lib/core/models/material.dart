/// 素材模型：日报流水线的全部输入（DESIGN.md §3.1 领域层）。
///
/// 全部支持 JSON 序列化（素材缓存 `.daymark/素材缓存/<date>.json`）。
library;

/// 代码提交（GitLab / GitHub）
class Commit {
  final String sha;
  final String message;
  /// 项目全名（GitLab: `group/project`；GitHub: `owner/repo`）
  final String project;
  final String author;
  final DateTime date;
  /// gitlab | github
  final String provider;

  const Commit({
    required this.sha,
    required this.message,
    required this.project,
    required this.author,
    required this.date,
    required this.provider,
  });

  Map<String, dynamic> toJson() => {
        'sha': sha,
        'message': message,
        'project': project,
        'author': author,
        'date': date.toIso8601String(),
        'provider': provider,
      };

  factory Commit.fromJson(Map<String, dynamic> json) => Commit(
        sha: json['sha'] as String,
        message: json['message'] as String,
        project: json['project'] as String,
        author: json['author'] as String,
        date: DateTime.parse(json['date'] as String),
        provider: json['provider'] as String,
      );
}

/// 提交作者（issue #20 第二轮）：从代码仓库拉取的真实提交人，供设置页
/// 勾选「并入代码提交的账户」。手动输入账户名可能与 Git 提交作者名
/// 不一致（如辅助账户的提交作者名实为主账户名），勾选真实作者必然命中
/// 采集过滤。
class CommitAuthor {
  final String name;
  final String email;

  const CommitAuthor({required this.name, required this.email});

  /// 勾选保存值：作者名优先（与提交 author_name 完全一致），
  /// 名为空时回退邮箱
  String get key => name.trim().isEmpty ? email.trim() : name.trim();

  /// 对话框展示文本：`name <email>`（无邮箱或邮箱与名相同时仅显示名）
  String get display {
    final k = key;
    final e = email.trim();
    if (e.isEmpty || e == k) return k;
    return '$k <$e>';
  }
}

/// 文件变更（notify 事件经节流聚合后的记录）
class FileChange {
  final String path;
  final DateTime mtime;
  final int size;
  /// create | modify | remove
  final String kind;
  /// 内容 hash（可选，用于去重）
  final String? contentHash;

  const FileChange({
    required this.path,
    required this.mtime,
    required this.size,
    required this.kind,
    this.contentHash,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'mtime': mtime.toIso8601String(),
        'size': size,
        'kind': kind,
        'contentHash': contentHash,
      };

  factory FileChange.fromJson(Map<String, dynamic> json) => FileChange(
        path: json['path'] as String,
        mtime: DateTime.parse(json['mtime'] as String),
        size: json['size'] as int,
        kind: json['kind'] as String,
        contentHash: json['contentHash'] as String?,
      );
}

/// 文档提取结果（Rust core `extract_document` 产物）
class Extracted {
  final String path;
  /// pptx | xlsx | docx | pdf
  final String kind;
  final String title;
  final String textExcerpt;
  final String textHash;

  const Extracted({
    required this.path,
    required this.kind,
    required this.title,
    required this.textExcerpt,
    required this.textHash,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'kind': kind,
        'title': title,
        'textExcerpt': textExcerpt,
        'textHash': textHash,
      };

  factory Extracted.fromJson(Map<String, dynamic> json) => Extracted(
        path: json['path'] as String,
        kind: json['kind'] as String,
        title: json['title'] as String,
        textExcerpt: json['textExcerpt'] as String,
        textHash: json['textHash'] as String,
      );
}

/// 会议转录（音频 + 转写产物）
class Transcript {
  final String audioPath;
  /// `_转写.txt` 产物路径
  final String textPath;
  final String text;
  final DateTime date;

  const Transcript({
    required this.audioPath,
    required this.textPath,
    required this.text,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
        'audioPath': audioPath,
        'textPath': textPath,
        'text': text,
        'date': date.toIso8601String(),
      };

  factory Transcript.fromJson(Map<String, dynamic> json) => Transcript(
        audioPath: json['audioPath'] as String,
        textPath: json['textPath'] as String,
        text: json['text'] as String,
        date: DateTime.parse(json['date'] as String),
      );
}

/// 随手记录（inbox 条目）
class QuickNote {
  final DateTime time;
  final String content;
  final List<String> tags;

  const QuickNote({
    required this.time,
    required this.content,
    required this.tags,
  });

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'content': content,
        'tags': tags,
      };

  factory QuickNote.fromJson(Map<String, dynamic> json) => QuickNote(
        time: DateTime.parse(json['time'] as String),
        content: json['content'] as String,
        tags: (json['tags'] as List).cast<String>(),
      );
}

/// 一天的素材集合（日报输入）
class DailyMaterial {
  final DateTime date;
  final List<QuickNote> notes;
  final List<Commit> commits;
  final List<FileChange> fileChanges;
  final List<Extracted> extractedDocs;
  final List<Transcript> transcripts;

  const DailyMaterial({
    required this.date,
    this.notes = const [],
    this.commits = const [],
    this.fileChanges = const [],
    this.extractedDocs = const [],
    this.transcripts = const [],
  });

  bool get isEmpty =>
      notes.isEmpty &&
      commits.isEmpty &&
      fileChanges.isEmpty &&
      extractedDocs.isEmpty &&
      transcripts.isEmpty;

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'notes': notes.map((e) => e.toJson()).toList(),
        'commits': commits.map((e) => e.toJson()).toList(),
        'fileChanges': fileChanges.map((e) => e.toJson()).toList(),
        'extractedDocs': extractedDocs.map((e) => e.toJson()).toList(),
        'transcripts': transcripts.map((e) => e.toJson()).toList(),
      };

  factory DailyMaterial.fromJson(Map<String, dynamic> json) => DailyMaterial(
        date: DateTime.parse(json['date'] as String),
        notes: (json['notes'] as List)
            .map((e) => QuickNote.fromJson(e as Map<String, dynamic>))
            .toList(),
        commits: (json['commits'] as List)
            .map((e) => Commit.fromJson(e as Map<String, dynamic>))
            .toList(),
        fileChanges: (json['fileChanges'] as List)
            .map((e) => FileChange.fromJson(e as Map<String, dynamic>))
            .toList(),
        extractedDocs: (json['extractedDocs'] as List)
            .map((e) => Extracted.fromJson(e as Map<String, dynamic>))
            .toList(),
        transcripts: (json['transcripts'] as List)
            .map((e) => Transcript.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// 浅拷贝并追加素材（流水线各阶段增量写入）
  DailyMaterial copyWith({
    List<QuickNote>? notes,
    List<Commit>? commits,
    List<FileChange>? fileChanges,
    List<Extracted>? extractedDocs,
    List<Transcript>? transcripts,
  }) =>
      DailyMaterial(
        date: date,
        notes: notes ?? this.notes,
        commits: commits ?? this.commits,
        fileChanges: fileChanges ?? this.fileChanges,
        extractedDocs: extractedDocs ?? this.extractedDocs,
        transcripts: transcripts ?? this.transcripts,
      );
}
