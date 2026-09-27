part of '../transcript_review.dart';

class _TranscriptReviewState extends State<TranscriptReview>
    with WindowListener {
  final _dictationAttempts = <String, _DictationAttempt>{};
  final _dictationText = TextEditingController();
  final _dictationFocus = FocusNode();
  bool _dictationOpen = false;
  int _dictationPauseGeneration = 0;
  int _dictationReplayRequest = 0;
  int? _dictationReplayEndMs;
  String? _dictationTargetId;
  TranscriptDocument? _dictationDocument;

  bool _mimicOpen = false;
  String? _mimicTargetId;
  final _mimicReps = <String, int>{};
  bool _mimicPassCounted = false;
  Timer? _mimicRepeatTimer;
  int _mimicWaitGeneration = 0;
  bool _mimicWaiting = false;

  bool get _playbackActive => _playing || _mimicWaiting;

  static const _reviewDividerWidth = 9.0;
  static const _minimumReviewPaneWidth = 280.0;
  static const _minimumCompanionPaneWidth = 420.0;
  static const _videoTitleHeaderHeight = 52.0;
  static const _mediaModeTransitionDuration = Duration(milliseconds: 320);
  static const _missingSourceAudioHeight = 112.0;
  static const _structureNoticeDuration = Duration(seconds: 4);

  Player? _player;
  LatestSeekDispatcher? _seekDispatcher;
  SentenceRepeatLoopController? _sentenceRepeatLoop;
  Future<void> _sentenceRepeatLoopUpdate = Future<void>.value();
  int _sentenceRepeatLoopRequest = 0;
  String? _nativeRepeatingSegmentId;
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
  Duration? _pendingPlaybackRestore;
  int? _pendingPlaybackRestoreRequest;
  bool _playbackRestoreReady = false;
  bool _playbackRestoreSeekInFlight = false;
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
  bool _structureMode = false;
  String? _structureNoticeMessageKey;
  Timer? _structureNoticeTimer;
  int _structureNoticeGeneration = 0;
  bool _showAiBrief = false;
  String? _revealedSegmentId;
  int _sentenceNavigationRequest = 0;
  bool _sentenceNavigationPending = false;
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
  final _structureEditor = TranscriptStructureEditor();
  TranscriptDocument? _structureAvailabilityDocument;
  bool _cachedStructureEditingAvailable = false;

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
  void onWindowBlur() {
    _endSentenceRepeatHold();
    unawaited(TranscriptStructureCursors.deactivateAll());
  }

  @override
  void onWindowFocus() {
    TranscriptStructureCursors.beginNewGeneration();
    if (mounted) setState(() {});
  }

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
    _sentenceRepeatLoop =
        debugTranscriptReviewSentenceRepeatLoopFactory?.call(player) ??
        _mpvSentenceRepeatLoopFor(player);
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
      _cancelMimicWait();
      unawaited(TranscriptStructureCursors.deactivateAll());
      _resetStructureNotice();
      _cancelDictationReplay();
      _dictationDocument = null;
      _dictationAttempts.clear();
      _dictationTargetId = null;
      _dictationOpen = false;
      _dictationText.clear();
      _dictationFocus.unfocus();
      _mimicOpen = false;
      _mimicTargetId = null;
      _mimicReps.clear();
      _mimicPassCounted = false;
      _rememberPlaybackPosition(oldWidget.jobId);
      _sourceRequest++;
      _clearPendingPlaybackRestore();
      _search.clear();
      _revealedSegmentId = null;
      _sentenceNavigationRequest++;
      _sentenceNavigationPending = false;
      _position = _appController.playbackPositionFor(widget.jobId);
      _duration = Duration.zero;
      _videoAspectRatio = 16 / 9;
      _playing = false;
      _manualRepeatingSegmentId = null;
      _heldRepeatingSegmentId = null;
      _nativeRepeatingSegmentId = null;
      _repeatRestartQueued = false;
      _repeatRestartQueuedResume = false;
      _followPlayback = true;
      _searchVisible = false;
      _structureMode = false;
      _showAiBrief = false;
      _editingSegmentId = null;
      _editingTranslationSegmentId = null;
      _viewMode = _defaultViewMode(_appController.jobById(widget.jobId));
      _lastScrolledSegmentId = null;
      _mappedDocument = null;
      _tokensBySegment = const {};
      _structureAvailabilityDocument = null;
      _cachedStructureEditingAvailable = false;
      _openedPath = '';
      _waveformSource = '';
      _waveformPath = null;
      _waveformLoading = false;
      _mediaMode = _ReviewMediaMode.video;
      _companionLeftPaneFraction = null;
      _companionLayoutActive = false;
      if (_aiBriefScroll.hasClients) _aiBriefScroll.jumpTo(0);
      unawaited(_setNativeSentenceRepeat(null));
      _openSource();
    }
  }

  void _handlePosition(Duration value) {
    if (!mounted ||
        _sentenceNavigationPending ||
        _repeatRestartPending ||
        _mimicWaiting ||
        (_seekDispatcher?.isBusy ?? false)) {
      return;
    }
    if (_consumePlaybackRestoreReset(value)) return;
    final previousMs = _position.inMilliseconds;
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
    setState(() {
      final listeningIndex = currentListeningSegmentIndex(
        document?.segments ?? const [],
        value.inMilliseconds,
      );
      final repeatingRevealedSentence =
          _revealedSegmentId != null &&
          _repeatingSegmentId == _revealedSegmentId;
      if (!repeatingRevealedSentence &&
          (listeningIndex == null ||
              document!.segments[listeningIndex].id != _revealedSegmentId)) {
        _revealedSegmentId = null;
      }
      _position = value;
    });
    _appController.rememberPlaybackPosition(widget.jobId, value);
    final replayEnd = _dictationReplayEndMs;
    if (replayEnd != null && value.inMilliseconds >= replayEnd) {
      _cancelDictationReplay();
      unawaited(_player?.pause());
    }
    final repeatedSegment = _repeatingSegment;
    if (_playing && repeatedSegment != null) {
      final previousSegment = _previousSegmentFor(repeatedSegment);
      final nextSegment = _nextSegmentFor(repeatedSegment);
      if (_nativeSentenceRepeatActive) {
        if (isRepeatLoopWrap(
          repeatedSegment,
          previousMs: previousMs,
          currentMs: value.inMilliseconds,
          previousSegment: previousSegment,
          nextSegment: nextSegment,
        )) {
          _mimicPassCounted = false;
          _countMimicRep(repeatedSegment);
        }
      } else {
        if (isRepeatLoopEndCrossing(
          repeatedSegment,
          previousMs: previousMs,
          currentMs: value.inMilliseconds,
          previousSegment: previousSegment,
          nextSegment: nextSegment,
        )) {
          _countMimicRep(repeatedSegment);
        }
        if (_repeatingSegmentId == repeatedSegment.id &&
            shouldRestartRepeatedSentence(
              repeatedSegment,
              value.inMilliseconds,
              previousSegment: previousSegment,
              nextSegment: nextSegment,
            )) {
          _queueRepeatRestart(resumeAfterSeek: true);
        }
      }
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

  bool _consumePlaybackRestoreReset(Duration value) {
    final target = _pendingPlaybackRestore;
    final request = _pendingPlaybackRestoreRequest;
    if (target == null || request == null) return false;
    if (request != _sourceRequest) {
      _clearPendingPlaybackRestore();
      return false;
    }
    final targetMs = target.inMilliseconds;
    final toleranceMs = min(500, max(1, targetMs ~/ 4));
    final isStartupReset =
        value <= Duration.zero || value.inMilliseconds + toleranceMs < targetMs;
    if (isStartupReset) {
      if (_playbackRestoreReady) {
        unawaited(_reassertPendingPlaybackRestore(target, request));
      }
      return true;
    }
    if (_playing) _clearPendingPlaybackRestore();
    return false;
  }

  Future<void> _reassertPendingPlaybackRestore(
    Duration target,
    int request,
  ) async {
    final seekDispatcher = _seekDispatcher;
    if (seekDispatcher == null ||
        _playbackRestoreSeekInFlight ||
        request != _sourceRequest ||
        _pendingPlaybackRestore != target) {
      return;
    }
    _playbackRestoreSeekInFlight = true;
    try {
      await seekDispatcher.seek(target);
    } on Object {
      // A later native position event can retry while restoration is pending.
    } finally {
      if (_pendingPlaybackRestoreRequest == request) {
        _playbackRestoreSeekInFlight = false;
      }
    }
  }

  void _clearPendingPlaybackRestore() {
    _pendingPlaybackRestore = null;
    _pendingPlaybackRestoreRequest = null;
    _playbackRestoreReady = false;
    _playbackRestoreSeekInFlight = false;
  }

  void _handlePlaying(bool value) {
    if (!mounted || value == _playing) return;
    if (value && _mimicWaiting) _cancelMimicWait();
    final resumed = value && !_playing;
    setState(() {
      _playing = value;
      if (resumed) _followPlayback = true;
    });
    final repeatedSegment = _repeatingSegment;
    if (resumed &&
        repeatedSegment != null &&
        !_nativeSentenceRepeatActive &&
        shouldRestartRepeatedSentence(
          repeatedSegment,
          _position.inMilliseconds,
          previousSegment: _previousSegmentFor(repeatedSegment),
          nextSegment: _nextSegmentFor(repeatedSegment),
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
        _repeatRestartPending ||
        _mimicWaiting ||
        player == null ||
        !player.state.completed ||
        _repeatingSegment == null) {
      return;
    }
    final segment = _repeatingSegment!;
    if (!_nativeSentenceRepeatActive &&
        _position.inMilliseconds >=
            sentenceRepeatStartMs(
              segment,
              previousSegment: _previousSegmentFor(segment),
            )) {
      _countMimicRep(segment);
    }
    if (_repeatingSegmentId == segment.id) {
      _queueRepeatRestart(resumeAfterSeek: true);
    }
  }

  /// Counts one pass of the mimic target; [_mimicPassCounted] keeps the end
  /// crossing and the completion event of the same pass from both counting.
  void _countMimicRep(TranscriptSegment segment) {
    if (!_mimicOpen ||
        segment.id != _mimicTargetId ||
        _mimicPassCounted ||
        _mimicWaiting) {
      return;
    }
    _mimicPassCounted = true;
    setState(() {
      _mimicReps[segment.id] = min(
        (_mimicReps[segment.id] ?? 0) + 1,
        _appController.settings.mimicRepGoal,
      );
    });
    if (_mimicGoalReached(segment.id) && _nextSegmentFor(segment) == null) {
      _stopMimicLoop();
    } else {
      unawaited(_waitBeforeMimicRepeat(segment.id));
    }
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

  bool get _nativeSentenceRepeatActive {
    final segmentId = _repeatingSegmentId;
    return segmentId != null && _nativeRepeatingSegmentId == segmentId;
  }

  Future<bool> _setNativeSentenceRepeat(TranscriptSegment? segment) {
    final loop = _sentenceRepeatLoop;
    final request = ++_sentenceRepeatLoopRequest;
    _nativeRepeatingSegmentId = null;
    if (loop == null) return Future<bool>.value(false);

    final completer = Completer<bool>();
    final previous = _sentenceRepeatLoopUpdate;
    _sentenceRepeatLoopUpdate = () async {
      try {
        try {
          await previous;
        } on Object {
          // A failed native property update must not block the latest request.
        }
        if (request != _sentenceRepeatLoopRequest ||
            !identical(loop, _sentenceRepeatLoop)) {
          completer.complete(false);
          return;
        }
        if (segment == null) {
          await loop.clear();
          completer.complete(false);
          return;
        }
        if (_repeatingSegmentId != segment.id) {
          completer.complete(false);
          return;
        }
        await loop.setRange(
          startMs: sentenceRepeatStartMs(
            segment,
            previousSegment: _previousSegmentFor(segment),
          ),
          endMs: sentenceRepeatEndMs(
            segment,
            nextSegment: _nextSegmentFor(segment),
          ),
        );
        final active =
            request == _sentenceRepeatLoopRequest &&
            identical(loop, _sentenceRepeatLoop) &&
            _repeatingSegmentId == segment.id;
        if (active) _nativeRepeatingSegmentId = segment.id;
        completer.complete(active);
      } on Object {
        if (request == _sentenceRepeatLoopRequest) {
          _nativeRepeatingSegmentId = null;
        }
        completer.complete(false);
      }
    }();
    return completer.future;
  }

  TranscriptSegment? _previousSegmentFor(TranscriptSegment segment) {
    final segments = _document?.segments;
    if (segments == null) return null;
    final index = segments.indexWhere((item) => item.id == segment.id);
    return index > 0 ? segments[index - 1] : null;
  }

  TranscriptSegment? _nextSegmentFor(TranscriptSegment segment) {
    final segments = _document?.segments;
    if (segments == null) return null;
    final index = segments.indexWhere((item) => item.id == segment.id);
    return index >= 0 && index + 1 < segments.length
        ? segments[index + 1]
        : null;
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
    _cancelMimicWait();
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
      _pendingPlaybackRestore = resumePosition > Duration.zero
          ? resumePosition
          : null;
      _pendingPlaybackRestoreRequest = resumePosition > Duration.zero
          ? request
          : null;
      _playbackRestoreReady = false;
      _playbackRestoreSeekInFlight = false;
      final player = _player!;
      await _setNativeSentenceRepeat(null);
      if (!mounted || request != _sourceRequest || widget.jobId != job.id) {
        return;
      }
      await player.open(Media(job.sourcePath), play: false);
      if (!mounted || request != _sourceRequest || widget.jobId != job.id) {
        return;
      }
      if (job.metadata?.hasVideo ?? false) {
        try {
          await player.setSubtitleTrack(SubtitleTrack.no());
        } on Object {
          // Playback remains usable if a platform cannot control subtitles.
        }
      }
      if (!mounted || request != _sourceRequest || widget.jobId != job.id) {
        return;
      }
      final duration = player.state.duration;
      final restoredPosition =
          duration > Duration.zero && resumePosition > duration
          ? duration
          : resumePosition;
      if (restoredPosition > Duration.zero) {
        _pendingPlaybackRestore = restoredPosition;
        await _seekDispatcher!.seek(restoredPosition);
        _playbackRestoreReady = true;
      } else {
        _clearPendingPlaybackRestore();
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
    _cancelMimicWait();
    _endSentenceRepeatHold(notify: false);
    HardwareKeyboard.instance.removeHandler(_handleReviewShortcut);
    _rememberPlaybackPosition(widget.jobId);
    _fullscreenController.unregisterMediaShutdown(this);
    windowManager.removeListener(this);
    _cancelDictationReplay();
    _dictationText.dispose();
    _dictationFocus.dispose();
    _search.dispose();
    _aiBriefScroll.dispose();
    _structureNoticeTimer?.cancel();
    unawaited(_shutdownMedia());
    unawaited(TranscriptStructureCursors.deactivateAll());
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
    _cancelMimicWait();
    _cancelDictationReplay();
    _sourceRequest++;
    _clearPendingPlaybackRestore();
    final player = _player;
    _player = null;
    await _setNativeSentenceRepeat(null);
    _sentenceRepeatLoop = null;
    _nativeRepeatingSegmentId = null;
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
    _syncDictation(document);
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
        ? _blindListening
              ? currentListeningSegmentIndex(
                  document.segments,
                  _position.inMilliseconds,
                )
              : currentTranscriptSegmentIndex(
                  document.segments,
                  _position.inMilliseconds,
                  pinnedSegmentId: _repeatingSegmentId,
                )
        : null;
    return Column(
      key: const Key('transcript-review-surface'),
      children: [
        _UnifiedReviewToolbar(
          dictationOpen: _dictationOpen,
          onToggleDictation: _dictationOpen || _currentSentenceId != null
              ? _toggleDictation
              : null,
          mimicOpen: _mimicOpen,
          onToggleMimic: _mimicOpen || _currentSentenceId != null
              ? _toggleMimic
              : null,
          blindListening: _blindListening,
          sentenceRevealed: _sentenceRevealed,
          onReveal: _currentSentenceId == null ? null : _toggleReveal,
          onToggleBlindListening:
              _editingSegmentId == null && _editingTranslationSegmentId == null
              ? _toggleBlindListening
              : null,
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
            if (value && _structureMode) {
              unawaited(TranscriptStructureCursors.deactivateAll());
            }
            setState(() {
              _showAiBrief = value;
              if (value) _searchVisible = false;
              if (value) _structureMode = false;
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

              // Structure adds another persistent transcript action. Keep the
              // minimum workspace width stacked so neither pane is cramped.
              final sideBySide = constraints.maxWidth >= 880;
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
      sentenceNavigation: _sentenceNavigationControls(),
      playing: _playbackActive,
      position: _position,
      duration: mediaDuration,
      waveformPath: _waveformPath,
      waveformLoading: _waveformLoading,
      onPlayPause: _togglePlayback,
      onSeek: _seek,
      onSwitchToVideoMode: audioMode ? () => _toggleMediaMode(job) : null,
    );
    if (audioMode) return audio;
    late final Widget pane;
    if (hasVideo) {
      final video = _MediaPane(
        sentenceNavigation: _sentenceNavigationControls(),
        job: job,
        video: _video!,
        videoKey: _videoKey,
        videoAspectRatio: _videoAspectRatio,
        maxVideoHeight: videoHeight,
        centerInAvailableHeight: fillHeight,
        playing: _playbackActive,
        playbackRate: _playbackRate,
        position: _position,
        duration: _duration,
        onPlayPause: _togglePlayback,
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
    final structureEnabled = _structureEditingAvailable(job, document);
    final structureInteractionsActive =
        _structureMode &&
        _editingSegmentId == null &&
        _editingTranslationSegmentId == null;
    final transcript = Column(
      children: [
        if (job.translationState.status != TranslationStatus.idle &&
            job.translationState.status != TranslationStatus.completed)
          _TranslationStatusStrip(job: job),
        if (controller.settings.showSpeakers && document.speakers.isNotEmpty)
          IgnorePointer(
            ignoring: _blindListening,
            child: ExcludeFocus(
              excluding: _blindListening,
              child: SpeakerStrip(job: job, document: document),
            ),
          ),
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
                  separatorBuilder: (_, index) {
                    if (!structureInteractionsActive) {
                      return const SizedBox(height: 8);
                    }
                    return _TranscriptMergeBoundary(
                      key: ValueKey('structure-merge-${segments[index].id}'),
                      enabled: _structureMergeAllowed(document, index),
                      onMerge: () => _applyStructureEdit(
                        MergeWithNext(segments[index].id),
                      ),
                    );
                  },
                  itemBuilder: (context, index) {
                    final segment = segments[index];
                    final tokens =
                        _tokensBySegment[segment.id] ??
                        const <TranscriptToken>[];
                    return _TranscriptSegmentGroup(
                      key: ValueKey('group-${segment.id}'),
                      blindListening: _blindListening,
                      blurred:
                          _blindListening &&
                          (_revealedSegmentId != segment.id ||
                              _currentSentenceId != segment.id),
                      segment: segment,
                      tokens: tokens,
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
                      structureMode: structureInteractionsActive,
                      splitTargets: structureInteractionsActive
                          ? _structureEditor.splitTargets(document, segment.id)
                          : const [],
                      isRepeating: _repeatingSegmentId == segment.id,
                      onToggleRepeat: _canRepeat(segment)
                          ? () => _toggleSentenceRepeat(segment)
                          : null,
                      onSeek: ({required reason}) =>
                          _seekTranscriptSegment(segment, reason: reason),
                      onEditOriginal: () => _startEditing(segment.id),
                      onCancelOriginal: () => _cancelEditing(segment.id),
                      onSaveOriginal: (text) => _saveSegment(segment.id, text),
                      onSplit: (rightTokenIndex) => _applyStructureEdit(
                        SplitAtTokenBoundary(
                          segment.id,
                          rightTokenIndex: rightTokenIndex,
                        ),
                      ),
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
          dictationOpen: _dictationOpen,
          onToggleDictation: _dictationOpen || _currentSentenceId != null
              ? _toggleDictation
              : null,
          mimicOpen: _mimicOpen,
          onToggleMimic: _mimicOpen || _currentSentenceId != null
              ? _toggleMimic
              : null,
          blindListening: _blindListening,
          sentenceRevealed: _sentenceRevealed,
          onReveal: _currentSentenceId == null ? null : _toggleReveal,
          onToggleBlindListening:
              _editingSegmentId == null && _editingTranslationSegmentId == null
              ? _toggleBlindListening
              : null,
          role: _ReviewToolbarRole.transcript,
          job: job,
          viewMode: _viewMode,
          showAiBrief: _showAiBrief,
          search: _search,
          searchVisible: _searchVisible,
          onTabChanged: (_) {},
          onViewModeChanged: (value) {
            if (_structureMode && value != TranslationViewMode.original) {
              _toggleStructureMode();
            }
            setState(() => _viewMode = value);
          },
          onOpenSearch: () {
            if (_structureMode) _toggleStructureMode();
            setState(() => _searchVisible = true);
          },
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
          structureMode: _structureMode,
          structureEnabled: structureEnabled,
          onToggleStructure: _toggleStructureMode,
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              transcript,
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    reverseDuration: const Duration(milliseconds: 120),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween(begin: .96, end: 1.0).animate(animation),
                        alignment: Alignment.bottomRight,
                        child: child,
                      ),
                    ),
                    child: _structureNoticeMessageKey == null
                        ? const SizedBox.shrink()
                        : AppNoticeSurface(
                            key: const ValueKey('transcript-structure-notice'),
                            message: context.strings.t(
                              _structureNoticeMessageKey!,
                            ),
                            tone: AppNoticeTone.success,
                            actionLabel: context.strings.t('undo'),
                            actionKey: const Key(
                              'transcript-structure-notice-undo',
                            ),
                            dismissKey: const Key(
                              'dismiss-transcript-structure-notice',
                            ),
                            onAction: () => unawaited(_undoStructureEdit()),
                            onDismiss: _dismissStructureNotice,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_blindListening &&
            _dictationOpen &&
            !_fullscreenController.isActive)
          _buildDictationPanel(document),
        if (_mimicOpen && !_fullscreenController.isActive)
          _buildMimicPanel(document),
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
      showAppNotice(context, message: context.strings.t('ai_brief_configure'));
      return;
    }
    final result = await _showAiBriefGenerationDialog(context, job);
    if (result == null || !mounted) return;
    if (job.aiBrief?.edited ?? false) {
      final replace = await _showDialogAfterDismissal<bool>(
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
      _showAiBrief = !_blindListening;
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
      blindListening: _blindListening,
      sentenceRevealed: _sentenceRevealed,
      onReveal: _currentSentenceId == null ? null : _toggleReveal,
      onListeningKey: _handleListeningShortcut,
      sentenceNavigation: _sentenceNavigationControls(),
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
      playing: _playbackActive,
      position: _position,
      duration: mediaDuration,
      onExit: () => unawaited(_fullscreenController.exit()),
      onPlayPause: () => unawaited(_togglePlayback()),
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
    _dictationFocus.unfocus();
    if (mounted) setState(() {});
    await defaultEnterNativeFullscreen();
  }

  Future<void> _exitNativeFullscreen() async {
    _endSentenceRepeatHold();
    _fullscreenController.markExited();
    if (mounted) setState(() {});
    _playbackTick.tick();
    await defaultExitNativeFullscreen();
  }

  void _seekTranscriptSegment(
    TranscriptSegment segment, {
    required TranscriptSeekReason reason,
  }) {
    if (_mimicOpen && reason == TranscriptSeekReason.sentenceClick) {
      _selectMimicTarget(segment, resetReps: true);
      return;
    }
    unawaited(_seek(Duration(milliseconds: segment.startMs), reason: reason));
  }

  Future<void> _seek(
    Duration position, {
    TranscriptSeekReason reason = TranscriptSeekReason.standard,
  }) async {
    if (reason != TranscriptSeekReason.repeatRestart) {
      _cancelMimicWait();
      _cancelDictationReplay();
    }
    final seekDispatcher = _seekDispatcher;
    if (seekDispatcher == null) return;
    _clearPendingPlaybackRestore();
    _mimicPassCounted = false;
    setState(() {
      final index = currentListeningSegmentIndex(
        _document?.segments ?? const [],
        position.inMilliseconds,
      );
      if (index == null ||
          _document!.segments[index].id != _revealedSegmentId) {
        _revealedSegmentId = null;
      }
      _position = position;
      if (_blindListening &&
          _dictationOpen &&
          reason != TranscriptSeekReason.repeatRestart) {
        _selectDictationTarget(_currentSentenceId);
      }
      _followPlayback = true;
    });
    _appController.rememberPlaybackPosition(widget.jobId, position);
    if (shouldFocusTranscriptAfterSeek(reason)) {
      _queueFocusCurrent(force: true);
    }
    await seekDispatcher.seek(position);
  }

  bool _canRepeat(TranscriptSegment segment) =>
      _player != null &&
      sentenceRepeatEndMs(segment, nextSegment: _nextSegmentFor(segment)) >
          segment.startMs;

  void _toggleSentenceRepeat(TranscriptSegment segment) {
    if (_mimicOpen) {
      if (_mimicTargetId == segment.id) {
        _toggleMimicLoop();
      } else {
        _selectMimicTarget(segment, resetReps: true);
      }
      return;
    }
    _cancelDictationReplay();
    if (_manualRepeatingSegmentId == segment.id) {
      setState(() {
        _manualRepeatingSegmentId = null;
        _repeatRestartQueued = false;
        _repeatRestartQueuedResume = false;
      });
      unawaited(_setNativeSentenceRepeat(_repeatingSegment));
      return;
    }
    if (!_canRepeat(segment)) return;
    setState(() => _manualRepeatingSegmentId = segment.id);
    _queueRepeatRestart(resumeAfterSeek: true);
  }

  void _syncDictation(TranscriptDocument document) {
    if (identical(document, _dictationDocument)) return;
    _dictationDocument = document;
    final byId = {for (final segment in document.segments) segment.id: segment};
    _dictationAttempts.removeWhere((id, _) => !byId.containsKey(id));
    for (final entry in _dictationAttempts.entries) {
      final reference = byId[entry.key]!.text;
      if (entry.value.reference != reference) {
        entry.value.reference = reference;
        entry.value.result = null;
      }
    }
    if (!byId.containsKey(_dictationTargetId)) _dictationTargetId = null;
  }

  void _selectDictationTarget(String? id) {
    _dictationTargetId = id;
    final segment = _document?.segments.where((s) => s.id == id).firstOrNull;
    final attempt = segment == null
        ? null
        : _dictationAttempts.putIfAbsent(
            segment.id,
            () => _DictationAttempt(segment.text),
          );
    _dictationText.value = TextEditingValue(
      text: attempt?.draft ?? '',
      selection: TextSelection.collapsed(offset: attempt?.draft.length ?? 0),
    );
  }

  void _cancelDictationReplay() {
    _dictationReplayRequest++;
    _dictationReplayEndMs = null;
  }

  Future<void> _replayDictationOnce(TranscriptSegment segment) async {
    final player = _player;
    if (player == null || !_canRepeat(segment)) return;
    _pauseForDictation();
    final request = _dictationReplayRequest;
    bool current() =>
        mounted &&
        identical(player, _player) &&
        request == _dictationReplayRequest;
    setState(() {
      _manualRepeatingSegmentId = null;
      _heldRepeatingSegmentId = null;
    });
    await _setNativeSentenceRepeat(null);
    if (!current()) return;
    await _seek(
      Duration(
        milliseconds: sentenceRepeatStartMs(
          segment,
          previousSegment: _previousSegmentFor(segment),
        ),
      ),
      reason: TranscriptSeekReason.repeatRestart,
    );
    if (!current()) return;
    _dictationReplayEndMs = sentenceRepeatEndMs(
      segment,
      nextSegment: _nextSegmentFor(segment),
    );
    await player.play();
  }

  void _pauseForDictation() {
    _cancelMimicWait();
    _cancelDictationReplay();
    // A pending repeat seek must not resume after opening/checking an answer.
    _dictationPauseGeneration++;
    _repeatRestartQueued = false;
    _repeatRestartQueuedResume = false;
    unawaited(_player?.pause());
  }

  void _toggleDictation() {
    if (_dictationOpen) {
      if (_dictationReplayEndMs != null) unawaited(_player?.pause());
      _cancelDictationReplay();
      _dictationFocus.unfocus();
      setState(() => _dictationOpen = false);
      return;
    }
    if (_currentSentenceId == null) return;
    if (_mimicOpen) _closeMimic();
    _pauseForDictation();
    setState(() {
      _dictationOpen = true;
      _selectDictationTarget(_currentSentenceId);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _dictationOpen &&
          _blindListening &&
          !_fullscreenController.isActive) {
        _dictationFocus.requestFocus();
      }
    });
  }

  Widget _buildDictationPanel(TranscriptDocument document) {
    final index = document.segments.indexWhere(
      (s) => s.id == _dictationTargetId,
    );
    final segment = index < 0 ? null : document.segments[index];
    final attempt = _dictationAttempts[_dictationTargetId];
    final eligible =
        segment != null &&
        supportsEnglishDictation(segment.text, segment.language);
    return DictationPanel(
      controller: _dictationText,
      focusNode: _dictationFocus,
      targetLabel: segment == null
          ? null
          : '${context.strings.t('dictation_sentence')} ${index + 1} · ${formatClock(segment.startMs)}',
      eligible: eligible,
      result: eligible ? attempt?.result : null,
      onChanged: (text) => setState(() {
        attempt?.draft = text;
        attempt?.result = null;
      }),
      onCheck:
          !eligible || attempt == null || _dictationText.text.trim().isEmpty
          ? null
          : () {
              _pauseForDictation();
              setState(
                () => attempt.result = compareDictation(
                  segment.text,
                  attempt.draft,
                ),
              );
            },
      onReplay: segment == null || !_canRepeat(segment)
          ? null
          : () => unawaited(_replayDictationOnce(segment)),
      onClose: _toggleDictation,
    );
  }

  TranscriptSegment? get _mimicTargetSegment {
    final targetId = _mimicTargetId;
    if (targetId == null) return null;
    return _document?.segments
        .where((segment) => segment.id == targetId)
        .firstOrNull;
  }

  void _toggleMimic() {
    if (_mimicOpen) {
      _closeMimic();
      return;
    }
    final target = _document?.segments
        .where((segment) => segment.id == _currentSentenceId)
        .firstOrNull;
    if (target == null || !_canRepeat(target)) return;
    _pauseForDictation();
    _dictationFocus.unfocus();
    setState(() {
      _dictationOpen = false;
      _mimicOpen = true;
      _mimicTargetId = target.id;
      _manualRepeatingSegmentId = target.id;
      _revealedSegmentId = null;
    });
    _queueRepeatRestart(resumeAfterSeek: true);
  }

  void _closeMimic() {
    _stopMimicLoop();
    setState(() {
      _mimicOpen = false;
      _mimicTargetId = null;
    });
  }

  bool _mimicGoalReached(String? segmentId) =>
      _mimicOpen &&
      segmentId != null &&
      segmentId == _mimicTargetId &&
      (_mimicReps[segmentId] ?? 0) >= _appController.settings.mimicRepGoal;

  void _cancelMimicWait() {
    _mimicWaitGeneration++;
    _mimicRepeatTimer?.cancel();
    _mimicRepeatTimer = null;
    _mimicWaiting = false;
  }

  Future<void> _waitBeforeMimicRepeat(String segmentId) async {
    final player = _player;
    final segment = _mimicTargetSegment;
    if (player == null || segment == null || segment.id != segmentId) return;
    final sentenceMs =
        sentenceRepeatEndMs(segment, nextSegment: _nextSegmentFor(segment)) -
        segment.startMs;
    final pauseSeconds = _appController.settings.mimicPauseSeconds;
    final pause = pauseSeconds > 0
        ? Duration(seconds: pauseSeconds)
        : Duration(
            milliseconds: max(1500, (sentenceMs / _playbackRate).ceil() + 500),
          );
    _cancelMimicWait();
    final generation = _mimicWaitGeneration;
    bool current() =>
        mounted &&
        generation == _mimicWaitGeneration &&
        identical(player, _player) &&
        _mimicOpen &&
        _mimicTargetId == segmentId &&
        _repeatingSegmentId == segmentId;
    setState(() => _mimicWaiting = true);
    await player.pause();
    if (!current()) return;
    _mimicRepeatTimer = Timer(pause, () {
      if (!current()) return;
      setState(_cancelMimicWait);
      if (_mimicGoalReached(segmentId)) {
        _finishMimicTarget();
      } else {
        _queueRepeatRestart(resumeAfterSeek: true);
      }
    });
  }

  Future<void> _setMimicPauseSeconds(int seconds) {
    final save = _appController.updateSettings(
      _appController.settings.copyWith(mimicPauseSeconds: seconds),
    );
    final targetId = _mimicTargetId;
    if (_mimicWaiting && targetId != null) {
      unawaited(_waitBeforeMimicRepeat(targetId));
    }
    return save;
  }

  void _finishMimicTarget() {
    if (!_moveMimicTarget(1, resetReps: true)) _stopMimicLoop();
  }

  void _stopMimicLoop() {
    _pauseForDictation();
    setState(() {
      if (_manualRepeatingSegmentId == _mimicTargetId) {
        _manualRepeatingSegmentId = null;
      }
      if (_heldRepeatingSegmentId == _mimicTargetId) {
        _heldRepeatingSegmentId = null;
      }
    });
    unawaited(_setNativeSentenceRepeat(_repeatingSegment));
  }

  Future<void> _setMimicRepGoal(int goal) {
    final save = _appController.updateSettings(
      _appController.settings.copyWith(mimicRepGoal: goal),
    );
    setState(() => _mimicReps.updateAll((_, reps) => min(reps, goal)));
    if (_mimicGoalReached(_mimicTargetId)) {
      if (_playing) {
        _finishMimicTarget();
      } else if (!_mimicWaiting) {
        _stopMimicLoop();
      }
    }
    return save;
  }

  void _toggleMimicLoop() {
    final segment = _mimicTargetSegment;
    if (segment == null) return;
    if (_manualRepeatingSegmentId == segment.id &&
        (_playbackActive || _repeatRestartPending)) {
      _stopMimicLoop();
      return;
    }
    if (!_canRepeat(segment) || _mimicGoalReached(segment.id)) return;
    setState(() => _manualRepeatingSegmentId = segment.id);
    _queueRepeatRestart(resumeAfterSeek: true);
  }

  bool _moveMimicTarget(int delta, {bool resetReps = false}) {
    final segments = _document?.segments ?? const <TranscriptSegment>[];
    final index = segments.indexWhere(
      (segment) => segment.id == _mimicTargetId,
    );
    final nextIndex = index + delta;
    if (index < 0 || nextIndex < 0 || nextIndex >= segments.length) {
      return false;
    }
    return _selectMimicTarget(segments[nextIndex], resetReps: resetReps);
  }

  bool _selectMimicTarget(TranscriptSegment segment, {bool resetReps = false}) {
    if (!_canRepeat(segment)) return false;
    _pauseForDictation();
    setState(() {
      _mimicTargetId = segment.id;
      if (resetReps) _mimicReps.remove(segment.id);
      _revealedSegmentId = null;
      _heldRepeatingSegmentId = null;
      _manualRepeatingSegmentId = segment.id;
    });
    _queueRepeatRestart(resumeAfterSeek: true);
    return true;
  }

  void _toggleMimicReveal() {
    final targetId = _mimicTargetId;
    if (targetId == null) return;
    setState(
      () =>
          _revealedSegmentId = _revealedSegmentId == targetId ? null : targetId,
    );
  }

  Widget _buildMimicPanel(TranscriptDocument document) {
    final index = document.segments.indexWhere(
      (segment) => segment.id == _mimicTargetId,
    );
    final segment = index < 0 ? null : document.segments[index];
    final looping =
        segment != null &&
        _playbackActive &&
        _manualRepeatingSegmentId == segment.id;
    return _MimicPanel(
      targetLabel: segment == null
          ? null
          : '${context.strings.t('dictation_sentence')} ${index + 1} · ${formatClock(segment.startMs)}',
      text: segment?.text,
      translation: segment?.translatedText,
      blindListening: _blindListening,
      revealed: segment != null && _revealedSegmentId == segment.id,
      onReveal: !_blindListening || segment == null ? null : _toggleMimicReveal,
      looping: looping,
      onToggleLoop:
          segment == null || (_mimicGoalReached(segment.id) && !_mimicWaiting)
          ? null
          : _toggleMimicLoop,
      reps: segment == null ? 0 : _mimicReps[segment.id] ?? 0,
      repGoal: _appController.settings.mimicRepGoal,
      onRepGoalChanged: _setMimicRepGoal,
      pauseSeconds: _appController.settings.mimicPauseSeconds,
      onPauseSecondsChanged: _setMimicPauseSeconds,
      onResetReps: segment == null || (_mimicReps[segment.id] ?? 0) == 0
          ? null
          : () => setState(() => _mimicReps.remove(segment.id)),
      playbackRate: _playbackRate,
      onPlaybackRateChanged: _setPlaybackRate,
      onPrevious: index > 0 ? () => _moveMimicTarget(-1) : null,
      onNext: index >= 0 && index + 1 < document.segments.length
          ? () => _moveMimicTarget(1)
          : null,
      onClose: _toggleMimic,
    );
  }

  bool get _blindListening => _appController.settings.blindListeningEnabled;

  String? get _currentSentenceId {
    final segments = _document?.segments ?? const <TranscriptSegment>[];
    if (segments.isEmpty) return null;
    // Practice controls remain usable before, between, and after timed cues.
    final index =
        currentTranscriptSegmentIndex(segments, _position.inMilliseconds) ?? 0;
    return segments[index].id;
  }

  bool get _sentenceRevealed =>
      _currentSentenceId != null && _revealedSegmentId == _currentSentenceId;

  void _toggleReveal() {
    if (!_blindListening || _currentSentenceId == null) return;
    setState(
      () => _revealedSegmentId = _sentenceRevealed ? null : _currentSentenceId,
    );
    _queueFocusCurrent(force: true);
  }

  void _toggleBlindListening() {
    if (_editingSegmentId != null || _editingTranslationSegmentId != null) {
      return;
    }
    if (_dictationReplayEndMs != null) unawaited(_player?.pause());
    _cancelDictationReplay();
    _dictationFocus.unfocus();
    final enabled = !_blindListening;
    setState(() {
      _revealedSegmentId = null;
      if (enabled) {
        _search.clear();
        _searchVisible = false;
        _showAiBrief = false;
        _structureMode = false;
      }
    });
    unawaited(TranscriptStructureCursors.deactivateAll());
    unawaited(
      _appController.updateSettings(
        _appController.settings.copyWith(blindListeningEnabled: enabled),
      ),
    );
    _playbackTick.tick();
  }

  int? _sentenceTarget(bool forward) => _player == null
      ? null
      : sentenceNavigationTarget(
          _document?.segments ?? const [],
          _position.inMilliseconds,
          forward: forward,
        );

  Future<void> _navigateSentence(bool forward) async {
    if (_mimicOpen && _mimicTargetId != null) {
      // Keep the mimic panel, loop, and rep count on the same sentence.
      _moveMimicTarget(forward ? 1 : -1);
      return;
    }
    final target = _sentenceTarget(forward);
    final player = _player;
    if (target == null || player == null) return;
    final position = Duration(
      milliseconds: _document!.segments[target].startMs,
    );
    final request = ++_sentenceNavigationRequest;
    setState(() {
      _sentenceNavigationPending = true;
      _manualRepeatingSegmentId = null;
      _heldRepeatingSegmentId = null;
      _repeatRestartQueued = false;
      _repeatRestartQueuedResume = false;
      _revealedSegmentId = null;
      _position = position;
    });
    try {
      await _setNativeSentenceRepeat(null);
      if (!mounted ||
          request != _sentenceNavigationRequest ||
          !identical(player, _player)) {
        return;
      }
      await _seek(position, reason: TranscriptSeekReason.sentenceClick);
    } finally {
      if (mounted && request == _sentenceNavigationRequest) {
        setState(() => _sentenceNavigationPending = false);
      }
    }
  }

  Widget _sentenceNavigationControls() => SentenceNavigationControls(
    onPrevious: _sentenceTarget(false) == null
        ? null
        : () => unawaited(_navigateSentence(false)),
    onNext: _sentenceTarget(true) == null
        ? null
        : () => unawaited(_navigateSentence(true)),
  );

  bool _handleListeningShortcut(KeyEvent event) {
    if (primaryFocusIsEditable() || event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyS &&
        !shortcutModifierPressed() &&
        _blindListening) {
      _toggleReveal();
      return true;
    }
    if (keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      unawaited(
        _navigateSentence(event.logicalKey == LogicalKeyboardKey.arrowRight),
      );
      return true;
    }
    return false;
  }

  bool _handleReviewShortcut(KeyEvent event) {
    if (_fullscreenController.isActive) return false;
    if (_appController.destination == AppDestination.workspace &&
        ModalRoute.of(context)?.isCurrent != false &&
        _handleListeningShortcut(event)) {
      return true;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _structureMode) {
      _toggleStructureMode();
      return true;
    }
    if (!_blindListening &&
        event is KeyDownEvent &&
        !primaryFocusIsEditable() &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      final redo =
          (event.logicalKey == LogicalKeyboardKey.keyZ &&
              HardwareKeyboard.instance.isShiftPressed) ||
          (event.logicalKey == LogicalKeyboardKey.keyY &&
              HardwareKeyboard.instance.isControlPressed);
      if (redo && _appController.canRedoTranscriptStructureEdit(widget.jobId)) {
        unawaited(_redoStructureEdit());
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyZ &&
          _appController.canUndoTranscriptStructureEdit(widget.jobId)) {
        unawaited(_undoStructureEdit());
        return true;
      }
    }
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
      unawaited(_togglePlayback());
      return true;
    }
    return event is KeyRepeatEvent || event is KeyUpEvent;
  }

  bool _beginHoldingCurrentSentence() {
    if (_mimicWaiting) return true;
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
    if (_mimicGoalReached(segment.id)) return true;
    _cancelDictationReplay();
    setState(() => _heldRepeatingSegmentId = segment.id);
    unawaited(_setNativeSentenceRepeat(segment));
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
    } else if (restoredSegmentId == null) {
      unawaited(_setNativeSentenceRepeat(null));
    }
    if (notify && player != null) {
      unawaited(_ensurePlaybackContinues(player));
    }
  }

  Future<void> _ensurePlaybackContinues(Player player) async {
    final pauseGeneration = _dictationPauseGeneration;
    final navigationRequest = _sentenceNavigationRequest;
    try {
      await _seekDispatcher?.idle;
    } on Object {
      return;
    }
    if (!mounted ||
        _mimicWaiting ||
        navigationRequest != _sentenceNavigationRequest ||
        pauseGeneration != _dictationPauseGeneration ||
        !identical(_player, player) ||
        player.state.playing) {
      return;
    }
    try {
      await player.play();
    } on Object {
      // Media teardown can race a lost key-up during navigation or shutdown.
    }
  }

  Future<void> _togglePlayback() async {
    if (_mimicOpen) {
      _toggleMimicLoop();
      return;
    }
    await _player?.playOrPause();
  }

  void _queueRepeatRestart({bool resumeAfterSeek = false}) {
    if (_mimicWaiting) return;
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
    if (player == null || segment == null || !_canRepeat(segment)) {
      return;
    }
    final segmentId = segment.id;
    final start = Duration(
      milliseconds: sentenceRepeatStartMs(
        segment,
        previousSegment: _previousSegmentFor(segment),
      ),
    );
    if (_mimicGoalReached(segmentId)) {
      _stopMimicLoop();
      await _seek(start, reason: TranscriptSeekReason.repeatRestart);
      return;
    }
    final pauseGeneration = _dictationPauseGeneration;
    final shouldResume = resumeAfterSeek || player.state.playing;
    _repeatRestartPending = true;
    try {
      final nativeLoopActive = await _setNativeSentenceRepeat(segment);
      if (!mounted ||
          !identical(_player, player) ||
          _repeatingSegmentId != segmentId) {
        return;
      }
      if (!nativeLoopActive && player.state.playing) await player.pause();
      if (!mounted ||
          !identical(_player, player) ||
          _repeatingSegmentId != segmentId) {
        return;
      }
      await _seek(start, reason: TranscriptSeekReason.repeatRestart);
      if (!mounted || _repeatingSegmentId != segmentId) return;
    } finally {
      if (shouldResume &&
          pauseGeneration == _dictationPauseGeneration &&
          _repeatingSegmentId == segmentId &&
          mounted &&
          identical(_player, player) &&
          !player.state.playing) {
        try {
          await player.play();
        } on Object {
          // Media teardown can race a repeat restart.
        }
      }
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

  bool _structureEditingAvailable(
    TranscriptionJob job,
    TranscriptDocument document,
  ) {
    if (_blindListening ||
        job.status.isActive ||
        job.translationState.status.isActive ||
        job.aiGenerationState.status.isActive ||
        _editingSegmentId != null ||
        _editingTranslationSegmentId != null) {
      return false;
    }
    if (!identical(_structureAvailabilityDocument, document)) {
      _structureAvailabilityDocument = document;
      _cachedStructureEditingAvailable = _structureEditor.hasAvailableEdit(
        document,
      );
    }
    return _cachedStructureEditingAvailable;
  }

  bool _structureMergeAllowed(TranscriptDocument document, int leftIndex) =>
      _structureEditor.canMergeWithNext(document, leftIndex);

  void _toggleStructureMode() {
    setState(() {
      _structureMode = !_structureMode;
      if (_structureMode) {
        _viewMode = TranslationViewMode.original;
        _search.clear();
        _searchVisible = false;
        _followPlayback = false;
      }
    });
    if (!_structureMode) {
      unawaited(TranscriptStructureCursors.deactivateAll());
    }
  }

  Future<void> _applyStructureEdit(TranscriptStructureEdit edit) async {
    final outcome = await context
        .read<AppController>()
        .applyTranscriptStructureEdit(widget.jobId, edit);
    if (!mounted || outcome is! TranscriptStructureEditResult) return;
    final currentIds = outcome.document.segments
        .map((segment) => segment.id)
        .toSet();
    if (_manualRepeatingSegmentId != null &&
        !currentIds.contains(_manualRepeatingSegmentId)) {
      _manualRepeatingSegmentId = null;
    }
    if (_heldRepeatingSegmentId != null &&
        !currentIds.contains(_heldRepeatingSegmentId)) {
      _heldRepeatingSegmentId = null;
    }
    _mimicReps.removeWhere((id, _) => !currentIds.contains(id));
    if (_mimicTargetId != null && !currentIds.contains(_mimicTargetId)) {
      _mimicOpen = false;
      _mimicTargetId = null;
    }
    await _setNativeSentenceRepeat(_repeatingSegment);
    await _player?.pause();
    final position = Duration(milliseconds: outcome.focusMs);
    if (_seekDispatcher == null) {
      setState(() => _position = position);
      _appController.rememberPlaybackPosition(widget.jobId, position);
    } else {
      await _seek(position, reason: TranscriptSeekReason.sentenceClick);
    }
    if (!mounted) return;
    final operationKey = edit is SplitAtTokenBoundary
        ? 'transcript_split_complete'
        : 'transcript_merge_complete';
    _showStructureNotice(operationKey);
  }

  Future<void> _undoStructureEdit() async {
    _dismissStructureNotice();
    await context.read<AppController>().undoTranscriptStructureEdit(
      widget.jobId,
    );
  }

  Future<void> _redoStructureEdit() async {
    _dismissStructureNotice();
    await context.read<AppController>().redoTranscriptStructureEdit(
      widget.jobId,
    );
  }

  void _showStructureNotice(String messageKey) {
    _structureNoticeTimer?.cancel();
    final generation = ++_structureNoticeGeneration;
    setState(() => _structureNoticeMessageKey = messageKey);
    _structureNoticeTimer = Timer(_structureNoticeDuration, () {
      if (!mounted || generation != _structureNoticeGeneration) return;
      setState(() => _structureNoticeMessageKey = null);
      _structureNoticeTimer = null;
    });
  }

  void _dismissStructureNotice() {
    _resetStructureNotice();
    if (mounted) setState(() {});
  }

  void _resetStructureNotice() {
    _structureNoticeGeneration++;
    _structureNoticeTimer?.cancel();
    _structureNoticeTimer = null;
    _structureNoticeMessageKey = null;
  }

  void _startEditing(String segmentId) {
    if (_blindListening) return;
    if (_structureMode) {
      unawaited(TranscriptStructureCursors.deactivateAll());
    }
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
      showAppNotice(
        context,
        message: context.strings.t('error_unexpected'),
        tone: AppNoticeTone.error,
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
      showAppNotice(
        context,
        message: context.strings.t('error_unexpected'),
        tone: AppNoticeTone.error,
      );
    }
  }

  void _startTranslationEditing(String segmentId) {
    if (_blindListening) return;
    if (_structureMode) {
      unawaited(TranscriptStructureCursors.deactivateAll());
    }
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
      showAppNotice(
        context,
        message: context.strings.t('error_unexpected'),
        tone: AppNoticeTone.error,
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
