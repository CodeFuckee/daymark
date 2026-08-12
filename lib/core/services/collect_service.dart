/// 素材收集服务（DESIGN.md §5.2/§5.3/§5.4）：
/// - 按自然日聚合 inbox + GitLab/GitHub 提交 + 文件变更缓存 + 会议转录
/// - 文件监控：Rust notify 事件流 → 5s 节流聚合 → 写素材缓存
/// - 转录：音频目录扫描 + 缓存复用（`_转写.txt` mtime 不早于音频）
library;

import 'dart:async';
import 'dart:io';

import '../../src/rust/api/extract.dart' as frb_extract;
import '../../src/rust/api/watcher.dart' as frb_watcher;
import '../models/material.dart';
import '../models/settings.dart';
import '../providers/code_provider.dart';
import '../providers/github_provider.dart';
import '../providers/gitlab_provider.dart';
import '../transcription/transcriber.dart';
import '../util/date_util.dart';
import '../util/markdown_util.dart';

class CollectService {
  final AppSettings settings;
  final Transcriber _transcriber;

  CollectService(this.settings, {Transcriber? transcriber})
      : _transcriber = transcriber ?? Transcriber();

  // ─────────────────────────── 当日素材聚合 ───────────────────────────

  /// 收集某天的全部素材（commit 拉取 + 缓存 + inbox）。
  /// [includeTranscripts] 控制是否转录（慢操作，UI 侧后台执行）。
  Future<DailyMaterial> collectForDate(
    DateTime date, {
    bool includeTranscripts = false,
    void Function(String stage)? onProgress,
  }) async {
    final d = dayStart(date);

    onProgress?.call('读取随手记录');
    final notes = await readInbox(settings.logRoot, d);

    onProgress?.call('拉取代码提交');
    final commits = await _fetchCommits(d);

    onProgress?.call('读取文件变更缓存');
    final cached = await loadMaterialCache(settings.logRoot, d);
    final fileChanges = cached?.fileChanges ?? const <FileChange>[];

    // 对新增/修改的文档做内容提取（失败降级为仅记录文件名）
    onProgress?.call('提取文档要点');
    final extracted = await _extractDocuments(fileChanges);

    var transcripts = const <Transcript>[];
    if (includeTranscripts) {
      onProgress?.call('扫描并转录音频');
      transcripts = await transcribeDayAudio(d);
    }

    return DailyMaterial(
      date: d,
      notes: notes,
      commits: commits,
      fileChanges: fileChanges,
      extractedDocs: extracted,
      transcripts: transcripts,
    );
  }

  /// 多实例并行拉 commit，按 sha 去重
  Future<List<Commit>> _fetchCommits(DateTime date) async {
    final results = await Future.wait(settings.codeInstances
        .where((i) => i.enabled && i.baseUrl.isNotEmpty)
        .map((instance) async {
      try {
        final token = await _tokenOf(instance);
        if (token == null || token.isEmpty) return const <Commit>[];
        final CodeProvider provider = instance.providerType == 'github'
            ? GitHubProvider()
            : GitLabProvider();
        return await provider.fetchCommits(
          date: date,
          instance: instance,
          token: token,
          author: settings.authorName,
        );
      } catch (e) {
        // 单个实例失败不阻断整体（如网络、权限）
        stderr.writeln('[daymark] fetch commits failed for ${instance.name}: $e');
        return const <Commit>[];
      }
    }));

    final seen = <String>{};
    return results
        .expand((e) => e)
        .where((c) => seen.add(c.sha))
        .toList();
  }

  Future<String?> _tokenOf(CodeInstance instance) async {
    // 由 SettingsService 注入的 token provider（避免循环依赖）
    return _tokenProvider?.call(instance.id);
  }

  /// 外部注入 token 读取（SettingsService.setTokenProvider）
  Future<String?> Function(String instanceId)? _tokenProvider;
  set tokenProvider(Future<String?> Function(String instanceId)? v) =>
      _tokenProvider = v;

  /// 对当天新增/修改的文档做内容提取
  Future<List<Extracted>> _extractDocuments(List<FileChange> changes) async {
    final docs = changes
        .where((c) =>
            c.kind != 'remove' &&
            const ['.pptx', '.xlsx', '.docx', '.pdf']
                .any((e) => c.path.toLowerCase().endsWith(e)))
        .toList();
    final results = await Future.wait(docs.map((c) async {
      try {
        final ex = await frb_extract.extractDocument(path: c.path);
        return Extracted(
          path: ex.path,
          kind: ex.kind,
          title: ex.title,
          textExcerpt: ex.textExcerpt,
          textHash: ex.textHash,
        );
      } catch (_) {
        // 提取失败降级：仅记录文件名
        return Extracted(
          path: c.path,
          kind: _kindOf(c.path),
          title: '(提取失败)',
          textExcerpt: '',
          textHash: '',
        );
      }
    }));
    return results.where((e) => e.textExcerpt.isNotEmpty || e.title.isNotEmpty).toList();
  }

  static String _kindOf(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'pptx' || 'xlsx' || 'docx' || 'pdf' => ext,
      _ => 'doc',
    };
  }

  // ─────────────────────────── 文件监控 ───────────────────────────

  static const _watchId = 1; // 单监控实例，id 固定
  StreamSubscription<frb_watcher.FileEvent>? _sub;
  Timer? _debounce;
  final Map<String, String> _pending = {}; // path → kind（聚合缓冲）

  bool get isWatching => _sub != null;

  /// 开始递归监控（设置中保存后调用）
  Future<void> startWatching() async {
    await stopWatching();
    final dirs = settings.watchDirs.where((d) => d.trim().isNotEmpty).toList();
    if (dirs.isEmpty) return;

    final stream = frb_watcher.watchDirectories(
      id: BigInt.from(_watchId),
      paths: dirs,
      excludes: settings.excludePatterns,
    );
    _sub = stream.listen((event) {
      // 排除目录自身（避免监控 .daymark 缓存写入引发的循环事件）
      if (event.path.contains('/.daymark/')) return;
      _pending[event.path] = event.kind;
      _debounce ??= Timer(const Duration(seconds: 5), _flushPending);
    }, onError: (Object e) {
      stderr.writeln('[daymark] watcher error: $e');
    });
  }

  Future<void> stopWatching() async {
    _debounce?.cancel();
    _debounce = null;
    await _sub?.cancel();
    _sub = null;
    await frb_watcher.stopWatching(id: BigInt.from(_watchId));
  }

  /// 5s 节流批处理：stat 后按 mtime 归档到自然日缓存
  Future<void> _flushPending() async {
    _debounce = null;
    if (_pending.isEmpty) return;
    final batch = Map.of(_pending);
    _pending.clear();

    for (final entry in batch.entries) {
      final path = entry.key;
      final kind = entry.value;
      final stat = File(path).statSync();
      final change = FileChange(
        path: path,
        mtime: stat.type == FileSystemEntityType.notFound
            ? DateTime.now()
            : stat.modified,
        size: stat.type == FileSystemEntityType.notFound ? 0 : stat.size,
        kind: stat.type == FileSystemEntityType.notFound ? 'remove' : kind,
      );
      await _mergeIntoCache(change);
    }
  }

  /// 合并进当日素材缓存（path 去重，新覆盖旧）
  Future<void> _mergeIntoCache(FileChange change) async {
    final date = dayStart(change.mtime);
    final cached = await loadMaterialCache(settings.logRoot, date);
    final list = [...?cached?.fileChanges];
    list.removeWhere((c) => c.path == change.path);
    list.add(change);
    final merged = (cached ?? DailyMaterial(date: date)).copyWith(fileChanges: list);
    await saveMaterialCache(settings.logRoot, merged);
  }

  // ─────────────────────────── 音频转录 ───────────────────────────

  /// 扫描音频目录当日音频并转录（缓存复用）。
  /// 返回产物列表；单个文件失败不阻断。
  Future<List<Transcript>> transcribeDayAudio(DateTime date) async {
    if (settings.audioDir.isEmpty) return const [];
    final dir = Directory(settings.audioDir);
    if (!await dir.exists()) return const [];

    final extOk = settings.transcript.extensions
        .map((e) => e.toLowerCase())
        .toList();
    final start = dayStart(date);
    final end = start.add(const Duration(days: 1));

    final entities = await dir.list().toList();
    final audios = entities.whereType<File>().where((f) {
      final stat = f.statSync();
      return !stat.modified.isBefore(start) &&
          stat.modified.isBefore(end) &&
          extOk.any((e) => f.path.toLowerCase().endsWith(e));
    }).toList();
    if (audios.isEmpty) return const [];

    final results = await Future.wait(audios.map((audio) async {
      try {
        final text = await _transcribeWithCache(audio);
        return Transcript(
          audioPath: audio.path,
          textPath: _textPath(audio.path),
          text: text,
          date: start,
        );
      } catch (e) {
        stderr.writeln('[daymark] transcribe failed for ${audio.path}: $e');
        return null;
      }
    }));
    return results.whereType<Transcript>().toList();
  }

  /// 缓存复用：`<音频名>_转写.txt` 存在且 mtime 不早于音频 → 直接复用
  Future<String> _transcribeWithCache(File audio) async {
    final textFile = File(_textPath(audio.path));
    if (await textFile.exists()) {
      final textMtime = (await textFile.stat()).modified;
      final audioMtime = (await audio.stat()).modified;
      if (!textMtime.isBefore(audioMtime)) {
        return textFile.readAsString();
      }
    }
    final text = await _transcriber.transcribe(
      audioPath: audio.path,
      config: settings.transcript,
    );
    await textFile.parent.create(recursive: true);
    await textFile.writeAsString(text);
    return text;
  }

  static String _textPath(String audioPath) {
    final dot = audioPath.lastIndexOf('.');
    final base = dot > 0 ? audioPath.substring(0, dot) : audioPath;
    return '${base}_转写.txt';
  }
}
