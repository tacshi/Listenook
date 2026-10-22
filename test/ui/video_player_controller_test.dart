import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/speech_boundaries.dart';
import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/ui/video_player/video_player_controller.dart';
import 'package:media_kit/media_kit.dart';

import 'video_player_fakes.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listenook-player-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  ({
    VideoPlayerController controller,
    FakePlayerPlatform platform,
    RecordingRepeatLoop loop,
  })
  create(
    String videoPath, {
    VideoPlaybackRepository? repository,
    Future<SpeechEnergy?> Function(String path)? loadSpeechEnergy,
  }) {
    final platform = FakePlayerPlatform();
    final loop = RecordingRepeatLoop();
    final controller = VideoPlayerController(
      path: videoPath,
      player: Player(platformPlayer: platform),
      repeatLoopFactory: (_) => loop,
      playbackRepository: repository,
      trackWaitTimeout: Duration.zero,
      loadSpeechEnergy: loadSpeechEnergy,
    );
    addTearDown(controller.close);
    return (controller: controller, platform: platform, loop: loop);
  }

  String writeVideo(String name) {
    final file = File('${directory.path}/$name')..writeAsBytesSync([0, 1]);
    return file.path;
  }

  void writeSrt(String name) {
    File('${directory.path}/$name').writeAsStringSync('''
1
00:00:01,000 --> 00:00:02,000
First line.

2
00:00:03,000 --> 00:00:04,500
Second line.

3
00:00:06,000 --> 00:00:07,000
Third line.
''');
  }

  test(
    'a sidecar subtitle becomes the sentence list and starts playing',
    () async {
      final video = writeVideo('movie.mp4');
      writeSrt('movie.en.srt');
      final player = create(video);

      await player.controller.open();

      expect(player.controller.sources, hasLength(1));
      expect(player.controller.selected?.kind, PlayerSubtitleKind.file);
      expect(player.controller.selected?.language, 'en');
      expect(player.controller.cues.map((cue) => cue.text), [
        'First line.',
        'Second line.',
        'Third line.',
      ]);
      expect(player.platform.operations, contains('play'));
      expect(
        player.platform.subtitleSelections.single.id,
        Uri.file('${directory.path}/movie.en.srt').toString(),
      );
    },
  );

  test('arrow navigation jumps between subtitle starts', () async {
    final video = writeVideo('movie.mp4');
    writeSrt('movie.srt');
    final player = create(video);
    await player.controller.open();

    player.platform.emitPosition(const Duration(milliseconds: 3500));
    await pumpEventQueue();
    await player.controller.nextSubtitle();
    expect(player.platform.seeks.last, const Duration(milliseconds: 6000));

    player.platform.emitPosition(const Duration(milliseconds: 6200));
    await pumpEventQueue();
    await player.controller.previousSubtitle();
    expect(player.platform.seeks.last, const Duration(milliseconds: 3000));
  });

  test('holding R loops the subtitle under the playhead', () async {
    final video = writeVideo('movie.mp4');
    writeSrt('movie.srt');
    final player = create(video);
    await player.controller.open();
    player.platform.emitPosition(const Duration(milliseconds: 3400));
    await pumpEventQueue();

    expect(player.controller.beginRepeatHold(), isTrue);
    await pumpEventQueue();
    expect(player.loop.events, ['range:2650:4500']);
    expect(player.controller.repeating, isTrue);

    player.platform.emitPosition(const Duration(milliseconds: 4700));
    await pumpEventQueue();
    expect(player.controller.subtitleText, 'Second line.');

    player.controller.endRepeatHold();
    await pumpEventQueue();
    expect(player.loop.events.last, 'clear');
    expect(player.controller.repeating, isFalse);
  });

  test(
    'a held repeat moves to the pauses once the audio is analyzed',
    () async {
      final video = writeVideo('movie.mp4');
      writeSrt('movie.srt');
      final analysis = Completer<SpeechEnergy?>();
      final requested = <String>[];
      final player = create(
        video,
        loadSpeechEnergy: (path) {
          requested.add(path);
          return analysis.future;
        },
      );
      await player.controller.open();
      expect(requested, [video]);
      player.platform.emitPosition(const Duration(milliseconds: 3400));
      await pumpEventQueue();

      expect(player.controller.beginRepeatHold(), isTrue);
      await pumpEventQueue();
      expect(player.loop.events, ['range:2650:4500']);

      // The second line is spoken from 3.1s to 4.4s, later than its cue.
      const speech = 140;
      const silence = 40;
      analysis.complete(
        SpeechEnergy(
          Uint8List.fromList([
            for (final (durationMs, level) in const [
              (1000, silence),
              (1000, speech),
              (1100, silence),
              (1300, speech),
              (1600, silence),
              (1000, speech),
              (1000, silence),
            ])
              ...List<int>.filled(durationMs ~/ SpeechEnergy.frameMs, level),
          ]),
        ),
      );
      await pumpEventQueue();

      final range = player.loop.events.last.split(':');
      expect(range.first, 'range');
      expect(int.parse(range[1]), inInclusiveRange(2950, 3100));
      expect(int.parse(range[2]), inInclusiveRange(4400, 4700));
    },
  );

  test('without subtitles the arrows seek five seconds', () async {
    final video = writeVideo('plain.mp4');
    final player = create(video);
    await player.controller.open();
    player.platform.emitPosition(const Duration(seconds: 20));
    await pumpEventQueue();

    expect(player.controller.sources, isEmpty);
    expect(player.controller.selected, isNull);
    await player.controller.nextSubtitle();
    expect(player.platform.seeks.last, const Duration(seconds: 25));
    expect(player.controller.beginRepeatHold(), isFalse);
  });

  test('built-in text tracks load cues from the container', () async {
    final video = '${directory.path}/movie.mkv';
    File('test/fixtures/embedded_subtitles/two_tracks.mkv').copySync(video);
    final player = create(video);

    await player.controller.open();

    expect(player.controller.sources.map((source) => source.language), [
      'eng',
      'fre',
    ]);
    expect(player.controller.selected?.language, 'eng');
    expect(player.platform.subtitleSelections.single.id, '1');
    expect(player.controller.cues.map((cue) => cue.text), [
      'Hello there.',
      'Second line, with comma.',
    ]);

    await player.controller.selectSubtitle(player.controller.sources.last);
    expect(player.platform.subtitleSelections.last.id, '2');
    expect(player.controller.cues.first.text, 'Bonjour, le monde');
  });

  test('restores the last subtitle choice and position', () async {
    final video = writeVideo('movie.mp4');
    writeSrt('movie.srt');
    final repository = MemoryPlaybackRepository()
      ..entries[video] = VideoPlaybackEntry(
        positionMs: 30000,
        subtitleId: 'off',
        updatedAt: DateTime.utc(2026),
      );
    final player = create(video, repository: repository);
    player.platform.duration = const Duration(minutes: 2);

    await player.controller.open();

    expect(player.controller.selected, isNull);
    expect(player.platform.seeks, [const Duration(seconds: 30)]);

    await player.controller.selectSubtitle(player.controller.sources.single);
    await pumpEventQueue();
    expect(
      repository.entries[video]?.subtitleId,
      player.controller.sources.single.id,
    );
  });
}
