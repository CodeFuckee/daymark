/// 设置页交互测试：
/// - 保存交互（issue #6：保存按钮卡在"保存中…"）；
/// - 目录监控添加（issue #11：+ 号无反应，改为目录选择器）。
///
/// UI 契约：
/// - 点击"保存设置"→ 等待 saveSettings 完成 → 按钮恢复、显示成功提示；
/// - saveSettings 抛异常 → 按钮恢复、显示"保存失败：…"；
/// - saveSettings 挂起期间按钮显示"保存中…"且禁用（不吞掉进行中状态）；
/// - 点击"添加监控目录"右侧按钮 → 弹出系统目录选择器 → 选中目录加入监控列表；
/// - 选择器取消 → 不添加条目；输入框回车仍可手动添加路径。
library;

import 'dart:async';

import 'package:daymark/core/about/about_info.dart';
import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:daymark/ui/pages/settings_page.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的 fake controller：saveSettings 行为由测试注入，build 不触 FRB/IO
class _FakeController extends AppController {
  _FakeController({this.onSave, this.onFetchAuthors, AppSettings? initial})
      : _initial = initial ?? AppSettings(authorName: '测试');

  Future<void> Function(AppSettings next)? onSave;
  /// 拉取提交作者行为（issue #20 第二轮）：未注入时返回空列表
  Future<List<CommitAuthor>> Function()? onFetchAuthors;
  final AppSettings _initial;

  @override
  AppState build() {
    settingsService = SettingsService(initial: _initial);
    recordService = RecordService(settingsService.settings);
    collectService = CollectService(settingsService.settings);
    reportService = ReportService(
      settingsService.settings,
      collector: collectService,
    );
    notificationService = NotificationService();
    updateConfig = UpdateConfig.fromEnvironment();
    updateService = UpdateService(config: updateConfig);
    reloadHotkey = () async {};
    reloadWatcher = () async {};
    reloadAutoLaunch = (_) async {};
    return AppState(settings: settingsService.settings, settingsLoaded: true);
  }

  @override
  Future<void> saveSettings(AppSettings next) async {
    if (onSave != null) {
      await onSave!(next);
      return;
    }
    await super.saveSettings(next);
  }

  @override
  Future<List<CommitAuthor>> fetchCommitAuthors() async {
    if (onFetchAuthors != null) return onFetchAuthors!();
    return const [];
  }
}

Widget _wrap(_FakeController controller) {
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith(() => controller)],
    child: const MaterialApp(home: SettingsPage()),
  );
}

void main() {
  testWidgets('保存成功：按钮恢复"保存设置"并显示成功提示', (tester) async {
    final controller = _FakeController(onSave: (_) async {});
    await tester.pumpWidget(_wrap(controller));

    expect(find.text('保存设置'), findsOneWidget);
    await tester.tap(find.text('保存设置'));
    await tester.pump();

    expect(find.text('保存设置'), findsOneWidget);
    expect(find.text('设置已保存'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });

  testWidgets('保存失败：按钮恢复并显示错误信息', (tester) async {
    final controller = _FakeController(
      onSave: (_) async => throw Exception('磁盘写入失败'),
    );
    await tester.pumpWidget(_wrap(controller));

    await tester.tap(find.text('保存设置'));
    await tester.pump();
    await tester.pump();

    expect(find.text('保存设置'), findsOneWidget);
    expect(find.textContaining('保存失败：'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });

  testWidgets('保存挂起期间：按钮显示"保存中…"且禁用（进行中状态不丢失）', (tester) async {
    final gate = Completer<void>();
    final controller = _FakeController(onSave: (_) => gate.future);
    await tester.pumpWidget(_wrap(controller));

    await tester.tap(find.text('保存设置'));
    await tester.pump();

    expect(find.text('保存中…'), findsOneWidget);
    // FilledButton.icon 实际类型是 _FilledButtonWithIcon，需用 bySubtype 匹配
    final button = tester.widget<FilledButton>(find.bySubtype<FilledButton>());
    expect(button.onPressed, isNull, reason: '保存中按钮应禁用，防止重复提交');

    // 完成后恢复
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('保存设置'), findsOneWidget);
    expect(find.text('保存中…'), findsNothing);
  });

  group('并入代码提交的账户（issue #20）', () {
    testWidgets('输入额外账户保存：逗号分隔写入 extraCommitAuthors', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      final field = find.widgetWithText(
          TextField, '并入代码提交的账户（如 agent/code01，多个用逗号分隔）');
      expect(field, findsOneWidget, reason: '设置页日志区块应包含该设置项');

      await tester.enterText(field, 'agent, code01, ');
      await tester.pump();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(saved?.extraCommitAuthors, ['agent', 'code01'],
          reason: '空白段应被清理，仅保留有效账户');
    });

    testWidgets('清空输入保存：extraCommitAuthors 为空列表', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(
        onSave: (next) async => saved = next,
        initial: AppSettings(
          authorName: '测试',
          extraCommitAuthors: const ['agent'],
        ),
      );
      await tester.pumpWidget(_wrap(controller));

      final field = find.widgetWithText(
          TextField, '并入代码提交的账户（如 agent/code01，多个用逗号分隔）');
      expect(tester.widget<TextField>(field).controller!.text, 'agent',
          reason: '已配置的额外账户应回显');

      await tester.enterText(field, '');
      await tester.pump();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(saved?.extraCommitAuthors, isEmpty);
    });
  });

  group('拉取提交作者勾选并入（issue #20 第二轮）', () {
    const authors = [
      CommitAuthor(name: 'agent', email: 'agent@example.com'),
      CommitAuthor(name: 'chenkaidi', email: '935637782@qq.com'),
    ];

    testWidgets('勾选并入保存：与手动输入值合并（列表内以勾选为准）', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(
        onSave: (next) async => saved = next,
        onFetchAuthors: () async => authors,
        initial: AppSettings(
          authorName: '测试',
          extraCommitAuthors: const ['manual_name'],
        ),
      );
      await tester.pumpWidget(_wrap(controller));

      await tester.tap(find.text('从代码仓库拉取提交作者'));
      await tester.pumpAndSettle();

      expect(find.text('agent <agent@example.com>'), findsOneWidget,
          reason: '对话框应展示拉取到的作者列表');

      // 勾选 agent，不勾选 chenkaidi
      await tester.tap(find.text('agent <agent@example.com>'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(saved?.extraCommitAuthors, containsAll(['manual_name', 'agent']),
          reason: '手动输入且不在拉取列表中的值保留，勾选值并入');
      expect(saved?.extraCommitAuthors, isNot(contains('chenkaidi')),
          reason: '未勾选的作者不并入');
    });

    testWidgets('取消勾选已并入账户：保存后移除（勾选状态为准）', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(
        onSave: (next) async => saved = next,
        onFetchAuthors: () async => authors,
        initial: AppSettings(
          authorName: '测试',
          extraCommitAuthors: const ['chenkaidi', 'agent'],
        ),
      );
      await tester.pumpWidget(_wrap(controller));

      await tester.tap(find.text('从代码仓库拉取提交作者'));
      await tester.pumpAndSettle();

      // 两个作者都已在并入列表中 → 初始勾选；取消 agent
      await tester.tap(find.text('agent <agent@example.com>'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(saved?.extraCommitAuthors, ['chenkaidi']);
    });

    testWidgets('拉取失败：对话框显示错误与重试按钮，重试成功展示列表', (tester) async {
      var calls = 0;
      final controller = _FakeController(
        onFetchAuthors: () async {
          calls++;
          if (calls == 1) throw Exception('网络超时');
          return authors;
        },
      );
      await tester.pumpWidget(_wrap(controller));

      await tester.tap(find.text('从代码仓库拉取提交作者'));
      await tester.pumpAndSettle();

      expect(find.textContaining('拉取失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('agent <agent@example.com>'), findsOneWidget,
          reason: '重试成功应展示作者列表');
      // 关闭对话框（取消不影响草稿）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('agent <agent@example.com>'), findsNothing);
    });

    testWidgets('未拉取到任何作者：对话框显示提示', (tester) async {
      final controller = _FakeController(
        onFetchAuthors: () async => const <CommitAuthor>[],
      );
      await tester.pumpWidget(_wrap(controller));

      await tester.tap(find.text('从代码仓库拉取提交作者'));
      await tester.pumpAndSettle();

      expect(find.textContaining('未拉取到任何提交作者'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  });

  group('目录监控（issue #11）：添加监控目录改为目录选择器', () {
    late FileSelectorPlatform original;

    setUp(() {
      original = FileSelectorPlatform.instance;
    });

    tearDown(() {
      FileSelectorPlatform.instance = original;
    });

    testWidgets('点击添加按钮弹出选择器，选中目录加入监控列表并保存', (tester) async {
      final selector = _FakeFileSelector('/picked/dir');
      FileSelectorPlatform.instance = selector;
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      // 修复前：按钮是"添加"文本按钮，找不到"选择目录"tooltip → 测试失败
      // 日志区块新增拉取作者按钮后（issue #20 第二轮），目录监控区块移出
      // 默认 800x600 测试视口 → 拉高视口保证可点（与关于板块测试同法）
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byTooltip('选择目录'));
      await tester.pumpAndSettle();

      expect(selector.calls, 1, reason: '点击按钮应调用系统目录选择器');
      expect(find.text('/picked/dir'), findsOneWidget, reason: '选中目录应出现在监控列表');

      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, ['/picked/dir']);
    });

    testWidgets('取消选择不添加条目：保存后 watchDirs 为空', (tester) async {
      final selector = _FakeFileSelector(null);
      FileSelectorPlatform.instance = selector;
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      // 拉高视口保证「目录监控」区块在可视区内可点（issue #20 第二轮
      // 新增按钮后区块下移）
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byTooltip('选择目录'));
      await tester.pumpAndSettle();

      expect(selector.calls, 1);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, isEmpty);
    });

    testWidgets('输入框手动输入路径并回车：加入监控列表（空白输入不添加）', (tester) async {
      AppSettings? saved;
      final controller = _FakeController(onSave: (next) async => saved = next);
      await tester.pumpWidget(_wrap(controller));

      // 空白输入回车 → 不添加
      final field = find.widgetWithText(TextField, '添加监控目录');
      await tester.enterText(field, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // 手动输入路径回车 → 添加
      await tester.enterText(field, '/manual/dir');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('/manual/dir'), findsOneWidget);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved?.watchDirs, ['/manual/dir']);
    });
  });
  group('关于板块（issue #7）：诊断信息展示 + 一键复制', () {
    testWidgets('设置页底部显示关于板块：应用名/版本占位/操作系统条目', (tester) async {
      final controller = _FakeController();
      await tester.pumpWidget(_wrap(controller));

      // 拉高测试窗口，让整个设置列表一次性构建（ListView 懒构建，
      // 默认 800x600 窗口装不下列表末尾的关于板块）
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();

      expect(find.text('关于'), findsOneWidget);
      expect(find.text('Daymark'), findsOneWidget, reason: '应显示应用名');
      expect(find.text('版本号: 开发构建（未注入版本号）'), findsOneWidget,
          reason: '测试环境未注入版本号应显示占位');
      expect(find.text('构建时间: 开发构建（未注入构建时间）'), findsOneWidget,
          reason: '测试环境未注入构建时间应显示占位');
      // 测试运行在真实宿主（Linux）上，操作系统条目应显示非占位值
      final osText = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .firstWhere((d) => d?.startsWith('操作系统:') == true, orElse: () => null);
      expect(osText, isNotNull, reason: '应显示操作系统条目');
      expect(osText, contains('linux'), reason: '测试宿主为 Linux');
    });

    testWidgets('点击复制按钮：剪贴板收到诊断文本并弹出提示', (tester) async {
      final controller = _FakeController();
      await tester.pumpWidget(_wrap(controller));

      // mock 系统平台通道，捕获 Clipboard.setData 调用
      final clipboardCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardCalls.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byTooltip('复制诊断信息'));
      await tester.pump();

      expect(clipboardCalls, hasLength(1), reason: '点击后应写入剪贴板一次');
      final copied = clipboardCalls.single;
      expect(copied, startsWith('Daymark 诊断信息\n'));
      expect(copied, contains('版本号: 开发构建（未注入版本号）'));
      expect(copied, contains('操作系统: '));
      expect(find.text('诊断信息已复制'), findsOneWidget, reason: '应弹出复制成功提示');
    });

    testWidgets('复制文本包含全部条目标签（不丢调试信息）', (tester) async {
      final controller = _FakeController();
      await tester.pumpWidget(_wrap(controller));

      final clipboardCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardCalls.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byTooltip('复制诊断信息'));
      await tester.pump();

      final copied = clipboardCalls.single;
      // 与 AboutInfo 条目一一对应：每个标签都出现在复制文本中
      final info = AboutInfo.collect(appVersion: null);
      for (final entry in info.entries) {
        expect(copied, contains('${entry.key}: '),
            reason: '复制文本应包含「${entry.key}」标签');
      }
    });
  });
}

/// 目录监控选择器 fake（issue #11）：拦截系统目录选择对话框
class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector(this.directory);

  /// getDirectoryPath 返回值（null 表示用户取消）
  String? directory;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return directory;
  }
}
