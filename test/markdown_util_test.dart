import 'dart:io';

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/util/date_util.dart';
import 'package:daymark/core/util/markdown_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late String logRoot;
  final date = DateTime(2026, 8, 11);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('daymark_test_');
    logRoot = tempDir.path;
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('inbox', () {
    test('追加后可按行解析', () async {
      await appendInbox(logRoot, date, '和产品确认审批流需求');
      await appendInbox(logRoot, date, '修复 shipyard 缓存 bug #开发');

      final notes = await readInbox(logRoot, date);
      expect(notes.length, 2);
      expect(notes[0].content, '和产品确认审批流需求');
      expect(notes[1].content, '修复 shipyard 缓存 bug');
      expect(notes[1].tags, ['开发']);
    });

    test('文件头正确', () async {
      await appendInbox(logRoot, date, '测试');
      final content = await File('$logRoot/inbox/${dateKey(date)}.md').readAsString();
      expect(content, contains('# ${dateKey(date)} 随手记录'));
      expect(content, contains('- [${hhmm(date)}] 测试'));
    });

    test('跳过空行和格式错误的行', () async {
      await appendInbox(logRoot, date, '第一行');
      final file = File('$logRoot/inbox/${dateKey(date)}.md');
      await file.writeAsString('${await file.readAsString()}\n\n不是记录行\n- [xx:yy] 时间非法\n');

      final notes = await readInbox(logRoot, date);
      expect(notes.length, 1);
      expect(notes[0].content, '第一行');
    });

    test('collectTags 收集历史标签并去重', () async {
      await appendInbox(logRoot, date, 'A #会议');
      await appendInbox(logRoot, date, 'B #会议 #开发');
      final tags = await collectTags(logRoot);
      expect(tags, containsAll(['会议', '开发']));
      expect(tags.where((t) => t == '会议').length, 1);
    });

    test('extractTags 忽略纯数字', () {
      expect(extractTags('内容 #2024'), isEmpty);
      expect(extractTags('内容 #标签1'), ['标签1']);
    });
  });

  group('日报路径与定稿', () {
    test('定稿前后判定', () async {
      expect(isFinalized(logRoot, date), isFalse);
      await finalizeReport(logRoot, date, '# 工作日报 2026-08-11\n\n内容');
      expect(isFinalized(logRoot, date), isTrue);
      final f = File(dailyReportPath(logRoot, date));
      expect(await f.exists(), isTrue);
      expect(await f.readAsString(), contains('工作日报'));
    });

    test('定稿后草稿被删除', () async {
      await writeDraft(logRoot, date, '草稿内容');
      expect(File(draftPath(logRoot, date)).existsSync(), isTrue);
      await finalizeReport(logRoot, date, '定稿内容');
      expect(File(draftPath(logRoot, date)).existsSync(), isFalse);
    });

    test('readExistingReport 优先定稿', () async {
      await writeDraft(logRoot, date, '草稿内容');
      await finalizeReport(logRoot, date, '定稿内容');
      final content = await readExistingReport(logRoot, date);
      expect(content, '定稿内容');
    });
  });

  group('素材缓存', () {
    test('存取往返', () async {
      final m = DailyMaterial(
        date: date,
        commits: [
          Commit(
            sha: 'abc123',
            message: 'fix: bug',
            project: 'group/repo',
            author: 'ckd',
            date: date,
            provider: 'gitlab',
          ),
        ],
        fileChanges: [
          FileChange(path: '/a/b.md', mtime: date, size: 10, kind: 'modify'),
        ],
        notes: [QuickNote(time: date, content: 'x', tags: const [])],
      );
      await saveMaterialCache(logRoot, m);
      final loaded = await loadMaterialCache(logRoot, date);
      expect(loaded, isNotNull);
      expect(loaded!.commits.single.sha, 'abc123');
      expect(loaded.fileChanges.single.kind, 'modify');
      expect(loaded.notes.single.content, 'x');
    });

    test('损坏缓存返回 null', () async {
      final dir = Directory('$logRoot/.daymark/素材缓存');
      await dir.create(recursive: true);
      await File(materialCachePath(logRoot, date)).writeAsString('{broken');
      expect(await loadMaterialCache(logRoot, date), isNull);
    });
  });
}
