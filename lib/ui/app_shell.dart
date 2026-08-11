import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'workspace_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  bool _onboardingShown = false;
  bool _sidebarVisible = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _showOnboarding() async {
    if (!mounted || _onboardingShown) return;
    final controller = context.read<AppController>();
    if (controller.settings.onboardingComplete) return;
    _onboardingShown = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: Image.asset(
          'assets/branding/meowstt-icon.png',
          width: 72,
          height: 72,
        ),
        title: Text(context.strings.t('welcome_title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(context.strings.t('welcome_body')),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.t('continue')),
          ),
        ],
      ),
    );
    await controller.updateSettings(
      controller.settings.copyWith(onboardingComplete: true),
    );
  }

  @override
  Future<void> onWindowClose() async {
    final controller = context.read<AppController>();
    if (!controller.hasActiveWork) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      return;
    }
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cloud_sync_outlined),
        title: Text(context.strings.t('quit_title')),
        content: Text(context.strings.t('quit_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 0),
            child: Text(context.strings.t('stay')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 2),
            child: Text(context.strings.t('cancel_quit')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 1),
            child: Text(context.strings.t('quit_resume')),
          ),
        ],
      ),
    );
    if (choice == null || choice == 0) return;
    if (choice == 2) await controller.cancelRemoteJobsForQuit();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> _addFiles() async {
    final media = XTypeGroup(
      label: context.strings.t('audio_video'),
      extensions: const [
        'aac',
        'aiff',
        'amr',
        'asf',
        'flac',
        'mp3',
        'ogg',
        'wav',
        'webm',
        'm4a',
        'mp4',
        'mov',
        'mkv',
        'avi',
        'wmv',
        'm4v',
        'mpeg',
        'mpg',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: [media]);
    if (files.isNotEmpty && mounted) {
      await context.read<AppController>().addSources(
        files.map((file) => file.path),
      );
    }
  }

  Future<void> _addFolder() async {
    final directory = await getDirectoryPath();
    if (directory != null && mounted) {
      await context.read<AppController>().addSources([directory]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final sidebarToggle = IconButton(
      key: const Key('toggle-app-sidebar'),
      tooltip: context.strings.t(
        _sidebarVisible ? 'hide_sidebar' : 'show_sidebar',
      ),
      onPressed: () => setState(() => _sidebarVisible = !_sidebarVisible),
      icon: Icon(
        _sidebarVisible ? Icons.menu_open_rounded : Icons.menu_rounded,
      ),
    );
    final destinations = [
      NavigationRailDestination(
        icon: const Icon(Icons.space_dashboard_outlined),
        selectedIcon: const Icon(Icons.space_dashboard_rounded),
        label: Text(context.strings.t('workspace')),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.library_books_outlined),
        selectedIcon: const Icon(Icons.library_books_rounded),
        label: Text(context.strings.t('library')),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.tune_outlined),
        selectedIcon: const Icon(Icons.tune_rounded),
        label: Text(context.strings.t('settings')),
      ),
    ];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _addFiles,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _addFiles,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            controller.startReady,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            controller.startReady,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              ClipRect(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeInOut,
                  alignment: Alignment.centerLeft,
                  child: _sidebarVisible
                      ? Row(
                          key: const Key('app-sidebar'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            NavigationRail(
                              minWidth: 64,
                              minExtendedWidth: 184,
                              selectedIndex: controller.destinationIndex,
                              onDestinationSelected: controller.setDestination,
                              extended:
                                  MediaQuery.sizeOf(context).width >= 1180,
                              leading: Padding(
                                padding: const EdgeInsets.only(
                                  top: 10,
                                  bottom: 14,
                                ),
                                child: Tooltip(
                                  message: 'MeowSTT',
                                  child: Image.asset(
                                    'assets/branding/meowstt-icon.png',
                                    width: 38,
                                    height: 38,
                                  ),
                                ),
                              ),
                              destinations: destinations,
                            ),
                            const VerticalDivider(width: 1),
                          ],
                        )
                      : const SizedBox.shrink(key: Key('app-sidebar-hidden')),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: switch (controller.destinationIndex) {
                    1 => LibraryPage(
                      key: const ValueKey('library'),
                      sidebarToggle: sidebarToggle,
                    ),
                    2 => SettingsPage(
                      key: const ValueKey('settings'),
                      sidebarToggle: sidebarToggle,
                    ),
                    _ => WorkspacePage(
                      key: const ValueKey('workspace'),
                      onAddFiles: _addFiles,
                      onAddFolder: _addFolder,
                      sidebarToggle: sidebarToggle,
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
