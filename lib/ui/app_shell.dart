import 'dart:async';

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
  bool _closeDialogOpen = false;
  bool? _preventClose;
  late final AppController _controller;

  @override
  void initState() {
    super.initState();
    _controller = context.read<AppController>();
    _controller.addListener(_syncCloseProtection);
    windowManager.addListener(this);
    _syncCloseProtection();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding());
  }

  @override
  void dispose() {
    _controller.removeListener(_syncCloseProtection);
    windowManager.removeListener(this);
    super.dispose();
  }

  void _syncCloseProtection() {
    final shouldPreventClose = _controller.hasActiveWork;
    if (_preventClose == shouldPreventClose) return;
    _preventClose = shouldPreventClose;
    unawaited(windowManager.setPreventClose(shouldPreventClose));
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
    final controller = _controller;
    if (!controller.hasActiveWork) {
      await windowManager.destroy();
      return;
    }
    if (!mounted || _closeDialogOpen) return;
    _closeDialogOpen = true;
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
    _closeDialogOpen = false;
    if (choice == null || choice == 0) return;
    if (choice == 2) await controller.cancelRemoteJobsForQuit();
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

  void _toggleSidebar() {
    setState(() => _sidebarVisible = !_sidebarVisible);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
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
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            controller.startReady,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            controller.startReady,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              AppWindowToolbar(
                sidebarVisible: _sidebarVisible,
                onToggleSidebar: _toggleSidebar,
              ),
              Expanded(
                child: Row(
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
                                    onDestinationSelected:
                                        controller.setDestination,
                                    extended:
                                        MediaQuery.sizeOf(context).width >=
                                        1180,
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
                            : const SizedBox.shrink(
                                key: Key('app-sidebar-hidden'),
                              ),
                      ),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: switch (controller.destinationIndex) {
                          1 => const LibraryPage(key: ValueKey('library')),
                          2 => const SettingsPage(key: ValueKey('settings')),
                          _ => WorkspacePage(
                            key: const ValueKey('workspace'),
                            onAddFiles: _addFiles,
                            onAddFolder: _addFolder,
                          ),
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppWindowToolbar extends StatefulWidget {
  const AppWindowToolbar({
    super.key,
    required this.sidebarVisible,
    required this.onToggleSidebar,
  });

  static const macOSHeight = 32.0;
  static const macOSControlHeight = 32.0;
  static const windowsHeight = 40.0;

  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;

  @override
  State<AppWindowToolbar> createState() => _AppWindowToolbarState();
}

class _AppWindowToolbarState extends State<AppWindowToolbar>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final windows = platform == TargetPlatform.windows;
    final macOS = platform == TargetPlatform.macOS;
    final height = macOS
        ? AppWindowToolbar.macOSHeight
        : AppWindowToolbar.windowsHeight;
    final controlHeight = macOS
        ? AppWindowToolbar.macOSControlHeight
        : AppWindowToolbar.windowsHeight;
    final brightness = Theme.of(context).brightness;
    return DecoratedBox(
      key: const Key('app-window-toolbar'),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: macOS
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            if (macOS)
              const SizedBox(key: Key('macos-traffic-light-space'), width: 72),
            if (windows) ...[
              Padding(
                key: const Key('windows-app-icon'),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Image.asset(
                  'assets/branding/meowstt-icon.png',
                  width: 20,
                  height: 20,
                ),
              ),
            ],
            IconButton(
              key: const Key('toggle-app-sidebar'),
              tooltip: context.strings.t(
                widget.sidebarVisible ? 'hide_sidebar' : 'show_sidebar',
              ),
              onPressed: widget.onToggleSidebar,
              icon: Icon(
                widget.sidebarVisible
                    ? Icons.menu_open_rounded
                    : Icons.menu_rounded,
              ),
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(
                width: 40,
                height: controlHeight,
              ),
            ),
            const SizedBox(width: 4),
            const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
            if (windows) ...[
              Tooltip(
                message: context.strings.t('minimize_window'),
                child: WindowCaptionButton.minimize(
                  key: const Key('window-minimize'),
                  brightness: brightness,
                  onPressed: () => unawaited(windowManager.minimize()),
                ),
              ),
              Tooltip(
                message: context.strings.t(
                  _maximized ? 'restore_window' : 'maximize_window',
                ),
                child: _maximized
                    ? WindowCaptionButton.unmaximize(
                        key: const Key('window-restore'),
                        brightness: brightness,
                        onPressed: () => unawaited(windowManager.unmaximize()),
                      )
                    : WindowCaptionButton.maximize(
                        key: const Key('window-maximize'),
                        brightness: brightness,
                        onPressed: () => unawaited(windowManager.maximize()),
                      ),
              ),
              Tooltip(
                message: context.strings.t('close_window'),
                child: WindowCaptionButton.close(
                  key: const Key('window-close'),
                  brightness: brightness,
                  onPressed: () => unawaited(windowManager.close()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
