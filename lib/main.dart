import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'core/local_speech.dart';
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

class MeowSttBootstrap extends StatelessWidget {
  const MeowSttBootstrap({super.key, required this.application});

  final Future<Widget> application;

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    future: application,
    builder: (context, snapshot) {
      if (snapshot.hasData) return snapshot.data!;
      if (snapshot.hasError) {
        return const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'MeowSTT could not start. Please quit and reopen the app.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7439ce)),
        ),
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  size: 52,
                  color: Color(0xff7439ce),
                ),
                SizedBox(height: 20),
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(height: 14),
                Text('Starting MeowSTT…'),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      arguments,
      'meowstt-desktop-inbox',
      onSecondWindow: (_) async {
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final backgroundLaunch = arguments.contains('--background');
  final application = (() async {
    final paths = await AppPaths.create();
    final settingsRepository = JsonSettingsRepository(paths);
    final credentials = SecureCredentialStore();
    final mossCredentials = SecureCredentialStore(
      storageKey: 'app.meowstt.desktop.moss_api_key',
      environmentVariable: 'MOSS_API_KEY',
    );
    final llmCredentials = SecureLlmCredentialStore();
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
    final desktopRuntime = DesktopRuntime();
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
    return MeowSttApp(
      controller: controller,
      updates: updates,
      desktopRuntime: desktopRuntime,
      podcastController: podcastController,
    );
  })();
  runApp(MeowSttBootstrap(application: application));
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
