import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/ui/transcript_review.dart';
import 'package:media_kit/media_kit.dart';

class MemoryPlaybackRepository implements VideoPlaybackRepository {
  final Map<String, VideoPlaybackEntry> entries = {};

  @override
  Future<VideoPlaybackEntry?> load(String mediaPath) async =>
      entries[mediaPath];

  @override
  Future<void> save(String mediaPath, VideoPlaybackEntry entry) async {
    entries[mediaPath] = entry;
  }
}

class RecordingRepeatLoop implements SentenceRepeatLoopController {
  final List<String> events = [];

  @override
  Future<void> clear() async => events.add('clear');

  @override
  Future<void> setRange({required int startMs, required int endMs}) async {
    events.add('range:$startMs:$endMs');
  }
}

class FakePlayerPlatform extends PlatformPlayer {
  FakePlayerPlatform() : super(configuration: const PlayerConfiguration()) {
    completer.complete();
  }

  final List<String> operations = [];
  final List<Duration> seeks = [];
  final List<SubtitleTrack> subtitleSelections = [];
  Duration duration = Duration.zero;

  @override
  Future<int> get handle async => 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    operations.add('open');
    state = state.copyWith(duration: duration);
  }

  @override
  Future<void> play() async {
    operations.add('play');
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    operations.add('pause');
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() async =>
      state.playing ? await pause() : await play();

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    emitPosition(duration);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleSelections.add(track);
  }

  void emitPosition(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }
}
