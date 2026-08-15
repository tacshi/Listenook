import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/inbox_page.dart';
import 'package:provider/provider.dart';

void main() {
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

AppController _controller() => AppController(
  credentialStore: _Credentials(),
  settingsRepository: _Settings(),
  jobRepository: _Jobs(),
  mediaService: _Media(),
  sourceResolver: const LocalMediaSourceResolver(),
  sonioxClient: _Soniox(),
  exporter: const DefaultTranscriptExporter(),
);

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
  bool canUploadDirectly(String path, MediaMetadata metadata) => true;

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
