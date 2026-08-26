import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/local_speech.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/timed_subtitle_import.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/inbox_page.dart';
import 'package:meow_stt/ui/subtitle_import_review_dialog.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'failed subtitle alignment exposes actionable diagnostics in Chinese',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'meow-subtitle-problem-widget-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final media = File('${directory.path}/problem.wav')
        ..writeAsBytesSync([0]);
      final subtitle = File('${directory.path}/problem.srt')
        ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Show the problem
''');
      final controller = _controller(
        localModelManager: _AlignmentModels()..installed = true,
        forcedAlignmentService: _FailedAlignment(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final review = await tester.runAsync(
        () => controller.previewSourceImports([media.path, subtitle.path]),
      );
      await tester.runAsync(
        () => controller.enqueueReviewedImports([
          SubtitleImportSelection(
            media: review!.media.single.media,
            subtitle: review.media.single.automaticCandidate,
          ),
        ]),
      );
      await tester.runAsync(controller.startReady);
      final job = controller.inboxJobs.single;
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.failed);

      await _pumpInbox(tester, controller, locale: const Locale('zh', 'CN'));

      expect(find.textContaining('本地对齐进程意外停止'), findsOneWidget);
      expect(find.text('查看问题'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('alignment-problem-${job.id}')));
      await tester.pumpAndSettle();

      expect(find.text('字幕对齐问题'), findsOneWidget);
      expect(find.textContaining('0/1 条字幕已对齐'), findsOneWidget);
      expect(find.textContaining('local_worker_failed'), findsOneWidget);
      expect(find.textContaining('Worker exited with code 9'), findsOneWidget);
      expect(find.textContaining('关闭其他占用大量内存的应用'), findsOneWidget);
      expect(find.text('重试对齐'), findsOneWidget);
    },
  );

  testWidgets('active imported alignment keeps Align subtitles label', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-subtitle-active-label-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final media = File('${directory.path}/active.wav')..writeAsBytesSync([0]);
    final subtitle = File('${directory.path}/active.srt')
      ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Align locally
''');
    final models = _AlignmentModels()..installed = true;
    final alignment = _GatedAlignment();
    addTearDown(() {
      if (!alignment.release.isCompleted) alignment.release.complete();
    });
    final controller = _controller(
      localModelManager: models,
      forcedAlignmentService: alignment,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final review = await tester.runAsync(
      () => controller.previewSourceImports([media.path, subtitle.path]),
    );
    await tester.runAsync(
      () => controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
        ),
      ]),
    );
    await _pumpInbox(tester, controller);
    expect(controller.defaultForcedAlignerReady, isTrue);
    expect(controller.inboxJobs.single.status, JobStatus.ready);
    expect(controller.inboxJobs.single.forcedAlignment.canRequest, isTrue);
    expect(controller.canStartReady, isTrue);

    late Future<void> processing;
    await tester.runAsync(() async {
      processing = controller.startReady();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(alignment.entered.isCompleted, isTrue);
    expect(controller.inboxJobs.single.status, JobStatus.aligning);
    expect(find.text('Align subtitles'), findsOneWidget);
    expect(find.textContaining('Aligning locally…'), findsOneWidget);
    expect(find.textContaining('Existing subtitles'), findsNothing);
    expect(find.textContaining('Aligning subtitles locally'), findsNothing);

    alignment.release.complete();
    await tester.runAsync(() => processing);
    await tester.pumpAndSettle();
  });

  testWidgets('partial subtitle alignment remains resumable from Inbox', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-subtitle-partial-resume-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final media = File('${directory.path}/resume.wav')..writeAsBytesSync([0]);
    final subtitle = File('${directory.path}/resume.srt')
      ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Resume locally
''');
    final controller = _controller(
      localModelManager: _AlignmentModels()..installed = true,
      forcedAlignmentService: _SupportedAlignment(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final review = await tester.runAsync(
      () => controller.previewSourceImports([media.path, subtitle.path]),
    );
    await tester.runAsync(
      () => controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
        ),
      ]),
    );
    await tester.runAsync(controller.startReady);
    expect(
      controller.inboxJobs.single.forcedAlignment.status,
      ForcedAlignmentStatus.partial,
    );

    await _pumpInbox(tester, controller);

    expect(controller.canStartReady, isTrue);
    expect(find.text('Align subtitles'), findsOneWidget);
    expect(find.text('View problem'), findsOneWidget);
    final action = tester.widget<FilledButton>(
      find.byKey(const Key('header-transcribe')),
    );
    expect(action.onPressed, isNotNull);
  });

  testWidgets('an unavailable imported alignment remains actionable in Inbox', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-subtitle-retry-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final media = File('${directory.path}/retry.wav')..writeAsBytesSync([0]);
    final subtitle = File('${directory.path}/retry.srt')
      ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Retry locally
''');
    final models = _AlignmentModels()..installed = true;
    final alignment = _UnavailableAlignment();
    final controller = _controller(
      localModelManager: models,
      forcedAlignmentService: alignment,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final review = await tester.runAsync(
      () => controller.previewSourceImports([media.path, subtitle.path]),
    );
    await tester.runAsync(
      () => controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
        ),
      ]),
    );
    await tester.runAsync(controller.startReady);
    expect(controller.inboxJobs.single.status, JobStatus.completed);
    expect(
      controller.inboxJobs.single.forcedAlignment.status,
      ForcedAlignmentStatus.unavailable,
    );

    await _pumpInbox(tester, controller);

    expect(find.text('Align subtitles'), findsOneWidget);
    expect(
      find.textContaining('selected language is not supported'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Select Align subtitles to retry'),
      findsOneWidget,
    );
    final action = tester.widget<FilledButton>(
      find.byKey(const Key('header-transcribe')),
    );
    expect(action.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('header-transcribe')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(alignment.calls, 2);
  });

  testWidgets('subtitle jobs stay ready until the recommended model installs', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-subtitle-model-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final media = File('${directory.path}/clip.wav')..writeAsBytesSync([0]);
    final subtitle = File('${directory.path}/clip.srt')
      ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Install locally
''');
    final models = _AlignmentModels();
    final controller = _controller(
      localModelManager: models,
      forcedAlignmentService: _SupportedAlignment(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final review = await tester.runAsync(
      () => controller.previewSourceImports([media.path, subtitle.path]),
    );
    await tester.runAsync(
      () => controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
        ),
      ]),
    );

    await _pumpInbox(tester, controller);

    expect(controller.inboxJobs.single.status, JobStatus.ready);
    expect(controller.canStartReady, isFalse);
    expect(
      find.byKey(const Key('install-subtitle-alignment-model')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('install-subtitle-alignment-model')));
    await tester.pumpAndSettle();

    expect(models.installed, isTrue);
    expect(controller.defaultForcedAlignerReady, isTrue);
    expect(controller.canStartReady, isTrue);
    expect(find.textContaining('installed and ready'), findsOneWidget);
  });

  testWidgets('subtitle pairing review explains local alignment and enqueues', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-subtitle-review-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final media = File('${directory.path}/meeting.wav')..writeAsBytesSync([0]);
    final subtitle = File('${directory.path}/meeting.en.srt')
      ..writeAsStringSync('''
1
00:00:00,100 --> 00:00:00,900
Hello locally
''');
    final controller = _controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    final review = await tester.runAsync(
      () => controller.previewSourceImports([media.path, subtitle.path]),
    );
    expect(review, isNotNull);
    Future<List<SubtitleImportSelection>?>? selectionFuture;
    await _pumpImportLauncher(
      tester,
      controller,
      onPressed: (context) {
        selectionFuture = showSubtitleImportReviewDialog(context, review!);
      },
    );

    await tester.tap(find.byKey(const Key('launch-subtitle-review')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('subtitle-import-review-dialog')),
      findsOneWidget,
    );
    expect(find.text('Local alignment'), findsOneWidget);
    expect(find.text('Audio stays on this Mac'), findsOneWidget);
    expect(find.text('No transcription API charge'), findsOneWidget);
    expect(find.textContaining('SRT · 1 timed cue'), findsOneWidget);

    await tester.tap(find.byKey(const Key('subtitle-import-confirm')));
    await tester.pumpAndSettle();
    final selections = (await selectionFuture!)!;
    await tester.runAsync(() => controller.enqueueReviewedImports(selections));

    final job = controller.inboxJobs.single;
    expect(
      job.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.importedSubtitles,
    );
    expect(job.document!.segments.single.text, 'Hello locally');

    await _pumpInbox(tester, controller);
    expect(find.text('Align subtitles'), findsOneWidget);
    expect(find.byKey(const Key('subtitle-alignment-panel')), findsOneWidget);
    expect(find.textContaining('macOS 15 or later'), findsOneWidget);
  });

  testWidgets('unconfigured Inbox uses compact monitoring guidance', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await _pumpInbox(tester, controller);

    final setupHint = find.byKey(const Key('inbox-monitor-setup-card'));
    expect(setupHint, findsOneWidget);
    expect(tester.getSize(setupHint).height, lessThanOrEqualTo(64));
    expect(
      find.textContaining('Transcription never starts on its own.'),
      findsOneWidget,
    );
    expect(find.text('Turn a folder into your Inbox'), findsNothing);
    expect(find.textContaining('MP3, WAV, M4A'), findsNothing);
    expect(find.text('Set up'), findsOneWidget);
    expect(
      find.byKey(const Key('inbox-monitor-choose-folder')),
      findsOneWidget,
    );
  });

  testWidgets('configured status supports pause and validates file types', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-monitor-widget-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final controller = _controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.runAsync(
      () => controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: supportedMonitoredMediaExtensions,
        launchAtLogin: false,
      ),
    );
    await _pumpInbox(tester, controller);

    expect(find.byKey(const Key('inbox-monitor-status-card')), findsOneWidget);
    expect(find.textContaining('7 types'), findsOneWidget);
    await tester.tap(find.byKey(const Key('inbox-monitor-pause-resume')));
    await tester.pump();
    expect(controller.inboxMonitorConfig.paused, isTrue);
    expect(find.text('Monitoring paused'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inbox-monitor-change')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('inbox-monitor-setup-dialog')), findsOneWidget);
    expect(
      find.byKey(const Key('inbox-monitor-podcast-downloads-hint')),
      findsOneWidget,
    );
    expect(find.textContaining('stored in the app cache'), findsOneWidget);
    expect(
      find.byKey(const Key('inbox-monitor-launch-at-login')),
      findsNothing,
    );
    final selectAll = find.text('Select all');
    expect(selectAll, findsNWidgets(2));
    await tester.tap(selectAll.at(0));
    await tester.pump();
    await tester.tap(selectAll.at(1));
    await tester.pump();
    await tester.tap(find.byKey(const Key('inbox-monitor-save')));
    await tester.pump();
    expect(find.text('Select at least one file type.'), findsOneWidget);
  });

  testWidgets('Simplified Chinese monitoring guidance is localized', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await _pumpInbox(tester, controller, locale: const Locale('zh', 'CN'));

    expect(find.textContaining('不会自动开始转写'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}

Future<void> _pumpImportLauncher(
  WidgetTester tester,
  AppController controller, {
  required void Function(BuildContext context) onPressed,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('launch-subtitle-review'),
                onPressed: () => onPressed(context),
                child: const Text('Import'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpInbox(
  WidgetTester tester,
  AppController controller, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
        home: Scaffold(
          body: InboxPage(onAddFiles: () {}, onImportFolder: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

AppController _controller({
  LocalModelManager? localModelManager,
  ForcedAlignmentService? forcedAlignmentService,
}) => AppController(
  credentialStore: _Credentials(),
  settingsRepository: _Settings(),
  jobRepository: _Jobs(),
  mediaService: _Media(),
  sourceResolver: const LocalMediaSourceResolver(),
  sonioxClient: _Soniox(),
  exporter: const DefaultTranscriptExporter(),
  localModelManager: localModelManager,
  forcedAlignmentService: forcedAlignmentService,
);

class _AlignmentModels implements LocalModelManager {
  bool installed = false;

  @override
  List<LocalModelDescriptor> get models => [
    LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8,
  ];

  @override
  Future<void> delete(String modelId) async => installed = false;

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    installed = true;
    final size = LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.sizeBytes;
    onProgress?.call(size, size);
  }

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async => LocalModelStatus(
    descriptor: LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8,
    availability: installed
        ? LocalModelAvailability.ready
        : LocalModelAvailability.missing,
    downloadedBytes: installed
        ? LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.sizeBytes
        : 0,
  );
}

class _SupportedAlignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => AlignmentResult(
    tokens: const [],
    status: ForcedAlignmentStatus.partial,
    alignedSegments: 0,
    totalSegments: request.document.segments.length,
  );
}

class _GatedAlignment implements ForcedAlignmentService {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    entered.complete();
    await release.future;
    return AlignmentResult(
      tokens: const [],
      status: ForcedAlignmentStatus.partial,
      alignedSegments: 0,
      totalSegments: request.document.segments.length,
    );
  }
}

class _FailedAlignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => AlignmentResult(
    tokens: const [],
    status: ForcedAlignmentStatus.failed,
    alignedSegments: 0,
    totalSegments: request.document.segments.length,
    warningCode: 'local_worker_failed',
    warningMessage:
        'Worker exited with code 9. Loaded tokenizer with 151706 tokens.',
  );
}

class _UnavailableAlignment implements ForcedAlignmentService {
  int calls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    calls++;
    return AlignmentResult(
      tokens: const [],
      status: ForcedAlignmentStatus.unavailable,
      alignedSegments: 0,
      totalSegments: request.document.segments.length,
      warningCode: 'alignment_language_unsupported',
    );
  }
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'configured';

  @override
  Future<void> writeApiKey(String key) async {}
}

class _Settings implements SettingsRepository {
  AppSettings value = const AppSettings(onboardingComplete: true);

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _Jobs implements JobRepository {
  final jobs = <String, TranscriptionJob>{};

  @override
  Future<void> delete(String id) async => jobs.remove(id);

  @override
  Future<List<TranscriptionJob>> loadAll() async => jobs.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => jobs[job.id] = job;
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

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
  Future<Map<String, dynamic>> getTranscript(String id) async => const {};

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
