import 'models.dart';

typedef ProgressCallback = void Function(double? fraction, String? detail);
typedef CancelCheck = bool Function();

class OperationCancelledException implements Exception {
  const OperationCancelledException();
}

abstract interface class CredentialStore {
  Future<String?> readApiKey();
  Future<void> writeApiKey(String key);
  Future<void> deleteApiKey();
}

abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

abstract interface class JobRepository {
  Future<List<TranscriptionJob>> loadAll();
  Future<void> save(TranscriptionJob job);
  Future<void> delete(String id);
}

abstract interface class MediaService {
  bool canUploadDirectly(String path, MediaMetadata metadata);
  Future<MediaMetadata> inspect(String sourcePath);
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
  Future<String> renderWaveform(String sourcePath, String cacheKey);
  Future<void> deleteTemporary(String path);
  Future<void> deleteGeneratedMedia(String cacheKey);
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys);
  Future<MediaDiagnostics> diagnostics();
}

class MediaDiagnostics {
  const MediaDiagnostics({
    required this.available,
    this.ffmpegPath,
    this.ffprobePath,
    this.version,
    this.errorCode,
    this.error,
  });

  final bool available;
  final String? ffmpegPath;
  final String? ffprobePath;
  final String? version;
  final String? errorCode;
  final String? error;
}

abstract interface class SonioxClient {
  Future<void> validateKey({String? apiKey});
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  );
  Future<SonioxTranscriptionState> getTranscription(String id);
  Future<Map<String, dynamic>> getTranscript(String id);
  Future<void> deleteTranscription(String id);
  Future<void> deleteFile(String id);
}

class SonioxTranscriptionState {
  const SonioxTranscriptionState({
    required this.status,
    this.errorType,
    this.errorMessage,
  });

  final String status;
  final String? errorType;
  final String? errorMessage;

  bool get isComplete => status == 'completed';
  bool get isFailed => status == 'error' || status == 'failed';
}

abstract interface class TranscriptExporter {
  String render(
    TranscriptDocument document,
    ExportOptions options, {
    required String title,
    MediaMetadata? metadata,
  });

  Future<String> exportToDirectory(
    TranscriptionJob job,
    String directory,
    ExportOptions options,
  );

  Future<String> exportZip(
    List<TranscriptionJob> jobs,
    String destination,
    ExportOptions options,
  );
}

abstract interface class MediaPlayerController {
  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}
