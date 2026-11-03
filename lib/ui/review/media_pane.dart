import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models.dart';
import '../../data/transcript_exporter.dart';
import '../../l10n/strings.dart';
import '../keyboard_shortcuts.dart';
import '../platform/platform_context.dart';
import '../transcript_review.dart';
import 'transcript_segments.dart';

enum ReviewMediaMode { video, audio }

class MediaPane extends StatelessWidget {
  const MediaPane({
    super.key,
    this.sentenceNavigation,
    required this.job,
    required this.video,
    required this.videoKey,
    required this.videoAspectRatio,
    required this.maxVideoHeight,
    required this.centerInAvailableHeight,
    required this.playing,
    required this.playbackRate,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onSeek,
    required this.onFullscreen,
    required this.onPlaybackRateChanged,
    required this.onEnterNativeFullscreen,
    required this.onExitNativeFullscreen,
    required this.onSwitchToAudioMode,
    required this.controls,
  });

  final TranscriptionJob job;
  final VideoController video;
  final GlobalKey<VideoState> videoKey;
  final double videoAspectRatio;
  final double? maxVideoHeight;
  final bool centerInAvailableHeight;
  final Widget? sentenceNavigation;
  final bool playing;
  final double playbackRate;
  final Duration position;
  final Duration duration;
  final Future<void> Function() onPlayPause;
  final TranscriptSeekCallback onSeek;
  final Future<void> Function() onFullscreen;
  final Future<void> Function(double) onPlaybackRateChanged;
  final Future<void> Function() onEnterNativeFullscreen;
  final Future<void> Function() onExitNativeFullscreen;
  final VoidCallback? onSwitchToAudioMode;
  final VideoControlsBuilder controls;

  @override
  Widget build(BuildContext context) {
    final mediaDuration = duration.inMilliseconds > 0
        ? duration
        : Duration(milliseconds: job.metadata?.durationMs ?? 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        const transportHeight = VideoTransport.height;
        final aspect = videoAspectRatio.isFinite && videoAspectRatio > 0
            ? videoAspectRatio
            : 16 / 9;
        final heightFromWidth = constraints.maxWidth / aspect;
        final availableHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight - transportHeight).clamp(
                0.0,
                double.infinity,
              )
            : heightFromWidth;
        final viewportHeight = videoViewportHeight(
          width: constraints.maxWidth,
          aspectRatio: aspect,
          availableHeight: availableHeight,
          maximumHeight: maxVideoHeight,
        );
        return Column(
          mainAxisSize: centerInAvailableHeight
              ? MainAxisSize.max
              : MainAxisSize.min,
          mainAxisAlignment: centerInAvailableHeight
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Container(
              key: const Key('video-viewport'),
              color: Colors.black,
              height: viewportHeight,
              width: double.infinity,
              child: Video(
                key: videoKey,
                controller: video,
                aspectRatio: aspect,
                fit: BoxFit.contain,
                controls: controls,
                onEnterFullscreen: onEnterNativeFullscreen,
                onExitFullscreen: onExitNativeFullscreen,
              ),
            ),
            VideoTransport(
              sentenceNavigation: sentenceNavigation,
              playing: playing,
              position: position,
              duration: mediaDuration,
              playbackRate: playbackRate,
              onPlayPause: onPlayPause,
              onSeek: onSeek,
              onPlaybackRateChanged: onPlaybackRateChanged,
              onSwitchToAudioMode: onSwitchToAudioMode,
              onFullscreen: onFullscreen,
            ),
          ],
        );
      },
    );
  }
}

double videoViewportHeight({
  required double width,
  required double aspectRatio,
  required double availableHeight,
  double? maximumHeight,
}) {
  final heightFromWidth = width / aspectRatio;
  final heightLimit = maximumHeight == null
      ? availableHeight
      : availableHeight.clamp(0.0, maximumHeight);
  return heightFromWidth.clamp(0.0, heightLimit).toDouble();
}

class VideoTransport extends StatelessWidget {
  const VideoTransport({
    this.sentenceNavigation,
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.playbackRate,
    required this.onPlayPause,
    required this.onSeek,
    required this.onPlaybackRateChanged,
    required this.onFullscreen,
    this.onSwitchToAudioMode,
  });

  static const height = 56.0;

  final Widget? sentenceNavigation;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double playbackRate;
  final Future<void> Function() onPlayPause;
  final TranscriptSeekCallback onSeek;
  final Future<void> Function(double) onPlaybackRateChanged;
  final VoidCallback? onSwitchToAudioMode;
  final Future<void> Function() onFullscreen;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('video-transport'),
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a phone the seek bar needs the room the clocks would take.
          final showClocks = constraints.maxWidth >= 480;
          return Row(
            children: [
              IconButton.filledTonal(
                key: const Key('video-play-pause'),
                onPressed: onPlayPause,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              if (sentenceNavigation != null) sentenceNavigation!,
              const SizedBox(width: 8),
              if (showClocks)
                Text(
                  formatClock(position.inMilliseconds),
                  key: const Key('video-current-time'),
                ),
              Expanded(
                child: Slider(
                  key: const Key('video-seek'),
                  value: position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble(),
                  max: duration.inMilliseconds
                      .clamp(1, double.infinity)
                      .toDouble(),
                  onChanged: (value) => onSeek(
                    Duration(milliseconds: value.round()),
                    reason: TranscriptSeekReason.videoProgressScrub,
                  ),
                ),
              ),
              if (showClocks)
                Text(
                  formatClock(duration.inMilliseconds),
                  key: const Key('video-duration'),
                ),
              PlaybackSpeedButton(
                rate: playbackRate,
                onChanged: onPlaybackRateChanged,
              ),
              if (onSwitchToAudioMode != null)
                MediaModeButton(
                  destination: ReviewMediaMode.audio,
                  onPressed: onSwitchToAudioMode!,
                ),
              IconButton(
                key: const Key('video-fullscreen'),
                tooltip: context.strings.t('fullscreen'),
                onPressed: () => unawaited(onFullscreen()),
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class PlaybackSpeedButton extends StatelessWidget {
  const PlaybackSpeedButton({
    super.key,
    required this.rate,
    required this.onChanged,
  });

  static const rates = <double>[.5, .75, 1, 1.25, 1.5, 1.75, 2];

  final double rate;
  final Future<void> Function(double rate) onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    key: const Key('video-playback-speed'),
    tooltip: context.strings.t('playback_speed'),
    initialValue: rate,
    onSelected: (value) => unawaited(onChanged(value)),
    itemBuilder: (context) => [
      for (final value in rates)
        CheckedPopupMenuItem<double>(
          key: ValueKey('playback-speed-${(value * 100).round()}'),
          value: value,
          checked: (value - rate).abs() < .001,
          child: Text(formatPlaybackRate(value)),
        ),
    ],
    icon: Text(
      formatPlaybackRate(rate),
      key: const Key('video-playback-speed-label'),
      style: Theme.of(context).textTheme.labelLarge,
    ),
  );
}

String formatPlaybackRate(double rate) {
  final fixed = rate.toStringAsFixed(2);
  final value = fixed.endsWith('00')
      ? fixed.substring(0, fixed.length - 3)
      : fixed.endsWith('0')
      ? fixed.substring(0, fixed.length - 1)
      : fixed;
  return '$value×';
}

class ReviewFullscreenControlsHost extends StatelessWidget {
  const ReviewFullscreenControlsHost({
    super.key,
    required this.playback,
    required this.isActive,
    required this.overlay,
  });

  final Listenable playback;
  final bool Function() isActive;
  final Widget Function() overlay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: playback,
      builder: (context, _) {
        if (!isActive()) return const SizedBox.shrink();
        return overlay();
      },
    );
  }
}

class VideoFullscreenKeyboardRegion extends StatefulWidget {
  const VideoFullscreenKeyboardRegion({
    this.blindListening = false,
    this.sentenceRevealed = false,
    this.onReveal,
    this.onListeningKey,
    this.sentenceNavigation,
    super.key,
    this.subtitle,
    this.subtitleHighlight,
    this.topBar,
    this.title,
    this.trailingControls = const [],
    this.fullscreen = true,
    this.onEnterFullscreen,
    this.onControlsVisibilityChanged,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onExit,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSeekBackward,
    required this.onSeekForward,
    required this.onDecreaseSpeed,
    required this.onIncreaseSpeed,
    required this.onRepeatHoldStart,
    required this.onRepeatHoldEnd,
    required this.child,
  });

  final bool blindListening;
  final bool sentenceRevealed;
  final VoidCallback? onReveal;
  final bool Function(KeyEvent)? onListeningKey;
  final Widget? sentenceNavigation;

  static const controlsAutoHideDelay = Duration(seconds: 3);
  static const controlsTransitionDuration = Duration(milliseconds: 180);

  final String? subtitle;
  final TextRange? subtitleHighlight;

  /// Shown above the video with the bottom controls, and hidden with them.
  final Widget? topBar;

  /// A label above the bottom controls, such as the file being played.
  final String? title;

  /// Extra buttons placed before the fullscreen button.
  final List<Widget> trailingControls;

  /// When false the region fills a normal window: the last button enters
  /// fullscreen through [onEnterFullscreen] instead of exiting it.
  final bool fullscreen;
  final VoidCallback? onEnterFullscreen;

  /// Called whenever the auto-hiding controls appear or disappear.
  final ValueChanged<bool>? onControlsVisibilityChanged;
  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onExit;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;
  final VoidCallback onDecreaseSpeed;
  final VoidCallback onIncreaseSpeed;
  final VoidCallback onRepeatHoldStart;
  final VoidCallback onRepeatHoldEnd;
  final Widget child;

  @override
  State<VideoFullscreenKeyboardRegion> createState() =>
      _VideoFullscreenKeyboardRegionState();
}

class _VideoFullscreenKeyboardRegionState
    extends State<VideoFullscreenKeyboardRegion> {
  static const _controlsClearance = 72.0;

  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool? _reportedControlsVisible;
  bool _scrubbing = false;
  bool _repeatKeyHeld = false;

  @override
  void initState() {
    super.initState();
    _restartHideTimer();
  }

  @override
  void didUpdateWidget(VideoFullscreenKeyboardRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.playing) {
      _hideTimer?.cancel();
      _controlsVisible = true;
    } else if (!oldWidget.playing) {
      _controlsVisible = true;
      _restartHideTimer();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent == false ||
        primaryFocusIsEditable()) {
      return KeyEventResult.ignored;
    }
    if (widget.onListeningKey?.call(event) ?? false) {
      // Option+arrow steps between sentences: a seek, like the plain arrows.
      if (event.logicalKey != LogicalKeyboardKey.arrowLeft &&
          event.logicalKey != LogicalKeyboardKey.arrowRight) {
        _showControls();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyR) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (!_repeatKeyHeld) return KeyEventResult.ignored;
      _releaseRepeatKey();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      return _repeatKeyHeld ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent || _fullscreenShortcutModifierPressed()) {
      return KeyEventResult.ignored;
    }
    _repeatKeyHeld = true;
    widget.onRepeatHoldStart();
    return KeyEventResult.handled;
  }

  bool _fullscreenShortcutModifierPressed() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed;
  }

  void _releaseRepeatKey() {
    if (!_repeatKeyHeld) return;
    _repeatKeyHeld = false;
    widget.onRepeatHoldEnd();
  }

  void _exit() {
    _releaseRepeatKey();
    widget.onExit();
  }

  bool _visibleAtPointerDown = false;

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!widget.playing || _scrubbing) return;
    _hideTimer = Timer(VideoFullscreenKeyboardRegion.controlsAutoHideDelay, () {
      if (!mounted || !widget.playing || _scrubbing) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls({bool restartTimer = true}) {
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (restartTimer) _restartHideTimer();
  }

  void _runWithVisibleControls(VoidCallback action) {
    _showControls();
    action();
  }

  void _beginScrubbing(double _) {
    _scrubbing = true;
    _showControls(restartTimer: false);
  }

  void _seekTo(double value) {
    widget.onSeek(Duration(milliseconds: value.round()));
  }

  void _finishScrubbing(double _) {
    _scrubbing = false;
    _showControls();
  }

  void _reportControlsVisibility() {
    final callback = widget.onControlsVisibilityChanged;
    final visible = _controlsVisible;
    if (callback == null || _reportedControlsVisible == visible) return;
    _reportedControlsVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(visible));
  }

  @override
  Widget build(BuildContext context) {
    _reportControlsVisibility();
    final text = widget.subtitle?.trim();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _exit,
        commandPeriod: _exit,
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _runWithVisibleControls(widget.onPlayPause),
        // Seeking from the keyboard leaves the controls as they are, so the
        // picture is not covered while stepping through it.
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            widget.onSeekBackward,
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            widget.onSeekForward,
        const SingleActivator(LogicalKeyboardKey.keyX): () =>
            _runWithVisibleControls(widget.onDecreaseSpeed),
        const SingleActivator(LogicalKeyboardKey.keyC): () =>
            _runWithVisibleControls(widget.onIncreaseSpeed),
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fontSize = (constraints.maxWidth / 40).clamp(18.0, 32.0);
            final bottomPadding = (constraints.maxHeight * .06).clamp(
              24.0,
              72.0,
            );
            return MouseRegion(
              key: const Key('fullscreen-pointer-region'),
              cursor: _controlsVisible
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.none,
              onEnter: (_) => _showControls(),
              onHover: (_) => _showControls(),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  _visibleAtPointerDown = _controlsVisible;
                  _showControls();
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // A mouse shows the controls by moving; a finger taps the
                    // picture to show them and taps again to hide them.
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (details) {
                        if (details.kind != PointerDeviceKind.touch ||
                            !_visibleAtPointerDown ||
                            !widget.playing) {
                          return;
                        }
                        _hideTimer?.cancel();
                        setState(() => _controlsVisible = false);
                      },
                      child: widget.child,
                    ),
                    if (text != null && text.isNotEmpty)
                      IgnorePointer(
                        child: AnimatedPadding(
                          key: const Key('fullscreen-subtitle-padding'),
                          duration: VideoFullscreenKeyboardRegion
                              .controlsTransitionDuration,
                          curve: Curves.easeInOut,
                          padding: EdgeInsets.only(
                            bottom: _controlsVisible ? _controlsClearance : 0,
                          ),
                          child: SafeArea(
                            minimum: EdgeInsets.only(bottom: bottomPadding),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                widthFactor: .84,
                                child: Center(
                                  widthFactor: 1,
                                  heightFactor: 1,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 960,
                                    ),
                                    child: DecoratedBox(
                                      key: const Key('fullscreen-subtitle'),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: .40,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 10,
                                        ),
                                        child: BlindListeningBlur(
                                          blurred:
                                              widget.blindListening &&
                                              !widget.sentenceRevealed,
                                          child: _FullscreenSubtitleText(
                                            text: text,
                                            highlight: widget.subtitleHighlight,
                                            fontSize: fontSize,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.topBar != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: _autoHiding(widget.topBar!, slideFrom: -.12),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ExcludeSemantics(
                        excluding: !_controlsVisible,
                        child: ExcludeFocus(
                          excluding: !_controlsVisible,
                          child: IgnorePointer(
                            ignoring: !_controlsVisible,
                            child: AnimatedSlide(
                              offset: _controlsVisible
                                  ? Offset.zero
                                  : const Offset(0, .12),
                              duration: VideoFullscreenKeyboardRegion
                                  .controlsTransitionDuration,
                              curve: Curves.easeInOut,
                              child: AnimatedOpacity(
                                key: const Key('fullscreen-controls-opacity'),
                                opacity: _controlsVisible ? 1 : 0,
                                duration: VideoFullscreenKeyboardRegion
                                    .controlsTransitionDuration,
                                curve: Curves.easeInOut,
                                child: _buildControls(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _withTitle(Widget controls) {
    final title = widget.title;
    if (title == null || title.isEmpty) return controls;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, bottom: 2),
          child: Text(
            title,
            key: const Key('fullscreen-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: Colors.white),
          ),
        ),
        controls,
      ],
    );
  }

  Widget _autoHiding(
    Widget child, {
    required double slideFrom,
  }) => ExcludeSemantics(
    excluding: !_controlsVisible,
    child: ExcludeFocus(
      excluding: !_controlsVisible,
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: AnimatedSlide(
          offset: _controlsVisible ? Offset.zero : Offset(0, slideFrom),
          duration: VideoFullscreenKeyboardRegion.controlsTransitionDuration,
          curve: Curves.easeInOut,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: VideoFullscreenKeyboardRegion.controlsTransitionDuration,
            curve: Curves.easeInOut,
            child: child,
          ),
        ),
      ),
    ),
  );

  Widget _buildControls(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final hasDuration = durationMs > 0;
    final positionMs = hasDuration
        ? widget.position.inMilliseconds.clamp(0, durationMs).toDouble()
        : 0.0;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        key: const Key('fullscreen-controls'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xB3000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 28, 12, 10),
          // Every control sits on the dark gradient, so the sentence and
          // reveal buttons must not fall back to the light theme's dark icons.
          child: IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white38,
              ),
            ),
            child: _withTitle(
              LayoutBuilder(
                builder: (context, constraints) {
                  // A phone held upright has no room for the clocks.
                  final showClocks = constraints.maxWidth >= 520;
                  return Row(
                    key: const Key('fullscreen-controls-bar'),
                    children: [
                      IconButton(
                        key: const Key('fullscreen-play-pause'),
                        tooltip: context.strings.t(
                          widget.playing ? 'pause' : 'play',
                        ),
                        onPressed: () =>
                            _runWithVisibleControls(widget.onPlayPause),
                        color: Colors.white,
                        iconSize: 30,
                        icon: Icon(
                          widget.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      if (widget.sentenceNavigation != null)
                        widget.sentenceNavigation!,
                      // Holding R repeats a sentence from the keyboard; a
                      // finger holds this button instead.
                      if (context.touchActive)
                        _RepeatHoldButton(
                          onStart: widget.onRepeatHoldStart,
                          onEnd: widget.onRepeatHoldEnd,
                        ),
                      if (widget.blindListening)
                        SentenceRevealButton(
                          revealed: widget.sentenceRevealed,
                          onPressed: widget.onReveal,
                        ),
                      const SizedBox(width: 4),
                      if (showClocks) ...[
                        Text(
                          formatClock(positionMs.round()),
                          key: const Key('fullscreen-position'),
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: colors.primaryContainer,
                            inactiveTrackColor: Colors.white38,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            key: const Key('fullscreen-seek'),
                            value: positionMs,
                            max: hasDuration ? durationMs.toDouble() : 1,
                            onChangeStart: hasDuration ? _beginScrubbing : null,
                            onChanged: hasDuration ? _seekTo : null,
                            onChangeEnd: hasDuration ? _finishScrubbing : null,
                          ),
                        ),
                      ),
                      if (showClocks) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatClock(hasDuration ? durationMs : 0),
                          key: const Key('fullscreen-duration'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                      const SizedBox(width: 4),
                      ...widget.trailingControls,
                      if (widget.fullscreen)
                        IconButton(
                          key: const Key('fullscreen-exit'),
                          tooltip: context.strings.t('exit_fullscreen'),
                          onPressed: () => _runWithVisibleControls(_exit),
                          color: Colors.white,
                          iconSize: 30,
                          icon: const Icon(Icons.fullscreen_exit_rounded),
                        )
                      else if (widget.onEnterFullscreen != null)
                        IconButton(
                          key: const Key('fullscreen-enter'),
                          tooltip: context.strings.t('fullscreen'),
                          onPressed: () => _runWithVisibleControls(
                            widget.onEnterFullscreen!,
                          ),
                          color: Colors.white,
                          iconSize: 30,
                          icon: const Icon(Icons.fullscreen_rounded),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenSubtitleText extends StatelessWidget {
  const _FullscreenSubtitleText({
    required this.text,
    required this.highlight,
    required this.fontSize,
  });

  final String text;
  final TextRange? highlight;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1.25,
      shadows: const [
        Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1)),
      ],
    );
    final range = highlight;
    if (range == null ||
        !range.isValid ||
        range.isCollapsed ||
        range.end > text.length) {
      return Text(text, textAlign: TextAlign.center, style: style);
    }
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (range.start > 0) TextSpan(text: text.substring(0, range.start)),
          TextSpan(
            text: text.substring(range.start, range.end),
            style: TextStyle(
              color: colors.onPrimary,
              backgroundColor: colors.primary,
            ),
          ),
          if (range.end < text.length)
            TextSpan(text: text.substring(range.end)),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class AudioTransport extends StatelessWidget {
  const AudioTransport({
    this.sentenceNavigation,
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.waveformPath,
    required this.waveformLoading,
    required this.onPlayPause,
    required this.onSeek,
    this.onSwitchToVideoMode,
  });

  static const height = 64.0;

  final Widget? sentenceNavigation;
  final bool playing;
  final Duration position;
  final Duration duration;
  final String? waveformPath;
  final bool waveformLoading;
  final Future<void> Function() onPlayPause;
  final Future<void> Function(Duration) onSeek;
  final VoidCallback? onSwitchToVideoMode;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('audio-transport'),
    height: height,
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          IconButton.filledTonal(
            key: const Key('audio-play-pause'),
            onPressed: onPlayPause,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          if (sentenceNavigation != null) sentenceNavigation!,
          const SizedBox(width: 8),
          Text(
            formatClock(position.inMilliseconds),
            key: const Key('audio-current-time'),
            style: _clockStyle,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 36,
              child: WaveformScrubber(
                path: waveformPath,
                loading: waveformLoading,
                position: position,
                duration: duration,
                onSeek: onSeek,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatClock(duration.inMilliseconds),
            key: const Key('audio-duration'),
            style: _clockStyle,
          ),
          if (onSwitchToVideoMode != null)
            MediaModeButton(
              destination: ReviewMediaMode.video,
              onPressed: onSwitchToVideoMode!,
            ),
        ],
      ),
    ),
  );
}

// Fixed-width digits keep the ticking clock from resizing the waveform.
const _clockStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

class WaveformScrubber extends StatefulWidget {
  const WaveformScrubber({
    super.key,
    required this.path,
    required this.loading,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final String? path;
  final bool loading;
  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration) onSeek;

  @override
  State<WaveformScrubber> createState() => _WaveformScrubberState();
}

class _WaveformScrubberState extends State<WaveformScrubber> {
  Uint8List? _levels;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLevels());
  }

  @override
  void didUpdateWidget(WaveformScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) unawaited(_loadLevels());
  }

  Future<void> _loadLevels() async {
    final path = widget.path;
    Uint8List? levels;
    if (path != null) {
      try {
        levels = await File(path).readAsBytes();
      } on FileSystemException {
        levels = null;
      }
    }
    if (mounted && widget.path == path) setState(() => _levels = levels);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    final duration = widget.duration;
    final position = widget.position;
    final enabled = duration.inMilliseconds > 0;
    final progress = enabled
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void seek(double dx) {
          if (!enabled || width <= 0) return;
          final fraction = (dx / width).clamp(0.0, 1.0);
          unawaited(
            widget.onSeek(
              Duration(
                milliseconds: (duration.inMilliseconds * fraction).round(),
              ),
            ),
          );
        }

        return Semantics(
          slider: true,
          value:
              '${formatClock(position.inMilliseconds)} / '
              '${formatClock(duration.inMilliseconds)}',
          increasedValue: enabled
              ? formatClock(
                  (duration.inMilliseconds * (progress + .05).clamp(0.0, 1.0))
                      .round(),
                )
              : null,
          decreasedValue: enabled
              ? formatClock(
                  (duration.inMilliseconds * (progress - .05).clamp(0.0, 1.0))
                      .round(),
                )
              : null,
          onIncrease: enabled
              ? () => seek(width * (progress + .05).clamp(0.0, 1.0))
              : null,
          onDecrease: enabled
              ? () => seek(width * (progress - .05).clamp(0.0, 1.0))
              : null,
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              key: const Key('waveform-scrubber'),
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              onHorizontalDragStart: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _WaveformPainter(
                      levels: _levels,
                      progress: progress,
                      playedColor: colors.primary,
                      unplayedColor: colors.onSurfaceVariant.withValues(
                        alpha: .35,
                      ),
                    ),
                  ),
                  if (enabled)
                    Positioned(
                      left: (width * progress - 1).clamp(0.0, width - 2),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        key: const Key('waveform-playhead'),
                        width: 2,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Draws the loudness levels as rounded bars, or a flat line until they are
/// available, tinting the part before [progress] as played.
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.levels,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

  static const _barWidth = 2.0;
  static const _barPitch = 3.0;
  static const _minBarHeight = 2.0;

  final Uint8List? levels;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = Path();
    final centerY = size.height / 2;
    final levels = this.levels;
    if (levels == null || levels.isEmpty) {
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - 1, size.width, 2),
          const Radius.circular(1),
        ),
      );
    } else {
      final bars = math.max(
        1,
        (size.width + _barPitch - _barWidth) ~/ _barPitch,
      );
      final offset = (size.width - (bars - 1) * _barPitch - _barWidth) / 2;
      for (var bar = 0; bar < bars; bar++) {
        final start = bar * levels.length ~/ bars;
        final end = math.max(start + 1, (bar + 1) * levels.length ~/ bars);
        var level = 0;
        for (var index = start; index < end; index++) {
          level = math.max(level, levels[index]);
        }
        final height = math.max(_minBarHeight, size.height * level / 255);
        path.addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              offset + bar * _barPitch,
              centerY - height / 2,
              _barWidth,
              height,
            ),
            const Radius.circular(_barWidth / 2),
          ),
        );
      }
    }
    final playedWidth = size.width * progress;
    canvas
      ..save()
      ..clipRect(Rect.fromLTRB(playedWidth, 0, size.width, size.height))
      ..drawPath(path, Paint()..color = unplayedColor)
      ..restore()
      ..save()
      ..clipRect(Rect.fromLTRB(0, 0, playedWidth, size.height))
      ..drawPath(path, Paint()..color = playedColor)
      ..restore();
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.levels != levels ||
      oldDelegate.progress != progress ||
      oldDelegate.playedColor != playedColor ||
      oldDelegate.unplayedColor != unplayedColor;
}

class _RepeatHoldButton extends StatefulWidget {
  const _RepeatHoldButton({required this.onStart, required this.onEnd});

  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  State<_RepeatHoldButton> createState() => _RepeatHoldButtonState();
}

class _RepeatHoldButtonState extends State<_RepeatHoldButton> {
  bool _holding = false;

  void _end() {
    if (!_holding) return;
    setState(() => _holding = false);
    widget.onEnd();
  }

  @override
  void dispose() {
    if (_holding) widget.onEnd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.strings.t('hold_to_repeat_sentence'),
    triggerMode: TooltipTriggerMode.tap,
    child: GestureDetector(
      key: const Key('fullscreen-repeat-hold'),
      onLongPressStart: (_) {
        setState(() => _holding = true);
        widget.onStart();
      },
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: _end,
      child: SizedBox.square(
        dimension: 44,
        child: Icon(
          Icons.repeat_one_rounded,
          color: _holding
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.white,
        ),
      ),
    ),
  );
}
