import 'dart:io';

import 'package:daymark/core/update/update_installer.dart';
import 'package:daymark/core/update/update_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = UpdateManifest(
  version: '0.1.4',
  assetName: 'daymark-linux-x86_64.AppImage',
  sourceType: 'gitlab',
);

void main() {
  group('UpdateInstaller.plan（平台决策）', () {
    test('Linux + APPIMAGE 环境 → linux-appimage', () {
      final installer = UpdateInstaller(
        osName: 'linux',
        environment: {'APPIMAGE': '/opt/daymark.AppImage'},
      );
      expect(installer.plan().kind, 'linux-appimage');
    });

    test('Linux 无 APPIMAGE（非 AppImage 运行）→ unsupported', () {
      final installer = UpdateInstaller(
        osName: 'linux',
        environment: {},
      );
      final plan = installer.plan();
      expect(plan.kind, 'unsupported');
      expect(plan.reason, contains('AppImage'));
    });

    test('macOS → macos-app（bundle 定位成功）', () {
      final installer = UpdateInstaller(
        osName: 'macos',
        currentExecutable: '/Applications/Daymark.app/Contents/MacOS/daymark',
      );
      expect(installer.plan().kind, 'macos-app');
    });

    test('macOS 无法定位 bundle → unsupported', () {
      final installer = UpdateInstaller(
        osName: 'macos',
        currentExecutable: '/usr/local/bin/daymark',
      );
      expect(installer.plan().kind, 'unsupported');
    });

    test('Windows → windows-setup', () {
      final installer = UpdateInstaller(osName: 'windows', environment: {});
      expect(installer.plan().kind, 'windows-setup');
    });
  });

  group('findAppBundle（macOS bundle 定位）', () {
    test('从 Contents/MacOS 内定位到 .app', () {
      expect(
        findAppBundle('/Applications/Daymark.app/Contents/MacOS/daymark'),
        '/Applications/Daymark.app',
      );
    });

    test('嵌套目录仍能定位', () {
      expect(
        findAppBundle('/Applications/Daymark.app/Contents/MacOS/sub/daymark'),
        '/Applications/Daymark.app',
      );
    });

    test('无 .app 路径 → null', () {
      expect(findAppBundle('/usr/local/bin/daymark'), isNull);
    });
  });

  group('parseHdiutilMount（挂载点解析）', () {
    test('标准输出解析 /Volumes 路径', () {
      const output = '''
/dev/disk4s1  \tApple_HFS  \t/Volumes/Daymark 1
''';
      expect(parseHdiutilMount(output), '/Volumes/Daymark 1');
    });

    test('无挂载信息 → null', () {
      expect(parseHdiutilMount('hdiutil: attach failed - no mountable file systems'), isNull);
    });
  });

  group('UpdateInstaller.install（Linux AppImage 替换）', () {
    test('替换 AppImage → 启动新版 → 退出旧进程', () async {
      final tempDir = await Directory.systemTemp.createTemp('daymark-install-');
      addTearDown(() => tempDir.delete(recursive: true));
      final appImage = File('${tempDir.path}/daymark.AppImage')
        ..writeAsStringSync('old-binary');
      final updateDir = Directory('${tempDir.path}/update')..createSync();
      File('${updateDir.path}/${_manifest.assetName}')
          .writeAsStringSync('new-binary');

      final runs = <(String, List<String>)>[];
      final starts = <(String, List<String>)>[];
      var exited = -1;
      final installer = UpdateInstaller(
        osName: 'linux',
        environment: {'APPIMAGE': appImage.path},
        runProcess: (exe, args) async {
          runs.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          starts.add((exe, args));
          return Process.start('/bin/true', const []);
        },
        exitApp: (code) => exited = code,
      );

      final ok = await installer.install(_manifest, updateDir.path);
      expect(ok, isTrue);
      // 替换生效：目标文件内容为新包
      expect(await appImage.readAsString(), 'new-binary');
      // chmod +x 被调用
      expect(runs.map((r) => r.$1).toList(), ['chmod']);
      // 启动新 AppImage 并退出
      expect(starts.single.$1, appImage.path);
      expect(exited, 0);
      // 无 .new 残留
      expect(await File('${appImage.path}.new').exists(), isFalse);
    });

    test('unsupported 环境 → 返回 false 且不执行任何命令', () async {
      var commandRan = false;
      final installer = UpdateInstaller(
        osName: 'linux',
        environment: {},
        runProcess: (exe, args) async {
          commandRan = true;
          return ProcessResult(0, 0, '', '');
        },
      );
      final ok = await installer.install(_manifest, '/nonexistent');
      expect(ok, isFalse);
      expect(commandRan, isFalse);
    });
  });

  group('UpdateInstaller.install（Windows 安装器启动）', () {
    test('启动 NSIS /S /UPDATE 并退出', () async {
      final starts = <(String, List<String>)>[];
      var exited = -1;
      final installer = UpdateInstaller(
        osName: 'windows',
        environment: {},
        startProcess: (exe, args) async {
          starts.add((exe, args));
          return Process.start('/bin/true', const []);
        },
        exitApp: (code) => exited = code,
      );
      final ok = await installer.install(_manifest, 'C:\\updates');
      expect(ok, isTrue);
      expect(starts.single.$1, r'C:\updates\daymark-linux-x86_64.AppImage');
      expect(starts.single.$2, ['/S', '/UPDATE']);
      expect(exited, 0);
    });
  });
}
