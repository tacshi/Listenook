import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/transcript_parser.dart';
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
    TranscriptParser parser = const TranscriptParser(),
    Uuid uuid = const Uuid(),
  }) : _credentials = credentialStore,
       _settingsRepository = settingsRepository,
       _jobsRepository = jobRepository,
       _media = mediaService,
       _soniox = sonioxClient,
       _exporter = exporter,
       _parser = parser,
       _uuid = uuid;

  final CredentialStore _credentials;
  final SettingsRepository _settingsRepository;
  final JobRepository _jobsRepository;
  final MediaService _media;
  final SonioxClient _soniox;
  final TranscriptExporter _exporter;
  final TranscriptParser _parser;
  final Uuid _uuid;
  final Map<String, TranscriptionJob> _jobs = {};
  final List<String> _workspaceIds = [];
  final Set<String> _cancelledIds = {};
  String _batchId = '';
  bool _processing = false;
  bool _initializing = true;
  bool _keyConfigured = false;
  int _destinationIndex = 0;
  String? _selectedJobId;
  MediaDiagnostics? _mediaDiagnostics;
  AppSettings _settings = const AppSettings();

  AppSettings get settings => _settings;
  bool get initializing => _initializing;
  bool get processing => _processing;
  bool get hasActiveWork => _jobs.values.any((job) => job.status.isActive);
  bool get keyConfigured => _keyConfigured;
  int get destinationIndex => _destinationIndex;
  String? get selectedJobId => _selectedJobId;
  MediaDiagnostics? get mediaDiagnostics => _mediaDiagnostics;

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
  int get untranscribedWorkspaceCount =>
      workspaceJobs.where((job) => job.document == null).length;
  bool get canStartNewSession =>
      workspaceJobs.isNotEmpty &&
      !_processing &&
      !workspaceJobs.any((job) => job.status.isActive);

  Future<void> initialize() async {
    _settings = await _settingsRepository.load();
    final stored = await _jobsRepository.loadAll();
    final loaded = <TranscriptionJob>[];
    for (final original in stored) {
      final document = original.document;
      final normalized = document == null
          ? null
          : _parser.normalizeSegments(document);
      final job = normalized == null || identical(normalized, document)
          ? original
          : original.copyWith(document: normalized);
      _jobs[job.id] = job;
      loaded.add(job);
      if (!identical(job, original)) {
        await _jobsRepository.save(job);
      }
    }
    _keyConfigured = (await _credentials.readApiKey())?.isNotEmpty ?? false;
    _batchId = _uuid.v4();
    final interrupted = loaded.where((job) => job.status.isActive).toList()
      ..sort((a, b) {
        final order = a.queueIndex.compareTo(b.queueIndex);
        return order == 0 ? a.createdAt.compareTo(b.createdAt) : order;
      });
    if (interrupted.isNotEmpty) {
      _batchId = interrupted.first.batchId;
      _workspaceIds.addAll(interrupted.map((job) => job.id));
    }
    _initializing = false;
    notifyListeners();
    unawaited(refreshMediaDiagnostics());
    unawaited(_recover(interrupted));
    unawaited(_retryPendingCleanup(loaded));
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
        options: TranscriptionOptions(
          languageHints: _settings.languageHints,
          contextTerms: _settings.contextTerms,
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
      final document = _parser.parse(payload);
      final status = document.segments.isEmpty
          ? JobStatus.empty
          : JobStatus.completed;
      job = await _transition(
        job,
        status: status,
        document: document,
        progress: const JobProgress(stage: 'complete', fraction: 1),
        clearError: true,
      );
      await _cleanup(job);
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
            code: state.errorType ?? 'transcription_failed',
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
  }

  Future<void> cancelRemoteJobsForQuit() async {
    final active = workspaceJobs.where((job) => job.status.isActive).toList();
    for (final job in active) {
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

  Future<void> relink(String id, String sourcePath) async {
    final job = _jobs[id];
    if (job == null) return;
    final updated = await _transition(
      job,
      sourcePath: sourcePath,
      status: JobStatus.pending,
      progress: const JobProgress(stage: 'pending'),
      clearError: true,
    );
    await _prepare(updated.id);
  }

  Future<void> removeFromWorkspace(String id) async {
    final job = _jobs[id];
    if (job == null || job.status.isActive) return;
    _workspaceIds.remove(id);
    if (job.document == null) {
      _jobs.remove(id);
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
      await _jobsRepository.delete(id);
    }
    _workspaceIds.clear();
    _selectedJobId = null;
    _batchId = _uuid.v4();
    notifyListeners();
  }

  Future<void> deleteHistory(String id) async {
    final job = _jobs[id];
    if (job == null || job.status.isActive) return;
    _jobs.remove(id);
    _workspaceIds.remove(id);
    if (_selectedJobId == id) _selectedJobId = null;
    await _jobsRepository.delete(id);
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
        if (segment.id == segmentId) segment.copyWith(text: text) else segment,
    ];
    await _transition(job, document: document.copyWith(segments: segments));
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

  Future<void> refreshMediaDiagnostics() async {
    _mediaDiagnostics = await _media.diagnostics();
    notifyListeners();
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
