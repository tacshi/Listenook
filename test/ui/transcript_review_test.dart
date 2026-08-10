import 'package:flutter/material.dart';
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

    await tester.tap(find.byKey(const Key('new-transcription')));
    await tester.pumpAndSettle();

    expect(addFilesCalls, 0);
    expect(controller.workspaceJobs, isEmpty);
    expect(find.byKey(const Key('empty-add-files')), findsOneWidget);
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

void _noop() {}

Iterable<TextSpan> _descendantSpans(TextSpan root) sync* {
  for (final child
      in root.children?.whereType<TextSpan>() ?? const <TextSpan>[]) {
    yield child;
    yield* _descendantSpans(child);
  }
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
