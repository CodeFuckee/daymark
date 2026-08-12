/// 主窗口框架：导航（日报 / 聚合报告 / 设置）+ 顶部操作区。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'pages/aggregate_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';

enum _Tab { daily, aggregate, settings }

class MainWindow extends ConsumerStatefulWidget {
  const MainWindow({super.key});

  @override
  ConsumerState<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends ConsumerState<MainWindow> {
  _Tab _tab = _Tab.daily;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tab.index,
            onDestinationSelected: (i) => setState(() => _tab = _Tab.values[i]),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.today_outlined),
                selectedIcon: Icon(Icons.today),
                label: Text('日报'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: Text('周/月报'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                _TopBar(controller: controller, showSetup: !state.settingsLoaded),
                Expanded(
                  child: switch (_tab) {
                    _Tab.daily => const HomePage(),
                    _Tab.aggregate => const AggregatePage(),
                    _Tab.settings => const SettingsPage(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部操作栏：新建记录 / 状态提示
class _TopBar extends ConsumerWidget {
  final AppController controller;
  final bool showSetup;

  const _TopBar({required this.controller, required this.showSetup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          Text(
            'Daymark',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(width: 16),
          if (state.hotkeyError != null) ...[
            Icon(Icons.warning_amber, size: 18, color: Colors.orange.shade800),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                state.hotkeyError!,
                style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          if (showSetup)
            const Text('正在加载设置…', style: TextStyle(color: Colors.grey)),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => controller.openQuickNote(),
            icon: const Icon(Icons.edit_note, size: 18),
            label: const Text('新建记录'),
          ),
        ],
      ),
    );
  }
}
