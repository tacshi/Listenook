import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';
import '../core/transcript_parser.dart';
import '../data/openai_translation_service.dart';
import '../data/inbox_folder_monitor.dart';
import '../data/podcast/download_location.dart';
import '../data/podcast/podcast_urls.dart';
import '../data/podcast/publisher_transcript.dart';
import '../data/process_media_service.dart';
import '../data/soniox_api_client.dart';
import '../data/transcript_exporter.dart';

enum AppDestination { inbox, podcast, workspace, library, settings }

class AppController extends ChangeNotifier {
  static const _maxConcurrentJobs = 4;

  AppController({
    required CredentialStore credentialStore,
    required SettingsRepository settingsRepository,
    required JobRepository jobRepository,
    LibraryCatalogRepository? libraryCatalogRepository,
    required MediaService mediaService,
    required MediaSourceResolver sourceResolver,
    required SonioxClient sonioxClient,
    required TranscriptExporter exporter,
    TranslationCredentialStore? translationCredentialStore,
    TranslationService? translationService,
    AiBriefService? aiBriefService,
    InboxMonitorRepository? inboxMonitorRepository,
    InboxFolderMonitor? inboxFolderMonitor,
    PodcastGateway? podcastGateway,
    String? podcastManagedRoot,
    TranscriptParser parser = const TranscriptParser(),
    PublisherTranscriptParser publisherTranscriptParser =
        const PublisherTranscriptParser(),
    PodcastDownloadLocator downloadLocator = const PodcastDownloadLocator(),
    Uuid uuid = const Uuid(),
  }) : _credentials = credentialStore,
       _settingsRepository = settingsRepository,
       _jobsRepository = jobRepository,
       _libraryCatalogRepository = libraryCatalogRepository,
       _media = mediaService,
       _soniox = sonioxClient,
       _exporter = exporter,
       _sourceResolver = sourceResolver,
       _translationCredentials = translationCredentialStore,
       _translationService = translationService,
       _aiBriefService = aiBriefService,
       _inboxMonitorRepository = inboxMonitorRepository,
       _inboxFolderMonitor = inboxFolderMonitor,
       _podcastGateway = podcastGateway,
       _podcastManagedRoot = podcastManagedRoot,
       _parser = parser,
       _publisherTranscriptParser = publisherTranscriptParser,
       _downloadLocator = downloadLocator,
       _uuid = uuid;

  final CredentialStore _credentials;
  final SettingsRepository _settingsRepository;
  final JobRepository _jobsRepository;
  final LibraryCatalogRepository? _libraryCatalogRepository;
  final MediaService _media;
  final SonioxClient _soniox;
  final TranscriptExporter _exporter;
  final MediaSourceResolver _sourceResolver;
  final TranslationCredentialStore? _translationCredentials;
  final TranslationService? _translationService;
  final AiBriefService? _aiBriefService;
  final InboxMonitorRepository? _inboxMonitorRepository;
  final InboxFolderMonitor? _inboxFolderMonitor;
  final PodcastGateway? _podcastGateway;
  final String? _podcastManagedRoot;
  final TranscriptParser _parser;
  final PublisherTranscriptParser _publisherTranscriptParser;
  final PodcastDownloadLocator _downloadLocator;
  final Uuid _uuid;
  final Set<String> _downloadCancelledIds = {};
  int _activePodcastDownloads = 0;
  final Map<String, TranscriptionJob> _jobs = {};
  final Map<String, Duration> _playbackPositions = {};
  final List<String> _inboxIds = [];
  final Set<String> _cancelledIds = {};
  final Set<String> _translationCancelledIds = {};
  final Set<String> _aiBriefCancelledIds = {};
  final Set<String> _monitorCandidatesInFlight = {};
  String _batchId = '';
  bool _processing = false;
  bool _initializing = true;
  bool _keyConfigured = false;
  bool _translationKeyConfigured = false;
  bool _monitorShutDown = false;
  AppDestination _destination = AppDestination.inbox;
  String? _activeWorkspaceJobId;
  AppSettings _settings = const AppSettings();
  LibraryCatalog _libraryCatalog = const LibraryCatalog();
  TranscriptionOptions _sessionOptions = const TranscriptionOptions();
  InboxMonitorStorage _inboxMonitorStorage = const InboxMonitorStorage();
  InboxMonitorStatus _inboxMonitorStatus = InboxMonitorStatus.unconfigured;
  String? _inboxMonitorError;

  AppSettings get settings => _settings;
  InboxMonitorConfig get inboxMonitorConfig => _inboxMonitorStorage.config;
  InboxMonitorStatus get inboxMonitorStatus => _inboxMonitorStatus;
  String? get inboxMonitorError => _inboxMonitorError;
  bool get inboxMonitorConfigured => inboxMonitorConfig.isConfigured;
  int get monitoredWaitingCount => inboxJobs
      .where(
        (job) =>
            job.sourceOrigin == JobSourceOrigin.monitoredFolder &&
            job.document == null,
      )
      .length;
  int get monitoredHandledCount => _inboxMonitorStorage.records.values
      .where(
        (record) =>
            record.disposition == MonitoredFileDisposition.completed ||
            record.disposition == MonitoredFileDisposition.dismissed,
      )
      .length;
  LibraryCatalog get libraryCatalog => _libraryCatalog;
  List<LibraryGroup> get libraryGroups {
    final groups = List<LibraryGroup>.of(_libraryCatalog.groups)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  List<LibraryTag> get libraryTags {
    final tags = List<LibraryTag>.of(_libraryCatalog.tags)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return tags;
  }

  LibraryGroup? libraryGroupById(String? id) {
    if (id == null) return null;
    for (final group in _libraryCatalog.groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  LibraryTag? libraryTagById(String id) {
    for (final tag in _libraryCatalog.tags) {
      if (tag.id == id) return tag;
    }
    return null;
  }

  TranscriptionOptions get sessionOptions => _sessionOptions;
  bool get initializing => _initializing;
  bool get processing => _processing;
  bool get hasActiveWork => _jobs.values.any((job) => job.isBusy);
  bool get keyConfigured => _keyConfigured;
  bool get translationKeyConfigured => _translationKeyConfigured;
  bool get translationConfigured => _settings.translationSettings.isConfigured(
    hasApiKey: _translationKeyConfigured,
  );
  bool get aiBriefConfigured => _settings.llmProviderSettings.isConfigured(
    hasApiKey: _translationKeyConfigured,
  );
  String get defaultAiBriefLanguage => switch (_settings.localeMode) {
    AppLocaleMode.simplifiedChinese => 'zh-Hans',
    AppLocaleMode.english => 'en',
    AppLocaleMode.system => _initialTargetLanguage(),
  };
  AppDestination get destination => _destination;
  String? get activeWorkspaceJobId => _activeWorkspaceJobId;

  List<TranscriptionJob> get allJobs {
    final list = _jobs.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<TranscriptionJob> get inboxJobs => _inboxIds
      .map((id) => _jobs[id])
      .whereType<TranscriptionJob>()
      .toList(growable: false);

  TranscriptionJob? jobById(String id) => _jobs[id];

  TranscriptionJob? get activeWorkspaceJob =>
      _activeWorkspaceJobId == null ? null : _jobs[_activeWorkspaceJobId];

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
      inboxJobs.where((job) => job.status.canTranscribe).length;
  int get processingCount => inboxJobs.where((job) => job.isBusy).length;
  int get completedCount =>
      inboxJobs.where((job) => job.status == JobStatus.completed).length;
  int get failedCount => inboxJobs
      .where(
        (job) =>
            job.status == JobStatus.failed ||
            job.status == JobStatus.missingSource,
      )
      .length;
  int get inactiveHistoryCount =>
      _jobs.values.where((job) => !job.isBusy).length;
  int get untranscribedInboxCount =>
      inboxJobs.where((job) => job.document == null).length;
  bool get canStartNewInboxBatch =>
      inboxJobs.isNotEmpty &&
      !_processing &&
      !inboxJobs.any((job) => job.isBusy);

  Future<void> initialize() async {
    _libraryCatalog =
        await _libraryCatalogRepository?.load() ?? const LibraryCatalog();
    _settings = await _settingsRepository.load();
    _inboxMonitorStorage =
        await _inboxMonitorRepository?.load() ?? const InboxMonitorStorage();
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
      if (job.aiGenerationState.status == AiGenerationStatus.generating) {
        job = job.copyWith(
          aiGenerationState: job.aiGenerationState.copyWith(
            status: AiGenerationStatus.interrupted,
            errorCode: 'ai_brief_interrupted',
            errorMessage: 'AI Brief generation was interrupted.',
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
    for (final job in List<TranscriptionJob>.of(loaded)) {
      if (job.status != JobStatus.downloading) continue;
      final failed = await _fail(
        job,
        'download_interrupted',
        'The podcast download was interrupted.',
      );
      final index = loaded.indexWhere((item) => item.id == job.id);
      if (index >= 0) loaded[index] = failed;
    }
    final interrupted = loaded.where((job) => job.status.isActive).toList()
      ..sort((a, b) {
        final order = a.queueIndex.compareTo(b.queueIndex);
        return order == 0 ? a.createdAt.compareTo(b.createdAt) : order;
      });
    if (interrupted.isNotEmpty) {
      _batchId = interrupted.first.batchId;
      _sessionOptions = interrupted.first.options;
      _inboxIds.addAll(interrupted.map((job) => job.id));
    }
    await _seedMonitorLedgerFromJobs(loaded);
    _initializing = false;
    notifyListeners();
    await _restartInboxMonitor();
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

  Future<void> configureInboxMonitor({
    required String folderPath,
    required Set<String> extensions,
    required bool launchAtLogin,
  }) async {
    final normalizedExtensions = extensions
        .map((value) => value.trim().toLowerCase().replaceFirst('.', ''))
        .where(supportedMonitoredMediaExtensions.contains)
        .toSet();
    if (normalizedExtensions.isEmpty) {
      throw ArgumentError.value(
        extensions,
        'extensions',
        'Select a file type.',
      );
    }
    final absolute = p.canonicalize(p.absolute(folderPath));
    if (!await Directory(absolute).exists()) {
      throw ArgumentError.value(folderPath, 'folderPath', 'Folder not found.');
    }
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: InboxMonitorConfig(
        folderPath: absolute,
        extensions: normalizedExtensions,
        launchAtLogin: launchAtLogin,
        showTrayIcon: inboxMonitorConfig.showTrayIcon,
      ),
    );
    await _seedMonitorLedgerFromJobs(allJobs);
    await _persistInboxMonitor();
    notifyListeners();
    await _restartInboxMonitor();
  }

  Future<void> setInboxMonitorPaused(bool paused) async {
    if (!inboxMonitorConfigured || inboxMonitorConfig.paused == paused) return;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: inboxMonitorConfig.copyWith(paused: paused),
    );
    await _persistInboxMonitor();
    notifyListeners();
    await _restartInboxMonitor();
  }

  Future<void> clearInboxMonitor() async {
    if (!inboxMonitorConfigured) return;
    final config = inboxMonitorConfig;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: InboxMonitorConfig(
        extensions: config.extensions,
        launchAtLogin: config.launchAtLogin,
        showTrayIcon: config.showTrayIcon,
      ),
    );
    await _persistInboxMonitor();
    notifyListeners();
    await _restartInboxMonitor();
  }

  Future<void> setInboxMonitorLaunchAtLogin(bool enabled) async {
    if (inboxMonitorConfig.launchAtLogin == enabled) {
      return;
    }
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: inboxMonitorConfig.copyWith(launchAtLogin: enabled),
    );
    await _persistInboxMonitor();
    notifyListeners();
  }

  Future<void> setDesktopTrayIconVisible(bool visible) async {
    if (inboxMonitorConfig.showTrayIcon == visible) return;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: inboxMonitorConfig.copyWith(showTrayIcon: visible),
    );
    await _persistInboxMonitor();
    notifyListeners();
  }

  Future<void> rescanInboxMonitor() =>
      _inboxFolderMonitor?.scanNow() ?? Future<void>.value();

  Future<void> _restartInboxMonitor() async {
    final monitor = _inboxFolderMonitor;
    if (monitor == null) {
      _setInboxMonitorStatus(
        inboxMonitorConfigured
            ? (inboxMonitorConfig.paused
                  ? InboxMonitorStatus.paused
                  : InboxMonitorStatus.active)
            : InboxMonitorStatus.unconfigured,
        null,
      );
      return;
    }
    await monitor.start(
      inboxMonitorConfig,
      onCandidate: _enqueueMonitoredCandidate,
      onSnapshot: _reconcileMonitoredSnapshot,
      onStatus: _setInboxMonitorStatus,
    );
  }

  Future<void> _reconcileMonitoredSnapshot(Set<String> identities) async {
    if (!inboxMonitorConfigured) return;
    final records = Map<String, MonitoredFileRecord>.of(
      _inboxMonitorStorage.records,
    );
    final removedJobs = <TranscriptionJob>[];
    var recordsChanged = false;
    for (final entry in _inboxMonitorStorage.records.entries) {
      if (identities.contains(entry.key) ||
          entry.value.disposition != MonitoredFileDisposition.queued) {
        continue;
      }
      final jobId = entry.value.jobId;
      final job = jobId == null ? null : _jobs[jobId];
      if (job != null && !_canRemoveMissingMonitoredJob(job)) continue;
      records.remove(entry.key);
      recordsChanged = true;
      if (job != null) removedJobs.add(job);
    }
    if (!recordsChanged) return;
    for (final job in removedJobs) {
      _inboxIds.remove(job.id);
      _jobs.remove(job.id);
      _playbackPositions.remove(job.id);
      await _media.deleteGeneratedMedia(job.id);
      await _jobsRepository.delete(job.id);
    }
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(records: records);
    await _persistInboxMonitor();
    notifyListeners();
  }

  bool _canRemoveMissingMonitoredJob(TranscriptionJob job) {
    if (job.sourceOrigin != JobSourceOrigin.monitoredFolder ||
        job.document != null) {
      return false;
    }
    return switch (job.status) {
      JobStatus.pending ||
      JobStatus.probing ||
      JobStatus.ready ||
      JobStatus.paused ||
      JobStatus.missingSource => true,
      JobStatus.failed =>
        job.metadata == null &&
            job.remoteFileId == null &&
            job.remoteTranscriptionId == null,
      _ => false,
    };
  }

  void _setInboxMonitorStatus(InboxMonitorStatus status, String? error) {
    if (_inboxMonitorStatus == status && _inboxMonitorError == error) return;
    _inboxMonitorStatus = status;
    _inboxMonitorError = error;
    notifyListeners();
  }

  Future<void> _seedMonitorLedgerFromJobs(
    Iterable<TranscriptionJob> jobs,
  ) async {
    if (!inboxMonitorConfigured) return;
    final records = Map<String, MonitoredFileRecord>.of(
      _inboxMonitorStorage.records,
    );
    var changed = false;
    for (final job in jobs) {
      if (job.status != JobStatus.completed && job.status != JobStatus.empty) {
        continue;
      }
      if (!_pathIsInMonitoredFolder(job.sourcePath)) continue;
      final fingerprint =
          job.sourceFingerprint ??
          await fingerprintMonitoredFile(job.sourcePath);
      if (fingerprint == null) continue;
      final current = records[fingerprint.identity];
      if (current != null && current.fingerprint.sameVersion(fingerprint)) {
        continue;
      }
      records[fingerprint.identity] = MonitoredFileRecord(
        fingerprint: fingerprint,
        disposition: MonitoredFileDisposition.completed,
        updatedAt: DateTime.now().toUtc(),
        jobId: job.id,
      );
      changed = true;
    }
    if (!changed) return;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(records: records);
    await _persistInboxMonitor();
  }

  Future<void> _enqueueMonitoredCandidate(SourceFingerprint fingerprint) async {
    final existing = _inboxMonitorStorage.records[fingerprint.identity];
    if (existing != null && existing.fingerprint.sameVersion(fingerprint)) {
      return;
    }
    if (!_monitorCandidatesInFlight.add(fingerprint.identity)) return;
    try {
      for (final job in _jobs.values) {
        if (_sourceResolver.identityFor(job.sourcePath) ==
            fingerprint.identity) {
          await _recordMonitoredFile(
            job,
            job.document != null ||
                    job.status == JobStatus.completed ||
                    job.status == JobStatus.empty
                ? MonitoredFileDisposition.completed
                : MonitoredFileDisposition.queued,
            fingerprint: fingerprint,
          );
          return;
        }
        final known = job.sourceFingerprint;
        if (known == null || !known.sameVersion(fingerprint)) continue;
        await _recordMonitoredFile(
          job,
          job.document != null ||
                  job.status == JobStatus.completed ||
                  job.status == JobStatus.empty
              ? MonitoredFileDisposition.completed
              : MonitoredFileDisposition.queued,
          fingerprint: fingerprint,
        );
        return;
      }
      final job = await _enqueueResolvedSource(
        ResolvedMediaSource(
          path: fingerprint.path,
          identity: fingerprint.identity,
        ),
        sourceOrigin: JobSourceOrigin.monitoredFolder,
        fingerprint: fingerprint,
      );
      if (job != null) {
        await _recordMonitoredFile(
          job,
          MonitoredFileDisposition.queued,
          fingerprint: fingerprint,
        );
      }
    } finally {
      _monitorCandidatesInFlight.remove(fingerprint.identity);
    }
  }

  Future<void> _recordMonitoredFile(
    TranscriptionJob job,
    MonitoredFileDisposition disposition, {
    SourceFingerprint? fingerprint,
  }) async {
    final value = fingerprint ?? job.sourceFingerprint;
    if (value == null || !inboxMonitorConfigured) return;
    final records = Map<String, MonitoredFileRecord>.of(
      _inboxMonitorStorage.records,
    );
    final current = records[value.identity];
    if (current != null &&
        current.fingerprint.sameVersion(value) &&
        current.disposition == disposition &&
        current.jobId == job.id) {
      return;
    }
    records[value.identity] = MonitoredFileRecord(
      fingerprint: value,
      disposition: disposition,
      updatedAt: DateTime.now().toUtc(),
      jobId: job.id,
    );
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(records: records);
    await _persistInboxMonitor();
    notifyListeners();
  }

  bool _pathIsInMonitoredFolder(String path) {
    if (!inboxMonitorConfigured) return false;
    final folder = monitoredPathIdentity(inboxMonitorConfig.folderPath);
    final candidate = monitoredPathIdentity(path);
    return candidate == folder || p.isWithin(folder, candidate);
  }

  Future<void> _persistInboxMonitor() =>
      _inboxMonitorRepository?.save(_inboxMonitorStorage) ??
      Future<void>.value();

  void setDestination(AppDestination destination) {
    if (_destination == destination) return;
    _destination = destination;
    notifyListeners();
  }

  Future<void> renameLibraryItem(String id, String? title) async {
    final job = _jobs[id];
    if (job == null) return;
    final normalized = title?.trim();
    if (normalized != null && normalized.length > 200) {
      throw ArgumentError.value(title, 'title', 'Title is too long.');
    }
    await _transition(
      job,
      displayTitle: normalized,
      clearDisplayTitle: normalized == null || normalized.isEmpty,
    );
  }

  Future<LibraryGroup> createLibraryGroup(String name) async {
    final normalized = _validateOrganizerName(name);
    if (_libraryCatalog.groups.any(
      (group) => group.name.toLowerCase() == normalized.toLowerCase(),
    )) {
      throw ArgumentError.value(name, 'name', 'Group name already exists.');
    }
    final group = LibraryGroup(id: _uuid.v4(), name: normalized);
    _libraryCatalog = _libraryCatalog.copyWith(
      groups: [..._libraryCatalog.groups, group],
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
    return group;
  }

  Future<LibraryTag> createLibraryTag(String name) async {
    final normalized = _validateOrganizerName(name);
    if (_libraryCatalog.tags.any(
      (tag) => tag.name.toLowerCase() == normalized.toLowerCase(),
    )) {
      throw ArgumentError.value(name, 'name', 'Tag name already exists.');
    }
    final tag = LibraryTag(id: _uuid.v4(), name: normalized);
    _libraryCatalog = _libraryCatalog.copyWith(
      tags: [..._libraryCatalog.tags, tag],
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
    return tag;
  }

  Future<void> renameLibraryGroup(String id, String name) async {
    final normalized = _validateOrganizerName(name);
    if (_libraryCatalog.groups.any(
      (group) =>
          group.id != id &&
          group.name.toLowerCase() == normalized.toLowerCase(),
    )) {
      throw ArgumentError.value(name, 'name', 'Group name already exists.');
    }
    if (libraryGroupById(id) == null) return;
    _libraryCatalog = _libraryCatalog.copyWith(
      groups: [
        for (final group in _libraryCatalog.groups)
          if (group.id == id) group.copyWith(name: normalized) else group,
      ],
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
  }

  Future<void> deleteLibraryGroup(String id) async {
    if (libraryGroupById(id) == null) return;
    for (final job in _jobs.values.where((job) => job.groupId == id).toList()) {
      await _transition(job, clearGroupId: true);
    }
    _libraryCatalog = _libraryCatalog.copyWith(
      groups: _libraryCatalog.groups
          .where((group) => group.id != id)
          .toList(growable: false),
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
  }

  Future<void> renameLibraryTag(String id, String name) async {
    final normalized = _validateOrganizerName(name);
    if (_libraryCatalog.tags.any(
      (tag) =>
          tag.id != id && tag.name.toLowerCase() == normalized.toLowerCase(),
    )) {
      throw ArgumentError.value(name, 'name', 'Tag name already exists.');
    }
    if (libraryTagById(id) == null) return;
    _libraryCatalog = _libraryCatalog.copyWith(
      tags: [
        for (final tag in _libraryCatalog.tags)
          if (tag.id == id) tag.copyWith(name: normalized) else tag,
      ],
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
  }

  Future<void> deleteLibraryTag(String id) async {
    if (libraryTagById(id) == null) return;
    for (final job
        in _jobs.values.where((job) => job.tagIds.contains(id)).toList()) {
      await _transition(job, tagIds: Set<String>.of(job.tagIds)..remove(id));
    }
    _libraryCatalog = _libraryCatalog.copyWith(
      tags: _libraryCatalog.tags
          .where((tag) => tag.id != id)
          .toList(growable: false),
    );
    await _libraryCatalogRepository?.save(_libraryCatalog);
    notifyListeners();
  }

  Future<void> moveLibraryItems(Iterable<String> ids, String? groupId) async {
    if (groupId != null && libraryGroupById(groupId) == null) {
      throw ArgumentError.value(groupId, 'groupId', 'Unknown group.');
    }
    for (final id in ids.toSet()) {
      final job = _jobs[id];
      if (job == null || job.groupId == groupId) continue;
      await _transition(job, groupId: groupId, clearGroupId: groupId == null);
    }
  }

  Future<void> updateLibraryItemTags(
    Iterable<String> ids, {
    Set<String> addTagIds = const {},
    Set<String> removeTagIds = const {},
  }) async {
    final knownTagIds = _libraryCatalog.tags.map((tag) => tag.id).toSet();
    if (!knownTagIds.containsAll(addTagIds)) {
      throw ArgumentError.value(addTagIds, 'addTagIds', 'Unknown tag.');
    }
    for (final id in ids.toSet()) {
      final job = _jobs[id];
      if (job == null) continue;
      final updatedTagIds = Set<String>.of(job.tagIds)
        ..addAll(addTagIds)
        ..removeAll(removeTagIds);
      if (setEquals(updatedTagIds, job.tagIds)) continue;
      await _transition(job, tagIds: updatedTagIds);
    }
  }

  String _validateOrganizerName(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 60) {
      throw ArgumentError.value(name, 'name', 'Invalid organizer name.');
    }
    return normalized;
  }

  void reorderInbox(int oldIndex, int newIndex) {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _inboxIds.length ||
        newIndex >= _inboxIds.length) {
      return;
    }
    final id = _inboxIds.removeAt(oldIndex);
    _inboxIds.insert(newIndex, id);
    notifyListeners();
    unawaited(_persistInboxOrder());
  }

  Future<void> _persistInboxOrder() async {
    for (var index = 0; index < _inboxIds.length; index++) {
      final job = _jobs[_inboxIds[index]];
      if (job != null && job.queueIndex != index) {
        await _transition(job, queueIndex: index);
      }
    }
  }

  TranscriptionJob? jobForEpisode(String episodeId) {
    for (final job in _jobs.values) {
      if (job.id == episodeId ||
          job.podcastProvenance?.episodeId == episodeId) {
        return job;
      }
    }
    return null;
  }

  List<TranscriptionJob> get podcastJobs {
    final jobs = [
      for (final job in _jobs.values)
        if (job.status != JobStatus.cancelled && _isPodcastLibraryJob(job)) job,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return jobs;
  }

  bool _isPodcastLibraryJob(TranscriptionJob job) {
    if (job.sourceOrigin == JobSourceOrigin.podcast) return true;
    return _isManagedPodcastPath(job.sourcePath);
  }

  bool _isManagedPodcastPath(String path) {
    final root = _podcastManagedRoot;
    if (root == null || root.isEmpty) return false;
    final value = path.trim();
    if (value.isEmpty) return false;
    final podcastsRoot = p.normalize(p.join(p.absolute(root), 'podcasts'));
    final file = p.normalize(p.absolute(value));
    return file == podcastsRoot || p.isWithin(podcastsRoot, file);
  }

  String? localMediaPathForEpisode(String episodeId) {
    final job = jobForEpisode(episodeId);
    if (job == null || job.status == JobStatus.downloading) return null;
    final path = job.sourcePath.trim();
    if (path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  Future<void> setTranscriptAcquisitionMode(
    String id,
    TranscriptAcquisitionMode mode,
  ) async {
    final job = _jobs[id];
    if (job == null) return;
    if (!job.status.canTranscribe &&
        job.status != JobStatus.failed &&
        job.status != JobStatus.cancelled) {
      return;
    }
    await _transition(job, transcriptAcquisitionMode: mode);
  }

  Future<TranscriptionJob?> enqueuePodcastEpisode(
    PodcastEpisode episode, {
    PodcastFeed? feed,
  }) async {
    final gateway = _podcastGateway;
    if (gateway == null) {
      throw const PodcastException('podcast_unavailable');
    }
    final existing = jobForEpisode(episode.id);
    if (existing != null) return existing;
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final jobId = _uuid.v4();
    final location = _downloadLocator.resolve(
      jobId: jobId,
      episode: episode,
      managedRoot: _podcastManagedRoot ?? Directory.systemTemp.path,
    );
    final provenance = PodcastEpisodeProvenance(
      feedUrl: episode.feedUrl,
      episodeId: episode.id,
      enclosureUrl: episode.enclosureUrl,
      showTitle: feed?.title ?? episode.title,
      episodeTitle: episode.title,
      guid: episode.guid,
      author: feed?.author,
      artworkUrl: episode.artworkUrl ?? feed?.artworkUrl,
      showUrl: feed?.showUrl,
      publishedAt: episode.publishedAt,
      language: _languageCode(feed?.language),
      description: episode.description,
      episodeUrl: episode.episodeUrl,
      transcripts: episode.transcripts,
      transcriptTiming: episode.transcriptTiming,
    );
    final hints = [
      ..._sessionOptions.languageHints,
      if (_languageCode(feed?.language) case final language?) language,
    ];
    final job = TranscriptionJob(
      id: jobId,
      batchId: _batchId,
      sourcePath: location.filePath,
      createdAt: now,
      updatedAt: now,
      status: JobStatus.downloading,
      queueIndex: _inboxIds.length,
      options: _sessionOptions.copyWith(languageHints: hints.toSet().toList()),
      translationOptions: TranslationOptions.fromSettings(
        _settings.translationSettings,
      ),
      sourceOrigin: JobSourceOrigin.podcast,
      displayTitle: provenance.displayName,
      podcastProvenance: provenance,
      transcriptAcquisitionMode: episode.transcripts.isNotEmpty
          ? TranscriptAcquisitionMode.publisherCaptions
          : TranscriptAcquisitionMode.soniox,
    );
    _jobs[job.id] = job;
    _inboxIds.add(job.id);
    await _jobsRepository.save(job);
    notifyListeners();
    unawaited(_downloadPodcastJob(job, location));
    return job;
  }

  String? _languageCode(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('en')) return 'en';
    return value.split(RegExp(r'[-_]')).first;
  }

  Future<void> _downloadPodcastJob(
    TranscriptionJob job,
    PodcastDownloadLocation location,
  ) async {
    final gateway = _podcastGateway;
    if (gateway == null) return;
    while (_activePodcastDownloads >= 2) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (_downloadCancelledIds.contains(job.id) ||
          !_jobs.containsKey(job.id)) {
        return;
      }
    }
    _activePodcastDownloads++;
    try {
      if (await File(location.filePath).exists()) {
        await _finishPodcastDownload(job, location.filePath);
        return;
      }
      await gateway.downloadEpisode(
        enclosureUrl: job.podcastProvenance?.enclosureUrl ?? '',
        destinationPath: location.filePath,
        onProgress: (fraction, detail) =>
            unawaited(_progress(job.id, 'downloading', fraction, detail)),
        shouldCancel: () => _downloadCancelledIds.contains(job.id),
      );
      if (_downloadCancelledIds.contains(job.id)) {
        throw const OperationCancelledException();
      }
      await _finishPodcastDownload(job, location.filePath);
    } on OperationCancelledException {
      final current = _jobs[job.id];
      if (current != null) {
        await _transition(
          current,
          status: JobStatus.cancelled,
          progress: const JobProgress(stage: 'cancelled'),
          errorCode: 'cancelled',
          errorMessage: 'Cancelled by the user.',
        );
      }
    } on PodcastException catch (error) {
      final current = _jobs[job.id];
      if (current != null) {
        await _fail(current, error.code, error.message ?? error.code);
      }
    } on Object catch (error) {
      final current = _jobs[job.id];
      if (current != null) {
        await _fail(current, 'podcast_download_failed', _safeError(error));
      }
    } finally {
      _activePodcastDownloads--;
      _downloadCancelledIds.remove(job.id);
    }
  }

  Future<void> _finishPodcastDownload(TranscriptionJob job, String path) async {
    final metadata = await _media.inspect(path);
    final fingerprint = await fingerprintMonitoredFile(path);
    final classified = await _classifyPublisherTranscript(_jobs[job.id] ?? job);
    var updated = await _transition(
      _jobs[job.id] ?? job,
      sourcePath: path,
      status: JobStatus.ready,
      metadata: metadata,
      sourceFingerprint: fingerprint,
      podcastProvenance: classified.$1,
      transcriptAcquisitionMode: classified.$2,
      progress: const JobProgress(stage: 'ready', fraction: 1),
      clearError: true,
    );
    if (fingerprint != null && _pathIsInMonitoredFolder(path)) {
      await _recordMonitoredFile(
        updated,
        MonitoredFileDisposition.queued,
        fingerprint: fingerprint,
      );
    }
  }

  Future<(PodcastEpisodeProvenance?, TranscriptAcquisitionMode)>
  _classifyPublisherTranscript(TranscriptionJob job) async {
    final provenance = job.podcastProvenance;
    final gateway = _podcastGateway;
    if (provenance == null || provenance.transcripts.isEmpty) {
      return (provenance, TranscriptAcquisitionMode.soniox);
    }
    if (gateway == null) {
      return (provenance, TranscriptAcquisitionMode.publisherCaptions);
    }
    for (final reference in provenance.transcripts) {
      try {
        final body = await gateway.fetchTranscript(reference);
        final parsed = _publisherTranscriptParser.parse(
          body: body,
          mimeType: reference.type,
          url: reference.url,
        );
        final updated = provenance.copyWith(transcriptTiming: parsed.timing);
        return (updated, TranscriptAcquisitionMode.publisherCaptions);
      } on Object {
        continue;
      }
    }
    return (provenance, TranscriptAcquisitionMode.publisherCaptions);
  }

  bool get canStartReady =>
      !_processing &&
      inboxJobs.any((job) => job.status.canTranscribe && _canStart(job));

  bool _canStart(TranscriptionJob job) {
    if (job.transcriptAcquisitionMode.usesPublisherTranscript) return true;
    return _keyConfigured;
  }

  Future<void> enqueueSources(Iterable<String> paths) async {
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final existing = <String>{
      for (final job in inboxJobs) _sourceResolver.identityFor(job.sourcePath),
    };
    final sources = await _sourceResolver.resolve(paths);
    for (final source in sources) {
      if (!existing.add(source.identity)) continue;
      await _enqueueResolvedSource(
        source,
        sourceOrigin: JobSourceOrigin.manual,
        fingerprint: await fingerprintMonitoredFile(source.path),
      );
    }
  }

  Future<TranscriptionJob?> _enqueueResolvedSource(
    ResolvedMediaSource source, {
    required JobSourceOrigin sourceOrigin,
    SourceFingerprint? fingerprint,
  }) async {
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final job = TranscriptionJob(
      id: _uuid.v4(),
      batchId: _batchId,
      sourcePath: source.path,
      createdAt: now,
      updatedAt: now,
      status: JobStatus.pending,
      queueIndex: _inboxIds.length,
      options: _sessionOptions,
      translationOptions: TranslationOptions.fromSettings(
        _settings.translationSettings,
      ),
      sourceOrigin: _isManagedPodcastPath(source.path)
          ? JobSourceOrigin.podcast
          : sourceOrigin,
      sourceFingerprint: fingerprint,
    );
    _jobs[job.id] = job;
    _inboxIds.add(job.id);
    await _jobsRepository.save(job);
    notifyListeners();
    unawaited(_prepare(job.id));
    return job;
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
      if (!_jobs.containsKey(id)) return;
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
      if (!_jobs.containsKey(id)) return;
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
      if (!_jobs.containsKey(id)) return;
      await _fail(job, 'media_error', _safeError(error));
    }
  }

  Future<void> startReady() async {
    if (_processing) return;
    final queue = inboxJobs
        .where((job) => job.status.canTranscribe && _canStart(job))
        .map((job) => job.id)
        .toList();
    if (queue.isEmpty) return;
    _processing = true;
    notifyListeners();
    await _runWorkerPool(queue);
    _processing = false;
    notifyListeners();
  }

  Future<void> _runWorkerPool(List<String> jobIds) async {
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < jobIds.length) {
        final id = jobIds[cursor++];
        await _runJob(id);
      }
    }

    await Future.wait(
      List.generate(min(_maxConcurrentJobs, jobIds.length), (_) => worker()),
    );
  }

  Future<void> _runJob(String id) async {
    final initialJob = _jobs[id];
    if (initialJob == null) return;
    TranscriptionJob job = initialJob;
    String? temporary;
    try {
      if (job.transcriptAcquisitionMode.usesPublisherTranscript) {
        await _importPublisherTranscript(job);
        return;
      }
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
        transcriptSource: TranscriptSource.soniox,
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

  Future<void> _importPublisherTranscript(TranscriptionJob job) async {
    final gateway = _podcastGateway;
    final provenance = job.podcastProvenance;
    if (gateway == null ||
        provenance == null ||
        provenance.transcripts.isEmpty) {
      await _fail(
        job,
        'podcast_transcript_missing',
        'The publisher transcript is no longer available.',
      );
      return;
    }
    try {
      PublisherTranscript? parsed;
      for (final reference in provenance.transcripts) {
        try {
          final body = await gateway.fetchTranscript(reference);
          parsed = _publisherTranscriptParser.parse(
            body: body,
            mimeType: reference.type,
            url: reference.url,
          );
          break;
        } on Object {
          continue;
        }
      }
      if (parsed == null) {
        await _fail(
          _jobs[job.id] ?? job,
          'podcast_transcript_failed',
          'The publisher captions could not be imported.',
        );
        return;
      }
      await _transition(
        _jobs[job.id] ?? job,
        status: parsed.document.segments.isEmpty
            ? JobStatus.empty
            : JobStatus.completed,
        document: TranscriptDocument(
          tokens: const [],
          segments: parsed.document.segments,
          speakers: parsed.document.speakers,
          updatedAt: parsed.document.updatedAt,
        ),
        transcriptSource: TranscriptSource.publisher,
        progress: const JobProgress(stage: 'complete', fraction: 1),
        clearError: true,
      );
    } on PodcastException catch (error) {
      await _fail(
        _jobs[job.id] ?? job,
        error.code,
        error.message ?? error.code,
      );
    } on Object catch (error) {
      await _fail(
        _jobs[job.id] ?? job,
        'podcast_transcript_failed',
        _safeError(error),
      );
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
    if (_jobs[id]?.status == JobStatus.downloading) {
      _downloadCancelledIds.add(id);
      return;
    }
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
    for (final job in inboxJobs.where((item) => item.status.isActive)) {
      _cancelledIds.add(job.id);
    }
    for (final job in inboxJobs.where(
      (item) => item.translationState.status.isActive,
    )) {
      _translationCancelledIds.add(job.id);
    }
  }

  Future<void> cancelRemoteJobsForQuit() async {
    final active = inboxJobs.where((job) => job.isBusy).toList();
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
    if (job.sourceOrigin == JobSourceOrigin.podcast &&
        (job.errorCode == 'download_interrupted' ||
            job.errorCode == 'podcast_download_failed' ||
            !await File(job.sourcePath).exists())) {
      final location = _downloadLocator.resolve(
        jobId: job.id,
        episode: PodcastEpisode(
          id: job.podcastProvenance?.episodeId ?? job.id,
          feedUrl: job.podcastProvenance?.feedUrl ?? '',
          title: job.podcastProvenance?.episodeTitle ?? job.displayName,
          enclosureUrl: job.podcastProvenance?.enclosureUrl ?? '',
          mediaExtension:
              extensionForEnclosure(
                url: job.podcastProvenance?.enclosureUrl ?? job.sourcePath,
              ) ??
              'mp3',
        ),
        managedRoot: _podcastManagedRoot ?? Directory.systemTemp.path,
      );
      if (job.errorCode == 'podcast_download_failed') {
        final invalid = File(location.filePath);
        if (await invalid.exists()) await invalid.delete();
      }
      await _transition(
        job,
        sourcePath: location.filePath,
        status: JobStatus.downloading,
        progress: const JobProgress(stage: 'downloading', fraction: 0),
        clearError: true,
      );
      if (!_inboxIds.contains(id)) _inboxIds.add(id);
      unawaited(_downloadPodcastJob(_jobs[id] ?? job, location));
      return;
    }
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
    if (!_inboxIds.contains(id)) _inboxIds.add(id);
    notifyListeners();
    if (_canStart(updated) && !_processing) {
      _processing = true;
      notifyListeners();
      await _runJob(updated.id);
      _processing = false;
      notifyListeners();
    }
  }

  void addToInbox(String id) {
    final job = _jobs[id];
    if (job == null || job.status != JobStatus.ready) return;
    if (!_inboxIds.contains(id)) _inboxIds.add(id);
    _destination = AppDestination.inbox;
    notifyListeners();
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

  Future<void> removeFromInbox(String id) async {
    final job = _jobs[id];
    if (job == null || job.isBusy) return;
    _inboxIds.remove(id);
    if (job.document == null) {
      if (_pathIsInMonitoredFolder(job.sourcePath)) {
        await _recordMonitoredFile(job, MonitoredFileDisposition.dismissed);
      }
      await _deleteManagedPodcastAudio(job);
      _jobs.remove(id);
      _playbackPositions.remove(id);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
    }
    notifyListeners();
  }

  Future<void> startNewInboxBatch() async {
    if (!canStartNewInboxBatch) return;
    final discardedIds = [
      for (final id in _inboxIds)
        if (_jobs[id]?.document == null) id,
    ];
    for (final id in discardedIds) {
      final discarded = _jobs[id];
      if (discarded != null && _pathIsInMonitoredFolder(discarded.sourcePath)) {
        await _recordMonitoredFile(
          discarded,
          MonitoredFileDisposition.dismissed,
        );
      }
      if (discarded != null) await _deleteManagedPodcastAudio(discarded);
      _jobs.remove(id);
      _playbackPositions.remove(id);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
    }
    _inboxIds.clear();
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
    _inboxIds.remove(id);
    if (_activeWorkspaceJobId == id) _activeWorkspaceJobId = null;
    await _deleteManagedPodcastAudio(job);
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
      final job = _jobs[id];
      if (job != null) await _deleteManagedPodcastAudio(job);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
      _jobs.remove(id);
      _playbackPositions.remove(id);
      _inboxIds.remove(id);
    }
    await _media.clearGeneratedMediaExcept(_jobs.keys.toSet());
    if (_activeWorkspaceJobId != null &&
        !_jobs.containsKey(_activeWorkspaceJobId)) {
      _activeWorkspaceJobId = null;
    }
    notifyListeners();
  }

  void openInWorkspace(String id) {
    final job = _jobs[id];
    if (job?.document == null) return;
    _activeWorkspaceJobId = id;
    _destination = AppDestination.workspace;
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
    for (final job in inboxJobs.where(
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
        preserveUpdatedAt: true,
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
      document: document.copyWith(segments: segments, preserveUpdatedAt: true),
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
            document: latest.copyWith(
              segments: segments,
              preserveUpdatedAt: true,
            ),
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
    for (final job in inboxJobs.where(
      (job) => job.document == null && job.remoteTranscriptionId == null,
    )) {
      await _transition(job, translationOptions: options);
    }
  }

  Future<void> _updateQueuedSonioxTranslationOptions() async {
    for (final job in inboxJobs.where(
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

  Future<void> generateAiBrief(
    String jobId, {
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    bool mergeSections = false,
  }) async {
    final service = _aiBriefService;
    var current = _jobs[jobId];
    final document = current?.document;
    if (current == null || document == null) return;
    if (service == null) {
      await _setAiBriefFailure(current, 'ai_brief_unavailable');
      return;
    }
    if (current.aiGenerationState.status.isActive) return;
    final provider = _settings.llmProviderSettings;
    final validation = provider.validationError();
    if (validation != null || !aiBriefConfigured) {
      await _setAiBriefFailure(
        current,
        validation ?? 'ai_brief_missing_credentials',
      );
      return;
    }
    final estimated = service.estimateRequestCount(document, sections);
    _aiBriefCancelledIds.remove(jobId);
    current = await _transition(
      current,
      aiGenerationState: AiGenerationState(
        status: AiGenerationStatus.generating,
        stage: 'analyzing',
        totalChunks: estimated,
        outputLanguage: outputLanguage,
        learningLanguage: learningLanguage,
        learningLevel: learningLevel,
        model: provider.model,
        selectedSections: Set<AiBriefSection>.of(sections),
        mergeSections: mergeSections,
      ),
    );
    try {
      final generated = await service.generate(
        settings: provider,
        document: document,
        sections: sections,
        outputLanguage: outputLanguage,
        learningLanguage: learningLanguage,
        learningLevel: learningLevel,
        shouldCancel: () => _aiBriefCancelledIds.contains(jobId),
        onProgress: (stage, completed, total) async {
          final latest = (_jobs[jobId] ?? current)!;
          current = await _transition(
            latest,
            aiGenerationState: latest.aiGenerationState.copyWith(
              status: AiGenerationStatus.generating,
              stage: stage,
              completedChunks: completed,
              totalChunks: total,
              clearError: true,
            ),
          );
        },
      );
      final latest = (_jobs[jobId] ?? current)!;
      current = latest;
      final brief = mergeSections && latest.aiBrief != null
          ? _mergeAiBrief(latest.aiBrief!, generated, sections)
          : generated;
      await _transition(
        latest,
        aiBrief: brief,
        aiGenerationState: latest.aiGenerationState.copyWith(
          status: AiGenerationStatus.completed,
          stage: 'complete',
          completedChunks: estimated,
          totalChunks: estimated,
          clearError: true,
        ),
      );
    } on OperationCancelledException {
      final latest = (_jobs[jobId] ?? current)!;
      await _transition(
        latest,
        aiGenerationState: latest.aiGenerationState.copyWith(
          status: AiGenerationStatus.cancelled,
          errorCode: 'ai_brief_cancelled',
          errorMessage: 'AI Brief generation was cancelled.',
        ),
      );
    } on AiBriefException catch (error) {
      await _setAiBriefFailure(
        _jobs[jobId] ?? current!,
        error.code,
        error.message,
      );
    } on Object catch (error) {
      await _setAiBriefFailure(
        _jobs[jobId] ?? current!,
        'ai_brief_request_failed',
        _safeError(error),
      );
    } finally {
      _aiBriefCancelledIds.remove(jobId);
    }
  }

  Future<void> retryAiBrief(String jobId) async {
    final job = _jobs[jobId];
    if (job == null || !job.aiGenerationState.status.canRetry) return;
    final sections = job.aiGenerationState.selectedSections.isNotEmpty
        ? job.aiGenerationState.selectedSections
        : job.aiBrief?.selectedSections ?? defaultAiBriefSections;
    final language = job.aiGenerationState.outputLanguage.isNotEmpty
        ? job.aiGenerationState.outputLanguage
        : job.aiBrief?.outputLanguage ?? defaultAiBriefLanguage;
    await generateAiBrief(
      jobId,
      sections: sections,
      outputLanguage: language,
      learningLanguage: job.aiGenerationState.learningLanguage,
      learningLevel: job.aiGenerationState.learningLevel,
      mergeSections: job.aiGenerationState.mergeSections,
    );
  }

  Future<void> regenerateAiBriefSections(
    String jobId,
    Set<AiBriefSection> sections,
  ) async {
    final job = _jobs[jobId];
    if (job?.aiBrief == null) return;
    await generateAiBrief(
      jobId,
      sections: sections,
      outputLanguage: job!.aiBrief!.outputLanguage,
      learningLanguage: job.aiBrief!.learningLanguage,
      learningLevel: job.aiBrief!.learningLevel,
      mergeSections: true,
    );
  }

  void cancelAiBrief(String jobId) {
    if (_jobs[jobId]?.aiGenerationState.status.isActive ?? false) {
      _aiBriefCancelledIds.add(jobId);
    }
  }

  Future<void> updateAiBriefOverview(String jobId, String value) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      aiBrief: brief.copyWith(overview: value.trim(), edited: true),
    );
  }

  Future<void> updateAiChapter(
    String jobId,
    String chapterId, {
    required String title,
    required String summary,
  }) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    final chapters = [
      for (final chapter in brief.chapters)
        if (chapter.id == chapterId)
          chapter.copyWith(
            title: title.trim(),
            summary: summary.trim(),
            edited: true,
          )
        else
          chapter,
    ];
    await _transition(
      job,
      aiBrief: brief.copyWith(chapters: chapters, edited: true),
    );
  }

  Future<void> deleteAiChapter(String jobId, String chapterId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      aiBrief: brief.copyWith(
        chapters: brief.chapters.where((item) => item.id != chapterId).toList(),
        edited: true,
      ),
    );
  }

  Future<void> updateAiInsight(
    String jobId,
    String insightId, {
    required String text,
    String? owner,
    String? deadline,
  }) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    final insights = [
      for (final insight in brief.insights)
        if (insight.id == insightId)
          insight.copyWith(
            text: text.trim(),
            owner: owner?.trim(),
            deadline: deadline?.trim(),
            clearOwner: owner?.trim().isEmpty ?? true,
            clearDeadline: deadline?.trim().isEmpty ?? true,
            edited: true,
          )
        else
          insight,
    ];
    await _transition(
      job,
      aiBrief: brief.copyWith(insights: insights, edited: true),
    );
  }

  Future<void> addAiInsight(
    String jobId, {
    required AiInsightType type,
    required String text,
  }) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    final value = text.trim();
    if (job == null || brief == null || value.isEmpty) return;
    final insight = AiInsight(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      text: value,
      evidenceSegmentIds: const [],
      edited: true,
    );
    await _transition(
      job,
      aiBrief: brief.copyWith(
        insights: [...brief.insights, insight],
        edited: true,
      ),
    );
  }

  Future<void> deleteAiInsight(String jobId, String insightId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      aiBrief: brief.copyWith(
        insights: brief.insights.where((item) => item.id != insightId).toList(),
        edited: true,
      ),
    );
  }

  Future<void> updateAiLanguageNote(
    String jobId,
    String noteId, {
    required String term,
    required String explanation,
    required String sourceExcerpt,
  }) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    final trimmedTerm = term.trim();
    final trimmedExplanation = explanation.trim();
    final trimmedSourceExcerpt = sourceExcerpt.trim();
    if (job == null ||
        brief == null ||
        trimmedTerm.isEmpty ||
        trimmedExplanation.isEmpty ||
        trimmedSourceExcerpt.isEmpty) {
      return;
    }
    final notes = [
      for (final note in brief.languageNotes)
        if (note.id == noteId)
          note.copyWith(
            term: trimmedTerm,
            explanation: trimmedExplanation,
            sourceExcerpt: trimmedSourceExcerpt,
            edited: true,
          )
        else
          note,
    ];
    await _transition(
      job,
      aiBrief: brief.copyWith(languageNotes: notes, edited: true),
    );
  }

  Future<void> deleteAiLanguageNote(String jobId, String noteId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      aiBrief: brief.copyWith(
        languageNotes: brief.languageNotes
            .where((item) => item.id != noteId)
            .toList(),
        edited: true,
      ),
    );
  }

  String renderAiBriefMarkdown(String jobId) {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    final document = job?.document;
    if (job == null || brief == null || document == null) return '';
    final buffer = StringBuffer()
      ..writeln('# ${job.displayName} — AI Brief')
      ..writeln();
    if (brief.overview.trim().isNotEmpty) {
      buffer
        ..writeln('## Overview')
        ..writeln()
        ..writeln(brief.overview.trim())
        ..writeln(_markdownEvidence(document, brief.overviewEvidenceSegmentIds))
        ..writeln();
    }
    if (brief.chapters.isNotEmpty) {
      buffer
        ..writeln('## Chapters')
        ..writeln();
      for (final chapter in brief.chapters) {
        buffer
          ..writeln('### ${chapter.title}')
          ..writeln()
          ..writeln(chapter.summary)
          ..writeln(_markdownEvidence(document, chapter.evidenceSegmentIds))
          ..writeln();
      }
    }
    for (final type in AiInsightType.values) {
      final items = brief.insights.where((item) => item.type == type).toList();
      if (items.isEmpty) continue;
      buffer
        ..writeln('## ${_aiInsightHeading(type)}')
        ..writeln();
      for (final item in items) {
        final details = [
          if (item.owner?.isNotEmpty ?? false) 'Owner: ${item.owner}',
          if (item.deadline?.isNotEmpty ?? false) 'Due: ${item.deadline}',
        ].join(' · ');
        buffer
          ..writeln('- ${item.text}${details.isEmpty ? '' : ' — $details'}')
          ..writeln(
            '  ${_markdownEvidence(document, item.evidenceSegmentIds)}',
          );
      }
      buffer.writeln();
    }
    if (brief.languageNotes.isNotEmpty) {
      buffer
        ..writeln('## Language Notes')
        ..writeln();
      for (final kind in AiLanguageNoteKind.values) {
        final notes = brief.languageNotes
            .where((item) => item.kind == kind)
            .toList();
        if (notes.isEmpty) continue;
        buffer
          ..writeln('### ${_aiLanguageNoteHeading(kind)}')
          ..writeln();
        for (final note in notes) {
          buffer
            ..writeln('**${note.term}**')
            ..writeln()
            ..writeln(note.explanation)
            ..writeln()
            ..writeln(
              note.sourceExcerpt
                  .split('\n')
                  .map((line) => '> $line')
                  .join('\n'),
            )
            ..writeln(_markdownEvidence(document, note.evidenceSegmentIds))
            ..writeln();
        }
      }
    }
    return buffer.toString().trimRight();
  }

  Future<String> exportAiBrief(String jobId, String directory) async {
    final job = _jobs[jobId];
    if (job?.aiBrief == null) throw StateError('Job has no AI Brief.');
    final base = (job!.displayTitle ?? p.basenameWithoutExtension(job.fileName))
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    var output = File(
      p.join(directory, '${base.isEmpty ? 'brief' : base}-brief.md'),
    );
    var suffix = 2;
    while (await output.exists()) {
      output = File(
        p.join(directory, '${base.isEmpty ? 'brief' : base}-brief-$suffix.md'),
      );
      suffix++;
    }
    await output.writeAsString(renderAiBriefMarkdown(jobId), flush: true);
    return output.path;
  }

  AiBrief _mergeAiBrief(
    AiBrief current,
    AiBrief generated,
    Set<AiBriefSection> sections,
  ) {
    bool replaces(AiInsightType type) => switch (type) {
      AiInsightType.keyIdea ||
      AiInsightType.notableMoment => sections.contains(AiBriefSection.keyIdeas),
      AiInsightType.decision => sections.contains(AiBriefSection.decisions),
      AiInsightType.actionItem => sections.contains(AiBriefSection.actionItems),
      AiInsightType.openQuestion => sections.contains(
        AiBriefSection.openQuestions,
      ),
    };
    final retainedInsights = current.insights
        .where((item) => !replaces(item.type))
        .toList();
    return AiBrief(
      overview: sections.contains(AiBriefSection.overview)
          ? generated.overview
          : current.overview,
      overviewEvidenceSegmentIds: sections.contains(AiBriefSection.overview)
          ? generated.overviewEvidenceSegmentIds
          : current.overviewEvidenceSegmentIds,
      chapters: sections.contains(AiBriefSection.chapters)
          ? generated.chapters
          : current.chapters,
      insights: [...retainedInsights, ...generated.insights],
      languageNotes: sections.contains(AiBriefSection.languageNotes)
          ? generated.languageNotes
          : current.languageNotes,
      learningLanguage: sections.contains(AiBriefSection.languageNotes)
          ? generated.learningLanguage
          : current.learningLanguage,
      learningLevel: sections.contains(AiBriefSection.languageNotes)
          ? generated.learningLevel
          : current.learningLevel,
      outputLanguage: generated.outputLanguage,
      model: generated.model,
      selectedSections: {...current.selectedSections, ...sections},
      generatedAt: generated.generatedAt,
      sourceTranscriptUpdatedAt: generated.sourceTranscriptUpdatedAt,
      edited:
          retainedInsights.any((item) => item.edited) ||
          (!sections.contains(AiBriefSection.overview) && current.edited) ||
          (!sections.contains(AiBriefSection.chapters) &&
              current.chapters.any((item) => item.edited)),
    );
  }

  Future<void> _setAiBriefFailure(
    TranscriptionJob job,
    String code, [
    String? message,
  ]) => _transition(
    job,
    aiGenerationState: job.aiGenerationState.copyWith(
      status: AiGenerationStatus.failed,
      errorCode: code,
      errorMessage: message,
    ),
  );

  String _markdownEvidence(
    TranscriptDocument document,
    List<String> segmentIds,
  ) {
    final byId = {for (final segment in document.segments) segment.id: segment};
    final times = segmentIds
        .map((id) => byId[id])
        .whereType<TranscriptSegment>()
        .map((segment) => formatClock(segment.startMs))
        .toSet()
        .toList();
    return times.isEmpty
        ? ''
        : 'Evidence: ${times.map((time) => '[$time]').join(' ')}';
  }

  String _aiInsightHeading(AiInsightType type) => switch (type) {
    AiInsightType.keyIdea => 'Key ideas',
    AiInsightType.notableMoment => 'Notable moments',
    AiInsightType.decision => 'Decisions',
    AiInsightType.actionItem => 'Action items',
    AiInsightType.openQuestion => 'Open questions',
  };

  String _aiLanguageNoteHeading(AiLanguageNoteKind kind) => switch (kind) {
    AiLanguageNoteKind.vocabulary => 'Vocabulary',
    AiLanguageNoteKind.expression => 'Useful expressions',
    AiLanguageNoteKind.grammar => 'Grammar & usage',
  };

  Future<String> exportJob(
    String id,
    String directory,
    ExportOptions options,
  ) async {
    final job = _jobs[id];
    if (job == null) throw StateError('Job not found.');
    return _exporter.exportToDirectory(job, directory, options);
  }

  Future<String> exportPodcastMedia(String id, String destinationPath) async {
    final job = _jobs[id];
    if (job == null || job.sourceOrigin != JobSourceOrigin.podcast) {
      throw StateError('Podcast job not found.');
    }
    final source = File(job.sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('Podcast media is missing.');
    }
    final destination = File(destinationPath);
    if (p.equals(p.absolute(source.path), p.absolute(destination.path))) {
      return destination.path;
    }
    await destination.parent.create(recursive: true);
    await source.copy(destination.path);
    return destination.path;
  }

  String renderJob(String id, ExportOptions options) {
    final job = _jobs[id];
    if (job?.document == null) return '';
    return _exporter.render(
      job!.document!,
      options,
      title: job.displayName,
      metadata: job.metadata,
    );
  }

  Future<List<String>> exportJobs(
    Iterable<String> ids,
    String directory,
    ExportOptions options,
  ) async {
    final results = <String>[];
    for (final id in ids) {
      final job = _jobs[id];
      if (job == null || job.document == null) continue;
      results.add(await _exporter.exportToDirectory(job, directory, options));
    }
    return results;
  }

  Future<String> exportJobsZip(
    Iterable<String> ids,
    String destination,
    ExportOptions options,
  ) {
    final jobs = ids
        .map((id) => _jobs[id])
        .whereType<TranscriptionJob>()
        .where((job) => job.document != null)
        .toList(growable: false);
    return _exporter.exportZip(jobs, destination, options);
  }

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
    await _runWorkerPool(resumable);
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

  Future<void> _deleteManagedPodcastAudio(TranscriptionJob job) async {
    if (job.sourceOrigin != JobSourceOrigin.podcast) return;
    if (_pathIsInMonitoredFolder(job.sourcePath)) return;
    final root = _podcastManagedRoot;
    if (root == null || root.isEmpty) return;
    final file = File(job.sourcePath);
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedFile = p.normalize(p.absolute(job.sourcePath));
    if (normalizedFile != normalizedRoot &&
        !p.isWithin(normalizedRoot, normalizedFile)) {
      return;
    }
    try {
      if (await file.exists()) await file.delete();
      final part = File('${job.sourcePath}.part');
      if (await part.exists()) await part.delete();
      final parent = file.parent;
      if (await parent.exists() &&
          await parent.list().isEmpty &&
          p.basename(parent.path) == job.id) {
        await parent.delete();
      }
    } on Object {
      // Cleanup is best-effort; the job record is already going away.
    }
  }

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
    AiBrief? aiBrief,
    AiGenerationState? aiGenerationState,
    TranscriptDocument? document,
    String? errorCode,
    String? errorMessage,
    String? remoteFileId,
    String? remoteTranscriptionId,
    CleanupState? cleanupState,
    String? displayTitle,
    String? groupId,
    Set<String>? tagIds,
    SourceFingerprint? sourceFingerprint,
    PodcastEpisodeProvenance? podcastProvenance,
    TranscriptAcquisitionMode? transcriptAcquisitionMode,
    TranscriptSource? transcriptSource,
    bool clearError = false,
    bool clearRemoteFileId = false,
    bool clearRemoteTranscriptionId = false,
    bool clearDisplayTitle = false,
    bool clearGroupId = false,
  }) async {
    final current = _jobs[job.id] ?? job;
    final updated = current.copyWith(
      sourcePath: sourcePath,
      status: status,
      queueIndex: queueIndex,
      progress: progress,
      metadata: metadata,
      options: options,
      translationOptions: translationOptions,
      translationState: translationState,
      aiBrief: aiBrief,
      aiGenerationState: aiGenerationState,
      document: document,
      errorCode: errorCode,
      errorMessage: errorMessage,
      remoteFileId: remoteFileId,
      remoteTranscriptionId: remoteTranscriptionId,
      cleanupState: cleanupState,
      displayTitle: displayTitle,
      groupId: groupId,
      tagIds: tagIds,
      sourceFingerprint: sourceFingerprint,
      podcastProvenance: podcastProvenance,
      transcriptAcquisitionMode: transcriptAcquisitionMode,
      transcriptSource: transcriptSource,
      clearError: clearError,
      clearRemoteFileId: clearRemoteFileId,
      clearRemoteTranscriptionId: clearRemoteTranscriptionId,
      clearDisplayTitle: clearDisplayTitle,
      clearGroupId: clearGroupId,
    );
    _jobs[job.id] = updated;
    await _jobsRepository.save(updated);
    if ((updated.status == JobStatus.completed ||
            updated.status == JobStatus.empty) &&
        _pathIsInMonitoredFolder(updated.sourcePath)) {
      final fingerprint =
          updated.sourceFingerprint ??
          await fingerprintMonitoredFile(updated.sourcePath);
      if (fingerprint != null) {
        await _recordMonitoredFile(
          updated,
          MonitoredFileDisposition.completed,
          fingerprint: fingerprint,
        );
      }
    }
    notifyListeners();
    return updated;
  }

  Future<void> shutdown() async {
    if (_monitorShutDown) return;
    _monitorShutDown = true;
    await _inboxFolderMonitor?.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
