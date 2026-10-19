import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/timed_subtitle_import.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/ui/inbox_page.dart';
import 'package:listenook/ui/subtitle_import_review_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import '../support/fakes.dart';

void main() {
  testWidgets('subtitle pairing review enqueues a completed job', (
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
    expect(find.textContaining('SRT · 1 timed cue'), findsOneWidget);
    expect(find.text('Local alignment'), findsNothing);

    await tester.tap(find.byKey(const Key('subtitle-import-confirm')));
    await tester.pumpAndSettle();
    final selections = (await selectionFuture!)!;
    await tester.runAsync(() => controller.enqueueReviewedImports(selections));

    final job = controller.inboxJobs.single;
    expect(
      job.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.importedSubtitles,
    );
    expect(job.status, JobStatus.completed);
    expect(job.document!.segments.single.text, 'Hello locally');
    expect(job.document!.segments.single.startMs, 100);
    expect(job.document!.segments.single.endMs, 900);
    expect(job.forcedAlignment.status, ForcedAlignmentStatus.notRequested);

    await _pumpInbox(tester, controller);
    expect(find.text('Align subtitles'), findsNothing);
    expect(find.byKey(const Key('subtitle-alignment-panel')), findsNothing);
  });

  testWidgets('subtitle imports complete without an alignment model', (
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
    final controller = _controller(
      localModelManager: FakeLocalModelManager(
        models: [LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8],
      ),
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

    expect(controller.inboxJobs.single.status, JobStatus.completed);
    expect(
      find.byKey(const Key('install-subtitle-alignment-model')),
      findsNothing,
    );
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
          ...GlobalMaterialLocalizations.delegates,
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
          ...GlobalMaterialLocalizations.delegates,
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
  credentialStore: MemoryCredentialStore('configured'),
  settingsRepository: MemorySettingsRepository(
    const AppSettings(onboardingComplete: true),
  ),
  jobRepository: MemoryJobRepository(),
  mediaService: FakeMediaService(),
  sourceResolver: const LocalMediaSourceResolver(),
  sonioxClient: FakeSonioxClient(),
  exporter: const DefaultTranscriptExporter(),
  localModelManager: localModelManager,
  forcedAlignmentService: forcedAlignmentService,
);

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
