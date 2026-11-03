import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/contracts.dart';
import '../core/local_speech.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';
import '../core/speech_boundaries.dart';
import '../core/transcript_parser.dart';
import '../core/transcript_structure_editor.dart';
import '../data/llm_translation_service.dart';
import '../data/moss_api_client.dart';
import '../data/inbox_folder_monitor.dart';
import '../data/managed_media_store.dart';
import '../data/podcast/download_location.dart';
import '../data/podcast/podcast_urls.dart';
import '../data/podcast/publisher_transcript.dart';
import '../data/process_media_service.dart';
import '../data/soniox_api_client.dart';
import '../data/transcript_exporter.dart';
import '../data/timed_subtitle_import.dart';
import 'local_models_controller.dart';

enum AppDestination { inbox, podcast, workspace, library, settings }

class AppController extends ChangeNotifier {
  static const _playbackHistorySaveInterval = Duration(seconds: 2);
  static const _progressPublishInterval = Duration(milliseconds: 250);

  AppController({
    required CredentialStore credentialStore,
    required SettingsRepository settingsRepository,
    required JobRepository jobRepository,
    LibraryCatalogRepository? libraryCatalogRepository,
    required MediaService mediaService,
    required MediaSourceResolver sourceResolver,
    required SonioxClient sonioxClient,
    CredentialStore? mossCredentialStore,
    TranscriptionClient? mossClient,
    required TranscriptExporter exporter,
    TranslationCredentialStore? translationCredentialStore,
    TranslationService? translationService,
    LocalModelManager? localModelManager,
    LocalSttService? localSttService,
    ForcedAlignmentService? forcedAlignmentService,
    AiBriefService? aiBriefService,
    InboxMonitorRepository? inboxMonitorRepository,
    InboxFolderMonitor? inboxFolderMonitor,
    PodcastGateway? podcastGateway,
    String? podcastManagedRoot,
    ManagedMediaStore? managedMediaStore,
    TranscriptParser parser = const TranscriptParser(),
    PublisherTranscriptParser publisherTranscriptParser =
        const PublisherTranscriptParser(),
    TimedSubtitleImportService timedSubtitleImportService =
        const TimedSubtitleImportService(),
    PodcastDownloadLocator downloadLocator = const PodcastDownloadLocator(),
    TranscriptStructureEditor? transcriptStructureEditor,
    Uuid uuid = const Uuid(),
  }) : _credentials = credentialStore,
       _settingsRepository = settingsRepository,
       _jobsRepository = jobRepository,
       _libraryCatalogRepository = libraryCatalogRepository,
       _media = mediaService,
       _soniox = sonioxClient,
       _mossCredentials = mossCredentialStore,
       _moss = mossClient,
       _exporter = exporter,
       _sourceResolver = sourceResolver,
       _translationCredentials = translationCredentialStore,
       _translationService = translationService,
       _localModelManager = localModelManager,
       _localSttService = localSttService,
       _forcedAlignmentService = forcedAlignmentService,
       _aiBriefService = aiBriefService,
       _inboxMonitorRepository = inboxMonitorRepository,
       _inboxFolderMonitor = inboxFolderMonitor,
       _podcastGateway = podcastGateway,
       _podcastManagedRoot = podcastManagedRoot,
       _managedMedia = managedMediaStore,
       _parser = parser,
       _publisherTranscriptParser = publisherTranscriptParser,
       _timedSubtitleImportService = timedSubtitleImportService,
       _downloadLocator = downloadLocator,
       _transcriptStructureEditor =
           transcriptStructureEditor ?? TranscriptStructureEditor(),
       _uuid = uuid;

  final CredentialStore _credentials;
  final SettingsRepository _settingsRepository;
  final JobRepository _jobsRepository;
  final LibraryCatalogRepository? _libraryCatalogRepository;
  final MediaService _media;
  final SonioxClient _soniox;
  final CredentialStore? _mossCredentials;
  final TranscriptionClient? _moss;
  final TranscriptExporter _exporter;
  final MediaSourceResolver _sourceResolver;
  final TranslationCredentialStore? _translationCredentials;
  final TranslationService? _translationService;
  final LocalModelManager? _localModelManager;
  final LocalSttService? _localSttService;
  final ForcedAlignmentService? _forcedAlignmentService;
  final AiBriefService? _aiBriefService;
  final InboxMonitorRepository? _inboxMonitorRepository;
  final InboxFolderMonitor? _inboxFolderMonitor;
  final PodcastGateway? _podcastGateway;
  final String? _podcastManagedRoot;

  /// iOS: Listenook's copies of imported media, deleted with their last job.
  final ManagedMediaStore? _managedMedia;
  final TranscriptParser _parser;
  final PublisherTranscriptParser _publisherTranscriptParser;
  final TimedSubtitleImportService _timedSubtitleImportService;
  final PodcastDownloadLocator _downloadLocator;
  final TranscriptStructureEditor _transcriptStructureEditor;
  final Uuid _uuid;
  final Set<String> _downloadCancelledIds = {};
  int _activePodcastDownloads = 0;
  final _jobs = _JobMap();
  (int, List<TranscriptionJob>)? _sortedJobs;
  (LibraryCatalog, List<LibraryGroup>)? _sortedGroups;
  (LibraryCatalog, List<LibraryTag>)? _sortedTags;
  final Map<String, Duration> _playbackPositions = {};
  final Map<String, _TranscriptStructureHistory> _structureHistories = {};
  final List<String> _inboxIds = [];
  final Set<String> _cancelledIds = {};
  final Set<String> _translationCancelledIds = {};
  final Set<String> _aiBriefCancelledIds = {};
  final Set<String> _alignmentInterruptedIds = {};
  final Set<String> _monitorCandidatesInFlight = {};
  final Set<String> _localAutoStartCandidates = {};
  final Map<String, Timer> _progressCooldowns = {};
  final Set<String> _progressPending = {};
  bool _progressDisposed = false;
  final _remoteLane = _PermitPool(4);
  final _localModelLane = _PermitPool(1);
  late final LocalModelsController localModels = LocalModelsController(
    _localModelManager,
    onStatusesChanged: _localModelStatusesChanged,
  );
  String _batchId = '';
  bool _processing = false;
  bool _initializing = true;
  bool _keyConfigured = false;
  bool _mossKeyConfigured = false;
  bool _translationKeyConfigured = false;
  bool _monitorShutDown = false;
  bool _localAutoStartDraining = false;
  AppDestination _destination = AppDestination.podcast;
  String? _activeWorkspaceJobId;
  Future<void> _settingsSaveTail = Future<void>.value();
  DateTime? _lastPlaybackHistorySaveAt;
  bool _playbackHistoryDirty = false;
  AppSettings _settings = const AppSettings();
  LibraryCatalog _libraryCatalog = const LibraryCatalog();
  TranscriptionOptions _sessionOptions = const TranscriptionOptions();
  TranscriptionProvider _sessionTranscriptionProvider =
      TranscriptionProvider.soniox;
  InboxMonitorStorage _inboxMonitorStorage = const InboxMonitorStorage();
  InboxMonitorStatus _inboxMonitorStatus = InboxMonitorStatus.unconfigured;

  AppSettings get settings => _settings;
  InboxMonitorConfig get inboxMonitorConfig => _inboxMonitorStorage.config;
  InboxMonitorStatus get inboxMonitorStatus => _inboxMonitorStatus;
  bool get inboxMonitorConfigured => inboxMonitorConfig.isConfigured;
  int get monitoredWaitingCount => inboxJobs
      .where(
        (job) =>
            job.sourceOrigin == JobSourceOrigin.monitoredFolder &&
            job.document == null,
      )
      .length;
  LibraryCatalog get libraryCatalog => _libraryCatalog;
  List<LibraryGroup> get libraryGroups {
    final cached = _sortedGroups;
    if (cached != null && identical(cached.$1, _libraryCatalog)) {
      return cached.$2;
    }
    final groups = List<LibraryGroup>.unmodifiable(
      List<LibraryGroup>.of(_libraryCatalog.groups)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
    );
    _sortedGroups = (_libraryCatalog, groups);
    return groups;
  }

  List<LibraryTag> get libraryTags {
    final cached = _sortedTags;
    if (cached != null && identical(cached.$1, _libraryCatalog)) {
      return cached.$2;
    }
    final tags = List<LibraryTag>.unmodifiable(
      List<LibraryTag>.of(_libraryCatalog.tags)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
    );
    _sortedTags = (_libraryCatalog, tags);
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
  TranscriptionProvider get sessionTranscriptionProvider =>
      _sessionTranscriptionProvider;
  bool get processing => _processing;
  bool get hasActiveWork => _jobs.values.any((job) => job.isBusy);
  bool get keyConfigured => _keyConfigured;
  bool get mossKeyConfigured => _mossKeyConfigured;
  bool isTranscriptionProviderConfigured(TranscriptionProvider provider) =>
      switch (provider) {
        TranscriptionProvider.soniox => _keyConfigured,
        TranscriptionProvider.mossPro => _mossKeyConfigured,
        TranscriptionProvider.mossLocal =>
          (_localSttService?.isSupported ?? false) &&
              localModels.isReady(LocalSpeechModels.mossDiarizeCoreMlInt8.id),
        TranscriptionProvider.qwen3Local =>
          (_localSttService?.isSupported ?? false) &&
              LocalSpeechModels.qwen3AsrBundle.artifacts.every(
                (model) => localModels.isReady(model.id),
              ),
      };
  bool get localSpeechSupported => _localSttService?.isSupported ?? false;

  List<TranscriptionProvider> get availableTranscriptionProviders => [
    TranscriptionProvider.soniox,
    TranscriptionProvider.mossPro,
    if (localSpeechSupported) TranscriptionProvider.mossLocal,
    if (localSpeechSupported) TranscriptionProvider.qwen3Local,
  ];
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

  /// Newest first. Sorted once per change to the jobs, since pages read this
  /// on every rebuild.
  List<TranscriptionJob> get allJobs {
    final cached = _sortedJobs;
    if (cached != null && cached.$1 == _jobs.version) return cached.$2;
    final list = List<TranscriptionJob>.unmodifiable(
      _jobs.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
    _sortedJobs = (_jobs.version, list);
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

  /// Saves are throttled while playback reports positions; pass [flush] when
  /// leaving a job so its last position is written now.
  void rememberPlaybackPosition(
    String jobId,
    Duration position, {
    bool flush = false,
  }) {
    final bool changed;
    if (position <= Duration.zero) {
      changed = _playbackPositions.remove(jobId) != null;
    } else {
      final normalized = Duration(milliseconds: position.inMilliseconds);
      changed = _playbackPositions[jobId] != normalized;
      _playbackPositions[jobId] = normalized;
    }
    if (changed && _jobs.containsKey(jobId)) {
      _markPlaybackHistoryDirty(force: flush);
    } else if (flush && _playbackHistoryDirty) {
      _requestPlaybackHistorySave(force: true);
    }
  }

  void _forgetPlaybackPosition(String jobId) {
    final removed = _playbackPositions.remove(jobId) != null;
    if (!removed && !_settings.playbackPositionsMs.containsKey(jobId)) return;
    _markPlaybackHistoryDirty();
  }

  void _markPlaybackHistoryDirty({bool force = false}) {
    // Called on every playback position tick: only flag the change here and
    // copy the positions into settings when they are actually saved.
    _playbackHistoryDirty = true;
    _requestPlaybackHistorySave(force: force);
  }

  void _requestPlaybackHistorySave({bool force = false}) {
    final now = DateTime.now();
    final lastSavedAt = _lastPlaybackHistorySaveAt;
    if (!force &&
        lastSavedAt != null &&
        now.difference(lastSavedAt) < _playbackHistorySaveInterval) {
      return;
    }
    _lastPlaybackHistorySaveAt = now;
    unawaited(
      _savePlaybackHistory().catchError((Object error) {
        debugPrint('Unable to save playback history: $error');
      }),
    );
  }

  Future<void> _savePlaybackHistory() async {
    if (!_playbackHistoryDirty) return;
    _playbackHistoryDirty = false;
    _settings = _settings.copyWith(
      playbackPositionsMs: {
        for (final entry in _playbackPositions.entries)
          if (_jobs.containsKey(entry.key))
            entry.key: entry.value.inMilliseconds,
      },
    );
    try {
      await _queueSettingsSave(_settings);
    } on Object {
      _playbackHistoryDirty = true;
      rethrow;
    }
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
    _sessionTranscriptionProvider = _settings.defaultTranscriptionProvider;
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
    _sessionOptions = TranscriptionOptions(
      sonioxTranslation: _settings.sonioxTranslation,
    );
    final stored = await _jobsRepository.loadAll();
    final loaded = <TranscriptionJob>[];
    for (final original in stored) {
      final document = original.document;
      var normalized = document;
      if (normalized != null && _isMossJob(original)) {
        normalized = _parser.removeMossControlOnlySegments(normalized);
      }
      if (normalized != null &&
          original.transcriptAcquisitionMode ==
              TranscriptAcquisitionMode.importedSubtitles) {
        normalized = _parser.removeImportedSubtitleCaptionArtifacts(normalized);
      }
      if (normalized != null &&
          !original.forcedAlignment.hasWordTiming &&
          original.transcriptAcquisitionMode !=
              TranscriptAcquisitionMode.importedSubtitles) {
        normalized = _parser.normalizeSegments(normalized);
      }
      final documentChanged =
          normalized != null && !identical(normalized, document);
      var job = documentChanged
          ? original.copyWith(document: normalized)
          : original;
      if (!identical(job, original) &&
          job.status == JobStatus.completed &&
          job.document?.segments.isEmpty == true) {
        job = job.copyWith(
          status: JobStatus.empty,
          progress: const JobProgress(stage: 'complete', fraction: 1),
        );
      }
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
      if (job.transcriptAcquisitionMode ==
              TranscriptAcquisitionMode.importedSubtitles &&
          (job.status.canTranscribe || job.status == JobStatus.aligning)) {
        job = job.copyWith(
          status: job.document?.segments.isNotEmpty == true
              ? JobStatus.completed
              : JobStatus.empty,
          progress: const JobProgress(stage: 'complete', fraction: 1),
          forcedAlignment: const ForcedAlignmentState(),
        );
      }
      if (job.status == JobStatus.aligning && job.document != null) {
        final alignment = job.forcedAlignment;
        job = job.copyWith(
          status: job.document!.segments.isEmpty
              ? JobStatus.empty
              : JobStatus.completed,
          progress: const JobProgress(stage: 'complete', fraction: 1),
          forcedAlignment: ForcedAlignmentState(
            status: ForcedAlignmentStatus.interrupted,
            modelId: alignment.modelId,
            modelRevision: alignment.modelRevision,
            alignedSegments: alignment.alignedSegments,
            totalSegments: alignment.totalSegments == 0
                ? job.document!.segments.length
                : alignment.totalSegments,
            languageAutomaticallyDetermined:
                alignment.languageAutomaticallyDetermined ||
                job.options.languageHints.isEmpty,
            warningCode: 'alignment_interrupted',
            warningMessage:
                'Precise word timing was interrupted before it finished.',
          ),
        );
      }
      _jobs[job.id] = job;
      loaded.add(job);
      if (!identical(job, original)) {
        await _jobsRepository.save(job);
      }
    }
    for (final entry in _settings.playbackPositionsMs.entries) {
      if (_jobs.containsKey(entry.key) && entry.value > 0) {
        _playbackPositions[entry.key] = Duration(milliseconds: entry.value);
      }
    }
    if (_playbackPositions.length != _settings.playbackPositionsMs.length) {
      _settings = _settings.copyWith(
        playbackPositionsMs: {
          for (final entry in _playbackPositions.entries)
            entry.key: entry.value.inMilliseconds,
        },
      );
      settingsChanged = true;
    }
    _keyConfigured = await _credentialIsAvailable(
      _credentials,
      _credentials.readApiKey,
    );
    _mossKeyConfigured = await _credentialIsAvailable(
      _mossCredentials,
      _mossCredentials?.readApiKey,
    );
    _translationKeyConfigured = await _credentialIsAvailable(
      _translationCredentials,
      _translationCredentials?.readApiKey,
    );
    await localModels.refresh();
    settingsChanged =
        _selectSoleInstalledForcedAlignerIfUnset() || settingsChanged;
    if (!availableTranscriptionProviders.contains(
      _sessionTranscriptionProvider,
    )) {
      _sessionTranscriptionProvider = TranscriptionProvider.soniox;
    }
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
      _sessionTranscriptionProvider = interrupted.first.transcriptionProvider;
      _inboxIds.addAll(interrupted.map((job) => job.id));
    }
    settingsChanged = _restoreContentDestination() || settingsChanged;
    if (settingsChanged) {
      await _queueSettingsSave(_settings);
    }
    await _seedMonitorLedgerFromJobs(loaded);
    _initializing = false;
    notifyListeners();
    await _restartInboxMonitor();
    unawaited(_verifyLocalModelStatusesInBackground());
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

  Future<void> _verifyLocalModelStatusesInBackground() async {
    try {
      await localModels.refresh(verifyIntegrity: true);
    } on Object catch (error) {
      debugPrint('Unable to verify local speech models: $error');
    }
  }

  Future<void> _localModelStatusesChanged() async {
    // initialize() applies the aligner default itself once settings load.
    if (_initializing) return;
    if (_selectSoleInstalledForcedAlignerIfUnset()) {
      await _queueSettingsSave(_settings);
    }
    notifyListeners();
    _scheduleLocalAutoStart();
  }

  bool _selectSoleInstalledForcedAlignerIfUnset() {
    if (_settings.defaultForcedAlignmentModel != null) return false;
    final installed = LocalSpeechModels.forcedAligners.entries
        .where(
          (entry) =>
              localModels.status(entry.value.id)?.availability ==
              LocalModelAvailability.ready,
        )
        .toList(growable: false);
    if (installed.length != 1) return false;
    _settings = _settings.copyWith(
      defaultForcedAlignmentModel: installed.single.key,
    );
    return true;
  }

  LocalModelDescriptor? get _defaultForcedAligner {
    final model = _settings.defaultForcedAlignmentModel;
    return model == null ? null : LocalSpeechModels.forcedAligner(model);
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
        showDockIcon: inboxMonitorConfig.showDockIcon,
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
        showDockIcon: config.showDockIcon,
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
    // Without either icon the app could not be reached once its window is
    // closed.
    if (!visible && !inboxMonitorConfig.showDockIcon) return;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: inboxMonitorConfig.copyWith(showTrayIcon: visible),
    );
    await _persistInboxMonitor();
    notifyListeners();
  }

  Future<void> setDesktopDockIconVisible(bool visible) async {
    if (inboxMonitorConfig.showDockIcon == visible) return;
    if (!visible && !inboxMonitorConfig.showTrayIcon) return;
    _inboxMonitorStorage = _inboxMonitorStorage.copyWith(
      config: inboxMonitorConfig.copyWith(showDockIcon: visible),
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
      _forgetPlaybackPosition(job.id);
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

  // The monitor also reports an error code with each status; nothing shows it.
  void _setInboxMonitorStatus(InboxMonitorStatus status, String? _) {
    if (_inboxMonitorStatus == status) return;
    _inboxMonitorStatus = status;
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
    final destinationChanged = _destination != destination;
    _destination = destination;
    final restoreStateChanged = _rememberContentDestination(destination);
    if (destinationChanged || restoreStateChanged) notifyListeners();
  }

  bool _restoreContentDestination() {
    switch (_settings.lastContentDestination) {
      case AppContentDestination.podcast:
        _destination = AppDestination.podcast;
        return false;
      case AppContentDestination.library:
        _destination = AppDestination.library;
        return false;
      case AppContentDestination.workspace:
        final jobId = _settings.lastWorkspaceJobId;
        final job = jobId == null ? null : _jobs[jobId];
        if (job?.document != null) {
          _activeWorkspaceJobId = jobId;
          _destination = AppDestination.workspace;
          return false;
        }
        _activeWorkspaceJobId = null;
        _destination = AppDestination.podcast;
        _settings = _settings.copyWith(
          lastContentDestination: AppContentDestination.podcast,
          clearLastWorkspaceJobId: true,
        );
        return true;
    }
  }

  bool _rememberContentDestination(AppDestination destination) {
    final contentDestination = switch (destination) {
      AppDestination.podcast => AppContentDestination.podcast,
      AppDestination.library => AppContentDestination.library,
      AppDestination.workspace
          when _jobs[_activeWorkspaceJobId]?.document != null =>
        AppContentDestination.workspace,
      _ => null,
    };
    if (contentDestination == null) return false;
    final workspaceJobId = contentDestination == AppContentDestination.workspace
        ? _activeWorkspaceJobId
        : _settings.lastWorkspaceJobId;
    if (_settings.lastContentDestination == contentDestination &&
        _settings.lastWorkspaceJobId == workspaceJobId) {
      return false;
    }
    _settings = _settings.copyWith(
      lastContentDestination: contentDestination,
      lastWorkspaceJobId: workspaceJobId,
    );
    unawaited(_saveNavigationState());
    return true;
  }

  Future<void> _saveNavigationState() async {
    try {
      await _queueSettingsSave(_settings);
    } on Object catch (error) {
      debugPrint('Unable to save navigation state: $error');
    }
  }

  Future<void> _queueSettingsSave(AppSettings settings) {
    final save = _settingsSaveTail.then(
      (_) => _settingsRepository.save(settings),
    );
    _settingsSaveTail = save.catchError((Object _) {});
    return save;
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
      (prior) => prior.copyWith(
        displayTitle: normalized,
        clearDisplayTitle: normalized == null || normalized.isEmpty,
      ),
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
      await _transition(job, (prior) => prior.copyWith(clearGroupId: true));
    }
    _libraryCatalog = _libraryCatalog.copyWith(
      groups: _libraryCatalog.groups
          .where((group) => group.id != id)
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
      await _transition(
        job,
        (prior) =>
            prior.copyWith(groupId: groupId, clearGroupId: groupId == null),
      );
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
      await _transition(job, (prior) => prior.copyWith(tagIds: updatedTagIds));
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
        await _transition(job, (prior) => prior.copyWith(queueIndex: index));
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
    final provider = switch (mode) {
      TranscriptAcquisitionMode.mossPro => TranscriptionProvider.mossPro,
      TranscriptAcquisitionMode.mossLocal => TranscriptionProvider.mossLocal,
      TranscriptAcquisitionMode.qwen3Local => TranscriptionProvider.qwen3Local,
      TranscriptAcquisitionMode.soniox => TranscriptionProvider.soniox,
      TranscriptAcquisitionMode.publisherCaptions => job.transcriptionProvider,
      TranscriptAcquisitionMode.importedSubtitles => job.transcriptionProvider,
    };
    final transcriptionModel = _localTranscriptionModelForMode(mode);
    await _transition(
      job,
      (prior) => prior.copyWith(
        transcriptAcquisitionMode: mode,
        transcriptionProvider: provider,
        transcriptionModel: transcriptionModel,
        clearTranscriptionModel: transcriptionModel == null,
      ),
    );
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
    final transcriptAcquisitionMode = episode.transcripts.isNotEmpty
        ? TranscriptAcquisitionMode.publisherCaptions
        : _providerAcquisitionMode(_sessionTranscriptionProvider);
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
      transcriptionProvider: _sessionTranscriptionProvider,
      transcriptAcquisitionMode: transcriptAcquisitionMode,
      transcriptionModel: _localTranscriptionModelForMode(
        transcriptAcquisitionMode,
      ),
    );
    _jobs[job.id] = job;
    _inboxIds.add(job.id);
    _trackLocalAutoStartCandidate(job.id);
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
          (prior) => prior.copyWith(
            status: JobStatus.cancelled,
            progress: const JobProgress(stage: 'cancelled'),
            errorCode: 'cancelled',
            errorMessage: 'Cancelled by the user.',
          ),
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
      (prior) => prior.copyWith(
        sourcePath: path,
        status: JobStatus.ready,
        metadata: metadata,
        sourceFingerprint: fingerprint,
        podcastProvenance: classified.$1,
        transcriptAcquisitionMode: classified.$2,
        progress: const JobProgress(stage: 'ready', fraction: 1),
        clearError: true,
      ),
    );
    if (fingerprint != null && _pathIsInMonitoredFolder(path)) {
      await _recordMonitoredFile(
        updated,
        MonitoredFileDisposition.queued,
        fingerprint: fingerprint,
      );
    }
    _scheduleLocalAutoStart();
  }

  Future<(PodcastEpisodeProvenance?, TranscriptAcquisitionMode)>
  _classifyPublisherTranscript(TranscriptionJob job) async {
    final provenance = job.podcastProvenance;
    final gateway = _podcastGateway;
    if (provenance == null || provenance.transcripts.isEmpty) {
      return (provenance, _providerAcquisitionMode(job.transcriptionProvider));
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

  bool get canStartReady => !_processing && inboxJobs.any(canProcessInboxJob);

  bool canProcessInboxJob(TranscriptionJob job) =>
      job.status.canTranscribe && _canStart(job);

  bool _canStart(TranscriptionJob job) {
    if (job.usesImportedSubtitles) {
      return job.document?.segments.isNotEmpty == true;
    }
    if (job.transcriptAcquisitionMode.usesPublisherTranscript) return true;
    return isTranscriptionProviderConfigured(job.transcriptionProvider);
  }

  Future<void> enqueueSources(
    Iterable<String> paths, {
    bool allowLocalAutoStart = true,
  }) async {
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final existing = <String>{
      for (final job in inboxJobs) _sourceResolver.identityFor(job.sourcePath),
    };
    final sources = await _sourceResolver.resolve(paths);
    for (final source in sources) {
      final extension = p
          .extension(source.path)
          .replaceFirst('.', '')
          .toLowerCase();
      if (!supportedMonitoredMediaExtensions.contains(extension)) continue;
      if (!existing.add(source.identity)) continue;
      await _enqueueResolvedSource(
        source,
        sourceOrigin: JobSourceOrigin.manual,
        fingerprint: await fingerprintMonitoredFile(source.path),
        allowLocalAutoStart: allowLocalAutoStart,
      );
    }
  }

  Future<SubtitleImportReview?> previewSourceImports(
    Iterable<String> paths,
  ) async {
    final review = await _timedSubtitleImportService.preview(
      paths,
      resolver: _sourceResolver,
    );
    if (review == null) return null;
    final matches = <MediaSubtitleMatch>[];
    for (final match in review.media) {
      final metadata = await _media.inspect(match.media.path);
      final candidates = <SubtitleFileCandidate>[];
      for (final candidate in match.candidates) {
        final source = candidate.parseResult;
        if (source == null) {
          candidates.add(candidate);
          continue;
        }
        final parsed = _timedSubtitleImportService.constrainToDuration(
          source,
          metadata.durationMs,
        );
        candidates.add(
          SubtitleFileCandidate(
            path: candidate.path,
            displayName: candidate.displayName,
            format: candidate.format,
            parseResult: parsed,
            errorCode: parsed.document.segments.isEmpty
                ? 'subtitle_no_valid_cues'
                : candidate.errorCode,
          ),
        );
      }
      matches.add(
        MediaSubtitleMatch(media: match.media, candidates: candidates),
      );
    }
    return SubtitleImportReview(
      media: List.unmodifiable(matches),
      unmatchedSubtitles: review.unmatchedSubtitles,
    );
  }

  Future<void> enqueueReviewedImports(
    Iterable<SubtitleImportSelection> selections,
  ) async {
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final existing = <String>{
      for (final job in inboxJobs) _sourceResolver.identityFor(job.sourcePath),
    };
    for (final selection in selections) {
      if (!existing.add(selection.media.identity)) continue;
      final subtitle = selection.subtitle;
      if (subtitle == null) {
        await _enqueueResolvedSource(
          selection.media,
          sourceOrigin: JobSourceOrigin.manual,
          fingerprint: await fingerprintMonitoredFile(selection.media.path),
          allowLocalAutoStart: false,
        );
        continue;
      }
      if (!subtitle.isValid) continue;
      await _enqueueImportedSubtitle(selection);
    }
  }

  Future<void> _enqueueImportedSubtitle(
    SubtitleImportSelection selection,
  ) async {
    final subtitle = selection.subtitle!;
    final metadata = await _media.inspect(selection.media.path);
    final parsed = _timedSubtitleImportService.constrainToDuration(
      subtitle.parseResult!,
      metadata.durationMs,
    );
    if (parsed.document.segments.isEmpty) {
      throw const TimedSubtitleImportException('subtitle_no_valid_cues');
    }
    final now = DateTime.now().toUtc();
    final job = TranscriptionJob(
      id: _uuid.v4(),
      batchId: _batchId,
      sourcePath: selection.media.path,
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      queueIndex: _inboxIds.length,
      progress: const JobProgress(stage: 'complete', fraction: 1),
      metadata: metadata,
      options: _sessionOptions,
      document: parsed.document,
      translationOptions: TranslationOptions.fromSettings(
        _settings.translationSettings,
      ),
      sourceOrigin: JobSourceOrigin.manual,
      sourceFingerprint: await fingerprintMonitoredFile(selection.media.path),
      importedSubtitleProvenance: ImportedSubtitleProvenance(
        sourcePath: subtitle.path,
        displayName: subtitle.displayName,
        format: subtitle.format,
        importedAt: now,
        sourceFingerprint: await fingerprintMonitoredFile(subtitle.path),
      ),
      transcriptionProvider: _sessionTranscriptionProvider,
      transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
      transcriptSource: TranscriptSource.importedSubtitle,
    );
    _jobs[job.id] = job;
    _inboxIds.add(job.id);
    await _jobsRepository.save(job);
    notifyListeners();
    if (_autoTranslationApplies(job)) unawaited(_autoTranslate(job));
  }

  Future<String?> replaceImportedSubtitle(
    String jobId,
    String subtitlePath,
  ) async {
    final job = _jobs[jobId];
    if (job == null ||
        job.transcriptAcquisitionMode !=
            TranscriptAcquisitionMode.importedSubtitles ||
        job.isBusy) {
      return 'subtitle_replace_unavailable';
    }
    try {
      final candidate = await _timedSubtitleImportService.parseCandidate(
        subtitlePath,
      );
      if (!candidate.isValid) {
        return candidate.errorCode ?? 'subtitle_no_valid_cues';
      }
      final metadata = job.metadata ?? await _media.inspect(job.sourcePath);
      final parsed = _timedSubtitleImportService.constrainToDuration(
        candidate.parseResult!,
        metadata.durationMs,
      );
      if (parsed.document.segments.isEmpty) {
        return 'subtitle_no_valid_cues';
      }
      final subtitleFingerprint = await fingerprintMonitoredFile(
        candidate.path,
      );
      final updated = await _transition(
        job,
        (prior) => prior.copyWith(
          status: JobStatus.completed,
          progress: const JobProgress(stage: 'complete', fraction: 1),
          metadata: metadata,
          document: parsed.document,
          importedSubtitleProvenance: ImportedSubtitleProvenance(
            sourcePath: candidate.path,
            displayName: candidate.displayName,
            format: candidate.format,
            importedAt: DateTime.now().toUtc(),
            sourceFingerprint: subtitleFingerprint,
          ),
          translationState: const TranslationState(),
          aiGenerationState: const AiGenerationState(),
          forcedAlignment: const ForcedAlignmentState(),
          clearAiBrief: true,
          clearError: true,
        ),
      );
      if (_autoTranslationApplies(updated)) unawaited(_autoTranslate(updated));
      return null;
    } on TimedSubtitleImportException catch (error) {
      return error.code;
    } on MediaException catch (error) {
      return error.code;
    } on Object {
      return 'subtitle_read_failed';
    }
  }

  Future<TranscriptionJob?> _enqueueResolvedSource(
    ResolvedMediaSource source, {
    required JobSourceOrigin sourceOrigin,
    SourceFingerprint? fingerprint,
    bool allowLocalAutoStart = true,
    PodcastEpisodeProvenance? podcastProvenance,
    String? displayTitle,
  }) async {
    if (_inboxIds.isEmpty && !_processing) _batchId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final transcriptAcquisitionMode = _providerAcquisitionMode(
      _sessionTranscriptionProvider,
    );
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
      podcastProvenance: podcastProvenance,
      displayTitle: displayTitle,
      transcriptionProvider: _sessionTranscriptionProvider,
      transcriptAcquisitionMode: transcriptAcquisitionMode,
      transcriptionModel: _localTranscriptionModelForMode(
        transcriptAcquisitionMode,
      ),
    );
    _jobs[job.id] = job;
    _inboxIds.add(job.id);
    if (allowLocalAutoStart) _trackLocalAutoStartCandidate(job.id);
    await _jobsRepository.save(job);
    notifyListeners();
    unawaited(_prepare(job.id));
    return job;
  }

  Future<TranscriptionJob?> enqueueAgain(String id) async {
    final original = _jobs[id];
    if (original == null) return null;
    final sources = await _sourceResolver.resolve([original.sourcePath]);
    if (sources.isEmpty) return null;
    final queued = await _enqueueResolvedSource(
      sources.first,
      sourceOrigin: JobSourceOrigin.manual,
      fingerprint: await fingerprintMonitoredFile(sources.first.path),
      allowLocalAutoStart: false,
      podcastProvenance: original.podcastProvenance,
      displayTitle: original.displayTitle,
    );
    setDestination(AppDestination.inbox);
    return queued;
  }

  Future<void> _prepare(String id) async {
    var job = _jobs[id];
    if (job == null || job.status != JobStatus.pending) return;
    job = await _transition(
      job,
      (prior) => prior.copyWith(
        status: JobStatus.probing,
        progress: const JobProgress(stage: 'probing'),
        clearError: true,
      ),
    );
    try {
      final metadata = await _media.inspect(job.sourcePath);
      if (!_jobs.containsKey(id)) return;
      await _transition(
        job,
        (prior) => prior.copyWith(
          status: _processing ? JobStatus.paused : JobStatus.ready,
          metadata: metadata,
          progress: JobProgress(
            stage: _processing ? 'paused' : 'ready',
            fraction: 0,
          ),
        ),
      );
      _scheduleLocalAutoStart();
    } on MediaException catch (error) {
      if (!_jobs.containsKey(id)) return;
      await _transition(
        job,
        (prior) => prior.copyWith(
          status: error.code == 'missing_source'
              ? JobStatus.missingSource
              : JobStatus.failed,
          errorCode: error.code,
          errorMessage: error.message,
          progress: const JobProgress(stage: 'failed'),
        ),
      );
    } on Object catch (error) {
      if (!_jobs.containsKey(id)) return;
      await _fail(job, 'media_error', _safeError(error));
    }
  }

  Future<void> startReady() async {
    if (_processing) return;
    final queue = inboxJobs.where(canProcessInboxJob).toList(growable: false);
    if (queue.isEmpty) return;
    _localAutoStartCandidates.removeAll(queue.map((job) => job.id));
    _processing = true;
    notifyListeners();
    try {
      await Future.wait([for (final job in queue) _runJob(job.id)]);
    } finally {
      _processing = false;
      notifyListeners();
      _scheduleLocalAutoStart();
    }
  }

  void _trackLocalAutoStartCandidate(String jobId) {
    if (_settings.autoTranscribeLocal) {
      _localAutoStartCandidates.add(jobId);
    }
  }

  List<String> _readyLocalAutoStartIds() {
    _localAutoStartCandidates.removeWhere((id) {
      final job = _jobs[id];
      return job == null ||
          !_inboxIds.contains(id) ||
          job.document != null ||
          job.status.isTerminal ||
          job.transcriptAcquisitionMode.usesPublisherTranscript;
    });
    return [
      for (final id in _localAutoStartCandidates)
        if (_jobs[id] case final TranscriptionJob job
            when job.status.canTranscribe &&
                _isLocalProvider(job.transcriptionProvider) &&
                _isLocalAcquisitionMode(job.transcriptAcquisitionMode) &&
                _canStart(job))
          id,
    ];
  }

  void _scheduleLocalAutoStart() {
    if (!_settings.autoTranscribeLocal ||
        _localAutoStartDraining ||
        _processing ||
        _readyLocalAutoStartIds().isEmpty) {
      return;
    }
    _localAutoStartDraining = true;
    unawaited(_drainLocalAutoStart());
  }

  Future<void> _drainLocalAutoStart() async {
    if (_processing) {
      _localAutoStartDraining = false;
      return;
    }
    _processing = true;
    notifyListeners();
    try {
      while (_settings.autoTranscribeLocal) {
        final queue = _readyLocalAutoStartIds();
        if (queue.isEmpty) break;
        final jobId = queue.first;
        _localAutoStartCandidates.remove(jobId);
        await _runWorkerPool([jobId]);
      }
    } finally {
      _processing = false;
      _localAutoStartDraining = false;
      notifyListeners();
      _scheduleLocalAutoStart();
    }
  }

  Future<void> _runWorkerPool(List<String> jobIds) async {
    await Future.wait(jobIds.map(_runJob));
  }

  Future<void> _runJob(String id) async {
    final initialJob = _jobs[id];
    if (initialJob == null) return;
    TranscriptionJob job = initialJob;
    try {
      if (job.transcriptAcquisitionMode.usesPublisherTranscript) {
        await _importPublisherTranscript(job);
        return;
      }
      final importedSubtitles =
          job.transcriptAcquisitionMode ==
          TranscriptAcquisitionMode.importedSubtitles;
      if (importedSubtitles) {
        final document = job.document;
        if (document == null || document.segments.isEmpty) {
          await _fail(
            job,
            'subtitle_no_valid_cues',
            'The imported subtitle has no valid timed cues.',
          );
          return;
        }
        job = await _transition(
          job,
          (prior) => prior.copyWith(
            status: JobStatus.completed,
            forcedAlignment: const ForcedAlignmentState(),
            progress: const JobProgress(stage: 'complete', fraction: 1),
            clearError: true,
          ),
        );
      } else {
        job = _isLocalProvider(job.transcriptionProvider)
            ? await _localModelLane.withPermit(
                () => _acquireLocalTranscript(job),
              )
            : await _remoteLane.withPermit(() => _acquireRemoteTranscript(job));

        if (_supportsWordAlignment(job) &&
            job.document?.segments.isNotEmpty == true &&
            _settings.automaticWordTiming) {
          job = await _runForcedAlignment(job);
        } else if (job.status == JobStatus.aligning) {
          job = await _transition(
            job,
            (prior) => prior.copyWith(
              status: JobStatus.completed,
              progress: const JobProgress(stage: 'complete', fraction: 1),
            ),
          );
        }
      }
      job = _jobs[id] ?? job;
      if (_autoTranslationApplies(job)) await _autoTranslate(job);
    } on OperationCancelledException {
      job = _jobs[id] ?? job;
      await _transition(
        job,
        (prior) => prior.copyWith(
          status: JobStatus.cancelled,
          progress: const JobProgress(stage: 'cancelled'),
          errorCode: 'cancelled',
          errorMessage: 'Cancelled by the user.',
        ),
      );
      await _cleanupIfRemote(_jobs[id] ?? job);
    } on MediaException catch (error) {
      await _fail(
        _jobs[id] ?? job,
        error.code,
        error.message,
        status: error.code == 'missing_source'
            ? JobStatus.missingSource
            : JobStatus.failed,
      );
      await _cleanupIfRemote(_jobs[id] ?? job);
    } on SonioxException catch (error) {
      await _fail(_jobs[id] ?? job, error.code, error.message);
      await _cleanupIfRemote(_jobs[id] ?? job);
    } on MossException catch (error) {
      await _fail(_jobs[id] ?? job, error.code, error.message);
      await _cleanupIfRemote(_jobs[id] ?? job);
    } on LocalSpeechException catch (error) {
      await _fail(_jobs[id] ?? job, error.code, error.message ?? error.code);
    } on Object catch (error) {
      await _fail(_jobs[id] ?? job, 'unexpected', _safeError(error));
      await _cleanupIfRemote(_jobs[id] ?? job);
    } finally {
      _cancelledIds.remove(id);
      _alignmentInterruptedIds.remove(id);
    }
  }

  Future<TranscriptionJob> _acquireLocalTranscript(TranscriptionJob job) async {
    final service = _localSttService;
    if (service == null || !service.isSupported) {
      throw const LocalSpeechException('local_stt_unsupported');
    }
    if (!await File(job.sourcePath).exists()) {
      throw const MediaException(
        'missing_source',
        'The source file is missing.',
      );
    }
    _checkCancelled(job.id);
    final metadata = job.metadata ?? await _media.inspect(job.sourcePath);
    job = await _transition(
      job,
      (prior) => prior.copyWith(
        status: JobStatus.converting,
        metadata: metadata,
        progress: const JobProgress(stage: 'converting', fraction: 0),
        clearError: true,
      ),
    );
    final engine = switch (job.transcriptionProvider) {
      TranscriptionProvider.mossLocal => LocalSttEngine.mossDiarize,
      TranscriptionProvider.qwen3Local => LocalSttEngine.qwen3Asr,
      _ => throw const LocalSpeechException('local_stt_unavailable'),
    };
    final result = await service.transcribe(
      LocalSttRequest(
        sourcePath: job.sourcePath,
        durationMs: metadata.durationMs,
        options: job.options,
        engine: engine,
      ),
      onProgress: (fraction, detail) {
        final transcribing = detail != 'converting';
        unawaited(
          _progress(
            job.id,
            transcribing ? 'local_transcribing' : 'converting',
            fraction,
            detail,
            status: transcribing ? JobStatus.processing : JobStatus.converting,
          ),
        );
      },
      shouldCancel: () => _cancelledIds.contains(job.id),
    );
    _checkCancelled(job.id);
    final document = result.document;
    final shouldAlign =
        document.segments.isNotEmpty && _settings.automaticWordTiming;
    return _transition(
      _jobs[job.id] ?? job,
      (prior) => prior.copyWith(
        status: document.segments.isEmpty
            ? JobStatus.empty
            : shouldAlign
            ? JobStatus.aligning
            : JobStatus.completed,
        document: document,
        transcriptSource: engine == LocalSttEngine.qwen3Asr
            ? TranscriptSource.qwen3Local
            : TranscriptSource.mossLocal,
        transcriptionModel: result.model,
        forcedAlignment: shouldAlign
            ? _queuedAlignmentState(
                document.segments.length,
                model: _defaultForcedAligner,
                languageAutomaticallyDetermined:
                    job.options.languageHints.isEmpty,
              )
            : null,
        progress: JobProgress(
          stage: shouldAlign ? 'aligning' : 'complete',
          fraction: shouldAlign ? 0 : 1,
        ),
        clearError: true,
      ),
    );
  }

  Future<TranscriptionJob> _acquireRemoteTranscript(
    TranscriptionJob initial,
  ) async {
    var job = initial;
    String? temporary;
    final transcriptionClient = _transcriptionClient(job.transcriptionProvider);
    try {
      if (!await File(job.sourcePath).exists()) {
        throw const MediaException(
          'missing_source',
          'The source file is missing.',
        );
      }
      _checkCancelled(job.id);
      var uploadPath = job.sourcePath;
      final metadata = job.metadata ?? await _media.inspect(job.sourcePath);
      final uploadProfile =
          job.transcriptionProvider == TranscriptionProvider.mossPro
          ? MediaUploadProfile.compactSpeech
          : MediaUploadProfile.standard;
      if (!_media.canUploadDirectly(
        job.sourcePath,
        metadata,
        profile: uploadProfile,
      )) {
        job = await _transition(
          job,
          (prior) => prior.copyWith(
            status: JobStatus.converting,
            metadata: metadata,
            progress: const JobProgress(stage: 'converting', fraction: 0),
          ),
        );
        temporary = await _media.extractAudio(
          job.sourcePath,
          job.id,
          durationMs: metadata.durationMs,
          profile: uploadProfile,
          onProgress: (fraction, detail) =>
              unawaited(_progress(job.id, 'converting', fraction, detail)),
          shouldCancel: () => _cancelledIds.contains(job.id),
        );
        uploadPath = temporary;
      }
      _checkCancelled(job.id);
      var fileId = job.remoteFileId;
      if (fileId == null) {
        job = await _transition(
          _jobs[job.id] ?? job,
          (prior) => prior.copyWith(
            status: JobStatus.uploading,
            progress: const JobProgress(stage: 'uploading', fraction: 0),
          ),
        );
        fileId = await transcriptionClient.uploadFile(
          uploadPath,
          onProgress: (fraction, detail) =>
              unawaited(_progress(job.id, 'uploading', fraction, detail)),
          shouldCancel: () => _cancelledIds.contains(job.id),
        );
        job = await _transition(
          _jobs[job.id] ?? job,
          (prior) => prior.copyWith(
            remoteFileId: fileId,
            cleanupState: CleanupState.pending,
          ),
        );
      }
      _checkCancelled(job.id);
      var transcriptionId = job.remoteTranscriptionId;
      if (transcriptionId == null) {
        transcriptionId = await transcriptionClient.createTranscription(
          fileId,
          job.options,
        );
        job = await _transition(
          job,
          (prior) => prior.copyWith(
            remoteTranscriptionId: transcriptionId,
            cleanupState: CleanupState.pending,
            status: JobStatus.queuedRemote,
            progress: const JobProgress(stage: 'queued_remote'),
          ),
        );
      }
      await _poll(
        job.id,
        transcriptionId,
        job.transcriptionProvider,
        transcriptionClient,
      );
      _checkCancelled(job.id);
      job = await _transition(
        _jobs[job.id] ?? job,
        (prior) => prior.copyWith(
          status: JobStatus.fetching,
          progress: const JobProgress(stage: 'fetching'),
        ),
      );
      final payload = await transcriptionClient.getTranscript(transcriptionId);
      final usesSoniox =
          job.transcriptionProvider == TranscriptionProvider.soniox;
      final embedded = usesSoniox && job.options.sonioxTranslation.enabled;
      final document = usesSoniox
          ? _parser.parse(
              payload,
              sonioxTranslationTargetLanguage: embedded
                  ? job.options.sonioxTranslation.targetLanguage
                  : null,
            )
          : const MossTranscriptParser().parse(payload);
      final shouldAlign =
          !usesSoniox &&
          document.segments.isNotEmpty &&
          _settings.automaticWordTiming;
      job = await _transition(
        job,
        (prior) => prior.copyWith(
          status: document.segments.isEmpty
              ? JobStatus.empty
              : shouldAlign
              ? JobStatus.aligning
              : JobStatus.completed,
          document: document,
          translationState: embedded
              ? _sonioxTranslationState(
                  document,
                  job.options.sonioxTranslation.targetLanguage,
                )
              : null,
          transcriptSource: usesSoniox
              ? TranscriptSource.soniox
              : TranscriptSource.mossPro,
          forcedAlignment: shouldAlign
              ? _queuedAlignmentState(
                  document.segments.length,
                  model: _defaultForcedAligner,
                  languageAutomaticallyDetermined:
                      job.options.languageHints.isEmpty,
                )
              : null,
          progress: JobProgress(
            stage: shouldAlign ? 'aligning' : 'complete',
            fraction: shouldAlign ? 0 : 1,
          ),
          clearError: true,
        ),
      );
      await _cleanup(job);
      return _jobs[job.id] ?? job;
    } finally {
      if (temporary != null) await _media.deleteTemporary(temporary);
    }
  }

  bool _isMossJob(TranscriptionJob job) =>
      job.transcriptSource == TranscriptSource.mossPro ||
      job.transcriptSource == TranscriptSource.mossLocal ||
      job.transcriptionProvider == TranscriptionProvider.mossPro ||
      job.transcriptionProvider == TranscriptionProvider.mossLocal;

  bool _isLocalProvider(TranscriptionProvider provider) =>
      provider == TranscriptionProvider.mossLocal ||
      provider == TranscriptionProvider.qwen3Local;

  bool _isLocalAcquisitionMode(TranscriptAcquisitionMode mode) =>
      mode == TranscriptAcquisitionMode.mossLocal ||
      mode == TranscriptAcquisitionMode.qwen3Local;

  bool _supportsWordAlignment(TranscriptionJob job) =>
      job.supportsLocalWordAlignment;

  ForcedAlignmentState _queuedAlignmentState(
    int totalSegments, {
    required LocalModelDescriptor? model,
    required bool languageAutomaticallyDetermined,
    int alignedSegments = 0,
  }) => ForcedAlignmentState(
    status: ForcedAlignmentStatus.queued,
    modelId: model?.id,
    modelRevision: model?.revision,
    alignedSegments: alignedSegments,
    totalSegments: totalSegments,
    languageAutomaticallyDetermined: languageAutomaticallyDetermined,
  );

  int _alignedSegmentCount(TranscriptDocument document) {
    final segmentIds = document.segments.map((segment) => segment.id).toSet();
    return document.tokens
        .map((token) => token.segmentId)
        .whereType<String>()
        .where(segmentIds.contains)
        .toSet()
        .length;
  }

  Future<TranscriptionJob> _runForcedAlignment(TranscriptionJob initial) async {
    var job = initial;
    final document = job.document;
    if (document == null || document.segments.isEmpty) return job;
    final service = _forcedAlignmentService;
    if (service == null || !service.isSupported) {
      return _completeWithoutAlignment(
        job,
        ForcedAlignmentStatus.unavailable,
        'alignment_unsupported',
      );
    }
    if (!await File(job.sourcePath).exists()) {
      return _completeWithoutAlignment(
        job,
        ForcedAlignmentStatus.unavailable,
        'alignment_source_missing',
      );
    }
    final model = LocalSpeechModels.forcedAlignerById(
      job.forcedAlignment.modelId,
    );
    if (model == null) {
      return _completeWithoutAlignment(
        job,
        ForcedAlignmentStatus.unavailable,
        job.forcedAlignment.modelId == null
            ? 'alignment_model_not_selected'
            : 'alignment_model_missing',
      );
    }
    job = await _transition(
      job,
      (prior) => prior.copyWith(
        status: JobStatus.aligning,
        forcedAlignment: ForcedAlignmentState(
          status: ForcedAlignmentStatus.running,
          modelId: model.id,
          modelRevision: model.revision,
          alignedSegments: job.forcedAlignment.alignedSegments,
          totalSegments: document.segments.length,
          languageAutomaticallyDetermined: job.options.languageHints.isEmpty,
        ),
        progress: const JobProgress(stage: 'aligning', fraction: 0),
      ),
    );
    var checkpointTail = Future<void>.value();

    void queueCheckpoint(AlignmentResult checkpoint) {
      checkpointTail = checkpointTail.then(
        (_) => _publishAlignmentCheckpoint(
          jobId: job.id,
          source: document,
          result: checkpoint,
          model: model,
        ),
      );
    }

    Future<void> flushCheckpoints() async {
      try {
        await checkpointTail;
      } on Object {
        // The final or interrupted transition below retries persistence with
        // the latest in-memory checkpoint.
      }
    }

    try {
      final result = await _localModelLane.withPermit(
        () => service.align(
          ForcedAlignmentRequest(
            sourcePath: job.sourcePath,
            document: document,
            model: model,
            languageHints: job.options.languageHints,
            onCheckpoint: queueCheckpoint,
          ),
          onProgress: (fraction, detail) =>
              unawaited(_progress(job.id, 'aligning', fraction, detail)),
          shouldCancel: () => _cancelledIds.contains(job.id),
        ),
      );
      await flushCheckpoints();
      final publishTokens =
          result.status == ForcedAlignmentStatus.completed ||
          result.status == ForcedAlignmentStatus.partial;
      return await _transition(
        _jobs[job.id] ?? job,
        (prior) => prior.copyWith(
          status: JobStatus.completed,
          document: publishTokens
              ? document.copyWith(tokens: result.tokens)
              : document,
          forcedAlignment: result.toState(model),
          progress: const JobProgress(stage: 'complete', fraction: 1),
          clearError: true,
        ),
      );
    } on OperationCancelledException {
      await flushCheckpoints();
      final interrupted = _alignmentInterruptedIds.contains(job.id);
      return _completeWithoutAlignment(
        _jobs[job.id] ?? job,
        interrupted
            ? ForcedAlignmentStatus.interrupted
            : ForcedAlignmentStatus.cancelled,
        interrupted ? 'alignment_interrupted' : 'alignment_cancelled',
      );
    } on LocalSpeechException catch (error) {
      await flushCheckpoints();
      return _completeWithoutAlignment(
        _jobs[job.id] ?? job,
        ForcedAlignmentStatus.failed,
        error.code,
        error.message,
      );
    } on Object catch (error) {
      await flushCheckpoints();
      return _completeWithoutAlignment(
        _jobs[job.id] ?? job,
        ForcedAlignmentStatus.failed,
        'alignment_failed',
        _safeError(error),
      );
    }
  }

  Future<void> _publishAlignmentCheckpoint({
    required String jobId,
    required TranscriptDocument source,
    required AlignmentResult result,
    required LocalModelDescriptor model,
  }) async {
    if (result.status != ForcedAlignmentStatus.completed &&
        result.status != ForcedAlignmentStatus.partial) {
      return;
    }
    final current = _jobs[jobId];
    if (current == null || current.status != JobStatus.aligning) return;
    await _transition(
      current,
      (prior) => prior.copyWith(
        status: JobStatus.aligning,
        document: source.copyWith(tokens: result.tokens),
        forcedAlignment: ForcedAlignmentState(
          status: ForcedAlignmentStatus.running,
          modelId: model.id,
          modelRevision: model.revision,
          alignedSegments: result.alignedSegments,
          totalSegments: result.totalSegments,
          languageAutomaticallyDetermined:
              result.languageAutomaticallyDetermined,
        ),
        progress: current.progress,
      ),
    );
  }

  Future<TranscriptionJob> _completeWithoutAlignment(
    TranscriptionJob job,
    ForcedAlignmentStatus status,
    String warningCode, [
    String? warningMessage,
  ]) => _transition(
    job,
    (prior) => prior.copyWith(
      status: job.document?.segments.isEmpty == true
          ? JobStatus.empty
          : JobStatus.completed,
      forcedAlignment: ForcedAlignmentState(
        status: status,
        modelId: job.forcedAlignment.modelId,
        modelRevision: job.forcedAlignment.modelRevision,
        alignedSegments: job.forcedAlignment.alignedSegments,
        totalSegments:
            job.document?.segments.length ?? job.forcedAlignment.totalSegments,
        languageAutomaticallyDetermined:
            job.forcedAlignment.languageAutomaticallyDetermined ||
            job.options.languageHints.isEmpty,
        warningCode: warningCode,
        warningMessage: warningMessage,
      ),
      progress: const JobProgress(stage: 'complete', fraction: 1),
      clearError: true,
    ),
  );

  Future<void> _cleanupIfRemote(TranscriptionJob job) async {
    if (_isLocalProvider(job.transcriptionProvider)) return;
    await _cleanup(job);
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
      final publisherDocument = parsed.document;
      await _transition(
        _jobs[job.id] ?? job,
        (prior) => prior.copyWith(
          status: publisherDocument.segments.isEmpty
              ? JobStatus.empty
              : JobStatus.completed,
          document: TranscriptDocument(
            tokens: const [],
            segments: publisherDocument.segments,
            speakers: publisherDocument.speakers,
            updatedAt: publisherDocument.updatedAt,
          ),
          transcriptSource: TranscriptSource.publisher,
          progress: const JobProgress(stage: 'complete', fraction: 1),
          clearError: true,
        ),
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

  TranscriptAcquisitionMode _providerAcquisitionMode(
    TranscriptionProvider provider,
  ) => switch (provider) {
    TranscriptionProvider.soniox => TranscriptAcquisitionMode.soniox,
    TranscriptionProvider.mossPro => TranscriptAcquisitionMode.mossPro,
    TranscriptionProvider.mossLocal => TranscriptAcquisitionMode.mossLocal,
    TranscriptionProvider.qwen3Local => TranscriptAcquisitionMode.qwen3Local,
  };

  TranscriptionModelReference? _localTranscriptionModelForMode(
    TranscriptAcquisitionMode mode,
  ) {
    final model = switch (mode) {
      TranscriptAcquisitionMode.mossLocal =>
        LocalSpeechModels.mossDiarizeCoreMlInt8,
      TranscriptAcquisitionMode.qwen3Local => LocalSpeechModels.qwen3AsrMlx8Bit,
      _ => null,
    };
    return model == null
        ? null
        : TranscriptionModelReference(id: model.id, revision: model.revision);
  }

  TranscriptionClient _transcriptionClient(TranscriptionProvider provider) =>
      switch (provider) {
        TranscriptionProvider.soniox => _soniox,
        TranscriptionProvider.mossPro =>
          _moss ??
              (throw const MossException(
                code: 'moss_unavailable',
                message: 'MOSS Pro transcription is unavailable.',
              )),
        TranscriptionProvider.mossLocal => throw const LocalSpeechException(
          'local_stt_unavailable',
        ),
        TranscriptionProvider.qwen3Local => throw const LocalSpeechException(
          'local_stt_unavailable',
        ),
      };

  Future<void> _poll(
    String id,
    String transcriptionId,
    TranscriptionProvider provider,
    TranscriptionClient client,
  ) async {
    var failures = 0;
    while (true) {
      _checkCancelled(id);
      try {
        final state = await client.getTranscription(transcriptionId);
        failures = 0;
        if (state.isComplete) return;
        if (state.isFailed) {
          if (provider == TranscriptionProvider.mossPro) {
            throw MossException(
              code: canonicalMossErrorCode(
                state.errorType,
                fallback: 'moss_transcription_failed',
              ),
              message:
                  state.errorMessage ?? 'MOSS could not transcribe this file.',
              errorType: state.errorType,
            );
          }
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
          (prior) => prior.copyWith(
            status: status,
            progress: JobProgress(stage: status.name),
          ),
        );
        await Future<void>.delayed(
          state.retryAfter ?? const Duration(seconds: 2),
        );
      } on SonioxException catch (error) {
        if (!error.retryable || failures >= 7) rethrow;
        failures++;
        await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
      } on MossException catch (error) {
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
        (prior) => prior.copyWith(
          status: JobStatus.cancelled,
          progress: const JobProgress(stage: 'cancelled'),
          errorCode: 'cancelled',
          errorMessage: 'Cancelled by the user.',
        ),
      );
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
        if (job.status == JobStatus.aligning && job.document != null) {
          _alignmentInterruptedIds.add(job.id);
          await _transition(
            _jobs[job.id] ?? job,
            (prior) => prior.copyWith(
              status: job.document!.segments.isEmpty
                  ? JobStatus.empty
                  : JobStatus.completed,
              forcedAlignment: ForcedAlignmentState(
                status: ForcedAlignmentStatus.interrupted,
                modelId: job.forcedAlignment.modelId,
                modelRevision: job.forcedAlignment.modelRevision,
                alignedSegments: job.forcedAlignment.alignedSegments,
                totalSegments: job.document!.segments.length,
                languageAutomaticallyDetermined:
                    job.forcedAlignment.languageAutomaticallyDetermined ||
                    job.options.languageHints.isEmpty,
                warningCode: 'alignment_interrupted',
              ),
              progress: const JobProgress(stage: 'complete', fraction: 1),
              clearError: true,
            ),
          );
          continue;
        }
        await _cleanup(job);
        await _transition(
          _jobs[job.id] ?? job,
          (prior) => prior.copyWith(
            status: JobStatus.cancelled,
            progress: const JobProgress(stage: 'cancelled'),
            errorCode: 'cancelled',
            errorMessage: 'Cancelled while quitting.',
          ),
        );
      }
    }
  }

  void _checkCancelled(String id) {
    if (_cancelledIds.contains(id)) {
      throw const OperationCancelledException();
    }
  }

  Future<void> retryForcedAlignment(String id) async {
    final job = _jobs[id];
    if (job == null ||
        job.document == null ||
        job.document!.segments.isEmpty ||
        !_supportsWordAlignment(job) ||
        job.status.isActive) {
      return;
    }
    _cancelledIds.remove(id);
    final queued = await _transition(
      job,
      (prior) => prior.copyWith(
        status: JobStatus.aligning,
        forcedAlignment: _queuedAlignmentState(
          job.document!.segments.length,
          model: _defaultForcedAligner,
          languageAutomaticallyDetermined: job.options.languageHints.isEmpty,
          alignedSegments: _alignedSegmentCount(job.document!),
        ),
        progress: const JobProgress(stage: 'aligning', fraction: 0),
        clearError: true,
      ),
    );
    await _runForcedAlignment(queued);
    _cancelledIds.remove(id);
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
        (prior) => prior.copyWith(
          sourcePath: location.filePath,
          status: JobStatus.downloading,
          progress: const JobProgress(stage: 'downloading', fraction: 0),
          clearError: true,
        ),
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
      (prior) => prior.copyWith(
        status: JobStatus.ready,
        progress: const JobProgress(stage: 'ready', fraction: 0),
        clearError: true,
        clearRemoteFileId: job.cleanupState == CleanupState.complete,
        clearRemoteTranscriptionId: job.cleanupState == CleanupState.complete,
        cleanupState: job.cleanupState == CleanupState.complete
            ? CleanupState.none
            : job.cleanupState,
      ),
    );
    if (!_inboxIds.contains(id)) _inboxIds.add(id);
    notifyListeners();
    if (_canStart(updated) && !_processing) {
      _localAutoStartCandidates.remove(updated.id);
      _processing = true;
      notifyListeners();
      try {
        await _runJob(updated.id);
      } finally {
        _processing = false;
        notifyListeners();
        _scheduleLocalAutoStart();
      }
    }
  }

  void addToInbox(String id) {
    final job = _jobs[id];
    if (job == null ||
        (job.status != JobStatus.ready && job.status != JobStatus.failed)) {
      return;
    }
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
        (prior) => prior.copyWith(
          sourcePath: sourcePath,
          metadata: metadata,
          status: job.document == null
              ? (_processing ? JobStatus.paused : JobStatus.ready)
              : job.status,
          progress: job.document == null
              ? JobProgress(
                  stage: _processing ? 'paused' : 'ready',
                  fraction: 0,
                )
              : job.progress,
          clearError: true,
        ),
      );
      if (job.sourcePath != sourcePath) await _releaseManagedImport(job);
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
    _localAutoStartCandidates.remove(id);
    _inboxIds.remove(id);
    if (job.document == null) {
      if (_pathIsInMonitoredFolder(job.sourcePath)) {
        await _recordMonitoredFile(job, MonitoredFileDisposition.dismissed);
      }
      await _deleteManagedMedia(job);
      _jobs.remove(id);
      _forgetPlaybackPosition(id);
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
      _localAutoStartCandidates.remove(id);
      final discarded = _jobs[id];
      if (discarded != null && _pathIsInMonitoredFolder(discarded.sourcePath)) {
        await _recordMonitoredFile(
          discarded,
          MonitoredFileDisposition.dismissed,
        );
      }
      if (discarded != null) await _deleteManagedMedia(discarded);
      _jobs.remove(id);
      _forgetPlaybackPosition(id);
      await _media.deleteGeneratedMedia(id);
      await _jobsRepository.delete(id);
    }
    _inboxIds.clear();
    _localAutoStartCandidates.clear();
    _batchId = _uuid.v4();
    _sessionOptions = TranscriptionOptions(
      sonioxTranslation: _settings.sonioxTranslation,
    );
    _sessionTranscriptionProvider = _settings.defaultTranscriptionProvider;
    notifyListeners();
  }

  Future<void> deleteHistory(String id) async {
    final job = _jobs[id];
    if (job == null || job.isBusy) return;
    _jobs.remove(id);
    _localAutoStartCandidates.remove(id);
    _forgetPlaybackPosition(id);
    _inboxIds.remove(id);
    if (_activeWorkspaceJobId == id) _activeWorkspaceJobId = null;
    _forgetWorkspaceJob(id);
    await _deleteManagedMedia(job);
    await _media.deleteGeneratedMedia(id);
    await _jobsRepository.delete(id);
    notifyListeners();
  }

  void openInWorkspace(String id) {
    final job = _jobs[id];
    if (job?.document == null) return;
    _activeWorkspaceJobId = id;
    setDestination(AppDestination.workspace);
  }

  void _forgetWorkspaceJob(String id) {
    if (_settings.lastWorkspaceJobId != id) return;
    final wasWorkspace =
        _settings.lastContentDestination == AppContentDestination.workspace;
    _settings = _settings.copyWith(
      lastContentDestination: wasWorkspace
          ? AppContentDestination.podcast
          : _settings.lastContentDestination,
      clearLastWorkspaceJobId: true,
    );
    unawaited(_saveNavigationState());
  }

  bool canUndoTranscriptStructureEdit(String jobId) =>
      !(_jobs[jobId]?.isBusy ?? true) &&
      (_structureHistories[jobId]?.undo.isNotEmpty ?? false);

  bool canRedoTranscriptStructureEdit(String jobId) =>
      !(_jobs[jobId]?.isBusy ?? true) &&
      (_structureHistories[jobId]?.redo.isNotEmpty ?? false);

  Future<TranscriptStructureEditOutcome> applyTranscriptStructureEdit(
    String jobId,
    TranscriptStructureEdit edit,
  ) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.segmentNotFound,
      );
    }
    if (job.isBusy) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.busy,
      );
    }
    final outcome = _transcriptStructureEditor.apply(document, edit);
    if (outcome is! TranscriptStructureEditResult) return outcome;

    final before = _TranscriptStructureSnapshot.fromJob(job);
    final progress = _translationProgress(outcome.document.segments);
    final hadTranslationState =
        job.translationState.status != TranslationStatus.idle ||
        document.segments.any((segment) => segment.hasTranslation);
    final translationState = hadTranslationState
        ? job.translationState.copyWith(
            status: progress.completed == progress.total
                ? TranslationStatus.completed
                : TranslationStatus.partial,
            completedSegments: progress.completed,
            totalSegments: progress.total,
            clearError: true,
          )
        : job.translationState;
    final updated = await _transition(
      job,
      (prior) => prior.copyWith(
        document: outcome.document,
        translationState: translationState,
        forcedAlignment: _structureAlignmentState(
          job.forcedAlignment,
          outcome.document,
        ),
        aiBrief: _remapAiBriefEvidence(
          job.aiBrief,
          outcome.segmentIdReplacements,
        ),
      ),
      preserveTranscriptStructureHistory: true,
    );
    final history = _structureHistories.putIfAbsent(
      jobId,
      _TranscriptStructureHistory.new,
    );
    history.record(
      _TranscriptStructureHistoryEntry(
        before: before,
        after: _TranscriptStructureSnapshot.fromJob(updated),
      ),
    );
    return outcome;
  }

  Future<bool> undoTranscriptStructureEdit(String jobId) async {
    final history = _structureHistories[jobId];
    final job = _jobs[jobId];
    if (history == null || history.undo.isEmpty || job == null || job.isBusy) {
      return false;
    }
    final entry = history.undo.removeLast();
    await _restoreTranscriptStructureSnapshot(job, entry.before);
    history.redo.add(entry);
    return true;
  }

  Future<bool> redoTranscriptStructureEdit(String jobId) async {
    final history = _structureHistories[jobId];
    final job = _jobs[jobId];
    if (history == null || history.redo.isEmpty || job == null || job.isBusy) {
      return false;
    }
    final entry = history.redo.removeLast();
    await _restoreTranscriptStructureSnapshot(job, entry.after);
    history.undo.add(entry);
    return true;
  }

  Future<void> _restoreTranscriptStructureSnapshot(
    TranscriptionJob job,
    _TranscriptStructureSnapshot snapshot,
  ) => _transition(
    job,
    (prior) => prior.copyWith(
      document: snapshot.document,
      translationState: snapshot.translationState,
      forcedAlignment: snapshot.forcedAlignment,
      aiBrief: snapshot.aiBrief,
      clearAiBrief: snapshot.aiBrief == null,
    ),
    preserveTranscriptStructureHistory: true,
  );

  ForcedAlignmentState _structureAlignmentState(
    ForcedAlignmentState state,
    TranscriptDocument document,
  ) {
    if (!state.hasWordTiming) return state;
    final aligned = document.segments.where((segment) {
      return document.tokens.any(
        (token) =>
            (token.startMs != 0 || token.endMs != 0) &&
            (token.segmentId == segment.id ||
                (token.segmentId == null &&
                    token.startMs >= segment.startMs &&
                    token.startMs <= segment.endMs)),
      );
    }).length;
    return ForcedAlignmentState(
      status: aligned == document.segments.length
          ? ForcedAlignmentStatus.completed
          : ForcedAlignmentStatus.partial,
      modelId: state.modelId,
      modelRevision: state.modelRevision,
      alignedSegments: aligned,
      totalSegments: document.segments.length,
      languageAutomaticallyDetermined: state.languageAutomaticallyDetermined,
      warningCode: state.warningCode,
      warningMessage: state.warningMessage,
    );
  }

  AiBrief? _remapAiBriefEvidence(
    AiBrief? brief,
    Map<String, List<String>> replacements,
  ) {
    if (brief == null || replacements.isEmpty) return brief;
    List<String> remap(List<String> ids) {
      final result = <String>[];
      final seen = <String>{};
      for (final id in ids) {
        for (final replacement in replacements[id] ?? [id]) {
          if (seen.add(replacement)) result.add(replacement);
        }
      }
      return result;
    }

    return brief.copyWith(
      overviewEvidenceSegmentIds: remap(brief.overviewEvidenceSegmentIds),
      chapters: [
        for (final chapter in brief.chapters)
          chapter.copyWith(
            evidenceSegmentIds: remap(chapter.evidenceSegmentIds),
          ),
      ],
      insights: [
        for (final insight in brief.insights)
          insight.copyWith(
            evidenceSegmentIds: remap(insight.evidenceSegmentIds),
          ),
      ],
      languageNotes: [
        for (final note in brief.languageNotes)
          note.copyWith(evidenceSegmentIds: remap(note.evidenceSegmentIds)),
      ],
    );
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
      (prior) => prior.copyWith(
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
      ),
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
    await _transition(
      job,
      (prior) =>
          prior.copyWith(document: document.copyWith(speakers: speakers)),
    );
  }

  Future<void> updateSegmentSpeaker(
    String jobId,
    String segmentId,
    String speakerId,
  ) async {
    final job = _jobs[jobId];
    final document = job?.document;
    if (job == null || document == null) return;
    if (!document.speakers.any((speaker) => speaker.id == speakerId)) return;
    final target = document.segments
        .where((segment) => segment.id == segmentId)
        .firstOrNull;
    if (target == null || target.speaker == speakerId) return;
    final segments = [
      for (final segment in document.segments)
        if (segment.id == segmentId)
          segment.copyWith(speaker: speakerId)
        else
          segment,
    ];
    await _transition(
      job,
      (prior) =>
          prior.copyWith(document: document.copyWith(segments: segments)),
    );
  }

  Future<void> updateSettings(AppSettings value) async {
    final disableLocalAutoStart =
        _settings.autoTranscribeLocal && !value.autoTranscribeLocal;
    _settings = value.copyWith(
      playbackPositionsMs: _settings.playbackPositionsMs,
    );
    if (disableLocalAutoStart) _localAutoStartCandidates.clear();
    await _queueSettingsSave(_settings);
    notifyListeners();
    _scheduleLocalAutoStart();
  }

  Future<void> updateSessionOptions(TranscriptionOptions value) async {
    _sessionOptions = value;
    for (final job in inboxJobs.where(
      (job) =>
          job.status == JobStatus.pending ||
          job.status == JobStatus.probing ||
          job.status.canTranscribe,
    )) {
      if (job.transcriptAcquisitionMode ==
          TranscriptAcquisitionMode.importedSubtitles) {
        continue;
      }
      await _transition(job, (prior) => prior.copyWith(options: value));
    }
    notifyListeners();
  }

  Future<void> updateSessionTranscriptionProvider(
    TranscriptionProvider provider,
  ) async {
    _sessionTranscriptionProvider = provider;
    for (final job in inboxJobs.where(
      (job) =>
          job.status == JobStatus.pending ||
          job.status == JobStatus.probing ||
          job.status.canTranscribe,
    )) {
      if (job.transcriptAcquisitionMode.usesPublisherTranscript ||
          job.transcriptAcquisitionMode ==
              TranscriptAcquisitionMode.importedSubtitles) {
        continue;
      }
      await _transition(
        job,
        (prior) => prior.copyWith(
          transcriptionProvider: provider,
          transcriptAcquisitionMode: _providerAcquisitionMode(provider),
        ),
      );
    }
    notifyListeners();
    _scheduleLocalAutoStart();
  }

  Future<void> updateDefaultTranscriptionProvider(
    TranscriptionProvider provider,
  ) async {
    _settings = _settings.copyWith(defaultTranscriptionProvider: provider);
    if (_inboxIds.isEmpty && !_processing) {
      _sessionTranscriptionProvider = provider;
    }
    await _queueSettingsSave(_settings);
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

  Future<void> saveMossApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _mossCredentials == null) return;
    await _mossCredentials.writeApiKey(trimmed);
    _mossKeyConfigured = true;
    notifyListeners();
  }

  Future<void> removeMossApiKey() async {
    await _mossCredentials?.deleteApiKey();
    _mossKeyConfigured = false;
    notifyListeners();
  }

  Future<String?> testMossApiKey([String? candidate]) async {
    final client = _moss;
    if (client == null) return 'moss_unavailable';
    try {
      await client.validateKey(apiKey: candidate);
      return null;
    } on MossException catch (error) {
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
    await _queueSettingsSave(_settings);
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
      await _queueSettingsSave(_settings);
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
    _settings = _settings.copyWith(translationSettings: settings);
    await _queueSettingsSave(_settings);
    await _updateQueuedTranslationOptions();
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
    _settings = _settings.copyWith(sonioxTranslation: options);
    _sessionOptions = _sessionOptions.copyWith(sonioxTranslation: options);
    await _queueSettingsSave(_settings);
    await _updateQueuedSonioxTranslationOptions();
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
      await _queueSettingsSave(_settings);
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
      (prior) => prior.copyWith(
        document: updatedDocument,
        translationOptions: TranslationOptions(
          enabled: false,
          targetLanguage: targetLanguage,
          baseUrl: settings.baseUrl,
          model: settings.model,
        ),
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
      (prior) => prior.copyWith(
        document: document.copyWith(
          segments: segments,
          preserveUpdatedAt: true,
        ),
        translationState: job.translationState.copyWith(
          status: progress.completed == progress.total
              ? TranslationStatus.completed
              : TranslationStatus.partial,
          completedSegments: progress.completed,
          totalSegments: progress.total,
          clearError: true,
        ),
      ),
    );
  }

  void cancelTranslation(String id) {
    if (_jobs[id]?.translationState.status.isActive ?? false) {
      _translationCancelledIds.add(id);
    }
  }

  bool _autoTranslationApplies(TranscriptionJob job) {
    final usesEmbeddedTranslation =
        job.transcriptAcquisitionMode !=
            TranscriptAcquisitionMode.importedSubtitles &&
        job.transcriptionProvider == TranscriptionProvider.soniox &&
        job.options.sonioxTranslation.enabled;
    return job.status == JobStatus.completed &&
        !usesEmbeddedTranslation &&
        job.translationOptions.enabled &&
        job.translationOptions.targetLanguage.isNotEmpty;
  }

  Future<void> _autoTranslate(TranscriptionJob job) => _runTranslation(
    job,
    settings: TranslationSettings(
      baseUrl: job.translationOptions.baseUrl,
      model: job.translationOptions.model,
      targetLanguage: job.translationOptions.targetLanguage,
    ),
    targetLanguage: job.translationOptions.targetLanguage,
  );

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
        (prior) => prior.copyWith(
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
        ),
      );
      return;
    }

    _translationCancelledIds.remove(job.id);
    current = await _transition(
      current,
      (prior) => prior.copyWith(
        translationState: TranslationState(
          status: TranslationStatus.translating,
          targetLanguage: targetLanguage,
          model: settings.model,
          origin: TranslationOrigin.llm,
          completedSegments: _translationProgress(
            translatableSegments,
          ).completed,
          totalSegments: translatableSegments.length,
        ),
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
            (prior) => prior.copyWith(
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
            ),
          );
        },
      );
      current = _jobs[job.id] ?? current;
      final segments = current.document?.segments ?? const [];
      final progress = _translationProgress(segments);
      await _transition(
        current,
        (prior) => prior.copyWith(
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
        ),
      );
    } on OperationCancelledException {
      current = _jobs[job.id] ?? current;
      final segments = current.document?.segments ?? const [];
      final progress = _translationProgress(segments);
      await _transition(
        current,
        (prior) => prior.copyWith(
          translationState: current.translationState.copyWith(
            status: progress.completed > 0
                ? TranslationStatus.partial
                : TranslationStatus.cancelled,
            completedSegments: progress.completed,
            totalSegments: progress.total,
            errorCode: 'translation_cancelled',
            errorMessage: 'Translation was cancelled.',
          ),
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
      (prior) => prior.copyWith(
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
      await _transition(
        job,
        (prior) => prior.copyWith(translationOptions: options),
      );
    }
  }

  Future<void> _updateQueuedSonioxTranslationOptions() async {
    for (final job in inboxJobs.where(
      (job) => job.document == null && job.remoteTranscriptionId == null,
    )) {
      await _transition(
        job,
        (prior) => prior.copyWith(
          options: job.options.copyWith(
            sonioxTranslation: _settings.sonioxTranslation,
          ),
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
      (prior) => prior.copyWith(
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
            (prior) => prior.copyWith(
              aiGenerationState: latest.aiGenerationState.copyWith(
                status: AiGenerationStatus.generating,
                stage: stage,
                completedChunks: completed,
                totalChunks: total,
                clearError: true,
              ),
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
        (prior) => prior.copyWith(
          aiBrief: brief,
          aiGenerationState: latest.aiGenerationState.copyWith(
            status: AiGenerationStatus.completed,
            stage: 'complete',
            completedChunks: estimated,
            totalChunks: estimated,
            clearError: true,
          ),
        ),
      );
    } on OperationCancelledException {
      final latest = (_jobs[jobId] ?? current)!;
      await _transition(
        latest,
        (prior) => prior.copyWith(
          aiGenerationState: latest.aiGenerationState.copyWith(
            status: AiGenerationStatus.cancelled,
            errorCode: 'ai_brief_cancelled',
            errorMessage: 'AI Brief generation was cancelled.',
          ),
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
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(overview: value.trim(), edited: true),
      ),
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
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(chapters: chapters, edited: true),
      ),
    );
  }

  Future<void> deleteAiChapter(String jobId, String chapterId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(
          chapters: brief.chapters
              .where((item) => item.id != chapterId)
              .toList(),
          edited: true,
        ),
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
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(insights: insights, edited: true),
      ),
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
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(
          insights: [...brief.insights, insight],
          edited: true,
        ),
      ),
    );
  }

  Future<void> deleteAiInsight(String jobId, String insightId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(
          insights: brief.insights
              .where((item) => item.id != insightId)
              .toList(),
          edited: true,
        ),
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
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(languageNotes: notes, edited: true),
      ),
    );
  }

  Future<void> deleteAiLanguageNote(String jobId, String noteId) async {
    final job = _jobs[jobId];
    final brief = job?.aiBrief;
    if (job == null || brief == null) return;
    await _transition(
      job,
      (prior) => prior.copyWith(
        aiBrief: brief.copyWith(
          languageNotes: brief.languageNotes
              .where((item) => item.id != noteId)
              .toList(),
          edited: true,
        ),
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
    (prior) => prior.copyWith(
      aiGenerationState: job.aiGenerationState.copyWith(
        status: AiGenerationStatus.failed,
        errorCode: code,
        errorMessage: message,
      ),
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

  Future<SpeechEnergy?> loadSpeechEnergy(String jobId) async {
    final job = _jobs[jobId];
    if (job == null) return null;
    return _readSpeechEnergy(
      () => _media.analyzeSpeechEnergy(job.sourcePath, job.id),
    );
  }

  /// The speech energy of a file played outside the jobs.
  Future<SpeechEnergy?> loadFileSpeechEnergy(String path) =>
      _readSpeechEnergy(() => _media.analyzeFileSpeechEnergy(path));

  Future<SpeechEnergy?> _readSpeechEnergy(
    Future<String> Function() analyze,
  ) async {
    try {
      return SpeechEnergy(await File(await analyze()).readAsBytes());
    } on Object {
      return null;
    }
  }

  Future<void> _recover(List<TranscriptionJob> interrupted) async {
    if (interrupted.isEmpty) return;
    final resumable = <String>[];
    for (final job in interrupted) {
      if (job.remoteTranscriptionId != null &&
          isTranscriptionProviderConfigured(job.transcriptionProvider)) {
        resumable.add(job.id);
      } else {
        await _transition(
          job,
          (prior) => prior.copyWith(
            status: JobStatus.ready,
            progress: const JobProgress(stage: 'ready', fraction: 0),
            clearError: true,
          ),
        );
      }
    }
    if (resumable.isEmpty) return;
    _processing = true;
    notifyListeners();
    try {
      await _runWorkerPool(resumable);
    } finally {
      _processing = false;
      notifyListeners();
      _scheduleLocalAutoStart();
    }
  }

  Future<void> _retryPendingCleanup(List<TranscriptionJob> jobs) async {
    for (final job in jobs.where(
      (item) => item.cleanupState == CleanupState.pending,
    )) {
      if (!job.status.isActive &&
          isTranscriptionProviderConfigured(job.transcriptionProvider)) {
        await _cleanup(job);
      }
    }
  }

  Future<void> _cleanup(TranscriptionJob job) async {
    if (_isLocalProvider(job.transcriptionProvider)) return;
    if (job.cleanupState == CleanupState.complete) return;
    final client = _transcriptionClient(job.transcriptionProvider);
    var success = true;
    if (job.remoteTranscriptionId case final id?) {
      try {
        await client.deleteTranscription(id);
      } on Object {
        success = false;
      }
    }
    if (job.remoteFileId case final id?) {
      try {
        await client.deleteFile(id);
      } on Object {
        success = false;
      }
    }
    await _transition(
      _jobs[job.id] ?? job,
      (prior) => prior.copyWith(
        cleanupState: success ? CleanupState.complete : CleanupState.pending,
      ),
    );
  }

  Future<TranscriptionJob> _progress(
    String id,
    String stage,
    double? fraction,
    String? detail, {
    JobStatus? status,
  }) async {
    final job = _jobs[id];
    if (job == null) throw StateError('Job not found.');
    final effectiveFraction =
        fraction ??
        (job.progress.stage == stage ? job.progress.fraction : null);
    final progress = JobProgress(
      stage: stage,
      fraction: effectiveFraction,
      detail: detail,
    );
    // Downloads and uploads report every network chunk. Within a stage, keep
    // the latest value in memory and publish it at most once per interval so
    // progress does not rewrite the manifest and rebuild the UI per chunk.
    final sameStage =
        job.progress.stage == stage && (status == null || status == job.status);
    if (sameStage && _progressCooldowns.containsKey(id)) {
      final updated = job.copyWith(progress: progress);
      _jobs[id] = updated;
      _progressPending.add(id);
      return updated;
    }
    _startProgressCooldown(id);
    return _transition(
      job,
      (prior) => prior.copyWith(status: status, progress: progress),
    );
  }

  void _startProgressCooldown(String id) {
    _progressCooldowns[id]?.cancel();
    _progressCooldowns[id] = Timer(_progressPublishInterval, () {
      _progressCooldowns.remove(id);
      if (!_progressPending.remove(id)) return;
      final job = _jobs[id];
      if (job == null || _progressDisposed) return;
      _startProgressCooldown(id);
      _transition(job, (prior) => prior).then<void>(
        (_) {},
        onError: (Object error) {
          debugPrint('Unable to save job progress: $error');
        },
      );
    });
  }

  Future<TranscriptionJob> _fail(
    TranscriptionJob job,
    String code,
    String message, {
    JobStatus status = JobStatus.failed,
  }) => _transition(
    job,
    (prior) => prior.copyWith(
      status: status,
      errorCode: code,
      errorMessage: message,
      progress: const JobProgress(stage: 'failed'),
    ),
  );

  /// Deletes the media Listenook keeps on the job's behalf: a downloaded
  /// episode, or (iOS) the copy of an imported file no other job uses.
  Future<void> _deleteManagedMedia(TranscriptionJob job) async {
    await _deleteManagedPodcastAudio(job);
    await _releaseManagedImport(job);
  }

  Future<void> _releaseManagedImport(TranscriptionJob job) async {
    final store = _managedMedia;
    if (store == null || !store.owns(job.sourcePath)) return;
    bool inUse(String path) => _jobs.values.any(
      (other) =>
          other.id != job.id &&
          p.equals(p.normalize(other.sourcePath), p.normalize(path)),
    );
    if (inUse(job.sourcePath)) return;
    await store.release(job.sourcePath, inUse: inUse);
  }

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

  /// Stores [update] applied to the latest stored version of [job], then
  /// notifies listeners. A new document clears the job's structure-edit
  /// history unless [preserveTranscriptStructureHistory].
  Future<TranscriptionJob> _transition(
    TranscriptionJob job,
    TranscriptionJob Function(TranscriptionJob prior) update, {
    bool preserveTranscriptStructureHistory = false,
  }) async {
    // This save carries any progress held back by _progress.
    _progressPending.remove(job.id);
    final current = _jobs[job.id] ?? job;
    final updated = update(current);
    if (!preserveTranscriptStructureHistory &&
        !identical(updated.document, current.document)) {
      _structureHistories.remove(job.id);
    }
    _jobs[job.id] = updated;
    if (updated.document != null || updated.status.isTerminal) {
      _localAutoStartCandidates.remove(updated.id);
    }
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
    _scheduleLocalAutoStart();
    return updated;
  }

  Future<void> shutdown() async {
    if (!_monitorShutDown) {
      _monitorShutDown = true;
      await _inboxFolderMonitor?.dispose();
    }
    try {
      await _savePlaybackHistory();
    } on Object catch (error) {
      debugPrint('Unable to save playback history during shutdown: $error');
    }
    await _settingsSaveTail;
  }

  @override
  void dispose() {
    _progressDisposed = true;
    for (final timer in _progressCooldowns.values) {
      timer.cancel();
    }
    _progressCooldowns.clear();
    unawaited(shutdown());
    localModels.dispose();
    super.dispose();
  }
}

class _TranscriptStructureSnapshot {
  const _TranscriptStructureSnapshot({
    required this.document,
    required this.translationState,
    required this.forcedAlignment,
    required this.aiBrief,
  });

  factory _TranscriptStructureSnapshot.fromJob(TranscriptionJob job) =>
      _TranscriptStructureSnapshot(
        document: job.document!,
        translationState: job.translationState,
        forcedAlignment: job.forcedAlignment,
        aiBrief: job.aiBrief,
      );

  final TranscriptDocument document;
  final TranslationState translationState;
  final ForcedAlignmentState forcedAlignment;
  final AiBrief? aiBrief;
}

class _TranscriptStructureHistoryEntry {
  const _TranscriptStructureHistoryEntry({
    required this.before,
    required this.after,
  });

  final _TranscriptStructureSnapshot before;
  final _TranscriptStructureSnapshot after;
}

class _TranscriptStructureHistory {
  static const _limit = 50;

  final List<_TranscriptStructureHistoryEntry> undo = [];
  final List<_TranscriptStructureHistoryEntry> redo = [];

  void record(_TranscriptStructureHistoryEntry entry) {
    undo.add(entry);
    if (undo.length > _limit) undo.removeAt(0);
    redo.clear();
  }
}

/// Counts writes so derived views such as [AppController.allJobs] can be
/// cached until the jobs change.
class _JobMap extends MapBase<String, TranscriptionJob> {
  final Map<String, TranscriptionJob> _inner = {};
  int version = 0;

  @override
  TranscriptionJob? operator [](Object? key) => _inner[key];

  @override
  void operator []=(String key, TranscriptionJob value) {
    _inner[key] = value;
    version++;
  }

  @override
  void clear() {
    _inner.clear();
    version++;
  }

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  Iterable<TranscriptionJob> get values => _inner.values;

  @override
  int get length => _inner.length;

  @override
  bool containsKey(Object? key) => _inner.containsKey(key);

  @override
  TranscriptionJob? remove(Object? key) {
    final removed = _inner.remove(key);
    if (removed != null) version++;
    return removed;
  }
}

class _PermitPool {
  _PermitPool(this._capacity) : assert(_capacity > 0);

  final int _capacity;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> withPermit<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < _capacity) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    // _release hands its permit straight to this waiter, so _active already
    // counts it.
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}
