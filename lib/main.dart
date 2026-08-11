import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/local_repositories.dart';
import 'data/openai_translation_service.dart';
import 'data/process_media_service.dart';
import 'data/soniox_api_client.dart';
import 'data/transcript_exporter.dart';
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
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final paths = await AppPaths.create();
  final settingsRepository = JsonSettingsRepository(paths);
  final initialSettings = await settingsRepository.load();
  final credentials = SecureCredentialStore();
  final translationCredentials = SecureTranslationCredentialStore();
  final media = ProcessMediaService(
    paths,
    overrideDirectory: initialSettings.ffmpegOverride,
  );
  final controller = AppController(
    credentialStore: credentials,
    settingsRepository: settingsRepository,
    jobRepository: LocalJobRepository(paths),
    mediaService: media,
    sonioxClient: SonioxApiClient(credentials),
    exporter: const DefaultTranscriptExporter(),
    translationCredentialStore: translationCredentials,
    translationService: OpenAiCompatibleTranslationService(
      translationCredentials,
    ),
  );
  await controller.initialize();
  runApp(MeowSttApp(controller: controller));
}
