import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/ui/video_player/video_player_controller.dart';
import 'package:listenook/ui/video_player/video_player_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'video_player_fakes.dart';

void main() {
  late Directory directory;
  late FakePlayerPlatform platform;
  late RecordingRepeatLoop loop;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listenook-player-ui-');
    File('${directory.path}/talk.mp4').writeAsBytesSync([0, 1]);
    File('${directory.path}/talk.srt').writeAsStringSync('''
1
00:00:01,000 --> 00:00:02,000
First line.

2
00:00:03,000 --> 00:00:04,500
Second line.
''');
    platform = FakePlayerPlatform();
    loop = RecordingRepeatLoop();
    debugVideoPlayerControllerFactory = (path) => VideoPlayerController(
      path: path,
      player: Player(platformPlayer: platform),
      repeatLoopFactory: (_) => loop,
      trackWaitTimeout: Duration.zero,
    );
  });

  tearDown(() async {
    debugVideoPlayerControllerFactory = null;
    await directory.delete(recursive: true);
  });

  Future<void> pumpPlayer(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppStrings.delegate],
          home: VideoPlayerPage(path: '${directory.path}/talk.mp4'),
        ),
      );
      // Let the controller read the subtitle file off the fake clock.
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (platform.operations.contains('play')) break;
      }
    });
    await tester.pump();
  }

  testWidgets('shows the current subtitle and steps by subtitle', (
    tester,
  ) async {
    await pumpPlayer(tester);
    expect(find.text('talk.mp4'), findsOneWidget);

    platform.emitPosition(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(find.text('First line.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(platform.seeks.last, const Duration(milliseconds: 3000));
    expect(find.text('Second line.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(platform.seeks.last, const Duration(milliseconds: 1000));
  });

  testWidgets('holding R repeats the current subtitle', (tester) async {
    await pumpPlayer(tester);
    platform.emitPosition(const Duration(milliseconds: 3200));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(loop.events, ['range:2650:4500']);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(loop.events.last, 'clear');
  });

  testWidgets('the subtitle menu can turn subtitles off', (tester) async {
    await pumpPlayer(tester);
    platform.emitPosition(const Duration(milliseconds: 1200));
    await tester.pump();

    await tester.tap(find.byKey(const Key('video-player-subtitles')));
    await tester.pumpAndSettle();
    expect(find.text('talk.srt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('video-player-subtitle-off')));
    await tester.pumpAndSettle();

    expect(find.text('First line.'), findsNothing);
    expect(platform.subtitleSelections.last.id, 'no');
  });

  testWidgets('Esc closes the windowed player', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppStrings.delegate],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(VideoPlayerPage.route('${directory.path}/talk.mp4')),
              child: const Text('open'),
            ),
          ),
        ),
      );
    });
    await tester.tap(find.text('open'));
    await tester.runAsync(() async {
      await tester.pump();
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (platform.operations.contains('play')) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsOneWidget);

    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
