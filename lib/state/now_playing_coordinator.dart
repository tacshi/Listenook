import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/now_playing.dart';
import 'podcast_player.dart';

/// Something that plays media: the podcast player or the transcript review.
abstract interface class NowPlayingSource implements Listenable {
  /// Null when there is nothing to show.
  NowPlayingItem? get nowPlaying;

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);
}

/// Shows the most recently started player on the lock screen and sends it
/// the system's media commands. Only one plays at a time: starting one pauses
/// the others elsewhere in the app, so the newest claim wins.
class NowPlayingCoordinator {
  NowPlayingCoordinator(this._bridge) {
    _subscription = _bridge.commands.listen(_handle);
  }

  final NowPlayingBridge _bridge;
  late final StreamSubscription<NowPlayingCommand> _subscription;
  NowPlayingSource? _source;
  NowPlayingItem? _shown;
  final _sinceShown = Stopwatch();
  bool _pushScheduled = false;

  NowPlayingSource? get source => _source;

  /// Makes [source] the one the system controls, if it is playing.
  void claim(NowPlayingSource source) {
    if (identical(_source, source)) return;
    _source?.removeListener(_changed);
    _source = source;
    source.addListener(_changed);
    _push();
  }

  /// Stops showing [source], if it is the current one.
  void release(NowPlayingSource source) {
    if (!identical(_source, source)) return;
    source.removeListener(_changed);
    _source = null;
    _shown = null;
    unawaited(_bridge.clear());
  }

  void _changed() {
    // Position reports arrive many times a second; one update per frame of
    // work is plenty, and the system extrapolates between them.
    if (_pushScheduled) return;
    _pushScheduled = true;
    scheduleMicrotask(() {
      _pushScheduled = false;
      _push();
    });
  }

  void _push() {
    final item = _source?.nowPlaying;
    if (item == null) {
      if (_shown != null) unawaited(_bridge.clear());
      _shown = null;
      return;
    }
    if (_shown != null && !_meaningfullyChanged(_shown!, item)) return;
    _shown = item;
    _sinceShown
      ..reset()
      ..start();
    unawaited(_bridge.update(item));
  }

  /// Steady playback only moves the position, which the system advances on
  /// its own; resend when anything else changes or the position jumps.
  bool _meaningfullyChanged(NowPlayingItem shown, NowPlayingItem next) {
    if (shown.title != next.title ||
        shown.artist != next.artist ||
        shown.album != next.album ||
        shown.artworkUrl != next.artworkUrl ||
        shown.duration != next.duration ||
        shown.playing != next.playing ||
        shown.rate != next.rate) {
      return true;
    }
    final expected = shown.playing
        ? shown.position + _sinceShown.elapsed * shown.rate
        : shown.position;
    return (next.position - expected).abs() >
        const Duration(milliseconds: 1500);
  }

  Future<void> _handle(NowPlayingCommand command) async {
    final source = _source;
    final item = source?.nowPlaying;
    if (source == null || item == null) return;
    switch (command) {
      case NowPlayingPlay():
        await source.play();
      case NowPlayingPause():
        await source.pause();
      case NowPlayingToggle():
        await (item.playing ? source.pause() : source.play());
      case NowPlayingSkip(:final offset):
        await source.seekTo(item.position + offset);
      case NowPlayingSeek(:final position):
        await source.seekTo(position);
    }
  }

  void dispose() {
    _source?.removeListener(_changed);
    unawaited(_subscription.cancel());
  }
}

/// The podcast player as seen by the lock screen.
class PodcastNowPlayingSource extends ChangeNotifier
    implements NowPlayingSource {
  PodcastNowPlayingSource(this._player, this._coordinator) {
    _player.addListener(_changed);
  }

  final PodcastPlayer _player;
  final NowPlayingCoordinator _coordinator;
  bool _wasPlaying = false;

  void _changed() {
    // Starting playback takes over the lock screen from the review player.
    if (_player.playing && !_wasPlaying) _coordinator.claim(this);
    _wasPlaying = _player.playing;
    notifyListeners();
  }

  @override
  NowPlayingItem? get nowPlaying {
    final episode = _player.episode;
    if (episode == null) return null;
    return NowPlayingItem(
      title: episode.title,
      artist: _player.feed?.author ?? _player.feed?.title,
      album: _player.feed?.title,
      artworkUrl: _player.artworkUrl,
      duration: _player.duration,
      position: _player.position,
      playing: _player.playing,
      rate: _player.rate,
    );
  }

  @override
  Future<void> play() async {
    if (!_player.playing) await _player.toggle();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seekTo(Duration position) => _player.seek(position);

  @override
  void dispose() {
    _player.removeListener(_changed);
    _coordinator.release(this);
    super.dispose();
  }
}
