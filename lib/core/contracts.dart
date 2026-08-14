import 'models.dart';

typedef ProgressCallback = void Function(double? fraction, String? detail);
typedef CancelCheck = bool Function();

class OperationCancelledException implements Exception {
  const OperationCancelledException();
}

class LlmException implements Exception {
  const LlmException(this.code, {this.message, this.retryable = false});

  final String code;
  final String? message;
  final bool retryable;

  @override
  String toString() => 'LlmException($code)';
}

class AiBriefException implements Exception {
  const AiBriefException(this.code, {this.message});

  final String code;
  final String? message;

  @override
  String toString() => 'AiBriefException($code)';
}

abstract interface class CredentialStore {
  Future<String?> readApiKey();
  Future<void> writeApiKey(String key);
  Future<void> deleteApiKey();
}

abstract interface class LlmCredentialStore {
  Future<String?> readApiKey();
  Future<void> writeApiKey(String key);
  Future<void> deleteApiKey();
}

abstract interface class TranslationCredentialStore
    implements LlmCredentialStore {}

/// Allows startup code to check credential availability without reading the
/// secret itself. On macOS this avoids triggering Keychain authorization UI.
abstract interface class CredentialAvailabilityStore {
  Future<bool> hasApiKey();
}

abstract interface class TranslationService {
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  });

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
  });
}

abstract interface class LlmClient {
  Future<List<String>> listModels(
    LlmProviderSettings settings, {
    String? candidateApiKey,
  });

  Future<String> complete({
    required LlmProviderSettings settings,
    required String systemPrompt,
    required String userPrompt,
    CancelCheck? shouldCancel,
  });
}

typedef AiBriefProgressCallback =
    Future<void> Function(String stage, int completedChunks, int totalChunks);

abstract interface class AiBriefService {
  int estimateRequestCount(
    TranscriptDocument document,
    Set<AiBriefSection> sections,
  );

  Future<AiBrief> generate({
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
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

abstract interface class LibraryCatalogRepository {
  Future<LibraryCatalog> load();
  Future<void> save(LibraryCatalog catalog);
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

class ResolvedMediaSource {
  const ResolvedMediaSource({required this.path, required this.identity});

  final String path;
  final String identity;
}

/// Resolves files and one-shot folder imports into canonical media candidates.
///
/// A future folder monitor can send changed paths through the same resolver and
/// queue entry point without coupling filesystem traversal to application state.
abstract interface class MediaSourceResolver {
  Future<List<ResolvedMediaSource>> resolve(Iterable<String> inputs);
  String identityFor(String path);
}

class MediaDiagnostics {
  const MediaDiagnostics({
    required this.available,
    this.enginePath,
    this.encoderPath,
    this.version,
    this.errorCode,
    this.error,
  });

  final bool available;
  final String? enginePath;
  final String? encoderPath;
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
