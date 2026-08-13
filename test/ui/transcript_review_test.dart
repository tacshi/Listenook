import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/app_shell.dart';
import 'package:meow_stt/ui/library_page.dart';
import 'package:meow_stt/ui/review_fullscreen_controller.dart';
import 'package:meow_stt/ui/transcript_review.dart';
import 'package:meow_stt/ui/workspace_page.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
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

  test('sentence repeat tolerates seek undershoot near its beginning', () {
    const valid = TranscriptSegment(
      id: 'valid',
      startMs: 1000,
      endMs: 1900,
      text: 'Repeat me',
    );
    const invalid = TranscriptSegment(
      id: 'invalid',
      startMs: 500,
      endMs: 500,
      text: 'No duration',
    );

    expect(shouldRestartRepeatedSentence(valid, 749), isTrue);
    expect(shouldRestartRepeatedSentence(valid, 750), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 999), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1000), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1899), isFalse);
    expect(shouldRestartRepeatedSentence(valid, 1900), isTrue);
    expect(shouldRestartRepeatedSentence(valid, 2200), isTrue);
    expect(shouldRestartRepeatedSentence(invalid, 500), isFalse);
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
    _setTestWindow(tester, const Size(1000, 700));
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

    await tester.tap(find.text('AI Brief').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript').first);
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

      final toolbar = find.byKey(const Key('review-toolbar-row'));
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
        find.byKey(const Key('translation-view-mode')),
      );
      final toolbarRect = tester.getRect(toolbar);
      final focus = tester.getRect(
        find.byKey(const Key('focus-current-sentence')),
      );
      final more = tester.getRect(find.byKey(const Key('review-toolbar-more')));
      expect(focus.left - dropdown.right, lessThanOrEqualTo(16));
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
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-toggle-speakers')), findsOneWidget);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsOneWidget);
    expect(find.text('Translate unfinished with LLM'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Translation is incomplete')).style?.color,
      Colors.orange.shade700,
    );
  });

  testWidgets('active translation exposes only the adjacent cancel icon', (
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
    expect(find.byKey(const Key('review-toolbar-more')), findsOneWidget);
    expect(find.byKey(const Key('translation-status-strip')), findsOneWidget);
    expect(find.byKey(const Key('translation-view-mode')), findsNothing);
    expect(find.byKey(const Key('toggle-speaker-labels')), findsNothing);
    expect(find.byKey(const Key('toggle-timestamps')), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('translation-toolbar-action')),
          )
          .tooltip,
      'Cancel',
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('translation-toolbar-action')),
          )
          .style
          ?.backgroundColor
          ?.resolve({}),
      isNull,
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
    expect(translatedDecoration.border, isNotNull);
    expect(pendingDecoration.color, isNull);
    expect(pendingDecoration.border, isNull);

    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pump(const Duration(milliseconds: 300));
    final translatedMode = find.byKey(
      const Key('translation-mode-translated-menu'),
    );
    expect(translatedMode, findsOneWidget);
    expect(
      tester
          .widget<CheckedPopupMenuItem>(
            find.byKey(const Key('translation-mode-original-menu')),
          )
          .checked,
      isTrue,
    );
    expect(
      tester.widget<CheckedPopupMenuItem>(translatedMode).checked,
      isFalse,
    );
    expect(find.byKey(const Key('more-toggle-speakers')), findsOneWidget);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-menu')), findsNothing);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    translation.release.complete();
    await translationFuture;
  });

  testWidgets('narrow transcript pane keeps commands in the unified toolbar', (
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
    final toolbar = find.byKey(const Key('review-toolbar-row'));
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
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('review-toolbar-more'))).right,
      closeTo(tester.getRect(toolbar).right, 0.1),
    );
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.text('Retranslate all with LLM'), findsOneWidget);
  });

  testWidgets('search expands in the right action lane and clears cleanly', (
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
    final tabsRect = tester.getRect(
      find.byKey(const Key('review-content-tabs')),
    );
    expect(find.byKey(const Key('review-filename')), findsOneWidget);
    expect(tester.getRect(search).left, greaterThan(tabsRect.right));
    expect(
      tester.getCenter(find.byKey(const Key('close-transcript-search'))).dx,
      greaterThan(tabsRect.right),
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
    expect(find.byKey(const Key('review-toolbar-row')), findsNothing);
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

  testWidgets('unified transcript toolbar adapts at each breakpoint', (
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
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toggle-speaker-labels')), findsNothing);
    expect(find.byKey(const Key('toggle-timestamps')), findsNothing);
    expect(find.byKey(const Key('translation-view-mode')), findsOneWidget);
    expect(find.byKey(const Key('focus-current-sentence')), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-toggle-speakers')), findsOneWidget);
    expect(find.byKey(const Key('more-toggle-timestamps')), findsOneWidget);
    expect(
      find.byKey(const Key('translation-mode-original-menu')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(600, 700);
    await tester.pumpAndSettle();
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
      tester.getCenter(find.text('转写')).dy,
      closeTo(tester.getCenter(find.text('AI 简报')).dy, 1),
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
    final filename = tester.widget<Text>(filenameFinder);
    expect(filename.data, fileName);
    expect(filename.maxLines, 1);
    expect(filename.overflow, TextOverflow.ellipsis);
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

  testWidgets('timestamp sits above repeat and repeat aligns with text', (
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
          .getTopRight(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dx,
      closeTo(
        tester
            .getTopRight(find.byKey(const ValueKey('segment-repeat-aligned')))
            .dx,
        1,
      ),
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

  testWidgets('read-only sentences stay borderless in light and dark themes', (
    tester,
  ) async {
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
      lessThanOrEqualTo(44),
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
    expect(tester.getCenter(cancel).dx, closeTo(tester.getCenter(save).dx, 1));
    expect(tester.getCenter(cancel).dy, lessThan(tester.getCenter(save).dy));
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

  testWidgets('library filter chips are ordered and mutually exclusive', (
    tester,
  ) async {
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([]),
      mediaService: _Media(),
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
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect((chips[0].label as Text).data, 'All');
    expect((chips[1].label as Text).data, 'Last 7 days');
    expect(chips.map((chip) => chip.selected), [true, false, false, false]);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Last 7 days'));
    await tester.pump();

    final updated = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect(updated.map((chip) => chip.selected), [false, true, false, false]);
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
      containsAll(['Workspace (⌘1)', 'Library (⌘2)', 'Settings (⌘,)']),
    );
    expect(
      tester.widget<IconButton>(sidebarToggle).tooltip,
      'Hide sidebar (⌘B)',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 1);
    expect(find.byKey(const Key('library-page-title')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 2);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);
    await tester.tap(find.byKey(const Key('soniox-key-field')));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 0);
    expect(find.byKey(const Key('workspace-page-title')), findsOneWidget);

    await messenger.handlePlatformMessage(
      'app.meowstt.desktop/navigation',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('showSettings'),
      ),
      null,
    );
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 2);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 0);

    await tester.tap(settingsNavigation);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 2);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.destinationIndex, 0);

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
      tester.getCenter(find.byIcon(Icons.space_dashboard_rounded)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Workspace (⌘1)'), findsOneWidget);
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

  testWidgets(
    'window close waits for review media before allowing native close',
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
        if (call.method == 'close') events.add('close');
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
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.updateSettings(
        controller.settings.copyWith(onboardingComplete: true),
      );
      final reviewController = ReviewFullscreenController();
      final mediaReleased = Completer<void>();
      final mediaOwner = Object();
      reviewController.registerMediaShutdown(mediaOwner, () async {
        events.add('media-start');
        await mediaReleased.future;
        events.add('media-done');
      });

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
      await tester.pumpAndSettle();
      expect(events, ['prevent:true']);
      events.clear();

      final dynamic appShellState = tester.state(find.byType(AppShell));
      final close = appShellState.onWindowClose() as Future<void>;
      await tester.pump();
      expect(events, ['media-start']);

      mediaReleased.complete();
      await close;
      expect(events, [
        'media-start',
        'media-done',
        'prevent:false',
        'close',
      ]);

      await appShellState.onWindowClose();
      expect(events, [
        'media-start',
        'media-done',
        'prevent:false',
        'close',
      ]);
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
      ..reopen('job')
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

    controller.setDestination(1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-page-title')), findsOneWidget);
    expect(find.byType(TranscriptReview), findsNothing);

    controller.setDestination(0);
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

  testWidgets(
    'workspace header owns export all and queue owns status summary',
    (tester) async {
      _setTestWindow(tester, const Size(1240, 820));
      final controller = await _controllerForDocument(_simpleDocument());
      addTearDown(controller.dispose);
      controller.reopen('job');

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [AppStrings.delegate],
            home: Scaffold(
              body: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pageTitle = find.byKey(const Key('workspace-page-title'));
      expect(
        tester.widget<Text>(pageTitle).style?.fontSize,
        Theme.of(tester.element(pageTitle)).textTheme.titleLarge?.fontSize,
      );
      expect(find.byKey(const Key('header-add-folder')), findsNothing);
      expect(find.byKey(const Key('header-add-files')), findsNothing);
      expect(find.byKey(const Key('export-all')), findsOneWidget);
      expect(find.text('Export all'), findsOneWidget);
      expect(
        find.byKey(const Key('file-queue-status-summary')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('queue-ready-status')), findsOneWidget);
      expect(find.byKey(const Key('queue-processing-status')), findsOneWidget);
      expect(find.byKey(const Key('queue-completed-status')), findsOneWidget);
      expect(find.byKey(const Key('queue-failed-status')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('queue-ready-status')),
          matching: find.text('0'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('queue-processing-status')),
          matching: find.text('0'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('queue-completed-status')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      final statusSummary = find.byKey(const Key('file-queue-status-summary'));
      expect(
        find.descendant(of: statusSummary, matching: find.text('Ready')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: statusSummary, matching: find.text('Processing')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: statusSummary, matching: find.text('Completed')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: statusSummary,
          matching: find.text('Needs attention'),
        ),
        findsNothing,
      );
      expect(
        find.text('Nothing uploads until you press Transcribe.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('export-all')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unexpected transcription failures show actionable guidance', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'failed-job',
          batchId: 'batch',
          sourcePath: '/missing/podcast-01.m4a',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.failed,
          errorCode: 'unexpected',
        ),
      ]),
      mediaService: _Media(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.reopen('failed-job');

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
          home: Scaffold(
            body: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('出现问题，请重试。'), findsNothing);
    expect(find.text('转写失败。请检查源文件、API 密钥和网络连接。'), findsOneWidget);
    expect(find.byKey(const Key('queue-failed-status')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('queue-failed-status')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('completed video collapses the queue and uses the wide split', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final controller = await _controllerForDocument(
      _simpleDocument(),
      metadata: _videoMetadata,
      sourcePath: '/missing/test.mp4',
    );
    addTearDown(controller.dispose);
    controller.reopen('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('file-queue-floating-button')), findsOneWidget);
    expect(find.byKey(const Key('file-queue-rail')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('expand-file-queue'))),
      const Size.square(48),
    );
    final queueOpacity = find.byKey(const Key('file-queue-floating-opacity'));
    expect(tester.widget<AnimatedOpacity>(queueOpacity).opacity, .25);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('expand-file-queue'))),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(queueOpacity).opacity, 1);
    await mouse.moveTo(const Offset(800, 20));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(queueOpacity).opacity, .25);

    final queueFab = tester.widget<FloatingActionButton>(
      find.byKey(const Key('expand-file-queue')),
    );
    queueFab.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(queueOpacity).opacity, 1);
    queueFab.focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(queueOpacity).opacity, .25);
    final layout = tester.getRect(
      find.byKey(const Key('workspace-review-layout')),
    );
    final collapsedReview = tester.getRect(find.byType(TranscriptReview));
    final queueButton = tester.getRect(
      find.byKey(const Key('expand-file-queue')),
    );
    expect(queueButton.left - collapsedReview.left, 16);
    expect(collapsedReview.bottom - queueButton.bottom, 16);
    expect(collapsedReview.left, layout.left);
    final reviewState = tester.state(find.byType(TranscriptReview));
    expect(find.byKey(const Key('video-review-split')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
    final initialMediaWidth = tester
        .getSize(find.byKey(const Key('video-review-media-pane')))
        .width;
    final initialTranscriptWidth = tester
        .getSize(find.byKey(const Key('video-review-transcript-pane')))
        .width;
    await tester.drag(
      find.byKey(const Key('video-transcript-divider')),
      const Offset(-100, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('video-review-media-pane'))).width,
      closeTo(initialMediaWidth - 100, 2),
    );
    expect(
      tester
          .getSize(find.byKey(const Key('video-review-transcript-pane')))
          .width,
      closeTo(initialTranscriptWidth + 100, 2),
    );

    await tester.tap(find.byKey(const Key('expand-file-queue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final expandingReview = tester.getRect(find.byType(TranscriptReview));
    final expandingQueue = tester.getRect(
      find.byKey(const Key('file-queue-panel')),
    );
    expect(expandingReview.left, greaterThan(layout.left));
    expect(expandingReview.left, lessThan(layout.left + 310));
    expect(expandingQueue.left, lessThan(layout.left));
    expect(expandingQueue.right, greaterThan(layout.left));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('file-queue-floating-button')), findsNothing);
    expect(find.byKey(const Key('collapse-file-queue')), findsOneWidget);
    final visibleStatusSummary = find.byKey(
      const Key('file-queue-status-summary'),
    );
    expect(
      find
          .descendant(of: visibleStatusSummary, matching: find.text('Ready'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      find
          .descendant(
            of: visibleStatusSummary,
            matching: find.text('Processing'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      find
          .descendant(
            of: visibleStatusSummary,
            matching: find.text('Completed'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: visibleStatusSummary,
        matching: find.text('Needs attention'),
      ),
      findsNothing,
    );
    final expandedReview = tester.getRect(find.byType(TranscriptReview));
    final queuePanel = tester.getRect(
      find.byKey(const Key('file-queue-panel')),
    );
    final collapseButton = tester.getRect(
      find.byKey(const Key('collapse-file-queue')),
    );
    expect(expandedReview.left, layout.left + 310);
    expect(queuePanel.left, layout.left);
    expect(queuePanel.bottom - collapseButton.bottom, lessThanOrEqualTo(8));
    expect(collapseButton.center.dy, greaterThan(queuePanel.center.dy));
    expect(tester.state(find.byType(TranscriptReview)), same(reviewState));

    controller.selectJob('job');
    await tester.pump();
    expect(find.byKey(const Key('file-queue-floating-button')), findsNothing);

    await tester.tap(find.byKey(const Key('collapse-file-queue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final collapsingReview = tester.getRect(find.byType(TranscriptReview));
    expect(collapsingReview.left, greaterThan(layout.left));
    expect(collapsingReview.left, lessThan(layout.left + 310));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('file-queue-floating-button')), findsOneWidget);
    expect(tester.getRect(find.byType(TranscriptReview)).left, layout.left);
    expect(tester.state(find.byType(TranscriptReview)), same(reviewState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue selection exits fullscreen before replacing the review', (
    tester,
  ) async {
    _setTestWindow(tester, const Size(1240, 820));
    final now = DateTime.now().toUtc();
    final document = _simpleDocument();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        for (final id in ['first', 'second'])
          TranscriptionJob(
            id: id,
            batchId: 'batch',
            sourcePath: '/missing/$id.wav',
            createdAt: now,
            updatedAt: now,
            status: JobStatus.completed,
            document: document,
          ),
      ]),
      mediaService: _Media(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller
      ..reopen('first')
      ..reopen('second')
      ..selectJob('first');
    final fullscreen = ReviewFullscreenController();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(
              onAddFiles: _noop,
              onAddFolder: _noop,
              fullscreenController: fullscreen,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    fullscreen.markEntered(navigator);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Text('Fullscreen route', key: Key('test-fullscreen-route')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final secondTile = find.ancestor(
      of: find.text('second.wav', skipOffstage: false),
      matching: find.byType(InkWell, skipOffstage: false),
    );
    tester.widget<InkWell>(secondTile.first).onTap!();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('test-fullscreen-route')), findsNothing);
    expect(fullscreen.isActive, isFalse);
    expect(controller.selectedJobId, 'second');
    expect(find.byType(TranscriptReview), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    controller.reopen('job');

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
                Expanded(
                  child: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('file-queue-floating-button')), findsOneWidget);
    expect(find.byKey(const Key('file-queue-rail')), findsNothing);
    expect(find.byKey(const Key('export-all')), findsOneWidget);
    expect(find.text('Export all'), findsNothing);
    expect(find.byKey(const Key('video-review-stacked')), findsOneWidget);
    expect(find.byKey(const Key('video-review-split')), findsNothing);
    expect(find.byKey(const Key('video-transcript-divider')), findsNothing);
    expect(find.byKey(const Key('video-audio-mode-toggle')), findsOneWidget);
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
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
    controller.reopen('job');

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
      ..reopen('job')
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
    final panelRect = tester.getRect(
      find.byKey(const Key('video-audio-mode-switcher')),
    );
    final toggleRect = tester.getRect(find.byKey(toggleKey));
    final videoToggleCenter = toggleRect.center;
    expect(media.waveformRequests, 0);
    expect(panelRect.right - toggleRect.right, closeTo(12, .1));
    expect(panelRect.bottom - toggleRect.bottom, closeTo(12, .1));
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
    final transitioningToggleCenter = tester.getCenter(find.byKey(toggleKey));
    await tester.pumpAndSettle();
    expect(media.waveformRequests, 1);
    expect(
      find.byKey(const ValueKey('video-audio-mode-audio')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('audio-review-layout')), findsOneWidget);
    expect(find.byKey(const Key('video-review-split')), findsNothing);
    final audioLayoutRect = tester.getRect(
      find.byKey(const Key('audio-review-layout')),
    );
    final audioToggleRect = tester.getRect(find.byKey(toggleKey));
    final audioToggleCenter = audioToggleRect.center;
    expect(
      transitioningToggleCenter.dx,
      inExclusiveRange(videoToggleCenter.dx, audioToggleCenter.dx),
    );
    expect(
      transitioningToggleCenter.dy,
      inExclusiveRange(audioToggleCenter.dy, videoToggleCenter.dy),
    );
    expect(audioLayoutRect.width, greaterThan(panelRect.width));
    expect(audioToggleRect.top, greaterThanOrEqualTo(audioLayoutRect.top));
    expect(audioToggleRect.bottom, lessThanOrEqualTo(audioLayoutRect.bottom));
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
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.reopen('first');

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
                  TranscriptReview(jobId: value.selectedJobId!),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const toggleKey = Key('video-audio-mode-toggle');
    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-audio-mode-audio')),
      findsOneWidget,
    );

    controller.reopen('second');
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
    controller.reopen('job');

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
    final fullscreen = tester.getRect(
      find.byKey(const Key('video-fullscreen')),
    );
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

  testWidgets('new transcription resets the page without opening files', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(920, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _pumpSpeakerStrip(tester);
    addTearDown(controller.dispose);
    controller.reopen('job');
    var addFilesCalls = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(
              onAddFiles: () => addFilesCalls++,
              onAddFolder: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Hello'), findsOneWidget);
    expect(find.byKey(const Key('header-add-folder')), findsNothing);
    expect(find.byKey(const Key('header-add-files')), findsNothing);
    expect(find.byKey(const Key('header-transcribe')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('new-transcription')));
    await tester.pumpAndSettle();

    expect(addFilesCalls, 0);
    expect(controller.workspaceJobs, isEmpty);
    expect(find.byKey(const Key('new-transcription')), findsNothing);
    expect(find.byKey(const Key('header-add-folder')), findsNothing);
    expect(find.byKey(const Key('header-add-files')), findsNothing);
    expect(find.byKey(const Key('header-transcribe')), findsNothing);
    expect(find.byKey(const Key('empty-add-files')), findsOneWidget);
    expect(
      find.text('Review everything before MeowSTT uploads anything.'),
      findsNothing,
    );
    expect(find.text('Batch drop · up to 5 hours each'), findsOneWidget);
  });

  testWidgets('language and context options belong to the workspace session', (
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
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.reopen('ready');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(onAddFiles: () {}, onAddFolder: () {}),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('header-add-folder')), findsOneWidget);
    expect(find.byKey(const Key('header-add-files')), findsOneWidget);
    expect(find.byKey(const Key('header-transcribe')), findsOneWidget);
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
      'MeowSTT, Soniox',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(controller.sessionOptions.contextTerms, ['MeowSTT', 'Soniox']);
    expect(controller.workspaceJobs.single.options.languageHints, ['zh', 'en']);
    expect(controller.workspaceJobs.single.options.contextTerms, [
      'MeowSTT',
      'Soniox',
    ]);
  });

  testWidgets('workspace replaces LLM controls with Soniox translation', (
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
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.reopen('ready');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
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

  testWidgets('workspace keeps two panes at Windows initial content width', (
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
          status: JobStatus.completed,
        ),
      ]),
      mediaService: _Media(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.reopen('job');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: WorkspacePage(onAddFiles: _noop, onAddFolder: _noop),
          ),
        ),
      ),
    );

    final queue = find.byKey(const Key('workspace-queue-pane'));
    final detail = find.byKey(const Key('workspace-detail-pane'));
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
    controller.reopen('job');

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

    await tester.tap(find.byKey(const ValueKey('segment-edit-first')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('segment-editor-first')),
      'First draft',
    );
    await tester.tap(find.byKey(const ValueKey('segment-edit-second')));
    await tester.pump();

    expect(find.byKey(const ValueKey('segment-editor-first')), findsNothing);
    expect(find.byKey(const ValueKey('segment-editor-second')), findsOneWidget);
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
    _setTestWindow(tester, const Size(1000, 700));
    final document = _simpleDocument();
    final brief = AiBrief(
      overview: 'Grounded overview',
      overviewEvidenceSegmentIds: const ['segment'],
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
    await tester.tap(find.text('AI Brief').first);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('review-header'))).height,
      transcriptHeaderHeight,
    );
    expect(
      tester.getCenter(find.byKey(const Key('review-content-tabs'))).dx,
      closeTo(transcriptTabsCenter, 0.1),
    );
    expect(find.text('Grounded overview'), findsOneWidget);
    expect(find.byKey(const Key('ai-evidence-segment')), findsOneWidget);
    expect(find.byKey(const Key('translate-transcript')), findsNothing);
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);

    tester.view.physicalSize = const Size(600, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-brief-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.text('Copy brief'), findsOneWidget);
    expect(find.text('Export Markdown'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ai-evidence-segment')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transcript-scroll')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('creating an AI Brief starts directly and renders output', (
    tester,
  ) async {
    final controller = await _controllerForDocument(
      _simpleDocument(),
      settings: const AppSettings(
        translationSettings: TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'brief-model',
        ),
      ),
      translationCredentials: _LlmCredentials(),
      aiBriefService: _ImmediateAiBrief(),
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
    expect(find.byKey(const Key('copy-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('export-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('refresh-ai-brief-toolbar')), findsNothing);
    expect(find.byKey(const Key('ai-brief-toolbar-more')), findsNothing);
    expect(find.byKey(const Key('cancel-ai-brief-toolbar')), findsNothing);
    await tester.tap(find.byKey(const Key('ai-brief-empty-action')));
    await tester.pumpAndSettle();
    expect(find.text('Provider model: brief-model'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-create-ai-brief')));
    await tester.pumpAndSettle();
    expect(find.text('Evidence-backed overview'), findsOneWidget);
    expect(find.byKey(const Key('ai-evidence-segment')), findsOneWidget);
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
    await service.started.future;
    await tester.pump();

    expect(find.text('Analyzing the transcript…'), findsOneWidget);
    expect(find.textContaining('0/1'), findsNothing);
    expect(find.byKey(const Key('cancel-ai-brief-toolbar')), findsOneWidget);
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
      ),
    ]),
    mediaService: mediaService ?? _Media(),
    sonioxClient: _Soniox(),
    exporter: const DefaultTranscriptExporter(),
    translationCredentialStore: translationCredentials,
    translationService: translationService,
    aiBriefService: aiBriefService,
  );
  await controller.initialize();
  return controller;
}

Future<void> _selectTranslationView(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('translation-view-mode')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void _noop() {}

void _noopSegmentSeek({required TranscriptSeekReason reason}) {}

void _setTestWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
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

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> writeApiKey(String key) async {}
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

class _LlmCredentials implements TranslationCredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'configured';

  @override
  Future<void> writeApiKey(String key) async {}
}

class _ImmediateAiBrief implements AiBriefService {
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
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await onProgress?.call('analyzing', 1, 2);
    await onProgress?.call('synthesizing', 2, 2);
    return AiBrief(
      overview: 'Evidence-backed overview',
      overviewEvidenceSegmentIds: [document.segments.first.id],
      chapters: const [],
      insights: const [],
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
  bool canUploadDirectly(String path, MediaMetadata metadata) => true;

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
