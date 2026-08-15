/// CollectService 刷新素材补扫测试（issue #19 第二轮：用户选择 2026.8.6、
/// 刷新素材后找不到当日修改过的「大干围建筑景观合模.skp」；第一轮移除
/// take(8) 渲染截断后仍不行——「刷新后什么文件都没有」）。
///
/// 根因：collectForDate 只读素材缓存、从不扫描磁盘。历史日期的缓存仅来自
/// 当天监控运行时的事件流；当天应用未运行/监控未开启时缓存为空，刷新素材
/// 自然看不到当日修改的文件。issue #13 的初始扫描只补「今日」，历史日期
/// 从不补扫。
///
/// 契约（修复后）：
/// 1. 历史日期无缓存时，刷新素材（collectForDate）补扫出 mtime 落在所选
///    日期的文件（修复前：缓存为空 → 列表为空，.skp 永远看不到）；
/// 2. mtime 不在所选日期的文件不混入；
/// 3. 缓存已有记录保留——磁盘 mtime 已移出所选日期时不丢缓存记录
///    （云盘同步重写 mtime 等场景）；
/// 4. 补扫同样应用排除规则与 .daymark 自身路径过滤；
/// 5. 扫描补充的记录写回缓存，后续刷新直接可用。
library;

import 'dart:io';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String logRoot;
  late String watched;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('daymark_scan_');
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

  /// 所选日期 = 3 天前的自然日
  DateTime targetDate() => dayStart(DateTime.now()).subtract(const Duration(days: 3));

  /// 在 watched 下创建文件并把 mtime 设为 [time]
  File writeWithMtime(String name, DateTime time) {
    final f = File('$watched/$name')..writeAsStringSync('内容');
    f.setLastModifiedSync(time);
    return f;
  }

  test('历史日期无缓存时，刷新素材补扫出当日修改的文件（issue #19 第二轮复现）', () async {
    // 用户场景：8.6 修改的 .skp 等文件在磁盘上（mtime 落在所选日期），
    // 但当天应用未运行/监控未开启，所选日期没有任何缓存记录。
    final skp = writeWithMtime(
      '大干围建筑景观合模.skp',
      targetDate().add(const Duration(hours: 14, minutes: 30)),
    );
    final txt = writeWithMtime(
      '说明.txt',
      targetDate().add(const Duration(hours: 9)),
    );

    // 不启动监控，直接刷新素材（= 用户点「刷新素材」按钮的链路）
    final material = await newService().collectForDate(targetDate());

    final paths = material.fileChanges.map((f) => f.path).toList();
    expect(paths, contains(skp.path),
        reason: '修复前缓存为空，刷新素材看不到当日修改的 .skp（issue #19）');
    expect(paths, contains(txt.path), reason: '当日修改的其他文件也应一并补扫出来');
  });

  test('补扫不混入所选日期之外 mtime 的文件', () async {
    writeWithMtime('当日.skp', targetDate().add(const Duration(hours: 10)));
    writeWithMtime('今日.txt', DateTime.now());
    writeWithMtime(
      '更早.txt',
      targetDate().subtract(const Duration(days: 1, hours: 1)),
    );

    final material = await newService().collectForDate(targetDate());

    final paths = material.fileChanges.map((f) => f.path).toList();
    expect(paths, contains('$watched/当日.skp'));
    expect(paths, isNot(contains('$watched/今日.txt')),
        reason: 'mtime 在所选日期之外（今日）的文件不应混入');
    expect(paths, isNot(contains('$watched/更早.txt')),
        reason: 'mtime 在所选日期之前的文件不应混入');
  });

  test('缓存已有记录保留——磁盘 mtime 已移出所选日期时不丢缓存记录', () async {
    // 云盘同步/编辑器等重写文件会把 mtime 移出所选日期；此时扫描找不到
    // 该文件，但缓存里的历史快照记录必须保留，不能被扫描结果抹掉。
    final stale = FileChange(
      path: '$watched/被云盘重写过.skp',
      mtime: targetDate().add(const Duration(hours: 11)),
      size: 1,
      kind: 'modify',
    );
    await saveMaterialCache(
        logRoot, DailyMaterial(date: targetDate(), fileChanges: [stale]));
    // 磁盘上同名文件 mtime 已是今天（扫描历史日期时扫不到）
    writeWithMtime('被云盘重写过.skp', DateTime.now());

    final material = await newService().collectForDate(targetDate());

    expect(material.fileChanges.map((f) => f.path), contains(stale.path),
        reason: '缓存已有记录不能被补扫结果清掉（issue #19 第二轮契约 3）');
  });

  test('补扫应用排除规则与 .daymark 自身路径过滤', () async {
    final ok = writeWithMtime('正常.skp', targetDate().add(const Duration(hours: 10)));
    // .git 子目录需先建父目录（与 collect_service_watch_test 写法一致）
    final excluded = File('$watched/.git/config')..createSync(recursive: true);
    excluded.writeAsStringSync('内容');
    excluded.setLastModifiedSync(targetDate().add(const Duration(hours: 10)));

    final service = CollectService(
      AppSettings(
        logRoot: logRoot,
        watchDirs: [watched],
        excludePatterns: ['.git'],
      ),
      debounceDuration: const Duration(milliseconds: 10),
    );
    final material = await service.collectForDate(targetDate());

    final paths = material.fileChanges.map((f) => f.path).toList();
    expect(paths, contains(ok.path));
    expect(paths, isNot(contains(excluded.path)),
        reason: '命中排除规则的文件不应被补扫出来');
    expect(paths, isNot(contains(RegExp(r'\.daymark'))),
        reason: '.daymark 自身缓存目录的文件不应被补扫出来');
  });

  test('扫描补充的记录写回缓存，后续刷新直接可用', () async {
    writeWithMtime('大干围建筑景观合模.skp', targetDate().add(const Duration(hours: 15)));

    await newService().collectForDate(targetDate());

    // collectForDate 完成后扫描结果应已写回所选日期缓存
    final cached = await loadMaterialCache(logRoot, targetDate());
    expect(
      cached?.fileChanges.map((f) => f.path),
      contains('$watched/大干围建筑景观合模.skp'),
      reason: '补扫出的文件变更应写回缓存，避免每次刷新都全量重扫',
    );
  });
}
