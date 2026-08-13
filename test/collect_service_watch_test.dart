/// CollectService 文件监控行为测试（issue #13：配置监控目录后无法获取
/// 今日修改/新增文件——mac 端报告；根因跨平台，三平台均受影响）。
///
/// 复现契约：
/// 1. 配置监控目录后，目录中「今日已修改/新增」的文件必须进入素材缓存——
///    事件流（FSEvents/inotify/ReadDirectoryChangesW）只报告监控建立之后的
///    变更，没有初始扫描则配置前今日已修改的文件永远缺失；
/// 2. remove 事件应把该文件从当日缓存中删除，而不是留下 kind='remove'
///    条目（macOS 上编辑器锁文件/临时文件高频 create→remove，噪音明显）。
library;

import 'dart:async';
import 'dart:io';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
import 'package:daymark/src/rust/api/extract.dart' as frb_extract;
import 'package:daymark/src/rust/api/watcher.dart';
import 'package:daymark/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试用 FRB api：watchDirectories 返回可控事件流，不触发真实 FFI
class _FakeRustApi extends RustLibApi {
  final StreamController<FileEvent> events = StreamController<FileEvent>.broadcast();
  final stopped = <BigInt>[];

  @override
  Stream<FileEvent> crateApiWatcherWatchDirectories({
    required BigInt id,
    required List<String> paths,
    required List<String> excludes,
  }) =>
      events.stream;

  @override
  Future<void> crateApiWatcherStopWatching({required BigInt id}) async {
    stopped.add(id);
  }

  @override
  Future<frb_extract.Extracted> crateApiExtractExtractDocument({required String path}) =>
      throw UnimplementedError();

  @override
  String crateApiSimpleGreet({required String name}) => '';

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  Stream<int> crateApiHotkeyRegisterHotkey({
    required BigInt id,
    required List<String> modifiers,
    required String key,
  }) =>
      const Stream<int>.empty();

  @override
  Future<void> crateApiHotkeyUnregisterHotkey({required BigInt id}) async {}
}

void main() {
  late Directory tmp;
  late String logRoot;
  late String watched;
  late _FakeRustApi rustApi;

  setUpAll(() {
    // RustLib 为全局单例，mock 只能初始化一次（FRB 限制）
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('daymark_watch_');
    logRoot = '${tmp.path}/logs';
    watched = '${tmp.path}/watched';
    Directory(watched).createSync(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  CollectService newService() => CollectService(
        AppSettings(logRoot: logRoot, watchDirs: [watched]),
        debounceDuration: const Duration(milliseconds: 10),
      );

  /// 轮询等待缓存满足条件（扫描/节流在后台异步进行）
  Future<T?> pollCache<T>(T? Function(DailyMaterial?) check) async {
    for (var i = 0; i < 100; i++) {
      final cached = await loadMaterialCache(logRoot, dayStart(DateTime.now()));
      final result = check(cached);
      if (result != null) return result;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return check(await loadMaterialCache(logRoot, dayStart(DateTime.now())));
  }

  test('配置监控目录后，今日已修改/新增的文件进入素材缓存（issue #13 复现：初始扫描缺失）',
      () async {
    // 预置：今日修改的文件 + 三天前的旧文件（模拟"配置目录前今天已干完活"）
    File('$watched/今天修改.txt').writeAsStringSync('今日内容');
    final oldFile = File('$watched/旧文件.txt')..writeAsStringSync('旧内容');
    oldFile.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));

    final service = newService();
    await service.startWatching();

    final cached = await pollCache<DailyMaterial>(
      (c) => (c != null && c.fileChanges.isNotEmpty) ? c : null,
    );
    expect(cached, isNotNull,
        reason: '配置监控目录后应能看到今日已修改的文件（issue #13）');
    final names =
        cached!.fileChanges.map((c) => c.path.split('/').last).toList();
    expect(names, contains('今天修改.txt'));
    expect(names, isNot(contains('旧文件.txt')),
        reason: '今日之外的文件不应进入当日缓存');
    await service.stopWatching();
  });

  test('remove 事件把文件从当日缓存移除，而不是留下 kind=remove 条目', () async {
    final file = File('$watched/a.txt')..writeAsStringSync('x');
    final service = newService();
    await service.startWatching();

    // 第一批：create 入库
    rustApi.events.add(FileEvent(path: file.path, kind: 'create'));
    await pollCache<bool>(
      (c) => c != null && c.fileChanges.any((f) => f.path == file.path) ? true : null,
    );

    // 第二批：文件删除 + remove 事件（留出 debounce 间隔保证分批）
    file.deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    rustApi.events.add(FileEvent(path: file.path, kind: 'remove'));

    final gone = await pollCache<bool>(
      (c) => c != null && !c.fileChanges.any((f) => f.path == file.path) ? true : null,
    );
    expect(gone, isTrue, reason: 'remove 后缓存不应残留该文件的记录');
    await service.stopWatching();
  });

  test('.daymark 自写排除兼容 Windows 反斜杠路径（issue #13 方案 B）', () {
    final service = CollectService(AppSettings());
    expect(service.isOwnCachePath('/a/.daymark/素材缓存/2026-08-13.json'), isTrue);
    expect(service.isOwnCachePath(r'C:\a\.daymark\素材缓存\2026-08-13.json'), isTrue);
    expect(service.isOwnCachePath('/a/b.txt'), isFalse);
  });

  test('初始扫描跳过失效目录，不中断其余目录（issue #13 方案 B 容错）', () async {
    final todayFile = File('$watched/存在.txt')..writeAsStringSync('今日内容');
    final service = CollectService(
      AppSettings(logRoot: logRoot, watchDirs: ['$tmp.path/不存在目录', watched]),
      debounceDuration: const Duration(milliseconds: 10),
    );
    await service.startWatching();

    final cached = await pollCache<DailyMaterial>(
      (c) => c != null && c.fileChanges.any((f) => f.path == todayFile.path) ? c : null,
    );
    expect(cached, isNotNull, reason: '失效目录不应阻断有效目录的扫描');
    await service.stopWatching();
  });
}
