import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';
import '../data/podcast/publisher_transcript.dart';

export '../core/podcast_models.dart' show PodcastListenProgress;

class PodcastPlayerCue {
  const PodcastPlayerCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.tokens = const [],
  });

  final int startMs;
  final int endMs;
  final String text;
  final List<TranscriptToken> tokens;
}

/// Converts discrete media_kit `time-pos` samples into a caption clock.
///
/// mpv reports position on a property timer and slightly behind the DAC, so
/// word highlight must interpolate between samples and lead the report.
@immutable
class PodcastPlaybackClock {
  const PodcastPlaybackClock({
    this.reportedMs = 0,
    this.playing = false,
    this.rate = 1,
    this.durationMs = 0,
    this.sampledAt,
  });

  static const highlightLeadMs = 80;
  static const maxExtrapolateMs = 400;

  final int reportedMs;
  final bool playing;
  final double rate;
  final int durationMs;
  final DateTime? sampledAt;

  int at([DateTime? now]) {
    var ms = reportedMs;
    if (playing) {
      final sampledAt = this.sampledAt;
      if (sampledAt != null) {
        final elapsed = (now ?? DateTime.now())
            .difference(sampledAt)
            .inMilliseconds;
        if (elapsed > 0) {
          ms += (elapsed.clamp(0, maxExtrapolateMs) * rate).round();
        }
      }
      ms += highlightLeadMs;
    }
    if (ms < 0) return 0;
    if (durationMs > 0 && ms > durationMs) return durationMs;
    return ms;
  }
}

class PodcastPlayer extends ChangeNotifier {
  PodcastPlayer({
    PodcastGateway? gateway,
    PublisherTranscriptParser parser = const PublisherTranscriptParser(),
    PodcastRepository? repository,
  }) : _gateway = gateway,
       _parser = parser,
       _repository = repository;

  static const rates = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  final PodcastGateway? _gateway;
  final PublisherTranscriptParser _parser;
  final PodcastRepository? _repository;
  Player? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  PodcastEpisode? _episode;
  PodcastFeed? _feed;
  TranscriptDocument? _document;
  List<PodcastPlayerCue> _cues = const [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _expanded = false;
  double _rate = 1;
  bool _loadingCues = false;
  final Map<String, PodcastListenProgress> _progress = {};
  Timer? _persistTimer;
  Future<void>? _shutdownFuture;
  Duration? _resumeAt;
  PodcastPlaybackClock _clock = const PodcastPlaybackClock();
  String _mediaSource = '';

  PodcastEpisode? get episode => _episode;
  PodcastFeed? get feed => _feed;
  TranscriptDocument? get document => _document;
  List<PodcastPlayerCue> get cues => _cues;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get expanded => _expanded;
  double get rate => _rate;
  bool get loadingCues => _loadingCues;
  bool get hasSession => _episode != null;

  String? get artworkUrl => _episode?.artworkUrl ?? _feed?.artworkUrl;

  Future<void> initialize() async {
    final repository = _repository;
    if (repository == null) return;
    final loaded = await repository.loadPlaybackProgress();
    if (loaded.isEmpty) return;
    _progress
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  PodcastListenProgress? progressFor(
    String episodeId, {
    int? fallbackDurationMs,
  }) {
    if (_episode?.id == episodeId) {
      final live = _liveProgress(fallbackDurationMs: fallbackDurationMs);
      if (live.isContinue) return live;
    }
    final saved = _progress[episodeId];
    if (saved == null) return null;
    final resolved = saved.withFallbackDuration(fallbackDurationMs);
    return resolved.isContinue ? resolved : null;
  }

  int storedPositionMs(String episodeId) {
    if (_episode?.id == episodeId) return displayPositionMs;
    return _progress[episodeId]?.positionMs ?? 0;
  }

  PodcastPlayerCue? get currentCue {
    final index = currentCueIndex;
    if (index < 0) return null;
    return _cues[index];
  }

  int get currentCueIndex => cueIndexAt(_cues, _position.inMilliseconds);

  int get displayPositionMs => _clock.at();

  static int cueIndexAt(List<PodcastPlayerCue> cues, int positionMs) {
    var index = -1;
    for (var i = 0; i < cues.length; i++) {
      if (cues[i].startMs > positionMs) break;
      index = i;
    }
    return index;
  }

  Future<void> play(
    PodcastEpisode episode,
    PodcastFeed feed, {
    TranscriptDocument? document,
    String? localPath,
  }) async {
    final source = podcastPlaybackSource(
      enclosureUrl: episode.enclosureUrl,
      localPath: localPath,
    );
    if (_episode?.id == episode.id && _mediaSource == source) {
      if (document != null) applyDocument(document);
      await toggle();
      return;
    }
    final keepPosition = _episode?.id == episode.id ? _position : null;
    _rememberProgress();
    await _resetPlayer();
    _episode = episode;
    _feed = feed;
    _document = document;
    _cues = cuesFrom(document);
    _loadingCues = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _rate = 1;
    _mediaSource = source;
    var resume = keepPosition;
    if (resume == null) {
      final saved = progressFor(
        episode.id,
        fallbackDurationMs: episode.durationMs,
      );
      if (saved != null) {
        resume = Duration(milliseconds: saved.positionMs);
      }
    }
    _resumeAt = resume;
    if (_resumeAt != null) _position = _resumeAt!;
    _syncClock();
    notifyListeners();
    final player = Player();
    _player = player;
    _subscriptions.addAll([
      player.stream.playing.listen((value) {
        _playing = value;
        _syncClock();
        notifyListeners();
      }),
      player.stream.position.listen((value) {
        final resumeAt = _resumeAt;
        if (resumeAt != null) {
          final delta = (value.inMilliseconds - resumeAt.inMilliseconds).abs();
          if (delta > 1500 && value.inMilliseconds < 500) return;
          if (delta <= 1500) _resumeAt = null;
        }
        _position = value;
        _syncClock();
        _rememberProgress();
        notifyListeners();
      }),
      player.stream.duration.listen((value) {
        _duration = value;
        _syncClock();
        unawaited(_applyResume());
        notifyListeners();
      }),
    ]);
    await player.open(Media(source));
    await player.setRate(_rate);
    await _applyResume();
    await player.play();
    unawaited(_loadCues(episode, document));
  }

  Future<void> pause() async {
    final player = _player;
    if (player == null || !_playing) return;
    await player.pause();
  }

  Future<void> toggle() async {
    final player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    final clamped = position < Duration.zero
        ? Duration.zero
        : _duration > Duration.zero && position > _duration
        ? _duration
        : position;
    _position = clamped;
    _syncClock();
    _rememberProgress();
    notifyListeners();
    await player.seek(clamped);
  }

  Future<void> skip(Duration delta) => seek(_position + delta);

  Future<void> seekToCue(PodcastPlayerCue cue) =>
      seek(Duration(milliseconds: cue.startMs));

  Future<void> setRate(double rate) async {
    _rate = rate;
    _syncClock();
    notifyListeners();
    await _player?.setRate(rate);
  }

  void applyDocument(TranscriptDocument document) {
    if (_document != null &&
        _cues.isNotEmpty &&
        _document!.updatedAt == document.updatedAt &&
        _document!.segments.length == document.segments.length) {
      return;
    }
    _document = document;
    _cues = cuesFrom(document);
    _loadingCues = false;
    notifyListeners();
  }

  void _syncClock() {
    _clock = PodcastPlaybackClock(
      reportedMs: _position.inMilliseconds,
      playing: _playing,
      rate: _rate,
      durationMs: _duration.inMilliseconds,
      sampledAt: DateTime.now(),
    );
  }

  void expand() {
    if (!_expanded) {
      _expanded = true;
      notifyListeners();
    }
  }

  void collapse() {
    if (_expanded) {
      _expanded = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _rememberProgress();
    await _persistNow();
    await _resetPlayer();
    _episode = null;
    _feed = null;
    _document = null;
    _cues = const [];
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _expanded = false;
    _rate = 1;
    _loadingCues = false;
    _mediaSource = '';
    _syncClock();
    notifyListeners();
  }

  Future<void> _loadCues(
    PodcastEpisode episode,
    TranscriptDocument? document,
  ) async {
    if (document != null || episode.transcripts.isEmpty) return;
    final gateway = _gateway;
    if (gateway == null) return;
    _loadingCues = true;
    notifyListeners();
    try {
      for (final reference in episode.transcripts) {
        try {
          final body = await gateway.fetchTranscript(reference);
          final parsed = _parser.parse(
            body: body,
            mimeType: reference.type,
            url: reference.url,
          );
          if (_episode?.id != episode.id) return;
          _cues = cuesFrom(parsed.document);
          _document ??= parsed.document;
          break;
        } on Object {
          continue;
        }
      }
    } finally {
      if (_episode?.id == episode.id) {
        _loadingCues = false;
        notifyListeners();
      }
    }
  }

  static List<PodcastPlayerCue> cuesFrom(TranscriptDocument? document) {
    if (document == null) return const [];
    final segments = [
      for (final segment in document.segments)
        if (segment.text.trim().isNotEmpty) segment,
    ];
    return [
      for (var index = 0; index < segments.length; index++)
        PodcastPlayerCue(
          startMs: segments[index].startMs,
          endMs: segments[index].endMs,
          text: segments[index].text.trim(),
          tokens: [
            for (final token in document.tokens)
              if (_tokenBelongsToSegment(
                token,
                segments[index],
                index + 1 < segments.length
                    ? segments[index + 1].startMs
                    : null,
              ))
                token,
          ],
        ),
    ];
  }

  static bool _tokenBelongsToSegment(
    TranscriptToken token,
    TranscriptSegment segment,
    int? nextStartMs,
  ) {
    if (token.startMs == 0 && token.endMs == 0 && token.text.trim().isEmpty) {
      return false;
    }
    if (token.startMs < segment.startMs) return false;
    if (nextStartMs != null) return token.startMs < nextStartMs;
    if (segment.endMs > segment.startMs) return token.startMs <= segment.endMs;
    return true;
  }

  PodcastListenProgress _liveProgress({int? fallbackDurationMs}) {
    final duration = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : fallbackDurationMs ?? _episode?.durationMs ?? 0;
    return PodcastListenProgress(
      positionMs: _position.inMilliseconds,
      durationMs: duration,
    );
  }

  Future<void> _applyResume() async {
    final target = _resumeAt;
    final player = _player;
    if (target == null || player == null) return;
    if (_duration > Duration.zero && target >= _duration) {
      _resumeAt = null;
      return;
    }
    _position = target;
    _syncClock();
    notifyListeners();
    await player.seek(target);
  }

  void _rememberProgress() {
    final episode = _episode;
    if (episode == null) return;
    final current = _liveProgress().withFallbackDuration(episode.durationMs);
    if (current.durationMs > 0 &&
        current.positionMs >=
            current.durationMs - PodcastListenProgress.finishedWithinMs) {
      if (_progress.remove(episode.id) != null) _schedulePersist();
      return;
    }
    if (!current.isContinue) return;
    _progress[episode.id] = PodcastListenProgress(
      positionMs: current.positionMs,
      durationMs: current.durationMs,
      updatedAt: DateTime.now().toUtc(),
    );
    _pruneProgress();
    _schedulePersist();
  }

  void _pruneProgress() {
    if (_progress.length <= PodcastListenProgress.maxEntries) return;
    final ranked = _progress.entries.toList()
      ..sort((a, b) {
        final aAt = a.value.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = b.value.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });
    final extra = _progress.length - PodcastListenProgress.maxEntries;
    for (final entry in ranked.take(extra)) {
      _progress.remove(entry.key);
    }
  }

  void _schedulePersist() {
    if (_repository == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    final repository = _repository;
    if (repository == null) return;
    try {
      await repository.savePlaybackProgress(Map.of(_progress));
    } on Object {
      // Shutdown or a missing directory must not crash playback.
    }
  }

  Future<void> _resetPlayer() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final player = _player;
    _player = null;
    await player?.dispose();
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _rememberProgress();
    await _persistNow();
    await _resetPlayer();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}

String podcastPlaybackSource({
  required String enclosureUrl,
  String? localPath,
}) {
  final path = localPath?.trim() ?? '';
  if (path.isEmpty) return enclosureUrl;
  final file = File(path);
  if (!file.existsSync()) return enclosureUrl;
  return Uri.file(file.absolute.path).toString();
}
