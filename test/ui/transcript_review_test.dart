import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/library_page.dart';
import 'package:meow_stt/ui/transcript_review.dart';
import 'package:meow_stt/ui/workspace_page.dart';
import 'package:provider/provider.dart';

void main() {
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

    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Translated'), findsOneWidget);
    expect(find.text('Bilingual'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '翻译');
    await tester.pump();
    await tester.tap(find.text('Translated'));
    await tester.pump();

    expect(find.text('翻译句子。'), findsOneWidget);
    expect(find.text('Original sentence.'), findsNothing);
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
          .widget<ListView>(find.byKey(const Key('transcript-scroll')))
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

  testWidgets('timestamp aligns with the speaker or first text line', (
    tester,
  ) async {
    const segment = TranscriptSegment(
      id: 'aligned',
      startMs: 2000,
      endMs: 4000,
      text: 'First transcript line',
      speaker: '1',
    );

    Future<void> pump({required bool showSpeaker}) => tester.pumpWidget(
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
            showTimestamp: true,
            isEditing: false,
            onSeek: () {},
            onEdit: () {},
            onCancel: () {},
            onSave: (_) async {},
          ),
        ),
      ),
    );

    await pump(showSpeaker: true);
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

    await pump(showSpeaker: false);
    final transcriptText = find.descendant(
      of: find.byKey(const ValueKey('segment-text-aligned')),
      matching: find.byType(RichText),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('segment-timestamp-aligned')))
          .dy,
      closeTo(tester.getTopLeft(transcriptText).dy, 4),
    );
  });

  testWidgets(
    'played words highlight at their start and follow backward seeks',
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
      expect(_backgroundTexts(tester), ['Hello world']);

      await pump(500);
      expect(_backgroundTexts(tester), ['Hello']);
    },
  );

  testWidgets(
    'edited text keeps aligned timing and completes as one selection',
    (tester) async {
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
      expect(_backgroundTexts(tester), ['Hello', 'world']);

      await pump(1800);
      expect(_backgroundTexts(tester), ['Hello brave world']);
    },
  );

  testWidgets('Chinese punctuation follows exact token timing', (tester) async {
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

    expect(_backgroundTexts(tester), ['你好，']);
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
              onSeek: () {},
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
            onSeek: () {},
            onEdit: () {},
            onCancel: () {},
            onSave: (_) async {},
          ),
        ),
      ),
    );

    expect(_backgroundTexts(tester), isEmpty);
  });

  testWidgets('sentence cards are read-only until hover edit is selected', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(child: _EditorHarness(onSaved: saved.add)),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('segment-card-editable'))),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

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
  });

  testWidgets('editor keyboard shortcuts save and cancel drafts', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _EditorHarness(onSaved: saved.add)),
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
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('new-transcription')));
    await tester.pumpAndSettle();

    expect(addFilesCalls, 0);
    expect(controller.workspaceJobs, isEmpty);
    expect(find.byKey(const Key('empty-add-files')), findsOneWidget);
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

    await tester.enterText(
      find.byKey(const Key('session-language-hints-field')),
      'zh, en',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(
      find.byKey(const Key('session-context-terms-field')),
      'MeowSTT, Soniox',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(controller.sessionOptions.languageHints, ['zh', 'en']);
    expect(controller.sessionOptions.contextTerms, ['MeowSTT', 'Soniox']);
    expect(controller.workspaceJobs.single.options.languageHints, ['zh', 'en']);
    expect(controller.workspaceJobs.single.options.contextTerms, [
      'MeowSTT',
      'Soniox',
    ]);
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
    final centerY = tester.getCenter(waveform).dy;

    expect(tester.getCenter(play).dy, closeTo(centerY, 1));
    expect(tester.getCenter(current).dy, closeTo(centerY, 1));
    expect(tester.getCenter(duration).dy, closeTo(centerY, 1));
    expect(tester.getCenter(play).dx, lessThan(tester.getCenter(current).dx));
    expect(
      tester.getCenter(current).dx,
      lessThan(tester.getCenter(waveform).dx),
    );
    expect(
      tester.getCenter(waveform).dx,
      lessThan(tester.getCenter(duration).dx),
    );
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

  testWidgets('focus clears search and centers a distant current sentence', (
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

    final search = find.byType(TextField);
    final focus = find.byKey(const Key('focus-current-sentence'));
    expect(tester.getCenter(search).dx, lessThan(tester.getCenter(focus).dx));
    await tester.enterText(search, 'Sentence 0');
    await tester.pump();
    final scrollable = find.descendant(
      of: find.byKey(const Key('transcript-scroll')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    await tester.tap(focus);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(position.pixels, greaterThan(0));
    final currentCard = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('segment-card-segment-59')),
    );
    final decoration = currentCard.decoration as BoxDecoration;
    expect(decoration.border, isNull);
    expect(decoration.color, isNull);
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
  const _EditorHarness({required this.onSaved});

  final ValueChanged<String> onSaved;

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
    onSeek: () {},
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
          onSeek: () {},
          onEdit: () => setState(() => _editingId = segment.id),
          onCancel: () => setState(() => _editingId = null),
          onSave: (_) async => setState(() => _editingId = null),
        ),
    ],
  );
}

Future<AppController> _controllerForDocument(
  TranscriptDocument document,
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
        document: document,
      ),
    ]),
    mediaService: _Media(),
    sonioxClient: _Soniox(),
    exporter: const DefaultTranscriptExporter(),
  );
  await controller.initialize();
  return controller;
}

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

class _Settings implements SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
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
