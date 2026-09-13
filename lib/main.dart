import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'core/local_speech.dart';
import 'core/app_identity.dart';
import 'core/models.dart';
import 'data/app_data_migration.dart';
import 'data/migrating_secure_value.dart';
import 'ui/startup_page.dart';

export 'ui/startup_page.dart';
import 'data/ai_brief_service.dart';
import 'data/desktop_runtime.dart';
import 'data/inbox_folder_monitor.dart';
import 'data/local_repositories.dart';
import 'data/local_model_manager.dart';
import 'data/local_media_source_resolver.dart';
import 'data/local_speech_process.dart';
import 'data/local_speech_services.dart';
import 'data/moss_api_client.dart';
import 'data/openai_llm_client.dart';
import 'data/openai_translation_service.dart';
import 'data/podcast/http_podcast_gateway.dart';
import 'data/process_media_service.dart';
import 'data/soniox_api_client.dart';
import 'data/transcript_exporter.dart';
import 'data/update_service.dart';
import 'state/app_controller.dart';
import 'state/podcast_controller.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      arguments,
      '${AppIdentity.bundleId}.instance',
      onSecondWindow: (_) async {
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final backgroundLaunch = arguments.contains('--background');
  final migrationProgress = ValueNotifier<double?>(null);
  final startupLocale = ValueNotifier(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  Future<Widget> createApplication() async {
    migrationProgress.value = null;
    final paths = await AppPaths.create(
      onMigrationProgress: (value) {
        migrationProgress.value = value;
      },
    );
    migrationProgress.value = null;
    final settingsRepository = JsonSettingsRepository(paths);
    final initialSettings = await settingsRepository.load();
    startupLocale.value = switch (initialSettings.localeMode) {
      AppLocaleMode.english => const Locale('en'),
      AppLocaleMode.simplifiedChinese => const Locale('zh', 'CN'),
      AppLocaleMode.system => WidgetsBinding.instance.platformDispatcher.locale,
    };
    final credentials = SecureCredentialStore();
    final mossCredentials = SecureCredentialStore(
      storageKey: '${AppIdentity.bundleId}.moss_api_key',
      environmentVariable: 'MOSS_API_KEY',
    );
    final llmCredentials = SecureLlmCredentialStore();
    final failedCredentials = <CredentialMigrationTarget>[];
    for (final target in [
      CredentialMigrationTarget(
        'Soniox',
        credentials.migrateLegacy,
        credentials.writeApiKey,
      ),
      CredentialMigrationTarget(
        'MOSS',
        mossCredentials.migrateLegacy,
        mossCredentials.writeApiKey,
      ),
      CredentialMigrationTarget(
        'AI',
        llmCredentials.migrateLegacy,
        llmCredentials.writeApiKey,
      ),
    ]) {
      try {
        await target.migrate();
      } on Object {
        failedCredentials.add(target);
      }
    }
    if (failedCredentials.isNotEmpty) {
      throw CredentialMigrationException(failedCredentials);
    }
    final llmClient = OpenAiCompatibleLlmClient(llmCredentials);
    final media = ProcessMediaService(paths);
    final localModels = HttpLocalModelManager(modelsDirectory: paths.models);
    final localPcm = ProcessLocalPcmPreparer(media);
    final localWorker = ProcessLocalSpeechWorker(
      temporaryDirectory: paths.temporary,
    );
    final localSpeechSupported = CoreMlSpeechRuntimeSupport.isSupported(
      isMacOS: Platform.isMacOS,
      isArm64: ffi.Abi.current() == ffi.Abi.macosArm64,
      operatingSystemVersion: Platform.operatingSystemVersion,
    );
    final podcastGateway = HttpPodcastGateway();
    final podcastRepository = JsonPodcastRepository(paths);
    final podcastController = PodcastController(
      gateway: podcastGateway,
      repository: podcastRepository,
    );
    await podcastController.initialize();
    final controller = AppController(
      credentialStore: credentials,
      settingsRepository: settingsRepository,
      jobRepository: LocalJobRepository(paths),
      libraryCatalogRepository: JsonLibraryCatalogRepository(paths),
      mediaService: media,
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: SonioxApiClient(credentials),
      mossCredentialStore: mossCredentials,
      mossClient: MossApiClient(mossCredentials),
      exporter: const DefaultTranscriptExporter(),
      translationCredentialStore: llmCredentials,
      translationService: OpenAiCompatibleTranslationService(llmCredentials),
      localModelManager: localModels,
      localSttService: ProcessLocalSttService(
        models: localModels,
        pcm: localPcm,
        worker: localWorker,
        platformSupported: localSpeechSupported,
      ),
      forcedAlignmentService: ProcessForcedAlignmentService(
        models: localModels,
        pcm: localPcm,
        worker: localWorker,
        platformSupported: localSpeechSupported,
      ),
      aiBriefService: DefaultAiBriefService(llmClient),
      inboxMonitorRepository: JsonInboxMonitorRepository(paths),
      inboxFolderMonitor: LocalInboxFolderMonitor(),
      podcastGateway: podcastGateway,
      podcastManagedRoot: paths.root.path,
    );
    await controller.initialize();
    final desktopRuntime = DesktopRuntime(
      migrationMarker: File(
        '${paths.root.path}/${AppDataMigration.markerName}',
      ),
    );
    await desktopRuntime.setLaunchAtLogin(
      controller.inboxMonitorConfig.launchAtLogin,
    );
    if (backgroundLaunch && !controller.inboxMonitorConfig.showTrayIcon) {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } else if (backgroundLaunch) {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    }
    final updates = UpdateService();
    await updates.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(localModels.removeLegacyGGUFModels());
    });
    return ListenookApp(
      controller: controller,
      updates: updates,
      desktopRuntime: desktopRuntime,
      podcastController: podcastController,
    );
  }

  Future<Widget> start() async {
    try {
      return await createApplication();
    } on Object {
      if (backgroundLaunch) {
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
      }
      rethrow;
    }
  }

  runApp(
    ListenookBootstrap(
      application: start(),
      restart: start,
      progress: migrationProgress,
      locale: startupLocale,
    ),
  );
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: '',
      minimumSize: Size(920, 640),
      size: Size(1240, 820),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
    ),
    () async {
      if (!backgroundLaunch) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
}
