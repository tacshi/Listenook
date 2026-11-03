import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'core/local_speech.dart';
import 'core/app_identity.dart';
import 'core/models.dart';
import 'core/windowing/app_window.dart';
import 'core/windowing/desktop_windows.dart';
import 'data/app_data_migration.dart';
import 'data/migrating_secure_value.dart';
import 'ui/startup_page.dart';
import 'ui/video_player/player_window_app.dart';
import 'ui/video_player/video_player_controller.dart';
import 'ui/video_player/video_player_windows.dart';

export 'ui/startup_page.dart';
import 'data/ai_brief_service.dart';
import 'data/background_activity.dart';
import 'data/desktop_runtime.dart';
import 'data/desktop_tray.dart';
import 'data/inbox_folder_monitor.dart';
import 'data/llm_translation_service.dart';
import 'data/local_repositories.dart';
import 'data/local_model_manager.dart';
import 'data/local_media_source_resolver.dart';
import 'data/local_speech_channel.dart';
import 'data/local_speech_process.dart';
import 'data/local_speech_services.dart';
import 'data/managed_media_store.dart';
import 'data/moss_api_client.dart';
import 'data/now_playing.dart';
import 'data/openai_llm_client.dart';
import 'data/podcast/http_podcast_gateway.dart';
import 'data/process_media_service.dart';
import 'data/soniox_api_client.dart';
import 'data/transcript_exporter.dart';
import 'data/update_service.dart';
import 'state/app_controller.dart';
import 'state/now_playing_coordinator.dart';
import 'state/podcast_controller.dart';
import 'state/video_open_requests.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final videoOpenRequests = VideoOpenRequests(acceptsImports: Platform.isIOS)
    ..addAll(arguments);
  // Files Finder (or, on iOS, another app) opened the app with are queued
  // natively before Dart starts.
  if (Platform.isMacOS || Platform.isIOS) {
    await videoOpenRequests.attachNativeInbox();
  }
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      arguments,
      '${AppIdentity.bundleId}.instance',
      // The runner's own window is a hidden engine host; Dart raises the
      // window that should come forward.
      bringWindowToFront: false,
      onSecondWindow: (secondArguments) async {
        videoOpenRequests.addAll(secondArguments);
        // A video opens in its own window; anything else raises the app.
        if (!videoOpenRequests.hasPending) {
          await DesktopWindows.instance?.showMain();
        }
      },
    );
  }
  final backgroundLaunch = arguments.contains('--background');
  // Filled once the app's services exist; video windows wait for it.
  final playerServices = Completer<_PlayerServices>();
  // Launched only to play a video: the player window is all that shows.
  final videoLaunch =
      videoOpenRequests.hasPending ||
      (Platform.isMacOS && await videoOpenRequests.launchedForFiles());
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
    // iOS cannot start processes: the engine runs inside the app there.
    final LocalSpeechWorker localWorker = Platform.isIOS
        ? ChannelLocalSpeechWorker()
        : ProcessLocalSpeechWorker(temporaryDirectory: paths.temporary);
    final localSpeechSupported = Platform.isIOS
        ? await ChannelLocalSpeechWorker.isDeviceSupported()
        : CoreMlSpeechRuntimeSupport.isSupported(
            isMacOS: Platform.isMacOS,
            isArm64: ffi.Abi.current() == ffi.Abi.macosArm64,
            operatingSystemVersion: Platform.operatingSystemVersion,
          );
    if (Platform.isIOS) {
      // Gigabytes of models and episodes do not belong in iCloud backups.
      for (final folder in [paths.models, paths.podcasts, paths.temporary]) {
        unawaited(ChannelLocalSpeechWorker.excludeFromBackup(folder.path));
      }
    }
    final containerRoot = paths.pathCodec.root;
    final managedMedia = containerRoot == null
        ? null
        : ManagedMediaStore(
            root: paths.media,
            containerRoot: containerRoot,
            temporaryRoots: [Directory.systemTemp.path],
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
      translationService: LlmTranslationService(llmClient),
      localModelManager: localModels,
      localSttService: ProcessLocalSttService(
        models: localModels,
        pcm: localPcm,
        worker: localWorker,
        platformSupported: localSpeechSupported,
        mossParallelChunks: Platform.isIOS ? 1 : 2,
      ),
      forcedAlignmentService: ProcessForcedAlignmentService(
        models: localModels,
        pcm: localPcm,
        worker: localWorker,
        platformSupported: localSpeechSupported,
      ),
      aiBriefService: DefaultAiBriefService(llmClient),
      // iOS has no folder monitoring: media arrives through the picker,
      // other apps and drag and drop.
      inboxMonitorRepository: Platform.isIOS
          ? null
          : JsonInboxMonitorRepository(paths),
      inboxFolderMonitor: Platform.isIOS ? null : LocalInboxFolderMonitor(),
      podcastGateway: podcastGateway,
      podcastManagedRoot: paths.root.path,
      managedMediaStore: managedMedia,
    );
    await controller.initialize();
    if (Platform.isIOS) {
      final background = BackgroundActivity();
      void syncBackgroundTime() => unawaited(
        background.setBusy(
          controller.hasActiveWork || controller.localModels.hasDownloads,
        ),
      );
      controller.addListener(syncBackgroundTime);
      controller.localModels.addListener(syncBackgroundTime);
    }
    final desktopRuntime = DesktopRuntime(
      migrationMarker: File(
        '${paths.root.path}/${AppDataMigration.markerName}',
      ),
    );
    await desktopRuntime.setLaunchAtLogin(
      controller.inboxMonitorConfig.launchAtLogin,
    );
    // The runner applies the last saved choice before any window shows; this
    // catches up if the settings file says otherwise.
    await desktopRuntime.setDockIconVisible(
      controller.inboxMonitorConfig.showDockIcon,
    );
    if (backgroundLaunch &&
        !videoLaunch &&
        !controller.inboxMonitorConfig.showTrayIcon) {
      // Without a tray icon a hidden window would leave no way back in.
      await DesktopWindows.instance?.showMain();
    }
    final updates = UpdateService();
    await updates.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(localModels.removeLegacyGGUFModels());
    });
    final videoPlayback = JsonVideoPlaybackRepository(paths);
    final nowPlaying = NowPlayingCoordinator(
      Platform.isIOS ? ChannelNowPlayingBridge() : const NoNowPlayingBridge(),
    );
    if (!playerServices.isCompleted) {
      playerServices.complete(_PlayerServices(controller, videoPlayback));
    }
    return ListenookApp(
      controller: controller,
      updates: updates,
      desktopRuntime: desktopRuntime,
      desktopTray: Platform.isMacOS || Platform.isWindows
          ? NativeDesktopTray()
          : null,
      podcastController: podcastController,
      videoOpenRequests: videoOpenRequests,
      videoPlaybackRepository: videoPlayback,
      managedMediaStore: managedMedia,
      nowPlaying: nowPlaying,
    );
  }

  Future<Widget> start() async {
    try {
      return await createApplication();
    } on Object {
      // Startup problems are shown in the main window.
      await DesktopWindows.instance?.showMain();
      rethrow;
    }
  }

  final bootstrap = ListenookBootstrap(
    application: start(),
    restart: start,
    progress: migrationProgress,
    locale: startupLocale,
  );
  if (!appWindowingAvailable) {
    runApp(bootstrap);
    return;
  }
  final windows = DesktopWindows.start(
    content: bootstrap,
    startHidden: backgroundLaunch || videoLaunch,
  );
  // Like a standalone player: a video gets its own window whether or not the
  // main window is on screen (a hidden window does not paint, so this cannot
  // wait for the main window's widgets).
  Future<void> openRequestedVideo() async {
    final services = await playerServices.future;
    final path = videoOpenRequests.takeLatest();
    if (path == null) return;
    await VideoPlayerWindows.instance?.open(
      path,
      createController: (path) => VideoPlayerController(
        path: path,
        playbackRepository: services.videoPlayback,
        preferredLanguage:
            WidgetsBinding.instance.platformDispatcher.locale.languageCode,
        loadSpeechEnergy: services.controller.loadFileSpeechEnergy,
      ),
      wrap: (_, player) => PlayerWindowApp(
        controller: services.controller,
        repository: services.videoPlayback,
        child: player,
      ),
    );
  }

  videoOpenRequests.addListener(() => unawaited(openRequestedVideo()));
  if (videoOpenRequests.hasPending) unawaited(openRequestedVideo());
  if (videoLaunch) {
    // Launched to open something that turned out not to be a playable video:
    // show the app rather than leave it running with no window.
    unawaited(
      playerServices.future.then((_) {
        Timer(const Duration(seconds: 3), () {
          if (!videoOpenRequests.hasPending &&
              !(VideoPlayerWindows.instance?.hasOpenWindows ?? false)) {
            unawaited(windows.showMain());
          }
        });
      }),
    );
  }
}

class _PlayerServices {
  const _PlayerServices(this.controller, this.videoPlayback);

  final AppController controller;
  final VideoPlaybackRepository videoPlayback;
}
