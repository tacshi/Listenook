import 'dart:convert';

const int manifestVersion = 15;
const int maxMediaDurationMs = 300 * 60 * 1000;

const Set<String> supportedMonitoredMediaExtensions = {
  'mp3',
  'wav',
  'm4a',
  'ogg',
  'mp4',
  'mkv',
  'avi',
};

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

enum ExportFormat { txt, markdown, srt, webVtt }

enum ExportContentMode { original, translated, bilingual }

enum TranslationViewMode { original, translated, bilingual }

enum TranslationOrigin { soniox, llm }

enum TranslationProviderTemplate {
  custom,
  openAi,
  openRouter,
  deepSeek,
  groq,
  nvidiaNim,
  togetherAi,
  mistralAi,
  lmStudio,
  ollama,
  fireworksAi,
  perplexity,
  volcengineArk,
}

extension TranslationProviderTemplateX on TranslationProviderTemplate {
  String get defaultBaseUrl => switch (this) {
    TranslationProviderTemplate.custom => '',
    TranslationProviderTemplate.openAi => 'https://api.openai.com/v1',
    TranslationProviderTemplate.openRouter => 'https://openrouter.ai/api/v1',
    TranslationProviderTemplate.deepSeek => 'https://api.deepseek.com/v1',
    TranslationProviderTemplate.groq => 'https://api.groq.com/openai/v1',
    TranslationProviderTemplate.nvidiaNim =>
      'https://integrate.api.nvidia.com/v1',
    TranslationProviderTemplate.togetherAi => 'https://api.together.xyz/v1',
    TranslationProviderTemplate.mistralAi => 'https://api.mistral.ai/v1',
    TranslationProviderTemplate.lmStudio => 'http://localhost:1234/v1',
    TranslationProviderTemplate.ollama => 'http://localhost:11434/v1',
    TranslationProviderTemplate.fireworksAi =>
      'https://api.fireworks.ai/inference/v1',
    TranslationProviderTemplate.perplexity => 'https://api.perplexity.ai',
    TranslationProviderTemplate.volcengineArk =>
      'https://ark.cn-beijing.volces.com/api/v3',
  };

  static TranslationProviderTemplate inferFromBaseUrl(String baseUrl) {
    final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    for (final template in TranslationProviderTemplate.values) {
      if (template == TranslationProviderTemplate.custom) continue;
      if (template.defaultBaseUrl == normalized) return template;
    }
    return TranslationProviderTemplate.custom;
  }
}

enum TranslationStatus {
  idle,
  translating,
  completed,
  partial,
  failed,
  cancelled,
  interrupted,
}

enum AiBriefSection {
  overview,
  chapters,
  keyIdeas,
  decisions,
  actionItems,
  openQuestions,
  languageNotes,
}

const defaultAiBriefSections = <AiBriefSection>{
  AiBriefSection.overview,
  AiBriefSection.chapters,
  AiBriefSection.keyIdeas,
  AiBriefSection.decisions,
  AiBriefSection.actionItems,
  AiBriefSection.openQuestions,
};

enum AiInsightType {
  keyIdea,
  notableMoment,
  decision,
  actionItem,
  openQuestion,
}

enum AiLearningLevel { beginner, intermediate, advanced }

enum AiLanguageNoteKind { vocabulary, expression, grammar }

enum AiGenerationStatus {
  idle,
  generating,
  completed,
  failed,
  cancelled,
  interrupted,
}

extension AiGenerationStatusX on AiGenerationStatus {
  bool get isActive => this == AiGenerationStatus.generating;
  bool get canRetry =>
      this == AiGenerationStatus.failed ||
      this == AiGenerationStatus.cancelled ||
      this == AiGenerationStatus.interrupted;
}

extension TranslationStatusX on TranslationStatus {
  bool get isActive => this == TranslationStatus.translating;
  bool get canRetry =>
      this == TranslationStatus.partial ||
      this == TranslationStatus.failed ||
      this == TranslationStatus.cancelled ||
      this == TranslationStatus.interrupted;
}

enum AppThemeMode { system, light, dark }

enum AppLocaleMode { system, english, simplifiedChinese }

enum AppContentDestination { podcast, workspace, library }

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

enum TranscriptSource {
  soniox,
  mossPro,
  mossLocal,
  publisher,
  qwen3Local,
  importedSubtitle,
}

enum SubtitleFormat { srt, webVtt }

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
            _enumByName(ForcedAlignmentStatus.values, json?['status']) ??
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
        publishedAt: _date(json['published_at']),
        language: json['language'] as String?,
        description: json['description'] as String?,
        episodeUrl: json['episode_url'] as String?,
        transcripts: _mapList(
          json['transcripts'],
          PodcastTranscriptReference.fromJson,
        ),
        transcriptTiming:
            _enumByName(
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
            _enumByName(SubtitleFormat.values, json['format']) ??
            SubtitleFormat.srt,
        importedAt: _date(json['imported_at']) ?? DateTime.now().toUtc(),
        sourceFingerprint: json['source_fingerprint'] is Map
            ? SourceFingerprint.fromJson(
                (json['source_fingerprint'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
}

enum InboxMonitorStatus {
  unconfigured,
  scanning,
  active,
  paused,
  unavailable,
  error,
}

enum MonitoredFileDisposition { queued, completed, dismissed }

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

class MediaMetadata {
  const MediaMetadata({
    required this.sizeBytes,
    required this.durationMs,
    required this.hasAudio,
    required this.hasVideo,
    required this.formatName,
    this.audioCodec,
    this.videoCodec,
  });

  final int sizeBytes;
  final int durationMs;
  final bool hasAudio;
  final bool hasVideo;
  final String formatName;
  final String? audioCodec;
  final String? videoCodec;

  Map<String, dynamic> toJson() => {
    'size_bytes': sizeBytes,
    'duration_ms': durationMs,
    'has_audio': hasAudio,
    'has_video': hasVideo,
    'format_name': formatName,
    if (audioCodec case final value?) 'audio_codec': value,
    if (videoCodec case final value?) 'video_codec': value,
  };

  factory MediaMetadata.fromJson(Map<String, dynamic> json) => MediaMetadata(
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    hasAudio: json['has_audio'] as bool? ?? false,
    hasVideo: json['has_video'] as bool? ?? false,
    formatName: json['format_name'] as String? ?? 'unknown',
    audioCodec: json['audio_codec'] as String?,
    videoCodec: json['video_codec'] as String?,
  );
}

class TranscriptToken {
  const TranscriptToken({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.segmentId,
    this.speaker,
    this.language,
    this.confidence,
    this.translationStatus,
    this.sourceLanguage,
  });

  final String text;
  final int startMs;
  final int endMs;
  final String? segmentId;
  final String? speaker;
  final String? language;
  final double? confidence;
  final String? translationStatus;
  final String? sourceLanguage;

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_ms': startMs,
    'end_ms': endMs,
    if (segmentId case final value?) 'segment_id': value,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (confidence case final value?) 'confidence': value,
    if (translationStatus case final value?) 'translation_status': value,
    if (sourceLanguage case final value?) 'source_language': value,
  };

  factory TranscriptToken.fromJson(Map<String, dynamic> json) =>
      TranscriptToken(
        text: json['text'] as String? ?? '',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        segmentId: json['segment_id'] as String?,
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
        translationStatus: json['translation_status'] as String?,
        sourceLanguage: json['source_language'] as String?,
      );
}

class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speaker,
    this.language,
    this.translatedText,
    this.preserveBoundaryBefore = false,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String? speaker;
  final String? language;
  final String? translatedText;
  final bool preserveBoundaryBefore;

  bool get hasTranslation => translatedText?.trim().isNotEmpty ?? false;

  TranscriptSegment copyWith({
    int? startMs,
    int? endMs,
    String? text,
    String? speaker,
    String? language,
    String? translatedText,
    bool clearTranslatedText = false,
    bool? preserveBoundaryBefore,
  }) => TranscriptSegment(
    id: id,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    language: language ?? this.language,
    translatedText: clearTranslatedText
        ? null
        : translatedText ?? this.translatedText,
    preserveBoundaryBefore:
        preserveBoundaryBefore ?? this.preserveBoundaryBefore,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'start_ms': startMs,
    'end_ms': endMs,
    'text': text,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (translatedText case final value?) 'translated_text': value,
    if (preserveBoundaryBefore) 'preserve_boundary_before': true,
  };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        id: json['id'] as String? ?? '${json['start_ms'] ?? 0}',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
        translatedText: json['translated_text'] as String?,
        preserveBoundaryBefore:
            json['preserve_boundary_before'] as bool? ?? false,
      );
}

class SpeakerProfile {
  const SpeakerProfile({required this.id, required this.name});
  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory SpeakerProfile.fromJson(Map<String, dynamic> json) => SpeakerProfile(
    id: json['id'].toString(),
    name: json['name'] as String? ?? 'Speaker ${json['id']}',
  );
}

class TranscriptDocument {
  const TranscriptDocument({
    required this.tokens,
    required this.segments,
    required this.speakers,
    required this.updatedAt,
  });

  final List<TranscriptToken> tokens;
  final List<TranscriptSegment> segments;
  final List<SpeakerProfile> speakers;
  final DateTime updatedAt;

  String speakerName(String? id) {
    if (id == null || id.isEmpty) return '';
    return speakers
            .where((profile) => profile.id == id)
            .map((profile) => profile.name)
            .firstOrNull ??
        'Speaker $id';
  }

  TranscriptDocument copyWith({
    List<TranscriptToken>? tokens,
    List<TranscriptSegment>? segments,
    List<SpeakerProfile>? speakers,
    bool preserveUpdatedAt = false,
  }) => TranscriptDocument(
    tokens: tokens ?? this.tokens,
    segments: segments ?? this.segments,
    speakers: speakers ?? this.speakers,
    updatedAt: preserveUpdatedAt ? updatedAt : DateTime.now().toUtc(),
  );

  Map<String, dynamic> toJson() => {
    'tokens': tokens.map((item) => item.toJson()).toList(),
    'segments': segments.map((item) => item.toJson()).toList(),
    'speakers': speakers.map((item) => item.toJson()).toList(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory TranscriptDocument.fromJson(Map<String, dynamic> json) =>
      TranscriptDocument(
        tokens: _mapList(json['tokens'], TranscriptToken.fromJson),
        segments: _mapList(json['segments'], TranscriptSegment.fromJson),
        speakers: _mapList(json['speakers'], SpeakerProfile.fromJson),
        updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
      );
}

class SonioxTranslationOptions {
  const SonioxTranslationOptions({
    this.enabled = false,
    this.targetLanguage = '',
  });

  final bool enabled;
  final String targetLanguage;

  String? validationError() {
    if (!enabled) return null;
    if (!supportedSonioxTranslationLanguageCodes.contains(targetLanguage)) {
      return 'soniox_translation_invalid_language';
    }
    return null;
  }

  SonioxTranslationOptions copyWith({bool? enabled, String? targetLanguage}) =>
      SonioxTranslationOptions(
        enabled: enabled ?? this.enabled,
        targetLanguage: targetLanguage ?? this.targetLanguage,
      );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'target_language': targetLanguage,
  };

  factory SonioxTranslationOptions.fromJson(Map<String, dynamic>? json) =>
      SonioxTranslationOptions(
        enabled: json?['enabled'] as bool? ?? false,
        targetLanguage: json?['target_language'] as String? ?? '',
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
        languageHints: _strings(json?['language_hints']),
        contextTerms: _strings(json?['context_terms']),
        sonioxTranslation: SonioxTranslationOptions.fromJson(
          (json?['soniox_translation'] as Map?)?.cast<String, dynamic>(),
        ),
      );
}

class TranslationSettings {
  const TranslationSettings({
    this.provider = TranslationProviderTemplate.custom,
    this.baseUrl = '',
    this.model = '',
    this.targetLanguage = '',
    this.autoTranslate = false,
  });

  final TranslationProviderTemplate provider;
  final String baseUrl;
  final String model;
  final String targetLanguage;
  final bool autoTranslate;

  Uri? get uri => Uri.tryParse(baseUrl.trim());

  bool get isLoopback {
    final host = uri?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool get requiresApiKey => !isLoopback;

  String? validationError({bool requireModel = true}) {
    final value = uri;
    if (value == null ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      return 'translation_invalid_url';
    }
    if (value.scheme != 'http' && value.scheme != 'https') {
      return 'translation_invalid_url';
    }
    if (!isLoopback && value.scheme != 'https') {
      return 'translation_https_required';
    }
    if (requireModel && model.trim().isEmpty) {
      return 'translation_model_required';
    }
    return null;
  }

  bool isConfigured({required bool hasApiKey}) =>
      validationError() == null && (!requiresApiKey || hasApiKey);

  TranslationSettings copyWith({
    TranslationProviderTemplate? provider,
    String? baseUrl,
    String? model,
    String? targetLanguage,
    bool? autoTranslate,
  }) => TranslationSettings(
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    autoTranslate: autoTranslate ?? this.autoTranslate,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'base_url': baseUrl,
    'model': model,
    'target_language': targetLanguage,
    'auto_translate': autoTranslate,
  };

  factory TranslationSettings.fromJson(Map<String, dynamic>? json) {
    final baseUrl = json?['base_url'] as String? ?? '';
    final provider =
        _enumByName(TranslationProviderTemplate.values, json?['provider']) ??
        TranslationProviderTemplateX.inferFromBaseUrl(baseUrl);
    return TranslationSettings(
      provider: provider,
      baseUrl: baseUrl,
      model: json?['model'] as String? ?? '',
      targetLanguage: json?['target_language'] as String? ?? '',
      autoTranslate: json?['auto_translate'] as bool? ?? false,
    );
  }

  factory TranslationSettings.fromParts(
    LlmProviderSettings provider,
    TranslationPreferences preferences,
  ) => TranslationSettings(
    provider: provider.provider,
    baseUrl: provider.baseUrl,
    model: provider.model,
    targetLanguage: preferences.targetLanguage,
    autoTranslate: preferences.autoTranslate,
  );

  LlmProviderSettings get providerSettings =>
      LlmProviderSettings(provider: provider, baseUrl: baseUrl, model: model);

  TranslationPreferences get preferences => TranslationPreferences(
    targetLanguage: targetLanguage,
    autoTranslate: autoTranslate,
  );
}

class LlmProviderSettings {
  const LlmProviderSettings({
    this.provider = TranslationProviderTemplate.custom,
    this.baseUrl = '',
    this.model = '',
  });

  final TranslationProviderTemplate provider;
  final String baseUrl;
  final String model;

  Uri? get uri => Uri.tryParse(baseUrl.trim());

  bool get isLoopback {
    final host = uri?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool get requiresApiKey => !isLoopback;

  String? validationError({bool requireModel = true}) {
    final value = uri;
    if (value == null ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      return 'translation_invalid_url';
    }
    if (value.scheme != 'http' && value.scheme != 'https') {
      return 'translation_invalid_url';
    }
    if (!isLoopback && value.scheme != 'https') {
      return 'translation_https_required';
    }
    if (requireModel && model.trim().isEmpty) {
      return 'translation_model_required';
    }
    return null;
  }

  bool isConfigured({required bool hasApiKey}) =>
      validationError() == null && (!requiresApiKey || hasApiKey);

  LlmProviderSettings copyWith({
    TranslationProviderTemplate? provider,
    String? baseUrl,
    String? model,
  }) => LlmProviderSettings(
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'base_url': baseUrl,
    'model': model,
  };

  factory LlmProviderSettings.fromJson(Map<String, dynamic>? json) {
    final baseUrl = json?['base_url'] as String? ?? '';
    return LlmProviderSettings(
      provider:
          _enumByName(TranslationProviderTemplate.values, json?['provider']) ??
          TranslationProviderTemplateX.inferFromBaseUrl(baseUrl),
      baseUrl: baseUrl,
      model: json?['model'] as String? ?? '',
    );
  }
}

class TranslationPreferences {
  const TranslationPreferences({
    this.targetLanguage = '',
    this.autoTranslate = false,
  });

  final String targetLanguage;
  final bool autoTranslate;

  TranslationPreferences copyWith({
    String? targetLanguage,
    bool? autoTranslate,
  }) => TranslationPreferences(
    targetLanguage: targetLanguage ?? this.targetLanguage,
    autoTranslate: autoTranslate ?? this.autoTranslate,
  );

  Map<String, dynamic> toJson() => {
    'target_language': targetLanguage,
    'auto_translate': autoTranslate,
  };

  factory TranslationPreferences.fromJson(Map<String, dynamic>? json) =>
      TranslationPreferences(
        targetLanguage: json?['target_language'] as String? ?? '',
        autoTranslate: json?['auto_translate'] as bool? ?? false,
      );
}

class TranslationOptions {
  const TranslationOptions({
    this.enabled = false,
    this.targetLanguage = '',
    this.baseUrl = '',
    this.model = '',
  });

  factory TranslationOptions.fromSettings(TranslationSettings settings) =>
      TranslationOptions(
        enabled: settings.autoTranslate,
        targetLanguage: settings.targetLanguage,
        baseUrl: settings.baseUrl,
        model: settings.model,
      );

  final bool enabled;
  final String targetLanguage;
  final String baseUrl;
  final String model;

  TranslationOptions copyWith({
    bool? enabled,
    String? targetLanguage,
    String? baseUrl,
    String? model,
  }) => TranslationOptions(
    enabled: enabled ?? this.enabled,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'target_language': targetLanguage,
    'base_url': baseUrl,
    'model': model,
  };

  factory TranslationOptions.fromJson(Map<String, dynamic>? json) =>
      TranslationOptions(
        enabled: json?['enabled'] as bool? ?? false,
        targetLanguage: json?['target_language'] as String? ?? '',
        baseUrl: json?['base_url'] as String? ?? '',
        model: json?['model'] as String? ?? '',
      );
}

class TranslationState {
  const TranslationState({
    this.status = TranslationStatus.idle,
    this.targetLanguage = '',
    this.model = '',
    this.origin,
    this.completedSegments = 0,
    this.totalSegments = 0,
    this.errorCode,
    this.errorMessage,
  });

  final TranslationStatus status;
  final String targetLanguage;
  final String model;
  final TranslationOrigin? origin;
  final int completedSegments;
  final int totalSegments;
  final String? errorCode;
  final String? errorMessage;

  double get progress =>
      totalSegments == 0 ? 0 : completedSegments / totalSegments;

  TranslationState copyWith({
    TranslationStatus? status,
    String? targetLanguage,
    String? model,
    TranslationOrigin? origin,
    int? completedSegments,
    int? totalSegments,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    bool clearOrigin = false,
  }) => TranslationState(
    status: status ?? this.status,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    model: model ?? this.model,
    origin: clearOrigin ? null : origin ?? this.origin,
    completedSegments: completedSegments ?? this.completedSegments,
    totalSegments: totalSegments ?? this.totalSegments,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'target_language': targetLanguage,
    'model': model,
    if (origin case final value?) 'origin': value.name,
    'completed_segments': completedSegments,
    'total_segments': totalSegments,
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
  };

  factory TranslationState.fromJson(Map<String, dynamic>? json) =>
      TranslationState(
        status:
            _enumByName(TranslationStatus.values, json?['status']) ??
            TranslationStatus.idle,
        targetLanguage: json?['target_language'] as String? ?? '',
        model: json?['model'] as String? ?? '',
        origin: _enumByName(TranslationOrigin.values, json?['origin']),
        completedSegments: (json?['completed_segments'] as num?)?.toInt() ?? 0,
        totalSegments: (json?['total_segments'] as num?)?.toInt() ?? 0,
        errorCode: json?['error_code'] as String?,
        errorMessage: json?['error_message'] as String?,
      );
}

class AiChapter {
  const AiChapter({
    required this.id,
    required this.title,
    required this.summary,
    required this.evidenceSegmentIds,
    this.edited = false,
  });

  final String id;
  final String title;
  final String summary;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiChapter copyWith({
    String? title,
    String? summary,
    List<String>? evidenceSegmentIds,
    bool? edited,
  }) => AiChapter(
    id: id,
    title: title ?? this.title,
    summary: summary ?? this.summary,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiChapter.fromJson(Map<String, dynamic> json) => AiChapter(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    evidenceSegmentIds: _strings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiInsight {
  const AiInsight({
    required this.id,
    required this.type,
    required this.text,
    required this.evidenceSegmentIds,
    this.owner,
    this.deadline,
    this.edited = false,
  });

  final String id;
  final AiInsightType type;
  final String text;
  final String? owner;
  final String? deadline;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiInsight copyWith({
    String? text,
    String? owner,
    String? deadline,
    List<String>? evidenceSegmentIds,
    bool? edited,
    bool clearOwner = false,
    bool clearDeadline = false,
  }) => AiInsight(
    id: id,
    type: type,
    text: text ?? this.text,
    owner: clearOwner ? null : owner ?? this.owner,
    deadline: clearDeadline ? null : deadline ?? this.deadline,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'text': text,
    if (owner case final value?) 'owner': value,
    if (deadline case final value?) 'deadline': value,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiInsight.fromJson(Map<String, dynamic> json) => AiInsight(
    id: json['id'] as String? ?? '',
    type:
        _enumByName(AiInsightType.values, json['type']) ??
        AiInsightType.keyIdea,
    text: json['text'] as String? ?? '',
    owner: json['owner'] as String?,
    deadline: json['deadline'] as String?,
    evidenceSegmentIds: _strings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiLanguageNote {
  const AiLanguageNote({
    required this.id,
    required this.kind,
    required this.term,
    required this.explanation,
    required this.sourceExcerpt,
    required this.evidenceSegmentIds,
    this.edited = false,
  });

  final String id;
  final AiLanguageNoteKind kind;
  final String term;
  final String explanation;
  final String sourceExcerpt;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiLanguageNote copyWith({
    String? term,
    String? explanation,
    String? sourceExcerpt,
    List<String>? evidenceSegmentIds,
    bool? edited,
  }) => AiLanguageNote(
    id: id,
    kind: kind,
    term: term ?? this.term,
    explanation: explanation ?? this.explanation,
    sourceExcerpt: sourceExcerpt ?? this.sourceExcerpt,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'term': term,
    'explanation': explanation,
    'source_excerpt': sourceExcerpt,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiLanguageNote.fromJson(Map<String, dynamic> json) => AiLanguageNote(
    id: json['id'] as String? ?? '',
    kind:
        _enumByName(AiLanguageNoteKind.values, json['kind']) ??
        AiLanguageNoteKind.vocabulary,
    term: json['term'] as String? ?? '',
    explanation: json['explanation'] as String? ?? '',
    sourceExcerpt: json['source_excerpt'] as String? ?? '',
    evidenceSegmentIds: _strings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiBrief {
  const AiBrief({
    required this.overview,
    this.overviewEvidenceSegmentIds = const [],
    required this.chapters,
    required this.insights,
    this.languageNotes = const [],
    this.learningLanguage,
    this.learningLevel = AiLearningLevel.intermediate,
    required this.outputLanguage,
    required this.model,
    required this.selectedSections,
    required this.generatedAt,
    required this.sourceTranscriptUpdatedAt,
    this.edited = false,
  });

  final String overview;
  final List<String> overviewEvidenceSegmentIds;
  final List<AiChapter> chapters;
  final List<AiInsight> insights;
  final List<AiLanguageNote> languageNotes;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
  final String outputLanguage;
  final String model;
  final Set<AiBriefSection> selectedSections;
  final DateTime generatedAt;
  final DateTime sourceTranscriptUpdatedAt;
  final bool edited;

  bool isStaleFor(TranscriptDocument document) =>
      document.updatedAt.isAfter(sourceTranscriptUpdatedAt);

  AiBrief copyWith({
    String? overview,
    List<String>? overviewEvidenceSegmentIds,
    List<AiChapter>? chapters,
    List<AiInsight>? insights,
    List<AiLanguageNote>? languageNotes,
    String? learningLanguage,
    AiLearningLevel? learningLevel,
    bool? edited,
    bool clearLearningLanguage = false,
  }) => AiBrief(
    overview: overview ?? this.overview,
    overviewEvidenceSegmentIds:
        overviewEvidenceSegmentIds ?? this.overviewEvidenceSegmentIds,
    chapters: chapters ?? this.chapters,
    insights: insights ?? this.insights,
    languageNotes: languageNotes ?? this.languageNotes,
    learningLanguage: clearLearningLanguage
        ? null
        : learningLanguage ?? this.learningLanguage,
    learningLevel: learningLevel ?? this.learningLevel,
    outputLanguage: outputLanguage,
    model: model,
    selectedSections: selectedSections,
    generatedAt: generatedAt,
    sourceTranscriptUpdatedAt: sourceTranscriptUpdatedAt,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'overview': overview,
    'overview_evidence_segment_ids': overviewEvidenceSegmentIds,
    'chapters': chapters.map((item) => item.toJson()).toList(),
    'insights': insights.map((item) => item.toJson()).toList(),
    'language_notes': languageNotes.map((item) => item.toJson()).toList(),
    if (learningLanguage case final value?) 'learning_language': value,
    'learning_level': learningLevel.name,
    'output_language': outputLanguage,
    'model': model,
    'selected_sections': selectedSections.map((item) => item.name).toList(),
    'generated_at': generatedAt.toIso8601String(),
    'source_transcript_updated_at': sourceTranscriptUpdatedAt.toIso8601String(),
    'edited': edited,
  };

  factory AiBrief.fromJson(Map<String, dynamic> json) => AiBrief(
    overview: json['overview'] as String? ?? '',
    overviewEvidenceSegmentIds: _strings(json['overview_evidence_segment_ids']),
    chapters: _mapList(json['chapters'], AiChapter.fromJson),
    insights: _mapList(json['insights'], AiInsight.fromJson),
    languageNotes: _mapList(json['language_notes'], AiLanguageNote.fromJson),
    learningLanguage: json['learning_language'] as String?,
    learningLevel:
        _enumByName(AiLearningLevel.values, json['learning_level']) ??
        AiLearningLevel.intermediate,
    outputLanguage: json['output_language'] as String? ?? 'en',
    model: json['model'] as String? ?? '',
    selectedSections: _enumSet(
      AiBriefSection.values,
      json['selected_sections'],
      fallback: defaultAiBriefSections,
    ),
    generatedAt: _date(json['generated_at']) ?? DateTime.now().toUtc(),
    sourceTranscriptUpdatedAt:
        _date(json['source_transcript_updated_at']) ?? DateTime.now().toUtc(),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiGenerationState {
  const AiGenerationState({
    this.status = AiGenerationStatus.idle,
    this.stage = '',
    this.completedChunks = 0,
    this.totalChunks = 0,
    this.outputLanguage = '',
    this.learningLanguage,
    this.learningLevel = AiLearningLevel.intermediate,
    this.model = '',
    this.selectedSections = const {},
    this.mergeSections = false,
    this.errorCode,
    this.errorMessage,
  });

  final AiGenerationStatus status;
  final String stage;
  final int completedChunks;
  final int totalChunks;
  final String outputLanguage;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
  final String model;
  final Set<AiBriefSection> selectedSections;
  final bool mergeSections;
  final String? errorCode;
  final String? errorMessage;

  double get progress => totalChunks == 0 ? 0 : completedChunks / totalChunks;

  AiGenerationState copyWith({
    AiGenerationStatus? status,
    String? stage,
    int? completedChunks,
    int? totalChunks,
    String? outputLanguage,
    String? learningLanguage,
    AiLearningLevel? learningLevel,
    String? model,
    Set<AiBriefSection>? selectedSections,
    bool? mergeSections,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    bool clearLearningLanguage = false,
  }) => AiGenerationState(
    status: status ?? this.status,
    stage: stage ?? this.stage,
    completedChunks: completedChunks ?? this.completedChunks,
    totalChunks: totalChunks ?? this.totalChunks,
    outputLanguage: outputLanguage ?? this.outputLanguage,
    learningLanguage: clearLearningLanguage
        ? null
        : learningLanguage ?? this.learningLanguage,
    learningLevel: learningLevel ?? this.learningLevel,
    model: model ?? this.model,
    selectedSections: selectedSections ?? this.selectedSections,
    mergeSections: mergeSections ?? this.mergeSections,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'stage': stage,
    'completed_chunks': completedChunks,
    'total_chunks': totalChunks,
    'output_language': outputLanguage,
    if (learningLanguage case final value?) 'learning_language': value,
    'learning_level': learningLevel.name,
    'model': model,
    'selected_sections': selectedSections.map((item) => item.name).toList(),
    'merge_sections': mergeSections,
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
  };

  factory AiGenerationState.fromJson(Map<String, dynamic>? json) =>
      AiGenerationState(
        status:
            _enumByName(AiGenerationStatus.values, json?['status']) ??
            AiGenerationStatus.idle,
        stage: json?['stage'] as String? ?? '',
        completedChunks: (json?['completed_chunks'] as num?)?.toInt() ?? 0,
        totalChunks: (json?['total_chunks'] as num?)?.toInt() ?? 0,
        outputLanguage: json?['output_language'] as String? ?? '',
        learningLanguage: json?['learning_language'] as String?,
        learningLevel:
            _enumByName(AiLearningLevel.values, json?['learning_level']) ??
            AiLearningLevel.intermediate,
        model: json?['model'] as String? ?? '',
        selectedSections: _enumSet(
          AiBriefSection.values,
          json?['selected_sections'],
          fallback: const {},
        ),
        mergeSections: json?['merge_sections'] as bool? ?? false,
        errorCode: json?['error_code'] as String?,
        errorMessage: json?['error_message'] as String?,
      );
}

const supportedTranslationLanguageCodes = <String>[
  'en',
  'zh-Hans',
  'zh-Hant',
  'ja',
  'ko',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ru',
  'ar',
  'hi',
  'vi',
  'th',
  'yue',
  'nl',
  'pl',
  'tr',
  'uk',
  'cs',
  'sv',
  'da',
  'fi',
  'el',
  'he',
  'id',
  'ms',
];

const supportedSonioxTranslationLanguageCodes = <String>[
  'af',
  'sq',
  'ar',
  'az',
  'eu',
  'be',
  'bn',
  'bs',
  'bg',
  'ca',
  'zh',
  'hr',
  'cs',
  'da',
  'nl',
  'en',
  'et',
  'fi',
  'fr',
  'gl',
  'de',
  'el',
  'gu',
  'he',
  'hi',
  'hu',
  'id',
  'it',
  'ja',
  'kn',
  'kk',
  'ko',
  'lv',
  'lt',
  'mk',
  'ms',
  'ml',
  'mr',
  'no',
  'fa',
  'pl',
  'pt',
  'pa',
  'ro',
  'ru',
  'sr',
  'sk',
  'sl',
  'es',
  'sw',
  'sv',
  'tl',
  'ta',
  'te',
  'th',
  'tr',
  'uk',
  'ur',
  'vi',
  'cy',
];

class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.txt,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.localeCode = 'en',
    this.contentMode = ExportContentMode.original,
  });

  final ExportFormat format;
  final bool showSpeakers;
  final bool showTimestamps;
  final String localeCode;
  final ExportContentMode contentMode;

  ExportOptions copyWith({
    ExportFormat? format,
    bool? showSpeakers,
    bool? showTimestamps,
    String? localeCode,
    ExportContentMode? contentMode,
  }) => ExportOptions(
    format: format ?? this.format,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    localeCode: localeCode ?? this.localeCode,
    contentMode: contentMode ?? this.contentMode,
  );

  Map<String, dynamic> toJson() => {
    'format': format.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'locale_code': localeCode,
    'content_mode': contentMode.name,
  };

  factory ExportOptions.fromJson(Map<String, dynamic>? json) => ExportOptions(
    format:
        _enumByName(ExportFormat.values, json?['format']) ?? ExportFormat.txt,
    showSpeakers: json?['show_speakers'] as bool? ?? true,
    showTimestamps: json?['show_timestamps'] as bool? ?? false,
    localeCode: json?['locale_code'] as String? ?? 'en',
    contentMode:
        _enumByName(ExportContentMode.values, json?['content_mode']) ??
        ExportContentMode.original,
  );
}

class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.localeMode = AppLocaleMode.system,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.blindListeningEnabled = false,
    this.mimicRepGoal = 3,
    this.mimicPauseSeconds = 0,
    this.exportOptions = const ExportOptions(),
    this.onboardingComplete = false,
    LlmProviderSettings llmProviderSettings = const LlmProviderSettings(),
    TranslationPreferences translationPreferences =
        const TranslationPreferences(),
    TranslationSettings? translationSettings,
    this.sonioxTranslation = const SonioxTranslationOptions(),
    this.defaultTranscriptionProvider = TranscriptionProvider.soniox,
    this.defaultForcedAlignmentModel,
    this.automaticWordTiming = true,
    this.autoTranscribeLocal = false,
    this.lastContentDestination = AppContentDestination.podcast,
    this.lastWorkspaceJobId,
    this.playbackPositionsMs = const {},
  }) : _llmProviderSettings = llmProviderSettings,
       _translationPreferences = translationPreferences,
       _legacyTranslationSettings = translationSettings;

  final AppThemeMode themeMode;
  final AppLocaleMode localeMode;
  final bool showSpeakers;
  final bool showTimestamps;
  final bool blindListeningEnabled;
  final int mimicRepGoal;

  /// Zero selects a pause based on the sentence's playback duration.
  final int mimicPauseSeconds;
  final ExportOptions exportOptions;
  final bool onboardingComplete;
  final LlmProviderSettings _llmProviderSettings;
  final TranslationPreferences _translationPreferences;
  final TranslationSettings? _legacyTranslationSettings;
  final SonioxTranslationOptions sonioxTranslation;
  final TranscriptionProvider defaultTranscriptionProvider;
  final ForcedAlignmentModel? defaultForcedAlignmentModel;
  final bool automaticWordTiming;
  final bool autoTranscribeLocal;
  final AppContentDestination lastContentDestination;
  final String? lastWorkspaceJobId;
  final Map<String, int> playbackPositionsMs;

  LlmProviderSettings get llmProviderSettings =>
      _legacyTranslationSettings?.providerSettings ?? _llmProviderSettings;

  TranslationPreferences get translationPreferences =>
      _legacyTranslationSettings?.preferences ?? _translationPreferences;

  TranslationSettings get translationSettings => TranslationSettings.fromParts(
    llmProviderSettings,
    translationPreferences,
  );

  AppSettings copyWith({
    AppThemeMode? themeMode,
    AppLocaleMode? localeMode,
    bool? showSpeakers,
    bool? showTimestamps,
    bool? blindListeningEnabled,
    int? mimicRepGoal,
    int? mimicPauseSeconds,
    ExportOptions? exportOptions,
    bool? onboardingComplete,
    LlmProviderSettings? llmProviderSettings,
    TranslationPreferences? translationPreferences,
    TranslationSettings? translationSettings,
    SonioxTranslationOptions? sonioxTranslation,
    TranscriptionProvider? defaultTranscriptionProvider,
    ForcedAlignmentModel? defaultForcedAlignmentModel,
    bool? automaticWordTiming,
    bool? autoTranscribeLocal,
    AppContentDestination? lastContentDestination,
    String? lastWorkspaceJobId,
    bool clearLastWorkspaceJobId = false,
    Map<String, int>? playbackPositionsMs,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    localeMode: localeMode ?? this.localeMode,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    blindListeningEnabled: blindListeningEnabled ?? this.blindListeningEnabled,
    mimicRepGoal: mimicRepGoal ?? this.mimicRepGoal,
    mimicPauseSeconds: mimicPauseSeconds ?? this.mimicPauseSeconds,
    exportOptions: exportOptions ?? this.exportOptions,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    llmProviderSettings:
        translationSettings?.providerSettings ??
        llmProviderSettings ??
        this.llmProviderSettings,
    translationPreferences:
        translationSettings?.preferences ??
        translationPreferences ??
        this.translationPreferences,
    sonioxTranslation: sonioxTranslation ?? this.sonioxTranslation,
    defaultTranscriptionProvider:
        defaultTranscriptionProvider ?? this.defaultTranscriptionProvider,
    defaultForcedAlignmentModel:
        defaultForcedAlignmentModel ?? this.defaultForcedAlignmentModel,
    automaticWordTiming: automaticWordTiming ?? this.automaticWordTiming,
    autoTranscribeLocal: autoTranscribeLocal ?? this.autoTranscribeLocal,
    lastContentDestination:
        lastContentDestination ?? this.lastContentDestination,
    lastWorkspaceJobId: clearLastWorkspaceJobId
        ? null
        : lastWorkspaceJobId ?? this.lastWorkspaceJobId,
    playbackPositionsMs: playbackPositionsMs ?? this.playbackPositionsMs,
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'theme_mode': themeMode.name,
    'locale_mode': localeMode.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'blind_listening_enabled': blindListeningEnabled,
    'mimic_rep_goal': mimicRepGoal,
    'mimic_pause_seconds': mimicPauseSeconds,
    'export_options': exportOptions.toJson(),
    'onboarding_complete': onboardingComplete,
    'llm_provider_settings': llmProviderSettings.toJson(),
    'translation_preferences': translationPreferences.toJson(),
    'soniox_translation': sonioxTranslation.toJson(),
    'default_transcription_provider': defaultTranscriptionProvider.name,
    if (defaultForcedAlignmentModel case final value?)
      'default_forced_alignment_model': value.name,
    'auto_align_transcripts': automaticWordTiming,
    'auto_transcribe_local': autoTranscribeLocal,
    'last_content_destination': lastContentDestination.name,
    if (lastWorkspaceJobId case final value?) 'last_workspace_job_id': value,
    if (playbackPositionsMs.isNotEmpty)
      'playback_positions_ms': playbackPositionsMs,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final legacy = TranslationSettings.fromJson(
      (json['translation_settings'] as Map?)?.cast<String, dynamic>(),
    );
    final hasSplitSettings = json['llm_provider_settings'] is Map;
    return AppSettings(
      themeMode:
          _enumByName(AppThemeMode.values, json['theme_mode']) ??
          AppThemeMode.system,
      localeMode:
          _enumByName(AppLocaleMode.values, json['locale_mode']) ??
          AppLocaleMode.system,
      showSpeakers: json['show_speakers'] as bool? ?? true,
      showTimestamps: json['show_timestamps'] as bool? ?? false,
      blindListeningEnabled: json['blind_listening_enabled'] as bool? ?? false,
      mimicRepGoal: switch (json['mimic_rep_goal']) {
        int value when value > 0 => value,
        _ => const AppSettings().mimicRepGoal,
      },
      mimicPauseSeconds: switch (json['mimic_pause_seconds']) {
        int value when value >= 0 && value <= 10 => value,
        _ => const AppSettings().mimicPauseSeconds,
      },
      exportOptions: ExportOptions.fromJson(
        (json['export_options'] as Map?)?.cast<String, dynamic>(),
      ),
      onboardingComplete: json['onboarding_complete'] as bool? ?? false,
      llmProviderSettings: hasSplitSettings
          ? LlmProviderSettings.fromJson(
              (json['llm_provider_settings'] as Map).cast<String, dynamic>(),
            )
          : legacy.providerSettings,
      translationPreferences: hasSplitSettings
          ? TranslationPreferences.fromJson(
              (json['translation_preferences'] as Map?)
                  ?.cast<String, dynamic>(),
            )
          : legacy.preferences,
      sonioxTranslation: SonioxTranslationOptions.fromJson(
        (json['soniox_translation'] as Map?)?.cast<String, dynamic>(),
      ),
      defaultTranscriptionProvider:
          _enumByName(
            TranscriptionProvider.values,
            json['default_transcription_provider'],
          ) ??
          TranscriptionProvider.soniox,
      defaultForcedAlignmentModel: _enumByName(
        ForcedAlignmentModel.values,
        json['default_forced_alignment_model'],
      ),
      automaticWordTiming:
          json['auto_align_transcripts'] as bool? ??
          json['auto_align_moss'] as bool? ??
          true,
      autoTranscribeLocal: json['auto_transcribe_local'] as bool? ?? false,
      lastContentDestination:
          _enumByName(
            AppContentDestination.values,
            json['last_content_destination'],
          ) ??
          AppContentDestination.podcast,
      lastWorkspaceJobId: json['last_workspace_job_id'] as String?,
      playbackPositionsMs: _playbackPositionsFromJson(
        json['playback_positions_ms'],
      ),
    );
  }
}

Map<String, int> _playbackPositionsFromJson(Object? value) {
  if (value is! Map) return const {};
  final maximum = const Duration(days: 365).inMilliseconds;
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is num)
        if ((entry.value as num).toInt() case final milliseconds
            when milliseconds > 0 && milliseconds <= maximum)
          entry.key as String: milliseconds,
  };
}

class LibraryGroup {
  const LibraryGroup({required this.id, required this.name});

  final String id;
  final String name;

  LibraryGroup copyWith({String? name}) =>
      LibraryGroup(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory LibraryGroup.fromJson(Map<String, dynamic> json) =>
      LibraryGroup(id: json['id'] as String, name: json['name'] as String);
}

class LibraryTag {
  const LibraryTag({required this.id, required this.name});

  final String id;
  final String name;

  LibraryTag copyWith({String? name}) =>
      LibraryTag(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory LibraryTag.fromJson(Map<String, dynamic> json) =>
      LibraryTag(id: json['id'] as String, name: json['name'] as String);
}

class LibraryCatalog {
  const LibraryCatalog({this.groups = const [], this.tags = const []});

  final List<LibraryGroup> groups;
  final List<LibraryTag> tags;

  LibraryCatalog copyWith({
    List<LibraryGroup>? groups,
    List<LibraryTag>? tags,
  }) => LibraryCatalog(groups: groups ?? this.groups, tags: tags ?? this.tags);

  Map<String, dynamic> toJson() => {
    'version': 1,
    'groups': groups.map((group) => group.toJson()).toList(),
    'tags': tags.map((tag) => tag.toJson()).toList(),
  };

  factory LibraryCatalog.fromJson(Map<String, dynamic>? json) => LibraryCatalog(
    groups: _mapList(json?['groups'], LibraryGroup.fromJson),
    tags: _mapList(json?['tags'], LibraryTag.fromJson),
  );
}

class InboxMonitorConfig {
  const InboxMonitorConfig({
    this.folderPath = '',
    this.paused = false,
    this.extensions = supportedMonitoredMediaExtensions,
    this.launchAtLogin = false,
    this.showTrayIcon = true,
  });

  final String folderPath;
  final bool paused;
  final Set<String> extensions;
  final bool launchAtLogin;
  final bool showTrayIcon;

  bool get isConfigured => folderPath.trim().isNotEmpty;

  InboxMonitorConfig copyWith({
    String? folderPath,
    bool? paused,
    Set<String>? extensions,
    bool? launchAtLogin,
    bool? showTrayIcon,
  }) => InboxMonitorConfig(
    folderPath: folderPath ?? this.folderPath,
    paused: paused ?? this.paused,
    extensions: extensions ?? this.extensions,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    showTrayIcon: showTrayIcon ?? this.showTrayIcon,
  );

  Map<String, dynamic> toJson() => {
    'folder_path': folderPath,
    'paused': paused,
    'extensions': extensions.toList()..sort(),
    'launch_at_login': launchAtLogin,
    'show_tray_icon': showTrayIcon,
  };

  factory InboxMonitorConfig.fromJson(Map<String, dynamic>? json) {
    final extensions = _strings(json?['extensions'])
        .map((value) => value.trim().toLowerCase().replaceFirst('.', ''))
        .where(supportedMonitoredMediaExtensions.contains)
        .toSet();
    return InboxMonitorConfig(
      folderPath: json?['folder_path'] as String? ?? '',
      paused: json?['paused'] as bool? ?? false,
      extensions: extensions.isEmpty
          ? supportedMonitoredMediaExtensions
          : extensions,
      launchAtLogin: json?['launch_at_login'] as bool? ?? false,
      showTrayIcon: json?['show_tray_icon'] as bool? ?? true,
    );
  }
}

class SourceFingerprint {
  const SourceFingerprint({
    required this.identity,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String identity;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;

  bool sameVersion(SourceFingerprint other) =>
      identity == other.identity &&
      sizeBytes == other.sizeBytes &&
      modifiedAt.isAtSameMomentAs(other.modifiedAt);

  Map<String, dynamic> toJson() => {
    'identity': identity,
    'path': path,
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt.toUtc().toIso8601String(),
  };

  factory SourceFingerprint.fromJson(Map<String, dynamic> json) =>
      SourceFingerprint(
        identity: json['identity'] as String? ?? json['path'] as String? ?? '',
        path: json['path'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        modifiedAt:
            _date(json['modified_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

class MonitoredFileRecord {
  const MonitoredFileRecord({
    required this.fingerprint,
    required this.disposition,
    required this.updatedAt,
    this.jobId,
  });

  final SourceFingerprint fingerprint;
  final MonitoredFileDisposition disposition;
  final DateTime updatedAt;
  final String? jobId;

  MonitoredFileRecord copyWith({
    SourceFingerprint? fingerprint,
    MonitoredFileDisposition? disposition,
    DateTime? updatedAt,
    String? jobId,
  }) => MonitoredFileRecord(
    fingerprint: fingerprint ?? this.fingerprint,
    disposition: disposition ?? this.disposition,
    updatedAt: updatedAt ?? this.updatedAt,
    jobId: jobId ?? this.jobId,
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint.toJson(),
    'disposition': disposition.name,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (jobId case final value?) 'job_id': value,
  };

  factory MonitoredFileRecord.fromJson(Map<String, dynamic> json) =>
      MonitoredFileRecord(
        fingerprint: SourceFingerprint.fromJson(
          (json['fingerprint'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        disposition:
            _enumByName(MonitoredFileDisposition.values, json['disposition']) ??
            MonitoredFileDisposition.dismissed,
        updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
        jobId: json['job_id'] as String?,
      );
}

class InboxMonitorStorage {
  const InboxMonitorStorage({
    this.config = const InboxMonitorConfig(),
    this.records = const {},
  });

  final InboxMonitorConfig config;
  final Map<String, MonitoredFileRecord> records;

  InboxMonitorStorage copyWith({
    InboxMonitorConfig? config,
    Map<String, MonitoredFileRecord>? records,
  }) => InboxMonitorStorage(
    config: config ?? this.config,
    records: records ?? this.records,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'config': config.toJson(),
    'records': {
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    },
  };

  factory InboxMonitorStorage.fromJson(Map<String, dynamic>? json) {
    final rawRecords = json?['records'];
    final records = <String, MonitoredFileRecord>{};
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final record = MonitoredFileRecord.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
        if (record.fingerprint.identity.isNotEmpty) {
          records[entry.key as String] = record;
        }
      }
    }
    return InboxMonitorStorage(
      config: InboxMonitorConfig.fromJson(
        (json?['config'] as Map?)?.cast<String, dynamic>(),
      ),
      records: records,
    );
  }
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

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory TranscriptionJob.fromJson(Map<String, dynamic> json) {
    final status =
        _enumByName(JobStatus.values, json['status']) ?? JobStatus.pending;
    return TranscriptionJob(
      id: json['id'] as String,
      batchId: json['batch_id'] as String? ?? 'recovered',
      sourcePath: json['source_path'] as String,
      createdAt: _date(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
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
          _enumByName(CleanupState.values, json['cleanup_state']) ??
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
      tagIds: _strings(
        json['tag_ids'],
      ).map((value) => value.trim()).where((value) => value.isNotEmpty).toSet(),
      sourceOrigin:
          _enumByName(JobSourceOrigin.values, json['source_origin']) ??
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
      transcriptAcquisitionMode: _transcriptAcquisitionModeFromJson(
        json['transcript_acquisition_mode'],
      ),
      transcriptionProvider: _transcriptionProviderFromJson(
        json['transcription_provider'],
        json['transcript_acquisition_mode'],
      ),
      transcriptSource: _enumByName(
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

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) parser) =>
    value is List
    ? value
          .whereType<Map>()
          .map((item) => parser(item.cast<String, dynamic>()))
          .toList()
    : <T>[];

List<String> _strings(dynamic value) =>
    value is List ? value.whereType<String>().toList() : const [];

Set<T> _enumSet<T extends Enum>(
  List<T> values,
  dynamic names, {
  required Set<T> fallback,
}) {
  if (names is! List) return Set<T>.of(fallback);
  final result = <T>{};
  for (final name in names) {
    final value = _enumByName(values, name);
    if (value != null) result.add(value);
  }
  return result;
}

DateTime? _date(dynamic value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

T? _enumByName<T extends Enum>(List<T> values, dynamic name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

TranscriptAcquisitionMode _transcriptAcquisitionModeFromJson(dynamic name) {
  if (name == 'publisherWordTimed') {
    return TranscriptAcquisitionMode.publisherCaptions;
  }
  return _enumByName(TranscriptAcquisitionMode.values, name) ??
      TranscriptAcquisitionMode.soniox;
}

TranscriptionProvider _transcriptionProviderFromJson(
  dynamic provider,
  dynamic acquisitionMode,
) =>
    _enumByName(TranscriptionProvider.values, provider) ??
    switch (acquisitionMode) {
      'mossPro' => TranscriptionProvider.mossPro,
      'mossLocal' => TranscriptionProvider.mossLocal,
      'qwen3Local' => TranscriptionProvider.qwen3Local,
      _ => TranscriptionProvider.soniox,
    };

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
