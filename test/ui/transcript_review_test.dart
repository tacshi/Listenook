import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/transcript_structure_editor.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/state/podcast_controller.dart';
import 'package:listenook/state/podcast_player.dart';
import 'package:listenook/ui/app_shell.dart';
import 'package:listenook/ui/inbox_page.dart';
import 'package:listenook/ui/review_fullscreen_controller.dart';
import 'package:listenook/ui/transcript_review.dart';
import 'package:listenook/ui/workspace_page.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tray_manager/tray_manager.dart' as tray;

void main() {
  testWidgets('blur toggle preserves selectable widget ancestry', (
    tester,
  ) async {
    var blurred = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return BlindListeningBlur(
                blurred: blurred,
                child: const Text(
                  'Current sentence',
                  key: ValueKey('stable-blind-text'),
                ),
              );
            },
          ),
        ),
      ),
    );
    final original = tester.element(
      find.byKey(const ValueKey('stable-blind-text')),
    );
    update(() => blurred = false);
    await tester.pump();
    expect(
      tester.element(find.byKey(const ValueKey('stable-blind-text'))),
      same(original),
    );
    update(() => blurred = true);
    await tester.pump();
    expect(
      tester.element(find.byKey(const ValueKey('stable-blind-text'))),
      same(original),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('blurred sentence click dispatches standard sentence seek', (
    tester,
  ) async {
    final seeks = <TranscriptSeekReason>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(
          body: SelectionArea(
            child: TranscriptSegmentEditor(
              segment: const TranscriptSegment(
                id: 'click',
                startMs: 1000,
                endMs: 2000,
                text: 'Hidden sentence',
              ),
              tokens: const [],
              positionMs: 0,
              isCurrent: false,
              query: '',
              speakerName: '',
              showSpeaker: false,
              showTimestamp: false,
              isEditing: false,
              blindListening: true,
              blurred: true,
              onSeek: ({required reason}) => seeks.add(reason),
              onEdit: () {},
              onCancel: () {},
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('blind-original-click')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(seeks, [TranscriptSeekReason.sentenceClick]);
    expect(
      tester
          .widget<BlindListeningBlur>(
            find.byKey(const ValueKey('blind-original-click')),
          )
          .blurred,
      isTrue,
    );
  });

  testWidgets(
    'blind listening toolbar preference protects drafts and restores normal text',
    (tester) async {
      final controller = await _controllerForDocument(_simpleDocument());
      addTearDown(controller.dispose);
      controller.openInWorkspace('job');
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('segment-edit-segment')),
          )
          .onPressed!();
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckedPopupMenuItem>(
              find.byKey(const Key('toggle-blind-listening')),
            )
            .enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('segment-cancel-segment')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toggle-blind-listening')));
      await tester.pumpAndSettle();
      expect(controller.settings.blindListeningEnabled, isTrue);
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-original-segment')),
            )
            .blurred,
        isTrue,
      );
      expect(
        tester
            .widget<SegmentedButton<bool>>(
              find.byKey(const Key('review-content-tabs')),
            )
            .segments
            .last
            .enabled,
        isFalse,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-original-segment')),
            )
            .blurred,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-original-segment')),
            )
            .blurred,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('toggle-blind-listening')));
      await tester.pumpAndSettle();
      expect(controller.settings.blindListeningEnabled, isFalse);
      expect(find.byKey(const Key('reveal-current-sentence')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('paused fullscreen reveal button changes only subtitle blur', (
    tester,
  ) async {
    var revealed = false;
    var previousCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => VideoFullscreenKeyboardRegion(
              blindListening: true,
              sentenceRevealed: revealed,
              onReveal: () => update(() => revealed = !revealed),
              subtitle: 'Current sentence',
              playing: false,
              position: const Duration(seconds: 2),
              duration: const Duration(seconds: 10),
              onExit: () {},
              onPlayPause: () {},
              onSeek: (_) {},
              onSeekBackward: () {},
              onSeekForward: () {},
              onDecreaseSpeed: () {},
              onIncreaseSpeed: () {},
              onRepeatHoldStart: () {},
              onRepeatHoldEnd: () {},
              sentenceNavigation: SentenceNavigationControls(
                onPrevious: () => previousCalls++,
                onNext: null,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<BlindListeningBlur>(find.byType(BlindListeningBlur))
          .blurred,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('reveal-current-sentence')));
    await tester.pump();
    expect(
      tester
          .widget<BlindListeningBlur>(find.byType(BlindListeningBlur))
          .blurred,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('previous-sentence')));
    expect(previousCalls, 1);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('next-sentence')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  test('sentence navigation handles cue boundaries, gaps and overlaps', () {
    const cues = [
      TranscriptSegment(id: 'a', startMs: 1000, endMs: 2000, text: 'A'),
      TranscriptSegment(id: 'b', startMs: 3000, endMs: 5000, text: 'B'),
      TranscriptSegment(id: 'c', startMs: 4500, endMs: 6000, text: 'C'),
    ];
    expect(sentenceNavigationTarget(cues, 3500, forward: false), 0);
    expect(sentenceNavigationTarget(cues, 3500, forward: true), 2);
    expect(sentenceNavigationTarget(cues, 2500, forward: false), 0);
    expect(sentenceNavigationTarget(cues, 2500, forward: true), 1);
    expect(sentenceNavigationTarget(cues, 0, forward: false), isNull);
    expect(sentenceNavigationTarget(cues, 0, forward: true), 0);
    expect(sentenceNavigationTarget(cues, 7000, forward: false), 2);
    expect(sentenceNavigationTarget(cues, 7000, forward: true), isNull);
    expect(sentenceNavigationTarget(cues, 4700, forward: false), 1);
    expect(currentListeningSegmentIndex(cues, 2500), isNull);
    expect(currentListeningSegmentIndex(cues, 6000), isNull);
    expect(sentenceNavigationTarget(const [], 0, forward: true), isNull);
  });

  testWidgets(
    'dictation pins drafts, checks locally and restores them on navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('meow-blind-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/listen.mp4');
      await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
      late _ReviewFakePlatformPlayer platform;
      debugTranscriptReviewPlayerFactory = () => Player(
        platformPlayer: platform = _ReviewFakePlatformPlayer(
          updatePlayingStateOnControls: true,
        ),
      );
      debugTranscriptReviewSourceExists = (_) async => true;
      final loop = _RecordingSentenceRepeatLoopController();
      debugTranscriptReviewSentenceRepeatLoopFactory = (_) => loop;
      addTearDown(() {
        debugTranscriptReviewPlayerFactory = null;
        debugTranscriptReviewSourceExists = null;
        debugTranscriptReviewSentenceRepeatLoopFactory = null;
      });
      final controller = await _controllerForDocument(
        TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'a',
              startMs: 0,
              endMs: 1000,
              text: 'First sentence.',
              translatedText: '第一句',
            ),
            TranscriptSegment(
              id: 'b',
              startMs: 2000,
              endMs: 3000,
              text: 'Second sentence.',
              translatedText: '第二句',
            ),
            TranscriptSegment(
              id: 'c',
              startMs: 4000,
              endMs: 5000,
              text: 'Third sentence.',
              translatedText: '第三句',
            ),
          ],
          speakers: const [],
          updatedAt: DateTime.utc(2026),
        ),
        sourcePath: source.path,
        metadata: const MediaMetadata(
          sizeBytes: 4,
          durationMs: 5000,
          hasAudio: true,
          hasVideo: true,
          formatName: 'mp4',
        ),
        transcriptSource: TranscriptSource.importedSubtitle,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
        settings: const AppSettings(blindListeningEnabled: true),
      );
      addTearDown(controller.dispose);
      controller.openInWorkspace('job');
      final fullscreen = ReviewFullscreenController();
      Widget reviewForJob(String jobId) => ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: TranscriptReview(
              jobId: jobId,
              fullscreenController: fullscreen,
            ),
          ),
        ),
      );
      await tester.pumpWidget(reviewForJob('job'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      await _selectTranslationView(tester, 'Bilingual');
      await platform.play();
      await tester.pump();
      await tester.tap(find.byKey(const Key('toggle-dictation')));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isFalse);
      final input = find.byKey(const Key('dictation-answer'));
      await tester.enterText(input, 'First wrong');
      platform.emitPosition(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, 'First wrong');
      expect(find.text('Sentence 1 · 00:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dictation-check')));
      await tester.pump();
      expect(find.byKey(const Key('dictation-retry')), findsOneWidget);
      expect(find.text('Different: wrong → sentence'), findsNothing);
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-original-a')),
            )
            .blurred,
        isTrue,
      );
      await tester.enterText(input, 'First sentence');
      await tester.pump();
      expect(find.byKey(const Key('dictation-retry')), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byKey(const Key('dictation-correct')), findsOneWidget);
      expect(find.text('Matches transcript'), findsNothing);
      expect(find.byKey(const Key('dictation-retry')), findsNothing);
      await tester.tap(find.byKey(const Key('dictation-replay')));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isTrue);
      expect(loop.events.where((event) => event.startsWith('range:')), isEmpty);
      platform.emitPosition(const Duration(milliseconds: 999));
      await tester.pump();
      expect(platform.state.playing, isTrue);
      platform.emitPosition(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isFalse);
      expect(platform.state.position, const Duration(milliseconds: 1000));
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      await tester.tap(find.byKey(const Key('dictation-replay')));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isTrue);
      await tester.tap(find.byKey(const Key('next-sentence')).first);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.enterText(input, 'Second draft');
      await tester.tap(find.byKey(const Key('previous-sentence')).first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      await tester.tap(find.byKey(const Key('close-dictation')));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await tester.tap(find.byKey(const Key('toggle-dictation')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      await controller.updateSettings(
        controller.settings.copyWith(blindListeningEnabled: false),
      );
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await controller.updateSettings(
        controller.settings.copyWith(blindListeningEnabled: true),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      await controller.updateSegment('job', 'a', 'Changed reference.');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      expect(find.byKey(const Key('dictation-retry')), findsNothing);
      // A timeline seek into silence keeps the preceding sentence available.
      final transport = tester.widget<VideoTransport>(
        find.byType(VideoTransport).first,
      );
      transport.onSeek(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      transport.onSeek(Duration.zero);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      final inputFocus = tester.widget<TextField>(input).focusNode!;
      inputFocus.unfocus();
      fullscreen.markEntered(
        tester.state<NavigatorState>(find.byType(Navigator).first),
      );
      await tester.pumpWidget(reviewForJob('job'));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      fullscreen.markExited();
      await tester.pumpWidget(reviewForJob('job'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'First sentence',
      );
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
      transport.onSeek(const Duration(milliseconds: 2000));
      await tester.pumpAndSettle();
      await controller.applyTranscriptStructureEdit(
        'job',
        const MergeWithNext('a'),
      );
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await controller.undoTranscriptStructureEdit('job');
      await tester.pumpAndSettle();
      transport.onSeek(const Duration(milliseconds: 2000));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.pumpWidget(reviewForJob('other'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(reviewForJob('job'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dictation-panel')), findsNothing);
      await tester.tap(find.byKey(const Key('toggle-dictation')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    },
  );

  testWidgets(
    'blind listening reveals only current cue and resets on navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('meow-blind-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/listen.mp4');
      await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
      late _ReviewFakePlatformPlayer platform;
      debugTranscriptReviewPlayerFactory = () => Player(
        platformPlayer: platform = _ReviewFakePlatformPlayer(
          updatePlayingStateOnControls: true,
        ),
      );
      debugTranscriptReviewSourceExists = (_) async => true;
      final loop = _RecordingSentenceRepeatLoopController();
      debugTranscriptReviewSentenceRepeatLoopFactory = (_) => loop;
      addTearDown(() {
        debugTranscriptReviewPlayerFactory = null;
        debugTranscriptReviewSourceExists = null;
        debugTranscriptReviewSentenceRepeatLoopFactory = null;
      });
      final controller = await _controllerForDocument(
        TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'a',
              startMs: 0,
              endMs: 1000,
              text: 'First sentence.',
              translatedText: '第一句',
            ),
            TranscriptSegment(
              id: 'b',
              startMs: 2000,
              endMs: 3000,
              text: 'Second sentence.',
              translatedText: '第二句',
            ),
            TranscriptSegment(
              id: 'c',
              startMs: 4000,
              endMs: 5000,
              text: 'Third sentence.',
              translatedText: '第三句',
            ),
          ],
          speakers: const [],
          updatedAt: DateTime.utc(2026),
        ),
        sourcePath: source.path,
        metadata: const MediaMetadata(
          sizeBytes: 4,
          durationMs: 5000,
          hasAudio: true,
          hasVideo: true,
          formatName: 'mp4',
        ),
        transcriptSource: TranscriptSource.importedSubtitle,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
        settings: const AppSettings(blindListeningEnabled: true),
      );
      addTearDown(controller.dispose);
      controller.openInWorkspace('job');
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      await _selectTranslationView(tester, 'Bilingual');
      bool blurred(String id) => tester
          .widget<BlindListeningBlur>(
            find.byKey(ValueKey('blind-original-$id')),
          )
          .blurred;
      expect(blurred('a'), isTrue);
      expect(blurred('b'), isTrue);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('open-transcript-search')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('reveal-current-sentence')));
      await tester.pump();
      expect(blurred('a'), isFalse);
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-translation-a')),
            )
            .blurred,
        isFalse,
      );
      expect(
        tester
            .widget<BlindListeningBlur>(
              find.byKey(const ValueKey('blind-translation-b')),
            )
            .blurred,
        isTrue,
      );
      expect(blurred('b'), isTrue);
      expect(controller.settings.blindListeningEnabled, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(blurred('a'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 1500));
      await tester.pump();
      expect(blurred('a'), isTrue);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('reveal-current-sentence')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('toggle-dictation')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('reveal-current-sentence')));
      await tester.pump();
      expect(blurred('a'), isFalse);
      await tester.tap(find.byKey(const Key('toggle-dictation')));
      await tester.pumpAndSettle();
      expect(find.text('Sentence 1 · 00:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-dictation')));
      await tester.pumpAndSettle();
      platform.emitPosition(const Duration(milliseconds: 2500));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(blurred('b'), isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 1800));
      await tester.pump();
      expect(blurred('b'), isTrue);
      platform.emitPosition(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(blurred('b'), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      platform.emitPlaying(false);
      await tester.pump();

      // Rapid presses use the pending target even before the native loop clears.
      final previous = tester
          .widget<IconButton>(find.byKey(const Key('previous-sentence')))
          .onPressed!;
      previous();
      await tester.pump();
      await tester.pump();
      expect(platform.seekDurations.last, Duration.zero);
      expect(blurred('b'), isTrue);
      expect(platform.state.playing, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      platform.emitPlaying(false);
      await tester.pump();
      final next = tester
          .widget<IconButton>(find.byKey(const Key('next-sentence')))
          .onPressed!;
      next();
      next();
      await tester.pump();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      expect(platform.seekDurations.last, const Duration(milliseconds: 4000));
      expect(platform.state.playing, isFalse);
      expect(loop.events.last, 'clear');
      expect(blurred('c'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [1400.0, 1800.0]) {
    testWidgets('mimic and blind listening toggle independently at $width', (
      tester,
    ) async {
      final loop = _RecordingSentenceRepeatLoopController();
      final platform = await _pumpMimicReview(
        tester,
        loop,
        size: Size(width, 1000),
      );
      final controller = tester
          .element(find.byType(TranscriptReview))
          .read<AppController>();
      Finder panelBlur() => find.descendant(
        of: find.byKey(const Key('mimic-panel')),
        matching: find.byType(BlindListeningBlur),
      );

      expect(
        find.byKey(const Key('toggle-mimic')),
        width == 1800 ? findsOneWidget : findsNothing,
      );
      await _openMimic(tester);
      expect(controller.settings.blindListeningEnabled, isFalse);
      expect(find.byKey(const Key('mimic-panel')), findsOneWidget);
      expect(tester.widget<BlindListeningBlur>(panelBlur()).blurred, isFalse);
      expect(find.byKey(const Key('mimic-reveal')), findsNothing);
      expect(loop.events.last, 'range:0:1000');
      expect(platform.state.playing, isTrue);

      platform.emitPosition(const Duration(milliseconds: 950));
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 10));
      await tester.pump();
      expect(_mimicReps(tester), 'Reps 1/3');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      final loopEvents = List<String>.of(loop.events);

      for (final enabled in [true, false, true]) {
        await tester.tap(find.byKey(const Key('review-toolbar-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('toggle-blind-listening')));
        await tester.pumpAndSettle();
        expect(controller.settings.blindListeningEnabled, enabled);
        expect(find.byKey(const Key('mimic-panel')), findsOneWidget);
        expect(tester.widget<BlindListeningBlur>(panelBlur()).blurred, enabled);
        expect(
          find.byKey(const Key('mimic-reveal')),
          enabled ? findsOneWidget : findsNothing,
        );
        expect(_mimicReps(tester), 'Reps 1/3');
        expect(loop.events, loopEvents);
        expect(platform.state.playing, isTrue);
      }

      await tester.tap(find.byKey(const Key('close-mimic')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mimic-panel')), findsNothing);
      expect(controller.settings.blindListeningEnabled, isTrue);
      expect(loop.events.last, 'clear');
      expect(platform.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mimic follows the clicked sentence immediately', (tester) async {
    final loop = _RecordingSentenceRepeatLoopController();
    final platform = await _pumpMimicReview(tester, loop);
    await _openMimic(tester);

    await tester.tap(find.text('Second sentence.').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
      'Second sentence.',
    );
    expect(_mimicReps(tester), 'Reps 0/3');
    expect(loop.events.last, 'range:1650:3000');
    expect(platform.state.playing, isTrue);

    platform.emitPosition(const Duration(milliseconds: 2950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 1700));
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 1/3');
    expect(platform.state.playing, isFalse);
    await tester.tap(find.text('Third sentence.').first);
    await tester.pumpAndSettle();
    expect(loop.events.last, 'range:3650:5000');
    final seeks = platform.seekDurations.length;
    await tester.pump(const Duration(seconds: 2));
    expect(platform.seekDurations, hasLength(seeks));
    expect(
      tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
      'Third sentence.',
    );
    expect(platform.state.playing, isTrue);
    await tester.tap(find.text('Second sentence.').first);
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 0/3');
    expect(loop.events.last, 'range:1650:3000');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mimic leaves a 1.5 second pause between repetitions', (
    tester,
  ) async {
    final platform = await _pumpMimicReview(
      tester,
      _RecordingSentenceRepeatLoopController(),
    );
    await _openMimic(tester);
    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 1/3');
    expect(platform.state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(platform.state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(platform.state.playing, isTrue);
    expect(_mimicReps(tester), 'Reps 1/3');
  });

  for (final (sentenceMs, rate, pauseMs) in [
    (4000, 1.0, 4500),
    (4000, 0.5, 8500),
    (4000, 2.0, 2500),
    (500, 2.0, 1500),
  ]) {
    testWidgets(
      'mimic allows time to follow a ${sentenceMs}ms sentence at $rate',
      (tester) async {
        final platform = await _pumpMimicReview(
          tester,
          _RecordingSentenceRepeatLoopController(),
          segments: [
            TranscriptSegment(
              id: 'a',
              startMs: 0,
              endMs: sentenceMs,
              text: 'A sentence to repeat aloud.',
            ),
          ],
        );
        platform.emitRate(rate);
        await tester.pump();
        await _openMimic(tester);
        platform.emitPosition(Duration(milliseconds: sentenceMs - 50));
        await tester.pump();
        platform.emitPosition(const Duration(milliseconds: 10));
        await tester.pump();
        expect(_mimicReps(tester), 'Reps 1/3');
        expect(platform.state.playing, isFalse);
        await tester.pump(Duration(milliseconds: pauseMs - 1));
        expect(platform.state.playing, isFalse);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpAndSettle();
        expect(platform.state.playing, isTrue);
        expect(_mimicReps(tester), 'Reps 1/3');
      },
    );
  }

  testWidgets('mimic pause selection replaces the pending wait and persists', (
    tester,
  ) async {
    final platform = await _pumpMimicReview(
      tester,
      _RecordingSentenceRepeatLoopController(),
    );
    await _openMimic(tester);
    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mimic-pause')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<int>>(
            find.byKey(const ValueKey('mimic-pause-0')),
          )
          .checked,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('mimic-pause-5')));
    await tester.pumpAndSettle();
    expect(find.text('Pause 5s'), findsOneWidget);
    expect(_mimicReps(tester), 'Reps 1/3');
    final controller = tester
        .element(find.byType(TranscriptReview))
        .read<AppController>();
    expect(controller.settings.mimicPauseSeconds, 5);
    await tester.pump(const Duration(seconds: 2));
    expect(platform.state.playing, isFalse);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(platform.state.playing, isTrue);
    expect(_mimicReps(tester), 'Reps 1/3');

    await tester.tap(find.byKey(const Key('close-mimic')));
    await tester.pumpAndSettle();
    await _openMimic(tester);
    expect(find.text('Pause 5s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mimic-pause')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<int>>(
            find.byKey(const ValueKey('mimic-pause-5')),
          )
          .checked,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('mimic-pause-0')));
    await tester.pumpAndSettle();
    expect(find.text('Pause Auto'), findsOneWidget);
    expect(controller.settings.mimicPauseSeconds, 0);
    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1499));
    expect(platform.state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(platform.state.playing, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mimic pause uses the saved fixed duration regardless of speed', (
    tester,
  ) async {
    final platform = await _pumpMimicReview(
      tester,
      _RecordingSentenceRepeatLoopController(),
      settings: const AppSettings(mimicPauseSeconds: 3),
    );
    platform.emitRate(0.5);
    await tester.pump();
    await _openMimic(tester);
    expect(find.text('Pause 3s'), findsOneWidget);
    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2999));
    expect(platform.state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(platform.state.playing, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
    testWidgets('mimic controls fit the minimum pane width in $locale', (
      tester,
    ) async {
      await _pumpMimicReview(
        tester,
        _RecordingSentenceRepeatLoopController(),
        locale: locale,
      );
      await _openMimic(tester);
      await tester.drag(
        find.byKey(const ValueKey('vertical-divider-slot')),
        const Offset(2000, 0),
      );
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byKey(const Key('mimic-panel')));
      expect(panel.width, 280);
      for (final key in [
        'mimic-rep-goal',
        'mimic-pause',
        'mimic-reset-reps',
        'close-mimic',
      ]) {
        final bounds = tester.getRect(find.byKey(Key(key)));
        expect(bounds.left, greaterThanOrEqualTo(panel.left));
        expect(bounds.right, lessThanOrEqualTo(panel.right));
      }
      await tester.tap(find.byKey(const Key('mimic-pause')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckedPopupMenuItem<int>>(
              find.byType(CheckedPopupMenuItem<int>),
            )
            .map((item) => item.value),
        [0, 1, 2, 3, 5, 10],
      );
      await tester.tap(find.byKey(const ValueKey('mimic-pause-10')));
      await tester.pumpAndSettle();
      expect(
        find.text(locale.languageCode == 'zh' ? '间隔 10 秒' : 'Pause 10s'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['panel', 'transport', 'space', 'close', 'dispose']) {
    testWidgets('mimic cancels its pending replay on $action', (tester) async {
      final platform = await _pumpMimicReview(
        tester,
        _RecordingSentenceRepeatLoopController(),
      );
      await _openMimic(tester);
      platform.emitPosition(const Duration(milliseconds: 950));
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 10));
      await tester.pump();
      expect(platform.state.playing, isFalse);
      expect(_mimicReps(tester), 'Reps 1/3');

      switch (action) {
        case 'panel':
          await tester.tap(find.byKey(const Key('mimic-loop-toggle')));
        case 'transport':
          await tester.tap(find.byKey(const Key('video-play-pause')));
        case 'space':
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
        case 'close':
          await tester.tap(find.byKey(const Key('close-mimic')));
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pumpAndSettle();
      final operations = List<String>.of(platform.operations);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(platform.operations, operations);
      expect(platform.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mimic mode loops the target sentence and counts reps', (
    tester,
  ) async {
    final loop = _RecordingSentenceRepeatLoopController();
    final platform = await _pumpMimicReview(
      tester,
      loop,
      settings: const AppSettings(blindListeningEnabled: true),
    );

    Finder panelBlur() => find.descendant(
      of: find.byKey(const Key('mimic-panel')),
      matching: find.byType(BlindListeningBlur),
    );

    await _openMimic(tester);
    expect(find.byKey(const Key('mimic-panel')), findsOneWidget);
    expect(loop.events, contains('range:0:1000'));
    expect(_mimicReps(tester), 'Reps 0/3');
    expect(tester.widget<BlindListeningBlur>(panelBlur()).blurred, isTrue);
    expect(find.byKey(const Key('mimic-translation')), findsOneWidget);
    expect(platform.state.playing, isTrue);

    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 1/3');

    await tester.tap(find.byKey(const Key('mimic-reveal')));
    await tester.pump();
    expect(tester.widget<BlindListeningBlur>(panelBlur()).blurred, isFalse);

    await tester.tap(find.byKey(const Key('mimic-next')));
    await tester.pumpAndSettle();
    expect(loop.events.last, 'range:1650:3000');
    expect(_mimicReps(tester), 'Reps 0/3');
    expect(tester.widget<BlindListeningBlur>(panelBlur()).blurred, isTrue);

    await tester.tap(find.byKey(const Key('mimic-loop-toggle')));
    await tester.pump();
    expect(loop.events.last, 'clear');
    expect(platform.state.playing, isFalse);

    await tester.tap(find.byKey(const Key('close-mimic')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mimic-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mimic rep goal changes without losing counts and survives reopening',
    (tester) async {
      final platform = await _pumpMimicReview(
        tester,
        _RecordingSentenceRepeatLoopController(),
      );
      await _openMimic(tester);
      platform.emitPosition(const Duration(milliseconds: 950));
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 10));
      await tester.pump();
      expect(_mimicReps(tester), 'Reps 1/3');

      await tester.tap(find.byKey(const Key('mimic-rep-goal')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckedPopupMenuItem<int>>(
              find.byKey(const ValueKey('mimic-rep-goal-3')),
            )
            .checked,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('mimic-rep-goal-5')));
      await tester.pumpAndSettle();
      expect(_mimicReps(tester), 'Reps 1/5');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isTrue);
      final controller = tester
          .element(find.byType(TranscriptReview))
          .read<AppController>();
      expect(controller.settings.mimicRepGoal, 5);

      await tester.tap(find.byKey(const Key('mimic-next')));
      await tester.pumpAndSettle();
      expect(_mimicReps(tester), 'Reps 0/5');
      await tester.tap(find.byKey(const Key('mimic-previous')));
      await tester.pumpAndSettle();
      expect(_mimicReps(tester), 'Reps 1/5');

      await tester.tap(find.byKey(const Key('close-mimic')));
      await tester.pumpAndSettle();
      await _openMimic(tester);
      expect(_mimicReps(tester), 'Reps 1/5');
      await tester.tap(find.byKey(const Key('mimic-reset-reps')));
      await tester.pump();
      expect(_mimicReps(tester), 'Reps 0/5');
      expect(tester.takeException(), isNull);
    },
  );

  for (final nativeLoop in [true, false]) {
    testWidgets('mimic advances at its rep goal with native loop $nativeLoop', (
      tester,
    ) async {
      final loop = _RecordingSentenceRepeatLoopController();
      final platform = await _pumpMimicReview(
        tester,
        nativeLoop ? loop : _FailingSentenceRepeatLoopController(),
      );
      await _openMimic(tester);

      const texts = ['First sentence.', 'Second sentence.', 'Third sentence.'];
      const starts = [0, 1650, 3650];
      for (var sentence = 0; sentence < 3; sentence++) {
        expect(
          tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
          texts[sentence],
        );
        expect(_mimicReps(tester), 'Reps 0/3');
        expect(platform.state.playing, isTrue);
        final end = sentence * 2000 + 1000;
        if (nativeLoop) {
          expect(loop.events.last, 'range:${starts[sentence]}:$end');
        }
        for (var pass = 1; pass <= 3; pass++) {
          if (!nativeLoop) platform.emitCompleted(completed: false);
          if (nativeLoop && sentence == 0 && pass == 3) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
            await tester.pump();
          }
          platform.emitPosition(Duration(milliseconds: end - 50));
          await tester.pump();
          if (nativeLoop || sentence < 2) {
            platform.emitPosition(
              Duration(
                milliseconds: nativeLoop ? starts[sentence] + 10 : end + 10,
              ),
            );
          }
          if (!nativeLoop) platform.emitCompleted();
          await tester.pumpAndSettle();
          expect(_mimicReps(tester), 'Reps $pass/3');
          expect(platform.state.playing, isFalse);
          if (nativeLoop && sentence == 0 && pass == 3) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
            await tester.pumpAndSettle();
            expect(platform.state.playing, isFalse);
          }
          await tester.pump(const Duration(milliseconds: 1500));
          await tester.pumpAndSettle();
          if (nativeLoop && sentence == 0 && pass == 3) {
            expect(loop.events.last, 'range:1650:3000');
          }
          if (pass < 3) expect(_mimicReps(tester), 'Reps $pass/3');
        }
      }

      expect(_mimicReps(tester), 'Reps 3/3');
      expect(platform.state.playing, isFalse);
      if (nativeLoop) expect(loop.events.last, 'clear');
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('mimic-loop-toggle')))
            .isSelected,
        isFalse,
      );
      // Late playback callbacks cannot count or restart the completed target.
      platform.emitPosition(const Duration(milliseconds: 4950));
      await tester.pump();
      platform.emitPosition(Duration(milliseconds: nativeLoop ? 3660 : 5010));
      platform.emitCompleted();
      await tester.pumpAndSettle();
      expect(_mimicReps(tester), 'Reps 3/3');
      expect(platform.state.playing, isFalse);

      await tester.tap(find.byKey(const Key('mimic-reset-reps')));
      await tester.pump();
      expect(_mimicReps(tester), 'Reps 0/3');
      await tester.tap(find.byKey(const Key('mimic-loop-toggle')));
      await tester.pumpAndSettle();
      expect(platform.state.playing, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mimic lowering the rep goal caps counts and advances playback', (
    tester,
  ) async {
    final loop = _RecordingSentenceRepeatLoopController();
    final platform = await _pumpMimicReview(tester, loop);
    await _openMimic(tester);
    for (var pass = 0; pass < 2; pass++) {
      platform.emitPosition(const Duration(milliseconds: 950));
      await tester.pump();
      platform.emitPosition(const Duration(milliseconds: 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
    }
    expect(_mimicReps(tester), 'Reps 2/3');

    await tester.tap(find.byKey(const Key('mimic-rep-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mimic-rep-goal-1')));
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 0/1');
    expect(
      tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
      'Second sentence.',
    );
    expect(platform.state.playing, isTrue);
    expect(loop.events.last, 'range:1650:3000');

    await tester.tap(find.byKey(const Key('mimic-previous')));
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 1/1');
    expect(platform.state.playing, isFalse);
    expect(loop.events.last, 'clear');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mimic ignores stale completion during automatic advancement', (
    tester,
  ) async {
    final loop = _GatedSentenceRepeatLoopController();
    final platform = await _pumpMimicReview(
      tester,
      loop,
      settings: const AppSettings(mimicRepGoal: 1),
    );
    await _openMimic(tester);
    loop.hold();
    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 10));
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();

    platform.emitPosition(const Duration(milliseconds: 5000));
    platform.emitCompleted();
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 0/1');
    expect(
      tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
      'Second sentence.',
    );
    loop.release();
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 0/1');
    expect(platform.state.playing, isTrue);

    platform.emitPosition(const Duration(milliseconds: 2950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 0/1');
    expect(
      tester.widget<Text>(find.byKey(const Key('mimic-text'))).data,
      'Third sentence.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mimic panel uses the saved rep goal on first open', (
    tester,
  ) async {
    await _pumpMimicReview(
      tester,
      _RecordingSentenceRepeatLoopController(),
      settings: const AppSettings(mimicRepGoal: 10),
    );
    await _openMimic(tester);
    expect(_mimicReps(tester), 'Reps 0/10');
  });

  testWidgets('mimic target change does not count the old sentence', (
    tester,
  ) async {
    final loop = _GatedSentenceRepeatLoopController();
    final platform = await _pumpMimicReview(tester, loop);
    await _openMimic(tester);
    expect(_mimicReps(tester), 'Reps 0/3');

    // Playback is still inside sentence a while the native loop for b is
    // being installed; none of that audio is a rep of b.
    loop.hold();
    await tester.tap(find.byKey(const Key('mimic-next')));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 400));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 500));
    await tester.pump();
    loop.release();
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 0/3');

    platform.emitPosition(const Duration(milliseconds: 2950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 1700));
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 1/3');
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
  });

  testWidgets('mimic counts one rep per pass without a native loop', (
    tester,
  ) async {
    final platform = await _pumpMimicReview(
      tester,
      _FailingSentenceRepeatLoopController(),
    );
    await _openMimic(tester);
    expect(_mimicReps(tester), 'Reps 0/3');

    // Seeking back before the sentence restarts the loop but is not a rep.
    platform.emitPosition(const Duration(milliseconds: 500));
    await tester.pump();
    expect(_mimicReps(tester), 'Reps 0/3');

    platform.emitPosition(const Duration(milliseconds: 950));
    await tester.pump();
    platform.emitPosition(const Duration(milliseconds: 1010));
    platform.emitPosition(const Duration(milliseconds: 1060));
    platform.emitCompleted();
    await tester.pumpAndSettle();
    expect(_mimicReps(tester), 'Reps 1/3');
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
  });

  testWidgets('blur excludes hidden text from semantics and selection', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    String? selected;
    var blurred = true;
    late StateSetter update;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SelectionArea(
            onSelectionChanged: (value) => selected = value?.plainText,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: BlindListeningBlur(
                    blurred: blurred,
                    child: const Text('Hidden answer'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      Future<void> selectText() async {
        final rect = tester.getRect(find.text('Hidden answer'));
        final pointer = await tester.startGesture(
          rect.centerLeft + const Offset(1, 0),
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveTo(rect.centerRight - const Offset(1, 0));
        await pointer.up();
        await tester.pump();
      }

      expect(
        tester
            .binding
            .renderViews
            .single
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!
            .toStringDeep(),
        isNot(contains('Hidden answer')),
      );
      await selectText();
      expect(selected ?? '', isEmpty);
      update(() => blurred = false);
      await tester.pump();
      expect(find.bySemanticsLabel('Hidden answer'), findsOneWidget);
      await selectText();
      expect(selected, contains('Hidden answer'));
      update(() => blurred = true);
      await tester.pump();
      final selectionDelegate = tester
          .widgetList<SelectionRegistrarScope>(
            find.byType(SelectionRegistrarScope),
          )
          .map((scope) => scope.registrar)
          .whereType<SelectionContainerDelegate>()
          .first;
      expect(selectionDelegate.getSelectedContent()?.plainText ?? '', isEmpty);
      expect(
        tester
            .binding
            .renderViews
            .single
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!
            .toStringDeep(),
        isNot(contains('Hidden answer')),
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('podcast shortcuts toggle playback and seek five seconds', (
    tester,
  ) async {
    final player = _ShortcutPodcastPlayer();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PodcastPlaybackShortcuts(
            player: player,
            child: const Column(
              children: [
                Focus(
                  autofocus: true,
                  child: SizedBox(key: Key('shortcut-target'), height: 40),
                ),
                TextField(key: Key('podcast-shortcut-editable')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(player.offsets, const [Duration(seconds: -5), Duration(seconds: 5)]);
    expect(player.toggleCalls, 1);

    await tester.tap(find.byKey(const Key('podcast-shortcut-editable')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.toggleCalls, 1);

    player.active = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(player.offsets, hasLength(2));
  });

  testWidgets('space toggles workspace video unless text is editable', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-video-space-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/space.mp4');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    late _ReviewFakePlatformPlayer platform;
    debugTranscriptReviewPlayerFactory = () =>
        Player(platformPlayer: platform = _ReviewFakePlatformPlayer());
    debugTranscriptReviewSourceExists = (_) async => true;
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() {
      debugTranscriptReviewPlayerFactory = null;
      debugTranscriptReviewSourceExists = null;
      debugPrint = originalDebugPrint;
    });
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: source.path,
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: TranscriptReview(jobId: 'job')),
                TextField(key: Key('shortcut-editable')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(platform.playOrPauseCalls, 1);

    await tester.tap(find.byKey(const Key('shortcut-editable')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(platform.playOrPauseCalls, 1);
    debugPrint = originalDebugPrint;
  });

  testWidgets('video review suppresses the source subtitle track', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-video-subtitles-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/subtitled.mkv');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    late _ReviewFakePlatformPlayer platform;
    debugTranscriptReviewPlayerFactory = () =>
        Player(platformPlayer: platform = _ReviewFakePlatformPlayer());
    debugTranscriptReviewSourceExists = (_) async => true;
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() {
      debugTranscriptReviewPlayerFactory = null;
      debugTranscriptReviewSourceExists = null;
      debugPrint = originalDebugPrint;
    });
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: source.path,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(platform.openCalls, 1);
    expect(platform.subtitleTrackSelections, [
      const SubtitleTrack('no', null, null),
    ]);
    debugPrint = originalDebugPrint;
  });

  testWidgets('sentence repeat prefers the native A-B loop', (tester) async {
    _setTestWindow(tester, const Size(1200, 820));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-repeat-boundary-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/repeat.mp4');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    late _ReviewFakePlatformPlayer platform;
    debugTranscriptReviewPlayerFactory = () => Player(
      platformPlayer: platform = _ReviewFakePlatformPlayer(
        updatePlayingStateOnControls: true,
      ),
    );
    final nativeLoop = _RecordingSentenceRepeatLoopController();
    debugTranscriptReviewSentenceRepeatLoopFactory = (_) => nativeLoop;
    debugTranscriptReviewSourceExists = (_) async => true;
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() {
      debugTranscriptReviewPlayerFactory = null;
      debugTranscriptReviewSentenceRepeatLoopFactory = null;
      debugTranscriptReviewSourceExists = null;
      debugPrint = originalDebugPrint;
    });
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'current',
            startMs: 90989,
            endMs: 96398,
            text:
                "Political protection is the thing that's going to slow progress.",
          ),
          TranscriptSegment(
            id: 'next',
            startMs: 94478,
            endMs: 102719,
            text: "Most people's Tuesdays will probably feel like this week.",
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 25),
      ),
      metadata: const MediaMetadata(
        sizeBytes: 1,
        durationMs: 103000,
        hasAudio: true,
        hasVideo: true,
        formatName: 'mp4',
      ),
      sourcePath: source.path,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    platform.emitPosition(const Duration(milliseconds: 93000));
    platform.emitPlaying(true);
    await tester.pump();
    nativeLoop.events.clear();
    platform.operations.clear();
    final repeat = find.byKey(const ValueKey('segment-repeat-current'));
    expect(repeat, findsOneWidget);
    final repeatButton = tester.widget<IconButton>(repeat);
    expect(repeatButton.onPressed, isNotNull);
    repeatButton.onPressed!();
    await tester.pump();
    await tester.pump();

    expect(nativeLoop.events, const ['range:90639:94478']);
    expect(platform.operations, const ['seek:90639']);
    platform.operations.clear();

    platform.emitPosition(const Duration(milliseconds: 94478));
    await tester.pump();
    await tester.pump();

    expect(
      platform.operations,
      isEmpty,
      reason: 'mpv owns the active A-B boundary; Flutter must not seek again.',
    );

    tester.widget<IconButton>(repeat).onPressed!();
    await tester.pump();
    await tester.pump();
    expect(nativeLoop.events, const ['range:90639:94478', 'clear']);
    debugPrint = originalDebugPrint;
  });

  test('wide video viewport derives its height from the available width', () {
    expect(
      videoViewportHeight(
        width: 960,
        aspectRatio: 16 / 9,
        availableHeight: 700,
      ),
      540,
    );
    expect(
      videoViewportHeight(
        width: 960,
        aspectRatio: 16 / 9,
        availableHeight: 700,
        maximumHeight: 300,
      ),
      300,
    );
  });

  test('current sentence remains active through the following silence', () {
    const segments = [
      TranscriptSegment(id: 'first', startMs: 100, endMs: 1000, text: 'First'),
      TranscriptSegment(
        id: 'second',
        startMs: 1500,
        endMs: 2200,
        text: 'Second',
      ),
    ];

    expect(currentTranscriptSegmentIndex(segments, 99), isNull);
    expect(currentTranscriptSegmentIndex(segments, 100), 0);
    expect(currentTranscriptSegmentIndex(segments, 1200), 0);
    expect(currentTranscriptSegmentIndex(segments, 1500), 1);
    expect(currentTranscriptSegmentIndex(segments, 5000), 1);
  });

  test(
    'rapid seeks execute the first and latest native positions only',
    () async {
      final firstSeek = Completer<void>();
      final nativePositions = <Duration>[];
      final dispatcher = LatestSeekDispatcher((position) async {
        nativePositions.add(position);
        if (nativePositions.length == 1) await firstSeek.future;
      });

      final pending = <Future<void>>[
        dispatcher.seek(const Duration(seconds: 1)),
        dispatcher.seek(const Duration(seconds: 20)),
        dispatcher.seek(const Duration(seconds: 45)),
      ];

      expect(nativePositions, [const Duration(seconds: 1)]);
      firstSeek.complete();
      await Future.wait(pending);
      expect(nativePositions, [
        const Duration(seconds: 1),
        const Duration(seconds: 45),
      ]);
    },
  );

  test('sentence repeat includes lead-in and tolerates seek undershoot', () {
    const valid = TranscriptSegment(
      id: 'valid',
      startMs: 1000,
      endMs: 1900,
      text: 'Repeat me',
    );
    const nearBeginning = TranscriptSegment(
      id: 'near-beginning',
      startMs: 200,
      endMs: 900,
      text: 'Clamp me',
    );
    const previous = TranscriptSegment(
      id: 'previous',
      startMs: 40830,
      endMs: 42510,
      text: 'I wanted something difficult.',
    );
    const afterPrevious = TranscriptSegment(
      id: 'after-previous',
      startMs: 42810,
      endMs: 44310,
      text: 'I wanted a challenge.',
    );
    const invalid = TranscriptSegment(
      id: 'invalid',
      startMs: 500,
      endMs: 500,
      text: 'No duration',
    );

    expect(sentenceRepeatStartMs(valid), 650);
    expect(sentenceRepeatStartMs(nearBeginning), 0);
    expect(
      sentenceRepeatStartMs(afterPrevious, previousSegment: previous),
      42610,
      reason: 'The lead-in must not replay the end of "difficult."',
    );
    expect(
      shouldRestartRepeatedSentence(
        afterPrevious,
        42609,
        previousSegment: previous,
      ),
      isFalse,
    );
    expect(shouldRestartRepeatedSentence(valid, 399), isTrue);
    expect(shouldRestartRepeatedSentence(valid, 400), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 649), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 650), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 999), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1000), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1899), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1900), isTrue);
    expect(shouldRestartRepeatedSentence(valid, 2200), isTrue);
    expect(shouldRestartRepeatedSentence(nearBeginning, 0), isFalse);
    expect(shouldRestartRepeatedSentence(nearBeginning, 899), isFalse);
    expect(shouldRestartRepeatedSentence(nearBeginning, 900), isTrue);
    expect(shouldRestartRepeatedSentence(invalid, 500), isFalse);
  });

  test('sentence repeat avoids prior speech when cues are tightly spaced', () {
    const previous = TranscriptSegment(
      id: 'previous',
      startMs: 56550,
      endMs: 59550,
      text:
          '"Come to class on Monday with the ballet 2 student, Stephanie," she said.',
    );
    const target = TranscriptSegment(
      id: 'target',
      startMs: 59610,
      endMs: 61590,
      text: '"You can give it a shot and we\'ll go from there."',
    );

    expect(
      sentenceRepeatStartMs(target, previousSegment: previous),
      59610,
      reason: 'A 60 ms cue gap is too short for clean repeat lead-in.',
    );
  });

  test('sentence repeat lets the current pass finish before restarting', () {
    const segment = TranscriptSegment(
      id: 'current',
      startMs: 1000,
      endMs: 1900,
      text: 'Finish this pass',
    );

    expect(shouldRestartRepeatedSentence(segment, 1450), isFalse);
    expect(shouldRestartRepeatedSentence(segment, 1899), isFalse);
    expect(shouldRestartRepeatedSentence(segment, 1900), isTrue);
  });

  test('sentence repeat stops before the next overlapping sentence', () {
    const current = TranscriptSegment(
      id: 'imported-sentence-19',
      startMs: 90989,
      endMs: 96398,
      text: "Political protection is the thing that's going to slow progress.",
    );
    const next = TranscriptSegment(
      id: 'imported-sentence-20',
      startMs: 94478,
      endMs: 102719,
      text:
          "Most people's Tuesdays will probably feel for better or worse a whole lot like Tuesday this week.",
    );

    expect(
      shouldRestartRepeatedSentence(current, 94357, nextSegment: next),
      isFalse,
    );
    expect(
      shouldRestartRepeatedSentence(current, 94358, nextSegment: next),
      isTrue,
      reason:
          'The repeat seek needs 120 ms to stop playback before "Most" starts.',
    );
  });

  test(
    'mpv A-B repeat uses exact millisecond boundaries and clears them',
    () async {
      final properties = <String>[];
      final loop = MpvSentenceRepeatLoopController((property, value) async {
        properties.add('$property=$value');
      });

      await loop.setRange(startMs: 90989, endMs: 94478);
      await loop.clear();

      expect(properties, const [
        'ab-loop-b=no',
        'ab-loop-count=inf',
        'ab-loop-a=90.989',
        'ab-loop-b=94.478',
        'ab-loop-b=no',
        'ab-loop-a=no',
      ]);
    },
  );

  test('sentence repeat does not follow a transient next sentence', () {
    expect(
      shouldAutoFollowPlaybackSegment(
        playing: true,
        previousIndex: 2,
        nextIndex: 3,
        repeating: true,
      ),
      isFalse,
    );
    expect(
      shouldAutoFollowPlaybackSegment(
        playing: true,
        previousIndex: 2,
        nextIndex: 3,
        repeating: false,
      ),
      isTrue,
    );
  });

  test('sentence repeat restart preserves the transcript viewport', () {
    expect(
      shouldFocusTranscriptAfterSeek(TranscriptSeekReason.repeatRestart),
      isFalse,
    );
    expect(
      shouldFocusTranscriptAfterSeek(TranscriptSeekReason.standard),
      isTrue,
    );
    expect(
      shouldFocusTranscriptAfterSeek(TranscriptSeekReason.videoProgressScrub),
      isFalse,
    );
    expect(shouldFocusTranscriptOnPlaybackResume(repeating: true), isFalse);
    expect(shouldFocusTranscriptOnPlaybackResume(repeating: false), isTrue);
  });

  testWidgets('dragging video progress does not focus the transcript', (
    tester,
  ) async {
    final reasons = <TranscriptSeekReason>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransport(
            playing: false,
            position: const Duration(seconds: 5),
            duration: const Duration(seconds: 30),
            playbackRate: 1,
            onPlayPause: () async {},
            onSeek:
                (
                  _, {
                  TranscriptSeekReason reason = TranscriptSeekReason.standard,
                }) async => reasons.add(reason),
            onPlaybackRateChanged: (_) async {},
            onFullscreen: () async {},
          ),
        ),
      ),
    );
    final seekBounds = tester.getRect(find.byKey(const Key('video-seek')));

    await tester.dragFrom(
      Offset(seekBounds.left + 8, seekBounds.center.dy),
      Offset(seekBounds.width * .8, 0),
    );

    expect(reasons, isNotEmpty);
    expect(
      reasons.every((reason) => !shouldFocusTranscriptAfterSeek(reason)),
      isTrue,
    );
  });

  testWidgets('clicking a sentence does not focus the transcript list', (
    tester,
  ) async {
    final reasons = <TranscriptSeekReason>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptSegmentEditor(
            segment: const TranscriptSegment(
              id: 'clicked',
              startMs: 5000,
              endMs: 6000,
              text: 'Clicked sentence',
            ),
            tokens: const [],
            positionMs: 0,
            isCurrent: false,
            query: '',
            speakerName: '',
            showSpeaker: false,
            showTimestamp: false,
            isEditing: false,
            onSeek: ({required reason}) => reasons.add(reason),
            onEdit: () {},
            onCancel: () {},
            onSave: (_) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('segment-text-clicked')));

    expect(reasons, isNotEmpty);
    expect(
      reasons.every((reason) => !shouldFocusTranscriptAfterSeek(reason)),
      isTrue,
    );
  });

  testWidgets('returning from AI Brief preserves a stopped transcript view', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(800, 700));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: List.generate(
          30,
          (index) => TranscriptSegment(
            id: 'segment-$index',
            startMs: index * 1000,
            endMs: (index + 1) * 1000,
            text: List.filled(
              3,
              'Transcript sentence $index with enough text for a full line.',
            ).join('\n'),
          ),
        ),
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);
    controller.rememberPlaybackPosition(
      'job',
      const Duration(milliseconds: 5000),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('transcript-scroll')),
      const Offset(0, 1000),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('segment-card-segment-0')),
      findsOneWidget,
    );
    final firstSegmentTop = tester.getTopLeft(
      find.byKey(const ValueKey('segment-card-segment-0')),
    );

    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('Transcript'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('segment-card-segment-0')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('segment-card-segment-0'))),
      firstSegmentTop,
    );
  });

  testWidgets(
    'large Workspace transcript opens and scrolls without a UI stall',
    (tester) async {
      _setTestWindow(tester, const Size(800, 700));
      final controller = await _controllerForDocument(
        TranscriptDocument(
          tokens: const [],
          segments: List.generate(
            4695,
            (index) => TranscriptSegment(
              id: 'large-$index',
              startMs: index * 1000,
              endMs: index * 1000 + 900,
              text: 'Subtitle cue $index',
            ),
          ),
          speakers: const [],
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      addTearDown(controller.dispose);

      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      );
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 150)),
        reason: 'Large transcript setup must not block the UI.',
      );

      stopwatch
        ..reset()
        ..start();
      await tester.drag(
        find.byKey(const Key('transcript-scroll')),
        const Offset(0, -500),
      );
      await tester.pump();
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 150)),
        reason: 'Large transcript scrolling must reuse cached eligibility.',
      );
    },
  );

  group('fullscreen transcript subtitles', () {
    const timedSegments = [
      TranscriptSegment(id: 'first', startMs: 100, endMs: 1000, text: 'First'),
      TranscriptSegment(
        id: 'second',
        startMs: 1500,
        endMs: 2200,
        text: 'Second',
      ),
    ];

    test('uses cue bounds and hides subtitles during timing gaps', () {
      String? subtitleAt(int positionMs) => fullscreenTranscriptSubtitle(
        timedSegments,
        positionMs,
        TranslationViewMode.original,
      );

      expect(subtitleAt(99), isNull);
      expect(subtitleAt(100), 'First');
      expect(subtitleAt(999), 'First');
      expect(subtitleAt(1000), isNull);
      expect(subtitleAt(1499), isNull);
      expect(subtitleAt(1500), 'Second');
      expect(subtitleAt(2199), 'Second');
      expect(subtitleAt(2200), isNull);
    });

    test('pins the repeated cue throughout its lead-in', () {
      expect(
        currentTranscriptSegmentIndex(
          timedSegments,
          1200,
          pinnedSegmentId: 'second',
        ),
        1,
      );
      expect(
        fullscreenTranscriptSubtitle(
          timedSegments,
          1200,
          TranslationViewMode.original,
          pinnedSegmentId: 'second',
        ),
        'Second',
      );
    });

    test('maps review modes and falls back from missing translations', () {
      const translated = TranscriptSegment(
        id: 'translated',
        startMs: 0,
        endMs: 1000,
        text: ' Original sentence. ',
        translatedText: ' 翻译句子。 ',
      );
      const untranslated = TranscriptSegment(
        id: 'untranslated',
        startMs: 0,
        endMs: 1000,
        text: 'Source fallback.',
      );

      expect(
        fullscreenTranscriptSubtitle(
          const [translated],
          500,
          TranslationViewMode.original,
        ),
        'Original sentence.',
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [translated],
          500,
          TranslationViewMode.translated,
        ),
        '翻译句子。',
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [translated],
          500,
          TranslationViewMode.bilingual,
        ),
        'Original sentence.\n翻译句子。',
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [untranslated],
          500,
          TranslationViewMode.translated,
        ),
        'Source fallback.',
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [untranslated],
          500,
          TranslationViewMode.bilingual,
        ),
        'Source fallback.',
      );
    });

    test('tracks the current timed word in visible original text', () {
      final document = TranscriptDocument(
        tokens: const [
          TranscriptToken(text: 'Hello', startMs: 100, endMs: 400),
          TranscriptToken(text: ' world', startMs: 500, endMs: 850),
          TranscriptToken(text: '.', startMs: 900, endMs: 950),
        ],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 100,
            endMs: 1000,
            text: 'Hello world.',
            translatedText: '你好世界。',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      );

      TextRange? rangeAt(int positionMs, TranslationViewMode viewMode) =>
          fullscreenTranscriptWordRange(document, positionMs, viewMode);

      expect(rangeAt(99, TranslationViewMode.original), isNull);
      expect(
        rangeAt(100, TranslationViewMode.original),
        const TextRange(start: 0, end: 5),
      );
      expect(
        rangeAt(499, TranslationViewMode.original),
        const TextRange(start: 0, end: 5),
      );
      expect(
        rangeAt(500, TranslationViewMode.original),
        const TextRange(start: 6, end: 11),
      );
      expect(
        rangeAt(900, TranslationViewMode.original),
        const TextRange(start: 6, end: 11),
      );
      expect(rangeAt(500, TranslationViewMode.translated), isNull);
      expect(
        rangeAt(500, TranslationViewMode.bilingual),
        const TextRange(start: 6, end: 11),
      );
      expect(rangeAt(1000, TranslationViewMode.original), isNull);

      final fragmentedWord = TranscriptDocument(
        tokens: const [
          TranscriptToken(text: 'skill', startMs: 100, endMs: 450),
          TranscriptToken(text: 's', startMs: 500, endMs: 800),
        ],
        segments: const [
          TranscriptSegment(
            id: 'fragmented',
            startMs: 100,
            endMs: 900,
            text: 'skills',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      );
      expect(
        fullscreenTranscriptWordRange(
          fragmentedWord,
          500,
          TranslationViewMode.original,
        ),
        const TextRange(start: 0, end: 6),
      );
    });

    test('does not highlight a word during a repeated cue lead-in', () {
      final document = TranscriptDocument(
        tokens: const [
          TranscriptToken(text: 'First', startMs: 100, endMs: 900),
          TranscriptToken(text: 'Second', startMs: 1500, endMs: 2100),
        ],
        segments: timedSegments,
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      );

      expect(
        fullscreenTranscriptWordRange(
          document,
          1200,
          TranslationViewMode.original,
          pinnedSegmentId: 'second',
        ),
        isNull,
      );
      expect(
        fullscreenTranscriptWordRange(
          document,
          1500,
          TranslationViewMode.original,
          pinnedSegmentId: 'second',
        ),
        const TextRange(start: 0, end: 6),
      );
    });

    test('omits blank lines and empty cues', () {
      const translatedOnly = TranscriptSegment(
        id: 'translated-only',
        startMs: 0,
        endMs: 1000,
        text: '   ',
        translatedText: ' Translation only. ',
      );
      const empty = TranscriptSegment(
        id: 'empty',
        startMs: 0,
        endMs: 1000,
        text: ' ',
        translatedText: '  ',
      );

      expect(
        fullscreenTranscriptSubtitle(
          const [translatedOnly],
          500,
          TranslationViewMode.bilingual,
        ),
        'Translation only.',
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [empty],
          500,
          TranslationViewMode.original,
        ),
        isNull,
      );
      expect(
        fullscreenTranscriptSubtitle(
          const [empty],
          500,
          TranslationViewMode.translated,
        ),
        isNull,
      );
    });
  });

  testWidgets('translated review mode searches and displays translated text', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: '翻译句子。',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final viewDropdown = tester.widget<DropdownButton<TranslationViewMode>>(
      find.byKey(const Key('translation-view-mode')),
    );
    expect(
      viewDropdown.items!.map((item) => item.value),
      TranslationViewMode.values,
    );
    expect(find.byKey(const Key('translation-toolbar-action')), findsNothing);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<PopupMenuItem>(find.byKey(const Key('translate-transcript')))
          .enabled,
      isFalse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _selectTranslationView(tester, 'Translated');
    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('transcript-search-field')),
      '翻译',
    );
    await tester.pump();

    expect(find.text('翻译句子。'), findsOneWidget);
    expect(find.text('Original sentence.'), findsNothing);
  });

  testWidgets(
    'completed translation command lives in the unified overflow menu',
    (tester) async {
      _setTestWindow(tester, const Size(900, 620));
      final controller = await _controllerForDocument(
        TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'segment',
              startMs: 0,
              endMs: 1000,
              text: 'Original sentence.',
              translatedText: '翻译句子。',
            ),
          ],
          speakers: const [],
          updatedAt: DateTime.now().toUtc(),
        ),
        translationState: const TranslationState(
          status: TranslationStatus.completed,
          targetLanguage: 'zh-Hans',
          completedSegments: 1,
          totalSegments: 1,
        ),
        settings: _configuredTranslationAppSettings,
      );
      addTearDown(controller.dispose);

      Future<void> pump(Locale locale) => tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            locale: locale,
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      );

      await pump(const Locale('en'));
      await tester.pumpAndSettle();

      final toolbar = find.byKey(const Key('transcript-pane-toolbar-row'));
      expect(find.byKey(const Key('transcript-pane-header')), findsOneWidget);
      expect(toolbar, findsOneWidget);
      expect(
        find.descendant(
          of: toolbar,
          matching: find.byKey(const Key('open-transcript-search')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: toolbar,
          matching: find.byKey(const Key('translation-view-mode')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: toolbar,
          matching: find.byKey(const Key('translation-status')),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('translation-toolbar-action')), findsNothing);
      expect(find.byType(SegmentedButton<TranslationViewMode>), findsNothing);
      expect(find.text('Retranslate all with LLM'), findsNothing);
      expect(find.text('Completed'), findsNothing);
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('Retranslate all with LLM'), findsOneWidget);
      expect(find.byIcon(Icons.restart_alt_rounded), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final dropdown = tester.getRect(
        find.byKey(const Key('translation-view-mode-control')),
      );
      final toolbarRect = tester.getRect(toolbar);
      final focus = tester.getRect(
        find.byKey(const Key('focus-current-sentence')),
      );
      final more = tester.getRect(find.byKey(const Key('review-toolbar-more')));
      final filename = tester.getRect(find.byKey(const Key('review-filename')));
      expect(filename.left, closeTo(toolbarRect.left, 0.1));
      expect(dropdown.left, greaterThan(filename.left));
      expect(focus.left - dropdown.right, greaterThan(16));
      expect(more.right, closeTo(toolbarRect.right, 0.1));
      expect(tester.takeException(), isNull);

      await pump(const Locale('zh'));
      await tester.pumpAndSettle();
      expect(find.text('已完成'), findsNothing);
      expect(find.text('使用 LLM 全部重新翻译'), findsNothing);
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('使用 LLM 全部重新翻译'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retryable translation command remains available in overflow', (
    tester,
  ) async {
    // TranscriptReview's Card contributes 8px of horizontal margin, leaving
    // the toolbar at the exact 680px expanded-layout breakpoint.
    _setTestWindow(tester, const Size(688, 620));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'translated',
            startMs: 0,
            endMs: 1000,
            text: 'Translated source.',
            translatedText: '已有译文。',
          ),
          TranscriptSegment(
            id: 'missing',
            startMs: 1000,
            endMs: 2000,
            text: 'Missing translation.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      translationState: const TranslationState(
        status: TranslationStatus.partial,
        targetLanguage: 'zh-Hans',
        completedSegments: 1,
        totalSegments: 2,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Translation is incomplete'), findsOneWidget);
    expect(find.text('Translate unfinished with LLM'), findsNothing);
    expect(find.text('Retranslate all with LLM'), findsNothing);
    expect(find.byKey(const Key('translation-more-actions')), findsNothing);
    expect(find.byKey(const Key('translation-toolbar-action')), findsNothing);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-toggle-speakers')), findsNothing);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsNothing);
    expect(find.text('Translate unfinished with LLM'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Translation is incomplete')).style?.color,
      Colors.orange.shade700,
    );
  });

  testWidgets('active translation places its cancel icon after progress', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(600, 900));
    final translation = _BlockingTranslation();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: [
          for (var index = 0; index < 2000; index += 1)
            TranscriptSegment(
              id: 'segment-$index',
              startMs: index * 1000,
              endMs: (index + 1) * 1000,
              text: index == 1 ? 'Still pending.' : 'Sentence $index.',
              translatedText: index != 1 && index <= 1380
                  ? 'Translated $index.'
                  : null,
            ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      settings: _configuredTranslationAppSettings,
      translationService: translation,
    );
    addTearDown(controller.dispose);
    final translationFuture = controller.translateJob(
      'job',
      targetLanguage: 'zh-Hans',
    );
    await translation.started.future;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pump();

    final progressCount = find.byKey(const Key('translation-progress-count'));
    expect(find.text('Translating 1380 of 2000'), findsOneWidget);
    expect(
      (tester.renderObject(progressCount) as RenderParagraph).didExceedMaxLines,
      isFalse,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('translation-status'))).label,
      contains('Translating 1380 of 2000'),
    );
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Translate unfinished with LLM'), findsNothing);
    expect(find.text('Retranslate all with LLM'), findsNothing);
    expect(find.byKey(const Key('translation-more-actions')), findsNothing);
    // Blind listening remains accessible while translation is running.
    expect(find.byKey(const Key('review-toolbar-more')), findsOneWidget);
    expect(find.byKey(const Key('translation-status-strip')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('translation-toolbar-action')), findsNothing);
    final progressBar = find.byKey(const Key('translation-progress-bar'));
    final cancelTranslation = find.byKey(
      const Key('cancel-translation-progress'),
    );
    expect(progressBar, findsOneWidget);
    expect(cancelTranslation, findsOneWidget);
    expect(tester.widget<IconButton>(cancelTranslation).tooltip, 'Cancel');
    expect(
      tester
          .widget<IconButton>(cancelTranslation)
          .style
          ?.backgroundColor
          ?.resolve({}),
      isNull,
    );
    expect(
      tester.getTopLeft(cancelTranslation).dx,
      greaterThan(tester.getTopRight(progressBar).dx),
    );
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    final translatedCard = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('segment-card-segment-0')),
    );
    final pendingCard = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('segment-card-segment-1')),
    );
    final translatedDecoration = translatedCard.decoration as BoxDecoration;
    final pendingDecoration = pendingCard.decoration as BoxDecoration;
    expect(translatedDecoration.color, isNotNull);
    expect(translatedDecoration.border, isNull);
    expect(pendingDecoration.color, isNull);
    expect(pendingDecoration.border, isNull);

    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);

    translation.release.complete();
    await translationFuture;
  });

  testWidgets('narrow transcript pane keeps commands in its local toolbar', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: '翻译句子。',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        completedSegments: 1,
        totalSegments: 1,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectTranslationView(tester, 'Translated');
    await tester.drag(
      find.byKey(const Key('video-transcript-divider')),
      const Offset(500, 0),
    );
    await tester.pump();

    expect(
      tester
          .getSize(find.byKey(const Key('video-review-transcript-pane')))
          .width,
      closeTo(280, 1),
    );
    final toolbar = find.byKey(const Key('transcript-pane-toolbar-row'));
    expect(find.byKey(const Key('review-header')), findsOneWidget);
    expect(toolbar, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-header')),
        matching: find.byKey(const Key('review-content-tabs')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('transcript-toolbar-row')), findsNothing);
    expect(find.byKey(const Key('translation-more-actions')), findsNothing);
    expect(find.byKey(const Key('translation-toolbar-action')), findsNothing);
    expect(find.byKey(const Key('translation-status')), findsNothing);
    expect(find.text('Completed'), findsNothing);
    expect(find.byKey(const Key('translation-view-mode')), findsNothing);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsNothing);
    expect(find.byKey(const Key('toggle-timestamps')), findsNothing);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsNothing);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsNothing);
    expect(
      tester.getRect(find.byKey(const Key('review-toolbar-more'))).right,
      closeTo(tester.getRect(toolbar).right, 0.1),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-group-segment'))),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getRect(find.byKey(const ValueKey('translated-retranslate-segment')))
          .right,
      lessThanOrEqualTo(
        tester
            .getRect(find.byKey(const ValueKey('translated-segment-segment')))
            .right,
      ),
    );
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-toggle-speakers')), findsOneWidget);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsOneWidget);
    expect(
      find.byKey(const Key('more-toggle-transcript-structure')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('copy-transcript-menu')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-menu')), findsOneWidget);
    expect(find.text('Retranslate all with LLM'), findsOneWidget);
  });

  testWidgets('search expands in the transcript pane and clears cleanly', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1000,
            text: 'First sentence.',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1000,
            endMs: 2000,
            text: 'Second sentence.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toolbarHeight = tester
        .getSize(find.byKey(const Key('review-header')))
        .height;
    expect(toolbarHeight, 64);
    expect(find.byKey(const Key('transcript-search-field')), findsNothing);
    final transcriptTabsCenter = tester
        .getCenter(find.byKey(const Key('review-content-tabs')))
        .dx;
    expect(
      transcriptTabsCenter,
      closeTo(tester.getCenter(find.byKey(const Key('review-header'))).dx, 0.1),
    );
    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    final search = find.byKey(const Key('transcript-search-field'));
    expect(search, findsOneWidget);
    final paneHeaderRect = tester.getRect(
      find.byKey(const Key('transcript-pane-header')),
    );
    expect(find.byKey(const Key('review-filename')), findsNothing);
    expect(tester.getRect(search).left, greaterThan(paneHeaderRect.left));
    expect(
      tester.getRect(search).right,
      lessThanOrEqualTo(paneHeaderRect.right),
    );
    expect(
      tester.getCenter(find.byKey(const Key('review-content-tabs'))).dx,
      closeTo(transcriptTabsCenter, 0.1),
    );
    expect(
      tester.getSize(find.byKey(const Key('review-header'))).height,
      toolbarHeight,
    );
    expect(find.byKey(const Key('review-toolbar-search-row')), findsOneWidget);
    expect(find.byKey(const Key('review-toolbar-row')), findsOneWidget);
    expect(find.byKey(const Key('transcript-pane-toolbar-row')), findsNothing);
    expect(find.byKey(const Key('transcript-toolbar-row')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-header')),
        matching: find.byKey(const Key('review-content-tabs')),
      ),
      findsOneWidget,
    );

    await tester.enterText(search, 'Second');
    await tester.pump();
    expect(find.byKey(const ValueKey('segment-card-first')), findsNothing);
    expect(find.byKey(const ValueKey('segment-card-second')), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-transcript-search')));
    await tester.pump();
    expect(find.byKey(const ValueKey('segment-card-first')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-card-second')), findsOneWidget);

    await tester.enterText(search, 'Second');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    expect(find.byKey(const Key('open-transcript-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-card-first')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('transcript-search-field')),
      'Second',
    );
    await tester.tap(find.text('AI Brief').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transcript-search-field')), findsNothing);
    expect(find.byKey(const Key('ai-brief-empty-action')), findsOneWidget);
    await tester.tap(find.text('Transcript').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('transcript-search-field')),
      'Second',
    );
    await tester.tap(find.byKey(const Key('close-transcript-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transcript-search-field')), findsNothing);
    expect(find.byKey(const ValueKey('segment-card-first')), findsOneWidget);
  });

  testWidgets('changing the reviewed job closes and clears search', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    TranscriptDocument document(String id) => TranscriptDocument(
      tokens: const [],
      segments: [
        TranscriptSegment(
          id: id,
          startMs: 0,
          endMs: 1000,
          text: '$id sentence.',
        ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    TranscriptionJob job(String id) => TranscriptionJob(
      id: id,
      batchId: 'batch',
      sourcePath: '/missing/$id.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: document(id),
    );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([job('first'), job('second')]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    Future<void> pump(String jobId) => tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: jobId)),
        ),
      ),
    );

    await pump('first');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('transcript-search-field')),
      'no match',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('segment-card-first')), findsNothing);

    await pump('second');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transcript-search-field')), findsNothing);
    expect(find.byKey(const Key('open-transcript-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-card-second')), findsOneWidget);
  });

  testWidgets('each translation view shows one repeat control per sentence', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: 'Translated sentence.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const repeatKey = ValueKey('segment-repeat-segment');
    const sourceKey = ValueKey('segment-card-segment');
    const translatedKey = ValueKey('translated-segment-segment');
    expect(find.byKey(repeatKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(sourceKey),
        matching: find.byKey(repeatKey),
      ),
      findsOneWidget,
    );

    await _selectTranslationView(tester, 'Translated');
    expect(find.byKey(repeatKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(translatedKey),
        matching: find.byKey(repeatKey),
      ),
      findsOneWidget,
    );

    await _selectTranslationView(tester, 'Bilingual');
    expect(find.byKey(repeatKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(sourceKey),
        matching: find.byKey(repeatKey),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(translatedKey),
        matching: find.byKey(repeatKey),
      ),
      findsNothing,
    );
  });

  testWidgets('translation modes share one calm grouped sentence layout', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'grouped',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: '翻译句子。',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        completedSegments: 1,
        totalSegments: 1,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const groupKey = ValueKey('segment-group-grouped');
    expect(find.byKey(groupKey), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(groupKey), matching: find.byType(Card)),
      findsNothing,
    );

    await _selectTranslationView(tester, 'Bilingual');
    final source = find.byKey(const ValueKey('segment-text-grouped'));
    final translation = find.byKey(const ValueKey('translated-text-grouped'));
    expect(source, findsOneWidget);
    expect(translation, findsOneWidget);
    expect(
      tester.getTopLeft(source).dx,
      closeTo(tester.getTopLeft(translation).dx, 1),
    );
    expect(
      tester.getTopLeft(source).dy,
      lessThan(tester.getTopLeft(translation).dy),
    );
    expect(
      find.descendant(
        of: find.byKey(groupKey),
        matching: find.byKey(const ValueKey('segment-repeat-grouped')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('translated hover actions are direct and layout-stable', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'actions',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: '翻译句子。',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        completedSegments: 1,
        totalSegments: 1,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectTranslationView(tester, 'Translated');

    const groupKey = ValueKey('segment-group-actions');
    final text = find.byKey(const ValueKey('translated-text-actions'));
    final editOpacity = find.byKey(
      const ValueKey('translated-edit-opacity-actions'),
    );
    final retranslateOpacity = find.byKey(
      const ValueKey('translated-retranslate-opacity-actions'),
    );
    final textRect = tester.getRect(text);
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(retranslateOpacity).opacity, 0);
    expect(
      find.descendant(
        of: find.byKey(groupKey),
        matching: find.byType(PopupMenuButton<String>),
      ),
      findsNothing,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(groupKey)));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(retranslateOpacity).opacity, 1);
    expect(tester.getRect(text), textRect);
  });

  testWidgets('bilingual source and translation edit independently', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'editable-pair',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: '翻译句子。',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        completedSegments: 1,
        totalSegments: 1,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectTranslationView(tester, 'Bilingual');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('segment-text-editable-pair')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-edit-editable-pair')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('segment-editor-editable-pair')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('translated-field-editable-pair')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('segment-cancel-editable-pair')),
    );
    await tester.pump();

    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('translated-text-editable-pair')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('translated-edit-editable-pair')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('segment-editor-editable-pair')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('translated-field-editable-pair')),
      findsOneWidget,
    );
  });

  testWidgets('review header toggles speaker labels and timestamps', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 620));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 5000,
            endMs: 7000,
            text: 'Original sentence.',
            speaker: '1',
          ),
        ],
        speakers: const [SpeakerProfile(id: '1', name: 'Narrator')],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const speakerToggle = Key('toggle-speaker-labels');
    const timestampToggle = Key('toggle-timestamps');
    const speakerLabel = ValueKey('segment-speaker-segment');
    const timestamp = ValueKey('segment-timestamp-segment');
    expect(
      tester.widget<IconButton>(find.byKey(speakerToggle)).isSelected,
      isTrue,
    );
    expect(
      tester.widget<IconButton>(find.byKey(timestampToggle)).isSelected,
      isFalse,
    );
    expect(tester.widget<IconButton>(find.byKey(speakerToggle)).style, isNull);
    expect(
      tester.widget<IconButton>(find.byKey(timestampToggle)).style,
      isNull,
    );
    expect(find.byKey(speakerLabel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('segment-speaker-dropdown-segment')),
      findsNothing,
    );
    expect(find.byType(SpeakerStrip), findsOneWidget);
    expect(find.byKey(timestamp), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(timestampToggle)).dx -
          tester.getTopRight(find.byKey(speakerToggle)).dx,
      0,
    );

    await tester.tap(find.byKey(speakerToggle));
    await tester.pumpAndSettle();
    expect(controller.settings.showSpeakers, isFalse);
    expect(find.byKey(speakerLabel), findsNothing);
    expect(find.byType(SpeakerStrip), findsNothing);
    expect(
      tester.widget<IconButton>(find.byKey(speakerToggle)).isSelected,
      isFalse,
    );

    await tester.tap(find.byKey(speakerToggle));
    await tester.pumpAndSettle();
    expect(controller.settings.showSpeakers, isTrue);
    expect(find.byKey(speakerLabel), findsOneWidget);
    expect(find.byType(SpeakerStrip), findsOneWidget);

    await tester.tap(find.byKey(timestampToggle));
    await tester.pumpAndSettle();
    expect(controller.settings.showTimestamps, isTrue);
    expect(find.byKey(timestamp), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(timestampToggle)).isSelected,
      isTrue,
    );
  });

  testWidgets('sentence speaker dropdown reassigns only that segment', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 620));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1000,
            text: 'First sentence.',
            speaker: '1',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1000,
            endMs: 2000,
            text: 'Second sentence.',
            speaker: '1',
          ),
          TranscriptSegment(
            id: 'third',
            startMs: 2000,
            endMs: 3000,
            text: 'Third sentence.',
            speaker: '2',
          ),
        ],
        speakers: const [
          SpeakerProfile(id: '1', name: 'Alice'),
          SpeakerProfile(id: '2', name: 'Bob'),
        ],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color? speakerColor(String segmentId) {
      final label = find.descendant(
        of: find.byKey(ValueKey('segment-speaker-$segmentId')),
        matching: find.byType(Text),
      );
      return tester.widget<Text>(label).style?.color;
    }

    final originalFirstColor = speakerColor('first');
    final thirdColor = speakerColor('third');
    expect(originalFirstColor, isNot(thirdColor));
    expect(find.byTooltip('Change speaker'), findsNWidgets(3));

    await tester.tap(
      find.byKey(const ValueKey('segment-speaker-dropdown-first')),
    );
    await tester.pumpAndSettle();

    final aliceOption = find.byKey(
      const ValueKey('segment-speaker-option-first-1'),
    );
    final bobOption = find.byKey(
      const ValueKey('segment-speaker-option-first-2'),
    );
    expect(aliceOption, findsOneWidget);
    expect(bobOption, findsOneWidget);
    expect(tester.widget<MenuItemButton>(aliceOption).onPressed, isNull);
    expect(tester.widget<MenuItemButton>(bobOption).onPressed, isNotNull);

    await tester.tap(bobOption);
    await tester.pumpAndSettle();

    final document = controller.allJobs.single.document!;
    expect(document.segments.first.speaker, '2');
    expect(document.segments[1].speaker, '1');
    expect(document.segments.last.speaker, '2');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('segment-speaker-first')),
        matching: find.text('Bob'),
      ),
      findsOneWidget,
    );
    expect(speakerColor('first'), thirdColor);
  });

  testWidgets('transcript pane toolbar adapts at each breakpoint', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 700));
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Original sentence.',
            translatedText: 'Translated sentence.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'en',
        completedSegments: 1,
        totalSegments: 1,
      ),
      settings: _configuredTranslationAppSettings,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('review-header')), findsOneWidget);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);

    tester.view.physicalSize = const Size(600, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-toggle-speakers')), findsNothing);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsNothing);
    expect(find.byKey(const Key('copy-transcript-menu')), findsNothing);
    expect(find.byKey(const Key('export-transcript-menu')), findsNothing);
    expect(
      find.byKey(const Key('translation-mode-original-menu')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(500, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsNothing);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const Key('translation-mode-original-menu')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('translation-mode-translated-menu')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('translation-mode-bilingual-menu')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('focus-current-menu')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Chinese toolbar stays aligned and keeps focus visible', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(600, 700));
    final controller = await _controllerForDocument(_simpleDocument());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tabs = find.byKey(const Key('review-content-tabs'));
    final transcriptLabel = tester.widget<Text>(
      find.descendant(of: tabs, matching: find.text('转写')),
    );
    final aiBriefLabel = tester.widget<Text>(
      find.descendant(of: tabs, matching: find.text('AI 简报')),
    );
    expect(transcriptLabel.maxLines, 1);
    expect(transcriptLabel.softWrap, isFalse);
    expect(transcriptLabel.overflow, isNull);
    expect(aiBriefLabel.maxLines, 1);
    expect(aiBriefLabel.softWrap, isFalse);
    expect(aiBriefLabel.overflow, isNull);
    expect(
      find.descendant(of: tabs, matching: find.byIcon(Icons.subject_rounded)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: tabs,
        matching: find.byIcon(Icons.auto_awesome_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: tabs,
        matching: find.byIcon(Icons.auto_awesome_outlined),
      ),
      findsNothing,
    );
    expect(
      tester.getCenter(find.descendant(of: tabs, matching: find.text('转写'))).dy,
      closeTo(
        tester
            .getCenter(find.descendant(of: tabs, matching: find.text('AI 简报')))
            .dy,
        1,
      ),
    );
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);

    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('focus-current-menu')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long review filename ellipsizes without moving centered tabs', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(600, 700));
    const fileName =
        'a-very-long-recording-name-that-must-not-move-the-document-tabs.mp4';
    final controller = await _controllerForDocument(
      _simpleDocument(),
      sourcePath: '/missing/$fileName',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final filenameFinder = find.byKey(const Key('review-filename'));
    expect(
      find.descendant(
        of: find.byKey(const Key('transcript-pane-header')),
        matching: filenameFinder,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('review-header')),
        matching: filenameFinder,
      ),
      findsNothing,
    );
    final filename = tester.widget<Text>(filenameFinder);
    expect(filename.data, fileName);
    expect(filename.maxLines, 1);
    expect(filename.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(of: filenameFinder, matching: find.byType(Tooltip)),
          )
          .message,
      fileName,
    );
    expect(
      (tester.renderObject(filenameFinder) as RenderParagraph)
          .didExceedMaxLines,
      isTrue,
    );
    expect(
      tester.getCenter(find.byKey(const Key('review-content-tabs'))).dx,
      closeTo(tester.getCenter(find.byKey(const Key('review-header'))).dx, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('review omits transcript segments with empty source content', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'visible',
            startMs: 0,
            endMs: 1000,
            text: 'Visible source.',
            translatedText: '可见译文。',
          ),
          TranscriptSegment(id: 'empty', startMs: 1000, endMs: 2000, text: ''),
        ],
        speakers: const [],
        updatedAt: now,
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('segment-card-empty')), findsNothing);
    await _selectTranslationView(tester, 'Translated');
    expect(find.text('可见译文。'), findsOneWidget);
    expect(find.byKey(const ValueKey('translated-empty')), findsNothing);
  });

  testWidgets('saving a speaker name closes the dialog without crashing', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'job',
          batchId: 'batch',
          sourcePath: '/missing/test.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'segment',
                startMs: 0,
                endMs: 1000,
                text: 'Hello',
                speaker: '1',
              ),
            ],
            speakers: const [SpeakerProfile(id: '1', name: 'Speaker 1')],
            updatedAt: now,
          ),
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: Consumer<AppController>(
              builder: (context, controller, _) {
                final job = controller.allJobs.single;
                return SpeakerStrip(job: job, document: job.document!);
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ActionChip, 'Speaker 1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Rocky');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.allJobs.single.document!.speakers.single.name, 'Rocky');
  });

  testWidgets('enter saves the edited speaker name', (tester) async {
    final controller = await _pumpSpeakerStrip(tester);
    addTearDown(controller.dispose);

    await tester.tap(find.widgetWithText(ActionChip, 'Speaker 1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('speaker-name-field')),
      'Rocky',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.allJobs.single.document!.speakers.single.name, 'Rocky');
  });

  testWidgets('speaker number is centered in its avatar', (tester) async {
    final controller = await _pumpSpeakerStrip(tester);
    addTearDown(controller.dispose);

    final avatar = find.byKey(const ValueKey('speaker-avatar-1'));
    final number = find.text('1');

    expect(tester.getSize(avatar), const Size.square(18));
    expect(tester.getCenter(number).dx, tester.getCenter(avatar).dx);
    expect(tester.getCenter(number).dy, tester.getCenter(avatar).dy);
  });

  testWidgets('speaker controls have breathing room above', (tester) async {
    final controller = await _pumpSpeakerStrip(tester);
    addTearDown(controller.dispose);

    final stripTop = tester.getTopLeft(find.byType(SpeakerStrip)).dy;
    final chipTop = tester.getTopLeft(find.byType(ActionChip)).dy;

    expect(chipTop - stripTop, greaterThanOrEqualTo(12));
  });

  testWidgets('speaker strip is horizontal and transcript list is vertical', (
    tester,
  ) async {
    final controller = await _pumpSpeakerStrip(tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );

    expect(
      tester
          .widget<ListView>(find.byKey(const Key('speaker-strip-scroll')))
          .scrollDirection,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<ScrollablePositionedList>(
            find.byKey(const Key('transcript-scroll')),
          )
          .scrollDirection,
      Axis.vertical,
    );

    final job = controller.allJobs.single;
    final manySpeakers = job.document!.copyWith(
      speakers: List.generate(
        12,
        (index) =>
            SpeakerProfile(id: '${index + 1}', name: 'Speaker ${index + 1}'),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: SpeakerStrip(job: job, document: manySpeakers),
              ),
            ),
          ),
        ),
      ),
    );
    final scrollable = find.descendant(
      of: find.byKey(const Key('speaker-strip-scroll')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(
      find.byKey(const Key('speaker-strip-scroll')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('metadata and trailing actions align with sentence text', (
    tester,
  ) async {
    const segment = TranscriptSegment(
      id: 'aligned',
      startMs: 2000,
      endMs: 4000,
      text: 'First transcript line',
      speaker: '1',
    );

    Future<void> pump({required bool showSpeaker, bool showTimestamp = true}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TranscriptSegmentEditor(
                segment: segment,
                tokens: const [],
                positionMs: 0,
                isCurrent: false,
                query: '',
                speakerName: 'Speaker 1',
                showSpeaker: showSpeaker,
                showTimestamp: showTimestamp,
                isEditing: false,
                onSeek: _noopSegmentSeek,
                onEdit: () {},
                onCancel: () {},
                onSave: (_) async {},
              ),
            ),
          ),
        );

    await pump(showSpeaker: true);
    var transcriptText = find.descendant(
      of: find.byKey(const ValueKey('segment-text-aligned')),
      matching: find.byType(RichText),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dy,
      closeTo(
        tester
            .getTopLeft(find.byKey(const ValueKey('segment-speaker-aligned')))
            .dy,
        1,
      ),
    );
    final timestampLabel = find.descendant(
      of: find.byKey(const ValueKey('segment-timestamp-aligned')),
      matching: find.byType(Text),
    );
    final speakerLabel = find.descendant(
      of: find.byKey(const ValueKey('segment-speaker-aligned')),
      matching: find.byType(Text),
    );
    expect(
      tester.widget<Text>(speakerLabel).style?.fontSize,
      tester.widget<Text>(timestampLabel).style?.fontSize,
    );
    expect(
      tester.getTopLeft(speakerLabel).dy,
      closeTo(tester.getTopLeft(timestampLabel).dy, 1),
    );
    expect(
      tester.getCenter(speakerLabel).dy,
      closeTo(tester.getCenter(timestampLabel).dy, 1),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('segment-repeat-aligned'))).dy,
      closeTo(tester.getCenter(transcriptText).dy, 2),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dx,
      closeTo(tester.getTopLeft(transcriptText).dx, 1),
    );

    await pump(showSpeaker: false);
    transcriptText = find.descendant(
      of: find.byKey(const ValueKey('segment-text-aligned')),
      matching: find.byType(RichText),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('segment-repeat-aligned'))).dy,
      closeTo(tester.getCenter(transcriptText).dy, 2),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('segment-repeat-aligned')))
            .dy,
      ),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dx,
      closeTo(tester.getTopLeft(transcriptText).dx, 1),
    );
    final timestampedSentenceLeft = tester.getTopLeft(transcriptText).dx;

    await pump(showSpeaker: false, showTimestamp: false);
    transcriptText = find.descendant(
      of: find.byKey(const ValueKey('segment-text-aligned')),
      matching: find.byType(RichText),
    );
    expect(
      tester.getTopLeft(transcriptText).dx,
      closeTo(timestampedSentenceLeft, 1),
    );
  });

  testWidgets('speaker labels use stable distinct colors', (tester) async {
    const segments = [
      TranscriptSegment(
        id: 'first',
        startMs: 0,
        endMs: 1000,
        text: 'First speaker',
        speaker: '1',
      ),
      TranscriptSegment(
        id: 'second',
        startMs: 1000,
        endMs: 2000,
        text: 'Second speaker',
        speaker: '2',
      ),
      TranscriptSegment(
        id: 'first-again',
        startMs: 2000,
        endMs: 3000,
        text: 'First speaker again',
        speaker: '1',
      ),
    ];

    Widget editor(TranscriptSegment segment) => TranscriptSegmentEditor(
      segment: segment,
      tokens: const [],
      positionMs: 0,
      isCurrent: false,
      query: '',
      speakerName: 'Speaker ${segment.speaker}',
      showSpeaker: true,
      showTimestamp: false,
      isEditing: false,
      onSeek: _noopSegmentSeek,
      onEdit: () {},
      onCancel: () {},
      onSave: (_) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Column(children: segments.map(editor).toList())),
      ),
    );

    Color? speakerColor(String segmentId) {
      final label = find.descendant(
        of: find.byKey(ValueKey('segment-speaker-$segmentId')),
        matching: find.byType(Text),
      );
      return tester.widget<Text>(label).style?.color;
    }

    expect(speakerColor('first'), isNot(speakerColor('second')));
    expect(speakerColor('first-again'), speakerColor('first'));
  });

  testWidgets(
    'current word highlights at its start and follows backward seeks',
    (tester) async {
      const tokens = [
        TranscriptToken(text: 'Hello', startMs: 0, endMs: 900),
        TranscriptToken(text: ' world', startMs: 1000, endMs: 1800),
      ];

      Future<void> pump(int positionMs) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackHighlightedText(
              text: 'Hello world',
              tokens: tokens,
              positionMs: positionMs,
              segmentStartMs: 0,
              segmentEndMs: 2000,
            ),
          ),
        ),
      );

      await pump(999);
      expect(_backgroundTexts(tester), ['Hello']);

      await pump(1000);
      expect(_backgroundTexts(tester), ['world']);

      await pump(500);
      expect(_backgroundTexts(tester), ['Hello']);
    },
  );

  testWidgets('edited text keeps current-word timing aligned', (tester) async {
    const tokens = [
      TranscriptToken(text: 'Hello', startMs: 100, endMs: 800),
      TranscriptToken(text: ' world', startMs: 900, endMs: 1700),
    ];

    Future<void> pump(int positionMs) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackHighlightedText(
            text: 'Hello brave world',
            tokens: tokens,
            positionMs: positionMs,
            segmentStartMs: 100,
            segmentEndMs: 1800,
          ),
        ),
      ),
    );

    await pump(900);
    expect(_backgroundTexts(tester), ['world']);

    await pump(1800);
    expect(_backgroundTexts(tester), isEmpty);
  });

  testWidgets('Structure mode previews, commits, and undoes a snapped split', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late _ReviewFakePlatformPlayer platform;
    debugTranscriptReviewPlayerFactory = () =>
        Player(platformPlayer: platform = _ReviewFakePlatformPlayer());
    debugTranscriptReviewSourceExists = (_) async => true;
    addTearDown(() {
      debugTranscriptReviewPlayerFactory = null;
      debugTranscriptReviewSourceExists = null;
    });
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [
          TranscriptToken(
            text: 'Hello',
            startMs: 100,
            endMs: 400,
            segmentId: 'segment',
          ),
          TranscriptToken(
            text: ' world.',
            startMs: 600,
            endMs: 900,
            segmentId: 'segment',
          ),
        ],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Hello world.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      sourcePath: '/fake/structure.mp4',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle-transcript-structure')));
    await tester.pump();
    final splitSurface = find.byKey(const ValueKey('structure-split-segment'));
    expect(splitSurface, findsOneWidget);

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(splitSurface));
    await pointer.moveTo(tester.getCenter(splitSurface));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('structure-split-preview-segment')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('segment-edit-segment')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('segment-editor-segment')),
      findsOneWidget,
    );
    expect(splitSurface, findsNothing);
    await tester.tap(find.byKey(const ValueKey('segment-cancel-segment')));
    await tester.pump();
    expect(splitSurface, findsOneWidget);

    await pointer.moveTo(tester.getCenter(splitSurface));
    await tester.pump();

    await pointer.down(tester.getCenter(splitSurface));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(2));
    expect(
      controller.jobById('job')!.document!.segments.last.preserveBoundaryBefore,
      isTrue,
    );
    final notice = find.byKey(const ValueKey('transcript-structure-notice'));
    expect(notice, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final transcriptPane = find.byKey(const Key('transcript-pane'));
    expect(
      tester.getBottomRight(notice).dx,
      lessThanOrEqualTo(tester.getBottomRight(transcriptPane).dx),
    );
    expect(
      tester.getBottomRight(notice).dy,
      lessThan(tester.getBottomRight(transcriptPane).dy),
    );
    expect(platform.pauseCalls, greaterThanOrEqualTo(1));
    expect(platform.seekDurations, contains(const Duration(milliseconds: 600)));

    await tester.tap(find.byKey(const Key('transcript-structure-notice-undo')));
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(1));
    expect(notice, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(2));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(1));

    await pointer.moveTo(tester.getCenter(splitSurface));
    await tester.pump();
    await pointer.down(tester.getCenter(splitSurface));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(2));
    expect(notice, findsOneWidget);
    await tester.tap(
      find.byKey(const Key('dismiss-transcript-structure-notice')),
    );
    await tester.pumpAndSettle();
    expect(notice, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(1));

    await pointer.moveTo(tester.getCenter(splitSurface));
    await tester.pump();
    await pointer.down(tester.getCenter(splitSurface));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 200));
    expect(notice, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(1));

    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    expect(find.byKey(const Key('transcript-search-field')), findsOneWidget);
    expect(splitSurface, findsNothing);
  });

  testWidgets('Structure mode exposes valid and forbidden merge gaps', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 500,
            text: 'First.',
            speaker: 'one',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 600,
            endMs: 1000,
            text: 'Second.',
            speaker: 'two',
          ),
          TranscriptSegment(
            id: 'third',
            startMs: 1100,
            endMs: 1500,
            text: 'Third.',
            speaker: 'two',
          ),
        ],
        speakers: const [
          SpeakerProfile(id: 'one', name: 'One'),
          SpeakerProfile(id: 'two', name: 'Two'),
        ],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toggle-transcript-structure')));
    await tester.pump();

    final forbidden = find.byKey(const ValueKey('structure-merge-first'));
    final valid = find.byKey(const ValueKey('structure-merge-second'));
    expect(forbidden, findsOneWidget);
    expect(valid, findsOneWidget);
    expect(
      tester
          .widget<MouseRegion>(
            find.descendant(of: forbidden, matching: find.byType(MouseRegion)),
          )
          .cursor,
      SystemMouseCursors.forbidden,
    );

    await tester.tap(forbidden);
    await tester.pump();
    expect(controller.jobById('job')!.document!.segments, hasLength(3));
    await tester.tap(valid);
    await tester.pumpAndSettle();
    expect(controller.jobById('job')!.document!.segments, hasLength(2));
    expect(
      controller.jobById('job')!.document!.segments.last.text,
      'Second. Third.',
    );
  });

  testWidgets('sub-word timing highlights the enclosing whole word', (
    tester,
  ) async {
    const tokens = [
      TranscriptToken(text: 'many skill', startMs: 100, endMs: 250),
      TranscriptToken(text: 's', startMs: 300, endMs: 450),
      TranscriptToken(text: ': beautifu', startMs: 500, endMs: 650),
      TranscriptToken(text: 'l', startMs: 700, endMs: 850),
    ];

    Future<void> pump(int positionMs) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackHighlightedText(
            text: 'many skills: beautiful',
            tokens: tokens,
            positionMs: positionMs,
            segmentStartMs: 100,
            segmentEndMs: 900,
          ),
        ),
      ),
    );

    await pump(300);
    expect(_backgroundTexts(tester), ['skills']);

    await pump(700);
    expect(_backgroundTexts(tester), ['beautiful']);
  });

  testWidgets(
    'punctuation timing keeps the word highlighted without punctuation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlaybackHighlightedText(
              text: '你好，世界',
              tokens: [
                TranscriptToken(text: '你好', startMs: 1, endMs: 400),
                TranscriptToken(text: '，', startMs: 401, endMs: 500),
                TranscriptToken(text: '世界', startMs: 501, endMs: 900),
              ],
              positionMs: 401,
              segmentStartMs: 1,
              segmentEndMs: 1000,
            ),
          ),
        ),
      );

      expect(_backgroundTexts(tester), ['你好']);
    },
  );

  testWidgets('punctuation attached to a timed word is not highlighted', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackHighlightedText(
            text: 'A busy city, today.',
            tokens: [
              TranscriptToken(text: 'A busy ', startMs: 1, endMs: 300),
              TranscriptToken(text: 'city,', startMs: 301, endMs: 600),
              TranscriptToken(text: ' today.', startMs: 601, endMs: 900),
            ],
            positionMs: 301,
            segmentStartMs: 1,
            segmentEndMs: 1000,
          ),
        ),
      ),
    );

    expect(_backgroundTexts(tester), ['city']);
  });

  testWidgets('invalid word timing falls back to card-only playback state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackHighlightedText(
            text: 'Untimed',
            tokens: [TranscriptToken(text: 'Untimed', startMs: 0, endMs: 0)],
            positionMs: 500,
            segmentStartMs: 0,
            segmentEndMs: 1000,
          ),
        ),
      ),
    );

    expect(_backgroundTexts(tester), isEmpty);
  });

  testWidgets('segment-owned tied timing at zero remains highlightable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackHighlightedText(
            text: '日本',
            tokens: [
              TranscriptToken(
                text: '日',
                startMs: 0,
                endMs: 0,
                segmentId: 'one',
              ),
              TranscriptToken(
                text: '本',
                startMs: 80,
                endMs: 160,
                segmentId: 'one',
              ),
            ],
            positionMs: 0,
            segmentStartMs: 0,
            segmentEndMs: 200,
          ),
        ),
      ),
    );

    expect(_backgroundTexts(tester), ['日']);
  });

  testWidgets('current sentences keep a bar without a fill', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: brightness,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: TranscriptSegmentEditor(
              segment: const TranscriptSegment(
                id: 'themed',
                startMs: 100,
                endMs: 1000,
                text: 'Themed text',
              ),
              tokens: const [
                TranscriptToken(text: 'Themed', startMs: 100, endMs: 400),
                TranscriptToken(text: ' text', startMs: 500, endMs: 800),
              ],
              positionMs: 200,
              isCurrent: true,
              query: '',
              speakerName: '',
              showSpeaker: false,
              showTimestamp: true,
              isEditing: false,
              onSeek: _noopSegmentSeek,
              onEdit: () {},
              onCancel: () {},
              onSave: (_) async {},
            ),
          ),
        ),
      );

      final card = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('segment-card-themed')),
      );
      final decoration = card.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.color, isNull);
      expect(_backgroundTexts(tester), ['Themed']);
    }
  });

  testWidgets('single-line transcript rows keep compact vertical spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              TranscriptSegmentEditor(
                segment: const TranscriptSegment(
                  id: 'compact',
                  startMs: 100,
                  endMs: 1000,
                  text: 'One compact transcript line.',
                ),
                tokens: const [],
                positionMs: 0,
                isCurrent: false,
                query: '',
                speakerName: '',
                showSpeaker: false,
                showTimestamp: false,
                isEditing: false,
                onSeek: _noopSegmentSeek,
                onEdit: () {},
                onCancel: () {},
                onSave: (_) async {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('segment-card-compact'))).height,
      lessThanOrEqualTo(48),
    );
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsNothing);
    expect(
      find.byKey(const ValueKey('segment-repeat-compact')),
      findsOneWidget,
    );
  });

  testWidgets('played-word selection clears when the next sentence starts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptSegmentEditor(
            segment: const TranscriptSegment(
              id: 'played',
              startMs: 0,
              endMs: 1000,
              text: 'Already played',
            ),
            tokens: const [
              TranscriptToken(text: 'Already played', startMs: 1, endMs: 900),
            ],
            positionMs: 2000,
            isCurrent: false,
            query: '',
            speakerName: '',
            showSpeaker: false,
            showTimestamp: true,
            isEditing: false,
            onSeek: _noopSegmentSeek,
            onEdit: () {},
            onCancel: () {},
            onSave: (_) async {},
          ),
        ),
      ),
    );

    expect(_backgroundTexts(tester), isEmpty);
  });

  testWidgets('read-only sentences seek in playback and search views', (
    tester,
  ) async {
    var seeks = 0;

    Future<void> pump(String query) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: TranscriptSegmentEditor(
              segment: const TranscriptSegment(
                id: 'seekable',
                startMs: 1200,
                endMs: 2400,
                text: 'Seekable sentence',
              ),
              tokens: const [],
              positionMs: 0,
              isCurrent: false,
              query: query,
              speakerName: '',
              showSpeaker: false,
              showTimestamp: true,
              isEditing: false,
              onSeek: ({required reason}) => seeks++,
              onEdit: () {},
              onCancel: () {},
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );

    const textKey = ValueKey('segment-text-seekable');
    await pump('');
    await tester.tap(find.byKey(textKey));
    expect(seeks, 1);

    final bounds = tester.getRect(find.byKey(textKey));
    final selection = await tester.startGesture(
      bounds.centerLeft + const Offset(8, 0),
      kind: PointerDeviceKind.mouse,
    );
    await selection.moveTo(bounds.centerRight - const Offset(8, 0));
    await selection.up();
    await tester.pump();
    expect(seeks, 1);

    await pump('seekable');
    await tester.tap(find.byKey(textKey));
    expect(seeks, 2);
  });

  testWidgets('sentence cards are read-only until hover edit is selected', (
    tester,
  ) async {
    final saved = <String>[];
    var seeks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: _EditorHarness(onSaved: saved.add, onSeek: () => seeks++),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    final editOpacity = find.byKey(
      const ValueKey('segment-edit-opacity-editable'),
    );
    final repeatOpacity = find.byKey(
      const ValueKey('segment-repeat-opacity-editable'),
    );
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-editable'))),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 1);

    await tester.tap(find.byKey(const ValueKey('segment-edit-editable')));
    await tester.pump();
    final editor = find.byKey(const ValueKey('segment-editor-editable'));
    final cancel = find.byKey(const ValueKey('segment-cancel-editable'));
    final save = find.byKey(const ValueKey('segment-save-editable'));
    expect(editor, findsOneWidget);
    expect(tester.getCenter(cancel).dx, lessThan(tester.getCenter(save).dx));
    expect(tester.getCenter(cancel).dy, closeTo(tester.getCenter(save).dy, 1));
    await tester.enterText(editor, 'Unsaved draft');
    await tester.tap(cancel);
    await tester.pump();
    expect(find.text('Original sentence'), findsOneWidget);
    expect(saved, isEmpty);

    await tester.tap(find.byKey(const ValueKey('segment-edit-editable')));
    await tester.pump();
    await tester.enterText(editor, 'Saved sentence');
    await tester.tap(find.byKey(const ValueKey('segment-save-editable')));
    await tester.pump();
    expect(saved, ['Saved sentence']);
    expect(find.text('Saved sentence'), findsOneWidget);
    expect(seeks, 0);
  });

  testWidgets('sentence repeat and edit appear on hover', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _RepeatEditorHarness())),
    );

    const cardKey = ValueKey('segment-card-repeatable');
    const repeatKey = ValueKey('segment-repeat-repeatable');
    final card = find.byKey(cardKey);
    final repeat = find.byKey(repeatKey);
    final edit = find.byKey(const ValueKey('segment-edit-repeatable'));
    final sentenceInk = tester.widget<InkWell>(
      find.byKey(const ValueKey('segment-text-repeatable')),
    );
    final editOpacity = find.byKey(
      const ValueKey('segment-edit-opacity-repeatable'),
    );
    final repeatOpacity = find.byKey(
      const ValueKey('segment-repeat-opacity-repeatable'),
    );
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 0);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsNothing);
    expect(tester.widget<IconButton>(repeat).isSelected, isFalse);
    expect(tester.getCenter(repeat).dx, lessThan(tester.getCenter(edit).dx));
    expect(
      (tester.widget<DecoratedBox>(card).decoration as BoxDecoration).color,
      isNull,
    );
    expect(sentenceInk.hoverColor, Colors.transparent);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 1);
    expect(
      (tester.widget<DecoratedBox>(card).decoration as BoxDecoration).color,
      Theme.of(tester.element(card)).colorScheme.surfaceContainerLow,
    );

    await tester.tap(repeat);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(repeat).isSelected, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(editOpacity).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 1);

    await tester.tap(repeat);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(repeat).isSelected, isFalse);
    expect(tester.widget<AnimatedOpacity>(repeatOpacity).opacity, 0);
  });

  testWidgets('unavailable sentence repeat is disabled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptSegmentEditor(
            segment: const TranscriptSegment(
              id: 'invalid-repeat',
              startMs: 500,
              endMs: 500,
              text: 'No timing range',
            ),
            tokens: const [],
            positionMs: 0,
            isCurrent: false,
            query: '',
            speakerName: '',
            showSpeaker: false,
            showTimestamp: false,
            isEditing: false,
            onSeek: _noopSegmentSeek,
            onEdit: _noop,
            onCancel: _noop,
            onSave: (_) async {},
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('segment-repeat-invalid-repeat')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('active sentence repeat remains accessible while editing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _RepeatEditorHarness())),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-repeatable'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-repeat-repeatable')));
    await tester.tap(find.byKey(const ValueKey('segment-edit-repeatable')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('segment-editor-repeatable')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('segment-repeat-repeatable')),
          )
          .isSelected,
      isTrue,
    );
  });

  testWidgets('editor keyboard shortcuts save and cancel drafts', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _EditorHarness(onSaved: saved.add, onSeek: () {}),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-editable'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-edit-editable')));
    await tester.pump();
    final editor = find.byKey(const ValueKey('segment-editor-editable'));
    await tester.enterText(editor, 'Cancelled by keyboard');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Original sentence'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('segment-edit-editable')));
    await tester.pump();
    await tester.enterText(editor, 'Saved by keyboard');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(saved, ['Saved by keyboard']);
  });

  testWidgets('app sidebar toggle hides and restores navigation', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => call.method == 'isFullScreen' ? false : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateSettings(
      controller.settings.copyWith(onboardingComplete: true),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final windowToolbar = find.byKey(const Key('app-window-toolbar'));
    final sidebarToggle = find.byKey(const Key('toggle-app-sidebar'));
    expect(windowToolbar, findsOneWidget);
    expect(
      find.descendant(of: windowToolbar, matching: sidebarToggle),
      findsOneWidget,
    );
    final platform = Theme.of(tester.element(windowToolbar)).platform;
    if (platform == TargetPlatform.macOS) {
      expect(
        tester.getCenter(find.byKey(const Key('macos-traffic-light-space'))).dx,
        lessThan(tester.getCenter(sidebarToggle).dx),
      );
    } else if (platform == TargetPlatform.windows) {
      expect(
        tester.getCenter(find.byKey(const Key('windows-app-icon'))).dx,
        lessThan(tester.getCenter(sidebarToggle).dx),
      );
      expect(find.byKey(const Key('window-close')), findsOneWidget);
    }
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    final inboxFab = find.byKey(const Key('inbox-fab'));
    expect(inboxFab, findsOneWidget);
    final inboxFabWidget = tester.widget<FloatingActionButton>(inboxFab);
    final inboxFabColors = Theme.of(tester.element(inboxFab)).colorScheme;
    expect(inboxFabWidget.isExtended, isTrue);
    expect(
      inboxFabWidget.backgroundColor,
      inboxFabColors.surfaceContainerHighest,
    );
    expect(inboxFabWidget.foregroundColor, inboxFabColors.primary);
    expect(inboxFabWidget.elevation, 0);
    expect(tester.getSize(inboxFab).height, 44);
    expect(controller.destination, AppDestination.podcast);
    final sidebar = find.byKey(const Key('app-sidebar'));
    final settingsNavigation = find.byKey(
      const Key('settings-navigation-button'),
    );
    final settingsIndicator = find.byKey(
      const Key('settings-navigation-indicator'),
    );
    final navigationRail = tester.widget<NavigationRail>(
      find.byType(NavigationRail),
    );
    expect(navigationRail.minExtendedWidth, 184);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('workspace-navigation-label')))
          .maxLines,
      1,
    );
    final settingsLabel = tester.widget<Text>(
      find.descendant(of: settingsNavigation, matching: find.text('Settings')),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('workspace-navigation-label')))
          .style
          ?.fontSize,
      settingsLabel.style?.fontSize,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('library-navigation-label')))
          .style
          ?.fontSize,
      settingsLabel.style?.fontSize,
    );
    expect(tester.getSize(sidebar).width, lessThanOrEqualTo(218));
    expect(tester.getSize(settingsIndicator).width, 56);
    expect(
      tester.getSize(settingsIndicator).width,
      lessThan(tester.getSize(settingsNavigation).width),
    );
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(
      tester.getBottomLeft(sidebar).dy -
          tester.getBottomLeft(settingsNavigation).dy,
      lessThanOrEqualTo(12),
    );
    expect(
      tester.getTopLeft(settingsNavigation).dy,
      greaterThan(tester.getBottomLeft(find.text('Library')).dy),
    );
    final tooltipMessages = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((tooltip) => tooltip.message);
    expect(
      tooltipMessages,
      containsAll([
        'Inbox (⌘I)',
        'Podcast (⌘1)',
        'Workspace (⌘2)',
        'Library (⌘3)',
        'Settings (⌘,)',
      ]),
    );
    expect(
      tester.widget<IconButton>(sidebarToggle).tooltip,
      'Hide sidebar (⌘B)',
    );

    await tester.tap(inboxFab);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.inbox);

    tester.view.physicalSize = const Size(1000, 820);
    await tester.pumpAndSettle();
    expect(tester.widget<FloatingActionButton>(inboxFab).isExtended, isFalse);
    tester.view.physicalSize = const Size(1240, 820);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.library);
    expect(find.byKey(const Key('library-page-title')), findsNothing);
    expect(find.byKey(const Key('library-search')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.settings);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);
    await tester.tap(find.text('Transcription'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('soniox-key-field')));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.inbox);
    expect(find.byKey(const Key('inbox-page-title')), findsNothing);
    expect(find.byKey(const Key('empty-add-files')), findsOneWidget);

    await messenger.handlePlatformMessage(
      'app.capyvibe.listenook/navigation',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('showSettings'),
      ),
      null,
    );
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.settings);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await messenger.handlePlatformMessage(
      'app.capyvibe.listenook/navigation',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('showInbox'),
      ),
      null,
    );
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.inbox);

    controller.setDestination(AppDestination.library);
    await tester.pumpAndSettle();
    await messenger.handlePlatformMessage(
      'app.capyvibe.listenook/navigation',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('showWindow'),
      ),
      null,
    );
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.library);

    await tester.tap(settingsNavigation);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.settings);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.inbox);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(settingsNavigation));
    await tester.pump(const Duration(seconds: 1));
    expect(
      (tester.widget<AnimatedContainer>(settingsIndicator).decoration
              as BoxDecoration)
          .color,
      isNotNull,
    );
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: settingsNavigation,
              matching: find.byType(InkWell),
            ),
          )
          .hoverColor,
      Colors.transparent,
    );
    await mouse.moveTo(
      tester.getCenter(find.byIcon(Icons.space_dashboard_outlined)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Workspace (⌘2)'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(sidebarToggle));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Hide sidebar (⌘B)'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar-hidden')), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      tester.widget<IconButton>(sidebarToggle).tooltip,
      'Show sidebar (⌘B)',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);

    await tester.tap(sidebarToggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar-hidden')), findsOneWidget);

    await tester.tap(sidebarToggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);

    final dynamic appShellState = tester.state(find.byType(AppShell));
    appShellState.onWindowEnterFullScreen();
    await tester.pump();
    expect(windowToolbar, findsNothing);
    expect(
      find.byKey(const Key('app-window-toolbar-fullscreen-hidden')),
      findsOneWidget,
    );

    appShellState.onWindowLeaveFullScreen();
    await tester.pump();
    expect(windowToolbar, findsOneWidget);
  });

  testWidgets('collapsing the app sidebar preserves transcript pane width', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => call.method == 'isFullScreen' ? false : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
      settings: const AppSettings(onboardingComplete: true),
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final transcript = find.byKey(const Key('video-review-transcript-pane'));
    final media = find.byKey(const Key('video-review-media-pane'));
    final transcriptWidth = tester.getSize(transcript).width;
    final mediaWidth = tester.getSize(media).width;

    await tester.tap(find.byKey(const Key('toggle-app-sidebar')));
    await tester.pumpAndSettle();

    expect(tester.getSize(transcript).width, closeTo(transcriptWidth, 1));
    expect(tester.getSize(media).width, greaterThan(mediaWidth));
  });

  testWidgets(
    'window close runs cleanup concurrently before allowing native close',
    (tester) async {
      const windowChannel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = <String>[];
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'isFullScreen') return false;
        if (call.method == 'setPreventClose') {
          final arguments = call.arguments as Map<Object?, Object?>;
          events.add('prevent:${arguments['isPreventClose']}');
        }
        if (call.method == 'destroy') events.add('destroy');
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: _Jobs([]),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.updateSettings(
        controller.settings.copyWith(onboardingComplete: true),
      );
      await controller.setDesktopTrayIconVisible(false);
      final reviewController = ReviewFullscreenController();
      final podcastRepository = _PlaybackFlushRepository(events);
      final podcastPlayer = PodcastPlayer(repository: podcastRepository);
      final podcastController = PodcastController(
        gateway: MemoryPodcastGateway(),
        repository: podcastRepository,
        player: podcastPlayer,
      );
      addTearDown(podcastPlayer.dispose);
      addTearDown(podcastController.dispose);
      await podcastController.initialize();
      final mediaReleased = Completer<void>();
      final mediaOwner = Object();
      reviewController.registerMediaShutdown(mediaOwner, () async {
        events.add('media-start');
        await mediaReleased.future;
        events.add('media-done');
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: podcastController),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [AppStrings.delegate],
            home: AppShell(reviewController: reviewController),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(events, ['prevent:true']);
      events.clear();

      final dynamic appShellState = tester.state(find.byType(AppShell));
      final close = appShellState.onWindowClose() as Future<void>;
      await tester.pump();
      expect(events, ['media-start', 'podcast-save']);

      mediaReleased.complete();
      await close;
      expect(events, [
        'media-start',
        'podcast-save',
        'media-done',
        'prevent:false',
        'destroy',
      ]);

      await appShellState.onWindowClose();
      expect(events, [
        'media-start',
        'podcast-save',
        'media-done',
        'prevent:false',
        'destroy',
      ]);
    },
  );

  testWidgets('Open Main Window tray action preserves the current tab', (
    tester,
  ) async {
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => switch (call.method) {
        'isFullScreen' => false,
        'isVisible' => true,
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateSettings(
      controller.settings.copyWith(onboardingComplete: true),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setDestination(AppDestination.library);

    final dynamic appShellState = tester.state(find.byType(AppShell));
    appShellState.onTrayMenuItemClick(
      tray.MenuItem(key: 'open-main-window', label: 'Open Main Window'),
    );
    await tester.pumpAndSettle();

    expect(controller.destination, AppDestination.library);
  });

  testWidgets(
    'menu bar item and close-to-menu-bar work without an Inbox folder',
    (tester) async {
      const windowChannel = MethodChannel('window_manager');
      const trayChannel = MethodChannel('tray_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = <String>[];
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'isFullScreen') return false;
        if (call.method == 'isVisible') return true;
        if (call.method == 'setPreventClose') {
          final arguments = call.arguments as Map<Object?, Object?>;
          events.add('prevent:${arguments['isPreventClose']}');
        }
        if (call.method == 'setSkipTaskbar') events.add('skip-taskbar');
        if (call.method == 'hide') events.add('hide');
        if (call.method == 'destroy') events.add('destroy');
        return null;
      });
      messenger.setMockMethodCallHandler(trayChannel, (call) async {
        events.add('tray:${call.method}');
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(trayChannel, null));
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: _Jobs([]),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.updateSettings(
        controller.settings.copyWith(onboardingComplete: true),
      );
      await controller.setDesktopTrayIconVisible(false);
      expect(controller.inboxMonitorConfigured, isFalse);
      expect(controller.inboxMonitorConfig.showTrayIcon, isFalse);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(events, isNot(contains('tray:setIcon')));

      await controller.setDesktopTrayIconVisible(true);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(events, contains('tray:setIcon'));
      events.clear();

      if (Platform.isWindows) {
        await messenger.handlePlatformMessage(
          'tray_manager',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onTrayIconRightMouseDown'),
          ),
          null,
        );
        await tester.pump();
        expect(events, contains('tray:popUpContextMenu'));
        events.clear();
      }

      final dynamic appShellState = tester.state(find.byType(AppShell));
      await appShellState.onWindowClose();

      expect(events, containsAllInOrder(['skip-taskbar', 'hide']));
      expect(events, isNot(contains('destroy')));
      expect(events, isNot(contains('prevent:false')));

      events.clear();
      await controller.setDesktopTrayIconVisible(false);
      await tester.pump();
      await appShellState.onWindowClose();

      expect(events, containsAllInOrder(['prevent:false', 'destroy']));
      expect(events, isNot(contains('hide')));
    },
  );

  testWidgets('playback position is restored after switching app tabs', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => call.method == 'isFullScreen' ? false : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final now = DateTime.now().toUtc();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1000,
            text: 'First sentence.',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1400,
            endMs: 2400,
            text: 'Second sentence.',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      ),
      settings: const AppSettings(onboardingComplete: true),
    );
    addTearDown(controller.dispose);
    controller
      ..openInWorkspace('job')
      ..rememberPlaybackPosition('job', const Duration(milliseconds: 1600));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstReviewState = tester.state(find.byType(TranscriptReview));
    expect(
      tester
          .widget<TranscriptSegmentEditor>(find.byKey(const ValueKey('second')))
          .isCurrent,
      isTrue,
    );

    controller.setDestination(AppDestination.library);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-page-title')), findsNothing);
    expect(find.byKey(const Key('library-search')), findsOneWidget);
    expect(find.byType(TranscriptReview), findsNothing);

    controller.setDestination(AppDestination.workspace);
    await tester.pumpAndSettle();

    expect(
      tester.state(find.byType(TranscriptReview)),
      isNot(firstReviewState),
    );
    expect(
      tester
          .widget<TranscriptSegmentEditor>(find.byKey(const ValueKey('second')))
          .isCurrent,
      isTrue,
    );
    expect(
      controller.playbackPositionFor('job'),
      const Duration(milliseconds: 1600),
    );
  });

  testWidgets('cold restored video seeks native player to saved position', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-cold-video-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/restored.mp4');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    late _ReviewFakePlatformPlayer platform;
    debugTranscriptReviewPlayerFactory = () => Player(
      platformPlayer: platform = _ReviewFakePlatformPlayer(
        emitPositionResetOnOpen: true,
      ),
    );
    debugTranscriptReviewSourceExists = (_) async => true;
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    var scheduledMediaFrames = 0;
    debugTranscriptReviewScheduleMediaFrame = () => scheduledMediaFrames++;
    addTearDown(() {
      debugTranscriptReviewPlayerFactory = null;
      debugTranscriptReviewSourceExists = null;
      debugTranscriptReviewScheduleMediaFrame = null;
      debugPrint = originalDebugPrint;
    });
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: source.path,
      settings: const AppSettings(playbackPositionsMs: {'job': 500}),
    );
    addTearDown(controller.dispose);
    expect(
      controller.playbackPositionFor('job'),
      const Duration(milliseconds: 500),
    );

    await tester.pumpWidget(
      TickerMode(
        enabled: false,
        child: ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      ),
    );

    expect(scheduledMediaFrames, 1);
    await tester.pump();
    await tester.pump();
    expect(platform.openCalls, 1);
    expect(platform.seekDurations, contains(const Duration(milliseconds: 500)));
    platform.emitPosition(Duration.zero);
    await tester.pump();
    expect(
      controller.playbackPositionFor('job'),
      const Duration(milliseconds: 500),
    );
    expect(
      platform.seekDurations.where(
        (position) => position == const Duration(milliseconds: 500),
      ),
      hasLength(2),
    );
    expect(find.byType(Video), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('video-viewport')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    debugPrint = originalDebugPrint;
  });

  testWidgets(
    'restored workspace keeps video ready when switching translation',
    (tester) async {
      _setTestWindow(tester, const Size(1055, 820));
      const windowChannel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'isFullScreen') return false;
        if (call.method == 'isVisible') return true;
        if (call.method == 'isMinimized') return false;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('meow-translated-video-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/translated.mp4');
      await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
      final platforms = <_ReviewFakePlatformPlayer>[];
      debugTranscriptReviewPlayerFactory = () {
        final platform = _ReviewFakePlatformPlayer();
        platforms.add(platform);
        return Player(platformPlayer: platform);
      };
      debugTranscriptReviewSourceExists = (_) async => true;
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() {
        debugTranscriptReviewPlayerFactory = null;
        debugTranscriptReviewSourceExists = null;
        debugPrint = originalDebugPrint;
      });
      final controller = await _controllerForDocument(
        TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'translated-video-segment',
              startMs: 0,
              endMs: 1000,
              text: 'Original video sentence.',
              translatedText: 'Translated video sentence.',
            ),
          ],
          speakers: const [],
          updatedAt: DateTime.utc(2026, 8, 17),
        ),
        metadata: _videoMetadata,
        sourcePath: source.path,
        settings: const AppSettings(onboardingComplete: true),
      );
      addTearDown(controller.dispose);
      controller.openInWorkspace('job');
      final reviewController = ReviewFullscreenController();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [AppStrings.delegate],
            home: AppShell(reviewController: reviewController),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final initialVideoState = tester.state(find.byType(Video));
      expect(platforms, hasLength(1));
      expect(platforms.single.openCalls, 1);

      final dynamic appShellState = tester.state(find.byType(AppShell));
      await tester.runAsync(
        () => appShellState.onWindowClose() as Future<void>,
      );
      final restoreFuture = messenger.handlePlatformMessage(
        'app.capyvibe.listenook/navigation',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('showWindow'),
        ),
        null,
      );
      await tester.pump();
      await tester.pump();
      await restoreFuture;
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-view-mode')), findsNothing);

      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pump(const Duration(milliseconds: 300));
      final translatedMenu = find.byKey(
        const Key('translation-mode-translated-menu'),
      );
      final translatedItem = tester.widget<PopupMenuItem>(translatedMenu);
      Navigator.of(tester.element(translatedMenu)).pop(translatedItem.value);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Translated video sentence.'), findsOneWidget);
      expect(find.text('Original video sentence.'), findsNothing);
      expect(tester.state(find.byType(Video)), isNot(same(initialVideoState)));
      expect(platforms, hasLength(2));
      expect(platforms.last.openCalls, 1);
      expect(
        find.descendant(
          of: find.byKey(const Key('video-viewport')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      debugPrint = originalDebugPrint;
    },
  );

  testWidgets('macOS toolbar aligns sidebar toggle with traffic lights', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: const Scaffold(
          body: AppWindowToolbar(sidebarVisible: true, onToggleSidebar: _noop),
        ),
      ),
    );

    final toolbar = find.byKey(const Key('app-window-toolbar'));
    final toggle = find.byKey(const Key('toggle-app-sidebar'));
    expect(tester.getSize(toolbar).height, AppWindowToolbar.macOSHeight);
    expect(tester.getSize(toggle).height, AppWindowToolbar.macOSControlHeight);
    expect(tester.getTopLeft(toggle).dy, tester.getTopLeft(toolbar).dy);
    expect(
      tester.getCenter(toggle).dy,
      tester.getTopLeft(toolbar).dy + (AppWindowToolbar.macOSControlHeight / 2),
    );
    expect(
      tester.getCenter(find.byKey(const Key('macos-traffic-light-space'))).dx,
      lessThan(tester.getCenter(toggle).dx),
    );
  });

  testWidgets('Windows toolbar places sidebar toggle after the app icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: AppWindowToolbar(sidebarVisible: true, onToggleSidebar: _noop),
        ),
      ),
    );

    final icon = find.byKey(const Key('windows-app-icon'));
    final toggle = find.byKey(const Key('toggle-app-sidebar'));
    expect(
      tester.getSize(find.byKey(const Key('app-window-toolbar'))).height,
      AppWindowToolbar.windowsHeight,
    );
    expect(tester.getCenter(icon).dx, lessThan(tester.getCenter(toggle).dx));
    expect(
      tester.getCenter(toggle).dx,
      lessThan(tester.getCenter(find.byKey(const Key('window-minimize'))).dx),
    );
    expect(find.byKey(const Key('window-maximize')), findsOneWidget);
    expect(find.byKey(const Key('window-close')), findsOneWidget);
  });

  testWidgets('workspace is editor-only and has a dedicated empty state', (
    tester,
  ) async {
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );

    expect(find.byKey(const Key('workspace-page-title')), findsNothing);
    expect(find.byKey(const Key('workspace-empty-title')), findsOneWidget);
    final emptyCard = find.ancestor(
      of: find.byKey(const Key('workspace-empty-title')),
      matching: find.byType(ConstrainedBox),
    );
    expect(tester.getSize(emptyCard.first).width, 760);
    expect(
      find.text('Open a completed transcript from Library.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace-go-to-inbox')), findsNothing);
    expect(find.byKey(const Key('workspace-go-to-library')), findsOneWidget);
    expect(find.byType(TranscriptReview), findsNothing);
    expect(find.byKey(const Key('file-queue-panel')), findsNothing);
    expect(find.byKey(const Key('empty-add-files')), findsNothing);
    expect(find.byKey(const Key('export-inbox-completed')), findsNothing);

    await tester.tap(find.byKey(const Key('workspace-go-to-library')));
    expect(controller.destination, AppDestination.library);
  });

  testWidgets('workspace omits the podcast provenance banner', (tester) async {
    final controller = await _controllerForDocument(
      _simpleDocument(),
      sourceOrigin: JobSourceOrigin.podcast,
      podcastProvenance: const PodcastEpisodeProvenance(
        feedUrl: 'https://feeds.example/show',
        episodeId: 'https://feeds.example/show\nguid-1',
        enclosureUrl: 'https://cdn.example/one.mp3',
        showTitle: 'Study English',
        episodeTitle: 'Episode One',
        episodeUrl: 'https://example.com/episodes/one',
      ),
      transcriptAcquisitionMode: TranscriptAcquisitionMode.publisherCaptions,
      transcriptSource: TranscriptSource.publisher,
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('podcast-workspace-provenance')), findsNothing);
    expect(
      find.byKey(const Key('podcast-workspace-open-episode')),
      findsNothing,
    );
    expect(find.byType(TranscriptReview), findsOneWidget);
  });

  testWidgets('active workspace review fills the page without an outer card', (
    tester,
  ) async {
    final controller = await _controllerForDocument(_simpleDocument());
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final workspace = find.byType(WorkspacePage);
    final review = find.byType(TranscriptReview);
    expect(tester.getRect(review), tester.getRect(workspace));
    expect(
      find.ancestor(of: review, matching: find.byType(Card)),
      findsNothing,
    );
  });

  for (final provider in TranscriptionProvider.values) {
    testWidgets('imported subtitle menu hides alignment for ${provider.name}', (
      tester,
    ) async {
      final controller = await _controllerForDocument(
        _simpleDocument(),
        transcriptionProvider: provider,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
        transcriptSource: TranscriptSource.importedSubtitle,
      );
      addTearDown(controller.dispose);
      controller.openInWorkspace('job');
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: WorkspacePage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('review-toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('retry-forced-alignment')), findsNothing);
    });
  }

  testWidgets('legacy MOSS transcripts expose manual local alignment', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      _simpleDocument(),
      transcriptAcquisitionMode: TranscriptAcquisitionMode.mossPro,
      transcriptSource: TranscriptSource.mossPro,
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('retry-forced-alignment')), findsNothing);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retry-forced-alignment')), findsOneWidget);
    expect(find.text('Generate precise timeline locally'), findsOneWidget);
  });

  testWidgets('saved partial alignment stays quiet and offers rerun', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      _simpleDocument(),
      transcriptAcquisitionMode: TranscriptAcquisitionMode.mossPro,
      transcriptSource: TranscriptSource.mossPro,
      forcedAlignment: const ForcedAlignmentState(
        status: ForcedAlignmentStatus.partial,
        alignedSegments: 69,
        totalSegments: 74,
        languageAutomaticallyDetermined: true,
        warningCode: 'alignment_partial',
      ),
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('69/74 segments'), findsNothing);
    expect(
      find.textContaining('language determined automatically'),
      findsNothing,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byKey(const Key('retry-forced-alignment')), findsNothing);
    expect(find.byKey(const Key('rerun-forced-alignment')), findsNothing);

    expect(find.byKey(const Key('workspace-moss-timing-status')), findsNothing);

    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();

    final retryAlignment = find.byKey(const Key('rerun-forced-alignment'));
    final addBackToInbox = find.byKey(const Key('add-back-to-inbox'));
    final translateWithLlm = find.byKey(const Key('translate-transcript'));
    expect(addBackToInbox, findsOneWidget);
    expect(find.text('Add back to Inbox'), findsOneWidget);
    expect(retryAlignment, findsOneWidget);
    expect(find.text('Retry local alignment'), findsOneWidget);
    expect(translateWithLlm, findsOneWidget);
    expect(
      tester.getTopLeft(addBackToInbox).dy,
      lessThan(tester.getTopLeft(retryAlignment).dy),
    );
    expect(
      tester.getTopLeft(retryAlignment).dy,
      lessThan(tester.getTopLeft(translateWithLlm).dy),
    );
  });

  testWidgets('workspace shows local alignment processing and result states', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-alignment-progress-'),
    );
    addTearDown(() => root!.delete(recursive: true));
    final source = File('${root!.path}/source.wav');
    await tester.runAsync(() => source.writeAsBytes(const [1]));
    final alignment = _BlockingAlignmentService(
      alignedSegments: 1,
      totalSegments: 2,
    );
    addTearDown(() {
      if (!alignment.release.isCompleted) alignment.release.complete();
    });
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1000,
            text: 'First',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1000,
            endMs: 2000,
            text: 'Second',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime(2026),
      ),
      sourcePath: source.path,
      transcriptAcquisitionMode: TranscriptAcquisitionMode.qwen3Local,
      transcriptSource: TranscriptSource.qwen3Local,
      forcedAlignmentService: alignment,
      settings: const AppSettings(
        defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
      ),
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    late Future<void> retry;
    await tester.runAsync(() async {
      retry = controller.retryForcedAlignment('job');
      await _waitForController(
        () =>
            controller.jobById('job')!.forcedAlignment.status ==
                ForcedAlignmentStatus.running &&
            controller.jobById('job')!.progress.fraction == 0.42,
      );
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: WorkspacePage()),
        ),
      ),
    );
    await tester.pump();

    final notification = find.byKey(const Key('workspace-moss-timing-status'));
    expect(notification, findsOneWidget);
    expect(
      find.descendant(
        of: notification,
        matching: find.byKey(const Key('workspace-alignment-processing')),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Generating precise word timing locally…'),
      findsOneWidget,
    );

    alignment.release.complete();
    await tester.runAsync(() => retry);
    await tester.pump();

    expect(controller.jobById('job')!.forcedAlignment.alignedSegments, 1);
    expect(controller.jobById('job')!.forcedAlignment.totalSegments, 2);
    expect(notification, findsOneWidget);
    expect(
      find.byKey(const Key('workspace-alignment-processing')),
      findsNothing,
    );
    expect(
      find.textContaining('Qwen3 Local · partially aligned'),
      findsOneWidget,
    );
    expect(find.textContaining('1/2 segments'), findsOneWidget);
    expect(
      tester.getCenter(notification).dy,
      greaterThan(tester.getCenter(find.byType(TranscriptReview)).dy),
    );
    await tester.tap(find.byKey(const Key('dismiss-alignment-notification')));
    await tester.pump();
    expect(notification, findsNothing);
  });

  testWidgets('inbox keeps completed batches visible until explicitly opened', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-inbox-ui-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.wav');
    final second = File('${directory.path}/second.wav');
    await tester.runAsync(() async {
      await first.writeAsBytes(const [1]);
      await second.writeAsBytes(const [2]);
    });
    final controller = AppController(
      credentialStore: _ConfiguredCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _TranscriptSoniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize().timeout(const Duration(seconds: 3));
    await tester.runAsync(() async {
      await controller
          .enqueueSources([first.path, second.path])
          .timeout(const Duration(seconds: 3));
      await _waitForController(
        () => controller.readyCount == 2,
      ).timeout(const Duration(seconds: 3));
      await controller.startReady().timeout(const Duration(seconds: 3));
    });

    expect(controller.completedCount, 2);
    expect(controller.destination, AppDestination.podcast);
    final firstJobId = controller.inboxJobs.first.id;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(TranscriptReview), findsNothing);
    expect(find.byKey(const Key('file-queue-panel')), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.ios_share_rounded), findsNWidgets(3));
    expect(find.byKey(const Key('export-inbox-completed')), findsOneWidget);
    expect(find.text('Export completed (2)'), findsOneWidget);

    await controller.removeFromInbox(controller.inboxJobs.last.id);
    await tester.pump();
    expect(controller.completedCount, 1);
    expect(find.byKey(const Key('export-inbox-completed')), findsNothing);

    await tester.tap(find.byKey(ValueKey('open-inbox-job-$firstJobId')));
    await tester.pump();

    expect(controller.activeWorkspaceJobId, firstJobId);
    expect(controller.destination, AppDestination.workspace);
  });

  testWidgets('video review stacks cleanly at the minimum window size', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(920, 640));
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 64),
                VerticalDivider(width: 1),
                Expanded(child: WorkspacePage()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('file-queue-panel')), findsNothing);
    expect(find.byKey(const Key('file-queue-rail')), findsNothing);
    expect(find.byKey(const Key('export-inbox-completed')), findsNothing);
    expect(find.byKey(const Key('video-review-stacked')), findsOneWidget);
    expect(find.byKey(const Key('video-review-split')), findsNothing);
    expect(find.byKey(const Key('video-transcript-divider')), findsNothing);
    expect(find.byKey(const Key('video-audio-mode-toggle')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video layout moves the title above the media', (tester) async {
    _setTestWindow(tester, const Size(1240, 820));
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final filename = find.byKey(const Key('review-filename'));
    expect(
      find.descendant(
        of: find.byKey(const Key('video-media-header')),
        matching: filename,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('transcript-pane-header')),
        matching: filename,
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('video-audio-mode-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-media-header')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('transcript-pane-header')),
        matching: filename,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video audio toggle localizes its destination tooltip', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('video-audio-mode-toggle')))
          .tooltip,
      '切换到音频模式',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video waveform is loaded lazily and reused across switches', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final media = _CountingWaveformMedia();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1000,
            text: 'First sentence.',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1400,
            endMs: 2400,
            text: 'Second sentence.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
      mediaService: media,
    );
    addTearDown(controller.dispose);
    controller
      ..openInWorkspace('job')
      ..rememberPlaybackPosition('job', const Duration(milliseconds: 1600));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const toggleKey = Key('video-audio-mode-toggle');
    expect(media.waveformRequests, 0);
    expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(toggleKey)).style?.backgroundColor,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byKey(toggleKey)).tooltip,
      'Switch to audio mode',
    );
    expect(
      tester
          .widget<TranscriptSegmentEditor>(find.byKey(const ValueKey('second')))
          .isCurrent,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('video-audio-mode-video')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(toggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(media.waveformRequests, 1);
    expect(find.byKey(const Key('audio-review-companion')), findsOneWidget);
    expect(find.byKey(const Key('audio-review-media')), findsOneWidget);
    expect(find.byKey(const Key('video-review-split')), findsNothing);
    expect(find.byKey(const Key('video-audio-mode-switcher')), findsNothing);
    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(toggleKey)).tooltip,
      'Switch to video mode',
    );
    expect(
      tester
          .widget<TranscriptSegmentEditor>(find.byKey(const ValueKey('second')))
          .isCurrent,
      isTrue,
    );

    await tester.tap(find.byKey(toggleKey));
    await tester.pump();
    expect(find.byKey(const Key('video-review-split')), findsOneWidget);
    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();
    expect(media.waveformRequests, 1);
    expect(
      tester
          .widget<TranscriptSegmentEditor>(find.byKey(const ValueKey('second')))
          .isCurrent,
      isTrue,
    );
  });

  testWidgets('video audio mode resets when the reviewed job changes', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final now = DateTime.now().toUtc();
    TranscriptionJob job(String id) => TranscriptionJob(
      id: id,
      batchId: 'batch',
      sourcePath: '/missing/$id.mp4',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      metadata: _videoMetadata,
      document: _simpleDocument(),
    );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([job('first'), job('second')]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.openInWorkspace('first');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: Consumer<AppController>(
              builder: (context, value, _) =>
                  TranscriptReview(jobId: value.activeWorkspaceJobId!),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const toggleKey = Key('video-audio-mode-toggle');
    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-review-companion')), findsOneWidget);

    controller.openInWorkspace('second');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('video-audio-mode-video')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
  });

  testWidgets('audio-only reviews do not show the video audio toggle', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: const MediaMetadata(
        sizeBytes: 1,
        durationMs: 1000,
        hasAudio: true,
        hasVideo: false,
        formatName: 'wav',
      ),
    );
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-audio-mode-toggle')), findsNothing);
  });

  testWidgets('stacked video transport keeps mode and fullscreen aligned', (
    tester,
  ) async {
    var modeSwitches = 0;
    var fullscreenRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 520,
              child: VideoTransport(
                playing: false,
                position: const Duration(seconds: 12),
                duration: const Duration(minutes: 3, seconds: 12),
                playbackRate: 1,
                onPlayPause: () async {},
                onSeek: (_, {reason = TranscriptSeekReason.standard}) async {},
                onPlaybackRateChanged: (_) async {},
                onSwitchToAudioMode: () => modeSwitches++,
                onFullscreen: () async => fullscreenRequests++,
              ),
            ),
          ),
        ),
      ),
    );

    final transport = tester.getRect(find.byKey(const Key('video-transport')));
    final mode = tester.getRect(
      find.byKey(const Key('video-audio-mode-toggle')),
    );
    final speed = tester.getRect(find.byKey(const Key('video-playback-speed')));
    final fullscreen = tester.getRect(
      find.byKey(const Key('video-fullscreen')),
    );
    expect(speed.right, lessThanOrEqualTo(mode.left));
    expect(mode.right, lessThanOrEqualTo(fullscreen.left));
    expect(mode.center.dy, closeTo(fullscreen.center.dy, 1));
    expect(mode.top, greaterThanOrEqualTo(transport.top));
    expect(fullscreen.right, lessThanOrEqualTo(transport.right));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('video-audio-mode-toggle')));
    await tester.tap(find.byKey(const Key('video-fullscreen')));
    expect(modeSwitches, 1);
    expect(fullscreenRequests, 1);
  });

  testWidgets('video speed button shows and applies a playback rate', (
    tester,
  ) async {
    var rate = 1.0;
    final selected = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PlaybackSpeedButton(
              rate: rate,
              onChanged: (value) async {
                selected.add(value);
                setState(() => rate = value);
              },
            ),
          ),
        ),
      ),
    );

    const buttonKey = Key('video-playback-speed');
    expect(find.text('1×'), findsOneWidget);
    expect(
      tester.widget<PopupMenuButton<double>>(find.byKey(buttonKey)).tooltip,
      'Playback speed',
    );

    await tester.tap(find.byKey(buttonKey));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<CheckedPopupMenuItem<double>>(
          find.byType(CheckedPopupMenuItem<double>),
        )
        .toList();
    expect(items, hasLength(PlaybackSpeedButton.rates.length));
    expect(items.where((item) => item.checked).single.value, 1);

    await tester.tap(find.byKey(const ValueKey('playback-speed-125')));
    await tester.pumpAndSettle();
    expect(selected, [1.25]);
    expect(find.text('1.25×'), findsOneWidget);
  });

  testWidgets('fullscreen video keyboard controls dispatch every shortcut', (
    tester,
  ) async {
    var fullscreen = true;
    var playPauseCalls = 0;
    var backwardCalls = 0;
    var forwardCalls = 0;
    var slowerCalls = 0;
    var fasterCalls = 0;
    var repeatStarts = 0;
    var repeatEnds = 0;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: StatefulBuilder(
          builder: (context, setState) => Stack(
            children: [
              const Text('Workspace', key: Key('workspace-content')),
              if (fullscreen)
                VideoFullscreenKeyboardRegion(
                  subtitle: 'Fullscreen transcript subtitle',
                  playing: true,
                  position: const Duration(seconds: 2),
                  duration: const Duration(seconds: 10),
                  onExit: () => setState(() => fullscreen = false),
                  onPlayPause: () => playPauseCalls++,
                  onSeek: (_) {},
                  onSeekBackward: () => backwardCalls++,
                  onSeekForward: () => forwardCalls++,
                  onDecreaseSpeed: () => slowerCalls++,
                  onIncreaseSpeed: () => fasterCalls++,
                  onRepeatHoldStart: () => repeatStarts++,
                  onRepeatHoldEnd: () => repeatEnds++,
                  child: const ColoredBox(
                    key: Key('fullscreen-video-surface'),
                    color: Colors.black,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fullscreen-video-surface')), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-subtitle')), findsOneWidget);
    expect(find.text('Fullscreen transcript subtitle'), findsOneWidget);
    final subtitleDecoration =
        tester
                .widget<DecoratedBox>(
                  find.byKey(const Key('fullscreen-subtitle')),
                )
                .decoration
            as BoxDecoration;
    expect(subtitleDecoration.color, Colors.black.withValues(alpha: .40));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);

    expect(playPauseCalls, 1);
    expect(backwardCalls, 1);
    expect(forwardCalls, 1);
    expect(slowerCalls, 1);
    expect(fasterCalls, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    expect(repeatStarts, 1);
    expect(repeatEnds, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    expect(repeatEnds, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    expect(repeatStarts, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(repeatEnds, 2);
    expect(find.byKey(const Key('fullscreen-video-surface')), findsNothing);
    expect(find.byKey(const Key('workspace-content')), findsOneWidget);
  });

  testWidgets('fullscreen subtitle highlights without changing word weight', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoFullscreenKeyboardRegion(
          subtitle: 'The current word',
          subtitleHighlight: const TextRange(start: 4, end: 11),
          playing: true,
          position: const Duration(seconds: 2),
          duration: const Duration(seconds: 10),
          onExit: _noop,
          onPlayPause: _noop,
          onSeek: (_) {},
          onSeekBackward: _noop,
          onSeekForward: _noop,
          onDecreaseSpeed: _noop,
          onIncreaseSpeed: _noop,
          onRepeatHoldStart: _noop,
          onRepeatHoldEnd: _noop,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );

    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('fullscreen-subtitle')),
        matching: find.byType(RichText),
      ),
    );
    final root = richText.text as TextSpan;
    final highlighted = _descendantSpans(
      root,
    ).where((span) => span.style?.backgroundColor != null).toList();
    expect(highlighted.map((span) => span.text), ['current']);
    expect(highlighted.single.style?.fontWeight, isNull);
  });

  testWidgets(
    'fullscreen controls hide while playing and stay visible while paused or scrubbing',
    (tester) async {
      _setTestWindow(tester, const Size(1000, 600));
      var playing = true;
      late StateSetter updatePlayback;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: StatefulBuilder(
            builder: (context, setState) {
              updatePlayback = setState;
              return VideoFullscreenKeyboardRegion(
                subtitle: 'Current sentence',
                playing: playing,
                position: const Duration(seconds: 2),
                duration: const Duration(seconds: 10),
                onExit: () {},
                onPlayPause: () => setState(() => playing = !playing),
                onSeek: (_) {},
                onSeekBackward: () {},
                onSeekForward: () {},
                onDecreaseSpeed: () {},
                onIncreaseSpeed: () {},
                onRepeatHoldStart: _noop,
                onRepeatHoldEnd: _noop,
                child: const ColoredBox(
                  key: Key('fullscreen-auto-hide-surface'),
                  color: Colors.black,
                ),
              );
            },
          ),
        ),
      );

      final opacityFinder = find.byKey(
        const Key('fullscreen-controls-opacity'),
      );
      final paddingFinder = find.byKey(
        const Key('fullscreen-subtitle-padding'),
      );
      final pointerFinder = find.byKey(const Key('fullscreen-pointer-region'));
      double controlsOpacity() =>
          tester.widget<AnimatedOpacity>(opacityFinder).opacity;
      double subtitleClearance() =>
          (tester.widget<AnimatedPadding>(paddingFinder).padding as EdgeInsets)
              .bottom;
      MouseCursor cursor() => tester.widget<MouseRegion>(pointerFinder).cursor;

      expect(controlsOpacity(), 1);
      expect(subtitleClearance(), 72);
      expect(cursor(), SystemMouseCursors.basic);

      await tester.pump(VideoFullscreenKeyboardRegion.controlsAutoHideDelay);
      await tester.pump(
        VideoFullscreenKeyboardRegion.controlsTransitionDuration,
      );
      expect(controlsOpacity(), 0);
      expect(subtitleClearance(), 0);
      expect(cursor(), SystemMouseCursors.none);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('fullscreen-auto-hide-surface'))),
      );
      await tester.pump(
        VideoFullscreenKeyboardRegion.controlsTransitionDuration,
      );
      expect(controlsOpacity(), 1);
      expect(subtitleClearance(), 72);
      expect(cursor(), SystemMouseCursors.basic);

      await tester.pump(const Duration(milliseconds: 2700));
      expect(controlsOpacity(), 1);

      updatePlayback(() => playing = false);
      await tester.pump(
        VideoFullscreenKeyboardRegion.controlsTransitionDuration,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(controlsOpacity(), 1);

      updatePlayback(() => playing = true);
      await tester.pump();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('fullscreen-seek')),
      );
      slider.onChangeStart!(2000);
      await tester.pump(const Duration(seconds: 4));
      expect(controlsOpacity(), 1);

      slider.onChangeEnd!(2000);
      await tester.pump(VideoFullscreenKeyboardRegion.controlsAutoHideDelay);
      await tester.pump(
        VideoFullscreenKeyboardRegion.controlsTransitionDuration,
      );
      expect(controlsOpacity(), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fullscreen transport dispatches controls and disables unknown seek',
    (tester) async {
      var playing = false;
      var duration = const Duration(seconds: 10);
      var playPauseCalls = 0;
      var exitCalls = 0;
      Duration? soughtPosition;
      late StateSetter updateTransport;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: StatefulBuilder(
            builder: (context, setState) {
              updateTransport = setState;
              return VideoFullscreenKeyboardRegion(
                playing: playing,
                position: const Duration(seconds: 2),
                duration: duration,
                onExit: () => exitCalls++,
                onPlayPause: () {
                  playPauseCalls++;
                  setState(() => playing = !playing);
                },
                onSeek: (value) => soughtPosition = value,
                onSeekBackward: () {},
                onSeekForward: () {},
                onDecreaseSpeed: () {},
                onIncreaseSpeed: () {},
                onRepeatHoldStart: _noop,
                onRepeatHoldEnd: _noop,
                child: const ColoredBox(color: Colors.black),
              );
            },
          ),
        ),
      );

      expect(find.byKey(const Key('fullscreen-controls')), findsOneWidget);
      expect(find.text('00:02'), findsOneWidget);
      expect(find.text('00:10'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('fullscreen-play-pause')))
            .tooltip,
        'Play',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('fullscreen-exit')))
            .tooltip,
        'Exit fullscreen',
      );

      final slider = tester.widget<Slider>(
        find.byKey(const Key('fullscreen-seek')),
      );
      slider.onChangeStart!(2000);
      slider.onChanged!(6500);
      slider.onChangeEnd!(6500);
      expect(soughtPosition, const Duration(milliseconds: 6500));

      await tester.tap(find.byKey(const Key('fullscreen-play-pause')));
      await tester.tap(find.byKey(const Key('fullscreen-exit')));
      expect(playPauseCalls, 1);
      expect(exitCalls, 1);

      updateTransport(() => duration = Duration.zero);
      await tester.pump();
      final disabledSlider = tester.widget<Slider>(
        find.byKey(const Key('fullscreen-seek')),
      );
      expect(disabledSlider.onChanged, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullscreen-position'))).data,
        '00:00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('fullscreen-duration'))).data,
        '00:00',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drag-and-drop Inbox imports remain manual with automation', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-manual-drop-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/dropped.wav');
    await tester.runAsync(() => source.writeAsBytes(const [1, 2, 3]));
    final localStt = _DropCountingLocalStt();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(
        const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          autoTranscribeLocal: true,
        ),
      ),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      localSttService: localStt,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );
    final dropTarget = tester.widget<DropTarget>(find.byType(DropTarget));
    await tester.runAsync(() async {
      dropTarget.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(source.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await _waitForController(
        () =>
            controller.inboxJobs.isNotEmpty &&
            controller.inboxJobs.single.status == JobStatus.ready,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(localStt.calls, 0);
    expect(controller.processing, isFalse);
    expect(controller.inboxJobs.single.sourceOrigin, JobSourceOrigin.manual);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('header-transcribe')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('language and context options belong to the inbox batch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'ready',
          batchId: 'batch',
          sourcePath: '/missing/ready.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.addToInbox('ready');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: () {}, onImportFolder: () {}),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('header-import-folder')), findsOneWidget);
    expect(find.byKey(const Key('header-add-files')), findsOneWidget);
    expect(find.byKey(const Key('header-transcribe')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('inbox-monitor-setup-card'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('header-add-files'))).dy),
    );
    expect(find.widgetWithText(SwitchListTile, 'Speaker labels'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'Timestamps'), findsNothing);
    expect(find.text('Concurrent jobs'), findsNothing);
    expect(find.byType(SegmentedButton<int>), findsNothing);

    expect(find.byKey(const Key('session-language-hints-field')), findsNothing);
    expect(find.text('Automatic'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-language-hints-picker')));
    await tester.pumpAndSettle();

    expect(find.text('Chinese  ·  zh'), findsOneWidget);
    expect(find.text('English  ·  en'), findsOneWidget);

    final chineseHint = find.byKey(const ValueKey('language-hint-zh'));
    await tester.ensureVisible(chineseHint);
    await tester.tap(chineseHint);
    await tester.pump();
    final englishHint = find.byKey(const ValueKey('language-hint-en'));
    await tester.ensureVisible(englishHint);
    await tester.tap(englishHint);
    await tester.pump();

    expect(controller.sessionOptions.languageHints, ['zh', 'en']);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Chinese, English'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('session-context-terms-field')),
      'Listenook, Soniox',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(controller.sessionOptions.contextTerms, ['Listenook', 'Soniox']);
    expect(controller.inboxJobs.single.options.languageHints, ['zh', 'en']);
    expect(controller.inboxJobs.single.options.contextTerms, [
      'Listenook',
      'Soniox',
    ]);
  });

  testWidgets('inbox replaces LLM controls with Soniox translation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(
        const AppSettings(
          sonioxTranslation: SonioxTranslationOptions(
            enabled: true,
            targetLanguage: 'zh',
          ),
          translationSettings: TranslationSettings(
            baseUrl: 'https://example.test/v1',
            model: 'configured-llm',
          ),
        ),
      ),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'ready',
          batchId: 'batch',
          sourcePath: '/missing/ready.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.addToInbox('ready');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('soniox-translation-summary')), findsOneWidget);
    expect(find.text('Soniox built-in translation'), findsOneWidget);
    expect(find.text('Chinese'), findsOneWidget);
    expect(find.text('AI provider'), findsNothing);
    expect(find.byKey(const Key('translation-target-language')), findsNothing);
    expect(find.byKey(const Key('auto-translate-switch')), findsNothing);
  });

  testWidgets('MOSS batch hides Soniox-only language and context options', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      mossCredentialStore: _Credentials(),
      settingsRepository: _Settings(
        const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossPro,
          sonioxTranslation: SonioxTranslationOptions(
            enabled: true,
            targetLanguage: 'zh',
          ),
        ),
      ),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'moss-ready',
          batchId: 'batch',
          sourcePath: '/moss.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          transcriptionProvider: TranscriptionProvider.mossPro,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      mossClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.addToInbox('moss-ready');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('session-transcription-provider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('session-language-hints-picker')),
      findsNothing,
    );
    expect(find.byKey(const Key('session-context-terms-field')), findsNothing);
    expect(
      find.text(
        'Multilingual diarized transcription; language and context are automatic',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('soniox-translation-summary')), findsNothing);
  });

  testWidgets('MOSS Local can start a 137-minute recording', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(
        const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        ),
      ),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'long-local',
          batchId: 'batch',
          sourcePath: '/long.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          transcriptionProvider: TranscriptionProvider.mossLocal,
          metadata: const MediaMetadata(
            sizeBytes: 1,
            durationMs: 137 * 60 * 1000,
            hasAudio: true,
            hasVideo: false,
            formatName: 'wav',
          ),
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      localSttService: _SupportedLocalStt(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.addToInbox('long-local');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );

    expect(controller.canStartReady, isTrue);
    expect(find.byKey(const Key('local-moss-duration-warning')), findsNothing);
    expect(find.textContaining('up to 90 minutes'), findsNothing);
  });

  test('local model inference uses indeterminate progress', () {
    final now = DateTime.now().toUtc();
    final local = TranscriptionJob(
      id: 'local-running',
      batchId: 'batch',
      sourcePath: '/source.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.processing,
      transcriptionProvider: TranscriptionProvider.mossLocal,
      progress: const JobProgress(stage: 'local_transcribing', fraction: 0.12),
    );
    expect(inboxJobProgressValue(local), isNull);
    expect(inboxJobProgressPercentage(local), '12%');
    expect(
      inboxJobProgressValue(
        local.copyWith(
          progress: const JobProgress(
            stage: 'local_transcribing',
            fraction: 0.3,
          ),
        ),
      ),
      0.3,
    );
    expect(
      inboxJobProgressPercentage(
        local.copyWith(
          progress: const JobProgress(
            stage: 'local_transcribing',
            fraction: 0.306,
          ),
        ),
      ),
      '30%',
    );
    expect(
      inboxJobProgressValue(
        local.copyWith(
          status: JobStatus.converting,
          progress: const JobProgress(stage: 'converting', fraction: 0.4),
        ),
      ),
      0.4,
    );
    expect(
      inboxJobProgressPercentage(
        local.copyWith(
          status: JobStatus.converting,
          progress: const JobProgress(stage: 'converting', fraction: 0.4),
        ),
      ),
      isNull,
    );
  });

  testWidgets('inbox keeps two panes at Windows initial content width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(936, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'job',
          batchId: 'batch',
          sourcePath: '/missing/test.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.addToInbox('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: InboxPage(onAddFiles: _noop, onImportFolder: _noop),
          ),
        ),
      ),
    );

    final queue = find.byKey(const Key('inbox-queue-pane'));
    final detail = find.byKey(const Key('inbox-detail-pane'));
    expect(queue, findsOneWidget);
    expect(detail, findsOneWidget);
    expect(tester.getRect(queue).right, lessThan(tester.getRect(detail).left));
  });

  testWidgets('waveform supports click and drag seeking', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 80,
              child: WaveformScrubber(
                path: null,
                loading: false,
                position: const Duration(seconds: 10),
                duration: const Duration(seconds: 40),
                onSeek: (position) async => seeks.add(position),
              ),
            ),
          ),
        ),
      ),
    );

    final scrubber = find.byKey(const Key('waveform-scrubber'));
    final bounds = tester.getRect(scrubber);
    await tester.tapAt(
      Offset(bounds.left + bounds.width * .75, bounds.center.dy),
    );
    expect(seeks.last, const Duration(seconds: 30));

    await tester.dragFrom(
      Offset(bounds.left + bounds.width * .25, bounds.center.dy),
      Offset(bounds.width * .25, 0),
    );
    expect(seeks.last, const Duration(seconds: 20));
  });

  testWidgets('audio controls and waveform share one transport row', (
    tester,
  ) async {
    var switchedToVideo = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: AudioTransport(
                playing: false,
                position: const Duration(seconds: 2),
                duration: const Duration(seconds: 33),
                waveformPath: null,
                waveformLoading: false,
                onPlayPause: () async {},
                onSeek: (_) async {},
                onSwitchToVideoMode: () => switchedToVideo = true,
              ),
            ),
          ),
        ),
      ),
    );

    final play = find.byKey(const Key('audio-play-pause'));
    final current = find.byKey(const Key('audio-current-time'));
    final waveform = find.byKey(const Key('waveform-scrubber'));
    final duration = find.byKey(const Key('audio-duration'));
    final switchMode = find.byKey(const Key('video-audio-mode-toggle'));
    final centerY = tester.getCenter(waveform).dy;

    expect(tester.getCenter(play).dy, closeTo(centerY, 1));
    expect(tester.getCenter(current).dy, closeTo(centerY, 1));
    expect(tester.getCenter(duration).dy, closeTo(centerY, 1));
    expect(tester.getCenter(switchMode).dy, closeTo(centerY, 1));
    expect(tester.getCenter(play).dx, lessThan(tester.getCenter(current).dx));
    expect(
      tester.getCenter(current).dx,
      lessThan(tester.getCenter(waveform).dx),
    );
    expect(
      tester.getCenter(waveform).dx,
      lessThan(tester.getCenter(duration).dx),
    );
    expect(
      tester.getCenter(duration).dx,
      lessThan(tester.getCenter(switchMode).dx),
    );
    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    await tester.tap(switchMode);
    expect(switchedToVideo, isTrue);
  });

  testWidgets('audio transcript starts near the top of its scroll area', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 700));
    final controller = await _controllerForDocument(_simpleDocument());
    addTearDown(controller.dispose);
    controller.openInWorkspace('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollTop = tester
        .getTopLeft(find.byKey(const Key('transcript-scroll')))
        .dy;
    final firstSegmentTop = tester
        .getTopLeft(find.byKey(const ValueKey('segment-card-segment')))
        .dy;

    expect(firstSegmentTop - scrollTop, lessThanOrEqualTo(32));

    await tester.tap(find.byKey(const Key('focus-current-sentence')));
    await tester.pumpAndSettle();
    final focusedSegmentTop = tester
        .getTopLeft(find.byKey(const ValueKey('segment-card-segment')))
        .dy;
    expect(focusedSegmentTop - scrollTop, lessThanOrEqualTo(32));
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening another sentence cancels the previous draft', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(body: _TwoEditorHarness()),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-first'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-edit-first')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('segment-editor-first')),
      'First draft',
    );
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-second'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-edit-second')));
    await tester.pump();

    expect(find.byKey(const ValueKey('segment-editor-first')), findsNothing);
    expect(find.byKey(const ValueKey('segment-editor-second')), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-first'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('segment-edit-first')));
    await tester.pump();
    final reopened = tester.widget<TextField>(
      find.byKey(const ValueKey('segment-editor-first')),
    );
    expect(reopened.controller!.text, 'First original');
  });

  testWidgets('search closes before focusing a distant current sentence', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: List.generate(
          60,
          (index) => TranscriptSegment(
            id: 'segment-$index',
            startMs: 0,
            endMs: 1000,
            text: List.filled(
              index.isEven ? 1 : 3,
              'Sentence $index has variable height.',
            ).join('\n'),
          ),
        ),
        speakers: const [],
        updatedAt: now,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-transcript-search')));
    await tester.pump();
    final search = find.byKey(const Key('transcript-search-field'));
    expect(search, findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsNothing);
    expect(find.byKey(const Key('review-content-tabs')), findsOneWidget);
    await tester.enterText(search, 'Sentence 0');
    await tester.pump();
    final scrollable = find.descendant(
      of: find.byKey(const Key('transcript-scroll')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    expect(find.byKey(const Key('open-transcript-search')), findsOneWidget);

    await tester.tap(find.byKey(const Key('focus-current-sentence')));
    await tester.pumpAndSettle();

    final currentCard = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('segment-card-segment-59')),
    );
    final decoration = currentCard.decoration as BoxDecoration;
    expect(decoration.border, isNull);
    expect(decoration.color, isNull);
  });

  testWidgets('focus keeps an already visible current sentence in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1240, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final document = TranscriptDocument(
      tokens: const [],
      segments: List.generate(
        14,
        (index) => TranscriptSegment(
          id: 'segment-$index',
          startMs: index * 1000,
          endMs: (index + 1) * 1000,
          text: 'Sentence $index is visible near the top.',
        ),
      ),
      speakers: const [],
      updatedAt: now,
    );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        for (final id in ['first-job', 'second-job'])
          TranscriptionJob(
            id: id,
            batchId: 'batch',
            sourcePath: '/missing/$id.mp4',
            createdAt: now,
            updatedAt: now,
            status: JobStatus.completed,
            metadata: _videoMetadata,
            document: document,
          ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    controller.rememberPlaybackPosition(
      'second-job',
      const Duration(milliseconds: 6100),
    );
    final jobId = ValueNotifier('first-job');
    addTearDown(jobId.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: jobId,
              builder: (_, value, __) => TranscriptReview(jobId: value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    jobId.value = 'second-job';
    await tester.pumpAndSettle();

    final firstCard = find.byKey(const ValueKey('segment-card-segment-0'));
    final currentCard = find.byKey(const ValueKey('segment-card-segment-6'));
    expect(firstCard, findsOneWidget);
    expect(currentCard, findsOneWidget);
    expect(
      tester
          .widgetList<TranscriptSegmentEditor>(
            find.byType(TranscriptSegmentEditor),
          )
          .singleWhere((editor) => editor.segment.id == 'segment-6')
          .isCurrent,
      isTrue,
    );
    final firstCardTop = tester.getTopLeft(firstCard).dy;
    final currentCardRect = tester.getRect(currentCard);
    final transcriptRect = tester.getRect(
      find.byKey(const Key('transcript-scroll')),
    );
    expect(transcriptRect.contains(currentCardRect.topLeft), isTrue);
    expect(transcriptRect.contains(currentCardRect.bottomRight), isTrue);

    await tester.tap(find.byKey(const Key('focus-current-sentence')));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(firstCard).dy, firstCardTop);
  });

  testWidgets('focus jumps to a distant sentence within one frame', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    const targetIndex = 1999;
    final controller = await _controllerForDocument(
      TranscriptDocument(
        tokens: const [],
        segments: List.generate(
          targetIndex + 1,
          (index) => TranscriptSegment(
            id: 'segment-$index',
            startMs: index * 1000,
            endMs: (index + 1) * 1000,
            text: 'Sentence $index.',
          ),
        ),
        speakers: const [],
        updatedAt: now,
      ),
    );
    addTearDown(controller.dispose);
    controller.rememberPlaybackPosition(
      'job',
      const Duration(milliseconds: targetIndex * 1000),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('focus-current-sentence')));
    var frames = 0;
    while (find
            .byKey(const ValueKey('segment-card-segment-$targetIndex'))
            .evaluate()
            .isEmpty &&
        frames < 120) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    expect(
      frames,
      lessThanOrEqualTo(1),
      reason: 'The distant sentence took ${frames * 16} ms to render.',
    );
  });

  testWidgets('search highlights every case-insensitive match', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SearchHighlightedText(
            key: Key('highlighted-result'),
            text: 'Fly with FLY and 飞书',
            query: 'fly',
          ),
        ),
      ),
    );

    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('highlighted-result')),
        matching: find.byType(RichText),
      ),
    );
    final root = richText.text as TextSpan;
    final matches = _descendantSpans(root)
        .where((span) => span.style?.backgroundColor != null)
        .map((span) => span.text)
        .toList();

    expect(matches, ['Fly', 'FLY']);
  });

  testWidgets('AI Brief evidence returns to and focuses the transcript', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final now = DateTime.now().toUtc();
    final document = TranscriptDocument(
      tokens: const [],
      segments: [
        for (var index = 0; index < 8; index++)
          TranscriptSegment(
            id: index == 0 ? 'segment' : 'segment-$index',
            startMs: index * 75000,
            endMs: index * 75000 + 1000,
            text: index == 0 ? 'Hello' : 'Sentence $index',
          ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    final overview = List.generate(
      180,
      (index) => 'Grounded overview sentence $index.',
    ).join(' ');
    final brief = AiBrief(
      overview: overview,
      overviewEvidenceSegmentIds: [
        for (var index = 0; index < 8; index++)
          index == 0 ? 'segment' : 'segment-$index',
      ],
      chapters: const [],
      insights: const [],
      outputLanguage: 'en',
      model: 'brief-model',
      selectedSections: const {AiBriefSection.overview},
      generatedAt: document.updatedAt,
      sourceTranscriptUpdatedAt: document.updatedAt,
    );
    final controller = await _controllerForDocument(document, aiBrief: brief);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: const Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final transcriptHeaderHeight = tester
        .getSize(find.byKey(const Key('review-header')))
        .height;
    final transcriptTabsCenter = tester
        .getCenter(find.byKey(const Key('review-content-tabs')))
        .dx;
    expect(transcriptHeaderHeight, 64);
    expect(
      transcriptTabsCenter,
      closeTo(tester.getCenter(find.byKey(const Key('review-header'))).dx, 0.1),
    );
    expect(find.byKey(const Key('review-header')), findsOneWidget);
    expect(find.byKey(const Key('transcript-toolbar-row')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-header')),
        matching: find.byKey(const Key('review-content-tabs')),
      ),
      findsOneWidget,
    );
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('review-header'))).height,
      transcriptHeaderHeight,
    );
    expect(
      tester.getCenter(find.byKey(const Key('review-content-tabs'))).dx,
      closeTo(transcriptTabsCenter, 0.1),
    );
    expect(
      find.textContaining('Grounded overview sentence 0.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ai-evidence-segment')), findsOneWidget);
    expect(find.byKey(const Key('translate-transcript')), findsNothing);
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);
    expect(find.byKey(const Key('ai-brief-companion-split')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);

    final aiBriefScroll = find.byKey(const Key('ai-brief-scroll'));
    final evidence = find.byKey(const Key('ai-evidence-segment'));
    final evidenceSize = tester.getSize(evidence);
    expect(evidenceSize.height, greaterThanOrEqualTo(24));
    expect(evidenceSize.height, lessThanOrEqualTo(28));
    expect(evidenceSize.width, lessThanOrEqualTo(84));
    final evidenceChips = find.descendant(
      of: aiBriefScroll,
      matching: find.byType(ActionChip),
    );
    expect(evidenceChips, findsNWidgets(8));
    for (final chip in evidenceChips.evaluate()) {
      final size = tester.getSize(find.byWidget(chip.widget));
      expect(size.height, inInclusiveRange(24, 28));
      expect(size.width, lessThanOrEqualTo(84));
    }
    final evidenceRows = evidenceChips
        .evaluate()
        .map((chip) => tester.getTopLeft(find.byWidget(chip.widget)).dy.round())
        .toSet();
    expect(evidenceRows.length, greaterThan(1));
    expect(tester.takeException(), isNull);
    final aiBriefScrollable = find.descendant(
      of: aiBriefScroll,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      evidence,
      300,
      scrollable: aiBriefScrollable,
    );
    await tester.pumpAndSettle();
    final aiBriefOffsetBeforeEvidence = tester
        .state<ScrollableState>(aiBriefScrollable)
        .position
        .pixels;
    expect(aiBriefOffsetBeforeEvidence, greaterThan(0));
    await tester.tap(evidence);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<bool>>(
            find.byKey(const Key('review-content-tabs')),
          )
          .selected,
      {true},
    );
    expect(find.byKey(const Key('ai-brief-scroll')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(
      tester.state<ScrollableState>(aiBriefScrollable).position.pixels,
      closeTo(aiBriefOffsetBeforeEvidence, .1),
    );

    tester.view.physicalSize = const Size(400, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      evidence,
      300,
      scrollable: aiBriefScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(evidence);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<bool>>(
            find.byKey(const Key('review-content-tabs')),
          )
          .selected,
      {false},
    );
    expect(find.byKey(const Key('ai-brief-scroll')), findsNothing);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('translation-only changes keep the AI Brief banner hidden', (
    tester,
  ) async {
    final document = _simpleDocument();
    final controller = await _controllerForDocument(
      document,
      settings: _configuredTranslationAppSettings,
      translationService: _ImmediateTranslation(),
      translationCredentials: _LlmCredentials(),
      aiBrief: _overviewBrief(document, overview: 'Current overview'),
    );
    addTearDown(controller.dispose);

    await controller.translateJob('job', targetLanguage: 'zh-Hans');
    expect(
      controller.allJobs.single.document!.segments.single.translatedText,
      '翻译。',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-brief-outdated')), findsNothing);
    expect(find.text('Current overview'), findsOneWidget);
  });

  testWidgets('AI Brief section actions appear only on hover', (tester) async {
    _setTestWindow(tester, const Size(1000, 760));
    final document = _simpleDocument();
    final controller = await _controllerForDocument(
      document,
      aiBrief: _overviewBrief(document, overview: 'Current overview'),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();

    final section = find.byKey(const Key('ai-brief-section-overview'));
    final actions = find.byKey(const Key('ai-brief-section-actions-overview'));
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    expect(
      find.descendant(of: section, matching: find.byIcon(Icons.copy_outlined)),
      findsNothing,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    final sectionSize = tester.getSize(section);
    await mouse.moveTo(tester.getCenter(section));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);
    expect(tester.getSize(section), sectionSize);
    expect(
      find.byKey(const Key('ai-brief-section-edit-overview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ai-brief-section-menu-overview')));
    await tester.pumpAndSettle();
    expect(find.text('Regenerate section'), findsOneWidget);
  });

  testWidgets('creating an AI Brief waits for dismissal and renders output', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-ai-brief-video-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/clip.mp4');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    debugTranscriptReviewPlayerFactory = () =>
        Player(platformPlayer: _ReviewFakePlatformPlayer());
    addTearDown(() => debugTranscriptReviewPlayerFactory = null);
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    final service = _PendingAiBrief();
    addTearDown(() {
      if (!service.release.isCompleted) service.release.complete();
    });
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: source.path,
      settings: const AppSettings(
        translationSettings: TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'brief-model',
        ),
      ),
      translationCredentials: _LlmCredentials(),
      aiBriefService: service,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: Consumer<AppController>(
          builder: (context, _, _) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            locale: const Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.byType(Video), findsOneWidget);

    await tester.tap(find.text('AI Brief').first);
    await tester.pump();
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);
    expect(find.byKey(const Key('cancel-ai-brief-toolbar')), findsNothing);
    await tester.tap(find.byKey(const Key('ai-brief-empty-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Provider model: brief-model'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-create-ai-brief')));
    await tester.pump();
    expect(service.started.isCompleted, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await service.started.future;
    expect(find.byType(AlertDialog), findsNothing);
    service.release.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    expect(find.text('Finished overview'), findsOneWidget);
    expect(find.byKey(const Key('ai-evidence-segment')), findsOneWidget);
    debugPrint = originalDebugPrint;
  });

  testWidgets('Language notes are opt-in and preserve learner settings', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 760));
    final service = _ImmediateAiBrief();
    final controller = await _controllerForDocument(
      _simpleDocument(),
      settings: const AppSettings(
        translationSettings: TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'brief-model',
        ),
      ),
      translationCredentials: _LlmCredentials(),
      aiBriefService: service,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: const Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI Brief').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-brief-empty-action')));
    await tester.pumpAndSettle();

    final chipFinder = find.byKey(const Key('ai-brief-section-languageNotes'));
    expect(tester.widget<FilterChip>(chipFinder).selected, isFalse);
    expect(find.byKey(const Key('ai-brief-learning-language')), findsNothing);
    expect(find.byKey(const Key('ai-brief-learning-level')), findsNothing);

    await tester.tap(chipFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-brief-learning-language')), findsOneWidget);
    expect(find.text('Auto-detect'), findsOneWidget);
    expect(find.text('Intermediate (B1–B2)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-brief-learning-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Japanese').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-brief-learning-level')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced (C1–C2)').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('confirm-create-ai-brief')));
    await tester.pumpAndSettle();

    expect(service.lastSections, contains(AiBriefSection.languageNotes));
    expect(service.lastLearningLanguage, 'ja');
    expect(service.lastLearningLevel, AiLearningLevel.advanced);
    expect(find.text('Language notes'), findsOneWidget);
    expect(find.text('Useful expressions'), findsOneWidget);
    expect(find.text('Hello'), findsWidgets);
    expect(find.text('A friendly greeting.'), findsOneWidget);
    final languageNotesSection = find.byKey(
      const Key('ai-brief-section-language-notes'),
    );
    expect(
      find.descendant(
        of: languageNotesSection,
        matching: find.byIcon(Icons.language_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('ai-brief-section-header-language-notes')),
        matching: find.text('Advanced (C1–C2)'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getBottomLeft(
            find.byKey(const Key('ai-brief-section-meta-language-notes')),
          )
          .dy,
      lessThan(tester.getTopLeft(find.text('Useful expressions')).dy),
    );
    tester.view.physicalSize = const Size(400, 760);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1000, 760);
    await tester.pumpAndSettle();
    final noteTile = find.byKey(const Key('ai-language-note-note'));
    final noteMenuReveal = find.byKey(
      const Key('ai-language-note-menu-reveal-note'),
    );
    expect(noteTile, findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(noteMenuReveal).opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    final tileSizeBeforeHover = tester.getSize(noteTile);
    await mouse.moveTo(tester.getCenter(noteTile));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(noteMenuReveal).opacity, 1);
    expect(tester.getSize(noteTile), tileSizeBeforeHover);

    await tester.tap(find.byKey(const Key('ai-language-note-menu-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit item').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ai-language-note-explanation')),
      'An edited explanation.',
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('An edited explanation.'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(noteMenuReveal).opacity, 0);
    await mouse.moveTo(tester.getCenter(noteTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-language-note-menu-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete item').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-language-note-note')), findsNothing);
  });

  testWidgets('AI Brief progress uses natural stage language', (tester) async {
    final service = _PendingAiBrief();
    final controller = await _controllerForDocument(
      _simpleDocument(),
      settings: const AppSettings(
        translationSettings: TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'brief-model',
        ),
      ),
      translationCredentials: _LlmCredentials(),
      aiBriefService: service,
    );
    addTearDown(controller.dispose);
    addTearDown(() {
      if (!service.release.isCompleted) service.release.complete();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: const Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI Brief').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-brief-empty-action')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Estimated AI requests'), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-create-ai-brief')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await service.started.future;
    await tester.pump();

    expect(find.text('Analyzing the transcript…'), findsOneWidget);
    expect(find.textContaining('0/1'), findsNothing);
    expect(find.byKey(const Key('cancel-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('cancel-ai-brief-progress')), findsOneWidget);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('review-header'))).height, 64);
    expect(
      find.descendant(
        of: find.byKey(const Key('review-content-tabs')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, isNull);

    service.release.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('audio AI Brief uses a resizable 1:1 companion workspace', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final document = _simpleDocument();
    final controller = await _controllerForDocument(
      document,
      aiBrief: _overviewBrief(document, overview: 'Audio overview'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();

    final sourcePane = find.byKey(const Key('ai-brief-companion-source-pane'));
    final briefPane = find.byKey(const Key('ai-brief-companion-brief-pane'));
    final divider = find.byKey(const Key('ai-brief-companion-divider'));
    expect(find.byKey(const Key('audio-review-companion')), findsOneWidget);
    expect(find.byKey(const Key('video-ai-brief-companion')), findsNothing);
    expect(find.byKey(const Key('transcript-pane-header')), findsOneWidget);
    expect(find.byKey(const Key('ai-brief-pane-header')), findsOneWidget);
    expect(find.byKey(const Key('open-transcript-search')), findsOneWidget);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsOneWidget);
    expect(
      tester.getSize(sourcePane).width,
      closeTo(tester.getSize(briefPane).width, 1),
    );
    expect(
      tester.getRect(find.byKey(const Key('audio-review-media'))).bottom,
      lessThanOrEqualTo(tester.getRect(sourcePane).top),
    );

    final initialSourceWidth = tester.getSize(sourcePane).width;
    await tester.drag(divider, const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(sourcePane).width,
      closeTo(initialSourceWidth + 100, 1),
    );

    await tester.drag(divider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(briefPane).width, greaterThanOrEqualTo(420));
    await tester.drag(divider, const Offset(-4000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sourcePane).width, greaterThanOrEqualTo(420));
    expect(tester.takeException(), isNull);
  });

  testWidgets('video AI Brief stacks media above the source transcript', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final document = _simpleDocument();
    final controller = await _controllerForDocument(
      document,
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
      aiBrief: _overviewBrief(document, overview: 'Video overview'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();

    final companion = find.byKey(const Key('video-ai-brief-companion'));
    final media = find.byKey(const Key('video-ai-brief-media'));
    final transcript = find.byKey(const Key('transcript-pane'));
    final sourcePane = find.byKey(const Key('ai-brief-companion-source-pane'));
    final briefPane = find.byKey(const Key('ai-brief-companion-brief-pane'));
    expect(companion, findsOneWidget);
    expect(find.byKey(const Key('audio-review-companion')), findsNothing);
    expect(
      tester.getSize(sourcePane).width,
      closeTo(tester.getSize(briefPane).width, 1),
    );
    expect(
      tester.getRect(media).bottom,
      lessThanOrEqualTo(tester.getRect(transcript).top),
    );
    expect(
      tester.getSize(media).height -
          tester.getSize(find.byKey(const Key('video-media-header'))).height -
          1 -
          VideoTransport.height,
      closeTo(tester.getSize(media).width / (16 / 9), .1),
    );

    final initialMediaHeight = tester.getSize(media).height;
    await tester.drag(
      find.byKey(const Key('ai-brief-companion-divider')),
      const Offset(100, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(media).height, greaterThan(initialMediaHeight));
    expect(
      tester.getSize(media).height -
          tester.getSize(find.byKey(const Key('video-media-header'))).height -
          1 -
          VideoTransport.height,
      closeTo(tester.getSize(media).width / (16 / 9), .1),
    );

    await tester.tap(find.byKey(const Key('video-audio-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-review-companion')), findsOneWidget);
    expect(find.byKey(const Key('video-ai-brief-companion')), findsNothing);
    expect(find.byKey(const Key('ai-brief-scroll')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
  });

  testWidgets('scrolling the AI Brief transcript keeps the video mounted', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-review-video-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/clip.mp4');
    await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
    debugTranscriptReviewPlayerFactory = () =>
        Player(platformPlayer: _ReviewFakePlatformPlayer());
    addTearDown(() => debugTranscriptReviewPlayerFactory = null);
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    final now = DateTime.now().toUtc();
    final document = TranscriptDocument(
      tokens: const [],
      segments: [
        for (var i = 0; i < 40; i++)
          TranscriptSegment(
            id: 's$i',
            startMs: i * 1000,
            endMs: i * 1000 + 900,
            text: 'Sentence $i for scrolling the companion transcript.',
          ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    final controller = await _controllerForDocument(
      document,
      metadata: _videoMetadata,
      sourcePath: source.path,
      aiBrief: _overviewBrief(document, overview: 'Video overview'),
    );
    addTearDown(controller.dispose);

    try {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: TranscriptReview(jobId: 'job')),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      await tester.tap(_reviewTab('AI Brief'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      final media = find.byKey(const Key('video-ai-brief-media'));
      final video = find.descendant(of: media, matching: find.byType(Video));
      expect(find.byKey(const Key('video-ai-brief-companion')), findsOneWidget);
      expect(media, findsOneWidget);
      expect(find.byKey(const Key('video-viewport')), findsOneWidget);
      expect(video, findsOneWidget);
      final videoElement = tester.element(video);
      expect(
        find.descendant(
          of: media,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const Key('transcript-scroll')),
        const Offset(0, -240),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('video-ai-brief-companion')), findsOneWidget);
      expect(find.byType(Video), findsOneWidget);
      expect(tester.element(video), same(videoElement));
      expect(
        find.descendant(
          of: media,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugPrint = originalDebugPrint;
    }
  });

  testWidgets('wide AI Brief transcript pane keeps display toggles visible', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1000, 700));
    final document = _simpleDocument();
    final controller = await _controllerForDocument(
      document,
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
      aiBrief: _overviewBrief(document, overview: 'Video overview'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: TranscriptReview(jobId: 'job')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI 简报'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-ai-brief-companion')), findsOneWidget);
    expect(find.byKey(const Key('transcript-pane-title')), findsNothing);
    expect(find.text('转写'), findsOneWidget);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsOneWidget);
    expect(find.byKey(const Key('toggle-timestamps')), findsOneWidget);
    expect(find.byTooltip('显示说话人'), findsOneWidget);
    expect(find.byTooltip('显示时间戳'), findsOneWidget);
    expect(find.byKey(const Key('copy-transcript-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-transcript-toolbar')), findsOneWidget);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.byTooltip('导出'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-transcript-menu')), findsNothing);
    expect(find.byKey(const Key('export-transcript-menu')), findsNothing);
  });

  testWidgets('companion divider resets to 1:1 when the task changes', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final now = DateTime.now().toUtc();
    TranscriptDocument document(String id) => TranscriptDocument(
      tokens: const [],
      segments: [
        TranscriptSegment(
          id: id,
          startMs: 0,
          endMs: 1000,
          text: '$id transcript',
        ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    final firstDocument = document('first');
    final secondDocument = document('second');
    TranscriptionJob job(String id, TranscriptDocument value) =>
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '/missing/$id.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: value,
          aiBrief: _overviewBrief(value, overview: '$id overview'),
        );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        job('first', firstDocument),
        job('second', secondDocument),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final selectedJob = ValueNotifier('first');
    addTearDown(selectedJob.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: selectedJob,
              builder: (_, jobId, __) => TranscriptReview(jobId: jobId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();
    final divider = find.byKey(const Key('ai-brief-companion-divider'));
    final sourcePane = find.byKey(const Key('ai-brief-companion-source-pane'));
    final briefPane = find.byKey(const Key('ai-brief-companion-brief-pane'));
    await tester.drag(divider, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(sourcePane).width,
      isNot(closeTo(tester.getSize(briefPane).width, 1)),
    );

    selectedJob.value = 'second';
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-brief-companion-split')), findsOneWidget);
    expect(
      find.byKey(const Key('ai-brief-companion-brief-pane')),
      findsNothing,
    );
    await tester.tap(_reviewTab('AI Brief'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(sourcePane).width,
      closeTo(tester.getSize(briefPane).width, 1),
    );
    expect(find.text('second overview'), findsOneWidget);
  });
}

class _ShortcutPodcastPlayer extends PodcastPlayer {
  final offsets = <Duration>[];
  bool active = true;
  int toggleCalls = 0;

  @override
  bool get hasSession => active;

  @override
  Future<void> skip(Duration delta) async => offsets.add(delta);

  @override
  Future<void> toggle() async => toggleCalls++;
}

class _PlaybackFlushRepository implements PodcastRepository {
  _PlaybackFlushRepository(this.events);

  final List<String> events;
  Map<String, PodcastListenProgress> progress = {
    'episode': PodcastListenProgress(
      positionMs: 185000,
      durationMs: 1920000,
      updatedAt: DateTime.utc(2026),
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
    events.add('podcast-save');
    this.progress = Map.of(progress);
  }
}

Iterable<TextSpan> _descendantSpans(TextSpan root) sync* {
  for (final child
      in root.children?.whereType<TextSpan>() ?? const <TextSpan>[]) {
    yield child;
    yield* _descendantSpans(child);
  }
}

List<String?> _backgroundTexts(WidgetTester tester) {
  final richText = tester.widget<RichText>(
    find.descendant(
      of: find.byType(PlaybackHighlightedText),
      matching: find.byType(RichText),
    ),
  );
  final root = richText.text as TextSpan;
  return _descendantSpans(root)
      .where((span) => span.style?.backgroundColor != null)
      .map((span) => span.text)
      .toList();
}

class _EditorHarness extends StatefulWidget {
  const _EditorHarness({required this.onSaved, required this.onSeek});

  final ValueChanged<String> onSaved;
  final VoidCallback onSeek;

  @override
  State<_EditorHarness> createState() => _EditorHarnessState();
}

class _EditorHarnessState extends State<_EditorHarness> {
  TranscriptSegment _segment = const TranscriptSegment(
    id: 'editable',
    startMs: 0,
    endMs: 1000,
    text: 'Original sentence',
  );
  bool _editing = false;

  @override
  Widget build(BuildContext context) => TranscriptSegmentEditor(
    segment: _segment,
    tokens: const [],
    positionMs: 0,
    isCurrent: false,
    query: '',
    speakerName: '',
    showSpeaker: false,
    showTimestamp: true,
    isEditing: _editing,
    onSeek: ({required reason}) => widget.onSeek(),
    onEdit: () => setState(() => _editing = true),
    onCancel: () => setState(() => _editing = false),
    onSave: (text) async {
      widget.onSaved(text);
      setState(() {
        _segment = _segment.copyWith(text: text);
        _editing = false;
      });
    },
  );
}

class _RepeatEditorHarness extends StatefulWidget {
  const _RepeatEditorHarness();

  @override
  State<_RepeatEditorHarness> createState() => _RepeatEditorHarnessState();
}

class _RepeatEditorHarnessState extends State<_RepeatEditorHarness> {
  bool _repeating = false;
  bool _editing = false;

  @override
  Widget build(BuildContext context) => TranscriptSegmentEditor(
    segment: const TranscriptSegment(
      id: 'repeatable',
      startMs: 100,
      endMs: 1000,
      text: 'Repeatable sentence',
    ),
    tokens: const [],
    positionMs: 0,
    isCurrent: false,
    query: '',
    speakerName: '',
    showSpeaker: false,
    showTimestamp: false,
    isEditing: _editing,
    isRepeating: _repeating,
    onToggleRepeat: () => setState(() => _repeating = !_repeating),
    onSeek: _noopSegmentSeek,
    onEdit: () => setState(() => _editing = true),
    onCancel: () => setState(() => _editing = false),
    onSave: (_) async => setState(() => _editing = false),
  );
}

class _TwoEditorHarness extends StatefulWidget {
  const _TwoEditorHarness();

  @override
  State<_TwoEditorHarness> createState() => _TwoEditorHarnessState();
}

class _TwoEditorHarnessState extends State<_TwoEditorHarness> {
  static const _segments = [
    TranscriptSegment(
      id: 'first',
      startMs: 0,
      endMs: 1000,
      text: 'First original',
    ),
    TranscriptSegment(
      id: 'second',
      startMs: 1200,
      endMs: 2000,
      text: 'Second original',
    ),
  ];
  String? _editingId;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final segment in _segments)
        TranscriptSegmentEditor(
          segment: segment,
          tokens: const [],
          positionMs: 0,
          isCurrent: false,
          query: '',
          speakerName: '',
          showSpeaker: false,
          showTimestamp: true,
          isEditing: _editingId == segment.id,
          onSeek: _noopSegmentSeek,
          onEdit: () => setState(() => _editingId = segment.id),
          onCancel: () => setState(() => _editingId = null),
          onSave: (_) async => setState(() => _editingId = null),
        ),
    ],
  );
}

Future<AppController> _controllerForDocument(
  TranscriptDocument document, {
  MediaMetadata? metadata,
  String sourcePath = '/missing/test.wav',
  TranslationState translationState = const TranslationState(),
  AppSettings settings = const AppSettings(),
  TranslationService? translationService,
  TranslationCredentialStore? translationCredentials,
  MediaService? mediaService,
  AiBriefService? aiBriefService,
  AiBrief? aiBrief,
  AiGenerationState aiGenerationState = const AiGenerationState(),
  JobSourceOrigin sourceOrigin = JobSourceOrigin.manual,
  PodcastEpisodeProvenance? podcastProvenance,
  TranscriptionProvider transcriptionProvider = TranscriptionProvider.soniox,
  TranscriptAcquisitionMode transcriptAcquisitionMode =
      TranscriptAcquisitionMode.soniox,
  TranscriptSource? transcriptSource,
  ImportedSubtitleProvenance? importedSubtitleProvenance,
  ForcedAlignmentService? forcedAlignmentService,
  ForcedAlignmentState forcedAlignment = const ForcedAlignmentState(),
}) async {
  final now = DateTime.now().toUtc();
  final controller = AppController(
    credentialStore: _Credentials(),
    settingsRepository: _Settings(settings),
    jobRepository: _Jobs([
      TranscriptionJob(
        id: 'job',
        batchId: 'batch',
        sourcePath: sourcePath,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        metadata: metadata,
        document: document,
        translationState: translationState,
        aiBrief: aiBrief,
        aiGenerationState: aiGenerationState,
        sourceOrigin: sourceOrigin,
        podcastProvenance: podcastProvenance,
        transcriptionProvider: transcriptionProvider,
        transcriptAcquisitionMode: transcriptAcquisitionMode,
        transcriptSource: transcriptSource,
        importedSubtitleProvenance: importedSubtitleProvenance,
        forcedAlignment: forcedAlignment,
      ),
    ]),
    mediaService: mediaService ?? _Media(),
    sourceResolver: const LocalMediaSourceResolver(),
    sonioxClient: _Soniox(),
    exporter: const DefaultTranscriptExporter(),
    translationCredentialStore: translationCredentials,
    translationService: translationService,
    aiBriefService: aiBriefService,
    forcedAlignmentService: forcedAlignmentService,
  );
  await controller.initialize();
  return controller;
}

class _BlockingAlignmentService implements ForcedAlignmentService {
  _BlockingAlignmentService({this.alignedSegments = 0, this.totalSegments});

  final int alignedSegments;
  final int? totalSegments;
  final release = Completer<void>();

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    onProgress?.call(0.42, 'aligning');
    await release.future;
    return AlignmentResult(
      tokens: const [],
      status: ForcedAlignmentStatus.partial,
      alignedSegments: alignedSegments,
      totalSegments: totalSegments ?? request.document.segments.length,
      warningCode: 'alignment_partial',
    );
  }
}

Future<void> _selectTranslationView(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('translation-view-mode')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder _reviewTab(String label) => find.descendant(
  of: find.byKey(const Key('review-content-tabs')),
  matching: find.text(label),
);

void _noop() {}

void _noopSegmentSeek({required TranscriptSeekReason reason}) {}

void _setTestWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _waitForController(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Controller condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

TranscriptDocument _simpleDocument() {
  final now = DateTime.now().toUtc();
  return TranscriptDocument(
    tokens: const [],
    segments: const [
      TranscriptSegment(id: 'segment', startMs: 0, endMs: 1000, text: 'Hello'),
    ],
    speakers: const [],
    updatedAt: now,
  );
}

AiBrief _overviewBrief(
  TranscriptDocument document, {
  required String overview,
}) => AiBrief(
  overview: overview,
  overviewEvidenceSegmentIds: [document.segments.first.id],
  chapters: const [],
  insights: const [],
  outputLanguage: 'en',
  model: 'brief-model',
  selectedSections: const {AiBriefSection.overview},
  generatedAt: document.updatedAt,
  sourceTranscriptUpdatedAt: document.updatedAt,
);

const _videoMetadata = MediaMetadata(
  sizeBytes: 1,
  durationMs: 1000,
  hasAudio: true,
  hasVideo: true,
  formatName: 'mp4',
);

const _configuredTranslationAppSettings = AppSettings(
  translationSettings: TranslationSettings(
    baseUrl: 'http://localhost:1234/v1',
    model: 'test-model',
    targetLanguage: 'zh-Hans',
  ),
);

Future<AppController> _pumpSpeakerStrip(WidgetTester tester) async {
  final now = DateTime.now().toUtc();
  final controller = AppController(
    credentialStore: _Credentials(),
    settingsRepository: _Settings(),
    jobRepository: _Jobs([
      TranscriptionJob(
        id: 'job',
        batchId: 'batch',
        sourcePath: '/missing/test.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'segment',
              startMs: 0,
              endMs: 1000,
              text: 'Hello',
              speaker: '1',
            ),
          ],
          speakers: const [SpeakerProfile(id: '1', name: 'Speaker 1')],
          updatedAt: now,
        ),
      ),
    ]),
    mediaService: _Media(),
    sourceResolver: const LocalMediaSourceResolver(),
    sonioxClient: _Soniox(),
    exporter: const DefaultTranscriptExporter(),
  );
  await controller.initialize();

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: Consumer<AppController>(
            builder: (context, controller, _) {
              final job = controller.allJobs.single;
              return SpeakerStrip(job: job, document: job.document!);
            },
          ),
        ),
      ),
    ),
  );
  return controller;
}

Future<_ReviewFakePlatformPlayer> _pumpMimicReview(
  WidgetTester tester,
  SentenceRepeatLoopController loop, {
  AppSettings settings = const AppSettings(),
  Size size = const Size(1400, 1000),
  List<TranscriptSegment>? segments,
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('meow-mimic-'),
  ))!;
  addTearDown(() => directory.delete(recursive: true));
  final source = File('${directory.path}/listen.mp4');
  await tester.runAsync(() => source.writeAsBytes(const [0, 1, 2, 3]));
  late _ReviewFakePlatformPlayer platform;
  debugTranscriptReviewPlayerFactory = () => Player(
    platformPlayer: platform = _ReviewFakePlatformPlayer(
      updatePlayingStateOnControls: true,
    ),
  );
  debugTranscriptReviewSourceExists = (_) async => true;
  debugTranscriptReviewSentenceRepeatLoopFactory = (_) => loop;
  addTearDown(() {
    debugTranscriptReviewPlayerFactory = null;
    debugTranscriptReviewSourceExists = null;
    debugTranscriptReviewSentenceRepeatLoopFactory = null;
  });
  final controller = await _controllerForDocument(
    TranscriptDocument(
      tokens: const [],
      segments:
          segments ??
          const [
            TranscriptSegment(
              id: 'a',
              startMs: 0,
              endMs: 1000,
              text: 'First sentence.',
              translatedText: '第一句',
            ),
            TranscriptSegment(
              id: 'b',
              startMs: 2000,
              endMs: 3000,
              text: 'Second sentence.',
              translatedText: '第二句',
            ),
            TranscriptSegment(
              id: 'c',
              startMs: 4000,
              endMs: 5000,
              text: 'Third sentence.',
              translatedText: '第三句',
            ),
          ],
      speakers: const [],
      updatedAt: DateTime.utc(2026),
    ),
    sourcePath: source.path,
    metadata: const MediaMetadata(
      sizeBytes: 4,
      durationMs: 5000,
      hasAudio: true,
      hasVideo: true,
      formatName: 'mp4',
    ),
    transcriptSource: TranscriptSource.importedSubtitle,
    transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
    settings: settings,
  );
  addTearDown(controller.dispose);
  controller.openInWorkspace('job');
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: TranscriptReview(jobId: 'job')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();

  return platform;
}

Future<void> _openMimic(WidgetTester tester) async {
  final toolbarButton = find.byKey(const Key('toggle-mimic'));
  if (toolbarButton.evaluate().isNotEmpty) {
    await tester.tap(toolbarButton);
  } else {
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('more-toggle-mimic')));
  }
  await tester.pumpAndSettle();
}

String _mimicReps(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('mimic-rep-count'))).data!;

class _ReviewFakePlatformPlayer extends PlatformPlayer {
  _ReviewFakePlatformPlayer({
    this.emitPositionResetOnOpen = false,
    this.updatePlayingStateOnControls = false,
  }) : super(configuration: const PlayerConfiguration()) {
    completer.complete();
  }

  final bool emitPositionResetOnOpen;
  final bool updatePlayingStateOnControls;

  @override
  Future<int> get handle async => 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
    if (emitPositionResetOnOpen) emitPosition(Duration.zero);
  }

  int openCalls = 0;
  int playOrPauseCalls = 0;
  int pauseCalls = 0;
  final List<String> operations = [];
  final List<Duration> seekDurations = [];
  final List<SubtitleTrack> subtitleTrackSelections = [];

  @override
  Future<void> play() async {
    operations.add('play');
    if (updatePlayingStateOnControls) emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    operations.add('pause');
    if (updatePlayingStateOnControls) emitPlaying(false);
  }

  @override
  Future<void> playOrPause() async => playOrPauseCalls++;

  @override
  Future<void> seek(Duration duration) async {
    seekDurations.add(duration);
    operations.add('seek:${duration.inMilliseconds}');
    if (emitPositionResetOnOpen) emitPosition(duration);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleTrackSelections.add(track);
  }

  void emitPosition(Duration duration) {
    state = state.copyWith(position: duration);
    positionController.add(duration);
  }

  void emitPlaying(bool playing) {
    state = state.copyWith(playing: playing);
    playingController.add(playing);
  }

  void emitRate(double rate) {
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  void emitCompleted({bool completed = true}) {
    state = state.copyWith(completed: completed);
    completedController.add(completed);
  }
}

class _RecordingSentenceRepeatLoopController
    implements SentenceRepeatLoopController {
  final List<String> events = [];

  @override
  Future<void> clear() async => events.add('clear');

  @override
  Future<void> setRange({required int startMs, required int endMs}) async {
    events.add('range:$startMs:$endMs');
  }
}

class _GatedSentenceRepeatLoopController
    implements SentenceRepeatLoopController {
  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() => _gate?.complete();

  @override
  Future<void> clear() async {}

  @override
  Future<void> setRange({required int startMs, required int endMs}) async {
    await _gate?.future;
  }
}

class _FailingSentenceRepeatLoopController
    implements SentenceRepeatLoopController {
  @override
  Future<void> clear() async {}

  @override
  Future<void> setRange({required int startMs, required int endMs}) =>
      Future.error(StateError('native loop unavailable'));
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> writeApiKey(String key) async {}
}

class _ConfiguredCredentials extends _Credentials {
  @override
  Future<String?> readApiKey() async => 'configured';
}

class _BlockingTranslation implements TranslationService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async => const [];

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {
    started.complete();
    await release.future;
  }
}

class _ImmediateTranslation implements TranslationService {
  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async => const [];

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {
    await onBatch(
      {for (final segment in segments) segment.id: '翻译。'},
      segments.length,
      segments.length,
    );
  }
}

class _LlmCredentials implements TranslationCredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'configured';

  @override
  Future<void> writeApiKey(String key) async {}
}

class _ImmediateAiBrief implements AiBriefService {
  Set<AiBriefSection> lastSections = const {};
  String? lastLearningLanguage;
  AiLearningLevel? lastLearningLevel;

  @override
  int estimateRequestCount(
    TranscriptDocument document,
    Set<AiBriefSection> sections,
  ) => 2;

  @override
  Future<AiBrief> generate({
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    lastSections = Set<AiBriefSection>.of(sections);
    lastLearningLanguage = learningLanguage;
    lastLearningLevel = learningLevel;
    await onProgress?.call('analyzing', 1, 2);
    await onProgress?.call('synthesizing', 2, 2);
    return AiBrief(
      overview: 'Evidence-backed overview',
      overviewEvidenceSegmentIds: [document.segments.first.id],
      chapters: const [],
      insights: const [],
      languageNotes: sections.contains(AiBriefSection.languageNotes)
          ? [
              AiLanguageNote(
                id: 'note',
                kind: AiLanguageNoteKind.expression,
                term: 'Hello',
                explanation: 'A friendly greeting.',
                sourceExcerpt: 'Hello',
                evidenceSegmentIds: [document.segments.first.id],
              ),
            ]
          : const [],
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      outputLanguage: outputLanguage,
      model: settings.model,
      selectedSections: sections,
      generatedAt: DateTime.now().toUtc(),
      sourceTranscriptUpdatedAt: document.updatedAt,
    );
  }
}

class _PendingAiBrief implements AiBriefService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  int estimateRequestCount(
    TranscriptDocument document,
    Set<AiBriefSection> sections,
  ) => 1;

  @override
  Future<AiBrief> generate({
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    started.complete();
    await release.future;
    return AiBrief(
      overview: 'Finished overview',
      overviewEvidenceSegmentIds: [document.segments.first.id],
      chapters: const [],
      insights: const [],
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      outputLanguage: outputLanguage,
      model: settings.model,
      selectedSections: sections,
      generatedAt: DateTime.now().toUtc(),
      sourceTranscriptUpdatedAt: document.updatedAt,
    );
  }
}

class _Settings implements SettingsRepository {
  _Settings([this.value = const AppSettings()]);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _SupportedLocalStt implements LocalSttService {
  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) => throw UnimplementedError();
}

class _DropCountingLocalStt implements LocalSttService {
  int calls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    calls++;
    return LocalSttResult(
      document: _simpleDocument(),
      model: TranscriptionModelReference(
        id: LocalSpeechModels.mossDiarizeCoreMlInt8.id,
        revision: LocalSpeechModels.mossDiarizeCoreMlInt8.revision,
      ),
    );
  }
}

class _Jobs implements JobRepository {
  _Jobs(this.jobs);

  final List<TranscriptionJob> jobs;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<TranscriptionJob>> loadAll() async => jobs;

  @override
  Future<void> save(TranscriptionJob job) async {
    final index = jobs.indexWhere((item) => item.id == job.id);
    if (index >= 0) jobs[index] = job;
  }
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {}

  @override
  Future<MediaDiagnostics> diagnostics() async =>
      const MediaDiagnostics(available: true);

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => sourcePath;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => const MediaMetadata(
    sizeBytes: 1,
    durationMs: 1000,
    hasAudio: true,
    hasVideo: false,
    formatName: 'wav',
  );

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _CountingWaveformMedia extends _Media {
  int waveformRequests = 0;

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async {
    waveformRequests++;
    return '/tmp/$cacheKey-waveform.png';
  }
}

class _Soniox implements SonioxClient {
  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'transcription';

  @override
  Future<void> deleteFile(String id) async {}

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {};

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async =>
      const SonioxTranscriptionState(status: 'completed');

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => 'file';

  @override
  Future<void> validateKey({String? apiKey}) async {}
}

class _TranscriptSoniox extends _Soniox {
  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {
    'tokens': [
      {'text': 'Done.', 'start_ms': 0, 'end_ms': 800, 'speaker': '1'},
    ],
  };
}
