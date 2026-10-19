import '../core/app_identity.dart';
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/windowing/app_window.dart';
import '../core/windowing/desktop_windows.dart';
import '../core/windowing/main_window_host.dart';
import '../core/windowing/window_caption_button.dart';
import '../core/windowing/window_drag_area.dart';
import '../data/desktop_runtime.dart';
import '../data/desktop_tray.dart';
import '../l10n/strings.dart';
import '../data/update_service.dart';
import '../state/app_controller.dart';
import '../state/podcast_controller.dart';
import '../state/podcast_player.dart';
import '../state/video_open_requests.dart';
import 'app_notice.dart';
import 'inbox_page.dart';
import 'keyboard_shortcuts.dart';
import 'library_page.dart';
import 'podcast_mini_bar.dart';
import 'podcast_page.dart';
import 'review_fullscreen_controller.dart';
import 'settings_page.dart';
import 'subtitle_import_review_dialog.dart';
import 'video_player/video_player_page.dart';
import 'video_player/video_player_windows.dart';
import 'workspace_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.reviewController});

  final ReviewFullscreenController? reviewController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with DesktopTrayListener, WidgetsBindingObserver {
  static const _nativeNavigationChannel = MethodChannel(
    AppIdentity.navigationChannel,
  );
  static const _compactSidebarWidth = 64.0;
  static const _extendedSidebarWidth = 184.0;

  String? _lastDisplayName;
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
  DesktopTray? _tray;
  UpdateService? _updates;
  VideoOpenRequests? _videoRequests;
  Route<void>? _videoPlayerRoute;

  @override
  void initState() {
    super.initState();
    _fullscreenController =
        widget.reviewController ?? ReviewFullscreenController();
    _controller = context.read<AppController>();
    _desktopRuntime = Provider.of<DesktopRuntime?>(context, listen: false);
    _tray = Provider.of<DesktopTray?>(context, listen: false);
    _updates = Provider.of<UpdateService?>(context, listen: false);
    _videoRequests = Provider.of<VideoOpenRequests?>(context, listen: false);
    final playerWindows = VideoPlayerWindows.instance;
    if (playerWindows == null) {
      // Without windowing the player is a route over this shell.
      _videoRequests?.addListener(_handleVideoRequests);
    } else {
      // Player windows open from main() even while this window is hidden and
      // not painting; the shell only steps its own playback aside.
      playerWindows
        ..beforeOpen = _pauseForVideoPlayer
        ..afterAllClosed = () {
          if (mounted) unawaited(_fullscreenController.resumeMedia());
        };
    }
    _knownMonitoredJobs = _monitoredJobIds();
    _controller.addListener(_handleControllerChange);
    WidgetsBinding.instance.addObserver(this);
    _mainWindow?.mainListenable.addListener(_syncWindowFullscreen);
    _mainWindow?.mainCloseHandler = _onMainWindowClose;
    _tray?.listener = this;
    _nativeNavigationChannel.setMethodCallHandler(_handleNativeNavigation);
    _syncWindowFullscreen();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOnboarding();
      unawaited(_showLegacyLoginNotice());
      unawaited(_updates?.start());
      unawaited(_initializeDesktopRuntime());
      _scheduleTraySync();
      if (VideoPlayerWindows.instance == null) _handleVideoRequests();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final strings = context.strings;
    if (_lastDisplayName == strings.appName) return;
    _lastDisplayName = strings.appName;
    unawaited(_syncDisplayName(strings));
    _scheduleTraySync();
  }

  Future<void> _syncDisplayName(AppStrings strings) async {
    try {
      _mainWindow?.setMainTitle(strings.appName);
      await _desktopRuntime?.setDisplayName(
        strings.appName,
        strings.locale.languageCode,
      );
    } on MissingPluginException {
      // Native surfaces are unavailable in widget tests.
    }
  }

  Future<void> _showLegacyLoginNotice() async {
    final runtime = _desktopRuntime;
    if (runtime == null ||
        !await runtime.needsLegacyLoginNotice() ||
        !mounted) {
      return;
    }
    if (!_controller.inboxMonitorConfig.launchAtLogin) {
      await runtime.dismissLegacyLoginNotice();
      return;
    }
    final strings = context.strings;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.t('migration_login_title')),
        content: Text(strings.t('migration_login_body')),
        actions: [
          TextButton(
            onPressed: () async {
              await runtime.dismissLegacyLoginNotice();
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(strings.t('migration_later')),
          ),
          FilledButton(
            onPressed: () async {
              await runtime.dismissLegacyLoginNotice(openSettings: true);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(strings.t('migration_open_login')),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _traySyncTimer?.cancel();
    _notificationTimer?.cancel();
    _controller.removeListener(_handleControllerChange);
    _videoRequests?.removeListener(_handleVideoRequests);
    WidgetsBinding.instance.removeObserver(this);
    _mainWindow?.mainListenable.removeListener(_syncWindowFullscreen);
    _mainWindow?.mainCloseHandler = null;
    _tray?.listener = null;
    _nativeNavigationChannel.setMethodCallHandler(null);
    super.dispose();
  }

  void _handleVideoRequests() {
    final path = _videoRequests?.takeLatest();
    if (path != null && mounted) unawaited(_openVideoPlayer(path));
  }

  /// Pauses review and podcast playback while a video plays.
  Future<void> _pauseForVideoPlayer() async {
    await _fullscreenController.exit();
    await _fullscreenController.shutdownMedia();
    await _podcastController(listen: false)?.playback.pause();
  }

  Future<void> _openVideoPlayer(String path) async {
    await _pauseForVideoPlayer();
    if (mounted) await _openVideoPlayerRoute(path);
  }

  /// Without windowing (widget tests), the player covers the main window.
  Future<void> _openVideoPlayerRoute(String path) async {
    await _showAndFocusWindow();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final route = VideoPlayerPage.route(path);
    final previous = _videoPlayerRoute;
    _videoPlayerRoute = route;
    if (previous != null && previous.isActive) {
      navigator.replace(oldRoute: previous, newRoute: route);
    } else {
      unawaited(navigator.push(route));
    }
    await route.popped;
    if (!identical(_videoPlayerRoute, route)) return;
    _videoPlayerRoute = null;
    if (mounted) await _fullscreenController.resumeMedia();
  }

  Future<void> _watchVideo() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: context.strings.t('video_files'),
          extensions: supportedPlayerVideoExtensions.toList(growable: false),
        ),
      ],
    );
    if (file != null) _videoRequests?.addAll([file.path]);
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
    if (call.method == 'checkForUpdates') {
      unawaited(_checkForUpdates());
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
    _windowHidden = !(_mainWindow?.mainVisible ?? true);
  }

  void _scheduleTraySync() {
    _traySyncTimer?.cancel();
    _traySyncTimer = Timer(const Duration(milliseconds: 100), _syncTray);
  }

  void _syncTray() {
    if (!mounted) return;
    final controller = _controller;
    final strings = context.strings;
    final tray = _tray;
    if (tray == null) return;
    if (!controller.inboxMonitorConfig.showTrayIcon) {
      if (_trayReady) {
        try {
          tray.remove();
        } on Object catch (error) {
          debugPrint('Unable to remove the tray icon: $error');
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
      tray.show(
        tooltip: strings.appName,
        menu: [
          DesktopTrayMenuItem(
            key: 'status',
            label: configured
                ? '$folder · $status · ${controller.monitoredWaitingCount} ${strings.t('inbox')}'
                : status,
            enabled: false,
          ),
          null,
          DesktopTrayMenuItem(
            key: 'open-main-window',
            label: strings.t('tray_open_main_window'),
          ),
          if (configured)
            DesktopTrayMenuItem(
              key: 'toggle-monitor',
              label: strings.t(
                config.paused ? 'inbox_monitor_resume' : 'inbox_monitor_pause',
              ),
            ),
          DesktopTrayMenuItem(
            key: 'settings',
            label: strings.t('tray_open_settings'),
          ),
          null,
          DesktopTrayMenuItem(key: 'quit', label: strings.t('tray_quit')),
        ],
      );
      _trayReady = true;
    } on Object catch (error) {
      debugPrint('Unable to show the tray icon: $error');
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
  void onTrayIconClicked() => unawaited(_restoreMainWindow());

  @override
  void onTrayMenuItemSelected(String key) {
    switch (key) {
      case 'open-main-window':
        unawaited(_restoreMainWindow());
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

  final MainWindowHost? _mainWindow = MainWindowHost.instance;

  void _syncWindowFullscreen() =>
      _setWindowFullscreen(_mainWindow?.mainFullscreen ?? false);

  void _setWindowFullscreen(bool value) {
    if (!mounted || _windowFullscreen == value) return;
    setState(() => _windowFullscreen = value);
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
          'assets/branding/listenook-icon.png',
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

  Future<void> _onMainWindowClose() async {
    // Closing the main window while a video plays leaves the player open.
    if (_controller.inboxMonitorConfig.showTrayIcon ||
        (VideoPlayerWindows.instance?.hasOpenWindows ?? false)) {
      await _hideToTray();
      return;
    }
    await _requestQuit();
  }

  Future<void> _hideToTray() async {
    try {
      await _fullscreenController.exit();
      await _fullscreenController.shutdownMedia();
      await _mainWindow?.hideMain();
      _windowHidden = true;
      _scheduleTraySync();
    } on Object {
      // The window channel is unavailable in widget tests.
    }
  }

  Future<void> _restoreInbox() => _restoreWindow(AppDestination.inbox);

  Future<void> _restoreMainWindow() => _showAndFocusWindow();

  Future<void> _restoreWindow(AppDestination destination) async {
    await _setDestination(destination);
    await _showAndFocusWindow();
  }

  Future<void> _showAndFocusWindow() async {
    try {
      await _mainWindow?.showMain();
      _windowHidden = false;
      if (_controller.destination == AppDestination.workspace) {
        await _fullscreenController.resumeMedia();
      }
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
    // The confirmation lives in the main window, which may be hidden while
    // only a video player is open.
    if (!(_mainWindow?.mainVisible ?? true)) {
      await _showAndFocusWindow();
    }
    if (!mounted) return;
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
      if (_trayReady) {
        try {
          _tray?.remove();
        } on Object catch (error) {
          debugPrint('Unable to remove the tray icon: $error');
        }
      }
      await Future.wait([
        _fullscreenController.shutdownMedia(),
        _podcastController(listen: false)?.shutdown() ?? Future<void>.value(),
        _controller.shutdown(),
        VideoPlayerWindows.instance?.shutdown() ?? Future<void>.value(),
      ]);
      await _mainWindow?.quit();
    } on Object {
      _windowClosing = false;
      rethrow;
    }
  }

  Future<void> _checkForUpdates() async {
    final updates = _updates;
    if (updates == null || !mounted) return;
    await _showAndFocusWindow();
    if (!mounted) return;
    final strings = context.strings;
    if (!updates.supported) {
      showAppNotice(context, message: strings.t('update_not_supported'));
      return;
    }
    showAppNotice(context, message: strings.t('update_checking'));
    try {
      await updates.checkAndDownloadNow();
    } on Object catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        message: '${context.strings.t('update_check_failed')} $error',
        tone: AppNoticeTone.error,
      );
      return;
    }
    if (!mounted) return;
    final release = updates.release;
    if (updates.readyToRestart && release != null) {
      showAppNotice(
        context,
        message: context.strings
            .t('update_ready')
            .replaceFirst('{version}', release.version.name),
        tone: AppNoticeTone.success,
        actionLabel: context.strings.t('restart_to_update'),
        onAction: () => unawaited(_restartForUpdate(updates)),
      );
      return;
    }
    if (updates.phase == UpdatePhase.upToDate) {
      showAppNotice(
        context,
        message: context.strings.t('update_up_to_date'),
        tone: AppNoticeTone.success,
      );
    } else if (updates.phase == UpdatePhase.idle) {
      showAppNotice(
        context,
        message: context.strings.t('update_check_failed'),
        tone: AppNoticeTone.error,
      );
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
      showAppNotice(
        context,
        message: '${context.strings.t('update_restart_failed')} $error',
        tone: AppNoticeTone.error,
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
      label: context.strings.t('audio_video_subtitles'),
      extensions: const [
        'mp3',
        'wav',
        'm4a',
        'ogg',
        'mp4',
        'mkv',
        'avi',
        'srt',
        'vtt',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: [media]);
    if (files.isNotEmpty && mounted) {
      await reviewAndEnqueueSources(context, files.map((file) => file.path));
      if (!mounted) return;
      final controller = context.read<AppController>();
      if (mounted) controller.setDestination(AppDestination.inbox);
    }
  }

  Future<void> _importFolder() async {
    final directory = await getDirectoryPath();
    if (directory != null && mounted) {
      await reviewAndEnqueueSources(context, [directory]);
      if (!mounted) return;
      final controller = context.read<AppController>();
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
        child: SizedBox(
          width: _extendedSidebarWidth - 24,
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
      enabled: controller.destination != AppDestination.workspace,
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
          const SingleActivator(
            LogicalKeyboardKey.keyO,
            meta: true,
            shift: true,
          ): _watchVideo,
          const SingleActivator(
            LogicalKeyboardKey.keyO,
            control: true,
            shift: true,
          ): _watchVideo,
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
                                                top: 12,
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
                                    onWatchVideo: _videoRequests == null
                                        ? null
                                        : _watchVideo,
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
                                  AppDestination.settings => SettingsPage(
                                    key: const ValueKey('settings'),
                                    onRestartUpdate: updates == null
                                        ? null
                                        : () => unawaited(
                                            _restartForUpdate(updates),
                                          ),
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
    this.enabled = true,
  });

  final PodcastPlayer? player;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _handleKeyEvent,
    child: CallbackShortcuts(
      bindings: enabled && player?.hasSession == true
          ? {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _seek(const Duration(seconds: -5)),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _seek(const Duration(seconds: 5)),
            }
          : const {},
      child: child,
    ),
  );

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final activePlayer = player;
    if (!enabled ||
        activePlayer == null ||
        !activePlayer.hasSession ||
        event.logicalKey != LogicalKeyboardKey.space ||
        primaryFocusIsEditable() ||
        shortcutModifierPressed()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      unawaited(activePlayer.toggle());
      return KeyEventResult.handled;
    }
    return event is KeyRepeatEvent || event is KeyUpEvent
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

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
                              ? colors.surfaceContainerHighest
                              : _hovered
                              ? colors.onSurface.withValues(alpha: .05)
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

class _AppWindowToolbarState extends State<AppWindowToolbar> {
  AppWindow? _window;

  bool get _maximized => _window?.isMaximized ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = AppWindow.maybeOf(context);
    if (identical(window, _window)) return;
    _window?.listenable.removeListener(_changed);
    _window = window;
    _window?.listenable.addListener(_changed);
  }

  @override
  void dispose() {
    _window?.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

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
                  'assets/branding/listenook-icon.png',
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
            const Expanded(child: WindowDragArea(child: SizedBox.expand())),
            if (windows) ...[
              Tooltip(
                message: context.strings.t('minimize_window'),
                child: WindowCaptionButton.minimize(
                  key: const Key('window-minimize'),
                  brightness: brightness,
                  onPressed: () => _window?.setMinimized(true),
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
                        onPressed: () => _window?.setMaximized(false),
                      )
                    : WindowCaptionButton.maximize(
                        key: const Key('window-maximize'),
                        brightness: brightness,
                        onPressed: () => _window?.setMaximized(true),
                      ),
              ),
              Tooltip(
                message: context.strings.t('close_window'),
                child: WindowCaptionButton.close(
                  key: const Key('window-close'),
                  brightness: brightness,
                  onPressed: () =>
                      unawaited(DesktopWindows.instance?.requestMainClose()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
