import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/transcript_parser.dart';
import '../data/openai_translation_service.dart';
import '../data/process_media_service.dart';
import '../data/soniox_api_client.dart';

class AppController extends ChangeNotifier {
  AppController({
    required CredentialStore credentialStore,
    required SettingsRepository settingsRepository,
    required JobRepository jobRepository,
    required MediaService mediaService,
    required SonioxClient sonioxClient,
    required TranscriptExporter exporter,
    TranslationCredentialStore? translationCredentialStore,
    TranslationService? translationService,
    TranscriptParser parser = const TranscriptParser(),
    Uuid uuid = const Uuid(),
  }) : _credentials = credentialStore,
       _settingsRepository = settingsRepository,
       _jobsRepository = jobRepository,
       _media = mediaService,
       _soniox = sonioxClient,
       _exporter = exporter,
       _translationCredentials = translationCredentialStore,
       _translationService = translationService,
       _parser = parser,
       _uuid = uuid;

  final CredentialStore _credentials;
  final SettingsRepository _settingsRepository;
  final JobRepository _jobsRepository;
  final MediaService _media;
  final SonioxClient _soniox;
  final TranscriptExporter _exporter;
  final TranslationCredentialStore? _translationCredentials;
  final TranslationService? _translationService;
  final TranscriptParser _parser;
  final Uuid _uuid;
  final Map<String, TranscriptionJob> _jobs = {};
  final Map<String, Duration> _playbackPositions = {};
  final List<String> _workspaceIds = [];
  final Set<String> _cancelledIds = {};
  final Set<String> _translationCancelledIds = {};
  String _batchId = '';
  bool _processing = false;
  bool _initializing = true;
  bool _keyConfigured = false;
  bool _translationKeyConfigured = false;
  int _destinationIndex = 0;
  String? _selectedJobId;
  AppSettings _settings = const AppSettings();
  TranscriptionOptions _sessionOptions = const TranscriptionOptions();

  AppSettings get settings => _settings;
  TranscriptionOptions get sessionOptions => _sessionOptions;
  bool get initializing => _initializing;
  bool get processing => _processing;
  bool get hasActiveWork => _jobs.values.any((job) => job.isBusy);
  bool get keyConfigured => _keyConfigured;
  bool get translationKeyConfigured => _translationKeyConfigured;
  bool get translationConfigured => _settings.translationSettings.isConfigured(
    hasApiKey: _translationKeyConfigured,
  );
  int get destinationIndex => _destinationIndex;
  String? get selectedJobId => _selectedJobId;

  List<TranscriptionJob> get allJobs {
    final list = _jobs.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<TranscriptionJob> get workspaceJobs => _workspaceIds
      .map((id) => _jobs[id])
      .whereType<TranscriptionJob>()
      .toList(growable: false);

  TranscriptionJob? get selectedJob =>
      _selectedJobId == null ? null : _jobs[_selectedJobId];

  Duration playbackPositionFor(String jobId) =>
      _playbackPositions[jobId] ?? Duration.zero;

  void rememberPlaybackPosition(String jobId, Duration position) {
    if (position <= Duration.zero) {
      _playbackPositions.remove(jobId);
      return;
    }
    _playbackPositions[jobId] = position;
  }

  int get readyCount =>
      workspaceJobs.where((job) => job.status.canTranscribe).length;
  int get completedCount =>
      workspaceJobs.where((job) => job.status == JobStatus.completed).length;
  int get failedCount => workspaceJobs
      .where(
        (job) =>
            job.status == JobStatus.failed ||
            job.status == JobStatus.missingSource,
      )
      .length;
  int get inactiveHistoryCount =>
      _jobs.values.where((job) => !job.isBusy).length;
  int get untranscribedWorkspaceCount =>
      workspaceJobs.where((job) => job.document == null).length;
  bool get canStartNewSession =>
      workspaceJobs.isNotEmpty &&
      !_processing &&
      !workspaceJobs.any((job) => job.isBusy);

  Future<void> initialize() async {
    _settings = await _settingsRepository.load();
    var settingsChanged = false;
    if (_settings.translationSettings.targetLanguage.isEmpty) {
      _settings = _settings.copyWith(
        translationSettings: _settings.translationSettings.copyWith(
          targetLanguage: _initialTargetLanguage(),
        ),
      );
      settingsChanged = true;
    }
    if (!supportedSonioxTranslationLanguageCodes.contains(
      _settings.sonioxTranslation.targetLanguage,
    )) {
      _settings = _settings.copyWith(
        sonioxTranslation: _settings.sonioxTranslation.copyWith(
          targetLanguage: _initialSonioxTargetLanguage(),
        ),
      );
      settingsChanged = true;
    }
    if (_settings.sonioxTranslation.enabled &&
        _settings.translationSettings.autoTranslate) {
      _settings = _settings.copyWith(
        translationSettings: _settings.translationSettings.copyWith(
          autoTranslate: false,
        ),
      );
      settingsChanged = true;
    }
    if (settingsChanged) {
      await _settingsRepository.save(_settings);
    }
    _sessionOptions = TranscriptionOptions(
      sonioxTranslation: _settings.sonioxTranslation,
    );
    final stored = await _jobsRepository.loadAll();
    final loaded = <TranscriptionJob>[];
    for (final original in stored) {
      final document = original.document;
      final normalized = document == null
          ? null
          : _parser.normalizeSegments(document);
      var job = normalized == null || identical(normalized, document)
          ? original
          : original.copyWith(document: normalized);
      if (!identical(job, original) &&
          job.translationState.status != TranslationStatus.idle) {
        final progress = _translationProgress(
          job.document?.segments ?? const [],
        );
        final complete = progress.completed == progress.total;
        job = job.copyWith(
          translationState: job.translationState.copyWith(
            status: complete
                ? TranslationStatus.completed
                : job.translationState.status,
            completedSegments: progress.completed,
            totalSegments: progress.total,
            clearError: complete,
          ),
        );
      }
      if (job.translationState.status == TranslationStatus.translating) {
        final progress = _translationProgress(
          job.document?.segments ?? const [],
        );
        job = job.copyWith(
          translationState: job.translationState.copyWith(
            status: progress.completed > 0
                ? TranslationStatus.partial
                : TranslationStatus.interrupted,
            completedSegments: progress.completed,
            totalSegments: progress.total,
            errorCode: 'translation_interrupted',
            errorMessage: 'Translation was interrupted before it finished.',
          ),
        );
      }
      _jobs[job.id] = job;
      loaded.add(job);
      if (!identical(job, original)) {
        await _jobsRepository.save(job);
      }
    }
    _keyConfigured = await _credentialIsAvailable(
      _credentials,
      _credentials.readApiKey,
    );
    _translationKeyConfigured = await _credentialIsAvailable(
      _translationCredentials,
      _translationCredentials?.readApiKey,
    );
    _batchId = _uuid.v4();
    final interrupted = loaded.where((job) => job.status.isActive).toList()
      ..sort((a, b) {
        final order = a.queueIndex.compareTo(b.queueIndex);
        return order == 0 ? a.createdAt.compareTo(b.createdAt) : order;
      });
    if (interrupted.isNotEmpty) {
      _batchId = interrupted.first.batchId;
      _sessionOptions = interrupted.first.options;
      _workspaceIds.addAll(interrupted.map((job) => job.id));
    }
    _initializing = false;
    notifyListeners();
    unawaited(_recover(interrupted));
    unawaited(_retryPendingCleanup(loaded));
  }

  Future<bool> _credentialIsAvailable(
    Object? store,
    Future<String?> Function()? read,
  ) async {
    if (store == null || read == null) return false;
    if (store is CredentialAvailabilityStore) return store.hasApiKey();
    return (await read())?.isNotEmpty ?? false;
  }

  void setDestination(int index) {
    if (_destinationIndex == index) return;
    _destinationIndex = index;
    notifyListeners();
  }

  void selectJob(String? id) {
    _selectedJobId = id;
    notifyListeners();
  }

  void reorderWorkspace(int oldIndex, int newIndex) {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _workspaceIds.length ||
        newIndex >= _workspaceIds.length) {
      return;
    }
    final id = _workspaceIds.removeAt(oldIndex);
    _workspaceIds.insert(newIndex, id);
    notifyListeners();
    unawaited(_persistWorkspaceOrder());
  }

  Future<void> _persistWorkspaceOrder() async {
    for (var index = 0; index < _workspaceIds.length; index++) {
      final job = _jobs[_workspaceIds[index]];
      if (job != null && job.queueIndex != index) {
        await _transition(job, queueIndex: index);
      }
    }
  }

  Future<void> addSources(Iterable<String> paths) async {
    if (_workspaceIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final existing = <String>{
      for (final job in workspaceJobs) _canonical(job.sourcePath),
    };
    final files = <String>[];
    for (final path in paths) {
      await _collectFiles(path, files);
    }
    for (final path in files) {
      final canonical = _canonical(path);
      if (!existing.add(canonical)) continue;
      final now = DateTime.now().toUtc();
      final job = TranscriptionJob(
        id: _uuid.v4(),
        batchId: _batchId,
        sourcePath: path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.pending,
        queueIndex: _workspaceIds.length,
        options: _sessionOptions,
        translationOptions: TranslationOptions.fromSettings(
          _settings.translationSettings,
        ),
      );
      _jobs[job.id] = job;
      _workspaceIds.add(job.id);
      _selectedJobId ??= job.id;
      await _jobsRepository.save(job);
      notifyListeners();
      unawaited(_prepare(job.id));
    }
  }

  Future<void> _collectFiles(String path, List<String> result) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      if (!_isHidden(path)) result.add(p.absolute(path));
      return;
    }
    if (type != FileSystemEntityType.directory) return;
    await for (final entity in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File && !_isHidden(entity.path)) {
        result.add(p.absolute(entity.path));
      }
    }
  }

  bool _isHidden(String path) => p
      .split(p.normalize(path))
      .any((part) => part.startsWith('.') && part != '.' && part != '..');

  String _canonical(String path) {
    final normalized = p.canonicalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<void> _prepare(String id) async {
    var job = _jobs[id];
    if (job == null || job.status != JobStatus.pending) return;
    job = await _transition(
      job,
      status: JobStatus.probing,
      progress: const JobProgress(stage: 'probing'),
      clearError: true,
    );
    try {
      final metadata = await _media.inspect(job.sourcePath);
      await _transition(
        job,
        status: _processing ? JobStatus.paused : JobStatus.ready,
        metadata: metadata,
        progress: JobProgress(
          stage: _processing ? 'paused' : 'ready',
          fraction: 0,
        ),
      );
    } on MediaException catch (error) {
      await _transition(
        job,
        status: error.code == 'missing_source'
            ? JobStatus.missingSource
            : JobStatus.failed,
        errorCode: error.code,
        errorMessage: error.message,
        progress: const JobProgress(stage: 'failed'),
      );
    } on Object catch (error) {
      await _fail(job, 'media_error', _safeError(error));
    }
  }

  Future<void> startReady() async {
    if (_processing || !_keyConfigured) return;
    final queue = workspaceJobs
        .where((job) => job.status.canTranscribe)
        .map((job) => job.id)
        .toList();
    if (queue.isEmpty) return;
    _processing = true;
    notifyListeners();
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < queue.length) {
        final id = queue[cursor++];
        await _runJob(id);
      }
    }

    await Future.wait(
      List.generate(min(_settings.concurrency, queue.length), (_) => worker()),
    );
    _processing = false;
    notifyListeners();
  }

  Future<void> _runJob(String id) async {
    final initialJob = _jobs[id];
    if (initialJob == null) return;
    TranscriptionJob job = initialJob;
    String? temporary;
    try {
      if (!await File(job.sourcePath).exists()) {
        throw const MediaException(
          'missing_source',
          'The source file is missing.',
        );
      }
      _checkCancelled(id);
      var uploadPath = job.sourcePath;
      final metadata = job.metadata ?? await _media.inspect(job.sourcePath);
      if (!_media.canUploadDirectly(job.sourcePath, metadata)) {
        job = await _transition(
          job,
          status: JobStatus.converting,
          metadata: metadata,
          progress: const JobProgress(stage: 'converting', fraction: 0),
        );
        temporary = await _media.extractAudio(
          job.sourcePath,
          job.id,
          durationMs: metadata.durationMs,
          onProgress: (fraction, detail) =>
              unawaited(_progress(id, 'converting', fraction, detail)),
          shouldCancel: () => _cancelledIds.contains(id),
        );
        uploadPath = temporary;
      }
      _checkCancelled(id);
      var fileId = job.remoteFileId;
      if (fileId == null) {
        job = await _transition(
          _jobs[id] ?? job,
          status: JobStatus.uploading,
          progress: const JobProgress(stage: 'uploading', fraction: 0),
        );
        fileId = await _soniox.uploadFile(
          uploadPath,
          onProgress: (fraction, detail) =>
              unawaited(_progress(id, 'uploading', fraction, detail)),
          shouldCancel: () => _cancelledIds.contains(id),
        );
        job = await _transition(
          _jobs[id] ?? job,
          remoteFileId: fileId,
          cleanupState: CleanupState.pending,
        );
      }
      _checkCancelled(id);
      var transcriptionId = job.remoteTranscriptionId;
      if (transcriptionId == null) {
        transcriptionId = await _soniox.createTranscription(
          fileId,
          job.options,
        );
        job = await _transition(
          job,
          remoteTranscriptionId: transcriptionId,
          cleanupState: CleanupState.pending,
          status: JobStatus.queuedRemote,
          progress: const JobProgress(stage: 'queued_remote'),
        );
      }
      await _poll(id, transcriptionId);
      _checkCancelled(id);
      job = await _transition(
        _jobs[id] ?? job,
        status: JobStatus.fetching,
        progress: const JobProgress(stage: 'fetching'),
      );
      final payload = await _soniox.getTranscript(transcriptionId);
      final sonioxTranslation = job.options.sonioxTranslation;
      final document = _parser.parse(
        payload,
        sonioxTranslationTargetLanguage: sonioxTranslation.enabled
            ? sonioxTranslation.targetLanguage
            : null,
      );
      final status = document.segments.isEmpty
          ? JobStatus.empty
          : JobStatus.completed;
      final sonioxTranslationState = sonioxTranslation.enabled
          ? _sonioxTranslationState(document, sonioxTranslation.targetLanguage)
          : null;
      job = await _transition(
        job,
        status: status,
        document: document,
        translationState: sonioxTranslationState,
        progress: const JobProgress(stage: 'complete', fraction: 1),
        clearError: true,
      );
      await _cleanup(job);
      job = _jobs[id] ?? job;
      if (status == JobStatus.completed &&
          !job.options.sonioxTranslation.enabled &&
          job.translationOptions.enabled &&
          job.translationOptions.targetLanguage.isNotEmpty) {
        await _runTranslation(
          job,
          settings: TranslationSettings(
            baseUrl: job.translationOptions.baseUrl,
            model: job.translationOptions.model,
            targetLanguage: job.translationOptions.targetLanguage,
          ),
          targetLanguage: job.translationOptions.targetLanguage,
        );
      }
    } on OperationCancelledException {
      job = _jobs[id] ?? job;
      await _transition(
        job,
        status: JobStatus.cancelled,
        progress: const JobProgress(stage: 'cancelled'),
        errorCode: 'cancelled',
        errorMessage: 'Cancelled by the user.',
      );
      await _cleanup(_jobs[id] ?? job);
    } on MediaException catch (error) {
      await _fail(
        _jobs[id] ?? job,
        error.code,
        error.message,
        status: error.code == 'missing_source'
            ? JobStatus.missingSource
            : JobStatus.failed,
      );
      await _cleanup(_jobs[id] ?? job);
    } on SonioxException catch (error) {
      await _fail(_jobs[id] ?? job, error.code, error.message);
      await _cleanup(_jobs[id] ?? job);
    } on Object catch (error) {
      await _fail(_jobs[id] ?? job, 'unexpected', _safeError(error));
      await _cleanup(_jobs[id] ?? job);
    } finally {
      if (temporary != null) await _media.deleteTemporary(temporary);
      _cancelledIds.remove(id);
    }
  }

  Future<void> _poll(String id, String transcriptionId) async {
    var failures = 0;
    while (true) {
      _checkCancelled(id);
      try {
        final state = await _soniox.getTranscription(transcriptionId);
        failures = 0;
        if (state.isComplete) return;
        if (state.isFailed) {
          throw SonioxException(
            code: canonicalSonioxErrorCode(
              state.errorType,
              fallback: 'transcription_failed',
            ),
            message:
                state.errorMessage ?? 'Soniox could not transcribe this file.',
            errorType: state.errorType,
          );
        }
        final status = state.status == 'queued'
            ? JobStatus.queuedRemote
            : JobStatus.processing;
        await _transition(
          _jobs[id]!,
          status: status,
          progress: JobProgress(stage: status.name),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      } on SonioxException catch (error) {
        if (!error.retryable || failures >= 7) rethrow;
        failures++;
        await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
      } on TimeoutException {
        if (failures >= 7) rethrow;
        failures++;
        await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
      } on SocketException {
        if (failures >= 7) rethrow;
        failures++;
        await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
      }
    }
  }

  Future<void> cancelJob(String id) async {
    if (_jobs[id]?.translationState.status.isActive ?? false) {
      _translationCancelledIds.add(id);
      return;
    }
    _cancelledIds.add(id);
    final job = _jobs[id];
    if (job != null && !job.status.isActive) {
      await _transition(
        job,
        status: JobStatus.cancelled,
        progress: const JobProgress(stage: 'cancelled'),
        errorCode: 'cancelled',
        errorMessage: 'Cancelled by the user.',
      );
    }
  }

  Future<void> cancelAll() async {
    for (final job in workspaceJobs.where((item) => item.status.isActive)) {
      _cancelledIds.add(job.id);
    }
    for (final job in workspaceJobs.where(
      (item) => item.translationState.status.isActive,
    )) {
      _translationCancelledIds.add(job.id);
    }
  }

  Future<void> cancelRemoteJobsForQuit() async {
    final active = workspaceJobs.where((job) => job.isBusy).toList();
    for (final job in active) {
      if (job.translationState.status.isActive) {
        _translationCancelledIds.add(job.id);
      }
      if (job.status.isActive) {
        _cancelledIds.add(job.id);
        await _cleanup(job);
        await _transition(
          _jobs[job.id] ?? job,
          status: JobStatus.cancelled,
          progress: const JobProgress(stage: 'cancelled'),
          errorCode: 'cancelled',
          errorMessage: 'Cancelled while quitting.',
        );
      }
    }
  }

  void _checkCancelled(String id) {
    if (_cancelledIds.contains(id)) {
      throw const OperationCancelledException();
    }
  }

  Future<void> retry(String id) async {
    final job = _jobs[id];
    if (job == null || !job.status.canRetry) return;
    if (!await File(job.sourcePath).exists()) {
      await _fail(
        job,
        'missing_source',
        'The source file is missing. Relink it before retrying.',
        status: JobStatus.missingSource,
      );
      return;
    }
    final updated = await _transition(
      job,
      status: JobStatus.ready,
      progress: const JobProgress(stage: 'ready', fraction: 0),
      clearError: true,
      clearRemoteFileId: job.cleanupState == CleanupState.complete,
      clearRemoteTranscriptionId: job.cleanupState == CleanupState.complete,
      cleanupState: job.cleanupState == CleanupState.complete
          ? CleanupState.none
          : job.cleanupState,
    );
    if (!_workspaceIds.contains(id)) _workspaceIds.add(id);
    notifyListeners();
    if (_keyConfigured && !_processing) {
      _processing = true;
      notifyListeners();
      await _runJob(updated.id);
      _processing = false;
      notifyListeners();
    }
  }

  Future<void> continueReadyJob(String id) async {
    final job = _jobs[id];
    if (job == null || job.status != JobStatus.ready) return;
    if (!await File(job.sourcePath).exists()) {
      await _fail(
        job,
        'missing_source',
        'The source file is missing. Relink it before continuing.',
        status: JobStatus.missingSource,
      );
      return;
    }
    if (!_workspaceIds.contains(id)) _workspaceIds.add(id);
    _selectedJobId = id;
    _destinationIndex = 0;
    notifyListeners();
    if (!_keyConfigured || _processing) return;
    _processing = true;
    notifyListeners();
    try {
      await _runJob(id);
    } finally {
      _processing = false;
      notifyListeners();
    }
  }

  Future<String?> relink(String id, String sourcePath) async {
    final job = _jobs[id];
    if (job == null) return 'unexpected';
    try {
      final metadata = await _media.inspect(sourcePath);
      await _transition(
        job,
        sourcePath: sourcePath,
        metadata: metadata,
        status: job.document == null
            ? (_processing ? JobStatus.paused : JobStatus.ready)
            : job.status,
        progress: job.document == null
            ? JobProgress(stage: _processing ? 'paused' : 'ready', fraction: 0)
            : job.progress,
        clearError: true,
      );
      return null;
    } on MediaException catch (error) {
      return error.code;
    } on Object {
      return 'media_error';
    }
  }

  Future<void> removeFromWorkspace(String id) async {
    final job = _jobs[id];
    if (job == null || job.isBusy) return;
    _workspaceIds.remove(id);
    if (job.document == null) {
      _jobs.remove(id);
      _playbackPositions.remove(id);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
    }
    if (_selectedJobId == id) _selectedJobId = _workspaceIds.firstOrNull;
    notifyListeners();
  }

  Future<void> startNewSession() async {
    if (!canStartNewSession) return;
    final discardedIds = [
      for (final id in _workspaceIds)
        if (_jobs[id]?.document == null) id,
    ];
    for (final id in discardedIds) {
      _jobs.remove(id);
      _playbackPositions.remove(id);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
    }
    _workspaceIds.clear();
    _selectedJobId = null;
    _batchId = _uuid.v4();
    _sessionOptions = TranscriptionOptions(
      sonioxTranslation: _settings.sonioxTranslation,
    );
    notifyListeners();
  }

  Future<void> deleteHistory(String id) async {
    final job = _jobs[id];
    if (job == null || job.isBusy) return;
    _jobs.remove(id);
    _playbackPositions.remove(id);
    _workspaceIds.remove(id);
    if (_selectedJobId == id) _selectedJobId = null;
    await _media.deleteGeneratedMedia(id);
    await _jobsRepository.delete(id);
    notifyListeners();
  }

  Future<void> clearInactiveHistory() async {
    final deletable = _jobs.values
        .where((job) => !job.isBusy)
        .map((job) => job.id)
        .toList(growable: false);
    if (deletable.isEmpty) return;
    for (final id in deletable) {
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
      _jobs.remove(id);
      _playbackPositions.remove(id);
      _workspaceIds.remove(id);
    }
    await _media.clearGeneratedMediaExcept(_jobs.keys.toSet());
    if (_selectedJobId != null && !_jobs.containsKey(_selectedJobId)) {
      _selectedJobId = _workspaceIds.firstOrNull;
    }
    notifyListeners();
  }

  void reopen(String id) {
    if (!_jobs.containsKey(id)) return;
    if (!_workspaceIds.contains(id)) _workspaceIds.add(id);
    _selectedJobId = id;
    _destinationIndex = 0;
    notifyListeners();
  }

  Future<void> updateSegment(
    String jobId,
    String segmentId,
    String text,
  ) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) return;
    final segments = [
      for (final segment in document.segments)
        if (segment.id == segmentId)
          segment.copyWith(text: text, clearTranslatedText: true)
        else
          segment,
    ];
    final progress = _translationProgress(segments);
    final invalidated = document.segments
        .where((segment) => segment.id == segmentId)
        .any((segment) => segment.hasTranslation);
    await _transition(
      job,
      document: document.copyWith(segments: segments),
      translationState: invalidated
          ? job.translationState.copyWith(
              status: progress.completed == progress.total
                  ? TranslationStatus.completed
                  : TranslationStatus.partial,
              completedSegments: progress.completed,
              totalSegments: progress.total,
              clearError: true,
            )
          : null,
    );
  }

  Future<void> renameSpeaker(
    String jobId,
    String speakerId,
    String name,
  ) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) return;
    final speakers = [
      for (final speaker in document.speakers)
        if (speaker.id == speakerId)
          SpeakerProfile(id: speaker.id, name: name.trim())
        else
          speaker,
    ];
    await _transition(job, document: document.copyWith(speakers: speakers));
  }

  Future<void> updateSettings(AppSettings value) async {
    _settings = value;
    await _settingsRepository.save(value);
    notifyListeners();
  }

  Future<void> updateSessionOptions(TranscriptionOptions value) async {
    _sessionOptions = value;
    for (final job in workspaceJobs.where(
      (job) =>
          job.status == JobStatus.pending ||
          job.status == JobStatus.probing ||
          job.status.canTranscribe,
    )) {
      await _transition(job, options: value);
    }
    notifyListeners();
  }

  Future<void> saveApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    await _credentials.writeApiKey(trimmed);
    _keyConfigured = true;
    notifyListeners();
  }

  Future<void> removeApiKey() async {
    await _credentials.deleteApiKey();
    _keyConfigured = false;
    notifyListeners();
  }

  Future<String?> testApiKey([String? candidate]) async {
    try {
      await _soniox.validateKey(apiKey: candidate);
      return null;
    } on SonioxException catch (error) {
      return error.code;
    } on Object {
      return 'unexpected';
    }
  }

  Future<String?> saveTranslationConfiguration(
    TranslationSettings value, {
    String? apiKey,
  }) async {
    final settings = _normalizeTranslationSettings(value);
    final validation = settings.validationError();
    if (validation != null) return validation;
    final candidate = apiKey?.trim() ?? '';
    final sameEndpoint =
        settings.baseUrl ==
        _normalizeTranslationSettings(_settings.translationSettings).baseUrl;
    if (settings.requiresApiKey &&
        candidate.isEmpty &&
        (!_translationKeyConfigured || !sameEndpoint)) {
      return 'translation_missing_credentials';
    }
    if (!settings.requiresApiKey) {
      if (_translationKeyConfigured) {
        await _translationCredentials?.deleteApiKey();
        _translationKeyConfigured = false;
      }
    } else if (candidate.isNotEmpty) {
      final credentials = _translationCredentials;
      if (credentials == null) return 'translation_unavailable';
      await credentials.writeApiKey(candidate);
      _translationKeyConfigured = true;
    }
    _settings = _settings.copyWith(translationSettings: settings);
    await _settingsRepository.save(_settings);
    await _updateQueuedTranslationOptions();
    notifyListeners();
    return null;
  }

  Future<void> removeTranslationApiKey() async {
    await _translationCredentials?.deleteApiKey();
    _translationKeyConfigured = false;
    if (_settings.translationSettings.autoTranslate) {
      _settings = _settings.copyWith(
        translationSettings: _settings.translationSettings.copyWith(
          autoTranslate: false,
        ),
      );
      await _settingsRepository.save(_settings);
      await _updateQueuedTranslationOptions();
    }
    notifyListeners();
  }

  Future<({List<String> models, String? errorCode})>
  testTranslationConfiguration(
    TranslationSettings value, {
    String? candidateApiKey,
  }) async {
    final service = _translationService;
    if (service == null) {
      return (models: const <String>[], errorCode: 'translation_unavailable');
    }
    final settings = _normalizeTranslationSettings(value);
    final candidate = candidateApiKey?.trim() ?? '';
    final sameEndpoint =
        settings.baseUrl ==
        _normalizeTranslationSettings(_settings.translationSettings).baseUrl;
    if (settings.requiresApiKey &&
        candidate.isEmpty &&
        (!_translationKeyConfigured || !sameEndpoint)) {
      return (
        models: const <String>[],
        errorCode: 'translation_missing_credentials',
      );
    }
    try {
      final models = await service.listModels(
        settings,
        candidateApiKey: candidateApiKey,
      );
      return (models: models, errorCode: null);
    } on TranslationException catch (error) {
      return (models: const <String>[], errorCode: error.code);
    } on TimeoutException {
      return (models: const <String>[], errorCode: 'translation_timeout');
    } on SocketException {
      return (models: const <String>[], errorCode: 'translation_network_error');
    } on Object {
      return (
        models: const <String>[],
        errorCode: 'translation_request_failed',
      );
    }
  }

  Future<String?> updateTranslationDefaults(TranslationSettings value) async {
    final settings = _normalizeTranslationSettings(value);
    if (settings.autoTranslate &&
        !settings.isConfigured(hasApiKey: _translationKeyConfigured)) {
      return settings.validationError() ?? 'translation_missing_credentials';
    }
    final sonioxTranslation = settings.autoTranslate
        ? _settings.sonioxTranslation.copyWith(enabled: false)
        : _settings.sonioxTranslation;
    _settings = _settings.copyWith(
      translationSettings: settings,
      sonioxTranslation: sonioxTranslation,
    );
    if (settings.autoTranslate) {
      _sessionOptions = _sessionOptions.copyWith(
        sonioxTranslation: sonioxTranslation,
      );
    }
    await _settingsRepository.save(_settings);
    await _updateQueuedTranslationOptions();
    if (settings.autoTranslate) await _updateQueuedSonioxTranslationOptions();
    notifyListeners();
    return null;
  }

  Future<String?> updateSonioxTranslation(
    SonioxTranslationOptions value,
  ) async {
    final targetLanguage = value.targetLanguage.trim().toLowerCase();
    final options = value.copyWith(targetLanguage: targetLanguage);
    final validation = options.validationError();
    if (validation != null) return validation;
    final translationSettings = options.enabled
        ? _settings.translationSettings.copyWith(autoTranslate: false)
        : _settings.translationSettings;
    _settings = _settings.copyWith(
      sonioxTranslation: options,
      translationSettings: translationSettings,
    );
    _sessionOptions = _sessionOptions.copyWith(sonioxTranslation: options);
    await _settingsRepository.save(_settings);
    await _updateQueuedSonioxTranslationOptions();
    if (options.enabled) await _updateQueuedTranslationOptions();
    notifyListeners();
    return null;
  }

  Future<void> translateJob(
    String id, {
    required String targetLanguage,
    bool replaceExisting = false,
  }) async {
    final job = _jobs[id];
    final document = job?.document;
    if (job == null ||
        document == null ||
        job.translationState.status.isActive) {
      return;
    }
    final settings = _normalizeTranslationSettings(
      _settings.translationSettings.copyWith(targetLanguage: targetLanguage),
    );
    final configurationError = settings.validationError();
    if (configurationError != null ||
        (settings.requiresApiKey && !_translationKeyConfigured)) {
      await _setTranslationFailure(
        job,
        configurationError ?? 'translation_missing_credentials',
      );
      return;
    }
    final hasExisting = document.segments.any(
      (segment) => segment.hasTranslation,
    );
    final targetChanged =
        hasExisting &&
        job.translationState.targetLanguage.isNotEmpty &&
        job.translationState.targetLanguage != targetLanguage;
    if (targetChanged && !replaceExisting) {
      await _setTranslationFailure(
        job,
        'translation_target_change_confirmation_required',
      );
      return;
    }
    if (_settings.translationSettings.targetLanguage != targetLanguage) {
      _settings = _settings.copyWith(
        translationSettings: settings.copyWith(targetLanguage: targetLanguage),
      );
      await _settingsRepository.save(_settings);
      await _updateQueuedTranslationOptions();
    }
    var updatedDocument = document;
    if (replaceExisting) {
      updatedDocument = document.copyWith(
        segments: [
          for (final segment in document.segments)
            segment.copyWith(clearTranslatedText: true),
        ],
      );
    }
    final updated = await _transition(
      job,
      document: updatedDocument,
      translationOptions: TranslationOptions(
        enabled: false,
        targetLanguage: targetLanguage,
        baseUrl: settings.baseUrl,
        model: settings.model,
      ),
    );
    await _runTranslation(
      updated,
      settings: settings,
      targetLanguage: targetLanguage,
    );
  }

  Future<void> retryTranslation(String id) async {
    final job = _jobs[id];
    if (job == null || !job.translationState.status.canRetry) return;
    final target = job.translationState.targetLanguage.isNotEmpty
        ? job.translationState.targetLanguage
        : _settings.translationSettings.targetLanguage;
    await translateJob(id, targetLanguage: target);
  }

  Future<void> retranslateSegment(String jobId, String segmentId) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) return;
    final target = job.translationState.targetLanguage.isNotEmpty
        ? job.translationState.targetLanguage
        : _settings.translationSettings.targetLanguage;
    final settings = _normalizeTranslationSettings(
      _settings.translationSettings.copyWith(targetLanguage: target),
    );
    await _runTranslation(
      job,
      settings: settings,
      targetLanguage: target,
      segmentIds: {segmentId},
    );
  }

  Future<void> updateTranslatedSegment(
    String jobId,
    String segmentId,
    String text,
  ) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) return;
    final value = text.trim();
    final segments = [
      for (final segment in document.segments)
        if (segment.id == segmentId)
          value.isEmpty
              ? segment.copyWith(clearTranslatedText: true)
              : segment.copyWith(translatedText: value)
        else
          segment,
    ];
    final progress = _translationProgress(segments);
    await _transition(
      job,
      document: document.copyWith(segments: segments),
      translationState: job.translationState.copyWith(
        status: progress.completed == progress.total
            ? TranslationStatus.completed
            : TranslationStatus.partial,
        completedSegments: progress.completed,
        totalSegments: progress.total,
        clearError: true,
      ),
    );
  }

  void cancelTranslation(String id) {
    if (_jobs[id]?.translationState.status.isActive ?? false) {
      _translationCancelledIds.add(id);
    }
  }

  Future<void> _runTranslation(
    TranscriptionJob job, {
    required TranslationSettings settings,
    required String targetLanguage,
    Set<String>? segmentIds,
  }) async {
    final service = _translationService;
    var current = _jobs[job.id] ?? job;
    final document = current.document;
    if (document == null) return;
    if (service == null) {
      await _setTranslationFailure(current, 'translation_unavailable');
      return;
    }
    final translatableSegments = document.segments
        .where(_isTranslatableSegment)
        .toList(growable: false);
    final candidates = translatableSegments
        .where(
          (segment) => segmentIds == null
              ? !segment.hasTranslation
              : segmentIds.contains(segment.id),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      final progress = _translationProgress(translatableSegments);
      await _transition(
        current,
        translationState: current.translationState.copyWith(
          status: progress.completed == progress.total
              ? TranslationStatus.completed
              : TranslationStatus.partial,
          targetLanguage: targetLanguage,
          model: settings.model,
          origin: TranslationOrigin.llm,
          completedSegments: progress.completed,
          totalSegments: progress.total,
          clearError: true,
        ),
      );
      return;
    }

    _translationCancelledIds.remove(job.id);
    current = await _transition(
      current,
      translationState: TranslationState(
        status: TranslationStatus.translating,
        targetLanguage: targetLanguage,
        model: settings.model,
        origin: TranslationOrigin.llm,
        completedSegments: _translationProgress(translatableSegments).completed,
        totalSegments: translatableSegments.length,
      ),
    );

    try {
      await service.translate(
        settings: settings,
        targetLanguage: targetLanguage,
        segments: candidates,
        shouldCancel: () => _translationCancelledIds.contains(job.id),
        onBatch: (translations, _, _) async {
          current = _jobs[job.id] ?? current;
          final latest = current.document;
          if (latest == null) return;
          final segments = [
            for (final segment in latest.segments)
              if (translations[segment.id] case final translated?)
                segment.copyWith(translatedText: translated)
              else
                segment,
          ];
          final progress = _translationProgress(segments);
          current = await _transition(
            current,
            document: latest.copyWith(segments: segments),
            translationState: current.translationState.copyWith(
              status: TranslationStatus.translating,
              completedSegments: progress.completed,
              totalSegments: progress.total,
              clearError: true,
            ),
          );
        },
      );
      current = _jobs[job.id] ?? current;
      final segments = current.document?.segments ?? const [];
      final progress = _translationProgress(segments);
      await _transition(
        current,
        translationState: current.translationState.copyWith(
          status: progress.completed == progress.total
              ? TranslationStatus.completed
              : TranslationStatus.partial,
          completedSegments: progress.completed,
          totalSegments: progress.total,
          errorCode: progress.completed == progress.total
              ? null
              : 'translation_incomplete_response',
          clearError: progress.completed == progress.total,
        ),
      );
    } on OperationCancelledException {
      current = _jobs[job.id] ?? current;
      final segments = current.document?.segments ?? const [];
      final progress = _translationProgress(segments);
      await _transition(
        current,
        translationState: current.translationState.copyWith(
          status: progress.completed > 0
              ? TranslationStatus.partial
              : TranslationStatus.cancelled,
          completedSegments: progress.completed,
          totalSegments: progress.total,
          errorCode: 'translation_cancelled',
          errorMessage: 'Translation was cancelled.',
        ),
      );
    } on TranslationException catch (error) {
      await _setTranslationFailure(
        _jobs[job.id] ?? current,
        error.code,
        error.message,
      );
    } on TimeoutException {
      await _setTranslationFailure(
        _jobs[job.id] ?? current,
        'translation_timeout',
      );
    } on SocketException {
      await _setTranslationFailure(
        _jobs[job.id] ?? current,
        'translation_network_error',
      );
    } on Object catch (error) {
      await _setTranslationFailure(
        _jobs[job.id] ?? current,
        'translation_request_failed',
        _safeError(error),
      );
    } finally {
      _translationCancelledIds.remove(job.id);
    }
  }

  Future<void> _setTranslationFailure(
    TranscriptionJob job,
    String code, [
    String? message,
  ]) async {
    final segments = job.document?.segments ?? const [];
    final progress = _translationProgress(segments);
    await _transition(
      job,
      translationState: TranslationState(
        status: progress.completed > 0 && progress.completed < progress.total
            ? TranslationStatus.partial
            : TranslationStatus.failed,
        targetLanguage: job.translationState.targetLanguage,
        model: job.translationState.model,
        origin: job.translationState.origin,
        completedSegments: progress.completed,
        totalSegments: progress.total,
        errorCode: code,
        errorMessage: message == null ? null : _safeError(message),
      ),
    );
  }

  Future<void> _updateQueuedTranslationOptions() async {
    final options = TranslationOptions.fromSettings(
      _settings.translationSettings,
    );
    for (final job in workspaceJobs.where(
      (job) => job.document == null && job.remoteTranscriptionId == null,
    )) {
      await _transition(job, translationOptions: options);
    }
  }

  Future<void> _updateQueuedSonioxTranslationOptions() async {
    for (final job in workspaceJobs.where(
      (job) => job.document == null && job.remoteTranscriptionId == null,
    )) {
      await _transition(
        job,
        options: job.options.copyWith(
          sonioxTranslation: _settings.sonioxTranslation,
        ),
      );
    }
  }

  TranslationState _sonioxTranslationState(
    TranscriptDocument document,
    String targetLanguage,
  ) {
    final progress = _translationProgress(document.segments);
    final complete = progress.completed == progress.total;
    return TranslationState(
      status: complete
          ? TranslationStatus.completed
          : TranslationStatus.partial,
      targetLanguage: targetLanguage,
      model: SonioxApiClient.model,
      origin: TranslationOrigin.soniox,
      completedSegments: progress.completed,
      totalSegments: progress.total,
      errorCode: complete ? null : 'translation_incomplete_response',
    );
  }

  bool _isTranslatableSegment(TranscriptSegment segment) =>
      segment.text.trim().isNotEmpty;

  ({int completed, int total}) _translationProgress(
    Iterable<TranscriptSegment> segments,
  ) {
    var completed = 0;
    var total = 0;
    for (final segment in segments) {
      if (!_isTranslatableSegment(segment)) continue;
      total++;
      if (segment.hasTranslation) completed++;
    }
    return (completed: completed, total: total);
  }

  TranslationSettings _normalizeTranslationSettings(TranslationSettings value) {
    final baseUrl = value.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return value.copyWith(baseUrl: baseUrl, model: value.model.trim());
  }

  String _initialTargetLanguage() {
    final locale = Platform.localeName.replaceAll('_', '-').toLowerCase();
    if (locale.startsWith('zh')) {
      if (locale.contains('hant') ||
          locale.contains('-tw') ||
          locale.contains('-hk') ||
          locale.contains('-mo')) {
        return 'zh-Hant';
      }
      return 'zh-Hans';
    }
    final base = locale.split('-').first;
    return supportedTranslationLanguageCodes.contains(base) ? base : 'en';
  }

  String _initialSonioxTargetLanguage() {
    final base = Platform.localeName
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    return supportedSonioxTranslationLanguageCodes.contains(base) ? base : 'en';
  }

  Future<String> exportJob(
    String id,
    String directory,
    ExportOptions options,
  ) async {
    final job = _jobs[id];
    if (job == null) throw StateError('Job not found.');
    return _exporter.exportToDirectory(job, directory, options);
  }

  String renderJob(String id, ExportOptions options) {
    final job = _jobs[id];
    if (job?.document == null) return '';
    return _exporter.render(
      job!.document!,
      options,
      title: job.fileName,
      metadata: job.metadata,
    );
  }

  Future<List<String>> exportCompleted(
    String directory,
    ExportOptions options,
  ) async {
    final results = <String>[];
    for (final job in workspaceJobs.where((item) => item.document != null)) {
      results.add(await _exporter.exportToDirectory(job, directory, options));
    }
    return results;
  }

  Future<String> exportCompletedZip(
    String destination,
    ExportOptions options,
  ) => _exporter.exportZip(
    workspaceJobs.where((job) => job.document != null).toList(),
    destination,
    options,
  );

  Future<String?> loadWaveform(String jobId) async {
    final job = _jobs[jobId];
    if (job == null) return null;
    try {
      return await _media.renderWaveform(job.sourcePath, job.id);
    } on Object {
      return null;
    }
  }

  Future<void> _recover(List<TranscriptionJob> interrupted) async {
    if (interrupted.isEmpty) return;
    final resumable = <String>[];
    for (final job in interrupted) {
      if (job.remoteTranscriptionId != null) {
        resumable.add(job.id);
      } else {
        await _transition(
          job,
          status: JobStatus.ready,
          progress: const JobProgress(stage: 'ready', fraction: 0),
          clearError: true,
        );
      }
    }
    if (resumable.isEmpty || !_keyConfigured) return;
    _processing = true;
    notifyListeners();
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < resumable.length) {
        await _runJob(resumable[cursor++]);
      }
    }

    await Future.wait(
      List.generate(
        min(_settings.concurrency, resumable.length),
        (_) => worker(),
      ),
    );
    _processing = false;
    notifyListeners();
  }

  Future<void> _retryPendingCleanup(List<TranscriptionJob> jobs) async {
    if (!_keyConfigured) return;
    for (final job in jobs.where(
      (item) => item.cleanupState == CleanupState.pending,
    )) {
      if (!job.status.isActive) await _cleanup(job);
    }
  }

  Future<void> _cleanup(TranscriptionJob job) async {
    if (job.cleanupState == CleanupState.complete) return;
    var success = true;
    if (job.remoteTranscriptionId case final id?) {
      try {
        await _soniox.deleteTranscription(id);
      } on Object {
        success = false;
      }
    }
    if (job.remoteFileId case final id?) {
      try {
        await _soniox.deleteFile(id);
      } on Object {
        success = false;
      }
    }
    await _transition(
      _jobs[job.id] ?? job,
      cleanupState: success ? CleanupState.complete : CleanupState.pending,
    );
  }

  Future<TranscriptionJob> _progress(
    String id,
    String stage,
    double? fraction,
    String? detail,
  ) async {
    final job = _jobs[id];
    if (job == null) throw StateError('Job not found.');
    return _transition(
      job,
      progress: JobProgress(stage: stage, fraction: fraction, detail: detail),
    );
  }

  Future<TranscriptionJob> _fail(
    TranscriptionJob job,
    String code,
    String message, {
    JobStatus status = JobStatus.failed,
  }) => _transition(
    job,
    status: status,
    errorCode: code,
    errorMessage: message,
    progress: const JobProgress(stage: 'failed'),
  );

  String _safeError(Object error) {
    final value = error.toString();
    return value
        .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{10,}'), '[REDACTED]')
        .replaceAll(
          RegExp(r'Bearer\s+\S+', caseSensitive: false),
          'Bearer [REDACTED]',
        );
  }

  Future<TranscriptionJob> _transition(
    TranscriptionJob job, {
    String? sourcePath,
    JobStatus? status,
    int? queueIndex,
    JobProgress? progress,
    MediaMetadata? metadata,
    TranscriptionOptions? options,
    TranslationOptions? translationOptions,
    TranslationState? translationState,
    TranscriptDocument? document,
    String? errorCode,
    String? errorMessage,
    String? remoteFileId,
    String? remoteTranscriptionId,
    CleanupState? cleanupState,
    bool clearError = false,
    bool clearRemoteFileId = false,
    bool clearRemoteTranscriptionId = false,
  }) async {
    final updated = job.copyWith(
      sourcePath: sourcePath,
      status: status,
      queueIndex: queueIndex,
      progress: progress,
      metadata: metadata,
      options: options,
      translationOptions: translationOptions,
      translationState: translationState,
      document: document,
      errorCode: errorCode,
      errorMessage: errorMessage,
      remoteFileId: remoteFileId,
      remoteTranscriptionId: remoteTranscriptionId,
      cleanupState: cleanupState,
      clearError: clearError,
      clearRemoteFileId: clearRemoteFileId,
      clearRemoteTranscriptionId: clearRemoteTranscriptionId,
    );
    _jobs[job.id] = updated;
    await _jobsRepository.save(updated);
    notifyListeners();
    return updated;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
