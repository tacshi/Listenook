/// Configurable stand-ins for the app's services and repositories, shared by
/// the tests. Each records what it was asked to do so tests can check it.
library;

import 'dart:async';

import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/podcast_models.dart';

/// An API key kept in memory. Starts empty unless given a key.
class MemoryCredentialStore
    implements CredentialStore, TranslationCredentialStore {
  MemoryCredentialStore([this.value]);

  String? value;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;

  @override
  Future<void> deleteApiKey() async => value = null;
}

class MemorySettingsRepository implements SettingsRepository {
  MemorySettingsRepository([this.value = const AppSettings()]);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class MemoryJobRepository implements JobRepository {
  MemoryJobRepository([Iterable<TranscriptionJob> initial = const []]) {
    for (final job in initial) {
      saved[job.id] = job;
    }
  }

  final Map<String, TranscriptionJob> saved = {};

  @override
  Future<List<TranscriptionJob>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => saved[job.id] = job;

  @override
  Future<void> delete(String id) async => saved.remove(id);
}

class MemoryPodcastRepository implements PodcastRepository {
  PodcastLibraryState value = const PodcastLibraryState();
  Map<String, PodcastListenProgress> playback = {};

  @override
  Future<PodcastLibraryState> load() async => value;

  @override
  Future<void> save(PodcastLibraryState state) async => value = state;

  @override
  Future<Map<String, PodcastListenProgress>> loadPlaybackProgress() async =>
      playback;

  @override
  Future<void> savePlaybackProgress(
    Map<String, PodcastListenProgress> progress,
  ) async => playback = Map.of(progress);
}

const fakeAudioMetadata = MediaMetadata(
  sizeBytes: 1,
  durationMs: 1000,
  hasAudio: true,
  hasVideo: false,
  formatName: 'wav',
);

/// A downloaded podcast episode.
const fakePodcastMetadata = MediaMetadata(
  sizeBytes: 4,
  durationMs: 1000,
  hasAudio: true,
  hasVideo: false,
  formatName: 'mp3',
);

/// Media that is always readable: probing returns [metadata] and extraction
/// returns the source unchanged.
class FakeMediaService implements MediaService {
  FakeMediaService({this.metadata = fakeAudioMetadata});

  MediaMetadata metadata;
  bool uploadDirectly = true;
  final deletedGeneratedMedia = <String>[];
  final checkedUploadProfiles = <MediaUploadProfile>[];
  final extractedUploadProfiles = <MediaUploadProfile>[];

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => metadata;

  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) {
    checkedUploadProfiles.add(profile);
    return uploadDirectly;
  }

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    extractedUploadProfiles.add(profile);
    return sourcePath;
  }

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';

  @override
  Future<String> analyzeSpeechEnergy(
    String sourcePath,
    String cacheKey,
  ) async => '';

  @override
  Future<String> analyzeFileSpeechEnergy(String sourcePath) async => '';

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async =>
      deletedGeneratedMedia.add(cacheKey);

  @override
  Future<MediaDiagnostics> diagnostics() async =>
      const MediaDiagnostics(available: true);
}

/// A Soniox transcript of one sentence, "Done.".
const fakeDoneTranscript = <String, dynamic>{
  'tokens': [
    {'text': 'Done.', 'start_ms': 0, 'end_ms': 800, 'speaker': '1'},
  ],
};

/// A Soniox account that finishes every transcription. Uploads are numbered
/// (`file-1`, `file-2`, …) and transcriptions take the file's id (`tx-file-1`).
class FakeSonioxClient implements SonioxClient {
  FakeSonioxClient({
    this.uploadDelay = Duration.zero,
    this.transcriptPayload = const {'tokens': []},
    this.pollingGate,
    this.transcriptionState = const SonioxTranscriptionState(
      status: 'completed',
    ),
  });

  final Duration uploadDelay;
  final Map<String, dynamic> transcriptPayload;

  /// Polling waits for this before reporting [transcriptionState].
  final Completer<void>? pollingGate;
  final SonioxTranscriptionState transcriptionState;

  int uploadCalls = 0;
  int currentUploads = 0;
  int maximumUploads = 0;
  final deletedFiles = <String>[];
  final deletedTranscriptions = <String>[];
  TranscriptionOptions? createdOptions;
  String? validatedKey;

  @override
  Future<void> validateKey({String? apiKey}) async => validatedKey = apiKey;

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final call = ++uploadCalls;
    currentUploads++;
    if (currentUploads > maximumUploads) maximumUploads = currentUploads;
    onProgress?.call(.5, null);
    await Future<void>.delayed(uploadDelay);
    currentUploads--;
    onProgress?.call(1, null);
    return 'file-$call';
  }

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async {
    createdOptions = options;
    return 'tx-$fileId';
  }

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async {
    await pollingGate?.future;
    return transcriptionState;
  }

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async =>
      transcriptPayload;

  @override
  Future<void> deleteFile(String id) async => deletedFiles.add(id);

  @override
  Future<void> deleteTranscription(String id) async =>
      deletedTranscriptions.add(id);
}

/// Local models that are ready once their id is in [installed]. Downloads
/// install the model, except [failDownloadId], which fails its checksum.
class FakeLocalModelManager implements LocalModelManager {
  FakeLocalModelManager({
    List<LocalModelDescriptor>? models,
    Iterable<String> installed = const [],
    this.failDownloadId,
    String Function(String modelId)? pathFor,
  }) : models = models ?? LocalSpeechModels.all,
       installed = {...installed},
       _pathFor = pathFor;

  /// Every model in [models] (by default every known model) is installed.
  factory FakeLocalModelManager.allInstalled({
    List<LocalModelDescriptor>? models,
    String Function(String modelId)? pathFor,
  }) {
    final available = models ?? LocalSpeechModels.all;
    return FakeLocalModelManager(
      models: available,
      installed: available.map((model) => model.id),
      pathFor: pathFor,
    );
  }

  @override
  final List<LocalModelDescriptor> models;
  final Set<String> installed;
  String? failDownloadId;
  final String Function(String modelId)? _pathFor;
  final downloads = <String>[];
  final statusRequests = <String>[];

  LocalModelDescriptor _descriptor(String modelId) =>
      models.singleWhere((model) => model.id == modelId);

  @override
  String pathFor(String modelId) =>
      _pathFor?.call(modelId) ?? '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    statusRequests.add(modelId);
    final descriptor = _descriptor(modelId);
    final ready = installed.contains(modelId);
    return LocalModelStatus(
      descriptor: descriptor,
      availability: ready
          ? LocalModelAvailability.ready
          : LocalModelAvailability.missing,
      downloadedBytes: ready ? descriptor.sizeBytes : 0,
    );
  }

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    downloads.add(modelId);
    if (modelId == failDownloadId) {
      throw const LocalModelException('model_checksum_mismatch');
    }
    installed.add(modelId);
    final size = _descriptor(modelId).sizeBytes;
    onProgress?.call(size, size);
  }

  @override
  Future<void> delete(String modelId) async => installed.remove(modelId);
}

/// PCM that is already prepared at [path].
class FixedPcmPreparer implements LocalPcmPreparer {
  const FixedPcmPreparer(this.path, {this.progressFraction});

  final String path;

  /// Reported once as conversion progress, when set.
  final double? progressFraction;

  @override
  Future<PreparedLocalPcm> prepare(
    String sourcePath, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (progressFraction case final fraction?) {
      onProgress?.call(fraction, 'converting');
    }
    return PreparedLocalPcm(path);
  }

  @override
  Future<void> release(PreparedLocalPcm pcm) async {}
}

/// Local speech that the platform supports but that tests never run.
class SupportedLocalStt implements LocalSttService {
  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) => throw UnimplementedError();
}
