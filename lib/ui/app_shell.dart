import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../data/update_service.dart';
import '../state/app_controller.dart';
import 'inbox_page.dart';
import 'library_page.dart';
import 'review_fullscreen_controller.dart';
import 'settings_page.dart';
import 'workspace_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.reviewController});

  final ReviewFullscreenController? reviewController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  static const _nativeNavigationChannel = MethodChannel(
    'app.meowstt.desktop/navigation',
  );
  static const _compactSidebarWidth = 64.0;
  static const _extendedSidebarWidth = 184.0;

  bool _onboardingShown = false;
  bool _sidebarVisible = true;
  bool _closeDialogOpen = false;
  bool _windowClosing = false;
  bool _windowFullscreen = false;
  late final ReviewFullscreenController _fullscreenController;
  late final AppController _controller;
  UpdateService? _updates;

  @override
  void initState() {
    super.initState();
    _fullscreenController =
        widget.reviewController ?? ReviewFullscreenController();
    _controller = context.read<AppController>();
    _updates = Provider.of<UpdateService?>(context, listen: false);
    windowManager.addListener(this);
    _nativeNavigationChannel.setMethodCallHandler(_handleNativeNavigation);
    unawaited(windowManager.setPreventClose(true));
    unawaited(_syncWindowFullscreen());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOnboarding();
      unawaited(_updates?.start());
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _nativeNavigationChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _handleNativeNavigation(MethodCall call) async {
    if (call.method == 'showSettings') {
      await _setDestination(AppDestination.settings);
      return null;
    }
    throw MissingPluginException('Unknown native navigation: ${call.method}');
  }

  Future<void> _syncWindowFullscreen() async {
    try {
      _setWindowFullscreen(await windowManager.isFullScreen());
    } on Object {
      // The window channel is unavailable in widget tests and early startup.
    }
  }

  void _setWindowFullscreen(bool value) {
    if (!mounted || _windowFullscreen == value) return;
    setState(() => _windowFullscreen = value);
  }

  @override
  void onWindowEnterFullScreen() => _setWindowFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => _setWindowFullscreen(false);

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
      await _destroyWindow();
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
    await _destroyWindow();
  }

  Future<void> _destroyWindow() async {
    if (_windowClosing) return;
    _windowClosing = true;
    _updates?.shutdown();
    try {
      await _fullscreenController.exit();
      await _fullscreenController.shutdownMedia();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object {
      _windowClosing = false;
      rethrow;
    }
  }

  Future<void> _restartForUpdate(UpdateService updates) async {
    if (_controller.hasActiveWork) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.restart_alt_rounded),
          title: Text(context.strings.t('update_active_title')),
          content: Text(context.strings.t('update_active_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.t('restart_to_update')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      await updates.installReadyUpdate();
      await _destroyWindow();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${context.strings.t('update_restart_failed')} $error'),
        ),
      );
    }
  }

  Future<void> _setDestination(AppDestination destination) async {
    await _fullscreenController.exit();
    if (mounted) _controller.setDestination(destination);
  }

  Future<void> _addFiles() async {
    final media = XTypeGroup(
      label: context.strings.t('audio_video'),
      extensions: const ['mp3', 'wav', 'm4a', 'ogg', 'mp4', 'mkv', 'avi'],
    );
    final files = await openFiles(acceptedTypeGroups: [media]);
    if (files.isNotEmpty && mounted) {
      final controller = context.read<AppController>();
      await controller.enqueueSources(files.map((file) => file.path));
      if (mounted) controller.setDestination(AppDestination.inbox);
    }
  }

  Future<void> _importFolder() async {
    final directory = await getDirectoryPath();
    if (directory != null && mounted) {
      final controller = context.read<AppController>();
      await controller.enqueueSources([directory]);
      if (mounted) controller.setDestination(AppDestination.inbox);
    }
  }

  void _toggleSidebar() {
    setState(() => _sidebarVisible = !_sidebarVisible);
  }

  String _shortcutTooltip(BuildContext context, String label, String key) {
    final modifier = Theme.of(context).platform == TargetPlatform.macOS
        ? '⌘'
        : 'Ctrl+';
    return '$label ($modifier$key)';
  }

  NavigationRailDestination _destination({
    required BuildContext context,
    required String labelKey,
    required String shortcutKey,
    required IconData icon,
    required IconData selectedIcon,
  }) {
    final label = context.strings.t(labelKey);
    final tooltip = _shortcutTooltip(context, label, shortcutKey);
    return NavigationRailDestination(
      icon: Tooltip(message: tooltip, child: Icon(icon)),
      selectedIcon: Tooltip(message: tooltip, child: Icon(selectedIcon)),
      label: Tooltip(
        message: tooltip,
        child: Text(
          label,
          key: ValueKey('$labelKey-navigation-label'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: Theme.of(context).textTheme.bodyLarge?.fontSize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final updates = context.watch<UpdateService?>();
    final hideWindowToolbar =
        _windowFullscreen && Theme.of(context).platform == TargetPlatform.macOS;
    final sidebarExtended = MediaQuery.sizeOf(context).width >= 1180;
    final destinations = [
      _destination(
        context: context,
        labelKey: 'inbox',
        shortcutKey: '1',
        icon: Icons.inbox_outlined,
        selectedIcon: Icons.inbox_rounded,
      ),
      _destination(
        context: context,
        labelKey: 'workspace',
        shortcutKey: '2',
        icon: Icons.space_dashboard_outlined,
        selectedIcon: Icons.space_dashboard_rounded,
      ),
      _destination(
        context: context,
        labelKey: 'library',
        shortcutKey: '3',
        icon: Icons.library_books_outlined,
        selectedIcon: Icons.library_books_rounded,
      ),
    ];
    final settingsLabel = context.strings.t('settings');
    final settingsTooltip = _shortcutTooltip(context, settingsLabel, ',');
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            _setDestination(AppDestination.inbox),
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            _setDestination(AppDestination.inbox),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            _setDestination(AppDestination.workspace),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            _setDestination(AppDestination.workspace),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            _setDestination(AppDestination.library),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
            _setDestination(AppDestination.library),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            _setDestination(AppDestination.settings),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            _setDestination(AppDestination.settings),
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _addFiles,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _addFiles,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (controller.destination == AppDestination.inbox) {
            unawaited(controller.startReady());
          }
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (controller.destination == AppDestination.inbox) {
            unawaited(controller.startReady());
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              if (hideWindowToolbar)
                const SizedBox.shrink(
                  key: Key('app-window-toolbar-fullscreen-hidden'),
                )
              else
                AppWindowToolbar(
                  sidebarVisible: _sidebarVisible,
                  onToggleSidebar: _toggleSidebar,
                ),
              if (updates?.readyToRestart == true)
                UpdateReadyBanner(
                  version: updates!.release!.version.name,
                  installing: updates.phase == UpdatePhase.installing,
                  onRestart: () => unawaited(_restartForUpdate(updates)),
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
                                  SizedBox(
                                    width: sidebarExtended
                                        ? _extendedSidebarWidth
                                        : _compactSidebarWidth,
                                    child: NavigationRail(
                                      minWidth: _compactSidebarWidth,
                                      minExtendedWidth: _extendedSidebarWidth,
                                      selectedIndex:
                                          switch (controller.destination) {
                                            AppDestination.inbox => 0,
                                            AppDestination.workspace => 1,
                                            AppDestination.library => 2,
                                            AppDestination.settings => null,
                                          },
                                      onDestinationSelected: (index) =>
                                          unawaited(
                                            _setDestination(
                                              AppDestination.values[index],
                                            ),
                                          ),
                                      extended: sidebarExtended,
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
                                      trailingAtBottom: true,
                                      trailing: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: _NavigationRailAction(
                                          key: const Key(
                                            'settings-navigation-button',
                                          ),
                                          extended: sidebarExtended,
                                          compactWidth: _compactSidebarWidth,
                                          extendedWidth: _extendedSidebarWidth,
                                          selected:
                                              controller.destination ==
                                              AppDestination.settings,
                                          label: settingsLabel,
                                          tooltip: settingsTooltip,
                                          icon: Icons.settings_outlined,
                                          selectedIcon: Icons.settings_rounded,
                                          onPressed: () => unawaited(
                                            _setDestination(
                                              AppDestination.settings,
                                            ),
                                          ),
                                        ),
                                      ),
                                      destinations: destinations,
                                    ),
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
                        child: switch (controller.destination) {
                          AppDestination.inbox => InboxPage(
                            key: const ValueKey('inbox'),
                            onAddFiles: _addFiles,
                            onImportFolder: _importFolder,
                          ),
                          AppDestination.workspace => WorkspacePage(
                            key: const ValueKey('workspace'),
                            fullscreenController: _fullscreenController,
                          ),
                          AppDestination.library => const LibraryPage(
                            key: ValueKey('library'),
                          ),
                          AppDestination.settings => const SettingsPage(
                            key: ValueKey('settings'),
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

class UpdateReadyBanner extends StatelessWidget {
  const UpdateReadyBanner({
    super.key,
    required this.version,
    required this.installing,
    required this.onRestart,
  });

  final String version;
  final bool installing;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('update-ready-banner'),
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update_alt_rounded,
              color: colors.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.strings
                    .t('update_ready')
                    .replaceFirst('{version}', version),
                style: TextStyle(color: colors.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              key: const Key('restart-to-update'),
              onPressed: installing ? null : onRestart,
              icon: installing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt_rounded),
              label: Text(
                context.strings.t(
                  installing ? 'restarting_to_update' : 'restart_to_update',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationRailAction extends StatefulWidget {
  const _NavigationRailAction({
    super.key,
    required this.extended,
    required this.compactWidth,
    required this.extendedWidth,
    required this.selected,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.selectedIcon,
    required this.onPressed,
  });

  final bool extended;
  final double compactWidth;
  final double extendedWidth;
  final bool selected;
  final String label;
  final String tooltip;
  final IconData icon;
  final IconData selectedIcon;
  final VoidCallback onPressed;

  @override
  State<_NavigationRailAction> createState() => _NavigationRailActionState();
}

class _NavigationRailActionState extends State<_NavigationRailAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onPressed,
            onHover: (hovered) => setState(() => _hovered = hovered),
            hoverColor: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            child: SizedBox(
              width: widget.extended
                  ? widget.extendedWidth
                  : widget.compactWidth,
              height: 56,
              child: Row(
                children: [
                  SizedBox(
                    width: widget.compactWidth,
                    child: Center(
                      child: AnimatedContainer(
                        key: const Key('settings-navigation-indicator'),
                        duration: kThemeAnimationDuration,
                        width: 56,
                        height: 32,
                        decoration: BoxDecoration(
                          color: widget.selected
                              ? colors.primaryContainer
                              : _hovered
                              ? colors.primary.withValues(alpha: .04)
                              : null,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          widget.selected ? widget.selectedIcon : widget.icon,
                          color: widget.selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  if (widget.extended)
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: widget.selected
                              ? colors.primary
                              : colors.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
    final shortcutModifier = macOS ? '⌘' : 'Ctrl+';
    final sidebarTooltip = context.strings.t(
      widget.sidebarVisible ? 'hide_sidebar' : 'show_sidebar',
    );
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
              tooltip: '$sidebarTooltip (${shortcutModifier}B)',
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
