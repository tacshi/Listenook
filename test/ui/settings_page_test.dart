import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/state/app_controller.dart';
import 'package:meow_stt/ui/settings_page.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('an unsaved Soniox key can be tested and then saved', (
    tester,
  ) async {
    final credentials = _Credentials();
    final soniox = _Soniox();
    final controller = AppController(
      credentialStore: credentials,
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sonioxClient: soniox,
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
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );

    expect(find.text('Transcription'), findsOneWidget);
    expect(find.text('Appearance'), findsWidgets);
    expect(find.text('System & About'), findsOneWidget);
    expect(find.byIcon(Icons.transcribe_rounded), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);

    expect(find.byKey(const Key('session-language-hints-field')), findsNothing);
    expect(find.byKey(const Key('session-context-terms-field')), findsNothing);

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-soniox-key')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('test-soniox-key')))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('soniox-key-field')),
      ' candidate-key ',
    );
    await tester.pump();

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('test-soniox-key')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('test-soniox-key')));
    await tester.pumpAndSettle();
    expect(soniox.validatedKey, 'candidate-key');

    await tester.tap(find.byKey(const Key('save-soniox-key')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(credentials.value, 'candidate-key');
    expect(controller.keyConfigured, isTrue);
    expect(find.text('Soniox key saved securely.'), findsOneWidget);

    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme').hitTestable(), findsOneWidget);

    await tester.tap(find.text('System & About'));
    await tester.pumpAndSettle();
    expect(find.text('FFmpeg diagnostics').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'translation configuration tests unsaved values and stores one key',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final translationCredentials = _TranslationCredentials();
      final translationService = _TranslationService();
      final settings = _Settings();
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: settings,
        jobRepository: _Jobs(),
        mediaService: _Media(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
        translationCredentialStore: translationCredentials,
        translationService: translationService,
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
            home: Scaffold(body: SettingsPage()),
          ),
        ),
      );

      final baseUrl = find.byKey(const Key('translation-base-url-field'));
      final model = find.byKey(const Key('translation-model-field'));
      final key = find.byKey(const Key('translation-key-field'));
      final provider = find.byKey(
        const Key('translation-provider-template-field'),
      );
      await tester.ensureVisible(baseUrl);

      expect(tester.widget<TextField>(baseUrl).controller?.text, isEmpty);
      expect(
        find.text('Test the connection to select a model'),
        findsOneWidget,
      );

      await tester.ensureVisible(provider);
      await tester.tap(provider);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groq').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(baseUrl).controller?.text,
        'https://api.groq.com/openai/v1',
      );

      await tester.enterText(baseUrl, 'https://example.test/v1/');
      await tester.pump();
      expect(find.text('Custom'), findsOneWidget);
      await tester.enterText(key, 'candidate-secret');
      await tester.pump();
      final testButton = find.byKey(const Key('test-translation-settings'));
      expect(tester.widget<OutlinedButton>(testButton).onPressed, isNotNull);
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      expect(translationService.candidateKey, 'candidate-secret');
      expect(
        translationService.testedSettings?.baseUrl,
        'https://example.test/v1',
      );
      expect(translationCredentials.value, isNull);
      expect(find.text('Select a model'), findsOneWidget);

      await tester.ensureVisible(model);
      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('suggested-model').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('save-translation-settings')));
      await tester.pumpAndSettle();
      expect(translationCredentials.value, 'candidate-secret');
      expect(
        settings.value.translationSettings.baseUrl,
        'https://example.test/v1',
      );
      expect(settings.value.translationSettings.model, 'suggested-model');

      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('replacement-model').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-translation-settings')));
      await tester.pumpAndSettle();
      expect(translationCredentials.value, 'candidate-secret');
      expect(settings.value.translationSettings.model, 'replacement-model');

      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(translationCredentials.value, isNull);
      expect(controller.translationKeyConfigured, isFalse);
    },
  );
}

class _Credentials implements CredentialStore {
  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}

class _TranslationCredentials implements TranslationCredentialStore {
  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}

class _TranslationService implements TranslationService {
  TranslationSettings? testedSettings;
  String? candidateKey;

  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async {
    testedSettings = settings;
    candidateKey = candidateApiKey;
    return ['suggested-model', 'replacement-model'];
  }

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
  }) async {}
}

class _Settings implements SettingsRepository {
  AppSettings value = const AppSettings();

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _Jobs implements JobRepository {
  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<TranscriptionJob>> loadAll() async => [];

  @override
  Future<void> save(TranscriptionJob job) async {}
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
  String? validatedKey;

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
  Future<void> validateKey({String? apiKey}) async {
    validatedKey = apiKey;
  }
}
