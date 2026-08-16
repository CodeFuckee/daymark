/// CollectService git 历史补扫测试（issue #32：11 号修改的文件、14 号又修改，
/// 16 号生成 11 号日报时该文件没有对应的变更记录）。
///
/// 根因：collectForDate 对历史日期的补扫只按「当前磁盘 mtime」归属自然日，
/// 文件在 11 号修改、14 号又修改后 mtime 已被覆盖为 14 号，扫 11 号时
/// mtime 不在区间内 → 11 号的变更记录丢失（当天应用未运行/监控未开启时
/// 缓存也为空，无其他恢复渠道）。
///
/// 修复：补扫时对监控目录内的 git 仓库查询 [date] 自然日 author date 的
/// 提交（与 GitLab/GitHub 提交采集同语义），把提交触及的文件补为变更记录
/// ——git 历史不随磁盘 mtime 覆盖而丢失。
///
/// 契约（修复后）：
/// 1. 文件在 D 日修改并提交、D+3 日又修改（mtime 已移出 D 日）→ 补扫 D 日
///    仍能恢复该文件的变更记录（issue #32 复现场景）；
/// 2. 按 author date 归属自然日——11 号编写、14 号才提交的改动计入 11 号；
/// 3. 提交时间不在所选日期的文件不混入；
/// 4. 非 git 监控目录行为不变（仅 mtime 扫描）；
/// 5. 排除规则同样作用于 git 补扫记录；
/// 6. 同日多次提交同一文件 → 单条记录（取当日最后一次提交时间）；
/// 7. 删除提交 → kind='remove' 记录（删除后磁盘无文件，mtime 扫描恢复不了）；
/// 8. 伪仓库（.git 目录但不是仓库）/ git 不可用 → 优雅跳过，不报错。
library;

import 'dart:io';

import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String logRoot;
  late String watched;
  late bool gitAvailable;

  setUpAll(() async {
    final probe = await Process.run('git', ['--version']);
    gitAvailable = probe.exitCode == 0;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('daymark_git_');
    logRoot = '${tmp.path}/logs';
    watched = '${tmp.path}/watched';
    Directory(watched).createSync(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  CollectService newService({List<String>? excludes}) => CollectService(
        AppSettings(
          logRoot: logRoot,
          watchDirs: [watched],
          excludePatterns: excludes ?? AppSettings.defaultExcludePatterns,
        ),
        debounceDuration: const Duration(milliseconds: 10),
      );

  /// 所选日期 = 3 天前的自然日（模拟「11 号」）
  DateTime day(int back) => dayStart(DateTime.now()).subtract(Duration(days: back));

  /// 在 [dir] 初始化 git 仓库（测试环境必须可用，失败直接断言报错）
  void gitInit(String dir) {
    final r = Process.runSync('git', ['init', '-q', dir]);
    expect(r.exitCode, 0, reason: 'git init 失败: ${r.stderr}');
    for (final cfg in [
      ['config', 'user.email', 'test@daymark.local'],
      ['config', 'user.name', '测试用户'],
      ['config', 'commit.gpgsign', 'false'],
      ['config', 'tag.gpgsign', 'false'],
    ]) {
      Process.runSync('git', ['-C', dir, ...cfg]);
    }
  }

  /// 写入 [file] 并提交，author/committer 时间均为 [when]（epoch 秒 +0800，
  /// 与 git 内部时间表示一致，不受机器时区影响）
  void gitCommit(String repo, String file, String content, DateTime when, String msg) {
    final f = File('$repo/$file')..writeAsStringSync(content);
    f.setLastModifiedSync(when);
    Process.runSync('git', ['-C', repo, 'add', file]);
    final epoch = (when.millisecondsSinceEpoch / 1000).floor();
    final r = Process.runSync(
      'git',
      ['-C', repo, 'commit', '-q', '-m', msg],
      environment: {
        'GIT_AUTHOR_DATE': '@$epoch +0800',
        'GIT_COMMITTER_DATE': '@$epoch +0800',
      },
    );
    expect(r.exitCode, 0, reason: 'git commit 失败: ${r.stderr}');
  }

  test('issue #32 复现：D 日修改并提交、D+3 日又修改的文件，补扫 D 日仍能恢复', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    // 用户场景：11 号修改 a.txt（提交），14 号又修改（提交）；
    // 16 号（=现在）生成 11 号日报。当前磁盘 mtime 已是 14 号的修改。
    gitCommit(watched, 'a.txt', 'v1', d.add(const Duration(hours: 10, minutes: 30)), '11号修改');
    gitCommit(watched, 'a.txt', 'v2', day(0).add(const Duration(hours: 9)), '14号又修改');

    final material = await newService().collectForDate(d);

    final paths = material.fileChanges.map((f) => f.path).toList();
    expect(paths, contains('$watched/a.txt'),
        reason: '修复前：文件 14 号又修改后 mtime 覆盖为 14 号，补扫 11 号看不到该文件（issue #32）');
    // 恢复的记录应归属所选日期（mtime = 11 号提交时间），而非 14 号
    final rec = material.fileChanges.singleWhere((f) => f.path == '$watched/a.txt');
    expect(rec.mtime, d.add(const Duration(hours: 10, minutes: 30)));
    // 补扫出的 git 记录应写回当日缓存（与 mtime 补扫同链路），后续刷新直接可用
    final cached = await loadMaterialCache(logRoot, d);
    expect(
      cached?.fileChanges.map((f) => f.path),
      contains('$watched/a.txt'),
      reason: 'git 补扫记录应写回素材缓存，避免每次刷新都重跑 git log',
    );
  });

  test('按 author date 归属自然日：11 号编写、14 号才提交的改动计入 11 号', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    final f = File('$watched/b.txt')..writeAsStringSync('内容');
    f.setLastModifiedSync(d.add(const Duration(hours: 20)));
    Process.runSync('git', ['-C', watched, 'add', 'b.txt']);
    final authorEpoch =
        (d.add(const Duration(hours: 20)).millisecondsSinceEpoch / 1000).floor();
    final commitEpoch =
        (d.add(const Duration(days: 3, hours: 20)).millisecondsSinceEpoch / 1000).floor();
    final r = Process.runSync(
      'git',
      ['-C', watched, 'commit', '-q', '-m', '11号编写14号才提交'],
      environment: {
        'GIT_AUTHOR_DATE': '@$authorEpoch +0800',
        'GIT_COMMITTER_DATE': '@$commitEpoch +0800',
      },
    );
    expect(r.exitCode, 0, reason: 'git commit 失败: ${r.stderr}');

    final material = await newService().collectForDate(d);

    expect(material.fileChanges.map((f) => f.path), contains('$watched/b.txt'),
        reason: '与 GitLab/GitHub 提交采集一致，按 author date 归属自然日');
  });

  test('提交时间不在所选日期的文件不混入', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    // 只有今天（14 号）的修改，11 号没有任何提交触及该文件
    gitCommit(watched, '只有14号.skp', 'v1', day(0).add(const Duration(hours: 10)), '14号才改');

    final material = await newService().collectForDate(d);

    expect(material.fileChanges.map((f) => f.path), isNot(contains('$watched/只有14号.skp')));
  });

  test('非 git 监控目录行为不变（仅 mtime 扫描）', () async {
    final d = day(3);
    final f = File('$watched/普通.txt')..writeAsStringSync('x');
    f.setLastModifiedSync(d.add(const Duration(hours: 9)));

    final material = await newService().collectForDate(d);

    expect(material.fileChanges.map((x) => x.path), contains(f.path));
    expect(material.fileChanges.length, 1, reason: '无 git 仓库时不应产生额外记录');
  });

  test('git 补扫记录同样应用排除规则', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    gitCommit(watched, '排除掉.skp', 'v1', d.add(const Duration(hours: 10)), '改');
    gitCommit(watched, '正常.txt', 'v1', d.add(const Duration(hours: 11)), '改');

    final material = await newService(excludes: ['排除掉']).collectForDate(d);

    final paths = material.fileChanges.map((f) => f.path).toList();
    expect(paths, contains('$watched/正常.txt'));
    expect(paths, isNot(contains('$watched/排除掉.skp')));
  });

  test('同日多次提交同一文件 → 单条记录，取当日最后一次提交时间', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    gitCommit(watched, '多次.txt', 'v1', d.add(const Duration(hours: 9)), '上午改');
    gitCommit(watched, '多次.txt', 'v2', d.add(const Duration(hours: 15)), '下午改');

    final material = await newService().collectForDate(d);

    final recs = material.fileChanges.where((f) => f.path == '$watched/多次.txt').toList();
    expect(recs.length, 1, reason: '同一文件同日多次提交应合并为单条记录');
    expect(recs.single.mtime, d.add(const Duration(hours: 15)));
  });

  test('删除提交 → kind=remove 记录（磁盘文件已不存在，mtime 扫描恢复不了）', () async {
    if (!gitAvailable) return;
    gitInit(watched);
    final d = day(3);
    // 前一天创建并提交，所选日期删除——删除后磁盘无文件，只能靠 git 历史恢复
    gitCommit(watched, '要删除.txt', 'v1', d.subtract(const Duration(days: 1)).add(const Duration(hours: 10)), '前一天创建');
    File('$watched/要删除.txt').deleteSync();
    final epoch = (d.add(const Duration(hours: 10)).millisecondsSinceEpoch / 1000).floor();
    final r = Process.runSync(
      'git',
      ['-C', watched, 'add', '-A'],
    );
    expect(r.exitCode, 0);
    final c = Process.runSync(
      'git',
      ['-C', watched, 'commit', '-q', '-m', '所选日期删除'],
      environment: {
        'GIT_AUTHOR_DATE': '@$epoch +0800',
        'GIT_COMMITTER_DATE': '@$epoch +0800',
      },
    );
    expect(c.exitCode, 0, reason: 'git commit 失败: ${c.stderr}');

    final material = await newService().collectForDate(d);

    final recs =
        material.fileChanges.where((f) => f.path == '$watched/要删除.txt').toList();
    expect(recs.length, 1);
    expect(recs.single.kind, 'remove');
  });

  test('嵌套 git 仓库（监控目录的子目录）也能补扫恢复', () async {
    if (!gitAvailable) return;
    final repo = '$watched/项目A/code';
    Directory(repo).createSync(recursive: true);
    gitInit(repo);
    final d = day(3);
    gitCommit(repo, 'nested.txt', 'v1', d.add(const Duration(hours: 14)), '11号改');
    gitCommit(repo, 'nested.txt', 'v2', day(0).add(const Duration(hours: 8)), '14号又改');

    final material = await newService().collectForDate(d);

    final recs =
        material.fileChanges.where((f) => f.path == '$repo/nested.txt').toList();
    expect(recs.length, 1, reason: '嵌套仓库内的历史变更也应能被 git 历史补扫恢复');
    expect(recs.single.mtime, d.add(const Duration(hours: 14)));
  });

  test('伪仓库（.git 目录但不是仓库）优雅跳过，不报错', () async {
    if (!gitAvailable) return;
    Directory('$watched/假装仓库/.git').createSync(recursive: true);
    final d = day(3);

    final material = await newService().collectForDate(d);

    expect(material.fileChanges, isEmpty, reason: '伪仓库应被优雅跳过，不产生记录也不抛错');
  });
}
