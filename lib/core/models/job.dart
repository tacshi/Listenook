import 'dart:convert';

import 'ai_brief.dart';
import 'inbox_monitor.dart';
import 'json.dart';
import 'transcript.dart';
import 'translation.dart';

const int manifestVersion = 15;
const int maxMediaDurationMs = 300 * 60 * 1000;

enum JobStatus {
  pending,
  probing,
  ready,
  downloading,
  converting,
  uploading,
  queuedRemote,
  processing,
  fetching,
  aligning,
  completed,
  empty,
  failed,
  cancelled,
  missingSource,
  paused,
}

extension JobStatusX on JobStatus {
  bool get isActive => switch (this) {
    JobStatus.probing ||
    JobStatus.downloading ||
    JobStatus.converting ||
    JobStatus.uploading ||
    JobStatus.queuedRemote ||
    JobStatus.processing ||
    JobStatus.fetching ||
    JobStatus.aligning => true,
    _ => false,
  };

  bool get isTerminal => switch (this) {
    JobStatus.completed ||
    JobStatus.empty ||
    JobStatus.failed ||
    JobStatus.cancelled ||
    JobStatus.missingSource => true,
    _ => false,
  };

  bool get canTranscribe => this == JobStatus.ready || this == JobStatus.paused;
  bool get canRetry =>
      this == JobStatus.failed ||
      this == JobStatus.cancelled ||
      this == JobStatus.missingSource ||
      this == JobStatus.empty;
}

enum CleanupState { none, pending, complete }

enum JobSourceOrigin { manual, monitoredFolder, podcast }

enum TranscriptionProvider { soniox, mossPro, mossLocal, qwen3Local }

enum ForcedAlignmentModel { qwen3CoreMlInt8, qwen3CoreMlFp16 }

enum TranscriptAcquisitionMode {
  soniox,
  mossPro,
  mossLocal,
  publisherCaptions,
  qwen3Local,
  importedSubtitles,
}

extension TranscriptAcquisitionModeX on TranscriptAcquisitionMode {
  bool get usesPublisherTranscript =>
      this == TranscriptAcquisitionMode.publisherCaptions;
}

class TranscriptionModelReference {
  const TranscriptionModelReference({required this.id, required this.revision});

  final String id;
  final String revision;

  Map<String, dynamic> toJson() => {'id': id, 'revision': revision};

  factory TranscriptionModelReference.fromJson(Map<String, dynamic> json) =>
      TranscriptionModelReference(
        id: json['id'] as String? ?? '',
        revision: json['revision'] as String? ?? '',
      );
}

enum ForcedAlignmentStatus {
  notRequested,
  queued,
  running,
  completed,
  partial,
  unavailable,
  failed,
  cancelled,
  interrupted,
}

class ForcedAlignmentState {
  const ForcedAlignmentState({
    this.status = ForcedAlignmentStatus.notRequested,
    this.modelId,
    this.modelRevision,
    this.alignedSegments = 0,
    this.totalSegments = 0,
    this.languageAutomaticallyDetermined = false,
    this.warningCode,
    this.warningMessage,
  });

  final ForcedAlignmentStatus status;
  final String? modelId;
  final String? modelRevision;
  final int alignedSegments;
  final int totalSegments;
  final bool languageAutomaticallyDetermined;
  final String? warningCode;
  final String? warningMessage;

  bool get hasWordTiming =>
      status == ForcedAlignmentStatus.completed ||
      status == ForcedAlignmentStatus.partial;

  bool get canRetry => switch (status) {
    ForcedAlignmentStatus.partial ||
    ForcedAlignmentStatus.unavailable ||
    ForcedAlignmentStatus.failed ||
    ForcedAlignmentStatus.cancelled ||
    ForcedAlignmentStatus.interrupted => true,
    _ => false,
  };

  bool get canRequest =>
      status == ForcedAlignmentStatus.notRequested || canRetry;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (modelId case final value?) 'model_id': value,
    if (modelRevision case final value?) 'model_revision': value,
    'aligned_segments': alignedSegments,
    'total_segments': totalSegments,
    if (languageAutomaticallyDetermined)
      'language_automatically_determined': true,
    if (warningCode case final value?) 'warning_code': value,
    if (warningMessage case final value?) 'warning_message': value,
  };

  factory ForcedAlignmentState.fromJson(Map<String, dynamic>? json) =>
      ForcedAlignmentState(
        status:
            enumByName(ForcedAlignmentStatus.values, json?['status']) ??
            ForcedAlignmentStatus.notRequested,
        modelId: json?['model_id'] as String?,
        modelRevision: json?['model_revision'] as String?,
        alignedSegments: (json?['aligned_segments'] as num?)?.toInt() ?? 0,
        totalSegments: (json?['total_segments'] as num?)?.toInt() ?? 0,
        languageAutomaticallyDetermined:
            json?['language_automatically_determined'] as bool? ?? false,
        warningCode: json?['warning_code'] as String?,
        warningMessage: json?['warning_message'] as String?,
      );
}

enum PodcastTranscriptTiming { none, cue, word }

class PodcastTranscriptReference {
  const PodcastTranscriptReference({
    required this.url,
    this.type,
    this.language,
    this.rel,
  });

  final String url;
  final String? type;
  final String? language;
  final String? rel;

  Map<String, dynamic> toJson() => {
    'url': url,
    if (type case final value?) 'type': value,
    if (language case final value?) 'language': value,
    if (rel case final value?) 'rel': value,
  };

  factory PodcastTranscriptReference.fromJson(Map<String, dynamic> json) =>
      PodcastTranscriptReference(
        url: json['url'] as String? ?? '',
        type: json['type'] as String?,
        language: json['language'] as String?,
        rel: json['rel'] as String?,
      );
}

class PodcastEpisodeProvenance {
  const PodcastEpisodeProvenance({
    required this.feedUrl,
    required this.episodeId,
    required this.enclosureUrl,
    required this.showTitle,
    required this.episodeTitle,
    this.guid,
    this.author,
    this.artworkUrl,
    this.showUrl,
    this.publishedAt,
    this.language,
    this.description,
    this.episodeUrl,
    this.transcripts = const [],
    this.transcriptTiming = PodcastTranscriptTiming.none,
  });

  final String feedUrl;
  final String episodeId;
  final String enclosureUrl;
  final String showTitle;
  final String episodeTitle;
  final String? guid;
  final String? author;
  final String? artworkUrl;
  final String? showUrl;
  final DateTime? publishedAt;
  final String? language;
  final String? description;
  final String? episodeUrl;
  final List<PodcastTranscriptReference> transcripts;
  final PodcastTranscriptTiming transcriptTiming;

  String get displayName {
    final show = showTitle.trim();
    final episode = episodeTitle.trim();
    if (show.isEmpty) return episode;
    if (episode.isEmpty) return show;
    return '$show · $episode';
  }

  Map<String, dynamic> toJson() => {
    'feed_url': feedUrl,
    'episode_id': episodeId,
    'enclosure_url': enclosureUrl,
    'show_title': showTitle,
    'episode_title': episodeTitle,
    if (guid case final value?) 'guid': value,
    if (author case final value?) 'author': value,
    if (artworkUrl case final value?) 'artwork_url': value,
    if (showUrl case final value?) 'show_url': value,
    if (publishedAt case final value?)
      'published_at': value.toUtc().toIso8601String(),
    if (language case final value?) 'language': value,
    if (description case final value?) 'description': value,
    if (episodeUrl case final value?) 'episode_url': value,
    if (transcripts.isNotEmpty)
      'transcripts': transcripts.map((item) => item.toJson()).toList(),
    'transcript_timing': transcriptTiming.name,
  };

  factory PodcastEpisodeProvenance.fromJson(Map<String, dynamic> json) =>
      PodcastEpisodeProvenance(
        feedUrl: json['feed_url'] as String? ?? '',
        episodeId: json['episode_id'] as String? ?? '',
        enclosureUrl: json['enclosure_url'] as String? ?? '',
        showTitle: json['show_title'] as String? ?? '',
        episodeTitle: json['episode_title'] as String? ?? '',
        guid: json['guid'] as String?,
        author: json['author'] as String?,
        artworkUrl: json['artwork_url'] as String?,
        showUrl: json['show_url'] as String?,
        publishedAt: dateFromJson(json['published_at']),
        language: json['language'] as String?,
        description: json['description'] as String?,
        episodeUrl: json['episode_url'] as String?,
        transcripts: mapJsonList(
          json['transcripts'],
          PodcastTranscriptReference.fromJson,
        ),
        transcriptTiming:
            enumByName(
              PodcastTranscriptTiming.values,
              json['transcript_timing'],
            ) ??
            PodcastTranscriptTiming.none,
      );

  PodcastEpisodeProvenance copyWith({
    PodcastTranscriptTiming? transcriptTiming,
    String? description,
    String? episodeUrl,
  }) => PodcastEpisodeProvenance(
    feedUrl: feedUrl,
    episodeId: episodeId,
    enclosureUrl: enclosureUrl,
    showTitle: showTitle,
    episodeTitle: episodeTitle,
    guid: guid,
    author: author,
    artworkUrl: artworkUrl,
    showUrl: showUrl,
    publishedAt: publishedAt,
    language: language,
    description: description ?? this.description,
    episodeUrl: episodeUrl ?? this.episodeUrl,
    transcripts: transcripts,
    transcriptTiming: transcriptTiming ?? this.transcriptTiming,
  );
}

class ImportedSubtitleProvenance {
  const ImportedSubtitleProvenance({
    required this.sourcePath,
    required this.displayName,
    required this.format,
    required this.importedAt,
    this.sourceFingerprint,
  });

  final String sourcePath;
  final String displayName;
  final SubtitleFormat format;
  final DateTime importedAt;
  final SourceFingerprint? sourceFingerprint;

  ImportedSubtitleProvenance copyWith() => this;

  Map<String, dynamic> toJson() => {
    'source_path': sourcePath,
    'display_name': displayName,
    'format': format.name,
    'imported_at': importedAt.toUtc().toIso8601String(),
    if (sourceFingerprint case final value?)
      'source_fingerprint': value.toJson(),
  };

  factory ImportedSubtitleProvenance.fromJson(Map<String, dynamic> json) =>
      ImportedSubtitleProvenance(
        sourcePath: json['source_path'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        format:
            enumByName(SubtitleFormat.values, json['format']) ??
            SubtitleFormat.srt,
        importedAt: dateFromJson(json['imported_at']) ?? DateTime.now().toUtc(),
        sourceFingerprint: json['source_fingerprint'] is Map
            ? SourceFingerprint.fromJson(
                (json['source_fingerprint'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
}

class JobProgress {
  const JobProgress({required this.stage, this.fraction, this.detail});

  const JobProgress.idle() : this(stage: 'pending');

  final String stage;
  final double? fraction;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'stage': stage,
    if (fraction case final value?) 'fraction': value,
    if (detail case final value?) 'detail': value,
  };

  factory JobProgress.fromJson(Map<String, dynamic>? json) => JobProgress(
    stage: json?['stage'] as String? ?? 'pending',
    fraction: (json?['fraction'] as num?)?.toDouble(),
    detail: json?['detail'] as String?,
  );
}

class TranscriptionOptions {
  const TranscriptionOptions({
    this.languageHints = const [],
    this.contextTerms = const [],
    this.sonioxTranslation = const SonioxTranslationOptions(),
  });

  final List<String> languageHints;
  final List<String> contextTerms;
  final SonioxTranslationOptions sonioxTranslation;

  TranscriptionOptions copyWith({
    List<String>? languageHints,
    List<String>? contextTerms,
    SonioxTranslationOptions? sonioxTranslation,
  }) => TranscriptionOptions(
    languageHints: languageHints ?? this.languageHints,
    contextTerms: contextTerms ?? this.contextTerms,
    sonioxTranslation: sonioxTranslation ?? this.sonioxTranslation,
  );

  Map<String, dynamic> toJson() => {
    'language_hints': languageHints,
    'context_terms': contextTerms,
    'soniox_translation': sonioxTranslation.toJson(),
    'enable_speaker_diarization': true,
    'enable_language_identification': true,
  };

  factory TranscriptionOptions.fromJson(Map<String, dynamic>? json) =>
      TranscriptionOptions(
        languageHints: jsonStrings(json?['language_hints']),
        contextTerms: jsonStrings(json?['context_terms']),
        sonioxTranslation: SonioxTranslationOptions.fromJson(
          (json?['soniox_translation'] as Map?)?.cast<String, dynamic>(),
        ),
      );
}

class TranscriptionJob {
  const TranscriptionJob({
    required this.id,
    required this.batchId,
    required this.sourcePath,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.queueIndex = 0,
    this.progress = const JobProgress.idle(),
    this.metadata,
    this.options = const TranscriptionOptions(),
    this.document,
    this.errorCode,
    this.errorMessage,
    this.remoteFileId,
    this.remoteTranscriptionId,
    this.cleanupState = CleanupState.none,
    this.translationOptions = const TranslationOptions(),
    this.translationState = const TranslationState(),
    this.aiBrief,
    this.aiGenerationState = const AiGenerationState(),
    this.displayTitle,
    this.groupId,
    this.tagIds = const {},
    this.sourceOrigin = JobSourceOrigin.manual,
    this.sourceFingerprint,
    this.podcastProvenance,
    this.importedSubtitleProvenance,
    this.transcriptionProvider = TranscriptionProvider.soniox,
    TranscriptAcquisitionMode? transcriptAcquisitionMode,
    this.transcriptSource,
    this.transcriptionModel,
    this.forcedAlignment = const ForcedAlignmentState(),
  }) : transcriptAcquisitionMode =
           transcriptAcquisitionMode ??
           (transcriptionProvider == TranscriptionProvider.mossPro
               ? TranscriptAcquisitionMode.mossPro
               : transcriptionProvider == TranscriptionProvider.mossLocal
               ? TranscriptAcquisitionMode.mossLocal
               : transcriptionProvider == TranscriptionProvider.qwen3Local
               ? TranscriptAcquisitionMode.qwen3Local
               : TranscriptAcquisitionMode.soniox);

  final String id;
  final String batchId;
  final String sourcePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final JobStatus status;
  final int queueIndex;
  final JobProgress progress;
  final MediaMetadata? metadata;
  final TranscriptionOptions options;
  final TranscriptDocument? document;
  final String? errorCode;
  final String? errorMessage;
  final String? remoteFileId;
  final String? remoteTranscriptionId;
  final CleanupState cleanupState;
  final TranslationOptions translationOptions;
  final TranslationState translationState;
  final AiBrief? aiBrief;
  final AiGenerationState aiGenerationState;
  final String? displayTitle;
  final String? groupId;
  final Set<String> tagIds;
  final JobSourceOrigin sourceOrigin;
  final SourceFingerprint? sourceFingerprint;
  final PodcastEpisodeProvenance? podcastProvenance;
  final ImportedSubtitleProvenance? importedSubtitleProvenance;
  final TranscriptAcquisitionMode transcriptAcquisitionMode;
  final TranscriptionProvider transcriptionProvider;
  final TranscriptSource? transcriptSource;
  final TranscriptionModelReference? transcriptionModel;
  final ForcedAlignmentState forcedAlignment;

  bool get usesImportedSubtitles =>
      transcriptAcquisitionMode ==
          TranscriptAcquisitionMode.importedSubtitles ||
      transcriptSource == TranscriptSource.importedSubtitle;

  bool get supportsLocalWordAlignment =>
      !usesImportedSubtitles &&
      (transcriptSource == TranscriptSource.mossPro ||
          transcriptSource == TranscriptSource.mossLocal ||
          transcriptSource == TranscriptSource.qwen3Local ||
          transcriptionProvider == TranscriptionProvider.mossPro ||
          transcriptionProvider == TranscriptionProvider.mossLocal ||
          transcriptionProvider == TranscriptionProvider.qwen3Local);

  bool get isBusy =>
      status.isActive ||
      translationState.status.isActive ||
      aiGenerationState.status.isActive;

  String get fileName => sourcePath.replaceAll('\\', '/').split('/').last;
  String get displayName {
    final title = displayTitle?.trim();
    return title == null || title.isEmpty ? fileName : title;
  }

  TranscriptionJob copyWith({
    String? sourcePath,
    JobStatus? status,
    int? queueIndex,
    JobProgress? progress,
    MediaMetadata? metadata,
    TranscriptionOptions? options,
    TranscriptDocument? document,
    String? errorCode,
    String? errorMessage,
    String? remoteFileId,
    String? remoteTranscriptionId,
    CleanupState? cleanupState,
    TranslationOptions? translationOptions,
    TranslationState? translationState,
    AiBrief? aiBrief,
    AiGenerationState? aiGenerationState,
    String? displayTitle,
    String? groupId,
    Set<String>? tagIds,
    JobSourceOrigin? sourceOrigin,
    SourceFingerprint? sourceFingerprint,
    PodcastEpisodeProvenance? podcastProvenance,
    ImportedSubtitleProvenance? importedSubtitleProvenance,
    TranscriptAcquisitionMode? transcriptAcquisitionMode,
    TranscriptionProvider? transcriptionProvider,
    TranscriptSource? transcriptSource,
    TranscriptionModelReference? transcriptionModel,
    ForcedAlignmentState? forcedAlignment,
    bool clearError = false,
    bool clearRemoteFileId = false,
    bool clearRemoteTranscriptionId = false,
    bool clearAiBrief = false,
    bool clearDisplayTitle = false,
    bool clearGroupId = false,
    bool clearTranscriptionModel = false,
  }) => TranscriptionJob(
    id: id,
    batchId: batchId,
    sourcePath: sourcePath ?? this.sourcePath,
    createdAt: createdAt,
    updatedAt: DateTime.now().toUtc(),
    status: status ?? this.status,
    queueIndex: queueIndex ?? this.queueIndex,
    progress: progress ?? this.progress,
    metadata: metadata ?? this.metadata,
    options: options ?? this.options,
    document: document ?? this.document,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    remoteFileId: clearRemoteFileId ? null : remoteFileId ?? this.remoteFileId,
    remoteTranscriptionId: clearRemoteTranscriptionId
        ? null
        : remoteTranscriptionId ?? this.remoteTranscriptionId,
    cleanupState: cleanupState ?? this.cleanupState,
    translationOptions: translationOptions ?? this.translationOptions,
    translationState: translationState ?? this.translationState,
    aiBrief: clearAiBrief ? null : aiBrief ?? this.aiBrief,
    aiGenerationState: aiGenerationState ?? this.aiGenerationState,
    displayTitle: clearDisplayTitle ? null : displayTitle ?? this.displayTitle,
    groupId: clearGroupId ? null : groupId ?? this.groupId,
    tagIds: tagIds ?? this.tagIds,
    sourceOrigin: sourceOrigin ?? this.sourceOrigin,
    sourceFingerprint: sourceFingerprint ?? this.sourceFingerprint,
    podcastProvenance: podcastProvenance ?? this.podcastProvenance,
    importedSubtitleProvenance:
        importedSubtitleProvenance ?? this.importedSubtitleProvenance,
    transcriptAcquisitionMode:
        transcriptAcquisitionMode ?? this.transcriptAcquisitionMode,
    transcriptionProvider: transcriptionProvider ?? this.transcriptionProvider,
    transcriptSource: transcriptSource ?? this.transcriptSource,
    transcriptionModel: clearTranscriptionModel
        ? null
        : transcriptionModel ?? this.transcriptionModel,
    forcedAlignment: forcedAlignment ?? this.forcedAlignment,
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'id': id,
    'batch_id': batchId,
    'source_path': sourcePath,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'status': status.name,
    'queue_index': queueIndex,
    'progress': progress.toJson(),
    if (metadata case final value?) 'metadata': value.toJson(),
    'options': options.toJson(),
    if (document case final value?) 'document': value.toJson(),
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
    if (remoteFileId case final value?) 'remote_file_id': value,
    if (remoteTranscriptionId case final value?)
      'remote_transcription_id': value,
    'cleanup_state': cleanupState.name,
    'translation_options': translationOptions.toJson(),
    'translation_state': translationState.toJson(),
    if (aiBrief case final value?) 'ai_brief': value.toJson(),
    'ai_generation_state': aiGenerationState.toJson(),
    if (displayTitle case final value?) 'display_title': value,
    if (groupId case final value?) 'group_id': value,
    if (tagIds.isNotEmpty) 'tag_ids': tagIds.toList()..sort(),
    'source_origin': sourceOrigin.name,
    if (sourceFingerprint case final value?)
      'source_fingerprint': value.toJson(),
    if (podcastProvenance case final value?)
      'podcast_provenance': value.toJson(),
    if (importedSubtitleProvenance case final value?)
      'imported_subtitle_provenance': value.toJson(),
    'transcript_acquisition_mode': transcriptAcquisitionMode.name,
    'transcription_provider': transcriptionProvider.name,
    if (transcriptSource case final value?) 'transcript_source': value.name,
    if (transcriptionModel case final value?)
      'transcription_model': value.toJson(),
    'forced_alignment': forcedAlignment.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  factory TranscriptionJob.fromJson(Map<String, dynamic> json) {
    final status =
        enumByName(JobStatus.values, json['status']) ?? JobStatus.pending;
    return TranscriptionJob(
      id: json['id'] as String,
      batchId: json['batch_id'] as String? ?? 'recovered',
      sourcePath: json['source_path'] as String,
      createdAt: dateFromJson(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: dateFromJson(json['updated_at']) ?? DateTime.now().toUtc(),
      status: status,
      queueIndex: (json['queue_index'] as num?)?.toInt() ?? 0,
      progress: JobProgress.fromJson(
        (json['progress'] as Map?)?.cast<String, dynamic>(),
      ),
      metadata: json['metadata'] is Map
          ? MediaMetadata.fromJson(
              (json['metadata'] as Map).cast<String, dynamic>(),
            )
          : null,
      options: TranscriptionOptions.fromJson(
        (json['options'] as Map?)?.cast<String, dynamic>(),
      ),
      document: json['document'] is Map
          ? TranscriptDocument.fromJson(
              (json['document'] as Map).cast<String, dynamic>(),
            )
          : null,
      errorCode: json['error_code'] as String?,
      errorMessage: json['error_message'] as String?,
      remoteFileId: json['remote_file_id'] as String?,
      remoteTranscriptionId: json['remote_transcription_id'] as String?,
      cleanupState:
          enumByName(CleanupState.values, json['cleanup_state']) ??
          CleanupState.none,
      translationOptions: TranslationOptions.fromJson(
        (json['translation_options'] as Map?)?.cast<String, dynamic>(),
      ),
      translationState: TranslationState.fromJson(
        (json['translation_state'] as Map?)?.cast<String, dynamic>(),
      ),
      aiBrief: json['ai_brief'] is Map
          ? AiBrief.fromJson((json['ai_brief'] as Map).cast<String, dynamic>())
          : null,
      aiGenerationState: AiGenerationState.fromJson(
        (json['ai_generation_state'] as Map?)?.cast<String, dynamic>(),
      ),
      displayTitle: switch (json['display_title']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      groupId: switch (json['group_id']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      tagIds: jsonStrings(
        json['tag_ids'],
      ).map((value) => value.trim()).where((value) => value.isNotEmpty).toSet(),
      sourceOrigin:
          enumByName(JobSourceOrigin.values, json['source_origin']) ??
          JobSourceOrigin.manual,
      sourceFingerprint: json['source_fingerprint'] is Map
          ? SourceFingerprint.fromJson(
              (json['source_fingerprint'] as Map).cast<String, dynamic>(),
            )
          : null,
      podcastProvenance: json['podcast_provenance'] is Map
          ? PodcastEpisodeProvenance.fromJson(
              (json['podcast_provenance'] as Map).cast<String, dynamic>(),
            )
          : null,
      importedSubtitleProvenance: json['imported_subtitle_provenance'] is Map
          ? ImportedSubtitleProvenance.fromJson(
              (json['imported_subtitle_provenance'] as Map)
                  .cast<String, dynamic>(),
            )
          : null,
      transcriptAcquisitionMode: transcriptAcquisitionModeFromJson(
        json['transcript_acquisition_mode'],
      ),
      transcriptionProvider: transcriptionProviderFromJson(
        json['transcription_provider'],
        json['transcript_acquisition_mode'],
      ),
      transcriptSource: enumByName(
        TranscriptSource.values,
        json['transcript_source'],
      ),
      transcriptionModel: json['transcription_model'] is Map
          ? TranscriptionModelReference.fromJson(
              (json['transcription_model'] as Map).cast<String, dynamic>(),
            )
          : null,
      forcedAlignment: ForcedAlignmentState.fromJson(
        (json['forced_alignment'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

class BatchSession {
  const BatchSession({
    required this.id,
    required this.jobIds,
    required this.createdAt,
  });

  final String id;
  final List<String> jobIds;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'job_ids': jobIds,
    'created_at': createdAt.toIso8601String(),
  };
}
