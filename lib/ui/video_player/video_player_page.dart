import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/windowing/app_window.dart';
import '../../core/windowing/window_caption_button.dart';
import '../../core/windowing/window_drag_area.dart';
import '../../core/windowing/window_handle_channel.dart';
import '../../data/local_repositories.dart';
import '../../l10n/strings.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';
import '../platform/file_picking.dart';
import '../platform/immersive_mode.dart';
import '../transcript_review.dart';
import 'video_player_controller.dart';

@visibleForTesting
VideoPlayerController Function(String path)? debugVideoPlayerControllerFactory;

/// Creates the controller for [path] with the app's resume-point store.
VideoPlayerController createVideoPlayerController(
  BuildContext context,
  String path,
) =>
    debugVideoPlayerControllerFactory?.call(path) ??
    VideoPlayerController(
      path: path,
      playbackRepository: _playbackRepository(context),
      preferredLanguage:
          WidgetsBinding.instance.platformDispatcher.locale.languageCode,
      loadSpeechEnergy: _appController(context)?.loadFileSpeechEnergy,
    );

/// Plays a video with its own subtitles, outside the transcription jobs:
/// ←/→ move between subtitles and holding R repeats the current one.
///
/// On desktop it fills its own window ([VideoPlayerWindows]), which owns
/// [controller] and closes through [onClose]. Without them (widget tests, or
/// an SDK without windowing) it is a route that owns its controller.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.path,
    this.controller,
    this.onClose,
    this.onVideoSize,
    this.onControlsVisibilityChanged,
  });

  static const routeName = '/video-player';

  final String path;
  final VideoPlayerController? controller;
  final VoidCallback? onClose;

  /// The video's pixel size, once known, for fitting the window to it.
  final ValueChanged<Size>? onVideoSize;

  /// Follows the auto-hiding controls, to fade the native title bar with them.
  final ValueChanged<bool>? onControlsVisibilityChanged;

  static Route<void> route(String path) => PageRouteBuilder<void>(
    settings: RouteSettings(name: routeName, arguments: path),
    transitionDuration: const Duration(milliseconds: 160),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, animation, secondaryAnimation) =>
        VideoPlayerPage(key: ValueKey(path), path: path),
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController _controller;
  late final bool _ownsController;
  late final VideoController _video;
  AppWindow? _window;
  bool _routeFullscreen = false;
  bool _closing = false;
  Size? _reportedVideoSize;

  bool get _fullscreen => _window?.isFullscreen ?? _routeFullscreen;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? createVideoPlayerController(context, widget.path);
    _video = VideoController(_controller.player);
    // A missing native video output must not take down playback controls.
    _video.platform.future.ignore();
    _controller.addListener(_reportVideoSize);
    unawaited(_controller.open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = AppWindow.maybeOf(context);
    if (identical(window, _window)) return;
    _window?.listenable.removeListener(_windowChanged);
    _window = window;
    _window?.listenable.addListener(_windowChanged);
  }

  @override
  void dispose() {
    _window?.listenable.removeListener(_windowChanged);
    _controller.removeListener(_reportVideoSize);
    if (_ownsController) {
      unawaited(_controller.close());
      _controller.dispose();
    }
    super.dispose();
  }

  void _windowChanged() {
    if (mounted) setState(() {});
  }

  void _reportVideoSize() {
    final size = _controller.videoSize;
    if (size == null || size == _reportedVideoSize) return;
    _reportedVideoSize = size;
    widget.onVideoSize?.call(size);
  }

  void _setFullscreen(bool value) {
    final window = _window;
    if (window != null) {
      window.setFullscreen(value);
    } else {
      setState(() => _routeFullscreen = value);
      unawaited(
        value ? ImmersiveMode.enter(context) : ImmersiveMode.exit(context),
      );
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _controller.endRepeatHold();
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    if (_routeFullscreen) await ImmersiveMode.exit(context);
    await _controller.close();
    // pop(), not maybePop(): PopScope still blocks pops until this rebuilds.
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _chooseSubtitleFile() async {
    final group = fileTypeGroup(
      context,
      label: context.strings.t('subtitle_files'),
      extensions: const ['srt', 'vtt', 'ass', 'ssa'],
    );
    final file = await openFile(
      acceptedTypeGroups: [group],
      initialDirectory: File(widget.path).parent.path,
    );
    if (file != null) await _controller.addSubtitleFile(file.path);
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: ListenookTheme.dark(),
    child: PopScope(
      canPop: _closing || widget.onClose != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF): () =>
              _setFullscreen(!_fullscreen),
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
              unawaited(_close()),
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
              unawaited(_close()),
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _buildPlayer(context),
          ),
        ),
      ),
    ),
  );

  Widget _buildPlayer(BuildContext context) {
    final controller = _controller;
    final hasCues = controller.cues.isNotEmpty;
    final window = _window;
    final status = _statusText(context);
    // On Windows the player window has no native caption (see
    // stylePlayerWindow); the top bar draws it, fading with the controls.
    final drawsCaption =
        window != null && defaultTargetPlatform == TargetPlatform.windows;
    return VideoFullscreenKeyboardRegion(
      key: const Key('video-player-region'),
      fullscreen: _fullscreen,
      onEnterFullscreen: () => _setFullscreen(true),
      // Esc leaves fullscreen first, then closes the player.
      onExit: () {
        if (_fullscreen) {
          _setFullscreen(false);
        } else {
          unawaited(_close());
        }
      },
      onControlsVisibilityChanged: widget.onControlsVisibilityChanged,
      // The native title bar shows the file name in a player window.
      title: window == null ? controller.title : null,
      // Without a window (iOS, tests) the bar also carries the close button:
      // there is no title bar, and back gestures are held for cleanup.
      topBar: _PlayerStatusBar(
        status: status,
        belowTitleBar: window != null && !drawsCaption,
        caption: drawsCaption && !_fullscreen
            ? _PlayerCaption(
                window: window,
                title: controller.title,
                onClose: () => unawaited(_close()),
              )
            : null,
        onClose: window == null ? () => unawaited(_close()) : null,
      ),
      subtitle: controller.subtitleText,
      sentenceNavigation: SentenceNavigationControls(
        previousLabel: 'shortcut_previous_subtitle',
        nextLabel: 'shortcut_next_subtitle',
        altModifier: false,
        onPrevious: controller.canGoPrevious
            ? () => unawaited(controller.previousSubtitle())
            : null,
        onNext: controller.canGoNext
            ? () => unawaited(controller.nextSubtitle())
            : null,
      ),
      trailingControls: [
        PlaybackSpeedButton(
          rate: controller.rate,
          onChanged: controller.setRate,
        ),
        _SubtitleMenuButton(
          controller: controller,
          onChooseFile: () => unawaited(_chooseSubtitleFile()),
        ),
      ],
      playing: controller.playing,
      position: controller.position,
      duration: controller.duration,
      onPlayPause: () => unawaited(controller.togglePlayback()),
      onSeek: (value) => unawaited(controller.seek(value)),
      onSeekBackward: () => unawaited(controller.previousSubtitle()),
      onSeekForward: () => unawaited(controller.nextSubtitle()),
      onDecreaseSpeed: () => unawaited(controller.slower()),
      onIncreaseSpeed: () => unawaited(controller.faster()),
      onRepeatHoldStart: () {
        if (hasCues || controller.selected != null) {
          controller.beginRepeatHold();
        }
      },
      onRepeatHoldEnd: controller.endRepeatHold,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Like QuickTime, the picture moves the window.
        onPanStart: window == null || _fullscreen
            ? null
            : (_) => unawaited(WindowHandleChannel.startDrag(window)),
        onDoubleTap: () => _setFullscreen(!_fullscreen),
        child: Video(
          controller: _video,
          controls: NoVideoControls,
          fill: Colors.black,
          subtitleViewConfiguration: const SubtitleViewConfiguration(
            visible: false,
          ),
        ),
      ),
    );
  }

  String? _statusText(BuildContext context) {
    final controller = _controller;
    final strings = context.strings;
    if (controller.openError != null) {
      return strings.error(controller.openError);
    }
    if (!controller.opened) return null;
    if (controller.loadingCues) return strings.t('player_loading_subtitles');
    if (controller.cueError != null) return strings.error(controller.cueError);
    final selected = controller.selected;
    if (selected != null && !selected.navigable) {
      return strings.t('player_subtitle_display_only');
    }
    return null;
  }
}

/// A one-line note about the subtitles (none found, still loading, …) at the
/// top of the picture, fading with the controls.
class _PlayerStatusBar extends StatelessWidget {
  const _PlayerStatusBar({
    required this.status,
    required this.belowTitleBar,
    this.caption,
    this.onClose,
  });

  /// Null when there is nothing to say: the bar then only shades the title
  /// bar so the file name stays readable over a bright picture.
  final String? status;

  /// Leaves room for a player window's native title bar (macOS).
  final bool belowTitleBar;

  /// The window's own title bar, where the player draws it (Windows).
  final Widget? caption;

  /// Closes a player that has no window of its own.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('video-player-top-bar'),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x80000000), Colors.transparent],
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?caption,
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              onClose == null ? 16 : 4,
              caption != null ? 2 : (belowTitleBar ? 34 : 10),
              16,
              18,
            ),
            child: Row(
              children: [
                if (onClose != null)
                  IconButton(
                    key: const Key('video-player-close'),
                    tooltip: context.strings.t('close_player'),
                    onPressed: onClose,
                    color: Colors.white,
                    iconSize: 28,
                    icon: const Icon(Icons.close_rounded),
                  ),
                Expanded(
                  child: status == null
                      ? const SizedBox.shrink()
                      : Text(
                          status!,
                          key: const Key('video-player-status'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.white70),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A player window's title bar on Windows: the file name and the caption
/// buttons, transparent over the video.
class _PlayerCaption extends StatelessWidget {
  const _PlayerCaption({
    required this.window,
    required this.title,
    required this.onClose,
  });

  static const height = 32.0;

  final AppWindow window;
  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final maximized = window.isMaximized;
    return SizedBox(
      key: const Key('video-player-caption'),
      height: height,
      child: Row(
        children: [
          Expanded(
            child: WindowDragArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          Tooltip(
            message: strings.t('minimize_window'),
            child: WindowCaptionButton.minimize(
              brightness: Brightness.dark,
              onPressed: () => window.setMinimized(true),
            ),
          ),
          Tooltip(
            message: strings.t(
              maximized ? 'restore_window' : 'maximize_window',
            ),
            child: maximized
                ? WindowCaptionButton.unmaximize(
                    brightness: Brightness.dark,
                    onPressed: () => window.setMaximized(false),
                  )
                : WindowCaptionButton.maximize(
                    brightness: Brightness.dark,
                    onPressed: () => window.setMaximized(true),
                  ),
          ),
          Tooltip(
            message: strings.t('close_window'),
            child: WindowCaptionButton.close(
              key: const Key('video-player-close'),
              brightness: Brightness.dark,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleMenuButton extends StatelessWidget {
  const _SubtitleMenuButton({
    required this.controller,
    required this.onChooseFile,
  });

  static const _off = '\u0000off';
  static const _chooseFile = '\u0000file';

  final VideoPlayerController controller;
  final VoidCallback onChooseFile;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final selectedId = controller.selected?.id ?? _off;
    return PopupMenuButton<String>(
      key: const Key('video-player-subtitles'),
      tooltip: strings.t('player_subtitles'),
      initialValue: selectedId,
      icon: Icon(
        controller.selected == null
            ? Icons.subtitles_off_outlined
            : Icons.subtitles_outlined,
        color: Colors.white,
      ),
      onSelected: (value) {
        if (value == _chooseFile) {
          onChooseFile();
          return;
        }
        final source = controller.sources
            .where((item) => item.id == value)
            .firstOrNull;
        unawaited(controller.selectSubtitle(source));
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          key: const Key('video-player-subtitle-off'),
          value: _off,
          checked: selectedId == _off,
          child: Text(strings.t('player_subtitles_off')),
        ),
        for (final (index, source) in controller.sources.indexed)
          CheckedPopupMenuItem<String>(
            key: ValueKey('video-player-subtitle-${source.id}'),
            value: source.id,
            enabled: !source.pictureBased,
            checked: selectedId == source.id,
            child: _SourceLabel(source: source, number: index + 1),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          key: const Key('video-player-choose-subtitle'),
          value: _chooseFile,
          child: Text(strings.t('player_choose_subtitle_file')),
        ),
      ],
    );
  }
}

class _SourceLabel extends StatelessWidget {
  const _SourceLabel({required this.source, required this.number});

  final PlayerSubtitleSource source;
  final int number;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final embedded = source.kind == PlayerSubtitleKind.embedded;
    final name = embedded
        ? [
            if (source.title case final title? when title.trim().isNotEmpty)
              title.trim(),
            if (source.language case final language?
                when language.trim().isNotEmpty)
              language.trim(),
          ].join(' · ')
        : source.title ?? '';
    final details = [
      strings.t(embedded ? 'player_subtitle_builtin' : 'player_subtitle_file'),
      if (_format(source) case final format?) format,
      if (source.pictureBased) strings.t('player_subtitle_picture'),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name.isEmpty
              ? strings
                    .t('player_subtitle_track')
                    .replaceFirst('{number}', '$number')
              : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          details,
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String? _format(PlayerSubtitleSource source) {
    final format = source.embedded?.format;
    if (format != null) return format.label;
    final codec = source.codec?.trim();
    return codec == null || codec.isEmpty ? null : codec.toUpperCase();
  }
}

AppController? _appController(BuildContext context) {
  try {
    return context.read<AppController>();
  } on ProviderNotFoundException {
    return null;
  }
}

VideoPlaybackRepository? _playbackRepository(BuildContext context) {
  try {
    return context.read<VideoPlaybackRepository>();
  } on ProviderNotFoundException {
    return null;
  }
}
