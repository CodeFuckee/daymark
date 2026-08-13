/// 设置页（DESIGN.md §5.8）：日志 / 代码 / 目录监控 / 音频 / AI / 快捷键 / 通知。
///
/// token 写入密钥库（flutter_secure_storage），不落 settings.json。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/settings.dart';
import '../app_controller.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late AppSettings _draft;
  AppSettings? _syncedFrom;

  @override
  void initState() {
    super.initState();
    final current = ref.read(appControllerProvider.select((s) => s.settings));
    _syncedFrom = current;
    _draft = AppSettings.fromJson(current.toJson());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 外部设置变化（如初次加载完成）时重新克隆草稿；用户未改动的草稿才覆盖
    final current = ref.read(appControllerProvider.select((s) => s.settings));
    if (!_dirty && !identical(_syncedFrom, current)) {
      _syncedFrom = current;
      _draft = AppSettings.fromJson(current.toJson());
    }
  }

  bool _dirty = false;
  String? _message;
  String? _error;
  bool _saving = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
      _error = null;
    });
    try {
      // 只等持久化完成；热键/监控/自启由 controller 在后台重载（issue #6：
      // 重载环节挂起时 UI 也不能卡在"保存中…"）
      await ref.read(appControllerProvider.notifier).saveSettings(_draft);
      if (mounted) {
        setState(() {
          _saving = false;
          _dirty = false;
          _message = '设置已保存';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败：$e';
        });
      }
    }
  }

  void _markDirty() => setState(() => _dirty = true);

  Future<String> _pickDirectory(String current) async {
    final dir = await getDirectoryPath(initialDirectory: current.isNotEmpty ? current : null);
    return dir ?? current;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save, size: 18),
            label: Text(_saving ? '保存中…' : '保存设置'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_message != null)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(_message!),
              ),
            ),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
              ),
            ),
          _section('日志', [
            _dirField('日志根目录', _draft.logRoot, (v) => _draft.logRoot = v),
            _textField('作者名（署名 + commit 过滤，多个用逗号分隔）',
                _draft.authorName, (v) => _draft.authorName = v),
            _textField('时区（自然日）', _draft.timezone, (v) => _draft.timezone = v),
          ]),
          _section('代码', [
            for (final (i, instance) in _draft.codeInstances.indexed) ...[
              Card(
                child: ListTile(
                  leading: Icon(
                    instance.providerType == 'github'
                        ? Icons.code
                        : Icons.account_tree,
                  ),
                  title: Text(instance.name.isEmpty ? instance.baseUrl : instance.name),
                  subtitle: Text(
                    '${instance.providerType} · ${instance.baseUrl}'
                    '${instance.enabled ? '' : '（已禁用）'}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editInstance(instance),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          setState(() {
                            _draft.codeInstances.removeAt(i);
                            _dirty = true;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
            OutlinedButton.icon(
              onPressed: () => _editInstance(CodeInstance(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                providerType: 'gitlab',
              )),
              icon: const Icon(Icons.add),
              label: const Text('新增代码实例'),
            ),
          ]),
          _section('目录监控', [
            for (final (i, dir) in _draft.watchDirs.indexed)
              ListTile(
                dense: true,
                title: Text(dir),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() {
                      _draft.watchDirs.removeAt(i);
                      _dirty = true;
                    });
                  },
                ),
              ),
            _dirAddField('添加监控目录', (v) {
              if (v.trim().isNotEmpty) {
                setState(() {
                  _draft.watchDirs.add(v.trim());
                  _dirty = true;
                });
              }
            }),
            _textField(
              '排除规则（逗号分隔）',
              _draft.excludePatterns.join(','),
              (v) {
                _draft.excludePatterns =
                    v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                _markDirty();
              },
            ),
          ]),
          _section('音频转录', [
            _dirField('音频目录', _draft.audioDir, (v) => _draft.audioDir = v),
            _textField('转录接口 base_url（OpenAI 兼容）', _draft.transcript.baseUrl,
                (v) => _draft.transcript.baseUrl = v),
            _textField('API Key', _draft.transcript.apiKey,
                (v) => _draft.transcript.apiKey = v),
            _textField('模型', _draft.transcript.model, (v) => _draft.transcript.model = v),
          ]),
          _section('AI', [
            DropdownButtonFormField<String>(
              initialValue: _draft.ai.provider.isEmpty ? null : _draft.ai.provider,
              decoration: const InputDecoration(labelText: '主供应商'),
              items: const [
                DropdownMenuItem(value: 'claude', child: Text('Claude')),
                DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                DropdownMenuItem(value: 'ollama', child: Text('Ollama（本地）')),
              ],
              onChanged: (v) {
                setState(() {
                  _draft.ai.provider = v ?? '';
                  _dirty = true;
                });
              },
            ),
            _textField('备选供应商（逗号分隔，按顺序降级）', _draft.ai.fallback.join(','),
                (v) {
              _draft.ai.fallback =
                  v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              _markDirty();
            }),
            _textField('语气偏好', _draft.ai.tone, (v) => _draft.ai.tone = v),
            _textField('会议内容禁用的供应商（逗号分隔，合规）',
                _draft.ai.conferenceBlocked.join(','), (v) {
              _draft.ai.conferenceBlocked =
                  v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              _markDirty();
            }),
            const Divider(),
            _textField('Claude base_url', _draft.ai.claudeBaseUrl,
                (v) => _draft.ai.claudeBaseUrl = v),
            _textField('Claude API Key', _draft.ai.claudeApiKey,
                (v) => _draft.ai.claudeApiKey = v),
            _textField('Claude 模型', _draft.ai.claudeModel,
                (v) => _draft.ai.claudeModel = v),
            const Divider(),
            _textField('DeepSeek base_url', _draft.ai.deepseekBaseUrl,
                (v) => _draft.ai.deepseekBaseUrl = v),
            _textField('DeepSeek API Key', _draft.ai.deepseekApiKey,
                (v) => _draft.ai.deepseekApiKey = v),
            _textField('DeepSeek 模型', _draft.ai.deepseekModel,
                (v) => _draft.ai.deepseekModel = v),
            const Divider(),
            _textField('Ollama base_url', _draft.ai.ollamaBaseUrl,
                (v) => _draft.ai.ollamaBaseUrl = v),
            _textField('Ollama 模型', _draft.ai.ollamaModel,
                (v) => _draft.ai.ollamaModel = v),
          ]),
          _section('快捷键', [
            Wrap(
              spacing: 8,
              children: [
                for (final m in const ['Ctrl', 'Shift', 'Alt', 'Meta'])
                  FilterChip(
                    label: Text(m),
                    selected: _draft.hotkey.modifiers.contains(m),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _draft.hotkey.modifiers.add(m);
                        } else {
                          _draft.hotkey.modifiers.remove(m);
                        }
                        _dirty = true;
                      });
                    },
                  ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: _draft.hotkey.key,
              decoration: const InputDecoration(labelText: '热键'),
              items: [
                for (final k in _keyOptions) DropdownMenuItem(value: k, child: Text(k)),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _draft.hotkey.key = v;
                    _dirty = true;
                  });
                }
              },
            ),
            SwitchListTile(
              title: const Text('开机自启'),
              value: _draft.hotkey.autoLaunch,
              onChanged: (v) => setState(() {
                _draft.hotkey.autoLaunch = v;
                _dirty = true;
              }),
            ),
          ]),
          _section('通知', [
            _textField('每日生成提醒时间（HH:mm，留空不提醒）',
                _draft.notification.reminderTime, (v) {
              _draft.notification.reminderTime = v;
              _markDirty();
            }),
            SwitchListTile(
              title: const Text('生成完成系统通知'),
              value: _draft.notification.completionNotification,
              onChanged: (v) => setState(() {
                _draft.notification.completionNotification = v;
                _dirty = true;
              }),
            ),
          ]),
          _updateSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static const _keyOptions = [
    'KeyA', 'KeyB', 'KeyC', 'KeyD', 'KeyE', 'KeyF', 'KeyG', 'KeyH', 'KeyI',
    'KeyJ', 'KeyK', 'KeyL', 'KeyM', 'KeyN', 'KeyO', 'KeyP', 'KeyQ', 'KeyR',
    'KeyS', 'KeyT', 'KeyU', 'KeyV', 'KeyW', 'KeyX', 'KeyY', 'KeyZ',
    'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
    'Space', 'Enter', 'Tab', 'Escape',
  ];

  /// 更新区块（issue #5）：当前版本 + 检查更新 + 状态 + 重启并更新 + 自动检查开关
  Widget _updateSection() {
    final updateStatus =
        ref.watch(appControllerProvider.select((s) => s.updateStatus));
    final controller = ref.read(appControllerProvider.notifier);
    final version = controller.updateConfig.appVersion;

    final Widget statusTile;
    switch (updateStatus.phase) {
      case UpdatePhase.checking:
        statusTile = const ListTile(
          leading: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('正在检查更新…'),
        );
      case UpdatePhase.available:
        statusTile = ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: Text('发现新版本 ${updateStatus.version}，准备下载…'),
        );
      case UpdatePhase.downloading:
        final percent =
            ((updateStatus.progress ?? 0) * 100).clamp(0, 100).round();
        statusTile = ListTile(
          leading: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('正在后台下载新版本 ${updateStatus.version}… $percent%'),
        );
      case UpdatePhase.ready:
        statusTile = ListTile(
          leading: const Icon(Icons.download_done, color: Colors.green),
          title: Text('新版本 ${updateStatus.version} 已下载完成'),
          subtitle: const Text('重启软件时自动完成更新'),
        );
      case UpdatePhase.error:
        statusTile = ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(updateStatus.message ?? ''),
        );
      case UpdatePhase.idle:
        statusTile = ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: Text(
            version == null
                ? '当前构建未包含更新源（本地开发构建不参与更新）'
                : '当前版本 v$version',
          ),
        );
    }

    final busy = updateStatus.phase == UpdatePhase.checking ||
        updateStatus.phase == UpdatePhase.downloading;

    return _section('更新', [
      statusTile,
      if (updateStatus.phase == UpdatePhase.ready)
        FilledButton.icon(
          onPressed: () => controller.restartToUpdate(),
          icon: const Icon(Icons.restart_alt),
          label: const Text('重启并更新'),
        )
      else
        OutlinedButton.icon(
          onPressed: busy ? null : () => controller.checkForUpdates(),
          icon: const Icon(Icons.refresh),
          label: Text(busy ? '处理中…' : '检查更新'),
        ),
      SwitchListTile(
        title: const Text('启动时自动检查更新（发现新版自动后台下载）'),
        value: _draft.update.autoCheck,
        onChanged: (v) => setState(() {
          _draft.update.autoCheck = v;
          _dirty = true;
        }),
      ),
    ]);
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          ...children,
          const Divider(),
        ],
      ),
    );
  }

  Widget _textField(String label, String value, void Function(String) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: TextEditingController(text: value),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onChanged: (v) {
          onChanged(v);
          _dirty = true;
        },
      ),
    );
  }

  Widget _dirField(String label, String value, void Function(String) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: TextEditingController(text: value),
              decoration:
                  InputDecoration(labelText: label, border: const OutlineInputBorder()),
              onChanged: (v) {
                onChanged(v);
                _dirty = true;
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '浏览…',
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              final picked = await _pickDirectory(value);
              if (picked.isNotEmpty) {
                onChanged(picked);
                _markDirty();
                // 刷新输入框显示
                if (mounted) setState(() {});
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _dirAddField(String label, void Function(String) onAdd) {
    final controller = TextEditingController();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration:
                  InputDecoration(labelText: label, border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '添加',
            icon: const Icon(Icons.add),
            onPressed: () {
              onAdd(controller.text);
              controller.clear();
            },
          ),
        ],
      ),
    );
  }

  /// 编辑/新增代码实例（含 token）
  Future<void> _editInstance(CodeInstance instance) async {
    final settingsService = ref.read(settingsServiceProvider);
    final token = await settingsService.getToken(instance.id) ?? '';
    final nameCtrl = TextEditingController(text: instance.name);
    final baseCtrl = TextEditingController(text: instance.baseUrl);
    final branchCtrl = TextEditingController(text: instance.defaultBranch);
    final filterCtrl = TextEditingController(text: instance.visibilityFilter);
    final tokenCtrl = TextEditingController(text: token);
    var type = instance.providerType;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(instance.name.isEmpty ? '新增代码实例' : '编辑 ${instance.name}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: '类型'),
                    items: const [
                      DropdownMenuItem(value: 'gitlab', child: Text('GitLab')),
                      DropdownMenuItem(value: 'github', child: Text('GitHub')),
                    ],
                    onChanged: (v) => setDialogState(() => type = v ?? type),
                  ),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '实例名（如 公司 GitLab）'),
                  ),
                  TextField(
                    controller: baseCtrl,
                    decoration: const InputDecoration(
                        labelText: 'base_url（如 https://git.example.com）'),
                  ),
                  TextField(
                    controller: branchCtrl,
                    decoration: const InputDecoration(labelText: '默认分支（留空用仓库默认）'),
                  ),
                  TextField(
                    controller: filterCtrl,
                    decoration: const InputDecoration(
                        labelText: '可见性过滤（gitlab: private/internal/public；github: private/public）'),
                  ),
                  TextField(
                    controller: tokenCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Token（存入系统密钥库）'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (baseCtrl.text.trim().isEmpty) {
                  return;
                }
                // providerType 是 final：整体重建
                final updated = CodeInstance(
                  id: instance.id,
                  providerType: type,
                  name: nameCtrl.text.trim(),
                  baseUrl: baseCtrl.text.trim(),
                  defaultBranch: branchCtrl.text.trim(),
                  enabled: instance.enabled,
                  visibilityFilter: filterCtrl.text.trim(),
                );
                final settingsService = ref.read(settingsServiceProvider);
                await settingsService.setToken(instance.id, tokenCtrl.text.trim());
                setState(() {
                  final idx = _draft.codeInstances.indexWhere((c) => c.id == instance.id);
                  if (idx >= 0) {
                    _draft.codeInstances[idx] = updated;
                  } else {
                    _draft.codeInstances.add(updated);
                  }
                  _dirty = true;
                });
                navigator.pop();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
