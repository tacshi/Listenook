import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'data/ai_brief_service.dart';
import 'data/desktop_runtime.dart';
import 'data/inbox_folder_monitor.dart';
import 'data/local_repositories.dart';
import 'data/local_media_source_resolver.dart';
import 'data/openai_llm_client.dart';
import 'data/openai_translation_service.dart';
import 'data/process_media_service.dart';
import 'data/soniox_api_client.dart';
import 'data/transcript_exporter.dart';
import 'data/update_service.dart';
import 'state/app_controller.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  AppController? runningController;
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      arguments,
      'meowstt-desktop-inbox',
      onSecondWindow: (_) async {
        runningController?.setDestination(AppDestination.inbox);
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final backgroundLaunch = arguments.contains('--background');
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

  final paths = await AppPaths.create();
  final settingsRepository = JsonSettingsRepository(paths);
  final credentials = SecureCredentialStore();
  final llmCredentials = SecureLlmCredentialStore();
  final llmClient = OpenAiCompatibleLlmClient(llmCredentials);
  final media = ProcessMediaService(paths);
  final controller = AppController(
    credentialStore: credentials,
    settingsRepository: settingsRepository,
    jobRepository: LocalJobRepository(paths),
    libraryCatalogRepository: JsonLibraryCatalogRepository(paths),
    mediaService: media,
    sourceResolver: const LocalMediaSourceResolver(),
    sonioxClient: SonioxApiClient(credentials),
    exporter: const DefaultTranscriptExporter(),
    translationCredentialStore: llmCredentials,
    translationService: OpenAiCompatibleTranslationService(llmCredentials),
    aiBriefService: DefaultAiBriefService(llmClient),
    inboxMonitorRepository: JsonInboxMonitorRepository(paths),
    inboxFolderMonitor: LocalInboxFolderMonitor(),
  );
  runningController = controller;
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
  runApp(
    MeowSttApp(
      controller: controller,
      updates: updates,
      desktopRuntime: desktopRuntime,
    ),
  );
}
