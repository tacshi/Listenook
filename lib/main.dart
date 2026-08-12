import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/ai_brief_service.dart';
import 'data/local_repositories.dart';
import 'data/openai_llm_client.dart';
import 'data/openai_translation_service.dart';
import 'data/process_media_service.dart';
import 'data/soniox_api_client.dart';
import 'data/transcript_exporter.dart';
import 'data/update_service.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
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
      await windowManager.show();
      await windowManager.focus();
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
    mediaService: media,
    sonioxClient: SonioxApiClient(credentials),
    exporter: const DefaultTranscriptExporter(),
    translationCredentialStore: llmCredentials,
    translationService: OpenAiCompatibleTranslationService(llmCredentials),
    aiBriefService: DefaultAiBriefService(llmClient),
  );
  await controller.initialize();
  final updates = UpdateService();
  await updates.initialize();
  runApp(MeowSttApp(controller: controller, updates: updates));
}
