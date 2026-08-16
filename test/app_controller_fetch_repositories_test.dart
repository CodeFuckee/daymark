/// AppController.fetchRepositories 行为测试（issue #31）：
/// 设置页「选择仓库」对话框的数据源契约：
/// 1. 按实例 id 读取密钥库 token，未配置 Token → 抛 CodeProviderException
///    （含实例名提示，与 fetchCommitAuthors 排障语义一致）；
/// 2. token 就绪 → 交给 provider.fetchRepositories 返回仓库路径列表；
/// 3. 网络/接口失败 → 转成用户可读的 CodeProviderException（friendlyDioMessage）。
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
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// token 读取可注入的 SettingsService（其余 IO 均无）
class _FakeSettingsService extends SettingsService {
  _FakeSettingsService({super.initial});
  final Map<String, String> tokens = {};

  @override
  Future<String?> getToken(String instanceId) async => tokens[instanceId];
}

/// 行为可注入的 CodeProvider（fetchCommits/作者不参与本测试）
class _FakeProvider implements CodeProvider {
  _FakeProvider(this.providerType, {this.onFetchRepos, this.throwDio = false});
  @override
  final String providerType;

  /// 仓库列表行为；null → 返回空列表
  Future<List<String>> Function(CodeInstance instance)? onFetchRepos;

  /// 模拟网络/接口失败
  bool throwDio;

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
  }) async =>
      const [];

  @override
  Future<List<String>> fetchRepositories({
    required CodeInstance instance,
    required String token,
  }) async {
    if (throwDio) {
      throw DioException(
        requestOptions: RequestOptions(path: '/projects'),
        response: Response(
          requestOptions: RequestOptions(path: '/projects'),
          statusCode: 401,
        ),
      );
    }
    if (onFetchRepos != null) return onFetchRepos!(instance);
    return const [];
  }
}

/// 装配无 IO 服务的 fake controller；providerFactory 注入 fake provider
class _FakeController extends AppController {
  _FakeController({
    AppSettings? initial,
    this.tokenFor,
    this.repoResult,
    this.throwDio = false,
  }) : _initial = initial ?? AppSettings();

  final AppSettings _initial;
  final Map<String, String>? tokenFor;
  final Future<List<String>> Function(CodeInstance)? repoResult;
  final bool throwDio;

  @override
  AppState build() {
    final fs = _FakeSettingsService(initial: _initial);
    if (tokenFor != null) fs.tokens.addAll(tokenFor!);
    settingsService = fs;
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
    providerFactory = (type) =>
        _FakeProvider(type, onFetchRepos: repoResult, throwDio: throwDio);
    return AppState(settings: settingsService.settings, settingsLoaded: true);
  }
}

void main() {
  _FakeController makeController({
    AppSettings? initial,
    Map<String, String>? tokens,
    Future<List<String>> Function(CodeInstance)? repoResult,
    bool throwDio = false,
  }) {
    final container = ProviderContainer(overrides: [
      appControllerProvider.overrideWith(
        () => _FakeController(
          initial: initial,
          tokenFor: tokens,
          repoResult: repoResult,
          throwDio: throwDio,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    // 触发 build()，初始化 settingsService 等字段
    return container.read(appControllerProvider.notifier) as _FakeController;
  }

  final instance = CodeInstance(
    id: 'gl1',
    providerType: 'gitlab',
    name: '公司 GitLab',
    baseUrl: 'https://git.example.com',
  );

  group('AppController.fetchRepositories（issue #31）', () {
    test('未配置 Token → 抛 CodeProviderException（含实例名）', () async {
      final controller = makeController(
        initial: AppSettings(codeInstances: [instance]),
      );
      await expectLater(
        controller.fetchRepositories(instance),
        throwsA(isA<CodeProviderException>().having(
          (e) => e.message,
          'message',
          contains('公司 GitLab：未配置 Token'),
        )),
      );
    });

    test('token 就绪 → 返回仓库路径列表', () async {
      final controller = makeController(
        initial: AppSettings(codeInstances: [instance]),
        tokens: {'gl1': 'test-token'},
        repoResult: (i) async => ['ckd/daymark', 'ckd/shipyard'],
      );
      final repos = await controller.fetchRepositories(instance);
      expect(repos, ['ckd/daymark', 'ckd/shipyard']);
    });

    test('接口 401 → 转成用户可读的 CodeProviderException', () async {
      final controller = makeController(
        initial: AppSettings(codeInstances: [instance]),
        tokens: {'gl1': 'test-token'},
        throwDio: true,
      );
      await expectLater(
        controller.fetchRepositories(instance),
        throwsA(isA<CodeProviderException>().having(
          (e) => e.message,
          'message',
          contains('401'),
        )),
      );
    });
  });
}
