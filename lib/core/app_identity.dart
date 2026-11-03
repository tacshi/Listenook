import 'dart:io';

abstract final class AppIdentity {
  static const name = 'Listenook';
  static const chineseName = '聆页';
  static const bundleId = 'app.capyvibe.listenook';
  static const legacyBundleId = 'app.meowstt.desktop';
  static const navigationChannel = '$bundleId/navigation';
  static const openFilesChannel = '$bundleId/open_files';
  static const windowHandleChannel = '$bundleId/window_handle';
  static const startupChannel = '$bundleId/launch_at_login';
  static const cursorChannel = '$bundleId/transcript_structure_cursor';
  static const encoderChannel = '$bundleId/audio_encoder';
  static const filesChannel = '$bundleId/files';
  static const nowPlayingChannel = '$bundleId/now_playing';
  static const backgroundActivityChannel = '$bundleId/background_activity';
  static const speechEngineChannel = '$bundleId/speech_engine';
  static const speechWorker = 'ListenookSpeechWorker';
  static const releaseRepository = 'tacshi/Listenook-Release';
  static const manifestName = 'listenook-latest.json';

  static String displayName(String languageCode) =>
      languageCode == 'zh' ? chineseName : name;

  /// Old build/runtime variables remain a fallback, never an override.
  static String? environment(String name, {Map<String, String>? values}) {
    final environment = values ?? Platform.environment;
    return environment[name] ??
        environment[name.replaceFirst('LISTENOOK_', 'MEOWSTT_')];
  }
}
