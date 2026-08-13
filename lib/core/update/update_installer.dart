/// 更新安装器（issue #5）：重启软件时自动完成更新。
///
/// 平台方案：
/// - Linux（AppImage）：新包替换 $APPIMAGE 文件（运行中进程不受影响，
///   Linux 打开文件替换安全）→ 启动新 AppImage → 退出旧进程
/// - macOS：hdiutil 挂载 dmg → ditto 覆盖 .app → 清 quarantine →
///   open 新 app → 退出旧进程
/// - Windows：启动 NSIS 安装器 /S /UPDATE（安装器覆盖安装并自动启动
///   新版本，见 scripts/daymark.nsi）→ 退出旧进程
///
/// 依赖注入（runProcess/startProcess/exitApp/environment/osName）便于测试。
library;

import 'dart:io';

import 'update_models.dart';

/// 平台安装计划（纯决策逻辑，可单测）
class UpdateInstallPlan {
  /// 'linux-appimage' | 'macos-app' | 'windows-setup' | 'unsupported'
  final String kind;
  /// unsupported 时的原因说明
  final String? reason;

  const UpdateInstallPlan(this.kind, [this.reason]);

  bool get supported => kind != 'unsupported';
}

class UpdateInstaller {
  final Future<ProcessResult> Function(String executable, List<String> arguments)
      runProcess;
  final Future<Process> Function(String executable, List<String> arguments)
      startProcess;
  final void Function(int code) exitApp;
  /// 环境变量（测试注入 APPIMAGE 等；null → 真实环境）
  final Map<String, String>? environment;
  /// 操作系统名（测试注入；null → Platform.operatingSystem）
  final String? osName;
  /// 当前可执行文件路径（macOS bundle 定位；null → Platform.resolvedExecutable）
  final String? currentExecutable;

  UpdateInstaller({
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    Future<Process> Function(String, List<String>)? startProcess,
    void Function(int)? exitApp,
    this.environment,
    this.osName,
    this.currentExecutable,
  })  : runProcess = runProcess ?? Process.run,
        startProcess = startProcess ?? Process.start,
        exitApp = exitApp ?? exit;

  String get _os => osName ?? Platform.operatingSystem;

  Map<String, String> get _env => environment ?? Platform.environment;

  /// 当前环境能否自动安装（纯决策；命令执行在 [install]）
  UpdateInstallPlan plan() {
    switch (_os) {
      case 'linux':
        final appImage = _env['APPIMAGE'];
        if (appImage != null && appImage.isNotEmpty) {
          return const UpdateInstallPlan('linux-appimage');
        }
        return const UpdateInstallPlan(
          'unsupported',
          '当前非 AppImage 运行环境，请手动下载新版本安装',
        );
      case 'macos':
        final bundle = findAppBundle(
            currentExecutable ?? Platform.resolvedExecutable);
        if (bundle == null) {
          return const UpdateInstallPlan(
            'unsupported',
            '无法定位 Daymark.app 应用包，请手动下载新版本安装',
          );
        }
        return const UpdateInstallPlan('macos-app');
      case 'windows':
        return const UpdateInstallPlan('windows-setup');
      default:
        return UpdateInstallPlan('unsupported', '不支持的操作系统: $_os');
    }
  }

  /// 执行待安装更新；成功后 Linux/macOS 重启进程并退出（exitApp 调用）。
  /// 返回 false 表示环境不支持（计划 unsupported）。
  Future<bool> install(UpdateManifest manifest, String updateDir) async {
    final p = plan();
    final assetPath = '$updateDir/${manifest.assetName}';
    switch (p.kind) {
      case 'linux-appimage':
        await _installLinuxAppImage(assetPath);
        return true;
      case 'macos-app':
        await _installMacosApp(assetPath);
        return true;
      case 'windows-setup':
        // Windows 路径用反斜杠（NSIS 安装器参数）
        await _installWindowsSetup('$updateDir\\${manifest.assetName}');
        return true;
      default:
        return false;
    }
  }

  /// Linux：新包替换 $APPIMAGE（原子 rename）→ 启动新版 → 退出旧进程
  Future<void> _installLinuxAppImage(String assetPath) async {
    final appImage = _env['APPIMAGE']!;
    final src = File(assetPath);
    // 可执行位（下载流写入不带 x）
    await runProcess('chmod', ['+x', src.path]);
    // 同目录临时名再 rename，保证原子替换
    final staged = File('$appImage.new');
    await src.copy(staged.path);
    await staged.rename(appImage);
    await startProcess(appImage, const []);
    exitApp(0);
  }

  /// macOS：挂载 dmg → ditto 覆盖 .app → 清 quarantine → 卸载 → 重启新 app
  Future<void> _installMacosApp(String assetPath) async {
    final attach = await runProcess(
        'hdiutil', ['attach', '-nobrowse', '-readonly', assetPath]);
    if (attach.exitCode != 0) {
      throw StateError('挂载 dmg 失败: ${attach.stderr}');
    }
    final mount = parseHdiutilMount(attach.stdout.toString());
    if (mount == null) {
      throw StateError('解析 dmg 挂载点失败: ${attach.stdout}');
    }
    try {
      // 挂载卷内找 .app
      final entries = Directory(mount)
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'));
      if (entries.isEmpty) {
        throw StateError('dmg 内未找到 .app: $mount');
      }
      final srcApp = entries.first.path;
      final bundle =
          findAppBundle(currentExecutable ?? Platform.resolvedExecutable)!;
      // 覆盖替换（ditto 保留权限与签名）
      await runProcess('/bin/rm', ['-rf', bundle]);
      final copy = await runProcess('ditto', [srcApp, bundle]);
      if (copy.exitCode != 0) {
        throw StateError('覆盖 .app 失败: ${copy.stderr}');
      }
      // 清除下载隔离属性（ad-hoc 签名 app 重新触发 Gatekeeper 的根因）
      await runProcess('xattr', ['-dr', 'com.apple.quarantine', bundle]);
      await startProcess('open', ['-n', bundle]);
      exitApp(0);
    } finally {
      await runProcess('hdiutil', ['detach', mount]);
    }
  }

  /// Windows：启动 NSIS 安装器静默覆盖安装（安装器完成后自动启动新版本）
  Future<void> _installWindowsSetup(String assetPath) async {
    await startProcess(assetPath, ['/S', '/UPDATE']);
    exitApp(0);
  }
}

/// 从可执行文件路径向上定位 .app bundle（macOS）
/// 例：/Applications/Daymark.app/Contents/MacOS/daymark → /Applications/Daymark.app
/// 纯路径逻辑（不查文件系统，保证跨平台可测）
String? findAppBundle(String executablePath) {
  var dir = File(executablePath).parent;
  for (var i = 0; i < 6; i++) {
    if (dir.path.endsWith('.app')) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

/// 解析 hdiutil attach 输出中的挂载点。
/// 挂载点以 /Volumes/ 开头且可含空格（卷名 "Daymark 1"），取该列起剩余部分。
String? parseHdiutilMount(String output) {
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    final idx = parts.indexWhere((p) => p.startsWith('/Volumes/'));
    if (idx >= 0) {
      return parts.sublist(idx).join(' ');
    }
  }
  return null;
}
