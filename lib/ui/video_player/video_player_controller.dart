import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../data/embedded_subtitles.dart';
import '../../data/local_repositories.dart';
import '../../data/timed_subtitle_import.dart';
import '../transcript_review.dart';

enum PlayerSubtitleKind { embedded, file }

/// One subtitle the viewer can pick: a track inside the video or a subtitle
/// file next to it.
class PlayerSubtitleSource {
  const PlayerSubtitleSource._({
    required this.id,
    required this.kind,
    this.mpvTrackId,
    this.embedded,
    this.path,
    this.language,
    this.title,
    this.codec,
    this.isDefault = false,
    this.pictureBased = false,
  });

  factory PlayerSubtitleSource.embedded({
    required int ordinal,
    String? mpvTrackId,
    EmbeddedSubtitleTrack? parsed,
    String? language,
    String? title,
    String? codec,
    bool isDefault = false,
    bool pictureBased = false,
  }) => PlayerSubtitleSource._(
    id: 'embedded:${parsed?.containerIndex ?? 'mpv-${mpvTrackId ?? ordinal}'}',
    kind: PlayerSubtitleKind.embedded,
    mpvTrackId: mpvTrackId,
    embedded: parsed,
    language: language ?? parsed?.language,
    title: title ?? parsed?.title,
    codec: codec ?? parsed?.codec,
    isDefault: isDefault || (parsed?.isDefault ?? false),
    pictureBased: pictureBased,
  );

  factory PlayerSubtitleSource.file(String path) => PlayerSubtitleSource._(
    id: 'file:${p.normalize(p.absolute(path))}',
    kind: PlayerSubtitleKind.file,
    path: p.normalize(p.absolute(path)),
    title: p.basename(path),
    language: _sidecarLanguage(path),
    codec: p.extension(path).replaceFirst('.', '').toUpperCase(),
  );

  final String id;
  final PlayerSubtitleKind kind;
  final String? mpvTrackId;
  final EmbeddedSubtitleTrack? embedded;
  final String? path;
  final String? language;
  final String? title;
  final String? codec;
  final bool isDefault;

  /// Picture subtitles (PGS, VobSub) cannot be read as text, so they can
  /// neither be shown in the subtitle overlay nor navigated by sentence.
  final bool pictureBased;

  /// Whether the cue list can be read ahead of playback, which sentence
  /// navigation and repeat depend on.
  bool get navigable =>
      kind == PlayerSubtitleKind.file || (embedded?.isText ?? false);

  static String? _sidecarLanguage(String path) {
    final stem = p.basenameWithoutExtension(path);
    final dot = stem.lastIndexOf('.');
    if (dot < 0) return null;
    final suffix = stem.substring(dot + 1);
    return suffix.length >= 2 && suffix.length <= 8 ? suffix : null;
  }
}

/// Plays one video outside the job pipeline, using its subtitles as the
/// sentence list for navigation and repeat.
class VideoPlayerController extends ChangeNotifier {
  VideoPlayerController({
    required this.path,
    Player? player,
    SentenceRepeatLoopController? Function(Player player)? repeatLoopFactory,
    this.embeddedReader = const EmbeddedSubtitleReader(),
    this.subtitleFiles = const TimedSubtitleImportService(),
    this.playbackRepository,
    this.trackWaitTimeout = const Duration(seconds: 5),
    this.preferredLanguage,
  }) : player = player ?? Player() {
    _repeatLoop = (repeatLoopFactory ?? _mpvRepeatLoop)(this.player);
  }

  static const _resumeMarginMs = 5000;
  static const _relativeSeek = Duration(seconds: 5);
  static const _positionSaveInterval = Duration(seconds: 5);
  static const _speedStep = .25;

  final String path;
  final Player player;
  final EmbeddedSubtitleReader embeddedReader;
  final TimedSubtitleImportService subtitleFiles;
  final VideoPlaybackRepository? playbackRepository;
  final Duration trackWaitTimeout;

  /// The UI language, used to choose among several built-in tracks.
  final String? preferredLanguage;

  SentenceRepeatLoopController? _repeatLoop;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _saveTimer;
  bool _disposed = false;
  int _selectionRequest = 0;

  List<PlayerSubtitleSource> _sources = const [];
  PlayerSubtitleSource? _selected;
  List<TranscriptSegment> _cues = const [];
  bool _loadingCues = false;
  String? _cueError;
  String? _openError;
  bool _opened = false;
  String? _heldCueId;

  Duration position = Duration.zero;
  int? _videoWidth;
  int? _videoHeight;
  Duration duration = Duration.zero;
  bool playing = false;
  double rate = 1;

  List<PlayerSubtitleSource> get sources => _sources;
  PlayerSubtitleSource? get selected => _selected;
  List<TranscriptSegment> get cues => _cues;
  bool get loadingCues => _loadingCues;
  String? get cueError => _cueError;
  String? get openError => _openError;
  bool get opened => _opened;
  bool get repeating => _heldCueId != null;
  String get title => p.basename(path);

  /// The decoded picture size, once the player reports it.
  Size? get videoSize {
    final width = _videoWidth;
    final height = _videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width.toDouble(), height.toDouble());
  }

  /// The subtitle on screen now: the cue under the playhead, or what mpv
  /// reports while the cue list is unavailable.
  String? get subtitleText {
    if (_selected == null) return null;
    if (_cues.isNotEmpty) {
      final index = _currentCueIndex(pinned: true);
      if (index == null) return null;
      final cue = _cues[index];
      final within = position.inMilliseconds < cue.endMs;
      return _heldCueId == cue.id || within ? cue.text : null;
    }
    final text = player.state.subtitle.firstOrNull?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  bool get canGoPrevious => _cues.isEmpty
      ? true
      : sentenceNavigationTarget(
              _cues,
              position.inMilliseconds,
              forward: false,
            ) !=
            null;

  bool get canGoNext => _cues.isEmpty
      ? true
      : sentenceNavigationTarget(
              _cues,
              position.inMilliseconds,
              forward: true,
            ) !=
            null;

  Future<void> open() async {
    _listen();
    final saved = await _loadSaved();
    try {
      await player.open(Media(path), play: false);
    } on Object {
      _openError = 'player_open_failed';
      _notify();
      return;
    }
    await _waitForTracks();
    if (_disposed) return;
    _sources = await _discoverSources();
    if (_disposed) return;
    _opened = true;
    _notify();
    await selectSubtitle(_defaultSource(saved?.subtitleId), remember: false);
    final resumeMs = saved?.positionMs ?? 0;
    final durationMs = player.state.duration.inMilliseconds;
    if (_disposed) return;
    if (resumeMs > _resumeMarginMs &&
        (durationMs <= 0 || resumeMs < durationMs - _resumeMarginMs)) {
      await player.seek(Duration(milliseconds: resumeMs));
    }
    if (_disposed) return;
    await player.play();
    _saveTimer = Timer.periodic(_positionSaveInterval, (_) {
      if (playing) unawaited(_savePlayback());
    });
  }

  /// Shows [source] and loads its cues; `null` turns subtitles off.
  Future<void> selectSubtitle(
    PlayerSubtitleSource? source, {
    bool remember = true,
  }) async {
    final request = ++_selectionRequest;
    _endHold(notify: false);
    _selected = source;
    _cues = const [];
    _cueError = null;
    _loadingCues = source?.navigable ?? false;
    _notify();
    if (remember) unawaited(_savePlayback());
    await _showInPlayer(source);
    if (source == null || !source.navigable) return;
    List<TranscriptSegment> cues = const [];
    String? error;
    try {
      cues = await _readCues(source);
      if (cues.isEmpty) error = 'subtitle_no_valid_cues';
    } on TimedSubtitleImportException catch (failure) {
      error = failure.code;
    } on EmbeddedSubtitleException catch (failure) {
      error = failure.code;
    } on Object {
      error = 'subtitle_read_failed';
    }
    if (_disposed || request != _selectionRequest) return;
    _cues = cues;
    _cueError = error;
    _loadingCues = false;
    _notify();
  }

  /// Adds a subtitle file the viewer picked and selects it.
  Future<void> addSubtitleFile(String filePath) async {
    final source = PlayerSubtitleSource.file(filePath);
    if (!_sources.any((item) => item.id == source.id)) {
      _sources = [..._sources, source];
    }
    await selectSubtitle(_sources.firstWhere((item) => item.id == source.id));
  }

  Future<void> togglePlayback() async {
    if (player.state.completed) {
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    await player.playOrPause();
  }

  Future<void> seek(Duration target) async {
    _endHold(notify: false);
    final durationMs = player.state.duration.inMilliseconds;
    final clamped = Duration(
      milliseconds: durationMs > 0
          ? target.inMilliseconds.clamp(0, durationMs)
          : target.inMilliseconds.clamp(0, 1 << 31),
    );
    position = clamped;
    _notify();
    await player.seek(clamped);
  }

  Future<void> previousSubtitle() => _navigate(forward: false);

  Future<void> nextSubtitle() => _navigate(forward: true);

  Future<void> changeSpeed(double delta) => setRate(rate + delta);

  Future<void> slower() => changeSpeed(-_speedStep);

  Future<void> faster() => changeSpeed(_speedStep);

  Future<void> setRate(double value) async {
    final next = (value * 100).round().clamp(25, 300) / 100;
    rate = next;
    _notify();
    await player.setRate(next);
  }

  /// Starts looping the subtitle under the playhead while R is held.
  bool beginRepeatHold() {
    if (_heldCueId != null) return true;
    final index = _currentCueIndex(pinned: false);
    if (index != null) {
      final cue = _cues[index];
      _heldCueId = cue.id;
      _notify();
      unawaited(
        _repeatLoop?.setRange(
          startMs: sentenceRepeatStartMs(
            cue,
            previousSegment: index > 0 ? _cues[index - 1] : null,
          ),
          endMs: sentenceRepeatEndMs(
            cue,
            nextSegment: index + 1 < _cues.length ? _cues[index + 1] : null,
          ),
        ),
      );
      if (!playing) unawaited(player.play());
      return true;
    }
    if (_cues.isEmpty && _selected != null) {
      unawaited(_repeatFromPlayerCue());
      return true;
    }
    return false;
  }

  void endRepeatHold() => _endHold(notify: true);

  Future<void> _navigate({required bool forward}) async {
    if (_cues.isNotEmpty) {
      final target = sentenceNavigationTarget(
        _cues,
        position.inMilliseconds,
        forward: forward,
      );
      if (target == null) return;
      await seek(Duration(milliseconds: _cues[target].startMs));
      return;
    }
    final native = player.platform;
    if (_selected != null && native is NativePlayer) {
      _endHold(notify: false);
      try {
        await native.command(['sub-seek', forward ? '1' : '-1']);
        return;
      } on Object {
        // Fall back to a fixed step below.
      }
    }
    await seek(position + (forward ? _relativeSeek : -_relativeSeek));
  }

  Future<void> _repeatFromPlayerCue() async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      final start = double.tryParse(await native.getProperty('sub-start'));
      final end = double.tryParse(await native.getProperty('sub-end'));
      if (start == null || end == null || end <= start) return;
      _heldCueId = 'player-cue';
      _notify();
      await _repeatLoop?.setRange(
        startMs: (start * 1000).round(),
        endMs: (end * 1000).round(),
      );
      if (!playing) await player.play();
    } on Object {
      // No subtitle is on screen; there is nothing to repeat.
    }
  }

  void _endHold({required bool notify}) {
    if (_heldCueId == null) return;
    _heldCueId = null;
    unawaited(_repeatLoop?.clear());
    if (notify) _notify();
  }

  int? _currentCueIndex({required bool pinned}) =>
      currentTranscriptSegmentIndex(
        _cues,
        position.inMilliseconds,
        pinnedSegmentId: pinned ? _heldCueId : null,
      );

  Future<List<TranscriptSegment>> _readCues(PlayerSubtitleSource source) async {
    if (source.kind == PlayerSubtitleKind.file) {
      final result = await subtitleFiles.parseFile(source.path!);
      return result.document.segments;
    }
    final track = source.embedded!;
    final cues = await embeddedReader.extract(path, track);
    return subtitleFiles
        .documentFromCues(cues, format: track.format!)
        .document
        .segments;
  }

  Future<void> _showInPlayer(PlayerSubtitleSource? source) async {
    try {
      if (source == null) {
        await player.setSubtitleTrack(SubtitleTrack.no());
      } else if (source.kind == PlayerSubtitleKind.file) {
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            Uri.file(source.path!).toString(),
            title: source.title,
            language: source.language,
          ),
        );
      } else if (source.mpvTrackId != null) {
        await player.setSubtitleTrack(
          SubtitleTrack(source.mpvTrackId!, source.title, source.language),
        );
      }
    } on Object {
      // The overlay still shows cues read from the file.
    }
  }

  Future<void> _waitForTracks() async {
    if (_hasMediaTracks(player.state.tracks)) return;
    try {
      await player.stream.tracks
          .firstWhere(_hasMediaTracks)
          .timeout(trackWaitTimeout);
    } on Object {
      // Continue with whatever the container reader finds.
    }
  }

  static bool _hasMediaTracks(Tracks tracks) => [
    ...tracks.video,
    ...tracks.audio,
  ].any((track) => track.id != 'auto' && track.id != 'no');

  Future<List<PlayerSubtitleSource>> _discoverSources() async {
    List<EmbeddedSubtitleTrack> parsed = const [];
    try {
      parsed = await embeddedReader.listTracks(path);
    } on Object {
      // The player can still show tracks it decodes itself.
    }
    final mpvTracks = player.state.tracks.subtitle
        .where(
          (track) =>
              track.id != 'auto' &&
              track.id != 'no' &&
              !track.uri &&
              !track.data,
        )
        .toList(growable: false);
    final ffIndexes = await _mpvSubtitleContainerIndexes();
    final sources = <PlayerSubtitleSource>[];
    final matched = <EmbeddedSubtitleTrack>{};
    for (var ordinal = 0; ordinal < mpvTracks.length; ordinal++) {
      final track = mpvTracks[ordinal];
      final ffIndex = ffIndexes[track.id];
      final match = ffIndex != null
          ? parsed.where((item) => item.containerIndex == ffIndex).firstOrNull
          : (ordinal < parsed.length ? parsed[ordinal] : null);
      if (match != null) matched.add(match);
      sources.add(
        PlayerSubtitleSource.embedded(
          ordinal: ordinal,
          mpvTrackId: track.id,
          parsed: match,
          language: track.language,
          title: track.title,
          codec: track.codec,
          isDefault: track.isDefault ?? false,
          pictureBased:
              (track.image ?? false) || (match != null && !match.isText),
        ),
      );
    }
    // Tracks the player has not reported (or cannot decode) still work for
    // navigation when the container reader can read them.
    for (final track in parsed) {
      if (matched.contains(track) || !track.isText) continue;
      final ordinal = parsed.indexOf(track);
      sources.add(
        PlayerSubtitleSource.embedded(
          ordinal: ordinal,
          mpvTrackId: mpvTracks.isEmpty ? '${ordinal + 1}' : null,
          parsed: track,
        ),
      );
    }
    for (final sidecar in await subtitleFiles.subtitleSidecarsFor(path)) {
      sources.add(PlayerSubtitleSource.file(sidecar));
    }
    return List.unmodifiable(sources);
  }

  /// Maps mpv subtitle track ids to their container stream index, which is
  /// how the container reader numbers tracks.
  Future<Map<String, int>> _mpvSubtitleContainerIndexes() async {
    final native = player.platform;
    if (native is! NativePlayer) return const {};
    try {
      final count = int.tryParse(await native.getProperty('track-list/count'));
      if (count == null) return const {};
      final indexes = <String, int>{};
      for (var index = 0; index < count; index++) {
        final prefix = 'track-list/$index';
        if (await native.getProperty('$prefix/type') != 'sub') continue;
        if (await native.getProperty('$prefix/external') == 'yes') continue;
        final ffIndex = int.tryParse(
          await native.getProperty('$prefix/ff-index'),
        );
        if (ffIndex == null) continue;
        indexes[await native.getProperty('$prefix/id')] = ffIndex;
      }
      return indexes;
    } on Object {
      return const {};
    }
  }

  PlayerSubtitleSource? _defaultSource(String? savedId) {
    if (savedId == 'off') return null;
    final saved = _sources.where((item) => item.id == savedId).firstOrNull;
    if (saved != null) return saved;
    final usable = _sources.where((item) => !item.pictureBased).toList();
    if (usable.isEmpty) return null;
    final files = usable.where((item) => item.kind == PlayerSubtitleKind.file);
    if (files.isNotEmpty) return files.first;
    final defaults = usable.where((item) => item.isDefault);
    if (defaults.isNotEmpty) return defaults.first;
    final language = preferredLanguage?.toLowerCase();
    if (language != null) {
      final matching = usable.where(
        (item) => item.language?.toLowerCase().startsWith(language) ?? false,
      );
      if (matching.isNotEmpty) return matching.first;
    }
    return usable.first;
  }

  Future<VideoPlaybackEntry?> _loadSaved() async {
    try {
      return await playbackRepository?.load(path);
    } on Object {
      return null;
    }
  }

  Future<void> _savePlayback() async {
    final repository = playbackRepository;
    if (repository == null || !_opened) return;
    try {
      await repository.save(
        path,
        VideoPlaybackEntry(
          positionMs: position.inMilliseconds,
          subtitleId: _selected?.id ?? 'off',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } on Object {
      // Losing a resume position is not worth interrupting playback.
    }
  }

  void _listen() {
    final stream = player.stream;
    _subscriptions.addAll([
      stream.position.listen((value) {
        position = value;
        _notify();
      }),
      stream.duration.listen((value) {
        duration = value;
        _notify();
      }),
      stream.playing.listen((value) {
        playing = value;
        if (!value) unawaited(_savePlayback());
        _notify();
      }),
      stream.rate.listen((value) {
        rate = value;
        _notify();
      }),
      stream.width.listen((value) {
        _videoWidth = value;
        _notify();
      }),
      stream.height.listen((value) {
        _videoHeight = value;
        _notify();
      }),
      stream.subtitle.listen((_) {
        if (_cues.isEmpty) _notify();
      }),
    ]);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void>? _closing;

  /// Saves the resume point and releases the player.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _saveTimer?.cancel();
    _disposed = true;
    await _savePlayback();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

SentenceRepeatLoopController? _mpvRepeatLoop(Player player) {
  final platform = player.platform;
  if (platform is! NativePlayer) return null;
  return MpvSentenceRepeatLoopController(platform.setProperty);
}
