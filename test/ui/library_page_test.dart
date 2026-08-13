import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/library_page.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Needs attention includes every actionable inactive job', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    const actionableStatuses = [
      JobStatus.ready,
      JobStatus.paused,
      JobStatus.failed,
      JobStatus.cancelled,
      JobStatus.missingSource,
      JobStatus.empty,
    ];
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        for (final status in actionableStatuses)
          TranscriptionJob(
            id: status.name,
            batchId: 'batch',
            sourcePath: '/missing/${status.name}.wav',
            createdAt: now,
            updatedAt: now,
            status: status,
          ),
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/completed.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
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
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final statusDropdown = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<String>,
    );
    await tester.tap(statusDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Needs attention').last);
    await tester.pumpAndSettle();

    for (final status in actionableStatuses) {
      expect(find.text('${status.name}.wav'), findsOneWidget);
    }
    expect(find.text('completed.wav'), findsNothing);
  });

  testWidgets('Continue restores a ready job without starting transcription', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final temporaryDirectory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('meow-stt-ready-job-'),
    );
    expect(temporaryDirectory, isNotNull);
    final directory = temporaryDirectory!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/ready.wav');
    await tester.runAsync(() => source.writeAsBytes(const [0]));
    final now = DateTime.now().toUtc();
    final soniox = _Soniox();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'ready',
          batchId: 'batch',
          sourcePath: source.path,
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: soniox,
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.setDestination(AppDestination.library);

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

    final continueButton = find.byKey(const Key('continue-ready-job-ready'));
    expect(continueButton, findsOneWidget);
    expect(tester.widget<OutlinedButton>(continueButton).onPressed, isNotNull);

    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    expect(controller.destination, AppDestination.inbox);
    expect(controller.inboxJobs.single.id, 'ready');
    expect(controller.activeWorkspaceJobId, isNull);
    expect(controller.inboxJobs.single.status, JobStatus.ready);
    expect(controller.processing, isFalse);
    expect(soniox.uploadCalls, 0);
  });

  testWidgets('Open enters Workspace without adding history to Inbox', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/completed.wav',
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
                text: 'Transcript',
              ),
            ],
            speakers: const [],
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
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-library-job-completed')));
    await tester.pump();

    expect(controller.destination, AppDestination.workspace);
    expect(controller.activeWorkspaceJobId, 'completed');
    expect(controller.inboxJobs, isEmpty);
  });

  testWidgets('Clear All confirms and removes inactive history', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'history',
        batchId: 'batch',
        sourcePath: '/missing/history.wav',
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
              text: 'Transcript',
            ),
          ],
          speakers: const [],
          updatedAt: now,
        ),
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
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
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    expect(find.byKey(const Key('library-page-title')), findsNothing);
    expect(find.byKey(const Key('library-search')), findsOneWidget);
    expect(find.text('history.wav'), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-all-history')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('permanently removes 1 inactive'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('history.wav'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-all-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-clear-all-history')));
    await tester.pumpAndSettle();

    expect(find.text('history.wav'), findsNothing);
    expect(jobs.saved, isEmpty);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('clear-all-history')))
          .onPressed,
      isNull,
    );
  });
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
  _Jobs(Iterable<TranscriptionJob> initial) {
    for (final job in initial) {
      saved[job.id] = job;
    }
  }

  final Map<String, TranscriptionJob> saved = {};

  @override
  Future<void> delete(String id) async => saved.remove(id);

  @override
  Future<List<TranscriptionJob>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => saved[job.id] = job;
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
  int uploadCalls = 0;

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'tx';

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
  }) async {
    uploadCalls++;
    return 'file';
  }

  @override
  Future<void> validateKey({String? apiKey}) async {}
}
