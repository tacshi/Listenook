import 'dart:convert';

const int manifestVersion = 5;
const int maxMediaDurationMs = 300 * 60 * 1000;

enum JobStatus {
  pending,
  probing,
  ready,
  converting,
  uploading,
  queuedRemote,
  processing,
  fetching,
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
    JobStatus.converting ||
    JobStatus.uploading ||
    JobStatus.queuedRemote ||
    JobStatus.processing ||
    JobStatus.fetching => true,
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

enum CleanupState { none, pending, complete }

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
    this.speaker,
    this.language,
    this.confidence,
    this.translationStatus,
    this.sourceLanguage,
  });

  final String text;
  final int startMs;
  final int endMs;
  final String? speaker;
  final String? language;
  final double? confidence;
  final String? translationStatus;
  final String? sourceLanguage;

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_ms': startMs,
    'end_ms': endMs,
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
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String? speaker;
  final String? language;
  final String? translatedText;

  bool get hasTranslation => translatedText?.trim().isNotEmpty ?? false;

  TranscriptSegment copyWith({
    String? text,
    String? speaker,
    String? language,
    String? translatedText,
    bool clearTranslatedText = false,
  }) => TranscriptSegment(
    id: id,
    startMs: startMs,
    endMs: endMs,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    language: language ?? this.language,
    translatedText: clearTranslatedText
        ? null
        : translatedText ?? this.translatedText,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'start_ms': startMs,
    'end_ms': endMs,
    'text': text,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (translatedText case final value?) 'translated_text': value,
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
    List<TranscriptSegment>? segments,
    List<SpeakerProfile>? speakers,
  }) => TranscriptDocument(
    tokens: tokens,
    segments: segments ?? this.segments,
    speakers: speakers ?? this.speakers,
    updatedAt: DateTime.now().toUtc(),
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

class AiBrief {
  const AiBrief({
    required this.overview,
    this.overviewEvidenceSegmentIds = const [],
    required this.chapters,
    required this.insights,
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
    bool? edited,
  }) => AiBrief(
    overview: overview ?? this.overview,
    overviewEvidenceSegmentIds:
        overviewEvidenceSegmentIds ?? this.overviewEvidenceSegmentIds,
    chapters: chapters ?? this.chapters,
    insights: insights ?? this.insights,
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
    String? model,
    Set<AiBriefSection>? selectedSections,
    bool? mergeSections,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
  }) => AiGenerationState(
    status: status ?? this.status,
    stage: stage ?? this.stage,
    completedChunks: completedChunks ?? this.completedChunks,
    totalChunks: totalChunks ?? this.totalChunks,
    outputLanguage: outputLanguage ?? this.outputLanguage,
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
    this.exportOptions = const ExportOptions(),
    this.onboardingComplete = false,
    LlmProviderSettings llmProviderSettings = const LlmProviderSettings(),
    TranslationPreferences translationPreferences =
        const TranslationPreferences(),
    TranslationSettings? translationSettings,
    this.sonioxTranslation = const SonioxTranslationOptions(),
  }) : _llmProviderSettings = llmProviderSettings,
       _translationPreferences = translationPreferences,
       _legacyTranslationSettings = translationSettings;

  final AppThemeMode themeMode;
  final AppLocaleMode localeMode;
  final bool showSpeakers;
  final bool showTimestamps;
  final ExportOptions exportOptions;
  final bool onboardingComplete;
  final LlmProviderSettings _llmProviderSettings;
  final TranslationPreferences _translationPreferences;
  final TranslationSettings? _legacyTranslationSettings;
  final SonioxTranslationOptions sonioxTranslation;

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
    ExportOptions? exportOptions,
    bool? onboardingComplete,
    LlmProviderSettings? llmProviderSettings,
    TranslationPreferences? translationPreferences,
    TranslationSettings? translationSettings,
    SonioxTranslationOptions? sonioxTranslation,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    localeMode: localeMode ?? this.localeMode,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
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
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'theme_mode': themeMode.name,
    'locale_mode': localeMode.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'export_options': exportOptions.toJson(),
    'onboarding_complete': onboardingComplete,
    'llm_provider_settings': llmProviderSettings.toJson(),
    'translation_preferences': translationPreferences.toJson(),
    'soniox_translation': sonioxTranslation.toJson(),
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
    );
  }
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
  });

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
    bool clearError = false,
    bool clearRemoteFileId = false,
    bool clearRemoteTranscriptionId = false,
    bool clearAiBrief = false,
    bool clearDisplayTitle = false,
    bool clearGroupId = false,
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
