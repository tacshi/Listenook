import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'job_actions.dart';
import 'keyboard_shortcuts.dart';
import 'review_fullscreen_controller.dart';
import 'transcript_export_dialog.dart';

class TranscriptReview extends StatefulWidget {
  const TranscriptReview({
    super.key,
    required this.jobId,
    this.fullscreenController,
  });
  final String jobId;
  final ReviewFullscreenController? fullscreenController;

  @override
  State<TranscriptReview> createState() => _TranscriptReviewState();
}

enum _ReviewMediaMode { video, audio }

@visibleForTesting
Player Function()? debugTranscriptReviewPlayerFactory;

@visibleForTesting
Future<bool> Function(String path)? debugTranscriptReviewSourceExists;

@visibleForTesting
VoidCallback? debugTranscriptReviewScheduleMediaFrame;

class _ReviewPlaybackTick extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _TranscriptReviewState extends State<TranscriptReview>
    with WindowListener {
  static const _reviewDividerWidth = 9.0;
  static const _minimumReviewPaneWidth = 280.0;
  static const _minimumCompanionPaneWidth = 420.0;
  static const _videoTitleHeaderHeight = 52.0;
  static const _mediaModeTransitionDuration = Duration(milliseconds: 320);
  static const _missingSourceAudioHeight = 112.0;

  Player? _player;
  LatestSeekDispatcher? _seekDispatcher;
  VideoController? _video;
  final _search = TextEditingController();
  final _aiBriefScroll = ScrollController();
  final _transcriptScroll = ItemScrollController();
  final _transcriptPositions = ItemPositionsListener.create();
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<double>? _rateSubscription;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  Future<void>? _mediaShutdown;
  GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  late final AppController _appController;
  late final ReviewFullscreenController _localFullscreenController;
  NavigatorState? _rootNavigator;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _videoAspectRatio = 16 / 9;
  double _playbackRate = 1;
  bool _playing = false;
  String? _manualRepeatingSegmentId;
  String? _heldRepeatingSegmentId;
  bool _repeatRestartPending = false;
  bool _repeatRestartQueued = false;
  bool _repeatRestartQueuedResume = false;
  bool _followPlayback = true;
  bool _focusFrameQueued = false;
  bool _forceFocusQueued = false;
  bool _searchVisible = false;
  bool _showAiBrief = false;
  TranslationViewMode _viewMode = TranslationViewMode.original;
  int _programmaticScrolls = 0;
  String? _lastScrolledSegmentId;
  String? _editingSegmentId;
  String? _editingTranslationSegmentId;
  TranscriptDocument? _mappedDocument;
  Map<String, List<TranscriptToken>> _tokensBySegment = const {};
  String _openedPath = '';
  String _waveformSource = '';
  String? _waveformPath;
  bool _waveformLoading = false;
  _ReviewMediaMode _mediaMode = _ReviewMediaMode.video;
  double? _transcriptPaneWidth;
  double? _companionLeftPaneFraction;
  bool _companionLayoutActive = false;
  int _sourceRequest = 0;
  late final VideoControlsBuilder _videoControls;
  final _playbackTick = _ReviewPlaybackTick();

  ReviewFullscreenController get _fullscreenController =>
      widget.fullscreenController ?? _localFullscreenController;

  @override
  void initState() {
    super.initState();
    _appController = context.read<AppController>();
    _videoControls = _buildVideoControls;
    _position = _appController.playbackPositionFor(widget.jobId);
    _viewMode = _defaultViewMode(_appController.jobById(widget.jobId));
    _localFullscreenController = ReviewFullscreenController();
    _fullscreenController.registerMediaShutdown(
      this,
      _shutdownMedia,
      resume: _resumeMedia,
    );
    HardwareKeyboard.instance.addHandler(_handleReviewShortcut);
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSource());
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (mounted) _playbackTick.tick();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rootNavigator = Navigator.of(context, rootNavigator: true);
  }

  @override
  void onWindowBlur() => _endSentenceRepeatHold();

  @override
  void onWindowLeaveFullScreen() {
    _endSentenceRepeatHold();
    unawaited(_fullscreenController.exit());
  }

  void _ensurePlayer() {
    if (_player != null) return;
    _openedPath = '';
    final player = debugTranscriptReviewPlayerFactory?.call() ?? Player();
    _player = player;
    _seekDispatcher = LatestSeekDispatcher(player.seek);
    _video = VideoController(player);
    (debugTranscriptReviewScheduleMediaFrame ??
        WidgetsBinding.instance.scheduleFrame)();
    _video!.platform.future.ignore();
    _positionSubscription = player.stream.position.listen(_handlePosition);
    _durationSubscription = player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _playingSubscription = player.stream.playing.listen(_handlePlaying);
    _completedSubscription = player.stream.completed.listen(_handleCompleted);
    _rateSubscription = player.stream.rate.listen((value) {
      if (!mounted || (value - _playbackRate).abs() < .001) return;
      setState(() => _playbackRate = value);
    });
    _videoParamsSubscription = player.stream.videoParams.listen((value) {
      final aspect =
          value.aspect ??
          ((value.dw ?? 0) > 0 && (value.dh ?? 0) > 0
              ? value.dw! / value.dh!
              : null);
      if (!mounted ||
          aspect == null ||
          !aspect.isFinite ||
          aspect <= 0 ||
          (aspect - _videoAspectRatio).abs() < .001) {
        return;
      }
      setState(() => _videoAspectRatio = aspect);
    });
  }

  @override
  void didUpdateWidget(covariant TranscriptReview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId) {
      _rememberPlaybackPosition(oldWidget.jobId);
      _sourceRequest++;
      _search.clear();
      _position = _appController.playbackPositionFor(widget.jobId);
      _duration = Duration.zero;
      _videoAspectRatio = 16 / 9;
      _playing = false;
      _manualRepeatingSegmentId = null;
      _heldRepeatingSegmentId = null;
      _repeatRestartQueued = false;
      _repeatRestartQueuedResume = false;
      _followPlayback = true;
      _searchVisible = false;
      _showAiBrief = false;
      _editingSegmentId = null;
      _editingTranslationSegmentId = null;
      _viewMode = _defaultViewMode(_appController.jobById(widget.jobId));
      _lastScrolledSegmentId = null;
      _mappedDocument = null;
      _tokensBySegment = const {};
      _openedPath = '';
      _waveformSource = '';
      _waveformPath = null;
      _waveformLoading = false;
      _mediaMode = _ReviewMediaMode.video;
      _companionLeftPaneFraction = null;
      _companionLayoutActive = false;
      if (_aiBriefScroll.hasClients) _aiBriefScroll.jumpTo(0);
      _openSource();
    }
  }

  void _handlePosition(Duration value) {
    if (!mounted || (_seekDispatcher?.isBusy ?? false)) return;
    final document = _document;
    final previousIndex = document == null
        ? null
        : currentTranscriptSegmentIndex(
            document.segments,
            _position.inMilliseconds,
          );
    final nextIndex = document == null
        ? null
        : currentTranscriptSegmentIndex(
            document.segments,
            value.inMilliseconds,
          );
    setState(() => _position = value);
    _appController.rememberPlaybackPosition(widget.jobId, value);
    final repeatedSegment = _repeatingSegment;
    if (_playing &&
        repeatedSegment != null &&
        shouldRestartRepeatedSentence(
          repeatedSegment,
          value.inMilliseconds,
          previousSegment: _previousSegmentFor(repeatedSegment),
        )) {
      _queueRepeatRestart();
    }
    if (shouldAutoFollowPlaybackSegment(
      playing: _playing,
      previousIndex: previousIndex,
      nextIndex: nextIndex,
      repeating: repeatedSegment != null,
    )) {
      _queueFocusCurrent();
    }
  }

  void _handlePlaying(bool value) {
    if (!mounted || value == _playing) return;
    final resumed = value && !_playing;
    setState(() {
      _playing = value;
      if (resumed) _followPlayback = true;
    });
    final repeatedSegment = _repeatingSegment;
    if (resumed &&
        repeatedSegment != null &&
        shouldRestartRepeatedSentence(
          repeatedSegment,
          _position.inMilliseconds,
        )) {
      _queueRepeatRestart(resumeAfterSeek: true);
    }
    if (resumed &&
        shouldFocusTranscriptOnPlaybackResume(
          repeating: repeatedSegment != null,
        )) {
      _queueFocusCurrent(force: true);
    }
  }

  void _handleCompleted(bool value) {
    final player = _player;
    if (!mounted ||
        !value ||
        player == null ||
        !player.state.completed ||
        _repeatingSegment == null) {
      return;
    }
    _queueRepeatRestart(resumeAfterSeek: true);
  }

  TranslationViewMode _defaultViewMode(TranscriptionJob? job) {
    if (job?.sourceOrigin == JobSourceOrigin.podcast &&
        (job?.document?.segments.any((item) => item.hasTranslation) ?? false)) {
      return TranslationViewMode.bilingual;
    }
    return TranslationViewMode.original;
  }

  TranscriptDocument? get _document => context
      .read<AppController>()
      .allJobs
      .where((item) => item.id == widget.jobId)
      .firstOrNull
      ?.document;

  String? get _repeatingSegmentId =>
      _heldRepeatingSegmentId ?? _manualRepeatingSegmentId;

  TranscriptSegment? get _repeatingSegment {
    final segmentId = _repeatingSegmentId;
    if (segmentId == null) return null;
    return _document?.segments
        .where((segment) => segment.id == segmentId)
        .firstOrNull;
  }

  TranscriptSegment? _previousSegmentFor(TranscriptSegment segment) {
    final segments = _document?.segments;
    if (segments == null) return null;
    final index = segments.indexWhere((item) => item.id == segment.id);
    return index > 0 ? segments[index - 1] : null;
  }

  Future<void> _openSource() async {
    if (!mounted) return;
    final job = _appController.allJobs
        .where((item) => item.id == widget.jobId)
        .firstOrNull;
    if (job == null) return;
    if (job.sourcePath == _openedPath && _player != null && _video != null) {
      return;
    }
    final request = ++_sourceRequest;
    final sourceExists = debugTranscriptReviewSourceExists;
    if (await (sourceExists == null
        ? File(job.sourcePath).exists()
        : sourceExists(job.sourcePath))) {
      if (!mounted || request != _sourceRequest || widget.jobId != job.id) {
        return;
      }
      _ensurePlayer();
      _openedPath = job.sourcePath;
      if (!(job.metadata?.hasVideo ?? false) ||
          _mediaMode == _ReviewMediaMode.audio) {
        unawaited(_loadWaveform(job));
      }
      final resumePosition = _appController.playbackPositionFor(job.id);
      final player = _player!;
      await player.open(Media(job.sourcePath), play: false);
      if (!mounted || request != _sourceRequest || widget.jobId != job.id) {
        return;
      }
      final duration = player.state.duration;
      final restoredPosition =
          duration > Duration.zero && resumePosition > duration
          ? duration
          : resumePosition;
      if (restoredPosition > Duration.zero) {
        await player.seek(restoredPosition);
      }
      if (mounted && request == _sourceRequest && widget.jobId == job.id) {
        _appController.rememberPlaybackPosition(job.id, restoredPosition);
        setState(() => _position = restoredPosition);
      }
    }
  }

  Future<void> _loadWaveform(TranscriptionJob job) async {
    final source = job.sourcePath;
    if (_waveformSource == source &&
        (_waveformLoading || _waveformPath != null)) {
      return;
    }
    setState(() {
      _waveformSource = source;
      _waveformPath = null;
      _waveformLoading = true;
    });
    final path = await context.read<AppController>().loadWaveform(job.id);
    if (!mounted || _openedPath != source) return;
    setState(() {
      _waveformPath = path;
      _waveformLoading = false;
    });
  }

  void _toggleMediaMode(TranscriptionJob job) {
    final nextMode = _mediaMode == _ReviewMediaMode.video
        ? _ReviewMediaMode.audio
        : _ReviewMediaMode.video;
    setState(() => _mediaMode = nextMode);
    if (nextMode == _ReviewMediaMode.audio) unawaited(_loadWaveform(job));
  }

  bool _supportsMediaModeSwitch(TranscriptionJob job) {
    final metadata = job.metadata;
    return metadata?.hasVideo == true && metadata?.hasAudio == true;
  }

  @override
  void dispose() {
    _endSentenceRepeatHold(notify: false);
    HardwareKeyboard.instance.removeHandler(_handleReviewShortcut);
    _rememberPlaybackPosition(widget.jobId);
    _fullscreenController.unregisterMediaShutdown(this);
    windowManager.removeListener(this);
    _search.dispose();
    _aiBriefScroll.dispose();
    unawaited(_shutdownMedia());
    super.dispose();
    _playbackTick.dispose();
  }

  Future<void> _shutdownMedia() => _mediaShutdown ??= _disposeMediaResources();

  Future<void> _resumeMedia() async {
    if (!mounted || _mediaShutdown == null) return;
    _mediaShutdown = null;
    _videoKey = GlobalKey<VideoState>();
    _openedPath = '';
    await _openSource();
  }

  Future<void> _disposeMediaResources() async {
    _sourceRequest++;
    final player = _player;
    _player = null;
    final seekDispatcher = _seekDispatcher;
    _seekDispatcher = null;
    _video = null;
    _openedPath = '';

    final subscriptions = <StreamSubscription<dynamic>?>[
      _positionSubscription,
      _durationSubscription,
      _playingSubscription,
      _completedSubscription,
      _rateSubscription,
      _videoParamsSubscription,
    ];
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _completedSubscription = null;
    _rateSubscription = null;
    _videoParamsSubscription = null;

    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    try {
      await seekDispatcher?.idle;
    } catch (_) {
      // A failed in-flight seek must not prevent the native player teardown.
    } finally {
      await player?.dispose();
    }
  }

  void _rememberPlaybackPosition(String jobId) {
    _appController.rememberPlaybackPosition(jobId, _position);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final job = controller.allJobs
        .where((item) => item.id == widget.jobId)
        .firstOrNull;
    final document = job?.document;
    if (job == null || document == null) return const SizedBox.shrink();
    _ensureTokenMap(document);
    final query = _search.text.trim().toLowerCase();
    final segments = query.isEmpty
        ? document.segments
        : document.segments
              .where(
                (segment) =>
                    segment.text.toLowerCase().contains(query) ||
                    (segment.translatedText?.toLowerCase().contains(query) ??
                        false) ||
                    context.strings
                        .speakerName(document.speakerName(segment.speaker))
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
    final currentIndex = query.isEmpty
        ? currentTranscriptSegmentIndex(
            document.segments,
            _position.inMilliseconds,
            pinnedSegmentId: _repeatingSegmentId,
          )
        : null;
    return Column(
      key: const Key('transcript-review-surface'),
      children: [
        _UnifiedReviewToolbar(
          role: _ReviewToolbarRole.global,
          job: job,
          viewMode: _viewMode,
          showAiBrief: _showAiBrief,
          search: _search,
          searchVisible: _searchVisible,
          onTabChanged: (value) {
            if (value && _searchVisible) {
              _search.clear();
              _queueFocusCurrent(force: true);
            }
            setState(() {
              _showAiBrief = value;
              if (value) _searchVisible = false;
            });
          },
          onViewModeChanged: (value) => setState(() => _viewMode = value),
          onOpenSearch: () => setState(() => _searchVisible = true),
          onCloseSearch: _closeTranscriptSearch,
          onSearch: () {
            setState(() {});
            if (_search.text.trim().isEmpty) {
              _queueFocusCurrent(force: true);
            }
          },
          onFocusCurrentSentence: document.segments.isEmpty
              ? null
              : _focusCurrentSentence,
          onGenerateAiBrief: () => _showAiBriefDialog(job),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final hasVideo = job.metadata?.hasVideo ?? false;
              final canSwitchMediaMode = _supportsMediaModeSwitch(job);
              final audioMode =
                  canSwitchMediaMode && _mediaMode == _ReviewMediaMode.audio;
              final transcriptPane = _buildTranscriptPane(
                controller: controller,
                job: job,
                document: document,
                query: query,
                segments: segments,
                currentIndex: currentIndex,
                showFilename: !hasVideo || audioMode,
              );
              final aiBriefPane = _buildAiBriefPane(
                job: job,
                document: document,
              );
              final companionAvailable =
                  constraints.maxWidth >=
                  (_minimumCompanionPaneWidth * 2 + _reviewDividerWidth);
              final companionActive = _showAiBrief && companionAvailable;
              final audioCompanion =
                  companionAvailable && (!hasVideo || audioMode);
              _companionLayoutActive = companionActive || audioCompanion;

              if (audioCompanion) {
                return Column(
                  key: const Key('audio-review-companion'),
                  children: [
                    KeyedSubtree(
                      key: const Key('audio-review-media'),
                      child: _buildMediaArea(
                        job,
                        presentation: _ReviewMediaMode.audio,
                        fillHeight: false,
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _buildCompanionSplit(
                        width: constraints.maxWidth,
                        left: transcriptPane,
                        right: aiBriefPane,
                        showRight: _showAiBrief,
                      ),
                    ),
                  ],
                );
              }

              if (companionActive) {
                return _buildVideoCompanion(
                  constraints: constraints,
                  job: job,
                  transcriptPane: transcriptPane,
                  aiBriefPane: aiBriefPane,
                );
              }

              final selectedPane = IndexedStack(
                key: const Key('review-tabbed-content'),
                index: _showAiBrief ? 1 : 0,
                sizing: StackFit.expand,
                children: [transcriptPane, aiBriefPane],
              );
              if (!hasVideo) {
                return Column(
                  key: const Key('video-review-stacked'),
                  children: [
                    _buildMediaArea(
                      job,
                      presentation: _ReviewMediaMode.audio,
                      fillHeight: false,
                    ),
                    const Divider(height: 1),
                    Expanded(child: selectedPane),
                  ],
                );
              }

              final sideBySide = constraints.maxWidth >= 840;
              final availableWidth = constraints.maxWidth - _reviewDividerWidth;
              final maximumPaneWidth = availableWidth - _minimumReviewPaneWidth;
              final preferredTranscriptWidth =
                  _transcriptPaneWidth ?? availableWidth * .45;
              final transcriptWidth = sideBySide
                  ? preferredTranscriptWidth
                        .clamp(_minimumReviewPaneWidth, maximumPaneWidth)
                        .toDouble()
                  : constraints.maxWidth;
              if (sideBySide && _transcriptPaneWidth == null) {
                _transcriptPaneWidth = transcriptWidth;
              }
              final videoWidth = sideBySide
                  ? availableWidth - transcriptWidth
                  : constraints.maxWidth;
              final stackedVideoHeight = (constraints.maxHeight * .4)
                  .clamp(180.0, 300.0)
                  .toDouble();
              final stackedMediaHeight =
                  _videoTitleHeaderHeight +
                  1 +
                  stackedVideoHeight +
                  VideoTransport.height;
              final videoMediaRect = sideBySide
                  ? Rect.fromLTWH(0, 0, videoWidth, constraints.maxHeight)
                  : Rect.fromLTWH(
                      0,
                      0,
                      constraints.maxWidth,
                      stackedMediaHeight,
                    );
              final videoTranscriptTop = sideBySide
                  ? 0.0
                  : stackedMediaHeight + 1;
              final videoTranscriptRect = Rect.fromLTWH(
                sideBySide ? videoWidth + _reviewDividerWidth : 0,
                videoTranscriptTop,
                sideBySide ? transcriptWidth : constraints.maxWidth,
                (constraints.maxHeight - videoTranscriptTop)
                    .clamp(0.0, constraints.maxHeight)
                    .toDouble(),
              );
              final audioMediaHeight = File(job.sourcePath).existsSync()
                  ? AudioTransport.height
                  : _missingSourceAudioHeight;
              final audioMediaRect = Rect.fromLTWH(
                0,
                0,
                constraints.maxWidth,
                audioMediaHeight,
              );
              final audioTranscriptRect = Rect.fromLTWH(
                0,
                audioMediaHeight + 1,
                constraints.maxWidth,
                (constraints.maxHeight - audioMediaHeight - 1)
                    .clamp(0.0, constraints.maxHeight)
                    .toDouble(),
              );
              final media = _buildMediaArea(
                job,
                presentation: audioMode
                    ? _ReviewMediaMode.audio
                    : _ReviewMediaMode.video,
                fillHeight: !audioMode && sideBySide,
                videoHeight: sideBySide ? null : stackedVideoHeight,
              );
              final layoutMarkerKey = audioMode
                  ? const Key('audio-review-layout')
                  : sideBySide
                  ? const Key('video-review-split')
                  : const Key('video-review-stacked');

              return TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: audioMode ? 1.0 : 0.0),
                duration: _mediaModeTransitionDuration,
                curve: Curves.easeInOutCubic,
                builder: (context, progress, _) {
                  final mediaRect = Rect.lerp(
                    videoMediaRect,
                    audioMediaRect,
                    progress,
                  )!;
                  final transcriptRect = Rect.lerp(
                    videoTranscriptRect,
                    audioTranscriptRect,
                    progress,
                  )!;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned.fill(
                        key: const ValueKey('review-layout-marker-slot'),
                        child: IgnorePointer(
                          child: SizedBox.expand(key: layoutMarkerKey),
                        ),
                      ),
                      Positioned.fromRect(
                        key: const ValueKey('video-mode-switcher-marker-slot'),
                        rect: videoMediaRect,
                        child: IgnorePointer(
                          child: audioMode
                              ? const SizedBox.shrink()
                              : const SizedBox.expand(
                                  key: Key('video-audio-mode-switcher'),
                                ),
                        ),
                      ),
                      Positioned.fromRect(
                        key: const ValueKey('animated-media-slot'),
                        rect: mediaRect,
                        child: SizedBox.expand(
                          key: const Key('video-review-media-pane'),
                          child: ClipRect(
                            child: KeyedSubtree(
                              key: ValueKey(
                                audioMode
                                    ? 'video-audio-mode-audio'
                                    : 'video-audio-mode-video',
                              ),
                              child: media,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fromRect(
                        key: const ValueKey('animated-transcript-slot'),
                        rect: transcriptRect,
                        child: SizedBox.expand(
                          key: const Key('video-review-transcript-pane'),
                          child: selectedPane,
                        ),
                      ),
                      Positioned(
                        key: const ValueKey('vertical-divider-slot'),
                        left: videoWidth * (1 - progress),
                        top: 0,
                        width: _reviewDividerWidth,
                        height: constraints.maxHeight,
                        child: sideBySide
                            ? IgnorePointer(
                                ignoring: progress > 0,
                                child: Opacity(
                                  opacity: 1 - progress,
                                  child: _ReviewSplitDivider(
                                    onDragUpdate: (delta) => _resizeReviewPanes(
                                      delta,
                                      availableWidth,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      Positioned(
                        key: const ValueKey('horizontal-divider-slot'),
                        left: 0,
                        top: transcriptRect.top - 1,
                        width: constraints.maxWidth,
                        height: 1,
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: sideBySide ? progress : 1,
                            child: Divider(
                              height: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _resizeReviewPanes(double delta, double availableWidth) {
    final maximumPaneWidth = availableWidth - _minimumReviewPaneWidth;
    final currentWidth = (_transcriptPaneWidth ?? availableWidth * .45).clamp(
      _minimumReviewPaneWidth,
      maximumPaneWidth,
    );
    final nextWidth = (currentWidth - delta)
        .clamp(_minimumReviewPaneWidth, maximumPaneWidth)
        .toDouble();
    setState(() => _transcriptPaneWidth = nextWidth);
  }

  Widget _buildCompanionSplit({
    required double width,
    required Widget left,
    required Widget right,
    bool showRight = true,
  }) {
    final availableWidth = width - _reviewDividerWidth;
    final leftWidth = showRight
        ? _resolvedCompanionLeftWidth(availableWidth)
        : width;
    return Row(
      key: const Key('ai-brief-companion-split'),
      children: [
        SizedBox(
          key: const Key('ai-brief-companion-source-pane'),
          width: leftWidth,
          child: left,
        ),
        if (showRight) ...[
          _ReviewSplitDivider(
            dividerKey: const Key('ai-brief-companion-divider'),
            onDragUpdate: (delta) =>
                _resizeCompanionPanes(delta, availableWidth),
          ),
          Expanded(
            child: SizedBox.expand(
              key: const Key('ai-brief-companion-brief-pane'),
              child: right,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVideoCompanion({
    required BoxConstraints constraints,
    required TranscriptionJob job,
    required Widget transcriptPane,
    required Widget aiBriefPane,
  }) {
    final availableWidth = constraints.maxWidth - _reviewDividerWidth;
    final leftWidth = _resolvedCompanionLeftWidth(availableWidth);
    final aspect = _videoAspectRatio.isFinite && _videoAspectRatio > 0
        ? _videoAspectRatio
        : 16 / 9;
    final availableViewportHeight =
        (constraints.maxHeight -
                _videoTitleHeaderHeight -
                VideoTransport.height -
                2)
            .clamp(0.0, double.infinity)
            .toDouble();
    final viewportHeight = videoViewportHeight(
      width: leftWidth,
      aspectRatio: aspect,
      availableHeight: availableViewportHeight,
    );
    final mediaHeight =
        _videoTitleHeaderHeight + 1 + viewportHeight + VideoTransport.height;
    final sourcePane = Column(
      key: const Key('video-ai-brief-source-column'),
      children: [
        SizedBox(
          key: const Key('video-ai-brief-media'),
          height: mediaHeight,
          child: _buildMediaArea(
            job,
            presentation: _ReviewMediaMode.video,
            fillHeight: true,
            videoHeight: viewportHeight,
          ),
        ),
        const Divider(height: 1),
        Expanded(child: transcriptPane),
      ],
    );
    return KeyedSubtree(
      key: const Key('video-ai-brief-companion'),
      child: _buildCompanionSplit(
        width: constraints.maxWidth,
        left: sourcePane,
        right: aiBriefPane,
      ),
    );
  }

  double _resolvedCompanionLeftWidth(double availableWidth) {
    final maximumLeftWidth = availableWidth - _minimumCompanionPaneWidth;
    final preferred = availableWidth * (_companionLeftPaneFraction ?? .5);
    return preferred
        .clamp(_minimumCompanionPaneWidth, maximumLeftWidth)
        .toDouble();
  }

  void _resizeCompanionPanes(double delta, double availableWidth) {
    final maximumLeftWidth = availableWidth - _minimumCompanionPaneWidth;
    final currentWidth = _resolvedCompanionLeftWidth(availableWidth);
    final nextWidth = (currentWidth + delta)
        .clamp(_minimumCompanionPaneWidth, maximumLeftWidth)
        .toDouble();
    setState(() => _companionLeftPaneFraction = nextWidth / availableWidth);
  }

  Widget _buildMediaArea(
    TranscriptionJob job, {
    required _ReviewMediaMode presentation,
    required bool fillHeight,
    double? videoHeight,
  }) {
    final hasVideo = job.metadata?.hasVideo ?? false;
    final canSwitchMediaMode = _supportsMediaModeSwitch(job);
    final audioMode =
        canSwitchMediaMode && presentation == _ReviewMediaMode.audio;
    final showVideoTitle = hasVideo && !audioMode;

    Widget withVideoTitle(Widget child) {
      if (!showVideoTitle) return child;
      return Column(
        children: [
          _VideoMediaHeader(job: job),
          const Divider(height: 1),
          if (fillHeight) Expanded(child: child) else child,
        ],
      );
    }

    if (!File(job.sourcePath).existsSync()) {
      final banner = MaterialBanner(
        content: Text(context.strings.t('source_missing')),
        leading: const Icon(Icons.link_off_rounded),
        actions: [
          if (canSwitchMediaMode)
            _MediaModeButton(
              destination: audioMode
                  ? _ReviewMediaMode.video
                  : _ReviewMediaMode.audio,
              onPressed: () => _toggleMediaMode(job),
            ),
          TextButton(
            onPressed: () async {
              final linked = await chooseAndRelink(context, job.id);
              if (!linked || !context.mounted) return;
              _openedPath = '';
              await _openSource();
            },
            child: Text(context.strings.t('relink')),
          ),
        ],
      );
      final missingSource = fillHeight
          ? Align(alignment: Alignment.topCenter, child: banner)
          : banner;
      return withVideoTitle(missingSource);
    }
    if (_player == null || _video == null) {
      if (_mediaShutdown == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openSource());
        });
      }
      return withVideoTitle(
        SizedBox(
          height: fillHeight ? null : 64,
          child: const Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final mediaDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(milliseconds: job.metadata?.durationMs ?? 0);
    final audio = AudioTransport(
      playing: _playing,
      position: _position,
      duration: mediaDuration,
      waveformPath: _waveformPath,
      waveformLoading: _waveformLoading,
      onPlayPause: _player!.playOrPause,
      onSeek: _seek,
      onSwitchToVideoMode: audioMode ? () => _toggleMediaMode(job) : null,
    );
    if (audioMode) return audio;
    late final Widget pane;
    if (hasVideo) {
      final video = _MediaPane(
        job: job,
        video: _video!,
        videoKey: _videoKey,
        videoAspectRatio: _videoAspectRatio,
        maxVideoHeight: videoHeight,
        centerInAvailableHeight: fillHeight,
        playing: _playing,
        playbackRate: _playbackRate,
        position: _position,
        duration: _duration,
        onPlayPause: _player!.playOrPause,
        onSeek: _seek,
        onFullscreen: _toggleFullscreen,
        onPlaybackRateChanged: _setPlaybackRate,
        onEnterNativeFullscreen: _enterNativeFullscreen,
        onExitNativeFullscreen: _exitNativeFullscreen,
        onSwitchToAudioMode: canSwitchMediaMode
            ? () => _toggleMediaMode(job)
            : null,
        controls: _videoControls,
      );
      pane = withVideoTitle(video);
    } else {
      pane = audio;
    }
    if (!fillHeight && hasVideo) {
      return SizedBox(
        height:
            _videoTitleHeaderHeight +
            1 +
            (videoHeight ?? 180) +
            VideoTransport.height,
        child: pane,
      );
    }
    return pane;
  }

  Widget _buildTranscriptPane({
    required AppController controller,
    required TranscriptionJob job,
    required TranscriptDocument document,
    required String query,
    required List<TranscriptSegment> segments,
    required int? currentIndex,
    required bool showFilename,
  }) {
    final transcript = Column(
      children: [
        if (job.translationState.status != TranslationStatus.idle &&
            job.translationState.status != TranslationStatus.completed)
          _TranslationStatusStrip(job: job),
        if (controller.settings.showSpeakers && document.speakers.isNotEmpty)
          SpeakerStrip(job: job, document: document),
        Expanded(
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _suspendFollow();
            },
            child: NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                if (_programmaticScrolls == 0 &&
                    notification.direction != ScrollDirection.idle) {
                  _suspendFollow();
                }
                return false;
              },
              child: SelectionArea(
                child: ScrollablePositionedList.separated(
                  key: const Key('transcript-scroll'),
                  itemScrollController: _transcriptScroll,
                  itemPositionsListener: _transcriptPositions,
                  initialScrollIndex: currentIndex ?? 0,
                  initialAlignment: currentIndex == null || currentIndex == 0
                      ? 0
                      : .5,
                  scrollDirection: Axis.vertical,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  itemCount: segments.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final segment = segments[index];
                    return _TranscriptSegmentGroup(
                      key: ValueKey('group-${segment.id}'),
                      segment: segment,
                      tokens: _tokensBySegment[segment.id] ?? const [],
                      positionMs: _position.inMilliseconds,
                      isCurrent: query.isEmpty && index == currentIndex,
                      viewMode: _viewMode,
                      query: query,
                      speakerName: context.strings.speakerName(
                        document.speakerName(segment.speaker),
                      ),
                      speakers: document.speakers,
                      showSpeaker: controller.settings.showSpeakers,
                      showTimestamp: controller.settings.showTimestamps,
                      highlightTranslated:
                          job.translationState.status.isActive &&
                          segment.hasTranslation,
                      isEditingOriginal: _editingSegmentId == segment.id,
                      isEditingTranslation:
                          _editingTranslationSegmentId == segment.id,
                      isRepeating: _repeatingSegmentId == segment.id,
                      onToggleRepeat: _canRepeat(segment)
                          ? () => _toggleSentenceRepeat(segment)
                          : null,
                      onSeek: ({required reason}) => unawaited(
                        _seek(
                          Duration(milliseconds: segment.startMs),
                          reason: reason,
                        ),
                      ),
                      onEditOriginal: () => _startEditing(segment.id),
                      onCancelOriginal: () => _cancelEditing(segment.id),
                      onSaveOriginal: (text) => _saveSegment(segment.id, text),
                      onSpeakerChanged: (speakerId) =>
                          _saveSegmentSpeaker(segment.id, speakerId),
                      onEditTranslation: () =>
                          _startTranslationEditing(segment.id),
                      onCancelTranslation: () =>
                          _cancelTranslationEditing(segment.id),
                      onSaveTranslation: (text) =>
                          _saveTranslation(segment.id, text),
                      onRetranslate:
                          job.translationState.status.isActive ||
                              !controller.translationConfigured
                          ? null
                          : () => context
                                .read<AppController>()
                                .retranslateSegment(widget.jobId, segment.id),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Column(
      key: const Key('transcript-pane'),
      children: [
        _UnifiedReviewToolbar(
          role: _ReviewToolbarRole.transcript,
          job: job,
          viewMode: _viewMode,
          showAiBrief: _showAiBrief,
          search: _search,
          searchVisible: _searchVisible,
          onTabChanged: (_) {},
          onViewModeChanged: (value) => setState(() => _viewMode = value),
          onOpenSearch: () => setState(() => _searchVisible = true),
          onCloseSearch: _closeTranscriptSearch,
          onSearch: () {
            setState(() {});
            if (_search.text.trim().isEmpty) {
              _queueFocusCurrent(force: true);
            }
          },
          onFocusCurrentSentence: document.segments.isEmpty
              ? null
              : _focusCurrentSentence,
          onGenerateAiBrief: () => _showAiBriefDialog(job),
          showFilename: showFilename,
        ),
        const Divider(height: 1),
        Expanded(child: transcript),
      ],
    );
  }

  Widget _buildAiBriefPane({
    required TranscriptionJob job,
    required TranscriptDocument document,
  }) => Column(
    key: const Key('ai-brief-pane'),
    children: [
      _UnifiedReviewToolbar(
        role: _ReviewToolbarRole.aiBrief,
        job: job,
        viewMode: _viewMode,
        showAiBrief: _showAiBrief,
        search: _search,
        searchVisible: _searchVisible,
        onTabChanged: (_) {},
        onViewModeChanged: (value) => setState(() => _viewMode = value),
        onOpenSearch: () => setState(() => _searchVisible = true),
        onCloseSearch: _closeTranscriptSearch,
        onSearch: () => setState(() {}),
        onFocusCurrentSentence: document.segments.isEmpty
            ? null
            : _focusCurrentSentence,
        onGenerateAiBrief: () => _showAiBriefDialog(job),
      ),
      const Divider(height: 1),
      Expanded(
        child: _AiBriefPane(
          job: job,
          document: document,
          scrollController: _aiBriefScroll,
          onGenerate: () => _showAiBriefDialog(job),
          onEvidence: _openAiEvidence,
        ),
      ),
    ],
  );

  Future<void> _showAiBriefDialog(TranscriptionJob job) async {
    final controller = context.read<AppController>();
    if (!controller.aiBriefConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('ai_brief_configure'))),
      );
      return;
    }
    final result = await _showAiBriefGenerationDialog(context, job);
    if (result == null || !mounted) return;
    if (job.aiBrief?.edited ?? false) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.strings.t('ai_brief_edited_refresh_title')),
          content: Text(context.strings.t('ai_brief_edited_refresh_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.t('continue')),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    setState(() {
      _showAiBrief = true;
      _searchVisible = false;
    });
    unawaited(
      controller.generateAiBrief(
        job.id,
        sections: result.sections,
        outputLanguage: result.outputLanguage,
        learningLanguage: result.learningLanguage,
        learningLevel: result.learningLevel,
      ),
    );
  }

  Future<void> _openAiEvidence(String segmentId) async {
    final document = _document;
    final segment = document?.segments
        .where((item) => item.id == segmentId)
        .firstOrNull;
    if (segment == null) return;
    final keepCompanionOpen = _showAiBrief && _companionLayoutActive;
    setState(() {
      if (!keepCompanionOpen) _showAiBrief = false;
      _searchVisible = false;
      _search.clear();
      _followPlayback = true;
    });
    await _seek(Duration(milliseconds: segment.startMs));
    _queueFocusCurrent(force: true);
  }

  Widget _buildVideoControls(VideoState _) {
    return _ReviewFullscreenControlsHost(
      playback: _playbackTick,
      isActive: () => _fullscreenController.isActive,
      overlay: _fullscreenOverlay,
    );
  }

  Widget _fullscreenOverlay() {
    final document = _document;
    if (document == null) return const SizedBox.shrink();
    final job = _appController.jobById(widget.jobId);
    final mediaDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(milliseconds: job?.metadata?.durationMs ?? 0);
    return VideoFullscreenKeyboardRegion(
      subtitle: fullscreenTranscriptSubtitle(
        document.segments,
        _position.inMilliseconds,
        _viewMode,
        pinnedSegmentId: _repeatingSegment?.id,
      ),
      subtitleHighlight: fullscreenTranscriptWordRange(
        document,
        _position.inMilliseconds,
        _viewMode,
        pinnedSegmentId: _repeatingSegment?.id,
      ),
      playing: _playing,
      position: _position,
      duration: mediaDuration,
      onExit: () => unawaited(_fullscreenController.exit()),
      onPlayPause: () =>
          unawaited(_player?.playOrPause() ?? Future<void>.value()),
      onSeek: (value) => unawaited(_seek(value)),
      onSeekBackward: () =>
          unawaited(_seekRelative(-const Duration(seconds: 5))),
      onSeekForward: () => unawaited(_seekRelative(const Duration(seconds: 5))),
      onDecreaseSpeed: () => unawaited(_changePlaybackRate(-.25)),
      onIncreaseSpeed: () => unawaited(_changePlaybackRate(.25)),
      onRepeatHoldStart: _beginHoldingCurrentSentence,
      onRepeatHoldEnd: _endSentenceRepeatHold,
      child: const SizedBox.expand(),
    );
  }

  Future<void> _toggleFullscreen() async {
    final videoState = _videoKey.currentState;
    if (videoState != null && !_fullscreenController.isActive) {
      await videoState.enterFullscreen();
    }
  }

  Future<void> _enterNativeFullscreen() async {
    final navigator = _rootNavigator;
    if (navigator != null && navigator.mounted) {
      _fullscreenController.markEntered(navigator);
      _playbackTick.tick();
    }
    await defaultEnterNativeFullscreen();
  }

  Future<void> _exitNativeFullscreen() async {
    _endSentenceRepeatHold();
    _fullscreenController.markExited();
    _playbackTick.tick();
    await defaultExitNativeFullscreen();
  }

  Future<void> _seek(
    Duration position, {
    TranscriptSeekReason reason = TranscriptSeekReason.standard,
  }) async {
    final seekDispatcher = _seekDispatcher;
    if (seekDispatcher == null) return;
    setState(() {
      _position = position;
      _followPlayback = true;
    });
    _appController.rememberPlaybackPosition(widget.jobId, position);
    if (shouldFocusTranscriptAfterSeek(reason)) {
      _queueFocusCurrent(force: true);
    }
    await seekDispatcher.seek(position);
  }

  bool _canRepeat(TranscriptSegment segment) =>
      _player != null && segment.endMs > segment.startMs;

  void _toggleSentenceRepeat(TranscriptSegment segment) {
    if (_manualRepeatingSegmentId == segment.id) {
      setState(() {
        _manualRepeatingSegmentId = null;
        _repeatRestartQueued = false;
        _repeatRestartQueuedResume = false;
      });
      return;
    }
    if (!_canRepeat(segment)) return;
    setState(() => _manualRepeatingSegmentId = segment.id);
    _queueRepeatRestart(resumeAfterSeek: true);
  }

  bool _handleReviewShortcut(KeyEvent event) {
    if (_fullscreenController.isActive) return false;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      return _handlePlayPauseShortcut(event);
    }
    if (event.logicalKey != LogicalKeyboardKey.keyR) {
      return false;
    }
    if (event is KeyUpEvent) {
      if (_heldRepeatingSegmentId == null) return false;
      _endSentenceRepeatHold();
      return true;
    }
    if (_appController.destination != AppDestination.workspace ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    if (primaryFocusIsEditable()) return false;
    if (event is KeyRepeatEvent) {
      return _heldRepeatingSegmentId != null;
    }
    if (event is! KeyDownEvent || shortcutModifierPressed()) {
      return false;
    }
    return _beginHoldingCurrentSentence();
  }

  bool _handlePlayPauseShortcut(KeyEvent event) {
    final player = _player;
    if (player == null ||
        _appController.destination != AppDestination.workspace ||
        ModalRoute.of(context)?.isCurrent == false ||
        primaryFocusIsEditable() ||
        shortcutModifierPressed()) {
      return false;
    }
    if (event is KeyDownEvent) {
      unawaited(player.playOrPause());
      return true;
    }
    return event is KeyRepeatEvent || event is KeyUpEvent;
  }

  bool _beginHoldingCurrentSentence() {
    if (_heldRepeatingSegmentId != null) return true;
    final document = _document;
    final player = _player;
    if (document == null || player == null) return false;
    final index = currentTranscriptSegmentIndex(
      document.segments,
      _position.inMilliseconds,
    );
    if (index == null) return false;
    final segment = document.segments[index];
    if (!_canRepeat(segment)) return false;
    setState(() => _heldRepeatingSegmentId = segment.id);
    unawaited(_ensurePlaybackContinues(player));
    return true;
  }

  void _endSentenceRepeatHold({bool notify = true}) {
    final heldSegmentId = _heldRepeatingSegmentId;
    if (heldSegmentId == null) return;
    final restoredSegmentId = _manualRepeatingSegmentId;
    final player = _player;
    if (notify && mounted) {
      setState(() => _heldRepeatingSegmentId = null);
    } else {
      _heldRepeatingSegmentId = null;
    }
    _repeatRestartQueued = false;
    _repeatRestartQueuedResume = false;
    if (notify &&
        restoredSegmentId != null &&
        restoredSegmentId != heldSegmentId) {
      _queueRepeatRestart(resumeAfterSeek: _player?.state.playing ?? false);
    }
    if (notify && player != null) {
      unawaited(_ensurePlaybackContinues(player));
    }
  }

  Future<void> _ensurePlaybackContinues(Player player) async {
    try {
      await _seekDispatcher?.idle;
    } on Object {
      return;
    }
    if (!mounted || !identical(_player, player) || player.state.playing) return;
    try {
      await player.play();
    } on Object {
      // Media teardown can race a lost key-up during navigation or shutdown.
    }
  }

  void _queueRepeatRestart({bool resumeAfterSeek = false}) {
    if (_repeatRestartPending) {
      _repeatRestartQueued = true;
      _repeatRestartQueuedResume |= resumeAfterSeek;
      return;
    }
    unawaited(_restartRepeatedSentence(resumeAfterSeek: resumeAfterSeek));
  }

  Future<void> _restartRepeatedSentence({required bool resumeAfterSeek}) async {
    final player = _player;
    final segment = _repeatingSegment;
    if (player == null || segment == null || segment.endMs <= segment.startMs) {
      return;
    }
    final segmentId = segment.id;
    _repeatRestartPending = true;
    try {
      await _seek(
        Duration(
          milliseconds: sentenceRepeatStartMs(
            segment,
            previousSegment: _previousSegmentFor(segment),
          ),
        ),
        reason: TranscriptSeekReason.repeatRestart,
      );
      if (!mounted || _repeatingSegmentId != segmentId) return;
      if (resumeAfterSeek && !player.state.playing) await player.play();
    } finally {
      _repeatRestartPending = false;
      if (_repeatRestartQueued && mounted && _repeatingSegmentId != null) {
        final resumeQueued = _repeatRestartQueuedResume;
        _repeatRestartQueued = false;
        _repeatRestartQueuedResume = false;
        _queueRepeatRestart(resumeAfterSeek: resumeQueued);
      } else {
        _repeatRestartQueued = false;
        _repeatRestartQueuedResume = false;
      }
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final player = _player;
    if (player == null) return;
    final state = player.state;
    final durationMs = state.duration.inMilliseconds;
    final requestedMs = state.position.inMilliseconds + offset.inMilliseconds;
    final upperBound = durationMs > 0
        ? durationMs
        : requestedMs > 0
        ? requestedMs
        : 0;
    final targetMs = requestedMs.clamp(0, upperBound).toInt();
    await _seek(Duration(milliseconds: targetMs));
  }

  Future<void> _changePlaybackRate(double step) async {
    final player = _player;
    if (player == null) return;
    final rate = (player.state.rate + step).clamp(.5, 2.0).toDouble();
    await _setPlaybackRate(rate);
  }

  Future<void> _setPlaybackRate(double value) async {
    final player = _player;
    if (player == null) return;
    final rate = value.clamp(.5, 2.0).toDouble();
    if ((rate - player.state.rate).abs() < .001) return;
    await player.setRate(rate);
  }

  void _focusCurrentSentence() {
    _search.clear();
    setState(() {
      _searchVisible = false;
      _followPlayback = true;
    });
    _queueFocusCurrent(force: true);
  }

  void _closeTranscriptSearch() {
    _search.clear();
    setState(() => _searchVisible = false);
    _queueFocusCurrent(force: true);
  }

  void _suspendFollow() {
    if (!mounted || !_followPlayback) return;
    setState(() => _followPlayback = false);
  }

  void _queueFocusCurrent({bool force = false}) {
    _forceFocusQueued |= force;
    if (_focusFrameQueued) return;
    _focusFrameQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final forceQueued = _forceFocusQueued;
      _focusFrameQueued = false;
      _forceFocusQueued = false;
      if (mounted) unawaited(_scrollToCurrent(force: forceQueued));
    });
  }

  Future<void> _scrollToCurrent({bool force = false}) async {
    if (!_followPlayback ||
        _search.text.trim().isNotEmpty ||
        !_transcriptScroll.isAttached) {
      return;
    }
    final document = _document;
    if (document == null || document.segments.isEmpty) return;
    final index =
        currentTranscriptSegmentIndex(
          document.segments,
          _position.inMilliseconds,
        ) ??
        0;
    final segmentId = document.segments[index].id;
    if (!force && segmentId == _lastScrolledSegmentId) return;
    _lastScrolledSegmentId = segmentId;
    final currentPosition = _transcriptPositions.itemPositions.value
        .where((position) => position.index == index)
        .firstOrNull;
    if (currentPosition != null &&
        currentPosition.itemLeadingEdge >= 0 &&
        currentPosition.itemTrailingEdge <= 1) {
      return;
    }
    _programmaticScrolls++;
    try {
      _transcriptScroll.jumpTo(index: index, alignment: index == 0 ? 0 : .5);
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _programmaticScrolls--;
    }
  }

  void _startEditing(String segmentId) {
    setState(() {
      _editingSegmentId = segmentId;
      _editingTranslationSegmentId = null;
      _followPlayback = false;
    });
  }

  void _cancelEditing(String segmentId) {
    if (_editingSegmentId == segmentId) {
      setState(() => _editingSegmentId = null);
    }
  }

  Future<void> _saveSegment(String segmentId, String text) async {
    try {
      await context.read<AppController>().updateSegment(
        widget.jobId,
        segmentId,
        text,
      );
      if (mounted && _editingSegmentId == segmentId) {
        setState(() => _editingSegmentId = null);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('error_unexpected'))),
      );
    }
  }

  Future<void> _saveSegmentSpeaker(String segmentId, String speakerId) async {
    try {
      await context.read<AppController>().updateSegmentSpeaker(
        widget.jobId,
        segmentId,
        speakerId,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('error_unexpected'))),
      );
    }
  }

  void _startTranslationEditing(String segmentId) {
    setState(() {
      _editingSegmentId = null;
      _editingTranslationSegmentId = segmentId;
      _followPlayback = false;
    });
  }

  void _cancelTranslationEditing(String segmentId) {
    if (_editingTranslationSegmentId == segmentId) {
      setState(() => _editingTranslationSegmentId = null);
    }
  }

  Future<void> _saveTranslation(String segmentId, String text) async {
    try {
      await context.read<AppController>().updateTranslatedSegment(
        widget.jobId,
        segmentId,
        text,
      );
      if (mounted && _editingTranslationSegmentId == segmentId) {
        setState(() => _editingTranslationSegmentId = null);
      }
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('error_unexpected'))),
      );
    }
  }

  void _ensureTokenMap(TranscriptDocument document) {
    if (identical(_mappedDocument, document)) return;
    _mappedDocument = document;
    final result = <String, List<TranscriptToken>>{
      for (final segment in document.segments) segment.id: [],
    };
    var segmentIndex = 0;
    for (final token in document.tokens) {
      if (token.startMs == 0 && token.endMs == 0 && token.segmentId == null) {
        continue;
      }
      final ownedSegmentId = token.segmentId;
      if (ownedSegmentId != null && result.containsKey(ownedSegmentId)) {
        result[ownedSegmentId]!.add(token);
        continue;
      }
      while (segmentIndex + 1 < document.segments.length &&
          token.startMs >= document.segments[segmentIndex + 1].startMs) {
        segmentIndex++;
      }
      if (document.segments.isEmpty) break;
      final segment = document.segments[segmentIndex];
      if (token.startMs >= segment.startMs && token.startMs <= segment.endMs) {
        result[segment.id]!.add(token);
      }
    }
    _tokensBySegment = {
      for (final entry in result.entries)
        entry.key: List.unmodifiable(entry.value),
    };
  }
}

class _ReviewSplitDivider extends StatelessWidget {
  const _ReviewSplitDivider({
    this.dividerKey = const Key('video-transcript-divider'),
    required this.onDragUpdate,
  });

  final Key dividerKey;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.strings.t('resize_review_panels'),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: dividerKey,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
        child: SizedBox(
          width: _TranscriptReviewState._reviewDividerWidth,
          child: Center(
            child: VerticalDivider(
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ReviewContentTabs extends StatelessWidget {
  const _ReviewContentTabs({
    required this.width,
    required this.showAiBrief,
    required this.onChanged,
  });

  final double width;
  final bool showAiBrief;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: SegmentedButton<bool>(
      key: const Key('review-content-tabs'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
      ),
      segments: [
        ButtonSegment(
          value: false,
          label: Text(
            context.strings.t('transcript'),
            maxLines: 1,
            softWrap: false,
          ),
        ),
        ButtonSegment(
          value: true,
          label: Text(
            context.strings.t('ai_brief'),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ],
      selected: {showAiBrief},
      onSelectionChanged: (values) => onChanged(values.first),
    ),
  );
}

class _AiBriefDialogResult {
  const _AiBriefDialogResult(
    this.sections,
    this.outputLanguage,
    this.learningLanguage,
    this.learningLevel,
  );

  final Set<AiBriefSection> sections;
  final String outputLanguage;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
}

Future<_AiBriefDialogResult?> _showAiBriefGenerationDialog(
  BuildContext context,
  TranscriptionJob job,
) async {
  final controller = context.read<AppController>();
  var sections = Set<AiBriefSection>.of(
    job.aiBrief?.selectedSections ??
        (job.sourceOrigin == JobSourceOrigin.podcast
            ? {AiBriefSection.languageNotes}
            : defaultAiBriefSections),
  );
  var outputLanguage =
      job.aiBrief?.outputLanguage ??
      (job.sourceOrigin == JobSourceOrigin.podcast
          ? 'zh-Hans'
          : controller.defaultAiBriefLanguage);
  var learningLanguage =
      job.aiBrief?.learningLanguage ??
      (job.sourceOrigin == JobSourceOrigin.podcast ? 'en' : null);
  var learningLevel =
      job.aiBrief?.learningLevel ?? AiLearningLevel.intermediate;
  if (learningLanguage != null &&
      !supportedTranslationLanguageCodes.contains(learningLanguage)) {
    learningLanguage = null;
  }
  if (!supportedTranslationLanguageCodes.contains(outputLanguage)) {
    outputLanguage = 'en';
  }
  return showDialog<_AiBriefDialogResult>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          title: Text(
            context.strings.t(
              job.aiBrief == null ? 'create_ai_brief' : 'refresh_ai_brief',
            ),
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(context.strings.t('ai_brief_description')),
                  const SizedBox(height: 16),
                  Text(
                    context.strings.t('ai_brief_sections'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final section in AiBriefSection.values)
                        FilterChip(
                          key: ValueKey('ai-brief-section-${section.name}'),
                          selected: sections.contains(section),
                          label: Text(
                            context.strings.t(
                              'ai_brief_section_${section.name}',
                            ),
                          ),
                          onSelected: (selected) => setDialogState(() {
                            if (selected) {
                              sections.add(section);
                            } else {
                              sections.remove(section);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (sections.contains(AiBriefSection.languageNotes)) ...[
                    DropdownButtonFormField<String>(
                      key: const Key('ai-brief-learning-language'),
                      initialValue: learningLanguage ?? '',
                      decoration: InputDecoration(
                        labelText: context.strings.t(
                          'ai_brief_learning_language',
                        ),
                        prefixIcon: const Icon(Icons.school_outlined),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(
                            context.strings.t(
                              'ai_brief_learning_language_auto',
                            ),
                          ),
                        ),
                        for (final code in supportedTranslationLanguageCodes)
                          DropdownMenuItem(
                            value: code,
                            child: Text(
                              context.strings.translationLanguageName(code),
                            ),
                          ),
                      ],
                      onChanged: (value) => setDialogState(
                        () => learningLanguage = value?.isEmpty ?? true
                            ? null
                            : value,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<AiLearningLevel>(
                      key: const Key('ai-brief-learning-level'),
                      initialValue: learningLevel,
                      decoration: InputDecoration(
                        labelText: context.strings.t('ai_brief_learning_level'),
                        prefixIcon: const Icon(Icons.trending_up_rounded),
                      ),
                      items: [
                        for (final level in AiLearningLevel.values)
                          DropdownMenuItem(
                            value: level,
                            child: Text(_learningLevelLabel(context, level)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => learningLevel = value);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  DropdownButtonFormField<String>(
                    key: const Key('ai-brief-output-language'),
                    initialValue: outputLanguage,
                    decoration: InputDecoration(
                      labelText: context.strings.t('ai_brief_output_language'),
                      prefixIcon: const Icon(Icons.language_rounded),
                    ),
                    items: [
                      for (final code in supportedTranslationLanguageCodes)
                        DropdownMenuItem(
                          value: code,
                          child: Text(
                            context.strings.translationLanguageName(code),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => outputLanguage = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.strings
                        .t('ai_brief_model')
                        .replaceFirst(
                          '{model}',
                          controller.settings.llmProviderSettings.model,
                        ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.strings.t('cancel')),
            ),
            FilledButton.icon(
              key: const Key('confirm-create-ai-brief'),
              onPressed: sections.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      _AiBriefDialogResult(
                        Set<AiBriefSection>.of(sections),
                        outputLanguage,
                        learningLanguage,
                        learningLevel,
                      ),
                    ),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(context.strings.t('generate')),
            ),
          ],
        );
      },
    ),
  );
}

class _AiBriefPane extends StatelessWidget {
  const _AiBriefPane({
    required this.job,
    required this.document,
    required this.scrollController,
    required this.onGenerate,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final ScrollController scrollController;
  final VoidCallback onGenerate;
  final Future<void> Function(String segmentId) onEvidence;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final state = job.aiGenerationState;
    final brief = job.aiBrief;
    if (brief == null && state.status.isActive) {
      return _AiBriefProgress(job: job);
    }
    if (brief == null) {
      return _AiBriefEmpty(job: job, onGenerate: onGenerate);
    }
    return Column(
      children: [
        if (brief.isStaleFor(document))
          MaterialBanner(
            key: const Key('ai-brief-outdated'),
            leading: const Icon(Icons.update_rounded),
            content: Text(context.strings.t('ai_brief_outdated')),
            actions: [
              TextButton(
                onPressed: state.status.isActive ? null : onGenerate,
                child: Text(context.strings.t('refresh_ai_brief')),
              ),
            ],
          ),
        if (state.status.isActive) _AiBriefProgress(job: job, compact: true),
        if (!state.status.isActive && state.errorCode != null)
          MaterialBanner(
            leading: Icon(
              state.status == AiGenerationStatus.cancelled
                  ? Icons.stop_circle_outlined
                  : Icons.error_outline_rounded,
            ),
            content: Text(
              context.strings.error(
                state.errorCode,
                englishFallback: state.errorMessage,
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () => controller.retryAiBrief(job.id),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.strings.t('retry')),
              ),
            ],
          ),
        Expanded(
          child: ListView(
            key: const Key('ai-brief-scroll'),
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_outlined, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.strings.t('ai_brief_draft'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (brief.overview.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'overview',
                  title: context.strings.t('overview'),
                  icon: Icons.summarize_outlined,
                  onEdit: () => _editOverview(context, job),
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.overview,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(brief.overview),
                      const SizedBox(height: 8),
                      _EvidenceChips(
                        document: document,
                        segmentIds: brief.overviewEvidenceSegmentIds,
                        onEvidence: onEvidence,
                      ),
                    ],
                  ),
                ),
              ],
              if (brief.chapters.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'chapters',
                  title: context.strings.t('chapters'),
                  icon: Icons.view_timeline_outlined,
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.chapters,
                        ),
                  child: Column(
                    children: [
                      for (final chapter in brief.chapters)
                        _AiChapterTile(
                          job: job,
                          document: document,
                          chapter: chapter,
                          onEvidence: onEvidence,
                        ),
                    ],
                  ),
                ),
              ],
              for (final type in AiInsightType.values)
                if (brief.insights.any((item) => item.type == type)) ...[
                  const SizedBox(height: 12),
                  _AiBriefSectionCard(
                    id: 'insight-${type.name}',
                    title: _insightTitle(context, type),
                    icon: _insightIcon(type),
                    onRegenerate: state.status.isActive
                        ? null
                        : () => _regenerateAiSection(
                            context,
                            job,
                            _sectionForInsight(type),
                          ),
                    child: Column(
                      children: [
                        for (final insight in brief.insights.where(
                          (item) => item.type == type,
                        ))
                          _AiInsightTile(
                            job: job,
                            document: document,
                            insight: insight,
                            onEvidence: onEvidence,
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => _addInsight(context, job, type),
                            icon: const Icon(Icons.add_rounded),
                            label: Text(context.strings.t('add_item')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              if (brief.languageNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'language-notes',
                  title: context.strings.t('language_notes'),
                  icon: Icons.menu_book_outlined,
                  headerMeta: Chip(
                    avatar: const Icon(Icons.trending_up_rounded, size: 16),
                    label: Text(
                      _learningLevelLabel(context, brief.learningLevel),
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.languageNotes,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final kind in AiLanguageNoteKind.values)
                        if (brief.languageNotes.any(
                          (item) => item.kind == kind,
                        )) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 12, 2, 4),
                            child: Text(
                              _languageNoteKindLabel(context, kind),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          for (final note in brief.languageNotes.where(
                            (item) => item.kind == kind,
                          ))
                            _AiLanguageNoteTile(
                              job: job,
                              document: document,
                              note: note,
                              onEvidence: onEvidence,
                            ),
                        ],
                    ],
                  ),
                ),
              ],
              if (brief.insights.isEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        _addInsight(context, job, AiInsightType.keyIdea),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(context.strings.t('add_item')),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AiBriefEmpty extends StatelessWidget {
  const _AiBriefEmpty({required this.job, required this.onGenerate});

  final TranscriptionJob job;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final state = job.aiGenerationState;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                context.strings.t('ai_brief_empty'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                context.strings.t('ai_brief_empty_body'),
                textAlign: TextAlign.center,
              ),
              if (state.errorCode != null) ...[
                const SizedBox(height: 12),
                Text(
                  context.strings.error(
                    state.errorCode,
                    englishFallback: state.errorMessage,
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('ai-brief-empty-action'),
                onPressed: controller.aiBriefConfigured ? onGenerate : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  context.strings.t(
                    state.status.canRetry ? 'retry' : 'create_ai_brief',
                  ),
                ),
              ),
              if (!controller.aiBriefConfigured) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      controller.setDestination(AppDestination.settings),
                  child: Text(context.strings.t('ai_brief_configure')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AiBriefProgress extends StatelessWidget {
  const _AiBriefProgress({required this.job, this.compact = false});

  final TranscriptionJob job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = job.aiGenerationState;
    final text = state.stage == 'synthesizing'
        ? context.strings.t('ai_brief_progress_synthesizing')
        : context.strings.t('ai_brief_progress_analyzing');
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(text)),
            TextButton.icon(
              onPressed: () =>
                  context.read<AppController>().cancelAiBrief(job.id),
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(context.strings.t('cancel')),
            ),
          ],
        ),
      ],
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: content,
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(padding: const EdgeInsets.all(24), child: content),
      ),
    );
  }
}

class _AiBriefSectionCard extends StatefulWidget {
  const _AiBriefSectionCard({
    required this.id,
    required this.title,
    required this.icon,
    this.headerMeta,
    this.onEdit,
    required this.onRegenerate,
    required this.child,
  });

  final String id;
  final String title;
  final IconData icon;
  final Widget? headerMeta;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final Widget child;

  @override
  State<_AiBriefSectionCard> createState() => _AiBriefSectionCardState();
}

class _AiBriefSectionCardState extends State<_AiBriefSectionCard> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _actionsFocused = false;

  bool get _showActions => _hovered || _menuOpen || _actionsFocused;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Card(
      key: ValueKey('ai-brief-section-${widget.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              key: ValueKey('ai-brief-section-header-${widget.id}'),
              children: [
                Icon(widget.icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (widget.headerMeta != null) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 2,
                          child: KeyedSubtree(
                            key: ValueKey('ai-brief-section-meta-${widget.id}'),
                            child: widget.headerMeta!,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.onEdit != null || widget.onRegenerate != null)
                  Focus(
                    onFocusChange: (value) =>
                        setState(() => _actionsFocused = value),
                    child: AnimatedOpacity(
                      key: ValueKey('ai-brief-section-actions-${widget.id}'),
                      opacity: _showActions ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: IgnorePointer(
                        ignoring: !_showActions,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.onEdit != null)
                              IconButton(
                                key: ValueKey(
                                  'ai-brief-section-edit-${widget.id}',
                                ),
                                tooltip: context.strings.t('edit'),
                                onPressed: widget.onEdit,
                                icon: const Icon(Icons.edit_outlined, size: 19),
                              ),
                            if (widget.onRegenerate != null)
                              PopupMenuButton<String>(
                                key: ValueKey(
                                  'ai-brief-section-menu-${widget.id}',
                                ),
                                tooltip: context.strings.t('more_actions'),
                                onOpened: () =>
                                    setState(() => _menuOpen = true),
                                onCanceled: () =>
                                    setState(() => _menuOpen = false),
                                onSelected: (value) {
                                  setState(() => _menuOpen = false);
                                  if (value == 'regenerate') {
                                    widget.onRegenerate?.call();
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'regenerate',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.refresh_rounded,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            context.strings.t(
                                              'regenerate_section',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 6, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AiChapterTile extends StatelessWidget {
  const _AiChapterTile({
    required this.job,
    required this.document,
    required this.chapter,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiChapter chapter;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: chapter.evidenceSegmentIds.isEmpty
                    ? null
                    : () => onEvidence(chapter.evidenceSegmentIds.first),
                child: Text(
                  _evidenceRange(document, chapter.evidenceSegmentIds),
                ),
              ),
              Expanded(
                child: Text(
                  chapter.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _editChapter(context, job, chapter);
                  if (value == 'delete') {
                    context.read<AppController>().deleteAiChapter(
                      job.id,
                      chapter.id,
                    );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.strings.t('edit')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.strings.t('delete_item')),
                  ),
                ],
              ),
            ],
          ),
          if (chapter.summary.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(chapter.summary),
            ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _EvidenceChips(
              document: document,
              segmentIds: chapter.evidenceSegmentIds,
              onEvidence: onEvidence,
            ),
          ),
        ],
      ),
    ),
  );
}

class _AiInsightTile extends StatelessWidget {
  const _AiInsightTile({
    required this.job,
    required this.document,
    required this.insight,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiInsight insight;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(insight.text)),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _editInsight(context, job, insight);
                  if (value == 'delete') {
                    context.read<AppController>().deleteAiInsight(
                      job.id,
                      insight.id,
                    );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.strings.t('edit_item')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.strings.t('delete_item')),
                  ),
                ],
              ),
            ],
          ),
          if ((insight.owner?.isNotEmpty ?? false) ||
              (insight.deadline?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [
                  if (insight.owner?.isNotEmpty ?? false)
                    Chip(
                      avatar: const Icon(Icons.person_outline, size: 16),
                      label: Text(insight.owner!),
                    ),
                  if (insight.deadline?.isNotEmpty ?? false)
                    Chip(
                      avatar: const Icon(Icons.event_outlined, size: 16),
                      label: Text(insight.deadline!),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          _EvidenceChips(
            document: document,
            segmentIds: insight.evidenceSegmentIds,
            onEvidence: onEvidence,
          ),
        ],
      ),
    ),
  );
}

class _AiLanguageNoteTile extends StatefulWidget {
  const _AiLanguageNoteTile({
    required this.job,
    required this.document,
    required this.note,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiLanguageNote note;
  final Future<void> Function(String) onEvidence;

  @override
  State<_AiLanguageNoteTile> createState() => _AiLanguageNoteTileState();
}

class _AiLanguageNoteTileState extends State<_AiLanguageNoteTile> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _menuFocused = false;

  bool get _showMenu => _hovered || _menuOpen || _menuFocused;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Card.outlined(
      key: ValueKey('ai-language-note-${widget.note.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    widget.note.term,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Focus(
                  onFocusChange: (value) =>
                      setState(() => _menuFocused = value),
                  child: AnimatedOpacity(
                    key: ValueKey(
                      'ai-language-note-menu-reveal-${widget.note.id}',
                    ),
                    opacity: _showMenu ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: IgnorePointer(
                      ignoring: !_showMenu,
                      child: PopupMenuButton<String>(
                        key: ValueKey(
                          'ai-language-note-menu-${widget.note.id}',
                        ),
                        onOpened: () => setState(() => _menuOpen = true),
                        onCanceled: () => setState(() => _menuOpen = false),
                        onSelected: (value) {
                          setState(() => _menuOpen = false);
                          if (value == 'edit') {
                            _editLanguageNote(context, widget.job, widget.note);
                          }
                          if (value == 'delete') {
                            context.read<AppController>().deleteAiLanguageNote(
                              widget.job.id,
                              widget.note.id,
                            );
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(context.strings.t('edit_item')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(context.strings.t('delete_item')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.note.explanation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(widget.note.explanation),
            ],
            if (widget.note.sourceExcerpt.isNotEmpty) ...[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Text(
                    '“${widget.note.sourceExcerpt}”',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _EvidenceChips(
              document: widget.document,
              segmentIds: widget.note.evidenceSegmentIds,
              onEvidence: widget.onEvidence,
            ),
          ],
        ),
      ),
    ),
  );
}

class _EvidenceChips extends StatelessWidget {
  const _EvidenceChips({
    required this.document,
    required this.segmentIds,
    required this.onEvidence,
  });

  final TranscriptDocument document;
  final List<String> segmentIds;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final segment in document.segments) segment.id: segment};
    final evidence = segmentIds
        .map((id) => (id: id, segment: byId[id]))
        .where((item) => item.segment != null)
        .toList();
    if (evidence.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${context.strings.t('evidence')}:',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        for (final item in evidence)
          ActionChip(
            key: ValueKey('ai-evidence-${item.id}'),
            avatarBoxConstraints: const BoxConstraints.tightFor(
              width: 14,
              height: 14,
            ),
            avatar: const Icon(Icons.play_arrow_rounded, size: 14),
            label: Text(
              formatClock(item.segment!.startMs),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.only(left: 2, right: 6),
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () => onEvidence(item.id),
          ),
      ],
    );
  }
}

Future<void> _copyBriefText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text.trim()));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.strings.t('brief_copied'))));
}

Future<void> _exportBrief(BuildContext context, String jobId) async {
  final directory = await getDirectoryPath(
    confirmButtonText: context.strings.t('export_brief'),
  );
  if (directory == null || !context.mounted) return;
  await context.read<AppController>().exportAiBrief(jobId, directory);
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.strings.t('brief_exported'))));
}

Future<void> _regenerateAiSection(
  BuildContext context,
  TranscriptionJob job,
  AiBriefSection section,
) async {
  final edited = switch (section) {
    AiBriefSection.overview => job.aiBrief?.edited ?? false,
    AiBriefSection.chapters =>
      job.aiBrief?.chapters.any((item) => item.edited) ?? false,
    AiBriefSection.languageNotes =>
      job.aiBrief?.languageNotes.any((item) => item.edited) ?? false,
    _ =>
      job.aiBrief?.insights.any(
            (item) => item.edited && _sectionForInsight(item.type) == section,
          ) ??
          false,
  };
  if (edited) {
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('ai_brief_edited_refresh_title')),
        content: Text(context.strings.t('ai_brief_edited_refresh_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('continue')),
          ),
        ],
      ),
    );
    if (replace != true || !context.mounted) return;
  }
  unawaited(
    context.read<AppController>().regenerateAiBriefSections(job.id, {section}),
  );
}

Future<void> _editOverview(BuildContext context, TranscriptionJob job) async {
  final field = TextEditingController(text: job.aiBrief?.overview ?? '');
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('overview')),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: field,
          autofocus: true,
          minLines: 4,
          maxLines: 12,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, field.text),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  field.dispose();
  if (value != null && context.mounted) {
    await context.read<AppController>().updateAiBriefOverview(job.id, value);
  }
}

Future<void> _editChapter(
  BuildContext context,
  TranscriptionJob job,
  AiChapter chapter,
) async {
  final title = TextEditingController(text: chapter.title);
  final summary = TextEditingController(text: chapter.summary);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('chapters')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, autofocus: true),
            const SizedBox(height: 12),
            TextField(controller: summary, minLines: 3, maxLines: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiChapter(
      job.id,
      chapter.id,
      title: title.text,
      summary: summary.text,
    );
  }
  title.dispose();
  summary.dispose();
}

Future<void> _editInsight(
  BuildContext context,
  TranscriptionJob job,
  AiInsight insight,
) async {
  final text = TextEditingController(text: insight.text);
  final owner = TextEditingController(text: insight.owner ?? '');
  final deadline = TextEditingController(text: insight.deadline ?? '');
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('edit_item')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
            ),
            if (insight.type == AiInsightType.actionItem) ...[
              const SizedBox(height: 12),
              TextField(
                controller: owner,
                decoration: InputDecoration(
                  labelText: context.strings.t('owner'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deadline,
                decoration: InputDecoration(
                  labelText: context.strings.t('deadline'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiInsight(
      job.id,
      insight.id,
      text: text.text,
      owner: owner.text,
      deadline: deadline.text,
    );
  }
  text.dispose();
  owner.dispose();
  deadline.dispose();
}

Future<void> _editLanguageNote(
  BuildContext context,
  TranscriptionJob job,
  AiLanguageNote note,
) async {
  final term = TextEditingController(text: note.term);
  final explanation = TextEditingController(text: note.explanation);
  final sourceExcerpt = TextEditingController(text: note.sourceExcerpt);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('edit_language_note')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('ai-language-note-term'),
                controller: term,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_term'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('ai-language-note-explanation'),
                controller: explanation,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_explanation'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('ai-language-note-excerpt'),
                controller: sourceExcerpt,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_source_excerpt'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed:
              term.text.trim().isEmpty ||
                  explanation.text.trim().isEmpty ||
                  sourceExcerpt.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiLanguageNote(
      job.id,
      note.id,
      term: term.text,
      explanation: explanation.text,
      sourceExcerpt: sourceExcerpt.text,
    );
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    term.dispose();
    explanation.dispose();
    sourceExcerpt.dispose();
  });
}

Future<void> _addInsight(
  BuildContext context,
  TranscriptionJob job,
  AiInsightType initialType,
) async {
  final text = TextEditingController();
  var type = initialType;
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('add_item')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<AiInsightType>(
                initialValue: type,
                items: [
                  for (final value in AiInsightType.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_insightTitle(context, value)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => type = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('save')),
          ),
        ],
      ),
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().addAiInsight(
      job.id,
      type: type,
      text: text.text,
    );
  }
  text.dispose();
}

String _evidenceRange(TranscriptDocument document, List<String> segmentIds) {
  final byId = {for (final segment in document.segments) segment.id: segment};
  final segments = segmentIds
      .map((id) => byId[id])
      .whereType<TranscriptSegment>()
      .toList();
  if (segments.isEmpty) return '';
  final start = formatClock(segments.first.startMs);
  final end = formatClock(segments.last.endMs);
  return start == end ? start : '$start–$end';
}

String _insightTitle(BuildContext context, AiInsightType type) =>
    switch (type) {
      AiInsightType.keyIdea => context.strings.t('key_ideas'),
      AiInsightType.notableMoment => context.strings.t('notable_moments'),
      AiInsightType.decision => context.strings.t('decisions'),
      AiInsightType.actionItem => context.strings.t('action_items'),
      AiInsightType.openQuestion => context.strings.t('open_questions'),
    };

IconData _insightIcon(AiInsightType type) => switch (type) {
  AiInsightType.keyIdea => Icons.lightbulb_outline_rounded,
  AiInsightType.notableMoment => Icons.stars_outlined,
  AiInsightType.decision => Icons.gavel_outlined,
  AiInsightType.actionItem => Icons.task_alt_rounded,
  AiInsightType.openQuestion => Icons.help_outline_rounded,
};

AiBriefSection _sectionForInsight(AiInsightType type) => switch (type) {
  AiInsightType.keyIdea ||
  AiInsightType.notableMoment => AiBriefSection.keyIdeas,
  AiInsightType.decision => AiBriefSection.decisions,
  AiInsightType.actionItem => AiBriefSection.actionItems,
  AiInsightType.openQuestion => AiBriefSection.openQuestions,
};

String _learningLevelLabel(BuildContext context, AiLearningLevel level) =>
    context.strings.t('ai_learning_level_${level.name}');

String _languageNoteKindLabel(BuildContext context, AiLanguageNoteKind kind) =>
    context.strings.t('ai_language_note_kind_${kind.name}');

enum _TranscriptMoreAction {
  toggleSpeakers,
  toggleTimestamps,
  original,
  translated,
  bilingual,
  addBackToInbox,
  retryAlignment,
  translate,
  copy,
  export,
}

enum _ReviewToolbarRole { global, transcript, aiBrief }

class _UnifiedReviewToolbar extends StatelessWidget {
  const _UnifiedReviewToolbar({
    required this.role,
    required this.job,
    required this.viewMode,
    required this.showAiBrief,
    required this.search,
    required this.searchVisible,
    required this.onTabChanged,
    required this.onViewModeChanged,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onSearch,
    required this.onFocusCurrentSentence,
    required this.onGenerateAiBrief,
    this.showFilename = true,
  });

  static const _fullBreakpoint = 900.0;
  static const _mediumBreakpoint = 700.0;
  static const _paneFullBreakpoint = 700.0;
  static const _paneMediumBreakpoint = 520.0;
  static const _paneDirectActionsBreakpoint = 400.0;

  final _ReviewToolbarRole role;
  final TranscriptionJob job;
  final TranslationViewMode viewMode;
  final bool showAiBrief;
  final TextEditingController search;
  final bool searchVisible;
  final ValueChanged<bool> onTabChanged;
  final ValueChanged<TranslationViewMode> onViewModeChanged;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final VoidCallback onSearch;
  final VoidCallback? onFocusCurrentSentence;
  final VoidCallback onGenerateAiBrief;
  final bool showFilename;

  bool get _translationStarted =>
      job.translationState.status != TranslationStatus.idle ||
      (job.document?.segments.any((segment) => segment.hasTranslation) ??
          false);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return switch (role) {
      _ReviewToolbarRole.global => _buildGlobalHeader(context),
      _ReviewToolbarRole.transcript => _buildTranscriptPaneHeader(
        context,
        controller,
      ),
      _ReviewToolbarRole.aiBrief => _buildAiBriefPaneHeader(
        context,
        controller,
      ),
    };
  }

  Widget _buildGlobalHeader(BuildContext context) {
    return SizedBox(
      key: const Key('review-header'),
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final full = constraints.maxWidth >= _fullBreakpoint;
            final medium = constraints.maxWidth >= _mediumBreakpoint;
            final tabWidth = full ? 256.0 : (medium ? 228.0 : 196.0);
            final sideWidth = (constraints.maxWidth - tabWidth) / 2;
            return Row(
              key: const Key('review-toolbar-row'),
              children: [
                SizedBox(width: sideWidth),
                _tabs(tabWidth),
                SizedBox(width: sideWidth),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTranscriptPaneHeader(
    BuildContext context,
    AppController controller,
  ) => SizedBox(
    key: const Key('transcript-pane-header'),
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (searchVisible) return _buildPaneSearchRow(context);
          final full = constraints.maxWidth >= _paneFullBreakpoint;
          final medium = constraints.maxWidth >= _paneMediumBreakpoint;
          final showDirectActions =
              constraints.maxWidth >= _paneDirectActionsBreakpoint;
          return Row(
            key: const Key('transcript-pane-toolbar-row'),
            children: [
              if (showFilename)
                Expanded(child: _ReviewFilename(job: job))
              else
                const Spacer(),
              if (_translationStarted && medium)
                _TranslationViewDropdown(
                  value: viewMode,
                  compact: !full,
                  onChanged: onViewModeChanged,
                ),
              _buildTranscriptActions(
                context,
                controller,
                medium: medium,
                showDirectActions: showDirectActions,
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildAiBriefPaneHeader(
    BuildContext context,
    AppController controller,
  ) => SizedBox(
    key: const Key('ai-brief-pane-header'),
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        key: const Key('ai-brief-pane-toolbar-row'),
        children: [
          Expanded(
            child: Text(
              context.strings.t('ai_brief'),
              key: const Key('ai-brief-pane-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          _buildAiBriefActions(context, controller),
        ],
      ),
    ),
  );

  Widget _tabs(double width) => _ReviewContentTabs(
    width: width,
    showAiBrief: showAiBrief,
    onChanged: onTabChanged,
  );

  Widget _buildPaneSearchRow(BuildContext context) => Row(
    key: const Key('review-toolbar-search-row'),
    children: [
      IconButton(
        key: const Key('close-transcript-search'),
        tooltip: context.strings.t('close_search'),
        onPressed: onCloseSearch,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): onCloseSearch,
          },
          child: TextField(
            key: const Key('transcript-search-field'),
            autofocus: true,
            controller: search,
            onChanged: (_) => onSearch(),
            decoration: InputDecoration(
              isDense: true,
              hintText: context.strings.t('search_transcript'),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('clear-transcript-search'),
                      tooltip: context.strings.t('clear_search'),
                      onPressed: () {
                        search.clear();
                        onSearch();
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildTranscriptActions(
    BuildContext context,
    AppController controller, {
    required bool medium,
    required bool showDirectActions,
  }) {
    final settings = controller.settings;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('open-transcript-search'),
          tooltip: context.strings.t('search_transcript'),
          onPressed: onOpenSearch,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.search_rounded),
        ),
        if (showDirectActions) ...[
          IconButton(
            key: const Key('toggle-speaker-labels'),
            tooltip: context.strings.t('speaker_labels'),
            isSelected: settings.showSpeakers,
            onPressed: () => unawaited(
              controller.updateSettings(
                settings.copyWith(showSpeakers: !settings.showSpeakers),
              ),
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(Icons.person_rounded),
          ),
          IconButton(
            key: const Key('toggle-timestamps'),
            tooltip: context.strings.t('timestamps'),
            isSelected: settings.showTimestamps,
            onPressed: () => unawaited(
              controller.updateSettings(
                settings.copyWith(showTimestamps: !settings.showTimestamps),
              ),
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.schedule_outlined),
            selectedIcon: const Icon(Icons.schedule_rounded),
          ),
        ],
        _focusButton(context),
        if (showDirectActions) ...[
          IconButton(
            key: const Key('copy-transcript-toolbar'),
            tooltip: context.strings.t('copy'),
            onPressed: () => _runTranscriptMoreAction(
              context,
              controller,
              settings,
              _TranscriptMoreAction.copy,
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            key: const Key('export-transcript-toolbar'),
            tooltip: context.strings.t('export'),
            onPressed: () => _runTranscriptMoreAction(
              context,
              controller,
              settings,
              _TranscriptMoreAction.export,
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
        _transcriptMoreMenu(
          context,
          controller,
          includeViewToggles: !showDirectActions,
          includeViewMode: !medium,
          includeDocumentActions: !showDirectActions,
        ),
      ],
    );
  }

  Widget _focusButton(BuildContext context) => IconButton(
    key: const Key('focus-current-sentence'),
    tooltip: context.strings.t('focus_current_sentence'),
    onPressed: onFocusCurrentSentence,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.center_focus_strong_rounded),
  );

  Widget _transcriptMoreMenu(
    BuildContext context,
    AppController controller, {
    required bool includeViewToggles,
    required bool includeViewMode,
    required bool includeDocumentActions,
  }) {
    final settings = controller.settings;
    final translationAction = _translationToolbarAction(
      job.translationState.status,
    );
    final translateLabel = _translationStarted
        ? _translationToolbarActionLabel(context, translationAction)
        : context.strings.t('translate_with_llm');
    final translateIcon = _translationStarted
        ? _translationToolbarActionIcon(translationAction)
        : Icons.translate_rounded;
    final alignment = job.forcedAlignment;
    final supportsLocalAlignment =
        job.transcriptSource == TranscriptSource.mossPro ||
        job.transcriptSource == TranscriptSource.mossLocal ||
        job.transcriptSource == TranscriptSource.qwen3Local ||
        job.transcriptionProvider == TranscriptionProvider.mossPro ||
        job.transcriptionProvider == TranscriptionProvider.mossLocal ||
        job.transcriptionProvider == TranscriptionProvider.qwen3Local;
    final entries = <PopupMenuEntry<_TranscriptMoreAction>>[];
    void addSection(List<PopupMenuEntry<_TranscriptMoreAction>> section) {
      if (section.isEmpty) return;
      if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
      entries.addAll(section);
    }

    if (includeViewToggles) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        CheckedPopupMenuItem(
          key: const Key('more-toggle-speakers'),
          value: _TranscriptMoreAction.toggleSpeakers,
          checked: settings.showSpeakers,
          child: Text(context.strings.t('speaker_labels')),
        ),
        CheckedPopupMenuItem(
          key: const Key('more-toggle-timestamps'),
          value: _TranscriptMoreAction.toggleTimestamps,
          checked: settings.showTimestamps,
          child: Text(context.strings.t('timestamps')),
        ),
      ]);
    }
    if (includeViewMode && _translationStarted) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        CheckedPopupMenuItem(
          key: const Key('translation-mode-original-menu'),
          value: _TranscriptMoreAction.original,
          checked: viewMode == TranslationViewMode.original,
          child: Text(context.strings.t('original')),
        ),
        CheckedPopupMenuItem(
          key: const Key('translation-mode-translated-menu'),
          value: _TranscriptMoreAction.translated,
          checked: viewMode == TranslationViewMode.translated,
          child: Text(context.strings.t('translated')),
        ),
        CheckedPopupMenuItem(
          key: const Key('translation-mode-bilingual-menu'),
          value: _TranscriptMoreAction.bilingual,
          checked: viewMode == TranslationViewMode.bilingual,
          child: Text(context.strings.t('bilingual')),
        ),
      ]);
    }
    final processingActions = <PopupMenuEntry<_TranscriptMoreAction>>[];
    if (job.translationState.status.isActive == false) {
      processingActions.add(
        _menuItem(
          key: const Key('add-back-to-inbox'),
          value: _TranscriptMoreAction.addBackToInbox,
          icon: Icons.input_rounded,
          label: context.strings.t('add_back_to_inbox'),
        ),
      );
    }
    if (supportsLocalAlignment &&
        (alignment.hasWordTiming || alignment.canRequest)) {
      processingActions.add(
        _menuItem(
          key: Key(
            alignment.hasWordTiming
                ? 'rerun-forced-alignment'
                : 'retry-forced-alignment',
          ),
          value: _TranscriptMoreAction.retryAlignment,
          icon: Icons.refresh_rounded,
          label: context.strings.t(
            alignment.status == ForcedAlignmentStatus.notRequested
                ? 'run_local_alignment'
                : 'retry_local_alignment',
          ),
        ),
      );
    }
    if (job.translationState.status.isActive == false) {
      processingActions.add(
        _menuItem(
          key: const Key('translate-transcript'),
          value: _TranscriptMoreAction.translate,
          icon: translateIcon,
          label: translateLabel,
          enabled: controller.translationConfigured,
        ),
      );
    }
    addSection(processingActions);
    if (includeDocumentActions) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        _menuItem(
          key: const Key('copy-transcript-menu'),
          value: _TranscriptMoreAction.copy,
          icon: Icons.copy_all_outlined,
          label: context.strings.t('copy'),
        ),
        _menuItem(
          key: const Key('export-transcript-menu'),
          value: _TranscriptMoreAction.export,
          icon: Icons.ios_share_rounded,
          label: context.strings.t('export'),
        ),
      ]);
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    return SizedBox.square(
      dimension: 40,
      child: PopupMenuButton<_TranscriptMoreAction>(
        key: const Key('review-toolbar-more'),
        tooltip: context.strings.t('more_actions'),
        padding: EdgeInsets.zero,
        onSelected: (action) =>
            _runTranscriptMoreAction(context, controller, settings, action),
        itemBuilder: (_) => entries,
        icon: const Icon(Icons.more_horiz_rounded),
      ),
    );
  }

  PopupMenuItem<_TranscriptMoreAction> _menuItem({
    Key? key,
    required _TranscriptMoreAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
  }) => PopupMenuItem(
    key: key,
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    ),
  );

  void _runTranscriptMoreAction(
    BuildContext context,
    AppController controller,
    AppSettings settings,
    _TranscriptMoreAction action,
  ) {
    switch (action) {
      case _TranscriptMoreAction.toggleSpeakers:
        unawaited(
          controller.updateSettings(
            settings.copyWith(showSpeakers: !settings.showSpeakers),
          ),
        );
      case _TranscriptMoreAction.toggleTimestamps:
        unawaited(
          controller.updateSettings(
            settings.copyWith(showTimestamps: !settings.showTimestamps),
          ),
        );
      case _TranscriptMoreAction.original:
        onViewModeChanged(TranslationViewMode.original);
      case _TranscriptMoreAction.translated:
        onViewModeChanged(TranslationViewMode.translated);
      case _TranscriptMoreAction.bilingual:
        onViewModeChanged(TranslationViewMode.bilingual);
      case _TranscriptMoreAction.addBackToInbox:
        unawaited(_enqueueAgain(context, controller));
      case _TranscriptMoreAction.retryAlignment:
        unawaited(controller.retryForcedAlignment(job.id));
      case _TranscriptMoreAction.translate:
        if (_translationStarted) {
          _runTranslationToolbarAction(
            context,
            job,
            controller,
            _translationToolbarAction(job.translationState.status),
          );
        } else {
          unawaited(_showTranslationDialog(context, job));
        }
      case _TranscriptMoreAction.copy:
        unawaited(_copyTranscript(context, controller, settings));
      case _TranscriptMoreAction.export:
        unawaited(showTranscriptExportDialog(context, jobIds: [job.id]));
    }
  }

  Future<void> _enqueueAgain(
    BuildContext context,
    AppController controller,
  ) async {
    final queued = await controller.enqueueAgain(job.id);
    if (queued == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('source_missing'))),
      );
    }
  }

  Future<void> _copyTranscript(
    BuildContext context,
    AppController controller,
    AppSettings settings,
  ) async {
    final options = ExportOptions(
      showSpeakers: settings.showSpeakers,
      showTimestamps: settings.showTimestamps,
      localeCode: Localizations.localeOf(context).languageCode,
      contentMode: switch (viewMode) {
        TranslationViewMode.original => ExportContentMode.original,
        TranslationViewMode.translated => ExportContentMode.translated,
        TranslationViewMode.bilingual => ExportContentMode.bilingual,
      },
    );
    await Clipboard.setData(
      ClipboardData(text: controller.renderJob(job.id, options)),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.strings.t('copied'))));
    }
  }

  Widget _buildAiBriefActions(BuildContext context, AppController controller) {
    final active = job.aiGenerationState.status.isActive;
    if (active) {
      return IconButton(
        key: const Key('cancel-ai-brief-toolbar'),
        tooltip: context.strings.t('cancel'),
        onPressed: () => controller.cancelAiBrief(job.id),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.stop_circle_outlined),
      );
    }
    if (job.aiBrief == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('copy-ai-brief-toolbar'),
          tooltip: context.strings.t('copy_brief'),
          onPressed: () =>
              _copyBriefText(context, controller.renderAiBriefMarkdown(job.id)),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.copy_all_outlined),
        ),
        IconButton(
          key: const Key('export-ai-brief-toolbar'),
          tooltip: context.strings.t('export_brief'),
          onPressed: () => _exportBrief(context, job.id),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.ios_share_rounded),
        ),
        IconButton(
          key: const Key('refresh-ai-brief-toolbar'),
          tooltip: context.strings.t('refresh_ai_brief'),
          onPressed: onGenerateAiBrief,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }
}

class _TranslationViewDropdown extends StatelessWidget {
  const _TranslationViewDropdown({
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final TranslationViewMode value;
  final bool compact;
  final ValueChanged<TranslationViewMode> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('translation-view-mode-control'),
    width: compact ? 108 : 112,
    height: 40,
    padding: const EdgeInsets.only(left: 12, right: 8),
    decoration: BoxDecoration(
      color:
          Theme.of(context).inputDecorationTheme.fillColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<TranslationViewMode>(
        key: const Key('translation-view-mode'),
        value: value,
        isDense: true,
        isExpanded: true,
        icon: const Icon(Icons.arrow_drop_down_rounded, size: 20),
        items: [
          DropdownMenuItem(
            value: TranslationViewMode.original,
            child: Text(context.strings.t('original')),
          ),
          DropdownMenuItem(
            value: TranslationViewMode.translated,
            child: Text(context.strings.t('translated')),
          ),
          DropdownMenuItem(
            value: TranslationViewMode.bilingual,
            child: Text(context.strings.t('bilingual')),
          ),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    ),
  );
}

enum _TranslationToolbarAction { retryUnfinished, retranslateAll, cancel }

_TranslationToolbarAction _translationToolbarAction(TranslationStatus status) {
  if (status.isActive) return _TranslationToolbarAction.cancel;
  if (status.canRetry) return _TranslationToolbarAction.retryUnfinished;
  return _TranslationToolbarAction.retranslateAll;
}

void _runTranslationToolbarAction(
  BuildContext context,
  TranscriptionJob job,
  AppController controller,
  _TranslationToolbarAction action,
) {
  switch (action) {
    case _TranslationToolbarAction.retryUnfinished:
      unawaited(controller.retryTranslation(job.id));
    case _TranslationToolbarAction.retranslateAll:
      unawaited(_confirmRetranslateAll(context, job));
    case _TranslationToolbarAction.cancel:
      controller.cancelTranslation(job.id);
  }
}

String _translationToolbarActionLabel(
  BuildContext context,
  _TranslationToolbarAction action,
) => switch (action) {
  _TranslationToolbarAction.retryUnfinished => context.strings.t(
    'translate_unfinished_with_llm',
  ),
  _TranslationToolbarAction.retranslateAll => context.strings.t(
    'retranslate_all_with_llm',
  ),
  _TranslationToolbarAction.cancel => context.strings.t('cancel'),
};

IconData _translationToolbarActionIcon(_TranslationToolbarAction action) =>
    switch (action) {
      _TranslationToolbarAction.retryUnfinished => Icons.refresh_rounded,
      _TranslationToolbarAction.retranslateAll => Icons.restart_alt_rounded,
      _TranslationToolbarAction.cancel => Icons.stop_circle_outlined,
    };

class _TranslationStatusStrip extends StatelessWidget {
  const _TranslationStatusStrip({required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final state = job.translationState;
    return DecoratedBox(
      key: const Key('translation-status-strip'),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.status == TranslationStatus.translating)
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    key: const Key('translation-progress-bar'),
                    value: state.totalSegments == 0
                        ? null
                        : state.progress.clamp(0, 1),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('cancel-translation-progress'),
                  tooltip: context.strings.t('cancel'),
                  style: IconButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () =>
                      context.read<AppController>().cancelTranslation(job.id),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
                const SizedBox(width: 4),
              ],
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _TranslationStatusLabel(job: job, compact: false),
          ),
        ],
      ),
    );
  }
}

class _TranslationStatusLabel extends StatelessWidget {
  const _TranslationStatusLabel({required this.job, required this.compact});

  final TranscriptionJob job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = job.translationState;
    final fullText = switch (state.status) {
      TranslationStatus.translating =>
        context.strings
            .t('translation_progress')
            .replaceFirst('{done}', '${state.completedSegments}')
            .replaceFirst('{total}', '${state.totalSegments}'),
      TranslationStatus.completed => context.strings.t('completed'),
      TranslationStatus.partial ||
      TranslationStatus.interrupted => context.strings.t('translation_partial'),
      TranslationStatus.cancelled => context.strings.t('translation_cancelled'),
      TranslationStatus.failed => context.strings.error(
        state.errorCode,
        englishFallback: state.errorMessage,
      ),
      TranslationStatus.idle => '',
    };
    if (fullText.isEmpty) return const SizedBox.shrink();
    final text = state.status == TranslationStatus.translating && compact
        ? '${state.completedSegments}/${state.totalSegments}'
        : fullText;
    final color = _translationStatusColor(context, state.status);
    final indicator = state.status == TranslationStatus.translating
        ? SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(_translationStatusIcon(state.status), size: 17, color: color);
    return Semantics(
      label: fullText,
      excludeSemantics: true,
      child: Row(
        key: const Key('translation-status'),
        mainAxisSize: MainAxisSize.min,
        children: [
          indicator,
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              key: state.status == TranslationStatus.translating
                  ? const Key('translation-progress-count')
                  : null,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: state.status == TranslationStatus.completed
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _translationStatusColor(BuildContext context, TranslationStatus status) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (status) {
    TranslationStatus.completed =>
      dark ? Colors.green.shade300 : Colors.green.shade700,
    TranslationStatus.partial ||
    TranslationStatus.interrupted ||
    TranslationStatus.cancelled =>
      dark ? Colors.orange.shade300 : Colors.orange.shade700,
    TranslationStatus.failed => theme.colorScheme.error,
    TranslationStatus.translating => theme.colorScheme.primary,
    TranslationStatus.idle => theme.colorScheme.onSurfaceVariant,
  };
}

Color _translatedSegmentHighlightColor(BuildContext context) =>
    _translationStatusColor(context, TranslationStatus.completed).withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? .18 : .10,
    );

IconData _translationStatusIcon(TranslationStatus status) => switch (status) {
  TranslationStatus.completed => Icons.check_circle_rounded,
  TranslationStatus.partial ||
  TranslationStatus.interrupted ||
  TranslationStatus.cancelled => Icons.warning_amber_rounded,
  TranslationStatus.failed => Icons.error_rounded,
  TranslationStatus.translating => Icons.sync_rounded,
  TranslationStatus.idle => Icons.info_outline_rounded,
};

Future<void> _showTranslationDialog(
  BuildContext context,
  TranscriptionJob job,
) async {
  final controller = context.read<AppController>();
  var target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  if (!supportedTranslationLanguageCodes.contains(target)) target = 'en';
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('translate_with_llm')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('manual-translation-target'),
                initialValue: target,
                decoration: InputDecoration(
                  labelText: context.strings.t('target_language'),
                ),
                items: [
                  for (final code in supportedTranslationLanguageCodes)
                    DropdownMenuItem(
                      value: code,
                      child: Text(
                        context.strings.translationLanguageName(code),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => target = value);
                },
              ),
              const SizedBox(height: 12),
              Text(
                context.strings
                    .t('translation_model_label')
                    .replaceFirst(
                      '{model}',
                      controller.settings.translationSettings.model,
                    ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, target),
            child: Text(context.strings.t('translate_with_llm')),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final hasExisting =
      job.document?.segments.any((segment) => segment.hasTranslation) ?? false;
  final targetChanged =
      hasExisting &&
      job.translationState.targetLanguage.isNotEmpty &&
      job.translationState.targetLanguage != selected;
  var replace = false;
  if (targetChanged) {
    replace = await _confirmTranslationReplacement(context) ?? false;
    if (!replace || !context.mounted) return;
  }
  await controller.translateJob(
    job.id,
    targetLanguage: selected,
    replaceExisting: replace,
  );
}

Future<void> _confirmRetranslateAll(
  BuildContext context,
  TranscriptionJob job,
) async {
  if (await _confirmTranslationReplacement(context) != true ||
      !context.mounted) {
    return;
  }
  final controller = context.read<AppController>();
  final target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  await controller.translateJob(
    job.id,
    targetLanguage: target,
    replaceExisting: true,
  );
}

Future<bool?> _confirmTranslationReplacement(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('translation_replace_title')),
        content: Text(context.strings.t('translation_replace_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('continue')),
          ),
        ],
      ),
    );

class _TranscriptSegmentGroup extends StatefulWidget {
  const _TranscriptSegmentGroup({
    super.key,
    required this.segment,
    required this.tokens,
    required this.positionMs,
    required this.isCurrent,
    required this.viewMode,
    required this.query,
    required this.speakerName,
    required this.speakers,
    required this.showSpeaker,
    required this.showTimestamp,
    required this.highlightTranslated,
    required this.isEditingOriginal,
    required this.isEditingTranslation,
    required this.isRepeating,
    required this.onToggleRepeat,
    required this.onSeek,
    required this.onEditOriginal,
    required this.onCancelOriginal,
    required this.onSaveOriginal,
    required this.onSpeakerChanged,
    required this.onEditTranslation,
    required this.onCancelTranslation,
    required this.onSaveTranslation,
    required this.onRetranslate,
  });

  final TranscriptSegment segment;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final bool isCurrent;
  final TranslationViewMode viewMode;
  final String query;
  final String speakerName;
  final List<SpeakerProfile> speakers;
  final bool showSpeaker;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditingOriginal;
  final bool isEditingTranslation;
  final bool isRepeating;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
  final VoidCallback onEditOriginal;
  final VoidCallback onCancelOriginal;
  final Future<void> Function(String) onSaveOriginal;
  final Future<void> Function(String) onSpeakerChanged;
  final VoidCallback onEditTranslation;
  final VoidCallback onCancelTranslation;
  final Future<void> Function(String) onSaveTranslation;
  final Future<void> Function()? onRetranslate;

  @override
  State<_TranscriptSegmentGroup> createState() =>
      _TranscriptSegmentGroupState();
}

class _TranscriptSegmentGroupState extends State<_TranscriptSegmentGroup> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final showOriginal = widget.viewMode != TranslationViewMode.translated;
    final showTranslation = widget.viewMode != TranslationViewMode.original;
    return MouseRegion(
      key: ValueKey('segment-group-${widget.segment.id}'),
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: _TranscriptSegmentSurface(
        surfaceKey: ValueKey(
          widget.viewMode == TranslationViewMode.translated
              ? 'translated-segment-${widget.segment.id}'
              : 'segment-card-${widget.segment.id}',
        ),
        hovered: _hovered,
        isCurrent: widget.isCurrent,
        isEditing: widget.isEditingOriginal || widget.isEditingTranslation,
        highlightTranslated: widget.highlightTranslated,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showTimestamp ||
                (widget.showSpeaker && widget.speakerName.isNotEmpty))
              _TranscriptSegmentMetadata(
                segment: widget.segment,
                query: widget.query,
                speakerName: widget.speakerName,
                speakers: widget.speakers,
                showSpeaker: widget.showSpeaker,
                showTimestamp: widget.showTimestamp,
                onSeek: widget.onSeek,
                onSpeakerChanged: widget.onSpeakerChanged,
              ),
            if (showOriginal)
              TranscriptSegmentEditor(
                key: ValueKey(widget.segment.id),
                segment: widget.segment,
                tokens: widget.tokens,
                positionMs: widget.positionMs,
                isCurrent: widget.isCurrent,
                query: widget.query,
                speakerName: widget.speakerName,
                showSpeaker: false,
                showTimestamp: false,
                isEditing: widget.isEditingOriginal,
                isRepeating: widget.isRepeating,
                embedded: true,
                groupHovered: _hovered,
                onToggleRepeat: widget.onToggleRepeat,
                onSeek: widget.onSeek,
                onEdit: widget.onEditOriginal,
                onCancel: widget.onCancelOriginal,
                onSave: widget.onSaveOriginal,
              ),
            if (showOriginal && showTranslation) const SizedBox(height: 6),
            if (showTranslation)
              KeyedSubtree(
                key: widget.viewMode == TranslationViewMode.bilingual
                    ? ValueKey('translated-segment-${widget.segment.id}')
                    : null,
                child: _TranslatedSegmentEditor(
                  key: ValueKey('translated-${widget.segment.id}'),
                  segment: widget.segment,
                  isCurrent: widget.isCurrent,
                  query: widget.query,
                  showTimestamp: false,
                  highlightTranslated: false,
                  isEditing: widget.isEditingTranslation,
                  showRepeatAction:
                      widget.viewMode == TranslationViewMode.translated,
                  isRepeating:
                      widget.viewMode == TranslationViewMode.translated &&
                      widget.isRepeating,
                  embedded: true,
                  groupHovered: _hovered,
                  bilingual: widget.viewMode == TranslationViewMode.bilingual,
                  onToggleRepeat:
                      widget.viewMode == TranslationViewMode.translated
                      ? widget.onToggleRepeat
                      : null,
                  onSeek: widget.onSeek,
                  onEdit: widget.onEditTranslation,
                  onCancel: widget.onCancelTranslation,
                  onSave: widget.onSaveTranslation,
                  onRetranslate: widget.onRetranslate,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptSegmentSurface extends StatelessWidget {
  const _TranscriptSegmentSurface({
    required this.surfaceKey,
    required this.hovered,
    required this.isCurrent,
    required this.isEditing,
    required this.highlightTranslated,
    required this.padding,
    required this.child,
  });

  final Key surfaceKey;
  final bool hovered;
  final bool isCurrent;
  final bool isEditing;
  final bool highlightTranslated;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final backgroundColor = isEditing
        ? colors.surfaceContainerLow
        : hovered
        ? colors.surfaceContainerLow
        : highlightTranslated
        ? _translatedSegmentHighlightColor(context)
        : null;
    return DecoratedBox(
      key: surfaceKey,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: isEditing ? Border.all(color: colors.outlineVariant) : null,
      ),
      child: Stack(
        children: [
          Padding(padding: padding, child: child),
          Positioned(
            left: 0,
            top: 8,
            bottom: 8,
            child: AnimatedContainer(
              key: ValueKey('segment-current-indicator-$surfaceKey'),
              duration: const Duration(milliseconds: 120),
              width: 3,
              decoration: BoxDecoration(
                color: isCurrent ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptSegmentMetadata extends StatelessWidget {
  const _TranscriptSegmentMetadata({
    required this.segment,
    required this.query,
    required this.speakerName,
    this.speakers = const [],
    required this.showSpeaker,
    required this.showTimestamp,
    required this.onSeek,
    this.onSpeakerChanged,
  });

  final TranscriptSegment segment;
  final String query;
  final String speakerName;
  final List<SpeakerProfile> speakers;
  final bool showSpeaker;
  final bool showTimestamp;
  final TranscriptSegmentSeekCallback onSeek;
  final Future<void> Function(String)? onSpeakerChanged;

  @override
  Widget build(BuildContext context) {
    final showsSpeaker = showSpeaker && speakerName.isNotEmpty;
    final canChangeSpeaker =
        showsSpeaker && speakers.length > 1 && onSpeakerChanged != null;
    final speakerColor = _speakerColor(context, segment.speaker ?? speakerName);
    final speakerLabel = SearchHighlightedText(
      key: ValueKey('segment-speaker-${segment.id}'),
      text: speakerName,
      query: query,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: speakerColor,
        fontWeight: FontWeight.w700,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showTimestamp)
            TextButton(
              key: ValueKey('segment-timestamp-${segment.id}'),
              onPressed: () =>
                  onSeek(reason: TranscriptSeekReason.sentenceClick),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                formatClock(segment.startMs),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          if (showTimestamp && showsSpeaker) const SizedBox(width: 8),
          if (showsSpeaker)
            Expanded(
              child: canChangeSpeaker
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: MenuAnchor(
                        key: ValueKey('segment-speaker-menu-${segment.id}'),
                        menuChildren: [
                          for (final speaker in speakers)
                            MenuItemButton(
                              key: ValueKey(
                                'segment-speaker-option-${segment.id}-${speaker.id}',
                              ),
                              leadingIcon: Icon(
                                speaker.id == segment.speaker
                                    ? Icons.check_rounded
                                    : Icons.circle,
                                size: speaker.id == segment.speaker ? 18 : 10,
                                color: _speakerColor(context, speaker.id),
                              ),
                              onPressed: speaker.id == segment.speaker
                                  ? null
                                  : () => unawaited(
                                      onSpeakerChanged!(speaker.id),
                                    ),
                              child: Text(
                                context.strings.speakerName(speaker.name),
                                style: TextStyle(
                                  color: _speakerColor(context, speaker.id),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                        builder: (context, menuController, child) => Tooltip(
                          message: context.strings.t('change_speaker'),
                          child: TextButton(
                            key: ValueKey(
                              'segment-speaker-dropdown-${segment.id}',
                            ),
                            onPressed: () => menuController.isOpen
                                ? menuController.close()
                                : menuController.open(),
                            style: TextButton.styleFrom(
                              foregroundColor: speakerColor,
                              minimumSize: Size.zero,
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: speakerLabel),
                                const SizedBox(width: 2),
                                const Icon(
                                  Icons.arrow_drop_down_rounded,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : speakerLabel,
            ),
        ],
      ),
    );
  }
}

class _TranslatedSegmentEditor extends StatefulWidget {
  const _TranslatedSegmentEditor({
    super.key,
    required this.segment,
    required this.isCurrent,
    required this.query,
    required this.showTimestamp,
    required this.highlightTranslated,
    required this.isEditing,
    required this.showRepeatAction,
    required this.isRepeating,
    this.embedded = false,
    this.groupHovered = false,
    this.bilingual = false,
    required this.onToggleRepeat,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    required this.onRetranslate,
  });

  final TranscriptSegment segment;
  final bool isCurrent;
  final String query;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditing;
  final bool showRepeatAction;
  final bool isRepeating;
  final bool embedded;
  final bool groupHovered;
  final bool bilingual;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final Future<void> Function(String) onSave;
  final Future<void> Function()? onRetranslate;

  @override
  State<_TranslatedSegmentEditor> createState() =>
      _TranslatedSegmentEditorState();
}

class _TranslatedSegmentEditorState extends State<_TranslatedSegmentEditor> {
  late final TextEditingController _draft;
  bool _hovered = false;
  bool _actionFocused = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(text: widget.segment.translatedText ?? '');
  }

  @override
  void didUpdateWidget(covariant _TranslatedSegmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEditing && widget.segment.translatedText != _draft.text) {
      _draft.text = widget.segment.translatedText ?? '';
    }
    if (widget.isEditing && !oldWidget.isEditing) {
      _draft.text = widget.segment.translatedText ?? '';
      _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _seek() => widget.onSeek(reason: TranscriptSeekReason.sentenceClick);

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.onSave(_draft.text);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final translated = widget.segment.translatedText?.trim();
    final fallback = translated == null || translated.isEmpty;
    final textStyle = widget.bilingual
        ? Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant)
        : Theme.of(context).textTheme.bodyLarge;
    final line = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTimestamp)
          _TranscriptSegmentMetadata(
            segment: widget.segment,
            query: widget.query,
            speakerName: '',
            showSpeaker: false,
            showTimestamp: true,
            onSeek: widget.onSeek,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: widget.isEditing
                  ? SelectionContainer.disabled(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            meta: true,
                          ): _save,
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            control: true,
                          ): _save,
                          const SingleActivator(LogicalKeyboardKey.escape):
                              widget.onCancel,
                        },
                        child: TextField(
                          key: ValueKey(
                            'translated-field-${widget.segment.id}',
                          ),
                          controller: _draft,
                          autofocus: true,
                          minLines: 1,
                          maxLines: null,
                          style: textStyle,
                          decoration: const InputDecoration(
                            isDense: true,
                            filled: false,
                            contentPadding: EdgeInsets.all(4),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    )
                  : InkWell(
                      key: ValueKey('translated-text-${widget.segment.id}'),
                      onTap: _seek,
                      hoverColor: Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: SearchHighlightedText(
                          text: fallback ? widget.segment.text : translated,
                          query: widget.query,
                          style: textStyle?.copyWith(
                            fontStyle: fallback ? FontStyle.italic : null,
                            color: fallback
                                ? colors.onSurfaceVariant
                                : textStyle.color,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 4),
            _buildActions(context),
          ],
        ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.embedded
          ? KeyedSubtree(
              key: ValueKey('translated-line-${widget.segment.id}'),
              child: line,
            )
          : _TranscriptSegmentSurface(
              surfaceKey: ValueKey('translated-segment-${widget.segment.id}'),
              hovered: _hovered,
              isCurrent: widget.isCurrent,
              isEditing: widget.isEditing,
              highlightTranslated: widget.highlightTranslated,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: line,
            ),
    );
  }

  Widget _buildActions(BuildContext context) {
    if (widget.isEditing) {
      final actionCount = (widget.isRepeating ? 1 : 0) + 2;
      return SizedBox(
        width: actionCount * 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isRepeating)
              _SentenceRepeatButton(
                segmentId: widget.segment.id,
                isRepeating: true,
                onPressed: widget.onToggleRepeat,
              ),
            IconButton(
              key: ValueKey('translated-cancel-${widget.segment.id}'),
              tooltip: context.strings.t('cancel'),
              onPressed: _saving ? null : widget.onCancel,
              style: _compactSegmentActionStyle(context),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
            IconButton(
              key: ValueKey('translated-save-${widget.segment.id}'),
              tooltip: context.strings.t('save'),
              onPressed: _saving ? null : _save,
              style: _compactSegmentActionStyle(context),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
            ),
          ],
        ),
      );
    }
    final repeatVisible =
        widget.groupHovered || _hovered || _actionFocused || widget.isRepeating;
    final lineActionsVisible = _hovered || _actionFocused;
    final actionCount =
        (widget.showRepeatAction ? 1 : 0) +
        1 +
        (widget.onRetranslate != null ? 1 : 0);
    return Focus(
      onFocusChange: (value) => setState(() => _actionFocused = value),
      child: SizedBox(
        width: actionCount * 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showRepeatAction)
              _SegmentActionVisibility(
                opacityKey: ValueKey(
                  'segment-repeat-opacity-${widget.segment.id}',
                ),
                visible: repeatVisible,
                child: _SentenceRepeatButton(
                  segmentId: widget.segment.id,
                  isRepeating: widget.isRepeating,
                  onPressed: widget.onToggleRepeat,
                ),
              ),
            _SegmentActionVisibility(
              opacityKey: ValueKey(
                'translated-edit-opacity-${widget.segment.id}',
              ),
              visible: lineActionsVisible,
              child: IconButton(
                key: ValueKey('translated-edit-${widget.segment.id}'),
                tooltip: context.strings.t('edit_translation'),
                onPressed: widget.onEdit,
                style: _compactSegmentActionStyle(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
            if (widget.onRetranslate != null)
              _SegmentActionVisibility(
                opacityKey: ValueKey(
                  'translated-retranslate-opacity-${widget.segment.id}',
                ),
                visible: lineActionsVisible,
                child: IconButton(
                  key: ValueKey('translated-retranslate-${widget.segment.id}'),
                  tooltip: context.strings.t('retranslate_segment_with_llm'),
                  onPressed: widget.onRetranslate,
                  style: _compactSegmentActionStyle(context),
                  icon: const Icon(Icons.translate_rounded, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SegmentActionVisibility extends StatelessWidget {
  const _SegmentActionVisibility({
    this.opacityKey,
    required this.visible,
    required this.child,
  });

  final Key? opacityKey;
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      key: opacityKey,
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: child,
    ),
  );
}

class _SentenceRepeatButton extends StatelessWidget {
  const _SentenceRepeatButton({
    required this.segmentId,
    required this.isRepeating,
    required this.onPressed,
  });

  final String segmentId;
  final bool isRepeating;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: ValueKey('segment-repeat-$segmentId'),
    tooltip: context.strings.t(
      isRepeating ? 'stop_repeating_sentence' : 'repeat_sentence',
    ),
    onPressed: onPressed,
    isSelected: isRepeating,
    style: _compactSegmentActionStyle(context, selected: isRepeating),
    icon: const Icon(Icons.repeat_one_rounded, size: 18),
  );
}

ButtonStyle _compactSegmentActionStyle(
  BuildContext context, {
  bool selected = false,
}) => IconButton.styleFrom(
  foregroundColor: selected
      ? Theme.of(context).colorScheme.onPrimaryContainer
      : null,
  backgroundColor: selected
      ? Theme.of(context).colorScheme.primaryContainer
      : null,
  minimumSize: Size.zero,
  fixedSize: const Size.square(32),
  maximumSize: const Size.square(32),
  padding: EdgeInsets.zero,
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _MediaModeButton extends StatelessWidget {
  const _MediaModeButton({required this.destination, required this.onPressed});

  final _ReviewMediaMode destination;
  final VoidCallback onPressed;

  static const size = 44.0;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('video-audio-mode-toggle'),
    tooltip: context.strings.t(
      destination == _ReviewMediaMode.video
          ? 'switch_to_video_mode'
          : 'switch_to_audio_mode',
    ),
    onPressed: onPressed,
    style: const ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.square(size)),
      maximumSize: WidgetStatePropertyAll(Size.square(size)),
      padding: WidgetStatePropertyAll(EdgeInsets.all(10)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: RotationTransition(
          turns: Tween(begin: -.08, end: 0.0).animate(animation),
          child: child,
        ),
      ),
      child: Icon(
        destination == _ReviewMediaMode.video
            ? Icons.videocam_rounded
            : Icons.headphones_rounded,
        key: ValueKey(destination),
      ),
    ),
  );
}

class _VideoMediaHeader extends StatelessWidget {
  const _VideoMediaHeader({required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('video-media-header'),
    height: _TranscriptReviewState._videoTitleHeaderHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _ReviewFilename(job: job),
      ),
    ),
  );
}

class _ReviewFilename extends StatelessWidget {
  const _ReviewFilename({required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: job.displayName,
    waitDuration: const Duration(milliseconds: 400),
    child: Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Text(
        job.displayName,
        key: const Key('review-filename'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _MediaPane extends StatelessWidget {
  const _MediaPane({
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
      child: Row(
        children: [
          IconButton.filledTonal(
            key: const Key('video-play-pause'),
            onPressed: onPlayPause,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          const SizedBox(width: 8),
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
              max: duration.inMilliseconds.clamp(1, double.infinity).toDouble(),
              onChanged: (value) => onSeek(
                Duration(milliseconds: value.round()),
                reason: TranscriptSeekReason.videoProgressScrub,
              ),
            ),
          ),
          Text(
            formatClock(duration.inMilliseconds),
            key: const Key('video-duration'),
          ),
          PlaybackSpeedButton(
            rate: playbackRate,
            onChanged: onPlaybackRateChanged,
          ),
          if (onSwitchToAudioMode != null)
            _MediaModeButton(
              destination: _ReviewMediaMode.audio,
              onPressed: onSwitchToAudioMode!,
            ),
          IconButton(
            key: const Key('video-fullscreen'),
            tooltip: context.strings.t('fullscreen'),
            onPressed: () => unawaited(onFullscreen()),
            icon: const Icon(Icons.fullscreen_rounded),
          ),
        ],
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

class _ReviewFullscreenControlsHost extends StatelessWidget {
  const _ReviewFullscreenControlsHost({
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
    super.key,
    this.subtitle,
    this.subtitleHighlight,
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

  static const controlsAutoHideDelay = Duration(seconds: 3);
  static const controlsTransitionDuration = Duration(milliseconds: 180);

  final String? subtitle;
  final TextRange? subtitleHighlight;
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

  @override
  Widget build(BuildContext context) {
    final text = widget.subtitle?.trim();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _exit,
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _runWithVisibleControls(widget.onPlayPause),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _runWithVisibleControls(widget.onSeekBackward),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _runWithVisibleControls(widget.onSeekForward),
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
                onPointerDown: (_) => _showControls(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.child,
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
          child: Row(
            key: const Key('fullscreen-controls-bar'),
            children: [
              IconButton(
                key: const Key('fullscreen-play-pause'),
                tooltip: context.strings.t(widget.playing ? 'pause' : 'play'),
                onPressed: () => _runWithVisibleControls(widget.onPlayPause),
                color: Colors.white,
                iconSize: 30,
                icon: Icon(
                  widget.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                formatClock(positionMs.round()),
                key: const Key('fullscreen-position'),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: colors.primaryContainer,
                    inactiveTrackColor: Colors.white38,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                    trackHeight: 3,
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
              const SizedBox(width: 8),
              Text(
                formatClock(hasDuration ? durationMs : 0),
                key: const Key('fullscreen-duration'),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('fullscreen-exit'),
                tooltip: context.strings.t('exit_fullscreen'),
                onPressed: () => _runWithVisibleControls(_exit),
                color: Colors.white,
                iconSize: 30,
                icon: const Icon(Icons.fullscreen_exit_rounded),
              ),
            ],
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
          const SizedBox(width: 8),
          Text(
            formatClock(position.inMilliseconds),
            key: const Key('audio-current-time'),
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
          ),
          if (onSwitchToVideoMode != null)
            _MediaModeButton(
              destination: _ReviewMediaMode.video,
              onPressed: onSwitchToVideoMode!,
            ),
        ],
      ),
    ),
  );
}

class WaveformScrubber extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (loading) {
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
            onSeek(
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
                  _waveformLayer(context, colors.outlineVariant),
                  ClipRect(
                    clipper: _WaveformProgressClipper(progress),
                    child: _waveformLayer(context, colors.primary),
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

  Widget _waveformLayer(BuildContext context, Color color) {
    if (path case final value?) {
      return Image.file(
        File(value),
        key: ValueKey('$value-${color.toARGB32()}'),
        fit: BoxFit.fill,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallback(color),
      );
    }
    return _fallback(color);
  }

  Widget _fallback(Color color) => Center(
    child: Container(
      height: 2,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(99),
      ),
    ),
  );
}

class _WaveformProgressClipper extends CustomClipper<Rect> {
  const _WaveformProgressClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_WaveformProgressClipper oldClipper) =>
      oldClipper.progress != progress;
}

const _speakerHues = <double>[270, 210, 155, 25, 335, 185];

Color _speakerColor(BuildContext context, String speakerId) {
  final numericId = int.tryParse(speakerId);
  var seed = numericId == null ? 0 : numericId - 1;
  if (numericId == null) {
    for (final codeUnit in speakerId.codeUnits) {
      seed = (seed * 31 + codeUnit) & 0x7fffffff;
    }
  }
  final index =
      ((seed % _speakerHues.length) + _speakerHues.length) %
      _speakerHues.length;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return HSLColor.fromAHSL(
    1,
    _speakerHues[index],
    dark ? .66 : .68,
    dark ? .72 : .4,
  ).toColor();
}

Color _onSpeakerColor(Color color) =>
    ThemeData.estimateBrightnessForColor(color) == Brightness.dark
    ? Colors.white
    : Colors.black;

class SpeakerStrip extends StatefulWidget {
  const SpeakerStrip({super.key, required this.job, required this.document});
  final TranscriptionJob job;
  final TranscriptDocument document;

  @override
  State<SpeakerStrip> createState() => _SpeakerStripState();
}

class _SpeakerStripState extends State<SpeakerStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent ||
          event.scrollDelta.dx != 0 ||
          !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + event.scrollDelta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    },
    child: SizedBox(
      height: 56,
      child: Scrollbar(
        controller: _scroll,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        interactive: true,
        child: ListView.separated(
          key: const Key('speaker-strip-scroll'),
          controller: _scroll,
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          scrollDirection: Axis.horizontal,
          itemCount: widget.document.speakers.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final speaker = widget.document.speakers[index];
            final speakerColor = _speakerColor(context, speaker.id);
            return ActionChip(
              avatarBoxConstraints: const BoxConstraints.tightFor(
                width: 18,
                height: 18,
              ),
              avatar: Container(
                key: ValueKey('speaker-avatar-${speaker.id}'),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: speakerColor,
                ),
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _onSpeakerColor(speakerColor),
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              label: Text(
                context.strings.speakerName(speaker.name),
                style: TextStyle(
                  color: speakerColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: () => _rename(context, speaker),
            );
          },
        ),
      ),
    ),
  );

  Future<void> _rename(BuildContext context, SpeakerProfile speaker) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _RenameSpeakerDialog(
        initialValue: context.strings.speakerName(speaker.name),
      ),
    );
    if (value != null && value.trim().isNotEmpty && context.mounted) {
      await context.read<AppController>().renameSpeaker(
        widget.job.id,
        speaker.id,
        value,
      );
    }
  }
}

class _RenameSpeakerDialog extends StatefulWidget {
  const _RenameSpeakerDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_RenameSpeakerDialog> createState() => _RenameSpeakerDialogState();
}

class _RenameSpeakerDialogState extends State<_RenameSpeakerDialog> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.t('rename_speaker')),
    content: TextField(
      key: const Key('speaker-name-field'),
      controller: _field,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('save-speaker-name'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}

class TranscriptSegmentEditor extends StatefulWidget {
  const TranscriptSegmentEditor({
    super.key,
    required this.segment,
    required this.tokens,
    required this.positionMs,
    required this.isCurrent,
    required this.query,
    required this.speakerName,
    required this.showSpeaker,
    required this.showTimestamp,
    this.highlightTranslated = false,
    required this.isEditing,
    this.isRepeating = false,
    this.embedded = false,
    this.groupHovered = false,
    this.onToggleRepeat,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
  });

  final TranscriptSegment segment;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final bool isCurrent;
  final String query;
  final String speakerName;
  final bool showSpeaker;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditing;
  final bool isRepeating;
  final bool embedded;
  final bool groupHovered;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final Future<void> Function(String text) onSave;

  @override
  State<TranscriptSegmentEditor> createState() =>
      _TranscriptSegmentEditorState();
}

class _TranscriptSegmentEditorState extends State<TranscriptSegmentEditor> {
  late final TextEditingController _draft;
  late final FocusNode _fieldFocus;
  bool _hovered = false;
  bool _actionFocused = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(text: widget.segment.text);
    _fieldFocus = FocusNode();
    if (widget.isEditing) _focusEditor();
  }

  @override
  void didUpdateWidget(covariant TranscriptSegmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEditing && widget.segment.text != _draft.text) {
      _draft.text = widget.segment.text;
    }
    if (widget.isEditing && !oldWidget.isEditing) {
      _draft.text = widget.segment.text;
      _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
      _focusEditor();
    }
    if (!widget.isEditing && oldWidget.isEditing) {
      _draft.text = widget.segment.text;
    }
  }

  void _focusEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isEditing) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.onSave(_draft.text);
    if (mounted) setState(() => _saving = false);
  }

  void _seek() => widget.onSeek(reason: TranscriptSeekReason.sentenceClick);

  @override
  Widget build(BuildContext context) {
    final line = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTimestamp || _showsSpeaker)
          _TranscriptSegmentMetadata(
            segment: widget.segment,
            query: widget.query,
            speakerName: widget.speakerName,
            showSpeaker: widget.showSpeaker,
            showTimestamp: widget.showTimestamp,
            onSeek: widget.onSeek,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildContent(context)),
            const SizedBox(width: 4),
            _buildActions(context),
          ],
        ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.embedded
          ? KeyedSubtree(
              key: ValueKey('segment-original-line-${widget.segment.id}'),
              child: line,
            )
          : _TranscriptSegmentSurface(
              surfaceKey: ValueKey('segment-card-${widget.segment.id}'),
              hovered: _hovered,
              isCurrent: widget.isCurrent,
              isEditing: widget.isEditing,
              highlightTranslated: widget.highlightTranslated,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: line,
            ),
    );
  }

  bool get _showsSpeaker => widget.showSpeaker && widget.speakerName.isNotEmpty;

  Widget _buildContent(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.isEditing)
        SelectionContainer.disabled(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
            },
            child: TextField(
              key: ValueKey('segment-editor-${widget.segment.id}'),
              controller: _draft,
              focusNode: _fieldFocus,
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                contentPadding: EdgeInsets.all(4),
                border: InputBorder.none,
              ),
            ),
          ),
        )
      else
        InkWell(
          key: ValueKey('segment-text-${widget.segment.id}'),
          onTap: _seek,
          hoverColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: widget.query.isEmpty
                ? PlaybackHighlightedText(
                    text: widget.segment.text,
                    tokens: widget.tokens,
                    positionMs: widget.positionMs,
                    segmentStartMs: widget.segment.startMs,
                    segmentEndMs: widget.segment.endMs,
                    enabled: widget.isCurrent,
                    style: Theme.of(context).textTheme.bodyLarge,
                  )
                : SearchHighlightedText(
                    text: widget.segment.text,
                    query: widget.query,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
          ),
        ),
    ],
  );

  Widget _buildActions(BuildContext context) {
    if (widget.isEditing) {
      final actionCount = (widget.isRepeating ? 1 : 0) + 2;
      return SizedBox(
        width: actionCount * 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isRepeating)
              _SentenceRepeatButton(
                segmentId: widget.segment.id,
                isRepeating: true,
                onPressed: widget.onToggleRepeat,
              ),
            IconButton(
              key: ValueKey('segment-cancel-${widget.segment.id}'),
              tooltip: context.strings.t('cancel'),
              onPressed: _saving ? null : widget.onCancel,
              style: _compactSegmentActionStyle(context),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
            IconButton(
              key: ValueKey('segment-save-${widget.segment.id}'),
              tooltip: context.strings.t('save'),
              onPressed: _saving ? null : _save,
              style: _compactSegmentActionStyle(context),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
            ),
          ],
        ),
      );
    }
    final repeatVisible =
        widget.groupHovered || _hovered || _actionFocused || widget.isRepeating;
    final editVisible = _hovered || _actionFocused;
    return Focus(
      onFocusChange: (value) => setState(() => _actionFocused = value),
      child: SizedBox(
        width: 64,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SegmentActionVisibility(
              opacityKey: ValueKey(
                'segment-repeat-opacity-${widget.segment.id}',
              ),
              visible: repeatVisible,
              child: _SentenceRepeatButton(
                segmentId: widget.segment.id,
                isRepeating: widget.isRepeating,
                onPressed: widget.onToggleRepeat,
              ),
            ),
            _SegmentActionVisibility(
              opacityKey: ValueKey('segment-edit-opacity-${widget.segment.id}'),
              visible: editVisible,
              child: IconButton(
                key: ValueKey('segment-edit-${widget.segment.id}'),
                tooltip: context.strings.t('edit'),
                onPressed: widget.onEdit,
                style: _compactSegmentActionStyle(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaybackHighlightedText extends StatelessWidget {
  const PlaybackHighlightedText({
    super.key,
    required this.text,
    required this.tokens,
    required this.positionMs,
    required this.segmentStartMs,
    required this.segmentEndMs,
    this.enabled = true,
    this.style,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final int segmentStartMs;
  final int segmentEndMs;
  final bool enabled;
  final TextStyle? style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final currentRange = enabled
        ? _currentTimedTextRange(
            text: text,
            tokens: tokens,
            positionMs: positionMs,
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentEndMs,
          )
        : null;
    final selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        Theme.of(context).colorScheme.primaryContainer;
    final highlight = TextStyle(backgroundColor: selectionColor);
    final spans = <InlineSpan>[];
    if (currentRange == null) {
      spans.add(TextSpan(text: text));
    } else {
      if (currentRange.start > 0) {
        spans.add(TextSpan(text: text.substring(0, currentRange.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(currentRange.start, currentRange.end),
          style: highlight,
        ),
      );
      if (currentRange.end < text.length) {
        spans.add(TextSpan(text: text.substring(currentRange.end)));
      }
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: textAlign,
    );
  }
}

TextRange? _currentTimedTextRange({
  required String text,
  required List<TranscriptToken> tokens,
  required int positionMs,
  required int segmentStartMs,
  required int segmentEndMs,
}) {
  if (text.isEmpty || positionMs < segmentStartMs) return null;
  if (segmentEndMs > segmentStartMs && positionMs >= segmentEndMs) return null;
  final timedTokens = tokens
      .where(
        (token) =>
            (token.startMs != 0 ||
                token.endMs != 0 ||
                token.segmentId != null) &&
            token.startMs >= segmentStartMs &&
            (segmentEndMs <= segmentStartMs || token.startMs < segmentEndMs),
      )
      .toList(growable: false);
  final timedRanges = _alignTokenRanges(text, timedTokens);
  int? currentIndex;
  for (
    var index = 0;
    index < timedTokens.length && index < timedRanges.length;
    index++
  ) {
    final range = timedRanges[index];
    if (timedTokens[index].startMs > positionMs) break;
    if (range != null) currentIndex = index;
  }
  if (currentIndex == null) return null;

  var currentRange = _trimTextRange(text, timedRanges[currentIndex]!);
  if (currentRange.isCollapsed) return null;
  if (_isPunctuationToken(timedTokens[currentIndex].text)) {
    TextRange? previousWordRange;
    for (var index = currentIndex - 1; index >= 0; index--) {
      final previous = timedRanges[index];
      if (previous == null) continue;
      final previousRange = _trimTextRange(text, previous);
      if (previousRange.isCollapsed) continue;
      if (_isPunctuationToken(timedTokens[index].text)) continue;
      previousWordRange = previousRange;
      break;
    }
    if (previousWordRange == null) return null;
    currentRange = previousWordRange;
  }
  final expandedRange = _expandToWholeLatinWord(text, currentRange);
  final highlightRange = _trimPunctuationEdges(text, expandedRange);
  return highlightRange.isCollapsed ? null : highlightRange;
}

TextRange _trimTextRange(String text, TextRange range) {
  var start = range.start.clamp(0, text.length);
  var end = range.end.clamp(start, text.length);
  while (start < end && text.substring(start, start + 1).trim().isEmpty) {
    start++;
  }
  while (end > start && text.substring(end - 1, end).trim().isEmpty) {
    end--;
  }
  return TextRange(start: start, end: end);
}

bool _isPunctuationToken(String text) {
  final value = text.trim();
  return value.isNotEmpty && value.codeUnits.every(_isPunctuationCodeUnit);
}

TextRange _trimPunctuationEdges(String text, TextRange range) {
  var start = range.start.clamp(0, text.length);
  var end = range.end.clamp(start, text.length);
  while (start < end &&
      (_isWhitespaceCodeUnit(text.codeUnitAt(start)) ||
          _isPunctuationCodeUnit(text.codeUnitAt(start)))) {
    start++;
  }
  while (end > start &&
      (_isWhitespaceCodeUnit(text.codeUnitAt(end - 1)) ||
          _isPunctuationCodeUnit(text.codeUnitAt(end - 1)))) {
    end--;
  }
  return TextRange(start: start, end: end);
}

bool _isWhitespaceCodeUnit(int codeUnit) =>
    String.fromCharCode(codeUnit).trim().isEmpty;

bool _isPunctuationCodeUnit(int codeUnit) =>
    (codeUnit >= 0x21 && codeUnit <= 0x2f) ||
    (codeUnit >= 0x3a && codeUnit <= 0x40) ||
    (codeUnit >= 0x5b && codeUnit <= 0x60) ||
    (codeUnit >= 0x7b && codeUnit <= 0x7e) ||
    (codeUnit >= 0x2000 && codeUnit <= 0x206f) ||
    (codeUnit >= 0x2e00 && codeUnit <= 0x2e7f) ||
    (codeUnit >= 0x3000 && codeUnit <= 0x303f) ||
    (codeUnit >= 0xfe10 && codeUnit <= 0xfe1f) ||
    (codeUnit >= 0xfe30 && codeUnit <= 0xfe4f) ||
    (codeUnit >= 0xff01 && codeUnit <= 0xff0f) ||
    (codeUnit >= 0xff1a && codeUnit <= 0xff20) ||
    (codeUnit >= 0xff3b && codeUnit <= 0xff40) ||
    (codeUnit >= 0xff5b && codeUnit <= 0xff65);

TextRange _expandToWholeLatinWord(String text, TextRange range) {
  final selected = text.substring(range.start, range.end);
  if (!selected.codeUnits.any(_isLatinLetterOrDigit)) return range;
  var start = range.start;
  var end = range.end;
  while (start > 0 && _isLatinWordCodeUnit(text.codeUnitAt(start - 1))) {
    start--;
  }
  while (end < text.length && _isLatinWordCodeUnit(text.codeUnitAt(end))) {
    end++;
  }
  return TextRange(start: start, end: end);
}

bool _isLatinLetterOrDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
    (codeUnit >= 0x00c0 && codeUnit <= 0x024f);

bool _isLatinWordCodeUnit(int codeUnit) =>
    _isLatinLetterOrDigit(codeUnit) ||
    (codeUnit >= 0x0300 && codeUnit <= 0x036f) ||
    codeUnit == 0x27 ||
    codeUnit == 0x2019 ||
    codeUnit == 0x2d;

List<TextRange?> _alignTokenRanges(String text, List<TranscriptToken> tokens) {
  if (tokens.isEmpty) return const [];
  final raw = StringBuffer();
  final rawRanges = <TextRange>[];
  for (final token in tokens) {
    final start = raw.length;
    raw.write(token.text);
    rawRanges.add(TextRange(start: start, end: raw.length));
  }
  final joined = raw.toString();
  final leading = joined.length - joined.trimLeft().length;
  final trailing = joined.trimRight().length;
  final normalized = joined.substring(leading, trailing);
  if (normalized == text) {
    return [
      for (final range in rawRanges)
        TextRange(
          start: (range.start - leading).clamp(0, text.length),
          end: (range.end - leading).clamp(0, text.length),
        ),
    ];
  }

  final normalizedText = text.toLowerCase();
  final result = <TextRange?>[];
  var cursor = 0;
  for (final token in tokens) {
    final part = token.text.trim();
    if (part.isEmpty) {
      result.add(null);
      continue;
    }
    final match = normalizedText.indexOf(part.toLowerCase(), cursor);
    if (match < 0) {
      result.add(null);
      continue;
    }
    final end = match + part.length;
    result.add(TextRange(start: match, end: end));
    cursor = end;
  }
  return result;
}

class LatestSeekDispatcher {
  LatestSeekDispatcher(this._performSeek);

  final Future<void> Function(Duration position) _performSeek;
  Duration? _pendingPosition;
  Completer<void>? _drainCompleter;

  Future<void> seek(Duration position) {
    _pendingPosition = position;
    final active = _drainCompleter;
    if (active != null) return active.future;

    final completer = Completer<void>();
    _drainCompleter = completer;
    unawaited(_drain(completer));
    return completer.future;
  }

  Future<void> get idle => _drainCompleter?.future ?? Future<void>.value();

  bool get isBusy => _drainCompleter != null;

  Future<void> _drain(Completer<void> completer) async {
    try {
      while (_pendingPosition != null) {
        final position = _pendingPosition!;
        _pendingPosition = null;
        await _performSeek(position);
      }
      completer.complete();
    } catch (error, stackTrace) {
      _pendingPosition = null;
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_drainCompleter, completer)) _drainCompleter = null;
    }
  }
}

const _sentenceRepeatPreRollMs = 350;
const _sentenceRepeatPreviousCueSafetyMs = 100;
const _repeatSeekUndershootToleranceMs = 250;

int sentenceRepeatStartMs(
  TranscriptSegment segment, {
  TranscriptSegment? previousSegment,
}) {
  final requestedStartMs = segment.startMs - _sentenceRepeatPreRollMs;
  final clampedStartMs = requestedStartMs < 0 ? 0 : requestedStartMs;
  if (previousSegment == null) return clampedStartMs;
  final previousEndMs = previousSegment.endMs.clamp(0, segment.startMs).toInt();
  final safeStartMs = (previousEndMs + _sentenceRepeatPreviousCueSafetyMs)
      .clamp(0, segment.startMs)
      .toInt();
  return clampedStartMs < safeStartMs ? safeStartMs : clampedStartMs;
}

bool shouldAutoFollowPlaybackSegment({
  required bool playing,
  required int? previousIndex,
  required int? nextIndex,
  required bool repeating,
}) => playing && !repeating && previousIndex != nextIndex;

enum TranscriptSeekReason {
  standard,
  videoProgressScrub,
  sentenceClick,
  repeatRestart,
}

typedef TranscriptSeekCallback =
    Future<void> Function(Duration position, {TranscriptSeekReason reason});

typedef TranscriptSegmentSeekCallback =
    void Function({required TranscriptSeekReason reason});

bool shouldFocusTranscriptAfterSeek(TranscriptSeekReason reason) =>
    reason == TranscriptSeekReason.standard;

bool shouldFocusTranscriptOnPlaybackResume({required bool repeating}) =>
    !repeating;

bool shouldRestartRepeatedSentence(
  TranscriptSegment segment,
  int positionMs, {
  TranscriptSegment? previousSegment,
}) =>
    segment.endMs > segment.startMs &&
    (positionMs <
            sentenceRepeatStartMs(segment, previousSegment: previousSegment) -
                _repeatSeekUndershootToleranceMs ||
        positionMs >= segment.endMs);

int? currentTranscriptSegmentIndex(
  List<TranscriptSegment> segments,
  int positionMs, {
  String? pinnedSegmentId,
}) {
  if (pinnedSegmentId != null) {
    final pinnedIndex = segments.indexWhere(
      (segment) => segment.id == pinnedSegmentId,
    );
    if (pinnedIndex >= 0) return pinnedIndex;
  }
  if (segments.isEmpty || positionMs < segments.first.startMs) return null;
  var low = 0;
  var high = segments.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (segments[middle].startMs <= positionMs) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return high;
}

String? fullscreenTranscriptSubtitle(
  List<TranscriptSegment> segments,
  int positionMs,
  TranslationViewMode viewMode, {
  String? pinnedSegmentId,
}) {
  final index = currentTranscriptSegmentIndex(
    segments,
    positionMs,
    pinnedSegmentId: pinnedSegmentId,
  );
  if (index == null) return null;
  final segment = segments[index];
  final isPinned = segment.id == pinnedSegmentId;
  if (!isPinned &&
      (positionMs < segment.startMs || positionMs >= segment.endMs)) {
    return null;
  }

  final original = segment.text.trim();
  final translated = segment.translatedText?.trim() ?? '';
  final lines = switch (viewMode) {
    TranslationViewMode.original => [original],
    TranslationViewMode.translated => [
      translated.isNotEmpty ? translated : original,
    ],
    TranslationViewMode.bilingual => [original, translated],
  }.where((line) => line.isNotEmpty).toList();
  return lines.isEmpty ? null : lines.join('\n');
}

TextRange? fullscreenTranscriptWordRange(
  TranscriptDocument document,
  int positionMs,
  TranslationViewMode viewMode, {
  String? pinnedSegmentId,
}) {
  final index = currentTranscriptSegmentIndex(
    document.segments,
    positionMs,
    pinnedSegmentId: pinnedSegmentId,
  );
  if (index == null) return null;
  final segment = document.segments[index];
  if (positionMs < segment.startMs || positionMs >= segment.endMs) return null;

  final original = segment.text.trim();
  final translated = segment.translatedText?.trim() ?? '';
  final originalIsVisible = switch (viewMode) {
    TranslationViewMode.original => original.isNotEmpty,
    TranslationViewMode.translated => translated.isEmpty && original.isNotEmpty,
    TranslationViewMode.bilingual => original.isNotEmpty,
  };
  if (!originalIsVisible) return null;

  final tokens = document.tokens
      .where(
        (token) =>
            token.startMs >= segment.startMs && token.startMs < segment.endMs,
      )
      .toList(growable: false);
  return _currentTimedTextRange(
    text: original,
    tokens: tokens,
    positionMs: positionMs,
    segmentStartMs: segment.startMs,
    segmentEndMs: segment.endMs,
  );
}

class SearchHighlightedText extends StatelessWidget {
  const SearchHighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
  });

  final String text;
  final String query;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Text(text, style: style);
    final normalizedText = text.toLowerCase();
    final normalizedQuery = trimmed.toLowerCase();
    final highlight = TextStyle(
      color: Theme.of(context).colorScheme.onPrimaryContainer,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      fontWeight: FontWeight.w700,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      final match = normalizedText.indexOf(normalizedQuery, cursor);
      if (match < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (match > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match)));
      }
      final end = match + trimmed.length;
      spans.add(TextSpan(text: text.substring(match, end), style: highlight));
      cursor = end;
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
