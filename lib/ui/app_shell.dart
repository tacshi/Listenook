import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../core/models.dart';
import '../data/desktop_runtime.dart';
import '../l10n/strings.dart';
import '../data/update_service.dart';
import '../state/app_controller.dart';
import '../state/podcast_controller.dart';
import '../state/podcast_player.dart';
import 'inbox_page.dart';
import 'library_page.dart';
import 'podcast_mini_bar.dart';
import 'podcast_page.dart';
import 'review_fullscreen_controller.dart';
import 'settings_page.dart';
import 'workspace_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.reviewController});

  final ReviewFullscreenController? reviewController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WindowListener, tray.TrayListener, WidgetsBindingObserver {
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
  bool _windowHidden = false;
  bool _trayReady = false;
  String? _lastTraySignature;
  Timer? _traySyncTimer;
  Timer? _notificationTimer;
  int _pendingDiscoveries = 0;
  Set<String> _knownMonitoredJobs = const {};
  late final ReviewFullscreenController _fullscreenController;
  late final AppController _controller;
  DesktopRuntime? _desktopRuntime;
  UpdateService? _updates;

  @override
  void initState() {
    super.initState();
    _fullscreenController =
        widget.reviewController ?? ReviewFullscreenController();
    _controller = context.read<AppController>();
    _desktopRuntime = Provider.of<DesktopRuntime?>(context, listen: false);
    _updates = Provider.of<UpdateService?>(context, listen: false);
    _knownMonitoredJobs = _monitoredJobIds();
    _controller.addListener(_handleControllerChange);
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    tray.trayManager.addListener(this);
    _nativeNavigationChannel.setMethodCallHandler(_handleNativeNavigation);
    unawaited(windowManager.setPreventClose(true));
    unawaited(_syncWindowFullscreen());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOnboarding();
      unawaited(_updates?.start());
      unawaited(_initializeDesktopRuntime());
      _scheduleTraySync();
    });
  }

  @override
  void dispose() {
    _traySyncTimer?.cancel();
    _notificationTimer?.cancel();
    _controller.removeListener(_handleControllerChange);
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    tray.trayManager.removeListener(this);
    _nativeNavigationChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _handleNativeNavigation(MethodCall call) async {
    if (call.method == 'showInbox') {
      await _restoreInbox();
      return null;
    }
    if (call.method == 'showWindow') {
      await _showAndFocusWindow();
      return null;
    }
    if (call.method == 'showSettings') {
      await _restoreWindow(AppDestination.settings);
      return null;
    }
    if (call.method == 'requestQuit') {
      await _requestQuit();
      return null;
    }
    throw MissingPluginException('Unknown native navigation: ${call.method}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _controller.inboxMonitorConfigured) {
      unawaited(_controller.rescanInboxMonitor());
    }
  }

  Set<String> _monitoredJobIds() => _controller.inboxJobs
      .where((job) => job.sourceOrigin == JobSourceOrigin.monitoredFolder)
      .map((job) => job.id)
      .toSet();

  void _handleControllerChange() {
    if (!mounted) return;
    final current = _monitoredJobIds();
    final discovered = current.difference(_knownMonitoredJobs).length;
    _knownMonitoredJobs = current;
    if (discovered > 0 && _windowHidden) {
      _pendingDiscoveries += discovered;
      _notificationTimer?.cancel();
      _notificationTimer = Timer(
        const Duration(seconds: 1),
        _showDiscoveryNotification,
      );
    }
    _scheduleTraySync();
    _pausePodcastInWorkspace();
  }

  void _pausePodcastInWorkspace() {
    if (_controller.destination != AppDestination.workspace) return;
    final player = _podcastController(listen: false)?.playback;
    if (player == null || !player.playing) return;
    unawaited(player.pause());
  }

  Future<void> _initializeDesktopRuntime() async {
    await _desktopRuntime?.initialize(onNotificationSelected: _restoreInbox);
    try {
      _windowHidden = !await windowManager.isVisible();
    } on Object {
      // The window channel is unavailable in widget tests.
    }
  }

  void _scheduleTraySync() {
    _traySyncTimer?.cancel();
    _traySyncTimer = Timer(const Duration(milliseconds: 100), _syncTray);
  }

  Future<void> _syncTray() async {
    if (!mounted) return;
    final controller = _controller;
    final strings = context.strings;
    if (!controller.inboxMonitorConfig.showTrayIcon) {
      if (_trayReady) {
        try {
          await tray.trayManager.destroy();
        } on Object {
          // Desktop plugins are intentionally unavailable in widget tests.
        }
      }
      _trayReady = false;
      _lastTraySignature = null;
      return;
    }
    final config = controller.inboxMonitorConfig;
    final signature = <Object?>[
      config.folderPath,
      config.paused,
      controller.inboxMonitorStatus,
      controller.monitoredWaitingCount,
      strings.isZh,
    ].join('|');
    if (_trayReady && signature == _lastTraySignature) return;
    _lastTraySignature = signature;
    final configured = controller.inboxMonitorConfigured;
    final folder = configured ? p.basename(config.folderPath) : '';
    final status = switch (controller.inboxMonitorStatus) {
      InboxMonitorStatus.scanning => strings.t('inbox_monitor_scanning'),
      InboxMonitorStatus.paused => strings.t('inbox_monitor_paused'),
      InboxMonitorStatus.unconfigured => strings.t(
        'inbox_monitor_not_configured',
      ),
      InboxMonitorStatus.unavailable => strings.t('inbox_monitor_unavailable'),
      InboxMonitorStatus.error => strings.t('inbox_monitor_error'),
      _ => strings.t('inbox_monitor_active'),
    };
    try {
      if (!_trayReady) {
        await tray.trayManager.setIcon(
          Platform.isWindows
              ? 'assets/branding/tray/meowstt-tray.ico'
              : 'assets/branding/tray/meowstt-tray-template.png',
          isTemplate: Platform.isMacOS,
          iconSize: 18,
        );
        await tray.trayManager.setToolTip('MeowSTT');
      }
      await tray.trayManager.setContextMenu(
        tray.Menu(
          items: [
            tray.MenuItem(
              key: 'status',
              label: configured
                  ? '$folder · $status · ${controller.monitoredWaitingCount} ${strings.t('inbox')}'
                  : status,
              disabled: true,
            ),
            tray.MenuItem.separator(),
            tray.MenuItem(
              key: 'open-inbox',
              label: strings.t('tray_open_inbox'),
            ),
            if (configured)
              tray.MenuItem(
                key: 'toggle-monitor',
                label: strings.t(
                  config.paused
                      ? 'inbox_monitor_resume'
                      : 'inbox_monitor_pause',
                ),
              ),
            tray.MenuItem(
              key: 'settings',
              label: strings.t('tray_open_settings'),
            ),
            tray.MenuItem.separator(),
            tray.MenuItem(key: 'quit', label: strings.t('tray_quit')),
          ],
        ),
      );
      _trayReady = true;
    } on Object {
      _trayReady = false;
    }
  }

  Future<void> _showDiscoveryNotification() async {
    if (!_windowHidden || _pendingDiscoveries == 0 || !mounted) return;
    final count = _pendingDiscoveries;
    _pendingDiscoveries = 0;
    await _desktopRuntime?.showDiscoveryNotification(
      title: context.strings.t('monitor_notification_title'),
      body: context.strings
          .t('monitor_notification_body')
          .replaceFirst('{count}', '$count'),
    );
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      unawaited(_restoreInbox());
    } else {
      unawaited(tray.trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open-inbox':
        unawaited(_restoreInbox());
        return;
      case 'toggle-monitor':
        unawaited(
          _controller.setInboxMonitorPaused(
            !_controller.inboxMonitorConfig.paused,
          ),
        );
        return;
      case 'settings':
        unawaited(_restoreWindow(AppDestination.settings));
        return;
      case 'quit':
        unawaited(_requestQuit());
        return;
    }
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
    if (_controller.inboxMonitorConfig.showTrayIcon) {
      await _hideToTray();
      return;
    }
    await _requestQuit();
  }

  Future<void> _hideToTray() async {
    try {
      await _fullscreenController.exit();
      await _fullscreenController.shutdownMedia();
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      _windowHidden = true;
      _scheduleTraySync();
    } on Object {
      // The window channel is unavailable in widget tests.
    }
  }

  Future<void> _restoreInbox() => _restoreWindow(AppDestination.inbox);

  Future<void> _restoreWindow(AppDestination destination) async {
    await _setDestination(destination);
    await _showAndFocusWindow();
  }

  Future<void> _showAndFocusWindow() async {
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
      _windowHidden = false;
    } on Object {
      // The window channel is unavailable in widget tests.
    }
  }

  Future<void> _requestQuit() async {
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
      if (_trayReady) {
        try {
          await tray.trayManager.destroy();
        } on Object {
          // Desktop plugins are intentionally unavailable in widget tests.
        }
      }
      await _podcastController(listen: false)?.shutdown();
      await _controller.shutdown();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
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

  PodcastController? _podcastController({bool listen = true}) {
    try {
      return Provider.of<PodcastController>(context, listen: listen);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _setDestination(AppDestination destination) async {
    final player = destination == AppDestination.workspace
        ? _podcastController(listen: false)?.playback
        : null;
    await _fullscreenController.exit();
    if (destination == AppDestination.workspace) {
      await player?.pause();
    }
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

  void _openPlayingEpisode(PodcastController podcast, AppController app) {
    final player = podcast.playback;
    final episode = player.episode;
    final feed = player.feed;
    player.collapse();
    if (episode == null || feed == null) return;
    unawaited(podcast.revealPlayingEpisode(episode, feed));
    app.setDestination(AppDestination.podcast);
  }

  void _bindCompletedPodcastTranscript(
    PodcastController podcast,
    AppController app,
  ) {
    final player = podcast.playback;
    final episode = player.episode;
    if (episode == null) return;
    final job = app.jobForEpisode(episode.id);
    final document = job?.status == JobStatus.completed ? job?.document : null;
    if (document == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      player.applyDocument(document);
    });
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

  Widget _inboxFab(BuildContext context, {required bool extended}) {
    final label = context.strings.t('inbox');
    final tooltip = _shortcutTooltip(context, label, 'I');
    final colors = Theme.of(context).colorScheme;
    void openInbox() => unawaited(_setDestination(AppDestination.inbox));
    if (extended) {
      return FloatingActionButtonTheme(
        data: FloatingActionButtonTheme.of(context).copyWith(
          extendedSizeConstraints: const BoxConstraints.tightFor(height: 44),
        ),
        child: FloatingActionButton.extended(
          key: const Key('inbox-fab'),
          heroTag: 'inbox-fab',
          tooltip: tooltip,
          onPressed: openInbox,
          backgroundColor: colors.surfaceContainerHighest,
          foregroundColor: colors.primary,
          elevation: 0,
          focusElevation: 1,
          hoverElevation: 2,
          highlightElevation: 1,
          icon: const Icon(Icons.inbox_rounded),
          label: Text(label),
        ),
      );
    }
    return FloatingActionButton.small(
      key: const Key('inbox-fab'),
      heroTag: 'inbox-fab',
      tooltip: tooltip,
      onPressed: openInbox,
      backgroundColor: colors.surfaceContainerHighest,
      foregroundColor: colors.primary,
      elevation: 0,
      focusElevation: 1,
      hoverElevation: 2,
      highlightElevation: 1,
      child: const Icon(Icons.inbox_rounded),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final updates = context.watch<UpdateService?>();
    final podcast = _podcastController();
    final player = podcast?.playback;
    if (podcast != null && player != null) {
      _bindCompletedPodcastTranscript(podcast, controller);
      if (player.expanded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openPlayingEpisode(podcast, controller);
        });
      }
    }
    final hideWindowToolbar =
        _windowFullscreen && Theme.of(context).platform == TargetPlatform.macOS;
    final sidebarExtended = MediaQuery.sizeOf(context).width >= 1180;
    const primaryDestinations = [
      AppDestination.podcast,
      AppDestination.workspace,
      AppDestination.library,
    ];
    final destinations = [
      _destination(
        context: context,
        labelKey: 'podcast',
        shortcutKey: '1',
        icon: Icons.podcasts_outlined,
        selectedIcon: Icons.podcasts_rounded,
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
    return PodcastPlaybackShortcuts(
      player: player,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
              _setDestination(AppDestination.inbox),
          const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
              _setDestination(AppDestination.inbox),
          const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
              _setDestination(AppDestination.podcast),
          const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
              _setDestination(AppDestination.podcast),
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
                    updateVersion: updates?.readyToRestart == true
                        ? updates!.release!.version.name
                        : null,
                    updateInstalling: updates?.phase == UpdatePhase.installing,
                    onRestartUpdate: updates?.readyToRestart == true
                        ? () => unawaited(_restartForUpdate(updates!))
                        : null,
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
                                    AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      curve: Curves.easeInOut,
                                      width: sidebarExtended
                                          ? _extendedSidebarWidth
                                          : _compactSidebarWidth,
                                      child: NavigationRail(
                                        minWidth: _compactSidebarWidth,
                                        minExtendedWidth: _extendedSidebarWidth,
                                        selectedIndex:
                                            switch (controller.destination) {
                                              AppDestination.podcast => 0,
                                              AppDestination.workspace => 1,
                                              AppDestination.library => 2,
                                              AppDestination.inbox ||
                                              AppDestination.settings => null,
                                            },
                                        onDestinationSelected: (index) =>
                                            unawaited(
                                              _setDestination(
                                                primaryDestinations[index],
                                              ),
                                            ),
                                        extended: sidebarExtended,
                                        leading: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 10,
                                                bottom: 12,
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
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 14,
                                              ),
                                              child: _inboxFab(
                                                context,
                                                extended: sidebarExtended,
                                              ),
                                            ),
                                          ],
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
                                            extendedWidth:
                                                _extendedSidebarWidth,
                                            selected:
                                                controller.destination ==
                                                AppDestination.settings,
                                            label: settingsLabel,
                                            tooltip: settingsTooltip,
                                            icon: Icons.settings_outlined,
                                            selectedIcon:
                                                Icons.settings_rounded,
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
                        child: Column(
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                child: switch (controller.destination) {
                                  AppDestination.inbox => InboxPage(
                                    key: const ValueKey('inbox'),
                                    onAddFiles: _addFiles,
                                    onImportFolder: _importFolder,
                                  ),
                                  AppDestination.podcast =>
                                    podcast == null
                                        ? const SizedBox.expand(
                                            key: ValueKey(
                                              'podcast-unavailable',
                                            ),
                                          )
                                        : const PodcastPage(
                                            key: ValueKey('podcast'),
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
                            if (player?.hasSession == true &&
                                controller.destination !=
                                    AppDestination.workspace)
                              const PodcastMiniBar(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PodcastPlaybackShortcuts extends StatelessWidget {
  const PodcastPlaybackShortcuts({
    super.key,
    required this.player,
    required this.child,
  });

  final PodcastPlayer? player;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: player?.hasSession == true
        ? {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _seek(const Duration(seconds: -5)),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _seek(const Duration(seconds: 5)),
          }
        : const {},
    child: child,
  );

  void _seek(Duration offset) {
    final activePlayer = player;
    if (activePlayer == null || !activePlayer.hasSession) return;
    unawaited(activePlayer.skip(offset));
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
    this.updateVersion,
    this.updateInstalling = false,
    this.onRestartUpdate,
  });

  static const macOSHeight = 32.0;
  static const macOSControlHeight = 32.0;
  static const windowsHeight = 40.0;

  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;
  final String? updateVersion;
  final bool updateInstalling;
  final VoidCallback? onRestartUpdate;

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
    final updateTooltip = widget.updateInstalling
        ? context.strings.t('restarting_to_update')
        : '${context.strings.t('update_ready').replaceFirst('{version}', widget.updateVersion ?? '')} '
              '${context.strings.t('restart_to_update')}';
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
            if (widget.updateVersion != null) ...[
              IconButton.filledTonal(
                key: const Key('restart-to-update'),
                tooltip: updateTooltip,
                onPressed: widget.updateInstalling
                    ? null
                    : widget.onRestartUpdate,
                icon: widget.updateInstalling
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt_rounded),
                iconSize: 18,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
              ),
              const SizedBox(width: 4),
            ],
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
