import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/core/podcast_models.dart';
import 'package:meow_stt/data/local_repositories.dart';
import 'package:meow_stt/state/podcast_player.dart';

void main() {
  test('segment-owned tokens stay with overlapping speaker cues', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Alpha',
          startMs: 1000,
          endMs: 1300,
          segmentId: 'a',
        ),
        TranscriptToken(
          text: 'Beta',
          startMs: 1000,
          endMs: 1300,
          segmentId: 'b',
        ),
      ],
      segments: const [
        TranscriptSegment(id: 'a', startMs: 900, endMs: 1500, text: 'Alpha'),
        TranscriptSegment(id: 'b', startMs: 900, endMs: 1500, text: 'Beta'),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 16),
    );

    final cues = PodcastPlayer.cuesFrom(document);

    expect(cues[0].tokens.map((token) => token.text), ['Alpha']);
    expect(cues[1].tokens.map((token) => token.text), ['Beta']);
  });

  test('playback progress survives a new player session', () async {
    final directory = await Directory.systemTemp.createTemp('meow-playback-');
    addTearDown(() => directory.delete(recursive: true));
    final repository = JsonPodcastRepository(
      AppPaths.forTesting(directory.path),
    );
    const episodeId = 'https://feeds.example/show\nguid-1';
    const saved = PodcastListenProgress(
      positionMs: 185_000,
      durationMs: 1_920_000,
    );

    await repository.savePlaybackProgress({episodeId: saved});

    final player = PodcastPlayer(repository: repository);
    addTearDown(player.dispose);
    await player.initialize();

    final progress = player.progressFor(episodeId);
    expect(progress, isNotNull);
    expect(progress!.isContinue, isTrue);
    expect(progress.positionMs, 185000);
    expect(progress.remainingMs, 1_920_000 - 185_000);
    expect(player.storedPositionMs(episodeId), 185000);
    expect(player.storedPositionMs('missing'), 0);
  });

  test('pause is a no-op without an active session', () async {
    final player = PodcastPlayer();
    addTearDown(player.dispose);
    await player.pause();
    expect(player.hasSession, isFalse);
    expect(player.playing, isFalse);
  });

  test('json playback store round-trips episode progress', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-playback-json-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final repository = JsonPodcastRepository(
      AppPaths.forTesting(directory.path),
    );
    final original = {
      'ep-a': const PodcastListenProgress(positionMs: 4000, durationMs: 60000),
      'ep-b': const PodcastListenProgress(positionMs: 12000, durationMs: 0),
    };

    await repository.savePlaybackProgress(original);
    final loaded = await repository.loadPlaybackProgress();

    expect(loaded['ep-a']?.positionMs, 4000);
    expect(loaded['ep-b']?.isContinue, isTrue);
  });

  test('shutdown waits until in-memory playback progress is stored', () async {
    final repository = _BlockingPlaybackRepository();
    final player = PodcastPlayer(repository: repository);
    addTearDown(player.dispose);
    await player.initialize();

    var shutdownCompleted = false;
    final shutdown = player.shutdown().then((_) => shutdownCompleted = true);
    await repository.saveStarted.future;
    await Future<void>.delayed(Duration.zero);

    expect(shutdownCompleted, isFalse);
    repository.allowSave.complete();
    await shutdown;

    expect(shutdownCompleted, isTrue);
    expect(repository.progress['episode']?.positionMs, 185000);
  });
}

class _BlockingPlaybackRepository implements PodcastRepository {
  final saveStarted = Completer<void>();
  final allowSave = Completer<void>();
  Map<String, PodcastListenProgress> progress = {
    'episode': const PodcastListenProgress(
      positionMs: 185000,
      durationMs: 1920000,
    ),
  };

  @override
  Future<PodcastLibraryState> load() async => const PodcastLibraryState();

  @override
  Future<void> save(PodcastLibraryState state) async {}

  @override
  Future<Map<String, PodcastListenProgress>> loadPlaybackProgress() async =>
      Map.of(progress);

  @override
  Future<void> savePlaybackProgress(
    Map<String, PodcastListenProgress> progress,
  ) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await allowSave.future;
    this.progress = Map.of(progress);
  }
}
