/// AppController.fetchCommitAuthors 行为测试（issue #20 第三轮）：
/// 「未拉取到任何提交作者（请确认代码实例已配置 Token 且仓库有提交）」的
/// 根因修复契约：
/// 1. fetchCommitAuthors 接受可选 [instances]：设置页传入草稿实例列表，
///    新增实例未点「保存设置」也能拉取（修复前读已持久化 settings，草稿
///    里的实例被忽略 → 空列表）；
/// 2. 实例级失败不静默吞掉：无任何作者且存在失败时抛 CodeProviderException，
///    消息按实例列出原因（401/网络/未配置 Token），用户可据提示排障；
/// 3. 部分失败部分成功时返回成功实例的作者（单实例失败不拖垮全部）；
/// 4. 全部成功时按 key 去重、排序返回。
library;

import 'package:daymark/core/models/material.dart';
import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/providers/code_provider.dart';
import 'package:daymark/core/services/collect_service.dart';
import 'package:daymark/core/services/notification_service.dart';
import 'package:daymark/core/services/record_service.dart';
import 'package:daymark/core/services/report_service.dart';
import 'package:daymark/core/services/settings_service.dart';
import 'package:daymark/core/update/update_config.dart';
import 'package:daymark/core/update/update_service.dart';
import 'package:daymark/ui/app_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// token 读取可注入的 SettingsService（其余 IO 均无）
class _FakeSettingsService extends SettingsService {
  _FakeSettingsService({super.initial});
  final Map<String, String> tokens = {};

  @override
  Future<String?> getToken(String instanceId) async => tokens[instanceId];
}

/// 行为可注入的 CodeProvider（fetchCommits 不参与本测试）
class _FakeProvider implements CodeProvider {
  _FakeProvider(this.providerType, {this.onFetchAuthors});
  @override
  final String providerType;
  final Future<List<CommitAuthor>> Function(CodeInstance instance)? onFetchAuthors;

  @override
  Future<List<Commit>> fetchCommits({
    required DateTime date,
    required CodeInstance instance,
    required String token,
    required String author,
    List<String> extraAuthors = const [],
  }) async =>
      const [];

  @override
  Future<List<CommitAuthor>> fetchCommitAuthors({
    required CodeInstance instance,
    required String token,
    int maxCommitsPerRepo = 100,
  }) =>
      onFetchAuthors!(instance);
}

/// 装配无 IO 服务的 fake controller；providerFactory 注入 fake provider
class _FakeController extends AppController {
  _FakeController({AppSettings? initial}) : _initial = initial ?? AppSettings();

  final AppSettings _initial;

  @override
  AppState build() {
    settingsService = _FakeSettingsService(initial: _initial);
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
}

CodeInstance _instance(
  String id, {
  String name = '',
  bool enabled = true,
  String providerType = 'gitlab',
}) =>
    CodeInstance(
      id: id,
      providerType: providerType,
      name: name,
      baseUrl: 'https://git.example.com',
      enabled: enabled,
    );

void main() {
  ProviderContainer makeContainer(AppController Function() create) {
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(create)],
    );
    addTearDown(container.dispose);
    return container;
  }

  _FakeController makeController({
    AppSettings? initial,
    Map<String, CodeProvider>? providers,
    Map<String, String>? tokens,
  }) {
    final container = makeContainer(() => _FakeController(initial: initial));
    final controller = container.read(appControllerProvider.notifier) as _FakeController;
    controller.providerFactory = (type) => providers![type]!;
    final service = controller.settingsService as _FakeSettingsService;
    service.tokens.addAll(tokens ?? const {});
    return controller;
  }

  test('instances 参数优先：settings 里无实例时传入草稿实例仍能拉取', () async {
    final fetched = <CodeInstance>[];
    final controller = makeController(
      providers: {
        'gitlab': _FakeProvider('gitlab', onFetchAuthors: (instance) async {
          fetched.add(instance);
          return const [CommitAuthor(name: 'chenkaidi', email: 'a@b.c')];
        }),
      },
      tokens: {'draft-1': 't1'},
    );
    // settings 持久化列表为空（模拟用户添加实例后未点「保存设置」）
    expect(controller.settingsService.settings.codeInstances, isEmpty);

    final authors = await controller.fetchCommitAuthors(
      instances: [_instance('draft-1', name: '草稿 GitLab')],
    );

    expect(fetched.single.id, 'draft-1');
    expect(authors.single.name, 'chenkaidi');
  });

  test('全部实例失败：抛 CodeProviderException 且消息按实例列出原因', () async {
    final controller = makeController(
      initial: AppSettings(
        codeInstances: [
          _instance('a', name: '公司 GitLab'),
          _instance('b', name: '个人 GitHub', providerType: 'github'),
        ],
      ),
      providers: {
        'gitlab': _FakeProvider('gitlab',
            onFetchAuthors: (_) async => throw CodeProviderException('401 未授权')),
        'github': _FakeProvider('github',
            onFetchAuthors: (_) async => throw CodeProviderException('网络连接失败')),
      },
      tokens: {'a': 't1', 'b': 't2'},
    );

    await expectLater(
      controller.fetchCommitAuthors(),
      throwsA(isA<CodeProviderException>().having(
        (e) => e.message,
        'message',
        allOf(contains('公司 GitLab'), contains('401 未授权'),
            contains('个人 GitHub'), contains('网络连接失败')),
      )),
    );
  });

  test('token 缺失：错误消息标出「未配置 Token」与实例名', () async {
    final controller = makeController(
      initial: AppSettings(codeInstances: [_instance('a', name: '公司 GitLab')]),
      providers: {
        'gitlab': _FakeProvider('gitlab',
            onFetchAuthors: (_) async => const [CommitAuthor(name: 'x', email: '')]),
      },
    );
    // tokens 未注入 → getToken 返回 null

    await expectLater(
      controller.fetchCommitAuthors(),
      throwsA(isA<CodeProviderException>().having(
        (e) => e.message,
        'message',
        allOf(contains('公司 GitLab'), contains('未配置 Token')),
      )),
    );
  });

  test('部分失败部分成功：返回成功实例的作者，不因单实例失败清空', () async {
    final controller = makeController(
      initial: AppSettings(codeInstances: [_instance('a'), _instance('b')]),
      providers: {
        'gitlab': _FakeProvider('gitlab', onFetchAuthors: (instance) async {
          if (instance.id == 'a') {
            throw CodeProviderException('连接超时');
          }
          return const [CommitAuthor(name: 'chenkaidi', email: 'a@b.c')];
        }),
      },
      tokens: {'a': 't1', 'b': 't2'},
    );

    final authors = await controller.fetchCommitAuthors();
    expect(authors.single.name, 'chenkaidi');
  });

  test('全部成功：跨实例去重 + 按 key 排序；禁用/空 baseUrl 实例不参与', () async {
    final controller = makeController(
      initial: AppSettings(codeInstances: [
        _instance('a'),
        _instance('b'),
        _instance('c', enabled: false),
        _instance('d')..baseUrl = '',
      ]),
      providers: {
        'gitlab': _FakeProvider('gitlab', onFetchAuthors: (instance) async {
          if (instance.id == 'a') {
            return const [
              CommitAuthor(name: 'ChenKaidi', email: 'A@B.C'),
              CommitAuthor(name: 'code01', email: 'x@y.z'),
            ];
          }
          return const [
            CommitAuthor(name: 'chenkaidi', email: 'a@b.c'),
            CommitAuthor(name: 'code02', email: 'u@v.w'),
          ];
        }),
      },
      tokens: {'a': 't1', 'b': 't2'},
    );

    final authors = await controller.fetchCommitAuthors();
    // 'ChenKaidi'/'chenkaidi' 同一 key（小写）→ 去重；禁用与空 baseUrl 不参与
    expect(authors.map((a) => a.key).toList(),
        ['ChenKaidi', 'code01', 'code02']);
    expect(authors.map((a) => a.key.toLowerCase()).toSet().length, authors.length);
  });
}
